import SwiftUI
import MeasureCore

enum AppTab: String, CaseIterable, Identifiable {
    case measure, scan, library, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .measure: return "Measure"
        case .scan: return "Scan"
        case .library: return "Library"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .measure: return "ruler"
        case .scan: return "cube.transparent"
        case .library: return "books.vertical"
        case .settings: return "gearshape"
        }
    }

    var usesCamera: Bool { self == .measure || self == .scan }
}

/// Onboarding gate, then one shared camera with the Measure or Scan tools on top of it, and
/// the Library and Settings with the camera fully off.
///
/// A custom tab bar (rather than `TabView`) keeps a single `ARView` in one place in the view
/// tree: switching between Measure and Scan swaps only the overlay, never the camera.
struct RootView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var camera = CameraPermission()
    @State private var tab: AppTab = .measure
    @State private var pendingTab: AppTab?

    var body: some View {
        if !settings.hasCompletedOnboarding {
            OnboardingView(camera: camera)
        } else {
            VStack(spacing: 0) {
                ZStack {
                    content
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                AppTabBar(selection: tab, onSelect: select)
            }
            .background(Color.black.ignoresSafeArea())
            .onAppear {
                camera.refresh()
                if !DeviceCapabilities.hasLiDAR { tab = .library }
                updateCamera()
            }
            .onChange(of: tab) { _, _ in updateCamera() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { camera.refresh() }
                updateCamera()
            }
            .onChange(of: camera.state) { _, _ in updateCamera() }
            .confirmationDialog("Finish the scan first?", isPresented: Binding(get: { pendingTab != nil }, set: { if !$0 { pendingTab = nil } }), titleVisibility: .visible) {
                Button("Finish scan and continue") {
                    model.capture.stopScan()
                    if let pendingTab { tab = pendingTab }
                    pendingTab = nil
                }
                Button("Keep scanning", role: .cancel) { pendingTab = nil }
            } message: {
                Text("Leaving stops the camera. What you've scanned so far is kept for review.")
            }
        }
    }

    @ViewBuilder private var content: some View {
        if tab.usesCamera {
            if !DeviceCapabilities.hasLiDAR {
                UnsupportedDeviceView()
            } else {
                switch camera.state {
                case .authorized:
                    ARViewContainer(arView: model.host.arView)
                        .ignoresSafeArea(edges: .top)
                    if tab == .measure {
                        ARMeasureView(controller: model.measure)
                    } else {
                        ModelCaptureView(controller: model.capture, lastMeasurementPoints: model.measure.lastCompletedPoints)
                    }
                case .notDetermined:
                    PermissionRequestView(camera: camera)
                case .denied, .restricted:
                    PermissionDeniedView(restricted: camera.state == .restricted)
                }
            }
        } else if tab == .library {
            LibraryView()
        } else {
            SettingsView(onRestartTracking: { model.host.restartTracking() })
        }
    }

    private func select(_ newTab: AppTab) {
        guard newTab != tab else { return }
        if tab == .scan && model.capture.phase == .scanning {
            pendingTab = newTab
            return
        }
        Haptics.tick()
        tab = newTab
    }

    /// The camera runs only when a camera tab is on screen, the app is active, and the
    /// user has granted access.
    private func updateCamera() {
        let wantsCamera = tab.usesCamera && scenePhase == .active && camera.state == .authorized && DeviceCapabilities.hasLiDAR
        if wantsCamera {
            model.host.activate(tab == .measure ? .measure : .capture)
        } else {
            model.host.deactivate()
        }
    }
}

/// Bottom tab bar with large targets and a high-contrast selected state.
struct AppTabBar: View {
    var selection: AppTab
    var onSelect: (AppTab) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                Button { onSelect(tab) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon).font(.system(size: 20, weight: .semibold))
                        Text(tab.title).font(.caption2.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .foregroundStyle(selection == tab ? Theme.accent : Color.white.opacity(0.6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selection == tab ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(.top, 6)
        .background(Color.black.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Divider().overlay(Color.white.opacity(0.15)) }
    }
}

struct UnsupportedDeviceView: View {
    var body: some View {
        ContentUnavailableView {
            Label("LiDAR not available", systemImage: "dot.radiowaves.left.and.right")
        } description: {
            Text(DeviceCapabilities.isSimulator
                 ? "The Simulator has no camera or LiDAR. Run on an iPhone 12 Pro or later Pro model, or an iPad Pro (2020 or later)."
                 : "Measuring and scanning need the LiDAR Scanner on iPhone 12 Pro and later Pro models, or iPad Pro (2020 and later). Saved items are still available in the Library.")
        }
    }
}

struct PermissionRequestView: View {
    @ObservedObject var camera: CameraPermission

    var body: some View {
        ContentUnavailableView {
            Label("Camera access needed", systemImage: "camera.viewfinder")
        } description: {
            Text("LiDAR measurement runs through the camera. Nothing is recorded or uploaded.")
        } actions: {
            Button("Allow camera access") { Task { await camera.request() } }
                .buttonStyle(.borderedProminent)
        }
    }
}

struct PermissionDeniedView: View {
    var restricted: Bool

    var body: some View {
        ContentUnavailableView {
            Label(restricted ? "Camera restricted" : "Camera access is off", systemImage: "video.slash")
        } description: {
            Text(restricted
                 ? "Camera use is restricted on this device (Screen Time or device management)."
                 : "Turn on camera access for this app in Settings to measure and scan.")
        } actions: {
            if !restricted {
                Button("Open Settings") { SystemSettings.open() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
