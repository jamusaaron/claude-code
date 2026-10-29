import Foundation

/// A rotation plus translation (no scale), stored as three rotation columns and a translation.
///
/// ARKit camera and anchor transforms are rigid, so this is all the core package needs. The app
/// target converts `simd_float4x4` to and from this type at the boundary (see `SIMDBridge.swift`).
public struct RigidTransform: Equatable, Codable, Sendable {
    /// Rotation columns: the local X, Y and Z axes expressed in the parent space.
    public var c0: Vec3
    public var c1: Vec3
    public var c2: Vec3
    /// Local origin expressed in the parent space.
    public var translation: Vec3

    public init(c0: Vec3, c1: Vec3, c2: Vec3, translation: Vec3) {
        self.c0 = c0
        self.c1 = c1
        self.c2 = c2
        self.translation = translation
    }

    public static let identity = RigidTransform(
        c0: Vec3(1, 0, 0), c1: Vec3(0, 1, 0), c2: Vec3(0, 0, 1), translation: .zero
    )

    /// Rotation about +Y (gravity-up in ARKit world space) followed by a translation.
    public static func yaw(_ radians: Double, translation: Vec3 = .zero) -> RigidTransform {
        let c = cos(radians), s = sin(radians)
        return RigidTransform(
            c0: Vec3(c, 0, -s),
            c1: Vec3(0, 1, 0),
            c2: Vec3(s, 0, c),
            translation: translation
        )
    }

    /// Maps a point from local to parent space.
    @inlinable public func apply(_ p: Vec3) -> Vec3 {
        c0 * p.x + c1 * p.y + c2 * p.z + translation
    }

    @inlinable public func apply(_ p: Vec3f) -> Vec3f {
        Vec.float(apply(Vec.double(p)))
    }

    /// Maps a direction (ignores translation).
    @inlinable public func rotate(_ d: Vec3) -> Vec3 {
        c0 * d.x + c1 * d.y + c2 * d.z
    }

    /// Inverse, valid because the rotation part is orthonormal (inverse == transpose).
    public var inverse: RigidTransform {
        let r0 = Vec3(c0.x, c1.x, c2.x)
        let r1 = Vec3(c0.y, c1.y, c2.y)
        let r2 = Vec3(c0.z, c1.z, c2.z)
        let t = -(r0 * translation.x + r1 * translation.y + r2 * translation.z)
        return RigidTransform(c0: r0, c1: r1, c2: r2, translation: t)
    }

    /// Composition: `(a * b).apply(p) == a.apply(b.apply(p))`.
    public static func * (a: RigidTransform, b: RigidTransform) -> RigidTransform {
        RigidTransform(
            c0: a.rotate(b.c0),
            c1: a.rotate(b.c1),
            c2: a.rotate(b.c2),
            translation: a.apply(b.translation)
        )
    }

    /// Unit +Y axis expressed in parent space.
    public var up: Vec3 { c1 }

    /// ARKit cameras look down their local -Z axis.
    public var cameraForward: Vec3 { -c2 }
}
