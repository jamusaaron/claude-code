import Foundation

public struct PrismMetrics: Sendable, Equatable {
    public var baseArea: Double
    /// Perpendicular distance from the base plane to the top point (m).
    public var height: Double
    public var volume: Double
    /// Unit normal of the base, oriented towards the top point.
    public var baseNormal: Vec3
    public var baseCentroid: Vec3
}

public struct MeshVolumeEstimate: Sendable, Equatable {
    /// Enclosed volume between the mesh surface and the support plane (m³).
    public var volume: Double
    /// Fraction of edge length (above the support plane) that borders a hole. 0 means closed.
    public var openness: Double
    /// Whether the estimate should be trusted at all: closed enough and positive.
    public var isReliable: Bool
}

public enum VolumeGeometry {
    /// Right prism: a traced base polygon extruded to the height of a top point.
    /// Works for rooms (floor outline + ceiling point) and boxes (top outline + floor point).
    public static func prism(base: [Vec3], top: Vec3) -> PrismMetrics? {
        guard let m = PolygonGeometry.metrics(base) else { return nil }
        var n = m.normal
        var h = Vec.dot(top - m.centroid, n)
        if h < 0 { n = -n; h = -h }
        return PrismMetrics(baseArea: m.area, height: h, volume: m.area * h, baseNormal: n, baseCentroid: m.centroid)
    }

    /// Volume of an object resting on a horizontal support plane (`y == planeY`, +Y up).
    ///
    /// Divergence theorem with the field F = (0, y - planeY, 0): over a closed surface,
    /// the integral of F·n dA equals the enclosed volume. The missing bottom face lies on the
    /// plane where F is zero, so an open-bottomed scan of an object still gives the right
    /// answer. Each triangle contributes (signed projected area on XZ) × (mean height of its
    /// vertices), which is exact for flat triangles.
    ///
    /// Caveats a user must see: holes in the scan, concavities the LiDAR never saw, and
    /// anything hidden under the object are all counted as solid or missing.
    public static func meshVolumeAbovePlane(positions: [Vec3f], indices: [UInt32], planeY: Double) -> MeshVolumeEstimate {
        let triangleCount = indices.count / 3
        guard triangleCount > 0 else { return MeshVolumeEstimate(volume: 0, openness: 1, isReliable: false) }

        var volume = 0.0
        for t in 0..<triangleCount {
            let a = Vec.double(positions[Int(indices[t * 3])])
            let b = Vec.double(positions[Int(indices[t * 3 + 1])])
            let c = Vec.double(positions[Int(indices[t * 3 + 2])])
            let projectedTwiceArea = Vec.cross(b - a, c - a).y // signed: +ve when facing up
            let meanHeight = ((a.y - planeY) + (b.y - planeY) + (c.y - planeY)) / 3
            volume += 0.5 * projectedTwiceArea * meanHeight
        }

        let openness = boundaryOpenness(positions: positions, indices: indices, ignoreBelowY: planeY + 0.02)
        let reliable = volume > 0 && openness < 0.05
        return MeshVolumeEstimate(volume: max(0, volume), openness: openness, isReliable: reliable)
    }

    /// Share of total edge length that is on a boundary (used by exactly one triangle),
    /// ignoring edges that sit on the support plane (the open bottom is expected).
    public static func boundaryOpenness(positions: [Vec3f], indices: [UInt32], ignoreBelowY: Double) -> Double {
        struct EdgeKey: Hashable { let a: UInt32; let b: UInt32 }
        var counts: [EdgeKey: Int] = [:]
        counts.reserveCapacity(indices.count)
        let triangleCount = indices.count / 3
        for t in 0..<triangleCount {
            for e in 0..<3 {
                let i = indices[t * 3 + e]
                let j = indices[t * 3 + (e + 1) % 3]
                counts[EdgeKey(a: min(i, j), b: max(i, j)), default: 0] += 1
            }
        }
        var total = 0.0
        var boundary = 0.0
        for (key, count) in counts {
            let p = positions[Int(key.a)], q = positions[Int(key.b)]
            if Double(max(p.y, q.y)) < ignoreBelowY { continue }
            let len = Double(Vec.length(p - q))
            total += len
            if count == 1 { boundary += len }
        }
        return total > 0 ? boundary / total : 1
    }
}
