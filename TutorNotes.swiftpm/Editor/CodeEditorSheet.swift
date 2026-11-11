import SwiftUI
import UIKit

/// Editing a code block: title, language, a code editor (line numbers, live highlighting,
/// auto-indent, Tab = 4 spaces, a key bar for symbols), the program input, Run (⌘R) with its
/// output, and Ask Tutor. Done saves everything as one undoable change; Cancel discards it.
struct CodeEditorSheet: View {
    @Bindable var model: EditorModel
    let elementID: String
    @Environment(\.dismiss) private var dismiss

    /// The block as it was when the sheet opened (nil if it's gone).
    @State private var original: CodeContent?
    @State private var title: String
    @State private var language: CodeLanguage
    @State private var code: String
    @State private var stdin: String
    /// The latest run started from this sheet, and the program it ran.
    @State private var sheetRun: SheetRun?
    @State private var running = false

    private struct SheetRun {
        var result: CodeRunResult
        var program: CodeContent
        var date: Date
    }

    @MainActor
    init(model: EditorModel, elementID: String) {
        _model = Bindable(model)
        self.elementID = elementID
        var content: CodeContent?
        if let e = model.document.element(elementID), case .code(let c) = e.kind { content = c }
        _original = State(initialValue: content)
        _title = State(initialValue: content?.title ?? "")
        _language = State(initialValue: content?.lang ?? .python)
        _code = State(initialValue: CodeText.lines(content?.code ?? "").joined(separator: "\n"))
        _stdin = State(initialValue: content?.stdin ?? "")
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(language == .python ? "Python" : "Pseudocode")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
        }
        .onAppear {
            if language == .python { PythonRunner.shared.warmUp() }
        }
        .interactiveDismissDisabled(hasChanges)
        .modifier(CodeSheetSizing())
    }

    // MARK: Layout

    @ViewBuilder private var content: some View {
        if original == nil {
            ContentUnavailableView("This code block isn't here any more", systemImage: "chevron.left.forwardslash.chevron.right",
                                   description: Text("It may have been deleted."))
        } else {
            VStack(spacing: 0) {
                header
                Divider()
                CodeTextView(text: $code, language: language, fontSize: 16, focusOnAppear: original?.code.isEmpty == true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                bottomPanel
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            TextField("Title (optional)", text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.headline)
            Picker("Language", selection: $language) {
                ForEach(CodeLanguage.allCases) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var bottomPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if language == .python {
                inputSection
                outputSection
            } else {
                Label("Pseudocode plans an algorithm, so it isn't run. Check it with a desk check (a trace table), or ask your tutor.",
                      systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Program input").font(.subheadline.weight(.semibold))
                Text("One line for each input() call").font(.caption).foregroundStyle(.secondary)
            }
            CodeTextView(text: $stdin, language: nil, fontSize: 15)
                .frame(height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(uiColor: .separator)))
        }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Output").font(.subheadline.weight(.semibold))
                Spacer()
                if running {
                    ProgressView().controlSize(.small)
                    Text(PythonRunner.shared.statusText ?? "Running…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let status = outputStatus {
                    Text(status.text)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(status.ok ? Color(hex: "#1A7F37") : Color(uiColor: CodeRenderer.errorColor))
                }
            }
            ScrollView {
                outputText
                    .font(.system(size: 14, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 150)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(uiColor: .separator)))
        }
    }

    @ViewBuilder private var outputText: some View {
        if let shown = shownOutput {
            VStack(alignment: .leading, spacing: 6) {
                if !shown.output.isEmpty {
                    Text(verbatim: shown.output).foregroundStyle(Color(hex: "#1F2328"))
                }
                if let error = shown.error, !error.isEmpty {
                    Text(verbatim: error).foregroundStyle(Color(uiColor: CodeRenderer.errorColor))
                }
                if shown.output.isEmpty && (shown.error ?? "").isEmpty {
                    Text("(no output)").italic().foregroundStyle(Color(hex: "#6E7781"))
                }
                if shown.stale {
                    Text("You've changed the program since this ran. Tap Run to update it.")
                        .font(.caption)
                        .foregroundStyle(Color(hex: "#6E7781"))
                }
            }
        } else {
            Text("Tap Run (⌘R) to see what your program prints.").foregroundStyle(Color(hex: "#6E7781"))
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Cancel") { dismiss() }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                ForEach(CodeHelpRequest.allCases) { request in
                    Button {
                        ask(request)
                    } label: {
                        Label(request.title, systemImage: request.symbol)
                    }
                }
            } label: {
                Label("Ask Tutor", systemImage: "sparkles")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(original == nil)
            Button {
                run()
            } label: {
                Label("Run", systemImage: "play.fill")
                    .labelStyle(.titleAndIcon)
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(running || language != .python || code.trimmed.isEmpty || original == nil)
            Button("Done") {
                save()
                dismiss()
            }
            .fontWeight(.semibold)
        }
    }

    // MARK: State

    /// The block as edited in the sheet (its last-run fields are the original's).
    private var draft: CodeContent {
        var c = original ?? CodeContent(code: "")
        c.title = title.trimmed.isEmpty ? nil : title.trimmed
        c.language = language.rawValue
        c.code = CodeText.lines(code).joined(separator: "\n")
        c.stdin = stdin.isEmpty ? nil : CodeText.normalized(stdin)
        return c
    }

    private func sameProgram(_ a: CodeContent, _ b: CodeContent) -> Bool {
        a.code == b.code && (a.stdin ?? "") == (b.stdin ?? "") && a.lang == b.lang
    }

    private var hasChanges: Bool {
        guard let o = original else { return false }
        let d = draft
        return d.code != o.code || d.title != o.title || d.lang != o.lang || (d.stdin ?? "") != (o.stdin ?? "") || sheetRun != nil
    }

    private struct ShownOutput {
        var output: String
        var error: String?
        var stale: Bool
    }

    private var shownOutput: ShownOutput? {
        let d = draft
        if let run = sheetRun {
            let text = CodeOutputText.limited(run.result.output, maxChars: 20_000, maxLines: 600).text
            return ShownOutput(output: text, error: run.result.error, stale: run.result.ran && !sameProgram(run.program, d))
        }
        if let o = original, o.hasRun {
            return ShownOutput(output: o.output ?? "", error: o.error, stale: !sameProgram(o, d))
        }
        return nil
    }

    private var outputStatus: (text: String, ok: Bool)? {
        if let r = sheetRun?.result { return (r.headline, r.status == .finished) }
        if let o = original, o.hasRun { return (o.errored ? "Last run stopped with an error" : "Last run", !o.errored) }
        return nil
    }

    // MARK: Actions

    private func run() {
        guard !running, language == .python, original != nil else { return }
        let program = draft
        running = true
        Task { @MainActor in
            let result = await PythonRunner.shared.run(program.code, stdin: program.stdinLines)
            sheetRun = SheetRun(result: result, program: program, date: Date())
            running = false
        }
    }

    /// Saves the edits as one undoable change, resizing the block to fit. The output stored on
    /// the block always belongs to the code it shows: a run from this sheet if it ran exactly
    /// this program, the block's earlier run if the program is unchanged, otherwise none.
    private func save() {
        guard let e = model.document.element(elementID), case .code(let current) = e.kind else { return }
        var c = draft
        if let run = sheetRun, run.result.ran, sameProgram(run.program, c) {
            c = run.result.applied(to: c, at: run.date)
        } else if sameProgram(current, c) {
            c.output = current.output
            c.error = current.error
            c.ranAt = current.ranAt
        } else {
            c = c.clearingRun()
        }
        if !c.isRunnable { c = c.clearingRun() }
        guard c != current else { return }
        let updated = c
        let height = CodeRenderer.size(for: updated, width: e.frame.width).height
        model.document.update(elementID, actionName: "Edit Code") {
            $0.kind = .code(updated)
            $0.frame.size.height = height
        }
    }

    private func ask(_ request: CodeHelpRequest) {
        save()
        dismiss()
        model.askTutor(aboutCode: elementID, request)
    }
}

/// A big sheet for editing code: page-sized where the system supports it (iOS 18), otherwise
/// the standard large form sheet.
private struct CodeSheetSizing: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.0)
        if #available(iOS 18.0, *) {
            content.presentationSizing(.page)
        } else {
            content.presentationDetents([.large])
        }
        #else
        content.presentationDetents([.large])
        #endif
    }
}

