import Foundation

/// One saved measurement, flattened for CSV export.
public struct MeasurementCSVRow: Sendable, Equatable {
    /// Stable record identifier, so re-exported rows can be de-duplicated in a spreadsheet.
    public var id: UUID?
    public var name: String
    public var kind: MeasurementKind
    /// SI value: m, m² or m³.
    public var value: Double
    /// 1-sigma uncertainty, same unit as `value`.
    public var uncertainty: Double
    public var confidence: ConfidenceGrade
    public var perimeter: Double?
    public var height: Double?
    public var baseArea: Double?
    /// Session-relative world coordinates (metres). Only meaningful relative to each other.
    public var points: [Vec3]
    public var createdAt: Date
    public var notes: String

    public init(id: UUID? = nil, name: String, kind: MeasurementKind, value: Double, uncertainty: Double, confidence: ConfidenceGrade,
                perimeter: Double? = nil, height: Double? = nil, baseArea: Double? = nil, points: [Vec3], createdAt: Date, notes: String = "") {
        self.id = id
        self.name = name
        self.kind = kind
        self.value = value
        self.uncertainty = uncertainty
        self.confidence = confidence
        self.perimeter = perimeter
        self.height = height
        self.baseArea = baseArea
        self.points = points
        self.createdAt = createdAt
        self.notes = notes
    }
}

/// RFC 4180 CSV. Numeric columns are SI with a "." decimal separator regardless of locale, so
/// spreadsheets parse them; a separate column carries the value as displayed in the app.
public enum CSVExporter {
    public static let header = [
        "id", "name", "type", "value", "unit", "uncertainty_1sigma", "display_value", "confidence",
        "perimeter_m", "height_m", "base_area_m2", "points_xyz_m", "created_at", "notes",
    ]

    public static func makeCSV(rows: [MeasurementCSVRow], formatter: MetricFormatter, includeBOM: Bool = true) -> Data {
        var lines: [String] = [header.joined(separator: ",")]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = TimeZone(secondsFromGMT: 0)
        for r in rows {
            let display: String
            switch r.kind {
            case .distance: display = formatter.formatLength(r.value, uncertainty: r.uncertainty)
            case .area: display = formatter.formatArea(r.value, uncertainty: r.uncertainty)
            case .volume: display = formatter.formatVolume(r.value, uncertainty: r.uncertainty)
            }
            let points = r.points.map { "\(number($0.x));\(number($0.y));\(number($0.z))" }.joined(separator: "|")
            let fields: [String] = [
                r.id?.uuidString ?? "",
                r.name,
                r.kind.rawValue,
                number(r.value),
                r.kind.siUnit,
                number(r.uncertainty),
                display,
                r.confidence.rawValue,
                r.perimeter.map(number) ?? "",
                r.height.map(number) ?? "",
                r.baseArea.map(number) ?? "",
                points,
                iso.string(from: r.createdAt),
                r.notes,
            ]
            lines.append(fields.map(escape).joined(separator: ","))
        }
        let text = lines.joined(separator: "\r\n") + "\r\n"
        var data = Data()
        if includeBOM { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) } // lets Excel detect UTF-8 (for ² and ³)
        data.append(Data(text.utf8))
        return data
    }

    public static func escape(_ field: String) -> String {
        let needsQuotes = field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r")
        guard needsQuotes else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Locale-independent, up to 6 decimals (micrometre / mm² resolution), trailing zeros removed.
    static func number(_ v: Double) -> String {
        var t = TextBuffer()
        t.append(v, decimals: 6)
        return String(decoding: t.bytes, as: UTF8.self)
    }
}
