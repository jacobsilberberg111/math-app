import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Wrapping long code lines to a column width (monospaced text, so columns = characters, with
/// wide characters such as emoji and CJK counting as two).
enum CodeWrap {
    /// One visual row of a line: characters [start, end) of the line, drawn `indent` columns in.
    struct Row: Equatable {
        var start: Int
        var end: Int
        var indent: Int
    }

    static func columns(_ c: Character) -> Int {
        guard let s = c.unicodeScalars.first else { return 1 }
        let v = s.value
        if v < 0x1100 { return 1 }
        if c.unicodeScalars.count > 1 && s.properties.isEmojiPresentation { return 2 }
        switch v {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
             0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x1FA70...0x1FAFF, 0x20000...0x3FFFD:
            return 2
        default:
            return s.properties.isEmojiPresentation ? 2 : 1
        }
    }

    static func columns<S: Sequence>(_ s: S) -> Int where S.Element == Character {
        s.reduce(0) { $0 + columns($1) }
    }

    /// Splits a line into rows of at most `maxColumns`. Continuation rows are indented by the
    /// line's own indentation plus 4 (at most half the width), so wrapped code still reads as
    /// one statement. Breaks after a space when that keeps at least half the row.
    static func wrap(_ chars: [Character], maxColumns: Int, continuationIndent: Bool = true) -> [Row] {
        let maxCols = max(1, maxColumns)
        let n = chars.count
        if n == 0 { return [Row(start: 0, end: 0, indent: 0)] }
        if columns(chars) <= maxCols { return [Row(start: 0, end: n, indent: 0)] }
        var leading = 0
        while leading < n && chars[leading] == " " { leading += 1 }
        let contIndent = continuationIndent && maxCols >= 12 ? min(leading + 4, maxCols / 2) : 0
        var rows: [Row] = []
        var start = 0
        var indent = 0
        while start < n {
            let avail = max(1, maxCols - indent)
            var cols = 0
            var end = start
            while end < n && cols + columns(chars[end]) <= avail {
                cols += columns(chars[end])
                end += 1
            }
            if end == start { end = start + 1 }
            if end < n {
                var sp = end - 1
                while sp > start && chars[sp] != " " { sp -= 1 }
                if chars[sp] == " " && sp + 1 - start >= max(1, (end - start) / 2) {
                    end = sp + 1
                }
            }
            rows.append(Row(start: start, end: end, indent: indent))
            start = end
            indent = contIndent
        }
        return rows
    }
}

/// Font measurements the card layout needs. The renderer measures its monospaced fonts; tests
/// pass round numbers.
struct CodeCardMetrics: Equatable {
    /// Advance of one column in the code font, and the height of one code row.
    var charWidth: CGFloat
    var lineHeight: CGFloat
    /// The same for the output panel's font.
    var outputCharWidth: CGFloat
    var outputLineHeight: CGFloat

    static let headerHeight: CGFloat = 34
    static let codeTopPadding: CGFloat = 8
    static let codeBottomPadding: CGFloat = 10
    static let sidePadding: CGFloat = 12
    static let gutterGap: CGFloat = 12
    static let outputLabelHeight: CGFloat = 24
    static let outputBottomPadding: CGFloat = 10
    /// The output panel shows at most this many rows; the rest is summarised as "… N more lines".
    static let maxOutputRows = 14
}

/// Where everything goes on a code card of a given width. CodeRenderer draws exactly this, and
/// CodeRenderer.size(for:width:) is its height, so the two always agree.
struct CodeCardLayout {
    struct CodeRow: Equatable {
        /// 0-based source line.
        var line: Int
        var row: CodeWrap.Row
        var isContinuation: Bool { row.start > 0 }
    }

    struct OutputRow: Equatable {
        enum Style: Equatable {
            case normal
            case error
            /// Never run: the renderer says "Not run yet — tap Run".
            case notRun
            /// Ran, printed nothing.
            case noOutput
            /// Rows left out: "… N more lines".
            case more(Int)
        }
        var text: String
        var style: Style
    }

    let width: CGFloat
    let metrics: CodeCardMetrics
    /// Display lines (tabs expanded).
    let lines: [String]
    let rows: [CodeRow]
    /// Index into `rows` of each line's first row.
    let firstRow: [Int]
    let gutterWidth: CGFloat
    /// x of the code text, relative to the card's left edge.
    let codeX: CGFloat
    let codeColumns: Int
    /// y of the first code row, relative to the card's top.
    let codeTop: CGFloat
    /// y of the line between code and output; nil for blocks without an output panel (pseudocode).
    let outputTop: CGFloat?
    let outputColumns: Int
    let outputRows: [OutputRow]
    let height: CGFloat

    init(_ c: CodeContent, width: CGFloat, metrics m: CodeCardMetrics) {
        self.width = width
        self.metrics = m
        let lines = c.displayLines
        self.lines = lines
        let digits = max(2, String(lines.count).count)
        gutterWidth = CGFloat(digits) * m.charWidth
        codeX = CodeCardMetrics.sidePadding + gutterWidth + CodeCardMetrics.gutterGap
        codeColumns = max(8, Int(((width - codeX - CodeCardMetrics.sidePadding) / max(1, m.charWidth)).rounded(.down)))
        var rows: [CodeRow] = []
        var first: [Int] = []
        for (i, line) in lines.enumerated() {
            first.append(rows.count)
            for r in CodeWrap.wrap(Array(line), maxColumns: codeColumns) {
                rows.append(CodeRow(line: i, row: r))
            }
        }
        self.rows = rows
        firstRow = first
        codeTop = CodeCardMetrics.headerHeight + CodeCardMetrics.codeTopPadding
        let codeBottom = codeTop + CGFloat(rows.count) * m.lineHeight + CodeCardMetrics.codeBottomPadding
        outputColumns = max(8, Int(((width - 2 * CodeCardMetrics.sidePadding) / max(1, m.outputCharWidth)).rounded(.down)))
        if c.isRunnable {
            outputTop = codeBottom
            let out = CodeCardLayout.outputRows(c, columns: outputColumns)
            outputRows = out
            height = (codeBottom + CodeCardMetrics.outputLabelHeight + CGFloat(out.count) * m.outputLineHeight
                      + CodeCardMetrics.outputBottomPadding).rounded(.up)
        } else {
            outputTop = nil
            outputRows = []
            height = codeBottom.rounded(.up)
        }
    }

    func rowTop(_ index: Int) -> CGFloat { codeTop + CGFloat(index) * metrics.lineHeight }

    /// Top of a source line's first row (0-based line), relative to the card.
    func lineTop(_ line: Int) -> CGFloat {
        guard firstRow.indices.contains(line) else { return rowTop(rows.count) }
        return rowTop(firstRow[line])
    }

    /// How many rows a source line wraps onto.
    func rowCount(ofLine line: Int) -> Int {
        guard firstRow.indices.contains(line) else { return 0 }
        let next = line + 1 < firstRow.count ? firstRow[line + 1] : rows.count
        return next - firstRow[line]
    }

    /// y of the first output row, relative to the card.
    var outputTextTop: CGFloat { (outputTop ?? height) + CodeCardMetrics.outputLabelHeight }

    /// The output panel's rows: output (wrapped), then the error in red, kept to
    /// `maxOutputRows` with the error's last rows (the message) always shown.
    static func outputRows(_ c: CodeContent, columns: Int) -> [OutputRow] {
        guard c.hasRun else { return [OutputRow(text: "", style: .notRun)] }
        func wrapped(_ text: String?, style: OutputRow.Style) -> [OutputRow] {
            guard let text, !text.isEmpty else { return [] }
            // Only the start of very long output can be shown; don't wrap megabytes.
            let limited = CodeOutputText.limited(text, maxChars: 6000, maxLines: 200).text
            var lines = CodeText.lines(limited)
            if lines.last == "" { lines.removeLast() }
            var out: [OutputRow] = []
            for line in lines {
                let chars = Array(line)
                for r in CodeWrap.wrap(chars, maxColumns: columns, continuationIndent: false) {
                    out.append(OutputRow(text: String(chars[r.start..<r.end]), style: style))
                }
            }
            return out
        }
        let out = wrapped(c.output, style: .normal)
        let err = wrapped(c.error, style: .error)
        if out.isEmpty && err.isEmpty { return [OutputRow(text: "", style: .noOutput)] }
        return fit(out, err, limit: CodeCardMetrics.maxOutputRows)
    }

    /// Keeps the first output rows and the last error rows within `limit`, with a "more" row
    /// standing in for what's left out.
    static func fit(_ out: [OutputRow], _ err: [OutputRow], limit: Int) -> [OutputRow] {
        if out.count + err.count <= limit { return out + err }
        let room = limit - 1
        let errKeep = min(err.count, max(limit / 2 + 1, room - out.count))
        let outKeep = min(out.count, room - errKeep)
        let hidden = (out.count - outKeep) + (err.count - errKeep)
        return Array(out.prefix(outKeep)) + [OutputRow(text: "", style: .more(hidden))] + Array(err.suffix(errKeep))
    }

    /// For the tutor: where each line sits on the page, so it can annotate a specific line.
    /// `origin` is the card's top-left in page coordinates.
    func linePositions(origin: CGPoint, maxLines: Int = 60) -> String {
        let rowH = metrics.lineHeight
        var s = "Rows are \(Int(rowH.rounded())) pt tall; code text starts at x=\(Int((origin.x + codeX).rounded())) and each column is \(String(format: "%.1f", metrics.charWidth)) pt wide. Line tops (page y):"
        var parts: [String] = []
        for i in lines.indices.prefix(maxLines) {
            let y = Int((origin.y + lineTop(i)).rounded())
            let n = rowCount(ofLine: i)
            parts.append(n > 1 ? "\(i + 1):\(y) (wraps to \(n) rows)" : "\(i + 1):\(y)")
        }
        s += " " + parts.joined(separator: ", ")
        if lines.count > maxLines { s += ", …" }
        s += "."
        return s
    }
}
