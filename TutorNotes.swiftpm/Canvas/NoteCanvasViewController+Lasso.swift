import UIKit
import PencilKit

/// The selected strokes, drawn alone for handwriting and maths recognition.
struct LassoInkSnapshot {
    var image: UIImage      // selected strokes only (no items) on white, ~2x, padded a little
    var docBounds: CGRect   // document rect of those strokes
    var colorHex: String    // most common stroke colour, "#RRGGBB"
}

/// A selection being dragged: the originals are hidden while `preview` stands in for them.
struct LassoLift {
    let preview: UIImageView
    /// Where the picture sits, in document coordinates.
    let rect: CGRect
    let hidesStrokes: Bool
}

/// Everything the lasso tool keeps, so the canvas controller needs a single stored property for it.
@MainActor
final class LassoState {
    var gesture: LassoGestureRecognizer?
    /// The dashed loop shown while drawing it.
    let loopLayer = CAShapeLayer()
    var view: LassoSelectionView?
    var editMenu: UIEditMenuInteraction?
    /// Indices into the document's strokes. Safe because every outside change to the ink clears the selection.
    var strokes: [Int] = []
    var elementIDs: [String] = []
    /// Document rect of the selection; null when nothing is selected.
    var bounds = CGRect.null
    var lift: LassoLift?
    /// True while our own edits run, so the callbacks they cause don't clear the selection.
    var isCommitting = false
    var pasteAt: CGPoint?
    /// The custom colour picker: the colour it opened on, and the one the student chose (nil until they change it).
    var pickerStartHex: String?
    var pickedColour: UIColor?

    var isEmpty: Bool { strokes.isEmpty && elementIDs.isEmpty }
}

/// The lasso tool: select ink and items by looping them, then move, resize, rotate, recolour or
/// copy them. The selection UI is `LassoSelectionView`; the actions are in +LassoActions.
extension NoteCanvasViewController {

    // MARK: Setup

    /// Called whenever the tool changes: sets the lasso up on first use and switches it on for the lasso tool only.
    func configureLasso(for tool: CanvasToolConfig) {
        if lasso.gesture == nil { setupLasso() }
        lasso.gesture?.isEnabled = tool.kind == .lasso
        lasso.gesture?.acceptsFinger = tool.fingerDrawing
    }

