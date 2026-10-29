import XCTest
@testable import MeasureCore

final class GeometryTests: XCTestCase {
    let unitSquare: [Vec3] = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 0, 1), Vec3(0, 0, 1)]

    func testSquareAreaAndPerimeter() throws {
        let m = try XCTUnwrap(PolygonGeometry.metrics(unitSquare))
        XCTAssertEqual(m.area, 1, accuracy: 1e-12)
        XCTAssertEqual(m.perimeter, 4, accuracy: 1e-12)
        XCTAssertEqual(abs(m.normal.y), 1, accuracy: 1e-12)
        XCTAssertEqual(m.maxPlaneDeviation, 0, accuracy: 1e-12)
        XCTAssertFalse(m.isSelfIntersecting)
    }

    func testTiltedRectangleAreaIsTrueArea() throws {
        // 2 m × 1 m rectangle on a 30° slope.
        let angle = 30.0 * .pi / 180
        let up = Vec3(0, sin(angle), cos(angle))
        let pts = [Vec3.zero, Vec3(2, 0, 0), Vec3(2, 0, 0) + up, up]
        let m = try XCTUnwrap(PolygonGeometry.metrics(pts))
        XCTAssertEqual(m.area, 2, accuracy: 1e-9)
        XCTAssertEqual(m.perimeter, 6, accuracy: 1e-9)
    }

    func testConcaveLShapeAreaAndTriangulation() throws {
        let l: [Vec3] = [Vec3(0, 0, 0), Vec3(2, 0, 0), Vec3(2, 0, 1), Vec3(1, 0, 1), Vec3(1, 0, 2), Vec3(0, 0, 2)]
        let m = try XCTUnwrap(PolygonGeometry.metrics(l))
        XCTAssertEqual(m.area, 3, accuracy: 1e-12)
        let tris = PolygonGeometry.triangulate(l)
        XCTAssertEqual(tris.count, (l.count - 2) * 3)
        var total = 0.0
        for t in stride(from: 0, to: tris.count, by: 3) {
            total += Vec.length(Vec.cross(l[tris[t + 1]] - l[tris[t]], l[tris[t + 2]] - l[tris[t]])) / 2
        }
        XCTAssertEqual(total, 3, accuracy: 1e-12, "ear clipping must cover exactly the polygon")
    }

    func testBowtieIsSelfIntersecting() throws {
        let bowtie: [Vec2] = [Vec2(0, 0), Vec2(2, 1), Vec2(2, 0), Vec2(0, 1)]
        XCTAssertTrue(PolygonGeometry.isSelfIntersecting(bowtie))
        XCTAssertFalse(PolygonGeometry.isSelfIntersecting([Vec2(0, 0), Vec2(2, 0), Vec2(2, 1), Vec2(0, 1)]))
        // An asymmetric bowtie in 3D has a non-zero Newell vector, so metrics() must flag it.
        let skewed: [Vec3] = [Vec3(0, 0, 0), Vec3(3, 0, 1), Vec3(3, 0, 0), Vec3(0, 0, 2)]
        let m = try XCTUnwrap(PolygonGeometry.metrics(skewed))
        XCTAssertTrue(m.isSelfIntersecting)
    }

    func testNonPlanarDeviationReported() throws {
        var pts = unitSquare
        pts[2].y = 0.1
        let m = try XCTUnwrap(PolygonGeometry.metrics(pts))
        XCTAssertGreaterThan(m.maxPlaneDeviation, 0.02)
    }

    func testParallelogramCompletion() {
        let pts = PolygonGeometry.completeParallelogram(Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 0, 2))
        XCTAssertEqual(pts[3], Vec3(0, 0, 2))
    }

    func testPlaneIntersections() throws {
        let floor = try XCTUnwrap(Plane(normal: Vec3(0, 1, 0), through: Vec3(0, 0, 0)))
        let wall = try XCTUnwrap(Plane(normal: Vec3(0, 0, 1), through: Vec3(0, 0, -2)))
        let side = try XCTUnwrap(Plane(normal: Vec3(1, 0, 0), through: Vec3(3, 0, 0)))
        let line = try XCTUnwrap(Plane.intersection(floor, wall))
        XCTAssertEqual(abs(line.direction.x), 1, accuracy: 1e-12)
        XCTAssertEqual(line.origin.y, 0, accuracy: 1e-12)
        XCTAssertEqual(line.origin.z, -2, accuracy: 1e-12)
        let corner = try XCTUnwrap(Plane.intersection(floor, wall, side))
        XCTAssertEqual(Vec.distance(corner, Vec3(3, 0, -2)), 0, accuracy: 1e-12)
        XCTAssertNil(Plane.intersection(floor, floor))
    }

    func testRigidTransformInverse() {
        let t = RigidTransform.yaw(0.7, translation: Vec3(1, 2, 3))
        let p = Vec3(0.3, -0.4, 5)
        let back = t.inverse.apply(t.apply(p))
        XCTAssertEqual(Vec.distance(back, p), 0, accuracy: 1e-12)
        let composed = (t * t.inverse).apply(p)
        XCTAssertEqual(Vec.distance(composed, p), 0, accuracy: 1e-12)
    }

    func testPrismVolume() throws {
        let prism = try XCTUnwrap(VolumeGeometry.prism(base: unitSquare, top: Vec3(0.5, 2.5, 0.5)))
        XCTAssertEqual(prism.volume, 2.5, accuracy: 1e-12)
        XCTAssertEqual(prism.height, 2.5, accuracy: 1e-12)
        // The top point below the base still gives a positive height.
        let below = try XCTUnwrap(VolumeGeometry.prism(base: unitSquare, top: Vec3(0, -0.5, 0)))
        XCTAssertEqual(below.volume, 0.5, accuracy: 1e-12)
    }

    func testMeshVolumeOfOpenBottomedCube() {
        // Unit cube resting on y = 0 with no bottom face (as a LiDAR scan of a box would be).
        let cube = TestMeshes.cube(size: 1, includeBottom: false)
        let estimate = VolumeGeometry.meshVolumeAbovePlane(positions: cube.positions, indices: cube.indices, planeY: 0)
        XCTAssertEqual(estimate.volume, 1, accuracy: 1e-6)
        XCTAssertLessThan(estimate.openness, 0.01)
        XCTAssertTrue(estimate.isReliable)
    }

    func testMeshVolumeOfClosedCubeOffsetPlane() {
        let cube = TestMeshes.cube(size: 0.5, includeBottom: true).translated(by: Vec3f(0, 1, 0))
        let estimate = VolumeGeometry.meshVolumeAbovePlane(positions: cube.positions, indices: cube.indices, planeY: 1)
        XCTAssertEqual(estimate.volume, 0.125, accuracy: 1e-6)
    }

    func testMeshVolumeFlagsHoles() {
        var cube = TestMeshes.cube(size: 1, includeBottom: false)
        cube.indices.removeLast(6) // drop one side
        let estimate = VolumeGeometry.meshVolumeAbovePlane(positions: cube.positions, indices: cube.indices, planeY: 0)
        XCTAssertFalse(estimate.isReliable)
        XCTAssertGreaterThan(estimate.openness, 0.05)
    }
}

