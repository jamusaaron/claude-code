import Foundation

/// Pinhole intrinsics for an image of `width × height` pixels (pixel centres at +0.5).
public struct CameraIntrinsics: Sendable, Equatable, Codable {
    public var fx: Double
    public var fy: Double
    public var cx: Double
    public var cy: Double
    public var width: Int
    public var height: Int

    public init(fx: Double, fy: Double, cx: Double, cy: Double, width: Int, height: Int) {
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
        self.width = width
        self.height = height
    }

    /// Intrinsics for the same camera after resizing the image.
    public func scaled(toWidth w: Int, height h: Int) -> CameraIntrinsics {
        let sx = Double(w) / Double(width)
        let sy = Double(h) / Double(height)
        return CameraIntrinsics(fx: fx * sx, fy: fy * sy, cx: cx * sx, cy: cy * sy, width: w, height: h)
    }
}

/// A LiDAR depth map aligned with a keyframe image. 0 marks invalid or low-confidence pixels.
public struct DepthImage: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var values: [Float]

    public init(width: Int, height: Int, values: [Float]) {
        precondition(values.count == width * height, "depth buffer size mismatch")
        self.width = width
        self.height = height
        self.values = values
    }

    /// Nearest-neighbour lookup at normalised image coordinates (0...1, top-left origin).
    public func value(atNormalized u: Double, _ v: Double) -> Float? {
        let x = Int(u * Double(width)), y = Int(v * Double(height))
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let d = values[y * width + x]
        return d > 0 && d.isFinite ? d : nil
    }
}

/// A camera frame kept during scanning for texturing.
///
/// `cameraToWorld` follows ARKit: the camera looks down local -Z, +Y is up and +X is right in
/// the sensor's native landscape orientation. Image coordinates are u right, v down.
public struct Keyframe: Sendable, Equatable {
    public var id: Int
    public var cameraToWorld: RigidTransform
    /// Intrinsics for the *stored* (downscaled) image.
    public var intrinsics: CameraIntrinsics
    public var depth: DepthImage?

    public init(id: Int, cameraToWorld: RigidTransform, intrinsics: CameraIntrinsics, depth: DepthImage?) {
        self.id = id
        self.cameraToWorld = cameraToWorld
        self.intrinsics = intrinsics
        self.depth = depth
    }
}

public struct TextureProjectionOptions: Sendable, Equatable {
    /// Keyframes kept in the atlas. More keyframes give better coverage and a bigger texture.
    public var maxKeyframes: Int
    /// Faces seen more obliquely than acos(minimumCosine) are not textured from that view.
    public var minimumCosine: Double
    /// Projected vertices must be this far inside the image (pixels), which stops texture
    /// filtering bleeding in from the neighbouring atlas cell.
    public var edgeMargin: Double
    /// A face is occluded in a view if the LiDAR depth there is nearer by more than this.
    public var occlusionTolerance: Double
    public var occlusionRelativeTolerance: Double
    /// Largest atlas side in pixels. 4096 is safe for AR Quick Look on every LiDAR device.
    public var maxAtlasDimension: Int
    /// Height of the neutral grey strip used by faces no keyframe saw.
    public var gutterHeight: Int

    public init(maxKeyframes: Int = 16, minimumCosine: Double = 0.2, edgeMargin: Double = 8,
                occlusionTolerance: Double = 0.04, occlusionRelativeTolerance: Double = 0.03,
                maxAtlasDimension: Int = 4096, gutterHeight: Int = 8) {
        self.maxKeyframes = maxKeyframes
        self.minimumCosine = minimumCosine
        self.edgeMargin = edgeMargin
        self.occlusionTolerance = occlusionTolerance
        self.occlusionRelativeTolerance = occlusionRelativeTolerance
        self.maxAtlasDimension = maxAtlasDimension
        self.gutterHeight = gutterHeight
    }
}

/// Where each keyframe image goes in the texture atlas (pixels, top-left origin).
public struct AtlasCell: Sendable, Equatable, Codable {
    public var keyframeID: Int
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
}

