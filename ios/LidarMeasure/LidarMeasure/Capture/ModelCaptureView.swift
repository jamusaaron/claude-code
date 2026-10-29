import SwiftUI
import SwiftData
import MeasureCore

/// 3D capture screen: choose what to scan, scan it, clean it up, preview and save.
struct ModelCaptureView: View {
    var isActive: Bool

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.modelContext) private var modelContext
    @StateObject private var controller = CaptureController()
    @State private var saveName = ""
    @State private var showSaveAlert = false
    @State private var confirmDiscard = false

    var body: some View {
        ZStack {
            ARViewContainer(arView: controller.arView)
                .ignoresSafeArea()

            if dimsCamera {
                Color.black.opacity(0.75).ignoresSafeArea()
            }

            VStack(spacing: 10) {
                statusBar
                if showsWarnings {
                    WarningStack(warnings: controller.warnings, highContrast: settings.highContrastHUD)
                }
                Spacer()
                if let toast = controller.toast {
                    Text(toast)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .hudPlate(highContrast: settings.highContrastHUD, cornerRadius: 20)
                }
                phasePanel
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .onAppear {
            controller.attach(settings: settings)
            if isActive { controller.start() }
        }
        .onDisappear { controller.pause() }
        .onChange(of: isActive) { _, nowActive in
            if nowActive { controller.start() } else { controller.pause() }
        }
        .fullScreenCover(isPresented: Binding(get: { controller.phase == .preview && controller.processed != nil }, set: { _ in })) {
            previewScreen
        }
        .alert(item: $controller.sessionError) { error in
            Alert(title: Text(error.title), message: Text(error.message), dismissButton: .default(Text("OK")))
        }
    }

    private var dimsCamera: Bool {
        switch controller.phase {
        case .extracting, .review, .processing, .failed: return true
        default: return false
        }
    }

    private var showsWarnings: Bool {
        controller.phase == .setup || controller.phase == .scanning
    }

    // MARK: Status

    private var statusBar: some View {
        HStack(spacing: 8) {
            Pill(text: controller.tracking.title,
                 systemImage: controller.tracking.quality == .normal ? "location.fill" : "exclamationmark.triangle.fill",
                 color: controller.tracking.quality == .normal ? Theme.good : Theme.fair)
            if controller.phase == .scanning {
                Pill(text: "REC \(timeString(controller.stats.elapsed))", systemImage: "record.circle", color: Theme.poor)
            }
            Spacer()
            if controller.phase == .setup {
                Button {
                    controller.resetMesh()
                } label: {
                    Label("Reset mesh", systemImage: "arrow.counterclockwise")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .hudPlate(highContrast: settings.highContrastHUD, cornerRadius: 18)
                }
                .foregroundStyle(.white)
            }
        }
    }

    // MARK: Panels

    @ViewBuilder private var phasePanel: some View {
        switch controller.phase {
        case .setup: setupPanel
        case .scanning: scanningPanel
        case .extracting: busyPanel(title: "Extracting LiDAR mesh…", fraction: nil, cancellable: false)
        case .review: CaptureReviewPanel(controller: controller)
        case .processing:
            busyPanel(title: controller.progress?.stage ?? "Processing…", fraction: controller.progress?.fraction, cancellable: true)
        case .preview: EmptyView()
        case .failed(let message): failedPanel(message)
        }
    }

    private var setupPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("What to capture", selection: $controller.scope) {
                ForEach(CaptureScope.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            if controller.scope == .object {
                if controller.regionBase == nil {
                    Label("Tap the floor or table where the object stands to place the capture box.", systemImage: "hand.tap")
                        .font(.subheadline)
                } else {
                    regionSliders
                }
            } else {
                Label("Captures everything the LiDAR sees, up to about 5 m. Best for rooms and large surfaces.", systemImage: "camera.metering.matrix")
                    .font(.subheadline)
            }

            Button {
                controller.startScan()
            } label: {
                Label("Start scan", systemImage: "record.circle")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.poor)
            .disabled(!controller.canStartScan)

            if controller.tracking.quality != .normal {
                Text("Waiting for tracking. Move the phone slowly.").font(.caption).foregroundStyle(Theme.fair)
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .hudPlate(highContrast: settings.highContrastHUD)
    }

    private var regionSliders: some View {
        let f = settings.formatter
        return VStack(spacing: 6) {
            sizeSlider("Width", value: $controller.regionSize.x, formatter: f)
            sizeSlider("Depth", value: $controller.regionSize.z, formatter: f)
            sizeSlider("Height", value: $controller.regionSize.y, formatter: f)
            HStack {
                Text("Rotate").font(.caption).frame(width: 52, alignment: .leading)
                Slider(value: $controller.regionYaw, in: -Float.pi...Float.pi)
                Text("\(Int((controller.regionYaw * 180 / .pi).rounded()))°").font(.caption.monospacedDigit()).frame(width: 60, alignment: .trailing)
            }
            Text("Tap again to move the box. Keep the whole object inside it.").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func sizeSlider(_ title: String, value: Binding<Float>, formatter: MetricFormatter) -> some View {
        HStack {
            Text(title).font(.caption).frame(width: 52, alignment: .leading)
            Slider(value: value, in: 0.05...3)
            Text(formatter.formatLength(Double(value.wrappedValue))).font(.caption.monospacedDigit()).frame(width: 60, alignment: .trailing)
        }
    }

    private var scanningPanel: some View {
        let s = controller.stats
        return VStack(alignment: .leading, spacing: 10) {
            Text(controller.scope == .object
                 ? "Walk slowly around the object, 0.3–1.5 m away. Cover the top and every side."
                 : "Sweep slowly across the scene. Overlap your passes and avoid fast turns.")
                .font(.subheadline)
            HStack(spacing: 14) {
                stat("Mesh", "\(compact(s.vertices)) vtx")
                stat("Keyframes", "\(s.keyframes)/\(s.maxKeyframes)")
                stat("Memory", String(format: "%.0f MB", s.estimatedMegabytes))
            }
            ProgressView(value: min(1, s.budgetFraction)) {
                Text("Scan size budget").font(.caption2)
            }
            .tint(s.budgetFraction > 0.85 ? Theme.poor : Theme.accent)

            Button {
                controller.stopScan()
            } label: {
                Label("Finish scan", systemImage: "stop.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .foregroundStyle(.black)
        }
        .foregroundStyle(.white)
        .padding(14)
        .hudPlate(highContrast: settings.highContrastHUD)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit())
        }
    }

    private func busyPanel(title: String, fraction: Double?, cancellable: Bool) -> some View {
        VStack(spacing: 12) {
            if let fraction {
                ProgressView(value: fraction) { Text(title) }
            } else {
                ProgressView(title)
            }
            if cancellable {
                Button("Cancel", role: .cancel) { controller.cancelProcessing() }
            }
            Text("Everything is processed on this device.").font(.caption2).foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
        .padding(14)
        .hudPlate(highContrast: settings.highContrastHUD)
    }

    private func failedPanel(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Capture problem", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(Theme.fair)
            Text(message).font(.subheadline)
            HStack {
                Button("Back") { controller.adjust() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Start over", role: .destructive) { controller.discard() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .hudPlate(highContrast: settings.highContrastHUD)
    }

    // MARK: Preview

    private var previewScreen: some View {
        NavigationStack {
            if let model = controller.processed {
                ModelViewerView(title: "Preview", folder: model.folder, stats: model.stats, allowsExport: false)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Adjust") { controller.adjust() }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                saveName = defaultModelName
                                showSaveAlert = true
                            }
                        }
                        ToolbarItem(placement: .bottomBar) {
                            Button("Discard scan", role: .destructive) { confirmDiscard = true }
                        }
                    }
                    .alert("Save model", isPresented: $showSaveAlert) {
                        TextField("Name", text: $saveName)
                        Button("Save") {
                            let name = saveName.trimmingCharacters(in: .whitespacesAndNewlines)
                            controller.save(name: name.isEmpty ? defaultModelName : name, context: modelContext)
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Saved on this device. Export USDZ, OBJ or glTF from the library.")
                    }
                    .confirmationDialog("Discard this scan?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                        Button("Discard", role: .destructive) { controller.discard() }
                    }
            }
        }
        .environmentObject(settings)
        .preferredColorScheme(.dark)
    }

    private var defaultModelName: String {
        let date = Date().formatted(date: .abbreviated, time: .shortened)
        return controller.scope == .object ? "Object \(date)" : "Scene \(date)"
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func compact(_ n: Int) -> String {
        n >= 1000 ? "\(n / 1000)k" : "\(n)"
    }
}
