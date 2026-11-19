import UIKit
import UIKit.UIGestureRecognizerSubclass
import PencilKit

/// Watches pencil touches alongside PencilKit (never recognising, never cancelling) so we can
/// detect draw-and-hold for shape snapping.
final class StrokeObserverGesture: UIGestureRecognizer {
    var acceptsFinger = false
    weak var coordinateView: UIView?
    var onBegin: ((CGPoint, TimeInterval) -> Void)?
    var onMove: ((CGPoint, TimeInterval) -> Void)?
    var onEnd: ((Bool) -> Void)?
    private var tracked: UITouch?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        // A palm resting on the page (the usual way to write) is ignored rather than failing the
        // whole recognizer: once failed it would miss every stroke until all touches lifted.
        for t in touches {
            let usable = t.type == .pencil || (acceptsFinger && t.type == .direct)
            if tracked == nil, usable {
                tracked = t
                onBegin?(t.location(in: coordinateView), t.timestamp)
            } else {
                ignore(t, for: event)
            }
        }
    }

    /// After a stroke, keep watching while other touches (the hand) are still down.
    private func finish(_ t: UITouch, event: UIEvent) {
        tracked = nil
        let others = (event.allTouches ?? []).filter { $0 !== t && $0.phase != .ended && $0.phase != .cancelled }
        if others.isEmpty { state = .failed }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = tracked, touches.contains(t) else { return }
        let samples = event.coalescedTouches(for: t) ?? [t]
        for s in samples {
            onMove?(s.location(in: coordinateView), s.timestamp)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = tracked, touches.contains(t) else { return }
        onEnd?(false)
        finish(t, event: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = tracked, touches.contains(t) else { return }
        onEnd?(true)
        finish(t, event: event)
    }

    override func reset() {
        super.reset()
        tracked = nil
    }
}

struct SnapState {
    var points: [CGPoint] = []
    var times: [TimeInterval] = []
    var shape: RecognizedShape?
    var anchor: CGPoint = .zero
    var original: CGPoint = .zero
    var snapPoint: CGPoint = .zero
    var strokeCountAtBegin = 0
    /// The pen's ink and width when the shape snapped, for the clean stroke.
    var ink: PKInk?
    var width: CGFloat = 3
    var pending: RecognizedShape?

}

extension NoteCanvasViewController: UITextViewDelegate, UIPencilInteractionDelegate {

    // MARK: Setup

    func setupGestures() {
        let undoTap = UITapGestureRecognizer(target: self, action: #selector(handleUndoTap))
        undoTap.numberOfTouchesRequired = 2
        undoTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        undoTap.delegate = self
        canvasView.addGestureRecognizer(undoTap)
        fingerOnlyGestures.append(undoTap)

        let redoTap = UITapGestureRecognizer(target: self, action: #selector(handleRedoTap))
        redoTap.numberOfTouchesRequired = 3
        redoTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        redoTap.delegate = self
        canvasView.addGestureRecognizer(redoTap)
        fingerOnlyGestures.append(redoTap)

        tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tapGesture.delegate = self
        canvasView.addGestureRecognizer(tapGesture)

        let doubleFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleFingerTap.numberOfTapsRequired = 2
        doubleFingerTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        doubleFingerTap.delegate = self
        canvasView.addGestureRecognizer(doubleFingerTap)
        fingerOnlyGestures.append(doubleFingerTap)

        longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.45
        longPress.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        longPress.delegate = self
        canvasView.addGestureRecognizer(longPress)
        fingerOnlyGestures.append(longPress)

        regionPan = UIPanGestureRecognizer(target: self, action: #selector(handleRegionPan(_:)))
        regionPan.maximumNumberOfTouches = 1
        regionPan.delegate = self
        regionPan.isEnabled = false
        canvasView.addGestureRecognizer(regionPan)

        strokeObserver = StrokeObserverGesture(target: nil, action: nil)
        strokeObserver.coordinateView = chrome
        strokeObserver.cancelsTouchesInView = false
        strokeObserver.delaysTouchesBegan = false
        strokeObserver.delaysTouchesEnded = false
        strokeObserver.delegate = self
        strokeObserver.onBegin = { [weak self] p, t in self?.strokeBegan(p, t) }
        strokeObserver.onMove = { [weak self] p, t in self?.strokeMoved(p, t) }
        strokeObserver.onEnd = { [weak self] cancelled in self?.strokeEnded(cancelled: cancelled) }
        canvasView.addGestureRecognizer(strokeObserver)

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        canvasView.addGestureRecognizer(hover)

        // One finger or the pencil; the delegate keeps a resting palm from dragging the item.
        let movePan = UIPanGestureRecognizer(target: self, action: #selector(handleMovePan(_:)))
        movePan.maximumNumberOfTouches = 1
        movePan.delegate = self
        selectionView.addGestureRecognizer(movePan)
        let resizePan = UIPanGestureRecognizer(target: self, action: #selector(handleResizePan(_:)))
        resizePan.maximumNumberOfTouches = 1
        resizePan.delegate = self
        selectionView.handle.addGestureRecognizer(resizePan)
        selectionView.onAction = { [weak self] action in self?.performSelectionAction(action) }

        let pencil = UIPencilInteraction()
        pencil.delegate = self
        view.addInteraction(pencil)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === strokeObserver || other === strokeObserver { return true }
        if gestureRecognizer === touchWatcher || other === touchWatcher { return true }
        if gestureRecognizer === tapGesture && other === canvasView.drawingGestureRecognizer { return true }
        return false
    }

    /// Touches on the text box being edited (caret taps, selection long-presses) and on the selection's
    /// action buttons belong to those views; otherwise the canvas tap would end editing or deselect.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === strokeObserver || gestureRecognizer === touchWatcher { return true }
        // The hand resting on the page never taps, long-presses or drags out a region.
        if isPalmTouch(touch) { return false }
        if gestureRecognizer === tapGesture { lastTapWasFinger = touch.type == .direct }
        guard let v = touch.view else { return true }
        if let tv = editingTextView, v.isDescendant(of: tv) { return false }
        if v.isDescendant(of: selectionView.actionBar) { return false }
        if v.isDescendant(of: shapeBar) { return false }
        // Touches on the lasso's box, handles and bar belong to it, not to the canvas's own gestures.
        if let box = lasso.view, !box.isHidden, v.isDescendant(of: box) { return false }
        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // Catches a touch that only grew palm-sized after it landed (or a palm lifting off as a "tap").
        if fingerOnlyGestures.contains(where: { $0 === gestureRecognizer }), isWritingHandActive { return false }
        // When fingers draw, a quick ":" or a held stroke mustn't open the Ask menu or select things.
        if fingersDraw, gestureRecognizer === longPress || isSingleFingerDoubleTap(gestureRecognizer) { return false }
        if gestureRecognizer === longPress {
            let p = gestureRecognizer.location(in: chrome)
            return hitTestElement(at: p) != nil
        }
        return true
    }

    /// Finger drawing is on and the current tool draws with PencilKit, so a finger is a pen.
    var fingersDraw: Bool { tool.fingerDrawing && tool.kind.usesPencilKit }

    private func isSingleFingerDoubleTap(_ g: UIGestureRecognizer) -> Bool {
        guard let tap = g as? UITapGestureRecognizer else { return false }
        return tap.numberOfTapsRequired == 2 && tap.numberOfTouchesRequired == 1
    }

    // MARK: Undo gestures

    @objc func handleUndoTap() {
        guard tool.gestureUndo else { return }
        undo()
        showToast(symbol: "arrow.uturn.backward")
    }

    @objc func handleRedoTap() {
        guard tool.gestureUndo else { return }
        redo()
        showToast(symbol: "arrow.uturn.forward")
    }

    /// A finger double-tap on the page opens the tutor's Ask menu right there.
    @objc func handleDoubleTap(_ g: UITapGestureRecognizer) {
        guard tool.kind != .text, replayTime == nil else { return }
        requestTutorMenu(at: g.location(in: chrome))
    }

    /// Small centred glyph flash, like Notability's undo feedback.
    func showToast(symbol: String) {
        let size: CGFloat = 64
        let v = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
        v.frame = CGRect(x: (view.bounds.width - size) / 2, y: view.bounds.height * 0.42, width: size, height: size)
        v.layer.cornerRadius = 16
        v.clipsToBounds = true
        let iv = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold)))
        iv.tintColor = .label
        iv.contentMode = .center
        iv.frame = v.bounds
        v.contentView.addSubview(iv)
        v.alpha = 0
        view.addSubview(v)
        UIView.animate(withDuration: 0.12, animations: { v.alpha = 1 }) { _ in
            UIView.animate(withDuration: 0.3, delay: 0.35, options: [], animations: { v.alpha = 0 }) { _ in v.removeFromSuperview() }
        }
    }

    // MARK: Hit testing

    /// Topmost element under a document point (above-ink elements first).
    func hitTestElement(at docPoint: CGPoint) -> CanvasElement? {
        let candidates = document.content.elements.reversed()
        for e in candidates where e.drawsAboveInk {
            if document.docRect(for: e).insetBy(dx: -6, dy: -6).contains(docPoint) { return e }
        }
        for e in candidates where !e.drawsAboveInk {
            if document.docRect(for: e).contains(docPoint) { return e }
        }
        return nil
    }

    // MARK: Taps

    @objc func handleTap(_ g: UITapGestureRecognizer) {
        takeKeyFocus()
        if eyedropper != nil { finishEyedropper(at: g.location(in: chrome)); return }
        let docPoint = g.location(in: chrome)
        if replayTime != nil {
            host?.canvasReplayTapped(at: docPoint)
            return
        }
        switch tool.kind {
        case .text:
            // Tapping a box (yours or the tutor's) edits it with the caret where you tapped; tapping
            // empty paper while a box is open just closes it, the next tap starts a new one.
            let wasEditing = editingTextView?.isFirstResponder == true
            if wasEditing { endTextEditing() }
            if let e = hitTestElement(at: docPoint), case .text = e.kind {
                beginEditingText(element: e, at: docPoint)
            } else if !wasEditing {
                beginNewText(at: docPoint)
            }
        case .select:
            if let e = hitTestElement(at: docPoint) {
                select(e.id)
            } else {
                select(nil)
            }
        case .lasso:
            handleLassoTap(at: docPoint)
        case .tutor:
            // A tap asks about whatever is around that point.
            let (page, p) = document.pagePoint(fromDoc: docPoint)
            let region = regionAround(pagePoint: p, page: page)
            showRegion(document.docRect(region, page: page))
            host?.canvasRegionSelected(page: page, rect: region, anchor: viewRect(fromDoc: document.docRect(region, page: page)))
        default:
            endShapeEditing()
            // A finger tap on the tutor's writing or marks selects it: drag to move it, or use the bar
            // to ask about it, edit it, duplicate or delete it. (Pencil taps keep writing.)
            if lastTapWasFinger, !fingersDraw, let e = hitTestElement(at: docPoint), e.isTutor {
                select(e.id)
            } else if selectedElementID != nil {
                select(nil)
            }
        }
    }

    @objc func handleLongPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        let p = g.location(in: chrome)
        if let e = hitTestElement(at: p) {
            Haptics.tap()
            select(e.id)
        }
    }

    /// The area of ink/elements near a point, used when the student taps with the tutor tool.
    func regionAround(pagePoint p: CGPoint, page: Int) -> CGRect {
        let pageOrigin = document.pageOrigin(page)
        let probe = CGRect(x: p.x - 140, y: p.y - 70, width: 280, height: 140)
        var union = CGRect.null
        for s in document.strokes(onPage: page) {
            let r = s.renderBounds.offsetBy(dx: -pageOrigin.x, dy: -pageOrigin.y)
            if r.intersects(probe) { union = union.union(r) }
        }
        for e in document.elements(onPage: page) where e.frame.intersects(probe) {
            union = union.union(e.frame)
        }
        if union.isNull { union = probe }
        let pageBounds = CGRect(origin: .zero, size: document.pageSize)
        return union.insetBy(dx: -12, dy: -12).intersection(pageBounds)
    }

    func viewRect(fromDoc r: CGRect) -> CGRect {
        chrome.convert(r, to: view)
    }

    // MARK: Region selection (Ask Tutor tool)

    @objc func handleRegionPan(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: chrome)
        switch g.state {
        case .began:
            regionStartDoc = p
            showRegion(CGRect(origin: p, size: .zero))
        case .changed:
            guard let s = regionStartDoc else { return }
            showRegion(CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y)))
        case .ended:
            guard let s = regionStartDoc else { return }
            var r = CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
            regionStartDoc = nil
            if r.width < 20 || r.height < 20 {
                let (page, pp) = document.pagePoint(fromDoc: p)
                r = document.docRect(regionAround(pagePoint: pp, page: page), page: page)
            }
            let (page, pageRect) = document.pageRectFromDoc(r)
            let clipped = pageRect.intersection(CGRect(origin: .zero, size: document.pageSize))
            guard !clipped.isNull else { clearRegion(); return }
            let docClipped = document.docRect(clipped, page: page)
            showRegion(docClipped)
            Haptics.tap()
            host?.canvasRegionSelected(page: page, rect: clipped, anchor: viewRect(fromDoc: docClipped))
        default:
            regionStartDoc = nil
            clearRegion()
        }
    }

    func showRegion(_ docRect: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        regionLayer.path = UIBezierPath(roundedRect: docRect, cornerRadius: 8 / zoom).cgPath
        regionLayer.lineWidth = 2 / zoom
        regionLayer.lineDashPattern = [NSNumber(value: Double(7 / zoom)), NSNumber(value: Double(5 / zoom))]
        CATransaction.commit()
    }

    func clearRegion() {
        regionLayer.path = nil
    }

    // MARK: Selection

    func select(_ id: String?) {
        if editingTextView != nil && id != nil { endTextEditing() }
        // An item selected here and a lasso selection never show together.
        if id != nil { clearLassoSelection() }
        selectedElementID = id
        guard let id, let e = document.element(id) else {
            selectionView.isHidden = true
            host?.canvasSelectionChanged(nil)
            return
        }
        selectionView.frame = document.docRect(for: e).insetBy(dx: -4, dy: -4)
        selectionView.configure(for: e, zoom: zoom)
        selectionView.isHidden = false
        chrome.bringSubviewToFront(selectionView)
        host?.canvasSelectionChanged(e)
    }

    @objc func handleMovePan(_ g: UIPanGestureRecognizer) {
        guard let id = selectedElementID, let e = document.element(id), let v = elementViews[id] else { return }
        let t = g.translation(in: chrome)
        switch g.state {
        case .began:
            moveStartFrame = document.docRect(for: e)
        case .changed:
            guard let start = moveStartFrame else { return }
            let r = start.offsetBy(dx: t.x, dy: t.y)
            v.frame = r.insetBy(dx: -ElementView.padding, dy: -ElementView.padding)
            selectionView.frame = r.insetBy(dx: -4, dy: -4)
            selectionView.layoutChrome(zoom: zoom)
        case .cancelled, .failed:
            // Interrupted (a call, a system gesture): put it back where it was.
            guard let start = moveStartFrame else { return }
            moveStartFrame = nil
            v.frame = start.insetBy(dx: -ElementView.padding, dy: -ElementView.padding)
            selectionView.frame = start.insetBy(dx: -4, dy: -4)
            selectionView.layoutChrome(zoom: zoom)
        case .ended:
            guard let start = moveStartFrame else { return }
            moveStartFrame = nil
            let r = start.offsetBy(dx: t.x, dy: t.y)
            let (page, local) = document.pageRectFromDoc(r)
            document.update(id, actionName: "Move") {
                $0.pageIndex = page
                $0.frame = local
            }
        default:
            break
        }
    }

    @objc func handleResizePan(_ g: UIPanGestureRecognizer) {
        guard let id = selectedElementID, let e = document.element(id), let v = elementViews[id] else { return }
        let t = g.translation(in: chrome)
        switch g.state {
        case .began:
            moveStartFrame = e.frame
        case .changed, .ended:
            guard let start = moveStartFrame else { return }
            var w = max(40, start.width + t.x)
            var h = max(30, start.height + t.y)
            if case .image = e.kind {
                let aspect = start.height / max(start.width, 1)
                h = w * aspect
            }
            if case .math = e.kind {
                let aspect = start.height / max(start.width, 1)
                h = w * aspect
            }
            w = min(w, document.pageSize.width * 1.2)
            let preview = CGRect(x: start.minX, y: start.minY, width: w, height: h)
            let docPreview = document.docRect(preview, page: e.pageIndex)
            v.frame = docPreview.insetBy(dx: -ElementView.padding, dy: -ElementView.padding)
            selectionView.frame = docPreview.insetBy(dx: -4, dy: -4)
            selectionView.layoutChrome(zoom: zoom)
            if g.state == .ended {
                moveStartFrame = nil
                let env = environment()
                document.update(id, actionName: "Resize") { el in
                    ElementResizer.resize(&el, to: CGSize(width: w, height: h), from: start, env: env)
                }
            }
        default:
            // Interrupted: back to its size before the drag.
            if moveStartFrame != nil {
                let r = document.docRect(for: e)
                v.frame = r.insetBy(dx: -ElementView.padding, dy: -ElementView.padding)
                selectionView.frame = r.insetBy(dx: -4, dy: -4)
                selectionView.layoutChrome(zoom: zoom)
            }
            moveStartFrame = nil
        }
    }

    func performSelectionAction(_ action: ElementAction) {
        guard let id = selectedElementID, let e = document.element(id) else { return }
        switch action {
        case .delete:
            select(nil)
            document.remove(id, actionName: "Delete")
        case .duplicate:
            var copy = e
            copy.id = document.nextElementID()
            copy.frame = e.frame.offsetBy(dx: 24, dy: 24)
            copy.createdAt = Date()
            document.add(copy, actionName: "Duplicate")
            select(copy.id)
        case .edit:
            select(nil)
            beginEditingText(element: e)
        default:
            host?.canvasElementAction(action, element: e)
        }
    }

    // MARK: Text editing

    /// A new box where you tapped, in the text tool's style, size and colour. It starts small and
    /// grows as you type, up to the page's right margin.
    func beginNewText(at docPoint: CGPoint) {
        endTextEditing()
        let (page, p) = document.pagePoint(fromDoc: docPoint)
        let pageW = document.pageSize.width
        // Near the right edge, start further left so there's room to type.
        let x = max(12, min(p.x, pageW - 24 - 200))
        let maxWidth = min(520, pageW - x - 24)
        guard maxWidth > 60 else { return }
        let style: TextStyle = tool.textStyle == .handwriting ? .typed : tool.textStyle
        let size = tool.textSize
        let font = StudentText.font(style: style, size: size)
        let tv = makeTextView(style: style, size: size, formatting: true)
        tv.typingAttributes = StudentText.baseAttributes(style: style, size: size, colorHex: tool.textColorHex)
        tv.maxWidth = maxWidth
        let inset = ElementRenderer.textInsets(style)
        let origin = CGPoint(x: x, y: p.y - font.lineHeight / 2 - inset.top)
        tv.frame = document.docRect(CGRect(origin: origin, size: CGSize(width: 120, height: font.lineHeight + inset.top + inset.bottom)), page: page)
        editingNewTextPage = page
        editingNewTextOrigin = origin
        overElements.addSubview(tv)
        editingTextView = tv
        resizeTextView(tv)
        startEditing(tv)
    }

    /// Edits an existing box in place: yours with its formatting, the tutor's in its own font with
    /// its markup kept. With a point, the caret goes where you tapped.
    func beginEditingText(element e: CanvasElement, at docPoint: CGPoint? = nil) {
        endTextEditing()
        guard case .text(let t) = e.kind else { return }
        let frame = document.docRect(for: e)
        let isStudentText = e.author == .student && !t.rich
        let tv = makeTextView(style: t.style, size: t.fontSize, formatting: isStudentText)
        tv.elementID = e.id
        if isStudentText {
            let s = StudentText.attributedString(t)
            tv.attributedText = s
            tv.typingAttributes = s.length > 0 ? s.attributes(at: s.length - 1, effectiveRange: nil)
                : StudentText.baseAttributes(style: t.style, size: t.fontSize, colorHex: t.colorHex)
            // Room to grow to the margin, unless the box was narrowed to wrap its lines on purpose.
            let inset = ElementRenderer.textInsets(t.style)
            let unwrapped = StudentText.size(s, width: .greatestFiniteMagnitude).width + inset.left + inset.right
            let (_, local) = document.pageRectFromDoc(frame)
            let toMargin = min(520, document.pageSize.width - local.minX - 24)
            tv.maxWidth = unwrapped > frame.width + 2 ? frame.width : max(frame.width, toMargin)
        } else {
            tv.tutorContent = t
            tv.font = ElementRenderer.font(for: t, author: e.author, env: environment())
            tv.textColor = UIColor(hex: t.colorHex)
            tv.text = t.text
            tv.maxWidth = frame.width
        }
        tv.frame = frame
        elementViews[e.id]?.isHidden = true
        overElements.addSubview(tv)
        editingTextView = tv
        resizeTextView(tv)
        if let docPoint {
            let p = CGPoint(x: docPoint.x - tv.frame.minX, y: docPoint.y - tv.frame.minY)
            if let pos = tv.closestPosition(to: p) { tv.selectedTextRange = tv.textRange(from: pos, to: pos) }
        }
        startEditing(tv)
    }

    private func makeTextView(style: TextStyle, size: CGFloat, formatting: Bool) -> CanvasTextView {
        let tv = CanvasTextView(frame: .zero, textContainer: nil)
        tv.style = style
        tv.baseSize = size
        tv.applyStyleDecoration()
        tv.zoom = zoom
        tv.allowsEditingTextAttributes = formatting
        tv.delegate = self
        tv.contentScaleFactor = min(displayScale * zoom, displayScale * 4)
        if formatting {
            let bar = TextFormatBar(textView: tv)
            bar.onDone = { [weak self] in self?.endTextEditing() }
            tv.inputAccessoryView = bar
        }
        return tv
    }

    private func startEditing(_ tv: CanvasTextView) {
        // Scrolling the page mustn't close the keyboard mid-sentence.
        canvasView.keyboardDismissMode = .none
        observeKeyboard()
        tv.becomeFirstResponder()
    }

    /// Left-aligned student boxes hug their text (up to `maxWidth`); centred / right-aligned ones
    /// use the full width; tutor boxes keep theirs. The height always fits the text.
    func resizeTextView(_ textView: UITextView) {
        guard let tv = textView as? CanvasTextView else { return }
        let inset = tv.textContainerInset
        if tv.tutorContent == nil {
            if tv.hasNonLeftAlignment {
                tv.frame.size.width = tv.maxWidth
            } else {
                let fit = StudentText.size(tv.attributedText ?? NSAttributedString(), width: tv.maxWidth - inset.left - inset.right)
                tv.frame.size.width = min(tv.maxWidth, max(120, fit.width + inset.left + inset.right + 8))
            }
        }
        let fit = tv.sizeThatFits(CGSize(width: tv.bounds.width, height: .greatestFiniteMagnitude))
        let lineHeight = (tv.typingAttributes[.font] as? UIFont)?.lineHeight ?? tv.font?.lineHeight ?? 22
        tv.frame.size.height = max(fit.height, lineHeight + inset.top + inset.bottom)
    }

    func textViewDidChange(_ textView: UITextView) {
        resizeTextView(textView)
        (textView.inputAccessoryView as? TextFormatBar)?.refresh()
        if let tv = textView as? CanvasTextView { scrollCaretVisible(tv) }
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        (textView.inputAccessoryView as? TextFormatBar)?.refresh()
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard text == "\n", let tv = textView as? CanvasTextView, tv.tutorContent == nil else { return true }
        return tv.handleReturn(in: range)
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        if textView === editingTextView { endTextEditing() }
    }

    func endTextEditing() {
        guard let tv = editingTextView else { return }
        editingTextView = nil
        stopObservingKeyboard()
        canvasView.keyboardDismissMode = .interactive
        let docFrame = tv.frame
        tv.removeFromSuperview()
        let env = environment()
        let existing = tv.elementID.flatMap { document.element($0) }
        let author = existing?.author ?? .student
        let content: TextContent
        if var t = tv.tutorContent {
            t.text = tv.text ?? ""
            content = t
        } else {
            let attr = NSAttributedString(attributedString: tv.attributedText ?? NSAttributedString())
            var t = TextContent(text: attr.string, style: tv.style, fontSize: tv.baseSize,
                                colorHex: StudentText.leading(attr)?.colorHex ?? tool.textColorHex, rich: false)
            t.attributed = StudentText.archive(attr)
            content = t
        }
        // The saved box is measured the way the page draws it.
        var size = docFrame.size
        if tv.tutorContent == nil && !tv.hasNonLeftAlignment {
            size.width = max(40, ElementRenderer.fittedTextWidth(content, author: author, maxWidth: docFrame.width, env: env))
        }
        size.height = ElementRenderer.measureText(content, author: author, width: size.width, env: env).height
        let blank = content.text.trimmed.isEmpty
        if let id = tv.elementID {
            elementViews[id]?.isHidden = false
            if blank {
                document.remove(id, actionName: "Delete Text")
            } else {
                let (page, local) = document.pageRectFromDoc(CGRect(origin: docFrame.origin, size: size))
                let unchanged: Bool = {
                    guard let old = existing, case .text(let t) = old.kind else { return false }
                    return t == content && old.pageIndex == page && old.frame.size.equalTo(local.size)
                }()
                if !unchanged {
                    document.update(id, actionName: "Edit Text") {
                        $0.pageIndex = page
                        $0.frame = local
                        $0.kind = .text(content)
                    }
                }
            }
        } else if !blank, let page = editingNewTextPage, let origin = editingNewTextOrigin {
            let e = CanvasElement(id: document.nextElementID(), pageIndex: page, frame: CGRect(origin: origin, size: size),
                                  author: .student, kind: .text(content))
            document.add(e, actionName: "Add Text")
        }
        editingNewTextPage = nil
        editingNewTextOrigin = nil
    }

    // MARK: Keyboard

    private func observeKeyboard() {
        guard extras.keyboardObservers.isEmpty else { return }
        let center = NotificationCenter.default
        extras.keyboardObservers = [
            center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] n in
                let end = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                MainActor.assumeIsolated { self?.keyboardMoved(to: end) }
            },
            center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setKeyboardInset(0) }
            },
        ]
    }

    func stopObservingKeyboard() {
        for o in extras.keyboardObservers { NotificationCenter.default.removeObserver(o) }
        extras.keyboardObservers = []
        setKeyboardInset(0)
    }

    /// Keeps the box being typed in above the keyboard (and its formatting bar).
    private func keyboardMoved(to screenFrame: CGRect?) {
        guard let screenFrame, let window = view.window else { return }
        let kb = view.convert(screenFrame, from: window.screen.coordinateSpace)
        setKeyboardInset(max(0, canvasView.frame.maxY - kb.minY))
        if let tv = editingTextView { scrollCaretVisible(tv) }
    }

    private func setKeyboardInset(_ h: CGFloat) {
        guard abs(extras.keyboardInset - h) > 0.5 else { return }
        extras.keyboardInset = h
        canvasView.contentInset.bottom = h
        canvasView.verticalScrollIndicatorInsets.bottom = h
    }

    func scrollCaretVisible(_ tv: CanvasTextView) {
        guard extras.keyboardInset > 0, let r = tv.selectedTextRange else { return }
        let caret = canvasView.convert(tv.caretRect(for: r.end), from: tv)
        let visible = CGRect(x: canvasView.contentOffset.x, y: canvasView.contentOffset.y,
                             width: canvasView.bounds.width, height: canvasView.bounds.height - extras.keyboardInset)
        guard !visible.insetBy(dx: 0, dy: 30).contains(caret) else { return }
        let y = caret.midY - (canvasView.bounds.height - extras.keyboardInset) * 0.4
        let maxY = canvasView.contentSize.height + extras.keyboardInset - canvasView.bounds.height
        canvasView.setContentOffset(CGPoint(x: canvasView.contentOffset.x, y: max(0, min(maxY, y))), animated: true)
    }

    // MARK: Shape snapping (draw and hold)

    func strokeBegan(_ p: CGPoint, _ t: TimeInterval) {
        snap = SnapState()
        snap.points = [p]
        snap.times = [t]
        snap.strokeCountAtBegin = canvasView.drawing.strokes.count
        shapePreview.clear()
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(timeInterval: 0.08, target: self, selector: #selector(checkHold), userInfo: nil, repeats: true)
    }

    func strokeMoved(_ p: CGPoint, _ t: TimeInterval) {
        if let shape = snap.shape {
            // After snapping, keep moving to resize before lifting.
            if p.distance(to: snap.snapPoint) * zoom > 3 {
                let adjusted = shape.adjusted(anchor: snap.anchor, original: snap.original, to: p)
                snap.pending = adjusted
                shapePreview.show(adjusted, color: UIColor(hex: tool.inkColorHex), width: tool.inkWidth)
            }
            return
        }
        snap.points.append(p)
        snap.times.append(t)
    }

    @objc func checkHold() {
        guard snap.shape == nil, snap.points.count > 6, let lastT = snap.times.last else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // Still for at least 0.5s?
        guard now - lastT > 0.5 || stillDuration() > 0.5 else { return }
        let length = ShapeGeometry.pathLength(snap.points)
        guard length * zoom > 30, let shape = ShapeRecognizer.recognize(snap.points) else { return }
        snap.shape = shape
        snap.pending = shape
        let b = ShapeGeometry.bounds(shape.outline())
        let start = snap.points[0]
        let corners = [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY), CGPoint(x: b.minX, y: b.maxY), CGPoint(x: b.maxX, y: b.maxY)]
        let anchor = corners.min { $0.distance(to: start) < $1.distance(to: start) } ?? start
        snap.anchor = anchor
        snap.original = CGPoint(x: anchor.x == b.minX ? b.maxX : b.minX, y: anchor.y == b.minY ? b.maxY : b.minY)
        if case .line(let a, _) = shape { snap.anchor = a }
        snap.snapPoint = snap.points.last ?? start
        if let inking = tool.pkTool() as? PKInkingTool {
            snap.ink = inking.ink
            snap.width = inking.width
        }
        // Stop PencilKit drawing the raw stroke: the clean shape replaces it when the pencil lifts
        // (the stroke observer keeps following the pencil for resizing).
        canvasView.drawingGestureRecognizer.isEnabled = false
        canvasView.drawingGestureRecognizer.isEnabled = true
        shapePreview.show(shape, color: UIColor(hex: tool.inkColorHex), width: tool.inkWidth)
        if #available(iOS 17.5, *) {
            UICanvasFeedbackGenerator(view: canvasView).alignmentOccurred(at: chrome.convert(snap.snapPoint, to: canvasView))
        }
        holdTimer?.invalidate()
    }

    private func stillDuration() -> TimeInterval {
        guard let last = snap.points.last, let lastT = snap.times.last else { return 0 }
        var i = snap.points.count - 1
        while i > 0 {
            if snap.points[i].distance(to: last) * zoom > 2.5 { break }
            i -= 1
        }
        return lastT - snap.times[i]
    }

    func strokeEnded(cancelled: Bool) {
        holdTimer?.invalidate()
        holdTimer = nil
        guard !cancelled, let shape = snap.pending ?? snap.shape else {
            shapePreview.clear()
            snap = SnapState()
            return
        }
        commitSnappedShape(shape)
    }

    /// Adds the clean shape as one undoable step ("Add Shape"). PencilKit's stroke was cancelled
    /// at the snap; anything of it that was committed anyway is dropped.
    private func commitSnappedShape(_ shape: RecognizedShape) {
        var d = document.drawing
        if d.strokes.count > snap.strokeCountAtBegin {
            d.strokes.removeSubrange(snap.strokeCountAtBegin...)
        }
        let fallback = PKInk(.pen, color: UIColor(hex: tool.inkColorHex))
        let edit = EditableShape(shape: shape, strokeIndex: d.strokes.count, ink: snap.ink ?? fallback,
                                 width: snap.width, opacity: 1, creationDate: Date())
        d.strokes.append(edit.makeStroke())
        lateStrokeGuard = (count: d.strokes.count, date: Date(), until: Date().addingTimeInterval(0.8))
        document.replaceDrawing(d, actionName: "Add Shape")
        shapePreview.clear()
        host?.canvasShapeSnapped(shape.name)
        snap = SnapState()
        beginShapeEditing(edit)
        host?.canvasStudentWrote(docRects: [shape.bounds])
    }

    /// Called when PencilKit adds strokes: a raw stroke from a snapped shape that PencilKit
    /// committed after all (despite the cancel) is removed.
    func applyPendingSnapIfReady() {
        guard let g = lateStrokeGuard else { return }
        guard Date() < g.until else { lateStrokeGuard = nil; return }
        var d = canvasView.drawing
        guard d.strokes.count > g.count else { return }
        let late = d.strokes[g.count...].filter { $0.path.creationDate < g.date }
        guard !late.isEmpty else { return }
        d.strokes = Array(d.strokes[..<g.count]) + d.strokes[g.count...].filter { $0.path.creationDate >= g.date }
        lateStrokeGuard = nil
        isApplyingDrawing = true
        canvasView.drawing = d
        isApplyingDrawing = false
        document.canvasDrawingChanged(d)
    }

    // MARK: Hover

    @objc func handleHover(_ g: UIHoverGestureRecognizer) {
        let p = g.location(in: chrome)
        var isPencilHover = false
        if #available(iOS 16.1, *) { isPencilHover = g.zOffset > 0 }
        if isPencilHover { lastHoverDocPoint = p }
        setPencilHovering(isPencilHover && (g.state == .began || g.state == .changed), at: isPencilHover ? g.location(in: view) : nil)
        guard tool.hoverPreview, isPencilHover, replayTime == nil, eyedropper == nil,
              tool.kind == .pen || tool.kind == .highlighter || tool.kind == .eraser else {
            hoverPreview.hide()
            return
        }
        switch g.state {
        case .began, .changed:
            let isEraser = tool.kind == .eraser
            let d = isEraser ? tool.eraserWidth : tool.inkWidth
            hoverPreview.show(at: p, diameter: d, color: UIColor(hex: tool.inkColorHex), isEraser: isEraser, zoom: zoom)
        default:
            hoverPreview.hide()
        }
    }

    // MARK: Apple Pencil double-tap & squeeze

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        handlePencilTap(hoverLocation: nil)
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        handlePencilTap(hoverLocation: tap.hoverPose?.location)
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended else { return }
        let docPoint = squeeze.hoverPose.map { view.convert($0.location, to: chrome) } ?? lastHoverDocPoint
        handleSqueeze(docPoint: docPoint)
    }

    func handlePencilTap(hoverLocation: CGPoint?) {
        let settings = AppSettings.shared
        switch settings.doubleTapAction {
        case .nothing:
            return
        case .eraser:
            toggleEraser()
        case .previous:
            host?.canvasRequestTool(previousToolKind)
        case .askTutor:
            let docPoint = hoverLocation.map { view.convert($0, to: chrome) } ?? lastHoverDocPoint
            requestTutorMenu(at: docPoint)
        case .system:
            switch UIPencilInteraction.preferredTapAction {
            case .ignore:
                return
            case .switchPrevious:
                host?.canvasRequestTool(previousToolKind)
            case .showColorPalette, .showInkAttributes:
                let anchor = hoverLocation.map { CGRect(origin: $0, size: .zero) } ?? CGRect(x: view.bounds.midX, y: 80, width: 0, height: 0)
                host?.canvasRequestPalette(anchor: anchor)
            default:
                toggleEraser()
            }
        }
    }

    func toggleEraser() {
        if tool.kind == .eraser {
            host?.canvasRequestTool(previousToolKind == .eraser ? .pen : previousToolKind)
        } else {
            host?.canvasRequestTool(.eraser)
        }
    }

    func handleSqueeze(docPoint: CGPoint?) {
        switch AppSettings.shared.squeezeAction {
        case .nothing: return
        case .toolPalette:
            let anchor = docPoint.map { viewRect(fromDoc: CGRect(origin: $0, size: .zero)) } ?? CGRect(x: view.bounds.midX, y: 80, width: 0, height: 0)
            host?.canvasRequestPalette(anchor: anchor)
        case .tutorMenu:
            requestTutorMenu(at: docPoint)
        }
    }

    func requestTutorMenu(at docPoint: CGPoint?) {
        let p: CGPoint
        if let docPoint {
            p = docPoint
        } else if let recent = document.drawing.strokes.last?.renderBounds, isVisible(recent) {
            p = CGPoint(x: recent.maxX, y: recent.midY)
        } else {
            let r = visibleDocRect
            p = CGPoint(x: r.midX, y: r.midY)
        }
        Haptics.tap()
        host?.canvasTutorMenuRequested(docPoint: p, anchor: viewRect(fromDoc: CGRect(origin: p, size: .zero)))
    }
}

