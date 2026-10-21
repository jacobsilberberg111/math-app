import SwiftUI
import PencilKit
import UniformTypeIdentifiers

enum TutorSuggestion: Equatable {
    case stuck(question: Int, elementID: String)
    /// The tutor wrote somewhere the student isn't looking (`docRect` in document coordinates).
    case offscreen(page: Int, docRect: CGRect, onBoard: Bool)

    var title: String {
        switch self {
        case .stuck(let q, _): return "Stuck on Q\(q)? Get a hint"
        case .offscreen(let p, _, let onBoard): return onBoard ? "Tutor wrote nearby: show me" : "Tutor wrote on page \(p + 1)"
        }
    }

    var symbol: String {
        switch self {
        case .stuck: return "lightbulb"
        case .offscreen: return "arrow.down.doc"
        }
    }
}

/// The tutor's brain for one open note: runs the Claude tool-use loop, streams its writing onto
/// the canvas, watches the student work, and keeps the conversation history.
///
/// History is append-only (we never edit or drop earlier turns) so prompt caching stays warm and
/// thinking blocks stay valid; the only exception is discarding a failed or declined turn from
/// the end, which leaves every earlier block's prefix untouched.
@MainActor
@Observable
final class TutorEngine {
    // UI state
    var chat: [ChatItem] = []
    var isBusy = false
    var isObserving = false
    var statusText: String?
    var watching: Bool
    var suggestion: TutorSuggestion?
    var uploading: Set<String> = []
    var lastErrorRetryable = false

    @ObservationIgnored let document: NoteDocument
    @ObservationIgnored weak var canvas: NoteCanvasViewController? {
        didSet {
            executor.canvas = canvas
            observerExecutor.canvas = canvas
        }
    }
    @ObservationIgnored let memory = TutorMemoryStore.shared
    @ObservationIgnored let executor: CanvasActionExecutor
    /// Separate executor for proactive glances so they never mix with a chat turn's records.
    @ObservationIgnored let observerExecutor: CanvasActionExecutor
    @ObservationIgnored private var apiMessages: [JSONValue] = []
    @ObservationIgnored private var session = TutorSessionFile()
    @ObservationIgnored var turnRecords: [UUID: TurnRecord] = [:]
    @ObservationIgnored private var currentTask: Task<Void, Never>?
    @ObservationIgnored private var observerTask: Task<Void, Never>?
    @ObservationIgnored private var glanceTimer: Task<Void, Never>?
    @ObservationIgnored private var stuckTimer: Task<Void, Never>?
    @ObservationIgnored var pendingWriting: [CGRect] = []
    @ObservationIgnored var recentWriting: [(Date, CGRect)] = []
    @ObservationIgnored private var lastLook = Date.distantPast
    @ObservationIgnored private var glanceLog: [Date] = []
    @ObservationIgnored private var lastStrokeDate = Date.distantPast
    @ObservationIgnored private var pendingNotes: [String] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Bumped by `newSession()` so a turn still unwinding from the old session can't touch the new one.
    @ObservationIgnored private var sessionGeneration = 0

    var settings: AppSettings { .shared }

    init(document: NoteDocument) {
        self.document = document
        self.executor = CanvasActionExecutor(document: document, memory: TutorMemoryStore.shared)
        self.observerExecutor = CanvasActionExecutor(document: document, memory: TutorMemoryStore.shared)
        self.watching = AppSettings.shared.proactive
        observerExecutor.allowsStudyTools = false
        load()
        startStuckWatcher()
    }

    var sessionURL: URL { document.folder.appendingPathComponent("tutor.json") }

    var hasConversation: Bool { !apiMessages.isEmpty }

    var modelOption: ClaudeModelOption { settings.modelOption }

    // MARK: Persistence

    private func load() {
        guard let file = Storage.read(TutorSessionFile.self, from: sessionURL) else { return }
        session = file
        chat = file.chat.map { var c = $0; c.isStreaming = false; c.canRevert = false; return c }
        if let parsed = try? JSONValue.parse(file.apiMessagesJSON), let arr = parsed.arrayValue {
            apiMessages = arr
        }
        pendingNotes = file.observerNotes
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        session.apiMessagesJSON = JSONValue.array(apiMessages).serialized()
        session.chat = chat
        session.observerNotes = pendingNotes
        let snapshot = session
        let url = sessionURL
        Storage.ioQueue.async { try? Storage.write(snapshot, to: url) }
        if !document.meta.hasTutorSession && !apiMessages.isEmpty {
            document.meta.hasTutorSession = true
            document.markDirty()
        }
    }

    /// Starts a fresh conversation (keeps the canvas as it is).
    func newSession() {
        stop()
        sessionGeneration += 1
        apiMessages = []
        chat = []
        pendingNotes = []
        session = TutorSessionFile()
        turnRecords.removeAll()
        suggestion = nil
        saveNow()
    }

    // MARK: Public actions

