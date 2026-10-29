import SwiftUI
import SwiftData
import MeasureCore

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.modelContext) private var modelContext
    @State private var storageBytes: Int64 = 0
    @State private var confirmDeleteAll = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Units", selection: $settings.unitPreference) {
                        ForEach(LengthUnitPreference.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Honest precision", isOn: $settings.honestPrecision)
                } header: {
                    Text("Units (metric)")
                } footer: {
                    Text("Auto picks mm, cm or m by size. Honest precision drops digits smaller than the measurement's uncertainty, so ±2 cm shows as 1.24 m, not 1.2437 m.")
                }

                Section {
                    Toggle("Planes", isOn: $settings.snapToPlanes)
                    Toggle("Edges and corners", isOn: $settings.snapToEdges)
                    Toggle("Existing points", isOn: $settings.snapToPoints)
                } header: {
                    Text("Snapping")
                } footer: {
                    Text("Edge and corner snapping fits planes to the LiDAR mesh either side of a fold and intersects them, which recovers sharp edges the mesh itself rounds off.")
                }

                Section("Display") {
                    Toggle("Show LiDAR mesh", isOn: $settings.showMeshOverlay)
                    Toggle("Show depth confidence", isOn: $settings.showConfidenceOverlay)
                    Toggle("Occlude lines behind objects", isOn: $settings.occlusionEnabled)
                    Toggle("High-contrast HUD", isOn: $settings.highContrastHUD)
                    Toggle("Haptics", isOn: $settings.hapticsEnabled)
                }

                Section {
                    Picker("Texture detail", selection: $settings.textureKeyframes) {
                        Text("Low (9 views)").tag(9)
                        Text("Medium (16 views)").tag(16)
                        Text("High (25 views)").tag(25)
                    }
                    Picker("Default simplification", selection: $settings.defaultSimplifyCentimetres) {
                        Text("Off").tag(0.0)
                        Text("1 cm").tag(1.0)
                        Text("2 cm").tag(2.0)
                        Text("3 cm").tag(3.0)
                    }
                    Picker("Scan size limit", selection: $settings.scanVertexBudget) {
                        Text("Small (300k vertices)").tag(300_000)
                        Text("Medium (600k)").tag(600_000)
                        Text("Large (1M)").tag(1_000_000)
                    }
                } header: {
                    Text("3D capture")
                } footer: {
                    Text("Large scans need more memory and processing time. Scans stop automatically above the limit or if iOS reports low memory.")
                }

                Section("About accuracy") {
                    NavigationLink("How accurate is phone LiDAR?") { AccuracyInfoView() }
                }

                Section("This device") {
                    LabeledContent("LiDAR", value: DeviceCapabilities.hasLiDAR ? "Available" : "Not available")
                    LabeledContent("Mesh classification", value: DeviceCapabilities.supportsMeshClassification ? "Yes" : "No")
                    LabeledContent("Model", value: DeviceCapabilities.modelIdentifier)
                }

                Section {
                    LabeledContent("3D models on device", value: ByteCountFormatter.string(fromByteCount: storageBytes, countStyle: .file))
                    Button("Clear temporary files") {
                        ModelStore.clearTemporaryFiles()
                        refreshStorage()
                    }
                    Button("Delete all measurements and models", role: .destructive) { confirmDeleteAll = true }
                } header: {
                    Text("Storage")
                } footer: {
                    Text("Everything stays on this device. Nothing is uploaded.")
                }

                Section {
                    Button("Show introduction again") { settings.hasCompletedOnboarding = false }
                    Button("Reset settings to defaults") { settings.resetToDefaults() }
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                }
            }
            .navigationTitle("Settings")
            .onAppear(perform: refreshStorage)
            .confirmationDialog("Delete everything?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("Delete all", role: .destructive) { deleteEverything() }
            } message: {
                Text("This removes every saved measurement and 3D model. It can't be undone.")
            }
        }
    }

    private func refreshStorage() {
        Task {
            let bytes = await Task.detached(priority: .utility) { ModelStore.diskUsage() }.value
            storageBytes = bytes
        }
    }

    private func deleteEverything() {
        try? modelContext.delete(model: SavedMeasurement.self)
        try? modelContext.delete(model: SavedModel.self)
        try? modelContext.save()
        ModelStore.deleteEverything()
        refreshStorage()
        Haptics.success()
    }
}

/// Plain-language accuracy guidance. Phone LiDAR is a good tape-measure substitute in the right
/// conditions and a poor one in the wrong ones; this page says which is which.
struct AccuracyInfoView: View {
    var body: some View {
        List {
            Section("What to expect") {
                info("±1 cm at 0.3–2 m", "On matte, well-lit surfaces with steady tracking, single distances are typically within about a centimetre. Error grows with range: roughly 0.5 cm more per metre.")
                info("Not survey-grade", "The sensor fires a sparse grid of laser dots that ARKit upsamples. It is not a calibrated instrument. For anything structural, legal or for ordering materials, confirm with a tape or laser measure.")
                info("Long distances drift", "Tracking accumulates small errors as you move. Expect about 0.5% of the distance on top of the point error (≈5 cm over 10 m).")
            }
            Section("Where LiDAR struggles") {
                info("Glass, mirrors, water", "Light passes through or reflects away. Depth is missing or belongs to whatever is behind or reflected.")
                info("Black, shiny or metallic surfaces", "Absorb or scatter the laser. Confidence drops and readings wander.")
                info("Thin objects and edges", "Cables, chair legs and sharp edges get blended with the background. Use edge snapping, or measure flat faces.")
                info("Beyond ~5 m and closer than ~20 cm", "Returns get sparse far away; up close the sensor can't resolve depth.")
                info("Low light", "LiDAR itself works in the dark, but tracking and colour capture need light.")
            }
            Section("How the app reports this") {
                info("± value", "Every result shows an estimated 1σ uncertainty from range, ARKit depth confidence, how the point was located (plane, edge, corner, mesh or raw depth) and tracking drift.")
                info("Confidence colour", "Green: within about 1 cm and 2%. Amber: within about 3 cm and 6%. Red: worse; treat as approximate.")
                info("Warnings", "Banners appear when tracking is limited, the surface is unreliable, you're near an edge, too close or too far, or the light is low.")
            }
            Section("3D models") {
                info("Shape, not CAD", "Scans capture shape to roughly 1–3 cm. Fine detail below that, sharp edges and thin parts are smoothed or lost.")
                info("Object volume", "Computed from the closed mesh above the support surface. Holes, unseen undersides and hollow interiors make it approximate; the app flags meshes with holes.")
            }
        }
        .navigationTitle("Accuracy")
    }

    private func info(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
