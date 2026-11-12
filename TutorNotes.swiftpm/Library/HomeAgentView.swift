import SwiftUI

/// The study agent's card on Home: quick questions, the last reply, and the full chat.
struct HomeAgentCard: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(LibraryStore.self) private var library
    var startNote: (UUID?, String, String, String) -> Void
    @State private var showChat = false
    private let agent = HomeAgent.shared

    static let suggestions = [
        "What's due this week?",
        "Anything new from my teachers?",
        "How am I going in my subjects?",
        "Plan my study for this week",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                TutorOrb(active: agent.isBusy, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Study agent").font(.headline)
                    Text(statusLine).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(agent.hasConversation ? "Open chat" : "Chat") { showChat = true }
                    .buttonStyle(.bordered)
            }
            if let reply = agent.lastReply {
                Text(RichTextParser.plainText(reply))
                    .font(.subheadline)
                    .lineLimit(3)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { showChat = true }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(HomeAgentCard.suggestions, id: \.self) { s in
                        Button {
                            showChat = true
                            agent.send(s)
                        } label: {
                            Text(s).font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(Color(hex: settings.tutorInkHex).opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        .disabled(agent.isBusy)
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
        .sheet(isPresented: $showChat) {
            HomeAgentChat()
                .environmentObject(settings)
        }
        .onAppear { wire() }
    }

    private var statusLine: String {
        if agent.isBusy { return agent.statusText ?? "Working…" }
        switch agent.canvasState {
        case .connected(let host): return "Canvas connected · \(host)"
        case .notSetUp: return "Canvas isn't set up yet · see Settings → Canvas"
        case .unavailable: return "Canvas unavailable · see Settings → Canvas"
        case .unknown: return "Plans with you across your subjects"
        }
    }

    private static var sentLaunchMessage = false

    private func wire() {
        agent.library = library
        agent.startNote = startNote
        agent.willNavigate = { showChat = false }
        agent.refreshCanvasStatus()
        // -uitest-agent-message "…": open the chat and send a message, for testing.
        let args = ProcessInfo.processInfo.arguments
        if !HomeAgentCard.sentLaunchMessage, let i = args.firstIndex(of: "-uitest-agent-message"), i + 1 < args.count {
            HomeAgentCard.sentLaunchMessage = true
            showChat = true
            agent.send(args[i + 1])
        }
    }
}

/// The full conversation with the study agent.
struct HomeAgentChat: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    private let agent = HomeAgent.shared
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if agent.chat.isEmpty { intro }
                            ForEach(agent.chat) { item in
                                HomeAgentRow(item: item, retry: { agent.retry() }, canRetry: agent.lastErrorRetryable && item.id == agent.chat.last?.id)
                                    .id(item.id)
                            }
                            if agent.isBusy, let status = agent.statusText {
                                Label(status, systemImage: "sparkles")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .id("status")
                            }
                        }
                        .frame(width: max(0, geo.size.width - 32), alignment: .leading)
                        .padding(16)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: agent.chat.last?.text) { _, _ in scrollToEnd(proxy) }
                    .onChange(of: agent.chat.count) { _, _ in scrollToEnd(proxy) }
                    .onAppear { scrollToEnd(proxy) }
                }
                }
                Divider()
                composer
            }
            .navigationTitle("Study agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { agent.newChat() } label: { Label("New Chat", systemImage: "square.and.pencil") }
                        .disabled(agent.chat.isEmpty)
                }
            }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard let last = agent.chat.last?.id else { return }
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("I can look across your subjects and your school's Canvas: what's due, announcements, your marks and feedback, task sheets and rubrics. I'll brief your note tutors and set up notes so you can get started.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if case .connected = agent.canvasState {} else {
                Label("Set up Canvas (Settings → Canvas) so I can read your courses.", systemImage: "link")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            ForEach(HomeAgentCard.suggestions + ["Help me get started on my next assessment"], id: \.self) { s in
                Button { agent.send(s) } label: {
                    Text(s).font(.subheadline)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Capsule().fill(Color(hex: settings.tutorInkHex).opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 8)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask about your study, Canvas, what's due…", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($focused)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 18).fill(Color(uiColor: .secondarySystemBackground)))
                .onSubmit(send)
            if agent.isBusy {
                Button { agent.stop() } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 30))
                }
                .accessibilityLabel("Stop")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                }
                .disabled(draft.trimmed.isEmpty)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func send() {
        let t = draft
        draft = ""
        agent.send(t)
    }
}

private struct HomeAgentRow: View {
    let item: ChatItem
    var retry: () -> Void
    var canRetry: Bool
    @EnvironmentObject var settings: AppSettings
    @State private var showThinking = false

    var body: some View {
        switch item.role {
        case .student:
            HStack {
                Spacer(minLength: 60)
                Text(item.text)
                    .font(.system(size: 15))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(hex: settings.tutorInkHex).opacity(0.14)))
                    .textSelection(.enabled)
            }
        case .notice, .observer:
            Label(item.text, systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        case .tutor:
            HStack(alignment: .top, spacing: 10) {
                TutorOrb(active: item.isStreaming, size: 24).padding(.top, 2)
                VStack(alignment: .leading, spacing: 8) {
                    if !item.thinking.trimmed.isEmpty {
                        DisclosureGroup(isExpanded: $showThinking) {
                            Text(item.thinking.trimmed).font(.system(size: 12)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } label: {
                            Text(item.isStreaming && item.text.isEmpty ? "Thinking…" : "Thought process")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .tint(.secondary)
                    }
                    if !item.actions.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(item.actions) { a in
                                Label(a.summary, systemImage: a.symbol)
                                    .font(.system(size: 12, weight: .medium))
                                    .padding(.horizontal, 9).padding(.vertical, 5)
                                    .background(Capsule().fill(Color.secondary.opacity(0.1)))
                            }
                        }
                    }
                    if !item.text.trimmed.isEmpty {
                        RichTextView(text: item.text, fontSize: 15)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if item.isStreaming && item.actions.isEmpty {
                        TypingDots()
                    }
                    if let error = item.error {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(error).font(.system(size: 13)).foregroundStyle(.red)
                            if canRetry {
                                Button("Try Again", action: retry).buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}
