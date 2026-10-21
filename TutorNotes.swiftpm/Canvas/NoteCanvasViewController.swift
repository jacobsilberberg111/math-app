import UIKit
import PencilKit

/// Hosts the PencilKit canvas for a note: continuous vertical pages, zoom, typed/tutor elements
/// layered under and over the ink, and everything the tutor does on the page.
final class NoteCanvasViewController: UIViewController, PKCanvasViewDelegate, UIGestureRecognizerDelegate, DocumentCanvas {
    let document: NoteDocument
    weak var host: CanvasHost?

    let canvasView = PKCanvasView()
    /// Below the ink: page backgrounds and under-ink elements (graphs, images, question cards).
    let underlay = PassthroughView()
    let pagesContainer = PassthroughView()
    let underElements = PassthroughView()
    /// Above the ink: tutor writing and marks, then interactive chrome.
    let overlay = PassthroughView()
    let overElements = PassthroughView()
    let chrome = PassthroughView()

    var pageViews: [Int: PageBackgroundView] = [:]
    /// Freeform boards draw their background as tiles, keyed by row * 4096 + column.
    var boardTiles: [Int: PageBackgroundView] = [:]
    static let boardTileSize: CGFloat = 1024
    var elementViews: [String: ElementView] = [:]

    private(set) var tool = CanvasToolConfig()
    var previousToolKind: CanvasToolKind = .pen

    private var lastLayoutWidth: CGFloat = 0
    private var userHasZoomed = false
    var isApplyingDrawing = false
    private var lastReportedPage = -1
    private var hasLaidOut = false

    // Input state (see +Input)
    var selectedElementID: String?
    let selectionView = SelectionOverlayView()
    var editingTextView: CanvasTextView?
    var editingNewTextPage: Int?
    var editingNewTextOrigin: CGPoint?
    let hoverPreview = HoverPreviewView()
    let shapePreview = ShapePreviewLayer()
    let regionLayer = CAShapeLayer()
    let findHighlights = FindHighlightLayer()
    var regionStartDoc: CGPoint?
    var strokeObserver: StrokeObserverGesture!
    var holdTimer: Timer?
    var snap = SnapState()
    var lastHoverDocPoint: CGPoint?
    var lastPencilDownDate = Date.distantPast
    var moveStartFrame: CGRect?
    var tapGesture: UITapGestureRecognizer!
    var regionPan: UIPanGestureRecognizer!
    var longPress: UILongPressGestureRecognizer!
    /// The pending one-shot colour sample, if the eyedropper is armed (see +Eyedropper).
    var eyedropper: EyedropperSession?
    /// Finger-only gestures (undo/redo taps, double-tap for the Ask menu, long-press) a resting hand must never trigger.
    var fingerOnlyGestures: [UIGestureRecognizer] = []
    var lastTapWasFinger = false

    // Palm rejection (see +Palm)
    var touchWatcher: TouchWatcherGesture!
    var pencilTouches = Set<UITouch>()
    var fingerTouches = Set<UITouch>()
    var palmTouches = Set<UITouch>()
    var pencilHovering = false
    var palmGuardUntil = Date.distantPast
    var scrollingBlockedForPalm = false
    var scrollBeforeFingers: (offset: CGPoint, zoom: CGFloat, date: Date)?

    // Snapped-shape resizing (see +Shapes)
    let shapeBar = ShapeBarView()
    var editableShape: EditableShape?

    // Tutor state (see +Tutor)
    let presence = TutorPresenceView()
    var revealQueue: [RevealJob] = []
    var activeReveal: RevealJob?
    var revealStart: CFTimeInterval = 0
    var displayLink: CADisplayLink?
    var replayTime: Date?
    var replayRevealedCount = -1
    var replaySourceDrawing: PKDrawing?

    init(document: NoteDocument) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Per-note undo stack shared by PencilKit and our element edits.
    override var undoManager: UndoManager? { document.undoManager }

