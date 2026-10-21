import UIKit

/// Paper patterns (ruled, grid, dots...) built as vector paths, shared by the on-screen page views
/// and by PDF export / tutor snapshots.
enum PaperRenderer {
    struct PatternPaths {
        var light: CGPath?
        var strong: CGPath?
        var dots: CGPath?
        var accent: CGPath?
    }

    static func spacing(for pattern: PaperPattern) -> CGFloat {
        switch pattern {
        case .ruled, .cornell: return 30
        case .narrowRuled: return 24
        case .grid: return 32
        case .smallGrid, .graph: return 16
        case .dots: return 24
        case .blank: return 0
        }
    }

    static func patternPaths(_ pattern: PaperPattern, size: CGSize) -> PatternPaths {
        var result = PatternPaths()
        let s = spacing(for: pattern)
        switch pattern {
        case .blank:
            break
        case .ruled, .narrowRuled, .cornell:
            let lines = CGMutablePath()
            var y: CGFloat = 96
            let bottomLimit = pattern == .cornell ? size.height - 190 : size.height - 40
            while y < bottomLimit {
                lines.move(to: CGPoint(x: 0, y: y))
                lines.addLine(to: CGPoint(x: size.width, y: y))
                y += s
            }
            result.light = lines
            let accent = CGMutablePath()
            if pattern == .cornell {
                accent.move(to: CGPoint(x: 210, y: 66))
                accent.addLine(to: CGPoint(x: 210, y: size.height - 190))
                accent.move(to: CGPoint(x: 0, y: size.height - 190))
                accent.addLine(to: CGPoint(x: size.width, y: size.height - 190))
                accent.move(to: CGPoint(x: 0, y: 66))
                accent.addLine(to: CGPoint(x: size.width, y: 66))
            } else {
                accent.move(to: CGPoint(x: 88, y: 0))
                accent.addLine(to: CGPoint(x: 88, y: size.height))
            }
            result.accent = accent
        case .grid, .smallGrid, .graph:
            let light = CGMutablePath()
            let strong = CGMutablePath()
            let strongEvery = pattern == .graph ? 5 : (pattern == .smallGrid ? 4 : 0)
            var i = 0
            var x: CGFloat = 0
            while x <= size.width + 0.5 {
                let p = (strongEvery > 0 && i % strongEvery == 0) ? strong : light
                p.move(to: CGPoint(x: x, y: 0))
                p.addLine(to: CGPoint(x: x, y: size.height))
                x += s
                i += 1
            }
            i = 0
            var y: CGFloat = 0
            while y <= size.height + 0.5 {
                let p = (strongEvery > 0 && i % strongEvery == 0) ? strong : light
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: size.width, y: y))
                y += s
                i += 1
            }
            result.light = light
            if strongEvery > 0 { result.strong = strong }
        case .dots:
            let dots = CGMutablePath()
            var y = s
            while y < size.height {
                var x = s
                while x < size.width {
                    dots.addEllipse(in: CGRect(x: x - 1.1, y: y - 1.1, width: 2.2, height: 2.2))
                    x += s
                }
                y += s
            }
            result.dots = dots
        }
        return result
    }

    static func lineColor(_ paper: PaperStyle) -> UIColor { UIColor(hex: paper.color.lineHex) }

    static func accentColor(_ paper: PaperStyle) -> UIColor {
        paper.pattern == .cornell ? UIColor(hex: "#9AA8BD") : UIColor(hex: "#F0A3A3")
    }

    /// Draws a full page (paper colour, pattern, PDF background) into `rect` of `ctx`.
    static func drawPage(_ page: Page, size: CGSize, in rect: CGRect, ctx: CGContext, pdf: CGPDFDocument?, patternAlpha: CGFloat = 1) {
        ctx.saveGState()
        ctx.setFillColor(UIColor(hex: page.paper.color.hex).cgColor)
        ctx.fill(rect)
        if let pdf, let idx = page.pdfPageIndex, let pdfPage = pdf.page(at: idx + 1) {
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(rect)
            drawPDFPage(pdfPage, in: rect, ctx: ctx)
        }
        let paths = patternPaths(page.paper.pattern, size: size)
        let sx = rect.width / size.width, sy = rect.height / size.height
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: sx, y: sy)
        let lw = 0.75 / max(sx, 0.01)
        if let light = paths.light {
            ctx.addPath(light)
            ctx.setStrokeColor(lineColor(page.paper).withAlphaComponent(0.9 * patternAlpha).cgColor)
            ctx.setLineWidth(lw)
            ctx.strokePath()
        }
        if let strong = paths.strong {
            ctx.addPath(strong)
            ctx.setStrokeColor(lineColor(page.paper).withAlphaComponent(patternAlpha).cgColor)
            ctx.setLineWidth(lw * 1.8)
            ctx.strokePath()
        }
        if let dots = paths.dots {
            ctx.addPath(dots)
            ctx.setFillColor(lineColor(page.paper).withAlphaComponent(patternAlpha).cgColor)
            ctx.fillPath()
        }
        if let accent = paths.accent {
            ctx.addPath(accent)
            ctx.setStrokeColor(accentColor(page.paper).withAlphaComponent(patternAlpha).cgColor)
            ctx.setLineWidth(lw * 1.3)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    /// Draws a PDF page aspect-fit into a UIKit (y-down) rect, honouring the page's rotation.
    static func drawPDFPage(_ page: CGPDFPage, in rect: CGRect, ctx: CGContext) {
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return }
        let rotated = page.rotationAngle % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
        let scale = min(rect.width / rotated.width, rect.height / rotated.height)
        let drawSize = CGSize(width: rotated.width * scale, height: rotated.height * scale)
        let origin = CGPoint(x: rect.midX - drawSize.width / 2, y: rect.midY - drawSize.height / 2)
        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y + drawSize.height)
        ctx.scaleBy(x: scale, y: -scale)
        let t = page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: rotated), rotate: 0, preserveAspectRatio: true)
        ctx.concatenate(t)
        ctx.interpolationQuality = .high
        ctx.setRenderingIntent(.defaultIntent)
        ctx.drawPDFPage(page)
        ctx.restoreGState()
    }
}
