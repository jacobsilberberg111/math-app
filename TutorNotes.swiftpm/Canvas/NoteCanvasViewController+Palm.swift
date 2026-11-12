import UIKit
import PencilKit

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
/// A finger touch is treated as part of the writing hand when its contact is palm-sized, or when it
/// lands close to the pencil (touching, hovering, or just lifted) or to a palm already resting
/// (PalmClassifier). Those touches are taken out of scrolling and zooming the moment they land (the
/// scroll view's pan and pinch let go of everything they track and pick up only new touches), so the
/// resting hand never moves the page, while a finger of the other hand still scrolls and zooms. Only
/// the pencil being on the glass stops scrolling altogether (a scroll would bend the stroke). A page
/// nudge from a palm that landed just before the pencil is put back.
///
/// Taps, long-presses and region drags stay cautious: no finger triggers them while the writing hand
/// is active.
///
/// With finger drawing on, a finger is a pen: a fingertip pressed flat can be as big as a small
/// palm, so contact size is ignored and only Apple Pencil activity marks fingers as the hand. The
/// drawing policy is never switched mid-touch (doing so dropped finger strokes).
extension NoteCanvasViewController {
    static var palmContactRadius: CGFloat { PalmClassifier.palmContactRadius }
    /// How long after the pencil or the hand lifts that new finger touches near it still count as the hand.
    static let palmGracePeriod: TimeInterval = 0.35

    func setupPalmRejection() {
        touchWatcher = TouchWatcherGesture(target: nil, action: nil)
        touchWatcher.delegate = self
        touchWatcher.onBegan = { [weak self] t in self?.watchedTouchBegan(t) }
        touchWatcher.onMoved = { [weak self] t in self?.watchedTouchMoved(t) }
        touchWatcher.onEnded = { [weak self] t in self?.watchedTouchEnded(t) }
        canvasView.addGestureRecognizer(touchWatcher)
    }

    /// The writing hand is busy: finger taps and long-presses are ignored.
    var isWritingHandActive: Bool {
        !pencilTouches.isEmpty || pencilHovering || !palmTouches.isEmpty || Date() < palmGuardUntil
    }

    /// Scrolling and zooming are off only while the pencil is on the glass.
    private var blocksScrolling: Bool { !pencilTouches.isEmpty }

    func isPalmSized(_ t: UITouch) -> Bool {
        t.type == .direct && PalmClassifier.isPalmSized(majorRadius: t.majorRadius, fingerDrawing: tool.fingerDrawing)
    }

    /// Whether a finger touch should be ignored by taps, long-presses and region drags.
    func isPalmTouch(_ t: UITouch) -> Bool {
        guard t.type == .direct else { return false }
        return palmTouches.contains(t) || isWritingHandActive || isPalmSized(t)
    }

    /// Where the writing hand is, for classifying a new finger touch.
    private var handContext: PalmClassifier.Context {
        var c = PalmClassifier.Context()
        c.pencilPoints = pencilTouches.map { $0.location(in: view) }
        c.palmPoints = palmTouches.map { $0.location(in: view) }
        c.inGrace = Date() < palmGuardUntil
        if pencilHovering || c.inGrace { c.hoverPoint = lastPencilViewPoint }
        c.fingerDrawing = tool.fingerDrawing
        return c
    }

    private func watchedTouchBegan(_ t: UITouch) {
        switch t.type {
        case .pencil:
            pencilTouches.insert(t)
            let p = t.location(in: view)
            lastPencilViewPoint = p
            // Fingers already on the glass near the pencil are the hand holding it; ones further
            // away are the other hand, which may be scrolling.
            let hand = fingerTouches.filter { isPalmSized($0) || $0.location(in: view).distance(to: p) <= PalmClassifier.handReach }
            if !hand.isEmpty {
                palmTouches.formUnion(hand)
                fingerTouches.subtract(hand)
                if fingerTouches.isEmpty { restorePalmNudgedScroll() }
            }
        case .direct:
            if PalmClassifier.isWritingHand(point: t.location(in: view), majorRadius: t.majorRadius, context: handContext) {
                palmTouches.insert(t)
                dropTouchesFromScrolling()
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
        if pencilTouches.contains(t) { lastPencilViewPoint = t.location(in: view) }
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
        if fingerTouches.isEmpty { restorePalmNudgedScroll() }
        dropTouchesFromScrolling()
        updatePalmGuard()
    }

    private func watchedTouchEnded(_ t: UITouch) {
        let wasPencil = pencilTouches.remove(t) != nil
        let wasPalm = palmTouches.remove(t) != nil
        // With finger drawing on, the next finger stroke right after this one must still draw.
        if wasPencil || (wasPalm && !tool.fingerDrawing) {
            palmGuardUntil = Date().addingTimeInterval(Self.palmGracePeriod)
        }
        fingerTouches.remove(t)
        if fingerTouches.isEmpty { scrollBeforeFingers = nil }
        updatePalmGuard()
    }

    /// Called from the hover recognizer as the pencil approaches and leaves the glass.
    func setPencilHovering(_ hovering: Bool, at point: CGPoint? = nil) {
        if let point { lastPencilViewPoint = point }
        guard hovering != pencilHovering else { return }
        pencilHovering = hovering
        if !hovering { palmGuardUntil = max(palmGuardUntil, Date().addingTimeInterval(Self.palmGracePeriod)) }
        updatePalmGuard()
    }

    func updatePalmGuard() {
        let block = blocksScrolling
        guard block != scrollingBlockedForPalm else { return }
        scrollingBlockedForPalm = block
        // Turning a recognizer off also cancels a scroll or pinch that was under way.
        canvasView.panGestureRecognizer.isEnabled = !block
        canvasView.pinchGestureRecognizer?.isEnabled = !block
    }

    /// Makes the scroll view's pan and pinch let go of every touch they're tracking, so a touch
    /// just taken as the writing hand is never part of a scroll or zoom; they pick up new touches
    /// (another finger) again straight after.
    private func dropTouchesFromScrolling() {
        guard !scrollingBlockedForPalm else { return }
        let pan = canvasView.panGestureRecognizer, pinch = canvasView.pinchGestureRecognizer
        pan.isEnabled = false
        pinch?.isEnabled = false
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.scrollingBlockedForPalm else { return }
            pan.isEnabled = true
            pinch?.isEnabled = true
        }
    }

    /// Only set when it actually changes: reassigning it while a finger is drawing cancels the stroke.
    func applyDrawingPolicy() {
        let policy: PKCanvasViewDrawingPolicy = tool.fingerDrawing ? .anyInput : .pencilOnly
        if canvasView.drawingPolicy != policy { canvasView.drawingPolicy = policy }
    }

    /// If the page moved under a palm that landed just before the pencil, put it back.
    private func restorePalmNudgedScroll() {
        guard let before = scrollBeforeFingers else { return }
        scrollBeforeFingers = nil
        guard Date().timeIntervalSince(before.date) < 1.5, abs(zoom - before.zoom) < 0.001 else { return }
        if canvasView.contentOffset.distance(to: before.offset) > 0.5 {
            scrollReason = "palm nudge undone"
            canvasView.setContentOffset(before.offset, animated: true)
        }
    }
}
