import UIKit
import PencilKit

struct ToolInputError: Error {
    let message: String
}

/// Typed access to a tool call's JSON input.
struct ToolArgs {
    let json: JSONValue

    func double(_ k: String) -> Double? { json[k]?.doubleValue }
    func cg(_ k: String) -> CGFloat? { double(k).map { CGFloat($0) } }
    func int(_ k: String) -> Int? { json[k]?.intValue }
    func string(_ k: String) -> String? {
        guard let s = json[k]?.stringValue?.trimmed, !s.isEmpty else { return nil }
        return s
    }
    func bool(_ k: String) -> Bool? { json[k]?.boolValue }
    func array(_ k: String) -> [JSONValue] { json[k]?.arrayValue ?? [] }

    func requireString(_ k: String) throws -> String {
        guard let s = json[k]?.stringValue, !s.trimmed.isEmpty else { throw ToolInputError(message: "Missing '\(k)'.") }
        return s
    }

    func requireDouble(_ k: String) throws -> Double {
        guard let d = double(k), d.isFinite else { throw ToolInputError(message: "Missing or invalid number '\(k)'.") }
        return d
    }
}

/// Applies the tutor's tool calls to the note, records them for "undo this turn", and returns a
/// compact result string the tutor can use to plan its next move.
@MainActor
final class CanvasActionExecutor {
    struct Outcome {
        var result: String
        var isError: Bool
        var action: ChatAction?
    }

    let document: NoteDocument
    weak var canvas: NoteCanvasViewController?
    let memory: TutorMemoryStore
    /// Edits from completed responses in this turn, and from the response currently streaming
    /// (kept apart so a mid-response model fallback can undo just the declined attempt).
    private var turnRecord = TurnRecord()
    private var responseRecord = TurnRecord()
    var record: TurnRecord {
        get {
            var r = turnRecord
            r.merge(responseRecord)
            return r
        }
        set {
            turnRecord = newValue
            responseRecord = TurnRecord()
        }
    }
    /// tool_use id -> element being written live.
    private var liveElements: [String: String] = [:]
    private var liveFrames: [String: CGRect] = [:]

    init(document: NoteDocument, memory: TutorMemoryStore) {
        self.document = document
        self.memory = memory
    }

    var settings: AppSettings { .shared }
    var layout: LayoutAssistant { LayoutAssistant(doc: document, frozenBounds: frozenArea) }
    var env: RenderEnvironment { PageRenderer.environment(for: document) }
    var pageWidth: CGFloat { document.pageSize.width }
    var pageHeight: CGFloat { document.pageSize.height }
    /// Where new things go by default and what they're kept inside: the page, or on a freeform
    /// board the student's view (extended downward).
    var area: CGRect { frozenArea ?? document.tutorWorkArea }
    /// On a board, the work area as it was when the turn began (see LayoutAssistant.frozenBounds).
    private var frozenArea: CGRect?

    /// `focus` (document coordinates) is the region the turn is about, if any; on a board the
    /// work area stretches to include it.
    func beginTurn(focus: CGRect? = nil) {
        if document.isFreeform {
            var a = document.tutorWorkArea
            if let focus, !a.contains(focus) { a = a.union(focus.insetBy(dx: -120, dy: -120)) }
            frozenArea = a
        } else {
            frozenArea = nil
        }
        turnRecord = TurnRecord()
        responseRecord = TurnRecord()
        liveElements.removeAll()
        liveFrames.removeAll()
    }

    func beginResponse() {
        turnRecord.merge(responseRecord)
        responseRecord = TurnRecord()
    }

    func endResponse() {
        turnRecord.merge(responseRecord)
        responseRecord = TurnRecord()
        // A tool call cut off mid-stream (stop, error) leaves its live element behind: finish
        // it as it stands so it renders normally.
        for id in liveElements.values { canvas?.finishLive(id) }
        liveElements.removeAll()
        liveFrames.removeAll()
    }

    /// Undoes only what the response currently streaming has done.
    func revertResponse() {
        CanvasActionExecutor.revert(responseRecord, in: document)
        responseRecord = TurnRecord()
        liveElements.removeAll()
        liveFrames.removeAll()
    }

    // MARK: Recording

    private func noteCreated(_ id: String) { responseRecord.created.append(id) }

    private func noteModified(_ e: CanvasElement) {
        let known = responseRecord.originals[e.id] != nil || responseRecord.created.contains(e.id)
            || turnRecord.originals[e.id] != nil || turnRecord.created.contains(e.id)
        if !known { responseRecord.originals[e.id] = e }
    }

    private func noteRemoved(_ e: CanvasElement) {
        if let i = responseRecord.created.firstIndex(of: e.id) {
            responseRecord.created.remove(at: i)
        } else if let i = turnRecord.created.firstIndex(of: e.id) {
            turnRecord.created.remove(at: i)
        } else {
            responseRecord.removed.append(responseRecord.originals[e.id] ?? turnRecord.originals[e.id] ?? e)
        }
    }

    /// Reverts everything a turn did.
    static func revert(_ r: TurnRecord, in doc: NoteDocument) {
        for id in r.created { doc.remove(id, actionName: "Undo Tutor") }
        for (_, original) in r.originals { doc.restore(original) }
        for e in r.removed { doc.restore(e) }
        if !r.erasedStrokes.isEmpty {
            var d = doc.drawing
            // Skip strokes that are back already (e.g. the student used Undo).
            let present = Set(d.strokes.map(strokeKey))
            d.strokes.append(contentsOf: r.erasedStrokes.filter { !present.contains(strokeKey($0)) })
            doc.replaceDrawing(d, actionName: "Undo Tutor")
        }
        if let paper = r.paperBefore {
            doc.content.paper = paper
            doc.markDirty()
        }
        // Pages the tutor added, newest first, if nothing has been put on them since.
        for id in r.appendedPageIDs.reversed() {
            guard let i = doc.content.pages.firstIndex(where: { $0.id == id }), doc.content.pages.count > 1,
                  doc.elements(onPage: i).isEmpty, doc.strokes(onPage: i).isEmpty else { continue }
            doc.deletePage(i)
        }
    }

    private static func strokeKey(_ s: PKStroke) -> String {
        "\(s.path.creationDate.timeIntervalSinceReferenceDate)|\(s.renderBounds)"
    }

    // MARK: Helpers

    /// Call before changing the past paper's state, so reverting the turn restores it.
    private func notePaperChange() {
        if responseRecord.paperBefore == nil && turnRecord.paperBefore == nil {
            responseRecord.paperBefore = document.content.paper
        }
    }

    /// Adds a page at the end and remembers it, so reverting the turn can take it away again.
    @discardableResult
    private func appendPage(paper: PaperStyle? = nil) -> Int {
        document.appendPage(paper: paper)
        if let page = document.content.pages.last { responseRecord.appendedPageIDs.append(page.id) }
        return document.content.pages.count - 1
    }

    /// Glances (proactive observation) don't get the paper and flashcard tools: they haven't
    /// seen the mark scheme, and the student didn't ask.
    var allowsStudyTools = true
    static let studyTools: Set<String> = ["make_flashcards", "outline_paper", "score_paper", "paper_summary"]

    func resolvePage(_ n: Int?) throws -> Int {
        if document.isFreeform {
            if let n, n != 1 {
                throw ToolInputError(message: "This note is a freeform board: it has only page 1. Use page 1 with board coordinates; the board grows as needed.")
            }
            return 0
        }
        guard let n else { return canvas?.currentPageIndex ?? 0 }
        let count = document.content.pages.count
        if n >= 1 && n <= count { return n - 1 }
        if n == count + 1 {
            return appendPage()
        }
        throw ToolInputError(message: "Page \(n) doesn't exist (the note has \(count) page\(count == 1 ? "" : "s"); use \(count + 1) to add one).")
    }

    func color(_ name: String?, default fallback: String? = nil) -> String {
        InkPalette.hex(for: name, default: fallback ?? settings.tutorInkHex)
    }

    func textSize(_ s: String?, style: TextStyle) -> CGFloat {
        let base: CGFloat
        switch s {
        case "small": base = 16
        case "large": base = 27
        default: base = 20
        }
        switch style {
        case .heading: return base + 7
        case .note: return base - 2
        default: return base
        }
    }

