import Foundation

/// Compact binary storage for a processed model (`mesh.bin` in each library folder), so exports
/// in any format can be regenerated later without re-parsing USD.
///
/// Layout (little-endian): "LMSH", version u32, vertexCount u32, indexCount u32, flags u32,
/// texturedAreaShare f32, then positions (3×f32 each), normals (3×f32), UVs (2×f32, if flag 1),
/// indices (u32).
public enum MeshArchive {
    static let magic: [UInt8] = Array("LMSH".utf8)
    static let version: UInt32 = 1
    static let hasUVFlag: UInt32 = 1

    public enum ArchiveError: Error, Equatable {
        case badMagic
        case unsupportedVersion(UInt32)
        case truncated
        case corrupt
    }

    public static func encode(_ mesh: TexturedMesh) -> Data {
        let hasUV = mesh.uvs.count == mesh.vertexCount && mesh.vertexCount > 0
        let normals = mesh.normals.count == mesh.vertexCount ? mesh.normals : [Vec3f](repeating: Vec3f(0, 1, 0), count: mesh.vertexCount)
        var d = Data(capacity: 24 + mesh.vertexCount * 32 + mesh.indices.count * 4)
        d.append(contentsOf: magic)
        d.appendLE(version)
        d.appendLE(UInt32(mesh.vertexCount))
        d.appendLE(UInt32(mesh.indices.count))
        d.appendLE(hasUV ? hasUVFlag : 0)
        d.appendLE(Float(mesh.texturedAreaShare))
        for p in mesh.positions { d.appendLE(p.x); d.appendLE(p.y); d.appendLE(p.z) }
        for n in normals { d.appendLE(n.x); d.appendLE(n.y); d.appendLE(n.z) }
        if hasUV { for uv in mesh.uvs { d.appendLE(uv.x); d.appendLE(uv.y) } }
        for i in mesh.indices { d.appendLE(i) }
        return d
    }

    /// The atlas layout is not stored: the composited texture image travels as its own file.
    public static func decode(_ data: Data) throws -> TexturedMesh {
        var reader = Reader(data: data)
        guard try reader.bytes(4) == magic else { throw ArchiveError.badMagic }
        let v = try reader.u32()
        guard v == version else { throw ArchiveError.unsupportedVersion(v) }
        let vertexCount = Int(try reader.u32())
        let indexCount = Int(try reader.u32())
        let flags = try reader.u32()
        let share = Double(try reader.f32())
        let hasUV = flags & hasUVFlag != 0
        let expected = vertexCount * (hasUV ? 32 : 24) + indexCount * 4
        guard data.count - reader.offset >= expected else { throw ArchiveError.truncated }

        var positions = [Vec3f](); positions.reserveCapacity(vertexCount)
        for _ in 0..<vertexCount { positions.append(Vec3f(try reader.f32(), try reader.f32(), try reader.f32())) }
        var normals = [Vec3f](); normals.reserveCapacity(vertexCount)
        for _ in 0..<vertexCount { normals.append(Vec3f(try reader.f32(), try reader.f32(), try reader.f32())) }
        var uvs = [Vec2f]()
        if hasUV {
            uvs.reserveCapacity(vertexCount)
            for _ in 0..<vertexCount { uvs.append(Vec2f(try reader.f32(), try reader.f32())) }
        }
        var indices = [UInt32](); indices.reserveCapacity(indexCount)
        for _ in 0..<indexCount {
            let i = try reader.u32()
            guard Int(i) < vertexCount else { throw ArchiveError.corrupt }
            indices.append(i)
        }
        // A placeholder layout marks the UVs as atlas UVs; the real image is texture.jpg.
        let atlas = hasUV ? AtlasLayout(width: 1, height: 1, cells: [], gutterY: 1) : nil
        return TexturedMesh(positions: positions, normals: normals, uvs: uvs, indices: indices, atlas: atlas, texturedAreaShare: share)
    }

    struct Reader {
        let data: Data
        var offset = 0

        init(data: Data) { self.data = data }

        mutating func bytes(_ n: Int) throws -> [UInt8] {
            guard offset + n <= data.count else { throw ArchiveError.truncated }
            let start = data.startIndex + offset
            offset += n
            return Array(data[start..<(start + n)])
        }

        mutating func u32() throws -> UInt32 {
            guard offset + 4 <= data.count else { throw ArchiveError.truncated }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            offset += 4
            return UInt32(littleEndian: value)
        }

        mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
    }
}
