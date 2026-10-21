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
        guard tracked == nil, touches.count == 1, let t = touches.first,
              t.type == .pencil || (acceptsFinger && t.type == .direct) else {
            if tracked == nil { state = .failed }
            return
        }
        tracked = t
        onBegin?(t.location(in: coordinateView), t.timestamp)
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
        tracked = nil
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = tracked, touches.contains(t) else { return }
        onEnd?(true)
        tracked = nil
        state = .failed
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
    var pending: RecognizedShape?
    var pendingDeadline = Date.distantPast
}

extension NoteCanvasViewController: UITextViewDelegate, UIPencilInteractionDelegate {

    // MARK: Setup

    func setupGestures() {
        let undoTap = UITapGestureRecognizer(target: self, action: #selector(handleUndoTap))
        undoTap.numberOfTouchesRequired = 2
        undoTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        undoTap.delegate = self
        canvasView.addGestureRecognizer(undoTap)

        let redoTap = UITapGestureRecognizer(target: self, action: #selector(handleRedoTap))
        redoTap.numberOfTouchesRequired = 3
        redoTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        redoTap.delegate = self
        canvasView.addGestureRecognizer(redoTap)

        tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tapGesture.delegate = self
        canvasView.addGestureRecognizer(tapGesture)

        let doubleFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTapZoom(_:)))
        doubleFingerTap.numberOfTapsRequired = 2
        doubleFingerTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        doubleFingerTap.delegate = self
        canvasView.addGestureRecognizer(doubleFingerTap)

        longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.45
        longPress.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        longPress.delegate = self
        canvasView.addGestureRecognizer(longPress)

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

        let movePan = UIPanGestureRecognizer(target: self, action: #selector(handleMovePan(_:)))
        selectionView.addGestureRecognizer(movePan)
        let resizePan = UIPanGestureRecognizer(target: self, action: #selector(handleResizePan(_:)))
        selectionView.handle.addGestureRecognizer(resizePan)
        selectionView.onAction = { [weak self] action in self?.performSelectionAction(action) }

        let pencil = UIPencilInteraction()
        pencil.delegate = self
        view.addInteraction(pencil)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === strokeObserver || other === strokeObserver { return true }
        if gestureRecognizer === tapGesture && other === canvasView.drawingGestureRecognizer { return true }
        return false
    }

    /// Touches on the text box being edited (caret taps, selection long-presses) and on the selection's
    /// action buttons belong to those views; otherwise the canvas tap would end editing or deselect.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer !== strokeObserver, let v = touch.view else { return true }
        if let tv = editingTextView, v.isDescendant(of: tv) { return false }
        if v.isDescendant(of: selectionView.actionBar) { return false }
        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === longPress {
            let p = gestureRecognizer.location(in: chrome)
            return hitTestElement(at: p) != nil
        }
        return true
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

    @objc func handleDoubleTapZoom(_ g: UITapGestureRecognizer) {
        guard tool.kind != .text else { return }
        if abs(zoom - fitZoom) > 0.02 {
            zoomToFit()
        }
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
        if eyedropper != nil { finishEyedropper(at: g.location(in: chrome)); return }
        let docPoint = g.location(in: chrome)
        if replayTime != nil {
            host?.canvasReplayTapped(at: docPoint)
            return
        }
        switch tool.kind {
        case .text:
            if let tv = editingTextView, tv.isFirstResponder {
                endTextEditing()
                return
            }
            if let e = hitTestElement(at: docPoint), case .text = e.kind, e.author == .student {
                beginEditingText(element: e)
            } else {
                beginNewText(at: docPoint)
            }
        case .select:
            if let e = hitTestElement(at: docPoint) {
                select(e.id)
            } else {
                select(nil)
            }
        case .tutor:
            // A tap asks about whatever is around that point.
            let (page, p) = document.pagePoint(fromDoc: docPoint)
            let region = regionAround(pagePoint: p, page: page)
            showRegion(document.docRect(region, page: page))
            host?.canvasRegionSelected(page: page, rect: region, anchor: viewRect(fromDoc: document.docRect(region, page: page)))
        default:
            if selectedElementID != nil { select(nil) }
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
        case .ended, .cancelled:
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

    func beginNewText(at docPoint: CGPoint) {
        endTextEditing()
        let (page, p) = document.pagePoint(fromDoc: docPoint)
        let width = min(360, document.pageSize.width - p.x - 24)
        guard width > 60 else { return }
        let font = NoteFonts.studentFont(size: 20)
        let tv = makeTextView(font: font, color: UIColor(hex: tool.penColorHex))
        let docOrigin = document.docRect(CGRect(x: p.x, y: p.y - font.lineHeight / 2, width: width, height: font.lineHeight + 8), page: page)
        tv.frame = docOrigin
        editingNewTextPage = page
        editingNewTextOrigin = CGPoint(x: p.x, y: p.y - font.lineHeight / 2)
        overElements.addSubview(tv)
        editingTextView = tv
        tv.becomeFirstResponder()
    }

    func beginEditingText(element e: CanvasElement) {
        endTextEditing()
        guard case .text(let t) = e.kind else { return }
        let font = NoteFonts.studentFont(size: t.fontSize)
        let tv = makeTextView(font: font, color: UIColor(hex: t.colorHex))
        tv.text = t.text
        tv.elementID = e.id
        tv.frame = document.docRect(for: e)
        elementViews[e.id]?.isHidden = true
        overElements.addSubview(tv)
        editingTextView = tv
        resizeTextView(tv)
        tv.becomeFirstResponder()
    }

    private func makeTextView(font: UIFont, color: UIColor) -> CanvasTextView {
        let tv = CanvasTextView(frame: .zero, textContainer: nil)
        tv.font = font
        tv.textColor = color
        tv.delegate = self
        tv.contentScaleFactor = min(displayScale * zoom, displayScale * 4)
        return tv
    }

    func resizeTextView(_ tv: UITextView) {
        let fit = tv.sizeThatFits(CGSize(width: tv.bounds.width, height: .greatestFiniteMagnitude))
        tv.frame.size.height = max(fit.height, (tv.font?.lineHeight ?? 20) + 8)
    }

    func textViewDidChange(_ textView: UITextView) {
        resizeTextView(textView)
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        if textView === editingTextView { endTextEditing() }
    }

    func endTextEditing() {
        guard let tv = editingTextView else { return }
        editingTextView = nil
        let text = tv.text ?? ""
        let docFrame = tv.frame
        tv.removeFromSuperview()
        let fontSize = tv.font?.pointSize ?? 20
        let colorHex = (tv.textColor ?? .black).hexString
        if let id = tv.elementID {
            elementViews[id]?.isHidden = false
            if text.trimmed.isEmpty {
                document.remove(id, actionName: "Delete Text")
            } else {
                let (page, local) = document.pageRectFromDoc(docFrame)
                document.update(id, actionName: "Edit Text") {
                    $0.pageIndex = page
                    $0.frame = local
                    $0.kind = .text(TextContent(text: text, style: .typed, fontSize: fontSize, colorHex: colorHex, rich: false))
                }
            }
        } else if !text.trimmed.isEmpty, let page = editingNewTextPage, let origin = editingNewTextOrigin {
            let local = CGRect(origin: origin, size: docFrame.size)
            let e = CanvasElement(id: document.nextElementID(), pageIndex: page, frame: local, author: .student,
                                  kind: .text(TextContent(text: text, style: .typed, fontSize: fontSize, colorHex: colorHex, rich: false)))
            document.add(e, actionName: "Add Text")
        }
        editingNewTextPage = nil
        editingNewTextOrigin = nil
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
        snap.pending = shape
        snap.pendingDeadline = Date().addingTimeInterval(0.6)
        applyPendingSnapIfReady()
    }

    /// Replaces the stroke PencilKit just committed with the perfected shape.
    func applyPendingSnapIfReady() {
        guard let shape = snap.pending, snap.shape != nil, Date() < snap.pendingDeadline || snap.pendingDeadline == .distantPast else { return }
        var d = canvasView.drawing
        guard d.strokes.count > snap.strokeCountAtBegin, let last = d.strokes.last else { return }
        let sizes = last.path.map { $0.size.width }
        let width = sizes.isEmpty ? tool.inkWidth : sizes.sorted()[sizes.count / 2]
        let opacity = last.path.first?.opacity ?? 1
        let pts = shape.outline(spacing: 2.5)
        var strokePoints: [PKStrokePoint] = []
        strokePoints.reserveCapacity(pts.count)
        for (i, p) in pts.enumerated() {
            strokePoints.append(PKStrokePoint(location: p, timeOffset: TimeInterval(i) * 0.004,
                                              size: CGSize(width: width, height: width), opacity: opacity,
                                              force: 1, azimuth: 0, altitude: .pi / 2))
        }
        let path = PKStrokePath(controlPoints: strokePoints, creationDate: last.path.creationDate)
        d.strokes[d.strokes.count - 1] = PKStroke(ink: last.ink, path: path, transform: .identity, mask: nil)
        isApplyingDrawing = true
        canvasView.drawing = d
        isApplyingDrawing = false
        document.canvasDrawingChanged(d)
        shapePreview.clear()
        host?.canvasShapeSnapped(shape.name)
        snap = SnapState()
    }

    // MARK: Hover

    @objc func handleHover(_ g: UIHoverGestureRecognizer) {
        let p = g.location(in: chrome)
        var isPencilHover = false
        if #available(iOS 16.1, *) { isPencilHover = g.zOffset > 0 }
        if isPencilHover { lastHoverDocPoint = p }
        guard tool.hoverPreview, isPencilHover, replayTime == nil,
              tool.kind == .pen || tool.kind == .highlighter || tool.kind == .eraser else {
            hoverPreview.hide()
            return
        }
        switch g.state {
        case .began, .changed:
            let isEraser = tool.kind == .eraser
            let d = isEraser ? (tool.eraserMode == .pixel ? tool.eraserWidth : 10) : tool.inkWidth
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
        default:
            e.frame = CGRect(origin: start.origin, size: size)
        }
    }
}
