import ARKit
import Combine
import RealityKit
import SwiftData
import UIKit
import MeasureCore

/// Live scan statistics shown while capturing.
struct ScanStats: Equatable {
    var meshAnchors = 0
    var vertices = 0
    var faces = 0
    var keyframes = 0
    var maxKeyframes = 0
    var elapsed: TimeInterval = 0
    /// Rough size of the mesh data we'll copy out (MB).
    var estimatedMegabytes: Double = 0
    var budgetFraction: Double = 0
}

struct PipelineProgress: Equatable {
    var stage: String
    var fraction: Double
}

/// Drives a 3D capture: choose scope → (place box) → scan → review options → process → save.
@MainActor
final class CaptureController: NSObject, ObservableObject, ARSessionEventHandling {
    enum Phase: Equatable {
        case setup
        case scanning
        case extracting
        case review
        case processing
        case preview
        case failed(String)
    }

    // MARK: Published

    @Published var scope: CaptureScope = .object { didSet { regionChanged() } }
    @Published private(set) var phase: Phase = .setup
    @Published var regionSize = SIMD3<Float>(0.5, 0.5, 0.5) { didSet { regionChanged() } }
    @Published var regionYaw: Float = 0 { didSet { regionChanged() } }
    @Published private(set) var regionBase: SIMD3<Float>?
    @Published private(set) var stats = ScanStats()
    @Published private(set) var warnings: [EnvironmentWarning] = []
    @Published private(set) var tracking: TrackingStatus = .initialising
    @Published var sessionError: SessionErrorInfo?
    @Published private(set) var progress: PipelineProgress?
    @Published private(set) var processed: ProcessedModel?
    @Published var options = ProcessingOptions()
    @Published var toast: String?

    let arView: ARView

    // MARK: Private

    private let delegateProxy = ARSessionDelegateProxy()
    private let monitor = EnvironmentMonitor()
    private let regionEntity = RegionBoxEntity()
    private let coaching = ARCoachingOverlayView()
    private weak var settings: AppSettings?
    private var recorder: KeyframeRecorder?
    private var snapshot: CaptureSnapshot?
    private var scanStart: Date?
    private var statsTimer: Timer?
    private var processingTask: Task<Void, Never>?
    private var frameCounter = 0
    private var isRunning = false
    private var memoryObserver: NSObjectProtocol?

