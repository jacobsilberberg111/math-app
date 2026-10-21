import SwiftUI
import PencilKit
import UIKit

/// How a newly added element appears on the canvas.
enum RevealStyle {
    case none
    /// Animated "being written" reveal, used for tutor content.
    case write(duration: TimeInterval)
    /// Content is streaming in; the view grows as the element updates.
    case live
}

/// Implemented by the canvas so document changes (from the student, undo, or the tutor) show up.
@MainActor
protocol DocumentCanvas: AnyObject {
    func documentDidAddElement(_ element: CanvasElement, reveal: RevealStyle)
    func documentDidUpdateElement(_ element: CanvasElement)
    func documentDidRemoveElement(id: String)
    func documentDidChangePages()
    func documentDidReplaceDrawing()
    /// Pages, elements and ink were all replaced at once (page move, resize, clear, or their undo).
    func documentDidReload()
}

/// The open note: pages, ink, elements, assets. All mutations go through here so they can be
/// undone, saved, and mirrored on the canvas.
@MainActor
@Observable
final class NoteDocument {
    // Layout constants (document coordinates, points at 100% zoom).
    static let pageGap: CGFloat = 28
    static let topMargin: CGFloat = 28
    static let sideMargin: CGFloat = 32
    static let footerHeight: CGFloat = 140

    let id: UUID
    var meta: NoteMeta
    var content: NoteContent
    var drawing: PKDrawing
    /// Bumped on every change so SwiftUI can refresh derived UI (page counts, thumbnails).
    var revision = 0

    @ObservationIgnored let folder: URL
    @ObservationIgnored let undoManager = UndoManager()
    @ObservationIgnored weak var canvas: DocumentCanvas?
    @ObservationIgnored var onMetaChanged: ((NoteMeta) -> Void)?
    /// Called when pages are moved or resized (including by undo and redo) so page numbers kept
    /// elsewhere can follow.
    @ObservationIgnored var onPagesRearranged: ((PageRemap) -> Void)?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var imageCache: [String: UIImage] = [:]
    @ObservationIgnored private var pdfCache: [String: CGPDFDocument] = [:]
    @ObservationIgnored private(set) var isDirty = false
    /// Freeform boards: the part of the board on screen (board coordinates). Kept up to date by
    /// the canvas so the tutor works where the student is looking.
    @ObservationIgnored var visibleBoardRect: CGRect?

    init(meta: NoteMeta, content: NoteContent, drawing: PKDrawing) {
        self.id = meta.id
        self.meta = meta
        self.content = content
        self.drawing = drawing
        self.folder = Storage.folder(for: meta.id)
        undoManager.levelsOfUndo = 200
    }

    // MARK: Loading & saving

    static func load(meta: NoteMeta) -> NoteDocument {
        let folder = Storage.folder(for: meta.id)
        let content = Storage.read(NoteContent.self, from: folder.appendingPathComponent("content.json")) ?? NoteContent()
        var drawing = PKDrawing()
        if let data = try? Data(contentsOf: folder.appendingPathComponent("drawing.data")),
           let d = try? PKDrawing(data: data) {
            drawing = d
        }
        return NoteDocument(meta: meta, content: content, drawing: drawing)
    }

    static func create(meta: NoteMeta, content: NoteContent) -> NoteDocument {
        let doc = NoteDocument(meta: meta, content: content, drawing: PKDrawing())
        try? FileManager.default.createDirectory(at: doc.folder, withIntermediateDirectories: true)
        doc.saveNow()
        return doc
    }

    func markDirty() {
        isDirty = true
        revision += 1
        scheduleSave()
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        // Only real edits count as a modification; opening/closing or backgrounding a note
        // shouldn't reorder the library's "Date Modified" sort.
        if isDirty { meta.modifiedAt = Date() }
        isDirty = false
        refreshMetaSummary()
        let folder = self.folder
        let contentData = try? Storage.encoder.encode(content)
        let metaData = try? Storage.encoder.encode(meta)
        let drawingData = drawing.dataRepresentation()
        Storage.ioQueue.async {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? contentData?.write(to: folder.appendingPathComponent("content.json"), options: .atomic)
            try? drawingData.write(to: folder.appendingPathComponent("drawing.data"), options: .atomic)
            try? metaData?.write(to: folder.appendingPathComponent("meta.json"), options: .atomic)
        }
        onMetaChanged?(meta)
    }

