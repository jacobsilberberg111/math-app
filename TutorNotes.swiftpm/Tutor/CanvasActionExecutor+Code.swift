import UIKit

/// The `code` and `run_code` tools.
extension CanvasActionExecutor {
    /// Longest example the tutor may put on the page (a page holds about 40 rows).
    static let maxCodeLines = 60

    func codeTool(_ args: ToolArgs) async throws -> Outcome {
        guard let raw = args.json["code"]?.stringValue, !raw.trimmed.isEmpty else {
            throw ToolInputError(message: "Missing 'code': the program text, with \\n between lines.")
        }
        var lines = CodeText.lines(raw)
        while lines.last?.trimmed.isEmpty == true { lines.removeLast() }
        while lines.first?.trimmed.isEmpty == true { lines.removeFirst() }
        guard lines.count <= CanvasActionExecutor.maxCodeLines else {
            throw ToolInputError(message: "That's \(lines.count) lines; keep code blocks to \(CanvasActionExecutor.maxCodeLines) lines or fewer (short examples teach best). Split it, or show only the part that matters.")
        }
        let code = lines.joined(separator: "\n")
        if let name = args.string("language"), !["python", "pseudocode"].contains(name.lowercased()) {
            throw ToolInputError(message: "language must be \"python\" or \"pseudocode\".")
        }
        let lang = CodeLanguage(loose: args.string("language"))
        let input = codeInput(args)
        let page = try resolvePage(args.int("page"))
        var c = CodeContent(language: lang.rawValue, code: code, title: args.string("title"),
                            stdin: input.map { $0.joined(separator: "\n") })
        var run: CodeRunResult?
        var note = ""
        if args.bool("run") == true {
            if lang.isRunnable {
                // Run first, so the block is placed at its final size with the output on it.
                let r = await PythonRunner.shared.run(code, stdin: input ?? [])
                try Task.checkCancellation()
                if r.ran { c = r.applied(to: c, at: Date()) }
                run = r
            } else {
                note = " Pseudocode isn't run, so run was ignored."
            }
        }
        let width = min(max(300, args.cg("width") ?? 560), max(300, area.width - 32))
        let size = CodeRenderer.size(for: c, width: width)
        let requested = CGRect(x: args.cg("x") ?? area.midX - width / 2, y: args.cg("y") ?? area.minY + 100, width: width, height: size.height)
        let placed = layout.place(requested, page: page)
        var frame = placed.rect
        let moved = placed.nudged
        if abs(frame.width - width) > 0.5 {
            frame.size.height = CodeRenderer.size(for: c, width: frame.width).height
        }
        let e = addTutorElement(page: page, frame: frame, kind: .code(c))
        let card = CodeRenderer.layout(c, width: frame.width)
        var result = "Code block \(e.id) (\(lang.displayName), \(card.lines.count) line\(card.lines.count == 1 ? "" : "s")) on page \(page + 1) at \(describe(frame))"
        result += moved ? " (moved to free space)" : ""
        result += " (bottom y=\(Int(frame.maxY))). " + card.linePositions(origin: frame.origin, maxLines: CanvasActionExecutor.maxCodeLines)
        if let run {
            result += "\n" + run.report(subject: e.id, inputLines: input?.count ?? 0)
        } else if lang.isRunnable {
            result += " Not run yet (use run_code with element_id \(e.id) to run it)."
        }
        result += note
        return Outcome(result: result, isError: false,
                       action: ChatAction(symbol: "chevron.left.forwardslash.chevron.right", summary: "Code on p.\(page + 1)", elementIDs: [e.id], page: page))
    }

    func runCodeTool(_ args: ToolArgs) async throws -> Outcome {
        let override = codeInput(args)
        if let id = args.string("element_id") {
            let e = try element(id)
            guard case .code(let c) = e.kind else {
                throw ToolInputError(message: "\(id) is a \(e.kind.typeName), not a code block.")
            }
            guard c.isRunnable else {
                throw ToolInputError(message: "\(id) is pseudocode, which can't be run. Read it line by line instead; a trace table (desk check) is a good way to check it with the student.")
            }
            guard !c.code.trimmed.isEmpty else {
                throw ToolInputError(message: "\(id) is empty: there's nothing to run yet.")
            }
            let input = override ?? c.stdinLines
            let r = await PythonRunner.shared.run(c.code, stdin: input)
            try Task.checkCancellation()
            var text = r.report(subject: id, inputLines: input.count)
            if r.ran {
                if override != nil {
                    text += "\n(Ran with the input you gave, so \(id) still shows its own last output.)"
                } else {
                    // Recorded so "Undo the tutor" also takes the stored output back off.
                    if let current = document.element(id) { noteModified(current) }
                    if CodeExecution.store(r, ranWith: c, into: id, in: document) {
                        var stored = "\nThe output is now shown on \(id)"
                        if let frame = document.element(id)?.frame {
                            stored += " (it now covers \(describe(frame)), bottom y=\(Int(frame.maxY)))"
                        }
                        text += stored + "."
                    }
                }
            }
            return Outcome(result: text, isError: r.status == .unavailable,
                           action: r.ran ? ChatAction(symbol: "play.fill", summary: "Ran \(id)", elementIDs: [id], page: e.pageIndex) : nil)
        }
        guard let raw = args.json["code"]?.stringValue, !raw.trimmed.isEmpty else {
            throw ToolInputError(message: "Give element_id (a Python code block on the page) or code (Python to test without putting it on the page).")
        }
        let input = override ?? []
        let r = await PythonRunner.shared.run(raw, stdin: input)
        try Task.checkCancellation()
        return Outcome(result: r.report(subject: "your test code (off the page; the student doesn't see it)", inputLines: input.count),
                       isError: r.status == .unavailable, action: nil)
    }

    /// The program input from `stdin`: an array (one entry per input() call), or a string with
    /// one line per call. Nil when not given.
    private func codeInput(_ args: ToolArgs) -> [String]? {
        guard let v = args.json["stdin"] else { return nil }
        if let arr = v.arrayValue {
            return arr.map { $0.stringValue ?? $0.doubleValue.map(JSONValue.formatNumber) ?? "" }
        }
        if let s = v.stringValue { return CodeText.inputLines(s) }
        if let d = v.doubleValue { return [JSONValue.formatNumber(d)] }
        return nil
    }
}
