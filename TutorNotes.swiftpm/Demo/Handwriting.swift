import UIKit
import PencilKit

/// Turns short math strings into natural-looking pen strokes. Used only by the scripted demo,
/// so the walkthrough can show a student writing without a real Apple Pencil.
@MainActor
enum Handwriting {
    /// Glyphs in a 10-unit-tall box: y = 0 is the top of digits, y = 10 the baseline,
    /// lowercase letters sit between 5 and 10. Each glyph is a list of strokes.
    private static let glyphs: [Character: (width: CGFloat, strokes: [[CGPoint]])] = {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        func oval(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat, start: CGFloat = -1.9) -> [CGPoint] {
            (0...18).map { i in
                let t = start + CGFloat(i) / 18 * 2.15 * .pi
                return p(cx + rx * cos(t), cy + ry * sin(t))
            }
        }
        var g: [Character: (CGFloat, [[CGPoint]])] = [:]
        g["0"] = (5.2, [oval(cx: 2.6, cy: 5, rx: 2.6, ry: 5)])
        g["1"] = (3.4, [[p(0.6, 2.2), p(2.4, 0), p(2.4, 10)]])
        g["2"] = (5.6, [[p(0.4, 2.4), p(1.6, 0.4), p(3.4, 0.1), p(5, 1.4), p(4.9, 3.6), p(2.8, 6.6), p(0, 10), p(5.6, 9.9)]])
        g["3"] = (5.2, [[p(0.4, 1.0), p(2.4, 0), p(4.5, 0.9), p(4.4, 3.5), p(2.3, 4.9), p(4.8, 6.3), p(5, 8.6), p(3, 10), p(0.4, 9.1)]])
        g["4"] = (5.8, [[p(4.2, 10), p(4.2, 0), p(0, 7), p(5.8, 7)]])
        g["5"] = (5.4, [[p(5, 0.1), p(1, 0.2), p(0.6, 4.6), p(2.6, 4.0), p(4.6, 5.0), p(5.1, 7.6), p(3.6, 9.8), p(1.1, 9.8), p(0, 8.6)]])
        g["6"] = (5.4, [[p(4.6, 0.5), p(2.2, 1.0), p(0.5, 4.0), p(0.3, 7.6), p(2.1, 10), p(4.1, 9.6), p(5.1, 7.5), p(4.1, 5.4), p(2.0, 5.2), p(0.5, 6.9)]])
        g["7"] = (5.6, [[p(0, 0.2), p(5.6, 0), p(2.2, 10)]])
        g["8"] = (5.6, [[p(2.8, 4.8), p(0.8, 3.5), p(0.8, 1.2), p(2.8, 0), p(4.8, 1.2), p(4.8, 3.5), p(2.8, 4.8),
                         p(0.5, 6.6), p(0.6, 9.0), p(2.8, 10), p(5.0, 9.0), p(5.0, 6.5), p(2.8, 4.8)]])
        g["9"] = (5.4, [[p(5, 3), p(3.5, 5), p(1.2, 4.8), p(0.3, 2.5), p(1.5, 0.2), p(4, 0.2), p(5, 2.6), p(5, 6.2), p(3.8, 9.5), p(1, 10)]])
        g["x"] = (5.0, [[p(0.2, 5.1), p(2.2, 7.4), p(4.8, 10)], [p(4.8, 5), p(2.4, 7.6), p(0, 10)]])
        g["y"] = (5.0, [[p(0.2, 5), p(2.4, 9.2)], [p(4.8, 5), p(2.6, 9.6), p(1.2, 13.2)]])
        g["o"] = (4.8, [oval(cx: 2.4, cy: 7.5, rx: 2.4, ry: 2.5)])
        g["r"] = (3.8, [[p(0.5, 5), p(0.5, 10)], [p(0.5, 7.2), p(1.8, 5.4), p(3.6, 5.3)]])
        g["="] = (5.2, [[p(0, 6.2), p(5.2, 6.0)], [p(0, 8.8), p(5.2, 8.6)]])
        g["+"] = (5.2, [[p(0, 7.5), p(5.2, 7.4)], [p(2.6, 4.9), p(2.6, 10.1)]])
        g["-"] = (4.6, [[p(0, 7.5), p(4.6, 7.4)]])
        g["−"] = g["-"]
        g["("] = (2.8, [[p(2.6, -0.6), p(0.7, 3.0), p(0.5, 7.0), p(2.6, 10.8)]])
        g[")"] = (2.8, [[p(0.2, -0.6), p(2.1, 3.0), p(2.3, 7.0), p(0.2, 10.8)]])
        g[","] = (1.6, [[p(1.0, 9.2), p(1.2, 10.2), p(0.4, 11.6)]])
        g["."] = (1.4, [[p(0.6, 9.6), p(0.8, 9.9)]])
        g[" "] = (3.0, [])
        return g.mapValues { (width: $0.0, strokes: $0.1) }
    }()

