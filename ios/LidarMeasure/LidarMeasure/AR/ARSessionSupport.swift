import ARKit
import RealityKit
import SwiftUI
import UIKit
import MeasureCore

/// Builds the ARKit configurations. Both modes need LiDAR; see `DeviceCapabilities`.
///
/// LiDAR pipeline in brief:
///  1. The dToF LiDAR fires a sparse grid of laser dots and times their return.
///  2. ARKit fuses those returns with the RGB camera into a dense 256×192 depth map per frame
///     (`sceneDepth`), with a per-pixel confidence map; `smoothedSceneDepth` averages a few frames
///     to cut temporal noise.
///  3. With `sceneReconstruction`, ARKit also integrates depth over time into a triangle mesh,
///     delivered as `ARMeshAnchor` chunks that are refined as you keep scanning.
///  4. World tracking (visual-inertial odometry) places all of that in one metric coordinate
///     frame: metres, +Y opposite to gravity.
enum ARConfigurationFactory {
    /// One configuration shared by Measure and Scan, so switching tabs never re-runs the
    /// session or moves the world origin: both planes (snapping, capture box placement),
    /// classified mesh (snapping, capture), and LiDAR depth (smoothed is steadier for picking
    /// a static point; raw is the fallback).
    static func shared() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            config.sceneReconstruction = .meshWithClassification
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        config.environmentTexturing = .none
        config.isLightEstimationEnabled = true
        return config
    }

    /// ARView tuned for measuring: no cinematic effects that cost frames or blur edges.
    @MainActor static func makeARView() -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.renderOptions = [.disableMotionBlur, .disableDepthOfField, .disablePersonOcclusion, .disableGroundingShadows, .disableCameraGrain]
        view.environment.sceneUnderstanding.options = []
        return view
    }
}

/// Human-readable tracking state.
struct TrackingStatus: Equatable {
    var quality: TrackingQuality
    var title: String
    var detail: String?

    static let initialising = TrackingStatus(quality: .limited, title: "Starting", detail: "Move the phone slowly to begin tracking.")

    init(quality: TrackingQuality, title: String, detail: String?) {
        self.quality = quality
        self.title = title
        self.detail = detail
    }

    init(_ state: ARCamera.TrackingState) {
        switch state {
        case .normal:
            self.init(quality: .normal, title: "Tracking", detail: nil)
        case .notAvailable:
            self.init(quality: .notAvailable, title: "No tracking", detail: "Tracking is unavailable. Restart the session.")
        case .limited(let reason):
            switch reason {
            case .initializing:
                self.init(quality: .limited, title: "Starting", detail: "Move the phone slowly to begin tracking.")
            case .excessiveMotion:
                self.init(quality: .limited, title: "Too fast", detail: "Slow down. Fast motion degrades tracking and accuracy.")
            case .insufficientFeatures:
                self.init(quality: .limited, title: "Low detail", detail: "Aim at a textured, well-lit area. Blank walls track poorly.")
            case .relocalizing:
                self.init(quality: .limited, title: "Relocalising", detail: "Return to where you started so tracking can recover.")
            @unknown default:
                self.init(quality: .limited, title: "Limited", detail: "Tracking is limited; measurements are less reliable.")
            }
        }
    }
}

/// A session failure the user can understand and act on.
struct SessionErrorInfo: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
    var opensSettings: Bool
    var canRetry: Bool

    static func == (a: SessionErrorInfo, b: SessionErrorInfo) -> Bool { a.id == b.id }

    init(title: String, message: String, opensSettings: Bool = false, canRetry: Bool = true) {
        self.title = title
        self.message = message
        self.opensSettings = opensSettings
        self.canRetry = canRetry
    }

    init(_ error: Error) {
        guard let arError = error as? ARError else {
            self.init(title: "AR session failed", message: error.localizedDescription)
            return
        }
        switch arError.code {
        case .cameraUnauthorized:
            self.init(title: "Camera access needed", message: "Allow camera access in Settings to measure with LiDAR.", opensSettings: true, canRetry: false)
        case .unsupportedConfiguration:
            self.init(title: "LiDAR not available", message: "This device doesn't support LiDAR scene reconstruction. An iPhone 12 Pro or later Pro model, or iPad Pro (2020 or later), is required.", canRetry: false)
        case .sensorUnavailable, .sensorFailed:
            self.init(title: "Sensor unavailable", message: "The camera or LiDAR sensor isn't responding. Close other camera apps and try again.")
        case .worldTrackingFailed:
            self.init(title: "Tracking lost", message: "World tracking failed. Restart the session and move slowly over a textured area.")
        default:
            self.init(title: "AR session failed", message: arError.localizedDescription)
        }
    }
}

/// Bridges ARKit's delegate callbacks into the main-actor `ARSessionHost`.
/// The host sets `session.delegateQueue = .main`, which `assumeIsolated` relies on.
final class ARSessionDelegateProxy: NSObject, ARSessionDelegate {
    weak var host: ARSessionHost?

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        MainActor.assumeIsolated { host?.dispatchFrame(frame) }
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        MainActor.assumeIsolated { host?.dispatchAnchors(anchors, removed: false) }
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        MainActor.assumeIsolated { host?.dispatchAnchors(anchors, removed: false) }
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        MainActor.assumeIsolated { host?.dispatchAnchors(anchors, removed: true) }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let status = TrackingStatus(camera.trackingState)
        MainActor.assumeIsolated { host?.dispatchTracking(status) }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        MainActor.assumeIsolated { host?.dispatchFailure(error) }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        MainActor.assumeIsolated { host?.dispatchInterruption(true) }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        MainActor.assumeIsolated { host?.dispatchInterruption(false) }
    }

    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }
}

/// A mode (Measure or Scan) that uses the shared AR session.
@MainActor
protocol ARModeHandling: AnyObject {
    /// Per-frame updates, delivered only to the mode on screen.
    func sessionDidUpdate(frame: ARFrame)
    /// Anchor changes, delivered to every mode so world-space state stays current.
    func sessionDidChange(anchors: [ARAnchor], removed: Bool)
    func sessionTrackingChanged(_ status: TrackingStatus)
    func sessionFailed(_ error: Error)
    func sessionInterrupted(_ interrupted: Bool)
    /// The mode came on screen / left the screen (the session keeps running between modes).
    func modeDidActivate()
    func modeDidDeactivate()
    /// The camera is about to stop (Library/Settings, background, or the scan is processing).
    func sessionWillPause()
    /// Tracking is restarting with a new world origin: drop every world-space coordinate.
    func worldWillReset()
}

/// Hosts a controller-owned ARView in SwiftUI. The view outlives SwiftUI updates, so the session
/// and all placed content survive tab switches.
struct ARViewContainer: UIViewRepresentable {
    let arView: ARView

    func makeUIView(context: Context) -> ARView { arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}

extension UIApplication {
    /// Interface orientation of the active scene (portrait for this app, but read it properly).
    @MainActor var activeInterfaceOrientation: UIInterfaceOrientation {
        connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }?.interfaceOrientation ?? .portrait
    }
}
