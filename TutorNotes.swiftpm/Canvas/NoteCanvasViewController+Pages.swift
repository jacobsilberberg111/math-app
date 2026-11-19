import UIKit
import PencilKit

extension NoteCanvasViewController {
    /// Pages, items and ink were replaced wholesale (a page added, removed, moved or cleared, the
    /// page size changed, or one of those was undone): rebuild the canvas from the document, refit
    /// if the pages changed width, and keep the page being read where it was on screen.
    func documentDidReload() {
        if let tv = editingTextView {
            // Its frame belongs to the old layout.
            editingTextView = nil
            editingNewTextPage = nil
            editingNewTextOrigin = nil
            tv.removeFromSuperview()
            stopObservingKeyboard()
            canvasView.keyboardDismissMode = .interactive
        }
        flushReveals()
        select(nil)
        endShapeEditing()
        clearRegion()
        let widthChanged = abs(underlay.bounds.width - document.documentSize.width) > 0.5
        keepingPageInView {
            documentDidReplaceDrawing()
            reloadPages()
            reloadAllElements()
            if widthChanged {
                // The fit zoom depends on the page width, and so do the zoom limits.
                updateZoomLimits()
                zoomToFit(animated: false)
            }
            layoutDocument()
        }
        rasterizeForCurrentZoom()
        lastReportedPage = currentPageIndex
        host?.canvasVisiblePageChanged(currentPageIndex)
    }
}
