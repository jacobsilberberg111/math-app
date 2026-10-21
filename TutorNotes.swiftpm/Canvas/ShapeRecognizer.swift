import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A shape the student meant to draw. Produced by draw-and-hold, Notability style.
enum RecognizedShape: Equatable {
    case line(CGPoint, CGPoint)
    case polygon([CGPoint])            // closed: triangle, quadrilateral, rectangle
    case ellipse(center: CGPoint, rx: CGFloat, ry: CGFloat, rotation: CGFloat)

    var name: String {
        switch self {
        case .line: return "Line"
        case .polygon(let pts): return pts.count == 3 ? "Triangle" : (pts.count == 4 ? "Rectangle" : "Polygon")
        case .ellipse(_, let rx, let ry, _): return abs(rx - ry) < 0.5 ? "Circle" : "Ellipse"
        }
    }

    /// Points along the outline, densely sampled, for building an ink stroke. Corners are repeated
    /// so PencilKit's spline smoothing keeps them sharp.
    func outline(spacing: CGFloat = 3) -> [CGPoint] {
        switch self {
        case .line(let a, let b):
            return ShapeGeometry.densify([a, b], spacing: spacing, cornerRepeat: 1)
        case .polygon(let pts):
            return ShapeGeometry.densify(pts + [pts[0]], spacing: spacing, cornerRepeat: 3)
        case .ellipse(let c, let rx, let ry, let rot):
            let perimeter = 2 * CGFloat.pi * sqrt((rx * rx + ry * ry) / 2)
            let n = max(24, Int(perimeter / spacing))
            var out: [CGPoint] = []
            for i in 0...n {
                let t = CGFloat(i) / CGFloat(n) * 2 * .pi
                let x = rx * cos(t), y = ry * sin(t)
                out.append(CGPoint(x: c.x + x * cos(rot) - y * sin(rot), y: c.y + x * sin(rot) + y * cos(rot)))
            }
            return out
        }
    }

    /// The shape rescaled so that its bounding box spans from `anchor` to `point` (used while the
    /// pencil keeps moving after a snap, so the student can adjust the size before lifting).
    func adjusted(anchor: CGPoint, original: CGPoint, to point: CGPoint) -> RecognizedShape {
        if case .line(let a, _) = self {
            return .line(a, ShapeGeometry.snapAngle(from: a, to: point))
        }
        let ox = original.x - anchor.x, oy = original.y - anchor.y
        let sx = abs(ox) > 4 ? (point.x - anchor.x) / ox : 1
        let sy = abs(oy) > 4 ? (point.y - anchor.y) / oy : 1
        func map(_ p: CGPoint) -> CGPoint {
            CGPoint(x: anchor.x + (p.x - anchor.x) * sx, y: anchor.y + (p.y - anchor.y) * sy)
        }
        switch self {
        case .line: return self
        case .polygon(let pts): return .polygon(pts.map(map))
        case .ellipse(let c, let rx, let ry, let rot):
            let isCircle = abs(rx - ry) < 0.5
            let s = isCircle ? max(abs(sx), abs(sy)) : 1
            return .ellipse(center: map(c), rx: isCircle ? rx * s : rx * abs(sx), ry: isCircle ? ry * s : ry * abs(sy), rotation: rot)
        }
    }
}

enum ShapeRecognizer {
    /// Returns nil when the stroke doesn't look like a clean geometric shape.
    static func recognize(_ raw: [CGPoint]) -> RecognizedShape? {
        let cleaned = ShapeGeometry.dedupe(raw, minDistance: 1)
        guard cleaned.count >= 4 else { return nil }
        let length = ShapeGeometry.pathLength(cleaned)
        guard length > 24 else { return nil }
        let pts = ShapeGeometry.resample(cleaned, count: 96)
        let bounds = ShapeGeometry.bounds(pts)
        let diag = hypot(bounds.width, bounds.height)
        guard diag > 16 else { return nil }
        let first = pts.first!, last = pts.last!
        let chord = hypot(last.x - first.x, last.y - first.y)

        // Straight line: everything hugs the chord.
        if chord > 0.86 * length {
            let maxDev = pts.map { ShapeGeometry.distance(from: $0, toSegment: first, last) }.max() ?? 0
            if maxDev <= max(3.5, 0.06 * chord) {
                return .line(first, ShapeGeometry.snapAngle(from: first, to: last))
            }
        }

        // Closed shapes: the end comes back near the start.
        let closed = chord < max(0.22 * max(bounds.width, bounds.height), 12) || chord < 0.12 * length
        guard closed else { return nil }

        var loop = pts
        if chord > 1 { loop.append(first) }

        let ellipse = fitEllipse(loop)
        let polygon = fitPolygon(loop, diag: diag)

        var bestPolygon: RecognizedShape?
        if let polygon, polygon.vertices.count == 3 || polygon.vertices.count == 4 {
            if polygon.vertices.count == 4, let rect = rectangle(from: polygon.vertices) {
                bestPolygon = .polygon(rect)
            } else {
                bestPolygon = .polygon(polygon.vertices)
            }
        }

        if let polygon, let bestPolygon, polygon.error < ellipse.error * 0.9 {
            return bestPolygon
        }
        if ellipse.error < 0.12 {
            return ellipse.shape
        }
        return bestPolygon
    }