    func send(_ text: String, focus: (page: Int, rect: CGRect)? = nil, displayText: String? = nil, allPages: Bool = false) {
        let trimmed = text.trimmed
        guard !trimmed.isEmpty else { return }
        guard settings.isTutorConfigured else {
            chat.append(ChatItem(role: .notice, text: "Connect your tutor in Settings (tutor server or API key) to start."))
            return
        }
        cancelObservation()
        let previous = currentTask
        previous?.cancel()
        suggestion = nil
        let newAttachments = document.content.attachments.filter { !session.sentAttachmentIDs.contains($0.id) }
        var item = ChatItem(role: .student, text: displayText ?? trimmed)
        item.attachmentNames = newAttachments.map(\.name)
        if let focus { item.contextLabel = document.isFreeform ? "Selected area" : "Selected area on page \(focus.page + 1)" }
        chat.append(item)

        var content: [JSONValue] = attachmentBlocks(newAttachments)
        let attachmentIDs = newAttachments.map(\.id)
        session.sentAttachmentIDs.append(contentsOf: attachmentIDs)
        let notes = pendingNotes
        let builder = TutorContextBuilder(doc: document, canvas: canvas, memory: memory)
        let recent = recentWriting.filter { Date().timeIntervalSince($0.0) < 180 }.map(\.1)
        content += builder.blocks(focus: focus, recentWriting: recent, extraNotes: notes, allPages: allPages)
        content.append(TutorContextBuilder.text(trimmed))
        pendingNotes.removeAll()

        let reply = ChatItem(role: .tutor, text: "", model: settings.tutorModel, isStreaming: true)
        chat.append(reply)
        let focusDoc = focus.map { document.docRect($0.rect, page: $0.page) }
        currentTask = Task { [weak self] in
            // A cancelled turn only stops at its next suspension point; let it finish unwinding
            // (history, records, busy state) before this one starts, so the two never interleave.
            await previous?.value
            await self?.runTurn(userContent: content, replyID: reply.id, focusDoc: focusDoc,
                                attachmentIDs: attachmentIDs, notes: notes, maxSteps: allPages ? 40 : 12)
        }
    }

    func quick(_ action: TutorQuickAction, focus: (page: Int, rect: CGRect)? = nil) {
        let desc = focus.map { document.isFreeform ? "the outlined region" : "the outlined region on page \($0.page + 1)" }
        send(action.prompt(regionDescription: desc), focus: focus, displayText: action.title)
    }

    func practice(_ request: PracticeRequest) {
        send(request.prompt, displayText: "Practice: \(request.count) × \(request.topic) (\(request.difficulty))")
    }

    // MARK: Past papers

    /// Has the tutor read the paper and map its questions (once, when a past paper is opened).
    func outlinePaper(again: Bool = false) {
        guard let paper = document.content.paper, again || !paper.outlined, !isBusy else { return }
        send(TutorPrompts.outlinePaper(pageCount: document.content.pages.count, pageSize: document.pageSize,
                                       hasMarkScheme: document.content.attachments.contains { $0.role == .markScheme },
                                       firstPaperPage: document.content.pages.firstIndex { $0.pdfAssetID != nil } ?? 0),
             displayText: "Read through this paper")
    }

    /// Marks one question against the mark scheme, with the tutor looking at that question.
    func markPaperQuestion(_ q: PaperQuestion) {
        let rect = CGRect(x: 0, y: q.top, width: document.pageSize.width, height: max(40, q.bottom - q.top))
        send(TutorPrompts.markPaperQuestion(q), focus: (q.page, rect), displayText: "Mark question \(q.label)")
    }

    /// Stops the clock and marks every answered question, then writes up the results.
    func finishPaper() {
        guard var paper = document.content.paper else { return }
        if paper.startedAt == nil { paper.startedAt = Date() }
        if paper.finishedAt == nil { paper.finishedAt = Date() }
        document.content.paper = paper
        document.markDirty()
        send(TutorPrompts.finishPaper(paper), displayText: "I've finished: mark my paper", allPages: true)
    }

    func stop() {
        // Keep the reference: the next turn waits for this one to finish unwinding.
        currentTask?.cancel()
        cancelObservation()
    }

    /// Retries after an error, continuing from the history as it stands.
    func retry() {
        guard !isBusy, let last = apiMessages.last, last["role"]?.stringValue == "user" else { return }
        cancelObservation()
        let previous = currentTask
        let reply = ChatItem(role: .tutor, text: "", model: settings.tutorModel, isStreaming: true)
        chat.append(reply)
        currentTask = Task { [weak self] in
            await previous?.value
            await self?.runTurn(userContent: nil, replyID: reply.id, focusDoc: nil)
        }
    }

    /// Undoes everything the tutor changed on the canvas in one turn.
    func revert(_ itemID: UUID) {
        guard let record = turnRecords[itemID] else { return }
        CanvasActionExecutor.revert(record, in: document)
        turnRecords[itemID] = nil
        if let i = chat.firstIndex(where: { $0.id == itemID }) {
            chat[i].reverted = true
            chat[i].canRevert = false
        }
        pendingNotes.append("The student undid the canvas changes from one of your earlier turns.")
        scheduleSave()
    }

    // MARK: The agent loop

    private struct StreamResult {
        var assistantBlocks: [JSONValue]
        var toolResults: [JSONValue]
        var stopReason: String?
        var text: String
        var actions: [ChatAction]
        var toolCalls: Int
    }

    private enum TurnError: Error {
        case refused
    }

    private func updateItem(_ id: UUID, _ change: (inout ChatItem) -> Void) {
        guard let i = chat.firstIndex(where: { $0.id == id }) else { return }
        change(&chat[i])
    }

