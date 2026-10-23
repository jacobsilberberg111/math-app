import SwiftUI
import PhotosUI

/// The editor's toolbar, in one row so writing isn't crowded by controls: back, title and undo on
/// the left; the drawing tools, the tutor's Ask and Hint, and the current pen's colours and width
/// in the middle; insert, record, More and the tutor on the right. Everything used less often
/// (pages, find, paper, export, the ruler and other drawing switches) is in the + and More menus.
/// (Explicitly main-actor: with the iOS 17 SDK nothing here would infer it, and `commitTitle`
/// touches the main-actor model.)
@MainActor
struct EditorTopBar: View {
    @Bindable var model: EditorModel
    var onClose: () -> Void
    var onInsertPhoto: () -> Void
    var onImportPDF: () -> Void
    var onExport: (ExportKind) -> Void
    var onScan: (() -> Void)?
    /// Closes this note and opens another (from the back button's recent notes).
    var onSwitchNote: ((NoteMeta) -> Void)?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(LibraryStore.self) private var library
    @EnvironmentObject var settings: AppSettings
    @State private var editingTitle = false
    @State private var titleDraft = ""
    @State private var clearingPage: Int?
    @State private var showPenStyles = false
    @State private var showEraserOptions = false
    @State private var editingColorIndex: Int?
    @State private var showWidths = false
    @State private var showInkOptions = false
    @FocusState private var titleFocused: Bool

    /// How much fits in the row, from the widest (labels, every colour slot) to the narrowest
    /// (icons only, one colour button, recording in the More menu).
    private enum Fit { case roomy, standard, tight, compact }

    private var tools: ToolState { model.tools }
    private var isBoard: Bool { model.document.isFreeform }
    private var tutorTint: Color { Color(hex: settings.tutorInkHex) }

    /// Other notes to jump to, most recent first.
    private var recentNotes: [NoteMeta] {
        Array(library.recentNotes.filter { $0.id != model.document.id }.prefix(8))
    }

    var body: some View {
        GeometryReader { geo in
            row(fit(for: geo.size.width))
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: 50)
        .padding(.horizontal, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .background { findShortcut }
        .clearPageDialog(model: model, page: $clearingPage)
    }

    private func fit(for width: CGFloat) -> Fit {
        if sizeClass == .compact || width < 700 { return .compact }
        if width >= 1100 { return .roomy }
        if width >= 940 { return .standard }
        return .tight
    }

    private func row(_ fit: Fit) -> some View {
        HStack(spacing: 4) {
            backButton
            title(fit)
            BarButton(symbol: "arrow.uturn.backward", label: "Undo", enabled: model.canUndo) { model.undo() }
            if fit != .compact {
                BarButton(symbol: "arrow.uturn.forward", label: "Redo", enabled: model.canRedo) { model.redo() }
            }
            Spacer(minLength: 6)
            toolGroup(labels: fit == .roomy)
            if showsInkOptions {
                if fit == .roomy || fit == .standard { inkRow } else { inkButton }
            }
            Spacer(minLength: 6)
            insertMenu
            if fit != .compact { RecordButton(audio: model.audio) }
            moreMenu(includesRecording: fit == .compact)
            TutorToggleButton(model: model, showsLabel: fit == .roomy || fit == .standard)
        }
    }

    // MARK: Left: back and title

    /// Tap goes back home; press and hold to jump straight to another recent note.
    private var backButton: some View {
        Menu {
            if let onSwitchNote, !recentNotes.isEmpty {
                Section("Recent Notes") {
                    ForEach(recentNotes) { meta in
                        Button { onSwitchNote(meta) } label: {
                            Label(meta.title, systemImage: meta.isFreeform ? "scribble.variable" : "doc.text")
                        }
                    }
                }
            }
            Button(action: onClose) { Label("Home", systemImage: "house") }
        } label: {
            Image(systemName: "chevron.backward")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 40, height: 40)
        } primaryAction: {
            onClose()
        }
        .accessibilityLabel("Back to Home")
    }

