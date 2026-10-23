import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Loads a note and shows the editor.
/// Something for the tutor to start on as soon as the note opens.
struct EditorStartRequest: Equatable {
    var prompt: String
    var displayText: String
}

struct NoteEditorContainer: View {
    let meta: NoteMeta
    /// Opens another note in place of this one (the editor has already closed this one).
    var onSwitchNote: ((NoteMeta) -> Void)?
    var startRequest: EditorStartRequest?
    @State private var model: EditorModel?

    var body: some View {
        Group {
            if let model {
                NoteEditorView(model: model, onSwitchNote: onSwitchNote, startRequest: startRequest)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            if model == nil {
                model = EditorModel(document: NoteEditorContainer.load(meta))
            }
        }
    }

    /// Saves are written on the io queue: let any pending ones land first (a note that was just
    /// created, imported or closed) so we don't read back stale or missing files.
    @MainActor
    private static func load(_ meta: NoteMeta) -> NoteDocument {
        Storage.ioQueue.sync {}
        return NoteDocument.load(meta: meta)
    }
}

struct NoteEditorView: View {
    @Bindable var model: EditorModel
    var onSwitchNote: ((NoteMeta) -> Void)?
    var startRequest: EditorStartRequest?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(LibraryStore.self) private var library
    @EnvironmentObject var settings: AppSettings
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showPDFImporter = false
    @State private var showScanner = false
    /// Mirror of model.showTutor that the panel layout reads (see onAppear).
    @State private var panelShown = false
    @State private var exportItem: ExportItem?

    struct ExportItem: Identifiable {
        let id = UUID()
        let urls: [URL]
    }

    var body: some View {
        VStack(spacing: 0) {
            EditorTopBar(model: model, onClose: close, onInsertPhoto: { showPhotoPicker = true },
                         onImportPDF: { showPDFImporter = true }, onExport: export, onScan: { showScanner = true },
                         onSwitchNote: onSwitchNote.map { open in { (meta: NoteMeta) in switchTo(meta, open) } })
            PaperBar(model: model)
            FindBar(find: model.find)
            HStack(spacing: 0) {
                canvasArea
                TutorSidePanel(model: model, shown: panelShown)
            }
            .overlay { TutorOverlayPanel(model: model, shown: panelShown) }
        }
        .background(Color(uiColor: .systemBackground))
        .onAppear {
            // The panel follows showTutor through plain view state. Observing showTutor directly
            // from the layout intermittently missed a change while the canvas was busy (the
            // toolbar button lit up but the panel stayed shut), so the model pushes it here.
            panelShown = model.showTutor
            model.onShowTutorChanged = { shown in panelShown = shown }
            model.document.onMetaChanged = { [weak library] meta in library?.update(meta) }
            DemoDirector.shared.editorAppeared(model)
            model.resumeStudyClock()
            model.paperAppeared()
            if let startRequest, !model.handledStartRequest {
                model.handledStartRequest = true
                model.showPanelIfNoKey()
                if settings.isTutorConfigured {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { model.showTutor = true }
                }
                model.tutor.send(startRequest.prompt, displayText: startRequest.displayText)
            }
            if !settings.isTutorConfigured && !settings.hasSeenOnboarding { model.showTutor = true }
        }
        .onDisappear { model.onShowTutorChanged = nil }
        .onChange(of: scenePhase) { old, phase in
            // Only leaving .active counts what came before (active → inactive → background).
            if phase == .active { model.resumeStudyClock() } else if old == .active { model.pauseStudyClock() }
            if phase != .active {
                model.tutor.saveNow()
                // Only when something changed: saving stamps the note's modified date.
                if model.document.isDirty { model.document.saveNow() }
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    model.canvas?.insertImage(img)
                }
                photoItem = nil
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .fileImporter(isPresented: $showPDFImporter, allowedContentTypes: [.pdf]) { result in
            guard case .success(let url) = result else { return }
            if let asset = model.document.storePDF(from: url) {
                model.document.importPDFPages(assetID: asset, replaceFirstBlankPage: true)
                // The import may have replaced a blank first page, so find where its pages landed.
                if let first = model.document.content.pages.firstIndex(where: { $0.pdfAssetID == asset }) {
                    model.canvas?.scrollToPage(first)
                    return
                }
            }
            model.flash("Couldn't import that PDF")
        }
        .alert("Microphone access is off", isPresented: Binding(get: { model.audio.permissionDenied },
                                                                set: { model.audio.permissionDenied = $0 })) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Allow Margin to use the microphone in Settings to record audio with your notes.")
        }
        .sheet(isPresented: $model.showPages) { PageNavigator(model: model) }
        .sheet(isPresented: $model.showPractice) { PracticeSheet(model: model) }
        .sheet(isPresented: $model.showPaper) { PaperPicker(model: model) }
        .sheet(isPresented: $model.showPaperQuestions) { PaperQuestionsSheet(model: model) }
        .fullScreenCover(isPresented: $showScanner) {
            DocumentScanner(onFinish: { pages in
                showScanner = false
                addScannedPages(pages)
            }, onCancel: { showScanner = false })
            .ignoresSafeArea()
        }
        .sheet(item: $exportItem) { item in ShareSheet(items: item.urls) }
        .sheet(item: $model.inkConversion) { InkConversionSheet(conversion: $0, model: model).environmentObject(settings) }
        .noteFileArrival(switchTo: { meta in if let onSwitchNote { switchTo(meta, onSwitchNote) } }, flash: { model.flash($0) })
        .statusBarHidden(false)
    }