    /// `maxSteps` caps the model responses in one turn (marking a whole paper needs many).
    private func runTurn(userContent: [JSONValue]?, replyID: UUID, focusDoc: CGRect?,
                         attachmentIDs: [String] = [], notes: [String] = [], maxSteps: Int = 12) async {
        isBusy = true
        lastErrorRetryable = false
        statusText = "Looking at your page…"
        canvas?.setTutorActivity(focusDoc.map { .looking($0) } ?? .thinking(nil))
        executor.beginTurn(focus: focusDoc)
        let generation = sessionGeneration
        let startCount = apiMessages.count
        if let userContent {
            apiMessages.append(["role": "user", "content": .array(userContent)])
        }
        var producedOutput = false
        do {
            var iterations = 0
            while iterations < maxSteps {
                iterations += 1
                try Task.checkCancellation()
                let result = try await streamOnce(messages: apiMessages, model: settings.tutorModel, effort: settings.effort,
                                                  itemID: replyID, executor: executor, observation: false)
                if result.stopReason == "refusal" { throw TurnError.refused }
                if !result.assistantBlocks.isEmpty {
                    apiMessages.append(["role": "assistant", "content": .array(result.assistantBlocks)])
                    producedOutput = true
                }
                if !result.toolResults.isEmpty {
                    // Every echoed tool_use needs its tool_result next, whatever the stop reason
                    // (e.g. model_context_window_exceeded), or the history can't be sent again.
                    apiMessages.append(["role": "user", "content": .array(result.toolResults)])
                    scheduleSave()
                    if result.stopReason == "tool_use" || result.stopReason == "max_tokens" {
                        statusText = "Working on the page…"
                        continue
                    }
                }
                break
            }
            finishTurn(replyID)
        } catch TurnError.refused {
            CanvasActionExecutor.revert(executor.record, in: document)
            if generation == sessionGeneration {
                dropHistory(from: startCount)
                if userContent != nil { restoreUnsent(attachmentIDs: attachmentIDs, notes: notes) }
            }
            updateItem(replyID) {
                $0.isStreaming = false
                $0.text = ""
                $0.actions = []
                $0.error = "The tutor declined to help with that request."
            }
        } catch is CancellationError {
            let record = executor.record
            updateItem(replyID) {
                $0.isStreaming = false
                if $0.text.isEmpty && $0.actions.isEmpty { $0.text = "Stopped." }
                $0.canRevert = !record.isEmpty
            }
            if !record.isEmpty {
                turnRecords[replyID] = record
                if generation == sessionGeneration {
                    pendingNotes.append("The student stopped your previous turn part-way; some of your writing may already be on the page.")
                }
            }
        } catch {
            let message = (error as? AnthropicError)?.errorDescription ?? error.localizedDescription
            let retryable = (error as? AnthropicError)?.isRetryable ?? true
            // A retryable failure keeps the turn (the history ends with a user message) so
            // "Try Again" can continue it. One that will fail the same way again is dropped when
            // nothing came of it, so the next message isn't stuck behind it.
            if generation == sessionGeneration, !retryable, !producedOutput, userContent != nil {
                dropHistory(from: startCount)
                restoreUnsent(attachmentIDs: attachmentIDs, notes: notes)
            }
            lastErrorRetryable = retryable && apiMessages.last?["role"]?.stringValue == "user"
            let record = executor.record
            updateItem(replyID) {
                $0.isStreaming = false
                $0.error = message
                $0.canRevert = !record.isEmpty
            }
            if !record.isEmpty { turnRecords[replyID] = record }
        }
        isBusy = false
        statusText = nil
        canvas?.setTutorActivity(.idle)
        scheduleSave()
    }

    /// Discards a failed or declined turn from the end of the history (never earlier turns).
    private func dropHistory(from count: Int) {
        guard count < apiMessages.count else { return }
        apiMessages.removeSubrange(count...)
    }

    /// A dropped user turn never reached the tutor: send its attachments and notes next time.
    private func restoreUnsent(attachmentIDs: [String], notes: [String]) {
        session.sentAttachmentIDs.removeAll { attachmentIDs.contains($0) }
        pendingNotes.insert(contentsOf: notes, at: 0)
    }

    private func finishTurn(_ replyID: UUID) {
        let record = executor.record
        turnRecords[replyID] = record
        var spoken = ""
        updateItem(replyID) {
            $0.isStreaming = false
            $0.canRevert = !record.isEmpty
            if $0.text.trimmed.isEmpty && !$0.actions.isEmpty { $0.text = "" }
            spoken = $0.text
        }
        if settings.speakFeedback, !spoken.trimmed.isEmpty {
            TutorVoice.shared.speak(RichTextParser.plainText(spoken))
        }
    }

