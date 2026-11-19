import UIKit

extension Notification.Name {
    /// The canvas scrolled or zoomed (throttled); the object is the note's `NoteDocument`. The
    /// editor shows its page indicator while these keep coming.
    static let canvasDidScroll = Notification.Name("MarginCanvasDidScroll")
}

/// Keeping a long note light: element views and page backgrounds exist only near the screen,
/// element bitmaps share a pixel budget, and the page being read stays put while pages change.
extension NoteCanvasViewController {
    /// All element bitmaps together, in pixels (about 240 MB): a long note full of graphs zoomed
    /// in mustn't run the iPad out of memory.
    static let elementPixelBudget: CGFloat = 60_000_000
    /// One element's bitmap at most.
    static let elementPixelCap: CGFloat = 14_000_000
    /// Paper lines and page numbers of a page on screen, per layer.
    static let pagePixelCap: CGFloat = 16_000_000

    // MARK: Element culling

    /// The part of the document whose elements get views: the screen and about a page each way
    /// (`grow` pages), or a screen's worth around it on a board.
    func elementWindow(grow: CGFloat) -> CGRect {
        let v = visibleDocRect
        if document.isFreeform {
            return v.insetBy(dx: -max(v.width, 600) * grow, dy: -max(v.height, 600) * grow)
        }
        return v.insetBy(dx: -document.documentSize.width, dy: -document.pageSize.height * grow)
    }

    /// Views that carry state of their own and must stay even far from the screen: the selected
    /// or edited item, a lasso selection, anything being revealed or streaming in, a code badge.
    func elementViewIsPinned(_ id: String, _ v: ElementView) -> Bool {
        id == selectedElementID || id == editingTextView?.elementID || v.isHidden || v.isLive
            || v.progress < 1 || v.alpha < 1 || !v.subviews.isEmpty || lasso.elementIDs.contains(id)
            || activeReveal?.elementID == id || revealQueue.contains { $0.elementID == id }
    }

    /// Builds views for elements coming into range and drops the ones well out of it. Cheap
    /// enough per scroll: it only does the work after the view has moved a quarter screen.
    func updateVisibleElements(force: Bool = false) {
        guard isViewLoaded else { return }
        let visible = visibleDocRect
        if !force, !elementCullRect.isNull {
            let moved = abs(visible.midY - elementCullRect.midY) > visible.height * 0.25
                || abs(visible.midX - elementCullRect.midX) > visible.width * 0.25
                || abs(visible.height - elementCullRect.height) > visible.height * 0.2
            guard moved else { return }
        }
        elementCullRect = visible
        let near = elementWindow(grow: 1)
        let keep = elementWindow(grow: 1.6)
        // In document order, so a rebuilt view goes back to its place in the stacking order.
        var lastUnder: ElementView?
        var lastOver: ElementView?
        var built = false
        for e in document.content.elements {
            let frame = frameForView(e)
            let container = e.drawsAboveInk ? overElements : underElements
            if let v = elementViews[e.id] {
                if !frame.intersects(keep) && !elementViewIsPinned(e.id, v) {
                    v.removeFromSuperview()
                    elementViews[e.id] = nil
                    continue
                }
                if v.superview === container {
                    if e.drawsAboveInk { lastOver = v } else { lastUnder = v }
                }
            } else if frame.intersects(near) || e.id == selectedElementID {
                let v = makeView(for: e, addTo: false)
                if let below = e.drawsAboveInk ? lastOver : lastUnder {
                    container.insertSubview(v, aboveSubview: below)
                } else {
                    container.insertSubview(v, at: 0)
                }
                if e.drawsAboveInk { lastOver = v } else { lastUnder = v }
                built = true
            }
        }
        // Ids of elements that are gone (the document no longer has them).
        if elementViews.count > document.content.elements.count {
            let ids = Set(document.content.elements.map(\.id))
            for (id, v) in elementViews where !ids.contains(id) {
                v.removeFromSuperview()
                elementViews[id] = nil
            }
        }
        // Mid-pinch every view would redraw for a zoom that's about to change again; the end of
        // the zoom re-renders everything once (see scrollViewDidEndZooming).
        guard !canvasView.isZooming else { return }
        if built || force { rasterizeElements() }
        updatePageRenderScales()
    }