    func mathSize(_ s: String?) -> CGFloat {
        switch s {
        case "small": return 18
        case "large": return 30
        default: return 23
        }
    }

    func describe(_ r: CGRect) -> String { r.roundedForDisplay }

    func element(_ id: String) throws -> CanvasElement {
        guard let e = document.element(id) else { throw ToolInputError(message: "No element with id \(id).") }
        return e
    }

    func question(number: Int) -> CanvasElement? {
        document.content.elements.last { e in
            if case .question(let q) = e.kind { return q.number == number }
            return false
        }
    }

    /// Adds a tutor element with the writing reveal.
    @discardableResult
    func addTutorElement(page: Int, frame: CGRect, kind: ElementKind, reveal: Bool = true) -> CanvasElement {
        let e = CanvasElement(id: document.nextElementID(), pageIndex: page, frame: frame, author: .tutor, kind: kind)
        document.add(e, reveal: reveal ? .write(duration: ElementRenderer.revealDuration(e)) : .none, actionName: "Tutor")
        noteCreated(e.id)
        return e
    }

    func points(_ value: JSONValue?) -> [CGPoint] {
        (value?.arrayValue ?? []).compactMap { p -> CGPoint? in
            if let arr = p.arrayValue, arr.count >= 2, let x = arr[0].doubleValue, let y = arr[1].doubleValue {
                return CGPoint(x: x, y: y)
            }
            if let x = p["x"]?.doubleValue, let y = p["y"]?.doubleValue { return CGPoint(x: x, y: y) }
            return nil
        }
    }

    /// Builds an ink element from page-coordinate strokes.
    func inkElement(page: Int, strokes: [[CGPoint]], colorHex: String, width: CGFloat, purpose: InkPurpose,
                    opacity: CGFloat = 1, closed: [Bool]? = nil, label: String? = nil, labelAt: CGPoint? = nil) -> CanvasElement? {
        let all = strokes.flatMap { $0 }
        guard !all.isEmpty else { return nil }
        var bounds = ShapeGeometry.bounds(all).insetBy(dx: -width - 2, dy: -width - 2)
        var labelOffset: CGPoint?
        if let label, !label.isEmpty {
            let f = NoteFonts.tutorFont(style: .handwriting, size: max(15, width * 5.5), hand: settings.tutorHand)
            let l = ElementRenderer.richLayout(label, font: f, width: 260, rich: true)
            var origin = labelAt ?? CGPoint(x: bounds.maxX + 6, y: bounds.midY - l.size.height / 2)
            if origin.x + l.size.width > area.maxX - 8 { origin.x = max(area.minX + 8, bounds.minX - l.size.width - 8) }
            let labelRect = CGRect(origin: origin, size: l.size)
            bounds = bounds.union(labelRect.insetBy(dx: -2, dy: -2))
            labelOffset = CGPoint(x: origin.x - bounds.minX, y: origin.y - bounds.minY)
        }
        let rel = strokes.enumerated().map { (i, s) in
            InkStroke(points: s.map { CGPoint(x: $0.x - bounds.minX, y: $0.y - bounds.minY) }, closed: closed?[safe: i] ?? false)
        }
        let ink = InkContent(strokes: rel, colorHex: colorHex, width: width, opacity: opacity, purpose: purpose, label: label, labelOffset: labelOffset)
        return CanvasElement(id: document.nextElementID(), pageIndex: page, frame: bounds, author: .tutor, kind: .ink(ink))
    }

    @discardableResult
    func addInk(_ e: CanvasElement) -> CanvasElement {
        document.add(e, reveal: .write(duration: ElementRenderer.revealDuration(e)), actionName: "Tutor")
        noteCreated(e.id)
        return e
    }

    // MARK: Live preview (eager input streaming)

    /// Called as tool input streams in, so writing appears on the page while it's generated.
    func preview(toolID: String, name: String, partial: JSONValue, raw: String) {
        guard TutorTools.liveTools.contains(name) else { return }
        let args = ToolArgs(json: partial)
        do {
            switch name {
            case "write":
                guard let text = partial["text"]?.stringValue, !text.isEmpty, args.double("y") != nil else { return }
                let content = try writeContent(args, text: text)
                if let id = liveElements[toolID], var frame = liveFrames[toolID] {
                    let h = ElementRenderer.measureText(content, author: .tutor, width: frame.width, env: env).height
                    frame.size.height = h
                    document.update(id, registerUndo: false) {
                        $0.kind = .text(content)
                        $0.frame = frame
                    }
                } else {
                    let page = try resolvePage(args.int("page"))
                    var frame = try writeFrame(args, content: content, fitted: false)
                    frame = layout.place(frame, page: page).rect
                    let e = CanvasElement(id: document.nextElementID(), pageIndex: page, frame: frame, author: .tutor, kind: .text(content))
                    document.add(e, reveal: .live, actionName: "Tutor")
                    noteCreated(e.id)
                    liveElements[toolID] = e.id
                    liveFrames[toolID] = frame
                }
            case "write_math":
                let lines = (partial["lines"]?.arrayValue ?? []).compactMap(\.stringValue).filter { !$0.isEmpty }
                guard !lines.isEmpty, args.double("y") != nil else { return }
                // Only show complete lines while streaming (a half line of LaTeX looks broken).
                let lastChar = raw.trimmingCharacters(in: .whitespacesAndNewlines).last
                let lastIsComplete = lastChar == "," || lastChar == "]" || lastChar == "}"
                let complete = lastIsComplete ? lines : Array(lines.dropLast())
                guard !complete.isEmpty else { return }
                let content = MathContent(lines: complete, fontSize: mathSize(args.string("size")), colorHex: color(args.string("color")))
                let size = ElementRenderer.measureMath(content)
                if let id = liveElements[toolID], var frame = liveFrames[toolID] {
                    frame.size = size
                    document.update(id, registerUndo: false) {
                        $0.kind = .math(content)
                        $0.frame = frame
                    }
                    liveFrames[toolID] = frame
                } else {
                    let page = try resolvePage(args.int("page"))
                    let x = args.cg("x") ?? area.minX + 60, y = args.cg("y") ?? area.minY + 60
                    let frame = layout.place(CGRect(x: x, y: y, width: max(size.width, 200), height: size.height), page: page).rect
                    let placed = CGRect(origin: frame.origin, size: size)
                    let e = CanvasElement(id: document.nextElementID(), pageIndex: page, frame: placed, author: .tutor, kind: .math(content))
                    document.add(e, reveal: .live, actionName: "Tutor")
                    noteCreated(e.id)
                    liveElements[toolID] = e.id
                    liveFrames[toolID] = placed
                }
            default:
                break
            }
        } catch {
            // Partial input may be temporarily invalid; ignore until complete.
        }
    }

    /// Removes a live element whose tool call turned out to be invalid.
    func discardLive(toolID: String) {
        if let id = liveElements[toolID] {
            document.remove(id)
            responseRecord.created.removeAll { $0 == id }
        }
        liveElements[toolID] = nil
        liveFrames[toolID] = nil
    }

    private func writeContent(_ args: ToolArgs, text: String) throws -> TextContent {
        let style = TextStyle(rawValue: args.string("style") ?? "handwriting") ?? .handwriting
        return TextContent(text: text, style: style, fontSize: textSize(args.string("size"), style: style),
                           colorHex: color(args.string("color")), rich: true)
    }

    private func writeFrame(_ args: ToolArgs, content: TextContent, fitted: Bool) throws -> CGRect {
        var x = args.cg("x") ?? area.minX + 60
        let y = args.cg("y") ?? area.minY + 60
        var width = min(736, max(80, args.cg("width") ?? 360))
        if x + width > area.maxX - 12 {
            let shrunk = area.maxX - 12 - x
            if shrunk >= 160 { width = shrunk } else { x = max(area.minX + 12, area.maxX - 12 - width) }
        }
        if fitted { width = ElementRenderer.fittedTextWidth(content, author: .tutor, maxWidth: width, env: env) }
        let h = ElementRenderer.measureText(content, author: .tutor, width: width, env: env).height
        return CGRect(x: x, y: y, width: width, height: h)
    }

    // MARK: Execute

