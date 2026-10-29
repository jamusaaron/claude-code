import XCTest
@testable import MeasureCore

final class TextureProjectionTests: XCTestCase {
    let intrinsics = CameraIntrinsics(fx: 800, fy: 800, cx: 512, cy: 384, width: 1024, height: 768)

    /// 1 m quad at z = 0 facing +Z.
    func quad() -> TriangleMesh {
        var m = TriangleMesh(
            positions: [Vec3f(-0.5, -0.5, 0), Vec3f(0.5, -0.5, 0), Vec3f(0.5, 0.5, 0), Vec3f(-0.5, 0.5, 0)],
            indices: [0, 1, 2, 0, 2, 3]
        )
        m.normals = MeshProcessing.vertexNormals(m)
        return m
    }

    func testProjectionMatchesPinholeModel() throws {
        let kf = Keyframe(id: 7, cameraToWorld: .init(c0: Vec3(1, 0, 0), c1: Vec3(0, 1, 0), c2: Vec3(0, 0, 1), translation: Vec3(0, 0, 2)), intrinsics: intrinsics, depth: nil)
        let p = try XCTUnwrap(TextureProjector.project(Vec3(0.5, 0.5, 0), into: kf, worldToCamera: kf.cameraToWorld.inverse))
        XCTAssertEqual(p.u, 712, accuracy: 1e-9)
        XCTAssertEqual(p.v, 184, accuracy: 1e-9, "+Y in the world is up in the image (smaller v)")
        XCTAssertEqual(p.depth, 2, accuracy: 1e-12)
    }

    func testFrontFacingQuadIsFullyTextured() throws {
        let kf = Keyframe(id: 7, cameraToWorld: RigidTransform(c0: Vec3(1, 0, 0), c1: Vec3(0, 1, 0), c2: Vec3(0, 0, 1), translation: Vec3(0, 0, 2)), intrinsics: intrinsics, depth: nil)
        let out = TextureProjector.project(mesh: quad(), keyframes: [kf])
        let atlas = try XCTUnwrap(out.atlas)
        XCTAssertEqual(out.texturedAreaShare, 1, accuracy: 1e-9)
        XCTAssertEqual(atlas.cells.map(\.keyframeID), [7])
        XCTAssertEqual(atlas.width, 1024)
        XCTAssertEqual(atlas.height, 768 + 8)
        XCTAssertEqual(out.uvs.count, out.positions.count)
        for uv in out.uvs {
            XCTAssertGreaterThanOrEqual(uv.x, 0); XCTAssertLessThanOrEqual(uv.x, 1)
            XCTAssertLessThan(uv.y, Float(768) / Float(776), "textured UVs stay out of the grey gutter")
        }
    }

    func testOccludedViewIsRejected() throws {
        // Keyframe 1 sees something 1 m away in front of the quad (2 m away): occluded.
        let occluder = DepthImage(width: 4, height: 3, values: Array(repeating: 1.0, count: 12))
        let blocked = Keyframe(id: 1, cameraToWorld: RigidTransform(c0: Vec3(1, 0, 0), c1: Vec3(0, 1, 0), c2: Vec3(0, 0, 1), translation: Vec3(0, 0, 2)), intrinsics: intrinsics, depth: occluder)
        let clear = Keyframe(id: 2, cameraToWorld: RigidTransform(c0: Vec3(1, 0, 0), c1: Vec3(0, 1, 0), c2: Vec3(0, 0, 1), translation: Vec3(0.1, 0, 2.5)), intrinsics: intrinsics, depth: nil)
        let out = TextureProjector.project(mesh: quad(), keyframes: [blocked, clear])
        XCTAssertEqual(try XCTUnwrap(out.atlas).cells.map(\.keyframeID), [2])
        XCTAssertEqual(out.texturedAreaShare, 1, accuracy: 1e-9)
    }

    func testBackFacingViewIsNotUsed() {
        // Camera behind the quad, looking towards +Z.
        let behind = Keyframe(id: 3, cameraToWorld: .yaw(.pi, translation: Vec3(0, 0, -2)), intrinsics: intrinsics, depth: nil)
        let out = TextureProjector.project(mesh: quad(), keyframes: [behind])
        XCTAssertNil(out.atlas)
        XCTAssertEqual(out.texturedAreaShare, 0)
    }