    /// Recomputes the parts of the meta the library shows (page count, open questions, paper
    /// score). Returns whether anything changed.
    @discardableResult
    func refreshMetaSummary() -> Bool {
        let before = meta
        meta.pageCount = content.pages.count
        meta.hasAudio = !content.recordings.isEmpty
        meta.layout = content.layout
        meta.paperScore = content.paper.map { p in
            p.markedCount > 0 ? "\(p.awardedMarks)/\(p.markedMarks)" : (p.totalMarks > 0 ? "\(p.totalMarks) marks" : "Past paper")
        }
        meta.openQuestions = content.elements.filter { if case .question(let q) = $0.kind { return q.status == .open }; return false }.count
        return meta != before
    }

    // MARK: Geometry

    var isFreeform: Bool { content.layout == .freeform }

    // A board fills the whole canvas: no margins around it and no gaps (it has one page).
    var topMargin: CGFloat { isFreeform ? 0 : NoteDocument.topMargin }
    var sideMargin: CGFloat { isFreeform ? 0 : NoteDocument.sideMargin }
    var pageGap: CGFloat { isFreeform ? 0 : NoteDocument.pageGap }
    var footerHeight: CGFloat { isFreeform ? 0 : NoteDocument.footerHeight }

    var pageSize: CGSize { CGSize(width: content.pageSize.width, height: content.pageSize.height) }

    var documentSize: CGSize {
        let h = topMargin + CGFloat(content.pages.count) * (pageSize.height + pageGap) + footerHeight
        return CGSize(width: pageSize.width + 2 * sideMargin, height: h)
    }

    func pageOrigin(_ index: Int) -> CGPoint {
        CGPoint(x: sideMargin, y: topMargin + CGFloat(index) * (pageSize.height + pageGap))
    }

    func pageRect(_ index: Int) -> CGRect {
        CGRect(origin: pageOrigin(index), size: pageSize)
    }

    /// Converts a page-relative rect to document coordinates.
    func docRect(_ rect: CGRect, page: Int) -> CGRect {
        rect.offsetBy(dx: pageOrigin(page).x, dy: pageOrigin(page).y)
    }

    func docRect(for element: CanvasElement) -> CGRect {
        docRect(element.frame, page: element.pageIndex)
    }

    /// The page under a document point (clamped to the nearest page).
    func pageIndex(at docPoint: CGPoint) -> Int {
        let stride = pageSize.height + pageGap
        let raw = Int(floor((docPoint.y - topMargin + pageGap / 2) / stride))
        return max(0, min(content.pages.count - 1, raw))
    }

    // MARK: Freeform board

    static let boardInitialSize = PageSize(width: 2048, height: 2048)
    static let boardGrowStep: CGFloat = 1024
    static let boardMaxSide: CGFloat = 16_384
    /// Free board kept to the right of and below everything, so there's always room to keep going.
    static let boardEdgeRoom: CGFloat = 640

    /// Grows a freeform board so the given board rects keep `boardEdgeRoom` of free space to the
    /// right and below. Boards only grow right and down; the top-left corner is the origin.
    func growBoardIfNeeded(toFit rects: [CGRect]) {
        guard isFreeform, !rects.isEmpty else { return }
        var w = content.pageSize.width, h = content.pageSize.height
        let step = NoteDocument.boardGrowStep, maxSide = NoteDocument.boardMaxSide
        for r in rects where !r.isNull && r.width.isFinite && r.height.isFinite {
            if r.maxX + NoteDocument.boardEdgeRoom > w { w = min(maxSide, (ceil((r.maxX + NoteDocument.boardEdgeRoom) / step) * step)) }
            if r.maxY + NoteDocument.boardEdgeRoom > h { h = min(maxSide, (ceil((r.maxY + NoteDocument.boardEdgeRoom) / step) * step)) }
        }
        guard w > content.pageSize.width || h > content.pageSize.height else { return }
        content.pageSize = PageSize(width: max(w, content.pageSize.width), height: max(h, content.pageSize.height))
        canvas?.documentDidChangePages()
        markDirty()
    }

    /// Everything on a freeform board (ink and elements), in board coordinates; nil when empty.
    var boardContentBounds: CGRect? {
        var r = CGRect.null
        for s in drawing.strokes { r = r.union(s.renderBounds) }
        for e in content.elements { r = r.union(e.frame) }
        return r.isNull ? nil : r
    }

