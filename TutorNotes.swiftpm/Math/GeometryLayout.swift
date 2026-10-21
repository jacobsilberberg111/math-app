import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Where angle marks and labels go on a polygon, so the tutor never has to guess label coordinates
/// (it used to put θ on the hypotenuse instead of inside the angle). Works for convex and concave
/// polygons given in either winding order.
enum GeometryLayout {
    static func unit(_ v: CGPoint) -> CGPoint {
        let len = hypot(v.x, v.y)
        return len < 1e-9 ? .zero : CGPoint(x: v.x / len, y: v.y / len)
    }

    static func sub(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func add(_ a: CGPoint, _ b: CGPoint, _ k: CGFloat = 1) -> CGPoint { CGPoint(x: a.x + b.x * k, y: a.y + b.y * k) }

    /// Ray-casting point-in-polygon test.
    static func isInside(_ p: CGPoint, _ poly: [CGPoint]) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in poly.indices {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y) {
                let x = a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x)
                if p.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// Unit vectors from vertex `i` along its two sides (towards the previous and next vertex).
    static func arms(_ poly: [CGPoint], _ i: Int) -> (toPrev: CGPoint, toNext: CGPoint) {
        let n = poly.count
        let v = poly[i]
        return (unit(sub(poly[(i - 1 + n) % n], v)), unit(sub(poly[(i + 1) % n], v)))
    }

    /// Unit vector from vertex `i` into the polygon, splitting its interior angle in half, and the
    /// interior angle itself in radians (more than π at a reflex corner).
    static func interiorBisector(_ poly: [CGPoint], _ i: Int) -> (direction: CGPoint, angle: CGFloat) {
        let (u, w) = arms(poly, i)
        var b = unit(add(u, w))
        if b == .zero { b = CGPoint(x: -u.y, y: u.x) }
        let between = acos(max(-1, min(1, u.x * w.x + u.y * w.y)))
        // Probe a hair along the bisector, scaled to the figure so tiny or huge figures both work.
        let probe = max(0.01, min(shortestArm(poly, i), 40) * 0.05)
        if isInside(add(poly[i], b, probe), poly) {
            return (b, between)
        }
        return (CGPoint(x: -b.x, y: -b.y), 2 * .pi - between)
    }

    /// Unit normal of side `i` (from vertex i to vertex i+1) pointing out of the polygon.
    static func outwardNormal(_ poly: [CGPoint], side i: Int) -> CGPoint {
        let a = poly[i], b = poly[(i + 1) % poly.count]
        let d = unit(sub(b, a))
        var n = CGPoint(x: -d.y, y: d.x)
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let probe = max(0.01, hypot(b.x - a.x, b.y - a.y) * 0.02)
        if isInside(add(mid, n, probe), poly) { n = CGPoint(x: -n.x, y: -n.y) }
        return n
    }

    /// Length of the shorter side meeting at vertex `i`.
    static func shortestArm(_ poly: [CGPoint], _ i: Int) -> CGFloat {
        let n = poly.count
        let v = poly[i], p = poly[(i - 1 + n) % n], q = poly[(i + 1) % n]
        return min(hypot(p.x - v.x, p.y - v.y), hypot(q.x - v.x, q.y - v.y))
    }

    /// A good radius for the angle arc at vertex `i`.
    static func arcRadius(_ poly: [CGPoint], _ i: Int) -> CGFloat {
        max(6, min(18, shortestArm(poly, i) * 0.22))
    }

    /// Points of an arc inside the angle at vertex `i`, from one side to the other.
    static func angleArc(_ poly: [CGPoint], _ i: Int, radius r: CGFloat) -> [CGPoint] {
        let (u, w) = arms(poly, i)
        let (b, _) = interiorBisector(poly, i)
        let a0 = atan2(u.y, u.x), a1 = atan2(w.y, w.x), mid = atan2(b.y, b.x)
        var d = a1 - a0
        while d > .pi { d -= 2 * .pi }
        while d <= -.pi { d += 2 * .pi }
        // Go whichever way round passes through the inside of the angle.
        let other = d > 0 ? d - 2 * .pi : d + 2 * .pi
        if cos(a0 + other / 2 - mid) > cos(a0 + d / 2 - mid) { d = other }
        let steps = max(8, Int(abs(d) * r / 2.5))
        let v = poly[i]
        return (0...steps).map { k in
            let t = a0 + d * CGFloat(k) / CGFloat(steps)
            return CGPoint(x: v.x + r * cos(t), y: v.y + r * sin(t))
        }
    }

    /// The little square marking a right angle at vertex `i`.
    static func rightAngleMark(_ poly: [CGPoint], _ i: Int) -> [CGPoint] {
        let (u, w) = arms(poly, i)
        let s = max(5, min(13, shortestArm(poly, i) * 0.18))
        let v = poly[i]
        return [add(v, u, s), add(add(v, u, s), w, s), add(v, w, s)]
    }

    /// Short strokes across the middle of side `i` marking equal sides (1–3 ticks).
    static func sideTicks(_ poly: [CGPoint], side i: Int, count: Int) -> [[CGPoint]] {
        let a = poly[i], b = poly[(i + 1) % poly.count]
        let d = unit(sub(b, a)), n = CGPoint(x: -d.y, y: d.x)
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let spacing: CGFloat = 4.5, half: CGFloat = 5
        return (0..<max(1, min(3, count))).map { k in
            let offset = (CGFloat(k) - CGFloat(count - 1) / 2) * spacing
            let c = add(mid, d, offset)
            return [add(c, n, -half), add(c, n, half)]
        }
    }

    /// Radius of the circle around a label box, used to keep it clear of lines.
    static func labelRadius(_ size: CGSize) -> CGFloat { hypot(size.width, size.height) / 2 }

    /// Centre for a label inside the angle at vertex `i`: on the bisector, just past the arc, and far
    /// enough out that a narrow angle still fits it between its two sides.
    static func angleLabelCenter(_ poly: [CGPoint], _ i: Int, labelSize: CGSize, arcRadius r: CGFloat) -> CGPoint {
        let (b, angle) = interiorBisector(poly, i)
        let rho = labelRadius(labelSize) * 0.8
        let half = min(angle, 2 * .pi - angle) / 2
        let fit = rho / max(sin(half), 0.2)
        let dist = max(r + rho + 3, fit)
        return add(poly[i], b, dist)
    }

    /// Centre for a vertex name, just outside the corner.
    static func vertexLabelCenter(_ poly: [CGPoint], _ i: Int, labelSize: CGSize) -> CGPoint {
        let (b, _) = interiorBisector(poly, i)
        return add(poly[i], b, -(labelRadius(labelSize) * 0.75 + 6))
    }

    /// Centre for a side label, just outside the middle of side `i`.
    static func sideLabelCenter(_ poly: [CGPoint], side i: Int, labelSize: CGSize, extra: CGFloat = 0) -> CGPoint {
        let a = poly[i], b = poly[(i + 1) % poly.count]
        let n = outwardNormal(poly, side: i)
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let dist = 7 + extra + abs(n.x) * labelSize.width / 2 + abs(n.y) * labelSize.height / 2
        return add(mid, n, dist)
    }

    /// Whether the angle at vertex `i` is a right angle (within 1.5°).
    static func isRightAngle(_ poly: [CGPoint], _ i: Int) -> Bool {
        abs(interiorBisector(poly, i).angle - .pi / 2) < 1.5 * .pi / 180
    }
}
