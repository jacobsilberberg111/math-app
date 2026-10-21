import SwiftUI

/// The strip under the toolbar while working through a past paper: the clock, the question
/// you're on, your score so far, and buttons to mark it or finish.
struct PaperBar: View {
    @Bindable var model: EditorModel
    @EnvironmentObject var settings: AppSettings
    @State private var confirmFinish = false

    private var tutor: TutorEngine { model.tutor }

    var body: some View {
        if let paper = model.document.content.paper {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                content(paper, now: context.date)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color(uiColor: .secondarySystemBackground))
            .overlay(alignment: .bottom) { Divider() }
            .confirmationDialog("Finish this paper?", isPresented: $confirmFinish, titleVisibility: .visible) {
                Button("Finish and Mark Everything") { model.finishPaper() }
                Button("Keep Working", role: .cancel) {}
            } message: {
                Text("The clock stops and your tutor marks every question against the mark scheme, then writes up your results.")
            }
        }
    }

    private func content(_ paper: PaperSession, now: Date) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(Color(hex: settings.tutorInkHex))
            clock(paper, now: now)
            Divider().frame(height: 22)
            questionStatus(paper)
            Spacer(minLength: 8)
            if paper.markedCount > 0 {
                Text("\(paper.awardedMarks)/\(paper.markedMarks)")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.green.opacity(0.15)))
                    .accessibilityLabel("Score so far \(paper.awardedMarks) out of \(paper.markedMarks)")
            }
            Button { model.showPaperQuestions = true } label: {
                Image(systemName: "list.bullet").frame(width: 30, height: 30)
            }
            .accessibilityLabel("Questions")
            if paper.finishedAt == nil {
                Button("Finish") { confirmFinish = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(tutor.isBusy || !paper.outlined)
            } else if !paper.isComplete {
                // Marking stopped part-way (a very long paper, or an error): carry on from here.
                Button("Mark Remaining") { model.finishPaper() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(tutor.isBusy)
            } else if let page = paper.resultsPage {
                Button("Results") { model.canvas?.scrollToPage(page) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .font(.subheadline)
        .onChange(of: overTime(paper, now: now)) { _, over in
            if over {
                Haptics.warning()
                model.flash("Time's up")
            }
        }
    }

    @ViewBuilder
    private func clock(_ paper: PaperSession, now: Date) -> some View {
        if paper.startedAt == nil, let limit = paper.timeLimitMinutes {
            Button {
                model.startPaper()
            } label: {
                Label("Start · \(PaperBar.minutes(limit))", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!paper.outlined && settings.isTutorConfigured)
        } else if paper.finishedAt != nil {
            Text("Finished in \(PaperBar.clock(paper.elapsed(at: now)))")
                .foregroundStyle(.secondary)
        } else if let remaining = paper.remaining(at: now) {
            Text(remaining >= 0 ? "\(PaperBar.clock(remaining)) left" : "Over by \(PaperBar.clock(-remaining))")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(remaining < 300 ? Color.red : Color.primary)
        } else {
            Text(PaperBar.clock(paper.elapsed(at: now, openSince: model.paperOpenSince)))
                .font(.subheadline.weight(.semibold).monospacedDigit())
        }
    }

    @ViewBuilder
    private func questionStatus(_ paper: PaperSession) -> some View {
        if !paper.outlined {
            if !settings.isTutorConfigured {
                Text("Connect your tutor to map and mark this paper").foregroundStyle(.secondary).lineLimit(1)
            } else if tutor.isBusy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading the paper…").foregroundStyle(.secondary)
                }
            } else {
                Button("Map the questions") { tutor.outlinePaper() }
            }
        } else if let q = currentQuestion(paper) {
            HStack(spacing: 8) {
                Text(q.label).font(.subheadline.weight(.bold))
                Text("\(q.marks) mark\(q.marks == 1 ? "" : "s")").foregroundStyle(.secondary)
                if let a = q.awarded {
                    Text("\(a)/\(q.marks)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(a == q.marks ? Color.green : (a == 0 ? Color.red : Color.orange))
                } else {
                    Button("Mark \(q.label)") {
                        model.showPanelIfNoKey()
                        tutor.markPaperQuestion(q)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(tutor.isBusy)
                }
            }
            .lineLimit(1)
        }
    }

    /// The question at the middle of the screen.
    private func currentQuestion(_ paper: PaperSession) -> PaperQuestion? {
        guard let canvas = model.canvas else { return paper.questions.first }
        let r = canvas.visibleDocRect
        let (page, point) = model.document.pagePoint(fromDoc: CGPoint(x: r.midX, y: r.minY + r.height * 0.4))
        return paper.question(page: page, y: point.y)
    }

    private func overTime(_ paper: PaperSession, now: Date) -> Bool {
        guard paper.finishedAt == nil, let remaining = paper.remaining(at: now) else { return false }
        return remaining <= 0
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func minutes(_ m: Int) -> String {
        m >= 60 ? (m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m") : "\(m) min"
    }
}

/// Every question on the paper with its marks; tap one to jump to it.
struct PaperQuestionsSheet: View {
    @Bindable var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let paper = model.document.content.paper, paper.outlined {
                    List {
                        Section {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(paper.questions.count) questions · \(paper.totalMarks) marks").font(.headline)
                                    Text(paper.timeLimitMinutes.map { "Timed: \(PaperBar.minutes($0))" } ?? "Untimed")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if paper.markedCount > 0 {
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text("\(paper.awardedMarks)/\(paper.markedMarks)").font(.title3.weight(.bold).monospacedDigit())
                                        Text("\(paper.markedCount) marked").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        Section("Questions") {
                            ForEach(paper.questions) { q in
                                Button {
                                    jump(to: q)
                                } label: {
                                    HStack(spacing: 12) {
                                        Text(q.label).font(.body.weight(.semibold)).frame(minWidth: 56, alignment: .leading)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(q.topic ?? "Page \(q.page + 1)").foregroundStyle(.primary).lineLimit(1)
                                            if let f = q.feedback {
                                                Text(f).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                            } else {
                                                Text("Page \(q.page + 1)").font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                        score(q)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } else {
                    ContentUnavailableView {
                        Label("Not mapped yet", systemImage: "list.bullet.rectangle")
                    } description: {
                        Text("Your tutor reads the paper and lists its questions so you can jump between them and get each one marked.")
                    } actions: {
                        Button("Map the Questions") {
                            model.tutor.outlinePaper()
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.tutor.isBusy)
                    }
                }
            }
            .navigationTitle("Paper")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            model.tutor.outlinePaper(again: true)
                            dismiss()
                        } label: { Label("Map Questions Again", systemImage: "arrow.clockwise") }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .disabled(model.tutor.isBusy)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func score(_ q: PaperQuestion) -> some View {
        if let a = q.awarded {
            Text("\(a)/\(q.marks)")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(a == q.marks ? Color.green : (a == 0 ? Color.red : Color.orange))
        } else {
            Text("–/\(q.marks)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func jump(to q: PaperQuestion) {
        let doc = model.document
        let rect = CGRect(x: 0, y: q.top, width: doc.pageSize.width, height: min(320, max(40, q.bottom - q.top)))
        model.canvas?.scrollToReveal(doc.docRect(rect, page: q.page))
        dismiss()
    }
}
