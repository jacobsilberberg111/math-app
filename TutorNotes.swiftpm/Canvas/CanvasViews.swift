import UIKit
import PencilKit

/// A container that never claims touches itself, only through its interactive subviews.
class PassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

// MARK: - Pages

final class PDFTiledView: UIView {
    override class var layerClass: AnyClass { CATiledLayer.self }

    private let pdfPage: CGPDFPage

    init(page: CGPDFPage, frame: CGRect) {
        self.pdfPage = page
        super.init(frame: frame)
        backgroundColor = .white
        isUserInteractionEnabled = false
        if let tiled = layer as? CATiledLayer {
            tiled.levelsOfDetail = 4
            tiled.levelsOfDetailBias = 4
            tiled.tileSize = CGSize(width: 512, height: 512)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(rect)
        PaperRenderer.drawPDFPage(pdfPage, in: bounds, ctx: ctx)
    }
}

final class PageBackgroundView: UIView {
    private let pdfContainer = UIView()
    private let patternView = UIView()
    private let light = CAShapeLayer()
    private let strong = CAShapeLayer()
    private let dots = CAShapeLayer()
    private let accent = CAShapeLayer()
    private var pdfView: PDFTiledView?
    private let numberLabel = UILabel()
    private(set) var configuredPage: Page?
    private var configuredTileRect: CGRect?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.13
        layer.shadowRadius = 7
        layer.shadowOffset = CGSize(width: 0, height: 2)
        pdfContainer.isUserInteractionEnabled = false
        patternView.isUserInteractionEnabled = false
        addSubview(pdfContainer)
        addSubview(patternView)
        for l in [light, strong, accent] {
            l.fillColor = nil
            l.lineCap = .butt
            patternView.layer.addSublayer(l)
        }
        patternView.layer.addSublayer(dots)
        numberLabel.font = .systemFont(ofSize: 11, weight: .medium)
        numberLabel.textColor = UIColor(hex: "#9AA3AF")
        numberLabel.textAlignment = .center
        addSubview(numberLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(page: Page, number: Int, size: CGSize, pdf: CGPDFDocument?) {
        let sameStyle = configuredPage?.paper == page.paper && configuredPage?.pdfAssetID == page.pdfAssetID
            && configuredPage?.pdfPageIndex == page.pdfPageIndex && pdfContainer.bounds.size == size
        configuredPage = page
        numberLabel.text = "\(number)"
        numberLabel.frame = CGRect(x: 0, y: size.height - 22, width: size.width, height: 16)
        layer.shadowPath = UIBezierPath(rect: CGRect(origin: .zero, size: size)).cgPath
        pdfContainer.frame = CGRect(origin: .zero, size: size)
        patternView.frame = CGRect(origin: .zero, size: size)
        if sameStyle { return }
        backgroundColor = UIColor(hex: page.paper.color.hex)
        let paths = PaperRenderer.patternPaths(page.paper.pattern, size: size)
        let lineColor = PaperRenderer.lineColor(page.paper)
        light.path = paths.light
        light.strokeColor = lineColor.withAlphaComponent(0.9).cgColor
        light.lineWidth = 0.75
        strong.path = paths.strong
        strong.strokeColor = lineColor.cgColor
        strong.lineWidth = 1.3
        dots.path = paths.dots
        dots.fillColor = lineColor.cgColor
        accent.path = paths.accent
        accent.strokeColor = PaperRenderer.accentColor(page.paper).cgColor
        accent.lineWidth = 1
        pdfView?.removeFromSuperview()
        pdfView = nil
        if let pdf, let idx = page.pdfPageIndex, let p = pdf.page(at: idx + 1) {
            let v = PDFTiledView(page: p, frame: CGRect(origin: .zero, size: size))
            pdfContainer.addSubview(v)
            pdfView = v
            // Keep any pattern above the PDF but faint.
            patternView.alpha = 0.6
        } else {
            patternView.alpha = 1
        }
    }

    /// One tile of a freeform board: paper and pattern for `rect` (board coordinates), with no
    /// page shadow or number so neighbouring tiles read as one sheet.
    func configureTile(paper: PaperStyle, rect: CGRect) {
        let page = Page(id: Page.boardTileID, paper: paper)
        let sameStyle = configuredPage?.paper == paper && configuredTileRect == rect
        configuredPage = page
        configuredTileRect = rect
        layer.shadowOpacity = 0
        numberLabel.isHidden = true
        pdfView?.removeFromSuperview()
        pdfView = nil
        patternView.alpha = 1
        pdfContainer.frame = CGRect(origin: .zero, size: rect.size)
        patternView.frame = CGRect(origin: .zero, size: rect.size)
        if sameStyle { return }
        backgroundColor = UIColor(hex: paper.color.hex)
        let paths = PaperRenderer.boardPatternPaths(paper.pattern, rect: rect)
        let lineColor = PaperRenderer.lineColor(paper)
        light.path = paths.light
        light.strokeColor = lineColor.withAlphaComponent(0.9).cgColor
        light.lineWidth = 0.75
        strong.path = paths.strong
        strong.strokeColor = lineColor.cgColor
        strong.lineWidth = 1.3
        dots.path = paths.dots
        dots.fillColor = lineColor.cgColor
        accent.path = nil
    }
}

extension Page {
    /// Placeholder id for the `Page` a board tile is configured with (tiles aren't pages).
    static let boardTileID = UUID(uuidString: "00000000-0000-0000-0000-00000000B0A2")!
}

// MARK: - Elements

final class ElementView: UIView {
    static let padding: CGFloat = 8

