import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct TutorPanel: View {
    @Bindable var model: EditorModel
    @EnvironmentObject var settings: AppSettings
    @StateObject private var dictation = SpeechDictation()
    @State private var draft = ""
    @State private var showFileImporter = false
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showSettings = false
    @State private var showScanner = false
    @FocusState private var composerFocused: Bool

    var tutor: TutorEngine { model.tutor }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !settings.isTutorConfigured {
                APIKeyPrompt()
                Divider()
            }
            attachmentsStrip
            messages
            suggestionsRow
            composer
        }
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.6))
        .background(.regularMaterial)
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.pdf, .image, .plainText, .text, .commaSeparatedText],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls { tutor.attachFile(url) }
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    tutor.attachImage(img)
                }
                photoItem = nil
            }
        }
        .onChange(of: dictation.transcript) { _, t in
            if dictation.isRecording { draft = t }
        }
        .onChange(of: model.pendingFocus != nil) { _, has in
            // The side panel stays mounted while closed (a board asks from its floating bar then).
            if has && model.showTutor { composerFocused = true }
        }
        .onChange(of: model.showTutor) { _, shown in
            // The side panel stays mounted when closed: don't leave the keyboard or the mic up for it.
            if !shown {
                composerFocused = false
                dictation.stop()
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .fullScreenCover(isPresented: $showScanner) {
            DocumentScanner(onFinish: { pages in
                showScanner = false
                if let url = DocumentScanner.pdf(from: pages, name: "Scanned pages") { tutor.attachFile(url) }
            }, onCancel: { showScanner = false })
            .ignoresSafeArea()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            TutorOrb(active: tutor.isBusy || tutor.isObserving, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Tutor").font(.system(size: 16, weight: .bold))
                Menu {
                    Section("Model") {
                        ForEach(ClaudeModelOption.all) { option in
                            Button {
                                settings.tutorModel = option.id
                            } label: {
                                if option.id == settings.tutorModel {
                                    Label("\(option.name) — \(option.subtitle)", systemImage: "checkmark")
                                } else {
                                    Text("\(option.name) — \(option.subtitle)")
                                }
                            }
                        }
                    }
                    Section("Thinking") {
                        ForEach(TutorEffort.allCases) { e in
                            Button {
                                settings.effort = e
                            } label: {
                                if e == settings.effort {
                                    Label("\(e.title) — \(e.subtitle)", systemImage: "checkmark")
                                } else {
                                    Text("\(e.title) — \(e.subtitle)")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text("\(settings.modelOption.name) · \(settings.effort.title)")
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                tutor.watching.toggle()
                model.flash(tutor.watching ? "Tutor is watching as you work" : "Tutor stopped watching")
            } label: {
                Image(systemName: tutor.watching ? "eye.fill" : "eye.slash")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tutor.watching ? Color(hex: settings.tutorInkHex) : .secondary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(tutor.watching ? Color(hex: settings.tutorInkHex).opacity(0.12) : Color.secondary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tutor.watching ? "Watching on" : "Watching off")
            Menu {
                Button { model.showPractice = true } label: { Label("Practice Questions…", systemImage: "pencil.and.list.clipboard") }
                Button { tutor.quick(.markAll) } label: { Label("Mark My Answers", systemImage: "checklist") }
                Divider()
                Button { showFileImporter = true } label: { Label("Attach File…", systemImage: "paperclip") }
                Button { showPhotoPicker = true } label: { Label("Attach Photo…", systemImage: "photo") }
                Divider()
                Button(role: .destructive) { tutor.newSession() } label: { Label("New Conversation", systemImage: "arrow.counterclockwise") }
                Button { showSettings = true } label: { Label("Tutor Settings", systemImage: "gearshape") }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 19)).frame(width: 34, height: 34)
            }
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { model.showTutor = false }
            } label: {
                Image(systemName: "sidebar.trailing").font(.system(size: 16)).frame(width: 34, height: 34)
            }
            .accessibilityLabel("Hide tutor")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Attachments

    @ViewBuilder
    private var attachmentsStrip: some View {
        let items = model.document.content.attachments
        if !items.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(items) { a in
                        HStack(spacing: 6) {
                            Image(systemName: a.kind == .pdf ? "doc.richtext" : (a.kind == .image ? "photo" : "doc.text"))
                            Text(a.name).lineLimit(1).frame(maxWidth: 150)
                            if tutor.uploading.contains(a.id) {
                                ProgressView().controlSize(.mini)
                            }
                            Button {
                                tutor.removeAttachment(a)
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.secondary.opacity(0.1)))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            Divider()
        }
    }

    // MARK: Messages

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if tutor.chat.isEmpty {
                        TutorEmptyState(model: model)
                    }
                    ForEach(tutor.chat) { item in
                        ChatRow(item: item, model: model).id(item.id)
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(14)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: tutor.chat.last?.text) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: tutor.chat.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    // MARK: Suggestions

    private var contextualActions: [TutorQuickAction] {
        var list: [TutorQuickAction] = []
        let hasOpenQuestions = model.document.content.elements.contains {
            if case .question(let q) = $0.kind { return q.status == .open }
            return false
        }
        if hasOpenQuestions { list.append(.markAll) }
        list += [.check, .hint, .explain, .practice, .graphIt, .solve]
        return list
    }

    private var suggestionsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(contextualActions) { action in
                    Button {
                        if action == .practice {
                            model.showPractice = true
                        } else {
                            tutor.quick(action, focus: model.pendingFocus)
                            model.pendingFocus = nil
                            model.canvas?.clearRegion()
                        }
                    } label: {
                        Label(action.title, systemImage: action.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .background(Capsule().strokeBorder(Color(hex: settings.tutorInkHex).opacity(0.35)))
                            .foregroundStyle(Color(hex: settings.tutorInkHex))
                    }
                    .buttonStyle(.plain)
                    .disabled(tutor.isBusy)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 6) {
            if let focus = model.pendingFocus {
                HStack(spacing: 6) {
                    Image(systemName: "viewfinder")
                    Text(model.document.isFreeform ? "About the selected area" : "About the selected area on page \(focus.page + 1)")
                    Spacer()
                    Button {
                        model.pendingFocus = nil
                        model.canvas?.clearRegion()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(hex: settings.tutorInkHex))
                .padding(.horizontal, 4)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button { showFileImporter = true } label: { Label("File (PDF, image, text)", systemImage: "doc") }
                    Button { showPhotoPicker = true } label: { Label("Photo", systemImage: "photo") }
                    if DocumentScanner.isAvailable {
                        Button { showScanner = true } label: { Label("Scan Document", systemImage: "doc.viewfinder") }
                    }
                } label: {
                    Image(systemName: "paperclip").font(.system(size: 17, weight: .medium)).frame(width: 34, height: 36)
                }
                .accessibilityLabel("Attach")

                TextField(placeholder, text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(uiColor: .systemBackground)))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.secondary.opacity(0.2)))
                    .onSubmit(sendDraft)

                if draft.trimmed.isEmpty && !tutor.isBusy {
                    Button {
                        if dictation.isRecording { dictation.stop(); sendDraft() } else { dictation.start(duringRecording: model.audio.isRecording) }
                    } label: {
                        Image(systemName: dictation.isRecording ? "waveform.circle.fill" : "mic.circle")
                            .font(.system(size: 28))
                            .foregroundStyle(dictation.isRecording ? Color.red : Color(hex: settings.tutorInkHex))
                            .symbolEffect(.pulse, isActive: dictation.isRecording)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(dictation.isRecording ? "Stop and send" : "Dictate")
                } else if tutor.isBusy {
                    Button { tutor.stop() } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 28)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop")
                } else {
                    Button(action: sendDraft) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 28))
                            .foregroundStyle(Color(hex: settings.tutorInkHex))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel("Send")
                }
            }
            if let err = dictation.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private var placeholder: String {
        if model.pendingFocus != nil { return "Ask about this…" }
        return tutor.chat.isEmpty ? "Ask anything, or write on the page…" : "Reply…"
    }

    private func sendDraft() {
        let text = draft.trimmed
        guard !text.isEmpty else { return }
        draft = ""
        tutor.send(text, focus: model.pendingFocus)
        model.pendingFocus = nil
        model.canvas?.clearRegion()
    }
}

// MARK: - Rows

struct ChatRow: View {
    let item: ChatItem
    @Bindable var model: EditorModel
    @EnvironmentObject var settings: AppSettings
    @State private var showThinking = false

    var body: some View {
        switch item.role {
        case .student:
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 4) {
                    if let label = item.contextLabel {
                        Label(label, systemImage: "viewfinder").font(.caption2).foregroundStyle(.secondary)
                    }
                    if !item.attachmentNames.isEmpty {
                        Label(item.attachmentNames.joined(separator: ", "), systemImage: "paperclip").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(item.text)
                        .font(.system(size: 15))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(hex: settings.tutorInkHex).opacity(0.14)))
                        .textSelection(.enabled)
                }
            }
        case .notice:
            HStack {
                Image(systemName: "info.circle")
                Text(item.text)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
        case .tutor, .observer:
            tutorRow
        }
    }

    private var tutorRow: some View {
        HStack(alignment: .top, spacing: 10) {
            TutorOrb(active: item.isStreaming, size: 24)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 8) {
                if item.role == .observer {
                    Label("While you were working", systemImage: "eye")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                if !item.thinking.trimmed.isEmpty {
                    DisclosureGroup(isExpanded: $showThinking) {
                        Text(item.thinking.trimmed)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    } label: {
                        Text(item.isStreaming && item.text.isEmpty ? "Thinking…" : "Thought process")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .tint(.secondary)
                }
                if !item.text.trimmed.isEmpty {
                    RichTextView(text: item.text, fontSize: 15)
                } else if item.isStreaming && item.thinking.isEmpty && item.actions.isEmpty {
                    TypingDots()
                }
                if !item.actions.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(item.actions) { action in
                            Button {
                                focus(action)
                            } label: {
                                Label(action.summary, systemImage: action.symbol)
                                    .font(.system(size: 12, weight: .medium))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(Capsule().fill(Color.secondary.opacity(0.1)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if let error = item.error {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(error).font(.system(size: 13)).foregroundStyle(.red)
                        if model.tutor.lastErrorRetryable && item.id == model.tutor.chat.last?.id {
                            Button("Try Again") { model.tutor.retry() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
                if item.canRevert && !item.isStreaming {
                    Button {
                        model.tutor.revert(item.id)
                    } label: {
                        Label("Undo tutor's changes", systemImage: "arrow.uturn.backward")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                } else if item.reverted {
                    Text("Changes undone").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func focus(_ action: ChatAction) {
        guard let canvas = model.canvas else { return }
        let rects = action.elementIDs.compactMap { model.document.element($0) }.map { model.document.docRect(for: $0) }
        if let first = rects.first {
            let union = rects.dropFirst().reduce(first) { $0.union($1) }
            canvas.focus(docRect: union, message: nil)
        } else if let page = action.page {
            canvas.scrollToPage(page)
        }
    }
}

struct TypingDots: View {
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle().fill(Color.secondary).frame(width: 6, height: 6)
                    .opacity(0.3 + 0.7 * abs(sin(phase + Double(i) * 0.6)))
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = .pi }
        }
    }
}

struct TutorEmptyState: View {
    @Bindable var model: EditorModel
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your tutor works right on the page.").font(.system(size: 17, weight: .semibold))
            VStack(alignment: .leading, spacing: 9) {
                tip("sparkles", "Tap **Ask**, then drag around any working to check it, get a hint, or have it explained.")
                tip("eye", "With **Watching** on, the tutor glances at your work when you pause — it circles slips and marks finished answers.")
                tip("pencil.and.list.clipboard", "Ask for **practice questions**: answer them in the boxes and they get marked.")
                tip("hand.tap", "**Double-tap** the page or Apple Pencil (or squeeze a Pencil Pro) to summon the tutor where you're writing.")
                tip("paperclip", "**Attach** worksheets, textbook pages or mark schemes as context.")
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(hex: settings.tutorInkHex).opacity(0.06)))
    }

    private func tip(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Color(hex: settings.tutorInkHex)).frame(width: 20)
            Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct APIKeyPrompt: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Connect your tutor", systemImage: "key.fill").font(.system(size: 14, weight: .semibold))
            Text("Enter your tutor server's URL and access token, or paste your own Anthropic API key.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            ConnectionForm(compact: true)
        }
        .padding(14)
    }
}

// MARK: - Rich text (math-aware) for chat

/// Renders chat text with `$...$` math and `**bold**` using the same engine as the canvas.
struct RichTextView: UIViewRepresentable {
    let text: String
    var fontSize: CGFloat = 15

    func makeUIView(context: Context) -> RichTextUIView {
        let v = RichTextUIView()
        v.backgroundColor = .clear
        v.isOpaque = false
        v.contentMode = .redraw
        return v
    }

    func updateUIView(_ v: RichTextUIView, context: Context) {
        if v.text != text || v.fontSize != fontSize {
            v.text = text
            v.fontSize = fontSize
            v.invalidateIntrinsicContentSize()
            v.setNeedsDisplay()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: RichTextUIView, context: Context) -> CGSize? {
        // nil or infinite proposals (ideal size) get a sensible default width.
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 300
        let l = uiView.layout(width: width)
        return CGSize(width: width, height: l.size.height + 2)
    }
}

final class RichTextUIView: UIView {
    var text = ""
    var fontSize: CGFloat = 15
    private var cache: (String, CGFloat, RichTextLayout)?

    var font: UIFont { UIFont.systemFont(ofSize: fontSize) }

    func layout(width: CGFloat) -> RichTextLayout {
        if let c = cache, c.0 == text, abs(c.1 - width) < 0.5 { return c.2 }
        let l = RichTextLayout(text: text, font: font, maxWidth: width, rich: true, hideUnclosedMath: true)
        cache = (text, width, l)
        return l
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        layout(width: bounds.width).draw(in: ctx, origin: CGPoint(x: 0, y: 1), color: .label)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        setNeedsDisplay()
    }
}

/// Wrapping horizontal layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            width = max(width, x - spacing)
        }
        return CGSize(width: min(width, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
