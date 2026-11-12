import UIKit

/// The calculator's screen: status indicators, then Natural Display input and the result, or a
/// menu, a message or the STAT editor. Draws its own little textbook layout (fractions, radicals,
/// raised powers, dotted empty boxes) with a blinking cursor.
final class CalculatorLCDView: UIView {
    var display: CalcDisplay? {
        didSet {
            guard display != oldValue else { return }
            caretVisible = true
            setNeedsDisplay()
        }
    }

    private var caretVisible = true
    private var blink: Timer?

    static let background = UIColor(red: 0.74, green: 0.78, blue: 0.70, alpha: 1)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = CalculatorLCDView.background
        contentMode = .redraw
        isOpaque = true
        layer.cornerRadius = 6
        layer.masksToBounds = true
        isAccessibilityElement = true
        accessibilityLabel = "Calculator screen"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        blink?.invalidate()
        guard window != nil else { return }
        blink = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.caretVisible.toggle()
            self.setNeedsDisplay()
        }
    }

    deinit { blink?.invalidate() }

    // MARK: Drawing

    private var ink: UIColor {
        let c = display?.contrast ?? 0.5
        return UIColor(white: 0.02 + (1 - c) * 0.3, alpha: 0.55 + c * 0.45)
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), let display else { return }
        CalculatorLCDView.background.setFill()
        ctx.fill(bounds)
        // Faint LCD inner shadow.
        UIColor.black.withAlphaComponent(0.06).setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: bounds.width, height: 2))

        drawIndicators(display.indicators, in: ctx)
        let body = bounds.insetBy(dx: 10, dy: 0).inset(by: UIEdgeInsets(top: 18, left: 0, bottom: 6, right: 0))
        switch display.content {
        case .calc(let input, let cursor, let result, let naturalIn, let naturalOut):
            drawCalc(input: input, cursor: cursor, result: result, naturalIn: naturalIn, naturalOut: naturalOut, in: body, ctx: ctx)
        case .menu(let items, let columns):
            drawMenu(items, columns: columns, in: body)
        case .message(let lines):
            drawMessage(lines, in: body)
        case .statEditor(let table):
            drawStatEditor(table, in: body, ctx: ctx)
        }
        accessibilityValue = accessibilityText(display)
    }

    private func drawIndicators(_ i: CalcDisplay.Indicators, in ctx: CGContext) {
        let font = UIFont.systemFont(ofSize: 9, weight: .bold)
        var items: [String] = []
        if i.shift { items.append("S") }
        if i.alpha { items.append("A") }
        if i.memory { items.append("M") }
        if i.sto { items.append("STO") }
        if i.rcl { items.append("RCL") }
        if i.stat { items.append("STAT") }
        items.append(i.angle.indicator)
        if i.fix { items.append("FIX") }
        if i.sci { items.append("SCI") }
        if i.math { items.append("Math") }
        var x: CGFloat = 10
        for s in items {
            let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
            let label = s
            if s == "S" || s == "A" {
                let size = (label as NSString).size(withAttributes: attr)
                let box = CGRect(x: x - 1.5, y: 3, width: size.width + 3, height: size.height + 1)
                ink.setFill()
                UIBezierPath(rect: box).fill()
                (label as NSString).draw(at: CGPoint(x: x, y: 3.5), withAttributes: [.font: font, .foregroundColor: CalculatorLCDView.background])
                x += size.width + 9
            } else {
                (label as NSString).draw(at: CGPoint(x: x, y: 3.5), withAttributes: attr)
                x += (label as NSString).size(withAttributes: attr).width + 8
            }
        }
        let arrows = (i.historyUp ? "▲" : "") + (i.historyDown ? "▼" : "")
        if !arrows.isEmpty {
            let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
            let w = (arrows as NSString).size(withAttributes: attr).width
            (arrows as NSString).draw(at: CGPoint(x: bounds.width - 10 - w, y: 3.5), withAttributes: attr)
        }
    }

    private func drawCalc(input: CalcLine, cursor: CalcCursor?, result: CalcLine?, naturalIn: Bool, naturalOut: Bool,
                          in body: CGRect, ctx: CGContext) {
        let size: CGFloat = 21
        let layout = LCDLayout(size: size, natural: naturalIn, color: ink)
        // An empty input shows just the cursor (empty slots inside templates show dotted boxes).
        let box = input.isEmpty
            ? LCDBox(width: 0, ascent: size, descent: 4, caret: CGRect(x: 0, y: -size * 0.85, width: 1.6, height: size * 1.05), color: ink)
            : layout.line(input, caret: cursor.map { ($0.path[...], $0.index) })
        // Input: top line, scrolled so the cursor stays on screen.
        var x = body.minX
        if box.width > body.width, let caret = box.caret {
            x = body.minX - max(0, min(box.width - body.width, caret.maxX - body.width + 14))
        } else if box.width > body.width {
            x = body.minX
        }
        let inputBaseline = body.minY + max(box.ascent, size) + 2
        ctx.saveGState()
        ctx.clip(to: body.insetBy(dx: -4, dy: -2))
        box.draw(at: CGPoint(x: x, y: inputBaseline), in: ctx)
        if caretVisible, let caret = box.caret {
            ink.setFill()
            ctx.fill(caret.offsetBy(dx: x, dy: inputBaseline))
        }
        ctx.restoreGState()

        guard let result else { return }
        let r = LCDLayout(size: size + 1, natural: naturalOut, color: ink)
        let rb = r.line(result, caret: nil)
        let baseline = body.maxY - max(rb.descent, 5) - 2
        let rx = max(body.minX, body.maxX - rb.width)
        rb.draw(at: CGPoint(x: rx, y: baseline), in: ctx)
    }

    private func drawMenu(_ items: [String], columns: Int, in body: CGRect) {
        let font = UIFont.systemFont(ofSize: 17, weight: .medium)
        let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        let rows = Int((Double(items.count) / Double(columns)).rounded(.up))
        let rowHeight = min(26, body.height / CGFloat(max(rows, 1)))
        let colWidth = body.width / CGFloat(columns)
        for (k, item) in items.enumerated() {
            let r = k / columns, c = k % columns
            (item as NSString).draw(at: CGPoint(x: body.minX + CGFloat(c) * colWidth, y: body.minY + CGFloat(r) * rowHeight), withAttributes: attr)
        }
    }

    private func drawMessage(_ lines: [String], in body: CGRect) {
        for (k, line) in lines.enumerated() {
            let font = UIFont.systemFont(ofSize: k == 0 ? 18 : 15, weight: k == 0 ? .semibold : .medium)
            let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
            let y = body.minY + CGFloat(k) * 25
            let w = (line as NSString).size(withAttributes: attr).width
            (line as NSString).draw(at: CGPoint(x: k == 0 ? body.midX - w / 2 : body.minX + 18, y: y), withAttributes: attr)
        }
    }

    private func drawStatEditor(_ t: CalcDisplay.StatTable, in body: CGRect, ctx: CGContext) {
        let font = UIFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        let numberWidth: CGFloat = 26
        let colWidth = (body.width - numberWidth) / CGFloat(max(t.columns.count, 1))
        let rowHeight: CGFloat = 17
        for (c, name) in t.columns.enumerated() {
            let w = (name as NSString).size(withAttributes: attr).width
            (name as NSString).draw(at: CGPoint(x: body.minX + numberWidth + CGFloat(c) * colWidth + colWidth - w - 6, y: body.minY), withAttributes: attr)
        }
        ink.setFill()
        ctx.fill(CGRect(x: body.minX, y: body.minY + rowHeight + 1, width: body.width, height: 1))
        for (k, row) in t.rows.enumerated() {
            let y = body.minY + CGFloat(k + 1) * rowHeight + 3
            ("\(row.0)" as NSString).draw(at: CGPoint(x: body.minX, y: y), withAttributes: attr)
            for (c, cell) in row.1.enumerated() {
                let cellRect = CGRect(x: body.minX + numberWidth + CGFloat(c) * colWidth, y: y - 1, width: colWidth - 2, height: rowHeight)
                let selected = row.0 == t.cursorRow && c == t.cursorColumn
                var a = attr
                if selected {
                    ink.setFill()
                    ctx.fill(cellRect)
                    a[.foregroundColor] = CalculatorLCDView.background
                }
                let w = (cell as NSString).size(withAttributes: a).width
                (cell as NSString).draw(at: CGPoint(x: cellRect.maxX - w - 4, y: y), withAttributes: a)
            }
        }
        // The value being typed into the selected cell, along the bottom.
        if let input = t.cellInput {
            let layout = LCDLayout(size: 15, natural: false, color: ink)
            let box = layout.line(input, caret: t.cellCursor.map { ($0.path[...], $0.index) })
            let baseline = body.maxY - 3
            let x = max(body.minX, body.maxX - box.width - 4)
            box.draw(at: CGPoint(x: x, y: baseline), in: ctx)
            if caretVisible, let caret = box.caret {
                ink.setFill()
                ctx.fill(caret.offsetBy(dx: x, dy: baseline))
            }
        }
    }

    private func accessibilityText(_ d: CalcDisplay) -> String {
        switch d.content {
        case .calc(let input, _, let result, _, _):
            return LCDLayout.plain(input) + (result.map { " equals " + LCDLayout.plain($0) } ?? "")
        case .menu(let items, _): return items.joined(separator: ", ")
        case .message(let lines): return lines.joined(separator: ". ")
        case .statEditor(let t): return "Statistics editor, row \(t.cursorRow), column \(t.columns[safe: t.cursorColumn] ?? "")"
        }
    }
}

