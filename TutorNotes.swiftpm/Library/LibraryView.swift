import SwiftUI
import UniformTypeIdentifiers

enum LibrarySelection: Hashable {
    case all
    case unfiled
    case subject(UUID)
}

struct LibraryView: View {
    @Environment(LibraryStore.self) private var library
    @EnvironmentObject var settings: AppSettings
    @State private var selection: LibrarySelection? = .all
    @State private var search = ""
    @State private var sort: LibrarySort = .modified
    @State private var openNote: NoteMeta?
    @State private var showSettings = false
    @State private var showPDFImporter = false
    @State private var renaming: NoteMeta?
    @State private var renameText = ""
    @State private var newSubjectName = ""
    @State private var showNewSubject = false
    @State private var editingSubject: Subject?
    @State private var pendingDelete: NoteMeta?
    @State private var showOnboarding = false

    var currentSubjectID: UUID? {
        if case .subject(let id) = selection { return id }
        return nil
    }

    var visibleNotes: [NoteMeta] {
        switch selection ?? .all {
        case .all: return library.notes(in: nil, search: search, sort: sort)
        case .unfiled: return library.notes(in: nil, unfiledOnly: true, search: search, sort: sort)
        case .subject(let id): return library.notes(in: id, search: search, sort: sort)
        }
    }

    var title: String {
        switch selection ?? .all {
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
                grid
                    .navigationTitle(title)
                    .searchable(text: $search, prompt: "Search titles and handwriting")
                    .toolbar { toolbar }
            }
        }
        .fullScreenCover(item: $openNote) { meta in
            NoteEditorContainer(meta: meta)
                .environment(library)
                .environmentObject(settings)
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showOnboarding) { OnboardingView() }
        .fileImporter(isPresented: $showPDFImporter, allowedContentTypes: [.pdf]) { result in
            if case .success(let url) = result, let meta = library.createNote(fromPDF: url, subjectID: currentSubjectID) {
                openNote = meta
            }
        }
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
            if !settings.hasSeenOnboarding { showOnboarding = true }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
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
                            ForEach(Subject.palette, id: \.self) { hex in
                                Button { library.recolorSubject(subject, hex: hex) } label: {
                                    Label(hex == subject.colorHex ? "Current" : " ", systemImage: "circle.fill")
                                }
                                .tint(Color(hex: hex))
                            }
                        } label: { Label("Colour", systemImage: "paintpalette") }
                        Button(role: .destructive) { library.deleteSubject(subject); selection = .all } label: { Label("Delete Subject", systemImage: "trash") }
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
                        Button("New Note") { createNote(PaperStyle(pattern: settings.defaultPattern, color: settings.defaultPaperColor)) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.top, 80)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 26)], spacing: 30) {
                ForEach(visibleNotes) { meta in
                    NoteCard(meta: meta, subject: library.subject(meta.subjectID))
                        .onTapGesture { openNote = meta }
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
            Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            Button { showPDFImporter = true } label: { Label("Import PDF", systemImage: "doc.badge.arrow.up") }
            Menu {
                ForEach([PaperPattern.ruled, .grid, .dots, .blank, .graph, .cornell]) { p in
                    Button { createNote(PaperStyle(pattern: p, color: settings.defaultPaperColor)) } label: { Text(p.title) }
                }
            } label: {
                Label("New Note", systemImage: "square.and.pencil")
            } primaryAction: {
                createNote(PaperStyle(pattern: settings.defaultPattern, color: settings.defaultPaperColor))
            }
        }
    }

    private func createNote(_ paper: PaperStyle) {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        let meta = library.createNote(title: "Note \(f.string(from: Date()))", subjectID: currentSubjectID, paper: paper)
        openNote = meta
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
                    Text("· \(meta.pageCount) pg")
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
    @State private var key = ""

    var body: some View {
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
                Text("Anthropic API key").font(.headline)
                SecureField("sk-ant-…", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text("Get one at console.anthropic.com. It's kept in the Keychain on this iPad and only sent to api.anthropic.com. You can add it later in Settings.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                if !key.trimmed.isEmpty { settings.apiKey = key.trimmed }
                settings.hasSeenOnboarding = true
                dismiss()
            } label: {
                Text(key.trimmed.isEmpty ? "Continue without a key" : "Get started").frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(36)
        .interactiveDismissDisabled()
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
