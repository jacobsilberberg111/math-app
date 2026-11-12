import UIKit

/// Feature checks for scrolling: the page must never jump on its own (status-bar taps, the tutor
/// writing while the student scrolls, the tutor panel sliding in and out), a note reopens where
/// it was left, and big items fade in.
extension DemoDirector {
    func checkScrolling(_ model: EditorModel, _ canvas: NoteCanvasViewController) async {
        let doc = model.document
        let scroll = canvas.canvasView
        FeatureCheck.check("no scroll-to-top on status bar taps", !scroll.scrollsToTop && canvas.scrollViewShouldScrollToTop(scroll) == false)

        while doc.content.pages.count < 3 { doc.appendPage() }
        canvas.scrollToPage(2, animated: false)
        await wait(0.4)
        let before = scroll.contentOffset

        // The tutor writes far up the note while the student is scrolling: the page stays put.
        canvas.lastUserScrollDate = Date()
        canvas.lastPencilDownDate = .distantPast
        let elementsBefore = doc.content.elements.count
        if let input = try? JSONValue.parse(#"{"page": 1, "x": 80, "y": 60, "text": "Look up here"}"#) {
            _ = await model.tutor.executor.perform(toolID: "scroll-check", name: "write", input: input)
        }
        await wait(1.6)
        FeatureCheck.check("tutor doesn't move the page while the student scrolls",
                           doc.content.elements.count == elementsBefore + 1 && scroll.contentOffset.distance(to: before) < 1,
                           "offset \(Int(before.y)) → \(Int(scroll.contentOffset.y))")

        // The tutor panel slides in and out: the same part of the note stays at the top.
        let topBefore = canvas.visibleDocRect.minY
        model.showTutor = true
        await wait(1.5)
        let topOpen = canvas.visibleDocRect.minY
        model.showTutor = false
        await wait(1.5)
        let topClosed = canvas.visibleDocRect.minY
        FeatureCheck.check("panel open/close keeps the place", abs(topOpen - topBefore) < 24 && abs(topClosed - topBefore) < 24,
                           "doc y \(Int(topBefore)) → \(Int(topOpen)) → \(Int(topClosed))")

        // Reopening remembers the place.
        canvas.rememberPosition()
        let remembered = CanvasPositionMemory.load(doc.meta.id)
        FeatureCheck.check("position remembered", remembered.map { abs($0.docY - canvas.visibleDocRect.minY) < 1 } ?? false,
                           "\(remembered.map { "\(Int($0.docY))" } ?? "nil") vs \(Int(canvas.visibleDocRect.minY))")

        // A big item the tutor adds fades in and ends fully visible.
        if let input = try? JSONValue.parse(#"{"page": 3, "y": 120, "nodes": [{"id": "a", "text": "Fade in"}, {"id": "b", "text": "Done"}]}"#) {
            canvas.lastUserScrollDate = .distantPast
            let r = await model.tutor.executor.perform(toolID: "fade-check", name: "flowchart", input: input)
            await wait(1.8)
            let id = doc.content.elements.last?.id ?? ""
            let alpha = canvas.elementViews[id]?.alpha ?? 0
            FeatureCheck.check("big items fade in fully", r.isError == false && alpha > 0.99, "alpha \(alpha)")
        }

        // Clean up.
        for e in doc.content.elements.dropFirst(elementsBefore) { doc.remove(e.id) }
        await wait(0.3)
    }
}