    @ViewBuilder
    private func title(_ fit: Fit) -> some View {
        if editingTitle {
            TextField("Title", text: $titleDraft)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .focused($titleFocused)
                .onSubmit { commitTitle() }
                .onChange(of: titleFocused) { _, focused in if !focused { commitTitle() } }
                // Focusing in the same update that inserts the field is unreliable; do it once it's there.
                .onAppear { titleFocused = true }
        } else {
            Button {
                titleDraft = model.document.meta.title
                editingTitle = true
                titleFocused = true
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.document.meta.title)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    if fit != .compact {
                        Text(isBoard ? "Freeform board" : "Page \(model.currentPage + 1) of \(model.pageCount)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)
            // The title gives way first when the row is short of room.
            .frame(maxWidth: fit == .roomy ? 240 : 160, alignment: .leading)
            .layoutPriority(-1)
        }
    }

    // MARK: Middle: tools

    private func toolGroup(labels: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach([CanvasToolKind.pen, .highlighter, .eraser, .lasso, .text], id: \.self) { kind in
                toolButton(kind)
            }
            Divider().frame(height: 22).padding(.horizontal, 3)
            askButton(label: labels)
            hintButton(label: labels)
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.secondary.opacity(0.08)))
        // Apple Pencil double-tap ("Show colour palette") and squeeze ("Tool palette") land here.
        .popover(isPresented: $model.palettePresented) {
            ColorPalettePicker(hex: currentColorBinding, highlighter: tools.kind == .highlighter,
                               onEyedropper: { model.startEyedropper() })
                .presentationCompactAdaptation(.popover)
        }
    }

    /// Tap a tool to use it; tap the one in use for its options (pen type, eraser kind).
    private func toolButton(_ kind: CanvasToolKind) -> some View {
        let selected = tools.kind == kind
        return Button {
            if selected {
                if kind == .pen { showPenStyles = true }
                if kind == .eraser { showEraserOptions = true }
            } else {
                model.selectTool(kind)
                if kind == .lasso { model.flash("Circle anything to select it") }
            }
        } label: {
            ZStack(alignment: .bottom) {
                Image(systemName: kind == .pen ? tools.penStyle.symbol : kind.symbol)
                    .font(.system(size: 18, weight: selected ? .semibold : .regular))
                    .frame(width: 40, height: 36)
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
                if kind == .pen || kind == .highlighter {
                    let hex = kind == .pen ? (tools.penColors[safe: tools.penColorIndex] ?? "#000000")
                                           : (tools.highlighterColors[safe: tools.highlighterColorIndex] ?? "#FFE066")
                    Capsule().fill(Color(hex: hex)).frame(width: 16, height: 3).offset(y: -1)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Color.accentColor.opacity(0.14) : .clear))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind.title)
        .help(kind.title)
        .popover(isPresented: Binding(get: { (kind == .pen && showPenStyles) || (kind == .eraser && showEraserOptions) },
                                      set: { if !$0 { showPenStyles = false; showEraserOptions = false } })) {
            Group {
                if kind == .pen {
                    PenStylePicker(selection: Binding(get: { tools.penStyle }, set: { tools.penStyle = $0; showPenStyles = false }))
                } else {
                    EraserOptions(tools: tools)
                }
            }
            .presentationCompactAdaptation(.popover)
        }
    }

    private func askButton(label: Bool) -> some View {
        let selected = tools.kind == .tutor
        return Button {
            if selected {
                model.selectTool(tools.lastDrawingKind)
            } else {
                model.selectTool(.tutor)
                model.flash("Circle or tap anything to ask about it")
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "sparkles").font(.system(size: 16, weight: .semibold))
                if label { Text("Ask").font(.system(size: 14, weight: .semibold)) }
            }
            .foregroundStyle(selected ? .white : tutorTint)
            .padding(.horizontal, label ? 10 : 0)
            .frame(minWidth: 40, minHeight: 36)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? tutorTint : tutorTint.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ask tutor about an area")
        .help("Ask the tutor about an area")
    }

