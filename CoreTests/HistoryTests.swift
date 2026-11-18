import Foundation

/// Tutor history pruning: old page snapshots are swapped for a note once too many build up.
func runHistoryTests() {
    func image(_ n: Int) -> JSONValue {
        ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": .string(String(repeating: "A", count: n))]]
    }
    func userTurn(_ text: String) -> JSONValue {
        ["role": "user", "content": [image(1000), ["type": "text", "text": .string(text)]]]
    }
    let assistant: JSONValue = ["role": "assistant", "content": [["type": "text", "text": "ok"]]]
    // A tool result that includes an image (e.g. a crop the tutor asked for).
    let toolResult: JSONValue = ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t1", "content": [["type": "text", "text": "done"], image(500)]]]]

    var history: [JSONValue] = []
    for k in 0..<HistoryPruning.threshold {
        history += [userTurn("q\(k)"), assistant]
    }
    check(HistoryPruning.pruned(history) == nil, "no pruning at the threshold")

    history += [toolResult, assistant, userTurn("latest"), assistant]
    guard let pruned = HistoryPruning.pruned(history) else { check(false, "prunes past the threshold"); return }
    check(pruned.count == history.count, "same number of messages")
    let withImages = pruned.filter(HistoryPruning.hasInlineImage)
    check(withImages.count == HistoryPruning.keep, "keeps the newest \(HistoryPruning.keep) snapshots, got \(withImages.count)")
    check(HistoryPruning.hasInlineImage(pruned[pruned.count - 2]), "newest turn keeps its image")
    check(!HistoryPruning.hasInlineImage(pruned[0]), "oldest turn loses its image")
    // The student's words and the placeholder are both there.
    let first = pruned[0]["content"]?.arrayValue ?? []
    check(first.count == 2 && first[0]["text"]?.stringValue == HistoryPruning.placeholder && first[1]["text"]?.stringValue == "q0", "image swapped for a note, text kept")
    // Tool results keep their shape.
    let stripped = HistoryPruning.strippingImages(toolResult)
    let inner = stripped["content"]?[0]?["content"]?.arrayValue ?? []
    check(inner.count == 2 && stripped["content"]?[0]?["tool_use_id"]?.stringValue == "t1" && !HistoryPruning.hasInlineImage(stripped), "tool result images stripped in place")
    // File-based images and documents are left alone (they're tiny references).
    let fileImage: JSONValue = ["type": "image", "source": ["type": "file", "file_id": "file_1"]]
    check(HistoryPruning.strippingImages(fileImage) == fileImage, "file references kept")
    check(pruned.map { $0.serialized().count }.reduce(0, +) < history.map { $0.serialized().count }.reduce(0, +) / 2, "history shrinks")
}
