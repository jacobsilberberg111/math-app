import Foundation

/// A flashcard: front and back understand `$math$` and `**bold**` like the tutor's writing.
struct Flashcard: Codable, Identifiable, Equatable {
    var id = UUID()
    var front: String
    var back: String
    var topic: String?
    var subjectID: UUID?
    var noteID: UUID?
    var noteTitle: String?
    var createdAt = Date()
    var review: ReviewState

    init(front: String, back: String, topic: String? = nil, subjectID: UUID? = nil, noteID: UUID? = nil, noteTitle: String? = nil, now: Date = Date()) {
        self.front = front
        self.back = back
        self.topic = topic
        self.subjectID = subjectID
        self.noteID = noteID
        self.noteTitle = noteTitle
        self.createdAt = now
        self.review = ReviewState(due: now)
    }
}

/// Everything that outlives a single note: the flashcard deck, marked attempts by topic, and
/// time studied per day. Stored in Documents/TutorNotes/study.json.
@MainActor
@Observable
final class StudyStore {
    static let shared = StudyStore()

    private struct File: Codable {
        var cards: [Flashcard] = []
        var attempts: [TopicAttempt] = []
        /// "yyyy-MM-dd" → seconds with a note open.
        var studyLog: [String: Double] = [:]
    }

    private(set) var cards: [Flashcard] = []
    private(set) var attempts: [TopicAttempt] = []
    private(set) var studyLog: [String: Double] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    static var url: URL { Storage.root.appendingPathComponent("study.json") }

    private init() {
        let f = Storage.read(File.self, from: StudyStore.url) ?? File()
        cards = f.cards
        attempts = f.attempts
        studyLog = f.studyLog
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
        let f = File(cards: cards, attempts: attempts, studyLog: studyLog)
        let url = StudyStore.url
        Storage.ioQueue.async { try? Storage.write(f, to: url) }
    }

    // MARK: Flashcards

    func dueCards(now: Date = Date(), subjectID: UUID? = nil) -> [Flashcard] {
        cards.filter { $0.review.isDue(at: now) && (subjectID == nil || $0.subjectID == subjectID) }
            .sorted { $0.review.due < $1.review.due }
    }

    /// Same front text, ignoring case and spacing (but not symbols: "x − 4" and "x + 4" differ).
    static func frontKey(_ front: String) -> String {
        front.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Adds cards, skipping any whose front is already in the deck (or earlier in this batch).
    @discardableResult
    func add(_ new: [Flashcard]) -> Int {
        var existing = Set(cards.map { StudyStore.frontKey($0.front) })
        var added = 0
        for c in new where !c.front.trimmed.isEmpty && !c.back.trimmed.isEmpty {
            let key = StudyStore.frontKey(c.front)
            guard !existing.contains(key) else { continue }
            existing.insert(key)
            cards.append(c)
            added += 1
        }
        if added > 0 { scheduleSave() }
        return added
    }

    func grade(_ card: Flashcard, _ grade: RecallGrade, now: Date = Date()) {
        guard let i = cards.firstIndex(where: { $0.id == card.id }) else { return }
        cards[i].review = cards[i].review.reviewed(grade, now: now)
        scheduleSave()
    }

    func delete(_ card: Flashcard) {
        cards.removeAll { $0.id == card.id }
        scheduleSave()
    }

    // MARK: Topics

    func record(topic: String?, subjectID: UUID?, earned: Double, possible: Double, now: Date = Date()) {
        guard let topic = topic?.trimmed, !topic.isEmpty, possible > 0 else { return }
        attempts.append(TopicAttempt(topic: topic, subjectID: subjectID, earned: earned, possible: possible, date: now))
        if attempts.count > 2000 { attempts.removeFirst(attempts.count - 2000) }
        scheduleSave()
    }

    func topicStats(now: Date = Date()) -> [TopicStat] { TopicStats.summarize(attempts, now: now) }

    /// A line for the tutor's context: what the student has found hard lately.
    var weakTopicsLine: String? {
        let weak = TopicStats.weakest(topicStats(), minAttempts: 2, limit: 4)
        guard !weak.isEmpty else { return nil }
        return weak.map { "\($0.topic) (\(Int(($0.score * 100).rounded()))%)" }.joined(separator: ", ")
    }

    // MARK: Study time

    /// Adds time studied, split across midnight if needed. Sessions are capped so a note left
    /// open overnight doesn't count as hours of study.
    func logStudy(from start: Date, to end: Date) {
        var from = start
        let to = min(end, start.addingTimeInterval(3 * 3600))
        guard to > from else { return }
        let cal = Calendar.current
        while from < to {
            let nextDay = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: from)) ?? to
            let chunkEnd = min(to, nextDay)
            studyLog[StudyStreak.dayKey(from), default: 0] += chunkEnd.timeIntervalSince(from)
            from = chunkEnd
        }
        scheduleSave()
    }

    /// Days with at least a minute of study.
    var studyDays: Set<String> { Set(studyLog.filter { $0.value >= 60 }.keys) }

    var streak: Int { StudyStreak.current(days: studyDays, today: Date()) }

    var secondsThisWeek: Double { StudyStreak.seconds(in: studyLog, lastDays: 7, today: Date()) }
}
