import Foundation

/// The length unit the user picked. `.auto` picks mm, cm or m from the magnitude.
public enum LengthUnitPreference: String, CaseIterable, Codable, Sendable, Identifiable {
    case auto
    case millimetres
    case centimetres
    case metres

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: return "Auto"
        case .millimetres: return "mm"
        case .centimetres: return "cm"
        case .metres: return "m"
        }
    }

    /// Cycle order for the HUD's unit button.
    public var next: LengthUnitPreference {
        let all = Self.allCases
        let i = all.firstIndex(of: self)!
        return all[(i + 1) % all.count]
    }
}

public enum LengthUnit: String, Codable, Sendable {
    case millimetre, centimetre, metre

    public var metres: Double {
        switch self {
        case .millimetre: return 0.001
        case .centimetre: return 0.01
        case .metre: return 1
        }
    }

    public var symbol: String {
        switch self {
        case .millimetre: return "mm"
        case .centimetre: return "cm"
        case .metre: return "m"
        }
    }

    /// Default decimals when no uncertainty is known: 1 mm resolution everywhere.
    var defaultDecimals: Int {
        switch self {
        case .millimetre: return 0
        case .centimetre: return 1
        case .metre: return 3
        }
    }
}

public enum AreaUnit: String, Codable, Sendable {
    case squareMillimetre, squareCentimetre, squareMetre

    public var squareMetres: Double {
        switch self {
        case .squareMillimetre: return 1e-6
        case .squareCentimetre: return 1e-4
        case .squareMetre: return 1
        }
    }

    public var symbol: String {
        switch self {
        case .squareMillimetre: return "mm²"
        case .squareCentimetre: return "cm²"
        case .squareMetre: return "m²"
        }
    }

    var defaultDecimals: Int {
        switch self {
        case .squareMillimetre: return 0
        case .squareCentimetre: return 1
        case .squareMetre: return 2
        }
    }
}

public enum VolumeUnit: String, Codable, Sendable {
    case cubicCentimetre, litre, cubicMetre

    public var cubicMetres: Double {
        switch self {
        case .cubicCentimetre: return 1e-6
        case .litre: return 1e-3
        case .cubicMetre: return 1
        }
    }

    public var symbol: String {
        switch self {
        case .cubicCentimetre: return "cm³"
        case .litre: return "L"
        case .cubicMetre: return "m³"
        }
    }

    var defaultDecimals: Int {
        switch self {
        case .cubicCentimetre: return 0
        case .litre: return 1
        case .cubicMetre: return 3
        }
    }
}

/// Formats SI values (metres, square metres, cubic metres) for display. Metric only, by design.
///
/// "Honest precision": a LiDAR distance with a ±2 cm uncertainty must not be shown as
/// "1.2437 m". When enabled, the number of decimals is cut back to the order of magnitude of
/// the uncertainty, so the last displayed digit is the first uncertain one.
public struct MetricFormatter: Sendable {
    public var preference: LengthUnitPreference
    public var honestPrecision: Bool
    public var locale: Locale

    public init(preference: LengthUnitPreference = .auto, honestPrecision: Bool = true, locale: Locale = .current) {
        self.preference = preference
        self.honestPrecision = honestPrecision
        self.locale = locale
    }

    // MARK: Unit selection

    public func lengthUnit(for metres: Double) -> LengthUnit {
        switch preference {
        case .millimetres: return .millimetre
        case .centimetres: return .centimetre
        case .metres: return .metre
        case .auto:
            let m = abs(metres)
            if m < 0.1 { return .millimetre }
            if m < 1 { return .centimetre }
            return .metre
        }
    }

    public func areaUnit(for squareMetres: Double) -> AreaUnit {
        switch preference {
        case .millimetres: return .squareMillimetre
        case .centimetres: return .squareCentimetre
        case .metres: return .squareMetre
        case .auto:
            let a = abs(squareMetres)
            if a < 1e-4 { return .squareMillimetre }
            if a < 1 { return .squareCentimetre }
            return .squareMetre
        }
    }

