import UIKit

/// Draws FlowchartContent: boxes in their shapes, arrows routed by FlowchartLayout, edge labels
/// and an optional title. The chart is laid out at its natural size and scaled to the frame.
@MainActor
enum FlowchartRenderer {
    static let textWidth: CGFloat = 170
    static let decisionTextWidth: CGFloat = 130
    static let circleTextWidth: CGFloat = 110
    static let ioSkew: CGFloat = 14
    static let titleHeight: CGFloat = 32

    struct Laid {
        var result: FlowchartLayout.Result
        var natural: CGSize
    }

    private static var cache: [String: Laid] = [:]
    private static var cacheOrder: [String] = []

    static func font(_ f: FlowchartContent) -> UIFont { NoteFonts.sans(size: f.fontSize, weight: .medium) }

    static func textLayout(_ node: FlowNode, font: UIFont) -> RichTextLayout {
        let w: CGFloat
        switch node.shape {
        case .decision: w = decisionTextWidth
        case .circle: w = circleTextWidth
        default: w = textWidth
        }
        return ElementRenderer.richLayout(node.text, font: font, width: w, rich: true)
    }

    /// A box big enough for its text in its shape.
    static func boxSize(_ node: FlowNode, font: UIFont) -> CGSize {
        let t = textLayout(node, font: font).size
        let tw = max(t.width, 24), th = max(t.height, font.lineHeight)
        switch node.shape {
        case .process: return CGSize(width: tw + 28, height: th + 20)
        case .terminal: return CGSize(width: tw + 40, height: th + 18)
        case .decision: return CGSize(width: tw * 2 + 20, height: th * 2 + 18)
        case .io: return CGSize(width: tw + 28 + 2 * ioSkew, height: th + 20)
        case .note: return CGSize(width: tw + 8, height: th + 6)
        case .circle:
            let d = max(tw, th) * 1.2 + 26
            return CGSize(width: d, height: d)
        }
    }

    static func laid(_ f: FlowchartContent) -> Laid {
        let key = cacheKey(f)
        if let l = cache[key] { return l }
        let font = font(f)
        let ids = f.nodes.map(\.id)
        let edges: [(Int, Int, Bool)] = f.edges.compactMap { e in
            guard let a = ids.firstIndex(of: e.from), let b = ids.firstIndex(of: e.to) else { return nil }
            return (a, b, !(e.label ?? "").isEmpty)
        }
        let result = FlowchartLayout.layout(sizes: f.nodes.map { boxSize($0, font: font) }, edges: edges, direction: f.direction)
        var natural = result.size
        if f.title?.isEmpty == false {
            natural.height += titleHeight
            let tl = ElementRenderer.richLayout(f.title ?? "", font: NoteFonts.sans(size: 17, weight: .semibold), width: 600, rich: true)
            natural.width = max(natural.width, tl.size.width + 24)
        }
        let l = Laid(result: result, natural: natural)
        cache[key] = l
        cacheOrder.append(key)
        if cacheOrder.count > 30 { cache[cacheOrder.removeFirst()] = nil }
        return l
    }

    private static func cacheKey(_ f: FlowchartContent) -> String {
        var s = "\(f.direction.rawValue)|\(f.fontSize)|\(f.title ?? "")|"
        for n in f.nodes { s += "\(n.id)\u{1}\(n.text)\u{1}\(n.shape.rawValue)\u{2}" }
        for e in f.edges { s += "\(e.from)>\(e.to):\(e.label ?? "")\u{2}" }
        return s
    }

    static func naturalSize(_ f: FlowchartContent) -> CGSize { laid(f).natural }

