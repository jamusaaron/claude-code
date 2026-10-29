import ARKit
import Combine
import RealityKit
import SwiftData
import UIKit
import MeasureCore

/// The Measure mode on the shared AR session: resolves the reticle, places anchored points,
/// keeps values live as ARKit refines anchors and the LiDAR mesh improves, and surfaces warnings.
@MainActor
final class MeasureController: NSObject, ObservableObject, ARModeHandling {
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

    let host: ARSessionHost
    var arView: ARView { host.arView }

    // MARK: Limits

    /// Taps closer than this to the previous point are almost always accidental double taps.
    static let minimumPointSpacing: Float = 0.005
    static let maximumCorners = 64
    /// A prism needs a real height; below this the top point is on the base itself.
    static let minimumHeight = 0.005

    // MARK: Private

    private let renderer: MeasurementRenderer
    private let resolver: SurfaceResolver
    private let monitor = EnvironmentMonitor()
    private weak var settings: AppSettings?
    private var frameCounter = 0
    private var lastSnap: SnapKind?
    private var countersByKind: [MeasurementKind: Int] = [:]
    private var refinementCursor = 0
    /// Set when the camera stopped with points on screen; cleared once tracking is normal again.
    private var resumedAfterPause = false
    private static let anchorPrefix = "lm.point."

    init(host: ARSessionHost) {
        self.host = host
        renderer = MeasurementRenderer(arView: host.arView)
        resolver = SurfaceResolver(arView: host.arView)
        super.init()
        renderer.setVisible(false)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        host.arView.addGestureRecognizer(tap)
    }

    private var isOnScreen: Bool { host.activeMode == .measure }

    // MARK: Settings

    func attach(settings: AppSettings) {
        self.settings = settings
        if isOnScreen { applyDisplaySettings() }
    }

    func applyDisplaySettings() {
        guard let settings, isOnScreen else { return }
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

    /// Full reset: new world origin, all on-screen points cleared (saved items are untouched).
    func restartSession() {
        host.restartTracking()
        sessionError = nil
    }

    // MARK: ARModeHandling

    func modeDidActivate() {
        renderer.setVisible(true)
        applyDisplaySettings()
    }

    func modeDidDeactivate() {
        renderer.setVisible(false)
        reticle = nil
    }

    func sessionWillPause() {
        // ARKit relocalises after a pause, but if it can't, old points sit in a different
        // world. Flag it until tracking is normal again so the user re-checks before saving.
        if !active.isEmpty || !completed.isEmpty { resumedAfterPause = true }
    }

    func worldWillReset() {
        clearAll()
        monitor.reset()
        resolver.meshIndex.reset()
        resumedAfterPause = false
    }

    func sessionDidUpdate(frame: ARFrame) {
        frameCounter &+= 1
        if frameCounter % 3 == 0 { updateReticle(frame) }       // ~20 Hz
        if frameCounter % 12 == 0 { updateEnvironment(frame) }  // ~5 Hz
        if frameCounter % 24 == 0 { refineStep(frame) }         // ~2.5 Hz
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
            if updatePoint(anchorID: anchor.identifier, to: anchor.transform.origin) { moved = true }
        }
        if moved && isOnScreen { refreshLive() }
    }

    func sessionTrackingChanged(_ status: TrackingStatus) {
        tracking = status
        if status.quality == .normal && resumedAfterPause {
            resumedAfterPause = false
            monitor.externalFlags.insert(.interrupted)
            clearInterruptedFlagSoon()
        }
    }

    func sessionFailed(_ error: Error) {
        sessionError = SessionErrorInfo(error)
        Haptics.error()
    }

    func sessionInterrupted(_ interrupted: Bool) {
        if interrupted {
            monitor.externalFlags.insert(.interrupted)
        } else {
            clearInterruptedFlagSoon()
        }
    }

    private func clearInterruptedFlagSoon() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            self?.monitor.externalFlags.remove(.interrupted)
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

