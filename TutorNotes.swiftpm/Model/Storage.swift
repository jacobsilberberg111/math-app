import Foundation

/// On-disk layout:
///   Documents/TutorNotes/
///     subjects.json
///     memory.json                 tutor's notes about the student
///     notes/<uuid>/
///       meta.json  content.json  drawing.data  tutor.json  thumb.jpg
///       assets/    (images, imported PDFs, tutor attachments, audio)
enum Storage {
    static let root: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("TutorNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let notesDir: URL = {
        let url = root.appendingPathComponent("notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var subjectsURL: URL { root.appendingPathComponent("subjects.json") }
    static var memoryURL: URL { root.appendingPathComponent("memory.json") }

    static func folder(for id: UUID) -> URL {
        notesDir.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func assetsFolder(for id: UUID) -> URL {
        let url = folder(for: id).appendingPathComponent("assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            print("Storage: failed to decode \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    /// Serial queue for disk writes so saves never block the pencil.
    static let ioQueue = DispatchQueue(label: "TutorNotes.io", qos: .utility)
}
