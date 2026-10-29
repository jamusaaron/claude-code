import SwiftUI
import UIKit
import MeasureCore

/// Post-scan cleanup and appearance options. The raw scan is kept, so every option can be
/// changed and re-processed without rescanning.
struct CaptureReviewPanel: View {
    @ObservedObject var controller: CaptureController
    @EnvironmentObject private var settings: AppSettings
    @State private var showAppearance = false
    @State private var confirmDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Scan captured", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(Theme.good)
                Spacer()
                Text("\(controller.rawTriangleCount.formatted()) tris · \(controller.keyframeCount) frames")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if controller.keyframeCount == 0 {
                Label("No camera views were captured, so the model can't be textured. For colour, scan more slowly in good light.", systemImage: "camera.metering.unknown")
                    .font(.caption)
                    .foregroundStyle(Theme.fair)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    cleanupSection
                    Divider().overlay(Color.white.opacity(0.2))
                    appearanceSection
                }
            }
            .frame(maxHeight: 340)

            HStack(spacing: 12) {
                Button("Discard", role: .destructive) { confirmDiscard = true }
                    .buttonStyle(.bordered)
                Spacer()
                Button {
                    controller.process()
                } label: {
                    Label("Process", systemImage: "gearshape.2.fill")
                        .font(.headline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .foregroundStyle(.black)
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .hudPlate(highContrast: settings.highContrastHUD)
        .confirmationDialog("Discard this scan?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { controller.discard() }
        }
    }

    private var cleanupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cleanup").font(.subheadline.weight(.bold))
            if controller.hasRegion {
                Toggle("Crop to capture box", isOn: $controller.options.cropToRegion)
                Toggle("Remove support surface", isOn: $controller.options.removeSupportSurface)
                    .disabled(!controller.options.cropToRegion)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Simplify")
                    Spacer()
                    Text(controller.options.simplifyCentimetres == 0 ? "Off (full detail)" : "\(Int(controller.options.simplifyCentimetres)) cm cells")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $controller.options.simplifyCentimetres, in: 0...5, step: 1)
                Text("LiDAR mesh detail is roughly 2–5 cm, so 1–2 cm cells shrink the file with little visible loss.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Toggle("Remove floating noise", isOn: $controller.options.removeNoise)
            if controller.options.removeNoise {
                HStack {
                    Text("Keep pieces larger than").font(.caption)
                    Spacer()
                    Picker("Noise threshold", selection: $controller.options.noiseThreshold) {
                        Text("0.5%").tag(0.005)
                        Text("2%").tag(0.02)
                        Text("10%").tag(0.1)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }
            }
        }
        .font(.subheadline)
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Appearance").font(.subheadline.weight(.bold))
            Picker("Material", selection: $controller.options.materialPreset) {
                ForEach(MaterialSpec.Preset.allCases.filter { $0 != .capturedTexture || controller.keyframeCount > 0 }) {
                    Text($0.title).tag($0)
                }
            }
            .pickerStyle(.menu)
            .tint(Theme.accent)

            if controller.options.materialPreset == .capturedTexture {
                HStack {
                    Text("Texture detail")
                    Spacer()
                    Picker("Texture detail", selection: $controller.options.textureKeyframes) {
                        Text("Low").tag(9)
                        Text("Medium").tag(16)
                        Text("High").tag(25)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
                Toggle("Even out exposure between frames", isOn: $controller.options.adjustments.normaliseExposure)
                adjustment("Exposure", value: $controller.options.adjustments.exposure, range: -1.5...1.5, display: { String(format: "%+.1f EV", $0) })
                adjustment("Contrast", value: $controller.options.adjustments.contrast, range: 0.6...1.6, display: { String(format: "%.2f", $0) })
                adjustment("Saturation", value: $controller.options.adjustments.saturation, range: 0...2, display: { String(format: "%.2f", $0) })
                adjustment("White balance", value: $controller.options.adjustments.temperature, range: 3000...10000, display: { "\(Int($0)) K" })
                Button("Reset colour") { controller.options.adjustments = .neutral }
                    .font(.caption)
            } else if controller.options.materialPreset != .clay {
                ColorPicker("Colour", selection: colourBinding, supportsOpacity: false)
            }
        }
        .font(.subheadline)
    }

    private func adjustment(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, display: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(display(value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.caption)
            Slider(value: value, in: range)
        }
    }

    private var colourBinding: Binding<Color> {
        Binding(
            get: {
                let c = controller.options.customColour
                return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
            },
            set: { color in
                let ui = UIColor(color)
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                ui.getRed(&r, green: &g, blue: &b, alpha: &a)
                controller.options.customColour = SIMD3(Float(min(1, max(0, r))), Float(min(1, max(0, g))), Float(min(1, max(0, b))))
            }
        )
    }
}