    // MARK: Ellipse

    static func fitEllipse(_ pts: [CGPoint]) -> (shape: RecognizedShape, error: CGFloat) {
        let n = CGFloat(pts.count)
        let cx = pts.reduce(0) { $0 + $1.x } / n
        let cy = pts.reduce(0) { $0 + $1.y } / n
        var sxx: CGFloat = 0, syy: CGFloat = 0, sxy: CGFloat = 0
        for p in pts {
            let dx = p.x - cx, dy = p.y - cy
            sxx += dx * dx; syy += dy * dy; sxy += dx * dy
        }
        sxx /= n; syy /= n; sxy /= n
        var angle = 0.5 * atan2(2 * sxy, sxx - syy)
        // Radii from the extent along the principal axes.
        var maxU: CGFloat = 0, maxV: CGFloat = 0
        var sumU: CGFloat = 0, sumV: CGFloat = 0
        for p in pts {
            let dx = p.x - cx, dy = p.y - cy
            let u = abs(dx * cos(angle) + dy * sin(angle))
            let v = abs(-dx * sin(angle) + dy * cos(angle))
            maxU = max(maxU, u); maxV = max(maxV, v)
            sumU += u * u; sumV += v * v
        }
        // For points on an ellipse, mean(u²) = a²/2.
        var rx = sqrt(2 * sumU / n)
        var ry = sqrt(2 * sumV / n)
        rx = (rx + maxU) / 2
        ry = (ry + maxV) / 2
        guard rx > 2, ry > 2 else { return (.ellipse(center: CGPoint(x: cx, y: cy), rx: rx, ry: ry, rotation: angle), 1) }

        var err: CGFloat = 0
        for p in pts {
            let dx = p.x - cx, dy = p.y - cy
            let u = dx * cos(angle) + dy * sin(angle)
            let v = -dx * sin(angle) + dy * cos(angle)
            let r = sqrt((u * u) / (rx * rx) + (v * v) / (ry * ry))
            err += abs(r - 1)
        }
        err /= n

        // Snap: near-circles become circles, near-axis ellipses become axis aligned.
        let ratio = min(rx, ry) / max(rx, ry)
        if ratio > 0.82 {
            let r = (rx + ry) / 2
            rx = r; ry = r; angle = 0
        } else {
            let deg = angle * 180 / .pi
            let nearest = (deg / 90).rounded() * 90
            if abs(deg - nearest) < 10 {
                angle = nearest * .pi / 180
                if Int((nearest / 90).rounded()) % 2 != 0 { angle = 0; swap(&rx, &ry) }
                else { angle = 0 }
            }
        }
        return (.ellipse(center: CGPoint(x: cx, y: cy), rx: rx, ry: ry, rotation: angle), err)
    }

    // MARK: Polygon

