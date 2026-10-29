import SwiftUI
import SwiftData
import MeasureCore

/// Measuring tools drawn over the shared camera (see `RootView`): reticle, live readout and
/// floating controls.
struct ARMeasureView: View {
    @ObservedObject var controller: MeasureController

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.modelContext) private var modelContext
    @State private var saveTarget: Measurement?
    @State private var confirmClear = false

    var body: some View {
        ZStack {
            if settings.showConfidenceOverlay, let image = controller.confidenceImage {
                ConfidenceOverlay(image: image)
            }

            // Full-screen layer so the crosshair sits exactly at the ARView's centre.
            ReticleView(resolved: controller.reticle, highContrast: settings.highContrastHUD)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(edges: .top)

            VStack(spacing: 10) {
                topBar
                WarningStack(warnings: controller.warnings, highContrast: settings.highContrastHUD)
                Spacer()
                if let toast = controller.toast {
                    Text(toast)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .hudPlate(highContrast: settings.highContrastHUD, cornerRadius: 20)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                ReadoutCard(
                    readout: controller.readout,
                    hint: controller.hint,
                    reticle: controller.reticle,
                    formatter: settings.formatter,
                    highContrast: settings.highContrastHUD,
                    onUnitTap: { settings.cycleUnit(); Haptics.tick() }
                )
                toolbar
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .animation(.snappy, value: controller.toast)
        }
        .onAppear { controller.attach(settings: settings) }
        .onChange(of: settings.showMeshOverlay) { _, _ in controller.applyDisplaySettings() }
        .onChange(of: settings.occlusionEnabled) { _, _ in controller.applyDisplaySettings() }
        .onChange(of: settings.showConfidenceOverlay) { _, _ in controller.applyDisplaySettings() }
        .onChange(of: settings.unitPreference) { _, _ in controller.applyDisplaySettings() }
        .onChange(of: settings.honestPrecision) { _, _ in controller.applyDisplaySettings() }
        .onChange(of: settings.highContrastHUD) { _, _ in controller.applyDisplaySettings() }
        .sheet(item: $saveTarget) { m in
            SaveMeasurementSheet(measurement: m, defaultName: controller.defaultName(for: m), formatter: settings.formatter) { name, notes in
                _ = controller.save(m, name: name, notes: notes, in: modelContext)
            }
            .presentationDetents([.medium, .large])
        }
        .alert(item: $controller.sessionError) { error in
            if error.opensSettings {
                return Alert(title: Text(error.title), message: Text(error.message),
                             primaryButton: .default(Text("Open Settings")) { SystemSettings.open() },
                             secondaryButton: .cancel())
            }
            return Alert(title: Text(error.title), message: Text(error.message),
                         primaryButton: .default(Text("Restart")) { controller.restartSession() },
                         secondaryButton: .cancel())
        }
        .confirmationDialog("Clear all measurements on screen?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { controller.clearAll() }
        } message: {
            Text("Saved measurements stay in the library.")
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            Pill(text: controller.tracking.title, systemImage: trackingIcon, color: trackingColor)
                .accessibilityLabel("Tracking: \(controller.tracking.title)")
            Spacer()
            HUDIconButton(systemImage: "square.grid.3x3.square", label: "Show LiDAR mesh", isOn: settings.showMeshOverlay, highContrast: settings.highContrastHUD) {
                settings.showMeshOverlay.toggle()
            }
            HUDIconButton(systemImage: "circle.lefthalf.filled", label: "Show depth confidence", isOn: settings.showConfidenceOverlay, highContrast: settings.highContrastHUD) {
                settings.showConfidenceOverlay.toggle()
            }
            Menu {
                Picker("Units", selection: $settings.unitPreference) {
                    ForEach(LengthUnitPreference.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Snap to edges & corners", isOn: $settings.snapToEdges)
                Toggle("Snap to planes", isOn: $settings.snapToPlanes)
                Toggle("Occlusion", isOn: $settings.occlusionEnabled)
                Divider()
                Button("Restart session", systemImage: "arrow.counterclockwise") { controller.restartSession() }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(.white)
                    .background(settings.highContrastHUD ? Theme.plateHighContrast : Theme.plate, in: Circle())
            }
            .accessibilityLabel("More options")
        }
    }

    private var trackingColor: Color {
        switch controller.tracking.quality {
        case .normal: return Theme.good
        case .limited: return Theme.fair
        case .notAvailable: return Theme.poor
        }
    }

    private var trackingIcon: String {
        controller.tracking.quality == .normal ? "location.fill" : "exclamationmark.triangle.fill"
    }

    // MARK: Toolbar

    private var toolbar: some View {
        VStack(spacing: 10) {
            Picker("Mode", selection: $controller.kind) {
                ForEach(MeasurementKind.allCases) { kind in
                    Label(kind.title, systemImage: Theme.symbol(for: kind)).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .padding(4)
            .hudPlate(highContrast: settings.highContrastHUD, cornerRadius: 10)

            HStack(spacing: 14) {
                HUDIconButton(systemImage: "arrow.uturn.backward", label: "Undo", highContrast: settings.highContrastHUD) { controller.undo() }
                    .disabled(!controller.canUndo)
                    .opacity(controller.canUndo ? 1 : 0.4)
                HUDIconButton(systemImage: "trash", label: "Clear all", highContrast: settings.highContrastHUD) { confirmClear = true }
                    .disabled(!controller.canUndo)
                    .opacity(controller.canUndo ? 1 : 0.4)

                Spacer()

                Button {
                    controller.addPointAtReticle()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 32, weight: .bold))
                        .frame(width: 74, height: 74)
                        .foregroundStyle(.black)
                        .background(Theme.accent, in: Circle())
                        .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                        .shadow(color: .black.opacity(0.5), radius: 6)
                }
                .accessibilityLabel("Add point at reticle")
                .disabled(controller.reticle == nil)
                .opacity(controller.reticle == nil ? 0.5 : 1)

                Spacer()

                if controller.kind != .distance {
                    if controller.canClosePolygon {
                        HUDIconButton(systemImage: "checkmark.seal", label: "Close outline", highContrast: settings.highContrastHUD) { controller.closePolygon() }
                    } else {
                        HUDIconButton(systemImage: "rectangle.dashed", label: "Three-point rectangle", isOn: controller.rectangleAssist, highContrast: settings.highContrastHUD) {
                            controller.rectangleAssist.toggle()
                        }
                    }
                } else {
                    Color.clear.frame(width: 44, height: 44)
                }
                HUDIconButton(systemImage: "square.and.arrow.down", label: "Save measurement", isOn: controller.saveCandidate != nil, highContrast: settings.highContrastHUD) {
                    saveTarget = controller.saveCandidate
                }
                .disabled(controller.saveCandidate == nil)
                .opacity(controller.saveCandidate == nil ? 0.4 : 1)
            }
        }
    }
}

/// LiDAR confidence map overlay. The map is in sensor (landscape) orientation; rotating it
/// `.right` and aspect-filling the screen matches how ARView draws the camera feed in portrait.
private struct ConfidenceOverlay: View {
    let image: CGImage

    var body: some View {
        GeometryReader { geo in
            Image(decorative: image, scale: 1, orientation: .right)
                .resizable()
                .interpolation(.none)
                .scaledToFill()
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
        }
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }
}

/// Name and notes for a measurement before it goes to the library.
struct SaveMeasurementSheet: View {
    let measurement: Measurement
    let defaultName: String
    let formatter: MetricFormatter
    let onSave: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var notes = ""

    var body: some View {
        NavigationStack {
            Form {
                if let r = measurement.result() {
                    Section("Value") {
                        let readout = Readout.make(for: r, formatter: formatter, isLive: false)
                        LabeledContent(measurement.kind.title, value: readout.primary)
                        LabeledContent("Uncertainty (≈1σ)", value: readout.uncertainty)
                        LabeledContent("Confidence", value: r.grade.title)
                        ForEach(readout.secondary, id: \.self) { Text($0) }
                        if !measurement.snapSummary.isEmpty { LabeledContent("Located by", value: measurement.snapSummary) }
                        ForEach(r.caveats, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.fair) }
                    }
                }
                Section("Details") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.sentences)
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }
                Section {
                    Text("Saved with the date and time. Phone LiDAR is not survey-grade; check critical dimensions with a tape or laser measure.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Save measurement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(trimmed.isEmpty ? defaultName : trimmed, notes)
                        dismiss()
                    }
                }
            }
            .onAppear { if name.isEmpty { name = defaultName } }
        }
    }
}
