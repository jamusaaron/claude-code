import ARKit
import AVFoundation
import Combine

/// What this device can do. LiDAR cannot be declared in `UIRequiredDeviceCapabilities`, so the
/// app checks at runtime and degrades to a library-only experience on non-LiDAR devices.
enum DeviceCapabilities {
    /// Scene reconstruction (the fused LiDAR mesh) and per-frame scene depth both require LiDAR.
    static var hasLiDAR: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
            && ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    static var supportsMeshClassification: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
    }

    static var supportsSmoothedDepth: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)
    }

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// Hardware identifier such as "iPhone15,2" (shown in Settings for support requests).
    static var modelIdentifier: String {
        if isSimulator { return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "Simulator" }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

/// Camera authorisation state with async request. ARKit itself also triggers the system prompt,
/// but asking explicitly lets onboarding explain why first and lets us show a clear denied state.
@MainActor
final class CameraPermission: ObservableObject {
    enum State: Equatable {
        case notDetermined
        case authorized
        case denied
        case restricted
    }

    @Published private(set) var state: State = .notDetermined

    init() { refresh() }

    func refresh() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: state = .authorized
        case .denied: state = .denied
        case .restricted: state = .restricted
        case .notDetermined: state = .notDetermined
        @unknown default: state = .denied
        }
    }

    func request() async {
        guard state == .notDetermined else { return }
        _ = await AVCaptureDevice.requestAccess(for: .video)
        refresh()
    }
}
