import UIKit

/// A laid-out piece of math. Coordinates are relative to the box's baseline origin, with y
/// growing downward (UIKit), so "above the baseline" is negative y.
final class MathBox {
    enum Content {
        case none
        case glyph(String, UIFont)
        case rule(CGRect)
        case stroke(CGPath, CGFloat)
        case fill(CGPath)
    }

    var width: CGFloat
    var ascent: CGFloat
    var descent: CGFloat
    var content: Content
    var children: [(box: MathBox, offset: CGPoint)] = []
    var color: UIColor?
    var atomClass: MathAtomClass = .ordinary
    /// x position of the first top-level relation symbol, used to align multi-line working.
    var alignX: CGFloat?

    init(width: CGFloat, ascent: CGFloat, descent: CGFloat, content: Content = .none) {
        self.width = width
        self.ascent = ascent
        self.descent = descent
        self.content = content
    }

    var height: CGFloat { ascent + descent }

    static func empty() -> MathBox { MathBox(width: 0, ascent: 0, descent: 0) }

    /// Draws with the baseline origin at `origin`. The context must be the current UIKit context.
    func draw(in ctx: CGContext, at origin: CGPoint, color inherited: UIColor) {
        let c = color ?? inherited
        switch content {
        case .none:
            break
        case .glyph(let text, let font):
            let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: c])
            attr.draw(at: CGPoint(x: origin.x, y: origin.y - font.ascender))
        case .rule(let r):
            ctx.setFillColor(c.cgColor)
            ctx.fill(r.offsetBy(dx: origin.x, dy: origin.y))
        case .stroke(let path, let lineWidth):
            ctx.saveGState()
            ctx.translateBy(x: origin.x, y: origin.y)
            ctx.addPath(path)
            ctx.setStrokeColor(c.cgColor)
            ctx.setLineWidth(lineWidth)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.strokePath()
            ctx.restoreGState()
        case .fill(let path):
            ctx.saveGState()
            ctx.translateBy(x: origin.x, y: origin.y)
            ctx.addPath(path)
            ctx.setFillColor(c.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }
        for (child, offset) in children {
            child.draw(in: ctx, at: CGPoint(x: origin.x + offset.x, y: origin.y + offset.y), color: c)
        }
    }
}

struct MathStyle {
    var size: CGFloat
    var level: Int = 0
    var display: Bool = true

    var script: MathStyle {
        MathStyle(size: max(7, size * (level == 0 ? 0.7 : 0.8)), level: level + 1, display: false)
    }

    var fractionPart: MathStyle {
        if display && level == 0 { return MathStyle(size: size * 0.92, level: 0, display: false) }
        return MathStyle(size: max(7, size * 0.78), level: level + 1, display: false)
    }

    var axis: CGFloat { size * 0.25 }
    var ruleThickness: CGFloat { max(0.9, size * 0.055) }
}

enum MathFonts {
    private static var cache: [String: UIFont] = [:]

    static func font(size: CGFloat, italic: Bool = false, bold: Bool = false) -> UIFont {
        let key = "\(Int(size * 10))-\(italic)-\(bold)"
        if let f = cache[key] { return f }
        var descriptor = UIFont.systemFont(ofSize: size).fontDescriptor
        if let serif = descriptor.withDesign(.serif) { descriptor = serif }
        var traits: UIFontDescriptor.SymbolicTraits = []
        if italic { traits.insert(.traitItalic) }
        if bold { traits.insert(.traitBold) }
        if !traits.isEmpty, let d = descriptor.withSymbolicTraits(traits) { descriptor = d }
        let font = UIFont(descriptor: descriptor, size: size)
        cache[key] = font
        return font
    }
}

enum MathLayout {
    // MARK: Entry points

    static func layout(latex: String, size: CGFloat, display: Bool = true) -> MathBox {
        layout(MathParser.parse(latex), style: MathStyle(size: size, level: 0, display: display))
    }