public struct AtlasLayout: Sendable, Equatable, Codable {
    public var width: Int
    public var height: Int
    public var cells: [AtlasCell]
    /// Neutral strip (top-left origin) for untextured faces: y in gutterY..<height.
    public var gutterY: Int
}

/// Output mesh ready for export: vertices are split wherever a face's texture source changes.
/// UVs use a top-left origin (glTF/Metal convention); exporters flip V for OBJ and USD.
public struct TexturedMesh: Sendable, Equatable {
    public var positions: [Vec3f]
    public var normals: [Vec3f]
    /// Empty when the mesh carries no texture.
    public var uvs: [Vec2f]
    public var indices: [UInt32]
    public var atlas: AtlasLayout?
    /// Share of surface area that received real camera texture (0...1).
    public var texturedAreaShare: Double

    public init(positions: [Vec3f], normals: [Vec3f], uvs: [Vec2f], indices: [UInt32], atlas: AtlasLayout?, texturedAreaShare: Double) {
        self.positions = positions
        self.normals = normals
        self.uvs = uvs
        self.indices = indices
        self.atlas = atlas
        self.texturedAreaShare = texturedAreaShare
    }

    public init(untextured mesh: TriangleMesh) {
        let normals = mesh.normals.count == mesh.vertexCount ? mesh.normals : MeshProcessing.vertexNormals(mesh)
        self.init(positions: mesh.positions, normals: normals, uvs: [], indices: mesh.indices, atlas: nil, texturedAreaShare: 0)
    }

    public var vertexCount: Int { positions.count }
    public var triangleCount: Int { indices.count / 3 }
    public var hasTexture: Bool { atlas != nil && uvs.count == positions.count }
    public var bounds: AABB? { AABB(points: positions) }

    public func translated(by offset: Vec3f) -> TexturedMesh {
        var copy = self
        copy.positions = positions.map { $0 + offset }
        return copy
    }
}

/// Multi-view projective texturing.
///
/// ARKit's scene mesh has geometry but no colour. To texture it we keep a set of camera
/// keyframes during the scan (image + pose + intrinsics + LiDAR depth). After cleanup, every
/// triangle picks the single keyframe that saw it best: facing the camera, close, near the
/// image centre and not hidden behind something nearer (checked against that keyframe's own
/// LiDAR depth). The chosen keyframe images are packed into a grid atlas, and each triangle's
/// UVs are simply its vertices projected into its keyframe's cell.
///
/// One keyframe per triangle avoids ghosting from blending poorly aligned views. The cost is
/// visible seams where neighbouring faces come from different exposures, which the app
/// softens with per-keyframe exposure normalisation when compositing the atlas.
public enum TextureProjector {
    struct Candidate {
        var keyframe: Int // index into the keyframes array
        var score: Double
    }

    /// Projects a world point into a keyframe image (pixels). Returns nil if behind the camera.
    public static func project(_ p: Vec3, into keyframe: Keyframe, worldToCamera: RigidTransform) -> (u: Double, v: Double, depth: Double)? {
        let c = worldToCamera.apply(p)
        let depth = -c.z
        guard depth > 0.05 else { return nil }
        let k = keyframe.intrinsics
        let u = k.fx * (c.x / depth) + k.cx
        let v = k.fy * (-c.y / depth) + k.cy
        return (u, v, depth)
    }

