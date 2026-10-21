import SwiftUI

/// Page operations from the UI. Undo and redo reach the same state through the document's
/// `onPagesRearranged`, which `observePageChanges` hooks up.
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

    func observePageChanges() {
        document.onPagesRearranged = { [weak self] remap in self?.pagesDidRearrange(remap) }
    }

    /// Pages were moved or resized: drop or renumber the editor state that points at a page.
    private func pagesDidRearrange(_ remap: PageRemap) {
        if quickMenu != nil { dismissQuickMenu() }
        if let focus = pendingFocus { pendingFocus = (remap.page(focus.page), focus.rect) }
        tutor.pagesDidRearrange(remap)
    }

    /// Runs a change that reorders or resizes pages, then keeps the page the student was looking
    /// at in view (it may have moved to a different index).
    private func keepingPageInView(rescroll: Bool, _ change: () -> Void) {
        canvas?.endTextEditing()
        let before = min(max(0, currentPage), pageCount - 1)
        let anchor = document.content.pages[safe: before]?.id
        change()
        guard let anchor, let page = document.content.pages.firstIndex(where: { $0.id == anchor }) else { return }
        if currentPage != page { currentPage = page }
        if rescroll || page != before { canvas?.scrollToPage(page, animated: false) }
    }
}