    static func layout(_ node: MathNode, style: MathStyle) -> MathBox {
        switch node {
        case .row(let items):
            return layoutRow(items, style: style)
        case .symbol(let s, let cls, let italic):
            let box = glyph(s, style: style, italic: italic)
            box.atomClass = cls
            return box
        case .text(let t, let cls):
            let box = glyph(t, style: style, italic: false)
            box.atomClass = cls == .op ? .op : .ordinary
            return box
        case .frac(let n, let d):
            return fraction(n, d, style: style)
        case .sqrt(let r, let index):
            return radical(r, index: index, style: style)
        case .scripts(let base, let sup, let sub):
            return scripts(base: base, sup: sup, sub: sub, style: style)
        case .bigOp(let sym, let lower, let upper, let above, let isText):
            return bigOperator(sym, lower: lower, upper: upper, limitsAbove: above, isText: isText, style: style)
        case .delimited(let l, let inner, let r):
            let innerBox = layout(inner, style: style)
            return delimited(left: l, innerBox, right: r, style: style)
        case .accent(let inner, let kind):
            return accent(inner, kind: kind, style: style)
        case .matrix(let rows, let l, let r):
            let grid = matrix(rows, style: style, leftAlign: l == "{" && r.isEmpty)
            if l.isEmpty && r.isEmpty { return grid }
            return delimited(left: l, grid, right: r, style: style)
        case .space(let em):
            return MathBox(width: em * style.size, ascent: 0, descent: 0)
        case .color(let name, let inner):
            let box = layout(inner, style: style)
            box.color = UIColor(hex: InkPalette.hex(for: name, default: "#1F2328"))
            return box
        }
    }

    // MARK: Glyphs

    static let tallCharacters = Set("bdfhkltABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789()[]{}|/\\!?δθλβζξ∂√∞'′∑∏ΣΠΔΓΘΛΞΦΨΩ%#&@∫⟨⟩⌊⌋⌈⌉")
    static let descenderCharacters = Set("gjpqyβγζημρφχψξ()[]{}|,;∫⌊⌋")
    static let bracketCharacters = Set("()[]{}|⟨⟩⌊⌋⌈⌉")

    static func glyph(_ s: String, style: MathStyle, italic: Bool) -> MathBox {
        let font = MathFonts.font(size: style.size, italic: italic)
        let attr = NSAttributedString(string: s, attributes: [.font: font])
        let width = ceil(attr.size().width * 100) / 100
        var ascent = font.xHeight
        var descent: CGFloat = 0
        if s.contains(where: { tallCharacters.contains($0) }) { ascent = font.capHeight }
        if s.contains(where: { bracketCharacters.contains($0) }) { ascent = max(ascent, font.ascender * 0.92) }
        if s.contains(where: { descenderCharacters.contains($0) }) { descent = -font.descender * 0.8 }
        if s == "−" || s == "+" || s == "=" || s == "±" || s == "×" || s == "÷" || s == "·" { ascent = font.xHeight * 0.95 }
        let box = MathBox(width: width, ascent: ascent, descent: descent, content: .glyph(s, font))
        return box
    }

    // MARK: Rows and spacing

    static func effectiveClass(_ box: MathBox) -> MathAtomClass { box.atomClass }

    static func spacing(between left: MathAtomClass, and right: MathAtomClass, style: MathStyle) -> CGFloat {
        let em = style.size
        let tight = style.level > 0
        switch (left, right) {
        case (.relation, .relation): return 0
        case (_, .relation), (.relation, _): return tight ? 0.1 * em : 0.28 * em
        case (_, .binary), (.binary, _): return tight ? 0.06 * em : 0.22 * em
        case (.punct, _): return tight ? 0 : 0.17 * em
        case (.op, .ordinary), (.ordinary, .op), (.op, .op), (.op, .open): return 0.12 * em
        case (.close, .op): return 0.12 * em
        default: return 0
        }
    }

    static func layoutRow(_ items: [MathNode], style: MathStyle) -> MathBox {
        let boxes = items.map { layout($0, style: style) }
        // A binary operator with nothing sensible to its left is unary (e.g. leading minus).
        var prev: MathAtomClass?
        for b in boxes {
            if b.atomClass == .binary {
                if prev == nil || prev == .binary || prev == .relation || prev == .open || prev == .punct || prev == .op {
                    b.atomClass = .ordinary
                }
            }
            prev = b.atomClass
        }
        if let last = boxes.last, last.atomClass == .binary { last.atomClass = .ordinary }

        let row = MathBox(width: 0, ascent: 0, descent: 0)
        var x: CGFloat = 0
        var prevBox: MathBox?
        for b in boxes {
            if let p = prevBox {
                x += spacing(between: p.atomClass, and: b.atomClass, style: style)
            }
            if b.atomClass == .relation && row.alignX == nil {
                row.alignX = x
            }
            row.children.append((b, CGPoint(x: x, y: 0)))
            x += b.width
            row.ascent = max(row.ascent, b.ascent)
            row.descent = max(row.descent, b.descent)
            prevBox = b
        }
        row.width = x
        if boxes.count == 1 {
            row.atomClass = boxes[0].atomClass
        }
        return row
    }

