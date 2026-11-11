import UIKit

/// Draws a code block as a card that reads well on paper: a header (language badge and title),
/// line numbers, syntax-highlighted monospaced code with long lines wrapped under a continuation
/// indent, and an output panel (what the program printed, errors in red).
///
/// All positions come from CodeCardLayout (Core), so `size(for:width:)` is exactly what `draw`
/// lays out, and the tutor's line positions match the drawing.
@MainActor
enum CodeRenderer {
    // MARK: Fonts and colours

    static let codeFontSize: CGFloat = 14
    static let outputFontSize: CGFloat = 13

    static var codeFont: UIFont { UIFont.monospacedSystemFont(ofSize: codeFontSize, weight: .regular) }
    static var outputFont: UIFont { UIFont.monospacedSystemFont(ofSize: outputFontSize, weight: .regular) }
    static var lineNumberFont: UIFont { UIFont.monospacedSystemFont(ofSize: 12, weight: .regular) }

    /// Measured once: the monospaced column width of each font, and fixed row heights.
    static let metrics: CodeCardMetrics = CodeCardMetrics(charWidth: columnWidth(codeFont), lineHeight: 20,
                                                          outputCharWidth: columnWidth(outputFont), outputLineHeight: 18)

    private static func columnWidth(_ font: UIFont) -> CGFloat {
        let sample = String(repeating: "M", count: 20) as NSString
        return sample.size(withAttributes: [.font: font]).width / 20
    }

    static func color(for kind: CodeTokenKind) -> UIColor {
        switch kind {
        case .plain: return UIColor(hex: "#1F2328")
        case .keyword: return UIColor(hex: "#8250DF")
        case .constant: return UIColor(hex: "#953800")
        case .builtin: return UIColor(hex: "#0550AE")
        case .string: return UIColor(hex: "#116329")
        case .comment: return UIColor(hex: "#6E7781")
        case .number: return UIColor(hex: "#953800")
        case .decorator: return UIColor(hex: "#953800")
        case .definition: return UIColor(hex: "#0969DA")
        }
    }

    static let errorColor = UIColor(hex: "#CF222E")
    static let quietColor = UIColor(hex: "#6E7781")
    static let borderColor = UIColor(hex: "#D0D7DE")

    static func badgeColor(_ lang: CodeLanguage) -> UIColor {
        lang == .python ? UIColor(hex: "#3572A5") : UIColor(hex: "#6E7781")
    }

    // MARK: Caches

    private static var layoutCache: [(content: CodeContent, width: CGFloat, layout: CodeCardLayout)] = []
    private static var highlightCache: [(key: String, lines: [[CodeSpan]])] = []

    static func layout(_ c: CodeContent, width: CGFloat) -> CodeCardLayout {
        if let hit = layoutCache.first(where: { abs($0.width - width) < 0.01 && $0.content == c }) { return hit.layout }
        let l = CodeCardLayout(c, width: width, metrics: metrics)
        layoutCache.append((content: c, width: width, layout: l))
        if layoutCache.count > 12 { layoutCache.removeFirst() }
        return l
    }

    static func highlighted(_ c: CodeContent) -> [[CodeSpan]] {
        let key = c.lang.rawValue + "\u{0}" + c.code
        if let hit = highlightCache.first(where: { $0.key == key }) { return hit.lines }
        let lines = CodeHighlighter.highlight(c.code, language: c.lang)
        highlightCache.append((key: key, lines: lines))
        if highlightCache.count > 24 { highlightCache.removeFirst() }
        return lines
    }

    // MARK: Size

    /// The block's natural size at a given width (code lines plus the output panel).
    static func size(for c: CodeContent, width: CGFloat) -> CGSize {
        CGSize(width: width, height: layout(c, width: width).height)
    }

    // MARK: Drawing

    static func draw(_ c: CodeContent, rect: CGRect, progress: CGFloat, env: RenderEnvironment, ctx: CGContext) {
        guard rect.width > 20, rect.height > 10 else { return }
        let l = layout(c, width: rect.width)
        let spans = highlighted(c)
        let m = metrics
        let cardAlpha = max(0, min(1, progress / 0.2))
        // Rows appear top to bottom: code first, then the output panel.
        let totalRows = l.rows.count + l.outputRows.count
        let shown = progress >= 1 ? totalRows : Int((max(0, (progress - 0.1) / 0.9) * CGFloat(totalRows)).rounded(.up))
        let codeShown = min(l.rows.count, shown)
        let outputShown = max(0, shown - l.rows.count)

        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: rect.insetBy(dx: -1, dy: -1))

