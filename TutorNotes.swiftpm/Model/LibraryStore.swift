import SwiftUI
import PencilKit
import UIKit

enum LibrarySort: String, CaseIterable, Identifiable {
    case modified, created, title
    var id: String { rawValue }
    var title: String {
        switch self {
        case .modified: return "Date Modified"
        case .created: return "Date Created"
        case .title: return "Title"
        }
    }
}

/// All notes and subjects. Note bodies load lazily when opened.
@MainActor
@Observable
final class LibraryStore {
    var notes: [NoteMeta] = []
    var subjects: [Subject] = []
    /// Thumbnail cache keyed by note id. Not observed directly (it is filled lazily while views
    /// render); views observe `thumbnailVersion` instead.
    @ObservationIgnored var thumbnails: [UUID: UIImage] = [:]
    var thumbnailVersion = 0
    /// A note that arrived from outside (a note file from AirDrop or Files) and should be opened;
    /// whichever view shows notes clears it.
    var pendingOpen: NoteMeta?
    /// Why the last note file couldn't be opened, until its alert is dismissed.
    var importFailure: String?

    init() {
        load()
    }

    func load() {
        subjects = Storage.read([Subject].self, from: Storage.subjectsURL) ?? []
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: Storage.notesDir, includingPropertiesForKeys: nil)) ?? []
        var loaded: [NoteMeta] = []
        for folder in folders {
            if let meta = Storage.read(NoteMeta.self, from: folder.appendingPathComponent("meta.json")) {
                loaded.append(meta)
            }
        }
        notes = loaded
        if notes.isEmpty && subjects.isEmpty {
            seedWelcome()
        }
    }

    private func seedWelcome() {
        let maths = Subject(name: "Maths", colorHex: Subject.palette[0])
        subjects = [maths, Subject(name: "Physics", colorHex: Subject.palette[4])]
        saveSubjects()
        let paper = PaperStyle(pattern: .grid, color: .white)
        let meta = NoteMeta(title: "Welcome to Margin", subjectID: maths.id, paper: paper)
        var content = NoteContent()
        content.pages = [Page(paper: paper)]
        let doc = NoteDocument.create(meta: meta, content: content)
        WelcomeContent.populate(doc)
        doc.saveNow()
        notes.append(doc.meta)
        // Thumbnails are normally made when a note closes; this one has never been opened.
        setThumbnail(PageRenderer.thumbnail(doc), for: doc.id)
    }

    func saveSubjects() {
        let subjects = self.subjects
        Storage.ioQueue.async { try? Storage.write(subjects, to: Storage.subjectsURL) }
    }

    func sorted(_ items: [NoteMeta], by sort: LibrarySort) -> [NoteMeta] {
        switch sort {
        case .modified: return items.sorted { $0.modifiedAt > $1.modifiedAt }
        case .created: return items.sorted { $0.createdAt > $1.createdAt }
        case .title: return items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    func notes(in subjectID: UUID?, unfiledOnly: Bool = false, search: String = "", sort: LibrarySort = .modified) -> [NoteMeta] {
        var items = notes
        if unfiledOnly {
            let ids = Set(subjects.map(\.id))
            items = items.filter { note in note.subjectID.map { !ids.contains($0) } ?? true }
        } else if let subjectID {
            items = items.filter { $0.subjectID == subjectID }
        }
        let q = search.trimmed
        if !q.isEmpty {
            items = items.filter {
                $0.title.localizedCaseInsensitiveContains(q) || ($0.searchText?.localizedCaseInsensitiveContains(q) ?? false)
            }
        }
        return sorted(items, by: sort)
    }

    func subject(_ id: UUID?) -> Subject? {
        guard let id else { return nil }
        return subjects.first { $0.id == id }
    }

    // MARK: Notes

    @discardableResult
    func createNote(title: String, subjectID: UUID?, paper: PaperStyle, layout: NoteLayout = .pages) -> NoteMeta {
        var paper = paper
        var meta = NoteMeta(title: title, subjectID: subjectID, paper: paper)
        meta.pageCount = 1
        var content = NoteContent()
        if layout == .freeform {
            // Cornell needs page edges; a board gets a plain grid instead.
            if !PaperPattern.boardPatterns.contains(paper.pattern) { paper.pattern = .grid }
            meta.paper = paper
            meta.layout = .freeform
            content.layout = .freeform
            content.pageSize = NoteDocument.boardInitialSize
        }
        content.pages = [Page(paper: paper)]
        let doc = NoteDocument.create(meta: meta, content: content)
        meta = doc.meta
        notes.append(meta)
        return meta
    }

    /// A note for working through a past paper: the paper's pages to write on, the paper and its
    /// mark scheme attached for the tutor (the mark scheme stays hidden from the student), and a
    /// paper session the tutor fills in by mapping the questions.
    func createPastPaper(paper: URL, markScheme: URL?, title: String, subjectID: UUID?, timeLimitMinutes: Int?) -> NoteMeta? {
        let meta = NoteMeta(title: title.trimmed.isEmpty ? "Past paper" : title.trimmed, subjectID: subjectID,
                            paper: PaperStyle(pattern: .blank, color: .white))
        let doc = NoteDocument.create(meta: meta, content: NoteContent())
        guard let asset = doc.storePDF(from: paper), doc.pdf(asset) != nil else {
            delete(meta)
            return nil
        }
        doc.importPDFPages(assetID: asset, replaceFirstBlankPage: true)
        func attach(_ file: String, name: String, role: AttachmentRole) {
            let size = (try? FileManager.default.attributesOfItem(atPath: doc.assetURL(file).path)[.size] as? Int) ?? 0
            doc.content.attachments.append(TutorAttachment(id: "a\(UUID().uuidString.prefix(6))", name: name, kind: .pdf,
                                                           mimeType: "application/pdf", localFile: file, sizeBytes: size, role: role))
        }
        attach(asset, name: "\(meta.title) (paper).pdf", role: .paper)
        if let markScheme, let ms = doc.storePDF(from: markScheme), doc.pdf(ms) != nil {
            attach(ms, name: "\(meta.title) (mark scheme).pdf", role: .markScheme)
        }
        doc.content.paper = PaperSession(timeLimitMinutes: timeLimitMinutes)
        doc.markDirty()
        doc.saveNow()
        notes.append(doc.meta)
        return doc.meta
    }

    /// Stamps when a note was opened (Home's "continue" and recents) without touching its
    /// modified date. Returns the updated meta to open the note with.
    @discardableResult
    func markOpened(_ meta: NoteMeta) -> NoteMeta {
        var m = notes.first { $0.id == meta.id } ?? meta
        m.lastOpenedAt = Date()
        persist(m)
        return m
    }

    /// Most recently opened or edited first.
    var recentNotes: [NoteMeta] { notes.sorted { $0.lastActivity > $1.lastActivity } }

    /// Notes with question cards still waiting for an answer, most recent first.
    var notesWithOpenQuestions: [NoteMeta] { recentNotes.filter { ($0.openQuestions ?? 0) > 0 } }

    /// Creates a note whose pages are the PDF's pages, ready to annotate.
    func createNote(fromPDF url: URL, subjectID: UUID?) -> NoteMeta? {
        let title = url.deletingPathExtension().lastPathComponent
        let meta = NoteMeta(title: title, subjectID: subjectID, paper: PaperStyle(pattern: .blank, color: .white))
        let doc = NoteDocument.create(meta: meta, content: NoteContent())
        guard let asset = doc.storePDF(from: url) else {
            delete(meta)
            return nil
        }
        doc.importPDFPages(assetID: asset, replaceFirstBlankPage: true)
        doc.saveNow()
        notes.append(doc.meta)
        return doc.meta
    }

    func update(_ meta: NoteMeta) {
        if let i = notes.firstIndex(where: { $0.id == meta.id }) {
            notes[i] = meta
        } else {
            notes.append(meta)
        }
    }

    func persist(_ meta: NoteMeta) {
        update(meta)
        let url = Storage.folder(for: meta.id).appendingPathComponent("meta.json")
        Storage.ioQueue.async { try? Storage.write(meta, to: url) }
    }

    func rename(_ meta: NoteMeta, to title: String) {
        var m = meta
        m.title = title.trimmed.isEmpty ? "Untitled" : title.trimmed
        persist(m)
    }

    func move(_ meta: NoteMeta, to subjectID: UUID?) {
        var m = meta
        m.subjectID = subjectID
        persist(m)
    }

    func delete(_ meta: NoteMeta) {
        notes.removeAll { $0.id == meta.id }
        thumbnails[meta.id] = nil
        let folder = Storage.folder(for: meta.id)
        Storage.ioQueue.async { try? FileManager.default.removeItem(at: folder) }
    }

    func duplicate(_ meta: NoteMeta) {
        let newID = UUID()
        let src = Storage.folder(for: meta.id)
        let dst = Storage.folder(for: newID)
        var copy = meta
        copy.id = newID
        copy.title = meta.title + " copy"
        copy.createdAt = Date()
        copy.modifiedAt = Date()
        copy.hasTutorSession = false
        Storage.ioQueue.sync {
            try? FileManager.default.copyItem(at: src, to: dst)
            try? FileManager.default.removeItem(at: dst.appendingPathComponent("tutor.json"))
            try? Storage.write(copy, to: dst.appendingPathComponent("meta.json"))
        }
        notes.append(copy)
    }

    // MARK: Subjects

    func addSubject(name: String) {
        let color = Subject.palette[subjects.count % Subject.palette.count]
        subjects.append(Subject(name: name.trimmed.isEmpty ? "New Subject" : name.trimmed, colorHex: color))
        saveSubjects()
    }

    func renameSubject(_ subject: Subject, to name: String) {
        guard let i = subjects.firstIndex(of: subject) else { return }
        subjects[i].name = name.trimmed.isEmpty ? subject.name : name.trimmed
        saveSubjects()
    }

    func recolorSubject(_ subject: Subject, hex: String) {
        guard let i = subjects.firstIndex(of: subject) else { return }
        subjects[i].colorHex = hex
        saveSubjects()
    }

    func deleteSubject(_ subject: Subject) {
        subjects.removeAll { $0.id == subject.id }
        for meta in notes where meta.subjectID == subject.id {
            move(meta, to: nil)
        }
        saveSubjects()
    }

    // MARK: Thumbnails

    func thumbnail(for meta: NoteMeta) -> UIImage? {
        if let img = thumbnails[meta.id] { return img }
        let url = Storage.folder(for: meta.id).appendingPathComponent("thumb.jpg")
        if let img = UIImage(contentsOfFile: url.path) {
            thumbnails[meta.id] = img
            return img
        }
        return nil
    }

    func setThumbnail(_ image: UIImage, for id: UUID) {
        thumbnails[id] = image
        thumbnailVersion += 1
        if let data = image.jpegData(compressionQuality: 0.8) {
            let url = Storage.folder(for: id).appendingPathComponent("thumb.jpg")
            Storage.ioQueue.async { try? data.write(to: url, options: .atomic) }
        }
    }
}

/// A first note that shows what the tutor can put on the page.
@MainActor
enum WelcomeContent {
    static func populate(_ doc: NoteDocument) {
        let env = PageRenderer.environment(for: doc)
        let tutorHex = AppSettings.shared.tutorInkHex
        func addText(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, style: TextStyle = .handwriting, size: CGFloat = 20, color: String? = nil) -> CGFloat {
            let t = TextContent(text: text, style: style, fontSize: size, colorHex: color ?? tutorHex, rich: true)
            let h = ElementRenderer.measureText(t, author: .tutor, width: width, env: env).height
            doc.content.elements.append(CanvasElement(id: doc.nextElementID(), pageIndex: 0,
                                                      frame: CGRect(x: x, y: y, width: width, height: h), author: .tutor, kind: .text(t)))
            return y + h
        }
        var y = addText("Welcome! I'm your tutor.", x: 56, y: 48, width: 600, style: .heading, size: 30)
        y = addText("I work right here on the page with you. Write with Apple Pencil, then tap **Ask** and drag around your working — or just pause and I'll take a look.", x: 56, y: y + 10, width: 700)
        let math = MathContent(lines: ["x^2 - 5x + 6 = 0", "(x - 2)(x - 3) = 0", "x = 2 \\text{ or } x = 3"], fontSize: 23, colorHex: tutorHex)
        let mathSize = ElementRenderer.measureMath(math)
        doc.content.elements.append(CanvasElement(id: doc.nextElementID(), pageIndex: 0, frame: CGRect(origin: CGPoint(x: 64, y: y + 24), size: mathSize),
                                                  author: .tutor, kind: .math(math)))
        var g = GraphContent()
        g.xMin = -1; g.xMax = 5; g.yMin = -1; g.yMax = 6
        g.functions = [GraphFunction(expression: "x^2 - 5x + 6", label: "$y = x^2 - 5x + 6$", colorHex: "#1C64F2")]
        g.points = [GraphPoint(x: 2, y: 0, label: "(2, 0)", colorHex: "#E03131"), GraphPoint(x: 3, y: 0, label: "(3, 0)", colorHex: "#E03131")]
        doc.content.elements.append(CanvasElement(id: doc.nextElementID(), pageIndex: 0,
                                                  frame: CGRect(x: 430, y: y + 16, width: 340, height: 260), author: .tutor, kind: .graph(g)))
        y = max(y + 24 + mathSize.height, y + 16 + 260) + 30
        var q = QuestionContent(number: doc.nextQuestionNumber(), prompt: "Your turn: solve $x^2 - 7x + 10 = 0$. Write your working in the box, then pause — I'll mark it.",
                                marks: 2, promptHeight: 0, answer: "x = 2 or x = 5", solution: "$(x-2)(x-5)=0$, so $x = 2$ or $x = 5$.",
                                hint: "Find two numbers that multiply to 10 and add to −7.", topic: "Quadratics", difficulty: "easy")
        q.promptHeight = ElementRenderer.questionPromptHeight(q, width: 736, env: env)
        doc.content.elements.append(CanvasElement(id: doc.nextElementID(), pageIndex: 0,
                                                  frame: CGRect(x: 40, y: y, width: 736, height: q.promptHeight + 230), author: .tutor, kind: .question(q)))
        y += q.promptHeight + 230 + 24
        _ = addText("Tips: draw a shape and hold to snap it · two-finger tap to undo · squeeze Apple Pencil Pro to call me · connect me in Settings.",
                    x: 56, y: min(y, 960), width: 700, style: .note, size: 16, color: "#57606A")
    }
}
