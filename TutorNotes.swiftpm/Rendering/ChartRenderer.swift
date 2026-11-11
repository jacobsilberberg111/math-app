import UIKit

/// Draws ChartContent: column, bar, line, scatter and pie charts and climate graphs (rainfall
/// columns with a temperature line on twin axes), with title, axis titles, legend and source.
@MainActor
enum ChartRenderer {
    /// Where things go, in element coordinates.
    struct Layout {
        var plot: CGRect
        var titleOrigin: CGPoint
        var subtitleOrigin: CGPoint?
        var legendY: CGFloat?
        var footerY: CGFloat
        var y: ChartScale
        var y2: ChartScale?
        /// Scatter and numeric line charts.
        var x: ChartScale?
    }

    static let dark = UIColor(hex: "#1F2328")
    static let grey = UIColor(hex: "#57606A")
    static let gridColor = UIColor(hex: "#E3E8EF")

    static func font(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont { NoteFonts.sans(size: size, weight: weight) }

    static func textSize(_ s: String, _ f: UIFont) -> CGSize {
        let r = (s as NSString).size(withAttributes: [.font: f])
        return CGSize(width: ceil(r.width), height: ceil(r.height))
    }

    // MARK: Scales

    static func valueRange(_ c: ChartContent, right: Bool) -> (Double, Double)? {
        var lo = Double.infinity, hi = -Double.infinity
        for s in c.allSeries where s.onRight == right {
            for v in s.values ?? [] { if let v, v.isFinite { lo = min(lo, v); hi = max(hi, v) } }
            for p in s.xyPoints { lo = min(lo, p.y); hi = max(hi, p.y) }
        }
        return lo.isFinite ? (lo, hi) : nil
    }

    static func scales(_ c: ChartContent, plotHeight: CGFloat) -> (y: ChartScale, y2: ChartScale?, x: ChartScale?) {
        let maxTicks = max(3, min(8, Int(plotHeight / 38)))
        let kind = c.chartKind
        if kind == .climate {
            let t = valueRange(c, right: false) ?? (0, 30)
            var axes = ChartScale.climateAxes(tempMin: t.0, tempMax: t.1, rainMax: valueRange(c, right: true)?.1 ?? 100, maxTicks: maxTicks)
            if let lo = c.yMin { axes.temp.lo = lo }
            if let hi = c.yMax { axes.temp.hi = hi }
            return (axes.temp, axes.rain, nil)
        }
        let includeZero = kind == .bar || kind == .horizontalBar
        let leftRange = valueRange(c, right: false) ?? (0, 1)
        var y = ChartScale.nice(min: c.yMin ?? leftRange.0, max: c.yMax ?? leftRange.1, maxTicks: maxTicks, includeZero: includeZero)
        if let lo = c.yMin { y.lo = lo }
        if let hi = c.yMax { y.hi = hi }
        var y2: ChartScale?
        if let r = valueRange(c, right: true) { y2 = ChartScale.nice(min: r.0, max: r.1, maxTicks: maxTicks, includeZero: includeZero) }
        var x: ChartScale?
        if kind == .scatter || (kind == .line && c.allSeries.contains(where: { !($0.points ?? []).isEmpty })) {
            let xs = c.allSeries.flatMap { $0.xyPoints.map(\.x) }
            if let lo = xs.min(), let hi = xs.max() { x = ChartScale.nice(min: lo, max: hi, maxTicks: 8) }
        }
        return (y, y2, x)
    }

    static func layout(_ c: ChartContent, size: CGSize) -> Layout {
        let pad: CGFloat = 12
        var top = pad
        let titleOrigin = CGPoint(x: pad + 2, y: top)
        if let t = c.title, !t.isEmpty { top += textSize(t, font(15, .semibold)).height + 2 }
        var subtitleOrigin: CGPoint?
        if let st = c.subtitle, !st.isEmpty {
            subtitleOrigin = CGPoint(x: pad + 2, y: top)
            top += textSize(st, font(10.5)).height + 2
        }
        var legendY: CGFloat?
        let series = c.allSeries
        if c.chartKind != .pie && (series.count > 1 || c.chartKind == .climate || (c.chartKind == .scatter && c.bestFit == true)) {
            legendY = top + 4
            top += 22
        }
        top += 8
        var bottom = size.height - pad
        let captionFont = font(9.5)
        if let src = c.source, !src.isEmpty { bottom -= textSize(src, captionFont).height + 2 }
        if let note = c.note, !note.isEmpty { bottom -= textSize(note, font(10)).height + 2 }
        let footerY = bottom + 2
        bottom -= 6
        if c.chartKind == .pie {
            return Layout(plot: CGRect(x: pad, y: top, width: size.width - 2 * pad, height: max(40, bottom - top)), titleOrigin: titleOrigin,
                          subtitleOrigin: subtitleOrigin, legendY: nil, footerY: footerY, y: ChartScale(lo: 0, hi: 1, step: 1), y2: nil, x: nil)
        }
        let tickFont = UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let axisFont = font(11, .medium)
        // X labels and title.
        if c.xLabel?.isEmpty == false { bottom -= textSize("Ag", axisFont).height + 2 }
        bottom -= textSize("0", tickFont).height + 6
        let plotHeight = max(40, bottom - top)
        let sc = scales(c, plotHeight: plotHeight)
        var left = pad
        if c.yLabel?.isEmpty == false { left += textSize("Ag", axisFont).height + 4 }
        if c.chartKind == .horizontalBar {
            let w = (c.categories ?? []).map { textSize($0, font(10.5)).width }.max() ?? 30
            left += min(size.width * 0.35, w + 8)
        } else {
            let w = sc.y.ticks.map { textSize(ChartScale.label($0, step: sc.y.step), tickFont).width }.max() ?? 20
            left += w + 6
        }
        var right = size.width - pad - 6
        if let y2 = sc.y2 {
            let w = y2.ticks.filter { $0 >= 0 }.map { textSize(ChartScale.label($0, step: y2.step), tickFont).width }.max() ?? 20
            right -= w + 6
            if c.y2Label?.isEmpty == false { right -= textSize("Ag", axisFont).height + 4 }
        }
        let plot = CGRect(x: left, y: top, width: max(40, right - left), height: plotHeight)
        return Layout(plot: plot, titleOrigin: titleOrigin, subtitleOrigin: subtitleOrigin, legendY: legendY, footerY: footerY,
                      y: sc.y, y2: sc.y2, x: sc.x)
    }

    // MARK: Drawing

    static func draw(_ c: ChartContent, rect: CGRect, progress: CGFloat, env: RenderEnvironment, ctx: CGContext) {
        let chromeAlpha = min(1, progress / 0.25)
        ctx.setFillColor(UIColor.white.withAlphaComponent(0.96 * chromeAlpha).cgColor)
        ctx.addPath(UIBezierPath(roundedRect: rect, cornerRadius: 10).cgPath)
        ctx.fillPath()
        ctx.setStrokeColor(UIColor(hex: "#D0D7E2").withAlphaComponent(chromeAlpha).cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(UIBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 10).cgPath)
        ctx.strokePath()
        guard rect.width > 80, rect.height > 80 else { return }

        let L = layout(c, size: rect.size)
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        UIGraphicsPushContext(ctx)
        defer {
            UIGraphicsPopContext()
            ctx.restoreGState()
        }
        let a = chromeAlpha
        if let t = c.title, !t.isEmpty {
            let l = ElementRenderer.richLayout(t, font: font(15, .semibold), width: rect.width - 24, rich: true)
            l.draw(in: ctx, origin: L.titleOrigin, color: dark.withAlphaComponent(a))
        }
        if let st = c.subtitle, !st.isEmpty, let o = L.subtitleOrigin {
            NSAttributedString(string: st, attributes: [.font: font(10.5), .foregroundColor: grey.withAlphaComponent(a)]).draw(at: o)
        }
        let dataP = max(0, min(1, (progress - 0.15) / 0.75))
        switch c.chartKind {
        case .pie: drawPie(c, L, progress: dataP, alpha: a, ctx: ctx)
        case .horizontalBar: drawHorizontalBars(c, L, progress: dataP, alpha: a, ctx: ctx)
        default: drawXY(c, L, progress: dataP, alpha: a, ctx: ctx)
        }
        if let ly = L.legendY { drawLegend(c, y: ly, width: rect.width, alpha: a, ctx: ctx) }
        var fy = L.footerY
        if let note = c.note, !note.isEmpty {
            let s = NSAttributedString(string: note, attributes: [.font: font(10, .medium), .foregroundColor: dark.withAlphaComponent(0.85 * a)])
            s.draw(at: CGPoint(x: 14, y: fy))
            fy += s.size().height + 2
        }
        if let src = c.source, !src.isEmpty {
            let s = NSAttributedString(string: src, attributes: [.font: UIFont.italicSystemFont(ofSize: 9.5), .foregroundColor: grey.withAlphaComponent(a)])
            let w = min(s.size().width, rect.width - 28)
            s.draw(in: CGRect(x: rect.width - 14 - w, y: fy, width: w + 2, height: s.size().height + 2))
        }
    }

    private static func color(_ s: ChartSeries, _ i: Int) -> UIColor { UIColor(hex: s.colorHex ?? ChartPalette.color(i)) }

    private static func drawLegend(_ c: ChartContent, y: CGFloat, width: CGFloat, alpha: CGFloat, ctx: CGContext) {
        var x: CGFloat = 14
        let f = font(10.5)
        var items: [(String, UIColor, String)] = c.allSeries.enumerated().map { ($1.name, color($1, $0), $1.style ?? (c.chartKind == .scatter ? "dot" : (c.chartKind == .line ? "line" : "bar"))) }
        if c.chartKind == .scatter && c.bestFit == true, let s = c.allSeries.first, let fit = ChartFit.leastSquares(s.xyPoints) {
            items.append(("Line of best fit: \(fit.equation)", color(s, 0), "line"))
        }
        for (name, col, style) in items {
            let ts = textSize(name, f)
            if x + 22 + ts.width > width - 12 && x > 14 { break }
            let mid = y + 7
            ctx.setFillColor(col.withAlphaComponent(alpha).cgColor)
            ctx.setStrokeColor(col.withAlphaComponent(alpha).cgColor)
            switch style {
            case "line", "dashed":
                ctx.setLineWidth(2.2)
                if style == "dashed" { ctx.setLineDash(phase: 0, lengths: [4, 3]) }
                ctx.move(to: CGPoint(x: x, y: mid))
                ctx.addLine(to: CGPoint(x: x + 16, y: mid))
                ctx.strokePath()
                ctx.setLineDash(phase: 0, lengths: [])
            case "dot":
                ctx.fillEllipse(in: CGRect(x: x + 4, y: mid - 4, width: 8, height: 8))
            default:
                ctx.fill(CGRect(x: x + 1, y: mid - 5, width: 14, height: 10))
            }
            NSAttributedString(string: name, attributes: [.font: f, .foregroundColor: dark.withAlphaComponent(alpha)]).draw(at: CGPoint(x: x + 20, y: mid - ts.height / 2))
            x += 20 + ts.width + 14
        }
    }

    /// Y position of a value on a scale.
    private static func yPos(_ v: Double, _ s: ChartScale, _ plot: CGRect) -> CGFloat {
        plot.maxY - CGFloat(s.fraction(v)) * plot.height
    }

    private static func drawAxesGrid(_ c: ChartContent, _ L: Layout, alpha: CGFloat, ctx: CGContext) {
        let plot = L.plot
        let tickFont = UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        ctx.setStrokeColor(gridColor.withAlphaComponent(alpha).cgColor)
        ctx.setLineWidth(0.8)
        for t in L.y.ticks {
            let y = yPos(t, L.y, plot)
            ctx.move(to: CGPoint(x: plot.minX, y: y))
            ctx.addLine(to: CGPoint(x: plot.maxX, y: y))
        }
        ctx.strokePath()
        let tempColor = c.chartKind == .climate ? UIColor(hex: ChartPalette.temp) : grey
        for t in L.y.ticks {
            let y = yPos(t, L.y, plot)
            let s = NSAttributedString(string: ChartScale.label(t, step: L.y.step), attributes: [.font: tickFont, .foregroundColor: tempColor.withAlphaComponent(alpha)])
            let sz = s.size()
            s.draw(at: CGPoint(x: plot.minX - sz.width - 5, y: y - sz.height / 2))
        }
        if let y2 = L.y2 {
            let rainColor = c.chartKind == .climate ? UIColor(hex: ChartPalette.rain) : grey
            for t in y2.ticks where t >= 0 {
                let y = yPos(t, y2, plot)
                let s = NSAttributedString(string: ChartScale.label(t, step: y2.step), attributes: [.font: tickFont, .foregroundColor: rainColor.withAlphaComponent(alpha)])
                s.draw(at: CGPoint(x: plot.maxX + 5, y: y - s.size().height / 2))
            }
        }
        // Axis lines: the x axis at zero when it's in range.
        ctx.setStrokeColor(dark.withAlphaComponent(0.8 * alpha).cgColor)
        ctx.setLineWidth(1.1)
        let zeroY = (L.y.lo <= 0 && 0 <= L.y.hi) ? yPos(0, L.y, plot) : plot.maxY
        ctx.move(to: CGPoint(x: plot.minX, y: zeroY))
        ctx.addLine(to: CGPoint(x: plot.maxX, y: zeroY))
        ctx.move(to: CGPoint(x: plot.minX, y: plot.minY))
        ctx.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
        if L.y2 != nil {
            ctx.move(to: CGPoint(x: plot.maxX, y: plot.minY))
            ctx.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        }
        ctx.strokePath()
        // Axis titles.
        let axisFont = font(11, .medium)
        if let yl = c.yLabel, !yl.isEmpty {
            drawRotated(yl, font: axisFont, color: (c.chartKind == .climate ? UIColor(hex: ChartPalette.temp) : dark).withAlphaComponent(alpha),
                        center: CGPoint(x: 12 + textSize("Ag", axisFont).height / 2, y: plot.midY), angle: -.pi / 2, ctx: ctx)
        }
        if let y2l = c.y2Label, !y2l.isEmpty, let y2 = L.y2 {
            let w = y2.ticks.filter { $0 >= 0 }.map { textSize(ChartScale.label($0, step: y2.step), tickFont).width }.max() ?? 20
            drawRotated(y2l, font: axisFont, color: (c.chartKind == .climate ? UIColor(hex: ChartPalette.rain) : dark).withAlphaComponent(alpha),
                        center: CGPoint(x: plot.maxX + w + 12 + textSize("Ag", axisFont).height / 2, y: plot.midY), angle: .pi / 2, ctx: ctx)
        }
        if let xl = c.xLabel, !xl.isEmpty {
            let s = NSAttributedString(string: xl, attributes: [.font: axisFont, .foregroundColor: dark.withAlphaComponent(alpha)])
            let sz = s.size()
            s.draw(at: CGPoint(x: plot.midX - sz.width / 2, y: plot.maxY + textSize("0", tickFont).height + 6))
        }
    }

    private static func drawRotated(_ text: String, font: UIFont, color: UIColor, center: CGPoint, angle: CGFloat, ctx: CGContext) {
        let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let sz = s.size()
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: angle)
        s.draw(at: CGPoint(x: -sz.width / 2, y: -sz.height / 2))
        ctx.restoreGState()
    }

