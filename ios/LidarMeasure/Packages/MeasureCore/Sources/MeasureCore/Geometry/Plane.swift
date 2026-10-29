import Foundation

/// Infinite plane `normal · x == offset` with a unit normal.
public struct Plane: Equatable, Sendable, Codable {
    public var normal: Vec3
    public var offset: Double

    /// Plane through `point` with the given (not necessarily unit) normal. Returns nil for a zero normal.
    public init?(normal: Vec3, through point: Vec3) {
        let n = Vec.normalize(normal)
        guard Vec.lengthSquared(n) > 0.5 else { return nil }
        self.normal = n
        self.offset = Vec.dot(n, point)
    }

    public init(unitNormal: Vec3, offset: Double) {
        self.normal = unitNormal
        self.offset = offset
    }

    @inlinable public func signedDistance(_ p: Vec3) -> Double { Vec.dot(normal, p) - offset }

    @inlinable public func project(_ p: Vec3) -> Vec3 { p - normal * signedDistance(p) }

    public var flipped: Plane { Plane(unitNormal: -normal, offset: -offset) }

    /// Line where two planes meet, or nil when they are (near) parallel.
    public static func intersection(_ a: Plane, _ b: Plane, minimumAngle: Double = 1e-3) -> Line? {
        let dir = Vec.cross(a.normal, b.normal)
        let sinAngle = Vec.length(dir)
        guard sinAngle > sin(minimumAngle) else { return nil }
        let c = Vec.dot(a.normal, b.normal)
        let denom = 1 - c * c
        // Closest point to the origin on both planes.
        let origin = (a.normal * (a.offset - b.offset * c) + b.normal * (b.offset - a.offset * c)) / denom
        return Line(origin: origin, direction: dir / sinAngle)
    }

    /// Single point where three planes meet, or nil when the system is ill-conditioned
    /// (`|det| < minimumDeterminant` for unit normals means the corner is poorly defined).
    public static func intersection(_ a: Plane, _ b: Plane, _ c: Plane, minimumDeterminant: Double = 0.05) -> Vec3? {
        let bc = Vec.cross(b.normal, c.normal)
        let det = Vec.dot(a.normal, bc)
        guard abs(det) > minimumDeterminant else { return nil }
        let p = (bc * a.offset + Vec.cross(c.normal, a.normal) * b.offset + Vec.cross(a.normal, b.normal) * c.offset) / det
        return Vec.isFinite(p) ? p : nil
    }
}

/// Infinite line with a unit direction.
public struct Line: Equatable, Sendable {
    public var origin: Vec3
    public var direction: Vec3

    public init(origin: Vec3, direction: Vec3) {
        self.origin = origin
        self.direction = Vec.normalize(direction)
    }

    public func closestPoint(to p: Vec3) -> Vec3 {
        origin + direction * Vec.dot(p - origin, direction)
    }

    public func distance(to p: Vec3) -> Double { Vec.distance(p, closestPoint(to: p)) }
}
