import Foundation

/// Reads handwritten math as LaTeX with one small request to Claude (Haiku: no tools, no
/// thinking). It only transcribes; the student checks the result before it replaces their ink.
enum MathTranscriber {
    static let prompt = """
    You transcribe handwritten mathematics from an image into LaTeX.

    - Transcribe exactly what is written, one entry per written line, top to bottom. Never solve, simplify, complete or correct anything, even if the working contains a mistake.
    - Use this LaTeX: \\frac{a}{b}, \\sqrt{x}, x^{2}, x_{1}, \\int_{0}^{1}, \\sum, \\lim, \\left( \\right), pmatrix, Greek letters, \\times, \\cdot, \\pm, \\le, \\ge, \\ne, \\approx, \\to. Put words inside \\text{...}. Do not wrap lines in $ or \\[ \\].
    - If a symbol is unclear, give your best reading rather than leaving it out.
    - Reply with only JSON, with no commentary and no code fences: {"lines": ["...", "..."]}. If there is no readable mathematics, reply {"lines": [], "error": "unreadable"}.
    """

    static func requestBody(png: Data) -> JSONValue {
        let source: JSONValue = ["type": "base64", "media_type": "image/png", "data": .string(png.base64EncodedString())]
        let image: JSONValue = ["type": "image", "source": source]
        let ask: JSONValue = ["type": "text", "text": "Transcribe the handwritten math in this image."]
        let message: JSONValue = ["role": "user", "content": [image, ask]]
        return .object([
            "model": .string(ClaudeModelOption.haiku.id),
            "max_tokens": 1024,
            "stream": true,
            "system": [["type": "text", "text": .string(prompt)]],
            "messages": [message],
        ])
    }

    /// The LaTeX lines for an image of handwritten math. Empty when Claude can't read any.
    static func transcribe(png: Data, client: AnthropicClient) async throws -> [String] {
        var reply = ""
        for try await event in client.streamMessage(body: requestBody(png: png), betas: []) {
            if case .textDelta(_, let delta) = event { reply += delta }
        }
        // A cancelled stream just ends: don't mistake what arrived so far for the answer.
        try Task.checkCancellation()
        return parse(reply)
    }

    // MARK: Reading the reply

    /// `{"lines": [...]}` as asked for, even when fenced or cut off; otherwise one line per line of text.
    static func parse(_ reply: String) -> [String] {
        let text = reply.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            .joined(separator: "\n")
            .trimmed
        if let json = jsonObject(in: text) {
            return (json["lines"]?.arrayValue ?? []).compactMap(\.stringValue).map(clean).filter { !$0.isEmpty }
        }
        return text.split(separator: "\n").map { clean(String($0)) }.filter { !$0.isEmpty }
    }

    private static func jsonObject(in text: String) -> JSONValue? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        if let end = text.lastIndex(of: "}"), end > start,
           let json = try? JSONValue.parse(String(text[start...end])), json.objectValue != nil {
            return json
        }
        // Cut off by the token limit: keep the lines that did arrive.
        guard let partial = JSONValue.parsePartial(String(text[start...])), partial.objectValue != nil else { return nil }
        return partial
    }

    /// A line without the `$…$`, `$$…$$`, `\(…\)` or `\[…\]` the model sometimes adds around it.
    static func clean(_ line: String) -> String {
        var s = line.trimmed
        for (open, close) in [("$$", "$$"), ("$", "$"), ("\\[", "\\]"), ("\\(", "\\)")] where s.hasPrefix(open) && s.hasSuffix(close) {
            let inner = String(s.dropFirst(open.count).dropLast(close.count))
            guard s.count >= open.count + close.count, !inner.contains(close) else { continue }
            s = inner.trimmed
            break
        }
        return s
    }
}
