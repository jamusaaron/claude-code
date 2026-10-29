import Foundation

/// One triangle of the LiDAR scene mesh in world space.
public struct SnapTriangle: Sendable, Equatable {
    public var a: Vec3
    public var b: Vec3
    public var c: Vec3

    public init(a: Vec3, b: Vec3, c: Vec3) {
        self.a = a
        self.b = b
        self.c = c
    }

    public var centroid: Vec3 { (a + b + c) / 3 }
    /// Unnormalised normal with length == 2 × area.
    public var areaNormal: Vec3 { Vec.cross(b - a, c - a) }
}

public enum SnapFeature: Sendable, Equatable {
    case none
    case edge(point: Vec3, direction: Vec3)
    case corner(point: Vec3)
}

public struct SnapConfiguration: Sendable {
    /// Neighbourhood radius around the query point (m).
    public var radius: Double
    /// Triangles within this angle of a cluster's normal join the cluster.
    public var clusterAngle: Double
    /// Two clusters must differ by at least this angle to form an edge.
    public var minimumFeatureAngle: Double
    /// A cluster must hold at least this share of the neighbourhood's area to count as a face.
    public var minimumClusterShare: Double

    public init(radius: Double = 0.04, clusterAngleDegrees: Double = 20, minimumFeatureAngleDegrees: Double = 35, minimumClusterShare: Double = 0.12) {
        self.radius = radius
        self.clusterAngle = clusterAngleDegrees * .pi / 180
        self.minimumFeatureAngle = minimumFeatureAngleDegrees * .pi / 180
        self.minimumClusterShare = minimumClusterShare
    }
}

/// Edge and corner snapping on the LiDAR mesh.
///
/// ARKit's reconstructed mesh rounds off sharp edges: a real 90° box edge shows up as a 1–3 cm
/// bevel, because the depth map is upsampled from a sparse dot pattern and then fused. Snapping
/// to the raw mesh vertex at an edge therefore lands *inside* the bevel. Instead we fit planes to
/// the flat faces either side (clusters of triangles with similar normals) and intersect them:
/// two planes give the true edge line, three give the true corner. Flat faces are far better
/// observed than the edge itself, so this recovers a crisper point than any raw sample.
public enum SnapGeometry {
    struct Cluster {
        var normalSum: Vec3     // area-weighted normal sum
        var centroidSum: Vec3   // area-weighted centroid sum
        var area: Double

        var normal: Vec3 { Vec.normalize(normalSum) }
        var centroid: Vec3 { centroidSum / max(area, 1e-12) }
        var plane: Plane? { Plane(normal: normal, through: centroid) }
    }

    public static func findFeature(near point: Vec3, triangles: [SnapTriangle], configuration: SnapConfiguration = SnapConfiguration()) -> SnapFeature {
        let r2 = configuration.radius * configuration.radius
        let local = triangles.filter { Vec.lengthSquared($0.centroid - point) <= r2 }
        guard local.count >= 4 else { return .none }

        let clusters = cluster(local, maxAngle: configuration.clusterAngle)
        let totalArea = clusters.reduce(0) { $0 + $1.area }
        guard totalArea > 0 else { return .none }

        // Distinct faces: big enough and pairwise separated by a real fold angle.
        var faces: [Cluster] = []
        for c in clusters.sorted(by: { $0.area > $1.area }) where c.area / totalArea >= configuration.minimumClusterShare {
            let distinct = faces.allSatisfy { Vec.angle($0.normal, c.normal) >= configuration.minimumFeatureAngle }
            if distinct { faces.append(c) }
            if faces.count == 3 { break }
        }

        if faces.count == 3,
           let p0 = faces[0].plane, let p1 = faces[1].plane, let p2 = faces[2].plane,
           let corner = Plane.intersection(p0, p1, p2),
           Vec.distance(corner, point) <= configuration.radius * 1.5 {
            return .corner(point: corner)
        }

        if faces.count >= 2,
           let p0 = faces[0].plane, let p1 = faces[1].plane,
           let line = Plane.intersection(p0, p1) {
            let onLine = line.closestPoint(to: point)
            if Vec.distance(onLine, point) <= configuration.radius {
                return .edge(point: onLine, direction: line.direction)
            }
        }
        return .none
    }

    /// Greedy normal clustering, largest triangles first, then one merge pass.
    static func cluster(_ triangles: [SnapTriangle], maxAngle: Double) -> [Cluster] {
        let cosMax = cos(maxAngle)
        let sorted = triangles
            .map { ($0, $0.areaNormal) }
            .filter { Vec.lengthSquared($0.1) > 1e-14 }
            .sorted { Vec.lengthSquared($0.1) > Vec.lengthSquared($1.1) }

        var clusters: [Cluster] = []
        for (tri, areaNormal) in sorted {
            let area = Vec.length(areaNormal) / 2
            let n = areaNormal / (2 * area)
            if let i = clusters.firstIndex(where: { Vec.dot($0.normal, n) >= cosMax }) {
                clusters[i].normalSum += n * area
                clusters[i].centroidSum += tri.centroid * area
                clusters[i].area += area
            } else {
                clusters.append(Cluster(normalSum: n * area, centroidSum: tri.centroid * area, area: area))
            }
        }

        // Merge clusters whose mean normals converged together.
        var merged: [Cluster] = []
        for c in clusters {
            if let i = merged.firstIndex(where: { Vec.dot($0.normal, c.normal) >= cosMax }) {
                merged[i].normalSum += c.normalSum
                merged[i].centroidSum += c.centroidSum
                merged[i].area += c.area
            } else {
                merged.append(c)
            }
        }
        return merged
    }
}
