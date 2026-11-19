import UIKit

/// The eraser also rubs out the tutor's writing and marks: its ink marks (circles, ticks, arrows,
/// labels) as soon as the eraser touches them, and its typed comments and typeset math once you
/// deliberately scrub across them (brushing past one while erasing your own ink nearby doesn't
/// delete it). Bigger pieces (graphs, tables, question cards, number lines) aren't erased by
/// brushing; select them and tap Delete instead.
///
/// One swipe is one undo: items disappear as you erase and are removed together when the eraser
/// lifts. A second finger landing (a scroll or the two-finger undo) cancels the swipe and brings
/// them back.
extension NoteCanvasViewController {
    /// The eraser's radius in page points, the same for PencilKit, the hover circle and this.
    var eraserRadius: CGFloat { max(3, tool.eraserWidth / 2) }

    /// How far the eraser must rub inside a typed tutor item before it goes.
    private func scrubThreshold(_ rect: CGRect) -> CGFloat {
        min(42, max(18, min(rect.width, rect.height) * 0.6))
    }

    func beginEraseSwipe() {
        let x = extras
        if x.erasing { endEraseSwipe(commit: true) }
        x.erasing = true
        x.erasedIDs = []
        x.rubDistance = [:]
        x.lastErasePoint = nil
    }

    /// Commit removes everything erased in the swipe as one undo step; otherwise it all comes back.
    func endEraseSwipe(commit: Bool) {
        let x = extras
        guard x.erasing else { return }
        x.erasing = false
        let ids = x.erasedIDs
        x.erasedIDs = []
        x.rubDistance = [:]
        x.lastErasePoint = nil
        guard !ids.isEmpty else { return }
        if commit {
            // All in one event, so the undo manager groups them as one "Erase".
            for id in ids {
                if selectedElementID == id { select(nil) }
                document.remove(id, actionName: "Erase")
            }
            document.undoManager.setActionName("Erase")
            host?.canvasUndoStateChanged()
        } else {
            for id in ids { elementViews[id]?.isHidden = false }
        }
    }

    /// Called for each eraser touch sample (from the touch watcher), inside a swipe.
    func eraseTutorMarks(at docPoint: CGPoint) {
        guard tool.kind == .eraser, replayTime == nil else { return }
        let x = extras
        if !x.erasing { beginEraseSwipe() }
        let moved = x.lastErasePoint.map { $0.distance(to: docPoint) } ?? 0
        x.lastErasePoint = docPoint
        let r = eraserRadius
        for e in document.content.elements where e.isTutor && !x.erasedIDs.contains(e.id) {
            let rect = document.docRect(for: e)
            switch e.kind {
            case .text, .math:
                guard rect.insetBy(dx: -r / 2, dy: -r / 2).contains(docPoint) else { continue }
                let rubbed = (x.rubDistance[e.id] ?? 0) + moved
                x.rubDistance[e.id] = rubbed
                if rubbed >= scrubThreshold(rect) { hide(e.id) }
            case .ink:
                if tutorMark(e, isHitAt: docPoint, radius: r) { hide(e.id) }
            default:
                continue
            }
        }
    }

    private func hide(_ id: String) {
        extras.erasedIDs.append(id)
        elementViews[id]?.isHidden = true
        if selectedElementID == id { select(nil) }
    }

    private func tutorMark(_ e: CanvasElement, isHitAt p: CGPoint, radius r: CGFloat) -> Bool {
        let rect = document.docRect(for: e)
        guard case .ink(let ink) = e.kind else { return false }
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
    }
}
