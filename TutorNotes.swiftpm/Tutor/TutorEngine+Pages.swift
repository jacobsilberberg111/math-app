import Foundation
import PencilKit

extension TurnRecord {
    /// This record after a page operation. Its snapshots hold page numbers and ink positions from
    /// before it, so reverting without this would put items and erased strokes on the wrong page.
    func remapped(by remap: PageRemap) -> TurnRecord {
        var r = self
        r.originals = originals.mapValues { remap.remapped($0) }
        r.removed = removed.map { remap.remapped($0) }
        r.erasedStrokes = remap.remapped(erasedStrokes)
        r.paperBefore = paperBefore.map { remap.remapped($0) }
        return r
    }
}

extension TutorEngine {
    /// Pages were moved or resized (or that was undone): keep what the tutor remembers about
    /// the canvas pointing at the right places.
    func pagesDidRearrange(_ remap: PageRemap) {
        turnRecords = turnRecords.mapValues { $0.remapped(by: remap) }
        // Records of a turn in progress; reading `record` merges the turn's and the response's.
        for e in [executor, observerExecutor] where !e.record.isEmpty {
            e.record = e.record.remapped(by: remap)
        }
        for i in chat.indices {
            for j in chat[i].actions.indices {
                guard let page = chat[i].actions[j].page, remap.page(page) != page else { continue }
                chat[i].actions[j].page = remap.page(page)
            }
        }
        if case .offscreen(_, _, _) = suggestion { suggestion = nil }
        // Where the student last wrote (document rects), which the next glance and turn look at.
        let moved = { (r: CGRect) in r.offsetBy(dx: 0, dy: remap.inkOffset(atDocY: r.midY)) }
        pendingWriting = pendingWriting.map(moved)
        recentWriting = recentWriting.map { ($0.0, moved($0.1)) }
    }
}
