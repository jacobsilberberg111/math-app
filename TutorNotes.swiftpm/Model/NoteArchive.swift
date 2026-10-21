import Foundation

/// A whole note in one file (`.margin`), for sharing or backing up: the meta and content, the
/// ink, and every file in the note's assets folder (images, PDFs, attachments, audio). The tutor
/// chat and the thumbnail are left out.
///
/// Stored as a binary property list, which keeps asset data as raw bytes instead of base64.
struct NoteArchive: Codable {
    static let currentVersion = 1
    static let fileExtension = "margin"

    var version = NoteArchive.currentVersion
    var meta: NoteMeta
    var content: NoteContent
    /// `PKDrawing.dataRepresentation()`.
    var drawing: Data
    /// File name → bytes, for everything in the assets folder.
    var assets: [String: Data]
}

enum NoteArchiveError: LocalizedError {
    case notANote, newerVersion, damaged

    var errorDescription: String? {
        switch self {
        case .notANote: return "That file isn't a Margin note."
        case .newerVersion: return "That note was made with a newer version of Margin. Update the app to open it."
        case .damaged: return "That note file is damaged."
        }
    }
}

extension NoteArchive {
    /// Packs a note's state with the files in its assets folder.
    static func pack(meta: NoteMeta, content: NoteContent, drawing: Data, assetsFolder: URL) throws -> NoteArchive {
        let files = try FileManager.default.contentsOfDirectory(at: assetsFolder, includingPropertiesForKeys: [.isRegularFileKey],
                                                                options: .skipsHiddenFiles)
        var assets: [String: Data] = [:]
        for file in files where (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            assets[file.lastPathComponent] = try Data(contentsOf: file)
        }
        return NoteArchive(meta: meta, content: content, drawing: drawing, assets: assets)
    }

    func encoded() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }

    /// Decodes and checks an archive. Files from a newer format are refused rather than
    /// half-read: the version is read on its own first, since the rest may not decode.
    static func decode(_ data: Data) throws -> NoteArchive {
        struct Header: Decodable { var version: Int }
        let decoder = PropertyListDecoder()
        guard let header = try? decoder.decode(Header.self, from: data), header.version >= 1 else { throw NoteArchiveError.notANote }
        guard header.version <= currentVersion else { throw NoteArchiveError.newerVersion }
        guard let archive = try? decoder.decode(NoteArchive.self, from: data), archive.isSound else { throw NoteArchiveError.damaged }
        return archive
    }

    /// Has pages to show, and only plain file names as assets (a name like "../x" would write
    /// outside the note's folder).
    private var isSound: Bool {
        !content.pages.isEmpty && assets.keys.allSatisfy { name in
            !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
        }
    }
}
