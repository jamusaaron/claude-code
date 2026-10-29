import XCTest
@testable import MeasureCore

final class MeshProcessingTests: XCTestCase {
    func testWeldMergesDuplicatedChunkBorders() {
        // Two triangles sharing an edge, but with the shared vertices duplicated (as at ARMeshAnchor borders).
        let mesh = TriangleMesh(
            positions: [Vec3f(0, 0, 0), Vec3f(1, 0, 0), Vec3f(0, 0, 1), Vec3f(1, 0, 0), Vec3f(1, 0, 1), Vec3f(0, 0, 1)],
            indices: [0, 2, 1, 3, 5, 4]
        )
        let welded = MeshProcessing.cluster(mesh, cellSize: 0.001)
        XCTAssertEqual(welded.vertexCount, 4)
        XCTAssertEqual(welded.triangleCount, 2)
    }

    func testClusterSimplificationReducesDenseGrid() {
        let grid = TestMeshes.grid(cells: 40, size: 1) // 2.5 cm spacing, 3200 triangles
        let simplified = MeshProcessing.cluster(grid, cellSize: 0.1)
        XCTAssertLessThan(simplified.triangleCount, grid.triangleCount / 10)
        XCTAssertGreaterThan(simplified.triangleCount, 0)
        // Simplification must not flip faces.
        for t in 0..<simplified.triangleCount {
            let (i, j, k) = simplified.triangle(t)
            let n = Vec.cross(simplified.positions[Int(j)] - simplified.positions[Int(i)], simplified.positions[Int(k)] - simplified.positions[Int(i)])
            XCTAssertGreaterThan(n.y, 0)
        }
        XCTAssertEqual(MeshProcessing.surfaceArea(simplified), 1, accuracy: 0.25)
    }

    func testRemoveSmallComponentsDropsFloatingNoise() {
        var mesh = TestMeshes.grid(cells: 10, size: 1)
        let speck = TriangleMesh(positions: [Vec3f(5, 5, 5), Vec3f(5.01, 5, 5), Vec3f(5, 5, 5.01)], indices: [0, 2, 1])
        mesh.append(speck)
        let cleaned = MeshProcessing.removeSmallComponents(mesh, minimumTriangles: 5, minimumShareOfLargest: 0.02)
        XCTAssertEqual(cleaned.triangleCount, 200)
        XCTAssertLessThan(cleaned.bounds!.max.y, 1)
    }

    func testCropAndSupportSurfaceRemoval() {
        var scene = TestMeshes.grid(cells: 20, size: 2, origin: Vec3f(-1, 0, -1)) // floor
        scene.append(TestMeshes.cube(size: 0.3, includeBottom: false))            // object on it
        let box = OrientedBox(base: .zero, yaw: 0.3, size: Vec3(0.5, 0.5, 0.5))
        let cropped = MeshProcessing.crop(scene, to: box)
        XCTAssertLessThan(cropped.triangleCount, scene.triangleCount)
        let objectOnly = MeshProcessing.removeSupportSurface(cropped, planeY: 0)
        XCTAssertEqual(objectOnly.triangleCount, 10, "only the cube's 5 faces remain")
    }

    func testFullPipelineKeepsObjectAndComputesNormals() {
        var scene = TestMeshes.grid(cells: 20, size: 2, origin: Vec3f(-1, 0, -1))
        scene.append(TestMeshes.cube(size: 0.3, includeBottom: false))
        let options = MeshCleanupOptions(cropBox: OrientedBox(base: .zero, yaw: 0, size: Vec3(0.6, 0.6, 0.6)), supportPlaneY: 0, simplifyCellSize: 0)
        let out = MeshProcessing.process(scene, options: options)
        XCTAssertEqual(out.triangleCount, 10)
        XCTAssertEqual(out.normals.count, out.vertexCount)
        let volume = VolumeGeometry.meshVolumeAbovePlane(positions: out.positions, indices: out.indices, planeY: 0)
        XCTAssertEqual(volume.volume, 0.027, accuracy: 1e-6)
    }

    func testWindingAgreementDetectsFlippedMesh() {
        var cube = TestMeshes.cube(size: 1, includeBottom: true)
        XCTAssertEqual(MeshProcessing.windingAgreement(cube), 1, accuracy: 1e-9)
        let normals = cube.normals
        cube.flipWinding()
        cube.normals = normals // ARKit normals still point outward
        XCTAssertLessThan(MeshProcessing.windingAgreement(cube), 0.5)
    }

