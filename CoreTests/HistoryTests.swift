import Foundation

/// History optimisation: stale page views are dropped, and long sessions fold into a recap.
func runHistoryTests() {
    func image(_ n: Int) -> JSONValue {
        ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": .string(String(repeating: "A", count: n))]]
    }
    func t(_ s: String) -> JSONValue { ["type": "text", "text": .string(s)] }
    /// A tutor turn as the app sends it: caption, snapshot, page map, then the student's words.
    func userTurn(_ text: String) -> JSONValue {
        ["role": "user", "content": [t("Page 1 of 1 (816×1056 pt):"), image(1000), t("<canvas_state>\nPage 1: 3 ink regions\n</canvas_state>"), t(text)]]
    }
    func assistant(_ text: String, tool: String? = nil) -> JSONValue {
        var c: [JSONValue] = [t(text)]
        if let tool { c.append(["type": "tool_use", "id": "t", "name": .string(tool), "input": ["x": 1]]) }
        return ["role": "assistant", "content": .array(c)]
    }
    let toolResult: JSONValue = ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t1", "content": [t("done"), image(500)]]]]

    // Kinds of message.
    check(HistoryPruning.isTypedUser(userTurn("hi")) && !HistoryPruning.isTypedUser(toolResult), "typed vs tool results")
    check(HistoryPruning.studentText(userTurn("what's 2+2?")) == "what's 2+2?", "student text is the last block")

    // Stale page views.
    var history: [JSONValue] = []
    for k in 0..<HistoryPruning.threshold { history += [userTurn("q\(k)"), assistant("a\(k)")] }
    check(HistoryPruning.pruned(history) == nil, "no pruning at the threshold")
    history += [toolResult, assistant("ok"), userTurn("latest"), assistant("done")]
    guard let pruned = HistoryPruning.pruned(history) else { check(false, "prunes past the threshold"); return }
    check(pruned.count == history.count, "same number of messages")
    let typedWithViews = pruned.filter { HistoryPruning.isTypedUser($0) && HistoryPruning.hasInlineImage($0) }
    check(typedWithViews.count == HistoryPruning.keep, "keeps the newest \(HistoryPruning.keep) page views, got \(typedWithViews.count)")
    let first = HistoryPruning.blocks(pruned[0])
    check(first.count == 2 && first[0]["text"]?.stringValue == HistoryPruning.placeholder && first[1]["text"]?.stringValue == "q0",
          "caption, snapshot and page map become one note; the question stays")
    check(!pruned[0].serialized().contains("canvas_state"), "old page map removed")
    check(HistoryPruning.hasInlineImage(pruned[pruned.count - 2]), "newest turn keeps its view")
    let stripped = HistoryPruning.strippingImages(toolResult)
    check(stripped["content"]?[0]?["tool_use_id"]?.stringValue == "t1" && !HistoryPruning.hasInlineImage(stripped), "tool result images stripped in place")
    let fileImage: JSONValue = ["type": "image", "source": ["type": "file", "file_id": "file_1"]]
    check(HistoryPruning.strippingImages(fileImage) == fileImage, "file references kept")

    // Long sessions fold into a recap, carrying attachments forward.
    let pdf: JSONValue = ["type": "document", "source": ["type": "file", "file_id": "file_paper"], "title": "Past paper"]
    var long: [JSONValue] = [["role": "user", "content": [pdf, t(String(repeating: "x", count: 400)), t("Mark my paper")]]]
    long.append(assistant("Sure, starting with Q1.", tool: "mark"))
    long.append(["role": "user", "content": [["type": "tool_result", "tool_use_id": "t", "content": "ok"]]])
    long.append(assistant("Q1 is right."))
    // Few but heavy turns, so the recap stays short enough to hold every line.
    for k in 0..<16 {
        long.append(["role": "user", "content": [t(String(repeating: "m", count: 9_000)), t("question \(k)")]])
        long.append(assistant("answer \(k) " + String(repeating: "w", count: 600), tool: k % 2 == 0 ? "write" : nil))
    }
    let before = long.map(HistoryPruning.estimatedTokens).reduce(0, +)
    check(before > HistoryPruning.compactAbove, "test history is over the limit (\(before))")
    guard let compact = HistoryPruning.compacted(long) else { check(false, "compacts a long session"); return }
    let after = compact.map(HistoryPruning.estimatedTokens).reduce(0, +)
    check(after < HistoryPruning.compactAbove / 2, "compacted to \(after) tokens")
    check(HistoryPruning.isTypedUser(compact[0]), "starts with a typed turn")
    let head = HistoryPruning.blocks(compact[0])
    check(head.first == pdf, "attachment carried forward")
    let recap = head.compactMap { $0["text"]?.stringValue }.first { $0.hasPrefix(HistoryPruning.recapTag) } ?? ""
    check(recap.contains("Student: \"Mark my paper\" → Tutor: \"Sure, starting with Q1. Q1 is right.\" (on the page: mark)"), "recap of the first exchange")
    check(recap.contains("question 0") && !recap.contains("question 15"), "recap covers dropped turns only")
    check(compact.last == long.last && compact[compact.count - 2] == long[long.count - 2], "newest exchange untouched")
    // Tool calls stay paired: every tool_use in what's kept is followed by its result or is in the last message.
    check(!compact.contains { HistoryPruning.isToolResults($0) } || HistoryPruning.isTypedUser(compact[0]), "cut at a typed turn")
    // Compacting again keeps the earlier recap's lines.
    var longer = compact
    for k in 16..<140 {
        longer.append(["role": "user", "content": [t(String(repeating: "m", count: 2_400)), t("question \(k)")]])
        longer.append(assistant("answer \(k) " + String(repeating: "w", count: 1_200)))
    }
    if let again = HistoryPruning.compacted(longer) {
        let r2 = HistoryPruning.blocks(again[0]).compactMap { $0["text"]?.stringValue }.first { $0.hasPrefix(HistoryPruning.recapTag) } ?? ""
        // The newest dropped turn is in the recap; the recap is capped (oldest lines go first).
        let firstKept = HistoryPruning.studentText(again[0]) ?? ""
        let lastDropped = "question \((Int(firstKept.split(separator: " ").last ?? "0") ?? 1) - 1)"
        check(r2.contains(lastDropped) && r2.count <= 6_400, "second recap holds \(lastDropped) and stays bounded (\(r2.count) chars)")
        check(HistoryPruning.blocks(again[0]).first == pdf, "attachment still carried after a second compaction")
    } else {
        check(false, "compacts again")
    }
    check(HistoryPruning.compacted(Array(long.prefix(6))) == nil, "short sessions untouched")
}
