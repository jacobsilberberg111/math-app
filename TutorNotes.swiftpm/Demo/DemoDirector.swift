import SwiftUI
import PencilKit

/// A scripted walkthrough used to record the product demo video (launch with `-demo-script`).
///
/// Student handwriting is synthesised (there's no Pencil in the simulator) and the tutor's turns
/// are canned tool calls, but they run through the real pipeline: the same executor, live
/// streaming previews, reveal animations, presence cursor and chat panel as a live Claude turn.
@MainActor
final class DemoDirector {
    static let shared = DemoDirector()

    static var arguments: [String] { ProcessInfo.processInfo.arguments }
    static var isDemo: Bool { arguments.contains("-demo-script") }
    static var skipOnboarding: Bool { isDemo || arguments.contains("-uitest-skip-onboarding") }
    static var openFirstNote: Bool { arguments.contains("-uitest-open-first-note") }
    static var showTutorPanel: Bool { arguments.contains("-uitest-show-tutor") }

    private var openNote: ((NoteMeta) -> Void)?
    private var closeNote: (() -> Void)?
    private var newBoard: ((String) -> Void)?
    private weak var library: LibraryStore?
    private var started = false
    private var editor: EditorModel?
    private var editorContinuation: CheckedContinuation<EditorModel, Never>?

    // MARK: Hooks from the UI

    func libraryAppeared(library: LibraryStore, open: @escaping (NoteMeta) -> Void, close: @escaping () -> Void,
                         newBoard: @escaping (String) -> Void) {
        let settings = AppSettings.shared
        if DemoDirector.skipOnboarding { settings.hasSeenOnboarding = true }
        self.library = library
        self.openNote = open
        self.closeNote = close
        self.newBoard = newBoard
        if DemoDirector.isDemo {
            guard !started else { return }
            started = true
            // The scripted tutor never calls the network; mark it configured so the panel looks connected.
            settings.connection = .server
            settings.serverURL = "demo.invalid"
            settings.serverToken = "demo"
            Task { await run() }
        } else if DemoDirector.openFirstNote, !started {
            started = true
            Task { await openWelcomeNote() }
        }
    }

    func editorAppeared(_ model: EditorModel) {
        editor = model
        if DemoDirector.isDemo { model.tutor.watching = false }
        if DemoDirector.showTutorPanel { model.showTutor = true }
        if let c = editorContinuation {
            editorContinuation = nil
            c.resume(returning: model)
        }
    }

    private func welcomeNote() -> NoteMeta? {
        guard let library else { return nil }
        return library.notes.first { $0.title.hasPrefix("Welcome") } ?? library.notes.first
    }

    /// Opens the welcome note, trying again if the presentation doesn't take: one requested while
    /// the library is still settling after launch can be dropped.
    private func openWelcomeNote() async {
        for attempt in 0..<4 {
            await wait(attempt == 0 ? 0.8 : 2.0)
            if editor != nil { return }
            if let note = welcomeNote() {
                log("opening \(note.title) (attempt \(attempt + 1))")
                openNote?(note)
            }
        }
    }

    /// Lines the CI recording step keeps in its log, to explain a video that looks wrong.
    private func log(_ message: String) {
        print("DEMO: \(message)")
    }

    // MARK: Helpers

