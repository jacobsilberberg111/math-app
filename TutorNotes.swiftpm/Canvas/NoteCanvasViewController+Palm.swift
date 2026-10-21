import UIKit

/// Sees every touch on the canvas without ever recognising or cancelling anything, so the controller
/// can tell the hand resting on the page apart from a finger that means to scroll or tap.
final class TouchWatcherGesture: UIGestureRecognizer {
    var onBegan: ((UITouch) -> Void)?
    var onMoved: ((UITouch) -> Void)?
    var onEnded: ((UITouch) -> Void)?
    private var live = Set<UITouch>()

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for t in touches {
            live.insert(t)
            onBegan?(t)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        for t in touches { onMoved?(t) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches) }

    private func finish(_ touches: Set<UITouch>) {
        for t in touches where live.remove(t) != nil { onEnded?(t) }
        if live.isEmpty { state = .failed }
    }

    override func reset() {
        super.reset()
        // Never leave a touch counted as still down.
        let leftover = live
        live.removeAll()
        for t in leftover { onEnded?(t) }
    }
}

/// Palm rejection. iPadOS keeps a resting hand from drawing (the canvas draws with the pencil only),
/// but the hand still reaches the scroll view and our finger gestures: it nudged the page, pinched
/// the zoom, and a palm lifting off could register as a two-finger undo tap.
///
/// A finger touch is treated as part of the writing hand when it lands while the pencil is on or
/// hovering over the glass (or just after it lifts), when it's already down as the pencil lands, or
/// when its contact is palm-sized. While any such touch is down, scrolling, zooming and finger
/// gestures are off; a page nudge from a palm that landed just before the pencil is put back.
extension NoteCanvasViewController {
    /// Fingertips report a major radius of roughly 8–20 pt; a palm or the side of a hand is larger.
    static let palmContactRadius: CGFloat = 28
    /// How long after the pencil or the hand lifts that new finger touches still count as the hand.
    static let palmGracePeriod: TimeInterval = 0.35

    func setupPalmRejection() {
        touchWatcher = TouchWatcherGesture(target: nil, action: nil)
        touchWatcher.delegate = self
        touchWatcher.onBegan = { [weak self] t in self?.watchedTouchBegan(t) }
        touchWatcher.onMoved = { [weak self] t in self?.watchedTouchMoved(t) }
        touchWatcher.onEnded = { [weak self] t in self?.watchedTouchEnded(t) }
        canvasView.addGestureRecognizer(touchWatcher)
    }

    /// New finger touches belong to the writing hand right now.
    var isWritingHandActive: Bool {
        !pencilTouches.isEmpty || pencilHovering || !palmTouches.isEmpty || Date() < palmGuardUntil
    }

    /// Scrolling and zooming are off: the pencil is down or the hand is resting on the page.
    /// (Hovering alone doesn't stop a scroll that's already under way.)
    private var blocksScrolling: Bool {
        !pencilTouches.isEmpty || !palmTouches.isEmpty || Date() < palmGuardUntil
    }

    func isPalmSized(_ t: UITouch) -> Bool {
        t.type == .direct && t.majorRadius >= Self.palmContactRadius
    }

    /// Whether a finger touch should be ignored by taps, long-presses and region drags.
    func isPalmTouch(_ t: UITouch) -> Bool {
        guard t.type == .direct else { return false }
        return palmTouches.contains(t) || isWritingHandActive || isPalmSized(t)
    }

    private func watchedTouchBegan(_ t: UITouch) {
        switch t.type {
        case .pencil:
            pencilTouches.insert(t)
            // Fingers already on the glass as the pencil lands are the hand holding it.
            if !fingerTouches.isEmpty {
                palmTouches.formUnion(fingerTouches)
                fingerTouches.removeAll()
                restorePalmNudgedScroll()
            }
        case .direct:
            if isWritingHandActive || isPalmSized(t) {
                palmTouches.insert(t)
            } else {
                if fingerTouches.isEmpty {
                    scrollBeforeFingers = (canvasView.contentOffset, zoom, Date())
                }
                fingerTouches.insert(t)
            }
        default:
            break
        }
        updatePalmGuard()
        if isErasingTouch(t) { eraseTutorMarks(at: t.location(in: chrome)) }
    }

    /// The eraser follows the pencil, or a finger when finger drawing is on.
    private func isErasingTouch(_ t: UITouch) -> Bool {
        guard tool.kind == .eraser else { return false }
        return pencilTouches.contains(t) || (tool.fingerDrawing && fingerTouches.contains(t))
    }

    private func watchedTouchMoved(_ t: UITouch) {
        if isErasingTouch(t) {
            // Fill the gap since the last sample so a quick swipe doesn't skip over thin marks.
            let a = t.precisePreviousLocation(in: chrome), b = t.preciseLocation(in: chrome)
            let steps = max(1, Int(a.distance(to: b) / 4))
            for i in 1...steps {
                let f = CGFloat(i) / CGFloat(steps)
                eraseTutorMarks(at: CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
            }
        }
        // A palm often lands as a small contact and spreads as the hand settles.
        guard fingerTouches.contains(t), isPalmSized(t) else { return }
        fingerTouches.remove(t)
        palmTouches.insert(t)
        restorePalmNudgedScroll()
        updatePalmGuard()
    }

    private func watchedTouchEnded(_ t: UITouch) {
        if pencilTouches.remove(t) != nil || palmTouches.remove(t) != nil {
            palmGuardUntil = Date().addingTimeInterval(Self.palmGracePeriod)
        }
        fingerTouches.remove(t)
        if fingerTouches.isEmpty { scrollBeforeFingers = nil }
        updatePalmGuard()
    }

    /// Called from the hover recognizer as the pencil approaches and leaves the glass.
    func setPencilHovering(_ hovering: Bool) {
        guard hovering != pencilHovering else { return }
        pencilHovering = hovering
        if !hovering { palmGuardUntil = max(palmGuardUntil, Date().addingTimeInterval(Self.palmGracePeriod)) }
        updatePalmGuard()
    }

    func updatePalmGuard() {
        let block = blocksScrolling
        if block != scrollingBlockedForPalm {
            scrollingBlockedForPalm = block
            // Turning a recognizer off also cancels a scroll or pinch the hand had started.
            canvasView.panGestureRecognizer.isEnabled = !block
            canvasView.pinchGestureRecognizer?.isEnabled = !block
            applyDrawingPolicy()
        }
        if block, pencilTouches.isEmpty, palmTouches.isEmpty {
            // Only the grace period is left: look again once it has run out.
            let wait = max(0.02, palmGuardUntil.timeIntervalSinceNow + 0.01)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.updatePalmGuard() }
        }
    }

    /// Finger drawing (when it's on) pauses while the writing hand is down, so a palm can't draw.
    func applyDrawingPolicy() {
        canvasView.drawingPolicy = tool.fingerDrawing && !scrollingBlockedForPalm ? .anyInput : .pencilOnly
    }

    /// If the page moved under a palm that landed just before the pencil, put it back.
    private func restorePalmNudgedScroll() {
        guard let before = scrollBeforeFingers else { return }
        scrollBeforeFingers = nil
        guard Date().timeIntervalSince(before.date) < 1.5, abs(zoom - before.zoom) < 0.001 else { return }
        if canvasView.contentOffset.distance(to: before.offset) > 0.5 {
            canvasView.setContentOffset(before.offset, animated: true)
        }
    }
}
