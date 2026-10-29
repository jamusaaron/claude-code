import Combine
import RealityKit
import UIKit

/// Non-AR RealityKit viewer for an exported USDZ with orbit, zoom and pan.
///
/// It loads the *exported file* (not the in-memory mesh), so what you inspect here is exactly
/// what AR Quick Look and other apps will receive. RealityKit has no built-in orbit camera on
/// iOS 17, so a perspective camera is driven by gestures.
@MainActor
final class ModelViewerController: NSObject, ObservableObject, UIGestureRecognizerDelegate {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var state: LoadState = .idle
    /// Image-based lighting exposure in stops.
    @Published var environmentExposure: Float = 0 { didSet { applyLighting() } }
    @Published var keyLightOn = true { didSet { applyLighting() } }
    @Published var showTexture = true { didSet { applyMaterials() } }

    let arView: ARView
    private let worldAnchor = AnchorEntity(world: .zero)
    private let camera = PerspectiveCamera()
    private let keyLight = DirectionalLight()
    private var model: Entity?
    private var originalMaterials: [(entity: Entity, materials: [RealityKit.Material])] = []
    private var loadRequest: AnyCancellable?
    private var loadedURL: URL?

    // Orbit state
    private var target = SIMD3<Float>(0, 0, 0)
    private var radius: Float = 1
    private var yaw: Float = 0.6
    private var pitch: Float = 0.35
    private var home = (target: SIMD3<Float>(0, 0, 0), radius: Float(1), yaw: Float(0.6), pitch: Float(0.35))
    private var gestureStart = (yaw: Float(0), pitch: Float(0), radius: Float(1), target: SIMD3<Float>(0, 0, 0))

    override init() {
        arView = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        super.init()
        arView.environment.background = .color(UIColor(white: 0.07, alpha: 1))
        camera.camera.fieldOfViewInDegrees = 45
        worldAnchor.addChild(camera)
        keyLight.light.intensity = 2500
        keyLight.look(at: .zero, from: SIMD3(1.2, 2.5, 1.8), relativeTo: nil)
        worldAnchor.addChild(keyLight)
        arView.scene.addAnchor(worldAnchor)
        installGestures()
    }

    // MARK: Loading

    func load(_ url: URL) {
        guard url != loadedURL || state != .loaded else { return }
        model?.removeFromParent()
        model = nil
        originalMaterials = []
        state = .loading
        loadedURL = url
        loadRequest = Entity.loadAsync(contentsOf: url)
            .sink(receiveCompletion: { [weak self] completion in
                if case .failure(let error) = completion {
                    self?.state = .failed("Couldn't open the model: \(error.localizedDescription)")
                }
            }, receiveValue: { [weak self] entity in
                self?.didLoad(entity)
            })
    }

    private func didLoad(_ entity: Entity) {
        worldAnchor.addChild(entity)
        model = entity
        originalMaterials = []
        visitModels(entity) { e, component in originalMaterials.append((e, component.materials)) }

        let bounds = entity.visualBounds(relativeTo: nil)
        let extents = bounds.extents
        let boundingRadius = max(0.05, simd_length(extents) / 2)
        let halfFOV = Float(camera.camera.fieldOfViewInDegrees) * .pi / 360
        target = bounds.center
        radius = boundingRadius / sin(halfFOV) * 1.15
        camera.camera.near = max(0.001, radius / 200)
        camera.camera.far = radius * 20
        yaw = 0.6
        pitch = 0.35
        home = (target, radius, yaw, pitch)
        updateCamera()
        applyMaterials()
        applyLighting()
        state = .loaded
    }

    private func visitModels(_ entity: Entity, _ body: (Entity, ModelComponent) -> Void) {
        if let component = entity.components[ModelComponent.self] { body(entity, component) }
        for child in entity.children { visitModels(child, body) }
    }

    // MARK: Appearance

    private func applyMaterials() {
        let clay = SimpleMaterial(color: UIColor(white: 0.78, alpha: 1), roughness: 0.75, isMetallic: false)
        for (entity, materials) in originalMaterials {
            guard var component = entity.components[ModelComponent.self] else { continue }
            component.materials = showTexture ? materials : Array(repeating: clay, count: max(1, materials.count))
            entity.components.set(component)
        }
    }

    private func applyLighting() {
        arView.environment.lighting.intensityExponent = environmentExposure
        keyLight.isEnabled = keyLightOn
    }

    // MARK: Camera

    func resetView() {
        (target, radius, yaw, pitch) = home
        updateCamera()
    }

    private func updateCamera() {
        pitch = min(1.45, max(-1.45, pitch))
        let offset = SIMD3<Float>(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw)) * radius
        camera.look(at: target, from: target + offset, relativeTo: nil)
    }

    private func installGestures() {
        let orbit = UIPanGestureRecognizer(target: self, action: #selector(handleOrbit(_:)))
        orbit.maximumNumberOfTouches = 1
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.delegate = self
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        [orbit, pan, pinch, doubleTap].forEach(arView.addGestureRecognizer)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func handleOrbit(_ g: UIPanGestureRecognizer) {
        if g.state == .began { gestureStart.yaw = yaw; gestureStart.pitch = pitch }
        let t = g.translation(in: arView)
        yaw = gestureStart.yaw - Float(t.x) * 0.008
        pitch = gestureStart.pitch + Float(t.y) * 0.008
        updateCamera()
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        if g.state == .began { gestureStart.target = target }
        let t = g.translation(in: arView)
        let m = camera.transformMatrix(relativeTo: nil)
        let right = SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        let up = SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z)
        let scale = radius * 0.0018
        target = gestureStart.target - right * Float(t.x) * scale + up * Float(t.y) * scale
        updateCamera()
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        if g.state == .began { gestureStart.radius = radius }
        radius = min(home.radius * 8, max(home.radius * 0.05, gestureStart.radius / Float(max(0.01, g.scale))))
        updateCamera()
    }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        resetView()
    }
}
