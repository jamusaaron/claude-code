import Foundation

/// Binary glTF 2.0 (.glb) writer: one mesh, one material, texture embedded in the BIN chunk.
/// glTF is +Y up, metres, counter-clockwise front faces and top-left UV origin, all of which
/// match the internal mesh, so no conversion is needed.
public enum GLBExporter {
    // MARK: JSON schema subset

    struct Root: Encodable {
        var asset = Asset()
        var scene = 0
        var scenes: [Scene]
        var nodes: [Node]
        var meshes: [Mesh]
        var accessors: [Accessor]
        var bufferViews: [BufferView]
        var buffers: [Buffer]
        var materials: [Material]
        var textures: [Texture]?
        var images: [Image]?
        var samplers: [Sampler]?
    }

    struct Asset: Encodable {
        var version = "2.0"
        var generator = "LiDAR Measure"
    }

    struct Scene: Encodable { var nodes: [Int] }
    struct Node: Encodable { var mesh: Int; var name: String }
    struct Mesh: Encodable { var name: String; var primitives: [Primitive] }

    struct Primitive: Encodable {
        var attributes: [String: Int]
        var indices: Int
        var material: Int
        var mode = 4 // TRIANGLES
    }

    struct Accessor: Encodable {
        var bufferView: Int
        var componentType: Int
        var count: Int
        var type: String
        var min: [Float]?
        var max: [Float]?
    }

    struct BufferView: Encodable {
        var buffer = 0
        var byteOffset: Int
        var byteLength: Int
        var target: Int?
    }

    struct Buffer: Encodable { var byteLength: Int }

    struct Material: Encodable {
        var name: String
        var pbrMetallicRoughness: PBR
        var doubleSided = true
    }

    struct PBR: Encodable {
        var baseColorFactor: [Float]
        var baseColorTexture: TextureInfo?
        var metallicFactor: Float
        var roughnessFactor: Float
    }

    struct TextureInfo: Encodable { var index: Int }
    struct Texture: Encodable { var sampler: Int; var source: Int }
    struct Image: Encodable { var bufferView: Int; var mimeType: String }

    struct Sampler: Encodable {
        var magFilter = 9729  // LINEAR
        var minFilter = 9987  // LINEAR_MIPMAP_LINEAR
        var wrapS = 33071     // CLAMP_TO_EDGE
        var wrapT = 33071
    }

    static let float = 5126
    static let unsignedInt = 5125
    static let arrayBuffer = 34962
    static let elementArrayBuffer = 34963

    // MARK: Export

    public enum GLBError: Error { case emptyMesh }

    public static func makeGLB(mesh: TexturedMesh, material: MaterialSpec, textureJPEG: Data?) throws -> Data {
        guard mesh.triangleCount > 0, let bounds = mesh.bounds else { throw GLBError.emptyMesh }
        let useTexture = material.usesTexture && mesh.hasTexture && textureJPEG != nil

        var bin = Data()
        var views: [BufferView] = []
        func addView(_ data: Data, target: Int?) -> Int {
            let offset = bin.count
            bin.append(data)
            while bin.count % 4 != 0 { bin.append(0) }
            views.append(BufferView(byteOffset: offset, byteLength: data.count, target: target))
            return views.count - 1
        }

        var positions = Data(capacity: mesh.vertexCount * 12)
        for p in mesh.positions { positions.appendLE(p.x); positions.appendLE(p.y); positions.appendLE(p.z) }
        var normals = Data(capacity: mesh.vertexCount * 12)
        for n in mesh.normals {
            // The validator requires unit normals; repair anything degenerate.
            var u = Vec.normalize(n)
            if Vec.lengthSquared(u) < 0.5 { u = Vec3f(0, 1, 0) }
            normals.appendLE(u.x); normals.appendLE(u.y); normals.appendLE(u.z)
        }
        var indices = Data(capacity: mesh.indices.count * 4)
        for i in mesh.indices { indices.appendLE(i) }

        var accessors: [Accessor] = []
        var attributes: [String: Int] = [:]

        let posView = addView(positions, target: arrayBuffer)
        accessors.append(Accessor(bufferView: posView, componentType: float, count: mesh.vertexCount, type: "VEC3",
                                  min: [bounds.min.x, bounds.min.y, bounds.min.z], max: [bounds.max.x, bounds.max.y, bounds.max.z]))
        attributes["POSITION"] = accessors.count - 1

        if mesh.normals.count == mesh.vertexCount {
            let view = addView(normals, target: arrayBuffer)
            accessors.append(Accessor(bufferView: view, componentType: float, count: mesh.vertexCount, type: "VEC3"))
            attributes["NORMAL"] = accessors.count - 1
        }

        if useTexture {
            var uvs = Data(capacity: mesh.vertexCount * 8)
            for uv in mesh.uvs { uvs.appendLE(uv.x); uvs.appendLE(uv.y) }
            let view = addView(uvs, target: arrayBuffer)
            accessors.append(Accessor(bufferView: view, componentType: float, count: mesh.vertexCount, type: "VEC2"))
            attributes["TEXCOORD_0"] = accessors.count - 1
        }

        let indexView = addView(indices, target: elementArrayBuffer)
        accessors.append(Accessor(bufferView: indexView, componentType: unsignedInt, count: mesh.indices.count, type: "SCALAR"))
        let indexAccessor = accessors.count - 1

        var textures: [Texture]?
        var images: [Image]?
        var samplers: [Sampler]?
        if useTexture, let jpeg = textureJPEG {
            let imageView = addView(jpeg, target: nil)
            images = [Image(bufferView: imageView, mimeType: "image/jpeg")]
            samplers = [Sampler()]
            textures = [Texture(sampler: 0, source: 0)]
        }

        let c = material.baseColor
        let gltfMaterial = Material(
            name: material.name,
            pbrMetallicRoughness: PBR(
                baseColorFactor: [c.x, c.y, c.z, 1],
                baseColorTexture: useTexture ? TextureInfo(index: 0) : nil,
                metallicFactor: material.metallic,
                roughnessFactor: material.roughness
            )
        )

        let root = Root(
            scenes: [Scene(nodes: [0])],
            nodes: [Node(mesh: 0, name: "Scan")],
            meshes: [Mesh(name: "Scan", primitives: [Primitive(attributes: attributes, indices: indexAccessor, material: 0)])],
            accessors: accessors,
            bufferViews: views,
            buffers: [Buffer(byteLength: bin.count)],
            materials: [gltfMaterial],
            textures: textures,
            images: images,
            samplers: samplers
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var json = try encoder.encode(root)
        while json.count % 4 != 0 { json.append(0x20) } // JSON chunk pads with spaces

        var out = Data(capacity: 12 + 8 + json.count + 8 + bin.count)
        out.appendLE(UInt32(0x4654_6C67))            // "glTF"
        out.appendLE(UInt32(2))
        out.appendLE(UInt32(12 + 8 + json.count + 8 + bin.count))
        out.appendLE(UInt32(json.count))
        out.appendLE(UInt32(0x4E4F_534A))            // "JSON"
        out.append(json)
        out.appendLE(UInt32(bin.count))
        out.appendLE(UInt32(0x004E_4942))            // "BIN\0"
        out.append(bin)
        return out
    }
}