// MARK: - Layout

/// A laid-out piece of the display, drawn relative to its left end on the baseline (y grows down).
struct LCDBox {
    enum Op {
        case text(String, CGPoint, UIFont)
        case line(CGPoint, CGPoint, CGFloat)
        case polyline([CGPoint], CGFloat)
        case dottedBox(CGRect)
    }

    var width: CGFloat = 0
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    var ops: [Op] = []
    var caret: CGRect?
    var color: UIColor = .black

    mutating func append(_ b: LCDBox, dy: CGFloat = 0) {
        let dx = width
        ops += b.ops.map { $0.offset(dx, dy) }
        if let c = b.caret { caret = c.offsetBy(dx: dx, dy: dy) }
        width += b.width
        ascent = max(ascent, b.ascent - dy)
        descent = max(descent, b.descent + dy)
    }

    func draw(at p: CGPoint, in ctx: CGContext) {
        color.setStroke()
        for op in ops {
            switch op.offset(p.x, p.y) {
            case .text(let s, let at, let font):
                (s as NSString).draw(at: at, withAttributes: [.font: font, .foregroundColor: color])
            case .line(let a, let b, let w):
                ctx.setLineWidth(w)
                ctx.move(to: a)
                ctx.addLine(to: b)
                ctx.strokePath()
            case .polyline(let pts, let w):
                guard let first = pts.first else { continue }
                ctx.setLineWidth(w)
                ctx.setLineJoin(.round)
                ctx.move(to: first)
                for q in pts.dropFirst() { ctx.addLine(to: q) }
                ctx.strokePath()
            case .dottedBox(let r):
                ctx.setLineWidth(1)
                ctx.setLineDash(phase: 0, lengths: [1.5, 1.5])
                ctx.stroke(r)
                ctx.setLineDash(phase: 0, lengths: [])
            }
        }
    }
}

