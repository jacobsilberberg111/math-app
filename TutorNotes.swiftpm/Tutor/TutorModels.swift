import Foundation
import PencilKit

/// One entry in the tutor chat.
struct ChatItem: Codable, Identifiable, Equatable {
    enum Role: String, Codable {
        case student, tutor, notice, observer
    }

    var id = UUID()
    var role: Role
    var text: String
    var thinking: String = ""
    var actions: [ChatAction] = []
    var attachmentNames: [String] = []
    var createdAt = Date()
    var model: String?
    var isStreaming = false
    var error: String?
    var contextLabel: String?
    var canRevert = false
    var reverted = false
}

/// A canvas edit the tutor made, shown as a tappable chip under its message.
struct ChatAction: Codable, Identifiable, Equatable {
    var id = UUID()
    var symbol: String
    var summary: String
    var elementIDs: [String] = []
    var page: Int?
}

/// What a tutor turn changed on the canvas, so the student can undo the whole turn at once.
struct TurnRecord {
    var created: [String] = []
    var originals: [String: CanvasElement] = [:]
    var removed: [CanvasElement] = []
    var drawingBefore: PKDrawing?

    var isEmpty: Bool { created.isEmpty && originals.isEmpty && removed.isEmpty && drawingBefore == nil }

    mutating func merge(_ other: TurnRecord) {
        created.append(contentsOf: other.created)
        for (k, v) in other.originals where originals[k] == nil { originals[k] = v }
        removed.append(contentsOf: other.removed)
        if drawingBefore == nil { drawingBefore = other.drawingBefore }
    }
}

/// Persisted per note: the raw API conversation (replayed verbatim, append-only) plus the chat.
struct TutorSessionFile: Codable {
    var version = 1
    var conversationID = UUID()
    var apiMessagesJSON = "[]"
    var chat: [ChatItem] = []
    var observerNotes: [String] = []
    var sentAttachmentIDs: [String] = []
}

/// Quick actions offered on the canvas and in the panel.
enum TutorQuickAction: String, CaseIterable, Identifiable {
    case check, hint, nextStep, explain, solve, graphIt, similar, markAll, practice

    var id: String { rawValue }

    var title: String {
        switch self {
        case .check: return "Check my work"
        case .hint: return "Hint"
        case .nextStep: return "Next step"
        case .explain: return "Explain"
        case .solve: return "Full solution"
        case .graphIt: return "Graph it"
        case .similar: return "Similar question"
        case .markAll: return "Mark my answers"
        case .practice: return "Practice"
        }
    }

    var symbol: String {
        switch self {
        case .check: return "checkmark.circle"
        case .hint: return "lightbulb"
        case .nextStep: return "arrow.down.right"
        case .explain: return "text.bubble"
        case .solve: return "list.number"
        case .graphIt: return "chart.xyaxis.line"
        case .similar: return "square.on.square"
        case .markAll: return "checklist"
        case .practice: return "pencil.and.list.clipboard"
        }
    }

    /// The instruction sent to the tutor for this action.
    func prompt(regionDescription: String?) -> String {
        let target = regionDescription.map { "the work in \($0)" } ?? "my work on the page I'm looking at"
        switch self {
        case .check:
            return "Check \(target). Mark what's right with ticks and circle any mistakes directly on the page, with a few words on each. Don't redo it for me — help me fix it."
        case .hint:
            return "Give me a hint for \(target) — just enough to get me unstuck, written on the page next to my work. Don't give the answer."
        case .nextStep:
            return "Show me only the next step for \(target), written right below my last line."
        case .explain:
            return "Explain \(target) clearly. Use the page: write the key idea, draw a diagram or graph if it helps, and keep it short."
        case .solve:
            return "Show a complete worked solution for \(target) on the page, step by step, aligned neatly, in space that doesn't cover my writing."
        case .graphIt:
            return "Graph what's in \(target) on the page, with the key features labelled (intercepts, turning points, asymptotes as relevant)."
        case .similar:
            return "Give me a similar question to \(target) to try, as a question card with space to answer."
        case .markAll:
            return "Mark all the questions I've answered. Tick or cross each one, give a score, and write brief feedback. Then tell me what to practise next."
        case .practice:
            return "Give me some practice questions on what we're working on."
        }
    }
}

struct PracticeRequest {
    var topic: String
    var count: Int
    var difficulty: String
    var style: String
    var newPage: Bool

    var prompt: String {
        var s = "Create \(count) practice question\(count == 1 ? "" : "s") on: \(topic). Difficulty: \(difficulty)."
        if !style.isEmpty { s += " Style: \(style)." }
        s += newPage ? " Put them on a new page." : " Put them in free space on the current page, adding pages if needed."
        s += " Use add_question for each (with accurate hidden answers and solutions), ordered from easier to harder. Then write a one-line instruction at the top of the first one."
        return s
    }
}
