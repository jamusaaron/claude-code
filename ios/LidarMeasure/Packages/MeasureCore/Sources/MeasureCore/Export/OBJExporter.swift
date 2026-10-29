import Foundation

/// Wavefront OBJ + MTL writer. OBJ has no unit field; values are metres with +Y up, which is
/// what Blender, MeshLab and most CAD importers assume for scan data. V is flipped because OBJ
/// texture space has a bottom-left origin.
public enum OBJExporter {
    public struct Files {
        public var obj: Data
        public var mtl: Data
    }

    public static func makeOBJ(mesh: TexturedMesh, material: MaterialSpec, baseName: String = "model", textureFileName: String? = "texture.jpg") -> Files {
        let useTexture = material.usesTexture && mesh.hasTexture && textureFileName != nil
        let hasNormals = mesh.normals.count == mesh.vertexCount
        let materialName = sanitizedIdentifier(material.name, fallback: "ScanMaterial")

        var t = TextBuffer(reserving: mesh.vertexCount * 100 + mesh.triangleCount * 40)
        t.append("# LiDAR Measure scan export\n# Units: metres. Up axis: +Y.\n")
        t.append("# Vertices: \(mesh.vertexCount)  Triangles: \(mesh.triangleCount)\n")
        t.append("mtllib \(baseName).mtl\no Scan\n")
        for p in mesh.positions {
            t.append("v ")
            t.append(p.x, decimals: 5); t.append(" ")
            t.append(p.y, decimals: 5); t.append(" ")
            t.append(p.z, decimals: 5); t.append("\n")
        }
        if useTexture {
            for uv in mesh.uvs {
                t.append("vt ")
                t.append(uv.x, decimals: 6); t.append(" ")
                t.append(1 - uv.y, decimals: 6); t.append("\n")
            }
        }
        if hasNormals {
            for n in mesh.normals {
                t.append("vn ")
                t.append(n.x, decimals: 4); t.append(" ")
                t.append(n.y, decimals: 4); t.append(" ")
                t.append(n.z, decimals: 4); t.append("\n")
            }
        }
        t.append("usemtl \(materialName)\ns off\n")
        for f in 0..<mesh.triangleCount {
            t.append("f")
            for k in 0..<3 {
                let i = mesh.indices[f * 3 + k] + 1 // OBJ is 1-based
                t.append(" ")
                t.append(i)
                if useTexture || hasNormals {
                    t.append("/")
                    if useTexture { t.append(i) }
                    if hasNormals { t.append("/"); t.append(i) }
                }
            }
            t.append("\n")
        }

        var m = TextBuffer()
        m.append("# LiDAR Measure material\nnewmtl \(materialName)\n")
        let c = material.baseColor
        m.append("Ka 1 1 1\nKd ")
        m.append(c.x, decimals: 4); m.append(" ")
        m.append(c.y, decimals: 4); m.append(" ")
        m.append(c.z, decimals: 4)
        m.append("\nKs 0 0 0\nd 1\nillum 1\n")
        if useTexture, let tex = textureFileName { m.append("map_Kd \(tex)\n") }
        return Files(obj: t.data, mtl: m.data)
    }

    /// OBJ, MTL and texture packed into one zip so the share sheet hands over a single file.
    public static func makeZip(mesh: TexturedMesh, material: MaterialSpec, textureJPEG: Data?, baseName: String = "model") throws -> Data {
        let useTexture = material.usesTexture && mesh.hasTexture && textureJPEG != nil
        let files = makeOBJ(mesh: mesh, material: material, baseName: baseName, textureFileName: useTexture ? "texture.jpg" : nil)
        var zip = ZipWriter()
        try zip.addFile(name: "\(baseName).obj", contents: files.obj)
        try zip.addFile(name: "\(baseName).mtl", contents: files.mtl)
        if useTexture, let jpeg = textureJPEG { try zip.addFile(name: "texture.jpg", contents: jpeg) }
        return zip.finalize()
    }
}