    static func fitPolygon(_ loop: [CGPoint], diag: CGFloat) -> (vertices: [CGPoint], error: CGFloat)? {
        guard loop.count > 8 else { return nil }
        // Anchor on the two points farthest apart so no corner gets split at the seam.
        var bestI = 0, bestJ = 0
        var bestD: CGFloat = 0
        let step = max(1, loop.count / 48)
        for i in stride(from: 0, to: loop.count, by: step) {
            for j in stride(from: i + 1, to: loop.count, by: step) {
                let d = hypot(loop[i].x - loop[j].x, loop[i].y - loop[j].y)
                if d > bestD { bestD = d; bestI = i; bestJ = j }
            }
        }
        let ring = Array(loop.dropLast()) // last == first
        guard ring.count > 6 else { return nil }
        let a = min(bestI, ring.count - 1), b = min(bestJ, ring.count - 1)
        guard a != b else { return nil }
        let firstHalf = Array(ring[a...b])
        let secondHalf = Array(ring[b...] + ring[...a])
        let epsilon = max(4, diag * 0.075)
        let s1 = ShapeGeometry.douglasPeucker(firstHalf, epsilon: epsilon)
        let s2 = ShapeGeometry.douglasPeucker(secondHalf, epsilon: epsilon)
        var vertices = Array(s1.dropLast()) + Array(s2.dropLast())
        vertices = ShapeGeometry.mergeClose(vertices, threshold: diag * 0.12)
        vertices = ShapeGeometry.removeCollinear(vertices, toleranceDegrees: 22)
        guard vertices.count >= 3 else { return nil }

        var err: CGFloat = 0
        for p in loop {
            var best = CGFloat.greatestFiniteMagnitude
            for k in 0..<vertices.count {
                best = min(best, ShapeGeometry.distance(from: p, toSegment: vertices[k], vertices[(k + 1) % vertices.count]))
            }
            err += best
        }
        err /= CGFloat(loop.count)
        return (vertices, err / max(diag, 1) * 4)
    }

    /// Turns a near-rectangular quad into a clean rectangle (axis-aligned if close to it).
    static func rectangle(from quad: [CGPoint]) -> [CGPoint]? {
        guard quad.count == 4 else { return nil }
        for k in 0..<4 {
            let p0 = quad[(k + 3) % 4], p1 = quad[k], p2 = quad[(k + 1) % 4]
            let angle = ShapeGeometry.angleDegrees(p0, p1, p2)
            if abs(angle - 90) > 18 { return nil }
        }
        let edge = CGPoint(x: quad[1].x - quad[0].x, y: quad[1].y - quad[0].y)
        var rot = atan2(edge.y, edge.x)
        // Normalise to [-45°, 45°].
        while rot > .pi / 4 { rot -= .pi / 2 }
        while rot < -.pi / 4 { rot += .pi / 2 }
        if abs(rot) < 8 * .pi / 180 {
            let b = ShapeGeometry.bounds(quad)
            return [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY),
                    CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.minX, y: b.maxY)]
        }
        // Rotated rectangle in the frame of `rot`.
        let c = CGPoint(x: quad.reduce(0) { $0 + $1.x } / 4, y: quad.reduce(0) { $0 + $1.y } / 4)
        var minU = CGFloat.greatestFiniteMagnitude, maxU = -CGFloat.greatestFiniteMagnitude
        var minV = CGFloat.greatestFiniteMagnitude, maxV = -CGFloat.greatestFiniteMagnitude
        for p in quad {
            let dx = p.x - c.x, dy = p.y - c.y
            let u = dx * cos(rot) + dy * sin(rot)
            let v = -dx * sin(rot) + dy * cos(rot)
            minU = min(minU, u); maxU = max(maxU, u); minV = min(minV, v); maxV = max(maxV, v)
        }
        let hu = (maxU - minU) / 2 * 0.96, hv = (maxV - minV) / 2 * 0.96
        let corners = [(-hu, -hv), (hu, -hv), (hu, hv), (-hu, hv)]
        return corners.map { (u, v) in
            CGPoint(x: c.x + u * cos(rot) - v * sin(rot), y: c.y + u * sin(rot) + v * cos(rot))
        }
    }
}

enum ShapeGeometry {
    static func dedupe(_ pts: [CGPoint], minDistance: CGFloat) -> [CGPoint] {
        var out: [CGPoint] = []
        for p in pts {
            if let last = out.last, hypot(p.x - last.x, p.y - last.y) < minDistance { continue }
            out.append(p)
        }
        return out
    }

