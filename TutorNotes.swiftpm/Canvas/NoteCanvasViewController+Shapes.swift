import UIKit
import PencilKit

/// A shape that was just snapped from a sketch, still open for resizing with the shape bar.
struct EditableShape {
    var shape: RecognizedShape
    var strokeIndex: Int
    let ink: PKInk
    let width: CGFloat
    let opacity: CGFloat
    let creationDate: Date

    /// The clean ink stroke for the shape. Corners are repeated in the outline so they stay sharp.
    func makeStroke() -> PKStroke {
        let pts = shape.outline(spacing: 2.5)
        var points: [PKStrokePoint] = []
        points.reserveCapacity(pts.count)
        for (i, p) in pts.enumerated() {
            points.append(PKStrokePoint(location: p, timeOffset: TimeInterval(i) * 0.004,
                                        size: CGSize(width: width, height: width), opacity: opacity,
                                        force: 1, azimuth: 0, altitude: .pi / 2))
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: creationDate), transform: .identity, mask: nil)
    }
}

/// Floating bar shown above a freshly snapped shape: smaller, bigger, done. Lives in document space
/// (inside the zoomed canvas) and counter-scales so it stays the same size on screen.
final class ShapeBarView: UIView {
    var onShrink: (() -> Void)?
    var onGrow: (() -> Void)?
    var onDone: (() -> Void)?
    private let stack = UIStackView()
    private let nameLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.systemBackground.withAlphaComponent(0.97)
        layer.cornerRadius = 14
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.16
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: 3)
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)

        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 2
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        addSubview(stack)

        stack.addArrangedSubview(button("minus", label: "Smaller") { [weak self] in self?.onShrink?() })
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = .secondaryLabel
        nameLabel.textAlignment = .center
        stack.addArrangedSubview(nameLabel)
        stack.addArrangedSubview(button("plus", label: "Bigger") { [weak self] in self?.onGrow?() })
        let divider = UIView()
        divider.backgroundColor = .separator
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 22).isActive = true
        stack.addArrangedSubview(divider)
        stack.addArrangedSubview(button("checkmark", label: "Done") { [weak self] in self?.onDone?() })
    }

    required init?(coder: NSCoder) { fatalError() }

    private func button(_ symbol: String, label: String, action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
        config.baseForegroundColor = .label
        b.configuration = config
        b.accessibilityLabel = label
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return b
    }

    /// Positions the bar centred above `shapeRect` (or below it near the top of the view).
    func layout(above shapeRect: CGRect, name: String, zoom: CGFloat, visible: CGRect) {
        nameLabel.text = name
        let inv = 1 / max(zoom, 0.01)
        transform = .identity
        let size = stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        bounds = CGRect(origin: .zero, size: size)
        stack.frame = bounds
        transform = CGAffineTransform(scaleX: inv, y: inv)
        let gap = 12 * inv
        let h = size.height * inv
        var y = shapeRect.minY - gap - h / 2
        if y - h / 2 < visible.minY { y = shapeRect.maxY + gap + h / 2 }
        let halfW = size.width * inv / 2
        let x = min(max(shapeRect.midX, visible.minX + halfW + 8 * inv), visible.maxX - halfW - 8 * inv)
        center = CGPoint(x: x, y: y)
    }
}

extension NoteCanvasViewController {
    func setupShapeBar() {
        shapeBar.isHidden = true
        shapeBar.onShrink = { [weak self] in self?.scaleEditableShape(by: 1 / 1.12) }
        shapeBar.onGrow = { [weak self] in self?.scaleEditableShape(by: 1.12) }
        shapeBar.onDone = { [weak self] in self?.endShapeEditing() }
        chrome.addSubview(shapeBar)
    }

    func beginShapeEditing(_ edit: EditableShape) {
        editableShape = edit
        shapeBar.isHidden = false
        shapeBar.alpha = 0
        chrome.bringSubviewToFront(shapeBar)
        layoutShapeBar()
        UIView.animate(withDuration: 0.18) { self.shapeBar.alpha = 1 }
    }

    func endShapeEditing() {
        guard editableShape != nil else { return }
        editableShape = nil
        UIView.animate(withDuration: 0.15, animations: { self.shapeBar.alpha = 0 }) { _ in
            if self.editableShape == nil { self.shapeBar.isHidden = true }
        }
    }

    func layoutShapeBar() {
        guard let edit = editableShape else { return }
        shapeBar.layout(above: edit.shape.bounds, name: edit.shape.name, zoom: zoom, visible: visibleDocRect)
    }

    /// After undo, erasing or a programmatic change, keep the bar only if its stroke is still there.
    func revalidateEditableShape() {
        guard var edit = editableShape else { return }
        let strokes = canvasView.drawing.strokes
        if edit.strokeIndex < strokes.count, strokes[edit.strokeIndex].path.creationDate == edit.creationDate {
            return
        }
        if let i = strokes.lastIndex(where: { $0.path.creationDate == edit.creationDate }) {
            edit.strokeIndex = i
            editableShape = edit
        } else {
            endShapeEditing()
        }
    }

    func scaleEditableShape(by factor: CGFloat) {
        revalidateEditableShape()
        guard var edit = editableShape else { return }
        let next = edit.shape.scaled(by: factor)
        let b = next.bounds
        // Keep it a usable size: not a speck, not wider than a page.
        guard max(b.width, b.height) >= 12, max(b.width, b.height) <= document.pageSize.width * 1.5 else { return }
        edit.shape = next
        var d = document.drawing
        guard edit.strokeIndex < d.strokes.count else { endShapeEditing(); return }
        d.strokes[edit.strokeIndex] = edit.makeStroke()
        editableShape = edit
        document.replaceDrawing(d, actionName: "Resize Shape")
        layoutShapeBar()
        Haptics.tap()
    }
}
