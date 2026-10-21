import Foundation

/// Where exports are written. Every export gets a fresh folder under the temporary directory, so
/// repeating one while the share sheet from the last is still open never overwrites files in use.
enum ExportFiles {
    private static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
    }

    /// A new empty folder for one export's files. Folders left by earlier exports a day or more
    /// ago are removed first.
    static func makeFolder() -> URL? {
        removeStale()
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        } catch {
            return nil
        }
    }

    private static func removeStale() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-86_400)
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for folder in folders {
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? fm.removeItem(at: folder) }
        }
    }

    /// A note title made safe to use as a file name: no path separators or characters that file
    /// systems and share targets reject, no leading dot, a sensible length, never empty.
    static func safeName(_ title: String) -> String {
        var name = title.replacingOccurrences(of: ": ", with: " - ")
        for c in ["/", "\\", ":"] { name = name.replacingOccurrences(of: c, with: "-") }
        name = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let dropped = CharacterSet(charactersIn: "*?\"<>|").union(.controlCharacters)
        name = String(name.unicodeScalars.filter { !dropped.contains($0) })
        name = String(name.prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: ". -").union(.whitespaces))
        return name.isEmpty ? "Note" : name
    }
}
