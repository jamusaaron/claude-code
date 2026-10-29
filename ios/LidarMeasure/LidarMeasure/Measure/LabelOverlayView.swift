import UIKit
import simd

/// Screen-space labels pinned to world positions. Drawn in UIKit rather than as 3D text so they
/// stay crisp and readable at any distance, and repositioned every frame without SwiftUI work.
final class LabelOverlayView: UIView {
    struct Spec: Equatable {
        var id: String
        var text: String
        var world: SIMD3<Float>
        var color: UIColor
        var prominent: Bool
    }

    private final class PaddedLabel: UILabel {
        var insets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

        override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }

        override var intrinsicContentSize: CGSize {
            let s = super.intrinsicContentSize
            return CGSize(width: s.width + insets.left + insets.right, height: s.height + insets.top + insets.bottom)
        }

        override func sizeThatFits(_ size: CGSize) -> CGSize {
            let s = super.sizeThatFits(size)
            return CGSize(width: s.width + insets.left + insets.right, height: s.height + insets.top + insets.bottom)
        }
    }

    private var labels: [String: PaddedLabel] = [:]
    private var specs: [Spec] = []
    private var highContrast = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setSpecs(_ newSpecs: [Spec], highContrast: Bool) {
        let styleChanged = highContrast != self.highContrast
        self.highContrast = highContrast
        let ids = Set(newSpecs.map(\.id))
        for (id, label) in labels where !ids.contains(id) {
            label.removeFromSuperview()
            labels[id] = nil
        }
        for spec in newSpecs {
            let label: PaddedLabel
            if let existing = labels[spec.id] {
                label = existing
            } else {
                label = PaddedLabel()
                label.textAlignment = .center
                label.layer.masksToBounds = true
                label.layer.cornerRadius = 8
                addSubview(label)
                labels[spec.id] = label
            }
            let old = specs.first { $0.id == spec.id }
            if old == nil || old?.text != spec.text || old?.color != spec.color || old?.prominent != spec.prominent || styleChanged {
                style(label, spec)
            }
        }
        specs = newSpecs
    }

    private func style(_ label: PaddedLabel, _ spec: Spec) {
        let size: CGFloat = spec.prominent ? (highContrast ? 22 : 19) : (highContrast ? 15 : 13)
        // Tabular digits so live values don't jitter in width; rounded for legibility.
        let base = UIFont.monospacedDigitSystemFont(ofSize: size, weight: spec.prominent ? .bold : .semibold)
        let descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        label.font = UIFont(descriptor: descriptor, size: size)
        label.textColor = .white
        label.text = spec.text
        label.backgroundColor = UIColor.black.withAlphaComponent(highContrast ? 0.92 : 0.75)
        label.layer.borderColor = spec.color.cgColor
        label.layer.borderWidth = spec.prominent ? 2 : 1
        label.sizeToFit()
    }

    /// Repositions labels; `project` returns nil for points behind the camera.
    func layout(project: (SIMD3<Float>) -> CGPoint?) {
        for spec in specs {
            guard let label = labels[spec.id] else { continue }
            if let p = project(spec.world) {
                label.isHidden = false
                label.center = CGPoint(x: p.x, y: p.y - (spec.prominent ? 26 : 16))
            } else {
                label.isHidden = true
            }
        }
    }
}
