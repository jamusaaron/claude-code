import RealityKit
import UIKit
import simd
import MeasureCore

/// Wireframe capture box drawn in AR: the selection used to crop an object scan.
@MainActor
final class RegionBoxEntity {
    let anchor = AnchorEntity(world: .zero)
    private let container = Entity()
    private var edges: [ModelEntity] = []
    private let floor: ModelEntity

    init() {
        var floorMaterial = UnlitMaterial(color: Theme.uiAccent)
        floorMaterial.blending = .transparent(opacity: .init(scale: 0.15))
        floor = ModelEntity(mesh: .generatePlane(width: 1, depth: 1), materials: [floorMaterial])

        let edgeMaterial = UnlitMaterial(color: Theme.uiAccent)
        for _ in 0..<12 {
            let e = ModelEntity(mesh: .generateBox(size: 1), materials: [edgeMaterial])
            edges.append(e)
            container.addChild(e)
        }
        container.addChild(floor)
        anchor.addChild(container)
        anchor.isEnabled = false
    }

    func update(_ box: OrientedBox?) {
        guard let box else {
            anchor.isEnabled = false
            return
        }
        anchor.isEnabled = true
        let base = SIMD3<Float>(Float(box.center.x), Float(box.baseY), Float(box.center.z))
        container.transform = Transform(scale: .one, rotation: simd_quatf(angle: Float(box.yaw), axis: SIMD3(0, 1, 0)), translation: base)

        let w = Float(box.size.x), h = Float(box.size.y), d = Float(box.size.z)
        let t: Float = 0.004
        var i = 0
        func edge(_ position: SIMD3<Float>, _ scale: SIMD3<Float>) {
            edges[i].position = position
            edges[i].scale = scale
            i += 1
        }
        for y in [Float(0), h] {
            for z in [-d / 2, d / 2] { edge(SIMD3(0, y, z), SIMD3(w, t, t)) }
            for x in [-w / 2, w / 2] { edge(SIMD3(x, y, 0), SIMD3(t, t, d)) }
        }
        for x in [-w / 2, w / 2] {
            for z in [-d / 2, d / 2] { edge(SIMD3(x, h / 2, z), SIMD3(t, h, t)) }
        }
        floor.position = SIMD3(0, 0.002, 0)
        floor.scale = SIMD3(w, 1, d)
    }
}
