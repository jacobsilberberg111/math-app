import UIKit

/// Find-in-note highlights, drawn in document coordinates inside `chrome`: translucent yellow
/// behind every match and orange behind the current one. Insets, corner radii and line widths
/// follow 1/zoom so they look the same at any zoom.
final class FindHighlightLayer: CALayer {
    private let matchesLayer = CAShapeLayer()
    private let currentLayer = CAShapeLayer()
    private var rects: [CGRect] = []
    private var currentIndex: Int?
    private var zoom: CGFloat = 1

    override init() {
        super.init()
        matchesLayer.fillColor = UIColor(hex: "#FFD60A").withAlphaComponent(0.38).cgColor
        currentLayer.fillColor = UIColor(hex: "#FF9500").withAlphaComponent(0.42).cgColor
        currentLayer.strokeColor = UIColor(hex: "#FF9500").cgColor
        addSublayer(matchesLayer)
        addSublayer(currentLayer)
    }

    override init(layer: Any) { super.init(layer: layer) }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ rects: [CGRect], current: Int?, zoom: CGFloat) {
        self.rects = rects
        currentIndex = current
        self.zoom = zoom
        redraw()
    }

    func clear() {
        rects = []
        currentIndex = nil
        redraw()
    }

    /// Called as the zoom changes; the paths only depend on it while something is shown.
    func relayout(zoom newZoom: CGFloat) {
        guard abs(newZoom - zoom) > 0.0005 else { return }
        zoom = newZoom
        if !rects.isEmpty { redraw() }
    }

    private func redraw() {
        let radius = 4 / zoom
        let all = UIBezierPath()
        var current: UIBezierPath?
        for (i, rect) in rects.enumerated() {
            let shape = UIBezierPath(roundedRect: rect.insetBy(dx: -3 / zoom, dy: -2 / zoom), cornerRadius: radius)
            if i == currentIndex { current = shape } else { all.append(shape) }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        matchesLayer.path = rects.isEmpty ? nil : all.cgPath
        currentLayer.path = current?.cgPath
        currentLayer.lineWidth = 2 / zoom
        CATransaction.commit()
    }
}

extension NoteCanvasViewController {
    /// Highlights find matches (document coordinates); `current` is the one shown in orange.
    func showFindHighlights(_ rects: [CGRect], current: Int?) {
        findHighlights.show(rects, current: current, zoom: zoom)
    }

    func clearFindHighlights() {
        findHighlights.clear()
    }

    /// Keeps the highlights' insets and line widths right as the zoom changes.
    func layoutFindHighlights() {
        findHighlights.relayout(zoom: zoom)
    }
}
