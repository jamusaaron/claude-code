import SwiftUI
import UIKit
import MeasureCore

/// High-contrast palette tuned for the camera feed and outdoor use: bright accents on near-opaque
/// dark plates, never thin text directly over video.
enum Theme {
    static let accent = Color(red: 1.0, green: 0.84, blue: 0.04)        // signal yellow
    static let good = Color(red: 0.19, green: 0.82, blue: 0.35)
    static let fair = Color(red: 1.0, green: 0.78, blue: 0.0)
    static let poor = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let plate = Color.black.opacity(0.72)
    static let plateHighContrast = Color.black.opacity(0.9)

    static let uiAccent = UIColor(red: 1.0, green: 0.84, blue: 0.04, alpha: 1)
    static let uiGood = UIColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1)
    static let uiFair = UIColor(red: 1.0, green: 0.78, blue: 0.0, alpha: 1)
    static let uiPoor = UIColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 1)

    static func color(for grade: ConfidenceGrade) -> Color {
        switch grade {
        case .high: return good
        case .medium: return fair
        case .low: return poor
        }
    }

    static func uiColor(for grade: ConfidenceGrade) -> UIColor {
        switch grade {
        case .high: return uiGood
        case .medium: return uiFair
        case .low: return uiPoor
        }
    }

    static func symbol(for snap: SnapKind) -> String {
        switch snap {
        case .mesh: return "circle.dotted"
        case .plane: return "square.on.square.dashed"
        case .edge: return "line.diagonal"
        case .corner: return "cube"
        case .point: return "smallcircle.filled.circle"
        case .depth: return "dot.radiowaves.left.and.right"
        case .estimatedPlane: return "questionmark.square.dashed"
        }
    }

    static func symbol(for kind: MeasurementKind) -> String {
        switch kind {
        case .distance: return "ruler"
        case .area: return "square.dashed"
        case .volume: return "cube.transparent"
        }
    }
}

/// Dark rounded plate used behind every HUD element.
struct HUDPlate: ViewModifier {
    var highContrast: Bool
    var cornerRadius: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .background(highContrast ? Theme.plateHighContrast : Theme.plate, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(highContrast ? 0.35 : 0.12), lineWidth: 1)
            )
    }
}

extension View {
    func hudPlate(highContrast: Bool, cornerRadius: CGFloat = 14) -> some View {
        modifier(HUDPlate(highContrast: highContrast, cornerRadius: cornerRadius))
    }
}

/// Small coloured pill: "High", "±4 mm", tracking state, etc.
struct Pill: View {
    var text: String
    var systemImage: String?
    var color: Color

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(.black)
        .background(color, in: Capsule())
    }
}
