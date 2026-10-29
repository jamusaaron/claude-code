import XCTest
@testable import MeasureCore

final class PolygonValidationTests: XCTestCase {
    let square: [Vec3] = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 0, 1), Vec3(0, 0, 1)]

    func testValidOutlinePasses() {
        XCTAssertNil(PolygonGeometry.validate(square))
    }

    func testRejectsTooFewDuplicateCollinearAndCrossing() {
        XCTAssertEqual(PolygonGeometry.validate(Array(square.prefix(2))), .tooFewPoints)
        XCTAssertEqual(PolygonGeometry.validate([Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1.0004, 0, 0), Vec3(0, 0, 1)]), .duplicatePoints)
        XCTAssertEqual(PolygonGeometry.validate([Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(2, 0, 0)]), .degenerate)
        XCTAssertEqual(PolygonGeometry.validate([Vec3(0, 0, 0), Vec3(3, 0, 1), Vec3(3, 0, 0), Vec3(0, 0, 2)]), .selfIntersecting)
    }

    func testTouchingVertexCountsAsIntersection() {
        // Vertex 4 lands exactly on edge 0–1: the outline touches itself.
        let touching: [Vec2] = [Vec2(0, 0), Vec2(2, 0), Vec2(2, 2), Vec2(1, 0), Vec2(0, 2)]
        XCTAssertTrue(PolygonGeometry.isSelfIntersecting(touching))
    }

    func testPlanarityToleranceScalesWithSpan() {
        XCTAssertEqual(PolygonGeometry.planarityTolerance(square), 0.01, accuracy: 1e-12)
        let room = square.map { $0 * 6 } // 6 m sides, ~8.5 m diagonal
        XCTAssertEqual(PolygonGeometry.planarityTolerance(room), 0.005 * 6 * 2.0.squareRoot(), accuracy: 1e-9)
    }

    func testNonPlanarAreaIsDowngradedAndCaveated() throws {
        var bent = square.map { MeasuredPoint(position: $0, sigma: 0.003) }
        bent[2].position.y = 0.1 // 10 cm lift: ±2.5 cm residuals, beyond 2× the 1 cm tolerance
        let r = try XCTUnwrap(MeasurementCalculator.area(bent))
        XCTAssertEqual(r.grade, .low)
        XCTAssertTrue(r.caveats.contains { $0.contains("not on one flat surface") })
    }

    func testVolumeCarriesPrismCaveat() throws {
        let base = square.map { MeasuredPoint(position: $0, sigma: 0.003) }
        let r = try XCTUnwrap(MeasurementCalculator.prismVolume(base: base, top: MeasuredPoint(position: Vec3(0.5, 1, 0.5), sigma: 0.003)))
        XCTAssertTrue(r.caveats.contains { $0.hasPrefix("Prism estimate") })
    }
}

final class TopologyTests: XCTestCase {
    func testClosedCubeIsClosedManifold() {
        let cube = TestMeshes.cube(size: 1, includeBottom: true)
        let t = MeshTopology.analyse(indices: cube.indices)
        XCTAssertTrue(t.isClosedManifold)
        XCTAssertEqual(t.components, 1)
        XCTAssertEqual(t.totalEdges, 18) // 12 cube edges + 6 face diagonals
    }

    func testOpenBottomHasBoundary() {
        let t = MeshTopology.analyse(indices: TestMeshes.cube(size: 1, includeBottom: false).indices)
        XCTAssertFalse(t.isClosedManifold)
        XCTAssertEqual(t.boundaryEdges, 4)
        XCTAssertTrue(t.isConsistentlyOriented)
    }

    func testFlippedFaceIsInconsistent() {
        var cube = TestMeshes.cube(size: 1, includeBottom: true)
        cube.indices.swapAt(1, 2) // flip one triangle
        let t = MeshTopology.analyse(indices: cube.indices)
        XCTAssertFalse(t.isConsistentlyOriented)
        XCTAssertFalse(t.isClosedManifold)
    }

    func testTwoPiecesAreTwoComponents() {
        var mesh = TestMeshes.cube(size: 1, includeBottom: true)
        mesh.append(TestMeshes.cube(size: 1, includeBottom: true).translated(by: Vec3f(3, 0, 0)))
        XCTAssertEqual(MeshTopology.analyse(indices: mesh.indices).components, 2)
    }

    func testEstimateVolumePrefersClosedMesh() throws {
        let cube = TestMeshes.cube(size: 0.5, includeBottom: true).translated(by: Vec3f(0, 0.2, 0))
        let e = try XCTUnwrap(VolumeGeometry.estimateVolume(positions: cube.positions, indices: cube.indices, supportPlaneY: nil))
        XCTAssertEqual(e.method, .closedMesh)
        XCTAssertEqual(e.volume, 0.125, accuracy: 1e-6)
        XCTAssertTrue(e.isReliable)
    }