// MARK: - Code text view

/// A UITextView set up for code: monospaced, no autocorrection, capitals, smart quotes or
/// dashes, spell-check or predictions; live syntax highlighting (debounced); line numbers;
/// auto-indent after a line ending in ":"; Tab inserts 4 spaces (Shift-Tab, ⌘[ and the ⇤ key
/// dedent); and a key bar with Tab, dedent and common symbols. With no language it's a plain
/// monospaced field (the program input).
struct CodeTextView: UIViewRepresentable {
    @Binding var text: String
    var language: CodeLanguage?
    var fontSize: CGFloat = 16
    var focusOnAppear = false

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, language: language) }

    func makeUIView(context: Context) -> CodeUITextView {
        let tv = CodeUITextView()
        tv.delegate = context.coordinator
        tv.overrideUserInterfaceStyle = .light
        tv.backgroundColor = .white
        tv.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        tv.textColor = CodeRenderer.color(for: .plain)
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.spellCheckingType = .no
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.smartInsertDeleteType = .no
        tv.inlinePredictionType = .no
        tv.dataDetectorTypes = []
        tv.allowsEditingTextAttributes = false
        tv.keyboardDismissMode = .interactive
        tv.alwaysBounceVertical = true
        #if compiler(>=6.0)
        if #available(iOS 18.0, *) {
            tv.writingToolsBehavior = .none
        }
        #endif
        tv.text = text
        context.coordinator.attach(tv)
        if focusOnAppear {
            context.coordinator.didRequestFocus = true
            tv.focusWhenInWindow()
        }
        return tv
    }

    func updateUIView(_ tv: CodeUITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.text = $text
        if tv.text != text {
            tv.text = text
            coordinator.highlightNow(tv)
            tv.refreshGutter()
        }
        if coordinator.language != language {
            coordinator.language = language
            coordinator.highlightNow(tv)
        }
        if focusOnAppear && !coordinator.didRequestFocus {
            coordinator.didRequestFocus = true
            tv.focusWhenInWindow()
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        var language: CodeLanguage?
        var didRequestFocus = false
        private var highlightTask: Task<Void, Never>?

        init(text: Binding<String>, language: CodeLanguage?) {
            self.text = text
            self.language = language
        }

        func attach(_ tv: CodeUITextView) {
            if language != nil {
                tv.showsLineNumbers = true
                tv.inputAccessoryView = keyBar(for: tv)
                tv.onIndentKey = { [weak self, weak tv] in
                    guard let self, let tv else { return }
                    self.insert(CodeEditing.indentUnit, in: tv)
                }
                tv.onDedentKey = { [weak self, weak tv] in
                    guard let self, let tv else { return }
                    self.dedent(tv)
                }
            } else {
                tv.showsLineNumbers = false
            }
            highlightNow(tv)
            tv.refreshGutter()
        }

        // MARK: UITextViewDelegate

        func textViewDidChange(_ textView: UITextView) {
            let now = textView.text ?? ""
            if text.wrappedValue != now { text.wrappedValue = now }
            (textView as? CodeUITextView)?.refreshGutter()
            scheduleHighlight(textView)
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText replacement: String) -> Bool {
            // Pasted text: normalise line endings and tabs, so offsets and indentation stay simple.
            if replacement.contains("\r") || (replacement.contains("\t") && replacement != "\t") {
                replace(textView, range, with: CodeText.lines(replacement).joined(separator: "\n"))
                return false
            }
            guard let language else { return true }
            if replacement == "\t" {
                replace(textView, range, with: CodeEditing.indentUnit)
                return false
            }
            if replacement == "\n" {
                let ns = (textView.text ?? "") as NSString
                let lineStart = ns.lineRange(for: NSRange(location: range.location, length: 0)).location
                let before = ns.substring(with: NSRange(location: lineStart, length: max(0, range.location - lineStart)))
                replace(textView, range, with: "\n" + CodeEditing.newlineIndent(after: before, language: language))
                return false
            }
            return true
        }

        // MARK: Editing

        private func replace(_ tv: UITextView, _ range: NSRange, with s: String) {
            guard let start = tv.position(from: tv.beginningOfDocument, offset: range.location),
                  let end = tv.position(from: start, offset: range.length),
                  let r = tv.textRange(from: start, to: end) else { return }
            tv.replace(r, withText: s)
            tv.selectedRange = NSRange(location: range.location + (s as NSString).length, length: 0)
            textViewDidChange(tv)
        }

        func insert(_ s: String, in tv: UITextView) {
            replace(tv, tv.selectedRange, with: s)
        }

        /// Removes one level of indentation from every line in the selection.
        func dedent(_ tv: UITextView) {
            let ns = (tv.text ?? "") as NSString
            let sel = tv.selectedRange
            let block = ns.lineRange(for: sel)
            var starts: [Int] = []
            var i = block.location
            repeat {
                starts.append(i)
                let next = NSMaxRange(ns.lineRange(for: NSRange(location: i, length: 0)))
                if next <= i { break }
                i = next
            } while i < NSMaxRange(block)
            var removedTotal = 0
            var removedFirst = 0
            for (k, start) in starts.enumerated().reversed() {
                let line = ns.substring(with: ns.lineRange(for: NSRange(location: start, length: 0)))
                let n = CodeEditing.dedent(line).removed
                guard n > 0, let a = tv.position(from: tv.beginningOfDocument, offset: start),
                      let b = tv.position(from: a, offset: n), let r = tv.textRange(from: a, to: b) else { continue }
                tv.replace(r, withText: "")
                removedTotal += n
                if k == 0 { removedFirst = n }
            }
            guard removedTotal > 0 else { return }
            let first = starts.first ?? sel.location
            let location = max(first, sel.location - removedFirst)
            let end = max(location, NSMaxRange(sel) - removedTotal)
            let length = ((tv.text ?? "") as NSString).length
            tv.selectedRange = NSRange(location: min(location, length), length: max(0, min(end, length) - min(location, length)))
            textViewDidChange(tv)
        }

        // MARK: Highlighting

        private func scheduleHighlight(_ tv: UITextView) {
            highlightTask?.cancel()
            highlightTask = Task { @MainActor [weak self, weak tv] in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled, let self, let tv else { return }
                self.highlightNow(tv)
            }
        }

        func highlightNow(_ tv: UITextView) {
            let font = tv.font ?? UIFont.monospacedSystemFont(ofSize: 16, weight: .regular)
            let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: CodeRenderer.color(for: .plain)]
            guard let language else {
                tv.typingAttributes = base
                return
            }
            // Don't restyle in the middle of composing a character (e.g. with an accent key).
            guard tv.markedTextRange == nil else {
                scheduleHighlight(tv)
                return
            }
            let storage = tv.textStorage
            let length = storage.length
            let selection = tv.selectedRange
            storage.beginEditing()
            storage.setAttributes(base, range: NSRange(location: 0, length: length))
            for run in CodeHighlighter.utf16Runs(storage.string, language: language) where run.location + run.length <= length {
                storage.addAttribute(.foregroundColor, value: CodeRenderer.color(for: run.kind),
                                     range: NSRange(location: run.location, length: run.length))
            }
            storage.endEditing()
            if tv.selectedRange != selection { tv.selectedRange = selection }
            tv.typingAttributes = base
        }

        // MARK: Key bar

        private func keyBar(for tv: CodeUITextView) -> UIView {
            let bar = UIInputView(frame: CGRect(x: 0, y: 0, width: 320, height: 48), inputViewStyle: .keyboard)
            bar.autoresizingMask = [.flexibleWidth]
            let scroll = UIScrollView(frame: bar.bounds)
            scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            scroll.showsHorizontalScrollIndicator = false
            let stack = UIStackView()
            stack.axis = .horizontal
            stack.spacing = 6
            stack.alignment = .center
            stack.translatesAutoresizingMaskIntoConstraints = false
            scroll.addSubview(stack)
            bar.addSubview(scroll)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
                stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
                stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
                stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
                stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            ])
            stack.addArrangedSubview(key("Tab", accessibility: "Indent") { [weak self, weak tv] in
                guard let self, let tv else { return }
                self.insert(CodeEditing.indentUnit, in: tv)
            })
            stack.addArrangedSubview(key("⇤", accessibility: "Dedent") { [weak self, weak tv] in
                guard let self, let tv else { return }
                self.dedent(tv)
            })
            let symbols: [(String, String)] = [(":", "Colon"), ("(", "Open bracket"), (")", "Close bracket"), ("[", "Open square bracket"),
                                               ("]", "Close square bracket"), ("\"", "Double quote"), ("'", "Single quote"), ("=", "Equals"),
                                               ("#", "Hash"), (",", "Comma"), ("_", "Underscore"), ("<", "Less than"), (">", "Greater than"),
                                               ("+", "Plus"), ("-", "Minus"), ("*", "Times"), ("/", "Divide")]
            for (symbol, name) in symbols {
                stack.addArrangedSubview(key(symbol, accessibility: name) { [weak self, weak tv] in
                    guard let self, let tv else { return }
                    self.insert(symbol, in: tv)
                })
            }
            let hide = UIButton(type: .system)
            hide.setImage(UIImage(systemName: "keyboard.chevron.compact.down"), for: .normal)
            hide.tintColor = .label
            hide.accessibilityLabel = "Hide keyboard"
            hide.widthAnchor.constraint(equalToConstant: 44).isActive = true
            hide.addAction(UIAction { [weak tv] _ in _ = tv?.resignFirstResponder() }, for: .touchUpInside)
            stack.addArrangedSubview(hide)
            return bar
        }

        private func key(_ title: String, accessibility: String, _ action: @escaping () -> Void) -> UIButton {
            let b = UIButton(type: .system)
            b.setTitle(title, for: .normal)
            b.titleLabel?.font = UIFont.monospacedSystemFont(ofSize: 17, weight: .medium)
            b.setTitleColor(.label, for: .normal)
            b.backgroundColor = UIColor.white
            b.layer.cornerRadius = 7
            b.layer.shadowColor = UIColor.black.cgColor
            b.layer.shadowOpacity = 0.25
            b.layer.shadowRadius = 0
            b.layer.shadowOffset = CGSize(width: 0, height: 1)
            b.accessibilityLabel = accessibility
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(greaterThanOrEqualToConstant: title.count > 1 ? 56 : 40).isActive = true
            b.heightAnchor.constraint(equalToConstant: 36).isActive = true
            b.addAction(UIAction { _ in action() }, for: .touchUpInside)
            return b
        }
    }
}

