import UIKit

struct RenderEnvironment {
    var hand: TutorHandStyle
    var tutorHex: String
    var image: @MainActor (String) -> UIImage?
    /// True when rendering for the tutor's eyes (snapshot): hidden answer keys are never drawn anyway,
    /// this only drops decorative chrome.
    var forSnapshot: Bool = false
}

/// Core Graphics drawing for every element kind. Used by on-screen element views (with a reveal
/// `progress` for animation), by PDF export and by the snapshots sent to the tutor.
@MainActor
enum ElementRenderer {
    // MARK: Caches

    private static var textCache: [String: RichTextLayout] = [:]
    private static var textCacheOrder: [String] = []

    static func richLayout(_ text: String, font: UIFont, width: CGFloat, rich: Bool, live: Bool = false) -> RichTextLayout {
        let key = "\(font.fontName)|\(font.pointSize)|\(Int(width))|\(rich)|\(live)|\(text)"
        if let l = textCache[key] { return l }
        let l = RichTextLayout(text: text, font: font, maxWidth: width, rich: rich, hideUnclosedMath: live)
        textCache[key] = l
        textCacheOrder.append(key)
        if textCacheOrder.count > 80 {
            let old = textCacheOrder.removeFirst()
            textCache[old] = nil
        }
        return l
    }

    // MARK: Fonts per element

    static func font(for t: TextContent, author: Author, env: RenderEnvironment) -> UIFont {
        if author == .student && !t.rich { return NoteFonts.studentFont(size: t.fontSize) }
        return NoteFonts.tutorFont(style: t.style, size: t.fontSize, hand: env.hand)
    }

    // MARK: Measuring

    static func measureText(_ t: TextContent, author: Author, width: CGFloat, env: RenderEnvironment) -> CGSize {
        let f = font(for: t, author: author, env: env)
        let inset = textInsets(t.style)
        if author == .student && !t.rich {
            let s = PlainTextRenderer.size(t.text, font: f, width: width - inset.left - inset.right)
            return CGSize(width: width, height: s.height + inset.top + inset.bottom)
        }
        let l = richLayout(t.text, font: f, width: width - inset.left - inset.right, rich: t.rich)
        return CGSize(width: width, height: max(f.lineHeight, l.size.height) + inset.top + inset.bottom)
    }

    /// Smallest width that fits the text on as few lines as the given max width allows.
    static func fittedTextWidth(_ t: TextContent, author: Author, maxWidth: CGFloat, env: RenderEnvironment) -> CGFloat {
        let f = font(for: t, author: author, env: env)
        let inset = textInsets(t.style)
        let l = richLayout(t.text, font: f, width: maxWidth - inset.left - inset.right, rich: t.rich)
        return min(maxWidth, l.size.width + inset.left + inset.right + 4)
    }

    static func textInsets(_ style: TextStyle) -> UIEdgeInsets {
        switch style {
        case .sticky: return UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        case .note: return UIEdgeInsets(top: 4, left: 12, bottom: 4, right: 4)
        default: return UIEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        }
    }

    static func measureMath(_ m: MathContent) -> CGSize {
        let r = MathLayout.layoutLines(m.lines, size: m.fontSize, align: m.alignRelations)
        return CGSize(width: r.size.width + 8, height: r.size.height + 8)
    }

    static func questionPromptHeight(_ q: QuestionContent, width: CGFloat, env: RenderEnvironment) -> CGFloat {
        let f = NoteFonts.tutorFont(style: .typed, size: 19, hand: env.hand)
        let l = richLayout(q.prompt, font: f, width: width - 64 - 96, rich: true)
        return max(36, l.size.height) + 30
    }

    static func tableSize(_ t: TableContent, maxWidth: CGFloat) -> CGSize {
        let widths = tableColumnWidths(t, maxWidth: maxWidth)
        let heights = tableRowHeights(t, widths: widths)
        return CGSize(width: widths.reduce(0, +), height: heights.reduce(0, +))
    }

    static func tableColumnWidths(_ t: TableContent, maxWidth: CGFloat) -> [CGFloat] {
        let cols = t.rows.map(\.count).max() ?? 0
        guard cols > 0 else { return [] }
        let font = NoteFonts.rounded(size: t.fontSize, weight: .regular)
        var natural = [CGFloat](repeating: 40, count: cols)
        for row in t.rows {
            for (j, cell) in row.enumerated() {
                let l = richLayout(cell, font: font, width: 1000, rich: true)
                natural[j] = max(natural[j], l.size.width + 24)
            }
        }
        let total = natural.reduce(0, +)
        if total <= maxWidth { return natural }
        return natural.map { $0 * maxWidth / total }
    }

    static func tableRowHeights(_ t: TableContent, widths: [CGFloat]) -> [CGFloat] {
        let font = NoteFonts.rounded(size: t.fontSize, weight: .regular)
        return t.rows.map { row in
            var h: CGFloat = font.lineHeight + 16
            for (j, cell) in row.enumerated() where j < widths.count {
                let l = richLayout(cell, font: font, width: widths[j] - 20, rich: true)
                h = max(h, l.size.height + 16)
            }
            return h
        }
    }

    // MARK: Reveal timing

    static func revealDuration(_ e: CanvasElement) -> TimeInterval {
        switch e.kind {
        case .text(let t): return min(3.2, max(0.45, Double(t.text.count) * 0.022))
        case .math(let m): return min(3.0, 0.6 + Double(m.lines.count) * 0.35)
        case .ink(let ink):
            let len = ink.strokes.reduce(0) { $0 + ShapeGeometry.pathLength($1.points) }
            return min(1.6, max(0.35, Double(len) / 650)) + (ink.label == nil ? 0 : 0.4)
        case .graph(let g): return 1.2 + Double(g.functions.count) * 0.5
        case .numberLine: return 1.0
        case .table(let t): return 0.5 + Double(t.rows.count) * 0.12
        case .question(let q): return min(2.4, 0.6 + Double(q.prompt.count) * 0.012)
        case .image: return 0.35
        }
    }

