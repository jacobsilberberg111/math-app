import SwiftUI

/// The landing screen: start something new, jump back into what you were doing, and see what's
/// waiting (unanswered practice questions).
struct HomeView: View {
    @Environment(LibraryStore.self) private var library
    @EnvironmentObject var settings: AppSettings
    var open: (NoteMeta) -> Void
    var newNotebook: () -> Void
    var newBoard: () -> Void
    var askTutor: () -> Void
    var importPDF: () -> Void
    var pastPaper: () -> Void
    var scan: (() -> Void)?
    var reviewCards: () -> Void
    var practiseWeakSpots: ([TopicStat]) -> Void
    var showAll: () -> Void
    var showSubject: (UUID) -> Void

    private var study: StudyStore { StudyStore.shared }

    static var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private var recents: [NoteMeta] { library.recentNotes }
    private var waiting: [NoteMeta] { Array(library.notesWithOpenQuestions.prefix(4)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                summary
                actions
                studyRow
                if let latest = recents.first {
                    section("Jump back in") { ContinueCard(meta: latest, subject: library.subject(latest.subjectID)) { open(latest) } }
                }
                if recents.count > 1 {
                    section("Recent", trailing: AnyView(Button("See All", action: showAll).font(.subheadline.weight(.medium)))) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 22) {
                                ForEach(recents.dropFirst().prefix(12)) { meta in
                                    NoteCard(meta: meta, subject: library.subject(meta.subjectID))
                                        .frame(width: 176)
                                        .onTapGesture { open(meta) }
                                }
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 2)
                        }
                    }
                }
                topicsSection
                if !waiting.isEmpty {
                    section("Waiting for you") {
                        VStack(spacing: 0) {
                            ForEach(Array(waiting.enumerated()), id: \.element.id) { i, meta in
                                if i > 0 { Divider().padding(.leading, 56) }
                                WaitingRow(meta: meta, subject: library.subject(meta.subjectID)) { open(meta) }
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
                    }
                }
                if !library.subjects.isEmpty {
                    section("Subjects") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 14)], spacing: 14) {
                            ForEach(library.subjects) { subject in
                                SubjectTile(subject: subject, count: library.notes.filter { $0.subjectID == subject.id }.count) {
                                    showSubject(subject.id)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 6)
            .padding(.bottom, 40)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    // MARK: Pieces

    private var summary: some View {
        let questions = library.notes.reduce(0) { $0 + ($1.openQuestions ?? 0) }
        var parts = [Date().formatted(.dateTime.weekday(.wide).month(.wide).day())]
        let streak = study.streak
        if streak > 1 { parts.append("\(streak)-day streak") }
        let week = study.secondsThisWeek
        if week >= 60 { parts.append("\(StudyStreak.duration(week)) this week") }
        if questions > 0 { parts.append("\(questions) question\(questions == 1 ? "" : "s") to finish") }
        return Text(parts.joined(separator: " · "))
            .font(.title3)
            .foregroundStyle(.secondary)
    }

    private var actions: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 14)], spacing: 14) {
            ActionTile(symbol: "book.pages", tint: Color(hex: "#5B5BD6"), title: "New Notebook", detail: "Pages with lines or grid", action: newNotebook)
            ActionTile(symbol: "scribble.variable", tint: Color(hex: "#12A594"), title: "New Board", detail: "A freeform canvas that grows", action: newBoard)
            ActionTile(symbol: "sparkles", tint: Color(hex: settings.tutorInkHex), title: "Ask the Tutor", detail: "Start a board and talk it through", action: askTutor)
            ActionTile(symbol: "doc.text.magnifyingglass", tint: Color(hex: "#E5484D"), title: "Past Paper", detail: "Timed practice, marked to the scheme", action: pastPaper)
            if let scan {
                ActionTile(symbol: "doc.viewfinder", tint: Color(hex: "#0090FF"), title: "Scan", detail: "Worksheets and textbook pages", action: scan)
            }
            ActionTile(symbol: "doc.badge.arrow.up", tint: Color(hex: "#F76B15"), title: "Import PDF", detail: "Annotate a worksheet", action: importPDF)
        }
    }

    /// Flashcards due today.
    @ViewBuilder
    private var studyRow: some View {
        let due = study.dueCards().count
        let total = study.cards.count
        if total > 0 {
            Button(action: reviewCards) {
                HStack(spacing: 14) {
                    Image(systemName: "rectangle.on.rectangle.angled")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(hex: "#8E4EC6").gradient))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(due > 0 ? "\(due) flashcard\(due == 1 ? "" : "s") to review" : "Flashcards: all caught up")
                            .font(.headline).foregroundStyle(.primary)
                        Text(due > 0 ? "A few minutes now keeps them from slipping." : "\(total) card\(total == 1 ? "" : "s") in your deck")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(due > 0 ? "Review" : "Browse")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(due > 0 ? Color.white : Color.accentColor)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(due > 0 ? Color.accentColor : Color.accentColor.opacity(0.12)))
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(PressableStyle())
        }
    }

    /// How marked work is going, by topic: what to practise, and what's going well.
    @ViewBuilder
    private var topicsSection: some View {
        let stats = study.topicStats()
        let weak = TopicStats.weakest(stats)
        let strong = Array(stats.filter { $0.score >= 0.75 }.sorted { $0.score > $1.score }.prefix(3))
        if !stats.isEmpty {
            section("Your topics") {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(weak + strong) { t in
                        TopicBar(stat: t, subject: library.subject(t.subjectID))
                    }
                    if !weak.isEmpty {
                        Button {
                            practiseWeakSpots(weak)
                        } label: {
                            Label("Practise my weak spots", systemImage: "target")
                                .font(.headline)
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 2)
                    } else {
                        Text("Nothing below 75% lately. Nice work.").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
            }
        }
    }

    private func section<Content: View>(_ title: String, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.title2.weight(.bold))
                Spacer()
                if let trailing { trailing }
            }
            content()
        }
    }
}

