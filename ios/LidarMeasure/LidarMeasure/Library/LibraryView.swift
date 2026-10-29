import SwiftUI
import SwiftData
import UIKit
import MeasureCore

/// Saved measurements and captured models.
struct LibraryView: View {
    enum Segment: String, CaseIterable, Identifiable {
        case measurements = "Measurements"
        case models = "3D Models"
        var id: String { rawValue }
    }

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SavedMeasurement.createdAt, order: .reverse) private var measurements: [SavedMeasurement]
    @Query(sort: \SavedModel.createdAt, order: .reverse) private var models: [SavedModel]
    @State private var segment: Segment = .measurements
    @State private var search = ""
    @State private var shareItem: ShareItem?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                switch segment {
                case .measurements: measurementList
                case .models: modelList
                }
            }
            .safeAreaInset(edge: .top) {
                Picker("Library", selection: $segment) {
                    ForEach(Segment.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.bar)
            }
            .navigationTitle("Library")
            .searchable(text: $search, prompt: segment == .measurements ? "Search measurements" : "Search models")
            .toolbar {
                if segment == .measurements {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            exportCSV()
                        } label: {
                            Label("Export CSV", systemImage: "tablecells")
                        }
                        .disabled(filteredMeasurements.isEmpty)
                    }
                }
            }
            .sheet(item: $shareItem) { item in ActivityView(items: item.urls) }
            .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: Measurements

    private var filteredMeasurements: [SavedMeasurement] {
        guard !search.isEmpty else { return measurements }
        return measurements.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.notes.localizedCaseInsensitiveContains(search) }
    }

    @ViewBuilder private var measurementList: some View {
        if measurements.isEmpty {
            ContentUnavailableView {
                Label("No measurements yet", systemImage: "ruler")
            } description: {
                Text("Measure a distance, area or volume, then tap Save to keep it here with its uncertainty and date.")
            }
        } else if filteredMeasurements.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            List {
                ForEach(filteredMeasurements) { m in
                    NavigationLink {
                        MeasurementDetailView(measurement: m)
                    } label: {
                        MeasurementRow(measurement: m, formatter: settings.formatter)
                    }
                }
                .onDelete { offsets in
                    for i in offsets { modelContext.delete(filteredMeasurements[i]) }
                    try? modelContext.save()
                }
            }
        }
    }

    private func exportCSV() {
        let rows = filteredMeasurements.map(\.csvRow)
        let data = CSVExporter.makeCSV(rows: rows, formatter: settings.formatter)
        do {
            let dir = ModelStore.temporaryRoot.appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stamp = Date().formatted(.iso8601.year().month().day())
            let url = dir.appendingPathComponent("LiDAR measurements \(stamp).csv")
            try data.write(to: url, options: .atomic)
            shareItem = ShareItem(urls: [url])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Models

    private var filteredModels: [SavedModel] {
        guard !search.isEmpty else { return models }
        return models.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    @ViewBuilder private var modelList: some View {
        if models.isEmpty {
            ContentUnavailableView {
                Label("No 3D models yet", systemImage: "cube.transparent")
            } description: {
                Text("Use the Scan tab to capture a room or an object with LiDAR. Models are stored on this device and export as USDZ, OBJ or glTF.")
            }
        } else if filteredModels.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            List {
                ForEach(filteredModels) { model in
                    NavigationLink {
                        ModelViewerView(title: model.name, folder: model.folderURL, stats: ModelStore.readMeta(model.folderURL)?.stats)
                    } label: {
                        ModelRow(model: model, formatter: settings.formatter)
                    }
                    .contextMenu {
                        ForEach(ModelStore.ExportFormat.allCases) { format in
                            Button(format.title) { share(model, format) }
                        }
                    }
                }
                .onDelete { offsets in
                    for i in offsets {
                        let model = filteredModels[i]
                        ModelStore.delete(folderName: model.folderName)
                        modelContext.delete(model)
                    }
                    try? modelContext.save()
                }
            }
        }
    }

    private func share(_ model: SavedModel, _ format: ModelStore.ExportFormat) {
        let folder = model.folderURL
        let name = model.name
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try ModelStore.export(folder: folder, format: format, displayName: name)
                }.value
                shareItem = ShareItem(urls: [url])
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct MeasurementRow: View {
    let measurement: SavedMeasurement
    let formatter: MetricFormatter

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: Theme.symbol(for: measurement.kind))
                .font(.title3)
                .frame(width: 36, height: 36)
                .foregroundStyle(.black)
                .background(Theme.color(for: measurement.confidence), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(measurement.name).font(.headline)
                Text(measurement.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(measurement.formattedValue(formatter)).font(.headline.monospacedDigit())
                Text(measurement.formattedUncertainty(formatter)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ModelRow: View {
    let model: SavedModel
    let formatter: MetricFormatter

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
                .frame(width: 56, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(model.name).font(.headline)
                Text("\(formatter.formatLength(model.sizeX)) × \(formatter.formatLength(model.sizeY)) × \(formatter.formatLength(model.sizeZ))")
                    .font(.caption.monospacedDigit())
                if let v = model.volume {
                    Text("Volume ≈ \(formatter.formatVolume(v))\(model.volumeReliable ? "" : " (holes)")")
                        .font(.caption.monospacedDigit())
                }
                Text("\(model.triangleCount.formatted()) triangles · \(model.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var thumbnail: some View {
        if let image = UIImage(contentsOfFile: model.folderURL.appendingPathComponent(ModelStore.thumbnailFile).path) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                Color.gray.opacity(0.3)
                Image(systemName: "cube.transparent").foregroundStyle(.secondary)
            }
        }
    }
}

/// Detail and editing for one saved measurement.
struct MeasurementDetailView: View {
    @Bindable var measurement: SavedMeasurement
    @EnvironmentObject private var settings: AppSettings
    @State private var shareItem: ShareItem?

    var body: some View {
        let f = settings.formatter
        Form {
            Section {
                TextField("Name", text: $measurement.name)
                TextField("Notes", text: $measurement.notes, axis: .vertical).lineLimit(2...6)
            }
            Section("Result") {
                LabeledContent(measurement.kind.title, value: measurement.formattedValue(f))
                LabeledContent("Uncertainty (≈1σ)", value: measurement.formattedUncertainty(f))
                LabeledContent("Confidence", value: measurement.confidence.title)
                if let p = measurement.perimeter { LabeledContent("Perimeter", value: f.formatLength(p)) }
                if let a = measurement.baseArea { LabeledContent("Base area", value: f.formatArea(a)) }
                if let h = measurement.height { LabeledContent("Height", value: f.formatLength(h)) }
                if !measurement.snapSummary.isEmpty { LabeledContent("Located by", value: measurement.snapSummary) }
                LabeledContent("Measured", value: measurement.createdAt.formatted(date: .long, time: .standard))
            }
            if !measurement.caveats.isEmpty {
                Section("Caveats") {
                    Label(measurement.caveats, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.fair)
                }
            }
            Section("Points (session coordinates, m)") {
                ForEach(Array(measurement.points.enumerated()), id: \.offset) { i, p in
                    Text(String(format: "%ld:  %.3f, %.3f, %.3f", i + 1, p.x, p.y, p.z))
                        .font(.caption.monospaced())
                }
            }
            Section {
                Text("Uncertainty is an estimate from LiDAR range, depth confidence, how each point was located and tracking drift. It is not a calibration; check critical dimensions with a tape or laser measure.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(measurement.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    let data = CSVExporter.makeCSV(rows: [measurement.csvRow], formatter: f)
                    let url = ModelStore.temporaryRoot.appendingPathComponent("\(ModelStore.sanitizedFileName(measurement.name)).csv")
                    if (try? data.write(to: url, options: .atomic)) != nil { shareItem = ShareItem(urls: [url]) }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share as CSV")
            }
        }
        .sheet(item: $shareItem) { item in ActivityView(items: item.urls) }
    }
}