    /// How the chart's own coordinates map into a frame: scale, then offset.
    static func placement(_ f: FlowchartContent, in rect: CGRect) -> (scale: CGFloat, origin: CGPoint, chartTop: CGFloat) {
        let n = laid(f).natural
        let s = max(0.2, min(rect.width / max(n.width, 1), rect.height / max(n.height, 1)))
        let origin = CGPoint(x: rect.minX + (rect.width - n.width * s) / 2, y: rect.minY)
        let top: CGFloat = f.title?.isEmpty == false ? titleHeight : 0
        return (s, origin, top)
    }

    /// A node's box in the coordinates of `rect` (page coordinates when rect is the frame).
    static func nodeFrames(_ f: FlowchartContent, in rect: CGRect) -> [CGRect] {
        let (s, o, top) = placement(f, in: rect)
        return laid(f).result.frames.map { r in
            CGRect(x: o.x + r.minX * s, y: o.y + (top + r.minY) * s, width: r.width * s, height: r.height * s)
        }
    }

    // MARK: Drawing

    static func draw(_ f: FlowchartContent, rect: CGRect, progress: CGFloat, env: RenderEnvironment, ctx: CGContext) {
        guard !f.nodes.isEmpty else { return }
        let l = laid(f)
        let (s, o, top) = placement(f, in: rect)
        let ink = UIColor(hex: f.colorHex)
        let font = font(f)
        ctx.saveGState()
        ctx.translateBy(x: o.x, y: o.y)
        ctx.scaleBy(x: s, y: s)
        if let title = f.title, !title.isEmpty {
            let tl = ElementRenderer.richLayout(title, font: NoteFonts.sans(size: 17, weight: .semibold), width: l.natural.width - 12, rich: true)
            tl.draw(in: ctx, origin: CGPoint(x: (l.natural.width - tl.size.width) / 2, y: 4), color: ink)
        }
        ctx.translateBy(x: 0, y: top)
        let visible = progress >= 1 ? f.nodes.count : Int((CGFloat(f.nodes.count) * progress).rounded(.up))

        // Arrows first, so boxes sit on top of their ends.
        let edgeColor = ink.withAlphaComponent(0.75)
        for e in l.result.edges where e.from < visible && e.to < visible {
            drawEdge(e, color: edgeColor, ctx: ctx)
        }
        for (i, node) in f.nodes.enumerated() where i < visible {
            drawNode(node, frame: l.result.frames[i], font: font, fallback: ink, ctx: ctx)
        }
        // Edge labels last.
        let labelFont = NoteFonts.sans(size: max(11, f.fontSize - 2), weight: .semibold)
        for e in l.result.edges where e.from < visible && e.to < visible {
            guard let at = e.labelAt, let text = labelFor(e, f) else { continue }
            let tl = ElementRenderer.richLayout(text, font: labelFont, width: 120, rich: true)
            let box = CGRect(x: at.x - tl.size.width / 2 - 4, y: at.y - tl.size.height / 2 - 1, width: tl.size.width + 8, height: tl.size.height + 2)
            ctx.setFillColor(UIColor.white.withAlphaComponent(0.92).cgColor)
            ctx.addPath(UIBezierPath(roundedRect: box, cornerRadius: 4).cgPath)
            ctx.fillPath()
            tl.draw(in: ctx, origin: CGPoint(x: box.minX + 4, y: box.minY + 1), color: ink)
        }
        ctx.restoreGState()
    }

    /// The label of the content edge a routed edge came from.
    private static func labelFor(_ e: FlowchartLayout.Edge, _ f: FlowchartContent) -> String? {
        guard e.from < f.nodes.count, e.to < f.nodes.count else { return nil }
        let a = f.nodes[e.from].id, b = f.nodes[e.to].id
        return f.edges.first { $0.from == a && $0.to == b && !($0.label ?? "").isEmpty }?.label
    }

