import Foundation

/// Cleanup options for a captured LiDAR mesh.
public struct MeshCleanupOptions: Sendable, Equatable, Codable {
    /// Keep only triangles whose centroid lies inside this box.
    public var cropBox: OrientedBox?
    /// Remove the upward-facing support surface (floor/table) at this height (+Y up).
    public var supportPlaneY: Double?
    /// Vertex-clustering cell size in metres. 0 disables simplification.
    public var simplifyCellSize: Double
    /// Remove disconnected pieces smaller than this share of the largest piece (0 disables).
    public var minimumComponentShare: Double
    /// Pieces with fewer triangles than this are always removed (when noise removal is on).
    public var minimumComponentTriangles: Int
    /// Vertices closer than this are merged before anything else (ARKit chunks duplicate their borders).
    public var weldTolerance: Double

    public init(cropBox: OrientedBox? = nil, supportPlaneY: Double? = nil, simplifyCellSize: Double = 0.01,
                minimumComponentShare: Double = 0.02, minimumComponentTriangles: Int = 30, weldTolerance: Double = 0.001) {
        self.cropBox = cropBox
        self.supportPlaneY = supportPlaneY
        self.simplifyCellSize = simplifyCellSize
        self.minimumComponentShare = minimumComponentShare
        self.minimumComponentTriangles = minimumComponentTriangles
        self.weldTolerance = weldTolerance
    }

    public var removesNoise: Bool { minimumComponentShare > 0 || minimumComponentTriangles > 0 }
}

public enum MeshProcessing {
    // MARK: Pipeline

    /// Full cleanup pipeline. `progress` receives values in 0...1.
    public static func process(_ input: TriangleMesh, options: MeshCleanupOptions, progress: ((Double) -> Void)? = nil) -> TriangleMesh {
        var mesh = input
        if let box = options.cropBox { mesh = crop(mesh, to: box) }
        progress?(0.15)
        if let y = options.supportPlaneY { mesh = removeSupportSurface(mesh, planeY: y) }
        progress?(0.25)
        mesh = cluster(mesh, cellSize: max(options.weldTolerance, 1e-5))
        progress?(0.45)
        if options.simplifyCellSize > options.weldTolerance {
            mesh = cluster(mesh, cellSize: options.simplifyCellSize)
        }
        progress?(0.7)
        if options.removesNoise {
            mesh = removeSmallComponents(mesh, minimumTriangles: options.minimumComponentTriangles, minimumShareOfLargest: options.minimumComponentShare)
        }
        progress?(0.85)
        mesh = compact(mesh)
        mesh.normals = vertexNormals(mesh)
        progress?(1)
        return mesh
    }

    // MARK: Crop

    /// Keeps triangles whose centroid is inside the box.
    public static func crop(_ mesh: TriangleMesh, to box: OrientedBox) -> TriangleMesh {
        filterTriangles(mesh) { a, b, c in
            box.contains(Vec.double((a + b + c) / 3))
        }
    }

    /// Removes near-horizontal, upward-facing triangles lying on the support plane, so an
    /// object scan doesn't come with a slab of floor attached.
    public static func removeSupportSurface(_ mesh: TriangleMesh, planeY: Double, tolerance: Double = 0.015, minimumUpDot: Float = 0.8) -> TriangleMesh {
        let top = Float(planeY + tolerance)
        return filterTriangles(mesh) { a, b, c in
            let n = Vec.normalize(Vec.cross(b - a, c - a))
            let onPlane = a.y <= top && b.y <= top && c.y <= top
            return !(onPlane && n.y >= minimumUpDot)
        }
    }

    public static func filterTriangles(_ mesh: TriangleMesh, keep: (Vec3f, Vec3f, Vec3f) -> Bool) -> TriangleMesh {
        var out = mesh
        out.indices.removeAll(keepingCapacity: true)
        out.faceClassifications.removeAll(keepingCapacity: true)
        let classes = mesh.hasClassifications
        for t in 0..<mesh.triangleCount {
            let (i, j, k) = mesh.triangle(t)
            if keep(mesh.positions[Int(i)], mesh.positions[Int(j)], mesh.positions[Int(k)]) {
                out.indices.append(contentsOf: [i, j, k])
                if classes { out.faceClassifications.append(mesh.faceClassifications[t]) }
            }
        }
        return compact(out)
    }

