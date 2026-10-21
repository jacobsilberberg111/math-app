import UIKit
import PencilKit

struct RevealJob {
    var elementID: String
    var duration: TimeInterval
}

enum TutorActivity {
    case hidden
    case idle
    case looking(CGRect)      // document rect it is reading
    case thinking(CGPoint?)   // document point to hover near
}

/// Everything the tutor does visually on the page: writing reveals, its presence cursor,
/// "look here" pulses, and audio replay of the student's ink.
extension NoteCanvasViewController {

    // MARK: Reveal queue

    func enqueueReveal(elementID: String, duration: TimeInterval) {
        revealQueue.append(RevealJob(elementID: elementID, duration: duration))
        if activeReveal == nil { startNextReveal() }
    }

    func startNextReveal() {
        guard activeReveal == nil else { return }
        while let job = revealQueue.first {
            revealQueue.removeFirst()
            guard let v = elementViews[job.elementID], let e = document.element(job.elementID) else { continue }
            activeReveal = job
            let docFrame = document.docRect(for: e)
            if !isVisible(docFrame) {
                if studentIsActive {
                    host?.canvasOffscreenTutorEdit(page: e.pageIndex, docRect: docFrame)
                } else {
                    scrollToReveal(docFrame)
                }
            }
            v.progress = 0
            let path = ElementRenderer.presencePath(e, env: environment()).map {
                CGPoint(x: $0.x + docFrame.minX, y: $0.y + docFrame.minY)
            }
            // Move before setMode: setMode fades alpha in (the model value changes at once), and glide
            // only jumps straight to the target while the presence is still hidden.
            if let first = path.first {
                presence.glide(to: first, duration: 0.25)
                presence.follow(path, duration: job.duration)
            }
            presence.setMode(.writing)
            revealStart = CACurrentMediaTime()
            if displayLink == nil {
                let link = CADisplayLink(target: self, selector: #selector(revealTick(_:)))
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
            return
        }
        displayLink?.invalidate()
        displayLink = nil
        if case .writing = presence.mode { presence.setMode(.idle) }
    }

    @objc func revealTick(_ link: CADisplayLink) {
        guard let job = activeReveal else {
            link.invalidate()
            displayLink = nil
            return
        }
        let t = (CACurrentMediaTime() - revealStart) / max(job.duration, 0.05)
        let eased = t >= 1 ? 1 : 1 - pow(1 - t, 1.6)
        elementViews[job.elementID]?.progress = CGFloat(eased)
        if t >= 1 {
            activeReveal = nil
            startNextReveal()
        }
    }

    /// Finishes all pending reveals instantly (e.g. when the student starts writing).
    func flushReveals() {
        if let job = activeReveal { elementViews[job.elementID]?.progress = 1 }
        for job in revealQueue { elementViews[job.elementID]?.progress = 1 }
        revealQueue.removeAll()
        activeReveal = nil
        displayLink?.invalidate()
        displayLink = nil
        // Nothing else returns the presence from writing once the queue is gone.
        if case .writing = presence.mode { presence.setMode(.idle) }
    }

    var isRevealing: Bool { activeReveal != nil || !revealQueue.isEmpty }

    /// Keeps the presence at the end of text that is streaming in.
    func followLive(_ e: CanvasElement) {
        let docFrame = document.docRect(for: e)
        var caret = CGPoint(x: docFrame.maxX, y: docFrame.maxY)
        if case .text(let t) = e.kind {
            let env = environment()
            let f = ElementRenderer.font(for: t, author: e.author, env: env)
            let inset = ElementRenderer.textInsets(t.style)
            let l = ElementRenderer.richLayout(t.text, font: f, width: docFrame.width - inset.left - inset.right, rich: t.rich, live: true)
            let p = l.caretPosition(afterChars: l.totalChars)
            caret = CGPoint(x: docFrame.minX + inset.left + p.x, y: docFrame.minY + inset.top + p.y)
        }
        presence.glide(to: caret, duration: 0.18)
        presence.setMode(.writing)
        if !isVisible(docFrame) && !studentIsActive {
            scrollToReveal(docFrame)
        }
    }

    // MARK: Presence

    func setTutorActivity(_ activity: TutorActivity) {
        presence.tint = UIColor(hex: AppSettings.shared.tutorInkHex)
        switch activity {
        case .hidden:
            if !isRevealing { presence.setMode(.hidden) }
        case .idle:
            if !isRevealing { presence.setMode(.idle) }
        case .looking(let rect):
            guard !isRevealing else { return }
            presence.glide(to: CGPoint(x: rect.maxX, y: rect.minY), duration: 0.6)
            presence.setMode(.looking)
        case .thinking(let point):
            guard !isRevealing else { return }
            if let point {
                presence.glide(to: point, duration: 0.5)
            } else if presence.alpha < 0.05 {
                let r = visibleDocRect
                presence.glide(to: CGPoint(x: r.maxX - 60 / zoom, y: r.minY + 60 / zoom), duration: 0)
            }
            presence.setMode(.thinking)
        }
    }

    // MARK: Focus

    /// Scrolls to and pulses a region, optionally with a short speech-bubble message.
    func focus(docRect: CGRect, message: String?) {
        scrollToReveal(docRect)
        let color = UIColor(hex: AppSettings.shared.tutorInkHex)
        let pulse = PulseView(frame: docRect.insetBy(dx: -8, dy: -8), color: color, zoom: zoom)
        chrome.insertSubview(pulse, belowSubview: presence)
        pulse.run()
        presence.glide(to: CGPoint(x: docRect.maxX, y: docRect.minY))
        presence.setMode(.idle)
        if let message, !message.trimmed.isEmpty {
            showBubble(message, near: docRect)
        }
    }

    func showBubble(_ text: String, near docRect: CGRect) {
        let label = PaddingLabel()
        label.text = RichTextParser.plainText(text)
        label.font = NoteFonts.tutorFont(style: .handwriting, size: 16, hand: AppSettings.shared.tutorHand)
        label.textColor = .white
        label.numberOfLines = 0
        label.backgroundColor = UIColor(hex: AppSettings.shared.tutorInkHex)
        label.layer.cornerRadius = 12
        label.clipsToBounds = true
        let maxW: CGFloat = 260
        let size = label.sizeThatFits(CGSize(width: maxW, height: 400))
        let inv = 1 / zoom
        label.bounds = CGRect(origin: .zero, size: CGSize(width: min(maxW, size.width), height: size.height))
        label.transform = CGAffineTransform(scaleX: inv, y: inv)
        label.center = CGPoint(x: min(docRect.maxX + 20 * inv + label.bounds.width * inv / 2, document.documentSize.width - label.bounds.width * inv / 2),
                               y: docRect.minY - label.bounds.height * inv / 2 - 6 * inv)
        label.alpha = 0
        chrome.addSubview(label)
        UIView.animate(withDuration: 0.25) { label.alpha = 1 }
        UIView.animate(withDuration: 0.4, delay: 4.5, options: [], animations: { label.alpha = 0 }) { _ in label.removeFromSuperview() }
    }

    // MARK: Audio replay

    /// Shows ink as it was at `time` during a recording: later strokes are faded.
    func setReplay(time: Date?) {
        if time == nil {
            guard replayTime != nil else { return }
            replayTime = nil
            replayRevealedCount = -1
            isApplyingDrawing = true
            // The document is authoritative: the tutor or page edits may have changed the ink meanwhile.
            canvasView.drawing = document.drawing
            isApplyingDrawing = false
            replaySourceDrawing = nil
            apply(tool: tool)
            return
        }
        if replayTime == nil {
            replaySourceDrawing = document.drawing
            endTextEditing()
            select(nil)
            clearLassoSelection()
        }
        replayTime = time
        canvasView.drawingGestureRecognizer.isEnabled = false
        // No ink is committed during replay, so a shape snap would leave its preview stuck on screen.
        strokeObserver?.isEnabled = false
        guard let source = replaySourceDrawing, let time else { return }
        let revealed = source.strokes.filter { $0.path.creationDate <= time }.count
        guard revealed != replayRevealedCount else { return }
        replayRevealedCount = revealed
        var d = PKDrawing()
        d.strokes = source.strokes.map { s in
            if s.path.creationDate <= time { return s }
            let faded = PKInk(s.ink.inkType, color: s.ink.color.withAlphaComponent(0.13))
            return PKStroke(ink: faded, path: s.path, transform: s.transform, mask: s.mask)
        }
        isApplyingDrawing = true
        canvasView.drawing = d
        isApplyingDrawing = false
    }
}

final class PaddingLabel: UILabel {
    var insets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let inner = super.sizeThatFits(CGSize(width: size.width - insets.left - insets.right, height: size.height))
        return CGSize(width: inner.width + insets.left + insets.right, height: inner.height + insets.top + insets.bottom)
    }
}
