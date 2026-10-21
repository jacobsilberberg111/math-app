import UIKit
import PencilKit

/// Knows where things are on each page so the tutor's writing lands in free space instead of
/// on top of the student's work, and so the tutor can be told what's where.
@MainActor
struct LayoutAssistant {
    let doc: NoteDocument

    var pageSize: CGSize { doc.pageSize }

    /// Where things may go (page coordinates): the whole page, or on a freeform board the part the
    /// student is looking at (extended downward).
    var bounds: CGRect { doc.tutorWorkArea }

    /// On a board, only what's in or near the work area matters (a board can hold a lot).
    private var relevantArea: CGRect? { doc.isFreeform ? bounds.insetBy(dx: -240, dy: -240) : nil }

    /// Bounding boxes of the student's ink, merged into readable clusters (page coordinates).
    func inkClusters(page: Int, gap: CGFloat = 14) -> [CGRect] {
        let origin = doc.pageOrigin(page)
        var rects = doc.strokes(onPage: page).map { $0.renderBounds.offsetBy(dx: -origin.x, dy: -origin.y) }
        if let area = relevantArea { rects = rects.filter { $0.intersects(area) } }
        let limit = doc.isFreeform ? CGSize(width: 2400, height: 2400) : pageSize
        rects = rects.filter { $0.width < limit.width * 1.5 && $0.height < limit.height * 1.5 }
        guard !rects.isEmpty else { return [] }
        var merged = true
        while merged {
            merged = false
            var out: [CGRect] = []
            for r in rects {
                if let i = out.firstIndex(where: { $0.insetBy(dx: -gap, dy: -gap * 0.6).intersects(r) }) {
                    out[i] = out[i].union(r)
                    merged = true
                } else {
                    out.append(r)
                }
            }
            rects = out
        }
        return rects.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
    }

    /// With `answerAreasFree`, only a question card's prompt counts as taken: its answer area is
    /// where marks, hints and feedback belong (the student's ink in it is still counted).
    func occupied(page: Int, excluding: Set<String> = [], answerAreasFree: Bool = false) -> [CGRect] {
        var rects = inkClusters(page: page)
        let area = relevantArea
        for e in doc.elements(onPage: page) where !excluding.contains(e.id) && (area == nil || e.frame.intersects(area!)) {
            switch e.kind {
            case .ink:
                continue // marks may overlap freely
            case .question(let q) where answerAreasFree:
                rects.append(CGRect(x: e.frame.minX, y: e.frame.minY, width: e.frame.width, height: q.promptHeight))
            default:
                rects.append(e.frame)
            }
        }
        return rects
    }

    private func collides(_ r: CGRect, with rects: [CGRect]) -> Bool {
        let area = max(1, r.width * r.height)
        for o in rects {
            let i = o.insetBy(dx: -4, dy: -4).intersection(r)
            if !i.isNull && (i.width * i.height) / area > 0.04 { return true }
        }
        return false
    }

    func clamp(_ r: CGRect) -> CGRect {
        let b = bounds
        var c = r
        c.size.width = min(c.width, b.width - 16)
        c.origin.x = max(b.minX + 8, min(c.minX, b.maxX - c.width - 8))
        c.origin.y = max(b.minY + 8, min(c.minY, b.maxY - min(c.height, b.height - 16) - 8))
        return c
    }

    /// Moves `r` to the nearest free spot (down first, then the right column). Returns the original
    /// position when nothing fits.
    func place(_ r: CGRect, page: Int, excluding: Set<String> = []) -> (rect: CGRect, nudged: Bool) {
        let rect = clamp(r)
        let occ = occupied(page: page, excluding: excluding, answerAreasFree: true)
        if !collides(rect, with: occ) { return (rect, false) }
        let b = bounds
        var dy: CGFloat = 12
        while rect.maxY + dy < b.maxY - 12 {
            let c = rect.offsetBy(dx: 0, dy: dy)
            if !collides(c, with: occ) { return (c, true) }
            dy += 12
        }
        // Right-hand column at the requested height.
        let rightX = b.maxX - rect.width - 24
        if rightX > rect.minX + 40 {
            var c = rect
            c.origin.x = rightX
            if !collides(c, with: occ) { return (c, true) }
        }
        dy = 12
        while rect.minY - dy > b.minY + 12 {
            let c = rect.offsetBy(dx: 0, dy: -dy)
            if !collides(c, with: occ) { return (c, true) }
            dy += 12
        }
        return (rect, false)
    }