extension LCDBox.Op {
    func offset(_ dx: CGFloat, _ dy: CGFloat) -> LCDBox.Op {
        switch self {
        case .text(let s, let p, let f): return .text(s, CGPoint(x: p.x + dx, y: p.y + dy), f)
        case .line(let a, let b, let w): return .line(CGPoint(x: a.x + dx, y: a.y + dy), CGPoint(x: b.x + dx, y: b.y + dy), w)
        case .polyline(let pts, let w): return .polyline(pts.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }, w)
        case .dottedBox(let r): return .dottedBox(r.offsetBy(dx: dx, dy: dy))
        }
    }
}

struct LCDLayout {
    let size: CGFloat
    /// Textbook layout (false draws fractions as a⌟b and roots as √( ) on one line).
    let natural: Bool
    let color: UIColor

    init(size: CGFloat, natural: Bool, color: UIColor) {
        self.size = size
        self.natural = natural
        self.color = color
    }

    private func font(_ s: CGFloat) -> UIFont { UIFont.systemFont(ofSize: s, weight: .medium) }

    private func scaled(_ k: CGFloat) -> LCDLayout { LCDLayout(size: max(9, size * k), natural: natural, color: color) }

    func text(_ s: String) -> LCDBox {
        let f = font(size)
        let w = (s as NSString).size(withAttributes: [.font: f]).width
        return LCDBox(width: w, ascent: f.ascender, descent: -f.descender, ops: [.text(s, CGPoint(x: 0, y: -f.ascender), f)], color: color)
    }

