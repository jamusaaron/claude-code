import SwiftUI
import MeasureCore

enum AppTab: Hashable {
    case measure, scan, library, settings
}

/// Onboarding gate, then the tab interface. AR tabs are gated on LiDAR support and camera
/// permission, with clear explanations instead of a black camera view.
struct RootView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var camera = CameraPermission()
    @State private var tab: AppTab = .measure

    var body: some View {
        if !settings.hasCompletedOnboarding {
            OnboardingView(camera: camera)
        } else {
            TabView(selection: $tab) {
                arGate { ARMeasureView(isActive: tab == .measure && scenePhase == .active) }
                    .tabItem { Label("Measure", systemImage: "ruler") }
                    .tag(AppTab.measure)
                arGate { ModelCaptureView(isActive: tab == .scan && scenePhase == .active) }
                    .tabItem { Label("Scan", systemImage: "cube.transparent") }
                    .tag(AppTab.scan)
                LibraryView()
                    .tabItem { Label("Library", systemImage: "books.vertical") }
                    .tag(AppTab.library)
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(AppTab.settings)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { camera.refresh() }
            }
            .onAppear {
                camera.refresh()
                if !DeviceCapabilities.hasLiDAR { tab = .library }
            }
        }
    }

    @ViewBuilder
    private func arGate<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if !DeviceCapabilities.hasLiDAR {
            UnsupportedDeviceView()
        } else {
            switch camera.state {
            case .authorized:
                content()
            case .notDetermined:
                PermissionRequestView(camera: camera)
            case .denied, .restricted:
                PermissionDeniedView(restricted: camera.state == .restricted)
            }
        }
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
