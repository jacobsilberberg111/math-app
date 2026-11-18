import Foundation

/// Keeps a tutor conversation small enough to send every turn.
///
/// Each turn carries a fresh snapshot of the page (a base64 image of around 250 KB), and the
/// history kept every one of them: after a long session a note's conversation reached 90
/// snapshots and 23 MB. That was uploaded from the iPad, and read by Claude, on every turn, so
/// replies took minutes. Only the latest snapshots matter (the tutor always gets a new one), so
/// once more than `threshold` turns with images build up, all but the newest `keep` are replaced
/// with a short note. Pruning in one go, rather than a little every turn, means the prompt cache
/// is rebuilt only now and then.
enum HistoryPruning {
    static let threshold = 12
    static let keep = 4
    static let placeholder = "[Earlier page snapshot removed to keep the conversation small.]"

    /// Whether a message holds an inline (base64) image anywhere, including inside tool results.
    static func hasInlineImage(_ v: JSONValue) -> Bool {
        switch v {
        case .object(let o):
            if isInlineImage(o) { return true }
            return o.values.contains(where: hasInlineImage)
        case .array(let a):
            return a.contains(where: hasInlineImage)
        default:
            return false
        }
    }

    private static func isInlineImage(_ o: [String: JSONValue]) -> Bool {
        o["type"]?.stringValue == "image" && o["source"]?["type"]?.stringValue == "base64"
    }

    /// The value with every inline image replaced by a short text block.
    static func strippingImages(_ v: JSONValue) -> JSONValue {
        switch v {
        case .object(let o):
            if isInlineImage(o) { return ["type": "text", "text": .string(placeholder)] }
            var out: [String: JSONValue] = [:]
            for (k, x) in o { out[k] = strippingImages(x) }
            return .object(out)
        case .array(let a):
            return .array(a.map(strippingImages))
        default:
            return v
        }
    }

    /// Returns the pruned history, or nil when nothing needs to change.
    static func pruned(_ messages: [JSONValue]) -> [JSONValue]? {
        let withImages = messages.indices.filter { messages[$0]["role"]?.stringValue == "user" && hasInlineImage(messages[$0]) }
        guard withImages.count > threshold else { return nil }
        let cutoff = withImages[withImages.count - keep]
        var out = messages
        for i in withImages where i < cutoff { out[i] = strippingImages(out[i]) }
        return out
    }
}
