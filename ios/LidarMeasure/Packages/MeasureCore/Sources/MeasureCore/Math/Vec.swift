// Vector helpers on the standard library SIMD types.
//
// The `simd` module is Apple-only, so the core package uses its own small set of helpers.
// They sit under a `Vec` namespace instead of global `dot`/`cross` functions so they never
// clash with the `simd` overloads the app target imports.

import Foundation

public typealias Vec3 = SIMD3<Double>
public typealias Vec3f = SIMD3<Float>
public typealias Vec2 = SIMD2<Double>
public typealias Vec2f = SIMD2<Float>

public enum Vec {
    // MARK: Double

    @inlinable public static func dot(_ a: Vec3, _ b: Vec3) -> Double {
        a.x * b.x + a.y * b.y + a.z * b.z
    }

    @inlinable public static func cross(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }

    @inlinable public static func lengthSquared(_ a: Vec3) -> Double { dot(a, a) }

    @inlinable public static func length(_ a: Vec3) -> Double { dot(a, a).squareRoot() }

    @inlinable public static func distance(_ a: Vec3, _ b: Vec3) -> Double { length(a - b) }

    /// Returns the unit vector, or `.zero` for a zero-length input (never NaN).
    @inlinable public static func normalize(_ a: Vec3) -> Vec3 {
        let l = length(a)
        return l > 1e-12 ? a / l : .zero
    }

    @inlinable public static func dot(_ a: Vec2, _ b: Vec2) -> Double { a.x * b.x + a.y * b.y }

    /// z-component of the 2D cross product (twice the signed triangle area).
    @inlinable public static func cross(_ a: Vec2, _ b: Vec2) -> Double { a.x * b.y - a.y * b.x }

    @inlinable public static func length(_ a: Vec2) -> Double { dot(a, a).squareRoot() }

    // MARK: Float

    @inlinable public static func dot(_ a: Vec3f, _ b: Vec3f) -> Float {
        a.x * b.x + a.y * b.y + a.z * b.z
    }

    @inlinable public static func cross(_ a: Vec3f, _ b: Vec3f) -> Vec3f {
        Vec3f(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }

    @inlinable public static func lengthSquared(_ a: Vec3f) -> Float { dot(a, a) }

    @inlinable public static func length(_ a: Vec3f) -> Float { dot(a, a).squareRoot() }

    @inlinable public static func normalize(_ a: Vec3f) -> Vec3f {
        let l = length(a)
        return l > 1e-12 ? a / l : .zero
    }

    // MARK: Conversion

    @inlinable public static func double(_ v: Vec3f) -> Vec3 { Vec3(Double(v.x), Double(v.y), Double(v.z)) }

    @inlinable public static func float(_ v: Vec3) -> Vec3f { Vec3f(Float(v.x), Float(v.y), Float(v.z)) }

    @inlinable public static func isFinite(_ v: Vec3) -> Bool { v.x.isFinite && v.y.isFinite && v.z.isFinite }

    @inlinable public static func isFinite(_ v: Vec3f) -> Bool { v.x.isFinite && v.y.isFinite && v.z.isFinite }

    /// Any unit vector perpendicular to `n` (which must be non-zero).
    public static func anyPerpendicular(to n: Vec3) -> Vec3 {
        let helper: Vec3 = abs(n.x) < 0.9 ? Vec3(1, 0, 0) : Vec3(0, 1, 0)
        return normalize(cross(n, helper))
    }

    /// Angle between two vectors in radians, robust to rounding at 0 and pi.
    public static func angle(_ a: Vec3, _ b: Vec3) -> Double {
        let c = dot(normalize(a), normalize(b))
        return acosClamped(c)
    }

    @inlinable public static func acosClamped(_ c: Double) -> Double {
        acos(max(-1, min(1, c)))
    }
}