    /// Where the tutor should place new work. Pages: the whole page. Boards: the part the student
    /// is looking at, extended downward so longer working still has room (the board grows to fit).
    var tutorWorkArea: CGRect {
        guard isFreeform else { return CGRect(origin: .zero, size: pageSize) }
        let v = boardViewRect
        return CGRect(x: v.minX, y: v.minY, width: v.width, height: min(NoteDocument.boardMaxSide - v.minY, v.height + 1400))
    }

    /// The part of the board the student is looking at, at least 600 pt square (zoomed right in,
    /// the view itself is too small to work in) and kept on the board.
    var boardViewRect: CGRect {
        let board = CGRect(origin: .zero, size: pageSize)
        var v = (visibleBoardRect ?? CGRect(x: 0, y: 0, width: 1000, height: 1200)).intersection(board)
        if v.isNull { v = CGRect(x: 0, y: 0, width: 1000, height: 1200).intersection(board) }
        let minSide: CGFloat = 600
        if v.width < minSide { v = v.insetBy(dx: -(minSide - v.width) / 2, dy: 0) }
        if v.height < minSide { v = v.insetBy(dx: 0, dy: -(minSide - v.height) / 2) }
        v.origin.x = max(0, min(v.minX, board.width - v.width))
        v.origin.y = max(0, min(v.minY, board.height - v.height))
        return v.intersection(board)
    }

    func pagePoint(fromDoc p: CGPoint) -> (page: Int, point: CGPoint) {
        let i = pageIndex(at: p)
        let o = pageOrigin(i)
        return (i, CGPoint(x: p.x - o.x, y: p.y - o.y))
    }

    func pageRectFromDoc(_ r: CGRect) -> (page: Int, rect: CGRect) {
        let i = pageIndex(at: r.center)
        let o = pageOrigin(i)
        return (i, r.offsetBy(dx: -o.x, dy: -o.y))
    }

    /// Ink strokes whose bounds intersect the given page.
    func strokes(onPage index: Int) -> [PKStroke] {
        let rect = pageRect(index)
        return drawing.strokes.filter { $0.renderBounds.intersects(rect) }
    }

    // MARK: Elements

    func element(_ id: String) -> CanvasElement? {
        content.elements.first { $0.id == id }
    }

    func nextElementID() -> String {
        let n = content.nextElementNumber
        content.nextElementNumber += 1
        return "e\(n)"
    }

    func nextQuestionNumber() -> Int {
        let n = content.nextQuestionNumber
        content.nextQuestionNumber += 1
        return n
    }

    func elements(onPage index: Int) -> [CanvasElement] {
        content.elements.filter { $0.pageIndex == index }
    }

    func add(_ element: CanvasElement, reveal: RevealStyle = .none, actionName: String? = nil) {
        content.elements.append(element)
        // Grow first, so the canvas can scroll to where the element lands.
        growBoardIfNeeded(toFit: [element.frame])
        canvas?.documentDidAddElement(element, reveal: reveal)
        undoManager.registerUndo(withTarget: self) { doc in
            doc.remove(element.id, actionName: actionName)
        }
        if let actionName { undoManager.setActionName(actionName) }
        markDirty()
    }

    func update(_ id: String, actionName: String? = nil, registerUndo: Bool = true, _ change: (inout CanvasElement) -> Void) {
        guard let idx = content.elements.firstIndex(where: { $0.id == id }) else { return }
        let before = content.elements[idx]
        var after = before
        change(&after)
        guard after != before else { return }
        content.elements[idx] = after
        growBoardIfNeeded(toFit: [after.frame])
        canvas?.documentDidUpdateElement(after)
        if registerUndo {
            undoManager.registerUndo(withTarget: self) { doc in
                doc.update(id, actionName: actionName) { $0 = before }
            }
            if let actionName { undoManager.setActionName(actionName) }
        }
        markDirty()
    }

    func remove(_ id: String, actionName: String? = nil) {
        guard let idx = content.elements.firstIndex(where: { $0.id == id }) else { return }
        let removed = content.elements.remove(at: idx)
        canvas?.documentDidRemoveElement(id: id)
        undoManager.registerUndo(withTarget: self) { doc in
            doc.insert(removed, at: idx, actionName: actionName)
        }
        if let actionName { undoManager.setActionName(actionName) }
        markDirty()
    }

    private func insert(_ element: CanvasElement, at index: Int, actionName: String?) {
        let i = min(index, content.elements.count)
        content.elements.insert(element, at: i)
        canvas?.documentDidAddElement(element, reveal: .none)
        undoManager.registerUndo(withTarget: self) { doc in
            doc.remove(element.id, actionName: actionName)
        }
        markDirty()
    }

