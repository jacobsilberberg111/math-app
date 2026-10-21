import SwiftUI
import PhotosUI

/// Top navigation row: back, title, undo/redo, pages, insert, record, share, tutor.
/// (Explicitly main-actor: with the iOS 17 SDK nothing here would infer it, and `commitTitle`
/// touches the main-actor model.)
@MainActor
struct EditorTopBar: View {
    @Bindable var model: EditorModel
    var onClose: () -> Void
    var onInsertPhoto: () -> Void
    var onImportPDF: () -> Void
    var onExport: () -> Void
    var onScan: (() -> Void)?
    /// Closes this note and opens another (from the back button's recent notes).
    var onSwitchNote: ((NoteMeta) -> Void)?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(LibraryStore.self) private var library
    @State private var editingTitle = false
    @State private var titleDraft = ""
    @FocusState private var titleFocused: Bool

    /// Narrow windows fold Pages and Export into the insert menu so the bar still fits.
    private var compact: Bool { sizeClass == .compact }

    private var isBoard: Bool { model.document.isFreeform }

    /// Other notes to jump to, most recent first.
    private var recentNotes: [NoteMeta] {
        Array(library.recentNotes.filter { $0.id != model.document.id }.prefix(8))
    }

    var body: some View {
        HStack(spacing: 6) {
            // Tap goes back home; press and hold to jump straight to another recent note.
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

            if editingTitle {
                TextField("Title", text: $titleDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
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
                            .font(.system(size: 17, weight: .semibold))
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        Text(isBoard ? "Freeform board" : "Page \(model.currentPage + 1) of \(model.pageCount)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 12)

            Group {
                BarButton(symbol: "arrow.uturn.backward", label: "Undo", enabled: model.canUndo) { model.undo() }
                BarButton(symbol: "arrow.uturn.forward", label: "Redo", enabled: model.canRedo) { model.redo() }
                if !compact {
                    Divider().frame(height: 22).padding(.horizontal, 4)
                    if isBoard {
                        BarButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Show Whole Board") { model.canvas?.zoomToShowAll() }
                    } else {
                        BarButton(symbol: "square.grid.2x2", label: "Pages") { model.showPages = true }
                    }
                    BarButton(symbol: "magnifyingglass", label: "Find in Note") { model.find.open() }
                        .keyboardShortcut("f", modifiers: .command)
                }
                if isBoard { BoardLinesMenu(document: model.document) }
                Menu {
                    Button { onInsertPhoto() } label: { Label("Photo", systemImage: "photo") }
                    if !isBoard {
                        Button { onImportPDF() } label: { Label("PDF Pages", systemImage: "doc.richtext") }
                    }
                    if let onScan, !isBoard, DocumentScanner.isAvailable {
                        Button { onScan() } label: { Label("Scan Pages", systemImage: "doc.viewfinder") }
                    }
                    Button { model.selectTool(.text) } label: { Label("Text Box", systemImage: "textformat") }
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
                        Button { model.showPaper = true } label: { Label("Paper Style", systemImage: "square.grid.3x3") }
                    }
                    if compact {
                        Divider()
                        if isBoard {
                            Button { model.canvas?.zoomToShowAll() } label: { Label("Show Whole Board", systemImage: "arrow.up.left.and.arrow.down.right") }
                        } else {
                            Button { model.showPages = true } label: { Label("Pages", systemImage: "square.grid.2x2") }
                        }
                        Button { model.find.open() } label: { Label("Find in Note", systemImage: "magnifyingglass") }
                        Button { onExport() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 40, height: 40)
                }
                .accessibilityLabel("Insert")
                RecordButton(audio: model.audio)
                if !compact {
                    BarButton(symbol: "square.and.arrow.up", label: "Export") { onExport() }
                }
            }
            TutorToggleButton(model: model, showsLabel: !compact)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
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

/// Switches a freeform board's background lines (and paper colour) in one tap.
struct BoardLinesMenu: View {
    let document: NoteDocument

    private var paper: PaperStyle { document.content.pages.first?.paper ?? .standard }

    var body: some View {
        Menu {
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
        } label: {
            Image(systemName: paper.pattern.symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 40, height: 40)
        }
        .accessibilityLabel("Background lines")
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

// MARK: - Tool strip

struct EditorToolStrip: View {
    @Bindable var model: EditorModel
    @EnvironmentObject var settings: AppSettings
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showPenStyles = false
    @State private var editingColorIndex: Int?
    @State private var editingWidthIndex: Int?

    var tools: ToolState { model.tools }

    var body: some View {
        Group {
            if sizeClass == .compact {
                // Narrow windows: the whole strip scrolls.
                ScrollView(.horizontal, showsIndicators: false) { strip(contextual) }
                    .scrollBounceBehavior(.basedOnSize)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Tools + colours + widths + toggles are wider than most iPads in portrait, so
                // the middle section scrolls rather than pushing the strip off both edges.
                strip(
                    ScrollView(.horizontal, showsIndicators: false) { contextual }
                        .scrollBounceBehavior(.basedOnSize)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func strip(_ middle: some View) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach([CanvasToolKind.pen, .highlighter, .eraser, .lasso, .text, .select], id: \.self) { kind in
                    toolButton(kind)
                }
                Divider().frame(height: 24).padding(.horizontal, 4)
                tutorToolButton
                hintButton
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.secondary.opacity(0.08)))
            // Apple Pencil double-tap ("Show colour palette") and squeeze ("Tool palette") land here.
            .popover(isPresented: $model.palettePresented) {
                ColorPalettePicker(hex: Binding(get: { tools.colors[safe: tools.colorIndex] ?? "#1F2328" },
                                                set: { tools.setColor($0, at: tools.colorIndex) }),
                                   highlighter: tools.kind == .highlighter,
                                   onEyedropper: { model.startEyedropper() })
                    .presentationCompactAdaptation(.popover)
            }

            middle

            HStack(spacing: 2) {
                ToggleIcon(symbol: "ruler", isOn: tools.rulerActive, label: "Ruler") { tools.rulerActive.toggle() }
                ToggleIcon(symbol: "scribble.variable", isOn: settings.shapeRecognition, label: "Shape recognition") {
                    settings.shapeRecognition.toggle()
                    model.flash(settings.shapeRecognition ? "Draw and hold to snap shapes" : "Shape recognition off")
                }
                ToggleIcon(symbol: "hand.draw", isOn: settings.fingerDrawing, label: "Draw with finger") {
                    settings.fingerDrawing.toggle()
                    model.flash(settings.fingerDrawing ? "Finger drawing on" : "Pencil only · fingers scroll")
                }
            }
        }
    }

    @ViewBuilder
    private func toolButton(_ kind: CanvasToolKind) -> some View {
        let selected = tools.kind == kind
        Button {
            if kind == .pen && selected {
                showPenStyles = true
            } else {
                model.selectTool(kind)
            }
        } label: {
            ZStack(alignment: .bottom) {
                Image(systemName: kind == .pen ? tools.penStyle.symbol : kind.symbol)
                    .font(.system(size: 19, weight: selected ? .semibold : .regular))
                    .frame(width: 42, height: 38)
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
                if kind == .pen || kind == .highlighter {
                    let hex = kind == .pen ? (tools.penColors[safe: tools.penColorIndex] ?? "#000000") : (tools.highlighterColors[safe: tools.highlighterColorIndex] ?? "#FFE066")
                    Capsule().fill(Color(hex: hex)).frame(width: 18, height: 3).offset(y: -1)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Color.accentColor.opacity(0.14) : .clear))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind.title)
        .popover(isPresented: Binding(get: { kind == .pen && showPenStyles }, set: { showPenStyles = $0 })) {
            PenStylePicker(selection: Binding(get: { tools.penStyle }, set: { tools.penStyle = $0; showPenStyles = false }))
                .presentationCompactAdaptation(.popover)
        }
    }

    private var tutorToolButton: some View {
        let selected = tools.kind == .tutor
        let tint = Color(hex: settings.tutorInkHex)
        return Button {
            model.selectTool(selected ? tools.lastDrawingKind : .tutor)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                Text("Ask").font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(selected ? .white : tint)
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? tint : tint.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ask tutor about an area")
    }

    private var hintButton: some View {
        let tint = Color(hex: settings.tutorInkHex)
        return Button {
            model.giveHint()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "lightbulb")
                    .font(.system(size: 16, weight: .semibold))
                Text("Hint").font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .disabled(model.tutor.isBusy)
        .opacity(model.tutor.isBusy ? 0.45 : 1)
        .accessibilityLabel("Give me a hint")
        .accessibilityHint("Your tutor leaves a small nudge beside your latest working, without giving the answer")
    }

    @ViewBuilder
    private var contextual: some View {
        switch tools.kind {
        case .pen, .highlighter, .text:
            HStack(spacing: 14) {
                HStack(spacing: 8) {
                    ForEach(Array(tools.colors.enumerated()), id: \.offset) { i, hex in
                        colorDot(i, hex)
                    }
                }
                if tools.kind != .text {
                    Divider().frame(height: 22)
                    HStack(spacing: 6) {
                        ForEach(Array(tools.widths.enumerated()), id: \.offset) { i, w in
                            widthDot(i, w)
                        }
                    }
                }
            }
        case .eraser:
            HStack(spacing: 12) {
                Picker("Eraser", selection: Binding(get: { tools.eraserMode }, set: { tools.eraserMode = $0 })) {
                    Text("Stroke").tag(EraserMode.stroke)
                    Text("Pixel").tag(EraserMode.pixel)
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
                if tools.eraserMode == .pixel {
                    Slider(value: Binding(get: { Double(tools.eraserWidth) }, set: { tools.eraserWidth = CGFloat($0) }), in: 4...80)
                        .frame(width: 140)
                }
            }
        case .lasso:
            hint("Circle ink to select it, then drag to move or tap for options")
        case .select:
            hint("Tap anything to select it · drag to move · long-press works in any tool")
        case .tutor:
            hint("Drag around anything — or tap it — to ask your tutor about it", tint: Color(hex: settings.tutorInkHex))
        }
    }

    private func hint(_ text: String, tint: Color = .secondary) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private func colorDot(_ i: Int, _ hex: String) -> some View {
        let selected = i == tools.colorIndex
        return Button {
            if selected { editingColorIndex = i } else { tools.selectColor(i) }
        } label: {
            ZStack {
                Circle().fill(Color(hex: hex)).frame(width: 24, height: 24)
                Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1).frame(width: 24, height: 24)
                if selected {
                    Circle().strokeBorder(Color.accentColor, lineWidth: 2.5).frame(width: 32, height: 32)
                }
            }
            .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Colour \(i + 1)")
        .popover(isPresented: Binding(get: { editingColorIndex == i }, set: { if !$0 { editingColorIndex = nil } })) {
            ColorPalettePicker(hex: Binding(get: { tools.colors[safe: i] ?? hex }, set: { tools.setColor($0, at: i) }),
                               highlighter: tools.kind == .highlighter,
                               onEyedropper: { editingColorIndex = nil; model.startEyedropper() })
                .presentationCompactAdaptation(.popover)
        }
    }

    private func widthDot(_ i: Int, _ w: CGFloat) -> some View {
        let selected = i == tools.widthIndex
        let maxW = tools.widths.max() ?? 1
        let d = 6 + 14 * (w / max(maxW, 1))
        return Button {
            if selected { editingWidthIndex = i } else { tools.selectWidth(i) }
        } label: {
            ZStack {
                if selected {
                    RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.14)).frame(width: 32, height: 32)
                }
                Circle().fill(Color.primary.opacity(0.85)).frame(width: d, height: d)
            }
            .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Width \(i + 1)")
        .popover(isPresented: Binding(get: { editingWidthIndex == i }, set: { if !$0 { editingWidthIndex = nil } })) {
            WidthEditor(width: Binding(get: { tools.widths[safe: i] ?? w }, set: { tools.setWidth($0, at: i) }),
                        range: tools.kind == .highlighter ? 4...40 : 0.8...16,
                        colorHex: tools.colors[safe: tools.colorIndex] ?? "#1F2328")
                .presentationCompactAdaptation(.popover)
        }
    }
}

struct ToggleIcon: View {
    let symbol: String
    let isOn: Bool
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 9).fill(isOn ? Color.accentColor.opacity(0.13) : .clear))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
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

struct WidthEditor: View {
    @Binding var width: CGFloat
    var range: ClosedRange<CGFloat>
    var colorHex: String

    var body: some View {
        VStack(spacing: 14) {
            Text("Thickness").font(.headline)
            Capsule().fill(Color(hex: colorHex)).frame(width: 160, height: max(1, width))
                .frame(height: 44)
            Slider(value: $width, in: range)
            Text(String(format: "%.1f pt", width)).font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 240)
    }
}