    private static func drawEdge(_ e: FlowchartLayout.Edge, color: UIColor, ctx: CGContext) {
        guard e.points.count >= 2 else { return }
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(1.8)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let tip = e.points[e.points.count - 1]
        var from = e.points[e.points.count - 2]
        if let c = e.control {
            ctx.move(to: e.points[0])
            // Stop short so the arrowhead covers the end.
            ctx.addQuadCurve(to: tip, control: c)
            ctx.strokePath()
            from = c
        } else {
            let path = CGMutablePath()
            path.move(to: e.points[0])
            if e.points.count > 2 {
                for i in 1..<(e.points.count - 1) {
                    path.addArc(tangent1End: e.points[i], tangent2End: e.points[i + 1], radius: 10)
                }
            }
            path.addLine(to: tip)
            ctx.addPath(path)
            ctx.strokePath()
        }
        ElementRenderer.drawArrowHead(at: tip, from: from, size: 9, color: color, ctx: ctx)
    }

    private static func drawNode(_ node: FlowNode, frame r: CGRect, font: UIFont, fallback: UIColor, ctx: CGContext) {
        let stroke = node.colorHex.map { UIColor(hex: $0) } ?? fallback
        let fill: UIColor
        if let hex = node.colorHex {
            fill = UIColor(hex: hex).withAlphaComponent(0.12)
        } else {
            switch node.shape {
            case .decision: fill = UIColor(hex: "#FFF6E0")
            case .terminal: fill = UIColor(hex: "#E9F6EE")
            case .io: fill = UIColor(hex: "#EEF1FF")
            case .circle: fill = UIColor(hex: "#EAF4FB")
            case .process: fill = UIColor(hex: "#F6F8FA")
            case .note: fill = .clear
            }
        }
        let path: UIBezierPath
        switch node.shape {
        case .process: path = UIBezierPath(roundedRect: r, cornerRadius: 8)
        case .terminal: path = UIBezierPath(roundedRect: r, cornerRadius: r.height / 2)
        case .decision:
            path = UIBezierPath()
            path.move(to: CGPoint(x: r.midX, y: r.minY))
            path.addLine(to: CGPoint(x: r.maxX, y: r.midY))
            path.addLine(to: CGPoint(x: r.midX, y: r.maxY))
            path.addLine(to: CGPoint(x: r.minX, y: r.midY))
            path.close()
        case .io:
            path = UIBezierPath()
            path.move(to: CGPoint(x: r.minX + ioSkew, y: r.minY))
            path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            path.addLine(to: CGPoint(x: r.maxX - ioSkew, y: r.maxY))
            path.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            path.close()
        case .circle: path = UIBezierPath(ovalIn: r)
        case .note: path = UIBezierPath(rect: r)
        }
        if node.shape != .note {
            ctx.setFillColor(fill.cgColor)
            ctx.addPath(path.cgPath)
            ctx.fillPath()
            ctx.setStrokeColor(stroke.cgColor)
            ctx.setLineWidth(1.6)
            ctx.addPath(path.cgPath)
            ctx.strokePath()
        }
        let tl = textLayout(node, font: font)
        tl.draw(in: ctx, origin: CGPoint(x: r.midX - tl.size.width / 2, y: r.midY - tl.size.height / 2), color: UIColor(hex: "#1F2328"))
    }

    // MARK: For the tutor

    static func tutorDescription(_ f: FlowchartContent, frame: CGRect) -> String {
        let frames = nodeFrames(f, in: frame)
        var s = (f.title.map { "\"\($0)\", " } ?? "") + "\(f.direction.rawValue), \(f.nodes.count) boxes: "
        s += zip(f.nodes, frames).prefix(24).map { n, r in
            "\(n.id) \(n.shape.rawValue) \"\(n.text.truncated(40))\" \(r.roundedForDisplay)"
        }.joined(separator: "; ")
        if f.nodes.count > 24 { s += "; …" }
        let arrows = f.edges.prefix(30).map { "\($0.from)→\($0.to)\($0.label.map { " (\($0))" } ?? "")" }
        if !arrows.isEmpty { s += ". Arrows: " + arrows.joined(separator: ", ") }
        return s
    }
}