    private func setupLasso() {
        let g = LassoGestureRecognizer(target: self, action: #selector(handleLassoGesture(_:)))
        g.coordinateView = chrome
        g.delegate = self
        g.accepts = { [weak self] touch in
            guard let self, self.replayTime == nil, self.eyedropper == nil else { return false }
            // Palm rejection: a finger only counts when it isn't part of the hand writing (see +Palm).
            return touch.type == .pencil || !self.isPalmTouch(touch)
        }
        canvasView.addGestureRecognizer(g)
        lasso.gesture = g
        let loop = lasso.loopLayer
        loop.fillColor = UIColor.systemBlue.withAlphaComponent(0.06).cgColor
        loop.strokeColor = UIColor.systemBlue.cgColor
        loop.lineCap = .round
        loop.lineJoin = .round
        chrome.layer.addSublayer(loop)
        let menu = UIEditMenuInteraction(delegate: self)
        view.addInteraction(menu)
        lasso.editMenu = menu
    }

    private func makeLassoView() -> LassoSelectionView {
        let v = LassoSelectionView()
        v.accepts = { [weak self] touch in !(self?.isPalmTouch(touch) ?? false) }
        v.onBegan = { [weak self] _ in self?.liftLassoSelection() }
        v.onChanged = { [weak self] t in self?.previewLasso(t) }
        v.onEnded = { [weak self] mode, t in self?.commitLasso(mode: mode, transform: t) }
        v.onCancelled = { [weak self] in
            self?.cancelLassoLift()
            self?.layoutLasso()
        }
        v.onAction = { [weak self] action in self?.performLassoAction(action) }
        chrome.addSubview(v)
        lasso.view = v
        return v
    }

    // MARK: Drawing the loop

    @objc func handleLassoGesture(_ g: LassoGestureRecognizer) {
        switch g.state {
        case .began:
            clearLassoSelection()
            if selectedElementID != nil { select(nil) }
            showLassoLoop(g.points)
        case .changed:
            showLassoLoop(g.points)
        case .ended:
            lasso.loopLayer.path = nil
            selectInsideLasso(ShapeGeometry.dedupe(g.points, minDistance: 3 / zoom))
        default:
            lasso.loopLayer.path = nil
        }
    }

    private func showLassoLoop(_ points: [CGPoint]) {
        let path = CGMutablePath()
        path.addLines(between: points)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lasso.loopLayer.path = path
        lasso.loopLayer.lineWidth = 2 / zoom
        lasso.loopLayer.lineDashPattern = [NSNumber(value: Double(7 / zoom)), NSNumber(value: Double(5 / zoom))]
        CATransaction.commit()
    }

    /// A tap with the lasso tool drops the selection, or offers Paste on an empty spot.
    func handleLassoTap(at docPoint: CGPoint) {
        if selectedElementID != nil { select(nil) }
        if !lasso.isEmpty {
            clearLassoSelection()
            return
        }
        guard CanvasClip.pasteboardHasContent else { return }
        lasso.pasteAt = docPoint
        let config = UIEditMenuConfiguration(identifier: nil, sourcePoint: chrome.convert(docPoint, to: view))
        lasso.editMenu?.presentEditMenu(with: config)
    }

    // MARK: Selecting

    /// Selects the ink and items the loop encloses; a loop around nothing leaves nothing selected.
    private func selectInsideLasso(_ loop: [CGPoint]) {
        guard loop.count > 2 else { return }
        let path = CGMutablePath()
        path.addLines(between: loop)
        path.closeSubpath()
        let box = path.boundingBox
        var strokes: [Int] = []
        for (i, stroke) in document.drawing.strokes.enumerated() where lassoEncloses(stroke, loop: path, box: box) {
            strokes.append(i)
        }
        let elements = document.content.elements.filter { path.contains(document.docRect(for: $0).center, using: .evenOdd) }
        setLassoSelection(strokes: strokes, elements: elements.map(\.id))
    }

    /// A stroke is in when at least half of its sampled points are inside the loop.
    private func lassoEncloses(_ stroke: PKStroke, loop: CGPath, box: CGRect) -> Bool {
        let bounds = stroke.renderBounds
        guard bounds.intersects(box) else { return false }
        let step = max(4, hypot(bounds.width, bounds.height) / 30)
        var inside = 0, total = 0
        for point in stroke.path.interpolatedPoints(by: .distance(step)) {
            total += 1
            if loop.contains(point.location.applying(stroke.transform), using: .evenOdd) { inside += 1 }
            if total >= 150 { break }
        }
        return total > 0 && inside * 2 >= total
    }

    /// Makes these strokes (by index) and items the lasso selection and shows its box.
    func setLassoSelection(strokes: [Int], elements: [String]) {
        if selectedElementID != nil { select(nil) }
        lasso.strokes = strokes
        lasso.elementIDs = elements
        lasso.bounds = lassoBounds()
        guard !lasso.bounds.isNull else {
            clearLassoSelection()
            return
        }
        let items = lassoElements
        let box = lasso.view ?? makeLassoView()
        box.configure(hasInk: !strokes.isEmpty,
                      canRecolour: !strokes.isEmpty || items.contains { canRecolour($0) },
                      canThicken: !strokes.isEmpty || items.contains { isInkMark($0) },
                      favourites: ColorFavorites.shared.colors)
        box.isHidden = false
        chrome.bringSubviewToFront(box)
        layoutLasso()
    }

    private func canRecolour(_ e: CanvasElement) -> Bool {
        switch e.kind {
        case .text, .math, .ink, .table: return true
        default: return false
        }
    }

    private func isInkMark(_ e: CanvasElement) -> Bool {
        if case .ink = e.kind { return true }
        return false
    }

    /// Drops the selection (and puts back anything lifted for a drag).
    func clearLassoSelection() {
        cancelLassoLift()
        lasso.strokes = []
        lasso.elementIDs = []
        lasso.bounds = .null
        lasso.view?.isHidden = true
    }

    /// Recomputes the box after the selected items changed; an emptied selection goes away.
    func refreshLassoSelection() {
        lasso.bounds = lassoBounds()
        if lasso.bounds.isNull { clearLassoSelection() } else { layoutLasso() }
    }

    /// An item left the document (deleted, undone, or removed by the tutor): it leaves the selection too.
    func lassoDroppedElement(_ id: String) {
        guard lasso.elementIDs.contains(id) else { return }
        if !lasso.isCommitting { cancelLassoLift() }
        lasso.elementIDs.removeAll { $0 == id }
        if !lasso.isCommitting { refreshLassoSelection() }
    }

    /// A selected item changed from outside (undo, the tutor): the box follows it.
    func lassoUpdatedElement(_ id: String) {
        guard lasso.elementIDs.contains(id), !lasso.isCommitting, lasso.lift == nil else { return }
        refreshLassoSelection()
    }

    /// Positions the selection view for the current zoom and scroll position.
    func layoutLasso() {
        guard let v = lasso.view, !v.isHidden, lasso.lift == nil, !lasso.bounds.isNull else { return }
        v.frame = chrome.bounds
        v.update(bounds: lasso.bounds, zoom: zoom, visible: visibleDocRect)
    }

    // MARK: Selected content

    /// Strokes that are still in the drawing, in selection order.
    func validLassoStrokeIndices() -> [Int] {
        let count = document.drawing.strokes.count
        return lasso.strokes.filter { $0 >= 0 && $0 < count }
    }

    var lassoStrokes: [PKStroke] {
        let all = document.drawing.strokes
        return lasso.strokes.compactMap { all[safe: $0] }
    }

    var lassoElements: [CanvasElement] {
        lasso.elementIDs.compactMap { document.element($0) }
    }

    /// Axis-aligned document rect of the selected ink and items; null when there are none.
    func lassoBounds() -> CGRect {
        var r = CGRect.null
        for stroke in lassoStrokes { r = r.union(stroke.renderBounds) }
        for e in lassoElements { r = r.union(document.docRect(for: e)) }
        return r
    }

    /// The selection drawn on its own in document order: items under the ink, the ink, items above it.
    func renderLassoSelection(rect: CGRect, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let elements = lassoElements
        let ink = PKDrawing(strokes: lassoStrokes)
        let env = environment()
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = UIGraphicsImageRenderer(size: rect.size, format: format).image { rc in
                let ctx = rc.cgContext
                ctx.translateBy(x: -rect.minX, y: -rect.minY)
                for e in elements where !e.drawsAboveInk {
                    ElementRenderer.draw(e, in: ctx, rect: document.docRect(for: e), env: env)
                }
                if !ink.strokes.isEmpty { ink.image(from: rect, scale: scale).draw(in: rect) }
                for e in elements where e.drawsAboveInk {
                    ElementRenderer.draw(e, in: ctx, rect: document.docRect(for: e), env: env)
                }
            }
        }
        return image
    }

