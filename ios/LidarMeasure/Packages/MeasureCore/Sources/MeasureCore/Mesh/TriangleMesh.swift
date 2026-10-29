import Foundation

/// Indexed triangle mesh in metres, +Y up (ARKit world convention), counter-clockwise front faces.
public struct TriangleMesh: Sendable, Equatable {
    public var positions: [Vec3f]
    /// Per-vertex unit normals. Either empty or `positions.count` long.
    public var normals: [Vec3f]
    /// Three indices per triangle.
    public var indices: [UInt32]
    /// Optional per-triangle ARKit classification (`ARMeshClassification.rawValue`).
    /// Either empty or `triangleCount` long.
    public var faceClassifications: [UInt8]

    public init(positions: [Vec3f] = [], normals: [Vec3f] = [], indices: [UInt32] = [], faceClassifications: [UInt8] = []) {
        self.positions = positions
        self.normals = normals
        self.indices = indices
        self.faceClassifications = faceClassifications
    }

    public var vertexCount: Int { positions.count }
    public var triangleCount: Int { indices.count / 3 }
    public var isEmpty: Bool { indices.isEmpty }
    public var hasClassifications: Bool { !faceClassifications.isEmpty && faceClassifications.count == triangleCount }

    public var bounds: AABB? { AABB(points: positions) }

    /// Approximate in-memory size, used for the scan memory budget display.
    public var estimatedBytes: Int {
        positions.count * MemoryLayout<Vec3f>.stride + normals.count * MemoryLayout<Vec3f>.stride
            + indices.count * 4 + faceClassifications.count
    }

    public func triangle(_ t: Int) -> (UInt32, UInt32, UInt32) {
        (indices[t * 3], indices[t * 3 + 1], indices[t * 3 + 2])
    }

    /// Appends another mesh (e.g. the next ARMeshAnchor chunk), offsetting its indices.
    public mutating func append(_ other: TriangleMesh) {
        let offset = UInt32(positions.count)
        let keepNormals = (normals.count == positions.count || positions.isEmpty) && other.normals.count == other.positions.count
        let keepClasses = (hasClassifications || isEmpty) && other.hasClassifications
        positions.append(contentsOf: other.positions)
        if keepNormals { normals.append(contentsOf: other.normals) } else { normals.removeAll() }
        indices.append(contentsOf: other.indices.map { $0 + offset })
        if keepClasses { faceClassifications.append(contentsOf: other.faceClassifications) } else { faceClassifications.removeAll() }
    }

    /// Reverses the winding of every triangle (flips front faces).
    public mutating func flipWinding() {
        for t in 0..<triangleCount { indices.swapAt(t * 3 + 1, t * 3 + 2) }
        normals = normals.map { -$0 }
    }

    public func translated(by offset: Vec3f) -> TriangleMesh {
        var copy = self
        copy.positions = positions.map { $0 + offset }
        return copy
    }
}

/// Axis-aligned bounding box.
public struct AABB: Sendable, Equatable, Codable {
    public var min: Vec3f
    public var max: Vec3f

    public init(min: Vec3f, max: Vec3f) {
        self.min = min
        self.max = max
    }

    public init?(points: [Vec3f]) {
        guard var lo = points.first else { return nil }
        var hi = lo
        for p in points {
            lo = pointwiseMin(lo, p)
            hi = pointwiseMax(hi, p)
        }
        self.min = lo
        self.max = hi
    }

    public var center: Vec3f { (min + max) / 2 }
    public var size: Vec3f { max - min }
    /// Bottom centre: where a model's origin should sit so it rests on the floor in AR Quick Look.
    public var baseCenter: Vec3f { Vec3f(center.x, min.y, center.z) }

    public func contains(_ p: Vec3f) -> Bool {
        p.x >= min.x && p.y >= min.y && p.z >= min.z && p.x <= max.x && p.y <= max.y && p.z <= max.z
    }

    public func intersects(_ other: AABB) -> Bool {
        min.x <= other.max.x && max.x >= other.min.x &&
            min.y <= other.max.y && max.y >= other.min.y &&
            min.z <= other.max.z && max.z >= other.min.z
    }

    public func expanded(by margin: Float) -> AABB {
        AABB(min: min - Vec3f(repeating: margin), max: max + Vec3f(repeating: margin))
    }
}

/// Gravity-aligned box used to crop a scan to an object or region. Rotates about +Y only,
/// because ARKit's world Y is aligned with gravity and objects sit on horizontal surfaces.
public struct OrientedBox: Sendable, Equatable, Codable {
    /// Geometric centre in world space.
    public var center: Vec3
    /// Rotation about +Y (radians).
    public var yaw: Double
    /// Full width (local X), height (local Y) and depth (local Z) in metres.
    public var size: Vec3

    public init(center: Vec3, yaw: Double, size: Vec3) {
        self.center = center
        self.yaw = yaw
        self.size = size
    }

    /// Box standing on a surface: `base` is the centre of its bottom face.
    public init(base: Vec3, yaw: Double, size: Vec3) {
        self.init(center: base + Vec3(0, size.y / 2, 0), yaw: yaw, size: size)
    }

    public var localToWorld: RigidTransform { .yaw(yaw, translation: center) }

    public var baseY: Double { center.y - size.y / 2 }

    public func contains(_ p: Vec3, margin: Double = 0) -> Bool {
        let local = localToWorld.inverse.apply(p)
        let h = size / 2 + Vec3(repeating: margin)
        return abs(local.x) <= h.x && abs(local.y) <= h.y && abs(local.z) <= h.z
    }

    /// World-space axis-aligned bounds of the rotated box.
    public var worldBounds: AABB {
        let t = localToWorld
        let h = size / 2
        var corners: [Vec3f] = []
        for sx in [-1.0, 1.0] { for sy in [-1.0, 1.0] { for sz in [-1.0, 1.0] {
            corners.append(Vec.float(t.apply(Vec3(sx * h.x, sy * h.y, sz * h.z))))
        } } }
        return AABB(points: corners)!
    }
}