    func execute(toolID: String, name: String, input: JSONValue) -> Outcome {
        let args = ToolArgs(json: input)
        if !allowsStudyTools && CanvasActionExecutor.studyTools.contains(name) {
            return Outcome(result: "\(name) isn't available while glancing; wait until the student asks.", isError: true, action: nil)
        }
        do {
            switch name {
            case "write": return try write(toolID: toolID, args)
            case "write_math": return try writeMath(toolID: toolID, args)
            case "draw": return try draw(args)
            case "geometry": return try geometry(args)
            case "annotate": return try annotate(args)
            case "graph": return try graph(args)
            case "number_line": return try numberLine(args)
            case "table": return try table(args)
            case "add_question": return try addQuestion(args)
            case "mark": return try mark(args)
            case "move": return try move(args)
            case "edit": return try edit(args)
            case "delete": return try delete(args)
            case "erase_ink": return try eraseInk(args)
            case "add_page": return try addPage(args)
            case "focus": return try focus(args)
            case "clear_marks": return try clearMarks(args)
            case "remember": return try remember(args)
            case "make_flashcards": return try makeFlashcards(args)
            case "outline_paper": return try outlinePaper(args)
            case "score_paper": return try scorePaper(args)
            case "paper_summary": return try paperSummary(args)
            default:
                return Outcome(result: "Unknown tool \(name).", isError: true, action: nil)
            }
        } catch let e as ToolInputError {
            discardLive(toolID: toolID)
            return Outcome(result: e.message, isError: true, action: nil)
        } catch {
            discardLive(toolID: toolID)
            return Outcome(result: "Failed: \(error.localizedDescription)", isError: true, action: nil)
        }
    }

    private func write(toolID: String, _ args: ToolArgs) throws -> Outcome {
        let text = try args.requireString("text")
        let content = try writeContent(args, text: text)
        if let id = liveElements[toolID], let start = liveFrames[toolID] {
            let fittedWidth = ElementRenderer.fittedTextWidth(content, author: .tutor, maxWidth: start.width, env: env)
            let h = ElementRenderer.measureText(content, author: .tutor, width: fittedWidth, env: env).height
            let page = document.element(id)?.pageIndex ?? 0
            // The live block was placed while it was a line or two tall; make sure the finished
            // block doesn't run into what's below it.
            let (frame, nudged) = layout.place(CGRect(x: start.minX, y: start.minY, width: fittedWidth, height: h),
                                               page: page, excluding: [id])
            document.update(id, registerUndo: false) {
                $0.kind = .text(content)
                $0.frame = frame
            }
            canvas?.finishLive(id)
            liveElements[toolID] = nil
            var result = "Wrote \(id) on page \(page + 1) at \(describe(frame)) (bottom y=\(Int(frame.maxY)))."
            if nudged { result += " Moved from y=\(Int(start.minY)) to avoid overlapping existing content." }
            return Outcome(result: result, isError: false,
                           action: ChatAction(symbol: "pencil.line", summary: "Wrote on p.\(page + 1)", elementIDs: [id], page: page))
        }
        let page = try resolvePage(args.int("page"))
        let requested = try writeFrame(args, content: content, fitted: true)
        let (frame, nudged) = layout.place(requested, page: page)
        let e = addTutorElement(page: page, frame: frame, kind: .text(content))
        var result = "Wrote \(e.id) on page \(page + 1) at \(describe(frame)) (bottom y=\(Int(frame.maxY)))."
        if nudged { result += " Moved from y=\(Int(requested.minY)) to avoid overlapping existing content." }
        return Outcome(result: result, isError: false,
                       action: ChatAction(symbol: "pencil.line", summary: "Wrote on p.\(page + 1)", elementIDs: [e.id], page: page))
    }

    private func writeMath(toolID: String, _ args: ToolArgs) throws -> Outcome {
        let lines = args.array("lines").compactMap(\.stringValue).filter { !$0.trimmed.isEmpty }
        guard !lines.isEmpty else { throw ToolInputError(message: "Provide at least one line of LaTeX in 'lines'.") }
        let content = MathContent(lines: lines, fontSize: mathSize(args.string("size")), colorHex: color(args.string("color")))
        let size = ElementRenderer.measureMath(content)
        if let id = liveElements[toolID], let start = liveFrames[toolID] {
            let page = document.element(id)?.pageIndex ?? 0
            // Placed when only the first line had streamed; re-check now it has all its lines.
            let (frame, nudged) = layout.place(CGRect(origin: start.origin, size: size), page: page, excluding: [id])
            document.update(id, registerUndo: false) {
                $0.kind = .math(content)
                $0.frame = frame
            }
            canvas?.finishLive(id)
            liveElements[toolID] = nil
            var result = "Wrote math \(id) (\(lines.count) line\(lines.count == 1 ? "" : "s")) on page \(page + 1) at \(describe(frame)) (bottom y=\(Int(frame.maxY)))."
            if nudged { result += " Moved to avoid overlapping existing content." }
            return Outcome(result: result, isError: false,
                           action: ChatAction(symbol: "function", summary: "Worked math on p.\(page + 1)", elementIDs: [id], page: page))
        }
        let page = try resolvePage(args.int("page"))
        let requested = CGRect(x: args.cg("x") ?? area.minX + 60, y: args.cg("y") ?? area.minY + 60, width: size.width, height: size.height)
        let (frame, nudged) = layout.place(requested, page: page)
        let e = addTutorElement(page: page, frame: frame, kind: .math(content))
        var result = "Wrote math \(e.id) on page \(page + 1) at \(describe(frame)) (bottom y=\(Int(frame.maxY)))."
        if nudged { result += " Moved to avoid overlapping existing content." }
        return Outcome(result: result, isError: false,
                       action: ChatAction(symbol: "function", summary: "Worked math on p.\(page + 1)", elementIDs: [e.id], page: page))
    }

