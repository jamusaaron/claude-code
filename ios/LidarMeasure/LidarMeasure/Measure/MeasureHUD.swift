import SwiftUI
import MeasureCore

/// Centre crosshair. The 3D disc drawn on the surface shows where the point lands; this 2D
/// mark shows where the phone is aiming, coloured by the current point's confidence.
struct ReticleView: View {
    var resolved: ResolvedPoint?
    var highContrast: Bool

    var body: some View {
        let color = resolved.map { Theme.color(for: $0.grade) } ?? Color.white.opacity(0.6)
        ZStack {
            Circle()
                .strokeBorder(color, style: StrokeStyle(lineWidth: highContrast ? 3 : 2, dash: resolved == nil ? [4, 4] : []))
                .frame(width: 34, height: 34)
                .shadow(color: .black.opacity(0.8), radius: 2)
            Circle().fill(color).frame(width: 5, height: 5)
            if let r = resolved, [.edge, .corner, .point, .plane].contains(r.snap) {
                Label(r.snap.title, systemImage: Theme.symbol(for: r.snap))
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(color, in: Capsule())
                    .foregroundStyle(.black)
                    .offset(y: 34)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Large live value with honest uncertainty.
struct ReadoutCard: View {
    var readout: Readout?
    var hint: String
    var reticle: ResolvedPoint?
    var formatter: MetricFormatter
    var highContrast: Bool
    var onUnitTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let r = readout {
                HStack(alignment: .firstTextBaseline) {
                    Text(r.primary)
                        .font(.system(size: highContrast ? 42 : 38, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .contentTransition(.numericText())
                    Spacer(minLength: 8)
                    Button(action: onUnitTap) {
                        Image(systemName: "arrow.left.arrow.right.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Theme.accent)
                    }
                    .accessibilityLabel("Change units")
                }
                HStack(spacing: 6) {
                    Pill(text: r.uncertainty, systemImage: "plusminus", color: Theme.color(for: r.grade))
                    Pill(text: "\(r.grade.title) confidence", systemImage: nil, color: Theme.color(for: r.grade).opacity(0.85))
                    if r.isLive { Pill(text: "Live", systemImage: "dot.radiowaves.left.and.right", color: .white.opacity(0.85)) }
                }
                ForEach(r.secondary, id: \.self) { line in
                    Text(line).font(.subheadline.monospacedDigit()).foregroundStyle(.white.opacity(0.85))
                }
                ForEach(r.caveats, id: \.self) { caveat in
                    Label(caveat, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.fair)
                }
            } else {
                Text(hint)
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            if let p = reticle {
                Text(reticleLine(p))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
            if readout != nil {
                Text("Estimate · verify critical dimensions with a tape or laser measure")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hudPlate(highContrast: highContrast)
        .accessibilityElement(children: .combine)
    }

    private func reticleLine(_ p: ResolvedPoint) -> String {
        "Range \(formatter.formatLength(Double(p.range))) · \(p.snap.title) · LiDAR \(p.confidence.title) · point \(formatter.formatLengthUncertainty(p.sigma))"
    }
}

/// Warning banners, most important first.
struct WarningStack: View {
    var warnings: [EnvironmentWarning]
    var highContrast: Bool
    @State private var expanded: EnvironmentWarning?

    var body: some View {
        VStack(spacing: 6) {
            ForEach(warnings.prefix(2)) { w in
                Button {
                    withAnimation(.snappy) { expanded = expanded == w ? nil : w }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(w.title, systemImage: w.systemImage)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.fair)
                        if expanded == w || highContrast {
                            Text(w.detail)
                                .font(.caption)
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hudPlate(highContrast: highContrast, cornerRadius: 10)
                }
                .buttonStyle(.plain)
                .accessibilityHint(w.detail)
            }
        }
        .animation(.snappy, value: warnings)
    }
}

/// Round icon button used on the camera HUD.
struct HUDIconButton: View {
    var systemImage: String
    var label: String
    var isOn = false
    var highContrast = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .foregroundStyle(isOn ? Color.black : Color.white)
                .background(isOn ? Theme.accent : (highContrast ? Theme.plateHighContrast : Theme.plate), in: Circle())
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
