import ARKit
import Metal
import MeasureCore

/// Direct, copy-free access to an `ARMeshGeometry`'s Metal buffers.
///
/// Each `ARMeshAnchor` is a chunk of the reconstructed scene with vertices in the anchor's
/// local space. Buffers use shared storage, so the CPU can read them in place. Faces are
/// triangles of 32-bit indices on current devices; 16-bit is handled defensively.
struct MeshGeometryReader {
    let geometry: ARMeshGeometry
    private let vertexBase: UnsafeMutableRawPointer
    private let vertexStride: Int
    private let normalBase: UnsafeMutableRawPointer
    private let normalStride: Int
    private let faceBase: UnsafeMutableRawPointer
    private let bytesPerIndex: Int
    private let indicesPerFace: Int

    init(_ geometry: ARMeshGeometry) {
        self.geometry = geometry
        vertexBase = geometry.vertices.buffer.contents().advanced(by: geometry.vertices.offset)
        vertexStride = geometry.vertices.stride
        normalBase = geometry.normals.buffer.contents().advanced(by: geometry.normals.offset)
        normalStride = geometry.normals.stride
        faceBase = geometry.faces.buffer.contents()
        bytesPerIndex = geometry.faces.bytesPerIndex
        indicesPerFace = geometry.faces.indexCountPerPrimitive
    }

    var vertexCount: Int { geometry.vertices.count }
    var faceCount: Int { geometry.faces.count }

    @inline(__always) func vertex(_ i: Int) -> SIMD3<Float> {
        let p = vertexBase.advanced(by: i * vertexStride).assumingMemoryBound(to: Float.self)
        return SIMD3(p[0], p[1], p[2])
    }

    @inline(__always) func normal(_ i: Int) -> SIMD3<Float> {
        let p = normalBase.advanced(by: i * normalStride).assumingMemoryBound(to: Float.self)
        return SIMD3(p[0], p[1], p[2])
    }

    @inline(__always) func faceIndices(_ f: Int) -> (Int, Int, Int) {
        let base = faceBase.advanced(by: f * indicesPerFace * bytesPerIndex)
        if bytesPerIndex == 4 {
            return (Int(base.load(fromByteOffset: 0, as: UInt32.self)),
                    Int(base.load(fromByteOffset: 4, as: UInt32.self)),
                    Int(base.load(fromByteOffset: 8, as: UInt32.self)))
        }
        return (Int(base.load(fromByteOffset: 0, as: UInt16.self)),
                Int(base.load(fromByteOffset: 2, as: UInt16.self)),
                Int(base.load(fromByteOffset: 4, as: UInt16.self)))
    }

    /// Per-face classification (`ARMeshClassification.rawValue`), if the session provides it.
    func classification(_ f: Int) -> UInt8? {
        guard let source = geometry.classification, f < source.count else { return nil }
        let p = source.buffer.contents().advanced(by: source.offset + f * source.stride)
        return p.load(as: UInt8.self)
    }

    /// Local-space bounds of the chunk.
    func localBounds() -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard vertexCount > 0 else { return nil }
        var lo = vertex(0), hi = lo
        for i in 1..<vertexCount {
            let v = vertex(i)
            lo = simd_min(lo, v)
            hi = simd_max(hi, v)
        }
        return (lo, hi)
    }
}

/// Gathers LiDAR mesh triangles around a world point for edge/corner snapping.
///
/// Rather than mirroring the whole mesh (which ARKit updates constantly), each query walks only
/// the anchors whose cached bounds come near the point, in their local space, and returns the
/// handful of triangles inside the radius. A few hundred microseconds per query.
@MainActor
final class MeshSnapIndex {
    private struct CachedBounds {
        var vertexCount: Int
        var faceCount: Int
        var min: SIMD3<Float>
        var max: SIMD3<Float>
    }

    private var bounds: [UUID: CachedBounds] = [:]

    func forget(_ anchorIDs: [UUID]) {
        for id in anchorIDs { bounds.removeValue(forKey: id) }
    }

    func reset() { bounds.removeAll() }

    func triangles(near world: SIMD3<Float>, radius: Float, anchors: [ARMeshAnchor], limit: Int = 600) -> [SnapTriangle] {
        var out: [SnapTriangle] = []
        let r2 = radius * radius
        for anchor in anchors {
            let reader = MeshGeometryReader(anchor.geometry)
            let toLocal = anchor.transform.inverse
            let local = toLocal.transformPoint(world)

            // Cheap reject using cached local bounds (rebuilt when the chunk changes size).
            if let b = cachedBounds(for: anchor, reader: reader) {
                let clamped = simd_clamp(local, b.min, b.max)
                if simd_length_squared(clamped - local) > r2 { continue }
            } else {
                continue
            }

            for f in 0..<reader.faceCount {
                let (i, j, k) = reader.faceIndices(f)
                let a = reader.vertex(i), b = reader.vertex(j), c = reader.vertex(k)
                let centroid = (a + b + c) / 3
                guard simd_length_squared(centroid - local) <= r2 else { continue }
                let wa = anchor.transform.transformPoint(a)
                let wb = anchor.transform.transformPoint(b)
                let wc = anchor.transform.transformPoint(c)
                out.append(SnapTriangle(a: wa.asDouble, b: wb.asDouble, c: wc.asDouble))
                if out.count >= limit { return out }
            }
        }
        return out
    }

    private func cachedBounds(for anchor: ARMeshAnchor, reader: MeshGeometryReader) -> CachedBounds? {
        if let b = bounds[anchor.identifier], b.vertexCount == reader.vertexCount, b.faceCount == reader.faceCount {
            return b
        }
        guard let lb = reader.localBounds() else { return nil }
        let b = CachedBounds(vertexCount: reader.vertexCount, faceCount: reader.faceCount, min: lb.min, max: lb.max)
        bounds[anchor.identifier] = b
        return b
    }
}
