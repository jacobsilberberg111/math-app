import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Tracks a free-form loop drawn with the pencil (or a finger, when fingers draw). It fails at once
/// for touches that should scroll, and for a second finger, which means scroll or zoom.
final class LassoGestureRecognizer: UIGestureRecognizer {
    var acceptsFinger = false
    weak var coordinateView: UIView?
    /// Asked as a touch lands, and again before the loop begins; false lets the touch through to everything
    /// else (replay, a resting palm).
    var accepts: (UITouch) -> Bool = { _ in true }
    /// The loop so far, in `coordinateView` coordinates.
    private(set) var points: [CGPoint] = []
    private var tracked: UITouch?
    private var startLocation: CGPoint = .zero

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard tracked == nil else {
            // A resting palm is ignored; a second finger turns a finger lasso into a scroll.
            if tracked?.type == .direct, state == .possible { state = .failed }
            return
        }
        guard touches.count == 1, let t = touches.first, accepts(t),
              t.type == .pencil || (acceptsFinger && t.type == .direct) else {
            state = .failed
            return
        }
        tracked = t
        startLocation = t.location(in: view)
        points = [t.location(in: coordinateView)]
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = tracked, touches.contains(t) else { return }
        for sample in event.coalescedTouches(for: t) ?? [t] {
            points.append(sample.location(in: coordinateView))
        }
        if state == .possible {
            // Begin after a few points of travel, so a tap stays a tap.
            guard t.location(in: view).distance(to: startLocation) > 4 else { return }
            guard accepts(t) else {
                tracked = nil
                state = .failed
                return
            }
            state = .began
        } else {
            state = .changed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = tracked, touches.contains(t) else { return }
        tracked = nil
        state = state == .possible ? .failed : .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = tracked, touches.contains(t) else { return }
        tracked = nil
        state = state == .possible ? .failed : .cancelled
    }

    override func reset() {
        super.reset()
        tracked = nil
        points = []
    }
}

enum LassoThickness {
    case thinner, thicker
    case width(CGFloat)
}

/// What the lasso's action bar can do to the selection.
enum LassoAction {
    case ask, toText, toMath, copy, cut, duplicate, delete
    case colour(String)
    case customColour
    case thickness(LassoThickness)
}

/// The dashed box, handles and action bar around a lasso selection. It lives in the canvas's chrome
/// (document coordinates, scaled by zoom) and turns a drag into one affine transform that the canvas
/// previews live and commits on release.
final class LassoSelectionView: UIView, UIGestureRecognizerDelegate {
    enum Mode { case move, resize, rotate }

    static let thicknessPresets: [CGFloat] = [1.2, 2, 3.2, 5, 8]
    /// Screen points from the box's top edge to the rotate handle, and how far from a handle's centre a touch still grabs it.
    private static let rotateOffset: CGFloat = 34
    private static let grabRadius: CGFloat = 24

    var onBegan: ((Mode) -> Void)?
    var onChanged: ((CGAffineTransform) -> Void)?
    var onEnded: ((Mode, CGAffineTransform) -> Void)?
    var onCancelled: (() -> Void)?
    var onAction: ((LassoAction) -> Void)?
    /// Asked for each touch that would start a drag; false ignores it (a resting palm).
    var accepts: (UITouch) -> Bool = { _ in true }

    private let border = CAShapeLayer()
    private let stem = CAShapeLayer()
    private let resizeHandle = UIView()
    private let rotateHandle = UIView()
    private let actionBar = UIStackView()
    private let toTextButton = UIButton(type: .system)
    private let toMathButton = UIButton(type: .system)
    private let colourButton = UIButton(type: .system)
    private let thicknessButton = UIButton(type: .system)
    private var titled: [(button: UIButton, title: String)] = []
    private var showsTitles = true

