import UIKit

/// Fonts used for the tutor's writing and the student's text boxes.
enum NoteFonts {
    static func tutorFont(style: TextStyle, size: CGFloat, hand: TutorHandStyle) -> UIFont {
        switch style {
        case .heading:
            if hand == .handwriting, let f = UIFont(name: "Noteworthy-Bold", size: size) { return f }
            return rounded(size: size, weight: .bold)
        case .typed:
            return rounded(size: size, weight: .regular)
        case .handwriting, .note, .sticky:
            if hand == .handwriting, let f = UIFont(name: "Noteworthy-Light", size: size) { return f }
            return rounded(size: size, weight: .regular)
        }
    }

    static func studentFont(size: CGFloat) -> UIFont {
        UIFont.systemFont(ofSize: size)
    }

    static func rounded(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        if let d = base.fontDescriptor.withDesign(.rounded) { return UIFont(descriptor: d, size: size) }
        return base
    }

    static func bold(_ font: UIFont) -> UIFont {
        if font.fontName.hasPrefix("Noteworthy") { return UIFont(name: "Noteworthy-Bold", size: font.pointSize) ?? font }
        if let d = font.fontDescriptor.withSymbolicTraits(.traitBold) { return UIFont(descriptor: d, size: font.pointSize) }
        return font
    }
}

/// Lays out tutor text that mixes words with inline `$math$`, wrapping to a width. Supports
/// partial reveal (by character count) so writing can animate in like handwriting.
final class RichTextLayout {
    enum ItemKind {
        case text(String, UIFont)
        case math(MathBox)
    }

    struct Item {
        var kind: ItemKind
        var x: CGFloat
        var baseline: CGFloat
        var width: CGFloat
        var charStart: Int
        var charCount: Int
    }

    private(set) var items: [Item] = []
    private(set) var lineRects: [CGRect] = []
    private(set) var size: CGSize = .zero
    private(set) var totalChars = 0

    init(text: String, font: UIFont, maxWidth: CGFloat, rich: Bool, hideUnclosedMath: Bool = false) {
        var source = text
        if hideUnclosedMath {
            // While streaming, don't flash raw LaTeX of a formula that hasn't closed yet.
            let dollars = source.filter { $0 == "$" }.count
            if dollars % 2 == 1, let idx = source.lastIndex(of: "$") {
                source = String(source[..<idx])
            }
        }
        let segments: [RichTextSegment] = rich ? RichTextParser.segments(source) : RichTextLayout.plainSegments(source)
        layout(segments, font: font, maxWidth: max(40, maxWidth))
    }