    /// Culls once the current burst of changes is over (several items added or updated at once).
    func scheduleElementCull() {
        guard !elementCullScheduled else { return }
        elementCullScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.elementCullScheduled = false
            self.updateVisibleElements(force: true)
        }
    }

    // MARK: Element sharpness

    /// The scale an element view wants at this zoom, capped for one view.
    func wantedScale(for v: ElementView) -> CGFloat {
        let area = max(1, v.bounds.width * v.bounds.height)
        return min(displayScale * zoom, sqrt(NoteCanvasViewController.elementPixelCap / area), displayScale * 4)
    }

    /// Re-renders the element views for the current zoom: those on screen first within the
    /// budget, the ones just off it with what's left.
    func rasterizeElements() {
        let visible = visibleDocRect
        let views = Array(elementViews.values)
        let items = views.map { v in
            RasterBudget.Item(area: Double(max(1, v.bounds.width * v.bounds.height)), wanted: Double(wantedScale(for: v)),
                              onScreen: v.frame.intersects(visible) || v.element.id == selectedElementID)
        }
        let scales = RasterBudget.scales(items, budget: Double(NoteCanvasViewController.elementPixelBudget))
        for (v, s) in zip(views, scales) where RasterBudget.needsRedraw(current: Double(v.contentScaleFactor), target: s) {
            v.contentScaleFactor = CGFloat(s)
            v.setNeedsDisplay()
        }
    }

    // MARK: Page backgrounds

    /// Paper lines and the page number are vector layers drawn at a fixed scale: zoomed in they
    /// need more pixels to stay crisp (capped, as each layer's bitmap covers the page).
    func pageRenderScale(for size: CGSize) -> CGFloat {
        let area = max(1, size.width * size.height)
        return max(1, min(displayScale * zoom, sqrt(NoteCanvasViewController.pagePixelCap / area), 6))
    }

    /// Sharp paper on the pages on screen; the rest drop to 1x so their bitmaps stay small.
    func updatePageRenderScales() {
        let visible = visibleDocRect
        let all = Array(pageViews.values) + Array(boardTiles.values)
        for v in all {
            v.setRenderScale(v.frame.intersects(visible) ? pageRenderScale(for: v.bounds.size) : 1)
        }
    }

    func dequeuePageView(frame: CGRect) -> PageBackgroundView {
        if let v = pageViewPool.popLast() {
            v.frame = frame
            v.isHidden = false
            return v
        }
        let v = PageBackgroundView(frame: frame)
        pagesContainer.addSubview(v)
        return v
    }

    /// Keeps a few page views for the next pages to come into range (building one costs more
    /// than reconfiguring one).
    func recyclePageView(_ v: PageBackgroundView) {
        if pageViewPool.count < 3 {
            v.isHidden = true
            v.prepareForReuse()
            pageViewPool.append(v)
        } else {
            v.removeFromSuperview()
        }
    }

    // MARK: Keeping the page in view

    /// Remembers the page at the top of the screen (by id) and how far down it the view starts.
    func updatePageAnchor() {
        guard hasLaidOut, !isRestoringPageAnchor, !document.isFreeform, !document.content.pages.isEmpty else { return }
        let top = visibleDocRect.minY
        let i = document.pageIndex(at: CGPoint(x: 0, y: top))
        pageAnchor = (document.content.pages[i].id, top - document.pageOrigin(i).y)
    }

    /// Runs a change to the pages' layout, then scrolls so the page that was at the top of the
    /// screen is where it was (a page that's gone leaves the view where it is, kept in range).
    func keepingPageInView(_ change: () -> Void) {
        // Scrolls caused by the relayout itself mustn't replace the anchor.
        let outer = isRestoringPageAnchor
        isRestoringPageAnchor = true
        change()
        restorePageAnchor()
        keepOffsetInRange()
        isRestoringPageAnchor = outer
        if !outer { updatePageAnchor() }
    }

    private func restorePageAnchor() {
        guard hasLaidOut, !document.isFreeform, let anchor = pageAnchor,
              let i = document.content.pages.firstIndex(where: { $0.id == anchor.id }) else { return }
        let y = (document.pageOrigin(i).y + anchor.dy) * zoom
        let maxY = max(0, canvasView.contentSize.height - canvasView.bounds.height + canvasView.contentInset.bottom)
        let target = min(max(0, y), maxY)
        guard abs(target - canvasView.contentOffset.y) > 0.5 else { return }
        scrollReason = "pages changed, keeping page \(i + 1) in view"
        canvasView.contentOffset = CGPoint(x: canvasView.contentOffset.x, y: target)
    }

    /// Pulls the scroll position back inside the content after its size changed.
    func keepOffsetInRange() {
        let inset = canvasView.contentInset
        let maxX = max(-inset.left, canvasView.contentSize.width - canvasView.bounds.width + inset.right)
        let maxY = max(0, canvasView.contentSize.height - canvasView.bounds.height + canvasView.contentInset.bottom)
        let offset = canvasView.contentOffset
        let clamped = CGPoint(x: min(max(offset.x, -inset.left), maxX), y: min(max(offset.y, 0), maxY))
        if clamped != offset {
            scrollReason = "content got shorter"
            canvasView.contentOffset = clamped
        }
    }

    // MARK: Zoom

    /// A pinch that ends within a few percent of fit-width settles on it. Returns whether it snapped.
    func snapZoomToFitIfClose() -> Bool {
        guard !document.isFreeform, ZoomSnap.snapsToFit(zoom: Double(zoom), fit: Double(fitZoom)) else { return false }
        canvasView.setZoomScale(fitZoom, animated: true)
        userHasZoomed = false
        return true
    }

    // MARK: Scroll notices and saving the place

    /// Tells the editor the canvas moved (a few times a second at most), for the page indicator.
    func noteScrolled() {
        guard hasLaidOut, Date().timeIntervalSince(lastScrollNotice) > 0.25 else { return }
        lastScrollNotice = Date()
        NotificationCenter.default.post(name: .canvasDidScroll, object: document)
    }

    /// Saves the place when the app goes to the background (it may never come back to close the note).
    func observeAppState() {
        let center = NotificationCenter.default
        appObservers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rememberPosition() }
        })
    }
}