    /// Top y of the first full-width free band of at least `height` below all content, or nil.
    func nextFreeY(page: Int, height: CGFloat, from minY: CGFloat = 40) -> CGFloat? {
        let b = bounds
        // On a board, only what's in this column of the board counts as "above".
        let occ = occupied(page: page).filter { !doc.isFreeform || ($0.maxX > b.minX && $0.minX < b.maxX) }
        let bottom = occ.map(\.maxY).max() ?? b.minY
        let y = max(b.minY + minY, bottom + 24)
        return y + height <= b.maxY - 30 ? y : nil
    }

    /// Vertical bands with nothing in them (full width), for describing free space to the tutor.
    func freeBands(page: Int, minHeight: CGFloat = 70) -> [(CGFloat, CGFloat)] {
        let b = bounds
        let occ = occupied(page: page).filter { $0.maxY > b.minY && $0.minY < b.maxY }.sorted { $0.minY < $1.minY }
        var bands: [(CGFloat, CGFloat)] = []
        var cursor: CGFloat = b.minY + 30
        for r in occ {
            if r.minY - cursor >= minHeight { bands.append((cursor, r.minY - 8)) }
            cursor = max(cursor, r.maxY + 8)
        }
        let end = b.maxY - 30
        if end - cursor >= minHeight { bands.append((cursor, end)) }
        return bands
    }
}

/// Teacher-style pen marks with a little natural wobble.
enum HandDrawn {
    /// Deterministic wobble so the same mark looks the same after reload.
    private static func wobble(_ seed: Int, _ i: Int, _ amount: CGFloat) -> CGFloat {
        let v = sin(Double(seed * 7919 + i * 104729) * 0.0001 + Double(i) * 1.7)
        return CGFloat(v) * amount
    }

    static func seed(_ r: CGRect) -> Int { Int(r.minX * 3 + r.minY * 7 + r.width * 11) }

    static func circle(around r: CGRect) -> [[CGPoint]] {
        let s = seed(r)
        let c = r.center
        let rx = r.width / 2 + 10, ry = r.height / 2 + 8
        var pts: [CGPoint] = []
        let start = -CGFloat.pi * 0.6
        let n = 48
        for i in 0...n {
            let t = start + CGFloat(i) / CGFloat(n) * (2 * .pi + 0.45)
            let k = 1 + wobble(s, i, 0.025) + CGFloat(i) / CGFloat(n) * 0.06
            pts.append(CGPoint(x: c.x + rx * k * cos(t), y: c.y + ry * k * sin(t)))
        }
        return [pts]
    }

    static func underline(_ r: CGRect) -> [[CGPoint]] {
        let s = seed(r)
        let y = r.maxY + 5
        var pts: [CGPoint] = []
        let n = max(6, Int(r.width / 18))
        for i in 0...n {
            let t = CGFloat(i) / CGFloat(n)
            pts.append(CGPoint(x: r.minX - 4 + t * (r.width + 8), y: y + wobble(s, i, 1.2) - t * 1.5))
        }
        return [pts]
    }

    static func box(_ r: CGRect) -> [[CGPoint]] {
        let s = seed(r)
        let b = r.insetBy(dx: -8, dy: -6)
        let o: CGFloat = 4
        return [[
            CGPoint(x: b.minX - o, y: b.minY + wobble(s, 1, 1)),
            CGPoint(x: b.maxX + o, y: b.minY + wobble(s, 2, 1.5)),
            CGPoint(x: b.maxX + wobble(s, 3, 1.5), y: b.maxY + o),
            CGPoint(x: b.minX + wobble(s, 4, 1.5), y: b.maxY),
            CGPoint(x: b.minX + wobble(s, 5, 1), y: b.minY - o),
        ]]
    }

    static func strike(_ r: CGRect) -> [[CGPoint]] {
        [[CGPoint(x: r.minX - 4, y: r.midY + 2), CGPoint(x: r.maxX + 4, y: r.midY - 2)]]
    }

