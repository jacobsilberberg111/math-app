import PencilKit
import UIKit

/// What a page operation changes, captured so the whole operation is one undo step. The past
/// paper's progress and each page's paper style aren't part of it: undo renumbers those instead,
/// so marking or restyling done since isn't lost.
struct PageSnapshot {
    var pageSize: PageSize
    var pages: [Page]
    var elements: [CanvasElement]
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
        after.drawing = redrawn(after.drawing, by: remap)
        switchPages(to: after, remap: remap, actionName: "Move Page")
    }

    /// Changes every page to `size`. Each page's ink and items keep their place on the page; a page
    /// whose content wouldn't fit the new size has it scaled down to fit, so nothing spills onto the
    /// next page or off the edge.
    func setPageSize(_ size: PageSize) {
        guard canChangePageSize, size != content.pageSize, size.width > 0, size.height > 0 else { return }
        let remap = PageRemap.resize(from: content.pageSize, to: size, count: content.pages.count, topMargin: topMargin, pageGap: pageGap)
        var after = fittedToPages(of: size)
        after.pageSize = size
        after.elements = after.elements.map { remap.remapped($0) }
        after.drawing = redrawn(after.drawing, by: remap)
        switchPages(to: after, remap: remap, actionName: "Page Size")
    }

    /// The note as it is, with each page's content scaled about the page's top-left corner where it
    /// wouldn't fit a page of `size`.
    private func fittedToPages(of size: PageSize) -> PageSnapshot {
        var out = pageSnapshot
        var strokes = drawing.strokes
        let pages = strokes.map { strokePage($0) }
        let env = PageRenderer.environment(for: self)
        for i in content.pages.indices {
            let origin = pageOrigin(i)
            var bounds = CGRect.null
            for (j, s) in strokes.enumerated() where pages[j] == i {
                bounds = bounds.union(s.renderBounds.offsetBy(dx: -origin.x, dy: -origin.y))
            }
            for e in content.elements where e.pageIndex == i { bounds = bounds.union(e.frame) }
            guard !bounds.isNull, bounds.maxX > size.width || bounds.maxY > size.height else { continue }
            let k = max(0.2, min(size.width / max(bounds.maxX, 1), size.height / max(bounds.maxY, 1), 1))
            let t = CGAffineTransform(translationX: -origin.x, y: -origin.y)
                .concatenating(CGAffineTransform(scaleX: k, y: k))
                .concatenating(CGAffineTransform(translationX: origin.x, y: origin.y))
            for j in strokes.indices where pages[j] == i { strokes[j].transform = strokes[j].transform.concatenating(t) }
            for j in out.elements.indices where out.elements[j].pageIndex == i {
                NoteDocument.scale(&out.elements[j], by: k, env: env)
            }
        }
        out.drawing.strokes = strokes
        return out
    }

    /// An item scaled by `k` about its page's top-left corner: text and maths get smaller type.
    private static func scale(_ e: inout CanvasElement, by k: CGFloat, env: RenderEnvironment) {
        let start = CGRect(origin: CGPoint(x: e.frame.minX * k, y: e.frame.minY * k), size: e.frame.size)
        if case .text(var text) = e.kind {
            text.fontSize = max(6, text.fontSize * k)
            e.kind = .text(text)
            e.frame = CGRect(origin: start.origin, size: ElementRenderer.measureText(text, author: e.author, width: e.frame.width * k, env: env))
        } else {
            ElementResizer.resize(&e, to: e.frame.size * k, from: start, env: env)
        }
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
        PageSnapshot(pageSize: content.pageSize, pages: content.pages, elements: content.elements, drawing: drawing)
    }

    /// Work on a local copy: every `PKDrawing.strokes` access bridges the whole array.
    private func redrawn(_ source: PKDrawing, by remap: PageRemap) -> PKDrawing {
        var d = source
        d.strokes = remap.remapped(d.strokes)
        return d
    }

    /// `target` plus the pages after its first `count` as they are now, with their items and ink
    /// (moved to where those pages sit in the target's layout).
    private func keepingPages(after count: Int, in target: PageSnapshot) -> PageSnapshot {
        var out = target
        out.pages += content.pages[count...]
        out.elements += content.elements.filter { $0.pageIndex >= count }
        let shift = target.pageSize.height - content.pageSize.height
        let extra = drawing.strokes.compactMap { stroke -> PKStroke? in
            let page = strokePage(stroke)
            guard page >= count else { return nil }
            var s = stroke
            if shift != 0 { s.transform = s.transform.concatenating(CGAffineTransform(translationX: 0, y: CGFloat(page) * shift)) }
            return s
        }
        out.drawing.strokes += extra
        return out
    }

    private func strokePage(_ stroke: PKStroke) -> Int {
        let y = stroke.renderBounds.midY
        return y.isFinite ? pageIndex(at: CGPoint(x: 0, y: y)) : 0
    }

    /// Switches the note to `target` as one undo step; the state it replaces becomes the redo step.
    /// `remap` says how pages moved on the way, so page numbers kept elsewhere can follow.
    /// `expecting` is set for a later undo or redo: the pages the step was recorded with. Pages added
    /// at the end since (an auto-added page, a PDF import) are kept with what's on them.
    private func switchPages(to target: PageSnapshot, remap: PageRemap?, actionName: String, expecting pageIDs: Set<UUID>? = nil) {
        var target = target
        if let pageIDs {
            let ids = content.pages.map(\.id)
            guard ids.count >= pageIDs.count, Set(ids.prefix(pageIDs.count)) == pageIDs else {
                // The pages changed some other way: this step (and the ones under it) no longer fit,
                // so drop them rather than put work on the wrong pages. Not from inside the undo itself.
                DispatchQueue.main.async { [weak self] in self?.undoManager.removeAllActions() }
                return
            }
            if ids.count > pageIDs.count { target = keepingPages(after: pageIDs.count, in: target) }
        }
        let previous = pageSnapshot
        let current = Dictionary(content.pages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        content.pageSize = target.pageSize
        content.pages = target.pages.map { current[$0.id] ?? $0 }
        content.elements = target.elements
        if let remap { content.paper = content.paper.map { remap.remapped($0) } }
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
