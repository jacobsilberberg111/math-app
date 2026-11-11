import Foundation

/// What a piece of code is, for colouring.
enum CodeTokenKind: String, Equatable {
    case plain
    case keyword
    /// True, False, None (Python); TRUE, FALSE (pseudocode).
    case constant
    case builtin
    case string
    case comment
    case number
    case decorator
    /// The name being defined after `def` or `class`.
    case definition
}

/// A run of text of one kind. A line's spans joined together are exactly the line.
struct CodeSpan: Equatable {
    var text: String
    var kind: CodeTokenKind
}

/// Syntax highlighting for Python and NESA-style pseudocode. Works line by line (so wrapped
/// lines can be split by column) and carries triple-quoted strings across lines.
enum CodeHighlighter {
    /// One array of spans per line of `code` (split on "\n", tabs expanded like CodeText.lines).
    static func highlight(_ code: String, language: CodeLanguage) -> [[CodeSpan]] {
        let lines = CodeText.lines(code)
        switch language {
        case .python:
            var state = PythonState()
            return lines.map { PythonLexer.lex(Array($0), state: &state) }
        case .pseudocode:
            return lines.map { PseudocodeLexer.lex(Array($0)) }
        }
    }

    /// Flattened (UTF-16 offset, length, kind) runs for the whole text, for colouring a text
    /// view. Offsets count the "\n" between lines. Plain runs are omitted.
    /// The text must already have tabs expanded and LF line endings (the editor guarantees it),
    /// otherwise offsets drift.
    static func utf16Runs(_ code: String, language: CodeLanguage) -> [(location: Int, length: Int, kind: CodeTokenKind)] {
        var out: [(location: Int, length: Int, kind: CodeTokenKind)] = []
        var offset = 0
        for (i, line) in highlight(code, language: language).enumerated() {
            if i > 0 { offset += 1 }
            for span in line {
                let n = span.text.utf16.count
                if span.kind != .plain && n > 0 { out.append((offset, n, span.kind)) }
                offset += n
            }
        }
        return out
    }

    static let pythonKeywords: Set<String> = [
        "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except",
        "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass",
        "raise", "return", "try", "while", "with", "yield",
    ]
    static let pythonConstants: Set<String> = ["True", "False", "None"]
    static let pythonBuiltins: Set<String> = [
        "abs", "all", "any", "bin", "bool", "chr", "dict", "dir", "divmod", "enumerate", "eval", "exit", "filter",
        "float", "format", "hex", "id", "input", "int", "isinstance", "iter", "len", "list", "map", "max", "min",
        "next", "oct", "open", "ord", "pow", "print", "range", "repr", "reversed", "round", "set", "sorted", "str",
        "sum", "super", "tuple", "type", "zip", "self", "object", "quit", "help",
        "Exception", "ValueError", "TypeError", "IndexError", "KeyError", "ZeroDivisionError", "NameError",
        "AttributeError", "RuntimeError", "StopIteration", "EOFError", "ImportError",
    ]

    /// NESA pseudocode keywords. Structural words are recognised in any case ("Display" too);
    /// the short ones that make ordinary variable names (to, of, and, next, step…) only in capitals.
    static let pseudocodeKeywordsAnyCase: Set<String> = [
        "BEGIN", "END", "IF", "THEN", "ELSE", "ELSEIF", "ENDIF", "WHILE", "ENDWHILE", "FOR", "ENDFOR", "REPEAT", "UNTIL",
        "CASEWHERE", "OTHERWISE", "ENDCASE", "DISPLAY", "INPUT", "OUTPUT", "PRINT", "RETURN", "SUBPROGRAM",
        "ENDSUBPROGRAM", "MAINPROGRAM",
    ]
    static let pseudocodeKeywordsUpper: Set<String> = [
        "TO", "STEP", "NEXT", "DO", "OF", "CASE", "AND", "OR", "NOT", "GET", "READ", "WRITE", "MOD", "DIV", "OPEN", "CLOSE",
        "CALL", "INCREMENT", "DECREMENT", "SET",
    ]
    static let pseudocodeConstants: Set<String> = ["TRUE", "FALSE"]
}

/// Python lexer state carried from one line to the next: an unterminated triple-quoted string.
struct PythonState: Equatable {
    var tripleQuote: Character?
    var tripleIsF = false
}

enum PythonLexer {
    static func isIdentStart(_ c: Character) -> Bool { c == "_" || c.isLetter }
    static func isIdent(_ c: Character) -> Bool { c == "_" || c.isLetter || c.isNumber }

