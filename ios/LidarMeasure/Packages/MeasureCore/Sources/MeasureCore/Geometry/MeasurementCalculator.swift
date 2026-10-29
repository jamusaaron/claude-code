import Foundation

public enum MeasurementKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case distance
    case area
    case volume

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .distance: return "Distance"
        case .area: return "Area"
        case .volume: return "Volume"
        }
    }

    /// SI unit symbol used in CSV exports.
    public var siUnit: String {
        switch self {
        case .distance: return "m"
        case .area: return "m2"
        case .volume: return "m3"
        }
    }
}

/// A point with its 1-sigma position uncertainty (m).
public struct MeasuredPoint: Sendable, Equatable, Codable {
    public var position: Vec3
    public var sigma: Double

    public init(position: Vec3, sigma: Double) {
        self.position = position
        self.sigma = sigma
    }
}

public struct SegmentResult: Sendable, Equatable {
    public var length: Double
    public var sigma: Double
    public var midpoint: Vec3
}

public struct MeasurementResult: Sendable, Equatable {
    public var kind: MeasurementKind
    /// Primary value in SI units: m, m² or m³.
    public var value: Double
    /// 1-sigma uncertainty of `value`, same unit.
    public var sigma: Double
    public var grade: ConfidenceGrade
    public var perimeter: Double?
    /// Base area for volumes, the area itself for areas.
    public var area: Double?
    public var height: Double?
    /// Distance of the worst vertex from the best-fit plane (area/volume bases).
    public var maxPlaneDeviation: Double?
    public var isSelfIntersecting: Bool
    public var segments: [SegmentResult]
    /// Where to draw the main label.
    public var labelAnchor: Vec3

    /// Human-readable caveats that apply to this specific measurement.
    public var caveats: [String] {
        var out: [String] = []
        if isSelfIntersecting { out.append("Edges cross: the area of a self-intersecting outline is not meaningful.") }
        if let dev = maxPlaneDeviation, let p = perimeter, dev > max(0.02, 0.02 * p) {
            out.append("Points are not on one flat surface (up to \(Int((dev * 1000).rounded())) mm off). Area is measured on the best-fit plane.")
        }
        if kind == .distance, value < 0.1 { out.append("Short distance: LiDAR error is large relative to objects under ~10 cm.") }
        return out
    }
}

/// Turns user points into distance, area and volume results with propagated uncertainty.
public enum MeasurementCalculator {
    public static func distance(_ a: MeasuredPoint, _ b: MeasuredPoint) -> MeasurementResult {
        let length = Vec.distance(a.position, b.position)
        let sigma = AccuracyModel.distanceSigma(a.sigma, b.sigma, length: length)
        let mid = (a.position + b.position) / 2
        return MeasurementResult(
            kind: .distance,
            value: length,
            sigma: sigma,
            grade: AccuracyModel.grade(lengthSigma: sigma, length: length),
            perimeter: nil,
            area: nil,
            height: nil,
            maxPlaneDeviation: nil,
            isSelfIntersecting: false,
            segments: [SegmentResult(length: length, sigma: sigma, midpoint: mid)],
            labelAnchor: mid
        )
    }

    /// Open polyline or closed polygon segments (used for edge labels while tracing).
    public static func segments(_ points: [MeasuredPoint], closed: Bool) -> [SegmentResult] {
        guard points.count >= 2 else { return [] }
        var out: [SegmentResult] = []
        let count = closed && points.count >= 3 ? points.count : points.count - 1
        for i in 0..<count {
            let a = points[i], b = points[(i + 1) % points.count]
            let length = Vec.distance(a.position, b.position)
            out.append(SegmentResult(
                length: length,
                sigma: AccuracyModel.distanceSigma(a.sigma, b.sigma, length: length),
                midpoint: (a.position + b.position) / 2
            ))
        }
        return out
    }

    public static func area(_ polygon: [MeasuredPoint]) -> MeasurementResult? {
        let positions = polygon.map(\.position)
        guard let m = PolygonGeometry.metrics(positions) else { return nil }
        let sigma = AccuracyModel.polygonAreaSigma(points: positions, sigmas: polygon.map(\.sigma), area: m.area)
        let relative = m.area > 0 ? sigma / m.area : .infinity
        var grade = AccuracyModel.grade(relativeError: relative)
        if m.isSelfIntersecting { grade = .low }
        return MeasurementResult(
            kind: .area,
            value: m.area,
            sigma: sigma,
            grade: grade,
            perimeter: m.perimeter,
            area: m.area,
            height: nil,
            maxPlaneDeviation: m.maxPlaneDeviation,
            isSelfIntersecting: m.isSelfIntersecting,
            segments: segments(polygon, closed: true),
            labelAnchor: m.centroid
        )
    }

    public static func prismVolume(base: [MeasuredPoint], top: MeasuredPoint) -> MeasurementResult? {
        let positions = base.map(\.position)
        guard let prism = VolumeGeometry.prism(base: positions, top: top.position),
              let baseResult = area(base) else { return nil }
        // Height error: the top point's error plus the base plane's error (averaged over its vertices).
        let meanBaseSigma = base.map(\.sigma).reduce(0, +) / Double(base.count)
        let basePlaneSigma = meanBaseSigma / Double(base.count).squareRoot()
        let heightSigma = (top.sigma * top.sigma + basePlaneSigma * basePlaneSigma).squareRoot()
        let sigma = AccuracyModel.prismVolumeSigma(area: prism.baseArea, areaSigma: baseResult.sigma, height: prism.height, heightSigma: heightSigma)
        let relative = prism.volume > 0 ? sigma / prism.volume : .infinity
        var grade = AccuracyModel.grade(relativeError: relative)
        if baseResult.isSelfIntersecting { grade = .low }
        return MeasurementResult(
            kind: .volume,
            value: prism.volume,
            sigma: sigma,
            grade: grade,
            perimeter: baseResult.perimeter,
            area: prism.baseArea,
            height: prism.height,
            maxPlaneDeviation: baseResult.maxPlaneDeviation,
            isSelfIntersecting: baseResult.isSelfIntersecting,
            segments: baseResult.segments,
            labelAnchor: prism.baseCentroid + prism.baseNormal * prism.height
        )
    }
}