    private func hintButton(label: Bool) -> some View {
        Button {
            model.giveHint()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "lightbulb").font(.system(size: 16, weight: .semibold))
                if label { Text("Hint").font(.system(size: 14, weight: .semibold)) }
            }
            .foregroundStyle(tutorTint)
            .padding(.horizontal, label ? 10 : 0)
            .frame(minWidth: 40, minHeight: 36)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tutorTint.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .disabled(model.tutor.isBusy)
        .opacity(model.tutor.isBusy ? 0.45 : 1)
        .accessibilityLabel("Give me a hint")
        .accessibilityHint("Your tutor leaves a small nudge beside your latest working, without giving the answer")
        .help("Get a hint")
    }

    // MARK: Middle: colour and width

    private var showsInkOptions: Bool { tools.kind == .pen || tools.kind == .highlighter || tools.kind == .text }

    private var currentColorBinding: Binding<String> {
        Binding(get: { tools.colors[safe: tools.colorIndex] ?? "#1F2328" }, set: { tools.setColor($0, at: tools.colorIndex) })
    }

    /// Three colour slots and the width, when there's room for them.
    private var inkRow: some View {
        HStack(spacing: 2) {
            ForEach(0..<min(ToolState.visibleColorSlots, tools.colors.count), id: \.self) { i in
                colorDot(i)
            }
            if tools.kind != .text { widthButton }
        }
    }

    private func colorDot(_ i: Int) -> some View {
        let hex = tools.colors[safe: i] ?? "#1F2328"
        let selected = i == tools.colorIndex
        return Button {
            if selected { editingColorIndex = i } else { tools.selectColor(i) }
        } label: {
            ZStack {
                Circle().fill(Color(hex: hex)).frame(width: 22, height: 22)
                Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1).frame(width: 22, height: 22)
                if selected {
                    Circle().strokeBorder(Color.accentColor, lineWidth: 2.5).frame(width: 30, height: 30)
                }
            }
            .frame(width: 34, height: 36)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Colour \(i + 1)")
        .accessibilityHint(selected ? "Opens the colour palette" : "")
        .popover(isPresented: Binding(get: { editingColorIndex == i }, set: { if !$0 { editingColorIndex = nil } })) {
            ColorPalettePicker(hex: Binding(get: { tools.colors[safe: i] ?? hex }, set: { tools.setColor($0, at: i) }),
                               highlighter: tools.kind == .highlighter,
                               onEyedropper: { editingColorIndex = nil; model.startEyedropper() })
                .presentationCompactAdaptation(.popover)
        }
    }

    private var widthButton: some View {
        Button {
            showWidths = true
        } label: {
            WidthSwatch(width: tools.widths[safe: tools.widthIndex] ?? 3, maxWidth: tools.widths.max() ?? 6)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Thickness")
        .popover(isPresented: $showWidths) {
            WidthPicker(tools: tools).padding(16).frame(width: 260)
                .presentationCompactAdaptation(.popover)
        }
    }

    /// Narrow rows: one button showing the current colour, opening slots, width and palette together.
    private var inkButton: some View {
        Button {
            showInkOptions = true
        } label: {
            ZStack {
                Circle().fill(Color(hex: currentColorBinding.wrappedValue)).frame(width: 24, height: 24)
                Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1).frame(width: 24, height: 24)
                Circle().strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 2).frame(width: 32, height: 32)
            }
            .frame(width: 38, height: 38)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Colour and thickness")
        .popover(isPresented: $showInkOptions) {
            InkOptionsPopover(tools: tools, color: currentColorBinding, onEyedropper: {
                showInkOptions = false
                model.startEyedropper()
            })
            .presentationCompactAdaptation(.popover)
        }
    }

    // MARK: Right: insert, More

    private var insertMenu: some View {
        Menu {
            Button { onInsertPhoto() } label: { Label("Photo", systemImage: "photo") }
            if !isBoard {
                Button { onImportPDF() } label: { Label("PDF Pages", systemImage: "doc.richtext") }
            }
            if let onScan, !isBoard, DocumentScanner.isAvailable {
                Button { onScan() } label: { Label("Scan Pages", systemImage: "doc.viewfinder") }
            }
            Button { model.selectTool(.text) } label: { Label("Text Box", systemImage: "textformat") }
            if CanvasClip.pasteboardHasContent {
                Button { model.canvas?.pasteFromClipboard(at: nil) } label: { Label("Paste", systemImage: "doc.on.clipboard") }
            }
            Divider()
            Button {
                model.showPanelIfNoKey()
                model.tutor.quick(.flashcards)
            } label: { Label("Flashcards from This Page", systemImage: "rectangle.on.rectangle.angled") }
            if model.canPractiseAsPastPaper {
                Button { model.practiseAsPastPaper() } label: { Label("Practise as Past Paper", systemImage: "doc.text.magnifyingglass") }
            }
            if !isBoard {
                Divider()
                Button { model.document.appendPage(); model.canvas?.scrollToPage(model.pageCount - 1) } label: { Label("New Page", systemImage: "doc.badge.plus") }
                Button(role: .destructive) { clearingPage = model.currentPage } label: { Label("Clear This Page", systemImage: "eraser") }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 40, height: 40)
        }
        .accessibilityLabel("Insert")
    }

    private func moreMenu(includesRecording: Bool) -> some View {
        Menu {
            if includesRecording {
                Section {
                    Button { model.audio.toggleRecording() } label: {
                        Label(model.audio.isRecording ? "Stop Recording" : "Record Audio", systemImage: model.audio.isRecording ? "stop.circle" : "mic")
                    }
                    if model.audio.activeRecording != nil && !model.audio.isRecording {
                        Button { model.audio.showsPlayer = true } label: { Label("Show Playback", systemImage: "play.circle") }
                    }
                }
            }
            Section {
                if isBoard {
                    Button { model.canvas?.zoomToShowAll() } label: { Label("Show Whole Board", systemImage: "arrow.up.left.and.arrow.down.right") }
                    Menu { BoardLinesMenuContent(document: model.document) } label: { Label("Background", systemImage: "squareshape.split.3x3") }
                } else {
                    Button { model.showPages = true } label: { Label("Pages", systemImage: "square.grid.2x2") }
                    Button { model.showPaper = true } label: { Label("Paper & Page Size", systemImage: "doc.plaintext") }
                }
                Button { model.find.open() } label: { Label("Find in Note", systemImage: "magnifyingglass") }
                Menu { ExportMenuItems(onExport: onExport) } label: { Label("Export", systemImage: "square.and.arrow.up") }
            }
            Section("Drawing") {
                Toggle(isOn: Binding(get: { tools.rulerActive }, set: { tools.rulerActive = $0 })) {
                    Label("Ruler", systemImage: "ruler")
                }
                Toggle(isOn: Binding(get: { settings.shapeRecognition }, set: { on in
                    settings.shapeRecognition = on
                    model.flash(on ? "Draw and hold to snap shapes" : "Shape snapping off")
                })) {
                    Label("Snap Shapes", systemImage: "scribble.variable")
                }
                Toggle(isOn: Binding(get: { settings.fingerDrawing }, set: { on in
                    settings.fingerDrawing = on
                    model.flash(on ? "Finger drawing on · two fingers scroll" : "Pencil only · fingers scroll")
                })) {
                    Label("Draw with Finger", systemImage: "hand.draw")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 18, weight: .medium))
                .frame(width: 40, height: 40)
        }
        .accessibilityLabel("More")
    }

    /// ⌘F opens Find; the button itself lives in the More menu.
    private var findShortcut: some View {
        Button("Find in Note") { model.find.open() }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    private func commitTitle() {
        editingTitle = false
        let t = titleDraft.trimmed
        if !t.isEmpty && t != model.document.meta.title {
            model.document.meta.title = t
            model.document.markDirty()
        }
    }
}

