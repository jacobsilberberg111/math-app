import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Loads a note and shows the editor.
struct NoteEditorContainer: View {
    let meta: NoteMeta
    @State private var model: EditorModel?

    var body: some View {
        Group {
            if let model {
                NoteEditorView(model: model)
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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(LibraryStore.self) private var library
    @EnvironmentObject var settings: AppSettings
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showPDFImporter = false
    @State private var exportItem: ExportItem?

    struct ExportItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        VStack(spacing: 0) {
            EditorTopBar(model: model, onClose: close, onInsertPhoto: { showPhotoPicker = true },
                         onImportPDF: { showPDFImporter = true }, onExport: export)
            EditorToolStrip(model: model)
            HStack(spacing: 0) {
                canvasArea
                TutorSidePanel(model: model)
            }
            .overlay { TutorOverlayPanel(model: model) }
        }
        .background(Color(uiColor: .systemBackground))
        .onAppear {
            model.document.onMetaChanged = { [weak library] meta in library?.update(meta) }
            DemoDirector.shared.editorAppeared(model)
            if !settings.isTutorConfigured && !settings.hasSeenOnboarding { model.showTutor = true }
        }
        .onChange(of: scenePhase) { _, phase in
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
            Text("Allow Tutor Notes to use the microphone in Settings to record audio with your notes.")
        }
        .sheet(isPresented: $model.showPages) { PageNavigator(model: model) }
        .sheet(isPresented: $model.showPractice) { PracticeSheet(model: model) }
        .sheet(isPresented: $model.showPaper) { PaperPicker(model: model) }
        .sheet(item: $exportItem) { item in ShareSheet(items: [item.url]) }
        .statusBarHidden(false)
    }

    private var canvasArea: some View {
        GeometryReader { geo in
            let _ = DemoDirector.trace("canvas area width \(Int(geo.size.width))")
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
        case .offscreen(let page):
            model.canvas?.scrollToPage(page)
        }
        model.tutor.dismissSuggestion()
    }

    private func export() {
        if let url = PageRenderer.exportPDF(model.document) {
            exportItem = ExportItem(url: url)
        } else {
            model.flash("Couldn't export this note")
        }
    }

    private func close() {
        model.close(library: library)
        dismiss()
    }
}

// The tutor panel reads `showTutor` in views of its own. Read directly in NoteEditorView's body,
// the change didn't re-render the editor until something else did (the toolbar button lit up, but
// the panel stayed closed).

/// The tutor beside the canvas in regular width. It stays mounted while hidden, so a half-typed
/// question and the chat's scroll position survive closing it, and it slides in by widening.
private struct TutorSidePanel: View {
    @Bindable var model: EditorModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    private static let width: CGFloat = 392

    var body: some View {
        let _ = DemoDirector.trace("side panel body: showTutor \(model.showTutor), sizeClass \(String(describing: sizeClass))")
        if sizeClass != .compact {
            HStack(spacing: 0) {
                Divider()
                TutorPanel(model: model)
                    .frame(width: Self.width)
            }
            .frame(width: model.showTutor ? Self.width + 1 : 0, alignment: .leading)
            .background(GeometryReader { g in
                Color.clear.onChange(of: g.size.width) { _, w in DemoDirector.trace("side panel width \(Int(w))") }
            })
            .clipped()
            .allowsHitTesting(model.showTutor)
            .accessibilityHidden(!model.showTutor)
        }
    }
}

/// Too narrow for a side panel (Split View, Slide Over): the tutor covers the canvas.
private struct TutorOverlayPanel: View {
    @Bindable var model: EditorModel
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if model.showTutor && sizeClass == .compact {
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