    // MARK: Live transform

    /// A drag begins: draw the selection into a picture and hide the originals, so the drag only moves one image.
    func liftLassoSelection() {
        guard lasso.lift == nil, !lasso.bounds.isNull else { return }
        let rect = lasso.bounds.insetBy(dx: -ElementView.padding, dy: -ElementView.padding).integral
        var scale = min(zoom * displayScale, 3)
        let pixels = rect.width * rect.height * scale * scale
        if pixels > 24_000_000 { scale *= sqrt(24_000_000 / pixels) }
        let preview = UIImageView(image: renderLassoSelection(rect: rect, scale: scale))
        preview.frame = rect
        if let v = lasso.view { chrome.insertSubview(preview, belowSubview: v) } else { chrome.addSubview(preview) }
        let hidesStrokes = !lasso.strokes.isEmpty
        if hidesStrokes {
            let lifted = Set(lasso.strokes)
            var drawing = document.drawing
            drawing.strokes = drawing.strokes.enumerated().filter { !lifted.contains($0.offset) }.map { $0.element }
            isApplyingDrawing = true
            canvasView.drawing = drawing
            isApplyingDrawing = false
        }
        for id in lasso.elementIDs { elementViews[id]?.isHidden = true }
        lasso.lift = LassoLift(preview: preview, rect: rect, hidesStrokes: hidesStrokes)
    }