    /// The latest completed measurement's points, for fitting a capture box in Scan.
    var lastCompletedPoints: [SIMD3<Float>]? {
        guard let m = completed.last else { return nil }
        var points = m.allPoints.map(\.position)
        if let top = m.prismTop(preview: nil) { points += top }
        return points.count >= 2 ? points : nil
    }

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
        guard isOnScreen, let frame = arView.session.currentFrame else { return }
        let resolved = resolver.resolve(at: screenCentre, frame: frame, options: snapOptions, existingPoints: snapCandidates())
        place(resolved)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard isOnScreen, gesture.state == .ended, let frame = arView.session.currentFrame else { return }
        let location = gesture.location(in: arView)
        let resolved = resolver.resolve(at: location, frame: frame, options: snapOptions, existingPoints: snapCandidates())
        place(resolved)
    }

    private func reject(_ message: String) {
        Haptics.warning()
        showToast(message)
    }

    private func place(_ resolved: ResolvedPoint?) {
        // Points placed while tracking is limited are in a world that may still shift.
        guard tracking.quality == .normal else {
            reject("Wait for stable tracking (\(tracking.title.lowercased())) before placing points.")
            return
        }
        guard let r = resolved else {
            reject("No reliable LiDAR surface here. Move within 0.15–5 m, or try another angle. Glass and thin edges often don't return depth.")
            return
        }

        // Tapping the first point of an outline closes it.
        if canClosePolygon, let ref = r.existingPoint, ref.measurementID == active.id, ref.index == 0 {
            closePolygon()
            return
        }

        if let last = (active.top ?? active.points.last), simd_distance(last.position, r.position) < Self.minimumPointSpacing {
            reject("That's the same spot as the last point. Move the crosshair, or use Undo.")
            return
        }

        switch active.kind {
        case .distance:
            active.points.append(makeAnchoredPoint(r))
            Haptics.pointPlaced()
            if active.points.count == 2 { complete() }
        case .area:
            guard addCorner(r) else { return }
            if rectangleAssist && active.points.count == 3 { completeRectangle() }
        case .volume:
            if !active.isClosed {
                guard addCorner(r) else { return }
                if rectangleAssist && active.points.count == 3 { completeRectangle() }
            } else {
                let candidate = MeasurementPoint(anchorID: nil, resolved: r)
                guard let prism = VolumeGeometry.prism(base: active.points.map { $0.position.asDouble }, top: candidate.position.asDouble),
                      prism.height >= Self.minimumHeight else {
                    reject("The top point is on the base. Aim at the opposite surface (top or ceiling).")
                    return
                }
                active.top = makeAnchoredPoint(r)
                complete()
            }
        }
        refreshLive()
    }

    private func addCorner(_ r: ResolvedPoint) -> Bool {
        guard active.points.count < Self.maximumCorners else {
            reject("An outline can have at most \(Self.maximumCorners) corners. Close it to continue.")
            return false
        }
        active.points.append(makeAnchoredPoint(r))
        Haptics.pointPlaced()
        return true
    }

    func closePolygon() {
        guard canClosePolygon else { return }
        // Refuse crossing, touching, duplicate or collinear outlines rather than report a
        // number that means nothing.
        if let issue = PolygonGeometry.validate(active.points.map { $0.position.asDouble }) {
            reject(issue.message)
            return
        }
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

    // MARK: Refinement

    /// Re-samples up to two free-surface points per tick along the current view ray. As ARKit
    /// fuses more depth, the surface under an early, noisy point becomes better known; each
    /// pass blends 20% toward the new hit, never more than 2 cm from the anchor.
    private func refineStep(_ frame: ARFrame) {
        guard tracking.quality == .normal else { return }
        var targets: [(measurement: Int?, index: Int)] = [] // nil measurement = active
        for (i, p) in active.points.enumerated() where p.isRefinable { targets.append((nil, i)) }
        for (m, measurement) in completed.enumerated() {
            for (i, p) in measurement.points.enumerated() where p.isRefinable { targets.append((m, i)) }
        }
        guard !targets.isEmpty else { return }
        let options = SnapOptions(planes: false, edges: false, points: false)
        var changed = false
        for _ in 0..<min(2, targets.count) {
            let target = targets[refinementCursor % targets.count]
            refinementCursor &+= 1
            let point = target.measurement.map { completed[$0].points[target.index] } ?? active.points[target.index]
            guard let screen = resolver.project(point.position, frame: frame),
                  arView.bounds.contains(screen),
                  let hit = resolver.resolve(at: screen, frame: frame, options: options, existingPoints: []),
                  hit.snap == .mesh || hit.snap == .depth
            else { continue }
            let offset = hit.position - point.anchorPosition
            guard simd_length(offset) <= MeasurementPoint.maximumRefinement else { continue }
            var refinement = point.refinement * 0.8 + offset * 0.2
            let length = simd_length(refinement)
            if length > MeasurementPoint.maximumRefinement { refinement *= MeasurementPoint.maximumRefinement / length }
            guard simd_distance(refinement, point.refinement) > 0.0003 else { continue }
            if let m = target.measurement {
                completed[m].points[target.index].refinement = refinement
            } else {
                active.points[target.index].refinement = refinement
            }
            changed = true
        }
        if changed { refreshLive() }
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
                if simd_distance(m.points[i].anchorPosition, p) > 0.0005 { m.points[i].anchorPosition = p; changed = true }
            }
            if var top = m.top, top.anchorID == anchorID, simd_distance(top.anchorPosition, p) > 0.0005 {
                top.anchorPosition = p
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