    /// Points (relative to the element frame) the tutor's cursor follows while this element appears.
    static func presencePath(_ e: CanvasElement, env: RenderEnvironment) -> [CGPoint] {
        let size = e.frame.size
        switch e.kind {
        case .ink(let ink):
            var pts: [CGPoint] = []
            for s in ink.strokes { pts.append(contentsOf: smoothed(s.points, closed: s.closed)) }
            return stride(from: 0, to: pts.count, by: max(1, pts.count / 40)).map { pts[$0] }
        case .text(let t):
            let f = font(for: t, author: e.author, env: env)
            let inset = textInsets(t.style)
            let l = richLayout(t.text, font: f, width: size.width - inset.left - inset.right, rich: t.rich)
            let n = max(1, l.totalChars)
            return stride(from: 0, through: n, by: max(1, n / 30)).map {
                let p = l.caretPosition(afterChars: $0)
                return CGPoint(x: p.x + inset.left, y: p.y + inset.top)
            }
        case .graph(let g):
            let plot = graphPlotRect(CGRect(origin: .zero, size: size), g)
            var pts = [CGPoint(x: plot.minX, y: plot.maxY), CGPoint(x: plot.maxX, y: plot.maxY), CGPoint(x: plot.minX, y: plot.minY)]
            if let f = g.functions.first, let expr = try? ExpressionParser.parse(f.expression) {
                let segs = FunctionSampler.sample(expr, xMin: g.xMin, xMax: g.xMax, yMin: g.yMin, yMax: g.yMax, samples: 40)
                for seg in segs { for p in seg { pts.append(graphMap(p.x, p.y, g, plot)) } }
            }
            return pts.filter { plot.insetBy(dx: -4, dy: -4).contains($0) }
        default:
            return [CGPoint(x: 8, y: 16), CGPoint(x: size.width * 0.5, y: 20), CGPoint(x: size.width - 8, y: 24),
                    CGPoint(x: 8, y: size.height * 0.6), CGPoint(x: size.width - 8, y: size.height - 8)]
        }
    }

    // MARK: Drawing entry point

    static func draw(_ e: CanvasElement, in ctx: CGContext, rect: CGRect, progress: CGFloat = 1, env: RenderEnvironment, live: Bool = false) {
        let p = max(0, min(1, progress))
        ctx.saveGState()
        defer { ctx.restoreGState() }
        switch e.kind {
        case .text(let t): drawText(t, author: e.author, rect: rect, progress: p, env: env, ctx: ctx, live: live)
        case .math(let m): drawMath(m, rect: rect, progress: p, ctx: ctx)
        case .ink(let ink): drawInk(ink, rect: rect, progress: p, env: env, ctx: ctx)
        case .graph(let g): drawGraph(g, rect: rect, progress: p, ctx: ctx)
        case .numberLine(let n): drawNumberLine(n, rect: rect, progress: p, ctx: ctx)
        case .table(let t): drawTable(t, rect: rect, progress: p, ctx: ctx)
        case .question(let q): drawQuestion(q, rect: rect, progress: p, env: env, ctx: ctx)
        case .image(let img): drawImage(img, rect: rect, progress: p, env: env, ctx: ctx)
        }
    }

    // MARK: Text

