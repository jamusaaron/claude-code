import Foundation
import simd
import MeasureCore

/// A placed point, tied to an ARAnchor so ARKit can refine its position as tracking improves.
struct MeasurementPoint: Identifiable, Equatable {
    let id: UUID
    /// Identifier of the backing `ARAnchor`, nil for preview points.
    var anchorID: UUID?
    var position: SIMD3<Float>
    var sigma: Double
    var confidence: DepthConfidence
    var snap: SnapKind
    var range: Float

    init(id: UUID = UUID(), anchorID: UUID?, resolved: ResolvedPoint) {
        self.id = id
        self.anchorID = anchorID
        self.position = resolved.position
        self.sigma = resolved.sigma
        self.confidence = resolved.confidence
        self.snap = resolved.snap
        self.range = resolved.range
    }

    var measured: MeasuredPoint { MeasuredPoint(position: position.asDouble, sigma: sigma) }
}

/// A distance, area or volume measurement in progress or completed.
struct Measurement: Identifiable, Equatable {
    let id: UUID
    var kind: MeasurementKind
    var points: [MeasurementPoint] = []
    /// Area outline / volume base closed.
    var isClosed = false
    /// Volume: the point that sets the prism height.
    var top: MeasurementPoint?
    var createdAt = Date()
    /// Set once saved to the library.
    var savedRecordID: UUID?
    var savedName: String?

    init(id: UUID = UUID(), kind: MeasurementKind) {
        self.id = id
        self.kind = kind
    }

    var isComplete: Bool {
        switch kind {
        case .distance: return points.count >= 2
        case .area: return isClosed
        case .volume: return isClosed && top != nil
        }
    }

    var isEmpty: Bool { points.isEmpty }

    var allPoints: [MeasurementPoint] { top.map { points + [$0] } ?? points }

    /// What to place next, for the instruction line.
    var nextStepHint: String {
        switch kind {
        case .distance:
            return points.isEmpty ? "Aim at the start point and tap +" : "Aim at the end point and tap +"
        case .area:
            if points.count < 3 { return "Add corner \(points.count + 1) of the outline" }
            return "Add more corners, or tap the first point to close"
        case .volume:
            if !isClosed {
                if points.count < 3 { return "Trace the base: corner \(points.count + 1)" }
                return "Add base corners, or tap the first point to close"
            }
            return "Aim at the top (or ceiling) and tap + to set the height"
        }
    }

    /// The result, optionally including a live preview point at the reticle.
    func result(preview: MeasurementPoint? = nil) -> MeasurementResult? {
        switch kind {
        case .distance:
            if points.count >= 2 { return MeasurementCalculator.distance(points[0].measured, points[1].measured) }
            if points.count == 1, let preview { return MeasurementCalculator.distance(points[0].measured, preview.measured) }
            return nil
        case .area:
            let outline = isClosed ? points : points + (preview.map { [$0] } ?? [])
            guard outline.count >= 3 else { return nil }
            return MeasurementCalculator.area(outline.map(\.measured))
        case .volume:
            guard isClosed else {
                let outline = points + (preview.map { [$0] } ?? [])
                guard outline.count >= 3 else { return nil }
                return MeasurementCalculator.area(outline.map(\.measured))
            }
            guard let topPoint = top ?? preview else { return MeasurementCalculator.area(points.map(\.measured)) }
            return MeasurementCalculator.prismVolume(base: points.map(\.measured), top: topPoint.measured)
        }
    }

    /// Length of the segment from the last placed point to the preview point.
    func previewSegment(to preview: MeasurementPoint?) -> SegmentResult? {
        guard let preview, let last = points.last, !(kind == .volume && isClosed), !isComplete else { return nil }
        return MeasurementCalculator.segments([last.measured, preview.measured], closed: false).first
    }

    /// Volume prism: base outline lifted to the top point's height along the base normal.
    func prismTop(preview: MeasurementPoint?) -> [SIMD3<Float>]? {
        guard kind == .volume, isClosed, let topPoint = top ?? preview,
              let prism = VolumeGeometry.prism(base: points.map { $0.position.asDouble }, top: topPoint.position.asDouble)
        else { return nil }
        let lift = prism.baseNormal * prism.height
        return points.map { ($0.position.asDouble + lift).asFloat }
    }

    /// Worst (largest) point uncertainty.
    var worstSigma: Double { allPoints.map(\.sigma).max() ?? 0 }

    var snapSummary: String {
        let kinds = Set(allPoints.map(\.snap))
        return SnapKind.allCases.filter { kinds.contains($0) }.map(\.title).joined(separator: ", ")
    }
}

/// Text for the live readout card.
struct Readout: Equatable {
    var primary: String
    var uncertainty: String
    var grade: ConfidenceGrade
    var secondary: [String]
    var caveats: [String]
    var isLive: Bool
}

extension Readout {
    static func make(for result: MeasurementResult, formatter f: MetricFormatter, isLive: Bool) -> Readout {
        var secondary: [String] = []
        let primary: String
        let uncertainty: String
        switch result.kind {
        case .distance:
            primary = f.formatLength(result.value, uncertainty: result.sigma)
            uncertainty = f.formatLengthUncertainty(result.sigma)
        case .area:
            primary = f.formatArea(result.value, uncertainty: result.sigma)
            uncertainty = f.formatAreaUncertainty(result.sigma, forValue: result.value)
            if let p = result.perimeter { secondary.append("Perimeter \(f.formatLength(p))") }
        case .volume:
            primary = f.formatVolume(result.value, uncertainty: result.sigma)
            uncertainty = f.formatVolumeUncertainty(result.sigma, forValue: result.value)
            if let a = result.area { secondary.append("Base \(f.formatArea(a))") }
            if let h = result.height { secondary.append("Height \(f.formatLength(h))") }
            if result.value >= 0.001 && result.value < 10 && f.volumeUnit(for: result.value) != .litre {
                secondary.append("≈ \(f.number(result.value * 1000, decimals: result.value < 0.1 ? 1 : 0)) L")
            }
        }
        return Readout(primary: primary, uncertainty: uncertainty, grade: result.grade, secondary: secondary, caveats: result.caveats, isLive: isLive)
    }
}