// MARK: - Tiles and cards

private struct TopicBar: View {
    let stat: TopicStat
    let subject: Subject?

    private var color: Color {
        stat.score >= 0.75 ? Color(hex: "#30A46C") : (stat.score >= 0.5 ? Color(hex: "#F76B15") : Color(hex: "#E5484D"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(stat.topic.prefix(1).uppercased() + stat.topic.dropFirst()).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let subject {
                    Text(subject.name).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int((stat.score * 100).rounded()))%").font(.subheadline.weight(.bold).monospacedDigit()).foregroundStyle(color)
                Text("· \(stat.attempts) marked").font(.caption).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(color.gradient).frame(width: max(6, geo.size.width * stat.score))
                }
            }
            .frame(height: 7)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ActionTile: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.gradient))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressableStyle())
    }
}

/// The note you were last in, big, with a one-tap way back in.
private struct ContinueCard: View {
    let meta: NoteMeta
    let subject: Subject?
    let action: () -> Void
    @Environment(LibraryStore.self) private var library

    var body: some View {
        let _ = library.thumbnailVersion
        Button(action: action) {
            HStack(alignment: .top, spacing: 22) {
                Group {
                    if let img = library.thumbnail(for: meta) {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else {
                        ZStack {
                            Color.white
                            PaperSwatch(style: meta.paper ?? .standard).opacity(0.8)
                        }
                    }
                }
                .frame(width: 170, height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.black.opacity(0.06)))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 4)

                VStack(alignment: .leading, spacing: 10) {
                    if let subject {
                        HStack(spacing: 6) {
                            Circle().fill(Color(hex: subject.colorHex)).frame(width: 8, height: 8)
                            Text(subject.name)
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    }
                    Text(meta.title)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                    Text(detailLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        if (meta.openQuestions ?? 0) > 0 {
                            chip("questionmark.square", "\(meta.openQuestions ?? 0) to answer")
                        }
                        if meta.hasTutorSession { chip("sparkles", "Tutor") }
                        if meta.hasAudio { chip("waveform", "Audio") }
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 6) {
                        Text("Continue")
                        Image(systemName: "arrow.right")
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.accentColor))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(PressableStyle())
    }

    private var detailLine: String {
        let when = meta.lastOpenedAt.map { "Opened \($0.shortRelative)" } ?? "Edited \(meta.modifiedAt.shortRelative)"
        let size = meta.isFreeform ? "Freeform board" : "\(meta.pageCount) page\(meta.pageCount == 1 ? "" : "s")"
        return "\(when) · \(size)"
    }

    private func chip(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
            .foregroundStyle(.secondary)
    }
}

private struct WaitingRow: View {
    let meta: NoteMeta
    let subject: Subject?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "questionmark.square.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color(hex: subject?.colorHex ?? "#5B5BD6"))
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(meta.title).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                    let n = meta.openQuestions ?? 0
                    Text("\(n) question\(n == 1 ? "" : "s") waiting for your answer")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SubjectTile: View {
    let subject: Subject
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(hex: subject.colorHex).gradient)
                    .frame(width: 22, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(subject.name).font(.headline).foregroundStyle(.primary).lineLimit(1)
                    Text("\(count) note\(count == 1 ? "" : "s")").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressableStyle())
    }
}

/// Cards dip slightly while pressed.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}
