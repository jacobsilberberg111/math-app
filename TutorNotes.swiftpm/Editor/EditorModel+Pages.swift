import SwiftUI

/// Page operations from the UI, each one undo step. Undo and redo reach the same state through
/// the document's `onPagesRearranged`, which `observePageChanges` hooks up. Whichever way the
/// pages change, the canvas keeps the page being read where it was on screen.
extension EditorModel {
    func movePage(from: Int, to: Int) {
        keepingPageInView(rescroll: false) { document.movePage(from: from, to: to) }
    }

    func setPageSize(_ size: PageSize) {
        // The layout changes under the scroll position, so scroll back to the page being viewed.
        keepingPageInView(rescroll: true) { document.setPageSize(size) }
    }

    func clearPage(_ index: Int) {
        canvas?.endTextEditing()
        document.clearPage(index)
    }

    func insertPage(after index: Int) {
        keepingPageInView(rescroll: false) { document.insertPage(after: index) }
    }

    func duplicatePage(_ index: Int) {
        keepingPageInView(rescroll: false) { document.duplicatePage(index) }
    }

    func deletePage(_ index: Int) {
        keepingPageInView(rescroll: false) { document.deletePage(index) }
    }

    /// Adds a page at the end, and with `show` scrolls to it.
    func appendPage(show: Bool = true) {
        keepingPageInView(rescroll: false) { document.appendPage() }
        if show { canvas?.scrollToPage(pageCount - 1) }
    }

    /// Adds a PDF's pages (in place of a lone blank page) and shows the first of them. Returns
    /// whether any were added.
    @discardableResult
    func importPDF(assetID: String) -> Bool {
        keepingPageInView(rescroll: false) { document.importPDFPages(assetID: assetID, replaceFirstBlankPage: true) }
        guard let first = document.content.pages.firstIndex(where: { $0.pdfAssetID == assetID }) else { return false }
        canvas?.scrollToPage(first)
        return true
    }

    func observePageChanges() {
        document.onPagesRearranged = { [weak self] remap in self?.pagesDidRearrange(remap) }
    }

    /// Pages were moved, added, removed or resized: drop or renumber the editor state that points
    /// at a page.
    private func pagesDidRearrange(_ remap: PageRemap) {
        if quickMenu != nil { dismissQuickMenu() }
        if let focus = pendingFocus { pendingFocus = (remap.page(focus.page), focus.rect) }
        tutor.pagesDidRearrange(remap)
        // Never "Page 5 of 4" after pages go (the canvas reports again once it has re-laid out).
        if currentPage >= pageCount { currentPage = max(0, pageCount - 1) }
    }

    /// Runs a change to the pages and keeps the page counter on the page the student was looking
    /// at (it may have moved to a different index). With `rescroll`, also scrolls to its top.
    private func keepingPageInView(rescroll: Bool, _ change: () -> Void) {
        canvas?.endTextEditing()
        let before = min(max(0, currentPage), pageCount - 1)
        let anchor = document.content.pages[safe: before]?.id
        change()
        let page = anchor.flatMap { id in document.content.pages.firstIndex { $0.id == id } } ?? min(before, pageCount - 1)
        if currentPage != page { currentPage = page }
        if rescroll { canvas?.scrollToPage(page, animated: false) }
    }
}
