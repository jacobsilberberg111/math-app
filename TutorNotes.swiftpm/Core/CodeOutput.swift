import Foundation

/// Cutting long program output down to size (for the card, the stored block and the tutor).
enum CodeOutputText {
    /// The text cut to at most `maxLines` lines and `maxChars` characters, ending with an
    /// "…" line when anything was left out.
    static func limited(_ s: String, maxChars: Int, maxLines: Int) -> (text: String, truncated: Bool) {
        var count = 0
        var lines = 0
        var cut: String.Index?
        var i = s.startIndex
        while i < s.endIndex {
            if count >= maxChars || lines >= maxLines {
                cut = i
                break
            }
            if s[i] == "\n" { lines += 1 }
            count += 1
            i = s.index(after: i)
        }
        guard let cut else { return (s, false) }
        var head = String(s[..<cut])
        if !head.hasSuffix("\n") && !head.isEmpty { head += "\n" }
        let restLines = s[cut...].reduce(0) { $1 == "\n" ? $0 + 1 : $0 } + (s.hasSuffix("\n") ? 0 : 1)
        return (head + "… (\(restLines) more line\(restLines == 1 ? "" : "s") not shown)", true)
    }

    /// The first `n` lines, for short summaries.
    static func firstLines(_ s: String, _ n: Int) -> String {
        let lines = CodeText.normalized(s).components(separatedBy: "\n")
        let shown = lines.prefix(n).joined(separator: "\n")
        return lines.count > n ? shown + "\n…" : shown
    }
}

/// Turning Python's tracebacks into what a student needs: their own lines and the error.
enum CodeTraceback {
    /// The file name the runner compiles student code under.
    static let userFile = "main.py"

    /// Drops frames that aren't the student's code (the runner, Pyodide internals), rewrites
    /// `File "main.py", line 3, in <module>` as `Line 3` (or `Line 7, in average` inside a
    /// function), and drops Python 3.11+'s ~~~^^^ expression underlines. Carets that point at
    /// a name or at a syntax error are kept.
    static func clean(_ raw: String, userFile: String = userFile) -> String {
        let lines = CodeText.normalized(raw).components(separatedBy: "\n")
        enum Frame { case none, user(runtime: Bool), other }
        var frame = Frame.none
        var out: [String] = []
        // A "Traceback (most recent call last):" header waiting to see whether any of the
        // student's own frames follow it. Without one (only runner frames, or a syntax error,
        // which Python reports without a header) it is dropped.
        var pendingHeader: Int?
        func dropPendingHeader() {
            if let h = pendingHeader, h < out.count { out.remove(at: h) }
            pendingHeader = nil
        }
        for line in lines {
            if let f = parseFrame(line) {
                if f.file == userFile {
                    if f.function == nil { dropPendingHeader() } else { pendingHeader = nil }
                    out.append(f.function.map { $0 == "<module>" ? "  Line \(f.line)" : "  Line \(f.line), in \($0)" } ?? "  Line \(f.line)")
                    frame = .user(runtime: f.function != nil)
                } else {
                    frame = .other
                }
                continue
            }
            let indent = line.prefix { $0 == " " }.count
            if indent >= 4 {
                switch frame {
                case .user(let runtime):
                    if runtime && isUnderline(line) { continue }
                    out.append(line)
                case .other:
                    continue
                case .none:
                    out.append(line)
                }
                continue
            }
            frame = .none
            if line.hasPrefix("Traceback (most recent call last)") {
                dropPendingHeader()
                out.append(line)
                pendingHeader = out.count - 1
                continue
            }
            if !line.isEmpty && !line.hasPrefix("  [Previous line repeated") { dropPendingHeader() }
            if !line.isEmpty || out.last?.isEmpty == false {
                out.append(line)
            }
        }
        dropPendingHeader()
        var result = out
        while result.last?.isEmpty == true { result.removeLast() }
        while result.first?.isEmpty == true { result.removeFirst() }
        var text = result.joined(separator: "\n")
        if let hint = hint(for: text) { text += "\n" + hint }
        return text
    }