    /// Restores an element exactly as it was (used by "undo tutor's changes").
    func restore(_ element: CanvasElement) {
        if content.elements.contains(where: { $0.id == element.id }) {
            update(element.id) { $0 = element }
        } else {
            add(element)
        }
    }

    // MARK: Ink

    /// Called by the canvas whenever PencilKit changes the drawing (student strokes, erasing, lasso).
    func canvasDrawingChanged(_ newDrawing: PKDrawing) {
        drawing = newDrawing
        markDirty()
    }

    /// Replaces the drawing programmatically (tutor erasing ink, page operations).
    func replaceDrawing(_ newDrawing: PKDrawing, actionName: String? = nil, registerUndo: Bool = true) {
        let before = drawing
        drawing = newDrawing
        canvas?.documentDidReplaceDrawing()
        if registerUndo {
            undoManager.registerUndo(withTarget: self) { doc in
                doc.replaceDrawing(before, actionName: actionName)
            }
            if let actionName { undoManager.setActionName(actionName) }
        }
        markDirty()
    }

    // MARK: Pages

    func appendPage(paper: PaperStyle? = nil) {
        let style = paper ?? content.pages.last?.paper ?? .standard
        content.pages.append(Page(paper: style))
        canvas?.documentDidChangePages()
        markDirty()
    }

    /// Inserts a blank page after `index`, shifting ink and elements below it down.
    func insertPage(after index: Int, paper: PaperStyle? = nil) {
        let insertAt = index + 1
        guard insertAt < content.pages.count else {
            appendPage(paper: paper)
            return
        }
        let style = paper ?? content.pages[index].paper
        let shiftFromY = pageOrigin(insertAt).y - NoteDocument.pageGap / 2
        let dy = pageSize.height + NoteDocument.pageGap
        content.pages.insert(Page(paper: style), at: insertAt)
        for i in content.elements.indices where content.elements[i].pageIndex >= insertAt {
            content.elements[i].pageIndex += 1
        }
        // Work on a local copy: every `PKDrawing.strokes` access bridges the whole array.
        var strokes = drawing.strokes
        for i in strokes.indices where strokes[i].renderBounds.midY > shiftFromY {
            strokes[i].transform = strokes[i].transform.concatenating(CGAffineTransform(translationX: 0, y: dy))
        }
        drawing.strokes = strokes
        undoManager.removeAllActions()
        canvas?.documentDidChangePages()
        canvas?.documentDidReplaceDrawing()
        markDirty()
    }

    /// Deletes a page together with its ink and elements. Not undoable (asks for confirmation in UI).
    func deletePage(_ index: Int) {
        guard content.pages.count > 1, content.pages.indices.contains(index) else { return }
        let rect = pageRect(index).insetBy(dx: -NoteDocument.sideMargin, dy: -NoteDocument.pageGap / 2)
        let dy = pageSize.height + NoteDocument.pageGap
        var strokes = drawing.strokes
        strokes.removeAll { rect.contains($0.renderBounds.center) }
        for i in strokes.indices where strokes[i].renderBounds.midY > rect.maxY {
            strokes[i].transform = strokes[i].transform.concatenating(CGAffineTransform(translationX: 0, y: -dy))
        }
        drawing.strokes = strokes
        let removedIDs = content.elements.filter { $0.pageIndex == index }.map(\.id)
        content.elements.removeAll { $0.pageIndex == index }
        for i in content.elements.indices where content.elements[i].pageIndex > index {
            content.elements[i].pageIndex -= 1
        }
        content.pages.remove(at: index)
        undoManager.removeAllActions()
        for id in removedIDs { canvas?.documentDidRemoveElement(id: id) }
        canvas?.documentDidChangePages()
        canvas?.documentDidReplaceDrawing()
        markDirty()
    }

    func duplicatePage(_ index: Int) {
        guard content.pages.indices.contains(index) else { return }
        let source = content.pages[index]
        insertPage(after: index, paper: source.paper)
        content.pages[index + 1].pdfAssetID = source.pdfAssetID
        content.pages[index + 1].pdfPageIndex = source.pdfPageIndex
        let dy = pageSize.height + NoteDocument.pageGap
        let rect = pageRect(index)
        var d = drawing
        let copies = d.strokes.filter { rect.contains($0.renderBounds.center) }.map { stroke -> PKStroke in
            var s = stroke
            s.transform = s.transform.concatenating(CGAffineTransform(translationX: 0, y: dy))
            return s
        }
        d.strokes.append(contentsOf: copies)
        drawing = d
        for e in content.elements where e.pageIndex == index {
            var copy = e
            copy.id = nextElementID()
            copy.pageIndex = index + 1
            content.elements.append(copy)
            canvas?.documentDidAddElement(copy, reveal: .none)
        }
        canvas?.documentDidChangePages()
        canvas?.documentDidReplaceDrawing()
        markDirty()
    }