    static func lex(_ chars: [Character], state: inout PythonState) -> [CodeSpan] {
        var spans: [CodeSpan] = []
        func emit(_ s: ArraySlice<Character>, _ kind: CodeTokenKind) {
            guard !s.isEmpty else { return }
            if let last = spans.last, last.kind == kind {
                spans[spans.count - 1].text += String(s)
            } else {
                spans.append(CodeSpan(text: String(s), kind: kind))
            }
        }
        var i = 0
        let n = chars.count
        // Continue a triple-quoted string from an earlier line.
        if let q = state.tripleQuote {
            let end = scanString(chars, from: 0, quote: q, triple: true, isF: state.tripleIsF, emit: emit)
            if end.closed {
                state.tripleQuote = nil
                state.tripleIsF = false
            }
            i = end.index
        }
        var lastWord: String?
        while i < n {
            let c = chars[i]
            if c == "#" {
                emit(chars[i..<n], .comment)
                return spans
            }
            if c == "\"" || c == "'" {
                let r = startString(chars, at: i, prefixStart: i, isF: false, state: &state, emit: emit)
                i = r
                lastWord = nil
                continue
            }
            if isIdentStart(c) {
                var j = i
                while j < n && isIdent(chars[j]) { j += 1 }
                let word = String(chars[i..<j])
                // String prefixes: r, b, u, f and two-letter combinations, right before a quote.
                if j < n, (chars[j] == "\"" || chars[j] == "'"), word.count <= 2,
                   word.lowercased().allSatisfy({ "rbuf".contains($0) }) {
                    let isF = word.lowercased().contains("f")
                    i = startString(chars, at: j, prefixStart: i, isF: isF, state: &state, emit: emit)
                    lastWord = nil
                    continue
                }
                let kind: CodeTokenKind
                if lastWord == "def" || lastWord == "class" {
                    kind = .definition
                } else if CodeHighlighter.pythonKeywords.contains(word) {
                    kind = .keyword
                } else if CodeHighlighter.pythonConstants.contains(word) {
                    kind = .constant
                } else if CodeHighlighter.pythonBuiltins.contains(word) && !(i > 0 && chars[i - 1] == ".") {
                    kind = .builtin
                } else {
                    kind = .plain
                }
                emit(chars[i..<j], kind)
                lastWord = word
                i = j
                continue
            }
            if c.isNumber || (c == "." && i + 1 < n && chars[i + 1].isNumber) {
                let j = scanNumber(chars, from: i)
                emit(chars[i..<j], .number)
                lastWord = nil
                i = j
                continue
            }
            if c == "@" {
                // A decorator at the start of a line (after indentation); elsewhere it's matrix multiply.
                let onlySpaceBefore = chars[0..<i].allSatisfy { $0 == " " }
                if onlySpaceBefore {
                    var j = i + 1
                    while j < n && (isIdent(chars[j]) || chars[j] == ".") { j += 1 }
                    emit(chars[i..<j], .decorator)
                    i = j
                    lastWord = nil
                    continue
                }
            }
            emit(chars[i...i], .plain)
            if c != " " { lastWord = nil }
            i += 1
        }
        return spans
    }

    /// Starts a string whose opening quote is at `at` (with any prefix from `prefixStart`).
    /// Returns the index after it (end of line if it doesn't close).
    private static func startString(_ chars: [Character], at q: Int, prefixStart: Int, isF: Bool, state: inout PythonState,
                                    emit: (ArraySlice<Character>, CodeTokenKind) -> Void) -> Int {
        let quote = chars[q]
        let triple = q + 2 < chars.count && chars[q + 1] == quote && chars[q + 2] == quote
        let openEnd = triple ? q + 3 : q + 1
        emit(chars[prefixStart..<openEnd], .string)
        let r = scanString(chars, from: openEnd, quote: quote, triple: triple, isF: isF, emit: emit)
        if triple && !r.closed {
            state.tripleQuote = quote
            state.tripleIsF = isF
        }
        return r.index
    }

