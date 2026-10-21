import SwiftUI

/// On a freeform board the tutor lives on the canvas: a floating bar to type or talk to it, with
/// its latest reply just above, so you can keep working without opening the side panel. Circle
/// some working with Ask first and the question is about that.
struct BoardTutorBar: View {
    @Bindable var model: EditorModel
    @EnvironmentObject var settings: AppSettings
    @StateObject private var dictation = SpeechDictation()
    @State private var draft = ""
    @State private var dismissedReplyID: UUID?
    @State private var collapsed = false
    /// Bumped to bounce the mic when the student circles something to ask about.
    @State private var invite = 0
    @FocusState private var focused: Bool

    private var tutor: TutorEngine { model.tutor }
    private var tint: Color { Color(hex: settings.tutorInkHex) }

    /// The tutor's most recent message, unless it was waved away.
    private var latestReply: ChatItem? {
        guard let last = tutor.chat.last, last.role != .student, last.id != dismissedReplyID else { return nil }
        if last.text.isEmpty && !last.isStreaming && last.error == nil { return nil }
        return last
    }

    var body: some View {
        Group {
            if collapsed {
                HStack {
                    Spacer()
                    Button {
                        collapsed = false
                    } label: {
                        TutorOrb(active: tutor.isBusy || tutor.isObserving, size: 30)
                            .frame(width: 54, height: 54)
                            .background(.regularMaterial, in: Circle())
                            .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Ask your tutor")
                }
            } else {
                VStack(spacing: 10) {
                    if let reply = latestReply {
                        replyCard(reply)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    bar
                }
                .frame(maxWidth: 640)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: latestReply?.id)
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: collapsed)
        .onChange(of: dictation.transcript) { _, t in
            if dictation.isRecording { draft = t }
        }
        .onChange(of: model.focusBoardBar) { _, want in
            guard want else { return }
            // Open the bar and point at the mic rather than raising the keyboard over the work:
            // with a Pencil in hand, talking or tapping the field is the student's call.
            collapsed = false
            invite += 1
            model.focusBoardBar = false
        }
        .onChange(of: tutor.chat.count) { _, _ in
            // A new reply brings the card back even if the last one was dismissed.
            if tutor.chat.last?.role != .student { dismissedReplyID = nil }
        }
        .onDisappear { dictation.stop() }
    }

    // MARK: Reply

    private func replyCard(_ item: ChatItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TutorOrb(active: item.isStreaming, size: 18)
                Text(item.role == .observer ? "While you were working" : (item.role == .notice ? "Tutor" : "Your tutor"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open chat") {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { model.showTutor = true }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                Button {
                    dismissedReplyID = item.id
                } label: {
                    Image(systemName: "xmark").font(.caption.weight(.bold)).frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss")
            }
            if let error = item.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.red)
            } else if item.text.isEmpty {
                HStack(spacing: 8) {
                    TypingDots()
                    Text(tutor.statusText ?? "Thinking…").font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                // Chat replies are meant to be a sentence or two; anything longer is in the chat.
                CappedHeight(limit: 132) {
                    RichTextView(text: item.text, fontSize: 15)
                }
                .clipped()
            }
            if !item.actions.isEmpty {
                Text(item.actions.map(\.summary).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.black.opacity(0.05)))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 4)
    }

    // MARK: Bar

    private var bar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.pendingFocus != nil {
                HStack(spacing: 6) {
                    Image(systemName: "viewfinder")
                    Text("About the area you selected")
                    Button {
                        model.pendingFocus = nil
                        model.canvas?.clearRegion()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(tint)
                .padding(.leading, 52)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button(action: toggleDictation) {
                    Image(systemName: dictation.isRecording ? "waveform.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(dictation.isRecording ? Color.red : tint)
                        .symbolEffect(.pulse, isActive: dictation.isRecording)
                        .symbolEffect(.bounce, value: invite)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(dictation.isRecording ? "Stop and send" : "Talk to your tutor")

                TextField(placeholder, text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($focused)
                    .font(.system(size: 16))
                    .padding(.vertical, 7)
                    .onSubmit(send)

                if tutor.isBusy {
                    Button { tutor.stop() } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 30)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop")
                } else if !draft.trimmed.isEmpty {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 30)).foregroundStyle(tint)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel("Send")
                } else {
                    Button {
                        focused = false
                        collapsed = true
                    } label: {
                        Image(systemName: "chevron.down.circle").font(.system(size: 26)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Hide")
                }
            }
            if let err = dictation.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red).padding(.leading, 52)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.black.opacity(0.06)))
        .shadow(color: .black.opacity(0.14), radius: 14, y: 4)
    }

    private var placeholder: String {
        if dictation.isRecording { return "Listening…" }
        if model.pendingFocus != nil { return "Ask about this…" }
        return "Ask your tutor, or circle something with Ask…"
    }

    private func toggleDictation() {
        if dictation.isRecording {
            dictation.stop()
            send()
        } else {
            dictation.start(duringRecording: model.audio.isRecording)
        }
    }

    private func send() {
        let text = draft.trimmed
        guard !text.isEmpty else { return }
        draft = ""
        dismissedReplyID = nil
        tutor.send(text, focus: model.pendingFocus)
        model.pendingFocus = nil
        model.canvas?.clearRegion()
    }
}

/// Its content's natural height, up to `limit` (a plain `.frame(maxHeight:)` would stretch short
/// content to the limit).
struct CappedHeight: Layout {
    var limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? size.width, height: min(size.height, limit))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}