    public func volumeUnit(for cubicMetres: Double) -> VolumeUnit {
        switch preference {
        // mm³ is never a useful display unit for LiDAR-scale volumes, so millimetres maps to cm³.
        case .millimetres, .centimetres: return .cubicCentimetre
        case .metres: return .cubicMetre
        case .auto:
            let v = abs(cubicMetres)
            if v < 1e-3 { return .cubicCentimetre }
            if v < 1 { return .litre }
            return .cubicMetre
        }
    }

    // MARK: Formatting

    public func formatLength(_ metres: Double, uncertainty: Double? = nil) -> String {
        let unit = lengthUnit(for: metres)
        let decimals = Self.decimals(default: unit.defaultDecimals, uncertaintyInUnit: uncertainty.map { $0 / unit.metres }, honest: honestPrecision)
        return "\(number(metres / unit.metres, decimals: decimals)) \(unit.symbol)"
    }

    public func formatArea(_ squareMetres: Double, uncertainty: Double? = nil) -> String {
        let unit = areaUnit(for: squareMetres)
        let decimals = Self.decimals(default: unit.defaultDecimals, uncertaintyInUnit: uncertainty.map { $0 / unit.squareMetres }, honest: honestPrecision)
        return "\(number(squareMetres / unit.squareMetres, decimals: decimals)) \(unit.symbol)"
    }

    public func formatVolume(_ cubicMetres: Double, uncertainty: Double? = nil) -> String {
        let unit = volumeUnit(for: cubicMetres)
        let decimals = Self.decimals(default: unit.defaultDecimals, uncertaintyInUnit: uncertainty.map { $0 / unit.cubicMetres }, honest: honestPrecision)
        return "\(number(cubicMetres / unit.cubicMetres, decimals: decimals)) \(unit.symbol)"
    }

    /// Length uncertainty in the most readable unit: "±4 mm", "±2.5 cm", "±0.12 m".
    public func formatLengthUncertainty(_ metres: Double) -> String {
        let m = abs(metres)
        if m < 0.01 { return "±\(number(max(1, (m * 1000).rounded()), decimals: 0)) mm" }
        if m < 1 { return "±\(number(m * 100, decimals: 1)) cm" }
        return "±\(number(m, decimals: 2)) m"
    }

    /// Area/volume uncertainty, expressed in the same unit as the value so they read together.
    public func formatAreaUncertainty(_ squareMetres: Double, forValue value: Double) -> String {
        let unit = areaUnit(for: value)
        let inUnit = squareMetres / unit.squareMetres
        return "±\(number(inUnit, decimals: Self.uncertaintyDecimals(inUnit))) \(unit.symbol)"
    }

    public func formatVolumeUncertainty(_ cubicMetres: Double, forValue value: Double) -> String {
        let unit = volumeUnit(for: value)
        let inUnit = cubicMetres / unit.cubicMetres
        return "±\(number(inUnit, decimals: Self.uncertaintyDecimals(inUnit))) \(unit.symbol)"
    }

    // MARK: Helpers

    /// Decimals so the display resolution matches the order of magnitude of the uncertainty,
    /// never finer than the unit's default resolution.
    static func decimals(default defaultDecimals: Int, uncertaintyInUnit: Double?, honest: Bool) -> Int {
        guard honest, let u = uncertaintyInUnit, u.isFinite, u > 0 else { return defaultDecimals }
        let magnitude = floor(log10(u))
        let d = max(0, Int(-magnitude))
        return min(defaultDecimals, d)
    }

    /// Two significant figures, at most three decimals.
    static func uncertaintyDecimals(_ value: Double) -> Int {
        guard value.isFinite, value > 0 else { return 0 }
        let magnitude = Int(floor(log10(value)))
        return max(0, min(3, 1 - magnitude))
    }

    public func number(_ value: Double, decimals: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = decimals
        formatter.maximumFractionDigits = decimals
        formatter.roundingMode = .halfUp
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.\(decimals)f", value)
    }
}
