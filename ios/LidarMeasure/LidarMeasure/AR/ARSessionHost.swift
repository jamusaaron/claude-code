import ARKit
import Combine
import RealityKit
import UIKit

enum ARMode: Equatable {
    case measure
    case capture
}

/// Owns the single camera, ARKit session and RealityKit view shared by Measure and Scan.
///
/// One session means:
///  * only one camera pipeline and renderer in memory;
///  * switching between Measure and Scan never pauses tracking, so placed points and the
///    reconstructed mesh stay in one coordinate system (a capture box can be fitted to a
///    measurement);
///  * the camera is fully off while browsing the Library or Settings.
@MainActor
final class ARSessionHost: ObservableObject {
    let arView: ARView
    @Published private(set) var activeMode: ARMode?
    @Published private(set) var isRunning = false

    weak var measureHandler: ARModeHandling?
    weak var captureHandler: ARModeHandling?

    private let proxy = ARSessionDelegateProxy()
    private let coaching = ARCoachingOverlayView()
    private var hasRunOnce = false
    /// A tracking restart requested while the camera was off; applied on the next run.
    private var pendingReset = false
    /// Held by Scan while it reviews or processes a capture: the camera isn't needed.
    private var isSuspended = false

    init() {
        arView = ARConfigurationFactory.makeARView()
        // Callbacks on main: the proxy hops onto the main actor synchronously, and Metal mesh
        // buffers are never read while ARKit updates them on another thread.
        arView.session.delegateQueue = .main
        proxy.host = self
        arView.session.delegate = proxy
        arView.accessibilityLabel = "Live LiDAR camera"
        arView.accessibilityHint = "Aim the centre crosshair at a surface, then use Add point."

        coaching.session = arView.session
        coaching.goal = .tracking
        coaching.activatesAutomatically = true
        coaching.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        coaching.frame = arView.bounds
        arView.addSubview(coaching)
    }

    private var handlers: [ARModeHandling] { [measureHandler, captureHandler].compactMap { $0 } }

    private func handler(for mode: ARMode?) -> ARModeHandling? {
        switch mode {
        case .measure: return measureHandler
        case .capture: return captureHandler
        case nil: return nil
        }
    }

    // MARK: Lifecycle

    /// Brings a mode on screen and makes sure the camera is running (unless suspended).
    func activate(_ mode: ARMode) {
        guard DeviceCapabilities.hasLiDAR else { return }
        if activeMode != mode {
            handler(for: activeMode)?.modeDidDeactivate()
            activeMode = mode
            coaching.goal = mode == .capture ? .horizontalPlane : .tracking
            handler(for: mode)?.modeDidActivate()
        }
        if mode == .measure { isSuspended = false }
        if !isRunning && !isSuspended { run(reset: !hasRunOnce || pendingReset) }
    }

    /// Turns the camera off (Library, Settings, background).
    func deactivate() {
        handler(for: activeMode)?.modeDidDeactivate()
        activeMode = nil
        pauseSession()
    }

    /// Pauses the camera while the active mode doesn't need it, without leaving the mode.
    func suspend() {
        isSuspended = true
        pauseSession()
    }

    /// Ends a suspension; restarts the camera if a mode is on screen.
    func resume() {
        isSuspended = false
        if activeMode != nil && !isRunning { run(reset: !hasRunOnce || pendingReset) }
    }

    /// New world origin: every mode drops its world-space state first.
    func restartTracking() {
        handlers.forEach { $0.worldWillReset() }
        isSuspended = false
        if activeMode != nil {
            run(reset: true)
        } else {
            pendingReset = true // don't switch the camera on from Settings
        }
    }

    /// Clears the reconstructed mesh but keeps the world origin, so placed points stay valid.
    func resetReconstruction() {
        guard isRunning else { return }
        arView.session.run(ARConfigurationFactory.shared(), options: [.resetSceneReconstruction])
    }

    private func run(reset: Bool) {
        let options: ARSession.RunOptions = reset ? [.resetTracking, .removeExistingAnchors, .resetSceneReconstruction] : []
        arView.session.run(ARConfigurationFactory.shared(), options: options)
        hasRunOnce = true
        if reset { pendingReset = false }
        isRunning = true
        UIApplication.shared.isIdleTimerDisabled = true
        Haptics.prepare()
    }

    private func pauseSession() {
        guard isRunning else { return }
        handlers.forEach { $0.sessionWillPause() }
        arView.session.pause()
        isRunning = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: Dispatch (from ARSessionDelegateProxy)

    func dispatchFrame(_ frame: ARFrame) {
        handler(for: activeMode)?.sessionDidUpdate(frame: frame)
    }

    func dispatchAnchors(_ anchors: [ARAnchor], removed: Bool) {
        handlers.forEach { $0.sessionDidChange(anchors: anchors, removed: removed) }
    }

    func dispatchTracking(_ status: TrackingStatus) {
        handlers.forEach { $0.sessionTrackingChanged(status) }
    }

    func dispatchFailure(_ error: Error) {
        isRunning = false
        UIApplication.shared.isIdleTimerDisabled = false
        (handler(for: activeMode) ?? measureHandler)?.sessionFailed(error)
    }

    func dispatchInterruption(_ interrupted: Bool) {
        handlers.forEach { $0.sessionInterrupted(interrupted) }
    }
}

/// App-wide owner of the shared session and both modes. Created once by the App.
@MainActor
final class AppModel: ObservableObject {
    let host: ARSessionHost
    let measure: MeasureController
    let capture: CaptureController

    init() {
        let host = ARSessionHost()
        self.host = host
        measure = MeasureController(host: host)
        capture = CaptureController(host: host)
        host.measureHandler = measure
        host.captureHandler = capture
    }
}