    static func plainSegments(_ s: String) -> [RichTextSegment] {
        var out: [RichTextSegment] = []
        let lines = s.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            if i > 0 { out.append(.newline) }
            if !line.isEmpty { out.append(.text(line, bold: false)) }
        }
        return out
    }

    private struct Token {
        var kind: ItemKind
        var width: CGFloat
        var ascent: CGFloat
        var descent: CGFloat
        var isSpace: Bool
        var chars: Int
    }

    private func layout(_ segments: [RichTextSegment], font: UIFont, maxWidth: CGFloat) {
        let boldFont = NoteFonts.bold(font)
        let mathSize = font.pointSize * 1.02
        let lineGap = font.pointSize * 0.28
        let baseAscent = font.ascender
        let baseDescent = -font.descender

        var lines: [[Token]] = [[]]
        var lineWidths: [CGFloat] = [0]

        func width(of s: String, _ f: UIFont) -> CGFloat {
            NSAttributedString(string: s, attributes: [.font: f]).size().width
        }

        func append(_ token: Token) {
            let current = lineWidths[lineWidths.count - 1]
            if !token.isSpace && current > 0 && current + token.width > maxWidth {
                // Drop trailing spaces before wrapping.
                while let last = lines[lines.count - 1].last, last.isSpace {
                    lines[lines.count - 1].removeLast()
                    lineWidths[lineWidths.count - 1] -= last.width
                }
                lines.append([])
                lineWidths.append(0)
            }
            if token.isSpace && lines.count > 1 && lines[lines.count - 1].isEmpty {
                // Leading space on a wrapped line: keep the character count but no width.
                var t = token
                t.width = 0
                lines[lines.count - 1].append(t)
                return
            }
            lines[lines.count - 1].append(token)
            lineWidths[lineWidths.count - 1] += token.width
        }

        for seg in segments {
            switch seg {
            case .newline:
                // Zero-width marker so character counts stay in step with `totalChars`.
                lines[lines.count - 1].append(Token(kind: .text("", font), width: 0, ascent: baseAscent, descent: baseDescent, isSpace: true, chars: 1))
                lines.append([])
                lineWidths.append(0)
                totalChars += 1
            case .math(let latex):
                let box = MathLayout.layout(latex: latex, size: mathSize, display: false)
                append(Token(kind: .math(box), width: box.width + 2, ascent: box.ascent, descent: box.descent, isSpace: false, chars: max(1, latex.count)))
                totalChars += max(1, latex.count)
            case .text(let s, let bold):
                let f = bold ? boldFont : font
                // Split into words, keeping spaces as separate tokens.
                var word = ""
                func flushWord() {
                    if !word.isEmpty {
                        let w = width(of: word, f)
                        if w > maxWidth {
                            // Very long word: break it by characters.
                            var chunk = ""
                            for ch in word {
                                let candidate = chunk + String(ch)
                                if width(of: candidate, f) > maxWidth && !chunk.isEmpty {
                                    append(Token(kind: .text(chunk, f), width: width(of: chunk, f), ascent: baseAscent, descent: baseDescent, isSpace: false, chars: chunk.count))
                                    chunk = String(ch)
                                } else {
                                    chunk = candidate
                                }
                            }
                            if !chunk.isEmpty {
                                append(Token(kind: .text(chunk, f), width: width(of: chunk, f), ascent: baseAscent, descent: baseDescent, isSpace: false, chars: chunk.count))
                            }
                        } else {
                            append(Token(kind: .text(word, f), width: w, ascent: baseAscent, descent: baseDescent, isSpace: false, chars: word.count))
                        }
                        totalChars += word.count
                        word = ""
                    }
                }
                for ch in s {
                    if ch == " " || ch == "\t" {
                        flushWord()
                        append(Token(kind: .text(" ", f), width: width(of: " ", f), ascent: baseAscent, descent: baseDescent, isSpace: true, chars: 1))
                        totalChars += 1
                    } else {
                        word.append(ch)
                    }
                }
                flushWord()
            }
        }

        var y: CGFloat = 0
        var charCursor = 0
        var maxLineWidth: CGFloat = 0
        for line in lines {
            let asc = max(baseAscent, line.map(\.ascent).max() ?? 0)
            let desc = max(baseDescent, line.map(\.descent).max() ?? 0)
            let baseline = y + asc
            var x: CGFloat = 0
            for t in line {
                items.append(Item(kind: t.kind, x: x, baseline: baseline, width: t.width, charStart: charCursor, charCount: t.chars))
                x += t.width
                charCursor += t.chars
            }
            lineRects.append(CGRect(x: 0, y: y, width: x, height: asc + desc))
            maxLineWidth = max(maxLineWidth, x)
            y = baseline + desc + lineGap
        }
        size = CGSize(width: ceil(maxLineWidth), height: ceil(max(0, y - lineGap)))
    }

    /// Draws at `origin` (top-left). `visibleChars` limits drawing for reveal animations.
    func draw(in ctx: CGContext, origin: CGPoint, color: UIColor, visibleChars: Int? = nil) {
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }
        let limit = visibleChars ?? Int.max
        for item in items {
            if item.charStart >= limit { break }
            switch item.kind {
            case .text(let s, let font):
                var str = s
                let remaining = limit - item.charStart
                if remaining < item.charCount {
                    str = String(s.prefix(remaining))
                }
                let attr = NSAttributedString(string: str, attributes: [.font: font, .foregroundColor: color])
                attr.draw(at: CGPoint(x: origin.x + item.x, y: origin.y + item.baseline - font.ascender))
            case .math(let box):
                box.draw(in: ctx, at: CGPoint(x: origin.x + item.x + 1, y: origin.y + item.baseline), color: color)
            }
        }
    }

    /// Where the "pen" is after `chars` characters, for the tutor presence cursor.
    func caretPosition(afterChars chars: Int) -> CGPoint {
        guard !items.isEmpty else { return .zero }
        for item in items where item.charStart + item.charCount >= chars {
            let frac = item.charCount > 0 ? CGFloat(chars - item.charStart) / CGFloat(item.charCount) : 1
            return CGPoint(x: item.x + item.width * max(0, min(1, frac)), y: item.baseline)
        }
        let last = items[items.count - 1]
        return CGPoint(x: last.x + last.width, y: last.baseline)
    }
}

/// Measures and draws the student's plain text boxes so they match the UITextView used to edit them.
enum PlainTextRenderer {
    static func attributed(_ text: String, font: UIFont, color: UIColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    }

    static func size(_ text: String, font: UIFont, width: CGFloat) -> CGSize {
        let s = text.isEmpty ? " " : text
        let r = attributed(s, font: font, color: .black).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return CGSize(width: ceil(r.width), height: ceil(r.height))
    }

    static func draw(_ text: String, in rect: CGRect, font: UIFont, color: UIColor, ctx: CGContext) {
        UIGraphicsPushContext(ctx)
        attributed(text, font: font, color: color).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        UIGraphicsPopContext()
    }
}