    private func wait(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func waitForEditor() async -> EditorModel {
        if let editor { return editor }
        return await withCheckedContinuation { c in editorContinuation = c }
    }

    private func waitForCanvas(_ model: EditorModel) async -> NoteCanvasViewController? {
        for _ in 0..<50 {
            if let c = model.canvas, c.isViewLoaded, c.view.window != nil { return c }
            await wait(0.1)
        }
        return model.canvas
    }

    private func waitForReveals(_ canvas: NoteCanvasViewController?) async {
        for _ in 0..<80 {
            guard let canvas, canvas.isRevealing else { return }
            await wait(0.1)
        }
    }

    /// Writes text as animated pen strokes, stroke by stroke.
    private func handwrite(_ text: String, at docOrigin: CGPoint, size: CGFloat, color: UIColor, width: CGFloat,
                           canvas: NoteCanvasViewController, speed: Double = 1) async {
        let strokes = Handwriting.strokes(text, origin: docOrigin, size: size, seed: text.count * 31 + Int(docOrigin.y))
        for pts in strokes where !pts.isEmpty {
            let base = canvas.canvasView.drawing
            let step = max(2, pts.count / 8)
            var k = min(2, pts.count)
            while k < pts.count {
                var d = base
                d.strokes.append(Handwriting.pkStroke(Array(pts.prefix(k)), color: color, width: width))
                canvas.canvasView.drawing = d
                k += step
                await wait(0.016 / speed)
            }
            var d = base
            d.strokes.append(Handwriting.pkStroke(pts, color: color, width: width))
            canvas.canvasView.drawing = d
            await wait(0.05 / speed)
        }
    }

    /// Runs one canned tool call through the real executor, streaming live tools in small chunks.
    @discardableResult
    private func tool(_ name: String, _ json: String, model: EditorModel, replyID: UUID?) async -> CanvasActionExecutor.Outcome? {
        let tutor = model.tutor
        let executor = tutor.executor
        let id = "toolu_demo_\(UUID().uuidString.prefix(8))"
        tutor.statusText = TutorEngine.status(forTool: name)
        if TutorTools.liveTools.contains(name) {
            let chars = Array(json)
            var end = 12
            while end < chars.count {
                let prefix = String(chars[0..<end])
                if let partial = JSONValue.parsePartial(prefix) {
                    executor.preview(toolID: id, name: name, partial: partial, raw: prefix)
                }
                end += 3
                await wait(0.028)
            }
        } else {
            await wait(0.5)
        }
        guard let input = try? JSONValue.parse(json) else { return nil }
        let outcome = executor.execute(toolID: id, name: name, input: input)
        if let replyID, let action = outcome.action, let i = tutor.chat.firstIndex(where: { $0.id == replyID }) {
            tutor.chat[i].actions.append(action)
        }
        await waitForReveals(model.canvas)
        return outcome
    }

    private func streamChat(_ text: String, into replyID: UUID, model: EditorModel) async {
        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
            if let i = model.tutor.chat.firstIndex(where: { $0.id == replyID }) {
                model.tutor.chat[i].text += (model.tutor.chat[i].text.isEmpty ? "" : " ") + word
            }
            await wait(0.045)
        }
    }

    private func beginTutorTurn(_ model: EditorModel, studentText: String?, thinking: String) -> UUID {
        let tutor = model.tutor
        if let studentText { tutor.chat.append(ChatItem(role: .student, text: studentText)) }
        let reply = ChatItem(role: .tutor, text: "", thinking: thinking, model: AppSettings.shared.tutorModel, isStreaming: true)
        tutor.chat.append(reply)
        tutor.isBusy = true
        tutor.statusText = "Looking at your page…"
        model.tutor.executor.beginTurn()
        return reply.id
    }

    private func endTutorTurn(_ model: EditorModel, replyID: UUID) {
        let tutor = model.tutor
        if let i = tutor.chat.firstIndex(where: { $0.id == replyID }) {
            tutor.chat[i].isStreaming = false
        }
        tutor.isBusy = false
        tutor.statusText = nil
        model.canvas?.setTutorActivity(.idle)
    }

    // MARK: The script

