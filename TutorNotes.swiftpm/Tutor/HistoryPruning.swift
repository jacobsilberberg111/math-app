import Foundation

/// Keeps a conversation small enough to send every turn.
///
/// Every request resends the whole history, so cost and speed track its size. Two things
/// make it grow:
/// 1. **Stale page views.** Each tutor turn carries fresh snapshots of the page (base64 images,
///    about 1.2k tokens each) and a text map of it (`<canvas_state>`). Only the newest matter.
///    Once more than `threshold` turns carry them, all but the newest `keep` are swapped for a
///    one-line note. (One note had reached 90 snapshots, 23 MB, and two-minute replies.)
/// 2. **Long sessions.** Past `compactAbove` estimated tokens, the oldest exchanges are folded
///    into a short written recap at the start of what's kept (about `compactTo` tokens of the
///    newest turns). Attached files (PDFs, images sent by file id) are carried forward, never
///    dropped.
/// Both happen in one go when their limit is crossed, so the prompt cache is rebuilt only now
/// and then rather than every turn.
enum HistoryPruning {
    static let threshold = 8
    static let keep = 2
    static let compactAbove = 24_000
    static let compactTo = 10_000
    static let placeholder = "[Earlier page view removed to keep the conversation small.]"
    static let recapTag = "<earlier_in_this_session>"

    // MARK: Message kinds

    static func blocks(_ m: JSONValue) -> [JSONValue] { m["content"]?.arrayValue ?? [] }

    static func isToolResults(_ m: JSONValue) -> Bool {
        m["role"]?.stringValue == "user" && blocks(m).contains { $0["type"]?.stringValue == "tool_result" }
    }

    /// A message the student (or the app on their behalf) started, as opposed to tool results.
    static func isTypedUser(_ m: JSONValue) -> Bool {
        guard m["role"]?.stringValue == "user" else { return false }
        if m["content"]?.stringValue != nil { return true }
        return !isToolResults(m)
    }

    private static func isInlineImage(_ o: JSONValue) -> Bool {
        o["type"]?.stringValue == "image" && o["source"]?["type"]?.stringValue == "base64"
    }

    private static func text(_ b: JSONValue) -> String? {
        b["type"]?.stringValue == "text" ? b["text"]?.stringValue : nil
    }

    /// Whether a message holds an inline (base64) image anywhere, including inside tool results.
    static func hasInlineImage(_ v: JSONValue) -> Bool {
        switch v {
        case .object(let o):
            if isInlineImage(v) { return true }
            return o.values.contains(where: hasInlineImage)
        case .array(let a):
            return a.contains(where: hasInlineImage)
        default:
            return false
        }
    }

    private static func hasPageView(_ m: JSONValue) -> Bool {
        hasInlineImage(m) || blocks(m).contains { text($0)?.hasPrefix("<canvas_state>") == true }
    }

    // MARK: Stale page views

    /// The value with every inline image replaced by a short text block.
    static func strippingImages(_ v: JSONValue) -> JSONValue {
        switch v {
        case .object(let o):
            if isInlineImage(v) { return ["type": "text", "text": .string(placeholder)] }
            var out: [String: JSONValue] = [:]
            for (k, x) in o { out[k] = strippingImages(x) }
            return .object(out)
        case .array(let a):
            return .array(a.map(strippingImages))
        default:
            return v
        }
    }

    /// A typed turn without its page view: snapshots, their captions and the page map go; the
    /// student's words, attachments and anything else stay. One placeholder marks the spot.
    static func strippingPageView(_ m: JSONValue) -> JSONValue {
        guard case .object(var o) = m, let content = o["content"]?.arrayValue else { return m }
        var out: [JSONValue] = []
        var marked = false
        for (i, b) in content.enumerated() {
            let captionBeforeImage = text(b) != nil && i + 1 < content.count && isInlineImage(content[i + 1])
            let drop = isInlineImage(b) || captionBeforeImage || text(b)?.hasPrefix("<canvas_state>") == true
            if drop {
                if !marked { out.append(["type": "text", "text": .string(placeholder)]); marked = true }
            } else {
                out.append(b)
            }
        }
        o["content"] = .array(out)
        return .object(o)
    }

    /// Returns the history with stale page views removed, or nil when nothing needs to change.
    static func pruned(_ messages: [JSONValue]) -> [JSONValue]? {
        let views = messages.indices.filter { isTypedUser(messages[$0]) && hasPageView(messages[$0]) }
        guard views.count > threshold else { return nil }
        let cutoff = views[views.count - keep]
        var out = messages
        for i in out.indices where i < cutoff {
            if isTypedUser(out[i]), hasPageView(out[i]) {
                out[i] = strippingPageView(out[i])
            } else if isToolResults(out[i]), hasInlineImage(out[i]) {
                out[i] = strippingImages(out[i])
            }
        }
        return out
    }

    // MARK: Size