/// Resizing rules per element type.
@MainActor
enum ElementResizer {
    static func resize(_ e: inout CanvasElement, to size: CGSize, from start: CGRect, env: RenderEnvironment) {
        switch e.kind {
        case .text(let t):
            let h = ElementRenderer.measureText(t, author: e.author, width: size.width, env: env).height
            e.frame = CGRect(x: start.minX, y: start.minY, width: size.width, height: h)
        case .math(var m):
            let scale = size.width / max(start.width, 1)
            m.fontSize = max(10, min(80, m.fontSize * scale))
            e.kind = .math(m)
            let s = ElementRenderer.measureMath(m)
            e.frame = CGRect(origin: start.origin, size: s)
        case .ink(var ink):
            let sx = size.width / max(start.width, 1), sy = size.height / max(start.height, 1)
            ink.strokes = ink.strokes.map { s in
                var c = s
                c.points = s.points.map { CGPoint(x: $0.x * sx, y: $0.y * sy) }
                return c
            }
            e.kind = .ink(ink)
            e.frame = CGRect(origin: start.origin, size: size)
        case .question(var q):
            q.promptHeight = ElementRenderer.questionPromptHeight(q, width: size.width, env: env)
            e.kind = .question(q)
            e.frame = CGRect(origin: start.origin, size: CGSize(width: size.width, height: max(size.height, q.promptHeight + 60)))
        case .table(let t):
            let s = ElementRenderer.tableSize(t, maxWidth: size.width)
            e.frame = CGRect(origin: start.origin, size: CGSize(width: size.width, height: s.height))
        case .code(let c):
            let s = CodeRenderer.size(for: c, width: max(240, size.width))
            e.frame = CGRect(origin: start.origin, size: s)
        case .labels(var l):
            // Labels keep pointing at the same parts of the picture as the set is scaled.
            let sx = size.width / max(start.width, 1), sy = size.height / max(start.height, 1)
            l.labels = l.labels.map { lb in
                var c = lb
                c.anchor = CGPoint(x: lb.anchor.x * sx, y: lb.anchor.y * sy)
                c.box = CGRect(x: lb.box.minX * sx, y: lb.box.minY * sy, width: lb.box.width, height: lb.box.height)
                return c
            }
            l.covers = l.covers.map { CGRect(x: $0.minX * sx, y: $0.minY * sy, width: $0.width * sx, height: $0.height * sy) }
            e.kind = .labels(l)
            e.frame = CGRect(origin: start.origin, size: size)
        default:
            e.frame = CGRect(origin: start.origin, size: size)
        }
    }
}