    // MARK: Vertex clustering (weld + simplify)

    struct CellKey: Hashable {
        let x: Int32, y: Int32, z: Int32
    }

    @inline(__always) static func quantise(_ v: Float, _ inverseCell: Double) -> Int32 {
        let q = (Double(v) * inverseCell).rounded(.down)
        guard q.isFinite else { return 0 }
        return Int32(clamping: Int(max(-2e9, min(2e9, q))))
    }

    /// Uniform-grid vertex clustering. Every vertex in a cell collapses to the cell's mean;
    /// triangles that become degenerate or duplicated are dropped.
    ///
    /// With a 1 mm cell this welds the duplicated borders between ARMeshAnchor chunks. With a
    /// 1–3 cm cell it simplifies: the LiDAR mesh has a native resolution of roughly 2–5 cm,
    /// so a cell under ~2 cm loses almost no real detail while cutting the size a lot.
    public static func cluster(_ mesh: TriangleMesh, cellSize: Double) -> TriangleMesh {
        guard !mesh.isEmpty, cellSize > 0 else { return mesh }
        let inv = 1 / cellSize
        var cellIndex: [CellKey: UInt32] = [:]
        cellIndex.reserveCapacity(mesh.vertexCount)
        var sums: [Vec3] = []
        var normalSums: [Vec3f] = []
        var counts: [Int] = []
        var remap = [UInt32](repeating: 0, count: mesh.vertexCount)
        let hasNormals = mesh.normals.count == mesh.vertexCount

        for (v, p) in mesh.positions.enumerated() {
            let key = CellKey(x: quantise(p.x, inv), y: quantise(p.y, inv), z: quantise(p.z, inv))
            if let existing = cellIndex[key] {
                remap[v] = existing
                sums[Int(existing)] += Vec.double(p)
                counts[Int(existing)] += 1
                if hasNormals { normalSums[Int(existing)] += mesh.normals[v] }
            } else {
                let new = UInt32(sums.count)
                cellIndex[key] = new
                remap[v] = new
                sums.append(Vec.double(p))
                counts.append(1)
                if hasNormals { normalSums.append(mesh.normals[v]) }
            }
        }

        var out = TriangleMesh()
        out.positions = zip(sums, counts).map { Vec.float($0 / Double($1)) }
        if hasNormals { out.normals = normalSums.map { Vec.normalize($0) } }
        let classes = mesh.hasClassifications

        struct TriKey: Hashable { let a: UInt32, b: UInt32, c: UInt32 }
        var seen = Set<TriKey>()
        seen.reserveCapacity(mesh.triangleCount)
        out.indices.reserveCapacity(mesh.indices.count)
        for t in 0..<mesh.triangleCount {
            let (i, j, k) = mesh.triangle(t)
            let a = remap[Int(i)], b = remap[Int(j)], c = remap[Int(k)]
            if a == b || b == c || a == c { continue }
            // Rotation-invariant key that keeps winding: smallest index first.
            let key: TriKey
            if a < b && a < c { key = TriKey(a: a, b: b, c: c) } else if b < c { key = TriKey(a: b, b: c, c: a) } else { key = TriKey(a: c, b: a, c: b) }
            if !seen.insert(key).inserted { continue }
            out.indices.append(contentsOf: [a, b, c])
            if classes { out.faceClassifications.append(mesh.faceClassifications[t]) }
        }
        return compact(out)
    }

    // MARK: Components

