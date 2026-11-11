import SwiftUI

/// What the student can ask the tutor about a code block (the code editor's Ask Tutor menu).
enum CodeHelpRequest: String, CaseIterable, Identifiable {
    case debug, explain, check, hint

    var id: String { rawValue }

    var title: String {
        switch self {
        case .debug: return "Why isn't it working?"
        case .explain: return "Explain my code"
        case .check: return "Check my code"
        case .hint: return "Give me a hint"
        }
    }

    var symbol: String {
        switch self {
        case .debug: return "ladybug"
        case .explain: return "text.bubble"
        case .check: return "checkmark.seal"
        case .hint: return "lightbulb"
        }
    }
}

extension EditorModel {
    /// Insert → Code Block: an empty Python block in view, opened in the code editor.
    func insertCodeBlock() {
        let c = CodeContent(code: "")
        guard let e = insertStudentElement(.code(c), size: CodeRenderer.size(for: c, width: 560), actionName: "Insert Code") else { return }
        codeEditTarget = CodeEditTarget(id: e.id)
    }

    /// Asks the tutor about a code block. The tutor already sees the block's code (with line
    /// numbers and where each line is on the page) and its last output in the page map; the
    /// message says what kind of help the student wants and keeps them doing the fixing.
    func askTutor(aboutCode id: String, _ request: CodeHelpRequest) {
        guard let e = document.element(id), case .code(let c) = e.kind else { return }
        let pseudo = !c.isRunnable
        let what = pseudo ? "pseudocode" : "code"
        var context = ""
        if !pseudo {
            if let err = c.error, !err.isEmpty {
                let s = CodeTraceback.summary(err)
                context = " When I run it, it stops with \"\(s.message)\"" + (s.line.map { " on line \($0)" } ?? "") + "."
            } else if !c.hasRun {
                context = " I haven't run it yet."
            }
        }
        let text: String
        switch request {
        case .debug:
            text = "My \(what) in block \(id) isn't doing what I want.\(context) Help me find the problem myself: "
                + (pseudo ? "trace it with me if that helps" : "run it if that helps")
                + ", point at the line that matters on the page and ask me a question about it. Don't rewrite my program."
        case .explain:
            text = "Explain what my \(what) in block \(id) does, in simple words, pointing at the important lines on the page.\(context)"
        case .check:
            text = "Check my \(what) in block \(id).\(context) Does it do what it should? "
                + (pseudo ? "Desk check it (a trace table helps)" : "Test it with normal, boundary and unexpected input")
                + ", then tell me what's good and the most important thing to improve, without rewriting it for me."
        case .hint:
            text = "Give me one small hint for my \(what) in block \(id), without giving me the answer.\(context)"
        }
        showPanelIfNoKey()
        tutor.send(text, focus: (e.pageIndex, e.frame.insetBy(dx: -8, dy: -8)), displayText: request.title)
    }
}
