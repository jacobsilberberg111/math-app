import SwiftUI
import UniformTypeIdentifiers

enum LibrarySelection: Hashable {
    case home
    case all
    case unfiled
    case subject(UUID)
}

struct LibraryView: View {
    @Environment(LibraryStore.self) private var library
    @EnvironmentObject var settings: AppSettings
    @State private var selection: LibrarySelection? = .home
    @State private var search = ""
    @State private var sort: LibrarySort = .modified
    @State private var openNote: NoteMeta?
    @State private var showSettings = false
    @State private var showPDFImporter = false
    @State private var showNoteImporter = false
    @State private var renaming: NoteMeta?
    @State private var renameText = ""
    @State private var newSubjectName = ""
    @State private var showNewSubject = false
    @State private var editingSubject: Subject?
    @State private var pendingDelete: NoteMeta?
    @State private var showOnboarding = false
    @State private var importFailed = false
    @State private var showPastPaper = false
    @State private var showScanner = false
    @State private var showFlashcards = false
    /// Something for the tutor to do as soon as a note opens (e.g. practise weak spots).
    @State private var startRequest: (noteID: UUID, request: EditorStartRequest)?

    var currentSubjectID: UUID? {
        if case .subject(let id) = selection { return id }
        return nil
    }

    var visibleNotes: [NoteMeta] {
        switch selection ?? .home {
        case .home, .all: return library.notes(in: nil, search: search, sort: sort)
        case .unfiled: return library.notes(in: nil, unfiledOnly: true, search: search, sort: sort)
        case .subject(let id): return library.notes(in: id, search: search, sort: sort)
        }
    }