    /// Removes floating noise: disconnected pieces that are tiny relative to the main scan.
    /// LiDAR produces these from reflections, passing people and mixed-pixel "flying" depth at edges.
    public static func removeSmallComponents(_ mesh: TriangleMesh, minimumTriangles: Int, minimumShareOfLargest: Double) -> TriangleMesh {
        guard !mesh.isEmpty else { return mesh }
        var parent = Array(0..<mesh.vertexCount)
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { r = parent[r] }
            var c = x
            while parent[c] != r { let next = parent[c]; parent[c] = r; c = next }
            return r
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
        for t in 0..<mesh.triangleCount {
            let (i, j, k) = mesh.triangle(t)
            union(Int(i), Int(j))
            union(Int(j), Int(k))
        }
        var componentTriangles: [Int: Int] = [:]
        var triangleRoot = [Int](repeating: 0, count: mesh.triangleCount)
        for t in 0..<mesh.triangleCount {
            let r = find(Int(mesh.indices[t * 3]))
            triangleRoot[t] = r
            componentTriangles[r, default: 0] += 1
        }
        let largest = componentTriangles.values.max() ?? 0
        let threshold = max(minimumTriangles, Int(Double(largest) * minimumShareOfLargest))
        var out = mesh
        out.indices.removeAll(keepingCapacity: true)
        out.faceClassifications.removeAll(keepingCapacity: true)
        let classes = mesh.hasClassifications
        for t in 0..<mesh.triangleCount {
            let size = componentTriangles[triangleRoot[t]] ?? 0
            // Never delete the largest piece, even if the whole scan is small.
            guard size >= threshold || size == largest else { continue }
            out.indices.append(contentsOf: [mesh.indices[t * 3], mesh.indices[t * 3 + 1], mesh.indices[t * 3 + 2]])
            if classes { out.faceClassifications.append(mesh.faceClassifications[t]) }
        }
        return compact(out)
    }

    // MARK: Utilities

    /// Drops vertices no triangle uses and renumbers indices.
    public static func compact(_ mesh: TriangleMesh) -> TriangleMesh {
        var remap = [Int32](repeating: -1, count: mesh.vertexCount)
        var out = TriangleMesh()
        let hasNormals = mesh.normals.count == mesh.vertexCount
        out.indices.reserveCapacity(mesh.indices.count)
        for i in mesh.indices {
            var m = remap[Int(i)]
            if m < 0 {
                m = Int32(out.positions.count)
                remap[Int(i)] = m
                out.positions.append(mesh.positions[Int(i)])
                if hasNormals { out.normals.append(mesh.normals[Int(i)]) }
            }
            out.indices.append(UInt32(m))
        }
        out.faceClassifications = mesh.hasClassifications ? mesh.faceClassifications : []
        return out
    }

    /// Area-weighted vertex normals; vertices with no usable faces get +Y.
    public static func vertexNormals(_ mesh: TriangleMesh) -> [Vec3f] {
        var sums = [Vec3f](repeating: .zero, count: mesh.vertexCount)
        for t in 0..<mesh.triangleCount {
            let (i, j, k) = mesh.triangle(t)
            let a = mesh.positions[Int(i)], b = mesh.positions[Int(j)], c = mesh.positions[Int(k)]
            let n = Vec.cross(b - a, c - a) // length == 2 × area, so this is area-weighted
            sums[Int(i)] += n
            sums[Int(j)] += n
            sums[Int(k)] += n
        }
        return sums.map { s in
            let n = Vec.normalize(s)
            return Vec.lengthSquared(n) > 0.5 ? n : Vec3f(0, 1, 0)
        }
    }

    public static func surfaceArea(_ mesh: TriangleMesh) -> Double {
        var total = 0.0
        for t in 0..<mesh.triangleCount {
            let (i, j, k) = mesh.triangle(t)
            let a = Vec.double(mesh.positions[Int(i)]), b = Vec.double(mesh.positions[Int(j)]), c = Vec.double(mesh.positions[Int(k)])
            total += Vec.length(Vec.cross(b - a, c - a)) / 2
        }
        return total
    }

    /// Fraction of triangles whose winding agrees with the supplied per-vertex normals.
    /// ARKit supplies normals; if most faces disagree, the index winding is reversed.
    public static func windingAgreement(_ mesh: TriangleMesh) -> Double {
        guard mesh.normals.count == mesh.vertexCount, mesh.triangleCount > 0 else { return 1 }
        var agree = 0
        var counted = 0
        for t in 0..<mesh.triangleCount {
            let (i, j, k) = mesh.triangle(t)
            let a = mesh.positions[Int(i)], b = mesh.positions[Int(j)], c = mesh.positions[Int(k)]
            let face = Vec.cross(b - a, c - a)
            let vn = mesh.normals[Int(i)] + mesh.normals[Int(j)] + mesh.normals[Int(k)]
            let d = Vec.dot(face, vn)
            if d == 0 { continue }
            counted += 1
            if d > 0 { agree += 1 }
        }
        return counted > 0 ? Double(agree) / Double(counted) : 1
    }
}