    private var caretHeight: CGFloat { size * 1.05 }

    private func caretRect(x: CGFloat) -> CGRect {
        CGRect(x: x - 0.75, y: -size * 0.85, width: 1.6, height: caretHeight)
    }

    typealias Caret = (path: ArraySlice<CalcCursor.Step>, index: Int)

    func line(_ line: CalcLine, caret: Caret?) -> LCDBox {
        var box = LCDBox(color: color)
        let f = font(size)
        box.ascent = f.ascender * 0.8
        box.descent = -f.descender * 0.8
        if line.isEmpty, natural || caret != nil {
            // An empty slot: a dotted box (the cursor sits inside it).
            let w = size * 0.55, h = size * 0.72
            var empty = LCDBox(width: w + 2, ascent: h, descent: 1, ops: [.dottedBox(CGRect(x: 1, y: -h, width: w, height: h))], color: color)
            if let caret, caret.path.isEmpty { empty.caret = caretRect(x: 2) }
            return empty
        }
        for (k, node) in line.nodes.enumerated() {
            if let caret, caret.path.isEmpty, caret.index == k { box.caret = caretRect(x: box.width) }
            var inner: Caret?
            if let caret, let step = caret.path.first, step.node == k { inner = (caret.path.dropFirst(), caret.index) }
            switch node {
            case .token(let t): box.append(text(t.label))
            case .template(let kind, let slots):
                box.append(template(kind, slots, caret: inner, innerSlot: caret?.path.first?.node == k ? caret?.path.first?.slot : nil))
            }
        }
        if let caret, caret.path.isEmpty, caret.index >= line.nodes.count { box.caret = caretRect(x: box.width) }
        return box
    }

    private func slot(_ slots: [CalcLine], _ k: Int, caret: Caret?, innerSlot: Int?, scale: CGFloat = 1) -> LCDBox {
        let l = scale == 1 ? self : scaled(scale)
        let c: Caret? = innerSlot == k ? caret : nil
        guard k < slots.count else { return LCDBox(color: color) }
        // Empty slots show their dotted box even while the cursor is elsewhere.
        if slots[k].isEmpty && c == nil {
            let w = l.size * 0.55, h = l.size * 0.72
            return LCDBox(width: w + 2, ascent: h, descent: 1, ops: [.dottedBox(CGRect(x: 1, y: -h, width: w, height: h))], color: color)
        }
        return l.line(slots[k], caret: c)
    }