    /// Column, line, scatter and climate charts.
    private static func drawXY(_ c: ChartContent, _ L: Layout, progress: CGFloat, alpha: CGFloat, ctx: CGContext) {
        let plot = L.plot
        drawAxesGrid(c, L, alpha: alpha, ctx: ctx)
        let tickFont = UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let cats = c.categories ?? []
        let series = c.allSeries
        let n = max(1, cats.count, series.map { $0.values?.count ?? 0 }.max() ?? 0)
        let slot = plot.width / CGFloat(n)
        func catX(_ i: Int) -> CGFloat { plot.minX + slot * (CGFloat(i) + 0.5) }

        // Numeric x axis (scatter / numeric lines) or category labels.
        if let xs = L.x {
            for t in xs.ticks {
                let x = plot.minX + CGFloat(xs.fraction(t)) * plot.width
                let s = NSAttributedString(string: ChartScale.label(t, step: xs.step), attributes: [.font: tickFont, .foregroundColor: grey.withAlphaComponent(alpha)])
                let sz = s.size()
                s.draw(at: CGPoint(x: x - sz.width / 2, y: plot.maxY + 4))
                ctx.setStrokeColor(gridColor.withAlphaComponent(alpha).cgColor)
                ctx.setLineWidth(0.8)
                ctx.move(to: CGPoint(x: x, y: plot.minY))
                ctx.addLine(to: CGPoint(x: x, y: plot.maxY))
                ctx.strokePath()
            }
        } else {
            let f = font(cats.count > 16 ? 8.5 : 10)
            let every = max(1, Int(ceil(Double(cats.map { textSize($0, f).width + 4 }.max() ?? 10) / Double(slot))))
            for (i, cat) in cats.enumerated() where i % every == 0 {
                let s = NSAttributedString(string: cat, attributes: [.font: f, .foregroundColor: dark.withAlphaComponent(alpha)])
                let sz = s.size()
                s.draw(at: CGPoint(x: catX(i) - sz.width / 2, y: plot.maxY + 4))
            }
        }

        // Bars first (climate rainfall, column charts), then lines and points.
        let barSeries = series.enumerated().filter { _, s in
            s.style == "bar" || (s.style == nil && c.chartKind == .bar) || (c.chartKind == .climate && s.onRight && s.style != "line")
        }
        if !barSeries.isEmpty {
            let groupW = slot * (barSeries.count == 1 ? 0.62 : 0.78)
            let barW = groupW / CGFloat(barSeries.count)
            for (j, (i, s)) in barSeries.enumerated() {
                let scale = s.onRight ? (L.y2 ?? L.y) : L.y
                let zero = yPos(max(scale.lo, min(scale.hi, 0)), scale, plot)
                let col = color(s, i)
                for (k, v) in (s.values ?? []).enumerated() {
                    guard let v, v.isFinite else { continue }
                    let reveal = max(0, min(1, progress * CGFloat(n) * 0.8 - CGFloat(k) * 0.6))
                    guard reveal > 0 else { continue }
                    let top = yPos(max(scale.lo, min(scale.hi, v)), scale, plot)
                    let h = (top - zero) * reveal
                    let x = catX(k) - groupW / 2 + barW * CGFloat(j)
                    let r = CGRect(x: x + 0.5, y: zero + h, width: barW - 1, height: -h).standardized
                    ctx.setFillColor(col.withAlphaComponent(0.85 * alpha).cgColor)
                    ctx.fill(r)
                    if c.showValues == true && reveal >= 1 {
                        let s = NSAttributedString(string: GeoFormat.value(v), attributes: [.font: font(8.5), .foregroundColor: dark.withAlphaComponent(alpha)])
                        let sz = s.size()
                        s.draw(at: CGPoint(x: x + barW / 2 - sz.width / 2, y: (v >= 0 ? r.minY - sz.height - 1 : r.maxY + 1)))
                    }
                }
            }
        }
        ctx.saveGState()
        ctx.clip(to: plot.insetBy(dx: -6, dy: -6))
        for (i, s) in series.enumerated() {
            let isBar = barSeries.contains { $0.offset == i }
            if isBar { continue }
            let scale = s.onRight ? (L.y2 ?? L.y) : L.y
            let col = color(s, i)
            var pts: [CGPoint] = []
            if let xs = L.x, !(s.points ?? []).isEmpty {
                pts = s.xyPoints.map { CGPoint(x: plot.minX + CGFloat(xs.fraction($0.x)) * plot.width, y: yPos($0.y, scale, plot)) }
            } else {
                for (k, v) in (s.values ?? []).enumerated() { if let v, v.isFinite { pts.append(CGPoint(x: catX(k), y: yPos(v, scale, plot))) } }
            }
            let shown = Int(ceil(CGFloat(pts.count) * progress))
            let visible = Array(pts.prefix(shown))
            if c.chartKind == .scatter {
                for p in visible {
                    ctx.setFillColor(col.withAlphaComponent(0.9 * alpha).cgColor)
                    ctx.fillEllipse(in: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7))
                }
                continue
            }
            guard visible.count >= 1 else { continue }
            ctx.setStrokeColor(col.withAlphaComponent(alpha).cgColor)
            let dashed = s.style == "dashed"
            ctx.setLineWidth(dashed ? 1.4 : 2.4)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            if dashed { ctx.setLineDash(phase: 0, lengths: [5, 4]) }
            ctx.move(to: visible[0])
            for p in visible.dropFirst() { ctx.addLine(to: p) }
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            if !dashed && pts.count <= 40 {
                for p in visible {
                    ctx.setFillColor(UIColor.white.withAlphaComponent(alpha).cgColor)
                    ctx.fillEllipse(in: CGRect(x: p.x - 3.2, y: p.y - 3.2, width: 6.4, height: 6.4))
                    ctx.setFillColor(col.withAlphaComponent(alpha).cgColor)
                    ctx.fillEllipse(in: CGRect(x: p.x - 2.2, y: p.y - 2.2, width: 4.4, height: 4.4))
                }
            }
        }
        // Line of best fit.
        if c.chartKind == .scatter, c.bestFit == true, progress >= 1, let s = series.first, let fit = ChartFit.leastSquares(s.xyPoints), let xs = L.x {
            let x0 = xs.lo, x1 = xs.hi
            let p0 = CGPoint(x: plot.minX, y: yPos(fit.slope * x0 + fit.intercept, L.y, plot))
            let p1 = CGPoint(x: plot.maxX, y: yPos(fit.slope * x1 + fit.intercept, L.y, plot))
            ctx.setStrokeColor(color(s, 0).withAlphaComponent(0.8 * alpha).cgColor)
            ctx.setLineWidth(1.6)
            ctx.setLineDash(phase: 0, lengths: [6, 4])
            ctx.move(to: p0)
            ctx.addLine(to: p1)
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }
        ctx.restoreGState()
    }

    private static func drawHorizontalBars(_ c: ChartContent, _ L: Layout, progress: CGFloat, alpha: CGFloat, ctx: CGContext) {
        let plot = L.plot
        let cats = c.categories ?? []
        let series = c.allSeries
        let n = max(1, cats.count, series.map { $0.values?.count ?? 0 }.max() ?? 0)
        let slot = plot.height / CGFloat(n)
        let scale = L.y
        func xPos(_ v: Double) -> CGFloat { plot.minX + CGFloat(scale.fraction(v)) * plot.width }
        let tickFont = UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        ctx.setStrokeColor(gridColor.withAlphaComponent(alpha).cgColor)
        ctx.setLineWidth(0.8)
        for t in scale.ticks {
            ctx.move(to: CGPoint(x: xPos(t), y: plot.minY))
            ctx.addLine(to: CGPoint(x: xPos(t), y: plot.maxY))
        }
        ctx.strokePath()
        for t in scale.ticks {
            let s = NSAttributedString(string: ChartScale.label(t, step: scale.step), attributes: [.font: tickFont, .foregroundColor: grey.withAlphaComponent(alpha)])
            let sz = s.size()
            s.draw(at: CGPoint(x: xPos(t) - sz.width / 2, y: plot.maxY + 4))
        }
        let zeroX = xPos(max(scale.lo, min(scale.hi, 0)))
        ctx.setStrokeColor(dark.withAlphaComponent(0.8 * alpha).cgColor)
        ctx.setLineWidth(1.1)
        ctx.move(to: CGPoint(x: zeroX, y: plot.minY))
        ctx.addLine(to: CGPoint(x: zeroX, y: plot.maxY))
        ctx.strokePath()
        let f = font(10.5)
        for (i, cat) in cats.enumerated() {
            let s = NSAttributedString(string: cat, attributes: [.font: f, .foregroundColor: dark.withAlphaComponent(alpha)])
            let sz = s.size()
            s.draw(in: CGRect(x: 12 + (c.yLabel?.isEmpty == false ? 16 : 0), y: plot.minY + slot * (CGFloat(i) + 0.5) - sz.height / 2,
                              width: plot.minX - 18 - (c.yLabel?.isEmpty == false ? 16 : 0), height: sz.height + 1))
        }
        let groupH = slot * (series.count == 1 ? 0.62 : 0.78)
        let barH = groupH / CGFloat(max(1, series.count))
        for (j, s) in series.enumerated() {
            let col = color(s, j)
            for (k, v) in (s.values ?? []).enumerated() {
                guard let v, v.isFinite else { continue }
                let reveal = max(0, min(1, progress * CGFloat(n) * 0.8 - CGFloat(k) * 0.6))
                guard reveal > 0 else { continue }
                let end = zeroX + (xPos(max(scale.lo, min(scale.hi, v))) - zeroX) * reveal
                let y = plot.minY + slot * CGFloat(k) + (slot - groupH) / 2 + barH * CGFloat(j)
                let r = CGRect(x: min(zeroX, end), y: y + 0.5, width: abs(end - zeroX), height: barH - 1)
                ctx.setFillColor(col.withAlphaComponent(0.85 * alpha).cgColor)
                ctx.fill(r)
                if c.showValues == true && reveal >= 1 {
                    let t = NSAttributedString(string: GeoFormat.value(v), attributes: [.font: font(8.5), .foregroundColor: dark.withAlphaComponent(alpha)])
                    let sz = t.size()
                    t.draw(at: CGPoint(x: v >= 0 ? r.maxX + 3 : r.minX - sz.width - 3, y: r.midY - sz.height / 2))
                }
            }
        }
        if let xl = c.xLabel, !xl.isEmpty {
            let s = NSAttributedString(string: xl, attributes: [.font: font(11, .medium), .foregroundColor: dark.withAlphaComponent(alpha)])
            let sz = s.size()
            s.draw(at: CGPoint(x: plot.midX - sz.width / 2, y: plot.maxY + textSize("0", tickFont).height + 6))
        }
        if let yl = c.yLabel, !yl.isEmpty {
            drawRotated(yl, font: font(11, .medium), color: dark.withAlphaComponent(alpha), center: CGPoint(x: 18, y: plot.midY), angle: -.pi / 2, ctx: ctx)
        }
    }

    private static func drawPie(_ c: ChartContent, _ L: Layout, progress: CGFloat, alpha: CGFloat, ctx: CGContext) {
        guard let s = c.allSeries.first else { return }
        let values = (s.values ?? []).map { $0 ?? 0 }
        let slices = ChartPie.slices(values)
        guard !slices.isEmpty else { return }
        let cats = c.categories ?? []
        let area = L.plot
        let legendW = min(area.width * 0.45, (cats.map { textSize($0 + "  100%", font(10.5)).width }.max() ?? 80) + 24)
        let radius = max(10, min((area.width - legendW) / 2 - 10, area.height / 2 - 6))
        let center = CGPoint(x: area.minX + radius + 8, y: area.midY)
        let sweepEnd = CGFloat(2 * Double.pi) * progress
        for (i, sl) in slices.enumerated() {
            let start = CGFloat(sl.start), end = min(CGFloat(sl.end), sweepEnd)
            guard end > start else { continue }
            let col = UIColor(hex: ChartPalette.color(i))
            ctx.setFillColor(col.withAlphaComponent(0.88 * alpha).cgColor)
            ctx.move(to: center)
            // Angles measured clockwise from 12 o'clock; Core Graphics measures from 3 o'clock with y down.
            ctx.addArc(center: center, radius: radius, startAngle: start - .pi / 2, endAngle: end - .pi / 2, clockwise: false)
            ctx.closePath()
            ctx.fillPath()
            ctx.setStrokeColor(UIColor.white.withAlphaComponent(alpha).cgColor)
            ctx.setLineWidth(1.5)
            ctx.move(to: center)
            ctx.addArc(center: center, radius: radius, startAngle: start - .pi / 2, endAngle: end - .pi / 2, clockwise: false)
            ctx.closePath()
            ctx.strokePath()
            // Percentage inside big slices.
            if progress >= 1 && sl.percent >= 6 {
                let mid = CGFloat((sl.start + sl.end) / 2) - .pi / 2
                let p = CGPoint(x: center.x + cos(mid) * radius * 0.65, y: center.y + sin(mid) * radius * 0.65)
                let t = NSAttributedString(string: "\(GeoFormat.trim(sl.percent, sl.percent < 10 ? 1 : 0))%", attributes: [.font: font(10, .semibold), .foregroundColor: UIColor.white])
                let sz = t.size()
                t.draw(at: CGPoint(x: p.x - sz.width / 2, y: p.y - sz.height / 2))
            }
        }
        // Legend on the right.
        var y = max(area.minY, center.y - CGFloat(cats.count) * 9)
        let x = center.x + radius + 18
        for (i, cat) in cats.enumerated() where i < slices.count {
            ctx.setFillColor(UIColor(hex: ChartPalette.color(i)).withAlphaComponent(alpha).cgColor)
            ctx.fill(CGRect(x: x, y: y + 3, width: 11, height: 11))
            let t = NSAttributedString(string: "\(cat)  \(GeoFormat.trim(slices[i].percent, 1))%", attributes: [.font: font(10.5), .foregroundColor: dark.withAlphaComponent(alpha)])
            t.draw(at: CGPoint(x: x + 16, y: y + 8.5 - t.size().height / 2))
            y += 18
        }
    }

    // MARK: Tutor description

    static func tutorDescription(_ c: ChartContent, frame: CGRect) -> String {
        var s = "\(c.chartKind.displayName.lowercased())\(c.title.map { " \"\($0)\"" } ?? "")."
        if let st = c.subtitle { s += " \(st)." }
        if let yl = c.yLabel { s += " y: \(yl)" + (c.y2Label.map { "; right axis: \($0)" } ?? "") + "." }
        if let xl = c.xLabel { s += " x: \(xl)." }
        s += " " + ChartSummary.text(c)
        if let note = c.note { s += ". \(note)" }
        if let src = c.source { s += ". \(src)" }
        if c.chartKind != .pie {
            let L = layout(c, size: frame.size)
            let plot = L.plot.offsetBy(dx: frame.minX, dy: frame.minY)
            s += ". Plot area on the page \(plot.roundedForDisplay); left axis \(GeoFormat.value(L.y.lo))…\(GeoFormat.value(L.y.hi)) from y=\(Int(plot.maxY)) up to y=\(Int(plot.minY))"
            if let y2 = L.y2 { s += ", right axis \(GeoFormat.value(max(0, y2.lo)))…\(GeoFormat.value(y2.hi))" }
            if c.chartKind != .scatter && c.chartKind != .horizontalBar, let cats = c.categories, !cats.isEmpty {
                let slot = plot.width / CGFloat(max(1, cats.count))
                s += "; category i (from 0) is centred at x = \(Int(plot.minX)) + \(GeoFormat.trim(Double(slot), 1))·(i + 0.5)"
            }
            if let xs = L.x { s += "; x axis \(GeoFormat.value(xs.lo))…\(GeoFormat.value(xs.hi)) from x=\(Int(plot.minX)) to x=\(Int(plot.maxX))" }
        }
        return s + "."
    }
}
