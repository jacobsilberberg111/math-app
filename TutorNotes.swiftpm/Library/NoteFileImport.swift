import SwiftUI
import UniformTypeIdentifiers

extension NoteArchive {
    /// The type of a note file: the one the app declares in its Info.plist, else anything named
    /// `.margin` (builds without the declaration, such as Swift Playgrounds), else any file.
    static let contentType = UTType("com.jacobsilberberg.margin.note") ?? UTType(filenameExtension: fileExtension) ?? .data
}

/// The Library's side of note files: "Import Note File…", opening notes queued in
/// `LibraryStore.pendingOpen`, and telling the user when a file couldn't be opened.
private struct NoteFileImport: ViewModifier {
    @Binding var isPresented: Bool
    /// False while the editor is open: it takes the arriving note itself (see `NoteFileArrival`).
    let canOpen: Bool
    let open: (NoteMeta) -> Void
    @Environment(LibraryStore.self) private var library

    func body(content: Content) -> some View {
        content
            // On a view of its own: a second file importer on the same view is ignored.
            .background {
                Color.clear.fileImporter(isPresented: $isPresented, allowedContentTypes: [NoteArchive.contentType]) { result in
                    guard case .success(let url) = result else { return }
                    library.openNoteFile(url)
                }
            }
            .onChange(of: library.pendingOpen, initial: true) { _, meta in
                guard let meta, canOpen else { return }
                library.pendingOpen = nil
                open(meta)
            }
            .alert("Couldn't open that note file", isPresented: Binding(get: { canOpen && library.importFailure != nil },
                                                                      set: { if !$0 { library.importFailure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(library.importFailure ?? "")
            }
    }
}

/// The editor's side: while a note is open, a note file that arrives (AirDrop, Files) is handled
/// here rather than by the Library underneath, so the open note is closed properly before the
/// new one replaces it. The Library's alert can't show over the editor, so failures are a toast.
private struct NoteFileArrival: ViewModifier {
    let switchTo: (NoteMeta) -> Void
    let flash: (String) -> Void
    @Environment(LibraryStore.self) private var library

    func body(content: Content) -> some View {
        content
            .onChange(of: library.pendingOpen, initial: true) { _, meta in
                guard let meta else { return }
                library.pendingOpen = nil
                switchTo(meta)
            }
            .onChange(of: library.importFailure) { _, message in
                guard message != nil else { return }
                library.importFailure = nil
                flash("Couldn't open that note file")
            }
    }
}

extension View {
    func noteFileImport(isPresented: Binding<Bool>, canOpen: Bool, open: @escaping (NoteMeta) -> Void) -> some View {
        modifier(NoteFileImport(isPresented: isPresented, canOpen: canOpen, open: open))
    }

    func noteFileArrival(switchTo: @escaping (NoteMeta) -> Void, flash: @escaping (String) -> Void) -> some View {
        modifier(NoteFileArrival(switchTo: switchTo, flash: flash))
    }
}