    var element: CanvasElement {
        didSet { setNeedsDisplay() }
    }
    var progress: CGFloat = 1 {
        didSet { if oldValue != progress { setNeedsDisplay() } }
    }
    var isLive = false
    var environment: () -> RenderEnvironment

    init(element: CanvasElement, environment: @escaping () -> RenderEnvironment) {
        self.element = element
        self.environment = environment
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let inner = bounds.insetBy(dx: ElementView.padding, dy: ElementView.padding)
        ElementRenderer.draw(element, in: ctx, rect: inner, progress: progress, env: environment(), live: isLive)
    }
}

// MARK: - Tutor presence

/// The tutor's "hand" on the page: a glowing orb that glides to where it is looking or writing.
final class TutorPresenceView: UIView {
    enum Mode { case hidden, idle, looking, thinking, writing }

    private let orb = UIView()
    private let gradient = CAGradientLayer()
    private let ring = CAShapeLayer()
    private let icon = UIImageView()
    private(set) var mode: Mode = .hidden
    var tint: UIColor = UIColor(hex: "#7048E8") {
        didSet { applyTint() }
    }

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        isUserInteractionEnabled = false
        alpha = 0
        orb.frame = CGRect(x: 8, y: 8, width: 28, height: 28)
        orb.layer.cornerRadius = 14
        orb.clipsToBounds = false
        gradient.frame = orb.bounds
        gradient.cornerRadius = 14
        gradient.startPoint = CGPoint(x: 0.2, y: 0.1)
        gradient.endPoint = CGPoint(x: 0.9, y: 1)
        orb.layer.addSublayer(gradient)
        orb.layer.shadowOpacity = 0.55
        orb.layer.shadowRadius = 10
        orb.layer.shadowOffset = .zero
        icon.image = UIImage(systemName: "sparkle", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold))
        icon.tintColor = .white
        icon.contentMode = .center
        icon.frame = orb.bounds
        orb.addSubview(icon)
        ring.path = UIBezierPath(ovalIn: CGRect(x: 2, y: 2, width: 40, height: 40)).cgPath
        ring.fillColor = nil
        ring.lineWidth = 2
        ring.opacity = 0
        layer.addSublayer(ring)
        addSubview(orb)
        applyTint()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyTint() {
        let lighter = tint.withAlphaComponent(0.75)
        gradient.colors = [lighter.cgColor, tint.cgColor]
        orb.layer.shadowColor = tint.cgColor
        ring.strokeColor = tint.withAlphaComponent(0.6).cgColor
    }

    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
        orb.layer.removeAnimation(forKey: "pulse")
        ring.removeAnimation(forKey: "ring")
        icon.layer.removeAnimation(forKey: "spin")
        switch newMode {
        case .hidden:
            UIView.animate(withDuration: 0.35) { self.alpha = 0 }
        case .idle:
            UIView.animate(withDuration: 0.3) { self.alpha = 0.85 }
        case .looking:
            UIView.animate(withDuration: 0.25) { self.alpha = 1 }
            let r = CABasicAnimation(keyPath: "opacity")
            r.fromValue = 0.9
            r.toValue = 0
            let s = CABasicAnimation(keyPath: "transform.scale")
            s.fromValue = 0.6
            s.toValue = 1.5
            let g = CAAnimationGroup()
            g.animations = [r, s]
            g.duration = 1.3
            g.repeatCount = .infinity
            ring.add(g, forKey: "ring")
        case .thinking:
            UIView.animate(withDuration: 0.25) { self.alpha = 1 }
            let p = CABasicAnimation(keyPath: "transform.scale")
            p.fromValue = 0.9
            p.toValue = 1.12
            p.duration = 0.7
            p.autoreverses = true
            p.repeatCount = .infinity
            p.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            orb.layer.add(p, forKey: "pulse")
            let spin = CABasicAnimation(keyPath: "transform.rotation")
            spin.fromValue = 0
            spin.toValue = Double.pi * 2
            spin.duration = 2.4
            spin.repeatCount = .infinity
            icon.layer.add(spin, forKey: "spin")
        case .writing:
            UIView.animate(withDuration: 0.2) { self.alpha = 1 }
            let p = CABasicAnimation(keyPath: "transform.scale")
            p.fromValue = 0.95
            p.toValue = 1.05
            p.duration = 0.25
            p.autoreverses = true
            p.repeatCount = .infinity
            orb.layer.add(p, forKey: "pulse")
        }
    }

