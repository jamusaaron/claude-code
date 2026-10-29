import ARKit
import Combine
import RealityKit
import UIKit
import MeasureCore

/// Draws measurements in the AR scene with RealityKit, plus screen-space value labels.
///
/// Points and lines are unlit primitives whose thickness is rescaled every frame from their
/// distance to the camera, so they read the same on screen at 30 cm and at 4 m.
@MainActor
final class MeasurementRenderer {
    private enum ScaleKind {
        case point
        case line(length: Float)
        case reticle
    }

    private struct Scalable {
        let entity: ModelEntity
        let kind: ScaleKind
    }

    private weak var arView: ARView?
    private let root = AnchorEntity(world: .zero)
    let labelOverlay = LabelOverlayView(frame: .zero)

    private var completedEntities: [UUID: (signature: [Float], entity: Entity, scalables: [Scalable])] = [:]
    private var activeEntity: Entity?
    private var activeScalables: [Scalable] = []
    private let reticle: ModelEntity
    private var reticleGrade: ConfidenceGrade?
    private let edgeGuide: ModelEntity
    private var updateSubscription: Cancellable?

    private static let sphereMesh = MeshResource.generateSphere(radius: 1)
    private static let boxMesh = MeshResource.generateBox(size: 1)
    private static let discMesh = MeshResource.generatePlane(width: 1, depth: 1, cornerRadius: 0.5)