/// A freeform board's background lines and paper colour, for the More menu.
struct BoardLinesMenuContent: View {
    let document: NoteDocument

    private var paper: PaperStyle { document.content.pages.first?.paper ?? .standard }

    var body: some View {
        Section("Lines") {
            ForEach(PaperPattern.boardPatterns) { p in
                Button {
                    document.setPaper(PaperStyle(pattern: p, color: paper.color), forPage: nil)
                } label: {
                    Label(p.title, systemImage: p == paper.pattern ? "checkmark" : p.symbol)
                }
            }
        }
        Menu {
            ForEach(PaperColor.allCases) { c in
                Button {
                    document.setPaper(PaperStyle(pattern: paper.pattern, color: c), forPage: nil)
                } label: {
                    Label {
                        Text(c.rawValue.capitalized)
                    } icon: {
                        Image(uiImage: LibraryView.swatch(c.hex, current: c == paper.color))
                    }
                }
            }
        } label: { Label("Paper Colour", systemImage: "paintpalette") }
    }
}

struct BarButton: View {
    let symbol: String
    let label: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 40, height: 40)
        }
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

struct RecordButton: View {
    let audio: AudioController

    var body: some View {
        // Tap records; long-press brings back the playback bar after it was closed.
        Menu {
            Button {
                audio.showsPlayer = true
            } label: {
                Label("Show Playback", systemImage: "play.circle")
            }
            .disabled(audio.isRecording || audio.activeRecording == nil)
        } label: {
            ZStack {
                if audio.isRecording {
                    Circle().fill(Color.red.opacity(0.15)).frame(width: 34, height: 34)
                }
                Image(systemName: audio.isRecording ? "stop.circle.fill" : "mic")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(audio.isRecording ? Color.red : Color.accentColor)
            }
            .frame(width: 40, height: 40)
        } primaryAction: {
            audio.toggleRecording()
        }
        .accessibilityLabel(audio.isRecording ? "Stop recording" : "Record audio")
    }
}