    func testEstimateVolumeFallsBackToSupportPlaneOrNothing() throws {
        let open = TestMeshes.cube(size: 1, includeBottom: false)
        let e = try XCTUnwrap(VolumeGeometry.estimateVolume(positions: open.positions, indices: open.indices, supportPlaneY: 0))
        XCTAssertEqual(e.method, .aboveSupportPlane)
        XCTAssertEqual(e.volume, 1, accuracy: 1e-6)
        XCTAssertTrue(e.isReliable)
        // A room-like open surface with no support plane gets no volume at all.
        XCTAssertNil(VolumeGeometry.estimateVolume(positions: open.positions, indices: open.indices, supportPlaneY: nil))
    }

    func testDisconnectedPiecesAreNotReliable() throws {
        var two = TestMeshes.cube(size: 1, includeBottom: false)
        two.append(TestMeshes.cube(size: 1, includeBottom: false).translated(by: Vec3f(3, 0, 0)))
        let e = try XCTUnwrap(VolumeGeometry.estimateVolume(positions: two.positions, indices: two.indices, supportPlaneY: 0))
        XCTAssertFalse(e.isReliable)
    }
}

final class TextureVisibilityTests: XCTestCase {
    let intrinsics = CameraIntrinsics(fx: 800, fy: 800, cx: 512, cy: 384, width: 1024, height: 768)

    func quad() -> TriangleMesh {
        var m = TriangleMesh(
            positions: [Vec3f(-0.5, -0.5, 0), Vec3f(0.5, -0.5, 0), Vec3f(0.5, 0.5, 0), Vec3f(-0.5, 0.5, 0)],
            indices: [0, 1, 2, 0, 2, 3]
        )
        m.normals = MeshProcessing.vertexNormals(m)
        return m
    }

    func camera(at z: Double, x: Double = 0) -> RigidTransform {
        RigidTransform(c0: Vec3(1, 0, 0), c1: Vec3(0, 1, 0), c2: Vec3(0, 0, 1), translation: Vec3(x, 0, z))
    }

    func testDepthThatDisagreesRejectsTheView() {
        // LiDAR says the surface is 4 m away but the quad is at 2 m: the camera saw something else.
        let wrong = Keyframe(id: 1, cameraToWorld: camera(at: 2), intrinsics: intrinsics,
                             depth: DepthImage(width: 4, height: 3, values: Array(repeating: 4.0, count: 12)))
        let out = TextureProjector.project(mesh: quad(), keyframes: [wrong])
        XCTAssertNil(out.atlas)
    }

    func testVerifiedViewBeatsUnverifiedCloserView() throws {
        // An unverified view (no depth) slightly closer vs a verified view a bit farther away.
        let unverified = Keyframe(id: 1, cameraToWorld: camera(at: 1.8), intrinsics: intrinsics, depth: nil)
        let verified = Keyframe(id: 2, cameraToWorld: camera(at: 2.2, x: 0.05), intrinsics: intrinsics,
                                depth: DepthImage(width: 4, height: 3, values: Array(repeating: 2.2, count: 12)))
        let out = TextureProjector.project(mesh: quad(), keyframes: [unverified, verified])
        XCTAssertEqual(try XCTUnwrap(out.atlas).cells.map(\.keyframeID), [2])
    }

    func testViewsBeyondFiveMetresAreIgnored() {
        let far = Keyframe(id: 1, cameraToWorld: camera(at: 6), intrinsics: intrinsics, depth: nil)
        XCTAssertNil(TextureProjector.project(mesh: quad(), keyframes: [far]).atlas)
    }
}

final class ExportExtrasTests: XCTestCase {
    func testCSVCarriesID() {
        let id = UUID()
        let row = MeasurementCSVRow(id: id, name: "Bench", kind: .distance, value: 1, uncertainty: 0.005, confidence: .high,
                                    points: [], createdAt: Date(timeIntervalSince1970: 0))
        let text = String(decoding: CSVExporter.makeCSV(rows: [row], formatter: MetricFormatter(locale: Locale(identifier: "en_AU")), includeBOM: false), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("id,name,"))
        XCTAssertTrue(text.contains("\r\n\(id.uuidString),Bench,distance,"))
    }

    func testOBJZipIncludesReadme() throws {
        let cube = TestMeshes.cube(size: 0.3, includeBottom: true)
        let zip = try OBJExporter.makeZip(mesh: TexturedMesh(untextured: cube), material: .preset(.clay), textureJPEG: nil, baseName: "Chair")
        let names = try ZipReader.entries(zip).map(\.name)
        XCTAssertEqual(names, ["Chair.obj", "Chair.mtl", "README.txt"])
    }
}