/// The text view behind CodeTextView: draws line numbers in a gutter and handles Tab and
/// Shift-Tab from a hardware keyboard.
final class CodeUITextView: UITextView {
    var showsLineNumbers = false {
        didSet {
            if showsLineNumbers && gutter.superview !== self {
                gutter.textView = self
                addSubview(gutter)
            }
            gutter.isHidden = !showsLineNumbers
            updateInsets()
            setNeedsLayout()
        }
    }
    var onIndentKey: (() -> Void)?
    var onDedentKey: (() -> Void)?
    private let gutter = LineNumberGutter(frame: .zero)
    private var gutterDigits = 2
    private var wantsFocus = false

    private var gutterWidth: CGFloat { showsLineNumbers ? CGFloat(gutterDigits) * gutter.digitWidth + 20 : 0 }

    private func updateInsets() {
        textContainerInset = showsLineNumbers
            ? UIEdgeInsets(top: 12, left: gutterWidth + 6, bottom: 12, right: 12)
            : UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
    }

    func refreshGutter() {
        guard showsLineNumbers else { return }
        let lines = (text ?? "").utf16.reduce(1) { $1 == 10 ? $0 + 1 : $0 }
        let digits = max(2, String(lines).count)
        if digits != gutterDigits {
            gutterDigits = digits
            updateInsets()
        }
        setNeedsLayout()
        gutter.setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard showsLineNumbers else { return }
        // Pinned to the visible area; it draws the numbers for whatever lines are on screen.
        gutter.frame = CGRect(x: contentOffset.x, y: contentOffset.y, width: gutterWidth, height: bounds.height)
        bringSubviewToFront(gutter)
        gutter.setNeedsDisplay()
    }

