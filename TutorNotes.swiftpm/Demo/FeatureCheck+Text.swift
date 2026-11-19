import UIKit

/// Text boxes: creating one with the text tool's settings, formatting, list continuation, saving
/// and re-opening with the formatting intact, editing a tutor box without losing its markup, and
/// scaling formatted text with the lasso.
extension DemoDirector {
    func checkText(_ model: EditorModel, _ canvas: NoteCanvasViewController) async {
        let doc = model.document
        model.tools.kind = .text
        model.tools.textStyle = .typed
        model.tools.textSize = 18
        await wait(0.3)
        let start = doc.docRect(CGRect(x: 80, y: 420, width: 1, height: 1), page: 0).origin
        canvas.beginNewText(at: start)
        guard let tv = canvas.editingTextView else {
            FeatureCheck.check("text box opens", false)
            return
        }
        FeatureCheck.check("text box opens", tv.isFirstResponder || tv.window != nil)
        FeatureCheck.check("format bar", tv.inputAccessoryView is TextFormatBar)
        tv.insertText("Hello world")
        tv.selectedRange = NSRange(location: 0, length: 5)
        tv.toggleTrait(.traitBold)
        tv.selectedRange = NSRange(location: (tv.text as NSString).length, length: 0)
        tv.insertText("\n")
        tv.toggleList(numbered: false)
        tv.insertText("one")
        // Return as the keyboard sends it: through the delegate first.
        if tv.delegate?.textView?(tv, shouldChangeTextIn: tv.selectedRange, replacementText: "\n") ?? true { tv.insertText("\n") }
        tv.insertText("two")
        FeatureCheck.check("bullet continues", tv.text.hasSuffix("• one\n• two"), tv.text.debugDescription)
        let widthWhileTyping = tv.frame.width
        let before = doc.content.elements.count
        canvas.endTextEditing()
        guard doc.content.elements.count == before + 1, let e = doc.content.elements.last, case .text(let t) = e.kind else {
            FeatureCheck.check("text saved", false, "elements \(before) -> \(doc.content.elements.count)")
            return
        }
        FeatureCheck.check("text saved", t.text == "Hello world\n• one\n• two" && t.attributed != nil, t.text.debugDescription)
        FeatureCheck.check("box hugs text", e.frame.width < 400 && e.frame.width > 60,
                           "width \(Int(e.frame.width)), while typing \(Int(widthWhileTyping))")
        let saved = StudentText.attributedString(t)
        let boldFont = saved.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        let plainFont = saved.attribute(.font, at: 7, effectiveRange: nil) as? UIFont
        FeatureCheck.check("bold kept", boldFont?.fontDescriptor.symbolicTraits.contains(.traitBold) == true
                           && plainFont?.fontDescriptor.symbolicTraits.contains(.traitBold) == false)

        // Re-open with the caret where tapped; closing without a change adds no undo step.
        let undoBefore = doc.undoManager.undoActionName
        canvas.beginEditingText(element: e, at: doc.docRect(for: e).center)
        let reopened = canvas.editingTextView
        let reBold = (reopened?.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?
            .fontDescriptor.symbolicTraits.contains(.traitBold) == true
        FeatureCheck.check("re-edit keeps formatting", reBold)
        FeatureCheck.check("caret at tap", (reopened?.selectedRange.location ?? 0) > 0, "\(reopened?.selectedRange.location ?? -1)")
        canvas.endTextEditing()
        FeatureCheck.check("unchanged edit is not an undo step", doc.undoManager.undoActionName == undoBefore && doc.element(e.id) != nil,
                           doc.undoManager.undoActionName)

        // A tutor box keeps its author, markup and style when edited.
        let tutorText = TextContent(text: "Area is $\\pi r^2$", style: .note, fontSize: 18, colorHex: "#7048E8", rich: true)
        let tutor = CanvasElement(id: doc.nextElementID(), pageIndex: 0, frame: CGRect(x: 80, y: 560, width: 300, height: 40),
                                  author: .tutor, kind: .text(tutorText))
        doc.add(tutor, actionName: "Add")
        await wait(0.3)
        canvas.beginEditingText(element: tutor)
        canvas.editingTextView?.selectedRange = NSRange(location: 0, length: 0)
        canvas.editingTextView?.insertText("So: ")
        canvas.endTextEditing()
        if let after = doc.element(tutor.id), case .text(let tt) = after.kind {
            FeatureCheck.check("tutor text edit", after.author == .tutor && tt.rich && tt.style == .note && tt.text == "So: Area is $\\pi r^2$",
                               tt.text)
        } else {
            FeatureCheck.check("tutor text edit", false, "missing")
        }

        // Lasso scaling scales every run of formatted text.
        let doubled = StudentText.scaled(t, by: 2)
        let big = (StudentText.attributedString(doubled).attribute(.font, at: 7, effectiveRange: nil) as? UIFont)?.pointSize ?? 0
        FeatureCheck.check("scaled text", FeatureCheck.close(big, (plainFont?.pointSize ?? 0) * 2, 0.5), "\(big)")

        // A sticky note, left open for a screenshot.
        model.tools.textStyle = .sticky
        await wait(0.3)
        canvas.beginNewText(at: doc.docRect(CGRect(x: 420, y: 420, width: 1, height: 1), page: 0).origin)
        canvas.editingTextView?.insertText("Remember: check units")
        FeatureCheck.check("sticky style", canvas.editingTextView?.style == .sticky)
        await wait(2.5)
        canvas.endTextEditing()
        model.tools.textStyle = .typed
        model.tools.kind = .pen
    }
}