    var zoom: CGFloat { canvasView.zoomScale }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hex: "#1B1C20") : UIColor(hex: "#E7EAEF")
        }

        canvasView.frame = view.bounds
        canvasView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        // Ink colours must never be inverted by dark mode: the paper is always light.
        canvasView.overrideUserInterfaceStyle = .light
        // Load the ink before setting the delegate so opening a note doesn't report it as a change.
        canvasView.drawing = document.drawing
        canvasView.delegate = self
        canvasView.alwaysBounceVertical = true
        canvasView.contentInsetAdjustmentBehavior = .never
        canvasView.minimumZoomScale = 0.4
        canvasView.maximumZoomScale = 5
        canvasView.bouncesZoom = true
        canvasView.showsHorizontalScrollIndicator = false
        canvasView.keyboardDismissMode = .interactive
        view.addSubview(canvasView)

        canvasView.insertSubview(underlay, at: 0)
        underlay.addSubview(pagesContainer)
        underlay.addSubview(underElements)
        canvasView.addSubview(overlay)
        overlay.addSubview(overElements)
        overlay.addSubview(chrome)

        selectionView.isHidden = true
        chrome.addSubview(selectionView)
        chrome.addSubview(hoverPreview)
        chrome.addSubview(presence)
        presence.tint = UIColor(hex: AppSettings.shared.tutorInkHex)
        chrome.layer.addSublayer(shapePreview)
        regionLayer.fillColor = UIColor.systemIndigo.withAlphaComponent(0.06).cgColor
        regionLayer.strokeColor = UIColor.systemIndigo.cgColor
        regionLayer.lineDashPattern = [7, 5]
        chrome.layer.addSublayer(regionLayer)
        chrome.layer.insertSublayer(findHighlights, at: 0)

        setupGestures()
        setupPalmRejection()
        setupShapeBar()
        document.canvas = self
        reloadPages()
        reloadAllElements()
        apply(tool: tool)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = canvasView.bounds.width
        if abs(width - lastLayoutWidth) > 0.5 {
            let fit = fitZoom
            updateZoomLimits()
            let topDocY = visibleDocRect.minY
            if !userHasZoomed || !hasLaidOut {
                canvasView.setZoomScale(fit, animated: false)
            }
            layoutDocument()
            // setZoomScale zooms about the centre of the view, which can leave the offset outside the
            // new content range (e.g. the page shifted sideways on open); clamp it back.
            let inset = canvasView.contentInset
            let maxX = max(-inset.left, canvasView.contentSize.width - canvasView.bounds.width + inset.right)
            let maxY = max(0, canvasView.contentSize.height - canvasView.bounds.height)
            let x = hasLaidOut ? min(max(canvasView.contentOffset.x, -inset.left), maxX) : -inset.left
            let y = hasLaidOut ? min(max(0, topDocY * zoom), maxY) : 0
            canvasView.contentOffset = CGPoint(x: x, y: y)
            // Programmatic zooms don't end in scrollViewDidEndZooming, so re-render elements for the new scale.
            rasterizeForCurrentZoom()
            lastLayoutWidth = width
            hasLaidOut = true
        }
        layoutDocument()
        canvasView.sendSubviewToBack(underlay)
        canvasView.bringSubviewToFront(overlay)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        endTextEditing()
        displayLink?.invalidate()
        displayLink = nil
        holdTimer?.invalidate()
        cancelEyedropper()
    }

    // MARK: Layout & zoom

    /// The zoom a note opens at and returns to: pages fit the width; boards open at actual size.
    var fitZoom: CGFloat {
        if document.isFreeform { return 1 }
        let w = max(canvasView.bounds.width, 100)
        return min(1.7, w / document.documentSize.width)
    }

    func updateZoomLimits() {
        if document.isFreeform {
            // Out far enough to see the whole board, no further.
            let b = canvasView.bounds.size, s = document.pageSize
            let whole = min(b.width / max(s.width, 1), b.height / max(s.height, 1))
            canvasView.minimumZoomScale = max(0.1, min(0.9, whole))
            canvasView.maximumZoomScale = 5
        } else {
            let fit = fitZoom
            canvasView.minimumZoomScale = max(0.3, fit * 0.5)
            canvasView.maximumZoomScale = max(5, fit * 5)
        }
    }

    var displayScale: CGFloat { max(1, traitCollection.displayScale) }

    func layoutDocument() {
        let z = zoom
        let size = document.documentSize
        canvasView.contentSize = CGSize(width: size.width * z, height: size.height * z)
        for container in [underlay, overlay] {
            container.transform = .identity
            container.layer.anchorPoint = .zero
            container.bounds = CGRect(origin: .zero, size: size)
            container.layer.position = .zero
            container.transform = CGAffineTransform(scaleX: z, y: z)
        }
        for c in [pagesContainer, underElements, overElements, chrome] {
            c.frame = CGRect(origin: .zero, size: size)
        }
        let inset = max(0, (canvasView.bounds.width - size.width * z) / 2)
        if abs(canvasView.contentInset.left - inset) > 0.5 {
            canvasView.contentInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
        }
        presence.inverseScale = 1 / z
        if let id = selectedElementID, let e = document.element(id) {
            selectionView.frame = document.docRect(for: e).insetBy(dx: -4, dy: -4)
            selectionView.layoutChrome(zoom: z)
        }
        regionLayer.lineWidth = 2 / z
        layoutFindHighlights()
        layoutShapeBar()
        if document.isFreeform { updateZoomLimits() }
        updateVisiblePages()
    }

    /// The part of the document currently on screen, in document coordinates.
    var visibleDocRect: CGRect {
        let z = max(zoom, 0.01)
        let b = canvasView.bounds
        return CGRect(x: b.minX / z, y: b.minY / z, width: b.width / z, height: b.height / z)
    }

    var currentPageIndex: Int {
        let r = visibleDocRect
        return document.pageIndex(at: CGPoint(x: r.midX, y: r.minY + r.height * 0.4))
    }

    var visiblePageIndices: [Int] {
        let r = visibleDocRect
        return document.content.pages.indices.filter { document.pageRect($0).intersects(r) }
    }

    // These also arrive for the in-place CanvasTextView (a UIScrollView whose delegate is self).
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        guard scrollView === canvasView else { return }
        userHasZoomed = abs(zoom - fitZoom) > 0.01
        layoutDocument()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        guard scrollView === canvasView else { return }
        rasterizeForCurrentZoom()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === canvasView else { return }
        updateVisiblePages()
        let page = currentPageIndex
        if page != lastReportedPage {
            lastReportedPage = page
            host?.canvasVisiblePageChanged(page)
        }
    }

    /// Re-renders element views at the current zoom so text and graphs stay sharp.
    func rasterizeForCurrentZoom() {
        let target = displayScale * zoom
        for v in elementViews.values {
            let area = max(1, v.bounds.width * v.bounds.height)
            let maxScale = sqrt(14_000_000 / area)
            let s = min(target, maxScale, displayScale * 4)
            if abs(v.contentScaleFactor - s) > 0.05 {
                v.contentScaleFactor = s
                v.setNeedsDisplay()
            }
        }
        if let tv = editingTextView {
            tv.contentScaleFactor = min(target, displayScale * 4)
        }
    }

    func zoomToFit(animated: Bool = true) {
        canvasView.setZoomScale(fitZoom, animated: animated)
        userHasZoomed = false
    }

    /// Freeform boards: zooms out to show everything on the board (or the whole board if empty).
    func zoomToShowAll() {
        let board = CGRect(origin: .zero, size: document.pageSize)
        let target = (document.boardContentBounds?.insetBy(dx: -60, dy: -60) ?? board).intersection(board)
        guard !target.isNull, target.width > 0, target.height > 0 else { return }
        let b = canvasView.bounds.size
        let z = min(max(canvasView.minimumZoomScale, min(b.width / target.width, b.height / target.height)), 1.5)
        canvasView.setZoomScale(z, animated: false)
        layoutDocument()
        let inset = canvasView.contentInset
        let maxX = max(-inset.left, canvasView.contentSize.width - b.width + inset.right)
        let maxY = max(0, canvasView.contentSize.height - b.height)
        let x = min(max(-inset.left, target.midX * z - b.width / 2), maxX)
        let y = min(max(0, target.midY * z - b.height / 2), maxY)
        canvasView.contentOffset = CGPoint(x: x, y: y)
        rasterizeForCurrentZoom()
        userHasZoomed = true
    }

    // MARK: Pages

    func reloadPages() {
        pageViews.values.forEach { $0.removeFromSuperview() }
        pageViews.removeAll()
        boardTiles.values.forEach { $0.removeFromSuperview() }
        boardTiles.removeAll()
        layoutDocument()
    }

    func updateVisiblePages() {
        if document.isFreeform {
            document.visibleBoardRect = visibleDocRect
            updateBoardTiles()
            return
        }
        let r = visibleDocRect.insetBy(dx: 0, dy: -document.pageSize.height * 1.2)
        let count = document.content.pages.count
        for i in 0..<count {
            let rect = document.pageRect(i)
            if rect.intersects(r) {
                let v = pageViews[i] ?? {
                    let nv = PageBackgroundView(frame: rect)
                    pagesContainer.addSubview(nv)
                    pageViews[i] = nv
                    return nv
                }()
                v.frame = rect
                let page = document.content.pages[i]
                v.configure(page: page, number: i + 1, size: rect.size, pdf: page.pdfAssetID.flatMap { document.pdf($0) })
            } else if let v = pageViews[i] {
                v.removeFromSuperview()
                pageViews[i] = nil
            }
        }
        for (i, v) in pageViews where i >= count {
            v.removeFromSuperview()
            pageViews[i] = nil
        }
    }

    /// Builds the board tiles around what's on screen and drops the rest.
    func updateBoardTiles() {
        let board = CGRect(origin: .zero, size: document.pageSize)
        let t = NoteCanvasViewController.boardTileSize
        let margin = max(t / 2, 300 / max(zoom, 0.05))
        let want = visibleDocRect.insetBy(dx: -margin, dy: -margin).intersection(board)
        var paper = document.content.pages.first?.paper ?? .standard
        // Zoomed far out, fine patterns are a blur of thousands of shapes per tile: draw lighter ones.
        if zoom < 0.3 {
            switch paper.pattern {
            case .dots: paper.pattern = .blank
            case .smallGrid, .graph: paper.pattern = .grid
            default: break
            }
        }
        var keep = Set<Int>()
        if !want.isNull, want.width > 1, want.height > 1 {
            let c0 = Int(floor(want.minX / t)), c1 = Int(floor((want.maxX - 0.5) / t))
            let r0 = Int(floor(want.minY / t)), r1 = Int(floor((want.maxY - 0.5) / t))
            for r in r0...max(r0, r1) {
                for c in c0...max(c0, c1) {
                    let rect = CGRect(x: CGFloat(c) * t, y: CGFloat(r) * t, width: t, height: t).intersection(board)
                    guard !rect.isNull, rect.width > 0, rect.height > 0 else { continue }
                    let key = r * 4096 + c
                    keep.insert(key)
                    let v = boardTiles[key] ?? {
                        let nv = PageBackgroundView(frame: rect)
                        pagesContainer.addSubview(nv)
                        boardTiles[key] = nv
                        return nv
                    }()
                    v.frame = rect
                    v.configureTile(paper: paper, rect: rect)
                }
            }
        }
        for (key, v) in boardTiles where !keep.contains(key) {
            v.removeFromSuperview()
            boardTiles[key] = nil
        }
    }

    func scrollToPage(_ index: Int, animated: Bool = true) {
        guard document.content.pages.indices.contains(index) else { return }
        let y = max(0, (document.pageOrigin(index).y - document.topMargin / 2) * zoom)
        let maxY = max(0, canvasView.contentSize.height - canvasView.bounds.height)
        canvasView.setContentOffset(CGPoint(x: canvasView.contentOffset.x, y: min(y, maxY)), animated: animated)
    }

    /// Scrolls so a document rect is comfortably visible (no-op if it already is).
    func scrollToReveal(_ docRect: CGRect, animated: Bool = true) {
        let visible = visibleDocRect.insetBy(dx: 0, dy: 40 / zoom)
        if visible.contains(docRect) { return }
        let z = zoom
        var target = canvasView.contentOffset
        if docRect.minY < visible.minY || docRect.maxY > visible.maxY {
            let maxY = max(0, canvasView.contentSize.height - canvasView.bounds.height)
            target.y = min(max(0, (docRect.midY * z) - canvasView.bounds.height * 0.4), maxY)
        }
        // Sideways too when it's off to one side (zoomed-in pages, wide boards).
        if docRect.minX < visibleDocRect.minX || docRect.maxX > visibleDocRect.maxX {
            let inset = canvasView.contentInset
            let maxX = max(-inset.left, canvasView.contentSize.width - canvasView.bounds.width + inset.right)
            let x = docRect.width * z < canvasView.bounds.width * 0.9 ? docRect.midX * z - canvasView.bounds.width / 2 : docRect.minX * z - 24
            target.x = min(max(-inset.left, x), maxX)
        }
        canvasView.setContentOffset(target, animated: animated)
    }

    func isVisible(_ docRect: CGRect) -> Bool {
        visibleDocRect.intersects(docRect)
    }

    // MARK: Elements

    func environment() -> RenderEnvironment { PageRenderer.environment(for: document) }

    func reloadAllElements() {
        elementViews.values.forEach { $0.removeFromSuperview() }
        elementViews.removeAll()
        for e in document.content.elements {
            _ = makeView(for: e)
        }
        rasterizeForCurrentZoom()
    }

    @discardableResult
    func makeView(for e: CanvasElement) -> ElementView {
        let v = ElementView(element: e) { [weak self] in
            self?.environment() ?? RenderEnvironment(hand: .handwriting, tutorHex: "#7048E8", image: { _ in nil })
        }
        v.frame = frameForView(e)
        (e.drawsAboveInk ? overElements : underElements).addSubview(v)
        elementViews[e.id] = v
        let target = displayScale * zoom
        let area = max(1, v.bounds.width * v.bounds.height)
        v.contentScaleFactor = min(target, sqrt(14_000_000 / area), displayScale * 4)
        return v
    }

    func frameForView(_ e: CanvasElement) -> CGRect {
        document.docRect(for: e).insetBy(dx: -ElementView.padding, dy: -ElementView.padding)
    }

    func refreshAllElementFrames() {
        for e in document.content.elements {
            guard let v = elementViews[e.id] else { continue }
            v.frame = frameForView(e)
        }
    }

    // MARK: DocumentCanvas

    func documentDidAddElement(_ element: CanvasElement, reveal: RevealStyle) {
        let v = elementViews[element.id] ?? makeView(for: element)
        v.element = element
        v.frame = frameForView(element)
        switch reveal {
        case .none:
            v.progress = 1
            v.isLive = false
        case .write(let duration):
            v.progress = 0
            v.isLive = false
            enqueueReveal(elementID: element.id, duration: duration)
        case .live:
            v.progress = 1
            v.isLive = true
            followLive(element)
        }
    }

    func documentDidUpdateElement(_ element: CanvasElement) {
        guard let v = elementViews[element.id] else {
            makeView(for: element)
            return
        }
        let container = element.drawsAboveInk ? overElements : underElements
        if v.superview !== container { container.addSubview(v) }
        let oldSize = v.bounds.size
        v.element = element
        v.frame = frameForView(element)
        if v.bounds.size != oldSize { rasterizeForCurrentZoom() }
        if v.isLive { followLive(element) }
        if selectedElementID == element.id {
            selectionView.frame = document.docRect(for: element).insetBy(dx: -4, dy: -4)
            selectionView.configure(for: element, zoom: zoom)
        }
    }

    func documentDidRemoveElement(id: String) {
        elementViews[id]?.removeFromSuperview()
        elementViews[id] = nil
        revealQueue.removeAll { $0.elementID == id }
        if selectedElementID == id { select(nil) }
    }

    func documentDidChangePages() {
        reloadPages()
        refreshAllElementFrames()
        layoutDocument()
    }

    func documentDidReplaceDrawing() {
        if replayTime != nil {
            // Mid-replay: re-render the replay from the new ink (the canvas shows a faded copy).
            replaySourceDrawing = document.drawing
            replayRevealedCount = -1
            setReplay(time: replayTime)
        } else {
            isApplyingDrawing = true
            canvasView.drawing = document.drawing
            isApplyingDrawing = false
        }
        revalidateEditableShape()
        host?.canvasUndoStateChanged()
    }

    /// Marks an element as finished streaming.
    func finishLive(_ elementID: String) {
        elementViews[elementID]?.isLive = false
        elementViews[elementID]?.setNeedsDisplay()
    }

    // MARK: Tools

    func apply(tool newTool: CanvasToolConfig) {
        if newTool.kind != tool.kind {
            if tool.kind != .tutor && tool.kind != .select { previousToolKind = tool.kind }
            if newTool.kind != .text { endTextEditing() }
            if newTool.kind != .select { select(nil) }
            if newTool.kind != .tutor { clearRegion() }
        }
        tool = newTool
        canvasView.tool = newTool.pkTool()
        applyDrawingPolicy()
        canvasView.isRulerActive = newTool.rulerActive
        canvasView.drawingGestureRecognizer.isEnabled = newTool.kind.usesPencilKit && replayTime == nil
        // In region-select mode one finger draws the region; scroll with two.
        canvasView.panGestureRecognizer.minimumNumberOfTouches = newTool.kind == .tutor ? 2 : 1
        regionPan?.isEnabled = newTool.kind == .tutor
        strokeObserver?.acceptsFinger = newTool.fingerDrawing
        strokeObserver?.isEnabled = newTool.shapeRecognition && (newTool.kind == .pen || newTool.kind == .highlighter) && replayTime == nil
        if !newTool.kind.usesPencilKit { hoverPreview.hide() }
        eyedropperToolApplied()
        if newTool.kind != .pen && newTool.kind != .highlighter { endShapeEditing() }
    }

    // MARK: PencilKit

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !isApplyingDrawing, replayTime == nil else { return }
        let newDrawing = canvasView.drawing
        let oldCount = document.drawing.strokes.count
        document.canvasDrawingChanged(newDrawing)
        if newDrawing.strokes.count < oldCount { revalidateEditableShape() }
        // The pixel eraser splits strokes, which also grows the count; that isn't new writing.
        if newDrawing.strokes.count > oldCount, tool.kind != .eraser {
            let added = newDrawing.strokes[oldCount...].map(\.renderBounds)
            endShapeEditing()
            applyPendingSnapIfReady()
            host?.canvasStudentWrote(docRects: added)
            autoAddPageIfNeeded(added)
        }
        host?.canvasUndoStateChanged()
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        lastPencilDownDate = Date()
        hoverPreview.hide()
        host?.canvasPencilStateChanged(isDrawing: true)
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        lastPencilDownDate = Date()
        host?.canvasPencilStateChanged(isDrawing: false)
    }

    private func autoAddPageIfNeeded(_ rects: [CGRect]) {
        if document.isFreeform {
            // Boards always make room as you write toward the edge.
            document.growBoardIfNeeded(toFit: rects)
            return
        }
        guard AppSettings.shared.autoAddPages else { return }
        let last = document.content.pages.count - 1
        let lastRect = document.pageRect(last)
        if rects.contains(where: { $0.maxY > lastRect.maxY - 110 && $0.minY < lastRect.maxY + document.pageGap }) {
            document.appendPage()
        }
    }

    /// True while the student has been writing in the last few seconds.
    var studentIsActive: Bool {
        Date().timeIntervalSince(lastPencilDownDate) < 3
    }

    // MARK: Commands

    func undo() {
        endTextEditing()
        if document.undoManager.canUndo { document.undoManager.undo() }
        host?.canvasUndoStateChanged()
    }

    func redo() {
        if document.undoManager.canRedo { document.undoManager.redo() }
        host?.canvasUndoStateChanged()
    }

    /// Places an image in the middle of the visible part of the current page.
    func insertImage(_ image: UIImage) {
        guard let asset = document.storeImage(image) else { return }
        let page = currentPageIndex
        let pageRect = document.pageRect(page)
        let visible = visibleDocRect.intersection(pageRect)
        let maxW = min(document.pageSize.width * 0.6, 480)
        let aspect = image.size.height / max(image.size.width, 1)
        let w = maxW, h = maxW * aspect
        let centerDoc = visible.isNull ? pageRect.center : visible.center
        let origin = CGPoint(x: centerDoc.x - w / 2 - pageRect.minX, y: max(20, centerDoc.y - h / 2 - pageRect.minY))
        let e = CanvasElement(id: document.nextElementID(), pageIndex: page, frame: CGRect(origin: origin, size: CGSize(width: w, height: h)),
                              author: .student, kind: .image(ImageContent(assetID: asset)))
        document.add(e, actionName: "Insert Image")
        select(e.id)
    }
}
