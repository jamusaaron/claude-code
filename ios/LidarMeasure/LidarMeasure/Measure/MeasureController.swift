import ARKit
import Combine
import RealityKit
import SwiftData
import UIKit
import MeasureCore

/// Owns the measuring AR session: resolves the reticle, places anchored points, keeps values
/// live as ARKit refines anchors, and surfaces warnings.
@MainActor
final class MeasureController: NSObject, ObservableObject, ARSessionEventHandling {
    // MARK: Published state

    @Published var kind: MeasurementKind = .distance {
        didSet { if oldValue != kind { switchKind() } }
    }
    @Published var rectangleAssist = false
    @Published private(set) var active = Measurement(kind: .distance)
    @Published private(set) var completed: [Measurement] = []
    @Published private(set) var reticle: ResolvedPoint?
    @Published private(set) var readout: Readout?
    @Published private(set) var warnings: [EnvironmentWarning] = []
    @Published private(set) var tracking: TrackingStatus = .initialising
    @Published private(set) var confidenceImage: CGImage?
    @Published var sessionError: SessionErrorInfo?
    @Published var toast: String?

    let arView: ARView

    // MARK: Private

    private let delegateProxy = ARSessionDelegateProxy()
    private let renderer: MeasurementRenderer
    private let resolver: SurfaceResolver
    private let monitor = EnvironmentMonitor()
    private let coaching = ARCoachingOverlayView()
    private weak var settings: AppSettings?
    private var frameCounter = 0
    private var isRunning = false
    private var hasRunOnce = false
    private var lastSnap: SnapKind?
    private var countersByKind: [MeasurementKind: Int] = [:]
    private static let anchorPrefix = "lm.point."

    override init() {
        arView = ARConfigurationFactory.makeARView()
        renderer = MeasurementRenderer(arView: arView)
        resolver = SurfaceResolver(arView: arView)
        super.init()

        delegateProxy.target = self
        arView.session.delegate = delegateProxy

        coaching.session = arView.session
        coaching.goal = .tracking
        coaching.activatesAutomatically = true
        coaching.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        coaching.frame = arView.bounds
        arView.addSubview(coaching)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        arView.addGestureRecognizer(tap)
    }

    // MARK: Session lifecycle

    func attach(settings: AppSettings) {
        self.settings = settings
        applyDisplaySettings()
    }

    func applyDisplaySettings() {
        guard let settings else { return }
        // Collision lets RealityKit ray-cast against the LiDAR mesh; occlusion hides lines behind real objects.
        var options: ARView.Environment.SceneUnderstanding.Options = [.collision]
        if settings.occlusionEnabled { options.insert(.occlusion) }
        arView.environment.sceneUnderstanding.options = options
        if settings.showMeshOverlay {
            arView.debugOptions.insert(.showSceneUnderstanding)
        } else {
            arView.debugOptions.remove(.showSceneUnderstanding)
        }
        if !settings.showConfidenceOverlay { confidenceImage = nil }
        refreshLive()
    }

    func start() {
        guard !isRunning, DeviceCapabilities.hasLiDAR else { return }
        let options: ARSession.RunOptions = hasRunOnce ? [] : [.resetTracking, .removeExistingAnchors, .resetSceneReconstruction]
        arView.session.run(ARConfigurationFactory.measurement(), options: options)
        hasRunOnce = true
        isRunning = true
        UIApplication.shared.isIdleTimerDisabled = true
        Haptics.prepare()
    }

