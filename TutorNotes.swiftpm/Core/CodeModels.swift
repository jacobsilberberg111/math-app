import Foundation

/// A code block on the page: typed code, the input to give it, and what happened the last time it
/// ran. Rendered by CodeRenderer; run by CodeExecution (Python, through Pyodide).
///
/// Every field but `code` is optional when decoding, so notes saved by older versions (which
/// stored only language, code and output) keep opening.
struct CodeContent: Codable, Equatable {
    /// "python" or "pseudocode" (see CodeLanguage). Kept as a string so an unknown value from a
    /// newer version still decodes.
    var language: String = CodeLanguage.python.rawValue
    var code: String
    var title: String?
    /// Program input: one line for each input() call.
    var stdin: String?
    /// The last run: what the program printed (stdout and stderr, in order; input() prompts and
    /// the answers fed to them appear as they would in IDLE).
    var output: String?
    /// The last run's error, shown in red: a cleaned traceback, or why it was stopped. Nil when
    /// the program finished normally.
    var error: String?
    /// When it last ran.
    var ranAt: Date?

    init(language: String = CodeLanguage.python.rawValue, code: String, title: String? = nil, stdin: String? = nil,
         output: String? = nil, error: String? = nil, ranAt: Date? = nil) {
        self.language = language
        self.code = code
        self.title = title
        self.stdin = stdin
        self.output = output
        self.error = error
        self.ranAt = ranAt
    }

    enum CodingKeys: String, CodingKey {
        case language, code, title, stdin, output, error, ranAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? CodeLanguage.python.rawValue
        code = try c.decodeIfPresent(String.self, forKey: .code) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title)
        stdin = try c.decodeIfPresent(String.self, forKey: .stdin)
        output = try c.decodeIfPresent(String.self, forKey: .output)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        ranAt = try c.decodeIfPresent(Date.self, forKey: .ranAt)
    }

    var lang: CodeLanguage { CodeLanguage(loose: language) }
    var isRunnable: Bool { lang.isRunnable }
    /// Whether there's a last run to show (older notes stored output without a date).
    var hasRun: Bool { ranAt != nil || output != nil || error != nil }
    var errored: Bool { error != nil }

    /// The title, or nil when it's blank.
    var displayTitle: String? {
        guard let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// The program input as lines (one per input() call). A trailing empty line from a final
    /// newline is dropped; empty lines in the middle are kept (input() can return "").
    var stdinLines: [String] { CodeText.inputLines(stdin) }

    /// The code's lines as shown on the page (tabs expanded to 4 spaces).
    var displayLines: [String] { CodeText.lines(code) }

    /// A copy with the last run's results cleared (the code or its input changed).
    func clearingRun() -> CodeContent {
        var c = self
        c.output = nil
        c.error = nil
        c.ranAt = nil
        return c
    }
}

enum CodeLanguage: String, CaseIterable, Identifiable {
    case python
    /// NESA-style pseudocode: displayed and highlighted, traced by hand, never run.
    case pseudocode

    var id: String { rawValue }

    /// Accepts the stored value, or something the tutor or an older note might have written.
    init(loose: String?) {
        switch loose?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "pseudocode", "pseudo", "pseudo-code", "algorithm", "nesa": self = .pseudocode
        default: self = .python
        }
    }

    var displayName: String {
        switch self {
        case .python: return "Python"
        case .pseudocode: return "Pseudocode"
        }
    }

    var isRunnable: Bool { self == .python }
}

/// Plain-text helpers for code (Foundation only, unit-tested).
enum CodeText {
    static let tabWidth = 4

    /// Normalises line endings (CRLF and CR to LF). Code from the tutor or a paste can have either.
    static func normalized(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// Lines as displayed: line endings normalised, tabs expanded to the next 4-column stop.
    static func lines(_ code: String) -> [String] {
        normalized(code).components(separatedBy: "\n").map(expandTabs)
    }

    static func expandTabs(_ line: String) -> String {
        guard line.contains("\t") else { return line }
        var out = ""
        var col = 0
        for ch in line {
            if ch == "\t" {
                let n = tabWidth - col % tabWidth
                out += String(repeating: " ", count: n)
                col += n
            } else {
                out.append(ch)
                col += CodeWrap.columns(ch)
            }
        }
        return out
    }

    static func inputLines(_ stdin: String?) -> [String] {
        guard let stdin, !stdin.isEmpty else { return [] }
        var lines = normalized(stdin).components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// The text fed to the program's standard input: each line ends with a newline.
    static func stdinText(_ lines: [String]) -> String {
        lines.map { $0 + "\n" }.joined()
    }

    /// Number of leading spaces (after tab expansion).
    static func indentWidth(_ line: String) -> Int {
        var n = 0
        for ch in expandTabs(line) {
            if ch == " " { n += 1 } else { break }
        }
        return n
    }
}