    func testOrientedBoxContainment() {
        let box = OrientedBox(base: Vec3(1, 0, 1), yaw: .pi / 4, size: Vec3(1, 1, 0.2))
        XCTAssertTrue(box.contains(Vec3(1, 0.5, 1)))
        XCTAssertFalse(box.contains(Vec3(1, 1.2, 1)))
        // Along the rotated local X axis the box extends ±0.5 m; the same offset along the
        // world diagonal is outside because the box is only 0.2 m deep.
        let alongLocalX = Vec3(1, 0.5, 1) + Vec3(cos(.pi / 4), 0, -sin(.pi / 4)) * 0.45
        XCTAssertTrue(box.contains(alongLocalX))
        XCTAssertFalse(box.contains(Vec3(1.45, 0.5, 1.45)))
    }
}

final class SnapTests: XCTestCase {
    /// Floor (y = 0, x in -0.5...0.5, z in -0.5...0) meeting a wall (z = 0, y in 0...0.5).
    func floorAndWall() -> [SnapTriangle] {
        var tris: [SnapTriangle] = []
        let n = 10
        let s = 0.05
        for i in 0..<n { for j in 0..<n {
            let x0 = -0.25 + Double(i) * s, x1 = x0 + s
            let z0 = -Double(j + 1) * s, z1 = z0 + s
            tris.append(SnapTriangle(a: Vec3(x0, 0, z0), b: Vec3(x0, 0, z1), c: Vec3(x1, 0, z0)))
            tris.append(SnapTriangle(a: Vec3(x1, 0, z0), b: Vec3(x0, 0, z1), c: Vec3(x1, 0, z1)))
            let y0 = Double(j) * s, y1 = y0 + s
            tris.append(SnapTriangle(a: Vec3(x0, y0, 0), b: Vec3(x1, y0, 0), c: Vec3(x0, y1, 0)))
            tris.append(SnapTriangle(a: Vec3(x1, y0, 0), b: Vec3(x1, y1, 0), c: Vec3(x0, y1, 0)))
        } }
        return tris
    }

    func testEdgeSnapFindsTrueFoldLine() {
        let query = Vec3(0.02, 0.012, -0.015) // near the fold, inside a would-be bevel
        let feature = SnapGeometry.findFeature(near: query, triangles: floorAndWall(), configuration: SnapConfiguration(radius: 0.06))
        guard case let .edge(point, direction) = feature else { return XCTFail("expected edge, got \(feature)") }
        XCTAssertEqual(point.y, 0, accuracy: 1e-6)
        XCTAssertEqual(point.z, 0, accuracy: 1e-6)
        XCTAssertEqual(point.x, 0.02, accuracy: 1e-6)
        XCTAssertEqual(abs(direction.x), 1, accuracy: 1e-6)
    }

    func testCornerSnapWithThreeFaces() {
        var tris = floorAndWall()
        // Side wall in the plane x = 0.25.
        let s = 0.05
        for j in 0..<10 { for k in 0..<10 {
            let y0 = Double(j) * s, y1 = y0 + s
            let z0 = -Double(k + 1) * s, z1 = z0 + s
            tris.append(SnapTriangle(a: Vec3(0.25, y0, z0), b: Vec3(0.25, y1, z0), c: Vec3(0.25, y0, z1)))
            tris.append(SnapTriangle(a: Vec3(0.25, y1, z0), b: Vec3(0.25, y1, z1), c: Vec3(0.25, y0, z1)))
        } }
        let feature = SnapGeometry.findFeature(near: Vec3(0.235, 0.01, -0.012), triangles: tris, configuration: SnapConfiguration(radius: 0.06))
        guard case let .corner(point) = feature else { return XCTFail("expected corner, got \(feature)") }
        XCTAssertEqual(Vec.distance(point, Vec3(0.25, 0, 0)), 0, accuracy: 1e-6)
    }

    func testFlatSurfaceHasNoFeature() {
        let flat = floorAndWall().filter { $0.a.y == 0 && $0.b.y == 0 && $0.c.y == 0 }
        XCTAssertEqual(SnapGeometry.findFeature(near: Vec3(0, 0, -0.25), triangles: flat), SnapFeature.none)
    }
}
