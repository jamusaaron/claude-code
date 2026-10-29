import simd
import MeasureCore

// Conversions between ARKit/RealityKit `simd` types and the framework-free MeasureCore types.

extension RigidTransform {
    /// Builds from a rigid `simd_float4x4` (ARKit camera and anchor transforms are rigid).
    init(_ m: simd_float4x4) {
        self.init(
            c0: Vec3(Double(m.columns.0.x), Double(m.columns.0.y), Double(m.columns.0.z)),
            c1: Vec3(Double(m.columns.1.x), Double(m.columns.1.y), Double(m.columns.1.z)),
            c2: Vec3(Double(m.columns.2.x), Double(m.columns.2.y), Double(m.columns.2.z)),
            translation: Vec3(Double(m.columns.3.x), Double(m.columns.3.y), Double(m.columns.3.z))
        )
    }
}

extension simd_float4x4 {
    /// Translation component (the origin of the local frame in parent space).
    var origin: SIMD3<Float> { SIMD3(columns.3.x, columns.3.y, columns.3.z) }

    /// Transforms a point (w = 1).
    func transformPoint(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let r = self * SIMD4<Float>(p, 1)
        return SIMD3(r.x, r.y, r.z)
    }

    /// Transforms a direction (w = 0).
    func transformDirection(_ d: SIMD3<Float>) -> SIMD3<Float> {
        let r = self * SIMD4<Float>(d, 0)
        return SIMD3(r.x, r.y, r.z)
    }
}

extension SIMD3 where Scalar == Float {
    var asDouble: Vec3 { Vec.double(self) }
}

extension SIMD3 where Scalar == Double {
    var asFloat: SIMD3<Float> { Vec.float(self) }
}