    var title: String {
        switch selection ?? .home {
        case .home: return HomeView.greeting
        case .all: return "All Notes"
        case .unfiled: return "Unfiled"
        case .subject(let id): return library.subject(id)?.name ?? "Notes"
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            NavigationStack {
                Group {
                    if (selection ?? .home) == .home && search.trimmed.isEmpty {
                        HomeView(open: open, newNotebook: { createNote(defaultPaper) }, newBoard: { createBoard(title: nil) },
                                 askTutor: { createBoard(title: "Question") }, importPDF: { showPDFImporter = true },
                                 pastPaper: { showPastPaper = true },
                                 scan: DocumentScanner.isAvailable ? { showScanner = true } : nil,
                                 reviewCards: { showFlashcards = true },
                                 practiseWeakSpots: practiseWeakSpots,
                                 showAll: { selection = .all }, showSubject: { selection = .subject($0) })
                    } else {
                        grid
                    }
                }
                .navigationTitle(title)
                .searchable(text: $search, prompt: "Search titles and handwriting")
                .toolbar { toolbar }
            }
        }
        .fullScreenCover(item: $openNote) { meta in
            NoteEditorContainer(meta: meta, onSwitchNote: switchTo,
                                startRequest: startRequest?.noteID == meta.id ? startRequest?.request : nil)
                .environment(library)
                .environmentObject(settings)
        }
        .onChange(of: openNote?.id) { _, id in
            // The request belongs to the note it was made for; switching away drops it.
            if id != startRequest?.noteID { startRequest = nil }
        }
        .sheet(isPresented: $showPastPaper) {
            PastPaperSetupView(subjectID: currentSubjectID) { meta in openAfterSheet(meta) }
                .environment(library)
        }
        .sheet(isPresented: $showFlashcards) {
            FlashcardsView().environmentObject(settings)
        }
        .fullScreenCover(isPresented: $showScanner) {
            DocumentScanner(onFinish: { pages in
                showScanner = false
                guard let url = DocumentScanner.pdf(from: pages, name: "Scan \(LibraryView.stamp)"),
                      let meta = library.createNote(fromPDF: url, subjectID: currentSubjectID) else {
                    // After the scanner has gone, or the alert is dropped.
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        importFailed = true
                    }
                    return
                }
                openAfterSheet(meta)
            }, onCancel: { showScanner = false })
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showOnboarding) { OnboardingView() }
        .fileImporter(isPresented: $showPDFImporter, allowedContentTypes: [.pdf]) { result in
            guard case .success(let url) = result else { return }
            if let meta = library.createNote(fromPDF: url, subjectID: currentSubjectID) {
                open(meta)
            } else {
                importFailed = true
            }
        }
        .alert("Couldn't import that PDF", isPresented: $importFailed) {
            Button("OK", role: .cancel) {}
        }
        .noteFileImport(isPresented: $showNoteImporter, canOpen: openNote == nil, open: open)
        .alert("Rename Note", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Rename") { if let r = renaming { library.rename(r, to: renameText) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("New Subject", isPresented: $showNewSubject) {
            TextField("Name", text: $newSubjectName)
            Button("Create") { library.addSubject(name: newSubjectName); newSubjectName = "" }
            Button("Cancel", role: .cancel) { newSubjectName = "" }
        }
        .alert("Rename Subject", isPresented: Binding(get: { editingSubject != nil }, set: { if !$0 { editingSubject = nil } })) {
            TextField("Name", text: $newSubjectName)
            Button("Save") { if let s = editingSubject { library.renameSubject(s, to: newSubjectName) }; editingSubject = nil; newSubjectName = "" }
            Button("Cancel", role: .cancel) { editingSubject = nil; newSubjectName = "" }
        }
        .confirmationDialog("Delete this note?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let n = pendingDelete { library.delete(n) }; pendingDelete = nil }
        } message: {
            Text("The note, its recordings and its tutor conversation will be deleted.")
        }
        .onAppear {
            DemoDirector.shared.libraryAppeared(library: library, open: { open($0) }, close: { openNote = nil },
                                                newBoard: { createBoard(title: $0) }, flashcards: { showFlashcards = $0 })
            if !settings.hasSeenOnboarding { showOnboarding = true }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                Label("Home", systemImage: "house").tag(LibrarySelection.home)
                Label("All Notes", systemImage: "tray.full").tag(LibrarySelection.all)
                    .badge(library.notes.count)
                Label("Unfiled", systemImage: "tray").tag(LibrarySelection.unfiled)
            }
            Section("Subjects") {
                ForEach(library.subjects) { subject in
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 4).fill(Color(hex: subject.colorHex)).frame(width: 14, height: 18)
                        Text(subject.name)
                        Spacer()
                        Text("\(library.notes.filter { $0.subjectID == subject.id }.count)").foregroundStyle(.secondary).font(.callout)
                    }
                    .tag(LibrarySelection.subject(subject.id))
                    .contextMenu {
                        Button { newSubjectName = subject.name; editingSubject = subject } label: { Label("Rename", systemImage: "pencil") }
                        Menu {
                            // Menus ignore .tint and draw symbols as templates, so name each colour and
                            // bake the colour into the icon image.
                            ForEach(Subject.palette, id: \.self) { hex in
                                Button { library.recolorSubject(subject, hex: hex) } label: {
                                    Label {
                                        Text(LibraryView.colourNames[hex] ?? hex)
                                    } icon: {
                                        Image(uiImage: LibraryView.swatch(hex, current: hex == subject.colorHex))
                                    }
                                }
                            }
                        } label: { Label("Colour", systemImage: "paintpalette") }
                        Button(role: .destructive) {
                            library.deleteSubject(subject)
                            if selection == .subject(subject.id) { selection = .home }
                        } label: { Label("Delete Subject", systemImage: "trash") }
                    }
                }
                Button {
                    showNewSubject = true
                } label: {
                    Label("New Subject", systemImage: "plus")
                }
            }
        }
        .navigationTitle("Tutor Notes")
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
            }
        }
    }

    // MARK: Grid

    private var grid: some View {
        ScrollView {
            if visibleNotes.isEmpty {
                ContentUnavailableView {
                    Label(search.isEmpty ? "No notes yet" : "No results", systemImage: search.isEmpty ? "square.and.pencil" : "magnifyingglass")
                } description: {
                    Text(search.isEmpty ? "Create a note to start writing, or import a PDF worksheet." : "Nothing matches “\(search)”.")
                } actions: {
                    if search.isEmpty {
                        HStack {
                            Button("New Notebook") { createNote(defaultPaper) }
                                .buttonStyle(.borderedProminent)
                            Button("New Board") { createBoard(title: nil) }
                                .buttonStyle(.bordered)
                        }
                    }
                }
                .padding(.top, 80)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 26)], spacing: 30) {
                ForEach(visibleNotes) { meta in
                    NoteCard(meta: meta, subject: library.subject(meta.subjectID))
                        .onTapGesture { open(meta) }
                        .contextMenu { contextMenu(for: meta) }
                }
            }
            .padding(24)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    @ViewBuilder
    private func contextMenu(for meta: NoteMeta) -> some View {
        Button { renameText = meta.title; renaming = meta } label: { Label("Rename", systemImage: "pencil") }
        Menu {
            Button { library.move(meta, to: nil) } label: { Label("Unfiled", systemImage: "tray") }
            ForEach(library.subjects) { s in
                Button { library.move(meta, to: s.id) } label: { Label(s.name, systemImage: meta.subjectID == s.id ? "checkmark" : "folder") }
            }
        } label: { Label("Move to", systemImage: "folder") }
        Button { library.duplicate(meta) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        Divider()
        Button(role: .destructive) { pendingDelete = meta } label: { Label("Delete", systemImage: "trash") }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if selection != .home {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }
            Button { showPDFImporter = true } label: { Label("Import PDF", systemImage: "doc.badge.arrow.up") }
            Menu {
                Button { createBoard(title: nil) } label: { Label("Freeform Board", systemImage: "scribble.variable") }
                Button { showPastPaper = true } label: { Label("Past Paper…", systemImage: "doc.text.magnifyingglass") }
                Button { showNoteImporter = true } label: { Label("Import Note File…", systemImage: "square.and.arrow.down") }
                if DocumentScanner.isAvailable {
                    Button { showScanner = true } label: { Label("Scan Document", systemImage: "doc.viewfinder") }
                }
                Section("Notebook") {
                    ForEach([PaperPattern.ruled, .grid, .dots, .blank, .graph, .cornell]) { p in
                        Button { createNote(PaperStyle(pattern: p, color: settings.defaultPaperColor)) } label: { Text(p.title) }
                    }
                }
            } label: {
                Label("New Note", systemImage: "square.and.pencil")
            } primaryAction: {
                createNote(defaultPaper)
            }
        }
    }

    private var defaultPaper: PaperStyle { PaperStyle(pattern: settings.defaultPattern, color: settings.defaultPaperColor) }

    private static var stamp: String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f.string(from: Date())
    }

    private func createNote(_ paper: PaperStyle) {
        open(library.createNote(title: "Note \(LibraryView.stamp)", subjectID: currentSubjectID, paper: paper))
    }

    private func createBoard(title: String?) {
        open(library.createNote(title: "\(title ?? "Board") \(LibraryView.stamp)", subjectID: currentSubjectID, paper: defaultPaper, layout: .freeform))
    }

    /// Every way into a note goes through here, so Home knows what was opened last.
    private func open(_ meta: NoteMeta) {
        openNote = library.markOpened(meta)
    }

    /// Opens a note once a sheet or the scanner has finished going away (presenting during a
    /// dismissal is dropped).
    private func openAfterSheet(_ meta: NoteMeta) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 550_000_000)
            open(meta)
        }
    }

    /// A fresh notebook where the tutor sets questions on the topics that have gone worst lately.
    private func practiseWeakSpots(_ topics: [TopicStat]) {
        let names = topics.map(\.topic)
        let meta = library.createNote(title: "Weak spots \(LibraryView.stamp)", subjectID: topics.first?.subjectID ?? currentSubjectID,
                                      paper: PaperStyle(pattern: .ruled, color: settings.defaultPaperColor))
        let prompt = "Give me practice on what I've found hard lately: \(names.joined(separator: ", ")). Make 5 questions with add_question, easier to harder, mixing the topics (accurate hidden answers and solutions). Start each topic's first question with a one-line reminder of the key idea, written above it."
        startRequest = (meta.id, EditorStartRequest(prompt: prompt, displayText: "Practise my weak spots"))
        open(meta)
    }

    /// From the editor's recent-notes menu: the editor has closed its note. Giving the cover a
    /// different item dismisses it and presents the new note.
    private func switchTo(_ meta: NoteMeta) {
        open(meta)
    }

    static let colourNames = ["#5B5BD6": "Indigo", "#E5484D": "Red", "#30A46C": "Green", "#F76B15": "Orange",
                              "#0090FF": "Blue", "#8E4EC6": "Purple", "#D6409F": "Pink", "#12A594": "Teal"]

    static func swatch(_ hex: String, current: Bool) -> UIImage {
        let image = UIImage(systemName: current ? "checkmark.circle.fill" : "circle.fill") ?? UIImage()
        return image.withTintColor(UIColor(hex: hex), renderingMode: .alwaysOriginal)
    }
}