    public static func project(mesh: TriangleMesh, keyframes: [Keyframe], options: TextureProjectionOptions = TextureProjectionOptions(), progress: ((Double) -> Void)? = nil) -> TexturedMesh {
        guard !mesh.isEmpty, !keyframes.isEmpty, options.maxKeyframes > 0 else {
            return TexturedMesh(untextured: mesh)
        }
        let worldToCamera = keyframes.map { $0.cameraToWorld.inverse }
        let cameraCentres = keyframes.map { $0.cameraToWorld.translation }
        let triangleCount = mesh.triangleCount

        // Pass 1: each triangle's three best views.
        var best = [[Candidate]](repeating: [], count: triangleCount)
        var areas = [Double](repeating: 0, count: triangleCount)
        let progressStride = max(1, triangleCount / 50)
        for t in 0..<triangleCount {
            if t % progressStride == 0 { progress?(0.8 * Double(t) / Double(triangleCount)) }
            let (i, j, k) = mesh.triangle(t)
            let a = Vec.double(mesh.positions[Int(i)])
            let b = Vec.double(mesh.positions[Int(j)])
            let c = Vec.double(mesh.positions[Int(k)])
            let areaNormal = Vec.cross(b - a, c - a)
            let twiceArea = Vec.length(areaNormal)
            guard twiceArea > 1e-12 else { continue }
            areas[t] = twiceArea / 2
            let n = areaNormal / twiceArea
            let centroid = (a + b + c) / 3

            var top: [Candidate] = []
            for (f, kf) in keyframes.enumerated() {
                let toCamera = cameraCentres[f] - centroid
                let distance = Vec.length(toCamera)
                guard distance > 0.05 else { continue }
                let cosine = Vec.dot(n, toCamera) / distance
                guard cosine >= options.minimumCosine else { continue }

                guard let pc = project(centroid, into: kf, worldToCamera: worldToCamera[f]),
                      inside(pc.u, pc.v, kf.intrinsics, margin: options.edgeMargin),
                      let pa = project(a, into: kf, worldToCamera: worldToCamera[f]),
                      let pb = project(b, into: kf, worldToCamera: worldToCamera[f]),
                      let pcc = project(c, into: kf, worldToCamera: worldToCamera[f]),
                      inside(pa.u, pa.v, kf.intrinsics, margin: options.edgeMargin),
                      inside(pb.u, pb.v, kf.intrinsics, margin: options.edgeMargin),
                      inside(pcc.u, pcc.v, kf.intrinsics, margin: options.edgeMargin)
                else { continue }

                // Occlusion: the keyframe's own LiDAR depth must not be clearly nearer.
                if let depth = kf.depth,
                   let measured = depth.value(atNormalized: pc.u / Double(kf.intrinsics.width), pc.v / Double(kf.intrinsics.height)) {
                    let tolerance = max(options.occlusionTolerance, options.occlusionRelativeTolerance * pc.depth)
                    if Double(measured) < pc.depth - tolerance { continue }
                }

                // Prefer head-on, close and central views (lens edges are softer and less accurate).
                let du = (pc.u - kf.intrinsics.cx) / Double(kf.intrinsics.width)
                let dv = (pc.v - kf.intrinsics.cy) / Double(kf.intrinsics.height)
                let radial = min(1, (du * du + dv * dv).squareRoot() * 2)
                let score = cosine * cosine / max(pc.depth, 0.3) * (1 - 0.5 * radial)
                insert(Candidate(keyframe: f, score: score), into: &top, limit: 3)
            }
            best[t] = top
        }

        // Pass 2: keep the keyframes that win the most surface area.
        var usage = [Double](repeating: 0, count: keyframes.count)
        for t in 0..<triangleCount { if let first = best[t].first { usage[first.keyframe] += areas[t] } }
        let kept = usage.enumerated()
            .filter { $0.element > 0 }
            .sorted { $0.element > $1.element }
            .prefix(options.maxKeyframes)
            .map { $0.offset }
            .sorted()
        guard !kept.isEmpty else { return TexturedMesh(untextured: mesh) }
        let keptSet = Set(kept)

        var assignment = [Int](repeating: -1, count: triangleCount)
        for t in 0..<triangleCount {
            if let choice = best[t].first(where: { keptSet.contains($0.keyframe) }) { assignment[t] = choice.keyframe }
        }
        progress?(0.85)

        // Atlas layout: a grid of equally sized cells, scaled to fit the maximum dimension.
        let reference = keyframes[kept[0]].intrinsics
        let layout = makeLayout(keyframeIDs: kept.map { keyframes[$0].id }, imageWidth: reference.width, imageHeight: reference.height, options: options)
        var cellForKeyframe: [Int: AtlasCell] = [:]
        for (slot, f) in kept.enumerated() { cellForKeyframe[f] = layout.cells[slot] }
        let untexturedUV = Vec2f(
            Float((Double(layout.width) / 2) / Double(layout.width)),
            Float((Double(layout.gutterY) + Double(layout.height - layout.gutterY) / 2) / Double(layout.height))
        )

        // Pass 3: split vertices per (original vertex, keyframe) and compute UVs.
        struct VertexKey: Hashable { let vertex: UInt32; let keyframe: Int }
        var vertexMap: [VertexKey: UInt32] = [:]
        vertexMap.reserveCapacity(mesh.vertexCount * 2)
        let normals = mesh.normals.count == mesh.vertexCount ? mesh.normals : MeshProcessing.vertexNormals(mesh)
        var outPositions: [Vec3f] = []
        var outNormals: [Vec3f] = []
        var outUVs: [Vec2f] = []
        var outIndices: [UInt32] = []
        outIndices.reserveCapacity(mesh.indices.count)
        var texturedArea = 0.0
        var totalArea = 0.0

        for t in 0..<triangleCount {
            let f = assignment[t]
            totalArea += areas[t]
            if f >= 0 { texturedArea += areas[t] }
            let (i, j, k) = mesh.triangle(t)
            for vi in [i, j, k] {
                let key = VertexKey(vertex: vi, keyframe: f)
                if let existing = vertexMap[key] {
                    outIndices.append(existing)
                    continue
                }
                let p = mesh.positions[Int(vi)]
                var uv = untexturedUV
                if f >= 0, let cell = cellForKeyframe[f],
                   let proj = project(Vec.double(p), into: keyframes[f], worldToCamera: worldToCamera[f]) {
                    let sx = Double(cell.width) / Double(keyframes[f].intrinsics.width)
                    let sy = Double(cell.height) / Double(keyframes[f].intrinsics.height)
                    uv = Vec2f(
                        Float((Double(cell.x) + proj.u * sx) / Double(layout.width)),
                        Float((Double(cell.y) + proj.v * sy) / Double(layout.height))
                    )
                }
                let index = UInt32(outPositions.count)
                vertexMap[key] = index
                outPositions.append(p)
                outNormals.append(normals[Int(vi)])
                outUVs.append(uv)
                outIndices.append(index)
            }
        }
        progress?(1)
        return TexturedMesh(
            positions: outPositions,
            normals: outNormals,
            uvs: outUVs,
            indices: outIndices,
            atlas: layout,
            texturedAreaShare: totalArea > 0 ? texturedArea / totalArea : 0
        )
    }

