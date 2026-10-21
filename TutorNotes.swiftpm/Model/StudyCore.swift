import Foundation

// Platform-independent study logic (Foundation only, unit-tested in CoreTests): flashcard
// scheduling, topic statistics and study streaks.

// MARK: - Spaced repetition

/// How well a flashcard was remembered.
enum RecallGrade: Int, Codable, CaseIterable, Identifiable {
    case again, hard, good, easy

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .again: return "Again"
        case .hard: return "Hard"
        case .good: return "Good"
        case .easy: return "Easy"
        }
    }
}

/// SM-2-style scheduling state for one card: intervals grow by the card's ease each time it's
/// remembered, and a forgotten card comes back in ten minutes with a lower ease.
struct ReviewState: Codable, Equatable {
    var due: Date
    /// Days until the next review after the last successful one (0 while new or relearning).
    var interval: Double = 0
    var ease: Double = 2.5
    /// Successful reviews in a row.
    var reps: Int = 0
    /// Times it was forgotten after being learned.
    var lapses: Int = 0

    static let minEase = 1.3
    static let maxIntervalDays = 730.0

    var isNew: Bool { reps == 0 && lapses == 0 && interval == 0 }

    func isDue(at now: Date) -> Bool { due <= now }

    /// The state after answering with `grade` at `now`.
    func reviewed(_ grade: RecallGrade, now: Date) -> ReviewState {
        var s = self
        let learned = reps > 0
        switch grade {
        case .again:
            if learned { s.lapses += 1 }
            s.reps = 0
            s.ease = max(ReviewState.minEase, ease - 0.2)
            s.interval = 0
            s.due = now.addingTimeInterval(10 * 60)
            return s
        case .hard:
            s.ease = max(ReviewState.minEase, ease - 0.15)
            s.interval = learned ? max(interval + 1, interval * 1.2) : 0.25
        case .good:
            s.interval = learned ? max(interval + 1, interval * ease) : 1
            if reps == 1 { s.interval = max(s.interval, 3) }
        case .easy:
            s.ease = ease + 0.15
            s.interval = learned ? max(interval + 2, interval * ease * 1.3) : 4
        }
        s.interval = min(ReviewState.maxIntervalDays, s.interval)
        s.reps += 1
        s.due = now.addingTimeInterval(s.interval * 86_400)
        return s
    }

    /// When the card would come back if answered with `grade` now, e.g. "10m", "6h", "3d", "2mo".
    func preview(_ grade: RecallGrade, now: Date) -> String {
        ReviewState.shortInterval(reviewed(grade, now: now).due.timeIntervalSince(now))
    }

    static func shortInterval(_ seconds: TimeInterval) -> String {
        let minutes = seconds / 60
        if minutes < 60 { return "\(max(1, Int(minutes.rounded())))m" }
        let hours = minutes / 60
        if hours < 24 { return "\(Int(hours.rounded()))h" }
        let days = hours / 24
        if days < 30 { return "\(Int(days.rounded()))d" }
        if days < 365 { return "\(Int((days / 30).rounded()))mo" }
        return String(format: "%.1fy", days / 365)
    }
}

// MARK: - Topic statistics

/// One marked attempt at something with a topic (a question card or a past-paper question).
struct TopicAttempt: Codable, Equatable {
    var topic: String
    var subjectID: UUID?
    var earned: Double
    var possible: Double
    var date: Date
}

struct TopicStat: Identifiable, Equatable {
    var id: String { key }
    var key: String
    /// The most recent spelling, for display.
    var topic: String
    var subjectID: UUID?
    var earned: Double
    var possible: Double
    var attempts: Int
    var lastDate: Date

    /// Recency-weighted share of marks earned (0...1).
    var score: Double
}

enum TopicStats {
    /// Case- and punctuation-insensitive key, so "Factorising" and "factorising." are one topic.
    static func key(_ topic: String) -> String {
        let lowered = topic.lowercased()
        let cleaned = lowered.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }

    /// Per-topic totals, newest attempts counting most (an attempt three weeks old counts half).
    static func summarize(_ attempts: [TopicAttempt], now: Date, halfLifeDays: Double = 21) -> [TopicStat] {
        var groups: [String: [TopicAttempt]] = [:]
        for a in attempts where a.possible > 0 {
            let k = key(a.topic)
            guard !k.isEmpty else { continue }
            groups[k, default: []].append(a)
        }
        return groups.map { k, items in
            let sorted = items.sorted { $0.date < $1.date }
            var weighted = 0.0, weight = 0.0
            for a in sorted {
                let ageDays = max(0, now.timeIntervalSince(a.date) / 86_400)
                let w = pow(0.5, ageDays / halfLifeDays)
                weighted += w * min(1, max(0, a.earned / a.possible))
                weight += w
            }
            let last = sorted.last!
            return TopicStat(key: k, topic: last.topic, subjectID: last.subjectID,
                             earned: sorted.reduce(0) { $0 + $1.earned }, possible: sorted.reduce(0) { $0 + $1.possible },
                             attempts: sorted.count, lastDate: last.date, score: weight > 0 ? weighted / weight : 0)
        }
        .sorted { $0.lastDate > $1.lastDate }
    }

    /// Topics worth practising: tried at least `minAttempts` times and below `threshold`, weakest first.
    static func weakest(_ stats: [TopicStat], minAttempts: Int = 1, threshold: Double = 0.75, limit: Int = 3) -> [TopicStat] {
        Array(stats.filter { $0.attempts >= minAttempts && $0.score < threshold }
            .sorted { ($0.score, -$0.attempts) < ($1.score, -$1.attempts) }
            .prefix(limit))
    }
}

// MARK: - Study streak

enum StudyStreak {
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Consecutive days with some study, ending today, or yesterday if today hasn't started yet
    /// (so a streak doesn't read as broken first thing in the morning).
    static func current(days: Set<String>, today: Date, calendar: Calendar = .current) -> Int {
        var day = calendar.startOfDay(for: today)
        if !days.contains(dayKey(day, calendar: calendar)) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }
        var count = 0
        while days.contains(dayKey(day, calendar: calendar)) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }

    /// Total seconds over the last `days` days including today.
    static func seconds(in log: [String: Double], lastDays days: Int, today: Date, calendar: Calendar = .current) -> Double {
        var total = 0.0
        var day = calendar.startOfDay(for: today)
        for _ in 0..<days {
            total += log[dayKey(day, calendar: calendar)] ?? 0
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return total
    }

    /// "2h 15m", "45m", "under a minute".
    static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "under a minute" }
        if minutes < 60 { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }
}