    /// Glides to a document point (the view's centre sits slightly above-right of the pen tip).
    func glide(to point: CGPoint, duration: TimeInterval = 0.45) {
        let target = CGPoint(x: point.x + 10 * inverseScale, y: point.y - 14 * inverseScale)
        if alpha < 0.05 {
            layer.removeAnimation(forKey: "follow")
            center = target
            return
        }
        UIView.animate(withDuration: duration, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0.4,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.center = target
        }
    }

    /// Follows a path of document points over `duration`, like a pen writing.
    func follow(_ points: [CGPoint], duration: TimeInterval) {
        guard points.count > 1 else {
            if let p = points.first { glide(to: p) }
            return
        }
        let offset = CGPoint(x: 10 * inverseScale, y: -14 * inverseScale)
        let path = CGMutablePath()
        path.move(to: points[0] + offset)
        for p in points.dropFirst() { path.addLine(to: p + offset) }
        let anim = CAKeyframeAnimation(keyPath: "position")
        anim.path = path
        anim.duration = duration
        anim.calculationMode = .paced
        anim.timingFunction = CAMediaTimingFunction(name: .linear)
        layer.add(anim, forKey: "follow")
        center = points[points.count - 1] + offset
    }

    /// The presence is counter-scaled so it stays the same size on screen at any zoom.
    var inverseScale: CGFloat = 1 {
        didSet { transform = CGAffineTransform(scaleX: inverseScale, y: inverseScale) }
    }
}

// MARK: - Selection