/// The tutor button glows while the tutor is thinking or watching.
struct TutorToggleButton: View {
    @Bindable var model: EditorModel
    var showsLabel = true
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { model.showTutor.toggle() }
        } label: {
            HStack(spacing: 6) {
                TutorOrb(active: model.tutor.isBusy || model.tutor.isObserving, size: 22)
                if showsLabel {
                    Text("Tutor").font(.system(size: 15, weight: .semibold))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(model.showTutor ? Color(hex: settings.tutorInkHex).opacity(0.16) : Color.secondary.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Tutor")
    }
}

/// Animated orb representing the tutor.
struct TutorOrb: View {
    var active: Bool
    var size: CGFloat = 26
    @EnvironmentObject var settings: AppSettings
    @State private var pulse = false

    var body: some View {
        let tint = Color(hex: settings.tutorInkHex)
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [tint.opacity(0.7), tint], startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: tint.opacity(active ? 0.7 : 0.3), radius: active ? 6 : 2)
                .scaleEffect(active && pulse ? 1.1 : 1)
            Image(systemName: "sparkle")
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundStyle(.white)
                .rotationEffect(.degrees(active && pulse ? 180 : 0))
        }
        .frame(width: size, height: size)
        .onAppear { updateAnimation() }
        .onChange(of: active) { _, _ in updateAnimation() }
    }

    private func updateAnimation() {
        if active {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
        } else {
            withAnimation(.easeOut(duration: 0.3)) { pulse = false }
        }
    }
}

struct PenStylePicker: View {
    @Binding var selection: PenStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Pen").font(.headline).padding(.bottom, 6)
            ForEach(PenStyle.allCases) { style in
                Button {
                    selection = style
                } label: {
                    HStack {
                        Image(systemName: style.symbol).frame(width: 26)
                        Text(style.title)
                        Spacer()
                        if style == selection { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 240)
    }
}

/// A short line drawn at a pen width, scaled so the thickest preset fills the space.
struct WidthSwatch: View {
    let width: CGFloat
    let maxWidth: CGFloat
    var selected = false

    var body: some View {
        let h = 2 + 12 * min(1, width / max(maxWidth, 0.1))
        ZStack {
            if selected {
                RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.14))
            }
            Capsule().fill(Color.primary.opacity(0.85)).frame(width: 20, height: h)
        }
    }
}

/// The tool's three thickness presets, and a slider for the one in use.
@MainActor
struct WidthPicker: View {
    let tools: ToolState

    private var range: ClosedRange<CGFloat> { tools.kind == .highlighter ? 4...40 : 0.8...16 }
    private var width: CGFloat { tools.widths[safe: tools.widthIndex] ?? 3 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Thickness").font(.headline)
            HStack(spacing: 8) {
                ForEach(Array(tools.widths.enumerated()), id: \.offset) { i, w in
                    Button { tools.selectWidth(i) } label: {
                        WidthSwatch(width: w, maxWidth: tools.widths.max() ?? w, selected: i == tools.widthIndex)
                            .frame(width: 52, height: 36)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Thickness \(i + 1)")
                }
            }
            Slider(value: Binding(get: { width }, set: { tools.setWidth($0, at: tools.widthIndex) }), in: range)
            Text(String(format: "%.1f pt", width)).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Stroke or pixel erasing, and the pixel eraser's size.
@MainActor
struct EraserOptions: View {
    let tools: ToolState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Eraser").font(.headline)
            Picker("Eraser", selection: Binding(get: { tools.eraserMode }, set: { tools.eraserMode = $0 })) {
                Text("Whole Stroke").tag(EraserMode.stroke)
                Text("Pixel").tag(EraserMode.pixel)
            }
            .pickerStyle(.segmented)
            if tools.eraserMode == .pixel {
                HStack {
                    Text("Size").font(.subheadline)
                    Slider(value: Binding(get: { Double(tools.eraserWidth) }, set: { tools.eraserWidth = CGFloat($0) }), in: 4...80)
                }
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}

/// Everything about the current pen in one place, for narrow toolbars: its three colour slots, its
/// thickness, and the full palette for the slot in use.
@MainActor
struct InkOptionsPopover: View {
    let tools: ToolState
    @Binding var color: String
    var onEyedropper: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ForEach(0..<min(ToolState.visibleColorSlots, tools.colors.count), id: \.self) { i in
                    Button { tools.selectColor(i) } label: {
                        ColorSwatch(hex: tools.colors[safe: i] ?? "#1F2328", selected: i == tools.colorIndex)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Colour \(i + 1)")
                }
            }
            .padding([.horizontal, .top], 16)
            if tools.kind != .text {
                WidthPicker(tools: tools).padding([.horizontal, .top], 16)
            }
            ColorPalettePicker(hex: $color, highlighter: tools.kind == .highlighter, onEyedropper: onEyedropper)
        }
    }
}