    private var canvasArea: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                CanvasRepresentable(model: model, config: model.tools.config(settings: settings))
                    .ignoresSafeArea(.container, edges: .bottom)

                TutorStatusPill(model: model)
                    .padding(.top, 10)
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.tutor.isBusy || model.tutor.isObserving)

                if let toast = model.toast {
                    ToastView(text: toast)
                        .padding(.top, model.tutor.isBusy || model.tutor.isObserving ? 56 : 14)
                }

                if let request = model.quickMenu {
                    QuickMenuView(request: request, model: model)
                        .position(QuickMenuView.position(for: request.anchor, in: geo.size))
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                }

                VStack(spacing: 10) {
                    Spacer()
                    if let s = model.tutor.suggestion {
                        SuggestionPill(suggestion: s, action: { handle(s) }, dismiss: { model.tutor.dismissSuggestion() })
                    }
                    if model.audio.isRecording || (model.audio.showsPlayer && model.audio.activeRecording != nil) {
                        AudioBar(audio: model.audio)
                    }
                    if model.document.isFreeform && !panelShown {
                        BoardTutorBar(model: model)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.bottom, 18)
                .padding(.horizontal, 16)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.tutor.suggestion)
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.86), value: model.quickMenu)
            .animation(.easeInOut(duration: 0.2), value: model.toast)
        }
    }

    private func handle(_ s: TutorSuggestion) {
        switch s {
        case .stuck(_, let elementID):
            if let e = model.document.element(elementID) { model.tutor.revealHint(for: e) }
        case .offscreen(let page, let docRect, let onBoard):
            if onBoard { model.canvas?.scrollToReveal(docRect) } else { model.canvas?.scrollToPage(page) }
        }
        model.tutor.dismissSuggestion()
    }

    /// Scanned pages go after the note's pages, ready to write on.
    private func addScannedPages(_ pages: [Data]) {
        guard let url = DocumentScanner.pdf(from: pages, name: "Scan"),
              let asset = model.document.storePDF(from: url) else {
            model.flash("Couldn't add the scan")
            return
        }
        model.document.importPDFPages(assetID: asset, replaceFirstBlankPage: true)
        if let first = model.document.content.pages.firstIndex(where: { $0.pdfAssetID == asset }) {
            model.canvas?.scrollToPage(first)
        }
        model.flash("Added \(pages.count) page\(pages.count == 1 ? "" : "s")")
    }

    /// Files go to the share sheet (AirDrop, Files, Mail…); Print opens the print dialog.
    private func export(_ kind: ExportKind) {
        model.document.saveNow()
        // A long note takes a moment: say so, and let the menu close before the work starts.
        if model.pageCount > 6 { model.flash("Preparing \(model.pageCount) pages…") }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            finishExport(kind)
        }
    }

    private func finishExport(_ kind: ExportKind) {
        guard let urls = NoteExporter.files(for: kind, document: model.document) else {
            model.flash("Couldn't export this note")
            return
        }
        if kind == .print {
            if !NoteExporter.printPDF(urls[0], jobName: model.document.meta.title) { model.flash("Couldn't print this note") }
        } else {
            exportItem = ExportItem(urls: urls)
        }
    }

    private func close() {
        model.close(library: library)
        dismiss()
    }

    private func switchTo(_ meta: NoteMeta, _ open: (NoteMeta) -> Void) {
        model.close(library: library)
        open(meta)
    }
}

/// The tutor beside the canvas in regular width. It stays mounted while hidden, so a half-typed
/// question and the chat's scroll position survive closing it, and it slides in by widening.
private struct TutorSidePanel: View {
    @Bindable var model: EditorModel
    let shown: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass
    private static let width: CGFloat = 392

    var body: some View {
        if sizeClass != .compact {
            HStack(spacing: 0) {
                Divider()
                TutorPanel(model: model)
                    .frame(width: Self.width)
            }
            .frame(width: shown ? Self.width + 1 : 0, alignment: .leading)
            .clipped()
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
        }
    }
}

/// Too narrow for a side panel (Split View, Slide Over): the tutor covers the canvas.
private struct TutorOverlayPanel: View {
    @Bindable var model: EditorModel
    let shown: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if shown && sizeClass == .compact {
            TutorPanel(model: model)
                .transition(.move(edge: .trailing))
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
