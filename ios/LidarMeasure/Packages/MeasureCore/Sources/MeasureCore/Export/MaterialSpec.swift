import Foundation

/// Surface material written by every exporter.
public struct MaterialSpec: Sendable, Equatable, Codable {
    public var name: String
    /// Linear-ish RGB in 0...1. Multiplied with the texture when one is present.
    public var baseColor: Vec3f
    public var roughness: Float
    public var metallic: Float
    /// Whether to use the captured texture atlas.
    public var usesTexture: Bool

    public init(name: String = "ScanMaterial", baseColor: Vec3f = Vec3f(1, 1, 1), roughness: Float = 1, metallic: Float = 0, usesTexture: Bool = true) {
        self.name = name
        self.baseColor = baseColor
        self.roughness = roughness
        self.metallic = metallic
        self.usesTexture = usesTexture
    }

    /// Preset materials offered after a scan.
    public enum Preset: String, CaseIterable, Codable, Sendable, Identifiable {
        case capturedTexture
        case clay
        case satin
        case customColour

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .capturedTexture: return "Captured texture"
            case .clay: return "Matte clay"
            case .satin: return "Satin"
            case .customColour: return "Custom colour"
            }
        }
    }

    public static func preset(_ preset: Preset, customColour: Vec3f = Vec3f(0.8, 0.8, 0.8)) -> MaterialSpec {
        switch preset {
        case .capturedTexture: return MaterialSpec(usesTexture: true)
        case .clay: return MaterialSpec(baseColor: Vec3f(0.72, 0.70, 0.66), roughness: 1, metallic: 0, usesTexture: false)
        case .satin: return MaterialSpec(baseColor: customColour, roughness: 0.45, metallic: 0, usesTexture: false)
        case .customColour: return MaterialSpec(baseColor: customColour, roughness: 0.8, metallic: 0, usesTexture: false)
        }
    }
}

/// Identifiers are restricted to [A-Za-z0-9_] and may not start with a digit (USD prim names).
func sanitizedIdentifier(_ s: String, fallback: String) -> String {
    var out = String(s.unicodeScalars.map { scalar -> Character in
        let isAlnum = (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122)
        return isAlnum ? Character(scalar) : "_"
    })
    if out.isEmpty { out = fallback }
    if let first = out.unicodeScalars.first, first.value >= 48 && first.value <= 57 { out = "_" + out }
    return out
}