    private static func imageCount(_ v: JSONValue) -> Int {
        switch v {
        case .object(let o):
            if o["type"]?.stringValue == "image" { return 1 }
            return o.values.reduce(0) { $0 + imageCount($1) }
        case .array(let a):
            return a.reduce(0) { $0 + imageCount($1) }
        default:
            return 0
        }
    }

    /// A rough token count: about four characters per token, 1,250 per image. (Attached PDFs
    /// sent by file id are counted only by their reference; they're carried forward anyway.)
    static func estimatedTokens(_ m: JSONValue) -> Int {
        let textual = strippingImages(m).serialized().count
        return textual / 4 + imageCount(m) * 1_250
    }

    // MARK: Recap

    private static func clip(_ s: String, _ n: Int) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return t.count <= n ? t : String(t.prefix(n)) + "…"
    }

    /// What the student typed in a turn: its last plain text block (not a page map, caption,
    /// placeholder or recap).
    static func studentText(_ m: JSONValue) -> String? {
        if let s = m["content"]?.stringValue { return s }
        guard let last = blocks(m).last, let t = text(last) else { return nil }
        if t.hasPrefix("<") || t == placeholder { return nil }
        return t
    }

    /// Folds the oldest exchanges into a recap once the history passes `compactAbove` tokens.
    /// Returns nil when nothing needs to change.
    static func compacted(_ messages: [JSONValue]) -> [JSONValue]? {
        let sizes = messages.map(estimatedTokens)
        guard sizes.reduce(0, +) > compactAbove else { return nil }
        let starts = messages.indices.filter { isTypedUser(messages[$0]) }
        guard starts.count >= 3 else { return nil }
        // The oldest turn start whose suffix fits in compactTo, but always keep the last two exchanges.
        var keepFrom = starts[starts.count - 2]
        for s in starts.reversed() {
            if sizes[s...].reduce(0, +) <= compactTo { keepFrom = s } else { break }
        }
        keepFrom = min(keepFrom, starts[starts.count - 2])
        guard keepFrom > starts[0] else { return nil }

        var carried: [JSONValue] = []
        var previousRecap = ""
        var lines: [String] = []
        var i = 0
        while i < keepFrom {
            let m = messages[i]
            if isTypedUser(m) {
                for b in blocks(m) {
                    let type = b["type"]?.stringValue
                    if type == "document" || (type == "image" && b["source"]?["type"]?.stringValue == "file") {
                        carried.append(b)
                    } else if let t = text(b), t.hasPrefix(recapTag) {
                        previousRecap = t
                            .replacingOccurrences(of: recapTag, with: "")
                            .replacingOccurrences(of: "</earlier_in_this_session>", with: "")
                            .components(separatedBy: "\n").filter { $0.hasPrefix("- ") }.joined(separator: "\n")
                    }
                }
                // This exchange: the student's words, then what the tutor said and did.
                var tutorText = ""
                var tools: [String] = []
                var j = i + 1
                while j < keepFrom, !isTypedUser(messages[j]) {
                    if messages[j]["role"]?.stringValue == "assistant" {
                        for b in blocks(messages[j]) {
                            if let t = text(b) { tutorText += t + " " }
                            if b["type"]?.stringValue == "tool_use", let name = b["name"]?.stringValue { tools.append(name) }
                        }
                    }
                    j += 1
                }
                let asked = studentText(m).map { "Student: \"\(clip($0, 220))\"" } ?? "Student: (page check)"
                var line = "- \(asked)"
                if !tutorText.trimmingCharacters(in: .whitespaces).isEmpty { line += " → Tutor: \"\(clip(tutorText, 300))\"" }
                if !tools.isEmpty {
                    let counts = Dictionary(tools.map { ($0, 1) }, uniquingKeysWith: +)
                    line += " (on the page: " + counts.sorted { $0.key < $1.key }.map { $0.value > 1 ? "\($0.key) ×\($0.value)" : $0.key }.joined(separator: ", ") + ")"
                }
                lines.append(line)
                i = j
            } else {
                i += 1
            }
        }
        var body = ([previousRecap] + lines).filter { !$0.isEmpty }.joined(separator: "\n")
        if body.count > 6_000 {
            // Keep the most recent part of the recap.
            body = "- …\n" + String(body.suffix(6_000))
        }
        let recap = "\(recapTag)\nEarlier turns of this session, shortened to save space. The page shows the work itself.\n\(body)\n</earlier_in_this_session>"

        var kept = Array(messages[keepFrom...])
        guard case .object(var first) = kept[0] else { return nil }
        var content = blocks(kept[0])
        if content.isEmpty, let s = kept[0]["content"]?.stringValue { content = [["type": "text", "text": .string(s)]] }
        first["content"] = .array(carried + [["type": "text", "text": .string(recap)]] + content)
        kept[0] = .object(first)
        return kept
    }

    /// Both steps, for the tutor before each new turn.
    static func optimized(_ messages: [JSONValue]) -> [JSONValue]? {
        var changed = false
        var m = messages
        if let p = pruned(m) { m = p; changed = true }
        if let c = compacted(m) { m = c; changed = true }
        return changed ? m : nil
    }
}