    private func template(_ kind: CalcTemplate, _ slots: [CalcLine], caret: Caret?, innerSlot: Int?) -> LCDBox {
        if !natural { return linearTemplate(kind, slots, caret: caret, innerSlot: innerSlot) }
        let f = font(size)
        let axis = f.xHeight * 0.55
        switch kind {
        case .fraction:
            return fraction(slot(slots, 0, caret: caret, innerSlot: innerSlot), slot(slots, 1, caret: caret, innerSlot: innerSlot), axis: axis)
        case .mixed:
            var b = slot(slots, 0, caret: caret, innerSlot: innerSlot)
            b.append(fraction(slot(slots, 1, caret: caret, innerSlot: innerSlot), slot(slots, 2, caret: caret, innerSlot: innerSlot), axis: axis))
            return b
        case .sqrt:
            return radical(slot(slots, 0, caret: caret, innerSlot: innerSlot), index: nil)
        case .cbrt:
            return radical(slot(slots, 0, caret: caret, innerSlot: innerSlot), index: scaled(0.6).text("3"))
        case .root:
            return radical(slot(slots, 1, caret: caret, innerSlot: innerSlot), index: slot(slots, 0, caret: caret, innerSlot: innerSlot, scale: 0.6))
        case .power:
            return superscript(slot(slots, 0, caret: caret, innerSlot: innerSlot, scale: 0.68), base: nil)
        case .tenPower:
            return superscript(slot(slots, 0, caret: caret, innerSlot: innerSlot, scale: 0.68), base: text("10"))
        case .ePower:
            return superscript(slot(slots, 0, caret: caret, innerSlot: innerSlot, scale: 0.68), base: text("e"))
        case .exp10:
            return superscript(slot(slots, 0, caret: caret, innerSlot: innerSlot, scale: 0.68), base: text("×10"))
        case .logBase:
            var b = text("log")
            b.append(slot(slots, 0, caret: caret, innerSlot: innerSlot, scale: 0.68), dy: size * 0.3)
            b.append(text("("))
            b.append(slot(slots, 1, caret: caret, innerSlot: innerSlot))
            b.append(text(")"))
            return b
        case .abs:
            let inner = slot(slots, 0, caret: caret, innerSlot: innerSlot)
            var b = LCDBox(width: 4, ascent: inner.ascent, descent: inner.descent, color: color)
            b.append(inner)
            let top = -inner.ascent - 1, bottom = inner.descent + 1
            b.ops.append(.line(CGPoint(x: 2, y: top), CGPoint(x: 2, y: bottom), 1.4))
            b.ops.append(.line(CGPoint(x: b.width + 2, y: top), CGPoint(x: b.width + 2, y: bottom), 1.4))
            b.width += 5
            return b
        }
    }

    private func fraction(_ num: LCDBox, _ den: LCDBox, axis: CGFloat) -> LCDBox {
        let w = max(num.width, den.width) + 4
        let gap: CGFloat = 2.5
        let numBaseline = -axis - gap - num.descent
        let denBaseline = -axis + gap + den.ascent
        var b = LCDBox(width: w + 4, color: color)
        b.ops = num.ops.map { $0.offset(2 + (w - num.width) / 2, numBaseline) }
            + den.ops.map { $0.offset(2 + (w - den.width) / 2, denBaseline) }
        b.ops.append(.line(CGPoint(x: 2, y: -axis), CGPoint(x: 2 + w, y: -axis), 1.3))
        if let c = num.caret { b.caret = c.offsetBy(dx: 2 + (w - num.width) / 2, dy: numBaseline) }
        if let c = den.caret { b.caret = c.offsetBy(dx: 2 + (w - den.width) / 2, dy: denBaseline) }
        b.ascent = -(numBaseline - num.ascent)
        b.descent = denBaseline + den.descent
        return b
    }

