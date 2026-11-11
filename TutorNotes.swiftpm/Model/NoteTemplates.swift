import UIKit

/// Creating notes from a subject's templates: the title and headed sections are placed as the
/// student's own typed text (they can edit, move or delete them), on the template's paper.
@MainActor
extension LibraryStore {
    @discardableResult
    func createNote(from template: NoteTemplate, subject: Subject?, paperColor: PaperColor, title: String? = nil) -> NoteMeta {
        let pattern = PaperPattern(rawValue: template.pattern) ?? .ruled
        let paper = PaperStyle(pattern: pattern, color: paperColor)
        let noteTitle = title ?? "\(template.title) · \(Date().formatted(.dateTime.day().month(.abbreviated)))"
        var meta = NoteMeta(title: noteTitle, subjectID: subject?.id, paper: paper)
        if template.isBlurt { meta.studyMode = "blurt" }
        var content = NoteContent()
        content.pageSize = .letter
        let accent = paperColor.isDark ? "#E6E8EB" : (subject?.colorHex ?? "#1F2328")
        let ink = paperColor.isDark ? "#E6E8EB" : "#1F2328"
        let hintHex = paperColor.isDark ? "#9AA4AF" : "#8A939E"
        let layout = NoteTemplateLayout(pattern: pattern, pageSize: CGSize(width: content.pageSize.width, height: content.pageSize.height))
        var elements: [CanvasElement] = []
        var n = 1
        func add(_ text: String, page: Int, x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat, hex: String) {
            let t = TextContent(text: text, style: .typed, fontSize: size, colorHex: hex, rich: true)
            let h = ceil(NoteFonts.sans(size: size, weight: .regular).lineHeight * CGFloat(max(1, text.components(separatedBy: "\n").count))) + 6
            elements.append(CanvasElement(id: "e\(n)", pageIndex: page, frame: CGRect(x: x, y: y, width: width, height: h), author: .student, kind: .text(t)))
            n += 1
        }
        // Title, sitting above the first ruled line.
        add("**\(template.isBlurt ? "Blurt" : template.title)**", page: 0, x: layout.left, y: layout.titleY, width: layout.width, size: 26, hex: accent)
        if pattern == .cornell {
            let h = content.pageSize.height
            add("Cues & questions", page: 0, x: 16, y: 72, width: 186, size: 12, hex: hintHex)
            add("Notes", page: 0, x: 222, y: 72, width: 300, size: 12, hex: hintHex)
            add("Summary", page: 0, x: 16, y: h - 184, width: 300, size: 12, hex: hintHex)
        }
        let slots = TemplateLayout.slots(weights: template.sections.map(\.weight), firstTop: layout.firstTop, top: layout.top,
                                         bottom: layout.bottom, lineSpacing: layout.lineSpacing, lineOrigin: layout.lineOrigin)
        for (section, slot) in zip(template.sections, slots) {
            // The heading sits on the ruled line (its text just above it), the hint under it.
            let headingY = slot.top - (layout.lineSpacing > 0 ? 26 : 0)
            add("**\(section.heading)**", page: slot.page, x: layout.left, y: headingY, width: layout.width, size: 18, hex: accent)
            if let hint = section.hint {
                add(hint, page: slot.page, x: layout.left + 2, y: headingY + 25, width: layout.width, size: 12.5, hex: hintHex)
            }
        }
        content.elements = elements
        content.nextElementNumber = n
        let pageCount = (slots.map(\.page).max() ?? 0) + 1
        content.pages = (0..<pageCount).map { _ in Page(paper: paper) }
        meta.pageCount = pageCount
        let doc = NoteDocument.create(meta: meta, content: content)
        meta = doc.meta
        notes.append(meta)
        return meta
    }
}

/// Page geometry for templates on each paper pattern (see PaperRenderer for the rulings).
struct NoteTemplateLayout {
    let pattern: PaperPattern
    let pageSize: CGSize

    var lineSpacing: CGFloat {
        switch pattern {
        case .ruled, .narrowRuled: return PaperRenderer.spacing(for: pattern)
        default: return 0
        }
    }
    /// The first ruled line.
    var lineOrigin: CGFloat { 96 }
    var left: CGFloat {
        switch pattern {
        case .ruled, .narrowRuled: return 100
        case .cornell: return 222
        default: return 56
        }
    }
    var width: CGFloat { pageSize.width - left - 48 }
    var titleY: CGFloat { pattern == .cornell ? 22 : 40 }
    /// Sections start one line below the title on the first page.
    var firstTop: CGFloat { lineSpacing > 0 ? lineOrigin + 2 * lineSpacing : 120 }
    var top: CGFloat { lineSpacing > 0 ? lineOrigin + lineSpacing : 72 }
    var bottom: CGFloat { pageSize.height - 48 }
}