    static func pathLength(_ pts: [CGPoint]) -> CGFloat {
        guard pts.count > 1 else { return 0 }
        var total: CGFloat = 0
        for i in 1..<pts.count { total += hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y) }
        return total
    }

    static func resample(_ pts: [CGPoint], count: Int) -> [CGPoint] {
        guard pts.count > 1, count > 1 else { return pts }
        let total = pathLength(pts)
        guard total > 0 else { return pts }
        let interval = total / CGFloat(count - 1)
        var out: [CGPoint] = [pts[0]]
        var accumulated: CGFloat = 0
        var prev = pts[0]
        var i = 1
        while i < pts.count {
            let cur = pts[i]
            let d = hypot(cur.x - prev.x, cur.y - prev.y)
            if accumulated + d >= interval && d > 0 {
                let t = (interval - accumulated) / d
                let q = CGPoint(x: prev.x + t * (cur.x - prev.x), y: prev.y + t * (cur.y - prev.y))
                out.append(q)
                prev = q
                accumulated = 0
            } else {
                accumulated += d
                prev = cur
                i += 1
            }
        }
        if out.count < count, let last = pts.last { out.append(last) }
        return out
    }

    static func bounds(_ pts: [CGPoint]) -> CGRect {
        guard let f = pts.first else { return .zero }
        var minX = f.x, maxX = f.x, minY = f.y, maxY = f.y
        for p in pts {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 == 0 { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
        t = max(0, min(1, t))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    static func douglasPeucker(_ pts: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard pts.count > 2 else { return pts }
        var maxD: CGFloat = 0
        var index = 0
        for i in 1..<(pts.count - 1) {
            let d = distance(from: pts[i], toSegment: pts[0], pts[pts.count - 1])
            if d > maxD { maxD = d; index = i }
        }
        if maxD > epsilon {
            let left = douglasPeucker(Array(pts[0...index]), epsilon: epsilon)
            let right = douglasPeucker(Array(pts[index...]), epsilon: epsilon)
            return Array(left.dropLast()) + right
        }
        return [pts[0], pts[pts.count - 1]]
    }

    static func mergeClose(_ pts: [CGPoint], threshold: CGFloat) -> [CGPoint] {
        var out: [CGPoint] = []
        for p in pts {
            if let last = out.last, hypot(p.x - last.x, p.y - last.y) < threshold {
                out[out.count - 1] = CGPoint(x: (p.x + last.x) / 2, y: (p.y + last.y) / 2)
            } else {
                out.append(p)
            }
        }
        if out.count > 2, let f = out.first, let l = out.last, hypot(f.x - l.x, f.y - l.y) < threshold {
            out[0] = CGPoint(x: (f.x + l.x) / 2, y: (f.y + l.y) / 2)
            out.removeLast()
        }
        return out
    }

    static func removeCollinear(_ pts: [CGPoint], toleranceDegrees: CGFloat) -> [CGPoint] {
        var out = pts
        var changed = true
        while changed && out.count > 3 {
            changed = false
            for k in 0..<out.count {
                let p0 = out[(k + out.count - 1) % out.count], p1 = out[k], p2 = out[(k + 1) % out.count]
                if abs(angleDegrees(p0, p1, p2) - 180) < toleranceDegrees {
                    out.remove(at: k)
                    changed = true
                    break
                }
            }
        }
        return out
    }

    /// Interior angle at p1 in degrees (0...180).
    static func angleDegrees(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint) -> CGFloat {
        let v1 = CGPoint(x: p0.x - p1.x, y: p0.y - p1.y)
        let v2 = CGPoint(x: p2.x - p1.x, y: p2.y - p1.y)
        let l1 = hypot(v1.x, v1.y), l2 = hypot(v2.x, v2.y)
        guard l1 > 0, l2 > 0 else { return 180 }
        let cosA = max(-1, min(1, (v1.x * v2.x + v1.y * v2.y) / (l1 * l2)))
        return acos(cosA) * 180 / .pi
    }

    /// Snaps the direction a→b to horizontal/vertical/45° when within a few degrees.
    static func snapAngle(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        guard len > 0 else { return b }
        let angle = atan2(dy, dx)
        let step = CGFloat.pi / 4
        let snapped = (angle / step).rounded() * step
        if abs(angle - snapped) < 4 * .pi / 180 {
            return CGPoint(x: a.x + len * cos(snapped), y: a.y + len * sin(snapped))
        }
        return b
    }

    /// Evenly spaced points along a polyline; each vertex repeated `cornerRepeat` times.
    static func densify(_ pts: [CGPoint], spacing: CGFloat, cornerRepeat: Int) -> [CGPoint] {
        guard pts.count > 1 else { return pts }
        var out: [CGPoint] = []
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            for _ in 0..<cornerRepeat { out.append(a) }
            let d = hypot(b.x - a.x, b.y - a.y)
            let n = max(1, Int(d / spacing))
            for k in 1..<n {
                let t = CGFloat(k) / CGFloat(n)
                out.append(CGPoint(x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y)))
            }
        }
        for _ in 0..<cornerRepeat { out.append(pts[pts.count - 1]) }
        return out
    }
}