    /// The selection's box in document coordinates, and the zoom and visible area it was laid out for.
    private var box = CGRect.zero
    private var zoom: CGFloat = 1
    private var visible = CGRect.zero
    /// The drag in progress.
    private var mode: Mode?
    private var startPoint = CGPoint.zero
    private var liveTransform = CGAffineTransform.identity
    private var snappedStep: Int?
    private var isGesturing = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        border.fillColor = UIColor.systemBlue.withAlphaComponent(0.04).cgColor
        border.strokeColor = UIColor.systemBlue.cgColor
        stem.fillColor = nil
        stem.strokeColor = UIColor.systemBlue.cgColor
        layer.addSublayer(border)
        layer.addSublayer(stem)
        for handle in [resizeHandle, rotateHandle] {
            handle.bounds = CGRect(x: 0, y: 0, width: 24, height: 24)
            handle.backgroundColor = .white
            handle.layer.cornerRadius = 12
            handle.layer.borderWidth = 2
            handle.layer.borderColor = UIColor.systemBlue.cgColor
            handle.layer.shadowColor = UIColor.black.cgColor
            handle.layer.shadowOpacity = 0.2
            handle.layer.shadowRadius = 3
            handle.layer.shadowOffset = CGSize(width: 0, height: 1)
            handle.isUserInteractionEnabled = false
            addSubview(handle)
        }
        let icon = UIImageView(image: UIImage(systemName: "arrow.clockwise", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)))
        icon.tintColor = .systemBlue
        icon.contentMode = .center
        icon.frame = rotateHandle.bounds
        rotateHandle.addSubview(icon)
        buildActionBar()
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Action bar

    private func buildActionBar() {
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

        add(UIButton(type: .system), .ask, symbol: "sparkles", title: "Ask", label: "Ask the tutor")
        add(toTextButton, .toText, symbol: "textformat", title: "To Text", label: "Convert to text")
        add(toMathButton, .toMath, symbol: "function", title: "To Math", label: "Convert to maths")
        style(colourButton, symbol: "paintpalette", title: nil, label: "Colour")
        colourButton.showsMenuAsPrimaryAction = true
        actionBar.addArrangedSubview(colourButton)
        style(thicknessButton, symbol: "lineweight", title: nil, label: "Thickness")
        thicknessButton.menu = thicknessMenu()
        thicknessButton.showsMenuAsPrimaryAction = true
        actionBar.addArrangedSubview(thicknessButton)
        add(UIButton(type: .system), .copy, symbol: "doc.on.doc", label: "Copy")
        add(UIButton(type: .system), .cut, symbol: "scissors", label: "Cut")
        add(UIButton(type: .system), .duplicate, symbol: "plus.square.on.square", label: "Duplicate")
        add(UIButton(type: .system), .delete, symbol: "trash", label: "Delete", tint: .systemRed)
    }

    private func add(_ button: UIButton, _ action: LassoAction, symbol: String, title: String? = nil, label: String, tint: UIColor = .label) {
        style(button, symbol: symbol, title: title, label: label, tint: tint)
        button.addAction(UIAction { [weak self] _ in self?.onAction?(action) }, for: .touchUpInside)
        actionBar.addArrangedSubview(button)
    }

    private func style(_ button: UIButton, symbol: String, title: String?, label: String, tint: UIColor = .label) {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol)
        config.title = title
        config.imagePadding = 4
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        config.baseForegroundColor = tint
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = UIFont.systemFont(ofSize: 13, weight: .medium)
            return out
        }
        button.configuration = config
        button.accessibilityLabel = label
        if let title { titled.append((button, title)) }
    }

    /// What the bar offers for this selection: conversion needs ink, colour and thickness need something that has them.
    func configure(hasInk: Bool, canRecolour: Bool, canThicken: Bool, favourites: [String]) {
        toTextButton.isHidden = !hasInk
        toMathButton.isHidden = !hasInk
        colourButton.isHidden = !canRecolour
        thicknessButton.isHidden = !canThicken
        colourButton.menu = colourMenu(favourites: favourites)
    }

    private func colourMenu(favourites: [String]) -> UIMenu {
        func group(_ title: String, _ hexes: [String]) -> UIMenu {
            let actions = hexes.map { hex in
                UIAction(title: hex, image: LassoSelectionView.swatch(hex)) { [weak self] _ in self?.onAction?(.colour(hex)) }
            }
            let menu = UIMenu(title: title, options: .displayInline, children: actions)
            menu.preferredElementSize = .small
            return menu
        }
        var items: [UIMenuElement] = []
        if !favourites.isEmpty { items.append(group("Favourites", favourites)) }
        items.append(group("Pens", ColorPalettePicker.pens))
        items.append(UIAction(title: "Custom…", image: UIImage(systemName: "eyedropper")) { [weak self] _ in self?.onAction?(.customColour) })
        return UIMenu(title: "Colour", children: items)
    }

    private func thicknessMenu() -> UIMenu {
        let steps = UIMenu(title: "", options: .displayInline, children: [
            UIAction(title: "Thinner", image: UIImage(systemName: "minus")) { [weak self] _ in self?.onAction?(.thickness(.thinner)) },
            UIAction(title: "Thicker", image: UIImage(systemName: "plus")) { [weak self] _ in self?.onAction?(.thickness(.thicker)) },
        ])
        let presets = UIMenu(title: "", options: .displayInline, children: LassoSelectionView.thicknessPresets.map { width in
            UIAction(title: String(format: "%g pt", width), image: LassoSelectionView.linePreview(width)) { [weak self] _ in
                self?.onAction?(.thickness(.width(width)))
            }
        })
        return UIMenu(title: "Thickness", children: [steps, presets])
    }

    /// A coloured dot for a menu item (kept in its own colour, with a ring so white shows up).
    private static func swatch(_ hex: String) -> UIImage {
        let size = CGSize(width: 24, height: 24)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            let dot = UIBezierPath(ovalIn: CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2))
            UIColor(hex: hex).setFill()
            dot.fill()
            UIColor.black.withAlphaComponent(0.25).setStroke()
            dot.lineWidth = 1
            dot.stroke()
        }
        return image.withRenderingMode(.alwaysOriginal)
    }

    /// A short line of the given thickness, tinted by the menu.
    private static func linePreview(_ width: CGFloat) -> UIImage {
        let size = CGSize(width: 28, height: 14)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            UIColor.label.setFill()
            UIBezierPath(roundedRect: CGRect(x: 2, y: (size.height - width) / 2, width: size.width - 4, height: width), cornerRadius: width / 2).fill()
        }
        return image.withRenderingMode(.alwaysTemplate)
    }

    // MARK: Layout

    /// Lays the box and its controls out around `bounds` (document coordinates) at the given zoom.
    func update(bounds: CGRect, zoom: CGFloat, visible: CGRect) {
        self.zoom = max(zoom, 0.01)
        self.visible = visible
        box = bounds.insetBy(dx: -6 / self.zoom, dy: -6 / self.zoom)
        liveTransform = .identity
        isGesturing = false
        layoutChrome()
    }

    private var corners: [CGPoint] {
        [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
         CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
    }

    /// The box's corners with the drag applied (top-left, top-right, bottom-right, bottom-left).
    private var quad: [CGPoint] { corners.map { $0.applying(liveTransform) } }

    private func layoutChrome() {
        let inv = 1 / zoom
        let q = quad
        let outline = UIBezierPath()
        outline.move(to: q[0])
        for p in q.dropFirst() { outline.addLine(to: p) }
        outline.close()
        let topMid = CGPoint(x: (q[0].x + q[1].x) / 2, y: (q[0].y + q[1].y) / 2)
        let centre = CGPoint(x: (q[0].x + q[2].x) / 2, y: (q[0].y + q[2].y) / 2)
        let length = max(hypot(topMid.x - centre.x, topMid.y - centre.y), 0.001)
        let outward = CGPoint(x: (topMid.x - centre.x) / length, y: (topMid.y - centre.y) / length)
        let rotatePoint = topMid + outward * (LassoSelectionView.rotateOffset * inv)
        let stemPath = UIBezierPath()
        stemPath.move(to: topMid)
        stemPath.addLine(to: rotatePoint)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        border.path = outline.cgPath
        border.lineWidth = 1.5 * inv
        border.lineDashPattern = [NSNumber(value: Double(6 * inv)), NSNumber(value: Double(4 * inv))]
        stem.path = stemPath.cgPath
        stem.lineWidth = 1.5 * inv
        CATransaction.commit()

        resizeHandle.transform = CGAffineTransform(scaleX: inv, y: inv)
        resizeHandle.center = q[2]
        rotateHandle.transform = CGAffineTransform(scaleX: inv, y: inv)
        rotateHandle.center = rotatePoint
        layoutActionBar(quad: q)
    }

    /// Above the box (and its rotate handle), or below it when the visible area has no room above.
    private func layoutActionBar(quad q: [CGPoint]) {
        actionBar.isHidden = isGesturing
        guard !isGesturing else { return }
        let inv = 1 / zoom
        // Without room for the labels the bar shows icons only.
        let wantsTitles = visible.width * zoom > 640
        if wantsTitles != showsTitles {
            showsTitles = wantsTitles
            for item in titled { item.button.configuration?.title = wantsTitles ? item.title : nil }
        }
        actionBar.transform = .identity
        let size = actionBar.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        actionBar.bounds = CGRect(origin: .zero, size: size)
        actionBar.transform = CGAffineTransform(scaleX: inv, y: inv)
        let w = size.width * inv, h = size.height * inv
        let margin = 8 * inv
        let top = q.map(\.y).min() ?? 0, bottom = q.map(\.y).max() ?? 0
        let midX = q.map(\.x).reduce(0, +) / CGFloat(q.count)
        var y = top - (LassoSelectionView.rotateOffset + 30) * inv - h / 2
        if y - h / 2 < visible.minY + margin {
            y = bottom + 36 * inv + h / 2
            // A box that fills the screen: the bar sits just inside its top.
            if y + h / 2 > visible.maxY - margin { y = visible.minY + margin + h / 2 }
        }
        let lowest = visible.minX + w / 2 + margin, highest = visible.maxX - w / 2 - margin
        let x = lowest <= highest ? min(max(midX, lowest), highest) : visible.midX
        actionBar.center = CGPoint(x: x, y: y)
    }

    // MARK: Hit testing

    private func hitMode(at p: CGPoint) -> Mode? {
        let inv = 1 / zoom
        let reach = LassoSelectionView.grabRadius * inv
        if p.distance(to: resizeHandle.center) <= reach { return .resize }
        if p.distance(to: rotateHandle.center) <= reach { return .rotate }
        return box.insetBy(dx: -8 * inv, dy: -8 * inv).contains(p) ? .move : nil
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if !actionBar.isHidden && actionBar.frame.insetBy(dx: -4, dy: -4).contains(point) { return true }
        return hitMode(at: point) != nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard accepts(touch), let v = touch.view, !v.isDescendant(of: actionBar) else { return false }
        startPoint = touch.location(in: self)
        mode = hitMode(at: startPoint)
        return mode != nil
    }

    // MARK: Dragging

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        guard let mode else { return }
        switch g.state {
        case .began:
            isGesturing = true
            snappedStep = nil
            onBegan?(mode)
            fallthrough
        case .changed:
            liveTransform = dragTransform(for: mode, at: g.location(in: self))
            layoutChrome()
            onChanged?(liveTransform)
        case .ended:
            let t = dragTransform(for: mode, at: g.location(in: self))
            self.mode = nil
            isGesturing = false
            onEnded?(mode, t)
        default:
            self.mode = nil
            isGesturing = false
            liveTransform = .identity
            layoutChrome()
            onCancelled?()
        }
    }

    /// The transform a drag of the given kind has made when the touch is at `p`.
    private func dragTransform(for mode: Mode, at p: CGPoint) -> CGAffineTransform {
        let drag = CGPoint(x: p.x - startPoint.x, y: p.y - startPoint.y)
        switch mode {
        case .move:
            return CGAffineTransform(translationX: drag.x, y: drag.y)
        case .resize:
            // Uniform scale about the opposite corner, following the handle along the diagonal.
            let anchor = CGPoint(x: box.minX, y: box.minY)
            let diagonal = CGPoint(x: box.maxX - anchor.x, y: box.maxY - anchor.y)
            let handle = CGPoint(x: box.maxX + drag.x - anchor.x, y: box.maxY + drag.y - anchor.y)
            let along = (handle.x * diagonal.x + handle.y * diagonal.y) / max(diagonal.x * diagonal.x + diagonal.y * diagonal.y, 1)
            let smallest = max(0.05, 16 / max(box.width, box.height, 1))
            let s = min(max(along, smallest), 20)
            return CGAffineTransform(translationX: -anchor.x, y: -anchor.y)
                .concatenating(CGAffineTransform(scaleX: s, y: s))
                .concatenating(CGAffineTransform(translationX: anchor.x, y: anchor.y))
        case .rotate:
            let centre = CGPoint(x: box.midX, y: box.midY)
            let start = CGPoint(x: box.midX, y: box.minY - LassoSelectionView.rotateOffset / zoom)
            let pointer = CGPoint(x: start.x + drag.x, y: start.y + drag.y)
            var angle = atan2(pointer.y - centre.y, pointer.x - centre.x) - atan2(start.y - centre.y, start.x - centre.x)
            angle = atan2(sin(angle), cos(angle))
            // Snap to multiples of 45 degrees within about 3, with a tick when it catches.
            let step = CGFloat.pi / 4
            let nearest = (angle / step).rounded()
            var snapped: Int?
            if abs(angle - nearest * step) < 3 * CGFloat.pi / 180 {
                angle = nearest * step
                snapped = Int(nearest)
            }
            if snapped != snappedStep {
                if snapped != nil { Haptics.tap() }
                snappedStep = snapped
            }
            return CGAffineTransform(translationX: -centre.x, y: -centre.y)
                .concatenating(CGAffineTransform(rotationAngle: angle))
                .concatenating(CGAffineTransform(translationX: centre.x, y: centre.y))
        }
    }
}