    func testAtlasLayoutFitsMaximumDimension() {
        let layout = TextureProjector.makeLayout(keyframeIDs: Array(0..<25), imageWidth: 1024, imageHeight: 768, options: TextureProjectionOptions())
        XCTAssertLessThanOrEqual(layout.width, 4096)
        XCTAssertLessThanOrEqual(layout.height, 4096)
        XCTAssertEqual(layout.cells.count, 25)
        XCTAssertEqual(Set(layout.cells.map { "\($0.x),\($0.y)" }).count, 25, "cells must not overlap")
    }
}

final class ExportTests: XCTestCase {
    func sampleMesh() -> TexturedMesh {
        let cube = TestMeshes.cube(size: 0.3, includeBottom: true)
        let uvs = cube.positions.map { Vec2f(($0.x + 0.15) / 0.3, 1 - $0.y / 0.3) }
        return TexturedMesh(positions: cube.positions, normals: cube.normals, uvs: uvs, indices: cube.indices,
                            atlas: AtlasLayout(width: 4, height: 4, cells: [], gutterY: 3), texturedAreaShare: 1)
    }

    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0xFF, 0xD9])

    func testGLBStructure() throws {
        let glb = try GLBExporter.makeGLB(mesh: sampleMesh(), material: MaterialSpec(), textureJPEG: jpeg)
        func u32(_ o: Int) -> UInt32 { glb.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt32.self)) } }
        XCTAssertEqual(u32(0), 0x4654_6C67)
        XCTAssertEqual(u32(4), 2)
        XCTAssertEqual(Int(u32(8)), glb.count)
        let jsonLength = Int(u32(12))
        XCTAssertEqual(jsonLength % 4, 0)
        XCTAssertEqual(u32(16), 0x4E4F_534A)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: glb.subdata(in: 20..<(20 + jsonLength))) as? [String: Any])
        let binLength = Int(u32(20 + jsonLength))
        XCTAssertEqual(u32(24 + jsonLength), 0x004E_4942)
        XCTAssertEqual(28 + jsonLength + binLength, glb.count)
        let views = try XCTUnwrap(json["bufferViews"] as? [[String: Any]])
        for v in views {
            let end = (v["byteOffset"] as! Int) + (v["byteLength"] as! Int)
            XCTAssertLessThanOrEqual(end, binLength)
            XCTAssertEqual((v["byteOffset"] as! Int) % 4, 0)
        }
        let attributes = try XCTUnwrap(((json["meshes"] as? [[String: Any]])?.first?["primitives"] as? [[String: Any]])?.first?["attributes"] as? [String: Int])
        XCTAssertEqual(Set(attributes.keys), ["POSITION", "NORMAL", "TEXCOORD_0"])
        XCTAssertNotNil(json["images"])
    }

    func testGLBWithoutTextureOmitsImage() throws {
        let glb = try GLBExporter.makeGLB(mesh: sampleMesh(), material: .preset(.clay), textureJPEG: jpeg)
        let jsonLength = Int(glb.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self) })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: glb.subdata(in: 20..<(20 + jsonLength))) as? [String: Any])
        XCTAssertNil(json["images"])
        XCTAssertNil(json["textures"])
    }

    func testUSDZIsAlignedStoredZipWithUSDARoot() throws {
        let usdz = try USDZExporter.makeUSDZ(mesh: sampleMesh(), material: MaterialSpec(), textureJPEG: jpeg)
        let entries = try ZipReader.entries(usdz)
        XCTAssertEqual(entries.map(\.name), ["model.usda", "textures/texture.jpg"])
        for e in entries {
            XCTAssertEqual(e.dataOffset % 64, 0, "\(e.name) data must be 64-byte aligned")
            XCTAssertEqual(e.compression, 0)
            XCTAssertEqual(CRC32.checksum(usdz.subdata(in: e.dataOffset..<(e.dataOffset + e.size))), e.crc)
        }
        let usda = String(decoding: usdz.subdata(in: entries[0].dataOffset..<(entries[0].dataOffset + entries[0].size)), as: UTF8.self)
        XCTAssertTrue(usda.hasPrefix("#usda 1.0"))
        XCTAssertTrue(usda.contains("upAxis = \"Y\""))
        XCTAssertTrue(usda.contains("metersPerUnit = 1"))
        XCTAssertTrue(usda.contains("texCoord2f[] primvars:st"))
        XCTAssertTrue(usda.contains("@textures/texture.jpg@"))
    }

    func testOBJCounts() {
        let mesh = sampleMesh()
        let files = OBJExporter.makeOBJ(mesh: mesh, material: MaterialSpec())
        let text = String(decoding: files.obj, as: UTF8.self)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.filter { $0.hasPrefix("v ") }.count, mesh.vertexCount)
        XCTAssertEqual(lines.filter { $0.hasPrefix("vt ") }.count, mesh.vertexCount)
        XCTAssertEqual(lines.filter { $0.hasPrefix("vn ") }.count, mesh.vertexCount)
        XCTAssertEqual(lines.filter { $0.hasPrefix("f ") }.count, mesh.triangleCount)
        XCTAssertTrue(lines.contains("f 5/5/5 8/8/8 7/7/7"))
        XCTAssertTrue(String(decoding: files.mtl, as: UTF8.self).contains("map_Kd texture.jpg"))
    }

    func testCSVEscapingAndBOM() {
        let row = MeasurementCSVRow(name: "Desk, \"left\"", kind: .distance, value: 1.2, uncertainty: 0.006, confidence: .high,
                                    points: [Vec3(0, 0, 0), Vec3(1.2, 0, 0)], createdAt: Date(timeIntervalSince1970: 0), notes: "line1\nline2")
        let data = CSVExporter.makeCSV(rows: [row], formatter: MetricFormatter(locale: Locale(identifier: "en_AU")))
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF])
        let text = String(decoding: data.dropFirst(3), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix(CSVExporter.header.joined(separator: ",") + "\r\n"))
        XCTAssertTrue(text.contains("\"Desk, \"\"left\"\"\",distance,1.2,m,0.006,1.200 m,high"))
        XCTAssertTrue(text.contains("0;0;0|1.2;0;0"))
        XCTAssertTrue(text.contains("\"line1\nline2\""))
        XCTAssertTrue(text.contains("1970-01-01T00:00:00Z"))
    }

    func testMeshArchiveRoundTrip() throws {
        let mesh = sampleMesh()
        let decoded = try MeshArchive.decode(MeshArchive.encode(mesh))
        XCTAssertEqual(decoded.positions, mesh.positions)
        XCTAssertEqual(decoded.normals, mesh.normals)
        XCTAssertEqual(decoded.uvs, mesh.uvs)
        XCTAssertEqual(decoded.indices, mesh.indices)
        XCTAssertTrue(decoded.hasTexture)
        XCTAssertThrowsError(try MeshArchive.decode(Data("nope".utf8)))
    }

    func testTextBufferNumbers() {
        func s(_ v: Double, _ d: Int) -> String {
            var t = TextBuffer()
            t.append(v, decimals: d)
            return String(decoding: t.bytes, as: UTF8.self)
        }
        XCTAssertEqual(s(0.05, 5), "0.05")
        XCTAssertEqual(s(-1.25, 5), "-1.25")
        XCTAssertEqual(s(3, 5), "3")
        XCTAssertEqual(s(-0.000001, 5), "0")
        XCTAssertEqual(s(0.000123, 6), "0.000123")
        XCTAssertEqual(s(.nan, 3), "0")
    }

    func testZipCRCKnownValue() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
    }
}

/// Just enough zip parsing to verify the writer.
enum ZipReader {
    struct Entry {
        var name: String
        var compression: UInt16
        var crc: UInt32
        var size: Int
        var dataOffset: Int
    }

    static func entries(_ data: Data) throws -> [Entry] {
        func u16(_ o: Int) -> UInt16 { data.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt16.self)) } }
        func u32(_ o: Int) -> UInt32 { data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt32.self)) } }
        var out: [Entry] = []
        var o = 0
        while o + 30 <= data.count, u32(o) == 0x04034B50 {
            let compression = u16(o + 8)
            let crc = u32(o + 14)
            let size = Int(u32(o + 22))
            let nameLength = Int(u16(o + 26))
            let extraLength = Int(u16(o + 28))
            let name = String(decoding: data.subdata(in: (o + 30)..<(o + 30 + nameLength)), as: UTF8.self)
            let dataOffset = o + 30 + nameLength + extraLength
            out.append(Entry(name: name, compression: compression, crc: crc, size: size, dataOffset: dataOffset))
            o = dataOffset + size
        }
        return out
    }
}