    private func requestBody(messages: [JSONValue], model: String, effort: TutorEffort) -> (JSONValue, [String]) {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "max_tokens": 32000,
            "stream": true,
            "system": [["type": "text", "text": .string(TutorPrompts.system)]],
            "tools": TutorTools.definitions,
            "tool_choice": ["type": "auto"],
            "thinking": ["type": "adaptive", "display": "summarized"],
            "output_config": ["effort": .string(effort.rawValue)],
            "cache_control": ["type": "ephemeral"],
            "messages": .array(messages),
        ]
        var betas: [String] = []
        if ClaudeModelOption.option(for: model).supportsFallbacks {
            // Server-side refusal fallback: the API retries a policy decline on a fallback model.
            body["fallbacks"] = "default"
            betas.append("server-side-fallback-2026-07-01")
        }
        return (.object(body), betas)
    }

    /// Streams one assistant response, executing tool calls on the canvas as each one completes.
    private func streamOnce(messages: [JSONValue], model: String, effort: TutorEffort, itemID: UUID?,
                            executor: CanvasActionExecutor, observation: Bool) async throws -> StreamResult {
        let (body, betas) = requestBody(messages: messages, model: model, effort: effort)
        let client = settings.makeClient()
        var attempt = 0
        while true {
            var receivedAnything = false
            do {
                return try await consume(client.streamMessage(body: body, betas: betas), itemID: itemID,
                                         executor: executor, observation: observation, received: &receivedAnything)
            } catch let e as AnthropicError where e.isRetryable && !receivedAnything && attempt < 2 {
                attempt += 1
                statusText = "Reconnecting…"
                try await Task.sleep(nanoseconds: UInt64(1_200_000_000 * attempt))
            }
        }
    }

    private struct Block {
        var type: String
        var start: JSONValue
        var text = ""
        var signature = ""
        var json = ""
        var toolID = ""
        var toolName = ""
        var parsedInput: JSONValue?
    }

    private func consume(_ stream: AsyncThrowingStream<StreamEvent, Error>, itemID: UUID?, executor: CanvasActionExecutor,
                         observation: Bool, received: inout Bool) async throws -> StreamResult {
        var blocks: [Int: Block] = [:]
        var order: [Int] = []
        var stopReason: String?
        var toolResults: [JSONValue] = []
        var actions: [ChatAction] = []
        var toolCalls = 0
        var sawMessageStop = false
        // Chips from earlier responses in this turn stay; only this response's can be taken back.
        let baseActionCount = itemID.flatMap { id in chat.first { $0.id == id }?.actions.count } ?? 0
        executor.beginResponse()

        do {
            for try await event in stream {
                try Task.checkCancellation()
                received = true
                switch event {
                case .messageStart:
                    break
                case .blockStart(let i, let block):
                    let type = block["type"]?.stringValue ?? "unknown"
                    var b = Block(type: type, start: block)
                    if type == "tool_use" {
                        b.toolID = block["id"]?.stringValue ?? ""
                        b.toolName = block["name"]?.stringValue ?? ""
                        toolCalls += 1
                        statusText = TutorEngine.status(forTool: b.toolName)
                    }
                    if type == "text", let t = block["text"]?.stringValue { b.text = t }
                    if type == "thinking" {
                        // Echoed verbatim later: start from whatever the block opened with.
                        b.text = block["thinking"]?.stringValue ?? ""
                        b.signature = block["signature"]?.stringValue ?? ""
                    }
                    if type == "fallback" {
                        // A fallback model took over mid-response: undo canvas edits made by the declined
                        // attempt and drop its tool results (its tool_use blocks are not echoed back).
                        executor.revertResponse()
                        toolResults.removeAll()
                        actions.removeAll()
                        if let itemID { updateItem(itemID) { $0.actions = Array($0.actions.prefix(baseActionCount)) } }
                    }
                    blocks[i] = b
                    order.append(i)
                case .textDelta(let i, let t):
                    blocks[i]?.text += t
                    if let itemID, !observation {
                        updateItem(itemID) { $0.text += t }
                    }
                    if !observation { statusText = nil }
                case .thinkingDelta(let i, let t):
                    blocks[i]?.text += t
                    if let itemID, !observation {
                        updateItem(itemID) { $0.thinking += t }
                    }
                    if statusText == nil || statusText == "Looking at your page…" { statusText = "Thinking…" }
                case .signatureDelta(let i, let s):
                    blocks[i]?.signature += s
                case .inputJSONDelta(let i, let p):
                    guard var b = blocks[i] else { break }
                    b.json += p
                    blocks[i] = b
                    if TutorTools.liveTools.contains(b.toolName), let partial = JSONValue.parsePartial(b.json) {
                        executor.preview(toolID: b.toolID, name: b.toolName, partial: partial, raw: b.json)
                    }
                case .blockStop(let i):
                    guard var b = blocks[i], b.type == "tool_use" else { break }
                    let outcome: CanvasActionExecutor.Outcome
                    do {
                        let input = b.json.trimmed.isEmpty ? JSONValue.object([:]) : try JSONValue.parse(b.json)
                        guard input.objectValue != nil else { throw ToolInputError(message: "Tool input must be a JSON object.") }
                        b.parsedInput = input
                        outcome = executor.execute(toolID: b.toolID, name: b.toolName, input: input)
                    } catch {
                        executor.discardLive(toolID: b.toolID)
                        let wrapper: JSONValue = ["INVALID_JSON": .string(String(b.json.prefix(2000)))]
                        outcome = CanvasActionExecutor.Outcome(result: wrapper.serialized(), isError: true, action: nil)
                    }
                    blocks[i] = b
                    var result: JSONValue = ["type": "tool_result", "tool_use_id": .string(b.toolID), "content": .string(outcome.result)]
                    if outcome.isError, case .object(var o) = result {
                        o["is_error"] = true
                        result = .object(o)
                    }
                    toolResults.append(result)
                    if let a = outcome.action {
                        actions.append(a)
                        if let itemID { updateItem(itemID) { $0.actions.append(a) } }
                    }
                case .messageDelta(let stop, _):
                    if let stop { stopReason = stop }
                case .messageStop:
                    sawMessageStop = true
                }
            }
            // A cancelled consumer sees the stream end quietly instead of throwing, and a dropped
            // connection can end it early: neither may be treated as a complete response.
            try Task.checkCancellation()
            guard sawMessageStop else {
                throw AnthropicError(status: nil, type: "network", message: "The response was cut off.")
            }
        } catch {
            if !(error is CancellationError) {
                // This partial response never reaches the history (its tool calls get no results),
                // so undo what it did on the canvas; a retry redoes it.
                executor.revertResponse()
                if let itemID { updateItem(itemID) { $0.actions = Array($0.actions.prefix(baseActionCount)) } }
            }
            executor.endResponse()
            throw error
        }
        executor.endResponse()

        // Assemble the assistant turn exactly as produced (thinking blocks verbatim).
        let lastFallback = order.lastIndex { blocks[$0]?.type == "fallback" }
        var content: [JSONValue] = []
        var text = ""
        for (pos, i) in order.enumerated() {
            guard let b = blocks[i] else { continue }
            // Before the last fallback boundary only the declined attempt's text carries over; its
            // thinking, tool calls and any other model-internal blocks are omitted.
            if let lf = lastFallback, pos < lf, b.type != "text" {
                continue
            }
            switch b.type {
            case "text":
                // Empty and whitespace-only text blocks are rejected by the API.
                if !b.text.trimmed.isEmpty {
                    content.append(["type": "text", "text": .string(b.text)])
                    text += b.text
                }
            case "thinking":
                content.append(["type": "thinking", "thinking": .string(b.text), "signature": .string(b.signature)])
            case "redacted_thinking":
                content.append(b.start)
            case "tool_use":
                content.append(["type": "tool_use", "id": .string(b.toolID), "name": .string(b.toolName),
                                "input": b.parsedInput ?? .object([:])])
            case "fallback":
                continue
            default:
                content.append(b.start)
            }
        }
        // Every tool_use we echo must have a result, and vice versa.
        let echoedIDs = content.compactMap { $0["type"]?.stringValue == "tool_use" ? $0["id"]?.stringValue : nil }
        let echoedSet = Set(echoedIDs)
        toolResults = toolResults.filter { echoedSet.contains($0["tool_use_id"]?.stringValue ?? "") }
        for id in echoedIDs where !toolResults.contains(where: { $0["tool_use_id"]?.stringValue == id }) {
            toolResults.append(["type": "tool_result", "tool_use_id": .string(id), "content": "Not run (response was cut off).", "is_error": true])
        }
        return StreamResult(assistantBlocks: content, toolResults: toolResults, stopReason: stopReason,
                            text: text, actions: actions, toolCalls: toolCalls)
    }

    static func status(forTool name: String) -> String {
        switch name {
        case "write": return "Writing…"
        case "write_math": return "Working it out on the page…"
        case "draw": return "Drawing…"
        case "geometry": return "Drawing a figure…"
        case "annotate": return "Marking up your work…"
        case "graph": return "Drawing a graph…"
        case "number_line": return "Drawing a number line…"
        case "table": return "Making a table…"
        case "add_question": return "Writing a question…"
        case "mark": return "Marking…"
        case "focus": return "Pointing something out…"
        case "remember": return "Making a note about you…"
        case "outline_paper": return "Reading the paper…"
        case "score_paper": return "Marking against the scheme…"
        case "paper_summary": return "Writing up your results…"
        case "make_flashcards": return "Making flashcards…"
        default: return "Working on the page…"
        }
    }

    // MARK: Attachments

    private func attachmentBlocks(_ items: [TutorAttachment]) -> [JSONValue] {
        var out: [JSONValue] = []
        for a in items {
            if let block = attachmentBlock(a) {
                switch a.role {
                case .paper:
                    out.append(TutorContextBuilder.text("The past paper the student is working through (its pages are this note's pages, in order): \(a.name)"))
                case .markScheme:
                    out.append(TutorContextBuilder.text("The mark scheme for this paper (\(a.name)). It is hidden from the student: use it to mark and to judge their working, and don't quote it or give answers from it unless they ask for a solution."))
                case nil:
                    out.append(TutorContextBuilder.text("Attached file: \(a.name)"))
                }
                out.append(block)
            } else {
                // Don't let the tutor think it has a file it can't see.
                out.append(TutorContextBuilder.text("The student attached \(a.name), but it couldn't be included (unreadable or too large)."))
            }
        }
        return out
    }

    private func attachmentBlock(_ a: TutorAttachment) -> JSONValue? {
        if let fileID = a.remoteFileID {
            switch a.kind {
            case .image:
                return ["type": "image", "source": ["type": "file", "file_id": .string(fileID)]]
            case .pdf, .text:
                return ["type": "document", "source": ["type": "file", "file_id": .string(fileID)], "title": .string(a.name)]
            }
        }
        // Not uploaded (offline or upload failed): inline the content instead.
        guard let data = try? Data(contentsOf: document.assetURL(a.localFile)) else { return nil }
        switch a.kind {
        case .image:
            return ["type": "image", "source": ["type": "base64", "media_type": .string(a.mimeType), "data": .string(data.base64EncodedString())]]
        case .pdf:
            guard data.count < 20_000_000 else { return nil }
            return ["type": "document", "source": ["type": "base64", "media_type": "application/pdf", "data": .string(data.base64EncodedString())], "title": .string(a.name)]
        case .text:
            let text = String(decoding: data, as: UTF8.self)
            guard !text.trimmed.isEmpty else { return nil }
            return ["type": "document", "source": ["type": "text", "media_type": "text/plain", "data": .string(text)], "title": .string(a.name)]
        }
    }

    /// Adds a file the tutor can use as context (copied into the note, uploaded to the Files API).
    func attachFile(_ url: URL) {
        let needsStop = url.startAccessingSecurityScopedResource()
        defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            chat.append(ChatItem(role: .notice, text: "Couldn't read \(url.lastPathComponent)."))
            return
        }
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        let kind: AttachmentKind
        var payload = data
        var mime: String
        var ext = url.pathExtension.lowercased()
        if type?.conforms(to: .pdf) == true {
            kind = .pdf; mime = "application/pdf"
        } else if type?.conforms(to: .image) == true {
            guard let img = UIImage(data: data) else {
                chat.append(ChatItem(role: .notice, text: "Couldn't open \(url.lastPathComponent) as an image."))
                return
            }
            kind = .image
            if ext == "png" && data.count <= 3_500_000 && TutorEngine.longestPixelSide(img) <= TutorEngine.maxImageSide {
                mime = "image/png"
            } else if let jpeg = TutorEngine.jpegForTutor(img) {
                payload = jpeg; mime = "image/jpeg"; ext = "jpg"
            } else {
                chat.append(ChatItem(role: .notice, text: "Couldn't read \(url.lastPathComponent)."))
                return
            }
        } else if type?.conforms(to: .text) == true || ["md", "csv", "tex", "txt", "json"].contains(ext) {
            kind = .text; mime = "text/plain"; ext = "txt"
        } else {
            chat.append(ChatItem(role: .notice, text: "\(url.lastPathComponent) isn't supported — attach a PDF, image or text file (export documents as PDF)."))
            return
        }
        addAttachment(data: payload, name: url.lastPathComponent, kind: kind, mime: mime, ext: ext)
    }

    func attachImage(_ image: UIImage, name: String = "Photo") {
        guard let data = TutorEngine.jpegForTutor(image) else { return }
        addAttachment(data: data, name: name + ".jpg", kind: .image, mime: "image/jpeg", ext: "jpg")
    }

    static let maxImageSide: CGFloat = 2400

    static func longestPixelSide(_ image: UIImage) -> CGFloat {
        max(image.size.width, image.size.height) * image.scale
    }

    /// JPEG small enough for the API's per-image limits: full-resolution photos are downscaled
    /// (the model doesn't use more detail than this anyway).
    static func jpegForTutor(_ image: UIImage) -> Data? {
        let longest = longestPixelSide(image)
        guard longest > maxImageSide else { return image.jpegData(compressionQuality: 0.85) }
        let scale = maxImageSide / longest
        let size = CGSize(width: (image.size.width * image.scale * scale).rounded(),
                          height: (image.size.height * image.scale * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let scaled = UIGraphicsImageRenderer(size: size, format: format).image { rc in
            UIColor.white.setFill()
            rc.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return scaled.jpegData(compressionQuality: 0.85)
    }

    private func addAttachment(data: Data, name: String, kind: AttachmentKind, mime: String, ext: String) {
        let id = "a\(UUID().uuidString.prefix(6))"
        let local = "attach-\(id).\(ext)"
        do {
            try data.write(to: document.assetURL(local), options: .atomic)
        } catch {
            chat.append(ChatItem(role: .notice, text: "Couldn't save \(name)."))
            return
        }
        let attachment = TutorAttachment(id: id, name: name, kind: kind, mimeType: mime, localFile: local, sizeBytes: data.count)
        document.content.attachments.append(attachment)
        document.markDirty()
        upload(attachment, data: data)
    }

    /// Uploads attachments that aren't on the Files API yet (added while offline, an upload that
    /// failed, or files a past paper came with). Until then they're sent inline.
    func uploadPendingAttachments() {
        for a in document.content.attachments where a.remoteFileID == nil && !uploading.contains(a.id) {
            guard let data = try? Data(contentsOf: document.assetURL(a.localFile)) else { continue }
            upload(a, data: data)
        }
    }

    private func upload(_ attachment: TutorAttachment, data: Data) {
        guard settings.isTutorConfigured else { return }
        let id = attachment.id, name = attachment.name, mime = attachment.mimeType
        uploading.insert(id)
        let client = settings.makeClient()
        Task { [weak self] in
            do {
                let fileID = try await client.uploadFile(data: data, filename: name, mimeType: mime)
                guard let self else { return }
                if let i = self.document.content.attachments.firstIndex(where: { $0.id == id }) {
                    self.document.content.attachments[i].remoteFileID = fileID
                    self.document.markDirty()
                }
                self.uploading.remove(id)
            } catch {
                guard let self else { return }
                self.uploading.remove(id)
                // Falls back to sending the file inline with the next message.
            }
        }
    }

    func removeAttachment(_ a: TutorAttachment) {
        document.content.attachments.removeAll { $0.id == a.id }
        // A past paper's attachment shares its file with the pages' PDF backgrounds.
        if !document.content.pages.contains(where: { $0.pdfAssetID == a.localFile }) {
            try? FileManager.default.removeItem(at: document.assetURL(a.localFile))
        }
        document.markDirty()
        if session.sentAttachmentIDs.contains(a.id) {
            pendingNotes.append("The student removed the attachment \"\(a.name)\"; don't rely on it any more.")
        }
    }

    // MARK: Proactive observation

    func studentWrote(_ docRects: [CGRect]) {
        let now = Date()
        lastStrokeDate = now
        pendingWriting.append(contentsOf: docRects)
        recentWriting.append(contentsOf: docRects.map { (now, $0) })
        recentWriting.removeAll { now.timeIntervalSince($0.0) > 300 }
        if case .stuck = suggestion { suggestion = nil }
        scheduleGlance()
    }

    func pencilStateChanged(isDrawing: Bool) {
        if isDrawing {
            glanceTimer?.cancel()
            lastStrokeDate = Date()
        } else {
            scheduleGlance()
        }
    }

    private func scheduleGlance() {
        glanceTimer?.cancel()
        guard watching, settings.proactive, settings.isTutorConfigured else { return }
        let delay = max(1.5, settings.pauseDelay)
        glanceTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.maybeGlance()
        }
    }

    /// Whether the student is using the tutor in this note at all (we don't watch plain note-taking).
    private var isEngaged: Bool {
        if chat.contains(where: { $0.role == .student }) { return true }
        return document.content.elements.contains { if case .question = $0.kind { return true }; return false }
    }

    private func maybeGlance() {
        guard watching, !isBusy, !isObserving, !pendingWriting.isEmpty, isEngaged else { return }
        guard Date().timeIntervalSince(lastLook) > settings.proactivity.cooldown else {
            scheduleGlance()
            return
        }
        let hourAgo = Date().addingTimeInterval(-3600)
        glanceLog.removeAll { $0 < hourAgo }
        guard glanceLog.count < 40 else { return }
        var union = CGRect.null
        for r in pendingWriting { union = union.union(r) }
        let area = union.width * union.height
        guard area > 900 || pendingWriting.count >= 3 else { return }
        pendingWriting.removeAll()
        lastLook = Date()
        glanceLog.append(Date())
        let (page, local) = document.pageRectFromDoc(union)
        let region = local.insetBy(dx: -24, dy: -24).intersection(CGRect(origin: .zero, size: document.pageSize))
        guard !region.isNull else { return }
        observerTask = Task { [weak self] in
            await self?.glance(page: page, region: region)
        }
    }

    func cancelObservation() {
        glanceTimer?.cancel()
        observerTask?.cancel()
        observerTask = nil
    }

    private func glance(page: Int, region: CGRect) async {
        isObserving = true
        let generation = sessionGeneration
        let docRegion = document.docRect(region, page: page)
        canvas?.setTutorActivity(.looking(docRegion))
        let builder = TutorContextBuilder(doc: document, canvas: canvas, memory: memory)
        let recent = recentWriting.filter { Date().timeIntervalSince($0.0) < 120 }.map(\.1)
        // The system prompt recognises observation turns by their leading [observation] text.
        var content: [JSONValue] = [TutorContextBuilder.text(TutorPrompts.observationPrompt(proactivity: settings.proactivity,
                                                                                            region: document.isFreeform ? "the board at \(region.roundedForDisplay)" : "page \(page + 1) \(region.roundedForDisplay)"))]
        content += builder.blocks(focus: (page, region), recentWriting: recent, extraNotes: [])
        var messages: [JSONValue] = [["role": "user", "content": .array(content)]]
        // Observation runs in its own short exchange so it never interleaves with the chat history.
        let executor = observerExecutor
        executor.beginTurn(focus: docRegion)
        var actions: [ChatAction] = []
        var text = ""
        do {
            for _ in 0..<3 {
                try Task.checkCancellation()
                let r = try await streamOnce(messages: messages, model: settings.observerModelID, effort: .low, itemID: nil,
                                             executor: executor, observation: true)
                if r.stopReason == "refusal" {
                    // As for chat turns, a declined observation leaves nothing behind.
                    CanvasActionExecutor.revert(executor.record, in: document)
                    executor.beginTurn()
                    actions.removeAll()
                    text = ""
                    break
                }
                actions += r.actions
                text += r.text
                if !r.assistantBlocks.isEmpty { messages.append(["role": "assistant", "content": .array(r.assistantBlocks)]) }
                if r.stopReason == "tool_use", !r.toolResults.isEmpty {
                    messages.append(["role": "user", "content": .array(r.toolResults)])
                    continue
                }
                break
            }
        } catch {
            // Observations are best-effort; failures are silent.
        }
        executor.endResponse()
        let record = executor.record
        if actions.isEmpty && !record.isEmpty {
            // Interrupted before any tool call finished: don't leave marks nobody can undo.
            CanvasActionExecutor.revert(record, in: document)
        }
        if !actions.isEmpty, generation == sessionGeneration {
            let cleaned = text.replacingOccurrences(of: "(watching)", with: "").trimmed
            var item = ChatItem(role: .observer, text: cleaned)
            item.actions = actions
            item.canRevert = !record.isEmpty
            item.model = settings.observerModelID
            chat.append(item)
            turnRecords[item.id] = record
            pendingNotes.append("While watching the student work you made these changes: " + actions.map(\.summary).joined(separator: "; ") + (cleaned.isEmpty ? "" : " — and said: \"\(cleaned.truncated(160))\""))
            if settings.speakFeedback, !cleaned.isEmpty { TutorVoice.shared.speak(RichTextParser.plainText(cleaned)) }
            scheduleSave()
        }
        isObserving = false
        // A chat turn may have started while this glance was unwinding; leave its status alone.
        if !isBusy {
            statusText = nil
            canvas?.setTutorActivity(actions.isEmpty ? .hidden : .idle)
        }
    }

    // MARK: Stuck detection (local, free)

    private func startStuckWatcher() {
        stuckTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self else { return }
                self.checkStuck()
            }
        }
    }

    private func checkStuck() {
        guard !isBusy, suggestion == nil, isEngaged else { return }
        let idle = Date().timeIntervalSince(lastStrokeDate)
        guard idle > 60 else { return }
        for e in document.content.elements {
            guard case .question(let q) = e.kind, q.status == .open, !q.revealedHint,
                  Date().timeIntervalSince(e.createdAt) > 75 else { continue }
            if let canvas, !canvas.isVisible(document.docRect(for: e)) { continue }
            suggestion = .stuck(question: q.number, elementID: e.id)
            return
        }
    }

    func dismissSuggestion() { suggestion = nil }

    func shutdown() {
        stop()
        stuckTimer?.cancel()
        saveNow()
    }

    // MARK: Question helpers (no API call needed)

    /// The Hint button. A question card's stored hint is shown first (no API call); otherwise the
    /// tutor looks at the latest working and leaves one small nudge beside it. Returns true if it
    /// asked the tutor.
    @discardableResult
    func nudge() -> Bool {
        guard !isBusy else { return false }
        if case .stuck = suggestion { suggestion = nil }
        let now = Date()
        let recent = recentWriting.filter { now.timeIntervalSince($0.0) < 180 }.map(\.1)
        let latest = recent.last

        // The question card being worked in: the one under the latest writing, else (with
        // nothing written lately) the first open card on screen.
        let cards = document.content.elements.filter {
            if case .question(let q) = $0.kind { return q.status == .open }
            return false
        }
        let card: CanvasElement?
        if let latest {
            card = cards.first { document.docRect(for: $0).intersects(latest.insetBy(dx: -40, dy: -40)) }
        } else {
            card = cards.first { canvas?.isVisible(document.docRect(for: $0)) ?? false }
        }
        if let card, case .question(let q) = card.kind {
            if !q.revealedHint, let hint = q.hint, !hint.isEmpty {
                revealHint(for: card)
                return false
            }
            send(TutorPrompts.nudge(on: "Q\(q.number)", hasWorking: latest != nil), focus: questionFocus(card, q), displayText: "Hint")
            return true
        }

        // Otherwise: the last few things written, or what's on screen.
        var area: CGRect
        if let latest {
            let last = Array(recent.suffix(4))
            area = last.dropFirst().reduce(last[0]) { $0.union($1) }
            if area.height > 700 || area.width > 1100 { area = latest }
            area = area.insetBy(dx: -60, dy: -60)
        } else if let visible = canvas?.visibleDocRect {
            area = visible
        } else {
            send(TutorPrompts.nudge(on: nil, hasWorking: false), displayText: "Hint")
            return true
        }
        let pageBounds = CGRect(origin: .zero, size: document.pageSize)
        let (page, local) = document.pageRectFromDoc(area)
        var rect = local.intersection(pageBounds)
        var target: String?
        // On a past paper the tutor also sees the question being answered, not just the working.
        if let paper = document.content.paper, paper.outlined, !rect.isNull {
            let y = latest.map(document.pageRectFromDoc).flatMap { $0.page == page ? $0.rect.midY : nil } ?? rect.midY
            if let pq = paper.question(page: page, y: y) {
                target = "question \(pq.label)"
                let question = CGRect(x: 0, y: pq.top, width: pageBounds.width, height: max(40, min(pq.bottom, rect.maxY) - pq.top))
                rect = rect.union(question).intersection(pageBounds)
            }
        }
        send(TutorPrompts.nudge(on: target, hasWorking: latest != nil),
             focus: rect.isNull || rect.isEmpty ? nil : (page, rect), displayText: "Hint")
        return true
    }

    func revealHint(for element: CanvasElement) {
        guard case .question(var q) = element.kind else { return }
        guard let hint = q.hint, !hint.isEmpty else {
            quick(.hint, focus: questionFocus(element, q))
            return
        }
        q.revealedHint = true
        let updated = q
        document.update(element.id, actionName: "Show Hint") { $0.kind = .question(updated) }
        let content = TextContent(text: "Hint: " + hint, style: .note, fontSize: 18, colorHex: settings.tutorInkHex, rich: true)
        let env = PageRenderer.environment(for: document)
        let width = min(420, element.frame.width - 120)
        let h = ElementRenderer.measureText(content, author: .tutor, width: width, env: env).height
        let frame = CGRect(x: element.frame.maxX - width - 24, y: element.frame.minY + q.promptHeight + 8, width: width, height: h)
        let e = CanvasElement(id: document.nextElementID(), pageIndex: element.pageIndex, frame: frame, author: .tutor, kind: .text(content))
        document.add(e, reveal: .write(duration: ElementRenderer.revealDuration(e)), actionName: "Show Hint")
        pendingNotes.append("The student revealed the stored hint for Q\(q.number).")
    }

    func revealSolution(for element: CanvasElement) {
        guard case .question(var q) = element.kind else { return }
        q.revealedSolution = true
        let updated = q
        document.update(element.id, actionName: "Show Solution") { $0.kind = .question(updated) }
        pendingNotes.append("The student asked to see the solution to Q\(q.number).")
        send("Show me the worked solution to Q\(q.number) on the page, step by step, below the question card or on a new page if there's no room. Use your stored solution and check it as you go.",
             focus: questionFocus(element, q), displayText: "Show solution to Q\(q.number)")
    }

    func checkAnswer(for element: CanvasElement) {
        guard case .question(let q) = element.kind else { return }
        send("Check my answer to Q\(q.number) and mark it.", focus: questionFocus(element, q), displayText: "Check Q\(q.number)")
    }

    private func questionFocus(_ e: CanvasElement, _ q: QuestionContent) -> (page: Int, rect: CGRect) {
        (e.pageIndex, e.frame)
    }
}