    /// The picture follows the drag. The transform is in document coordinates; a view's own transform
    /// works about its centre, so move the origin there and back.
    func previewLasso(_ t: CGAffineTransform) {
        guard let lift = lasso.lift else { return }
        let c = lift.rect.center
        lift.preview.transform = CGAffineTransform(translationX: c.x, y: c.y)
            .concatenating(t)
            .concatenating(CGAffineTransform(translationX: -c.x, y: -c.y))
    }

    /// The drag ended: apply it to the document in one undo step.
    func commitLasso(mode: LassoSelectionView.Mode, transform t: CGAffineTransform) {
        let isIdentity = abs(t.a - 1) < 0.001 && abs(t.d - 1) < 0.001 && abs(t.b) < 0.001 && abs(t.c) < 0.001
            && abs(t.tx) < 0.25 && abs(t.ty) < 0.25
        guard lasso.lift != nil, !isIdentity else {
            cancelLassoLift()
            layoutLasso()
            return
        }
        let name: String
        switch mode {
        case .move: name = "Move"
        case .resize: name = "Resize"
        case .rotate: name = "Rotate"
        }
        applyLassoTransform(t, actionName: name)
        endLassoLift()
        lasso.bounds = lassoBounds()
        // Elements grow a board themselves; ink dragged toward its edge needs the same room.
        document.growBoardIfNeeded(toFit: [lasso.bounds])
        layoutLasso()
        host?.canvasUndoStateChanged()
    }

    /// Puts everything back as it was before the drag.
    func cancelLassoLift() {
        guard let lift = lasso.lift else { return }
        if lift.hidesStrokes && replayTime == nil {
            isApplyingDrawing = true
            canvasView.drawing = document.drawing
            isApplyingDrawing = false
        }
        endLassoLift()
    }

    private func endLassoLift() {
        lasso.lift?.preview.removeFromSuperview()
        lasso.lift = nil
        for id in lasso.elementIDs { elementViews[id]?.isHidden = false }
    }

    /// Ink: concatenate the transform onto each stroke. Items: move so the centre follows it, scale by
    /// the transform's overall scale, and (for ink marks) transform their points.
    private func applyLassoTransform(_ t: CGAffineTransform, actionName: String) {
        lasso.isCommitting = true
        defer { lasso.isCommitting = false }
        let indices = validLassoStrokeIndices()
        if !indices.isEmpty {
            var strokes = document.drawing.strokes
            for i in indices { strokes[i].transform = strokes[i].transform.concatenating(t) }
            replaceLassoStrokes(strokes, actionName: actionName)
        }
        let scale = sqrt(abs(t.a * t.d - t.b * t.c))
        let env = environment()
        for id in lasso.elementIDs {
            document.update(id, actionName: actionName) { transformLassoElement(&$0, by: t, scale: scale, env: env) }
        }
    }

    func replaceLassoStrokes(_ strokes: [PKStroke], actionName: String) {
        var drawing = document.drawing
        drawing.strokes = strokes
        document.replaceDrawing(drawing, actionName: actionName)
    }

