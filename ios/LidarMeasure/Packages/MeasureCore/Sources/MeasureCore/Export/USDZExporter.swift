import Foundation

/// Writes a textured mesh as USDZ for AR Quick Look and RealityKit.
///
/// The package holds a text `model.usda` root layer plus the texture, stored uncompressed with
/// 64-byte aligned file data as the USDZ spec requires. AR Quick Look opens USDA-rooted packages
/// (three.js's USDZExporter, used by `<model-viewer>` for iOS AR, ships the same structure),
/// and writing text keeps the exporter dependency-free and testable. Units are metres with +Y up,
/// matching ARKit, so models open at true scale.
public enum USDZExporter {
    public static let rootLayerName = "model.usda"
    public static let textureName = "textures/texture.jpg"

    public static func makeUSDZ(mesh: TexturedMesh, material: MaterialSpec, textureJPEG: Data?) throws -> Data {
        let useTexture = material.usesTexture && mesh.hasTexture && textureJPEG != nil
        let usda = makeUSDA(mesh: mesh, material: material, texturePath: useTexture ? textureName : nil)
        var zip = ZipWriter(alignment: 64)
        try zip.addFile(name: rootLayerName, contents: usda)
        if useTexture, let jpeg = textureJPEG {
            try zip.addFile(name: textureName, contents: jpeg)
        }
        return zip.finalize()
    }

    public static func makeUSDA(mesh: TexturedMesh, material: MaterialSpec, texturePath: String?, rootName: String = "Scan") -> Data {
        let root = sanitizedIdentifier(rootName, fallback: "Scan")
        let materialName = sanitizedIdentifier(material.name, fallback: "ScanMaterial")
        let materialPath = "/\(root)/Materials/\(materialName)"
        let bounds = mesh.bounds ?? AABB(min: .zero, max: .zero)
        var t = TextBuffer(reserving: mesh.vertexCount * 90 + mesh.indices.count * 8 + 4096)

        t.append("#usda 1.0\n(\n")
        t.append("    customLayerData = {\n        string creator = \"LiDAR Measure\"\n    }\n")
        t.append("    defaultPrim = \"\(root)\"\n")
        t.append("    metersPerUnit = 1\n")
        t.append("    upAxis = \"Y\"\n)\n\n")

        t.append("def Xform \"\(root)\" (\n    kind = \"component\"\n)\n{\n")
        t.append("    def Mesh \"Geometry\" (\n        prepend apiSchemas = [\"MaterialBindingAPI\"]\n    )\n    {\n")
        t.append("        uniform bool doubleSided = 1\n")
        t.append("        float3[] extent = [")
        appendTuple(&t, bounds.min, decimals: 5)
        t.append(", ")
        appendTuple(&t, bounds.max, decimals: 5)
        t.append("]\n")

        t.append("        int[] faceVertexCounts = [")
        for f in 0..<mesh.triangleCount {
            if f > 0 { t.append(byte: UInt8(ascii: ",")) }
            t.append(byte: UInt8(ascii: "3"))
        }
        t.append("]\n")

        t.append("        int[] faceVertexIndices = [")
        for (n, i) in mesh.indices.enumerated() {
            if n > 0 { t.append(byte: UInt8(ascii: ",")) }
            t.append(i)
        }
        t.append("]\n")

        t.append("        rel material:binding = <\(materialPath)>\n")

        t.append("        normal3f[] normals = [")
        for (n, v) in mesh.normals.enumerated() {
            if n > 0 { t.append(byte: UInt8(ascii: ",")) }
            appendTuple(&t, v, decimals: 4)
        }
        t.append("] (\n            interpolation = \"vertex\"\n        )\n")

        t.append("        point3f[] points = [")
        for (n, v) in mesh.positions.enumerated() {
            if n > 0 { t.append(byte: UInt8(ascii: ",")) }
            appendTuple(&t, v, decimals: 5)
        }
        t.append("]\n")

        if texturePath != nil {
            // USD texture space has its origin at the bottom-left; ours is top-left.
            t.append("        texCoord2f[] primvars:st = [")
            for (n, uv) in mesh.uvs.enumerated() {
                if n > 0 { t.append(byte: UInt8(ascii: ",")) }
                t.append("(")
                t.append(uv.x, decimals: 6)
                t.append(",")
                t.append(1 - uv.y, decimals: 6)
                t.append(")")
            }
            t.append("] (\n            interpolation = \"vertex\"\n        )\n")
        }
        t.append("        uniform token subdivisionScheme = \"none\"\n    }\n\n")

        t.append("    def Scope \"Materials\"\n    {\n")
        t.append("        def Material \"\(materialName)\"\n        {\n")
        t.append("            token outputs:surface.connect = <\(materialPath)/PreviewSurface.outputs:surface>\n\n")
        t.append("            def Shader \"PreviewSurface\"\n            {\n")
        t.append("                uniform token info:id = \"UsdPreviewSurface\"\n")
        if texturePath != nil {
            t.append("                color3f inputs:diffuseColor.connect = <\(materialPath)/DiffuseTexture.outputs:rgb>\n")
        } else {
            t.append("                color3f inputs:diffuseColor = ")
            appendTuple(&t, material.baseColor, decimals: 4)
            t.append("\n")
        }
        t.append("                float inputs:metallic = ")
        t.append(material.metallic, decimals: 3)
        t.append("\n                float inputs:roughness = ")
        t.append(material.roughness, decimals: 3)
        t.append("\n                int inputs:useSpecularWorkflow = 0\n")
        t.append("                token outputs:surface\n            }\n")

        if let path = texturePath {
            t.append("\n            def Shader \"DiffuseTexture\"\n            {\n")
            t.append("                uniform token info:id = \"UsdUVTexture\"\n")
            t.append("                asset inputs:file = @\(path)@\n")
            t.append("                float4 inputs:scale = (")
            t.append(material.baseColor.x, decimals: 4); t.append(", ")
            t.append(material.baseColor.y, decimals: 4); t.append(", ")
            t.append(material.baseColor.z, decimals: 4); t.append(", 1)\n")
            t.append("                token inputs:sourceColorSpace = \"sRGB\"\n")
            t.append("                float2 inputs:st.connect = <\(materialPath)/STReader.outputs:result>\n")
            t.append("                token inputs:wrapS = \"clamp\"\n")
            t.append("                token inputs:wrapT = \"clamp\"\n")
            t.append("                float3 outputs:rgb\n            }\n")

            t.append("\n            def Shader \"STReader\"\n            {\n")
            t.append("                uniform token info:id = \"UsdPrimvarReader_float2\"\n")
            t.append("                string inputs:varname = \"st\"\n")
            t.append("                float2 outputs:result\n            }\n")
        }
        t.append("        }\n    }\n}\n")
        return t.data
    }

    private static func appendTuple(_ t: inout TextBuffer, _ v: Vec3f, decimals: Int) {
        t.append("(")
        t.append(v.x, decimals: decimals)
        t.append(",")
        t.append(v.y, decimals: decimals)
        t.append(",")
        t.append(v.z, decimals: decimals)
        t.append(")")
    }
}
