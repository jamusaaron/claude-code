import Foundation
import SwiftData
import MeasureCore

/// A saved distance, area or volume. Values are stored in SI units (m, m², m³) and formatted at
/// display time, so changing the unit preference re-renders the whole library.
@Model
final class SavedMeasurement {
    @Attribute(.unique) var id: UUID
    var name: String
    var notes: String
    var createdAt: Date
    var kindRaw: String
    var value: Double
    /// 1-sigma uncertainty, same unit as `value`.
    var uncertainty: Double
    var confidenceRaw: String
    var perimeter: Double?
    var height: Double?
    var baseArea: Double?
    /// JSON `[[x, y, z]]`, session-relative world coordinates in metres.
    var pointsData: Data
    var snapSummary: String
    var caveats: String

    init(id: UUID = UUID(), name: String, notes: String, createdAt: Date, kind: MeasurementKind, value: Double, uncertainty: Double,
         confidence: ConfidenceGrade, perimeter: Double?, height: Double?, baseArea: Double?, points: [Vec3], snapSummary: String, caveats: String) {
        self.id = id
        self.name = name
        self.notes = notes
        self.createdAt = createdAt
        self.kindRaw = kind.rawValue
        self.value = value
        self.uncertainty = uncertainty
        self.confidenceRaw = confidence.rawValue
        self.perimeter = perimeter
        self.height = height
        self.baseArea = baseArea
        self.pointsData = (try? JSONEncoder().encode(points.map { [$0.x, $0.y, $0.z] })) ?? Data()
        self.snapSummary = snapSummary
        self.caveats = caveats
    }

    convenience init(measurement m: Measurement, result r: MeasurementResult, name: String, notes: String) {
        self.init(
            name: name,
            notes: notes,
            createdAt: m.createdAt,
            kind: m.kind,
            value: r.value,
            uncertainty: r.sigma,
            confidence: r.grade,
            perimeter: r.perimeter,
            height: r.height,
            baseArea: m.kind == .volume ? r.area : nil,
            points: m.allPoints.map { $0.position.asDouble },
            snapSummary: m.snapSummary,
            caveats: r.caveats.joined(separator: " ")
        )
    }

    var kind: MeasurementKind { MeasurementKind(rawValue: kindRaw) ?? .distance }
    var confidence: ConfidenceGrade { ConfidenceGrade(rawValue: confidenceRaw) ?? .low }

    var points: [Vec3] {
        guard let raw = try? JSONDecoder().decode([[Double]].self, from: pointsData) else { return [] }
        return raw.compactMap { $0.count == 3 ? Vec3($0[0], $0[1], $0[2]) : nil }
    }

    func formattedValue(_ f: MetricFormatter) -> String {
        switch kind {
        case .distance: return f.formatLength(value, uncertainty: uncertainty)
        case .area: return f.formatArea(value, uncertainty: uncertainty)
        case .volume: return f.formatVolume(value, uncertainty: uncertainty)
        }
    }

    func formattedUncertainty(_ f: MetricFormatter) -> String {
        switch kind {
        case .distance: return f.formatLengthUncertainty(uncertainty)
        case .area: return f.formatAreaUncertainty(uncertainty, forValue: value)
        case .volume: return f.formatVolumeUncertainty(uncertainty, forValue: value)
        }
    }

    var csvRow: MeasurementCSVRow {
        MeasurementCSVRow(name: name, kind: kind, value: value, uncertainty: uncertainty, confidence: confidence,
                          perimeter: perimeter, height: height, baseArea: baseArea, points: points, createdAt: createdAt, notes: notes)
    }
}

/// A captured 3D model. Geometry and exports live in a folder under Application Support
/// (see `ModelStore`); this record holds the metadata the library lists.
@Model
final class SavedModel {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var folderName: String
    var vertexCount: Int
    var triangleCount: Int
    var sizeX: Double
    var sizeY: Double
    var sizeZ: Double
    var volume: Double?
    var volumeReliable: Bool
    var texturedShare: Double
    var scopeRaw: String
    var notes: String

    init(id: UUID, name: String, createdAt: Date, folderName: String, stats: ModelStats, scope: CaptureScope) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.folderName = folderName
        self.vertexCount = stats.vertexCount
        self.triangleCount = stats.triangleCount
        self.sizeX = stats.size.x
        self.sizeY = stats.size.y
        self.sizeZ = stats.size.z
        self.volume = stats.volume
        self.volumeReliable = stats.volumeReliable
        self.texturedShare = stats.texturedShare
        self.scopeRaw = scope.rawValue
        self.notes = ""
    }

    var folderURL: URL { ModelStore.folder(named: folderName) }
    var scope: CaptureScope { CaptureScope(rawValue: scopeRaw) ?? .scene }
    var size: Vec3 { Vec3(sizeX, sizeY, sizeZ) }
}

/// Region the user chose to capture.
enum CaptureScope: String, Codable, CaseIterable, Identifiable {
    case scene
    case object

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scene: return "Whole scene"
        case .object: return "Object / region"
        }
    }
}

/// Summary of a processed model, also written to `meta.json`.
struct ModelStats: Codable, Equatable {
    var vertexCount: Int
    var triangleCount: Int
    /// Bounding box size (m): width (X), height (Y), depth (Z).
    var size: Vec3
    var volume: Double?
    var volumeReliable: Bool
    var volumeOpenness: Double?
    var texturedShare: Double
    var materialPreset: MaterialSpec.Preset
}