    /// `  File "x.py", line 12, in f` → (x.py, 12, f); syntax error locations have no function.
    static func parseFrame(_ line: String) -> (file: String, line: Int, function: String?)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("  File \"") || line.hasPrefix("File \""), t.hasPrefix("File \"") else { return nil }
        let afterFile = t.dropFirst(6)
        guard let q = afterFile.firstIndex(of: "\"") else { return nil }
        let file = String(afterFile[..<q])
        var rest = afterFile[afterFile.index(after: q)...]
        guard rest.hasPrefix(", line ") else { return nil }
        rest = rest.dropFirst(7)
        let digits = rest.prefix { $0.isNumber }
        guard let n = Int(digits) else { return nil }
        rest = rest.dropFirst(digits.count)
        var function: String?
        if rest.hasPrefix(", in ") { function = String(rest.dropFirst(5)) }
        return (file, n, function)
    }

    /// Python 3.11+'s `~~~~^^^~~` underline under an expression in a runtime frame. A plain
    /// `^^^^` (under a single name, as in a NameError) is kept: it points at the word.
    static func isUnderline(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && t.contains("~") && t.allSatisfy { $0 == "^" || $0 == "~" }
    }

    /// The last line of the error ("NameError: name 'x' is not defined") and the student's line
    /// it happened on (the innermost frame), from a cleaned traceback.
    static func summary(_ cleaned: String) -> (message: String, line: Int?) {
        let lines = cleaned.components(separatedBy: "\n")
        var lineNumber: Int?
        for l in lines where l.hasPrefix("  Line ") {
            let digits = l.dropFirst(7).prefix { $0.isNumber }
            if let n = Int(digits) { lineNumber = n }
        }
        let message = lines.last { !$0.isEmpty && !$0.hasPrefix(" ") && !$0.hasPrefix("(") && !$0.hasPrefix("Traceback") }
            ?? lines.last { !$0.isEmpty } ?? ""
        return (message, lineNumber)
    }

    /// A plain-words note for errors a student hits when Python here can't do what IDLE can.
    static func hint(for text: String) -> String? {
        let lower = text.lowercased()
        if lower.contains("modulenotfounderror") && (lower.contains("'turtle'") || lower.contains("'tkinter'") || lower.contains("'pygame'")) {
            return "(Turtle graphics and windows can't open inside a code block: there's no screen to draw on here.)"
        }
        return nil
    }
}

/// What came back from running a program.
struct CodeRunResult: Equatable {
    enum Status: String, Equatable {
        /// Ran to the end.
        case finished
        /// Stopped with a Python error.
        case failed
        /// Still running when time ran out; stopped.
        case timedOut
        /// Python itself stopped (e.g. the browser engine ran out of stack); it's restarted.
        case crashed
        /// Python couldn't start (usually no internet the first time).
        case unavailable
        /// Stopped on request.
        case cancelled
    }

    var status: Status
    /// What the program printed (capped).
    var output: String = ""
    /// Shown in red: the cleaned traceback, or why it stopped.
    var error: String?
    var outputTruncated = false
    var seconds: Double = 0
    /// Technical detail (why Python couldn't start), for the tutor and logs.
    var detail: String?

    /// Whether the program actually ran (so the result belongs on the block).
    var ran: Bool { status != .unavailable && status != .cancelled }

    static let unavailableMessage = "Python couldn't start. It needs an internet connection the first time it starts: check you're online, then tap Run again."

    static func timeoutMessage(_ seconds: Double) -> String {
        "Stopped after \(Int(seconds.rounded())) seconds: the program was still running. Is there a loop that never ends? (A while loop needs something inside it that eventually makes its condition false.)"
    }

    /// Builds the result from what the runner page returned (a JSON-like dictionary).
    static func fromRunner(_ d: [String: Any], timeout: Double) -> CodeRunResult {
        let status = d["status"] as? String ?? "crashed"
        var output = d["output"] as? String ?? ""
        let rawError = d["error"] as? String ?? ""
        let truncatedFlag = (d["truncated"] as? Bool) ?? ((d["truncated"] as? NSNumber)?.boolValue ?? false)
        let ms = (d["ms"] as? Double) ?? (d["ms"] as? NSNumber)?.doubleValue ?? 0
        let message = d["message"] as? String ?? ""
        let limited = CodeOutputText.limited(output, maxChars: 20_000, maxLines: 1_000)
        output = limited.text
        var r = CodeRunResult(status: .crashed, output: output, error: nil, outputTruncated: truncatedFlag || limited.truncated,
                              seconds: ms / 1000)
        switch status {
        case "ok":
            r.status = .finished
        case "error":
            r.status = .failed
            let cleaned = CodeTraceback.clean(rawError)
            r.error = cleaned.isEmpty ? rawError : cleaned
        case "timeout":
            r.status = .timedOut
            r.error = timeoutMessage(timeout)
            r.seconds = timeout
        case "unavailable":
            r.status = .unavailable
            r.error = unavailableMessage
            r.detail = message.isEmpty ? nil : message
        case "cancelled":
            r.status = .cancelled
            r.error = "Stopped."
        default:
            r.status = .crashed
            r.error = "Python stopped unexpectedly\(message.isEmpty ? "" : " (\(message))"). This can happen when a function calls itself too many times. Python has been restarted: tap Run to try again."
        }
        if truncatedFlag && !limited.truncated && r.status != .unavailable {
            r.output += r.output.hasSuffix("\n") || r.output.isEmpty ? "… (output cut short)" : "\n… (output cut short)"
        }
        return r
    }

