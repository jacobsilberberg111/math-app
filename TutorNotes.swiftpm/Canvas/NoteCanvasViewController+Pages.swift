import UIKit
import PencilKit

extension NoteCanvasViewController {
    /// Pages, items and ink were replaced wholesale (a page moved or cleared, the page size changed,
    /// or one of those was undone): rebuild the canvas from the document and refit if the pages
    /// changed width.
    func documentDidReload() {
        if let tv = editingTextView {
            // Its frame belongs to the old layout.
            editingTextView = nil
            editingNewTextPage = nil
            editingNewTextOrigin = nil
            tv.removeFromSuperview()
        }
        flushReveals()
        select(nil)
        endShapeEditing()
        clearRegion()
        let widthChanged = abs(underlay.bounds.width - document.documentSize.width) > 0.5
        documentDidReplaceDrawing()
        reloadPages()
        reloadAllElements()
        if widthChanged {
            // The fit zoom depends on the page width, and so do the zoom limits.
            updateZoomLimits()
            zoomToFit(animated: false)
        }
        layoutDocument()
        keepOffsetInRange()
        rasterizeForCurrentZoom()
        host?.canvasVisiblePageChanged(currentPageIndex)
    }

    /// Pulls the scroll position back inside the content after its size changed.
    private func keepOffsetInRange() {
        let inset = canvasView.contentInset
        let maxX = max(-inset.left, canvasView.contentSize.width - canvasView.bounds.width + inset.right)
        let maxY = max(0, canvasView.contentSize.height - canvasView.bounds.height)
        let offset = canvasView.contentOffset
        let clamped = CGPoint(x: min(max(offset.x, -inset.left), maxX), y: min(max(offset.y, 0), maxY))
        if clamped != offset { canvasView.contentOffset = clamped }
    }
}