final class SelectionOverlayView: UIView {
    let border = CAShapeLayer()
    let handle = UIView()
    let actionBar = UIStackView()
    var onAction: ((ElementAction) -> Void)?
    private var actions: [ElementAction] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        border.fillColor = UIColor.systemBlue.withAlphaComponent(0.04).cgColor
        border.strokeColor = UIColor.systemBlue.cgColor
        border.lineDashPattern = [6, 4]
        border.lineWidth = 1.5
        layer.addSublayer(border)
        handle.backgroundColor = .white
        handle.layer.borderColor = UIColor.systemBlue.cgColor
        handle.layer.borderWidth = 2
        handle.layer.cornerRadius = 11
        handle.frame = CGRect(x: 0, y: 0, width: 22, height: 22)
        addSubview(handle)
        actionBar.axis = .horizontal
        actionBar.spacing = 2
        actionBar.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.97)
        actionBar.layer.cornerRadius = 12
        actionBar.layer.shadowColor = UIColor.black.cgColor
        actionBar.layer.shadowOpacity = 0.15
        actionBar.layer.shadowRadius = 10
        actionBar.layer.shadowOffset = CGSize(width: 0, height: 3)
        actionBar.isLayoutMarginsRelativeArrangement = true
        actionBar.layoutMargins = UIEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        addSubview(actionBar)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(for element: CanvasElement, zoom: CGFloat) {
        var list: [ElementAction] = [.askTutor]
        switch element.kind {
        case .text: list.append(.edit)
        case .question(let q):
            if !q.revealedHint { list.append(.revealHint) }
            list.append(.checkAnswer)
            if !q.revealedSolution { list.append(.revealSolution) }
        default: break
        }
        list.append(contentsOf: [.duplicate, .delete])
        if list.map(String.init(describing:)) != actions.map(String.init(describing:)) {
            actions = list
            actionBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for a in list {
                let b = UIButton(type: .system)
                var config = UIButton.Configuration.plain()
                config.image = UIImage(systemName: SelectionOverlayView.symbol(a))
                let title = SelectionOverlayView.title(a)
                config.title = title.isEmpty ? nil : title
                config.imagePadding = 4
                config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
                config.baseForegroundColor = a == .delete ? .systemRed : .label
                config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                    var out = incoming
                    out.font = UIFont.systemFont(ofSize: 13, weight: .medium)
                    return out
                }
                b.configuration = config
                b.addAction(UIAction { [weak self] _ in self?.onAction?(a) }, for: .touchUpInside)
                actionBar.addArrangedSubview(b)
            }
        }
        handle.isHidden = !SelectionOverlayView.isResizable(element)
        layoutChrome(zoom: zoom)
    }

    static func isResizable(_ e: CanvasElement) -> Bool {
        switch e.kind {
        case .image, .graph, .text, .math, .table, .numberLine, .question, .ink: return true
        }
    }

    func layoutChrome(zoom: CGFloat) {
        let inv = 1 / max(zoom, 0.01)
        border.frame = bounds
        border.path = UIBezierPath(roundedRect: bounds, cornerRadius: 6 * inv).cgPath
        border.lineWidth = 1.5 * inv
        border.lineDashPattern = [NSNumber(value: Double(6 * inv)), NSNumber(value: Double(4 * inv))]
        handle.transform = CGAffineTransform(scaleX: inv, y: inv)
        handle.center = CGPoint(x: bounds.maxX, y: bounds.maxY)
        actionBar.transform = .identity
        let size = actionBar.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        actionBar.bounds = CGRect(origin: .zero, size: size)
        actionBar.transform = CGAffineTransform(scaleX: inv, y: inv)
        actionBar.center = CGPoint(x: bounds.midX, y: -size.height * inv / 2 - 12 * inv)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if bounds.insetBy(dx: -16, dy: -16).contains(point) { return true }
        if actionBar.frame.contains(point) { return true }
        if handle.frame.insetBy(dx: -12, dy: -12).contains(point) { return true }
        return false
    }

    static func symbol(_ a: ElementAction) -> String {
        switch a {
        case .askTutor: return "sparkles"
        case .explain: return "questionmark.bubble"
        case .delete: return "trash"
        case .duplicate: return "plus.square.on.square"
        case .edit: return "character.cursor.ibeam"
        case .revealHint: return "lightbulb"
        case .revealSolution: return "eye"
        case .checkAnswer: return "checkmark.seal"
        }
    }

    static func title(_ a: ElementAction) -> String {
        switch a {
        case .askTutor: return "Ask"
        case .explain: return "Explain"
        case .delete: return ""
        case .duplicate: return ""
        case .edit: return "Edit"
        case .revealHint: return "Hint"
        case .revealSolution: return "Solution"
        case .checkAnswer: return "Check"
        }
    }
}

