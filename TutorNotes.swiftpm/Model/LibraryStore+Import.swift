import Foundation

/// Bringing in `.margin` note files (see `NoteArchive`).
extension LibraryStore {
    /// Imports a note file and queues the new note to open, or records why that failed. This is
    /// the one way in for a file picked in the Library and one opened from AirDrop or Files.
    /// Reading, checking and writing the files happen off the main thread, so a big note (or one
    /// still downloading from iCloud) doesn't freeze the app.
    func openNoteFile(_ url: URL) {
        Task {
            do {
                let archive = try await Task.detached(priority: .userInitiated) {
                    try NoteArchive.decode(LibraryStore.readNoteFile(url))
                }.value
                pendingOpen = try await importArchive(archive)
                LibraryStore.removeFromInbox(url)
            } catch {
                importFailure = error.localizedDescription
            }
        }
    }

    /// Imports a note file as a new note (synchronously; the feature check uses this).
    @discardableResult
    func importNoteFile(at url: URL) throws -> NoteMeta {
        let archive = try NoteArchive.decode(LibraryStore.readNoteFile(url))
        let meta = importedMeta(for: archive)
        try LibraryStore.write(archive, as: meta)
        return added(meta)
    }

    /// Adds a decoded note file as a new note, so the same file can be imported again and again.
    private func importArchive(_ archive: NoteArchive) async throws -> NoteMeta {
        let meta = importedMeta(for: archive)
        try await Task.detached(priority: .userInitiated) { try LibraryStore.write(archive, as: meta) }.value
        return added(meta)
    }

    /// The new note's meta: a fresh id; it keeps its title and creation date, and starts with no
    /// tutor chat, and without a subject if this library doesn't have the one it was filed under.
    private func importedMeta(for archive: NoteArchive) -> NoteMeta {
        var meta = archive.meta
        meta.id = UUID()
        meta.modifiedAt = Date()
        meta.hasTutorSession = false
        meta.lastOpenedAt = nil
        if subject(meta.subjectID) == nil { meta.subjectID = nil }
        if meta.title.trimmed.isEmpty { meta.title = "Untitled" }
        return meta
    }

    private func added(_ meta: NoteMeta) -> NoteMeta {
        notes.append(meta)
        setThumbnail(PageRenderer.thumbnail(NoteDocument.load(meta: meta)), for: meta.id)
        return meta
    }

    /// Writes the note's files. `meta.json` goes last: a note exists in the library once it does,
    /// and a failure part-way removes what was written.
    nonisolated private static func write(_ archive: NoteArchive, as meta: NoteMeta) throws {
        var content = archive.content
        // Files uploaded for the sender's tutor mean nothing here; they are uploaded again when needed.
        for i in content.attachments.indices { content.attachments[i].remoteFileID = nil }
        let folder = Storage.folder(for: meta.id)
        let assets = Storage.assetsFolder(for: meta.id)
        do {
            for (name, data) in archive.assets {
                try data.write(to: assets.appendingPathComponent(name), options: .atomic)
            }
            try Storage.write(content, to: folder.appendingPathComponent("content.json"))
            try archive.drawing.write(to: folder.appendingPathComponent("drawing.data"), options: .atomic)
            try Storage.write(meta, to: folder.appendingPathComponent("meta.json"))
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// Reads a file the user picked or another app handed over. Such URLs can be security-scoped
    /// (the file stays in another app's container or in iCloud), so access is opened for the
    /// read and the bytes copied out before it ends.
    nonisolated private static func readNoteFile(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            result = Result { try Data(contentsOf: readURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw NoteArchiveError.notANote }
        return try result.get()
    }

    /// Files received by AirDrop are copied into Documents/Inbox; once imported, that copy is clutter.
    private static func removeFromInbox(_ url: URL) {
        let inbox = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Inbox", isDirectory: true).standardizedFileURL.path
        guard url.standardizedFileURL.path.hasPrefix(inbox + "/") else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
