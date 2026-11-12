import Foundation

/// Notes the Home study agent passes to the note tutors: what's coming up on Canvas, an
/// assessment's requirements, themes in teacher feedback. A brief can be for one subject or for
/// every note, and the tutors see the relevant ones in each turn.
final class AgentBriefStore: ObservableObject {
    static let shared = AgentBriefStore()

    struct Brief: Codable, Identifiable, Equatable {
        var id = UUID()
        var text: String
        /// nil: shared with every tutor.
        var subjectID: UUID?
        var date = Date()
    }

    @Published private(set) var briefs: [Brief] = []

    static var url: URL { Storage.root.appendingPathComponent("agent_briefs.json") }

    private init() {
        briefs = Storage.read([Brief].self, from: AgentBriefStore.url) ?? []
    }

    func add(_ text: String, subjectID: UUID?) {
        let t = text.trimmed
        guard !t.isEmpty else { return }
        if briefs.contains(where: { $0.subjectID == subjectID && $0.text.caseInsensitiveCompare(t) == .orderedSame }) { return }
        briefs.append(Brief(text: String(t.prefix(1500)), subjectID: subjectID))
        // Keep what goes into every tutor request small.
        if briefs.count > 30 { briefs.removeFirst(briefs.count - 30) }
        save()
    }

    func remove(_ brief: Brief) {
        briefs.removeAll { $0.id == brief.id }
        save()
    }

    func clear() {
        briefs.removeAll()
        save()
    }

    private func save() {
        let snapshot = briefs
        Storage.ioQueue.async { try? Storage.write(snapshot, to: AgentBriefStore.url) }
    }

    /// The briefs a note's tutor should see: those for its subject and the shared ones, newest
    /// last, capped at about 4,000 characters.
    func promptText(subjectID: UUID?) -> String {
        let relevant = briefs.filter { $0.subjectID == nil || $0.subjectID == subjectID }
        guard !relevant.isEmpty else { return "" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        var lines: [String] = []
        var total = 0
        for b in relevant.reversed() {
            let line = "- \(f.string(from: b.date)): \(b.text)"
            total += line.count
            if total > 4000 { break }
            lines.insert(line, at: 0)
        }
        return lines.joined(separator: "\n")
    }
}