    public static func makeLayout(keyframeIDs: [Int], imageWidth: Int, imageHeight: Int, options: TextureProjectionOptions) -> AtlasLayout {
        let count = max(1, keyframeIDs.count)
        let columns = Int(Double(count).squareRoot().rounded(.up))
        let rows = (count + columns - 1) / columns
        let maxDim = Double(options.maxAtlasDimension)
        let scale = min(1, maxDim / Double(columns * imageWidth), (maxDim - Double(options.gutterHeight)) / Double(rows * imageHeight))
        let cellW = max(1, Int((Double(imageWidth) * scale).rounded(.down)))
        let cellH = max(1, Int((Double(imageHeight) * scale).rounded(.down)))
        var cells: [AtlasCell] = []
        for (slot, id) in keyframeIDs.enumerated() {
            cells.append(AtlasCell(keyframeID: id, x: (slot % columns) * cellW, y: (slot / columns) * cellH, width: cellW, height: cellH))
        }
        return AtlasLayout(width: columns * cellW, height: rows * cellH + options.gutterHeight, cells: cells, gutterY: rows * cellH)
    }

    @inline(__always) static func inside(_ u: Double, _ v: Double, _ k: CameraIntrinsics, margin: Double) -> Bool {
        u >= margin && v >= margin && u <= Double(k.width) - margin && v <= Double(k.height) - margin
    }

    static func insert(_ c: Candidate, into list: inout [Candidate], limit: Int) {
        var i = list.count
        while i > 0 && list[i - 1].score < c.score { i -= 1 }
        guard i < limit else { return }
        list.insert(c, at: i)
        if list.count > limit { list.removeLast() }
    }
}