// MARK: - Misc overlays

final class HoverPreviewView: UIView {
    let dot = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.addSublayer(dot)
        alpha = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(at point: CGPoint, diameter: CGFloat, color: UIColor, isEraser: Bool, zoom: CGFloat) {
        let d = max(diameter, 4 / zoom)
        bounds = CGRect(x: 0, y: 0, width: d + 4, height: d + 4)
        center = point
        dot.frame = bounds
        dot.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2)).cgPath
        if isEraser {
            dot.fillColor = UIColor.white.withAlphaComponent(0.4).cgColor
            dot.strokeColor = UIColor.gray.cgColor
            dot.lineWidth = 1 / zoom
        } else {
            dot.fillColor = color.withAlphaComponent(0.45).cgColor
            dot.strokeColor = color.withAlphaComponent(0.8).cgColor
            dot.lineWidth = 0.8 / zoom
        }
        if alpha < 1 { UIView.animate(withDuration: 0.12) { self.alpha = 1 } }
    }

    func hide() {
        guard alpha > 0 else { return }
        UIView.animate(withDuration: 0.15) { self.alpha = 0 }
    }
}

/// Briefly highlights a region the tutor wants the student to look at.
final class PulseView: UIView {
    init(frame: CGRect, color: UIColor, zoom: CGFloat) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.cornerRadius = 10 / zoom
        layer.borderWidth = 2.5 / zoom
        layer.borderColor = color.cgColor
        backgroundColor = color.withAlphaComponent(0.08)
        alpha = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    func run() {
        UIView.animateKeyframes(withDuration: 2.2, delay: 0, options: []) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.15) { self.alpha = 1 }
            UIView.addKeyframe(withRelativeStartTime: 0.25, relativeDuration: 0.15) { self.alpha = 0.35 }
            UIView.addKeyframe(withRelativeStartTime: 0.45, relativeDuration: 0.15) { self.alpha = 1 }
            UIView.addKeyframe(withRelativeStartTime: 0.75, relativeDuration: 0.25) { self.alpha = 0 }
        } completion: { _ in
            self.removeFromSuperview()
        }
    }
}

/// UITextView used for editing text boxes in place. Supports Scribble automatically.
final class CanvasTextView: UITextView {
    var elementID: String?
    /// Typing undo stays with this short-lived view instead of landing on the note's shared stack.
    private let typingUndoManager = UndoManager()
    override var undoManager: UndoManager? { typingUndoManager }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        backgroundColor = UIColor.systemBlue.withAlphaComponent(0.04)
        isScrollEnabled = false
        textContainerInset = UIEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        // `self.`: the init parameter of the same name is nil here. Must match PlainTextRenderer (no padding).
        self.textContainer.lineFragmentPadding = 0
        layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.5).cgColor
        layer.borderWidth = 1
        layer.cornerRadius = 4
        autocorrectionType = .default
        smartQuotesType = .no
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Shape preview while the pencil is held after drawing (draw-and-hold snapping).
final class ShapePreviewLayer: CAShapeLayer {
    /// No implicit animations: the preview must track the pencil exactly as it resizes the shape.
    override func action(forKey event: String) -> CAAction? { nil }

    func show(_ shape: RecognizedShape, color: UIColor, width: CGFloat) {
        let pts = shape.outline(spacing: 2)
        let path = CGMutablePath()
        if let f = pts.first {
            path.move(to: f)
            for p in pts.dropFirst() { path.addLine(to: p) }
        }
        self.path = path
        strokeColor = color.cgColor
        fillColor = nil
        lineWidth = width
        lineCap = .round
        lineJoin = .round
        opacity = 0.95
    }

    func clear() {
        path = nil
    }
}