    func pause() {
        guard isRunning else { return }
        arView.session.pause()
        isRunning = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Full reset: clears all points and restarts tracking and reconstruction.
    func restartSession() {
        clearAll()
        monitor.reset()
        resolver.meshIndex.reset()
        arView.session.run(ARConfigurationFactory.measurement(), options: [.resetTracking, .removeExistingAnchors, .resetSceneReconstruction])
        hasRunOnce = true
        isRunning = true
        sessionError = nil
    }

    // MARK: ARSessionEventHandling

    func sessionDidUpdate(frame: ARFrame) {
        frameCounter &+= 1
        if frameCounter % 3 == 0 { updateReticle(frame) }      // ~20 Hz
        if frameCounter % 12 == 0 { updateEnvironment(frame) } // ~5 Hz
    }

    func sessionDidChange(anchors: [ARAnchor], removed: Bool) {
        if removed {
            resolver.meshIndex.forget(anchors.compactMap { ($0 as? ARMeshAnchor)?.identifier })
            return
        }
        // ARKit refines anchor poses as its map improves; follow them so values stay correct.
        var moved = false
        for anchor in anchors {
            guard let name = anchor.name, name.hasPrefix(Self.anchorPrefix) else { continue }
            let p = anchor.transform.origin
            if updatePoint(anchorID: anchor.identifier, to: p) { moved = true }
        }
        if moved { refreshLive() }
    }

    func sessionTrackingChanged(_ status: TrackingStatus) {
        tracking = status
    }

    func sessionFailed(_ error: Error) {
        isRunning = false
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

    // MARK: Reticle & live values

    private var screenCentre: CGPoint { CGPoint(x: arView.bounds.midX, y: arView.bounds.midY) }

    private var snapOptions: SnapOptions {
        SnapOptions(planes: settings?.snapToPlanes ?? true, edges: settings?.snapToEdges ?? true, points: settings?.snapToPoints ?? true)
    }

    private func updateReticle(_ frame: ARFrame) {
        let resolved = resolver.resolve(at: screenCentre, frame: frame, options: snapOptions, existingPoints: snapCandidates())
        if let snap = resolved?.snap, snap != lastSnap, [.edge, .corner, .point].contains(snap) { Haptics.snapped() }
        lastSnap = resolved?.snap
        reticle = resolved
        renderer.updateReticle(resolved, cameraPosition: frame.camera.transform.origin)
        refreshLive()
    }

    private func updateEnvironment(_ frame: ARFrame) {
        let centre = DepthSampler.sample(frame: frame, viewPoint: screenCentre, viewportSize: arView.bounds.size, orientation: UIApplication.shared.activeInterfaceOrientation)
        let stats = DepthSampler.centralStats(frame: frame)
        let w = monitor.evaluate(frame: frame, centre: centre, stats: stats)
        if w != warnings { warnings = w }
        if settings?.showConfidenceOverlay == true {
            confidenceImage = DepthSampler.confidenceOverlay(frame: frame)
        }
    }

    private var previewPoint: MeasurementPoint? {
        reticle.map { MeasurementPoint(anchorID: nil, resolved: $0) }
    }

    private func refreshLive() {
        let formatter = settings?.formatter ?? MetricFormatter()
        let preview = previewPoint
        if let r = active.result(preview: preview) {
            readout = Readout.make(for: r, formatter: formatter, isLive: true)
        } else if active.isEmpty, let last = completed.last, let r = last.result() {
            readout = Readout.make(for: r, formatter: formatter, isLive: false)
        } else {
            readout = nil
        }
        renderer.render(completed: completed, active: active, preview: preview, formatter: formatter, highContrast: settings?.highContrastHUD ?? false)
    }

    var hint: String { active.nextStepHint }

    /// The measurement the Save button acts on: the most recent completed one not yet saved.
    var saveCandidate: Measurement? { completed.last { $0.savedRecordID == nil } }

    var canUndo: Bool { !active.isEmpty || !completed.isEmpty }

    var canClosePolygon: Bool {
        (active.kind == .area || (active.kind == .volume && !active.isClosed)) && active.points.count >= 3
    }

    /// Existing points the reticle may snap onto: every completed point, plus the first point
    /// of the outline being traced (to close it). Never the point just placed.
    private func snapCandidates() -> [(PointReference, SIMD3<Float>)] {
        var out: [(PointReference, SIMD3<Float>)] = []
        for m in completed {
            for (i, p) in m.allPoints.enumerated() { out.append((PointReference(measurementID: m.id, index: i), p.position)) }
        }
        if canClosePolygon, let first = active.points.first {
            out.append((PointReference(measurementID: active.id, index: 0), first.position))
        }
        return out
    }

    // MARK: Placing points

    func addPointAtReticle() {
        guard let frame = arView.session.currentFrame else { return }
        let resolved = resolver.resolve(at: screenCentre, frame: frame, options: snapOptions, existingPoints: snapCandidates())
        place(resolved)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let frame = arView.session.currentFrame else { return }
        let location = gesture.location(in: arView)
        let resolved = resolver.resolve(at: location, frame: frame, options: snapOptions, existingPoints: snapCandidates())
        place(resolved)
    }

    private func place(_ resolved: ResolvedPoint?) {
        guard let r = resolved else {
            Haptics.warning()
            showToast("No surface found. Aim at a surface within about 5 m.")
            return
        }
        if tracking.quality != .normal { showToast("Tracking is limited, so this point may drift.") }

        // Tapping the first point of an outline closes it.
        if canClosePolygon, let ref = r.existingPoint, ref.measurementID == active.id, ref.index == 0 {
            closePolygon()
            return
        }

        let point = makeAnchoredPoint(r)
        switch active.kind {
        case .distance:
            active.points.append(point)
            Haptics.pointPlaced()
            if active.points.count == 2 { complete() }
        case .area:
            active.points.append(point)
            Haptics.pointPlaced()
            if rectangleAssist && active.points.count == 3 { completeRectangle() }
        case .volume:
            if !active.isClosed {
                active.points.append(point)
                Haptics.pointPlaced()
                if rectangleAssist && active.points.count == 3 { completeRectangle() }
            } else {
                active.top = point
                complete()
            }
        }
        refreshLive()
    }

    func closePolygon() {
        guard canClosePolygon else { return }
        active.isClosed = true
        if active.kind == .area { complete() } else { Haptics.pointPlaced() }
        refreshLive()
    }

    /// 3-point rectangle helper: completes the parallelogram from three corners.
    private func completeRectangle() {
        let p = active.points
        let fourth = PolygonGeometry.completeParallelogram(p[0].position.asDouble, p[1].position.asDouble, p[2].position.asDouble)[3].asFloat
        let worst = p.max { $0.sigma < $1.sigma } ?? p[2]
        let resolved = ResolvedPoint(position: fourth, normal: nil, snap: worst.snap, confidence: worst.confidence,
                                     range: worst.range, sigma: worst.sigma * 1.4, existingPoint: nil, edgeDirection: nil, nearDepthEdge: false)
        active.points.append(makeAnchoredPoint(resolved))
        closePolygon()
    }

    private func makeAnchoredPoint(_ r: ResolvedPoint) -> MeasurementPoint {
        // If snapped onto an existing point, reuse its exact position and uncertainty.
        var resolved = r
        if let ref = r.existingPoint, let existing = point(for: ref) {
            resolved.position = existing.position
            resolved.sigma = existing.sigma
            resolved.confidence = existing.confidence
        }
        let anchor = ARAnchor(name: Self.anchorPrefix + UUID().uuidString, transform: simd_float4x4(translation: resolved.position))
        arView.session.add(anchor: anchor)
        return MeasurementPoint(anchorID: anchor.identifier, resolved: resolved)
    }

    private func complete() {
        let finished = active
        completed.append(finished)
        countersByKind[finished.kind, default: 0] += 1
        active = Measurement(kind: kind)
        Haptics.success()
    }

    private func switchKind() {
        // Abandon an unfinished measurement of the previous kind.
        removeAnchors(of: active)
        active = Measurement(kind: kind)
        refreshLive()
    }

    // MARK: Editing

    func undo() {
        if !active.isEmpty {
            if active.top != nil {
                if let id = active.top?.anchorID { removeAnchor(id) }
                active.top = nil
            } else if active.isClosed {
                active.isClosed = false
            } else if let last = active.points.popLast(), let id = last.anchorID {
                removeAnchor(id)
            }
        } else if let last = completed.popLast() {
            removeAnchors(of: last)
        }
        Haptics.tick()
        refreshLive()
    }

    func clearAll() {
        removeAnchors(of: active)
        for m in completed { removeAnchors(of: m) }
        completed.removeAll()
        active = Measurement(kind: kind)
        renderer.removeAll()
        refreshLive()
    }

    private func removeAnchors(of m: Measurement) {
        for p in m.allPoints { if let id = p.anchorID { removeAnchor(id) } }
    }

    private func removeAnchor(_ id: UUID) {
        guard let anchor = arView.session.currentFrame?.anchors.first(where: { $0.identifier == id }) else { return }
        arView.session.remove(anchor: anchor)
    }

    private func point(for ref: PointReference) -> MeasurementPoint? {
        if ref.measurementID == active.id { return active.allPoints.indices.contains(ref.index) ? active.allPoints[ref.index] : nil }
        guard let m = completed.first(where: { $0.id == ref.measurementID }), m.allPoints.indices.contains(ref.index) else { return nil }
        return m.allPoints[ref.index]
    }

    /// Moves every point backed by `anchorID`; returns true if anything moved by more than 0.5 mm.
    private func updatePoint(anchorID: UUID, to p: SIMD3<Float>) -> Bool {
        func apply(_ m: inout Measurement) -> Bool {
            var changed = false
            for i in m.points.indices where m.points[i].anchorID == anchorID {
                if simd_distance(m.points[i].position, p) > 0.0005 { m.points[i].position = p; changed = true }
            }
            if var top = m.top, top.anchorID == anchorID, simd_distance(top.position, p) > 0.0005 {
                top.position = p
                m.top = top
                changed = true
            }
            return changed
        }
        var moved = apply(&active)
        for i in completed.indices { if apply(&completed[i]) { moved = true } }
        return moved
    }

    // MARK: Saving

    func defaultName(for m: Measurement) -> String {
        let n = completed.filter { $0.kind == m.kind }.firstIndex { $0.id == m.id }.map { $0 + 1 } ?? (countersByKind[m.kind] ?? 1)
        return "\(m.kind.title) \(n)"
    }

    @discardableResult
    func save(_ measurement: Measurement, name: String, notes: String, in context: ModelContext) -> Bool {
        guard let result = measurement.result() else { return false }
        let record = SavedMeasurement(measurement: measurement, result: result, name: name, notes: notes)
        context.insert(record)
        do {
            try context.save()
        } catch {
            showToast("Couldn't save: \(error.localizedDescription)")
            Haptics.error()
            return false
        }
        if let i = completed.firstIndex(where: { $0.id == measurement.id }) {
            completed[i].savedRecordID = record.id
            completed[i].savedName = name
        }
        Haptics.success()
        showToast("Saved “\(name)”")
        refreshLive()
        return true
    }

    // MARK: Toast

    func showToast(_ message: String) {
        toast = message
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if self?.toast == message { self?.toast = nil }
        }
    }
}

extension simd_float4x4 {
    init(translation t: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.3 = SIMD4(t.x, t.y, t.z, 1)
    }
}
