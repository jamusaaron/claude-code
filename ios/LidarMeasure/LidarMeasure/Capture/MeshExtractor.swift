import ARKit
import simd
import MeasureCore

/// Copies the reconstructed LiDAR mesh (all `ARMeshAnchor` chunks) into one world-space mesh.
///
/// Vertices come in each anchor's local space; they are transformed by the anchor's transform
/// at the moment of capture. Chunks overlap by a vertex at their borders; the cleanup pipeline
/// welds those duplicates. Per-face ARKit classification (floor, wall, table, ...) is kept when
/// the session provides it.
enum MeshExtractor {
    /// Safe to call off the main thread as long as the anchors are kept alive.
    static func extract(_ anchors: [ARMeshAnchor], region: OrientedBox?) -> TriangleMesh {
        var mesh = TriangleMesh()
        let regionBounds = region.map { $0.worldBounds.expanded(by: 0.1) }

        for anchor in anchors {
            let reader = MeshGeometryReader(anchor.geometry)
            let vertexCount = reader.vertexCount
            guard reader.faceCount > 0, vertexCount > 0 else { continue }
            let transform = anchor.transform

            var chunk = TriangleMesh()
            chunk.positions.reserveCapacity(vertexCount)
            for i in 0..<vertexCount {
                chunk.positions.append(transform.transformPoint(reader.vertex(i)))
            }
            if let rb = regionBounds, let cb = AABB(points: chunk.positions), !cb.intersects(rb) { continue }

            chunk.normals.reserveCapacity(vertexCount)
            for i in 0..<vertexCount {
                let n = simd_normalize(transform.transformDirection(reader.normal(i)))
                chunk.normals.append(n.x.isFinite && n.y.isFinite && n.z.isFinite ? n : SIMD3(0, 1, 0))
            }

            let hasClassification = anchor.geometry.classification != nil
            chunk.indices.reserveCapacity(reader.faceCount * 3)
            for f in 0..<reader.faceCount {
                let (a, b, c) = reader.faceIndices(f)
                guard a < vertexCount, b < vertexCount, c < vertexCount else { continue }
                chunk.indices.append(contentsOf: [UInt32(a), UInt32(b), UInt32(c)])
                if hasClassification { chunk.faceClassifications.append(reader.classification(f) ?? 0) }
            }

            // ARKit faces are counter-clockwise when seen from the side the normals point to.
            // Verify against the supplied normals rather than assume it, so exports never come
            // out inside-out.
            if MeshProcessing.windingAgreement(chunk) < 0.5 {
                let normals = chunk.normals
                chunk.flipWinding()
                chunk.normals = normals
            }
            mesh.append(chunk)
        }
        return mesh
    }

    /// Total vertex/face counts for the live memory budget.
    static func counts(_ anchors: [ARMeshAnchor]) -> (vertices: Int, faces: Int) {
        anchors.reduce((0, 0)) { ($0.0 + $1.geometry.vertices.count, $0.1 + $1.geometry.faces.count) }
    }
}