    private func draw(_ args: ToolArgs) throws -> Outcome {
        let page = try resolvePage(args.int("page"))
        let strokesJSON = args.array("strokes")
        var strokes: [[CGPoint]] = []
        var closed: [Bool] = []
        var sharp = false
        for s in strokesJSON {
            let pts = points(s["points"])
            guard pts.count >= 2 else { continue }
            strokes.append(pts)
            closed.append(s["closed"]?.boolValue ?? false)
            if s["sharp"]?.boolValue == true { sharp = true }
        }
        guard !strokes.isEmpty else { throw ToolInputError(message: "Each stroke needs at least two [x, y] points.") }
        let isHighlighter = args.string("style") == "highlighter"
        let width = CGFloat(min(30, max(0.8, args.double("width") ?? (isHighlighter ? 14 : 2.5))))
        let hex = color(args.string("color"), default: isHighlighter ? InkPalette.highlighterYellow : nil)
        if sharp {
            // Polygons: close by repeating the first point and skip smoothing via the box purpose.
            strokes = strokes.enumerated().map { (i, s) in closed[i] ? s + [s[0]] : s }
        }
        guard let e = inkElement(page: page, strokes: strokes, colorHex: hex, width: width,
                                 purpose: isHighlighter ? .highlight : (sharp ? .box : .freehand),
                                 opacity: isHighlighter ? 0.38 : 1, closed: sharp ? nil : closed) else {
            throw ToolInputError(message: "Nothing to draw.")
        }
        addInk(e)
        var ids = [e.id]
        for l in args.array("labels") {
            guard let x = l["x"]?.doubleValue, let y = l["y"]?.doubleValue, let text = l["text"]?.stringValue, !text.isEmpty else { continue }
            let content = TextContent(text: text, style: .handwriting, fontSize: 17, colorHex: hex, rich: true)
            let w = ElementRenderer.fittedTextWidth(content, author: .tutor, maxWidth: 220, env: env)
            let h = ElementRenderer.measureText(content, author: .tutor, width: w, env: env).height
            let label = addTutorElement(page: page, frame: CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h), kind: .text(content))
            ids.append(label.id)
        }
        return Outcome(result: "Drew \(e.id) (\(strokes.count) stroke\(strokes.count == 1 ? "" : "s")) on page \(page + 1) covering \(describe(e.frame))" + (ids.count > 1 ? "; labels \(ids.dropFirst().joined(separator: ", "))." : "."),
                       isError: false, action: ChatAction(symbol: "scribble", summary: "Drew on p.\(page + 1)", elementIDs: ids, page: page))
    }

    private func annotate(_ args: ToolArgs) throws -> Outcome {
        let page = try resolvePage(args.int("page"))
        let markName = try args.requireString("mark")
        let x = args.cg("x"), y = args.cg("y")
        let w = args.cg("width") ?? 60, h = args.cg("height") ?? 30
        let target = CGRect(x: x ?? 0, y: y ?? 0, width: max(4, w), height: max(4, h))
        let label = args.string("label")
        var strokes: [[CGPoint]]
        var width: CGFloat = 2.6
        var purpose: InkPurpose
        var opacity: CGFloat = 1
        var defaultColor = "red"
        switch markName {
        case "circle":
            guard x != nil, y != nil else { throw ToolInputError(message: "circle needs x, y, width, height around the target.") }
            strokes = HandDrawn.circle(around: target); purpose = .circle
        case "underline":
            guard x != nil, y != nil else { throw ToolInputError(message: "underline needs the target rectangle.") }
            strokes = HandDrawn.underline(target); purpose = .underline
        case "box":
            guard x != nil, y != nil else { throw ToolInputError(message: "box needs the target rectangle.") }
            strokes = HandDrawn.box(target); purpose = .box
        case "strike":
            guard x != nil, y != nil else { throw ToolInputError(message: "strike needs the target rectangle.") }
            strokes = HandDrawn.strike(target); purpose = .strike
        case "bracket":
            guard x != nil, y != nil else { throw ToolInputError(message: "bracket needs the target rectangle.") }
            strokes = HandDrawn.bracket(target); purpose = .bracket
        case "highlight":
            guard x != nil, y != nil else { throw ToolInputError(message: "highlight needs the target rectangle.") }
            let hl = HandDrawn.highlight(target)
            strokes = hl.strokes; width = hl.width; purpose = .highlight; opacity = 0.4; defaultColor = "yellow"
        case "arrow":
            let from = CGPoint(x: args.cg("from_x") ?? target.minX, y: args.cg("from_y") ?? target.minY)
            guard let tx = args.cg("to_x"), let ty = args.cg("to_y") else { throw ToolInputError(message: "arrow needs to_x and to_y (and from_x, from_y).") }
            strokes = HandDrawn.arrow(from: from, to: CGPoint(x: tx, y: ty)); purpose = .arrow; defaultColor = "blue"
        case "tick":
            strokes = HandDrawn.tick(at: target.origin, size: min(max(w, 24), 48)); purpose = .tick; defaultColor = "green"; width = 3
        case "cross":
            strokes = HandDrawn.cross(at: target.origin, size: min(max(w, 22), 42)); purpose = .cross; width = 3
        case "question":
            strokes = HandDrawn.question(at: target.origin); purpose = .question; defaultColor = "orange"
        case "star":
            strokes = HandDrawn.star(at: target.origin); purpose = .star; defaultColor = "orange"
        default:
            throw ToolInputError(message: "Unknown mark '\(markName)'.")
        }
        let hex = color(args.string("color"), default: InkPalette.hex(for: defaultColor, default: settings.tutorInkHex))
        let resolvedHex = markName == "highlight" && args.string("color") == nil ? InkPalette.highlighterYellow : hex
        guard let e = inkElement(page: page, strokes: strokes, colorHex: resolvedHex, width: width, purpose: purpose,
                                 opacity: opacity, label: label) else { throw ToolInputError(message: "Nothing to draw.") }
        addInk(e)
        let verb: String
        switch markName {
        case "circle": verb = "Circled"
        case "underline": verb = "Underlined"
        case "tick": verb = "Ticked"
        case "cross": verb = "Crossed"
        case "highlight": verb = "Highlighted"
        default: verb = markName.capitalized
        }
        let symbol = markName == "tick" ? "checkmark" : (markName == "cross" ? "xmark" : (markName == "arrow" ? "arrow.up.right" : "circle.dashed"))
        return Outcome(result: "\(verb) on page \(page + 1) (\(e.id), \(describe(e.frame))).", isError: false,
                       action: ChatAction(symbol: symbol, summary: "\(verb)\(label.map { ": \($0.truncated(28))" } ?? "")", elementIDs: [e.id], page: page))
    }

    private func graph(_ args: ToolArgs) throws -> Outcome {
        var warnings: [String] = []
        func functions() -> [GraphFunction] {
            args.array("functions").compactMap { f in
                guard let expr = f["expression"]?.stringValue, !expr.trimmed.isEmpty else { return nil }
                do {
                    _ = try ExpressionParser.parse(expr)
                } catch {
                    warnings.append("Couldn't parse '\(expr)': \(error)")
                    return nil
                }
                return GraphFunction(expression: expr, label: f["label"]?.stringValue,
                                     colorHex: color(f["color"]?.stringValue, default: GraphPalette.next(f["color"]?.stringValue, index: 0)),
                                     dashed: f["dashed"]?.boolValue ?? false,
                                     domainMin: f["domain_min"]?.doubleValue, domainMax: f["domain_max"]?.doubleValue)
            }
        }
        let points = args.array("points").compactMap { p -> GraphPoint? in
            guard let x = p["x"]?.doubleValue, let y = p["y"]?.doubleValue else { return nil }
            return GraphPoint(x: x, y: y, label: p["label"]?.stringValue, colorHex: color(p["color"]?.stringValue, default: "#1F2328"), open: p["open"]?.boolValue ?? false)
        }
        let segments = args.array("segments").compactMap { s -> GraphSegment? in
            guard let x1 = s["x1"]?.doubleValue, let y1 = s["y1"]?.doubleValue, let x2 = s["x2"]?.doubleValue, let y2 = s["y2"]?.doubleValue else { return nil }
            return GraphSegment(x1: x1, y1: y1, x2: x2, y2: y2, colorHex: color(s["color"]?.stringValue, default: settings.tutorInkHex),
                                dashed: s["dashed"]?.boolValue ?? false, arrow: s["arrow"]?.boolValue ?? false, label: s["label"]?.stringValue)
        }
        let guides = args.array("guides").compactMap { g -> GraphGuideLine? in
            let gx = g["x"]?.doubleValue, gy = g["y"]?.doubleValue
            guard gx != nil || gy != nil else { return nil }
            return GraphGuideLine(x: gx, y: gy, colorHex: color(g["color"]?.stringValue, default: "#868E96"), dashed: true, label: g["label"]?.stringValue)
        }
        let shades = args.array("shade").compactMap { s -> GraphShading? in
            guard let from = s["from"]?.doubleValue, let to = s["to"]?.doubleValue else { return nil }
            return GraphShading(upper: s["upper"]?.stringValue, lower: s["lower"]?.stringValue, from: from, to: to,
                                colorHex: color(s["color"]?.stringValue, default: "#1C64F2"))
        }

        if let gid = args.string("graph_id") {
            let e = try element(gid)
            guard case .graph(var g) = e.kind else { throw ToolInputError(message: "\(gid) is not a graph.") }
            noteModified(e)
            var fns = functions()
            for i in fns.indices where args.array("functions")[safe: i]?["color"] == nil {
                fns[i].colorHex = GraphPalette.color(at: g.functions.count + i)
            }
            g.functions += fns
            g.points += points
            g.segments += segments
            g.guides += guides
            g.shadings += shades
            if let v = args.double("x_min") { g.xMin = v }
            if let v = args.double("x_max") { g.xMax = v }
            if let v = args.double("y_min") { g.yMin = v }
            if let v = args.double("y_max") { g.yMax = v }
            if let t = args.string("title") { g.title = t }
            guard g.xMax > g.xMin, g.yMax > g.yMin else { throw ToolInputError(message: "Axis ranges must have max > min.") }
            let updated = g
            document.update(gid, actionName: "Tutor") { $0.kind = .graph(updated) }
            canvas?.elementViews[gid]?.progress = 0
            canvas?.enqueueReveal(elementID: gid, duration: 1.0)
            let plot = ElementRenderer.graphPlotRect(e.frame, g)
            var result = "Updated graph \(gid). " + plotMapping(g, plot: plot, page: e.pageIndex)
            if !warnings.isEmpty { result += " Warnings: " + warnings.joined(separator: "; ") }
            return Outcome(result: result, isError: false,
                           action: ChatAction(symbol: "chart.xyaxis.line", summary: "Updated graph", elementIDs: [gid], page: e.pageIndex))
        }

        let page = try resolvePage(args.int("page"))
        var g = GraphContent()
        g.xMin = args.double("x_min") ?? -10
        g.xMax = args.double("x_max") ?? 10
        g.yMin = args.double("y_min") ?? -10
        g.yMax = args.double("y_max") ?? 10
        guard g.xMax > g.xMin, g.yMax > g.yMin else { throw ToolInputError(message: "Axis ranges must have max > min.") }
        g.xStep = args.double("x_step").flatMap { $0 > 0 ? $0 : nil }
        g.yStep = args.double("y_step").flatMap { $0 > 0 ? $0 : nil }
        g.showGrid = args.bool("grid") ?? true
        g.title = args.string("title")
        g.xLabel = args.string("x_label") ?? "x"
        g.yLabel = args.string("y_label") ?? "y"
        var fns = functions()
        for i in fns.indices where args.array("functions")[safe: i]?["color"] == nil {
            fns[i].colorHex = GraphPalette.color(at: i)
        }
        g.functions = fns
        g.points = points
        g.segments = segments
        g.guides = guides
        g.shadings = shades
        let w = min(area.width - 32, max(200, args.cg("width") ?? 440))
        let h = min(area.height - 40, max(160, args.cg("height") ?? 340))
        let requested = CGRect(x: args.cg("x") ?? area.midX - w / 2, y: args.cg("y") ?? area.minY + 80, width: w, height: h)
        let (frame, nudged) = layout.place(requested, page: page)
        let e = addTutorElement(page: page, frame: frame, kind: .graph(g))
        let plot = ElementRenderer.graphPlotRect(frame, g)
        var result = "Graph \(e.id) on page \(page + 1) at \(describe(frame))\(nudged ? " (moved to free space)" : ""). " + plotMapping(g, plot: plot, page: page)
        if !warnings.isEmpty { result += " Warnings: " + warnings.joined(separator: "; ") }
        return Outcome(result: result, isError: false,
                       action: ChatAction(symbol: "chart.xyaxis.line", summary: "Graphed on p.\(page + 1)", elementIDs: [e.id], page: page))
    }

    private func plotMapping(_ g: GraphContent, plot: CGRect, page: Int) -> String {
        "Plot area: x∈[\(JSONValue.formatNumber(g.xMin)), \(JSONValue.formatNumber(g.xMax))] spans page x \(Int(plot.minX))–\(Int(plot.maxX)); y∈[\(JSONValue.formatNumber(g.yMin)), \(JSONValue.formatNumber(g.yMax))] spans page y \(Int(plot.maxY))–\(Int(plot.minY)) (y up)."
    }

    private func numberLine(_ args: ToolArgs) throws -> Outcome {
        let page = try resolvePage(args.int("page"))
        let minV = try args.requireDouble("min"), maxV = try args.requireDouble("max")
        guard maxV > minV else { throw ToolInputError(message: "max must be greater than min.") }
        var step = args.double("step") ?? 1
        if step <= 0 || (maxV - minV) / step > 60 { step = ElementRenderer.niceStep(maxV - minV, targetTicks: 12) }
        let lineColor = color(args.string("color"), default: "#1F2328")
        var n = NumberLineContent(min: minV, max: maxV, step: step, labelEvery: max(1, args.int("label_every") ?? 1), colorHex: lineColor)
        n.points = args.array("points").compactMap { p in
            guard let v = p["value"]?.doubleValue else { return nil }
            return NumberLinePoint(value: v, label: p["label"]?.stringValue, open: p["open"]?.boolValue ?? false,
                                   colorHex: color(p["color"]?.stringValue))
        }
        n.intervals = args.array("intervals").map { i in
            NumberLineInterval(from: i["from"]?.doubleValue, to: i["to"]?.doubleValue,
                               openStart: i["open_start"]?.boolValue ?? false, openEnd: i["open_end"]?.boolValue ?? false,
                               colorHex: color(i["color"]?.stringValue))
        }
        let w = min(area.width - 32, max(200, args.cg("width") ?? 520))
        let requested = CGRect(x: args.cg("x") ?? area.midX - w / 2, y: args.cg("y") ?? area.minY + 100, width: w, height: 84)
        let (frame, _) = layout.place(requested, page: page)
        let e = addTutorElement(page: page, frame: frame, kind: .numberLine(n))
        return Outcome(result: "Number line \(e.id) on page \(page + 1) at \(describe(frame)); value v sits at page x = \(Int(frame.minX + 16)) + (v − \(JSONValue.formatNumber(minV)))·\(String(format: "%.1f", (frame.width - 32) / CGFloat(maxV - minV))).",
                       isError: false, action: ChatAction(symbol: "ruler", summary: "Number line on p.\(page + 1)", elementIDs: [e.id], page: page))
    }

    private func table(_ args: ToolArgs) throws -> Outcome {
        let page = try resolvePage(args.int("page"))
        let rows = args.array("rows").map { row in (row.arrayValue ?? []).map { $0.stringValue ?? ($0.doubleValue.map(JSONValue.formatNumber) ?? "") } }
        guard !rows.isEmpty, rows.contains(where: { !$0.isEmpty }) else { throw ToolInputError(message: "rows must contain at least one row of cells.") }
        let t = TableContent(rows: rows, header: args.bool("header") ?? true)
        let maxW = min(area.width - 32, args.cg("width") ?? 640)
        let size = ElementRenderer.tableSize(t, maxWidth: maxW)
        let requested = CGRect(x: args.cg("x") ?? area.midX - size.width / 2, y: args.cg("y") ?? area.minY + 100, width: size.width, height: size.height)
        let (frame, _) = layout.place(requested, page: page)
        let e = addTutorElement(page: page, frame: frame, kind: .table(t))
        return Outcome(result: "Table \(e.id) on page \(page + 1) at \(describe(frame)).", isError: false,
                       action: ChatAction(symbol: "tablecells", summary: "Table on p.\(page + 1)", elementIDs: [e.id], page: page))
    }

    private func addQuestion(_ args: ToolArgs) throws -> Outcome {
        let prompt = try args.requireString("prompt")
        let answer = try args.requireString("answer")
        let solution = args.string("solution") ?? answer
        var q = QuestionContent(number: 0, prompt: prompt, marks: max(1, args.int("marks") ?? 1), promptHeight: 0,
                                answer: answer, solution: solution, hint: args.string("hint"), topic: args.string("topic"),
                                difficulty: args.string("difficulty"))
        // A page-width card on pages; on a board, a comfortable card inside the student's view.
        let width = document.isFreeform ? min(720, area.width - 80) : pageWidth - 80
        q.promptHeight = ElementRenderer.questionPromptHeight(q, width: width, env: env)
        let answerSpace = min(560, max(100, args.cg("answer_space") ?? 200))
        let height = q.promptHeight + answerSpace + 14

        var page: Int
        var y: CGFloat
        if document.isFreeform {
            page = 0
            if let requestedY = args.cg("y") {
                y = requestedY
            } else if let free = layout.nextFreeY(page: 0, height: height) {
                y = free
            } else {
                // Below everything in this part of the board; the board grows to fit.
                let b = area
                let bottom = layout.occupied(page: 0).filter { $0.maxX > b.minX && $0.minX < b.maxX }.map(\.maxY).max() ?? b.minY
                y = bottom + 30
            }
        } else if args.bool("new_page") == true {
            page = appendPage()
            y = 50
        } else if let p = args.int("page") {
            page = try resolvePage(p)
            if let requestedY = args.cg("y") {
                y = requestedY
            } else if let free = layout.nextFreeY(page: page, height: height) {
                y = free
            } else {
                // No room left on that page: don't stack the card on top of what's there.
                page = appendPage()
                y = 50
            }
        } else {
            // Continue after the last question if there is one, otherwise on the current page.
            let lastQuestionPage = document.content.elements.filter { if case .question = $0.kind { return true }; return false }.map(\.pageIndex).max()
            page = lastQuestionPage ?? (canvas?.currentPageIndex ?? 0)
            if let free = layout.nextFreeY(page: page, height: height) {
                y = free
            } else if page + 1 < document.content.pages.count, let free = layout.nextFreeY(page: page + 1, height: height) {
                page += 1
                y = free
            } else {
                page = appendPage()
                y = 50
            }
        }
        if !document.isFreeform && y + height > pageHeight - 20 {
            page = appendPage()
            y = 50
        }
        q.number = document.nextQuestionNumber()
        let frame = CGRect(x: area.minX + 40, y: y, width: width, height: height)
        let e = addTutorElement(page: page, frame: frame, kind: .question(q))
        let answerArea = CGRect(x: frame.minX + 14, y: frame.minY + q.promptHeight, width: frame.width - 28, height: answerSpace)
        return Outcome(result: "Added Q\(q.number) (\(e.id)) on page \(page + 1) at \(describe(frame)); answer area \(describe(answerArea)).",
                       isError: false, action: ChatAction(symbol: "questionmark.square", summary: "Question \(q.number)", elementIDs: [e.id], page: page))
    }

    private func mark(_ args: ToolArgs) throws -> Outcome {
        let verdictRaw = try args.requireString("verdict")
        guard let verdict = QuestionStatus(rawValue: verdictRaw), verdict != .open else {
            throw ToolInputError(message: "verdict must be correct, incorrect or partial.")
        }
        let comment = args.string("comment")
        let score = args.string("score")
        let markColor = verdict == .correct ? InkPalette.named["green"]! : (verdict == .incorrect ? InkPalette.named["red"]! : InkPalette.named["orange"]!)
        var page: Int
        var markOrigin: CGPoint
        var commentRect: CGRect?
        var ids: [String] = []
        var summary: String

        if let number = args.int("question") {
            guard let qe = question(number: number), case .question(var q) = qe.kind else {
                throw ToolInputError(message: "There is no Q\(number).")
            }
            page = qe.pageIndex
            let answerArea = CGRect(x: qe.frame.minX + 14, y: qe.frame.minY + q.promptHeight, width: qe.frame.width - 28,
                                    height: qe.frame.height - q.promptHeight - 14)
            if let x = args.cg("x"), let y = args.cg("y") {
                markOrigin = CGPoint(x: x, y: y)
            } else {
                markOrigin = CGPoint(x: answerArea.maxX - 58, y: answerArea.minY + 12)
            }
            noteModified(qe)
            let firstMarking = q.status == .open
            q.status = verdict
            q.score = score ?? (verdict == .correct ? "\(q.marks)/\(q.marks)" : (verdict == .incorrect ? "0/\(q.marks)" : nil))
            q.feedback = comment
            if firstMarking {
                let earned = CanvasActionExecutor.earnedMarks(score: q.score, verdict: verdict, marks: q.marks)
                StudyStore.shared.record(topic: q.topic, subjectID: document.meta.subjectID, earned: earned, possible: Double(max(1, q.marks)))
            }
            let updated = q
            document.update(qe.id, actionName: "Mark") { $0.kind = .question(updated) }
            if comment != nil {
                commentRect = CGRect(x: answerArea.maxX - 300, y: markOrigin.y + 44, width: 290, height: 40)
            }
            summary = "Marked Q\(number) \(verdict.rawValue)\(q.score.map { " (\($0))" } ?? "")"
        } else {
            page = try resolvePage(args.int("page"))
            guard let x = args.cg("x"), let y = args.cg("y") else {
                throw ToolInputError(message: "Give question (number) or page, x and y for the mark.")
            }
            markOrigin = CGPoint(x: x, y: y)
            if comment != nil {
                commentRect = CGRect(x: x + 48, y: y, width: min(280, area.maxX - x - 60), height: 40)
            }
            summary = "Marked \(verdict.rawValue)"
        }

        let strokes: [[CGPoint]]
        switch verdict {
        case .correct: strokes = HandDrawn.tick(at: markOrigin)
        case .incorrect: strokes = HandDrawn.cross(at: markOrigin)
        default: strokes = HandDrawn.partial(at: markOrigin)
        }
        let scoreLabel = args.int("question") != nil ? score : nil
        if let e = inkElement(page: page, strokes: strokes, colorHex: markColor, width: 3.2, purpose: verdict == .correct ? .tick : (verdict == .incorrect ? .cross : .partial),
                              label: scoreLabel) {
            addInk(e)
            ids.append(e.id)
        }
        if let comment, var rect = commentRect {
            let content = TextContent(text: comment, style: .handwriting, fontSize: 18, colorHex: markColor, rich: true)
            rect.size.width = max(140, min(rect.width, area.maxX - rect.minX - 12))
            let w = ElementRenderer.fittedTextWidth(content, author: .tutor, maxWidth: rect.width, env: env)
            let h = ElementRenderer.measureText(content, author: .tutor, width: w, env: env).height
            let requested = CGRect(x: rect.maxX - w, y: rect.minY, width: w, height: h)
            let (frame, _) = layout.place(requested, page: page)
            let c = addTutorElement(page: page, frame: frame, kind: .text(content))
            ids.append(c.id)
        }
        if settings.speakFeedback, let comment {
            TutorVoice.shared.speak(RichTextParser.plainText(comment))
        }
        Haptics.success()
        return Outcome(result: summary + " — " + (ids.isEmpty ? "no marks drawn" : "drew \(ids.joined(separator: ", "))") + ".",
                       isError: false,
                       action: ChatAction(symbol: verdict == .correct ? "checkmark.circle.fill" : (verdict == .incorrect ? "xmark.circle.fill" : "circle.lefthalf.filled"),
                                          summary: summary, elementIDs: ids, page: page))
    }

    private func move(_ args: ToolArgs) throws -> Outcome {
        let id = try args.requireString("element_id")
        let e = try element(id)
        let page = try args.int("page").map { try resolvePage($0) } ?? e.pageIndex
        let x = try args.requireDouble("x"), y = try args.requireDouble("y")
        noteModified(e)
        let requested = CGRect(x: x, y: y, width: e.frame.width, height: e.frame.height)
        // On a board anything on the board is fair game (it grows); pages keep things on the page.
        let maxSide = NoteDocument.boardMaxSide
        let frame = document.isFreeform
            ? CGRect(x: min(max(8, requested.minX), maxSide - requested.width - 8), y: min(max(8, requested.minY), maxSide - requested.height - 8),
                     width: requested.width, height: requested.height)
            : layout.clamp(requested)
        document.update(id, actionName: "Move") {
            $0.pageIndex = page
            $0.frame = frame
        }
        return Outcome(result: "Moved \(id) to page \(page + 1) at \(describe(frame)).", isError: false,
                       action: ChatAction(symbol: "arrow.up.and.down.and.arrow.left.and.right", summary: "Moved an item", elementIDs: [id], page: page))
    }

    private func edit(_ args: ToolArgs) throws -> Outcome {
        let id = try args.requireString("element_id")
        let e = try element(id)
        noteModified(e)
        let newColor = args.string("color").map { color($0) }
        switch e.kind {
        case .text(var t):
            if let text = args.json["text"]?.stringValue { t.text = text }
            if let c = newColor { t.colorHex = c }
            let h = ElementRenderer.measureText(t, author: e.author, width: e.frame.width, env: env).height
            let updated = t
            document.update(id, actionName: "Edit") {
                $0.kind = .text(updated)
                $0.frame.size.height = h
            }
        case .math(var m):
            let lines = args.array("lines").compactMap(\.stringValue)
            if !lines.isEmpty { m.lines = lines }
            if let c = newColor { m.colorHex = c }
            let size = ElementRenderer.measureMath(m)
            let updated = m
            document.update(id, actionName: "Edit") {
                $0.kind = .math(updated)
                $0.frame.size = size
            }
        case .question(var q):
            if let text = args.json["text"]?.stringValue { q.prompt = text }
            q.promptHeight = ElementRenderer.questionPromptHeight(q, width: e.frame.width, env: env)
            let updated = q
            document.update(id, actionName: "Edit") { $0.kind = .question(updated) }
        case .ink(var ink):
            if let c = newColor { ink.colorHex = c }
            let updated = ink
            document.update(id, actionName: "Edit") { $0.kind = .ink(updated) }
        default:
            throw ToolInputError(message: "\(id) (\(e.kind.typeName)) can't be edited this way.")
        }
        canvas?.elementViews[id]?.progress = 0
        canvas?.enqueueReveal(elementID: id, duration: 0.5)
        return Outcome(result: "Edited \(id).", isError: false,
                       action: ChatAction(symbol: "pencil", summary: "Edited an item", elementIDs: [id], page: e.pageIndex))
    }

    private func delete(_ args: ToolArgs) throws -> Outcome {
        let ids = args.array("element_ids").compactMap(\.stringValue)
        guard !ids.isEmpty else { throw ToolInputError(message: "element_ids is empty.") }
        var deleted: [String] = []
        var missing: [String] = []
        for id in ids {
            guard let e = document.element(id) else { missing.append(id); continue }
            noteRemoved(e)
            document.remove(id, actionName: "Delete")
            deleted.append(id)
        }
        var result = "Deleted \(deleted.joined(separator: ", "))."
        if !missing.isEmpty { result += " Not found: \(missing.joined(separator: ", "))." }
        return Outcome(result: result, isError: deleted.isEmpty, action: deleted.isEmpty ? nil : ChatAction(symbol: "trash", summary: "Removed \(deleted.count) item\(deleted.count == 1 ? "" : "s")"))
    }

    private func eraseInk(_ args: ToolArgs) throws -> Outcome {
        let page = try resolvePage(args.int("page"))
        let r = CGRect(x: try args.requireDouble("x"), y: try args.requireDouble("y"),
                       width: try args.requireDouble("width"), height: try args.requireDouble("height"))
        let docRect = document.docRect(r, page: page)
        var d = document.drawing
        let erased = d.strokes.filter { docRect.contains($0.renderBounds.center) }
        let removed = erased.count
        guard removed > 0 else { return Outcome(result: "No ink found in that area.", isError: false, action: nil) }
        d.strokes.removeAll { docRect.contains($0.renderBounds.center) }
        responseRecord.erasedStrokes.append(contentsOf: erased)
        document.replaceDrawing(d, actionName: "Erase")
        return Outcome(result: "Erased \(removed) stroke\(removed == 1 ? "" : "s") on page \(page + 1).", isError: false,
                       action: ChatAction(symbol: "eraser", summary: "Erased ink on p.\(page + 1)", page: page))
    }

    private func addPage(_ args: ToolArgs) throws -> Outcome {
        if document.isFreeform {
            let below = layout.occupied(page: 0).map(\.maxY).max() ?? area.minY
            throw ToolInputError(message: "Freeform boards have no pages. Put new work below what's there (around y \(Int(below + 40))) or beside it; the board grows automatically.")
        }
        let paper: PaperStyle? = args.string("paper").map { name in
            let pattern: PaperPattern
            switch name {
            case "blank": pattern = .blank
            case "grid": pattern = .grid
            case "dots": pattern = .dots
            case "graph": pattern = .graph
            default: pattern = .ruled
            }
            return PaperStyle(pattern: pattern, color: document.content.pages.last?.paper.color ?? .white)
        }
        let number: Int
        if let after = args.int("after_page"), after >= 1, after < document.content.pages.count {
            document.insertPage(after: after - 1, paper: paper)
            number = after + 1
        } else {
            number = appendPage(paper: paper) + 1
        }
        return Outcome(result: "Added page \(number) (the note now has \(document.content.pages.count) pages).", isError: false,
                       action: ChatAction(symbol: "doc.badge.plus", summary: "Added page \(number)", page: number - 1))
    }

    private func focus(_ args: ToolArgs) throws -> Outcome {
        let page = try resolvePage(args.int("page"))
        let r = CGRect(x: try args.requireDouble("x"), y: try args.requireDouble("y"),
                       width: max(20, try args.requireDouble("width")), height: max(20, try args.requireDouble("height")))
        canvas?.focus(docRect: document.docRect(r, page: page), message: args.string("message"))
        return Outcome(result: "Showed the student page \(page + 1) \(describe(r)).", isError: false,
                       action: ChatAction(symbol: "eye", summary: args.string("message")?.truncated(40) ?? "Look here", page: page))
    }

    private func clearMarks(_ args: ToolArgs) throws -> Outcome {
        let page = try args.int("page").map { try resolvePage($0) }
        let targets = document.content.elements.filter { e in
            guard e.author == .tutor else { return false }
            if case .question = e.kind { return false }
            return page == nil || e.pageIndex == page
        }
        for e in targets {
            noteRemoved(e)
            document.remove(e.id, actionName: "Clear Marks")
        }
        return Outcome(result: "Removed \(targets.count) of your marks\(page.map { " from page \($0 + 1)" } ?? "").", isError: false,
                       action: targets.isEmpty ? nil : ChatAction(symbol: "sparkles", summary: "Cleared \(targets.count) marks"))
    }

    /// Marks earned from a score like "3/4", else from the verdict.
    static func earnedMarks(score: String?, verdict: QuestionStatus, marks: Int) -> Double {
        if let score {
            let parts = score.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, let a = Double(parts[0]) { return max(0, min(Double(marks), a)) }
        }
        switch verdict {
        case .correct: return Double(marks)
        case .partial: return Double(marks) / 2
        default: return 0
        }
    }

    // MARK: Flashcards

    private func makeFlashcards(_ args: ToolArgs) throws -> Outcome {
        let items = args.array("cards")
        let cards = items.prefix(30).compactMap { c -> Flashcard? in
            guard let front = c["front"]?.stringValue?.trimmed, !front.isEmpty,
                  let back = c["back"]?.stringValue?.trimmed, !back.isEmpty else { return nil }
            let topic = c["topic"]?.stringValue?.trimmed
            return Flashcard(front: front, back: back, topic: topic?.isEmpty == false ? topic : nil, subjectID: document.meta.subjectID,
                             noteID: document.id, noteTitle: document.meta.title)
        }
        guard !cards.isEmpty else { throw ToolInputError(message: "Give cards as [{front, back, topic}], each with a non-empty front and back.") }
        let added = StudyStore.shared.add(cards)
        let skipped = cards.count - added
        return Outcome(result: "Added \(added) flashcard\(added == 1 ? "" : "s") to the deck" + (skipped > 0 ? " (\(skipped) already there)" : "") + "; they're due for review now.",
                       isError: false, action: ChatAction(symbol: "rectangle.on.rectangle.angled", summary: "\(added) flashcard\(added == 1 ? "" : "s")"))
    }

    // MARK: Past papers

    private func currentPaper() throws -> PaperSession {
        guard let paper = document.content.paper else { throw ToolInputError(message: "This note isn't a past paper.") }
        return paper
    }

    private func outlinePaper(_ args: ToolArgs) throws -> Outcome {
        var paper = try currentPaper()
        notePaperChange()
        let pageCount = document.content.pages.count
        let h = pageHeight
        var qs: [PaperQuestion] = []
        var seen = Set<String>()
        for item in args.array("questions") {
            guard var label = item["label"]?.stringValue?.trimmed, !label.isEmpty,
                  let p = item["page"]?.intValue, p >= 1, p <= pageCount,
                  let marks = item["marks"]?.intValue, marks > 0 else { continue }
            if seen.contains(PaperSession.labelKey(label)) { label += " (\(qs.count + 1))" }
            seen.insert(PaperSession.labelKey(label))
            let y = min(max(0, CGFloat(item["y"]?.doubleValue ?? 40)), h - 40)
            let topic = item["topic"]?.stringValue?.trimmed
            qs.append(PaperQuestion(label: label, page: p - 1, top: y, bottom: h - 20, marks: min(marks, 100),
                                    topic: topic?.isEmpty == false ? topic : nil))
        }
        guard !qs.isEmpty else {
            throw ToolInputError(message: "No usable questions: each needs a label, a page from 1 to \(pageCount), and marks above 0.")
        }
        qs.sort { ($0.page, $0.top) < ($1.page, $1.top) }
        for i in qs.indices {
            if i + 1 < qs.count, qs[i + 1].page == qs[i].page {
                qs[i].bottom = max(qs[i].top + 30, qs[i + 1].top - 6)
            }
            // Keep marks already given when the outline is corrected.
            if let old = paper.index(of: qs[i].label) {
                qs[i].awarded = paper.questions[old].awarded
                qs[i].feedback = paper.questions[old].feedback
                qs[i].markElementID = paper.questions[old].markElementID
            }
        }
        paper.questions = qs
        paper.outlined = true
        document.content.paper = paper
        document.markDirty()
        let pages = Set(qs.map(\.page)).count
        var result = "Outlined \(qs.count) question parts, \(paper.totalMarks) marks in total, across \(pages) page\(pages == 1 ? "" : "s")."
        if let printed = args.int("paper_total"), printed != paper.totalMarks {
            result += " Warning: the paper's printed total is \(printed), so some marks are missing or counted twice (list only the lowest-level parts, not a question and its parts). Call outline_paper again with the corrected list."
        }
        return Outcome(result: result, isError: false, action: ChatAction(symbol: "list.bullet.rectangle", summary: "Mapped \(qs.count) questions"))
    }

    private func scorePaper(_ args: ToolArgs) throws -> Outcome {
        var paper = try currentPaper()
        let label = try args.requireString("label")
        guard let i = paper.index(of: label) else {
            throw ToolInputError(message: "No question \(label) in the outline. Questions: " + paper.questions.map(\.label).joined(separator: ", ") + ".")
        }
        guard let raw = args.int("awarded") else { throw ToolInputError(message: "Missing 'awarded'.") }
        notePaperChange()
        var q = paper.questions[i]
        let awarded = max(0, min(q.marks, raw))
        let firstTime = q.awarded == nil
        // Re-marking replaces the earlier margin score.
        if let old = q.markElementID, let e = document.element(old) {
            noteRemoved(e)
            document.remove(old, actionName: "Tutor")
        }
        let full = awarded == q.marks, none = awarded == 0
        let purpose: InkPurpose = full ? .tick : (none ? .cross : .partial)
        let hex = full ? InkPalette.named["green"]! : (none ? InkPalette.named["red"]! : InkPalette.named["orange"]!)
        // In the right-hand margin just below the question line, clear of the printed "[n marks]".
        let origin = CGPoint(x: pageWidth - 56, y: q.top + 26)
        let strokes = full ? HandDrawn.tick(at: origin, size: 26) : (none ? HandDrawn.cross(at: origin, size: 22) : HandDrawn.partial(at: origin, size: 26))
        var ids: [String] = []
        if let e = inkElement(page: q.page, strokes: strokes, colorHex: hex, width: 3, purpose: purpose, label: "\(awarded)/\(q.marks)",
                              labelAt: CGPoint(x: origin.x - 4, y: origin.y + 30)) {
            addInk(e)
            ids.append(e.id)
        }
        q.awarded = awarded
        q.feedback = args.string("feedback")
        q.markElementID = ids.first
        paper.questions[i] = q
        document.content.paper = paper
        document.markDirty()
        if firstTime {
            StudyStore.shared.record(topic: q.topic, subjectID: document.meta.subjectID, earned: Double(awarded), possible: Double(q.marks))
        }
        Haptics.success()
        return Outcome(result: "\(q.label): \(awarded)/\(q.marks) recorded. Running total \(paper.awardedMarks)/\(paper.markedMarks) with \(paper.markedCount) of \(paper.questions.count) questions marked (\(paper.totalMarks) marks available).",
                       isError: false,
                       action: ChatAction(symbol: full ? "checkmark.circle.fill" : (none ? "xmark.circle.fill" : "circle.lefthalf.filled"),
                                          summary: "\(q.label): \(awarded)/\(q.marks)", elementIDs: ids, page: q.page))
    }

    /// Writes a results page at the end of the note: score, time, summary, per-question table.
    private func paperSummary(_ args: ToolArgs) throws -> Outcome {
        var paper = try currentPaper()
        let summary = try args.requireString("summary")
        let strengths = args.array("strengths").compactMap { $0.stringValue?.trimmed }.filter { !$0.isEmpty }
        let review = args.array("to_review").compactMap { $0.stringValue?.trimmed }.filter { !$0.isEmpty }
        let next = args.string("next_steps")
        notePaperChange()
        var page = appendPage(paper: PaperStyle(pattern: .blank, color: .white))
        let firstPage = page
        let width = pageWidth - 112
        let hex = settings.tutorInkHex
        var ids: [String] = []
        var y: CGFloat = 56

        func text(_ s: String, style: TextStyle, size: CGFloat, color: String = hex, gap: CGFloat = 10) {
            let t = TextContent(text: s, style: style, fontSize: size, colorHex: color, rich: true)
            let h = ElementRenderer.measureText(t, author: .tutor, width: width, env: env).height
            if y + h > pageHeight - 40 {
                page = appendPage(paper: PaperStyle(pattern: .blank, color: .white))
                y = 56
            }
            ids.append(addTutorElement(page: page, frame: CGRect(x: 56, y: y, width: width, height: h), kind: .text(t)).id)
            y += h + gap
        }

        let total = paper.totalMarks, got = paper.awardedMarks
        let pct = total > 0 ? Int((Double(got) / Double(total) * 100).rounded()) : 0
        text("Results: \(got)/\(total) (\(pct)%)", style: .heading, size: 32, gap: 4)
        var facts: [String] = []
        if paper.startedAt != nil, let end = paper.finishedAt {
            facts.append("Time: \(max(1, Int(paper.elapsed(at: end) / 60))) min" + (paper.timeLimitMinutes.map { " of \($0)" } ?? ""))
        }
        facts.append("\(paper.markedCount) of \(paper.questions.count) questions marked")
        text(facts.joined(separator: " · "), style: .note, size: 16, color: "#57606A", gap: 18)
        text(summary, style: .handwriting, size: 20, gap: 18)
        if !strengths.isEmpty { text("**Went well:** " + strengths.joined(separator: "; "), style: .handwriting, size: 19, color: InkPalette.named["green"]!) }
        if !review.isEmpty { text("**To review:** " + review.joined(separator: "; "), style: .handwriting, size: 19, color: InkPalette.named["red"]!) }
        if let next { text("**Next:** " + next, style: .handwriting, size: 19, gap: 22) }

        // Per-question table, split into columns of up to 18 rows.
        let rows = paper.questions.map { q in [q.label, q.awarded.map { "\($0)/\(q.marks)" } ?? "–/\(q.marks)", q.topic ?? ""] }
        let chunks = stride(from: 0, to: rows.count, by: 18).map { Array(rows[$0..<min($0 + 18, rows.count)]) }
        let columnWidth = (width - 20) / 2
        var column = 0
        var rowTop = y
        for chunk in chunks {
            let t = TableContent(rows: [["Question", "Marks", "Topic"]] + chunk, header: true, fontSize: 14)
            let size = ElementRenderer.tableSize(t, maxWidth: columnWidth)
            if rowTop + size.height > pageHeight - 40 {
                page = appendPage(paper: PaperStyle(pattern: .blank, color: .white))
                rowTop = 56
                column = 0
            }
            let frame = CGRect(x: 56 + CGFloat(column) * (columnWidth + 20), y: rowTop, width: size.width, height: size.height)
            ids.append(addTutorElement(page: page, frame: frame, kind: .table(t)).id)
            column += 1
            if column == 2 {
                column = 0
                rowTop += size.height + 20
            }
        }
        paper.summary = summary
        paper.resultsPage = firstPage
        document.content.paper = paper
        document.markDirty()
        canvas?.scrollToPage(firstPage)
        return Outcome(result: "Results written on page \(firstPage + 1): \(got)/\(total) (\(pct)%).", isError: false,
                       action: ChatAction(symbol: "chart.bar.doc.horizontal", summary: "Results: \(got)/\(total)", elementIDs: ids, page: firstPage))
    }

    private func remember(_ args: ToolArgs) throws -> Outcome {
        let note = try args.requireString("note")
        memory.add(note)
        return Outcome(result: "Saved to memory.", isError: false, action: ChatAction(symbol: "brain", summary: "Remembered: \(note.truncated(40))"))
    }
}

/// Distinct colours for multiple curves on one graph.
enum GraphPalette {
    static let colors = ["#1C64F2", "#E03131", "#2F9E44", "#7048E8", "#F76707", "#0C8599"]

    static func color(at i: Int) -> String { colors[i % colors.count] }

    static func next(_ requested: String?, index: Int) -> String {
        requested.map { InkPalette.hex(for: $0, default: color(at: index)) } ?? color(at: index)
    }
}