    // MARK: Fractions

    static func fraction(_ n: MathNode, _ d: MathNode, style: MathStyle) -> MathBox {
        let partStyle = style.fractionPart
        let num = layout(n, style: partStyle)
        let den = layout(d, style: partStyle)
        let t = style.ruleThickness
        let gap = style.size * (style.display ? 0.16 : 0.1)
        let pad = style.size * 0.12
        let width = max(num.width, den.width) + 2 * pad
        let axis = style.axis
        // Bar centred on the math axis.
        let barY = -axis - t / 2
        let numBaseline = barY - gap - num.descent
        let denBaseline = barY + t + gap + den.ascent
        let box = MathBox(width: width, ascent: -(numBaseline - num.ascent), descent: denBaseline + den.descent)
        box.children.append((num, CGPoint(x: (width - num.width) / 2, y: numBaseline)))
        box.children.append((den, CGPoint(x: (width - den.width) / 2, y: denBaseline)))
        let bar = MathBox(width: width, ascent: 0, descent: 0, content: .rule(CGRect(x: pad * 0.4, y: barY, width: width - pad * 0.8, height: t)))
        box.children.append((bar, .zero))
        box.width = width + style.size * 0.06
        return box
    }

    // MARK: Radicals

    static func radical(_ r: MathNode, index: MathNode?, style: MathStyle) -> MathBox {
        let rad = layout(r, style: style)
        let t = style.ruleThickness
        let gap = style.size * 0.14
        let top = -(max(rad.ascent, style.size * 0.55) + gap + t / 2)
        let bottom = max(rad.descent, style.size * 0.05) + style.size * 0.06
        let h = bottom - top
        let signW = max(style.size * 0.55, h * 0.32)
        var indexBox: MathBox?
        var lead: CGFloat = 0
        if let index {
            let ib = layout(index, style: style.script.script)
            indexBox = ib
            lead = max(0, ib.width - signW * 0.45)
        }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: lead, y: top + h * 0.58))
        path.addLine(to: CGPoint(x: lead + signW * 0.22, y: top + h * 0.5))
        path.addLine(to: CGPoint(x: lead + signW * 0.52, y: bottom))
        path.addLine(to: CGPoint(x: lead + signW, y: top))
        path.addLine(to: CGPoint(x: lead + signW + rad.width + style.size * 0.12, y: top))
        let box = MathBox(width: lead + signW + rad.width + style.size * 0.2, ascent: -top + t, descent: bottom)
        box.children.append((MathBox(width: 0, ascent: 0, descent: 0, content: .stroke(path, t)), .zero))
        box.children.append((rad, CGPoint(x: lead + signW + style.size * 0.06, y: 0)))
        if let ib = indexBox {
            let baseline = top + h * 0.45
            box.children.append((ib, CGPoint(x: lead + signW * 0.45 - ib.width, y: baseline)))
            box.ascent = max(box.ascent, -(baseline - ib.ascent))
        }
        return box
    }

    // MARK: Scripts

    static func scripts(base: MathNode, sup: MathNode?, sub: MathNode?, style: MathStyle) -> MathBox {
        if case .bigOp(let sym, let lower, let upper, let above, let isText) = base {
            return bigOperator(sym, lower: sub ?? lower, upper: sup ?? upper, limitsAbove: above, isText: isText, style: style)
        }
        let b = layout(base, style: style)
        let s = style.script
        let supBox = sup.map { layout($0, style: s) }
        let subBox = sub.map { layout($0, style: s) }
        var italicKern: CGFloat = 0
        if case .symbol(_, _, let italic) = base, italic { italicKern = style.size * 0.04 }

        var u: CGFloat = 0
        var v: CGFloat = 0
        if let sp = supBox {
            u = max(style.size * 0.42, b.ascent - sp.ascent * 0.45)
        }
        if let sb = subBox {
            v = max(style.size * (supBox == nil ? 0.18 : 0.26), b.descent + sb.ascent * 0.3)
        }
        if let sp = supBox, let sb = subBox {
            let minGap = style.size * 0.12
            let gap = (u - sp.descent) - (sb.ascent - v)
            if gap < minGap { v += minGap - gap }
        }
        let box = MathBox(width: b.width, ascent: b.ascent, descent: b.descent)
        box.atomClass = b.atomClass
        box.children.append((b, .zero))
        var extra: CGFloat = 0
        if let sp = supBox {
            box.children.append((sp, CGPoint(x: b.width + italicKern, y: -u)))
            box.ascent = max(box.ascent, u + sp.ascent)
            extra = max(extra, sp.width + italicKern)
        }
        if let sb = subBox {
            box.children.append((sb, CGPoint(x: b.width, y: v)))
            box.descent = max(box.descent, v + sb.descent)
            extra = max(extra, sb.width)
        }
        box.width = b.width + extra + style.size * 0.04
        return box
    }

    // MARK: Big operators

    static func bigOperator(_ sym: String, lower: MathNode?, upper: MathNode?, limitsAbove: Bool, isText: Bool, style: MathStyle) -> MathBox {
        let s = style.script
        let lowerBox = lower.map { layout($0, style: s) }
        let upperBox = upper.map { layout($0, style: s) }
        let opBox: MathBox
        let isIntegral = "∫∬∭∮".contains(sym)
        if isText {
            opBox = glyph(sym, style: style, italic: false)
        } else if isIntegral {
            opBox = integralSign(sym, style: style)
        } else {
            let scale: CGFloat = style.display && style.level == 0 ? 1.45 : 1.15
            let glyphChar = sym == "∑" ? "Σ" : (sym == "∏" ? "Π" : sym)
            let g = glyph(glyphChar, style: MathStyle(size: style.size * scale, level: style.level, display: style.display), italic: false)
            // Centre the glyph on the math axis.
            let shift = (g.ascent - g.descent) / 2 - style.axis
            let wrapper = MathBox(width: g.width, ascent: g.ascent - shift, descent: g.descent + shift)
            wrapper.children.append((g, CGPoint(x: 0, y: shift)))
            opBox = wrapper
        }

        let box = MathBox(width: 0, ascent: opBox.ascent, descent: opBox.descent)
        box.atomClass = .op
        if limitsAbove && (style.display || isText) && !isIntegral {
            let width = max(opBox.width, lowerBox?.width ?? 0, upperBox?.width ?? 0)
            box.children.append((opBox, CGPoint(x: (width - opBox.width) / 2, y: 0)))
            let gap = style.size * 0.12
            if let ub = upperBox {
                let y = -opBox.ascent - gap - ub.descent
                box.children.append((ub, CGPoint(x: (width - ub.width) / 2, y: y)))
                box.ascent = -(y - ub.ascent)
            }
            if let lb = lowerBox {
                let y = opBox.descent + gap + lb.ascent
                box.children.append((lb, CGPoint(x: (width - lb.width) / 2, y: y)))
                box.descent = y + lb.descent
            }
            box.width = width + style.size * 0.08
        } else {
            box.children.append((opBox, .zero))
            var extra: CGFloat = 0
            if let ub = upperBox {
                let y = -opBox.ascent + ub.ascent * 0.6
                box.children.append((ub, CGPoint(x: opBox.width + style.size * 0.02, y: y)))
                box.ascent = max(box.ascent, -(y - ub.ascent))
                extra = max(extra, ub.width)
            }
            if let lb = lowerBox {
                let y = opBox.descent - lb.descent * 0.2
                let x = opBox.width - (isIntegral ? style.size * 0.28 : 0)
                box.children.append((lb, CGPoint(x: x, y: y)))
                box.descent = max(box.descent, y + lb.descent)
                extra = max(extra, lb.width - (isIntegral ? style.size * 0.28 : 0))
            }
            box.width = opBox.width + extra + style.size * 0.1
        }
        return box
    }

    /// Integral signs drawn as paths so they look right at any size.
    static func integralSign(_ sym: String, style: MathStyle) -> MathBox {
        let scale: CGFloat = style.display && style.level == 0 ? 2.1 : 1.45
        let h = style.size * scale
        let w = h * 0.36
        let top = -style.axis - h / 2
        let bottom = -style.axis + h / 2
        let count = sym == "∬" ? 2 : (sym == "∭" ? 3 : 1)
        let lw = max(1, style.size * 0.075)
        let path = CGMutablePath()
        for k in 0..<count {
            let ox = CGFloat(k) * w * 0.55
            path.move(to: CGPoint(x: ox + w * 0.95, y: top + h * 0.06))
            path.addCurve(to: CGPoint(x: ox + w * 0.55, y: top + h * 0.18),
                          control1: CGPoint(x: ox + w * 0.85, y: top - h * 0.02),
                          control2: CGPoint(x: ox + w * 0.6, y: top + h * 0.02))
            path.addLine(to: CGPoint(x: ox + w * 0.45, y: bottom - h * 0.18))
            path.addCurve(to: CGPoint(x: ox + w * 0.05, y: bottom - h * 0.06),
                          control1: CGPoint(x: ox + w * 0.4, y: bottom - h * 0.02),
                          control2: CGPoint(x: ox + w * 0.15, y: bottom + h * 0.02))
        }
        if sym == "∮" {
            let r = w * 0.32
            path.addEllipse(in: CGRect(x: w * 0.5 - r, y: -style.axis - r, width: 2 * r, height: 2 * r))
        }
        let total = w + CGFloat(count - 1) * w * 0.55
        let box = MathBox(width: total + style.size * 0.08, ascent: -top, descent: bottom)
        box.children.append((MathBox(width: 0, ascent: 0, descent: 0, content: .stroke(path, lw)), .zero))
        return box
    }

    // MARK: Delimiters

    static func delimited(left: String, _ inner: MathBox, right: String, style: MathStyle) -> MathBox {
        let axis = style.axis
        let half = max(inner.ascent - axis, inner.descent + axis, style.size * 0.45) + style.size * 0.08
        let top = -axis - half
        let bottom = -axis + half
        let h = bottom - top
        let dw = style.size * 0.32 + h * 0.05
        let box = MathBox(width: 0, ascent: -top, descent: bottom)
        var x: CGFloat = 0
        if let l = delimiterBox(left, top: top, height: h, width: dw, style: style, isLeft: true) {
            box.children.append((l, CGPoint(x: x, y: 0)))
            x += l.width
        }
        box.children.append((inner, CGPoint(x: x + style.size * 0.04, y: 0)))
        x += inner.width + style.size * 0.08
        if let r = delimiterBox(right, top: top, height: h, width: dw, style: style, isLeft: false) {
            box.children.append((r, CGPoint(x: x, y: 0)))
            x += r.width
        }
        box.width = x
        box.ascent = max(box.ascent, inner.ascent)
        box.descent = max(box.descent, inner.descent)
        return box
    }

    static func delimiterBox(_ d: String, top: CGFloat, height h: CGFloat, width w: CGFloat, style: MathStyle, isLeft: Bool) -> MathBox? {
        guard !d.isEmpty else { return nil }
        let lw = max(0.9, style.size * 0.06)
        let bottom = top + h
        let mid = top + h / 2
        let path = CGMutablePath()
        var filled = false
        switch d {
        case "(", ")":
            let flip = d == ")"
            func X(_ f: CGFloat) -> CGFloat { flip ? w * (1 - f) : w * f }
            path.move(to: CGPoint(x: X(0.82), y: top))
            path.addQuadCurve(to: CGPoint(x: X(0.82), y: bottom), control: CGPoint(x: X(-0.12), y: mid))
            path.addQuadCurve(to: CGPoint(x: X(0.82), y: top), control: CGPoint(x: X(0.22), y: mid))
            path.closeSubpath()
            filled = true
        case "[", "]", "⌊", "⌋", "⌈", "⌉":
            let flip = d == "]" || d == "⌋" || d == "⌉"
            func X(_ f: CGFloat) -> CGFloat { flip ? w * (1 - f) : w * f }
            let showTop = d != "⌊" && d != "⌋"
            let showBottom = d != "⌈" && d != "⌉"
            if showTop {
                path.move(to: CGPoint(x: X(0.8), y: top))
                path.addLine(to: CGPoint(x: X(0.3), y: top))
            } else {
                path.move(to: CGPoint(x: X(0.3), y: top))
            }
            path.addLine(to: CGPoint(x: X(0.3), y: bottom))
            if showBottom { path.addLine(to: CGPoint(x: X(0.8), y: bottom)) }
        case "{", "}":
            let flip = d == "}"
            func X(_ f: CGFloat) -> CGFloat { flip ? w * (1 - f) : w * f }
            path.move(to: CGPoint(x: X(0.85), y: top))
            path.addQuadCurve(to: CGPoint(x: X(0.5), y: top + h * 0.12), control: CGPoint(x: X(0.5), y: top))
            path.addLine(to: CGPoint(x: X(0.5), y: mid - h * 0.1))
            path.addQuadCurve(to: CGPoint(x: X(0.15), y: mid), control: CGPoint(x: X(0.5), y: mid))
            path.addQuadCurve(to: CGPoint(x: X(0.5), y: mid + h * 0.1), control: CGPoint(x: X(0.5), y: mid))
            path.addLine(to: CGPoint(x: X(0.5), y: bottom - h * 0.12))
            path.addQuadCurve(to: CGPoint(x: X(0.85), y: bottom), control: CGPoint(x: X(0.5), y: bottom))
        case "|":
            path.move(to: CGPoint(x: w * 0.5, y: top))
            path.addLine(to: CGPoint(x: w * 0.5, y: bottom))
        case "‖":
            path.move(to: CGPoint(x: w * 0.35, y: top))
            path.addLine(to: CGPoint(x: w * 0.35, y: bottom))
            path.move(to: CGPoint(x: w * 0.65, y: top))
            path.addLine(to: CGPoint(x: w * 0.65, y: bottom))
        case "⟨", "<":
            path.move(to: CGPoint(x: w * 0.8, y: top))
            path.addLine(to: CGPoint(x: w * 0.2, y: mid))
            path.addLine(to: CGPoint(x: w * 0.8, y: bottom))
        case "⟩", ">":
            path.move(to: CGPoint(x: w * 0.2, y: top))
            path.addLine(to: CGPoint(x: w * 0.8, y: mid))
            path.addLine(to: CGPoint(x: w * 0.2, y: bottom))
        default:
            let g = glyph(d, style: style, italic: false)
            return g
        }
        let content: MathBox.Content = filled ? .fill(path) : .stroke(path, lw)
        return MathBox(width: w, ascent: -top, descent: bottom, content: content)
    }

    // MARK: Matrices

    static func matrix(_ rows: [[MathNode]], style: MathStyle, leftAlign: Bool) -> MathBox {
        let cellStyle = MathStyle(size: style.size * (style.level == 0 ? 0.95 : 1), level: style.level, display: false)
        let boxes = rows.map { $0.map { layout($0, style: cellStyle) } }
        let cols = boxes.map(\.count).max() ?? 0
        guard cols > 0 else { return .empty() }
        var colWidths = [CGFloat](repeating: 0, count: cols)
        for r in boxes { for (j, b) in r.enumerated() { colWidths[j] = max(colWidths[j], b.width) } }
        let colGap = style.size * (leftAlign ? 1.0 : 0.85)
        let rowGap = style.size * 0.32
        var rowAsc: [CGFloat] = []
        var rowDesc: [CGFloat] = []
        for r in boxes {
            rowAsc.append(max(r.map(\.ascent).max() ?? 0, style.size * 0.7))
            rowDesc.append(max(r.map(\.descent).max() ?? 0, style.size * 0.25))
        }
        let totalHeight = zip(rowAsc, rowDesc).reduce(0) { $0 + $1.0 + $1.1 } + rowGap * CGFloat(max(0, boxes.count - 1))
        let top = -style.axis - totalHeight / 2
        let box = MathBox(width: 0, ascent: -top, descent: top + totalHeight)
        var y = top
        for (i, r) in boxes.enumerated() {
            let baseline = y + rowAsc[i]
            var x: CGFloat = 0
            for (j, b) in r.enumerated() {
                let cx = leftAlign ? x : x + (colWidths[j] - b.width) / 2
                box.children.append((b, CGPoint(x: cx, y: baseline)))
                x += colWidths[j] + colGap
            }
            y = baseline + rowDesc[i] + rowGap
        }
        box.width = colWidths.reduce(0, +) + colGap * CGFloat(cols - 1)
        return box
    }

    // MARK: Accents

    static func accent(_ inner: MathNode, kind: MathAccent, style: MathStyle) -> MathBox {
        let b = layout(inner, style: style)
        let lw = max(0.9, style.size * 0.05)
        let box = MathBox(width: b.width, ascent: b.ascent, descent: b.descent)
        box.atomClass = b.atomClass
        box.children.append((b, .zero))
        let y = -b.ascent - style.size * 0.12
        let path = CGMutablePath()
        var filled = false
        switch kind {
        case .vec:
            let x0 = style.size * 0.05, x1 = max(b.width, style.size * 0.5)
            path.move(to: CGPoint(x: x0, y: y))
            path.addLine(to: CGPoint(x: x1, y: y))
            path.move(to: CGPoint(x: x1 - style.size * 0.15, y: y - style.size * 0.1))
            path.addLine(to: CGPoint(x: x1, y: y))
            path.addLine(to: CGPoint(x: x1 - style.size * 0.15, y: y + style.size * 0.1))
            box.ascent = b.ascent + style.size * 0.25
        case .bar:
            path.move(to: CGPoint(x: style.size * 0.03, y: y))
            path.addLine(to: CGPoint(x: b.width, y: y))
            box.ascent = b.ascent + style.size * 0.18
        case .hat:
            let cx = b.width / 2
            path.move(to: CGPoint(x: cx - style.size * 0.18, y: y + style.size * 0.02))
            path.addLine(to: CGPoint(x: cx, y: y - style.size * 0.12))
            path.addLine(to: CGPoint(x: cx + style.size * 0.18, y: y + style.size * 0.02))
            box.ascent = b.ascent + style.size * 0.28
        case .dot, .ddot:
            let r = style.size * 0.05
            let cx = b.width / 2
            let xs: [CGFloat] = kind == .dot ? [cx] : [cx - style.size * 0.12, cx + style.size * 0.12]
            for x in xs { path.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)) }
            filled = true
            box.ascent = b.ascent + style.size * 0.2
        case .tilde:
            let x0: CGFloat = 0, x1 = max(b.width, style.size * 0.4)
            path.move(to: CGPoint(x: x0, y: y))
            path.addCurve(to: CGPoint(x: x1, y: y), control1: CGPoint(x: x0 + (x1 - x0) * 0.35, y: y - style.size * 0.15),
                          control2: CGPoint(x: x0 + (x1 - x0) * 0.65, y: y + style.size * 0.15))
            box.ascent = b.ascent + style.size * 0.25
        case .underline:
            let uy = b.descent + style.size * 0.1
            path.move(to: CGPoint(x: 0, y: uy))
            path.addLine(to: CGPoint(x: b.width, y: uy))
            box.descent = uy + lw
        case .overbrace:
            let h = style.size * 0.18
            path.move(to: CGPoint(x: 0, y: y + h / 2))
            path.addQuadCurve(to: CGPoint(x: b.width / 2, y: y - h / 2), control: CGPoint(x: 0, y: y - h / 2))
            path.addQuadCurve(to: CGPoint(x: b.width, y: y + h / 2), control: CGPoint(x: b.width, y: y - h / 2))
            box.ascent = b.ascent + style.size * 0.3
        }
        box.children.append((MathBox(width: 0, ascent: 0, descent: 0, content: filled ? .fill(path) : .stroke(path, lw)), .zero))
        return box
    }

    // MARK: Multi-line display math

    /// Lays out several lines of working, aligned on their first relation symbol.
    static func layoutLines(_ lines: [String], size: CGFloat, align: Bool, lineGap: CGFloat? = nil) -> (boxes: [(MathBox, CGPoint)], size: CGSize) {
        let boxes = lines.map { layout(latex: $0, size: size, display: true) }
        let gap = lineGap ?? size * 0.55
        let alignTo = align ? (boxes.compactMap(\.alignX).max() ?? 0) : 0
        var placed: [(MathBox, CGPoint)] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        for b in boxes {
            let x = align && b.alignX != nil ? alignTo - (b.alignX ?? 0) : 0
            y += b.ascent
            placed.append((b, CGPoint(x: x, y: y)))
            y += b.descent + gap
            width = max(width, x + b.width)
        }
        let height = max(0, y - gap)
        return (placed, CGSize(width: ceil(width) + 2, height: ceil(height) + 2))
    }
}
