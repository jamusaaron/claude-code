import Foundation

/// Measurements of a 3D polygon traced by the user on a surface.
public struct PolygonMetrics: Sendable, Equatable {
    /// Area of the polygon projected onto its best-fit plane (m²).
    public var area: Double
    /// Closed perimeter, measured along the actual 3D edges (m).
    public var perimeter: Double
    /// Unit normal of the best-fit plane.
    public var normal: Vec3
    public var centroid: Vec3
    /// Largest distance from a vertex to the best-fit plane (m). Large values mean the user's
    /// points are not on one flat surface, so "area" is the area of a projection.
    public var maxPlaneDeviation: Double
    /// Deviation LiDAR tap noise can explain: max(1 cm, 0.5% of the outline's span).
    /// Beyond it the points are genuinely not on one flat surface.
    public var planarityTolerance: Double
    public var isSelfIntersecting: Bool

    public var isPlanar: Bool { maxPlaneDeviation <= planarityTolerance }
}

/// Why an outline can't be closed into a measurable polygon.
public enum PolygonIssue: Error, Equatable, Sendable {
    case tooFewPoints
    case duplicatePoints
    case degenerate
    case selfIntersecting

    public var message: String {
        switch self {
        case .tooFewPoints: return "An area needs at least three corners."
        case .duplicatePoints: return "Two corners are at the same spot. Undo the extra point."
        case .degenerate: return "The corners are in a line, so there is no area to measure."
        case .selfIntersecting: return "The outline crosses itself. Tap the corners in order around the edge."
        }
    }
}

public enum PolygonGeometry {
    /// Newell's method. For a planar polygon the vector's length is twice the area, and for a
    /// non-planar one it is twice the area of the projection onto the plane it defines, which is
    /// the most stable best-fit normal for a hand-placed polygon.
    public static func newellVector(_ points: [Vec3]) -> Vec3 {
        guard points.count >= 3 else { return .zero }
        var n = Vec3.zero
        for i in 0..<points.count {
            let a = points[i]
            let b = points[(i + 1) % points.count]
            n.x += (a.y - b.y) * (a.z + b.z)
            n.y += (a.z - b.z) * (a.x + b.x)
            n.z += (a.x - b.x) * (a.y + b.y)
        }
        return n
    }

    public static func centroid(_ points: [Vec3]) -> Vec3 {
        guard !points.isEmpty else { return .zero }
        return points.reduce(Vec3.zero, +) / Double(points.count)
    }

    public static func perimeter(_ points: [Vec3], closed: Bool = true) -> Double {
        guard points.count >= 2 else { return 0 }
        var total = 0.0
        for i in 0..<(points.count - 1) { total += Vec.distance(points[i], points[i + 1]) }
        if closed, points.count >= 3 { total += Vec.distance(points[points.count - 1], points[0]) }
        return total
    }

    public static func metrics(_ points: [Vec3]) -> PolygonMetrics? {
        guard points.count >= 3 else { return nil }
        let newell = newellVector(points)
        let twiceArea = Vec.length(newell)
        guard twiceArea > 1e-12 else { return nil }
        let normal = newell / twiceArea
        let c = centroid(points)
        let plane = Plane(unitNormal: normal, offset: Vec.dot(normal, c))
        let deviation = points.map { abs(plane.signedDistance($0)) }.max() ?? 0
        let flat = project(points, normal: normal, origin: c)
        return PolygonMetrics(
            area: twiceArea / 2,
            perimeter: perimeter(points),
            normal: normal,
            centroid: c,
            maxPlaneDeviation: deviation,
            planarityTolerance: planarityTolerance(points),
            isSelfIntersecting: isSelfIntersecting(flat)
        )
    }

    /// max(1 cm, 0.5% of the largest distance between any two corners).
    public static func planarityTolerance(_ points: [Vec3]) -> Double {
        var span = 0.0
        for i in 0..<points.count {
            for j in (i + 1)..<points.count { span = max(span, Vec.distance(points[i], points[j])) }
        }
        return max(0.01, 0.005 * span)
    }

    /// Checks an outline before it is closed. Crossing, touching, duplicate and collinear
    /// outlines are refused rather than turned into a misleading number.
    public static func validate(_ points: [Vec3], minimumSpacing: Double = 0.001, minimumArea: Double = 1e-6) -> PolygonIssue? {
        guard points.count >= 3 else { return .tooFewPoints }
        for i in 0..<points.count {
            for j in (i + 1)..<points.count where Vec.distance(points[i], points[j]) < minimumSpacing {
                return .duplicatePoints
            }
        }
        guard let m = metrics(points), m.area >= minimumArea else { return .degenerate }
        return m.isSelfIntersecting ? .selfIntersecting : nil
    }

    /// Orthonormal in-plane basis (u, v) with u × v == normal.
    public static func basis(for normal: Vec3) -> (u: Vec3, v: Vec3) {
        let u = Vec.anyPerpendicular(to: normal)
        let v = Vec.cross(normal, u)
        return (u, v)
    }

    public static func project(_ points: [Vec3], normal: Vec3, origin: Vec3) -> [Vec2] {
        let (u, v) = basis(for: normal)
        return points.map { p in
            let d = p - origin
            return Vec2(Vec.dot(d, u), Vec.dot(d, v))
        }
    }