    /// Scans string contents from `from` up to and including the closing quote. f-string
    /// replacement fields ({name}) are highlighted as code.
    static func scanString(_ chars: [Character], from: Int, quote: Character, triple: Bool, isF: Bool,
                           emit: (ArraySlice<Character>, CodeTokenKind) -> Void) -> (index: Int, closed: Bool) {
        let n = chars.count
        var i = from
        var runStart = from
        while i < n {
            let c = chars[i]
            if c == "\\" {
                i = min(n, i + 2)
                continue
            }
            if c == quote {
                if triple {
                    if i + 2 < n && chars[i + 1] == quote && chars[i + 2] == quote {
                        emit(chars[runStart..<(i + 3)], .string)
                        return (i + 3, true)
                    }
                } else {
                    emit(chars[runStart...i], .string)
                    return (i + 1, true)
                }
            }
            if isF && c == "{" {
                if i + 1 < n && chars[i + 1] == "{" {
                    i += 2
                    continue
                }
                // A replacement field: find its closing brace (brackets may nest).
                var depth = 0
                var j = i + 1
                var close: Int?
                while j < n {
                    let d = chars[j]
                    if d == "{" || d == "(" || d == "[" { depth += 1 }
                    if d == ")" || d == "]" { depth -= 1 }
                    if d == "}" {
                        if depth == 0 { close = j; break }
                        depth -= 1
                    }
                    if !triple && d == quote && depth == 0 { break }
                    j += 1
                }
                if let close {
                    emit(chars[runStart..<i], .string)
                    emit(chars[i...i], .plain)
                    var inner = PythonState()
                    for span in lex(Array(chars[(i + 1)..<close]), state: &inner) {
                        emit(ArraySlice(Array(span.text)), span.kind == .comment ? .plain : span.kind)
                    }
                    emit(chars[close...close], .plain)
                    i = close + 1
                    runStart = i
                    continue
                }
            }
            i += 1
        }
        emit(chars[runStart..<n], .string)
        // A single-quoted string can't continue onto the next line (unless the line ends with a
        // backslash, which is rare in student code): it just ends here.
        return (n, false)
    }

    static func scanNumber(_ chars: [Character], from: Int) -> Int {
        let n = chars.count
        var i = from
        if chars[i] == "0", i + 1 < n, "xXoObB".contains(chars[i + 1]) {
            i += 2
            while i < n && (chars[i].isHexDigit || chars[i] == "_") { i += 1 }
            return i
        }
        while i < n && (chars[i].isNumber || chars[i] == "_") { i += 1 }
        if i < n && chars[i] == "." && !(i + 1 < n && chars[i + 1] == ".") {
            i += 1
            while i < n && (chars[i].isNumber || chars[i] == "_") { i += 1 }
        }
        if i < n && (chars[i] == "e" || chars[i] == "E") {
            var j = i + 1
            if j < n && (chars[j] == "+" || chars[j] == "-") { j += 1 }
            if j < n && chars[j].isNumber {
                i = j
                while i < n && (chars[i].isNumber || chars[i] == "_") { i += 1 }
            }
        }
        if i < n && (chars[i] == "j" || chars[i] == "J") { i += 1 }
        return i
    }
}

enum PseudocodeLexer {
    static func lex(_ chars: [Character]) -> [CodeSpan] {
        var spans: [CodeSpan] = []
        func emit(_ s: ArraySlice<Character>, _ kind: CodeTokenKind) {
            guard !s.isEmpty else { return }
            if let last = spans.last, last.kind == kind {
                spans[spans.count - 1].text += String(s)
            } else {
                spans.append(CodeSpan(text: String(s), kind: kind))
            }
        }
        let n = chars.count
        var i = 0
        while i < n {
            let c = chars[i]
            // Comments: // or # to the end of the line, or a REM line.
            if (c == "/" && i + 1 < n && chars[i + 1] == "/") || c == "#" {
                emit(chars[i..<n], .comment)
                return spans
            }
            if c == "\"" || c == "'" || c == "“" || c == "‘" {
                let close: Character = c == "“" ? "”" : (c == "‘" ? "’" : c)
                var j = i + 1
                while j < n && chars[j] != close { j += 1 }
                let end = min(n, j + 1)
                emit(chars[i..<end], .string)
                i = end
                continue
            }
            if PythonLexer.isIdentStart(c) {
                var j = i
                while j < n && PythonLexer.isIdent(chars[j]) { j += 1 }
                let word = String(chars[i..<j])
                let upper = word.uppercased()
                if upper == "REM" && chars[0..<i].allSatisfy({ $0 == " " }) {
                    emit(chars[i..<n], .comment)
                    return spans
                }
                let kind: CodeTokenKind
                if CodeHighlighter.pseudocodeKeywordsAnyCase.contains(upper) || CodeHighlighter.pseudocodeKeywordsUpper.contains(word) {
                    kind = .keyword
                } else if CodeHighlighter.pseudocodeConstants.contains(upper) {
                    kind = .constant
                } else {
                    kind = .plain
                }
                emit(chars[i..<j], kind)
                i = j
                continue
            }
            if c.isNumber {
                var j = i
                while j < n && (chars[j].isNumber || (chars[j] == "." && j + 1 < n && chars[j + 1].isNumber)) { j += 1 }
                emit(chars[i..<j], .number)
                i = j
                continue
            }
            emit(chars[i...i], .plain)
            i += 1
        }
        return spans
    }
}
