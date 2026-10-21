import UIKit
import PencilKit

/// Builds what the tutor sees each turn: page snapshots plus a compact text description of the
/// canvas (where the student's ink is, every element with its id and frame, free space,
/// questions with their hidden answer keys).
@MainActor
struct TutorContextBuilder {
    let doc: NoteDocument
    weak var canvas: NoteCanvasViewController?
    let memory: TutorMemoryStore
    var settings: AppSettings { .shared }

    var layout: LayoutAssistant { LayoutAssistant(doc: doc) }

    static func imageBlock(jpeg: Data) -> JSONValue {
        ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": .string(jpeg.base64EncodedString())]]
    }

    static func text(_ s: String) -> JSONValue { ["type": "text", "text": .string(s)] }

    /// Pages to show: what the student is looking at (at most two), plus the focus page.
    func pagesToShow(focusPage: Int?) -> [Int] {
        var pages = canvas?.visiblePageIndices ?? [0]
        if pages.isEmpty { pages = [canvas?.currentPageIndex ?? 0] }
        if let current = canvas?.currentPageIndex, pages.count > 2 {
            pages = pages.sorted { abs($0 - current) < abs($1 - current) }
            pages = Array(pages.prefix(2)).sorted()
        }
        if pages.count > 2 { pages = Array(pages.prefix(2)) }
        if let f = focusPage {
            if !pages.contains(f) { pages = [f] + pages.prefix(1) }
        }
        return pages.sorted()
    }

    /// Content blocks for a turn: snapshots, an optional sharper crop of the focus region, then
    /// the canvas description.
    func blocks(focus: (page: Int, rect: CGRect)?, recentWriting: [CGRect], extraNotes: [String]) -> [JSONValue] {
        var out: [JSONValue] = []
        let pages = pagesToShow(focusPage: focus?.page)
        for p in pages {
            let focusRect = focus?.page == p ? focus?.rect : nil
            if let snap = PageRenderer.snapshot(doc, page: p, focus: focusRect) {
                out.append(TutorContextBuilder.text("Page \(p + 1) of \(doc.content.pages.count) (\(Int(doc.pageSize.width))×\(Int(doc.pageSize.height)) pt):"))
                out.append(TutorContextBuilder.imageBlock(jpeg: snap.jpeg))
            }
        }
        if let focus, let crop = PageRenderer.regionCrop(doc, page: focus.page, region: focus.rect) {
            out.append(TutorContextBuilder.text("Close-up of the outlined region on page \(focus.page + 1) (for legibility; use page coordinates from the full snapshot):"))
            out.append(TutorContextBuilder.imageBlock(jpeg: crop))
        }
        out.append(TutorContextBuilder.text(canvasState(shownPages: pages, focus: focus, recentWriting: recentWriting, extraNotes: extraNotes)))
        return out
    }

    func canvasState(shownPages: [Int], focus: (page: Int, rect: CGRect)?, recentWriting: [CGRect], extraNotes: [String]) -> String {
        var s = "<canvas_state>\n"
        let current = canvas?.currentPageIndex ?? 0
        s += "Note: \"\(doc.meta.title)\" · \(doc.content.pages.count) page\(doc.content.pages.count == 1 ? "" : "s") · page size \(Int(doc.pageSize.width))×\(Int(doc.pageSize.height)) pt · student is looking at page \(current + 1)"
        if let canvas {
            let vis = canvas.visibleDocRect.intersection(doc.pageRect(current))
            if !vis.isNull {
                let o = doc.pageOrigin(current)
                s += " (visible y \(Int(vis.minY - o.y))–\(Int(vis.maxY - o.y)))"
            }
        }
        s += "\n"
        if let focus {
            s += "Focus: the student selected page \(focus.page + 1) \(focus.rect.roundedForDisplay) — outlined in blue.\n"
        }
        for p in doc.content.pages.indices {
            let detailed = shownPages.contains(p) || focus?.page == p
            s += detailed ? describePage(p) : summarizePage(p)
        }
        let questions = doc.content.elements.compactMap { e -> String? in
            guard case .question(let q) = e.kind else { return nil }
            return "Q\(q.number) (\(e.id), page \(e.pageIndex + 1)): \(q.status.rawValue)\(q.score.map { " \($0)" } ?? "")"
        }
        if !questions.isEmpty { s += "Questions: " + questions.joined(separator: "; ") + "\n" }
        if !recentWriting.isEmpty {
            let parts = recentWriting.suffix(4).map { r -> String in
                let (page, local) = doc.pageRectFromDoc(r)
                return "page \(page + 1) \(local.roundedForDisplay)"
            }
            s += "Recently written by the student: " + parts.joined(separator: "; ") + "\n"
        }
        if let lastPDF = doc.content.pages.firstIndex(where: { $0.pdfAssetID != nil }) {
            s += "Pages with an imported PDF background start at page \(lastPDF + 1) (the PDF content is part of the snapshot).\n"
        }
        s += "</canvas_state>\n"
        let level = settings.studentLevel.trimmed, goals = settings.studentGoals.trimmed
        if !level.isEmpty || !goals.isEmpty {
            s += "<student>"
            if !level.isEmpty { s += "Level: \(level). " }
            if !goals.isEmpty { s += "Goals: \(goals)" }
            s += "</student>\n"
        }
        let mem = memory.promptText
        if !mem.isEmpty { s += "<memory>\n\(mem)\n</memory>\n" }
        if !doc.content.attachments.isEmpty {
            s += "<attachments>" + doc.content.attachments.map { "\($0.name) (\($0.kind.rawValue))" }.joined(separator: ", ") + "</attachments>\n"
        }
        if !extraNotes.isEmpty {
            s += "<since_last_turn>\n" + extraNotes.map { "- \($0)" }.joined(separator: "\n") + "\n</since_last_turn>\n"
        }
        s += "Date: \(Date().formatted(date: .abbreviated, time: .omitted))"
        return s
    }