    func setPaper(_ paper: PaperStyle, forPage index: Int?) {
        if let index, content.pages.indices.contains(index) {
            content.pages[index].paper = paper
        } else {
            for i in content.pages.indices { content.pages[i].paper = paper }
            meta.paper = paper
        }
        canvas?.documentDidChangePages()
        markDirty()
    }

    // MARK: Assets

    var assetsFolder: URL { Storage.assetsFolder(for: id) }

    func assetURL(_ name: String) -> URL { assetsFolder.appendingPathComponent(name) }

    /// Stores image data (downscaled to a sensible size) and returns its asset id.
    func storeImage(_ image: UIImage) -> String? {
        let maxSide: CGFloat = 2400
        var img = image
        let longest = max(image.size.width, image.size.height)
        if longest > maxSide {
            let scale = maxSide / longest
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            // Scale 1 so the result really is `maxSide` pixels (the default format uses the screen scale).
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            img = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        }
        guard let data = img.jpegData(compressionQuality: 0.86) else { return nil }
        let name = "img-\(UUID().uuidString.prefix(8)).jpg"
        do {
            try data.write(to: assetURL(name), options: .atomic)
            imageCache[name] = img
            return name
        } catch {
            return nil
        }
    }

    /// Stores raw asset bytes (images pasted from another note) and returns the asset id.
    func storeAsset(_ data: Data, ext: String) -> String? {
        let name = "img-\(UUID().uuidString.prefix(8)).\(ext)"
        do {
            try data.write(to: assetURL(name), options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    func image(_ assetID: String) -> UIImage? {
        if let img = imageCache[assetID] { return img }
        guard let img = UIImage(contentsOfFile: assetURL(assetID).path) else { return nil }
        imageCache[assetID] = img
        return img
    }

    func storePDF(from url: URL) -> String? {
        let name = "pdf-\(UUID().uuidString.prefix(8)).pdf"
        let needsStop = url.startAccessingSecurityScopedResource()
        defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.copyItem(at: url, to: assetURL(name))
            return name
        } catch {
            return nil
        }
    }

    func pdf(_ assetID: String) -> CGPDFDocument? {
        if let d = pdfCache[assetID] { return d }
        guard let d = CGPDFDocument(assetURL(assetID) as CFURL) else { return nil }
        pdfCache[assetID] = d
        return d
    }

    /// Appends one page per PDF page with the PDF drawn as the page background.
    func importPDFPages(assetID: String, replaceFirstBlankPage: Bool) {
        guard let pdf = pdf(assetID) else { return }
        let count = pdf.numberOfPages
        guard count > 0 else { return }
        var startIndex = content.pages.count
        let firstIsBlank = content.pages.count == 1 && content.elements.isEmpty && drawing.strokes.isEmpty && content.pages[0].pdfAssetID == nil
        if replaceFirstBlankPage && firstIsBlank {
            content.pages.removeAll()
            startIndex = 0
            if let first = pdf.page(at: 1) {
                let box = first.getBoxRect(.cropBox)
                let rotated = first.rotationAngle % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
                if rotated.width > 0 {
                    content.pageSize = PageSize(width: 816, height: (816 * rotated.height / rotated.width).rounded())
                }
            }
        }
        for i in 0..<count {
            content.pages.append(Page(paper: PaperStyle(pattern: .blank, color: .white), pdfAssetID: assetID, pdfPageIndex: i))
        }
        _ = startIndex
        canvas?.documentDidChangePages()
        markDirty()
    }

    // MARK: Search

    /// Typed text in the note (student text boxes and tutor text), used together with OCR.
    var typedText: String {
        content.elements.compactMap { e -> String? in
            switch e.kind {
            case .text(let t): return t.rich ? RichTextParser.plainText(t.text) : t.text
            case .question(let q): return RichTextParser.plainText(q.prompt)
            case .math(let m): return m.lines.map(MathSpeech.readable).joined(separator: " ")
            default: return nil
            }
        }.joined(separator: "\n")
    }
}
