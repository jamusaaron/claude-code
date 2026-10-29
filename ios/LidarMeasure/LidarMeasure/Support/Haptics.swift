import UIKit

/// Haptic vocabulary used across the app. Generators are kept alive and prepared so the first
/// tap after a pause still fires instantly.
@MainActor
enum Haptics {
    static var isEnabled = true

    private static let impact = UIImpactFeedbackGenerator(style: .medium)
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let selection = UISelectionFeedbackGenerator()
    private static let notification = UINotificationFeedbackGenerator()

    static func prepare() {
        guard isEnabled else { return }
        impact.prepare()
        selection.prepare()
        notification.prepare()
    }

    /// A measurement point was placed.
    static func pointPlaced() {
        guard isEnabled else { return }
        impact.impactOccurred()
        impact.prepare()
    }

    /// The reticle snapped to an edge, corner, plane or existing point.
    static func snapped() {
        guard isEnabled else { return }
        selection.selectionChanged()
        selection.prepare()
    }

    static func tick() {
        guard isEnabled else { return }
        light.impactOccurred(intensity: 0.6)
    }

    /// A measurement was completed or a capture finished.
    static func success() {
        guard isEnabled else { return }
        notification.notificationOccurred(.success)
        notification.prepare()
    }

    static func warning() {
        guard isEnabled else { return }
        notification.notificationOccurred(.warning)
    }

    static func error() {
        guard isEnabled else { return }
        notification.notificationOccurred(.error)
    }
}