    func summarizePage(_ p: Int) -> String {
        let ink = layout.inkClusters(page: p).count
        let els = doc.elements(onPage: p)
        if ink == 0 && els.isEmpty { return "Page \(p + 1): empty.\n" }
        let qs = els.compactMap { e -> String? in if case .question(let q) = e.kind { return "Q\(q.number)" }; return nil }
        return "Page \(p + 1): \(ink) ink region\(ink == 1 ? "" : "s"), \(els.count) element\(els.count == 1 ? "" : "s")\(qs.isEmpty ? "" : " (" + qs.joined(separator: ", ") + ")").\n"
    }

    func describePage(_ p: Int) -> String {
        var s = "Page \(p + 1)"
        if let pdfIdx = doc.content.pages[p].pdfPageIndex { s += " (PDF page \(pdfIdx + 1) as background)" }
        s += ":\n"
        let clusters = layout.inkClusters(page: p)
        if clusters.isEmpty {
            s += "  student ink: none\n"
        } else {
            let shown = clusters.prefix(30).map { r in
                "[x\(Int(r.minX))–\(Int(r.maxX)), y\(Int(r.minY))–\(Int(r.maxY))]"
            }
            s += "  student ink regions: " + shown.joined(separator: " ") + (clusters.count > 30 ? " …" : "") + "\n"
        }
        let bands = layout.freeBands(page: p)
        if !bands.isEmpty {
            s += "  free full-width space: " + bands.map { "y\(Int($0.0))–\(Int($0.1))" }.joined(separator: ", ") + "\n"
        }
        let els = doc.elements(onPage: p)
        if !els.isEmpty {
            s += "  elements:\n"
            for e in els { s += "    " + describe(e) + "\n" }
        }
        return s
    }

    func describe(_ e: CanvasElement) -> String {
        let who = e.author == .tutor ? "yours" : "student's"
        let f = e.frame.roundedForDisplay
        switch e.kind {
        case .text(let t):
            return "\(e.id) text (\(who)) \(f): \"\(t.text.truncated(90))\""
        case .math(let m):
            return "\(e.id) math (\(who)) \(f): " + m.lines.map { $0.truncated(60) }.joined(separator: " | ")
        case .ink(let ink):
            return "\(e.id) \(ink.purpose.rawValue) mark (\(who)) \(f)\(ink.label.map { " \"\($0.truncated(40))\"" } ?? "")"
        case .graph(let g):
            let plot = ElementRenderer.graphPlotRect(e.frame, g)
            let fns = g.functions.map(\.expression).joined(separator: ", ")
            return "\(e.id) graph (\(who)) \(f): x∈[\(JSONValue.formatNumber(g.xMin)),\(JSONValue.formatNumber(g.xMax))] → page x \(Int(plot.minX))–\(Int(plot.maxX)), y∈[\(JSONValue.formatNumber(g.yMin)),\(JSONValue.formatNumber(g.yMax))] → page y \(Int(plot.maxY))–\(Int(plot.minY))" + (fns.isEmpty ? " (blank plane)" : "; y = \(fns)") + (g.points.isEmpty ? "" : "; \(g.points.count) points")
        case .numberLine(let n):
            return "\(e.id) number line (\(who)) \(f): \(JSONValue.formatNumber(n.min)) to \(JSONValue.formatNumber(n.max))"
        case .table(let t):
            return "\(e.id) table (\(who)) \(f): \(t.rows.count) rows; first row: " + (t.rows.first ?? []).joined(separator: " | ").truncated(80)
        case .question(let q):
            let answerArea = CGRect(x: e.frame.minX + 14, y: e.frame.minY + q.promptHeight, width: e.frame.width - 28, height: e.frame.height - q.promptHeight - 14)
            var s = "\(e.id) Q\(q.number) question card \(f), \(q.marks) mark\(q.marks == 1 ? "" : "s"), status \(q.status.rawValue)\(q.score.map { " (\($0))" } ?? ""); answer area \(answerArea.roundedForDisplay)"
            s += "\n      prompt: \"\(q.prompt.truncated(200))\""
            s += "\n      hidden answer key: \"\(q.answer.truncated(160))\"" + (q.hint.map { "; hidden hint: \"\($0.truncated(100))\"" } ?? "")
            if q.revealedHint { s += "; hint already shown" }
            if q.revealedSolution { s += "; solution already shown" }
            return s
        case .image:
            return "\(e.id) image (\(who)) \(f)"
        }
    }
}