    static func bracket(_ r: CGRect) -> [[CGPoint]] {
        let x = r.maxX + 10
        return [[CGPoint(x: x - 6, y: r.minY), CGPoint(x: x, y: r.minY + 4), CGPoint(x: x, y: r.midY - 4),
                 CGPoint(x: x + 6, y: r.midY), CGPoint(x: x, y: r.midY + 4), CGPoint(x: x, y: r.maxY - 4), CGPoint(x: x - 6, y: r.maxY)]]
    }

    static func tick(at p: CGPoint, size: CGFloat = 34) -> [[CGPoint]] {
        [[CGPoint(x: p.x, y: p.y + size * 0.5), CGPoint(x: p.x + size * 0.18, y: p.y + size * 0.68),
          CGPoint(x: p.x + size * 0.36, y: p.y + size * 0.92), CGPoint(x: p.x + size * 0.62, y: p.y + size * 0.42),
          CGPoint(x: p.x + size, y: p.y)]]
    }

    static func cross(at p: CGPoint, size: CGFloat = 30) -> [[CGPoint]] {
        [[CGPoint(x: p.x, y: p.y), CGPoint(x: p.x + size * 0.5, y: p.y + size * 0.48), CGPoint(x: p.x + size, y: p.y + size)],
         [CGPoint(x: p.x + size, y: p.y), CGPoint(x: p.x + size * 0.52, y: p.y + size * 0.5), CGPoint(x: p.x, y: p.y + size)]]
    }

    static func partial(at p: CGPoint, size: CGFloat = 34) -> [[CGPoint]] {
        var strokes = tick(at: p, size: size)
        strokes.append([CGPoint(x: p.x + size * 0.45, y: p.y + size * 0.2), CGPoint(x: p.x + size * 0.85, y: p.y + size * 0.75)])
        return strokes
    }

    static func arrow(from a: CGPoint, to b: CGPoint) -> [[CGPoint]] {
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(1, hypot(dx, dy))
        // Slight curve, like a quick pen arrow.
        let bend = CGPoint(x: mid.x - dy / len * len * 0.06, y: mid.y + dx / len * len * 0.06)
        let shaft = [a, bend, b]
        let angle = atan2(b.y - bend.y, b.x - bend.x)
        let head: CGFloat = min(16, len * 0.3)
        let h1 = CGPoint(x: b.x - head * cos(angle - 0.45), y: b.y - head * sin(angle - 0.45))
        let h2 = CGPoint(x: b.x - head * cos(angle + 0.45), y: b.y - head * sin(angle + 0.45))
        return [shaft, [h1, b, h2]]
    }

    static func highlight(_ r: CGRect) -> (strokes: [[CGPoint]], width: CGFloat) {
        let lineHeight: CGFloat = 26
        let lines = max(1, Int((r.height / lineHeight).rounded()))
        let w = min(r.height / CGFloat(lines), 30)
        var strokes: [[CGPoint]] = []
        for i in 0..<lines {
            let y = r.minY + w * (CGFloat(i) + 0.5) + (r.height - w * CGFloat(lines)) / 2
            strokes.append([CGPoint(x: r.minX - 2, y: y), CGPoint(x: r.maxX + 2, y: y)])
        }
        return (strokes, w)
    }

    static func question(at p: CGPoint, size: CGFloat = 30) -> [[CGPoint]] {
        var arc: [CGPoint] = []
        for i in 0...10 {
            let t = CGFloat.pi * (1.1 - CGFloat(i) / 10 * 1.6)
            arc.append(CGPoint(x: p.x + size * 0.3 + size * 0.28 * cos(t), y: p.y + size * 0.3 - size * 0.28 * sin(t)))
        }
        arc.append(CGPoint(x: p.x + size * 0.3, y: p.y + size * 0.62))
        arc.append(CGPoint(x: p.x + size * 0.3, y: p.y + size * 0.72))
        let dot = [CGPoint(x: p.x + size * 0.3, y: p.y + size * 0.92), CGPoint(x: p.x + size * 0.31, y: p.y + size * 0.95)]
        return [arc, dot]
    }

    static func star(at p: CGPoint, size: CGFloat = 30) -> [[CGPoint]] {
        var pts: [CGPoint] = []
        let c = CGPoint(x: p.x + size / 2, y: p.y + size / 2)
        for i in 0...10 {
            let r = i % 2 == 0 ? size / 2 : size / 5
            let t = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
            pts.append(CGPoint(x: c.x + r * cos(t), y: c.y + r * sin(t)))
        }
        return [pts]
    }
}
