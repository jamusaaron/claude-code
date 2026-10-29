import Foundation

/// ARKit's per-pixel depth confidence (`ARConfidenceLevel`), mirrored so the core stays framework-free.
public enum DepthConfidence: Int, Codable, Sendable, Comparable, CaseIterable {
    case low = 0
    case medium = 1
    case high = 2

    public static func < (a: DepthConfidence, b: DepthConfidence) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }
}

/// How a measurement point was located. This drives both the accuracy estimate and the UI hint.
public enum SnapKind: String, Codable, Sendable, CaseIterable {
    /// Ray hit on the fused LiDAR scene mesh.
    case mesh
    /// Projected onto a detected ARKit plane (least-squares fit over many depth samples).
    case plane
    /// Intersection line of two planes fitted to the local mesh.
    case edge
    /// Intersection point of three planes fitted to the local mesh.
    case corner
    /// Re-used an existing measurement point.
    case point
    /// Unprojected directly from a single frame of the LiDAR depth map.
    case depth
    /// ARKit's estimated plane only (no LiDAR support). Least reliable.
    case estimatedPlane

    public var title: String {
        switch self {
        case .mesh: return "Surface"
        case .plane: return "Plane"
        case .edge: return "Edge"
        case .corner: return "Corner"
        case .point: return "Point"
        case .depth: return "Depth"
        case .estimatedPlane: return "Estimated"
        }
    }
}

public enum TrackingQuality: String, Codable, Sendable {
    case normal
    case limited
    case notAvailable
}

/// Coarse confidence grade shown next to every value.
public enum ConfidenceGrade: String, Codable, Sendable, Comparable {
    case low
    case medium
    case high

    private var rank: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    public static func < (a: ConfidenceGrade, b: ConfidenceGrade) -> Bool { a.rank < b.rank }

    public var title: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }
}

/// Error model for phone LiDAR measurements.
///
/// This is an engineering estimate, not a calibration. It is built from:
///  * The sensor: a sparse dToF emitter (~576 points) upsampled by ARKit to a 256×192 depth map.
///    Published evaluations of iPhone 12/13 Pro LiDAR (e.g. Luetzenburg et al. 2021,
///    Vogt et al. 2021) report roughly ±1 cm for objects larger than ~10 cm at close range,
///    with errors growing with range and failing on specular, transparent or very dark surfaces.
///  * The depth confidence ARKit reports per pixel.
///  * How the point was found: plane fits average many samples, a single-frame depth pixel does not.
///  * Visual-inertial tracking drift, which grows with the distance between the two points.
///
/// Values are 1-sigma "typical error" estimates, shown with a ± so users never read
/// phone LiDAR as survey-grade.
public enum AccuracyModel {
    /// Range-independent floor for a well-observed, high-confidence point (m).
    public static let baseSigma = 0.003
    /// Additional error per metre of range for a high-confidence point (m/m).
    public static let rangeCoefficient = 0.005
    /// Relative tracking drift between two points, as a fraction of their separation.
    public static let relativeDrift = 0.005
    /// Beyond this range the LiDAR returns are sparse and unreliable (m).
    public static let reliableRange = 5.0

    public static func pointSigma(range: Double, confidence: DepthConfidence, snap: SnapKind, tracking: TrackingQuality) -> Double {
        let r = max(0, range)
        var sigma = baseSigma + rangeCoefficient * r

        switch confidence {
        case .high: break
        case .medium: sigma *= 2
        case .low: sigma *= 4
        }

        switch snap {
        case .plane: sigma *= 0.75     // least-squares plane over hundreds of samples
        case .corner: sigma *= 0.9      // three fitted planes; sharper than the rounded raw mesh
        case .edge: sigma *= 1.0
        case .mesh, .point: sigma *= 1.0
        case .depth: sigma *= 1.3       // single frame, single pixel neighbourhood
        case .estimatedPlane: sigma *= 2.5
        }

        if r > reliableRange { sigma *= 1 + (r - reliableRange) } // degrade quickly past ~5 m

        switch tracking {
        case .normal: break
        case .limited: sigma *= 2
        case .notAvailable: sigma *= 5
        }
        return sigma
    }

    /// Point-to-point distance: independent endpoint errors plus drift proportional to length.
    public static func distanceSigma(_ s1: Double, _ s2: Double, length: Double) -> Double {
        let drift = relativeDrift * length
        return (s1 * s1 + s2 * s2 + drift * drift).squareRoot()
    }

    /// First-order propagation of independent, isotropic vertex errors into polygon area.
    /// Moving vertex i perpendicular to the chord (v[i-1], v[i+1]) changes the area at a rate
    /// of |v[i+1] - v[i-1]| / 2. The scale-drift term adds a relative error of 2 × drift.
    public static func polygonAreaSigma(points: [Vec3], sigmas: [Double], area: Double) -> Double {
        let n = points.count
        guard n >= 3, sigmas.count == n else { return .infinity }
        var variance = 0.0
        for i in 0..<n {
            let chord = Vec.distance(points[(i + 1) % n], points[(i + n - 1) % n])
            let term = 0.5 * chord * sigmas[i]
            variance += term * term
        }
        let drift = 2 * relativeDrift * area
        return (variance + drift * drift).squareRoot()
    }

    public static func prismVolumeSigma(area: Double, areaSigma: Double, height: Double, heightSigma: Double) -> Double {
        let a = areaSigma * height
        let b = area * heightSigma
        return (a * a + b * b).squareRoot()
    }

    /// Grade from absolute and relative error. A tiny object with ±5 mm is "low" even though
    /// ±5 mm sounds good: at 4 cm that is a 12% error.
    public static func grade(lengthSigma sigma: Double, length: Double) -> ConfidenceGrade {
        let relative = length > 0 ? sigma / length : .infinity
        if sigma <= 0.01 && relative <= 0.02 { return .high }
        if sigma <= 0.03 && relative <= 0.06 { return .medium }
        return .low
    }

    public static func grade(relativeError: Double) -> ConfidenceGrade {
        if relativeError <= 0.03 { return .high }
        if relativeError <= 0.08 { return .medium }
        return .low
    }

    /// Grade of a single point on its own (used for the live reticle colour).
    public static func grade(pointSigma sigma: Double) -> ConfidenceGrade {
        if sigma <= 0.01 { return .high }
        if sigma <= 0.025 { return .medium }
        return .low
    }
}
