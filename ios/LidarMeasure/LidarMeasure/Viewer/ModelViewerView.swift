import SwiftUI
import MeasureCore

/// 3D preview of an exported model with orbit/zoom/pan, lighting, AR Quick Look and export.
struct ModelViewerView: View {
    let title: String
    let folder: URL
    let stats: ModelStats?
    /// Library mode shows export; capture preview supplies its own actions.
    var allowsExport = true

    @EnvironmentObject private var settings: AppSettings
    @StateObject private var controller = ModelViewerController()
    @State private var quickLookURL: URL?
    @State private var shareItem: ShareItem?
    @State private var exportError: String?
    @State private var exporting = false
    @State private var showControls = true

    private var usdzURL: URL { folder.appendingPathComponent(ModelStore.usdzFile) }

    var body: some View {
        ZStack {
            ARViewContainer(arView: controller.arView)
                .ignoresSafeArea()

            switch controller.state {
            case .idle, .loading:
                ProgressView("Loading model…")
                    .padding()
                    .hudPlate(highContrast: settings.highContrastHUD)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Can't display model", systemImage: "cube.transparent")
                } description: {
                    Text(message)
                } actions: {
                    Button("Open in AR Quick Look") { quickLookURL = usdzURL }
                }
                .hudPlate(highContrast: true)
                .padding()
            case .loaded:
                EmptyView()
            }

            VStack {
                if let stats, showControls { statsCard(stats) }
                Spacer()
                if showControls { controls }
            }
            .padding(12)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { withAnimation { showControls.toggle() } } label: {
                    Image(systemName: showControls ? "eye.slash" : "slider.horizontal.3")
                }
                .accessibilityLabel(showControls ? "Hide controls" : "Show controls")
                if allowsExport {
                    Menu {
                        ForEach(ModelStore.ExportFormat.allCases) { format in
                            Button(format.title) { export(format) }
                        }
                    } label: {
                        if exporting { ProgressView() } else { Image(systemName: "square.and.arrow.up") }
                    }
                    .disabled(exporting)
                    .accessibilityLabel("Export model")
                }
            }
        }
        .onAppear { controller.load(usdzURL) }
        .sheet(item: $shareItem) { item in ActivityView(items: item.urls) }
        .fullScreenCover(item: Binding(get: { quickLookURL.map(IdentifiedURL.init) }, set: { quickLookURL = $0?.url })) { item in
            ARQuickLookView(url: item.url).ignoresSafeArea()
        }
        .alert("Export failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    private func statsCard(_ s: ModelStats) -> some View {
        let f = settings.formatter
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(f.formatLength(s.size.x)) × \(f.formatLength(s.size.y)) × \(f.formatLength(s.size.z))")
                .font(.headline.monospacedDigit())
            Text("W × H × D (bounding box)").font(.caption2).foregroundStyle(.secondary)
            if let v = s.volume {
                HStack(spacing: 6) {
                    Text("Volume ≈ \(f.formatVolume(v))").font(.subheadline.monospacedDigit())
                    Pill(text: s.volumeReliable ? "Closed mesh" : "Mesh has holes", systemImage: nil, color: s.volumeReliable ? Theme.good : Theme.fair)
                }
            }
            Text("\(s.triangleCount.formatted()) triangles · \(Int((s.texturedShare * 100).rounded()))% textured")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hudPlate(highContrast: settings.highContrastHUD)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "sun.min")
                Slider(value: $controller.environmentExposure, in: -2...2)
                Image(systemName: "sun.max")
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Environment lighting")
            HStack(spacing: 10) {
                Toggle(isOn: $controller.showTexture) { Label("Texture", systemImage: "photo") }
                    .toggleStyle(.button)
                Toggle(isOn: $controller.keyLightOn) { Label("Key light", systemImage: "lightbulb") }
                    .toggleStyle(.button)
                Spacer()
                Button { controller.resetView() } label: { Image(systemName: "scope") }
                    .accessibilityLabel("Reset view")
                Button { quickLookURL = usdzURL } label: { Label("AR", systemImage: "arkit") }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("View in AR at true scale")
            }
            Text("Drag to orbit · two fingers to pan · pinch to zoom · double-tap to reset")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .hudPlate(highContrast: settings.highContrastHUD)
    }

    private func export(_ format: ModelStore.ExportFormat) {
        exporting = true
        let exportFolder = self.folder
        let name = self.title
        Task {
            do {
                // Large meshes take a moment to serialise; keep it off the main thread.
                let url = try await Task.detached(priority: .userInitiated) {
                    try ModelStore.export(folder: exportFolder, format: format, displayName: name)
                }.value
                exporting = false
                shareItem = ShareItem(urls: [url])
            } catch {
                exporting = false
                exportError = error.localizedDescription
            }
        }
    }
}

struct IdentifiedURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
