import Foundation

/// Shape snapping: squares, equilateral triangles, pentagons and hexagons, 15° lines, and circles
/// that resize without drifting.
func runShapeTests() {
    /// A closed hand-drawn polygon: points along each side with a little wobble.
    func polygon(_ corners: [CGPoint], wobble: Double = 1.5) -> [CGPoint] {
        var pts: [CGPoint] = []
        for k in 0..<corners.count {
            let a = corners[k], b = corners[(k + 1) % corners.count]
            for i in 0..<20 {
                let t = CGFloat(i) / 20
                let j = CGFloat(sin(Double(k * 20 + i) * 1.9) * wobble)
                pts.append(CGPoint(x: a.x + (b.x - a.x) * t + j, y: a.y + (b.y - a.y) * t - j))
            }
        }
        pts.append(corners[0])
        return pts
    }
    func regular(_ n: Int, r: CGFloat = 100, c: CGPoint = CGPoint(x: 300, y: 300), start: CGFloat = -.pi / 2) -> [CGPoint] {
        (0..<n).map { k in
            let a = start + 2 * .pi * CGFloat(k) / CGFloat(n)
            return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
        }
    }
    func sides(_ v: [CGPoint]) -> [CGFloat] {
        var out: [CGFloat] = []
        for k in 0..<v.count {
            let a = v[k], b = v[(k + 1) % v.count]
            out.append(hypot(b.x - a.x, b.y - a.y))
        }
        return out
    }

    // A slightly uneven rectangle (100 × 106) becomes a square.
    let nearSquare = polygon([CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100), CGPoint(x: 200, y: 206), CGPoint(x: 100, y: 206)])
    if let shape = ShapeRecognizer.recognize(nearSquare), case .polygon(let v) = shape {
        let s = sides(v)
        check(v.count == 4 && (s.max()! - s.min()!) < 0.5, "near-square snaps to a square: \(s)")
        check(shape.name == "Square", "named Square: \(shape.name)")
    } else { check(false, "near-square recognised") }
    // A clearly long rectangle stays a rectangle.
    let longRect = polygon([CGPoint(x: 100, y: 100), CGPoint(x: 260, y: 100), CGPoint(x: 260, y: 180), CGPoint(x: 100, y: 180)])
    if let shape = ShapeRecognizer.recognize(longRect) { check(shape.name == "Rectangle", "long rectangle stays a rectangle: \(shape.name)") }

    // Near-equilateral triangle → equilateral.
    var tri = regular(3)
    tri[1].x += 6
    if case .polygon(let v)? = ShapeRecognizer.recognize(polygon(tri)) {
        let s = sides(v)
        check(v.count == 3 && (s.max()! - s.min()!) < 0.5, "equilateral snap: \(s)")
    } else { check(false, "triangle recognised") }

    // Pentagon and hexagon.
    for n in [5, 6] {
        let shape = ShapeRecognizer.recognize(polygon(regular(n), wobble: 1))
        if let shape, case .polygon(let v) = shape {
            check(v.count == n, "\(n)-gon has \(n) corners, got \(v.count)")
            check(shape.name == (n == 5 ? "Pentagon" : "Hexagon"), "named \(shape.name)")
        } else {
            check(false, "\(n)-gon recognised: \(String(describing: shape))")
        }
    }

    // A wobbly circle is still a circle, not a hexagon.
    let circle = (0...80).map { i -> CGPoint in
        let t = Double(i) / 80 * 2 * .pi
        let r = 80 + sin(Double(i) * 1.3) * 2
        return CGPoint(x: 300 + r * cos(t), y: 300 + r * sin(t))
    }
    if case .ellipse? = ShapeRecognizer.recognize(circle) {} else { check(false, "wobbly circle stays a circle: \(String(describing: ShapeRecognizer.recognize(circle)))") }

    // Lines snap to 15° steps (30° here), and to horizontal more readily.
    let a = CGPoint(x: 0, y: 0)
    let at31 = CGPoint(x: 100 * cos(31 * .pi / 180), y: 100 * sin(31 * .pi / 180))
    let snapped = ShapeGeometry.snapAngle(from: a, to: at31)
    check(abs(atan2(snapped.y, snapped.x) * 180 / .pi - 30) < 0.01, "31° snaps to 30°")
    let at5 = CGPoint(x: 100 * cos(5 * .pi / 180), y: 100 * sin(5 * .pi / 180))
    check(abs(ShapeGeometry.snapAngle(from: a, to: at5).y) < 0.01, "5° snaps to horizontal")
    let at22 = CGPoint(x: 100 * cos(22 * .pi / 180), y: 100 * sin(22 * .pi / 180))
    check(ShapeGeometry.snapAngle(from: a, to: at22) == at22, "22° is left alone")

    // Resizing a circle from its anchor corner keeps it a circle touching that corner.
    let c = RecognizedShape.ellipse(center: CGPoint(x: 150, y: 150), rx: 50, ry: 50, rotation: 0)
    if case .ellipse(let center, let rx, let ry, _) = c.adjusted(anchor: CGPoint(x: 100, y: 100), original: CGPoint(x: 200, y: 200), to: CGPoint(x: 300, y: 260)) {
        check(rx == ry && abs(center.x - rx - 100) < 0.01 && abs(center.y - ry - 100) < 0.01, "circle grows from its anchor: \(center) r=\(rx)")
    } else { check(false, "circle stays an ellipse") }
}