    /// Signed area (counter-clockwise positive).
    public static func signedArea(_ points: [Vec2]) -> Double {
        guard points.count >= 3 else { return 0 }
        var s = 0.0
        for i in 0..<points.count {
            s += Vec.cross(points[i], points[(i + 1) % points.count])
        }
        return s / 2
    }

    /// True if any two non-adjacent edges cross.
    public static func isSelfIntersecting(_ points: [Vec2]) -> Bool {
        let n = points.count
        guard n >= 4 else { return false }
        for i in 0..<n {
            let a1 = points[i], a2 = points[(i + 1) % n]
            for j in (i + 1)..<n {
                // Skip edges that share a vertex.
                if j == i || (j + 1) % n == i || (i + 1) % n == j { continue }
                let b1 = points[j], b2 = points[(j + 1) % n]
                if segmentsIntersect(a1, a2, b1, b2) { return true }
            }
        }
        return false
    }

    /// Proper crossings, plus a vertex touching or overlapping the other segment.
    static func segmentsIntersect(_ p1: Vec2, _ p2: Vec2, _ q1: Vec2, _ q2: Vec2, epsilon: Double = 1e-10) -> Bool {
        func orient(_ a: Vec2, _ b: Vec2, _ c: Vec2) -> Double { Vec.cross(b - a, c - a) }
        func onSegment(_ a: Vec2, _ b: Vec2, _ p: Vec2) -> Bool {
            abs(orient(a, b, p)) <= epsilon
                && p.x >= min(a.x, b.x) - epsilon && p.x <= max(a.x, b.x) + epsilon
                && p.y >= min(a.y, b.y) - epsilon && p.y <= max(a.y, b.y) + epsilon
        }
        let d1 = orient(q1, q2, p1), d2 = orient(q1, q2, p2)
        let d3 = orient(p1, p2, q1), d4 = orient(p1, p2, q2)
        if ((d1 > epsilon && d2 < -epsilon) || (d1 < -epsilon && d2 > epsilon))
            && ((d3 > epsilon && d4 < -epsilon) || (d3 < -epsilon && d4 > epsilon)) {
            return true
        }
        return onSegment(q1, q2, p1) || onSegment(q1, q2, p2) || onSegment(p1, p2, q1) || onSegment(p1, p2, q2)
    }

    /// Ear-clipping triangulation of a simple polygon (convex or concave). Returns index
    /// triples into `points`, wound counter-clockwise around the Newell normal. Falls back to
    /// a fan for degenerate or self-intersecting input so rendering never fails.
    public static func triangulate(_ points: [Vec3]) -> [Int] {
        let n = points.count
        guard n >= 3 else { return [] }
        let newell = newellVector(points)
        guard Vec.lengthSquared(newell) > 1e-20 else { return fan(n) }
        let normal = Vec.normalize(newell)
        let flat = project(points, normal: normal, origin: centroid(points))

        var remaining = Array(0..<n)
        if signedArea(flat) < 0 { remaining.reverse() }
        var triangles: [Int] = []
        triangles.reserveCapacity((n - 2) * 3)

        var guardCounter = 0
        while remaining.count > 3 && guardCounter < n * n {
            guardCounter += 1
            var clipped = false
            for i in 0..<remaining.count {
                let prev = remaining[(i + remaining.count - 1) % remaining.count]
                let cur = remaining[i]
                let next = remaining[(i + 1) % remaining.count]
                let a = flat[prev], b = flat[cur], c = flat[next]
                // Convex corner?
                guard Vec.cross(b - a, c - b) > 1e-12 else { continue }
                // No other vertex inside the candidate ear.
                var containsOther = false
                for k in remaining where k != prev && k != cur && k != next {
                    if pointInTriangle(flat[k], a, b, c) { containsOther = true; break }
                }
                if containsOther { continue }
                triangles.append(contentsOf: [prev, cur, next])
                remaining.remove(at: i)
                clipped = true
                break
            }
            if !clipped { return fan(n) }
        }
        if remaining.count == 3 { triangles.append(contentsOf: remaining) }
        return triangles
    }

    static func fan(_ n: Int) -> [Int] {
        guard n >= 3 else { return [] }
        var t: [Int] = []
        for i in 1..<(n - 1) { t.append(contentsOf: [0, i, i + 1]) }
        return t
    }

    static func pointInTriangle(_ p: Vec2, _ a: Vec2, _ b: Vec2, _ c: Vec2) -> Bool {
        let d1 = Vec.cross(b - a, p - a)
        let d2 = Vec.cross(c - b, p - b)
        let d3 = Vec.cross(a - c, p - c)
        return d1 >= 0 && d2 >= 0 && d3 >= 0
    }

    /// Completes a parallelogram from three corners where `b` is the corner between `a` and
    /// `c`. Used by the 3-point rectangle helper when the fourth corner is hidden or awkward to reach.
    public static func completeParallelogram(_ a: Vec3, _ b: Vec3, _ c: Vec3) -> [Vec3] {
        [a, b, c, a + (c - b)]
    }
}
