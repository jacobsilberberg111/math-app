import PencilKit
import UIKit

/// Everything a page operation can change, captured so the whole operation is one undo step.
struct PageSnapshot {
    var pageSize: PageSize
    var pages: [Page]
    var elements: [CanvasElement]
    var paper: PaperSession?
    var drawing: PKDrawing
}

extension PageRemap {
    /// Ink moved along with its page: each stroke belongs to the page its bounds centre is on.
    func remapped(_ strokes: [PKStroke]) -> [PKStroke] {
        var out = strokes
        for i in out.indices {
            let dy = inkOffset(atDocY: out[i].renderBounds.midY)
            if dy != 0 { out[i].transform = out[i].transform.concatenating(CGAffineTransform(translationX: 0, y: dy)) }
        }
        return out
    }
}

extension NoteDocument {
    // MARK: Page size

    /// Why this note's page size can't be changed, or nil when it can.
    var pageSizeLockReason: String? {
        if isFreeform { return "Freeform boards don't have pages." }
        if content.paper != nil { return "Past papers keep the size of the original paper." }
        if content.pages.contains(where: { $0.pdfAssetID != nil }) { return "Pages from a PDF keep the PDF's size." }
        return nil
    }

    var canChangePageSize: Bool { pageSizeLockReason == nil }

    // MARK: Page operations (each one undo step)

    /// Moves a page so it ends up at index `to`, taking its ink, items and paper-question numbers along.
    func movePage(from: Int, to: Int) {
        let count = content.pages.count
        guard !isFreeform, from != to, (0..<count).contains(from), (0..<count).contains(to) else { return }
        let remap = PageRemap.move(from: from, to: to, count: count, size: content.pageSize, topMargin: topMargin, pageGap: pageGap)
        var after = pageSnapshot
        after.pages.insert(after.pages.remove(at: from), at: to)
        after.elements = after.elements.map { remap.remapped($0) }
        after.paper = after.paper.map { remap.remapped($0) }
        after.drawing = redrawn(after.drawing, by: remap)
        switchPages(to: after, remap: remap, actionName: "Move Page")
    }

    /// Changes every page to `size`. Each page's ink moves with its page; items keep their place on
    /// the page, nudged back inside it if they would overflow.
    func setPageSize(_ size: PageSize) {
        guard canChangePageSize, size != content.pageSize, size.width > 0, size.height > 0 else { return }
        let remap = PageRemap.resize(from: content.pageSize, to: size, count: content.pages.count, topMargin: topMargin, pageGap: pageGap)
        var after = pageSnapshot
        after.pageSize = size
        after.elements = after.elements.map { remap.remapped($0) }
        after.drawing = redrawn(after.drawing, by: remap)
        switchPages(to: after, remap: remap, actionName: "Page Size")
    }

    /// Removes a page's ink and items; the paper (or PDF background) stays.
    func clearPage(_ index: Int) {
        guard !isFreeform, content.pages.indices.contains(index) else { return }
        var after = pageSnapshot
        after.elements.removeAll { $0.pageIndex == index }
        var d = after.drawing
        let strokes = d.strokes
        let kept = strokes.filter { strokePage($0) != index }
        guard kept.count != strokes.count || after.elements.count != content.elements.count else { return }
        d.strokes = kept
        after.drawing = d
        switchPages(to: after, remap: nil, actionName: "Clear Page")
    }

    // MARK: Helpers

    private var pageSnapshot: PageSnapshot {
        PageSnapshot(pageSize: content.pageSize, pages: content.pages, elements: content.elements, paper: content.paper, drawing: drawing)
    }

    /// Work on a local copy: every `PKDrawing.strokes` access bridges the whole array.
    private func redrawn(_ source: PKDrawing, by remap: PageRemap) -> PKDrawing {
        var d = source
        d.strokes = remap.remapped(d.strokes)
        return d
    }

    private func strokePage(_ stroke: PKStroke) -> Int {
        let y = stroke.renderBounds.midY
        return y.isFinite ? pageIndex(at: CGPoint(x: 0, y: y)) : 0
    }

    /// Switches the note to `target` as one undo step; the state it replaces becomes the redo step.
    /// `remap` says how pages moved on the way, so page numbers kept elsewhere can follow.
    /// `expecting` guards a later undo or redo: if pages were added or removed since the step was
    /// recorded (an auto-added page, a PDF import), the snapshot no longer fits and is skipped.
    private func switchPages(to target: PageSnapshot, remap: PageRemap?, actionName: String, expecting pageIDs: Set<UUID>? = nil) {
        if let pageIDs, Set(content.pages.map(\.id)) != pageIDs { return }
        let previous = pageSnapshot
        content.pageSize = target.pageSize
        content.pages = target.pages
        content.elements = target.elements
        content.paper = target.paper
        drawing = target.drawing
        let targetIDs = Set(target.pages.map(\.id))
        undoManager.registerUndo(withTarget: self) { doc in
            doc.switchPages(to: previous, remap: remap?.inverse, actionName: actionName, expecting: targetIDs)
        }
        undoManager.setActionName(actionName)
        canvas?.documentDidReload()
        if let remap { onPagesRearranged?(remap) }
        markDirty()
    }
}
