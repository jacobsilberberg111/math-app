import UIKit
import PencilKit
import os

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
    /// Where Apple Pencil last touched or hovered, in this controller's view: locates the writing hand.
    var lastPencilViewPoint: CGPoint?
    /// When the student last scrolled or zoomed (the tutor doesn't move the page for a while after).
    var lastUserScrollDate = Date.distantPast

    // Scroll diagnostics: why the page last moved, for the jump logger (see scrollViewDidScroll).
    var scrollReason: String? { didSet { scrollReasonDate = Date() } }
    var scrollReasonDate = Date.distantPast
    var lastLoggedOffset: CGPoint = .zero
    static let scrollLog = Logger(subsystem: "com.jacobsilberberg.margin", category: "canvas-scroll")
    var pendingRasterize: DispatchWorkItem?

    // Lasso tool (see +Lasso)
    let lasso = LassoState()

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
        // Tapping the status bar (easy to do with the pencil, a fingertip or the side of the hand
        // near the top edge) would otherwise fly back to the top of the note.
        canvasView.scrollsToTop = false
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
            // Reopening a note goes back to where the student was (and how far they'd zoomed).
            let remembered = hasLaidOut ? nil : CanvasPositionMemory.load(document.meta.id)
            if let z = remembered?.zoom {
                canvasView.setZoomScale(min(max(z, canvasView.minimumZoomScale), canvasView.maximumZoomScale), animated: false)
                userHasZoomed = abs(zoom - fit) > 0.01
            } else if !userHasZoomed || !hasLaidOut {
                canvasView.setZoomScale(fit, animated: false)
            }
            layoutDocument()
            // setZoomScale zooms about the centre of the view, which can leave the offset outside the
            // new content range (e.g. the page shifted sideways on open); clamp it back.
            let inset = canvasView.contentInset
            let maxX = max(-inset.left, canvasView.contentSize.width - canvasView.bounds.width + inset.right)
            let maxY = max(0, canvasView.contentSize.height - canvasView.bounds.height)
            var x = hasLaidOut ? min(max(canvasView.contentOffset.x, -inset.left), maxX) : -inset.left
            var y = hasLaidOut ? min(max(0, topDocY * zoom), maxY) : 0
            if let r = remembered {
                y = min(max(0, r.docY * zoom), maxY)
                if r.zoom != nil { x = min(max(-inset.left, r.docX * zoom), maxX) }
            }
            scrollReason = hasLaidOut ? "width changed to \(Int(width))" : "first layout"
            canvasView.contentOffset = CGPoint(x: x, y: y)
            // Programmatic zooms don't end in scrollViewDidEndZooming, so re-render elements for the
            // new scale: at once the first time, otherwise once the width has settled (the tutor panel
            // slides in over many layout passes, and redrawing every item on each one stutters).
            if hasLaidOut { scheduleRasterize() } else { rasterizeForCurrentZoom() }
            lastLayoutWidth = width
            hasLaidOut = true
        }
        layoutDocument()
        canvasView.sendSubviewToBack(underlay)
        canvasView.bringSubviewToFront(overlay)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        rememberPosition()
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
        layoutLasso()
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
        rememberPosition()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === canvasView else { return }
        logScrollJumpIfNeeded()
        updateVisiblePages()
        layoutLasso()
        let page = currentPageIndex
        if page != lastReportedPage {
            lastReportedPage = page
            host?.canvasVisiblePageChanged(page)
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView === canvasView else { return }
        lastUserScrollDate = Date()
        scrollReason = "student scrolled"
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        guard scrollView === canvasView else { return }
        lastUserScrollDate = Date()
        scrollReason = "student zoomed"
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === canvasView else { return }
        rememberPosition()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView === canvasView, !decelerate else { return }
        rememberPosition()
    }

    /// Saves where the student is in the note, so it reopens there.
    func rememberPosition() {
        guard hasLaidOut else { return }
        let r = visibleDocRect
        CanvasPositionMemory.save(document.meta.id, docX: r.minX, docY: r.minY, zoom: userHasZoomed ? zoom : nil)
    }

    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        // Belt and braces with scrollsToTop = false: never fly to the top of the note (or of a text box).
        false
    }

    /// Logs any big jump of the page the student didn't make, with what caused it, so a jump seen on
    /// a device can be traced (Console app: subsystem com.jacobsilberberg.margin, category
    /// canvas-scroll).
    func logScrollJumpIfNeeded() {
        let o = canvasView.contentOffset
        let previous = lastLoggedOffset
        lastLoggedOffset = o
        let jump = abs(o.y - previous.y)
        guard hasLaidOut, jump > max(400, canvasView.bounds.height * 0.8),
              !canvasView.isTracking, !canvasView.isDecelerating, !canvasView.isZooming else { return }
        // A reason only explains a jump that follows soon after it was given.
        let reason = Date().timeIntervalSince(scrollReasonDate) < 1.5 ? (scrollReason ?? "unknown") : "unknown"
        let frames = reason == "unknown" ? Thread.callStackSymbols.prefix(14).joined(separator: " | ") : ""
        let from = Int(previous.y), to = Int(o.y), size = Int(jump)
        NoteCanvasViewController.scrollLog.notice("Page jumped \(size, privacy: .public) pt (y \(from, privacy: .public) to \(to, privacy: .public)), reason: \(reason, privacy: .public) \(frames, privacy: .public)")
        print("SCROLL_JUMP \(size) pt, reason: \(reason)")
    }

    /// Re-renders element views at the current zoom once layout has settled.
    func scheduleRasterize(after delay: TimeInterval = 0.2) {
        pendingRasterize?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rasterizeForCurrentZoom() }
        pendingRasterize = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
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
        scrollReason = "go to page \(index + 1)"
        let y = max(0, (document.pageOrigin(index).y - document.topMargin / 2) * zoom)
        let maxY = max(0, canvasView.contentSize.height - canvasView.bounds.height)
        canvasView.setContentOffset(CGPoint(x: canvasView.contentOffset.x, y: min(y, maxY)), animated: animated)
    }

    /// Scrolls so a document rect is comfortably visible (no-op if it already is).
    func scrollToReveal(_ docRect: CGRect, animated: Bool = true) {
        let visible = visibleDocRect.insetBy(dx: 0, dy: 40 / zoom)
        if visible.contains(docRect) { return }
        scrollReason = "reveal \(docRect.roundedForDisplay)"
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
            v.isLive = false
            if ElementRenderer.revealsByFading(element) {
                v.progress = 1
                v.alpha = 0
            } else {
                v.progress = 0
            }
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
        lassoUpdatedElement(element.id)
    }

    func documentDidRemoveElement(id: String) {
        elementViews[id]?.removeFromSuperview()
        elementViews[id] = nil
        revealQueue.removeAll { $0.elementID == id }
        if selectedElementID == id { select(nil) }
        lassoDroppedElement(id)
    }

    func documentDidChangePages() {
        reloadPages()
        refreshAllElementFrames()
        layoutDocument()
    }

    func documentDidReplaceDrawing() {
        // Selected strokes are tracked by index, so any outside change to the ink ends the selection.
        if !lasso.isCommitting { clearLassoSelection() }
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
            if newTool.kind != .lasso { clearLassoSelection() }
        }
        tool = newTool
        canvasView.tool = newTool.pkTool()
        applyDrawingPolicy()
        canvasView.isRulerActive = newTool.rulerActive
        canvasView.drawingGestureRecognizer.isEnabled = newTool.kind.usesPencilKit && replayTime == nil
        // In region-select mode one finger draws the region; scroll with two. Same for a lasso drawn with fingers.
        canvasView.panGestureRecognizer.minimumNumberOfTouches = newTool.kind == .tutor || (newTool.kind == .lasso && newTool.fingerDrawing) ? 2 : 1
        configureLasso(for: newTool)
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
        // PencilKit's own undo and redo change the ink directly; a lasso selection holds stroke
        // indices, so it can't outlive that.
        if !lasso.isEmpty && !lasso.isCommitting { clearLassoSelection() }
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

    /// True while the student is busy on the page: writing in the last few seconds, or scrolling
    /// and zooming (or just did). The tutor then doesn't move the page; it shows a "see what I
    /// wrote" pill instead.
    var studentIsActive: Bool {
        Date().timeIntervalSince(lastPencilDownDate) < 3 || Date().timeIntervalSince(lastUserScrollDate) < 8
            || canvasView.isTracking || canvasView.isDecelerating || canvasView.isZooming
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

/// Where each note was last viewed (document coordinates of the top-left of the view, and the zoom
/// if the student had zoomed), kept in UserDefaults.
enum CanvasPositionMemory {
    struct Position {
        var docX: CGFloat
        var docY: CGFloat
        var zoom: CGFloat?
    }

    private static func key(_ id: UUID) -> String { "canvasPosition.\(id.uuidString)" }

    static func save(_ id: UUID, docX: CGFloat, docY: CGFloat, zoom: CGFloat?) {
        UserDefaults.standard.set([Double(docX), Double(docY), Double(zoom ?? 0)], forKey: key(id))
    }

    static func load(_ id: UUID) -> Position? {
        guard let a = UserDefaults.standard.array(forKey: key(id)) as? [Double], a.count == 3,
              a.allSatisfy({ $0.isFinite }) else { return nil }
        return Position(docX: CGFloat(a[0]), docY: CGFloat(max(0, a[1])), zoom: a[2] > 0 ? CGFloat(a[2]) : nil)
    }
}

