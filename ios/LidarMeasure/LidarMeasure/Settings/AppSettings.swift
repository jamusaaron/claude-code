import Foundation
import Combine
import MeasureCore

/// User preferences, persisted in UserDefaults. One instance is shared through the environment.
@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    // Units
    @Published var unitPreference: LengthUnitPreference { didSet { defaults.set(unitPreference.rawValue, forKey: Keys.unit) } }
    @Published var honestPrecision: Bool { didSet { defaults.set(honestPrecision, forKey: Keys.honestPrecision) } }

    // Snapping
    @Published var snapToPlanes: Bool { didSet { defaults.set(snapToPlanes, forKey: Keys.snapPlanes) } }
    @Published var snapToEdges: Bool { didSet { defaults.set(snapToEdges, forKey: Keys.snapEdges) } }
    @Published var snapToPoints: Bool { didSet { defaults.set(snapToPoints, forKey: Keys.snapPoints) } }

    // Display
    @Published var showMeshOverlay: Bool { didSet { defaults.set(showMeshOverlay, forKey: Keys.meshOverlay) } }
    @Published var showConfidenceOverlay: Bool { didSet { defaults.set(showConfidenceOverlay, forKey: Keys.confidenceOverlay) } }
    @Published var occlusionEnabled: Bool { didSet { defaults.set(occlusionEnabled, forKey: Keys.occlusion) } }
    @Published var highContrastHUD: Bool { didSet { defaults.set(highContrastHUD, forKey: Keys.highContrast) } }
    @Published var hapticsEnabled: Bool {
        didSet {
            defaults.set(hapticsEnabled, forKey: Keys.haptics)
            Haptics.isEnabled = hapticsEnabled
        }
    }

    // Scanning
    @Published var textureKeyframes: Int { didSet { defaults.set(textureKeyframes, forKey: Keys.textureKeyframes) } }
    @Published var defaultSimplifyCentimetres: Double { didSet { defaults.set(defaultSimplifyCentimetres, forKey: Keys.simplify) } }
    @Published var scanVertexBudget: Int { didSet { defaults.set(scanVertexBudget, forKey: Keys.vertexBudget) } }

    // Onboarding
    @Published var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.onboarding) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.unit: LengthUnitPreference.auto.rawValue,
            Keys.honestPrecision: true,
            Keys.snapPlanes: true,
            Keys.snapEdges: true,
            Keys.snapPoints: true,
            Keys.meshOverlay: false,
            Keys.confidenceOverlay: false,
            Keys.occlusion: false,
            Keys.highContrast: false,
            Keys.haptics: true,
            Keys.textureKeyframes: 16,
            Keys.simplify: 1.0,
            Keys.vertexBudget: 600_000,
            Keys.onboarding: false,
        ])
        unitPreference = LengthUnitPreference(rawValue: defaults.string(forKey: Keys.unit) ?? "") ?? .auto
        honestPrecision = defaults.bool(forKey: Keys.honestPrecision)
        snapToPlanes = defaults.bool(forKey: Keys.snapPlanes)
        snapToEdges = defaults.bool(forKey: Keys.snapEdges)
        snapToPoints = defaults.bool(forKey: Keys.snapPoints)
        showMeshOverlay = defaults.bool(forKey: Keys.meshOverlay)
        showConfidenceOverlay = defaults.bool(forKey: Keys.confidenceOverlay)
        occlusionEnabled = defaults.bool(forKey: Keys.occlusion)
        highContrastHUD = defaults.bool(forKey: Keys.highContrast)
        hapticsEnabled = defaults.bool(forKey: Keys.haptics)
        textureKeyframes = defaults.integer(forKey: Keys.textureKeyframes)
        defaultSimplifyCentimetres = defaults.double(forKey: Keys.simplify)
        scanVertexBudget = defaults.integer(forKey: Keys.vertexBudget)
        hasCompletedOnboarding = defaults.bool(forKey: Keys.onboarding)
        Haptics.isEnabled = hapticsEnabled
    }

    var formatter: MetricFormatter {
        MetricFormatter(preference: unitPreference, honestPrecision: honestPrecision)
    }

    func cycleUnit() {
        unitPreference = unitPreference.next
    }

    func resetToDefaults() {
        unitPreference = .auto
        honestPrecision = true
        snapToPlanes = true
        snapToEdges = true
        snapToPoints = true
        showMeshOverlay = false
        showConfidenceOverlay = false
        occlusionEnabled = false
        highContrastHUD = false
        hapticsEnabled = true
        textureKeyframes = 16
        defaultSimplifyCentimetres = 1
        scanVertexBudget = 600_000
    }

    static let textureKeyframeOptions = [9, 16, 25]
    static let simplifyOptions: [Double] = [0, 1, 2, 3]
    static let vertexBudgetOptions = [300_000, 600_000, 1_000_000]

    private enum Keys {
        static let unit = "units.preference"
        static let honestPrecision = "units.honestPrecision"
        static let snapPlanes = "snap.planes"
        static let snapEdges = "snap.edges"
        static let snapPoints = "snap.points"
        static let meshOverlay = "display.meshOverlay"
        static let confidenceOverlay = "display.confidenceOverlay"
        static let occlusion = "display.occlusion"
        static let highContrast = "display.highContrast"
        static let haptics = "feedback.haptics"
        static let textureKeyframes = "scan.textureKeyframes"
        static let simplify = "scan.simplifyCentimetres"
        static let vertexBudget = "scan.vertexBudget"
        static let onboarding = "onboarding.completed"
    }
}
