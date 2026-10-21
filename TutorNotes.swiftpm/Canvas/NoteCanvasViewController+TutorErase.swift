import UIKit

/// The eraser also rubs out the tutor's writing and marks: its handwriting, circles, ticks, arrows,
/// labels, typed comments and typeset math. Bigger pieces (graphs, tables, question cards, number
/// lines) aren't erased by brushing, so erasing your own ink on top of them can't remove them; select
/// them and tap Delete instead.
extension NoteCanvasViewController {
    /// Called for each eraser touch sample (from the touch watcher).
    func eraseTutorMarks(at docPoint: CGPoint) {
        guard tool.kind == .eraser, replayTime == nil else { return }
        let radius = tool.eraserMode == .pixel ? max(4, tool.eraserWidth / 2) : 6
        let hits = document.content.elements.filter { $0.isTutor && tutorMark($0, isHitAt: docPoint, radius: radius) }
        guard !hits.isEmpty else { return }
        for e in hits {
            if selectedElementID == e.id { select(nil) }
            document.remove(e.id, actionName: "Erase")
        }
        host?.canvasUndoStateChanged()
    }

    private func tutorMark(_ e: CanvasElement, isHitAt p: CGPoint, radius r: CGFloat) -> Bool {
        let rect = document.docRect(for: e)
        switch e.kind {
        case .text, .math:
            return rect.insetBy(dx: -r / 2, dy: -r / 2).contains(p)
        case .ink(let ink):
            if let label = ink.label, !label.isEmpty {
                // Same placement as ElementRenderer's ink label.
                let size = max(15, ink.width * 5.5)
                let off = ink.labelOffset ?? CGPoint(x: rect.width + 6, y: rect.height / 2 - size * 0.6)
                let labelRect = CGRect(x: rect.minX + off.x, y: rect.minY + off.y,
                                       width: min(260, CGFloat(label.count) * size * 0.55 + 8), height: size * 1.4)
                if labelRect.insetBy(dx: -r, dy: -r).contains(p) { return true }
            }
            let tolerance = r + ink.width / 2 + 2
            guard rect.insetBy(dx: -tolerance, dy: -tolerance).contains(p) else { return false }
            let local = CGPoint(x: p.x - rect.minX, y: p.y - rect.minY)
            for s in ink.strokes {
                var pts = s.points
                if s.closed, let first = pts.first { pts.append(first) }
                if pts.count == 1, pts[0].distance(to: local) <= tolerance { return true }
                for i in pts.indices.dropFirst()
                    where ShapeGeometry.distance(from: local, toSegment: pts[i - 1], pts[i]) <= tolerance {
                    return true
                }
            }
            return false
        default:
            return false
        }
    }
}
