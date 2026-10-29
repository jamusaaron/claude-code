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
    public enum Method: String, Codable, Sendable {
        /// Divergence theorem over a closed, consistently oriented, single-piece mesh.
        case closedMesh
        /// Surface plus the support plane it rests on (open-bottomed object scans).
        case aboveSupportPlane
    }

    /// Enclosed volume (m³).
    public var volume: Double
    /// Fraction of edge length (above the support plane) that borders a hole. 0 means closed.
    public var openness: Double
    /// Whether the estimate should be trusted at all: closed enough and positive.
    public var isReliable: Bool
    public var method: Method = .aboveSupportPlane
    public var topology: MeshTopology?

    public init(volume: Double, openness: Double, isReliable: Bool, method: Method = .aboveSupportPlane, topology: MeshTopology? = nil) {
        self.volume = volume
        self.openness = openness
        self.isReliable = isReliable
        self.method = method
        self.topology = topology
    }
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

    /// Volume of a closed, consistently oriented mesh: sum of signed tetrahedra from the
    /// centroid. Only meaningful when `MeshTopology.isClosedManifold` holds.
    public static func closedMeshVolume(positions: [Vec3f], indices: [UInt32]) -> Double {
        guard !positions.isEmpty else { return 0 }
        let reference = positions.reduce(Vec3.zero) { $0 + Vec.double($1) } / Double(positions.count)
        var signed = 0.0
        for t in 0..<(indices.count / 3) {
            let a = Vec.double(positions[Int(indices[t * 3])]) - reference
            let b = Vec.double(positions[Int(indices[t * 3 + 1])]) - reference
            let c = Vec.double(positions[Int(indices[t * 3 + 2])]) - reference
            signed += Vec.dot(a, Vec.cross(b, c)) / 6
        }
        return signed
    }

    /// Best available volume for a captured mesh, or nil when no estimate is defensible.
    ///
    /// 1. A single closed, consistently oriented manifold gets an exact enclosed volume.
    /// 2. Otherwise, with a known support plane (object scans), the open-bottom estimate is
    ///    used and marked reliable only if the rest of the surface is nearly closed, one
    ///    piece and consistently oriented.
    /// 3. Anything else (rooms, scattered pieces) gets no volume rather than a guess.
    public static func estimateVolume(positions: [Vec3f], indices: [UInt32], supportPlaneY: Double?) -> MeshVolumeEstimate? {
        guard indices.count >= 3 else { return nil }
        let topology = MeshTopology.analyse(indices: indices)
        if topology.isClosedManifold && topology.components == 1 {
            let v = closedMeshVolume(positions: positions, indices: indices)
            return MeshVolumeEstimate(volume: abs(v), openness: 0, isReliable: v > 0, method: .closedMesh, topology: topology)
        }
        guard let planeY = supportPlaneY else { return nil }
        var estimate = meshVolumeAbovePlane(positions: positions, indices: indices, planeY: planeY)
        estimate.topology = topology
        estimate.isReliable = estimate.isReliable && topology.components == 1 && topology.isConsistentlyOriented
            && topology.nonManifoldEdges == 0
        return estimate
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