    private func radical(_ inner: LCDBox, index: LCDBox?) -> LCDBox {
        var b = LCDBox(color: color)
        var lead: CGFloat = 0
        if let index {
            b.ops += index.ops.map { $0.offset(0, -inner.ascent * 0.35) }
            if let c = index.caret { b.caret = c.offsetBy(dx: 0, dy: -inner.ascent * 0.35) }
            lead = max(0, index.width - 5)
            b.ascent = max(b.ascent, inner.ascent * 0.35 + index.ascent)
        }
        let top = -inner.ascent - 3, bottom = inner.descent
        let h = bottom - top
        let x0 = lead
        b.ops.append(.polyline([
            CGPoint(x: x0, y: bottom - h * 0.42), CGPoint(x: x0 + 3, y: bottom - h * 0.5),
            CGPoint(x: x0 + 7, y: bottom), CGPoint(x: x0 + 11, y: top),
            CGPoint(x: x0 + 13 + inner.width + 2, y: top),
        ], 1.4))
        b.ops += inner.ops.map { $0.offset(x0 + 13, 0) }
        if let c = inner.caret { b.caret = c.offsetBy(dx: x0 + 13, dy: 0) }
        b.width = x0 + 13 + inner.width + 4
        b.ascent = max(b.ascent, inner.ascent + 4)
        b.descent = inner.descent + 1
        return b
    }

    private func superscript(_ exp: LCDBox, base: LCDBox?) -> LCDBox {
        var b = base ?? LCDBox(color: color)
        if base == nil { b.ascent = 0; b.descent = 0 }
        b.append(exp, dy: -size * 0.42)
        b.width += 1
        return b
    }

    private func linearTemplate(_ kind: CalcTemplate, _ slots: [CalcLine], caret: Caret?, innerSlot: Int?) -> LCDBox {
        func s(_ k: Int) -> LCDBox {
            let c: Caret? = innerSlot == k ? caret : nil
            return line(slots[k], caret: c)
        }
        var b = LCDBox(color: color)
        func add(_ t: String) { b.append(text(t)) }
        switch kind {
        case .fraction: b.append(s(0)); add("⌟"); b.append(s(1))
        case .mixed: b.append(s(0)); add("⌟"); b.append(s(1)); add("⌟"); b.append(s(2))
        case .sqrt: add("√("); b.append(s(0)); add(")")
        case .cbrt: add("³√("); b.append(s(0)); add(")")
        case .root: b.append(s(0)); add("√("); b.append(s(1)); add(")")
        case .power: add("^("); b.append(s(0)); add(")")
        case .tenPower: add("10^("); b.append(s(0)); add(")")
        case .ePower: add("e^("); b.append(s(0)); add(")")
        case .exp10: add("×10^"); b.append(s(0))
        case .logBase: add("log("); b.append(s(0)); add(","); b.append(s(1)); add(")")
        case .abs: add("Abs("); b.append(s(0)); add(")")
        }
        return b
    }

    /// Plain text for VoiceOver.
    static func plain(_ line: CalcLine) -> String {
        line.nodes.map { n -> String in
            switch n {
            case .token(let t): return t.label
            case .template(let k, let s):
                let p = s.map(plain)
                switch k {
                case .fraction: return "(\(p[0])) over (\(p[1]))"
                case .mixed: return "\(p[0]) and \(p[1]) over \(p[2])"
                case .sqrt: return "root of \(p[0])"
                case .cbrt: return "cube root of \(p[0])"
                case .root: return "\(p[0])th root of \(p[1])"
                case .power: return " to the power \(p[0])"
                case .tenPower: return "10 to the power \(p[0])"
                case .ePower: return "e to the power \(p[0])"
                case .exp10: return " times 10 to the \(p[0])"
                case .logBase: return "log base \(p[0]) of \(p[1])"
                case .abs: return "absolute value of \(p[0])"
                }
            }
        }.joined()
    }
}