struct NoteCard: View {
    let meta: NoteMeta
    let subject: Subject?
    @Environment(LibraryStore.self) private var library

    var body: some View {
        let _ = library.thumbnailVersion
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let img = library.thumbnail(for: meta) {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else {
                        ZStack {
                            Color.white
                            PaperSwatch(style: meta.paper ?? .standard).opacity(0.8)
                        }
                    }
                }
                .frame(height: 230)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.black.opacity(0.06)))
                .shadow(color: .black.opacity(0.1), radius: 6, y: 3)

                HStack(spacing: 4) {
                    if meta.isFreeform { badge("scribble.variable") }
                    if meta.isPastPaper { badge("doc.text.magnifyingglass") }
                    if meta.hasTutorSession { badge("sparkles") }
                    if meta.hasAudio { badge("waveform") }
                }
                .padding(8)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(meta.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                HStack(spacing: 6) {
                    if let subject {
                        Circle().fill(Color(hex: subject.colorHex)).frame(width: 7, height: 7)
                        Text(subject.name).lineLimit(1)
                        Text("·")
                    }
                    Text(meta.modifiedAt.shortRelative)
                    if let score = meta.paperScore {
                        Text("· \(score)")
                    } else {
                        Text(meta.isFreeform ? "· Board" : "· \(meta.pageCount) pg")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private func badge(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Circle().fill(Color.black.opacity(0.45)))
    }
}

struct OnboardingView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // Scrolls so it still fits in a form-size sheet, in landscape, and with the keyboard up.
        ScrollView {
            content.padding(36)
        }
        .safeAreaInset(edge: .bottom) {
            Button { finish() } label: {
                Text(settings.isTutorConfigured ? "Get started" : "Continue without the tutor for now").frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 36)
            .padding(.top, 12)
            .padding(.bottom, 28)
            .background(Color(uiColor: .systemBackground))
        }
        .interactiveDismissDisabled()
    }

    private func finish() {
        settings.hasSeenOnboarding = true
        dismiss()
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                TutorOrb(active: true, size: 44)
                VStack(alignment: .leading) {
                    Text("Tutor Notes").font(.largeTitle.bold())
                    Text("Notes with a tutor who works on the page with you.").foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                row("pencil.tip", "Write naturally", "Apple Pencil draws, fingers scroll. Draw a shape and hold to snap it perfect. Two-finger tap to undo.")
                row("sparkles", "Ask about anything", "Tap Ask and drag around your working — check it, get a hint, see the next step.")
                row("eye", "It watches as you work", "Pause, and your tutor glances at the page: it circles slips and marks finished answers.")
                row("chart.xyaxis.line", "Real math on the page", "Typeset algebra, graphs with asymptotes and shading, number lines, tables and diagrams.")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Connect your tutor").font(.headline)
                ConnectionForm()
                Text("You can change this later in Settings.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Color(hex: settings.tutorInkHex)).frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}
