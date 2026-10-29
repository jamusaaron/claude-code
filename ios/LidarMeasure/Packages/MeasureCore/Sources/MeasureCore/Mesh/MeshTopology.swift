import Foundation

/// Edge-level topology of an indexed triangle mesh (vertices must already be welded).
///
/// A volume is only trustworthy when the surface actually encloses it. Closed means every
/// edge is shared by exactly two faces; consistent means those two faces traverse the edge in
/// opposite directions (so all normals point the same way); one component means it is a
/// single object, not several pieces whose volumes would be silently added together.
public struct MeshTopology: Sendable, Equatable {
    /// Edges used by one face: holes or the open bottom of a scan.
    public var boundaryEdges: Int
    /// Edges used by three or more faces.
    public var nonManifoldEdges: Int
    /// Two-face edges whose faces are wound in the same direction (flipped neighbours).
    public var inconsistentEdges: Int
    public var totalEdges: Int
    /// Edge-connected pieces.
    public var components: Int

    public var isClosedManifold: Bool {
        totalEdges > 0 && boundaryEdges == 0 && nonManifoldEdges == 0 && inconsistentEdges == 0
    }

    public var isConsistentlyOriented: Bool { inconsistentEdges == 0 }

    public static func analyse(indices: [UInt32]) -> MeshTopology {
        struct EdgeKey: Hashable { let a: UInt32; let b: UInt32 }
        struct EdgeUse { var count = 0; var direction = 0; var firstFace = -1 }

        let faceCount = indices.count / 3
        var edges: [EdgeKey: EdgeUse] = [:]
        edges.reserveCapacity(indices.count)
        var parent = Array(0..<faceCount)
        func root(_ x: Int) -> Int {
            var i = x
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }

        for f in 0..<faceCount {
            for e in 0..<3 {
                let i = indices[f * 3 + e], j = indices[f * 3 + (e + 1) % 3]
                let key = EdgeKey(a: min(i, j), b: max(i, j))
                var use = edges[key, default: EdgeUse()]
                use.count += 1
                use.direction += i < j ? 1 : -1
                if use.firstFace < 0 {
                    use.firstFace = f
                } else {
                    let ra = root(f), rb = root(use.firstFace)
                    if ra != rb { parent[ra] = rb }
                }
                edges[key] = use
            }
        }

        var boundary = 0, nonManifold = 0, inconsistent = 0
        for use in edges.values {
            switch use.count {
            case 1: boundary += 1
            case 2: if use.direction != 0 { inconsistent += 1 }
            default: nonManifold += 1
            }
        }
        var roots = Set<Int>()
        for f in 0..<faceCount { roots.insert(root(f)) }
        return MeshTopology(boundaryEdges: boundary, nonManifoldEdges: nonManifold, inconsistentEdges: inconsistent,
                            totalEdges: edges.count, components: roots.count)
    }
}
