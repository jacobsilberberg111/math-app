import SwiftUI

/// Reviewing due flashcards (tap to flip, then say how well you knew it) and browsing the deck.
struct FlashcardsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var settings: AppSettings
    private var store: StudyStore { StudyStore.shared }

    private enum Mode: String, CaseIterable, Identifiable {
        case review = "Review", deck = "All Cards"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .review
    @State private var queue: [Flashcard] = []
    @State private var reviewed = 0
    @State private var flipped = false
    @State private var search = ""
    @State private var sessionStart = Date()

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .review: review
                case .deck: deck
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .onAppear {
            queue = store.dueCards()
            sessionStart = Date()
        }
        .onDisappear { store.logStudy(from: sessionStart, to: Date()) }
    }

    // MARK: Review

    @ViewBuilder
    private var review: some View {
        if let card = queue.first {
            VStack(spacing: 26) {
                Text("\(reviewed + 1) of \(reviewed + queue.count)")
                    .font(.subheadline.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.top, 20)
                cardView(card)
                    .onTapGesture { withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) { flipped.toggle() } }
                if flipped {
                    HStack(spacing: 12) {
                        ForEach(RecallGrade.allCases) { g in
                            Button {
                                grade(card, g)
                            } label: {
                                VStack(spacing: 3) {
                                    Text(g.title).font(.headline)
                                    Text(card.review.preview(g, now: Date())).font(.caption.monospacedDigit()).opacity(0.8)
                                }
                                .frame(width: 104, height: 58)
                                .foregroundStyle(.white)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(color(g).gradient))
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    Text("Tap the card to see the answer")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(height: 58)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
        } else {
            ContentUnavailableView {
                Label(reviewed > 0 ? "All caught up" : "Nothing due", systemImage: reviewed > 0 ? "checkmark.seal.fill" : "rectangle.on.rectangle.angled")
            } description: {
                Text(doneMessage)
            } actions: {
                if !store.cards.isEmpty {
                    Button("Browse All Cards") { mode = .deck }
                }
            }
        }
    }

    private var doneMessage: String {
        var s = reviewed > 0 ? "You reviewed \(reviewed) card\(reviewed == 1 ? "" : "s"). " : ""
        if let next = store.cards.map(\.review.due).filter({ $0 > Date() }).min() {
            s += "The next one is due in \(ReviewState.shortInterval(next.timeIntervalSinceNow))."
        } else if store.cards.isEmpty {
            s += "Ask your tutor for flashcards from any note: select some working with Ask, then tap Flashcards."
        }
        return s
    }

    private func cardView(_ card: Flashcard) -> some View {
        ZStack {
            face(text: card.front, label: "Question", card: card)
                .opacity(flipped ? 0 : 1)
            face(text: card.back, label: "Answer", card: card)
                .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                .opacity(flipped ? 1 : 0)
        }
        .rotation3DEffect(.degrees(flipped ? 180 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
        .frame(maxWidth: 620, minHeight: 320)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Double-tap to flip")
    }

    private func face(text: String, label: String, card: Flashcard) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(label.uppercased()).font(.caption.weight(.bold)).foregroundStyle(Color(hex: settings.tutorInkHex))
                Spacer()
                if let topic = card.topic { Text(topic).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
            RichTextView(text: text, fontSize: 24)
                .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            if let title = card.noteTitle {
                Label(title, systemImage: "doc.text").font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, minHeight: 320)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
        .shadow(color: .black.opacity(0.1), radius: 16, y: 6)
    }

    private func color(_ g: RecallGrade) -> Color {
        switch g {
        case .again: return Color(hex: "#E5484D")
        case .hard: return Color(hex: "#F76B15")
        case .good: return Color(hex: "#30A46C")
        case .easy: return Color(hex: "#0090FF")
        }
    }

    private func grade(_ card: Flashcard, _ g: RecallGrade) {
        store.grade(card, g)
        Haptics.tap()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            queue.removeFirst()
            // Forgotten cards come back at the end of this session too.
            if g == .again, let updated = store.cards.first(where: { $0.id == card.id }) { queue.append(updated) }
            reviewed += 1
            flipped = false
        }
    }

    // MARK: Deck

    private var deck: some View {
        let q = search.trimmed
        let cards = store.cards
            .filter { q.isEmpty || $0.front.localizedCaseInsensitiveContains(q) || $0.back.localizedCaseInsensitiveContains(q) || ($0.topic?.localizedCaseInsensitiveContains(q) ?? false) }
            .sorted { $0.createdAt > $1.createdAt }
        return List {
            if cards.isEmpty {
                Text(store.cards.isEmpty ? "No flashcards yet. Ask your tutor to make some from your notes." : "No cards match “\(q)”.")
                    .foregroundStyle(.secondary)
            }
            ForEach(cards) { card in
                VStack(alignment: .leading, spacing: 4) {
                    RichTextView(text: card.front, fontSize: 16)
                    RichTextView(text: card.back, fontSize: 14)
                        .opacity(0.7)
                    HStack(spacing: 6) {
                        if let topic = card.topic { Text(topic) }
                        Text(card.review.isDue(at: Date()) ? "Due now" : "Due in \(ReviewState.shortInterval(card.review.due.timeIntervalSinceNow))")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .swipeActions {
                    Button(role: .destructive) { store.delete(card) } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
        .searchable(text: $search, prompt: "Search cards")
    }
}