    private func run() async {
        await wait(2.7)
        await openWelcomeNote()
        let model = await waitForEditor()
        guard let canvas = await waitForCanvas(model) else { log("no canvas"); return }
        log("editor open, canvas width \(Int(canvas.view.bounds.width))")
        let doc = model.document
        await wait(2.5)

        // 1. Student answers Q1 by hand.
        guard let q = doc.content.elements.first(where: { if case .question = $0.kind { return true }; return false }),
              case .question(let qc) = q.kind else { return }
        let qDoc = doc.docRect(for: q)
        canvas.scrollToReveal(qDoc.insetBy(dx: 0, dy: -60))
        await wait(1.2)
        model.tools.kind = .pen
        model.tools.penColorIndex = 0
        let answerTop = qDoc.minY + qc.promptHeight + 36
        let ink = UIColor(hex: "#1F2328")
        await handwrite("(x − 2)(x − 5) = 0", at: CGPoint(x: qDoc.minX + 40, y: answerTop), size: 30, color: ink, width: 2.6, canvas: canvas)
        await wait(0.4)
        await handwrite("x = 2  or  x = 5", at: CGPoint(x: qDoc.minX + 40, y: answerTop + 62), size: 30, color: ink, width: 2.6, canvas: canvas)
        await wait(1.4)

        // 2. The tutor glances while the student pauses, and marks the answer.
        let tutor = model.tutor
        tutor.isObserving = true
        tutor.statusText = "Glancing at your work…"
        canvas.setTutorActivity(.looking(CGRect(x: qDoc.minX + 30, y: answerTop - 10, width: 420, height: 130)))
        await wait(2.2)
        tutor.executor.beginTurn()
        await tool("mark", #"{"question": 1, "verdict": "correct", "score": "2/2", "comment": "Nice factorising! 🎉"}"#, model: model, replyID: nil)
        var observerItem = ChatItem(role: .observer, text: "Spot on — both roots are right.")
        observerItem.actions = [ChatAction(symbol: "checkmark.circle.fill", summary: "Marked Q1 correct (2/2)")]
        tutor.chat.append(observerItem)
        tutor.isObserving = false
        tutor.statusText = nil
        canvas.setTutorActivity(.idle)
        await wait(1.8)

        // 3. Highlighter and draw-and-hold shape snapping.
        model.tools.kind = .highlighter
        model.flash("Highlighter")
        await wait(0.8)
        let hlY = answerTop + 62 + 18
        let hl = (0...20).map { i in CGPoint(x: qDoc.minX + 34 + CGFloat(i) * 12, y: hlY + sin(CGFloat(i) * 0.6) * 1.2) }
        var d = canvas.canvasView.drawing
        d.strokes.append(Handwriting.pkStroke(hl, color: UIColor(hex: "#FFE066"), width: 22, ink: .marker))
        canvas.canvasView.drawing = d
        await wait(1.0)
        model.tools.kind = .pen
        model.tools.penColorIndex = 1
        await wait(0.6)
        let circleCenter = CGPoint(x: qDoc.maxX - 140, y: answerTop + 150)
        let rough = (0...40).map { i -> CGPoint in
            let t = CGFloat(i) / 40 * 2.1 * .pi - 1.4
            let r: CGFloat = 46 + sin(CGFloat(i) * 1.3) * 4
            return CGPoint(x: circleCenter.x + r * 1.15 * cos(t), y: circleCenter.y + r * sin(t))
        }
        for k in stride(from: 3, through: rough.count, by: 3) {
            var dd = canvas.canvasView.drawing
            if k > 3 { dd.strokes.removeLast() }
            dd.strokes.append(Handwriting.pkStroke(Array(rough.prefix(k)), color: UIColor(hex: "#1C64F2"), width: 2.6))
            canvas.canvasView.drawing = dd
            await wait(0.02)
        }
        await wait(0.6)
        if let shape = ShapeRecognizer.recognize(rough) {
            var dd = canvas.canvasView.drawing
            dd.strokes.removeLast()
            dd.strokes.append(Handwriting.pkStroke(shape.outline(spacing: 2.5), color: UIColor(hex: "#1C64F2"), width: 2.6))
            canvas.canvasView.drawing = dd
            model.flash(shape.name)
        }
        await wait(1.8)

        // 4. Ask the tutor about a region.
        model.tools.kind = .tutor
        await wait(0.8)
        let regionPage = q.pageIndex
        let regionRect = CGRect(x: q.frame.minX + 24, y: q.frame.minY + qc.promptHeight + 20, width: 460, height: 140)
        canvas.showRegion(doc.docRect(regionRect, page: regionPage))
        model.quickMenu = QuickMenuRequest(page: regionPage, rect: regionRect,
                                           anchor: canvas.viewRect(fromDoc: doc.docRect(regionRect, page: regionPage)))
        await wait(2.6)
        model.dismissQuickMenu()
        model.tools.kind = .pen
        log("showing tutor panel")
        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { model.showTutor = true }
        await wait(0.3)
        log("0.3s: showTutor \(model.showTutor), canvas width \(Int(canvas.view.bounds.width))")
        await wait(0.9)
        log("1.2s: showTutor \(model.showTutor), canvas width \(Int(canvas.view.bounds.width))")

        // 5. A full tutor turn: graph, typeset working, explanation, a new practice question.
        let reply = beginTutorTurn(model, studentText: "Can you graph it and show me where the roots are?",
                                   thinking: "The student solved x² − 7x + 10 = 0 correctly. Show the parabola, its roots at 2 and 5, the vertex at (3.5, −2.25), then set a similar question.")
        canvas.setTutorActivity(.thinking(nil))
        await wait(2.0)
        await streamChat("Here's the graph. The roots are exactly where the curve crosses the x-axis.", into: reply, model: model)
        await tool("write", #"{"page": 2, "x": 64, "y": 56, "width": 640, "style": "heading", "text": "Graph of $y = x^2 - 7x + 10$"}"#, model: model, replyID: reply)
        let graphOutcome = await tool("graph", #"{"page": 2, "x": 56, "y": 120, "width": 470, "height": 370, "x_min": -1, "x_max": 8, "y_min": -4, "y_max": 12, "functions": [{"expression": "x^2 - 7x + 10", "label": "$y = x^2 - 7x + 10$"}], "points": [{"x": 2, "y": 0, "label": "(2, 0)", "color": "red"}, {"x": 5, "y": 0, "label": "(5, 0)", "color": "red"}, {"x": 3.5, "y": -2.25, "label": "vertex", "color": "purple"}], "guides": [{"x": 3.5, "label": "x = 3.5"}]}"#, model: model, replyID: reply)
        await tool("write_math", #"{"page": 2, "x": 556, "y": 140, "size": "medium", "lines": ["y = x^2 - 7x + 10", "= \\left(x - \\frac{7}{2}\\right)^2 - \\frac{9}{4}"]}"#, model: model, replyID: reply)
        await tool("write", #"{"page": 2, "x": 556, "y": 270, "width": 230, "text": "Vertex at $(3.5, -2.25)$: the curve is symmetric about $x = 3.5$, halfway between the roots."}"#, model: model, replyID: reply)
        if graphOutcome != nil, let graph = doc.content.elements.last(where: { if case .graph = $0.kind { return true }; return false }),
           case .graph(let g) = graph.kind {
            let plot = ElementRenderer.graphPlotRect(graph.frame, g)
            let r1 = ElementRenderer.graphMap(2, 0, g, plot), r2 = ElementRenderer.graphMap(5, 0, g, plot)
            let target = CGRect(x: r1.x - 14, y: r1.y - 14, width: r2.x - r1.x + 28, height: 28)
            await tool("annotate", "{\"page\": \(graph.pageIndex + 1), \"mark\": \"circle\", \"x\": \(Int(target.minX)), \"y\": \(Int(target.minY)), \"width\": \(Int(target.width)), \"height\": \(Int(target.height)), \"label\": \"your roots!\"}", model: model, replyID: reply)
        }
        await streamChat("Now try one on your own — I've added it below.", into: reply, model: model)
        await tool("add_question", #"{"page": 2, "prompt": "Solve $x^2 + 3x - 10 = 0$, then sketch the parabola and mark its roots.", "answer": "x = 2 or x = -5", "solution": "$(x + 5)(x - 2) = 0$, so $x = -5$ or $x = 2$.", "hint": "Two numbers that multiply to −10 and add to 3.", "marks": 3, "answer_space": 230, "difficulty": "medium"}"#, model: model, replyID: reply)
        endTutorTurn(model, replyID: reply)
        await wait(2.5)

        // 6. Pages overview.
        model.showPages = true
        await wait(2.6)
        model.showPages = false
        await wait(1.0)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { model.showTutor = false }
        await wait(1.0)

        // 7. Back to Home, where the note waits to be jumped back into.
        if let library { model.close(library: library) }
        closeNote?()
        await wait(3.8)

        // 8. A freeform board: write, switch the lines, circle the working and ask from the bar.
        editor = nil
        newBoard?("Factorising practice")
        let board = await waitForEditor()
        guard let boardCanvas = await waitForCanvas(board) else { log("no board canvas"); return }
        log("board open, canvas width \(Int(boardCanvas.view.bounds.width))")
        await wait(1.4)
        board.tools.kind = .pen
        board.tools.penColorIndex = 0
        await handwrite("x² + 5x + 6 = 0", at: CGPoint(x: 120, y: 170), size: 34, color: ink, width: 2.7, canvas: boardCanvas)
        await wait(0.3)
        await handwrite("(x + 2)(x + 3) = 0", at: CGPoint(x: 120, y: 245), size: 34, color: ink, width: 2.7, canvas: boardCanvas)
        await wait(0.8)
        for (pattern, name) in [(PaperPattern.dots, "Dotted"), (.ruled, "Ruled"), (.grid, "Grid")] {
            board.document.setPaper(PaperStyle(pattern: pattern, color: .white), forPage: nil)
            board.flash(name)
            await wait(1.2)
        }
        board.tools.kind = .tutor
        await wait(0.6)
        let region = CGRect(x: 100, y: 150, width: 470, height: 160)
        boardCanvas.showRegion(region)
        board.askAboutRegion(QuickMenuRequest(page: 0, rect: region, anchor: boardCanvas.viewRect(fromDoc: region)))
        await wait(1.8)
        board.tools.kind = .pen
        let boardReply = beginTutorTurn(board, studentText: "Is my factorising right? What are the roots?",
                                        thinking: "2 × 3 = 6 and 2 + 3 = 5, so the factorising is correct; the roots are −2 and −3.")
        board.pendingFocus = nil
        boardCanvas.clearRegion()
        boardCanvas.setTutorActivity(.thinking(nil))
        await wait(1.6)
        await streamChat("Yes, that's right! The roots are x = −2 and x = −3. I've sketched it so you can see them.", into: boardReply, model: board)
        await tool("mark", #"{"page": 1, "verdict": "correct", "x": 540, "y": 236, "comment": "Spot on"}"#, model: board, replyID: boardReply)
        await tool("write", #"{"page": 1, "x": 120, "y": 335, "width": 470, "text": "So $x = -2$ or $x = -3$. Both are negative because $+5x$ and $+6$ are positive."}"#, model: board, replyID: boardReply)
        await tool("graph", #"{"page": 1, "x": 650, "y": 130, "width": 330, "height": 300, "x_min": -5, "x_max": 1, "y_min": -1, "y_max": 6, "functions": [{"expression": "x^2 + 5x + 6", "label": "$y = x^2 + 5x + 6$"}], "points": [{"x": -2, "y": 0, "label": "(−2, 0)", "color": "red"}, {"x": -3, "y": 0, "label": "(−3, 0)", "color": "red"}]}"#, model: board, replyID: boardReply)
        endTutorTurn(board, replyID: boardReply)
        await wait(3.2)
        boardCanvas.zoomToShowAll()
        await wait(3.0)
        // Marker the recording script waits for.
        print("DEMO_COMPLETE")
        FileManager.default.createFile(atPath: NSTemporaryDirectory() + "demo-complete", contents: Data())
    }
}