    /// Strokes for `text` with its top-left at `origin` (document coordinates). `size` is the
    /// height of a digit in points. "²" is written as a small raised 2.
    static func strokes(_ text: String, origin: CGPoint, size: CGFloat, seed: Int = 1) -> [[CGPoint]] {
        let unit = size / 10
        var x = origin.x
        var out: [[CGPoint]] = []
        var n = seed
        func jitter() -> CGFloat {
            n = (n &* 1103515245 &+ 12345) & 0x7fffffff
            return (CGFloat(n % 1000) / 1000 - 0.5)
        }
        for ch in text {
            var key = ch
            var scale: CGFloat = 1
            var dy: CGFloat = 0
            if ch == "²" { key = "2"; scale = 0.5; dy = -2.0 }
            guard let glyph = glyphs[key] else {
                x += 3 * unit
                continue
            }
            let baselineWobble = jitter() * 0.5
            for stroke in glyph.strokes {
                let pts = stroke.map { pt -> CGPoint in
                    let gx = pt.x * scale, gy = pt.y * scale + dy
                    // A slight forward slant and wobble so it reads as handwriting.
                    let slant = (10 - gy) * 0.09
                    return CGPoint(x: x + (gx + slant + jitter() * 0.18) * unit,
                                   y: origin.y + (gy + baselineWobble + jitter() * 0.18) * unit)
                }
                out.append(ElementRenderer.smoothed(pts, closed: false))
            }
            x += (glyph.width * scale + 1.7) * unit
        }
        return out
    }

    static func width(_ text: String, size: CGFloat) -> CGFloat {
        let unit = size / 10
        return text.reduce(0) { acc, ch in
            let key: Character = ch == "²" ? "2" : ch
            let scale: CGFloat = ch == "²" ? 0.5 : 1
            return acc + ((glyphs[key]?.width ?? 3) * scale + 1.7) * unit
        }
    }

    /// A PencilKit stroke along the points, with gentle pressure variation like a real pen.
    static func pkStroke(_ points: [CGPoint], color: UIColor, width: CGFloat, ink: PKInk.InkType = .pen) -> PKStroke {
        // PencilKit fits a spline through the control points, so a short stroke given as two or
        // three points (a minus sign, half an x) renders as almost nothing. Resample it evenly and
        // repeat the ends so the spline reaches them, like the points a real Pencil reports.
        var points = ShapeGeometry.densify(points, spacing: 2, cornerRepeat: 1)
        if let first = points.first, let last = points.last {
            points = [first, first] + points + [last, last]
        }
        var pts: [PKStrokePoint] = []
        let n = max(1, points.count - 1)
        for (i, p) in points.enumerated() {
            let t = CGFloat(i) / CGFloat(n)
            let pressure = 0.75 + 0.35 * sin(t * .pi)
            pts.append(PKStrokePoint(location: p, timeOffset: TimeInterval(i) * 0.008,
                                     size: CGSize(width: width * pressure, height: width * pressure),
                                     opacity: 1, force: pressure, azimuth: 0, altitude: .pi / 2.4))
        }
        let path = PKStrokePath(controlPoints: pts, creationDate: Date())
        return PKStroke(ink: PKInk(ink, color: color), path: path, transform: .identity, mask: nil)
    }
}