    override init() {
        arView = ARConfigurationFactory.makeARView()
        super.init()
        delegateProxy.target = self
        arView.session.delegate = delegateProxy
        arView.scene.addAnchor(regionEntity.anchor)

        coaching.session = arView.session
        coaching.goal = .horizontalPlane
        coaching.activatesAutomatically = true
        coaching.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        coaching.frame = arView.bounds
        arView.addSubview(coaching)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        arView.addGestureRecognizer(tap)

        memoryObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMemoryWarning() }
        }
    }

    func attach(settings: AppSettings) {
        self.settings = settings
        options.textureKeyframes = settings.textureKeyframes
        options.simplifyCentimetres = settings.defaultSimplifyCentimetres
    }

    // MARK: Session

    func start() {
        guard !isRunning, DeviceCapabilities.hasLiDAR else { return }
        switch phase {
        case .setup, .scanning:
            runSession(reset: !hasRunOnce)
        default:
            break // reviewing/processing: keep the session paused
        }
    }

    private var hasRunOnce = false

    private func runSession(reset: Bool) {
        let options: ARSession.RunOptions = reset ? [.resetTracking, .removeExistingAnchors, .resetSceneReconstruction] : []
        arView.session.run(ARConfigurationFactory.capture(), options: options)
        // The live wireframe shows what the LiDAR has reconstructed so far.
        arView.debugOptions.insert(.showSceneUnderstanding)
        hasRunOnce = true
        isRunning = true
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func pause() {
        guard isRunning else { return }
        if phase == .scanning { stopScanTimer() }
        arView.session.pause()
        isRunning = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Throws away the reconstructed mesh so far (e.g. after moving to a new spot).
    func resetMesh() {
        regionBase = nil
        regionChanged()
        monitor.reset()
        runSession(reset: true)
        Haptics.tick()
    }

    // MARK: ARSessionEventHandling

    func sessionDidUpdate(frame: ARFrame) {
        frameCounter &+= 1
        if phase == .scanning, frameCounter % 6 == 0 { recorder?.consider(frame) }
        if frameCounter % 12 == 0 {
            let centre = DepthSampler.sample(frame: frame, viewPoint: CGPoint(x: arView.bounds.midX, y: arView.bounds.midY),
                                             viewportSize: arView.bounds.size, orientation: UIApplication.shared.activeInterfaceOrientation)
            let w = monitor.evaluate(frame: frame, centre: centre, stats: DepthSampler.centralStats(frame: frame))
            if w != warnings { warnings = w }
        }
    }

    func sessionDidChange(anchors: [ARAnchor], removed: Bool) {}

    func sessionTrackingChanged(_ status: TrackingStatus) { tracking = status }

    func sessionFailed(_ error: Error) {
        isRunning = false
        if phase == .scanning { stopScanTimer() }
        sessionError = SessionErrorInfo(error)
        Haptics.error()
    }

    func sessionInterrupted(_ interrupted: Bool) {
        if interrupted {
            monitor.externalFlags.insert(.interrupted)
        } else {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                self?.monitor.externalFlags.remove(.interrupted)
            }
        }
    }

    // MARK: Region

    var region: OrientedBox? {
        guard scope == .object, let base = regionBase else { return nil }
        return OrientedBox(base: base.asDouble, yaw: Double(regionYaw), size: regionSize.asDouble)
    }

    private func regionChanged() {
        regionEntity.update(region)
        coaching.goal = scope == .object ? .horizontalPlane : .tracking
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard phase == .setup, scope == .object, gesture.state == .ended else { return }
        let point = gesture.location(in: arView)
        let hit = arView.raycast(from: point, allowing: .existingPlaneGeometry, alignment: .horizontal).first
            ?? arView.raycast(from: point, allowing: .estimatedPlane, alignment: .horizontal).first
        guard let hit else {
            Haptics.warning()
            showToast("Tap on a floor or table surface.")
            return
        }
        regionBase = hit.worldTransform.origin
        // Square the box up with the viewing direction.
        if let camera = arView.session.currentFrame?.camera.transform {
            let forward = -SIMD3(camera.columns.2.x, 0, camera.columns.2.z)
            if simd_length(forward) > 0.01 { regionYaw = atan2(forward.x, forward.z) }
        }
        regionChanged()
        Haptics.pointPlaced()
    }

    // MARK: Scanning

    var canStartScan: Bool {
        phase == .setup && tracking.quality == .normal && (scope == .scene || regionBase != nil)
    }

    func startScan() {
        guard canStartScan else { return }
        do {
            let dir = try ModelStore.makeTemporaryFolder(prefix: "keyframes")
            recorder = KeyframeRecorder(directory: dir, maxKeyframes: 100)
        } catch {
            sessionError = SessionErrorInfo(title: "Storage unavailable", message: error.localizedDescription, canRetry: false)
            return
        }
        scanStart = Date()
        stats = ScanStats(maxKeyframes: 100)
        phase = .scanning
        startScanTimer()
        Haptics.success()
    }

    private func startScanTimer() {
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStats() }
        }
    }

    private func stopScanTimer() {
        statsTimer?.invalidate()
        statsTimer = nil
    }

    private func updateStats() {
        guard phase == .scanning, let frame = arView.session.currentFrame else { return }
        let anchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        let counts = MeshExtractor.counts(anchors)
        let budget = settings?.scanVertexBudget ?? 600_000
        var s = stats
        s.meshAnchors = anchors.count
        s.vertices = counts.vertices
        s.faces = counts.faces
        s.keyframes = recorder?.records.count ?? 0
        s.elapsed = Date().timeIntervalSince(scanStart ?? Date())
        // Our copy needs position + normal per vertex and three indices + class per face.
        s.estimatedMegabytes = Double(counts.vertices * 24 + counts.faces * 13) / 1_048_576
        s.budgetFraction = Double(counts.vertices) / Double(budget)
        stats = s

        if s.budgetFraction > 0.85 { monitor.externalFlags.insert(.memory) } else { monitor.externalFlags.remove(.memory) }
        if s.budgetFraction >= 1.2 {
            showToast("Scan size limit reached. Stopping to keep memory in check.")
            stopScan()
        }
    }

    private func handleMemoryWarning() {
        guard phase == .scanning else { return }
        showToast("iOS reported low memory. Finishing the scan now.")
        stopScan()
    }

    func stopScan() {
        guard phase == .scanning else { return }
        stopScanTimer()
        phase = .extracting
        let anchors = arView.session.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
        let captureRegion = self.region
        let captureScope = self.scope
        let keyframes = recorder?.records ?? []
        let directory = recorder?.directory ?? ModelStore.temporaryRoot
        // Freeze the session: the anchors we hold keep their buffers alive while we copy.
        arView.session.pause()
        isRunning = false
        UIApplication.shared.isIdleTimerDisabled = false

        // Strong capture: the controller is main-actor isolated (Sendable) and outlives this task.
        Task.detached(priority: .userInitiated) { [self] in
            let mesh = MeshExtractor.extract(anchors, region: captureRegion)
            let snapshot = CaptureSnapshot(rawMesh: mesh, keyframes: keyframes, keyframeDirectory: directory, region: captureRegion, scope: captureScope)
            await MainActor.run {
                if mesh.isEmpty {
                    self.phase = .failed("No LiDAR mesh was captured. Scan surfaces 0.3–3 m away and move slowly so the mesh can build up.")
                    Haptics.error()
                } else {
                    self.snapshot = snapshot
                    self.options.removeSupportSurface = captureScope == .object
                    self.options.cropToRegion = captureScope == .object
                    self.phase = .review
                    Haptics.success()
                }
            }
        }
    }

    var rawTriangleCount: Int { snapshot?.rawMesh.triangleCount ?? 0 }
    var keyframeCount: Int { snapshot?.keyframes.count ?? 0 }
    var hasRegion: Bool { snapshot?.region != nil }

    // MARK: Processing

    func process() {
        guard let snapshot, phase == .review || phase == .preview else { return }
        discardProcessed()
        phase = .processing
        progress = PipelineProgress(stage: "Starting", fraction: 0)
        let runOptions = self.options
        processingTask = Task.detached(priority: .userInitiated) { [self] in
            let report: ModelPipeline.Progress = { stage, fraction in
                Task { @MainActor in self.progress = PipelineProgress(stage: stage, fraction: fraction) }
            }
            do {
                let model = try ModelPipeline.run(snapshot, options: runOptions, progress: report)
                await MainActor.run {
                    self.processed = model
                    self.progress = nil
                    self.phase = .preview
                    Haptics.success()
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.progress = nil
                    self.phase = .review
                }
            } catch {
                await MainActor.run {
                    self.progress = nil
                    self.phase = .failed(error.localizedDescription)
                    Haptics.error()
                }
            }
        }
    }

    func cancelProcessing() {
        processingTask?.cancel()
    }

    /// Back from the preview (or an error) to tweak options.
    func adjust() {
        guard phase == .preview || isFailed else { return }
        if snapshot == nil {
            finishCapture()
        } else {
            phase = .review
        }
    }

    var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    @discardableResult
    func save(name: String, context: ModelContext) -> Bool {
        guard let processed else { return false }
        let id = UUID()
        do {
            let folderName = try ModelStore.adopt(temporaryFolder: processed.folder, id: id)
            let record = SavedModel(id: id, name: name, createdAt: Date(), folderName: folderName, stats: processed.stats, scope: snapshot?.scope ?? scope)
            context.insert(record)
            try context.save()
        } catch {
            showToast("Couldn't save the model: \(error.localizedDescription)")
            Haptics.error()
            return false
        }
        self.processed = nil
        Haptics.success()
        showToast("Saved “\(name)” to the library")
        finishCapture()
        return true
    }

    /// Discard the scan entirely and return to setup.
    func discard() {
        processingTask?.cancel()
        discardProcessed()
        finishCapture()
    }

    private func discardProcessed() {
        if let processed { try? FileManager.default.removeItem(at: processed.folder) }
        processed = nil
    }

    private func finishCapture() {
        recorder?.discard()
        recorder = nil
        if let dir = snapshot?.keyframeDirectory { try? FileManager.default.removeItem(at: dir) }
        snapshot = nil
        regionBase = nil
        stats = ScanStats()
        phase = .setup
        regionChanged()
        monitor.reset()
        runSession(reset: true)
    }

    // MARK: Toast

    func showToast(_ message: String) {
        toast = message
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if self?.toast == message { self?.toast = nil }
        }
    }
}