    static func drawText(_ t: TextContent, author: Author, rect: CGRect, progress: CGFloat, env: RenderEnvironment, ctx: CGContext, live: Bool) {
        let f = font(for: t, author: author, env: env)
        let color = UIColor(hex: t.colorHex)
        let inset = textInsets(t.style)
        switch t.style {
        case .sticky:
            let path = UIBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerRadius: 6)
            ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 6, color: UIColor.black.withAlphaComponent(0.12 * progress).cgColor)
            ctx.setFillColor(UIColor(hex: "#FFF4B8").withAlphaComponent(progress).cgColor)
            ctx.addPath(path.cgPath)
            ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
        case .note:
            ctx.setFillColor(color.withAlphaComponent(0.5).cgColor)
            ctx.fill(CGRect(x: rect.minX, y: rect.minY + 2, width: 3, height: rect.height - 4))
        default:
            break
        }
        let inner = rect.inset(by: inset)
        if author == .student && !t.rich {
            PlainTextRenderer.draw(t.text, in: inner, font: f, color: color, ctx: ctx)
            return
        }
        let l = richLayout(t.text, font: f, width: inner.width, rich: t.rich, live: live)
        let visible = progress >= 1 ? nil : Int(CGFloat(l.totalChars) * progress)
        l.draw(in: ctx, origin: inner.origin, color: color, visibleChars: visible)
    }

    // MARK: Math

    static func drawMath(_ m: MathContent, rect: CGRect, progress: CGFloat, ctx: CGContext) {
        let r = MathLayout.layoutLines(m.lines, size: m.fontSize, align: m.alignRelations)
        let color = UIColor(hex: m.colorHex)
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }
        let n = CGFloat(max(1, r.boxes.count))
        for (i, (box, origin)) in r.boxes.enumerated() {
            let lineProgress = max(0, min(1, progress * n - CGFloat(i)))
            if lineProgress <= 0 { break }
            ctx.saveGState()
            let o = CGPoint(x: rect.minX + 4 + origin.x, y: rect.minY + 4 + origin.y)
            if lineProgress < 1 {
                ctx.clip(to: CGRect(x: o.x - 4, y: o.y - box.ascent - 8, width: (box.width + 8) * lineProgress, height: box.height + 16))
            }
            box.draw(in: ctx, at: o, color: color)
            ctx.restoreGState()
        }
    }

    // MARK: Ink

    /// Catmull-Rom smoothing so the tutor's polylines look hand drawn rather than jagged.
    static func smoothed(_ pts: [CGPoint], closed: Bool) -> [CGPoint] {
        guard pts.count > 2 else { return pts }
        var src = pts
        if closed, let f = src.first, let l = src.last, f.distance(to: l) > 1 { src.append(f) }
        var out: [CGPoint] = []
        let n = src.count
        for i in 0..<(n - 1) {
            let p0 = src[max(0, i - 1)], p1 = src[i], p2 = src[i + 1], p3 = src[min(n - 1, i + 2)]
            let d = p1.distance(to: p2)
            let steps = max(1, Int(d / 4))
            for s in 0..<steps {
                let t = CGFloat(s) / CGFloat(steps)
                let t2 = t * t, t3 = t2 * t
                let x = 0.5 * ((2 * p1.x) + (-p0.x + p2.x) * t + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 + (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3)
                let y = 0.5 * ((2 * p1.y) + (-p0.y + p2.y) * t + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 + (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3)
                out.append(CGPoint(x: x, y: y))
            }
        }
        out.append(src[n - 1])
        return out
    }

    static func drawInk(_ ink: InkContent, rect: CGRect, progress: CGFloat, env: RenderEnvironment, ctx: CGContext) {
        let color = UIColor(hex: ink.colorHex).withAlphaComponent(ink.opacity)
        let strokes = ink.strokes.map { s -> [CGPoint] in
            let pts = ink.purpose == .box || ink.purpose == .strike ? s.points : smoothed(s.points, closed: s.closed)
            return pts.map { CGPoint(x: $0.x + rect.minX, y: $0.y + rect.minY) }
        }
        let lengths = strokes.map { ShapeGeometry.pathLength($0) }
        let total = max(1, lengths.reduce(0, +))
        let hasLabel = ink.label?.isEmpty == false
        let inkShare: CGFloat = hasLabel ? 0.75 : 1
        var budget = total * min(1, progress / inkShare)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(color.cgColor)
        if ink.purpose == .highlight {
            ctx.setBlendMode(.multiply)
        }
        // Highlighter strokes are translucent: stroke each as one path so the round caps of
        // neighbouring segments don't stack into dark blotches.
        let continuous = ink.purpose == .highlight
        for (si, pts) in strokes.enumerated() {
            guard pts.count > 1, budget > 0 else { break }
            let len = lengths[si]
            var traveled: CGFloat = 0
            if continuous {
                ctx.setLineWidth(ink.width)
                ctx.move(to: pts[0])
            }
            for i in 1..<pts.count {
                let a = pts[i - 1], b = pts[i]
                let d = a.distance(to: b)
                if budget <= 0 { break }
                var end = b
                if d > budget {
                    let t = budget / d
                    end = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                }
                if continuous {
                    ctx.addLine(to: end)
                } else {
                    // Pen-like taper at both ends of each stroke.
                    let pos = len > 0 ? (traveled + d / 2) / len : 0.5
                    let taper = min(1, 0.55 + min(pos, 1 - pos) * 4.5)
                    ctx.setLineWidth(ink.width * taper)
                    ctx.move(to: a)
                    ctx.addLine(to: end)
                    ctx.strokePath()
                }
                traveled += d
                budget -= d
            }
            if continuous { ctx.strokePath() }
        }
        ctx.setBlendMode(.normal)
        if hasLabel, let label = ink.label, progress > inkShare {
            let labelProgress = (progress - inkShare) / (1 - inkShare)
            let f = NoteFonts.tutorFont(style: .handwriting, size: max(15, ink.width * 5.5), hand: env.hand)
            let off = ink.labelOffset ?? CGPoint(x: rect.width + 6, y: rect.height / 2 - f.lineHeight / 2)
            let l = richLayout(label, font: f, width: 260, rich: true)
            let visible = labelProgress >= 1 ? nil : Int(CGFloat(l.totalChars) * labelProgress)
            l.draw(in: ctx, origin: CGPoint(x: rect.minX + off.x, y: rect.minY + off.y), color: UIColor(hex: ink.colorHex), visibleChars: visible)
        }
    }

    // MARK: Graph

    static func graphPlotRect(_ rect: CGRect, _ g: GraphContent) -> CGRect {
        let top: CGFloat = (g.title?.isEmpty == false) ? 34 : 14
        return CGRect(x: rect.minX + 14, y: rect.minY + top, width: rect.width - 28, height: rect.height - top - 14)
    }

    static func graphMap(_ x: Double, _ y: Double, _ g: GraphContent, _ plot: CGRect) -> CGPoint {
        let px = plot.minX + CGFloat((x - g.xMin) / (g.xMax - g.xMin)) * plot.width
        let py = plot.maxY - CGFloat((y - g.yMin) / (g.yMax - g.yMin)) * plot.height
        return CGPoint(x: px, y: py)
    }

    static func niceStep(_ range: Double, targetTicks: Double = 10) -> Double {
        guard range > 0, range.isFinite else { return 1 }
        let raw = range / targetTicks
        let mag = pow(10, floor(log10(raw)))
        let norm = raw / mag
        let nice: Double = norm < 1.5 ? 1 : (norm < 3 ? 2 : (norm < 7 ? 5 : 10))
        return nice * mag
    }

    static func formatTick(_ v: Double, step: Double) -> String {
        let tol = abs(step) * 1e-6
        if abs(v) < tol { return "0" }
        if step >= 1 && abs(v - v.rounded()) < tol && abs(v) < 1e15 { return String(Int(v.rounded())) }
        // Enough decimals to show both the step and the value, e.g. 0.25, 2.5, -1.5 (number line
        // starting at a half), or π/2 ≈ 1.57.
        let decimals = (0...4).first { d in
            let scale = pow(10, Double(d))
            return abs(v * scale - (v * scale).rounded()) < tol * scale
                && abs(step * scale - (step * scale).rounded()) < tol * scale
        } ?? 2
        return String(format: "%.\(decimals)f", v)
    }

    static func drawGraph(_ g: GraphContent, rect: CGRect, progress: CGFloat, ctx: CGContext) {
        guard g.xMax > g.xMin, g.yMax > g.yMin else { return }
        let plot = graphPlotRect(rect, g)
        let axesAlpha = min(1, progress / 0.25)
        let dark = UIColor(hex: "#1F2328")

        // Background card.
        ctx.setFillColor(UIColor.white.withAlphaComponent(0.92 * axesAlpha).cgColor)
        ctx.addPath(UIBezierPath(roundedRect: rect, cornerRadius: 10).cgPath)
        ctx.fillPath()
        ctx.setStrokeColor(UIColor(hex: "#D0D7E2").withAlphaComponent(axesAlpha).cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(UIBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 10).cgPath)
        ctx.strokePath()

        if let title = g.title, !title.isEmpty {
            let f = NoteFonts.rounded(size: 15, weight: .semibold)
            let l = richLayout(title, font: f, width: rect.width - 28, rich: true)
            l.draw(in: ctx, origin: CGPoint(x: rect.minX + 14, y: rect.minY + 8), color: dark.withAlphaComponent(axesAlpha))
        }

        // A stored step that is non-positive or would draw hundreds of lines (and hang the tick
        // loops below) falls back to an automatic one.
        func usable(_ step: Double?, _ range: Double) -> Double? { step.flatMap { $0 > 0 && range / $0 <= 200 ? $0 : nil } }
        // Automatic steps aim for a labelled tick every ~55 pt, so small graphs don't crowd their axes.
        let xStep = usable(g.xStep, g.xMax - g.xMin) ?? niceStep(g.xMax - g.xMin, targetTicks: min(10, max(4, Double(plot.width) / 55)))
        let yStep = usable(g.yStep, g.yMax - g.yMin) ?? niceStep(g.yMax - g.yMin, targetTicks: min(10, max(4, Double(plot.height) / 45)))

        // Grid.
        if g.showGrid {
            ctx.setStrokeColor(UIColor(hex: "#E6EBF2").withAlphaComponent(axesAlpha).cgColor)
            ctx.setLineWidth(0.8)
            var x = ceil(g.xMin / xStep) * xStep
            while x <= g.xMax + xStep * 1e-6 {
                let p = graphMap(x, 0, g, plot)
                ctx.move(to: CGPoint(x: p.x, y: plot.minY))
                ctx.addLine(to: CGPoint(x: p.x, y: plot.maxY))
                x += xStep
            }
            var y = ceil(g.yMin / yStep) * yStep
            while y <= g.yMax + yStep * 1e-6 {
                let p = graphMap(0, y, g, plot)
                ctx.move(to: CGPoint(x: plot.minX, y: p.y))
                ctx.addLine(to: CGPoint(x: plot.maxX, y: p.y))
                y += yStep
            }
            ctx.strokePath()
        }

        // Axes (at zero when visible, otherwise along the edges).
        let axisX = (g.yMin...g.yMax).contains(0) ? graphMap(0, 0, g, plot).y : plot.maxY
        let axisY = (g.xMin...g.xMax).contains(0) ? graphMap(0, 0, g, plot).x : plot.minX
        ctx.setStrokeColor(dark.withAlphaComponent(axesAlpha).cgColor)
        ctx.setLineWidth(1.4)
        ctx.move(to: CGPoint(x: plot.minX, y: axisX))
        ctx.addLine(to: CGPoint(x: plot.maxX, y: axisX))
        ctx.move(to: CGPoint(x: axisY, y: plot.maxY))
        ctx.addLine(to: CGPoint(x: axisY, y: plot.minY))
        ctx.strokePath()
        // Arrow heads.
        ctx.setFillColor(dark.withAlphaComponent(axesAlpha).cgColor)
        let ah: CGFloat = 7
        ctx.move(to: CGPoint(x: plot.maxX + 2, y: axisX))
        ctx.addLine(to: CGPoint(x: plot.maxX - ah, y: axisX - ah * 0.55))
        ctx.addLine(to: CGPoint(x: plot.maxX - ah, y: axisX + ah * 0.55))
        ctx.closePath()
        ctx.move(to: CGPoint(x: axisY, y: plot.minY - 2))
        ctx.addLine(to: CGPoint(x: axisY - ah * 0.55, y: plot.minY + ah))
        ctx.addLine(to: CGPoint(x: axisY + ah * 0.55, y: plot.minY + ah))
        ctx.closePath()
        ctx.fillPath()

        UIGraphicsPushContext(ctx)
        let labelColor = UIColor(hex: "#57606A").withAlphaComponent(axesAlpha)
        let numFont = UIFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        if g.showNumbers {
            var x = ceil(g.xMin / xStep) * xStep
            while x <= g.xMax + xStep * 1e-6 {
                if abs(x) > xStep * 1e-6 {
                    let p = graphMap(x, 0, g, plot)
                    if p.x > plot.minX + 6 && p.x < plot.maxX - 10 {
                        let s = NSAttributedString(string: formatTick(x, step: xStep), attributes: [.font: numFont, .foregroundColor: labelColor])
                        let sz = s.size()
                        let ty = min(axisX + 3, plot.maxY - sz.height)
                        s.draw(at: CGPoint(x: p.x - sz.width / 2, y: ty))
                        ctx.setStrokeColor(dark.withAlphaComponent(axesAlpha).cgColor)
                        ctx.setLineWidth(1)
                        ctx.move(to: CGPoint(x: p.x, y: axisX - 3))
                        ctx.addLine(to: CGPoint(x: p.x, y: axisX + 3))
                        ctx.strokePath()
                    }
                }
                x += xStep
            }
            var y = ceil(g.yMin / yStep) * yStep
            while y <= g.yMax + yStep * 1e-6 {
                if abs(y) > yStep * 1e-6 {
                    let p = graphMap(0, y, g, plot)
                    if p.y > plot.minY + 10 && p.y < plot.maxY - 6 {
                        let s = NSAttributedString(string: formatTick(y, step: yStep), attributes: [.font: numFont, .foregroundColor: labelColor])
                        let sz = s.size()
                        let tx = max(plot.minX + 1, axisY - sz.width - 4)
                        s.draw(at: CGPoint(x: tx, y: p.y - sz.height / 2))
                        ctx.setStrokeColor(dark.withAlphaComponent(axesAlpha).cgColor)
                        ctx.setLineWidth(1)
                        ctx.move(to: CGPoint(x: axisY - 3, y: p.y))
                        ctx.addLine(to: CGPoint(x: axisY + 3, y: p.y))
                        ctx.strokePath()
                    }
                }
                y += yStep
            }
            if (g.xMin...g.xMax).contains(0) && (g.yMin...g.yMax).contains(0) {
                let s = NSAttributedString(string: "O", attributes: [.font: MathFonts.font(size: 11, italic: true), .foregroundColor: labelColor])
                s.draw(at: CGPoint(x: axisY - 12, y: axisX + 2))
            }
        }
        let axisFont = MathFonts.font(size: 15, italic: true)
        NSAttributedString(string: g.xLabel, attributes: [.font: axisFont, .foregroundColor: dark.withAlphaComponent(axesAlpha)])
            .draw(at: CGPoint(x: plot.maxX - 12, y: axisX - 24))
        NSAttributedString(string: g.yLabel, attributes: [.font: axisFont, .foregroundColor: dark.withAlphaComponent(axesAlpha)])
            .draw(at: CGPoint(x: axisY + 8, y: plot.minY - 4))
        UIGraphicsPopContext()

        guard progress > 0.2 else { return }
        let curveProgress = min(1, (progress - 0.2) / 0.7)

        ctx.saveGState()
        ctx.clip(to: plot)

        // Shaded regions.
        for shade in g.shadings {
            let upper = shade.upper.flatMap { try? ExpressionParser.parse($0) }
            let lower = shade.lower.flatMap { try? ExpressionParser.parse($0) }
            let from = max(g.xMin, min(shade.from, shade.to)), to = min(g.xMax, max(shade.from, shade.to))
            guard to > from else { continue }
            let n = 120
            let path = CGMutablePath()
            var top: [CGPoint] = []
            var bottom: [CGPoint] = []
            for i in 0...n {
                let x = from + (to - from) * Double(i) / Double(n)
                let yu = upper?.evaluate(x: x) ?? 0
                let yl = lower?.evaluate(x: x) ?? 0
                guard yu.isFinite, yl.isFinite else { continue }
                top.append(graphMap(x, min(max(yu, g.yMin - 1e3), g.yMax + 1e3), g, plot))
                bottom.append(graphMap(x, min(max(yl, g.yMin - 1e3), g.yMax + 1e3), g, plot))
            }
            guard let first = top.first else { continue }
            path.move(to: first)
            for p in top.dropFirst() { path.addLine(to: p) }
            for p in bottom.reversed() { path.addLine(to: p) }
            path.closeSubpath()
            ctx.addPath(path)
            ctx.setFillColor(UIColor(hex: shade.colorHex).withAlphaComponent(0.22 * curveProgress).cgColor)
            ctx.fillPath()
        }

        var labelPositions: [(String, CGPoint, String)] = []

        // Guide lines (asymptotes etc).
        for guide in g.guides {
            ctx.setStrokeColor(UIColor(hex: guide.colorHex).withAlphaComponent(curveProgress).cgColor)
            ctx.setLineWidth(1.3)
            if guide.dashed { ctx.setLineDash(phase: 0, lengths: [6, 5]) }
            let label = curveProgress >= 1 ? guide.label.flatMap { $0.isEmpty ? nil : $0 } : nil
            if let x = guide.x {
                let p = graphMap(x, 0, g, plot)
                ctx.move(to: CGPoint(x: p.x, y: plot.minY))
                ctx.addLine(to: CGPoint(x: p.x, y: plot.maxY))
                if let label, (g.xMin...g.xMax).contains(x) {
                    labelPositions.append((label, CGPoint(x: p.x, y: plot.minY + 4), guide.colorHex))
                }
            } else if let y = guide.y {
                let p = graphMap(0, y, g, plot)
                ctx.move(to: CGPoint(x: plot.minX, y: p.y))
                ctx.addLine(to: CGPoint(x: plot.maxX, y: p.y))
                if let label, (g.yMin...g.yMax).contains(y) {
                    labelPositions.append((label, CGPoint(x: plot.maxX - 4, y: p.y), guide.colorHex))
                }
            }
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }

        // Functions, drawn left to right.
        let nf = CGFloat(max(1, g.functions.count))
        for (fi, f) in g.functions.enumerated() {
            let fp = max(0, min(1, curveProgress * nf - CGFloat(fi)))
            guard fp > 0, let expr = try? ExpressionParser.parse(f.expression) else { continue }
            let domain: ClosedRange<Double>? = (f.domainMin != nil || f.domainMax != nil)
                ? (f.domainMin ?? g.xMin)...(max(f.domainMin ?? g.xMin, f.domainMax ?? g.xMax)) : nil
            let segments = FunctionSampler.sample(expr, xMin: g.xMin, xMax: g.xMax, yMin: g.yMin, yMax: g.yMax, domain: domain)
            let cutoffX = g.xMin + (g.xMax - g.xMin) * Double(fp)
            ctx.setStrokeColor(UIColor(hex: f.colorHex).cgColor)
            ctx.setLineWidth(2.4)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            if f.dashed { ctx.setLineDash(phase: 0, lengths: [8, 6]) }
            var lastVisible: CGPoint?
            for seg in segments {
                var started = false
                for p in seg where p.x <= cutoffX {
                    let q = graphMap(p.x, p.y, g, plot)
                    if !started { ctx.move(to: q); started = true } else { ctx.addLine(to: q) }
                    if plot.insetBy(dx: 4, dy: 4).contains(q) { lastVisible = q }
                }
                if started { ctx.strokePath() }
            }
            ctx.setLineDash(phase: 0, lengths: [])
            if fp >= 1, let label = f.label, !label.isEmpty, let lp = lastVisible {
                labelPositions.append((label, lp, f.colorHex))
            }
        }

        // Segments / vectors.
        for s in g.segments {
            let a = graphMap(s.x1, s.y1, g, plot), b = graphMap(s.x2, s.y2, g, plot)
            ctx.setStrokeColor(UIColor(hex: s.colorHex).withAlphaComponent(curveProgress).cgColor)
            ctx.setLineWidth(2)
            if s.dashed { ctx.setLineDash(phase: 0, lengths: [6, 5]) }
            ctx.move(to: a)
            ctx.addLine(to: b)
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            if s.arrow {
                drawArrowHead(at: b, from: a, size: 9, color: UIColor(hex: s.colorHex).withAlphaComponent(curveProgress), ctx: ctx)
            }
            if let label = s.label, !label.isEmpty, curveProgress >= 1 {
                labelPositions.append((label, CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), s.colorHex))
            }
        }
        ctx.restoreGState()

        // Points.
        if progress > 0.85 {
            let pointAlpha = min(1, (progress - 0.85) / 0.15)
            for pt in g.points {
                let q = graphMap(pt.x, pt.y, g, plot)
                guard plot.insetBy(dx: -6, dy: -6).contains(q) else { continue }
                let r: CGFloat = 4.5
                let c = UIColor(hex: pt.colorHex).withAlphaComponent(pointAlpha)
                let circle = CGRect(x: q.x - r, y: q.y - r, width: 2 * r, height: 2 * r)
                if pt.open {
                    ctx.setFillColor(UIColor.white.cgColor)
                    ctx.fillEllipse(in: circle)
                    ctx.setStrokeColor(c.cgColor)
                    ctx.setLineWidth(1.8)
                    ctx.strokeEllipse(in: circle)
                } else {
                    ctx.setFillColor(c.cgColor)
                    ctx.fillEllipse(in: circle)
                }
                if let label = pt.label, !label.isEmpty {
                    labelPositions.append((label, CGPoint(x: q.x + 6, y: q.y - 20), pt.colorHex))
                }
            }
        }

        // Labels last, on top of everything.
        let labelFont = NoteFonts.rounded(size: 13, weight: .medium)
        for (text, pos, hex) in labelPositions {
            let l = richLayout(text, font: labelFont, width: 220, rich: true)
            var origin = CGPoint(x: pos.x - l.size.width - 4, y: pos.y - l.size.height - 2)
            if origin.x < plot.minX { origin.x = pos.x + 6 }
            if origin.y < plot.minY { origin.y = pos.y + 4 }
            origin.x = min(origin.x, plot.maxX - l.size.width)
            let bg = CGRect(x: origin.x - 3, y: origin.y - 1, width: l.size.width + 6, height: l.size.height + 2)
            ctx.setFillColor(UIColor.white.withAlphaComponent(0.85).cgColor)
            ctx.addPath(UIBezierPath(roundedRect: bg, cornerRadius: 4).cgPath)
            ctx.fillPath()
            l.draw(in: ctx, origin: origin, color: UIColor(hex: hex))
        }
    }

    static func drawArrowHead(at tip: CGPoint, from: CGPoint, size: CGFloat, color: UIColor, ctx: CGContext) {
        let angle = atan2(tip.y - from.y, tip.x - from.x)
        let a1 = angle + .pi * 0.85, a2 = angle - .pi * 0.85
        ctx.setFillColor(color.cgColor)
        ctx.move(to: tip)
        ctx.addLine(to: CGPoint(x: tip.x + size * cos(a1), y: tip.y + size * sin(a1)))
        ctx.addLine(to: CGPoint(x: tip.x + size * cos(a2), y: tip.y + size * sin(a2)))
        ctx.closePath()
        ctx.fillPath()
    }

    // MARK: Number line

    static func drawNumberLine(_ n: NumberLineContent, rect: CGRect, progress: CGFloat, ctx: CGContext) {
        guard n.max > n.min, n.step > 0 else { return }
        let color = UIColor(hex: n.colorHex)
        let left = rect.minX + 16, right = rect.maxX - 16
        let axisY = rect.minY + rect.height * 0.55
        func px(_ v: Double) -> CGFloat { left + CGFloat((v - n.min) / (n.max - n.min)) * (right - left) }
        let drawRight = left + (right - left) * min(1, progress / 0.5)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(1.6)
        ctx.move(to: CGPoint(x: left - 10, y: axisY))
        ctx.addLine(to: CGPoint(x: drawRight + 10, y: axisY))
        ctx.strokePath()
        if progress >= 0.5 {
            drawArrowHead(at: CGPoint(x: right + 14, y: axisY), from: CGPoint(x: right, y: axisY), size: 8, color: color, ctx: ctx)
            drawArrowHead(at: CGPoint(x: left - 14, y: axisY), from: CGPoint(x: left, y: axisY), size: 8, color: color, ctx: ctx)
        }
        UIGraphicsPushContext(ctx)
        let f = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        var v = n.min
        var i = 0
        while v <= n.max + n.step * 1e-6 {
            let x = px(v)
            if x <= drawRight + 1 {
                ctx.setStrokeColor(color.cgColor)
                ctx.setLineWidth(1.2)
                ctx.move(to: CGPoint(x: x, y: axisY - 6))
                ctx.addLine(to: CGPoint(x: x, y: axisY + 6))
                ctx.strokePath()
                if i % max(1, n.labelEvery) == 0 {
                    let s = NSAttributedString(string: formatTick(v, step: n.step), attributes: [.font: f, .foregroundColor: UIColor(hex: "#57606A")])
                    let sz = s.size()
                    s.draw(at: CGPoint(x: x - sz.width / 2, y: axisY + 9))
                }
            }
            v += n.step
            i += 1
        }
        UIGraphicsPopContext()
        guard progress > 0.5 else { return }
        let alpha = min(1, (progress - 0.5) / 0.4)
        for interval in n.intervals {
            let c = UIColor(hex: interval.colorHex).withAlphaComponent(alpha)
            let x0 = interval.from.map(px) ?? left - 10
            let x1 = interval.to.map(px) ?? right + 10
            let y = axisY - 14
            ctx.setStrokeColor(c.cgColor)
            ctx.setLineWidth(4)
            ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: x0, y: y))
            ctx.addLine(to: CGPoint(x: x1, y: y))
            ctx.strokePath()
            if interval.from == nil { drawArrowHead(at: CGPoint(x: x0 - 6, y: y), from: CGPoint(x: x0 + 4, y: y), size: 9, color: c, ctx: ctx) }
            if interval.to == nil { drawArrowHead(at: CGPoint(x: x1 + 6, y: y), from: CGPoint(x: x1 - 4, y: y), size: 9, color: c, ctx: ctx) }
            for (x, open, exists) in [(x0, interval.openStart, interval.from != nil), (x1, interval.openEnd, interval.to != nil)] where exists {
                let r: CGFloat = 5.5
                let circle = CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)
                if open {
                    ctx.setFillColor(UIColor.white.cgColor)
                    ctx.fillEllipse(in: circle)
                    ctx.setLineWidth(2)
                    ctx.strokeEllipse(in: circle)
                } else {
                    ctx.setFillColor(c.cgColor)
                    ctx.fillEllipse(in: circle)
                }
            }
        }
        let labelFont = NoteFonts.rounded(size: 13, weight: .medium)
        for p in n.points {
            let c = UIColor(hex: p.colorHex).withAlphaComponent(alpha)
            let x = px(p.value)
            let r: CGFloat = 5.5
            let circle = CGRect(x: x - r, y: axisY - r, width: 2 * r, height: 2 * r)
            if p.open {
                ctx.setFillColor(UIColor.white.cgColor)
                ctx.fillEllipse(in: circle)
                ctx.setStrokeColor(c.cgColor)
                ctx.setLineWidth(2)
                ctx.strokeEllipse(in: circle)
            } else {
                ctx.setFillColor(c.cgColor)
                ctx.fillEllipse(in: circle)
            }
            if let label = p.label, !label.isEmpty {
                let l = richLayout(label, font: labelFont, width: 160, rich: true)
                l.draw(in: ctx, origin: CGPoint(x: x - l.size.width / 2, y: axisY - 30 - l.size.height + 8), color: c)
            }
        }
    }

    // MARK: Table

    static func drawTable(_ t: TableContent, rect: CGRect, progress: CGFloat, ctx: CGContext) {
        let widths = tableColumnWidths(t, maxWidth: rect.width)
        let heights = tableRowHeights(t, widths: widths)
        let font = NoteFonts.rounded(size: t.fontSize, weight: .regular)
        let headerFont = NoteFonts.rounded(size: t.fontSize, weight: .semibold)
        let color = UIColor(hex: t.colorHex)
        let visibleRows = Int(ceil(CGFloat(t.rows.count) * progress))
        let totalW = widths.reduce(0, +)
        var y = rect.minY
        let border = UIColor(hex: "#C9D1DC")
        for (i, row) in t.rows.enumerated() where i < visibleRows {
            let h = heights[i]
            if i == 0 && t.header {
                ctx.setFillColor(UIColor(hex: "#EEF2F8").cgColor)
                ctx.fill(CGRect(x: rect.minX, y: y, width: totalW, height: h))
            }
            var x = rect.minX
            for (j, cell) in row.enumerated() where j < widths.count {
                let l = richLayout(cell, font: (i == 0 && t.header) ? headerFont : font, width: widths[j] - 20, rich: true)
                l.draw(in: ctx, origin: CGPoint(x: x + (widths[j] - l.size.width) / 2, y: y + (h - l.size.height) / 2), color: color)
                x += widths[j]
            }
            ctx.setStrokeColor(border.cgColor)
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: rect.minX, y: y + h))
            ctx.addLine(to: CGPoint(x: rect.minX + totalW, y: y + h))
            ctx.strokePath()
            y += h
        }
        let shownHeight = y - rect.minY
        ctx.setStrokeColor(border.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: rect.minX, y: rect.minY, width: totalW, height: shownHeight))
        var x = rect.minX
        for w in widths.dropLast() {
            x += w
            ctx.move(to: CGPoint(x: x, y: rect.minY))
            ctx.addLine(to: CGPoint(x: x, y: rect.minY + shownHeight))
        }
        ctx.strokePath()
    }

    // MARK: Question card

    static func statusColor(_ s: QuestionStatus) -> UIColor {
        switch s {
        case .open: return UIColor(hex: "#57606A")
        case .correct: return UIColor(hex: "#2F9E44")
        case .incorrect: return UIColor(hex: "#E03131")
        case .partial: return UIColor(hex: "#F08C00")
        }
    }

    static func drawQuestion(_ q: QuestionContent, rect: CGRect, progress: CGFloat, env: RenderEnvironment, ctx: CGContext) {
        let tint = UIColor(hex: env.tutorHex)
        let cardAlpha = min(1, progress / 0.3)
        let card = UIBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerRadius: 14)
        ctx.setFillColor(tint.withAlphaComponent(0.045 * cardAlpha).cgColor)
        ctx.addPath(card.cgPath)
        ctx.fillPath()
        ctx.setStrokeColor(tint.withAlphaComponent(0.28 * cardAlpha).cgColor)
        ctx.setLineWidth(1.2)
        ctx.addPath(card.cgPath)
        ctx.strokePath()

        UIGraphicsPushContext(ctx)
        // Number badge.
        let badgeFont = NoteFonts.rounded(size: 15, weight: .bold)
        let badgeText = NSAttributedString(string: "Q\(q.number)", attributes: [.font: badgeFont, .foregroundColor: UIColor.white.withAlphaComponent(cardAlpha)])
        let bs = badgeText.size()
        let badge = CGRect(x: rect.minX + 14, y: rect.minY + 14, width: max(38, bs.width + 16), height: 28)
        ctx.setFillColor(tint.withAlphaComponent(cardAlpha).cgColor)
        ctx.addPath(UIBezierPath(roundedRect: badge, cornerRadius: 14).cgPath)
        ctx.fillPath()
        badgeText.draw(at: CGPoint(x: badge.midX - bs.width / 2, y: badge.midY - bs.height / 2))

        // Marks / status on the right.
        let metaFont = NoteFonts.rounded(size: 13, weight: .semibold)
        var metaText = "\(q.marks) mark\(q.marks == 1 ? "" : "s")"
        if q.status != .open {
            let symbol = q.status == .correct ? "✓" : (q.status == .incorrect ? "✗" : "◐")
            metaText = "\(symbol)  " + (q.score ?? metaText)
        }
        let meta = NSAttributedString(string: metaText, attributes: [.font: metaFont, .foregroundColor: statusColor(q.status).withAlphaComponent(cardAlpha)])
        let ms = meta.size()
        let pill = CGRect(x: rect.maxX - ms.width - 34, y: rect.minY + 16, width: ms.width + 20, height: 24)
        ctx.setFillColor(statusColor(q.status).withAlphaComponent(0.1 * cardAlpha).cgColor)
        ctx.addPath(UIBezierPath(roundedRect: pill, cornerRadius: 12).cgPath)
        ctx.fillPath()
        meta.draw(at: CGPoint(x: pill.midX - ms.width / 2, y: pill.midY - ms.height / 2))
        UIGraphicsPopContext()

        // Prompt text.
        let f = NoteFonts.tutorFont(style: .typed, size: 19, hand: env.hand)
        let promptRect = CGRect(x: rect.minX + 64, y: rect.minY + 17, width: rect.width - 64 - 96, height: q.promptHeight)
        let l = richLayout(q.prompt, font: f, width: promptRect.width, rich: true)
        let promptProgress = max(0, min(1, (progress - 0.15) / 0.75))
        let visible = promptProgress >= 1 ? nil : Int(CGFloat(l.totalChars) * promptProgress)
        if promptProgress > 0 {
            l.draw(in: ctx, origin: promptRect.origin, color: UIColor(hex: "#1F2328"), visibleChars: visible)
        }

        // Answer area.
        let answer = CGRect(x: rect.minX + 14, y: rect.minY + q.promptHeight, width: rect.width - 28, height: rect.height - q.promptHeight - 14)
        if answer.height > 20 && progress > 0.5 {
            let a = min(1, (progress - 0.5) / 0.4)
            ctx.setStrokeColor(tint.withAlphaComponent(0.25 * a).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [5, 5])
            ctx.addPath(UIBezierPath(roundedRect: answer, cornerRadius: 10).cgPath)
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            if !env.forSnapshot {
                UIGraphicsPushContext(ctx)
                let hint = NSAttributedString(string: "Answer", attributes: [.font: NoteFonts.rounded(size: 11, weight: .medium),
                                                                              .foregroundColor: tint.withAlphaComponent(0.45 * a)])
                hint.draw(at: CGPoint(x: answer.minX + 10, y: answer.minY + 6))
                UIGraphicsPopContext()
            }
        }
    }

    // MARK: Image

    static func drawImage(_ img: ImageContent, rect: CGRect, progress: CGFloat, env: RenderEnvironment, ctx: CGContext) {
        guard let image = env.image(img.assetID) else {
            ctx.setFillColor(UIColor(hex: "#EEF1F5").cgColor)
            ctx.fill(rect)
            return
        }
        UIGraphicsPushContext(ctx)
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 4)
        ctx.addPath(path.cgPath)
        ctx.clip()
        image.draw(in: rect, blendMode: .normal, alpha: progress)
        UIGraphicsPopContext()
    }
}
