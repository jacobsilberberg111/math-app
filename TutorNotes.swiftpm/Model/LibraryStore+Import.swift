import Foundation

/// Bringing in `.margin` note files (see `NoteArchive`).
extension LibraryStore {
    /// Imports a note file and queues the new note to open, or records why that failed. This is
    /// the one way in for a file picked in the Library and one opened from AirDrop or Files.
    func openNoteFile(_ url: URL) {
        do {
            pendingOpen = try importNoteFile(at: url)
        } catch {
            importFailure = error.localizedDescription
        }
    }

    /// Imports a note file as a new note, so the same file can be imported again and again.
    /// It keeps its title and creation date; it starts with no tutor chat, and without a subject
    /// if this library doesn't have the one it was filed under.
    @discardableResult
    func importNoteFile(at url: URL) throws -> NoteMeta {
        var archive = try NoteArchive.decode(Self.readNoteFile(url))
        var meta = archive.meta
        meta.id = UUID()
        meta.modifiedAt = Date()
        meta.hasTutorSession = false
        meta.lastOpenedAt = nil
        if subject(meta.subjectID) == nil { meta.subjectID = nil }
        if meta.title.trimmed.isEmpty { meta.title = "Untitled" }
        // Files uploaded for the sender's tutor mean nothing here; they are uploaded again when needed.
        for i in archive.content.attachments.indices { archive.content.attachments[i].remoteFileID = nil }

        let folder = Storage.folder(for: meta.id)
        let assets = Storage.assetsFolder(for: meta.id)
        do {
            for (name, data) in archive.assets {
                try data.write(to: assets.appendingPathComponent(name), options: .atomic)
            }
            try Storage.write(archive.content, to: folder.appendingPathComponent("content.json"))
            try archive.drawing.write(to: folder.appendingPathComponent("drawing.data"), options: .atomic)
            // Last: a note exists in the library once its meta.json does.
            try Storage.write(meta, to: folder.appendingPathComponent("meta.json"))
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        notes.append(meta)
        setThumbnail(PageRenderer.thumbnail(NoteDocument.load(meta: meta)), for: meta.id)
        return meta
    }

    /// Reads a file the user picked or another app handed over. Such URLs can be security-scoped
    /// (the file stays in another app's container or in iCloud), so access is opened for the
    /// read and the bytes copied out before it ends.
    private static func readNoteFile(_ url: URL) throws -> Data {
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
}