        // Card.
        let card = UIBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 10)
        ctx.setFillColor(UIColor(hex: "#F6F8FA").withAlphaComponent(cardAlpha).cgColor)
        ctx.addPath(card.cgPath)
        ctx.fillPath()
        ctx.saveGState()
        ctx.addPath(card.cgPath)
        ctx.clip()
        ctx.setFillColor(UIColor(hex: "#EBEEF2").withAlphaComponent(cardAlpha).cgColor)
        ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: CodeCardMetrics.headerHeight))
        if let top = l.outputTop {
            ctx.setFillColor(UIColor.white.withAlphaComponent(cardAlpha).cgColor)
            ctx.fill(CGRect(x: rect.minX, y: rect.minY + top, width: rect.width, height: max(0, rect.height - top)))
        }
        ctx.restoreGState()
        ctx.setStrokeColor(borderColor.withAlphaComponent(cardAlpha).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: rect.minX, y: rect.minY + CodeCardMetrics.headerHeight))
        ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + CodeCardMetrics.headerHeight))
        if let top = l.outputTop {
            ctx.move(to: CGPoint(x: rect.minX, y: rect.minY + top))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + top))
        }
        ctx.strokePath()
        ctx.addPath(card.cgPath)
        ctx.strokePath()

        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }

        drawHeader(c, rect: rect, alpha: cardAlpha)

        // Code rows.
        let font = codeFont
        let numberFont = lineNumberFont
        let textDY = (m.lineHeight - font.lineHeight) / 2
        let numberColor = UIColor(hex: "#8C959F")
        let right = NSMutableParagraphStyle()
        right.alignment = .right
        for i in 0..<codeShown {
            let row = l.rows[i]
            let y = rect.minY + l.rowTop(i)
            let gutter = CGRect(x: rect.minX + CodeCardMetrics.sidePadding - 4, y: y + (m.lineHeight - numberFont.lineHeight) / 2,
                                width: l.gutterWidth + 4, height: numberFont.lineHeight + 2)
            if !row.isContinuation {
                NSAttributedString(string: "\(row.line + 1)", attributes: [.font: numberFont, .foregroundColor: numberColor, .paragraphStyle: right])
                    .draw(in: gutter)
            } else {
                NSAttributedString(string: "↪", attributes: [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: numberColor.withAlphaComponent(0.6), .paragraphStyle: right])
                    .draw(in: gutter)
            }
            let lineSpans = spans[safe: row.line] ?? [CodeSpan(text: l.lines[safe: row.line] ?? "", kind: .plain)]
            let text = rowText(lineSpans, from: row.row.start, to: row.row.end, font: font)
            text.draw(at: CGPoint(x: rect.minX + l.codeX + CGFloat(row.row.indent) * m.charWidth, y: y + textDY))
        }
        if c.code.isEmpty && codeShown > 0 && !env.forSnapshot {
            let hint = NSAttributedString(string: c.isRunnable ? "# Tap Edit Code to write your program" : "Tap Edit Code to write your algorithm",
                                          attributes: [.font: font, .foregroundColor: quietColor.withAlphaComponent(0.7)])
            hint.draw(at: CGPoint(x: rect.minX + l.codeX, y: rect.minY + l.rowTop(0) + textDY))
        }

        // Output panel.
        guard let outputTop = l.outputTop, shown > l.rows.count || progress >= 1 || l.rows.isEmpty else { return }
        drawOutputLabel(c, rect: rect, top: rect.minY + outputTop)
        let outFont = outputFont
        let outDY = (m.outputLineHeight - outFont.lineHeight) / 2
        let italic = UIFont.italicSystemFont(ofSize: outputFontSize)
        for (i, row) in l.outputRows.prefix(outputShown).enumerated() {
            let p = CGPoint(x: rect.minX + CodeCardMetrics.sidePadding, y: rect.minY + l.outputTextTop + CGFloat(i) * m.outputLineHeight + outDY)
            let s: NSAttributedString
            switch row.style {
            case .normal:
                s = NSAttributedString(string: row.text, attributes: [.font: outFont, .foregroundColor: color(for: .plain)])
            case .error:
                s = NSAttributedString(string: row.text, attributes: [.font: outFont, .foregroundColor: errorColor])
            case .notRun:
                s = NSAttributedString(string: env.forSnapshot ? "Not run yet" : "Not run yet — tap Run",
                                       attributes: [.font: italic, .foregroundColor: quietColor])
            case .noOutput:
                s = NSAttributedString(string: "(no output)", attributes: [.font: italic, .foregroundColor: quietColor])
            case .more(let n):
                s = NSAttributedString(string: "… \(n) more line\(n == 1 ? "" : "s")", attributes: [.font: italic, .foregroundColor: quietColor])
            }
            s.draw(at: p)
        }
    }

    /// The part of a line's spans between two character offsets, coloured.
    static func rowText(_ spans: [CodeSpan], from start: Int, to end: Int, font: UIFont) -> NSAttributedString {
        let out = NSMutableAttributedString(string: "")
        var offset = 0
        for span in spans {
            let n = span.text.count
            let a = max(start, offset), b = min(end, offset + n)
            if a < b {
                let chars = Array(span.text)
                out.append(NSAttributedString(string: String(chars[(a - offset)..<(b - offset)]),
                                              attributes: [.font: font, .foregroundColor: color(for: span.kind)]))
            }
            offset += n
            if offset >= end { break }
        }
        return out
    }

    private static func drawHeader(_ c: CodeContent, rect: CGRect, alpha: CGFloat) {
        let badgeFont = NoteFonts.sans(size: 11, weight: .semibold)
        let badgeText = NSAttributedString(string: c.lang.displayName,
                                           attributes: [.font: badgeFont, .foregroundColor: UIColor.white.withAlphaComponent(alpha)])
        let bs = badgeText.size()
        let badge = CGRect(x: rect.minX + CodeCardMetrics.sidePadding, y: rect.minY + (CodeCardMetrics.headerHeight - 20) / 2,
                           width: ceil(bs.width) + 14, height: 20)
        let ctx = UIGraphicsGetCurrentContext()
        ctx?.setFillColor(badgeColor(c.lang).withAlphaComponent(alpha).cgColor)
        ctx?.addPath(UIBezierPath(roundedRect: badge, cornerRadius: 10).cgPath)
        ctx?.fillPath()
        badgeText.draw(at: CGPoint(x: badge.midX - bs.width / 2, y: badge.midY - bs.height / 2))

        guard let title = c.displayTitle else { return }
        let titleFont = NoteFonts.sans(size: 14, weight: .semibold)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let t = NSAttributedString(string: title, attributes: [.font: titleFont, .foregroundColor: UIColor(hex: "#1F2328").withAlphaComponent(alpha),
                                                               .paragraphStyle: para])
        let x = badge.maxX + 10
        let titleRect = CGRect(x: x, y: rect.minY + (CodeCardMetrics.headerHeight - titleFont.lineHeight) / 2,
                               width: max(0, rect.maxX - CodeCardMetrics.sidePadding - x), height: titleFont.lineHeight + 1)
        t.draw(with: titleRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }

    private static func drawOutputLabel(_ c: CodeContent, rect: CGRect, top: CGFloat) {
        let labelFont = NoteFonts.sans(size: 10, weight: .semibold)
        let label = NSAttributedString(string: "OUTPUT", attributes: [.font: labelFont, .foregroundColor: UIColor(hex: "#57606A"), .kern: 0.8])
        let y = top + (CodeCardMetrics.outputLabelHeight - labelFont.lineHeight) / 2 + 1
        label.draw(at: CGPoint(x: rect.minX + CodeCardMetrics.sidePadding, y: y))
        guard c.hasRun else { return }
        var status = c.errored ? "✗ Stopped with an error" : "✓ Ran"
        if let date = c.ranAt { status += " · " + timeLabel(date) }
        let s = NSAttributedString(string: status, attributes: [.font: NoteFonts.sans(size: 10, weight: .medium),
                                                                .foregroundColor: c.errored ? errorColor : UIColor(hex: "#1A7F37")])
        let w = s.size().width
        s.draw(at: CGPoint(x: rect.maxX - CodeCardMetrics.sidePadding - w, y: y))
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return f
    }()

    static func timeLabel(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? timeFormatter.string(from: date) : dateFormatter.string(from: date)
    }

    // MARK: For the tutor

    /// The code exactly as written, with line numbers and where each line sits on the page (so
    /// the tutor can point at a line), the program input and the last run.
    static func tutorDescription(_ c: CodeContent, frame: CGRect) -> String {
        let l = layout(c, width: frame.width)
        var s = c.lang.displayName
        if let t = c.displayTitle { s += " \"\(t)\"" }
        if !c.isRunnable { s += " (pseudocode: read and trace it; it can't be run)" }
        s += ", \(l.lines.count) line\(l.lines.count == 1 ? "" : "s"). " + l.linePositions(origin: frame.origin, maxLines: 60)
        let shownLines = 60
        let width = String(min(l.lines.count, shownLines)).count
        s += "\n      code:"
        if c.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            s += " (empty)"
        } else {
            for (i, line) in l.lines.prefix(shownLines).enumerated() {
                let n = String(i + 1)
                s += "\n      " + String(repeating: " ", count: max(0, width - n.count)) + n + " | " + line
            }
            if l.lines.count > shownLines { s += "\n      … \(l.lines.count - shownLines) more lines" }
        }
        let input = c.stdinLines
        if !input.isEmpty {
            s += "\n      program input (one line per input() call): " + input.prefix(20).map { "\"\($0)\"" }.joined(separator: ", ")
            if input.count > 20 { s += ", …" }
        }
        guard c.isRunnable else { return s }
        if !c.hasRun {
            s += "\n      not run yet"
            return s
        }
        s += "\n      last run" + (c.ranAt.map { " (\(timeLabel($0)))" } ?? "") + (c.errored ? ": stopped with an error" : ": finished")
        if let out = c.output, !out.isEmpty {
            s += "\n      output:\n" + indented(CodeOutputText.limited(out, maxChars: 1_200, maxLines: 15).text)
        } else {
            s += "; printed nothing"
        }
        if let err = c.error, !err.isEmpty {
            s += "\n      error:\n" + indented(CodeOutputText.limited(err, maxChars: 800, maxLines: 14).text)
        }
        return s
    }

    private static func indented(_ text: String) -> String {
        CodeText.normalized(text).components(separatedBy: "\n").map { "        " + $0 }.joined(separator: "\n")
    }
}
