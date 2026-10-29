import ARKit
import RealityKit
import UIKit
import MeasureCore

/// A 3D point located under a screen position, with how it was found and how much to trust it.
struct ResolvedPoint: Equatable {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>?
    var snap: SnapKind
    var confidence: DepthConfidence
    /// Camera-to-point distance (m).
    var range: Float
    /// 1-sigma position uncertainty from `AccuracyModel` (m).
    var sigma: Double
    /// Set when snapped onto an already-placed point (measurement id, point index).
    var existingPoint: PointReference?
    var edgeDirection: SIMD3<Float>?
    /// The depth map is discontinuous here (edge, hole or thin object).
    var nearDepthEdge: Bool

    var grade: ConfidenceGrade { AccuracyModel.grade(pointSigma: sigma) }
}

struct PointReference: Equatable, Hashable {
    var measurementID: UUID
    var index: Int
}

/// Snapping switches, copied from settings each query.
struct SnapOptions {
    var planes = true
    var edges = true
    var points = true
}

/// Resolves screen points to world points using every LiDAR-derived source ARKit offers.
///
/// Sources, in order of preference:
///  * an existing measurement point within ~22 pt on screen (lets polygons close exactly);
///  * a ray hit on the fused LiDAR scene mesh (RealityKit scene-understanding collision);
///  * the single-frame LiDAR depth under the pixel, unprojected through the camera intrinsics;
///  * ARKit's estimated plane (no LiDAR support) as a last resort.
/// On top of that the point may be refined: projected onto a detected plane when it agrees with
/// the surface (a plane is fitted to hundreds of samples, so it is steadier than any single hit),
/// or moved onto a fitted edge line or corner (see `SnapGeometry`).
///
/// Every candidate must also be *supported*: a point is only accepted if the LiDAR depth
/// under the pixel agrees with it, or reconstructed mesh exists right there. AR ray casts can
/// otherwise invent surfaces (an estimated plane through thin air, or a room plane behind the
/// object you are aiming at), and an unsupported number is worse than none.
@MainActor
final class SurfaceResolver {
    private let arView: ARView
    let meshIndex = MeshSnapIndex()

    /// The LiDAR can't resolve depth closer than this.
    static let minimumRange: Float = 0.15
    /// Beyond this, only points on already reconstructed geometry are accepted.
    static let reliableRange = Float(AccuracyModel.reliableRange)

    init(arView: ARView) {
        self.arView = arView
    }

    func resolve(at screenPoint: CGPoint, frame: ARFrame, options: SnapOptions, existingPoints: [(PointReference, SIMD3<Float>)]) -> ResolvedPoint? {
        let cameraPosition = frame.camera.transform.origin
        let tracking = TrackingStatus(frame.camera.trackingState).quality
        let orientation = UIApplication.shared.activeInterfaceOrientation
        let depth = DepthSampler.sample(frame: frame, viewPoint: screenPoint, viewportSize: arView.bounds.size, orientation: orientation)
        let confidence = depth?.confidence ?? .low
        let nearEdge = depth?.isDiscontinuity ?? false

        func finish(_ position: SIMD3<Float>, normal: SIMD3<Float>?, snap: SnapKind, existing: PointReference? = nil, edge: SIMD3<Float>? = nil) -> ResolvedPoint {
            let range = simd_distance(position, cameraPosition)
            // Plane/edge/corner fits average many samples, so a single noisy pixel at the tap
            // shouldn't drag their confidence down to "low".
            let effectiveConfidence: DepthConfidence = [.plane, .edge, .corner].contains(snap) ? max(confidence, .medium) : confidence
            let sigma = AccuracyModel.pointSigma(range: Double(range), confidence: effectiveConfidence, snap: snap, tracking: tracking)
            return ResolvedPoint(position: position, normal: normal, snap: snap, confidence: effectiveConfidence, range: range,
                                 sigma: sigma, existingPoint: existing, edgeDirection: edge, nearDepthEdge: nearEdge)
        }

        // 1. Existing points (screen-space proximity).
        if options.points {
            var bestDistance: CGFloat = 22
            var best: (PointReference, SIMD3<Float>)?
            for (ref, p) in existingPoints {
                guard let projected = project(p, frame: frame) else { continue }
                let d = hypot(projected.x - screenPoint.x, projected.y - screenPoint.y)
                if d < bestDistance { bestDistance = d; best = (ref, p) }
            }
            if let best { return finish(best.1, normal: nil, snap: .point, existing: best.0) }
        }

        // 2. Base surface point.
        var base: (position: SIMD3<Float>, normal: SIMD3<Float>?, snap: SnapKind)?
        if let hit = arView.hitTest(screenPoint, query: .nearest, mask: .sceneUnderstanding).first {
            base = (hit.position, hit.normal, .mesh)
        } else if let depth, depth.validFraction > 0.3 {
            base = (depth.worldPosition, nil, .depth)
        } else if let estimated = arView.raycast(from: screenPoint, allowing: .estimatedPlane, alignment: .any).first {
            base = (estimated.worldTransform.origin, estimated.worldTransform.columns.1.xyz, .estimatedPlane)
        }

        // 3. Plane refinement.
        if options.planes, let planeHit = arView.raycast(from: screenPoint, allowing: .existingPlaneGeometry, alignment: .any).first {
            let planePoint = planeHit.worldTransform.origin
            let planeNormal = planeHit.worldTransform.columns.1.xyz
            if let b = base {
                let range = simd_distance(b.position, cameraPosition)
                let tolerance = max(0.02, 0.01 * range)
                if simd_distance(b.position, planePoint) <= tolerance {
                    base = (planePoint, planeNormal, .plane)
                }
            } else {
                base = (planePoint, planeNormal, .plane)
            }
        }

        guard let surface = base else { return nil }

        // 4. Support and range checks.
        let range = simd_distance(surface.position, cameraPosition)
        guard range >= Self.minimumRange else { return nil }
        let reconstructed: Set<SnapKind> = [.mesh, .plane]
        guard range <= Self.reliableRange || reconstructed.contains(surface.snap) else { return nil }

        var downgraded = false
        switch depthAgreement(surface.position, sample: depth, frame: frame) {
        case .agrees:
            break
        case .disagrees:
            // The LiDAR sees a different surface at this pixel. An estimated or detected plane
            // is then usually the wall behind the object being aimed at: reject it. A mesh hit
            // is real reconstructed geometry that may lag the scene (something moved), so keep
            // it but trust it less.
            if surface.snap != .mesh { return nil }
            downgraded = true
        case .unknown:
            // No usable depth here: only accept points sitting on reconstructed mesh.
            if surface.snap == .estimatedPlane || surface.snap == .depth {
                guard hasMeshSupport(near: surface.position, frame: frame) else { return nil }
            }
        }

        // 5. Edge / corner refinement on the LiDAR mesh (not on a point we already distrust).
        if options.edges, !downgraded, surface.snap != .estimatedPlane, let anchors = meshAnchors(frame), !anchors.isEmpty {
            let range = simd_distance(surface.position, cameraPosition)
            let radius = min(0.06, max(0.025, 0.015 * range))
            let triangles = meshIndex.triangles(near: surface.position, radius: radius, anchors: anchors)
            let config = SnapConfiguration(radius: Double(radius))
            switch SnapGeometry.findFeature(near: surface.position.asDouble, triangles: triangles, configuration: config) {
            case .corner(let p):
                return finish(p.asFloat, normal: surface.normal, snap: .corner)
            case .edge(let p, let dir):
                return finish(p.asFloat, normal: surface.normal, snap: .edge, edge: dir.asFloat)
            case .none:
                break
            }
        }

        let result = finish(surface.position, normal: surface.normal, snap: surface.snap)
        return downgraded ? lowered(result, tracking: tracking) : result
    }