    init(arView: ARView) {
        var reticleMaterial = UnlitMaterial(color: .white)
        reticleMaterial.blending = .transparent(opacity: .init(scale: 0.55))
        let reticleEntity = ModelEntity(mesh: Self.discMesh, materials: [reticleMaterial])
        reticleEntity.isEnabled = false
        let guide = ModelEntity(mesh: Self.boxMesh, materials: [UnlitMaterial(color: Theme.uiAccent)])
        guide.isEnabled = false
        self.reticle = reticleEntity
        self.edgeGuide = guide
        self.arView = arView

        root.addChild(reticle)
        root.addChild(edgeGuide)
        arView.scene.addAnchor(root)

        labelOverlay.frame = arView.bounds
        labelOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        arView.addSubview(labelOverlay)

        updateSubscription = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            self?.perFrame()
        }
    }

    func removeAll() {
        for entry in completedEntities.values { entry.entity.removeFromParent() }
        completedEntities.removeAll()
        activeEntity?.removeFromParent()
        activeEntity = nil
        activeScalables = []
        labelOverlay.setSpecs([], highContrast: false)
    }

    // MARK: Measurements

    func render(completed: [Measurement], active: Measurement?, preview: MeasurementPoint?, formatter: MetricFormatter, highContrast: Bool) {
        let ids = Set(completed.map(\.id))
        for (id, entry) in completedEntities where !ids.contains(id) {
            entry.entity.removeFromParent()
            completedEntities[id] = nil
        }
        for m in completed {
            let signature = Self.signature(m)
            if let existing = completedEntities[m.id], existing.signature == signature { continue }
            completedEntities[m.id]?.entity.removeFromParent()
            let built = build(m, preview: nil, isActive: false)
            root.addChild(built.entity)
            completedEntities[m.id] = (signature, built.entity, built.scalables)
        }

        activeEntity?.removeFromParent()
        activeEntity = nil
        activeScalables = []
        if let active, !active.isEmpty {
            let built = build(active, preview: preview, isActive: true)
            root.addChild(built.entity)
            activeEntity = built.entity
            activeScalables = built.scalables
        }

        var specs: [LabelOverlayView.Spec] = []
        for m in completed { specs += labelSpecs(m, preview: nil, formatter: formatter, isActive: false) }
        if let active { specs += labelSpecs(active, preview: preview, formatter: formatter, isActive: true) }
        labelOverlay.setSpecs(specs, highContrast: highContrast)
        perFrame()
    }

    private static func signature(_ m: Measurement) -> [Float] {
        var s: [Float] = [Float(m.points.count), m.isClosed ? 1 : 0]
        for p in m.allPoints { s += [p.position.x, p.position.y, p.position.z, Float(p.sigma)] }
        return s
    }

    private func build(_ m: Measurement, preview: MeasurementPoint?, isActive: Bool) -> (entity: Entity, scalables: [Scalable]) {
        let group = Entity()
        var scalables: [Scalable] = []
        let result = m.result(preview: preview)
        let color: UIColor = result.map { Theme.uiColor(for: $0.grade) } ?? Theme.uiAccent
        let solid = UnlitMaterial(color: color)
        var faint = UnlitMaterial(color: color)
        faint.blending = .transparent(opacity: .init(scale: 0.45))

        func addPoint(_ p: SIMD3<Float>, material: Material) {
            let e = ModelEntity(mesh: Self.sphereMesh, materials: [material])
            e.position = p
            group.addChild(e)
            scalables.append(Scalable(entity: e, kind: .point))
        }
        func addLine(_ a: SIMD3<Float>, _ b: SIMD3<Float>, material: Material) {
            let d = b - a
            let length = simd_length(d)
            guard length > 1e-4 else { return }
            let e = ModelEntity(mesh: Self.boxMesh, materials: [material])
            e.position = (a + b) / 2
            e.orientation = Self.rotation(from: SIMD3(0, 0, 1), to: d / length)
            e.scale = SIMD3(0.002, 0.002, length)
            group.addChild(e)
            scalables.append(Scalable(entity: e, kind: .line(length: length)))
        }

        let positions = m.points.map(\.position)
        for p in positions { addPoint(p, material: solid) }
        if positions.count >= 2 {
            for i in 0..<(positions.count - 1) { addLine(positions[i], positions[i + 1], material: solid) }
        }
        if m.isClosed, positions.count >= 3 { addLine(positions[positions.count - 1], positions[0], material: solid) }

        // Rubber band from the last point to the reticle.
        if isActive, let preview, !m.isComplete {
            if !(m.kind == .volume && m.isClosed), let last = positions.last {
                addLine(last, preview.position, material: faint)
                if m.kind != .distance, positions.count >= 2 { addLine(preview.position, positions[0], material: faint) }
            }
        }

        // Area fill (closed outline, or live outline including the preview point).
        var outline = positions
        if !m.isClosed, isActive, let preview, m.kind != .distance { outline.append(preview.position) }
        if m.kind != .distance, outline.count >= 3, let fill = fillEntity(outline, color: color) {
            group.addChild(fill)
        }

        // Volume prism.
        if let top = m.prismTop(preview: isActive ? preview : nil) {
            let mat: Material = m.top == nil ? faint : solid
            for i in 0..<top.count {
                addLine(top[i], top[(i + 1) % top.count], material: mat)
                addLine(positions[i], top[i], material: mat)
            }
            if let topPoint = m.top { addPoint(topPoint.position, material: solid) }
        }
        return (group, scalables)
    }

    private func fillEntity(_ points: [SIMD3<Float>], color: UIColor) -> ModelEntity? {
        let triangles = PolygonGeometry.triangulate(points.map(\.asDouble))
        guard !triangles.isEmpty else { return nil }
        // Lift 2 mm off the surface to avoid z-fighting with the scene mesh.
        let normal = Vec.normalize(PolygonGeometry.newellVector(points.map(\.asDouble))).asFloat
        let lifted = points.map { $0 + normal * 0.002 }
        var indices: [UInt32] = triangles.map { UInt32($0) }
        for t in stride(from: 0, to: triangles.count, by: 3) {
            indices += [UInt32(triangles[t]), UInt32(triangles[t + 2]), UInt32(triangles[t + 1])] // back faces
        }
        var descriptor = MeshDescriptor(name: "fill")
        descriptor.positions = MeshBuffers.Positions(lifted)
        descriptor.primitives = .triangles(indices)
        guard let mesh = try? MeshResource.generate(from: [descriptor]) else { return nil }
        var material = UnlitMaterial(color: color)
        material.blending = .transparent(opacity: .init(scale: 0.22))
        return ModelEntity(mesh: mesh, materials: [material])
    }

    // MARK: Labels

    private func labelSpecs(_ m: Measurement, preview: MeasurementPoint?, formatter f: MetricFormatter, isActive: Bool) -> [LabelOverlayView.Spec] {
        var specs: [LabelOverlayView.Spec] = []
        let key = m.id.uuidString
        let result = m.result(preview: isActive ? preview : nil)
        let color: UIColor = result.map { Theme.uiColor(for: $0.grade) } ?? Theme.uiAccent

        if let r = result {
            var text: String
            switch r.kind {
            case .distance: text = f.formatLength(r.value, uncertainty: r.sigma)
            case .area: text = f.formatArea(r.value, uncertainty: r.sigma)
            case .volume: text = f.formatVolume(r.value, uncertainty: r.sigma)
            }
            if !isActive { text += "  " + Self.uncertaintyText(r, f) }
            if m.savedRecordID != nil { text = "✓ " + text }
            specs.append(.init(id: key + ".main", text: text, world: r.labelAnchor.asFloat, color: color, prominent: true))

            if r.kind != .distance {
                for (i, seg) in r.segments.enumerated() {
                    specs.append(.init(id: key + ".seg\(i)", text: f.formatLength(seg.length, uncertainty: seg.sigma), world: seg.midpoint.asFloat, color: color, prominent: false))
                }
            }
            if r.kind == .volume, let h = r.height, let top = m.prismTop(preview: isActive ? preview : nil), let base = m.points.first {
                let mid = (base.position + top[0]) / 2
                specs.append(.init(id: key + ".height", text: "↕ " + f.formatLength(h), world: mid, color: color, prominent: false))
            }
        }
        // While tracing an outline, show the length of the segment being drawn.
        if isActive, let seg = m.previewSegment(to: preview), m.kind != .distance {
            specs.append(.init(id: key + ".live", text: f.formatLength(seg.length, uncertainty: seg.sigma), world: seg.midpoint.asFloat, color: Theme.uiAccent, prominent: false))
        }
        return specs
    }

    private static func uncertaintyText(_ r: MeasurementResult, _ f: MetricFormatter) -> String {
        switch r.kind {
        case .distance: return f.formatLengthUncertainty(r.sigma)
        case .area: return f.formatAreaUncertainty(r.sigma, forValue: r.value)
        case .volume: return f.formatVolumeUncertainty(r.sigma, forValue: r.value)
        }
    }

    // MARK: Reticle

    func updateReticle(_ resolved: ResolvedPoint?, cameraPosition: SIMD3<Float>) {
        guard let r = resolved else {
            reticle.isEnabled = false
            edgeGuide.isEnabled = false
            return
        }
        let towardCamera = simd_normalize(cameraPosition - r.position)
        var normal = towardCamera
        if let n = r.normal {
            let u = simd_normalize(n)
            if u.x.isFinite && u.y.isFinite && u.z.isFinite { normal = simd_dot(u, towardCamera) < 0 ? -u : u }
        }
        reticle.isEnabled = true
        reticle.position = r.position + normal * 0.001
        reticle.orientation = Self.rotation(from: SIMD3(0, 1, 0), to: normal)
        if reticleGrade != r.grade {
            reticleGrade = r.grade
            var material = UnlitMaterial(color: Theme.uiColor(for: r.grade))
            material.blending = .transparent(opacity: .init(scale: 0.55))
            reticle.model?.materials = [material]
        }
        if let dir = r.edgeDirection, r.snap == .edge {
            edgeGuide.isEnabled = true
            edgeGuide.position = r.position
            edgeGuide.orientation = Self.rotation(from: SIMD3(0, 0, 1), to: simd_normalize(dir))
        } else {
            edgeGuide.isEnabled = false
        }
    }

    // MARK: Per-frame

    private func perFrame() {
        guard let arView else { return }
        let camera = arView.cameraTransform
        let cameraPosition = camera.translation
        let forward = -SIMD3(camera.matrix.columns.2.x, camera.matrix.columns.2.y, camera.matrix.columns.2.z)

        func rescale(_ s: Scalable) {
            let d = simd_distance(cameraPosition, s.entity.position(relativeTo: nil))
            switch s.kind {
            case .point:
                s.entity.scale = SIMD3(repeating: min(0.03, max(0.003, 0.0045 * d)))
            case .line(let length):
                let w = min(0.012, max(0.0012, 0.0018 * d))
                s.entity.scale = SIMD3(w, w, length)
            case .reticle:
                s.entity.scale = SIMD3(repeating: min(0.25, max(0.02, 0.03 * d)))
            }
        }
        for entry in completedEntities.values { entry.scalables.forEach(rescale) }
        activeScalables.forEach(rescale)
        if reticle.isEnabled { rescale(Scalable(entity: reticle, kind: .reticle)) }
        if edgeGuide.isEnabled {
            let d = simd_distance(cameraPosition, edgeGuide.position(relativeTo: nil))
            let w = min(0.008, max(0.001, 0.0014 * d))
            edgeGuide.scale = SIMD3(w, w, min(0.4, max(0.08, 0.1 * d)))
        }

        labelOverlay.layout { world in
            guard simd_dot(world - cameraPosition, forward) > 0.05 else { return nil }
            return arView.project(world)
        }
    }

    static func rotation(from a: SIMD3<Float>, to b: SIMD3<Float>) -> simd_quatf {
        let c = simd_dot(a, b)
        if c < -0.9999 {
            // Opposite directions: rotate 180° about any axis perpendicular to `a`.
            let axis = abs(a.x) < 0.9 ? simd_normalize(simd_cross(a, SIMD3(1, 0, 0))) : simd_normalize(simd_cross(a, SIMD3(0, 1, 0)))
            return simd_quatf(angle: .pi, axis: axis)
        }
        return simd_quatf(from: a, to: b)
    }
}