enum TestMeshes {
    /// Axis-aligned cube with its base centred at the origin, outward CCW faces.
    static func cube(size s: Float, includeBottom: Bool) -> TriangleMesh {
        let h = s / 2
        let p: [Vec3f] = [
            Vec3f(-h, 0, -h), Vec3f(h, 0, -h), Vec3f(h, 0, h), Vec3f(-h, 0, h),
            Vec3f(-h, s, -h), Vec3f(h, s, -h), Vec3f(h, s, h), Vec3f(-h, s, h),
        ]
        var idx: [UInt32] = [
            4, 7, 6, 4, 6, 5, // top (+Y)
            3, 2, 6, 3, 6, 7, // front (+Z)
            1, 0, 4, 1, 4, 5, // back (-Z)
            2, 1, 5, 2, 5, 6, // right (+X)
            0, 3, 7, 0, 7, 4, // left (-X)
        ]
        if includeBottom { idx += [0, 1, 2, 0, 2, 3] }
        var mesh = TriangleMesh(positions: p, indices: idx)
        mesh.normals = MeshProcessing.vertexNormals(mesh)
        return mesh
    }

    /// Flat grid in the XZ plane at height y, facing +Y.
    static func grid(cells: Int, size: Float, y: Float = 0, origin: Vec3f = .zero) -> TriangleMesh {
        var positions: [Vec3f] = []
        let step = size / Float(cells)
        for j in 0...cells { for i in 0...cells {
            positions.append(origin + Vec3f(Float(i) * step, y, Float(j) * step))
        } }
        var indices: [UInt32] = []
        let row = UInt32(cells + 1)
        for j in 0..<UInt32(cells) { for i in 0..<UInt32(cells) {
            let a = j * row + i, b = a + 1, c = a + row, d = c + 1
            indices += [a, c, b, b, c, d]
        } }
        return TriangleMesh(positions: positions, indices: indices)
    }
}