    private func transformLassoElement(_ e: inout CanvasElement, by t: CGAffineTransform, scale k: CGFloat, env: RenderEnvironment) {
        let old = document.docRect(for: e)
        var size = old.size * k
        var rect: CGRect?
        switch e.kind {
        case .text(var text):
            let fontSize = max(6, min(240, text.fontSize * k))
            let applied = fontSize / max(text.fontSize, 1)
            text.fontSize = fontSize
            e.kind = .text(text)
            size = ElementRenderer.measureText(text, author: e.author, width: old.width * applied, env: env)
        case .math(var math):
            math.fontSize = max(10, min(80, math.fontSize * k))
            e.kind = .math(math)
            size = ElementRenderer.measureMath(math)
        case .ink(let ink):
            let (moved, frame) = transformedInk(ink, from: old, by: t, scale: k, env: env)
            e.kind = .ink(moved)
            rect = frame
        default:
            let start = e.frame
            ElementResizer.resize(&e, to: size, from: start, env: env)
            size = e.frame.size
        }
        let centre = old.center.applying(t)
        let target = rect ?? CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2, width: size.width, height: size.height)
        let (page, local) = document.pageRectFromDoc(target)
        e.pageIndex = page
        e.frame = local
    }

    /// An ink mark with its points (relative to the frame) carried through `t`, and its new document frame.
    private func transformedInk(_ ink: InkContent, from old: CGRect, by t: CGAffineTransform, scale k: CGFloat,
                                env: RenderEnvironment) -> (InkContent, CGRect) {
        var out = ink
        out.width = max(0.5, min(80, ink.width * k))
        let moved = ink.strokes.map { stroke in
            InkStroke(points: stroke.points.map { CGPoint(x: old.minX + $0.x, y: old.minY + $0.y).applying(t) }, closed: stroke.closed)
        }
        let all = moved.flatMap { $0.points }
        guard !all.isEmpty else { return (out, old) }
        var frame = ShapeGeometry.bounds(all).insetBy(dx: -out.width - 2, dy: -out.width - 2)
        var labelAt: CGPoint?
        if let label = ink.label, !label.isEmpty, let offset = ink.labelOffset {
            let at = CGPoint(x: old.minX + offset.x, y: old.minY + offset.y).applying(t)
            let font = NoteFonts.tutorFont(style: .handwriting, size: max(15, out.width * 5.5), hand: env.hand)
            let size = ElementRenderer.richLayout(label, font: font, width: 260, rich: true).size
            frame = frame.union(CGRect(origin: at, size: size).insetBy(dx: -2, dy: -2))
            labelAt = at
        }
        out.strokes = moved.map { stroke in
            InkStroke(points: stroke.points.map { CGPoint(x: $0.x - frame.minX, y: $0.y - frame.minY) }, closed: stroke.closed)
        }
        if let labelAt { out.labelOffset = CGPoint(x: labelAt.x - frame.minX, y: labelAt.y - frame.minY) }
        return (out, frame)
    }

    // MARK: Recognition support

    /// The selected strokes drawn alone on white, for handwriting and maths recognition. Nil without ink.
    func lassoInkSnapshot() -> LassoInkSnapshot? {
        let strokes = lassoStrokes
        guard !strokes.isEmpty else { return nil }
        var bounds = CGRect.null
        for stroke in strokes { bounds = bounds.union(stroke.renderBounds) }
        let area = bounds.insetBy(dx: -16, dy: -16)
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(2, 4096 / max(area.width, area.height, 1))
        format.opaque = true
        let drawing = PKDrawing(strokes: strokes)
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = UIGraphicsImageRenderer(size: area.size, format: format).image { rc in
                UIColor.white.setFill()
                rc.fill(CGRect(origin: .zero, size: area.size))
                drawing.image(from: area, scale: format.scale).draw(in: CGRect(origin: .zero, size: area.size))
            }
        }
        return LassoInkSnapshot(image: image, docBounds: bounds, colorHex: dominantColourHex(of: strokes) ?? tool.penColorHex)
    }

    /// The most common stroke colour as "#RRGGBB".
    func dominantColourHex(of strokes: [PKStroke]) -> String? {
        let groups = Dictionary(grouping: strokes) { String($0.ink.color.hexString.prefix(7)) }
        return groups.max { $0.value.count < $1.value.count }?.key
    }

    /// Swaps the selected strokes for a converted item (typed text or maths), as one undo step, and clears the selection.
    func replaceLassoInk(with element: CanvasElement, actionName: String) {
        let drop = Set(validLassoStrokeIndices())
        lasso.isCommitting = true
        if !drop.isEmpty {
            let kept = document.drawing.strokes.enumerated().filter { !drop.contains($0.offset) }.map { $0.element }
            replaceLassoStrokes(kept, actionName: actionName)
        }
        document.add(element, actionName: actionName)
        lasso.isCommitting = false
        clearLassoSelection()
        host?.canvasUndoStateChanged()
    }

    // MARK: Paste

    /// Pastes a copied selection, an image or text, centred on `docPoint` (the middle of the visible area when nil).
    func pasteFromClipboard(at docPoint: CGPoint?) {
        let board = UIPasteboard.general
        let centre = docPoint ?? visibleDocRect.center
        if let data = board.data(forPasteboardType: CanvasClip.pasteboardType), let clip = CanvasClip(data: data) {
            pasteClip(clip, centredAt: centre)
        } else if let image = board.image {
            pasteImage(image, at: docPoint)
        } else if let text = board.string, !text.trimmed.isEmpty {
            pasteText(text, centredAt: centre)
        }
    }

    private func pasteClip(_ clip: CanvasClip, centredAt centre: CGPoint) {
        let doc = document.documentSize
        var origin = CGPoint(x: centre.x - clip.size.width / 2, y: centre.y - clip.size.height / 2)
        origin.x = max(0, min(origin.x, doc.width - clip.size.width))
        origin.y = max(0, min(origin.y, doc.height - clip.size.height))
        let shift = CGAffineTransform(translationX: origin.x, y: origin.y)
        let strokes = ((try? PKDrawing(data: clip.strokes))?.strokes ?? []).map { stroke -> PKStroke in
            var moved = stroke
            moved.transform = moved.transform.concatenating(shift)
            return moved
        }
        var elements: [CanvasElement] = []
        for source in clip.elements {
            var e = source
            e.id = document.nextElementID()
            e.createdAt = Date()
            if case .image(let image) = source.kind, let asset = importClipAsset(image.assetID, from: clip) {
                e.kind = .image(ImageContent(assetID: asset))
            }
            let (page, local) = document.pageRectFromDoc(source.frame.offsetBy(dx: origin.x, dy: origin.y))
            e.pageIndex = page
            e.frame = local
            elements.append(e)
        }
        guard !strokes.isEmpty || !elements.isEmpty else { return }
        document.growBoardIfNeeded(toFit: [CGRect(origin: origin, size: clip.size)])
        if tool.kind != .lasso { host?.canvasRequestTool(.lasso) }
        addLassoContent(strokes: strokes, elements: elements, actionName: "Paste")
    }

    /// The asset id to use here for a clip's image: the same file if this note has it, else a stored copy.
    private func importClipAsset(_ id: String, from clip: CanvasClip) -> String? {
        if FileManager.default.fileExists(atPath: document.assetURL(id).path) { return id }
        guard let data = clip.assets[id] else { return nil }
        let ext = URL(fileURLWithPath: id).pathExtension
        return document.storeAsset(data, ext: ext.isEmpty ? "jpg" : ext)
    }

    private func pasteImage(_ image: UIImage, at docPoint: CGPoint?) {
        let before = document.content.elements.count
        insertImage(image)
        guard document.content.elements.count > before, let id = document.content.elements.last?.id else { return }
        if let docPoint, let e = document.element(id) {
            let size = e.frame.size
            let (page, local) = document.pageRectFromDoc(CGRect(x: docPoint.x - size.width / 2, y: docPoint.y - size.height / 2,
                                                                width: size.width, height: size.height))
            document.update(id, actionName: "Paste") {
                $0.pageIndex = page
                $0.frame = CGRect(x: max(0, local.minX), y: max(0, local.minY), width: local.width, height: local.height)
            }
        }
        if tool.kind != .lasso { host?.canvasRequestTool(.lasso) }
        setLassoSelection(strokes: [], elements: [id])
    }

    private func pasteText(_ text: String, centredAt centre: CGPoint) {
        let content = TextContent(text: text, style: .typed, fontSize: 20, colorHex: tool.penColorHex, rich: false)
        let env = environment()
        let width = ElementRenderer.fittedTextWidth(content, author: .student, maxWidth: min(420, document.pageSize.width - 64), env: env)
        let size = ElementRenderer.measureText(content, author: .student, width: width, env: env)
        let (page, local) = document.pageRectFromDoc(CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2,
                                                            width: size.width, height: size.height))
        let e = CanvasElement(id: document.nextElementID(), pageIndex: page,
                              frame: CGRect(x: max(0, local.minX), y: max(0, local.minY), width: size.width, height: size.height),
                              author: .student, kind: .text(content))
        document.add(e, actionName: "Paste")
        if tool.kind != .lasso { host?.canvasRequestTool(.lasso) }
        setLassoSelection(strokes: [], elements: [e.id])
    }
}

extension NoteCanvasViewController: UIEditMenuInteractionDelegate {
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        let paste = UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
            self?.pasteFromClipboard(at: self?.lasso.pasteAt)
        }
        return UIMenu(title: "", children: [paste])
    }
}
