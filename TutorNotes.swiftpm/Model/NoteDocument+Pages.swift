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
    //
    // Operations that move ink and items switch the whole note between snapshots (`switchPages`).
    // Adding pages at the end, and taking empty ones away again, only touch the page list, so the
    // canvas doesn't have to rebuild.

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

    // MARK: Adding and removing pages

    /// Adds a page at the end. `undoable` is false for pages added on their own as the student
    /// writes near the bottom: Undo should take back the writing, not the page under it.
    func appendPage(paper: PaperStyle? = nil, undoable: Bool = true) {
        let page = Page(paper: paper ?? content.pages.last?.paper ?? .standard)
        appendPages([page], actionName: undoable ? "Add Page" : nil)
    }

    /// Inserts a blank page after `index`, moving the ink and items below it down a page.
    func insertPage(after index: Int, paper: PaperStyle? = nil) {
        let insertAt = index + 1
        guard insertAt < content.pages.count else {
            appendPage(paper: paper)
            return
        }
        guard index >= 0 else { return }
        insert(Page(paper: paper ?? content.pages[index].paper), at: insertAt, copying: nil, actionName: "Insert Page")
    }

    /// Puts a copy of a page (its paper or PDF, ink and items) right after it.
    func duplicatePage(_ index: Int) {
        guard content.pages.indices.contains(index) else { return }
        let source = content.pages[index]
        var copy = Page(paper: source.paper)
        copy.pdfAssetID = source.pdfAssetID
        copy.pdfPageIndex = source.pdfPageIndex
        insert(copy, at: index + 1, copying: index, actionName: "Duplicate Page")
    }

    /// Deletes a page together with its ink and items; the pages after it move up.
    func deletePage(_ index: Int) {
        guard content.pages.count > 1, content.pages.indices.contains(index) else { return }
        if index == content.pages.count - 1 {
            removeTrailingPages([content.pages[index].id], actionName: "Delete Page")
        } else {
            deletePages([index], actionName: "Delete Page")
        }
    }

    /// Adds one page per PDF page with the PDF drawn as the page background. A note that is just
    /// one blank page takes the PDF's pages (and page shape) in its place.
    func importPDFPages(assetID: String, replaceFirstBlankPage: Bool) {
        guard let pdf = pdf(assetID) else { return }
        let count = pdf.numberOfPages
        guard count > 0 else { return }
        let pages = (0..<count).map { Page(paper: PaperStyle(pattern: .blank, color: .white), pdfAssetID: assetID, pdfPageIndex: $0) }
        let firstIsBlank = content.pages.count == 1 && content.elements.isEmpty && drawing.strokes.isEmpty && content.pages[0].pdfAssetID == nil
        guard replaceFirstBlankPage && firstIsBlank else {
            appendPages(pages, actionName: "Import PDF")
            return
        }
        var after = pageSnapshot
        after.pages = pages
        if let first = pdf.page(at: 1) {
            let box = first.getBoxRect(.cropBox)
            let rotated = first.rotationAngle % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
            if rotated.width > 0 {
                after.pageSize = PageSize(width: 816, height: (816 * rotated.height / rotated.width).rounded())
            }
        }
        switchPages(to: after, remap: nil, actionName: "Import PDF")
    }

    /// Adds pages at the end. Nothing else moves, so the canvas just adds them (no rebuild), and
    /// undo takes them away the same way. Without an `actionName` it isn't an undo step.
    private func appendPages(_ pages: [Page], actionName: String?) {
        guard !pages.isEmpty else { return }
        content.pages += pages
        canvas?.documentDidChangePages()
        if let actionName {
            let ids = pages.map(\.id)
            undoManager.registerUndo(withTarget: self) { doc in doc.removeTrailingPages(ids, actionName: actionName) }
            undoManager.setActionName(actionName)
        }
        markDirty()
    }

    /// Takes away pages at the end of the note, the light way while they're still the last pages
    /// and empty. Otherwise (something was put on them, or pages were added after) they're deleted
    /// the full way, which keeps what was on them for redo.
    private func removeTrailingPages(_ ids: [UUID], actionName: String) {
        let count = content.pages.count
        let start = count - ids.count
        guard start > 0 else { return }
        let isTail = content.pages[start...].map(\.id) == ids
        let empty = !content.elements.contains { $0.pageIndex >= start } && !drawing.strokes.contains { strokePage($0) >= start }
        guard isTail && empty else {
            let indices = ids.compactMap { id in content.pages.firstIndex { $0.id == id } }
            if !indices.isEmpty && indices.count < count { deletePages(indices, actionName: actionName) }
            return
        }
        let removed = Array(content.pages[start...])
        // Anything that pointed at a removed page now points at the last one left.
        let remap = PageRemap(destination: (0..<count).map { min($0, start - 1) }, oldSize: content.pageSize,
                              newSize: content.pageSize, topMargin: topMargin, pageGap: pageGap)
        content.pages.removeLast(ids.count)
        content.paper = content.paper.map { remap.remapped($0) }
        canvas?.documentDidChangePages()
        undoManager.registerUndo(withTarget: self) { doc in doc.appendPages(removed, actionName: actionName) }
        undoManager.setActionName(actionName)
        onPagesRearranged?(remap)
        markDirty()
    }

    /// Deletes pages with their ink and items as one undo step; the pages after them move up.
    private func deletePages(_ indices: [Int], actionName: String) {
        let count = content.pages.count
        let gone = Set(indices.filter { (0..<count).contains($0) })
        guard !gone.isEmpty, gone.count < count else { return }
        let kept = (0..<count).filter { !gone.contains($0) }
        var destination = Array(repeating: 0, count: count)
        var next = 0
        for old in 0..<count {
            if gone.contains(old) {
                // Page numbers kept elsewhere (past-paper questions, the tutor's records) that
                // pointed at a deleted page now point at the one before it.
                destination[old] = max(0, next - 1)
            } else {
                destination[old] = next
                next += 1
            }
        }
        let remap = PageRemap(destination: destination, oldSize: content.pageSize, newSize: content.pageSize,
                              topMargin: topMargin, pageGap: pageGap)
        let back = PageRemap(destination: kept, oldSize: content.pageSize, newSize: content.pageSize,
                             topMargin: topMargin, pageGap: pageGap)
        var after = pageSnapshot
        after.pages = kept.map { content.pages[$0] }
        after.elements = after.elements.filter { !gone.contains($0.pageIndex) }.map { remap.remapped($0) }
        var d = after.drawing
        d.strokes = remap.remapped(d.strokes.filter { !gone.contains(strokePage($0)) })
        after.drawing = d
        switchPages(to: after, remap: remap, undoRemap: back, actionName: actionName)
    }

    /// Inserts `page` at `insertAt`, moving the pages from there down one. With `source`, that
    /// page's ink and items are copied onto the new page.
    private func insert(_ page: Page, at insertAt: Int, copying source: Int?, actionName: String) {
        let count = content.pages.count
        guard (0...count).contains(insertAt) else { return }
        let remap = PageRemap(destination: (0..<count).map { $0 < insertAt ? $0 : $0 + 1 }, oldSize: content.pageSize,
                              newSize: content.pageSize, topMargin: topMargin, pageGap: pageGap)
        // Undone, anything that pointed at the new page goes back to the page it came from.
        let back = PageRemap(destination: (0...count).map { $0 < insertAt ? $0 : ($0 == insertAt ? source ?? max(0, insertAt - 1) : $0 - 1) },
                             oldSize: content.pageSize, newSize: content.pageSize, topMargin: topMargin, pageGap: pageGap)
        var after = pageSnapshot
        after.pages.insert(page, at: insertAt)
        after.elements = after.elements.map { remap.remapped($0) }
        let strokes = drawing.strokes
        var moved = remap.remapped(strokes)
        if let source {
            let dy = CGFloat(insertAt - source) * (pageSize.height + pageGap)
            moved += strokes.filter { strokePage($0) == source }.map { stroke -> PKStroke in
                var s = stroke
                s.transform = s.transform.concatenating(CGAffineTransform(translationX: 0, y: dy))
                return s
            }
            for e in content.elements where e.pageIndex == source {
                var copy = e
                copy.id = nextElementID()
                copy.pageIndex = insertAt
                after.elements.append(copy)
            }
        }
        var d = after.drawing
        d.strokes = moved
        after.drawing = d
        switchPages(to: after, remap: remap, undoRemap: back, actionName: actionName)
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
    /// (moved to where those pages sit in the target's layout, which can have more or fewer pages
    /// before them, of another size).
    private func keepingPages(after count: Int, in target: PageSnapshot) -> PageSnapshot {
        var out = target
        let delta = target.pages.count - count
        out.pages += content.pages[count...]
        out.elements += content.elements.filter { $0.pageIndex >= count }.map { e -> CanvasElement in
            var moved = e
            moved.pageIndex += delta
            return moved
        }
        let oldStride = content.pageSize.height + pageGap
        let newStride = target.pageSize.height + pageGap
        let extra = drawing.strokes.compactMap { stroke -> PKStroke? in
            let page = strokePage(stroke)
            guard page >= count else { return nil }
            var s = stroke
            let dy = CGFloat(page + delta) * newStride - CGFloat(page) * oldStride
            if dy != 0 { s.transform = s.transform.concatenating(CGAffineTransform(translationX: 0, y: dy)) }
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
    /// `remap` says how pages moved on the way, so page numbers kept elsewhere can follow, and
    /// `undoRemap` how they move back (when pages were added or removed it isn't `remap.inverse`).
    /// `expecting` is set for a later undo or redo: the pages the step was recorded with. Pages added
    /// at the end since (an auto-added page) are kept with what's on them.
    private func switchPages(to target: PageSnapshot, remap: PageRemap?, undoRemap: PageRemap? = nil, actionName: String,
                             expecting pageIDs: Set<UUID>? = nil) {
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
        let back = undoRemap ?? remap?.inverse
        undoManager.registerUndo(withTarget: self) { doc in
            doc.switchPages(to: previous, remap: back, undoRemap: remap, actionName: actionName, expecting: targetIDs)
        }
        undoManager.setActionName(actionName)
        canvas?.documentDidReload()
        if let remap { onPagesRearranged?(remap) }
        markDirty()
    }
}