    /// The block with this run stored on it.
    func applied(to c: CodeContent, at date: Date) -> CodeContent {
        var c = c
        let stored = CodeOutputText.limited(output, maxChars: 8_000, maxLines: 300).text
        c.output = stored.isEmpty ? nil : stored
        c.error = error
        c.ranAt = date
        return c
    }

    /// A short line for status displays ("Finished in 0.3 s", "Error on line 4").
    var headline: String {
        switch status {
        case .finished: return seconds < 0.05 ? "Finished" : "Finished in \(String(format: "%.1f", seconds)) s"
        case .failed:
            let s = CodeTraceback.summary(error ?? "")
            return s.line.map { "Error on line \($0)" } ?? "Error"
        case .timedOut: return "Stopped: took too long"
        case .crashed: return "Python stopped"
        case .unavailable: return "Python couldn't start"
        case .cancelled: return "Stopped"
        }
    }

    /// What the tutor's tool result says about the run.
    func report(subject: String, inputLines: Int, maxOutput: Int = 3_000, maxError: Int = 1_200) -> String {
        var s = "Ran \(subject)"
        if inputLines > 0 { s += " with \(inputLines) line\(inputLines == 1 ? "" : "s") of program input" }
        switch status {
        case .finished:
            s += ". It finished in \(String(format: "%.1f", seconds)) s with no errors."
        case .failed:
            let sum = CodeTraceback.summary(error ?? "")
            s += ". It stopped with an error" + (sum.line.map { " on line \($0)" } ?? "") + ": \(sum.message)"
        case .timedOut:
            s += ". It was still running after \(Int(seconds.rounded())) s and was stopped (probably a loop that never ends)."
        case .crashed:
            s += ". Python itself crashed (often runaway recursion) and was restarted."
        case .unavailable:
            return "Python isn't available right now (it needs an internet connection the first time it starts\(detail.map { "; \($0)" } ?? "")). Don't guess the output: trace the code by hand, or ask the student to run it when they're online."
        case .cancelled:
            return "The run was stopped before it finished."
        }
        if output.isEmpty {
            s += "\nIt printed nothing."
        } else {
            let o = CodeOutputText.limited(output, maxChars: maxOutput, maxLines: 120).text
            s += "\n\(status == .finished ? "Output" : "Output before it stopped") (input() prompts and the answers fed in appear as typed):\n" + o
        }
        if status == .failed, let error, !error.isEmpty {
            s += "\nError:\n" + CodeOutputText.limited(error, maxChars: maxError, maxLines: 40).text
        }
        return s
    }
}

/// Small text rules for the code editor: auto-indent and dedent.
enum CodeEditing {
    static let indentUnit = "    "

    /// The indentation for a new line typed after `line` (the text of the current line up to the
    /// cursor): the same as that line, one level more after a line ending in ":" (Python) or a
    /// block-opening keyword (pseudocode), one level less after return/pass/break/continue/raise.
    static func newlineIndent(after line: String, language: CodeLanguage) -> String {
        let width = CodeText.indentWidth(line)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var level = width
        switch language {
        case .python:
            // Ignore a trailing comment ("if x:  # check") but not a # inside a string.
            let spans = CodeHighlighter.highlight(trimmed, language: .python).first ?? []
            let code = spans.filter { $0.kind != .comment }.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            let firstWord = code.prefix { $0.isLetter }
            if code.hasSuffix(":") {
                level += indentUnit.count
            } else if ["return", "pass", "break", "continue", "raise"].contains(String(firstWord)) {
                level = max(0, level - indentUnit.count)
            }
        case .pseudocode:
            let first = trimmed.prefix { $0.isLetter }.uppercased()
            let opens = ["BEGIN", "IF", "ELSE", "ELSEIF", "WHILE", "FOR", "REPEAT", "CASEWHERE", "OTHERWISE"]
            if opens.contains(first) || (trimmed.hasSuffix(":") && !trimmed.isEmpty) {
                level += indentUnit.count
            }
        }
        return String(repeating: " ", count: level)
    }

    /// The line with one level of indentation removed (to the previous multiple of 4), and how
    /// many characters went.
    static func dedent(_ line: String) -> (line: String, removed: Int) {
        let spaces = line.prefix { $0 == " " }.count
        guard spaces > 0 else { return (line, 0) }
        let remove = spaces % indentUnit.count == 0 ? indentUnit.count : spaces % indentUnit.count
        return (String(line.dropFirst(remove)), remove)
    }
}