    // MARK: Support checks

    enum DepthAgreement: Equatable {
        case agrees, disagrees, unknown
    }

    /// Compares the candidate's distance along the camera axis with the LiDAR depth under the
    /// pixel. Tolerance max(5 cm, 4%) covers sensor noise without accepting a different surface.
    func depthAgreement(_ point: SIMD3<Float>, sample: DepthSample?, frame: ARFrame) -> DepthAgreement {
        guard let sample, sample.validFraction > 0.3, sample.confidence != .low else { return .unknown }
        let local = frame.camera.transform.inverse * SIMD4<Float>(point, 1)
        let expected = -local.z
        guard expected > 0 else { return .disagrees }
        return abs(sample.depth - expected) <= max(0.05, 0.04 * expected) ? .agrees : .disagrees
    }

    /// Reconstructed LiDAR mesh within 4 cm of the point.
    func hasMeshSupport(near point: SIMD3<Float>, frame: ARFrame) -> Bool {
        guard let anchors = meshAnchors(frame) else { return false }
        return !meshIndex.triangles(near: point, radius: 0.04, anchors: anchors, limit: 1).isEmpty
    }

    /// One confidence level lower, with the uncertainty recomputed to match.
    private func lowered(_ r: ResolvedPoint, tracking: TrackingQuality) -> ResolvedPoint {
        var out = r
        out.confidence = DepthConfidence(rawValue: max(0, r.confidence.rawValue - 1)) ?? .low
        out.sigma = AccuracyModel.pointSigma(range: Double(r.range), confidence: out.confidence, snap: r.snap, tracking: tracking)
        out.nearDepthEdge = true
        return out
    }

    /// Screen position of a world point, nil if behind the camera or off-screen.
    func project(_ world: SIMD3<Float>, frame: ARFrame) -> CGPoint? {
        let camera = frame.camera.transform
        let toPoint = world - camera.origin
        let forward = -SIMD3(camera.columns.2.x, camera.columns.2.y, camera.columns.2.z)
        guard simd_dot(toPoint, forward) > 0.05 else { return nil }
        guard let p = arView.project(world) else { return nil }
        let b = arView.bounds
        guard p.x >= -50, p.y >= -50, p.x <= b.width + 50, p.y <= b.height + 50 else { return nil }
        return p
    }

    private func meshAnchors(_ frame: ARFrame) -> [ARMeshAnchor]? {
        let anchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        return anchors.isEmpty ? nil : anchors
    }
}

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