    func focusWhenInWindow() {
        if window != nil {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                _ = self?.becomeFirstResponder()
            }
        } else {
            wantsFocus = true
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if wantsFocus && window != nil {
            wantsFocus = false
            focusWhenInWindow()
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        guard onIndentKey != nil else { return super.keyCommands }
        let tab = UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(indentKeyPressed))
        tab.wantsPriorityOverSystemBehavior = true
        let backTab = UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(dedentKeyPressed))
        backTab.wantsPriorityOverSystemBehavior = true
        let indent = UIKeyCommand(title: "Indent", action: #selector(indentKeyPressed), input: "]", modifierFlags: .command)
        let outdent = UIKeyCommand(title: "Outdent", action: #selector(dedentKeyPressed), input: "[", modifierFlags: .command)
        return (super.keyCommands ?? []) + [tab, backTab, indent, outdent]
    }

    @objc private func indentKeyPressed() { onIndentKey?() }
    @objc private func dedentKeyPressed() { onDedentKey?() }
}

/// Line numbers beside the code, for the lines currently on screen (wrapped lines are numbered
/// once, on their first row, like the card on the page).
final class LineNumberGutter: UIView {
    weak var textView: UITextView?
    let font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    var digitWidth: CGFloat { ("0" as NSString).size(withAttributes: [.font: font]).width }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        isUserInteractionEnabled = false
        backgroundColor = UIColor(hex: "#F6F8FA")
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        UIColor(hex: "#F6F8FA").setFill()
        UIRectFill(bounds)
        UIColor(hex: "#D0D7DE").setFill()
        UIRectFill(CGRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height))
        guard let tv = textView else { return }
        let text = (tv.text ?? "") as NSString
        let top = tv.contentOffset.y
        let bottom = top + tv.bounds.height
        // Start from the first line that could be on screen.
        var location = 0
        if let p = tv.closestPosition(to: CGPoint(x: tv.textContainerInset.left + 2, y: max(0, top))) {
            location = max(0, min(text.length, tv.offset(from: tv.beginningOfDocument, to: p)))
        }
        var lineStart = text.lineRange(for: NSRange(location: location, length: 0)).location
        var number = 1
        for i in 0..<lineStart where text.character(at: i) == 10 { number += 1 }
        let para = NSMutableParagraphStyle()
        para.alignment = .right
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor(hex: "#8C959F"), .paragraphStyle: para]
        var steps = 0
        while steps < 2000 {
            steps += 1
            guard let pos = tv.position(from: tv.beginningOfDocument, offset: lineStart) else { break }
            let caret = tv.caretRect(for: pos)
            if caret.isNull || caret.isInfinite || caret.minY > bottom { break }
            if caret.maxY >= top {
                let y = caret.minY - top + (caret.height - font.lineHeight) / 2
                NSAttributedString(string: "\(number)", attributes: attrs)
                    .draw(in: CGRect(x: 0, y: y, width: bounds.width - 8, height: font.lineHeight + 2))
            }
            if lineStart >= text.length { break }
            let next = NSMaxRange(text.lineRange(for: NSRange(location: lineStart, length: 0)))
            if next <= lineStart { break }
            if next >= text.length {
                // A last, empty line after a final newline still gets its number.
                if text.length > 0 && text.character(at: text.length - 1) == 10 {
                    lineStart = text.length
                    number += 1
                    continue
                }
                break
            }
            lineStart = next
            number += 1
        }
    }
}
