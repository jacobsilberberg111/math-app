import SwiftUI
import PencilKit

/// A self-test of the editing features, run in the simulator by CI (launch with `-feature-check`).
/// It drives the real code paths (lasso, conversion, find, pages, export, colours) on a fresh note
/// and prints "CHECK PASS|FAIL name: detail" lines, then "FEATURE_CHECK_DONE failures=N".
@MainActor
enum FeatureCheck {
    static var isOn: Bool { DemoDirector.arguments.contains("-feature-check") }
    static var failures = 0

    static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if !ok { failures += 1 }
        let d = detail()
        print("CHECK \(ok ? "PASS" : "FAIL") \(name)\(d.isEmpty ? "" : ": " + d)")
    }

    static func info(_ text: String) {
        print("CHECK INFO \(text)")
    }

    /// Strokes' bounds in document coordinates.
    static func inkBounds(_ strokes: [PKStroke]) -> CGRect {
        strokes.reduce(CGRect.null) { $0.union($1.renderBounds) }
    }

    static func close(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat) -> Bool { abs(a - b) <= tolerance }
}

extension DemoDirector {
    func runFeatureCheck() async {
        await wait(1.5)
        guard let library else { return }
        let meta = library.createNote(title: "Feature check", subjectID: nil, paper: PaperStyle(pattern: .blank, color: .white))
        openNote?(meta)
        let model = await waitForEditor()
        model.tutor.watching = false
        guard let canvas = await waitForCanvas(model) else {
            FeatureCheck.check("open note", false, "no canvas")
            finishFeatureCheck()
            return
        }
        await wait(1)
        await checkLasso(model, canvas)
        await checkConversion(model, canvas)
        await checkFind(model, canvas)
        await checkPages(model, canvas)
        await checkExport(model, library)
        await checkColours(model, canvas)
        finishFeatureCheck()
    }

    private func finishFeatureCheck() {
        print("FEATURE_CHECK_DONE failures=\(FeatureCheck.failures)")
        FileManager.default.createFile(atPath: NSTemporaryDirectory() + "feature-check-done", contents: Data())
    }

    /// Writes "2025 + 7 = 2032" on page `page` and returns how many strokes it took.
    private func writeSum(_ model: EditorModel, _ canvas: NoteCanvasViewController, page: Int = 0, y: CGFloat = 160) async -> Int {
        model.tools.kind = .pen
        await wait(0.3)
        let before = model.document.drawing.strokes.count
        let origin = model.document.pageOrigin(page)
        await handwrite("2025 + 7 = 2032", at: CGPoint(x: origin.x + 80, y: origin.y + y), size: 44,
                        color: UIColor(hex: "#1F2328"), width: 3.2, canvas: canvas, speed: 6)
        await wait(0.3)
        return model.document.drawing.strokes.count - before
    }

    // MARK: Lasso

    private func checkLasso(_ model: EditorModel, _ canvas: NoteCanvasViewController) async {
        let doc = model.document
        let n = await writeSum(model, canvas)
        FeatureCheck.check("write ink", n > 8, "\(n) strokes")
        model.tools.kind = .lasso
        await wait(0.4)
        canvas.setLassoSelection(strokes: Array(0..<n), elements: [])
        let start = canvas.lasso.bounds
        FeatureCheck.check("lasso select", !start.isNull && canvas.lasso.view?.isHidden == false && canvas.lasso.strokes.count == n)

        // Rotate 30° and move, as a drag would, then undo.
        let c = start.center
        let t = CGAffineTransform(translationX: -c.x, y: -c.y)
            .concatenating(CGAffineTransform(rotationAngle: .pi / 6))
            .concatenating(CGAffineTransform(translationX: c.x + 40, y: c.y + 60))
        canvas.liftLassoSelection()
        FeatureCheck.check("lasso lift hides ink", canvas.canvasView.drawing.strokes.count == doc.drawing.strokes.count - n)
        canvas.previewLasso(t)
        await wait(0.3)
        canvas.commitLasso(mode: .rotate, transform: t)
        let moved = FeatureCheck.inkBounds(Array(doc.drawing.strokes.prefix(n)))
        FeatureCheck.check("lasso rotate + move",
                           FeatureCheck.close(moved.midX, c.x + 40, 6) && FeatureCheck.close(moved.midY, c.y + 60, 6) && moved.height > start.height + 40,
                           "centre \(Int(moved.midX)),\(Int(moved.midY)) (want \(Int(c.x + 40)),\(Int(c.y + 60))), height \(Int(start.height))→\(Int(moved.height))")
        FeatureCheck.check("lasso selection follows", canvas.lasso.lift == nil && !canvas.lasso.bounds.isNull
                           && FeatureCheck.close(canvas.lasso.bounds.midX, moved.midX, 2))
        await wait(0.25)
        model.undo()
        await wait(0.3)
        let back = FeatureCheck.inkBounds(Array(doc.drawing.strokes.prefix(n)))
        FeatureCheck.check("lasso undo", FeatureCheck.close(back.midX, c.x, 1) && FeatureCheck.close(back.midY, c.y, 1) && canvas.lasso.isEmpty,
                           "centre \(Int(back.midX)),\(Int(back.midY))")

        // Scale up from the corner.
        canvas.setLassoSelection(strokes: Array(0..<n), elements: [])
        let o = canvas.lasso.bounds.origin
        let s = CGAffineTransform(translationX: -o.x, y: -o.y).concatenating(CGAffineTransform(scaleX: 1.5, y: 1.5))
            .concatenating(CGAffineTransform(translationX: o.x, y: o.y))
        canvas.liftLassoSelection()
        canvas.commitLasso(mode: .resize, transform: s)
        let big = FeatureCheck.inkBounds(Array(doc.drawing.strokes.prefix(n)))
        FeatureCheck.check("lasso resize", FeatureCheck.close(big.width, start.width * 1.5, start.width * 0.08), "width \(Int(start.width))→\(Int(big.width))")
        await wait(0.25)
        model.undo()
        await wait(0.3)

        // Recolour and thickness.
        canvas.setLassoSelection(strokes: Array(0..<n), elements: [])
        canvas.recolourLasso("#E03131")
        let colours = Set(doc.drawing.strokes.prefix(n).map { String($0.ink.color.hexString.prefix(7)).uppercased() })
        FeatureCheck.check("lasso recolour", colours == ["#E03131"], "\(colours)")
        await wait(0.25)
        canvas.rethickenLasso(.width(8))
        let sizes = doc.drawing.strokes.prefix(n).flatMap { $0.path.map(\.size.width) }.sorted()
        let median = sizes.isEmpty ? 0 : sizes[sizes.count / 2]
        FeatureCheck.check("lasso thickness", FeatureCheck.close(median, 8, 1.5), "median width \(median)")
        await wait(0.25)
        model.undo()
        await wait(0.2)
        model.undo()
        await wait(0.3)
        let undone = Set(doc.drawing.strokes.prefix(n).map { String($0.ink.color.hexString.prefix(7)).uppercased() })
        FeatureCheck.check("recolour undo", undone == ["#1F2328"], "\(undone)")

        // Copy, paste, duplicate, delete.
        canvas.setLassoSelection(strokes: Array(0..<n), elements: [])
        canvas.performLassoAction(.copy)
        FeatureCheck.check("clipboard has clip", CanvasClip.pasteboardHasContent)
        let page = doc.pageRect(0)
        canvas.pasteFromClipboard(at: CGPoint(x: page.midX, y: page.minY + 520))
        FeatureCheck.check("paste", doc.drawing.strokes.count == 2 * n && canvas.lasso.strokes.count == n,
                           "\(doc.drawing.strokes.count) strokes, \(canvas.lasso.strokes.count) selected")
        await wait(0.25)
        canvas.performLassoAction(.duplicate)
        FeatureCheck.check("duplicate", doc.drawing.strokes.count == 3 * n, "\(doc.drawing.strokes.count) strokes")
        await wait(0.25)
        canvas.performLassoAction(.delete)
        FeatureCheck.check("delete", doc.drawing.strokes.count == 2 * n && canvas.lasso.isEmpty, "\(doc.drawing.strokes.count) strokes")
        await wait(0.25)
        model.undo()
        await wait(0.3)
        FeatureCheck.check("delete undo", doc.drawing.strokes.count == 3 * n, "\(doc.drawing.strokes.count) strokes")

        // Items: a text box moves with the lasso.
        let text = CanvasElement(id: doc.nextElementID(), pageIndex: 0, frame: CGRect(x: 80, y: 760, width: 300, height: 40), author: .student,
                                 kind: .text(TextContent(text: "Photosynthesis", style: .typed, fontSize: 22, colorHex: "#1F2328", rich: false)))
        doc.add(text, actionName: "Add Text")
        await wait(0.25)
        canvas.setLassoSelection(strokes: [], elements: [text.id])
        canvas.liftLassoSelection()
        canvas.commitLasso(mode: .move, transform: CGAffineTransform(translationX: 30, y: 20))
        let f = doc.element(text.id)?.frame ?? .zero
        FeatureCheck.check("lasso moves items", FeatureCheck.close(f.minX, 110, 1) && FeatureCheck.close(f.minY, 780, 1), "\(f)")
        await wait(0.25)
        let g = canvas.lasso.bounds
        let grow = CGAffineTransform(translationX: -g.minX, y: -g.minY).concatenating(CGAffineTransform(scaleX: 2, y: 2))
            .concatenating(CGAffineTransform(translationX: g.minX, y: g.minY))
        canvas.liftLassoSelection()
        canvas.commitLasso(mode: .resize, transform: grow)
        var fontSize: CGFloat = 0
        if case .text(let t) = doc.element(text.id)?.kind { fontSize = t.fontSize }
        FeatureCheck.check("lasso scales text", FeatureCheck.close(fontSize, 44, 0.5), "font \(fontSize)")
        await wait(0.25)
        model.undo()
        await wait(0.3)
        canvas.clearLassoSelection()
        await wait(0.25)

        // Leave one copy of the sum (the original) for the next checks.
        let extra = doc.drawing.strokes.count - n
        canvas.setLassoSelection(strokes: Array(n..<(n + extra)), elements: [])
        canvas.performLassoAction(.delete)
        FeatureCheck.check("cleanup", doc.drawing.strokes.count == n, "\(doc.drawing.strokes.count) strokes")
    }

    // MARK: Convert

    private func checkConversion(_ model: EditorModel, _ canvas: NoteCanvasViewController) async {
        let doc = model.document
        let n = doc.drawing.strokes.count
        model.tools.kind = .lasso
        await wait(0.3)
        canvas.setLassoSelection(strokes: Array(0..<n), elements: [])
        model.canvasConvertLasso(.text)
        guard let conversion = model.inkConversion else {
            FeatureCheck.check("convert to text starts", false)
            return
        }
        for _ in 0..<60 where conversion.phase == .working { await wait(0.5) }
        FeatureCheck.info("text read: \(conversion.text.replacingOccurrences(of: "\n", with: " / ")) phase \(conversion.phase)")
        FeatureCheck.check("convert to text reads", conversion.phase == .ready && !conversion.text.trimmed.isEmpty)
        if conversion.phase == .ready {
            let elements = doc.content.elements.count
            model.finishInkConversion(conversion)
            await wait(0.3)
            let added = doc.content.elements.last
            var isText = false
            if let added, case .text = added.kind { isText = added.author == .student }
            FeatureCheck.check("convert to text replaces ink", doc.drawing.strokes.isEmpty && doc.content.elements.count == elements + 1 && isText,
                               "\(doc.drawing.strokes.count) strokes left")
            model.undo()
            await wait(0.3)
            FeatureCheck.check("convert to text undo", doc.drawing.strokes.count == n && doc.content.elements.count == elements)
        } else {
            model.cancelInkConversion()
        }
        await wait(0.6)

        // Maths needs the tutor connection; without one the sheet says so instead of calling the API.
        canvas.setLassoSelection(strokes: Array(0..<n), elements: [])
        if AppSettings.shared.isTutorConfigured {
            FeatureCheck.info("tutor is connected: skipping the no-connection maths check")
        } else {
            model.canvasConvertLasso(.math)
            FeatureCheck.check("convert to math needs connection", model.inkConversion?.phase == .needsConnection)
            model.cancelInkConversion()
        }
        let parsed = MathTranscriber.parse("```json\n{\"lines\": [\"$2x + 3 = 7$\", \"x = 2\"]}\n```")
        FeatureCheck.check("math reply parsing", parsed == ["2x + 3 = 7", "x = 2"], "\(parsed)")
        await wait(0.6)
        canvas.clearLassoSelection()
    }

    // MARK: Find

    private func checkFind(_ model: EditorModel, _ canvas: NoteCanvasViewController) async {
        let find = model.find
        find.open()
        find.query = "photo"
        await wait(0.5)
        FeatureCheck.check("find typed text", find.matches.count == 1 && find.currentIndex == 0, "\(find.matches.count) matches")
        find.query = "2025"
        for _ in 0..<60 {
            await wait(0.5)
            if !find.isReading && !find.matches.isEmpty { break }
        }
        FeatureCheck.info("handwriting matches for 2025: \(find.matches.count)")
        FeatureCheck.check("find handwriting", !find.matches.isEmpty)
        find.close()
        FeatureCheck.check("find closes", !find.isOpen && find.matches.isEmpty)
    }

    // MARK: Pages

    private func checkPages(_ model: EditorModel, _ canvas: NoteCanvasViewController) async {
        let doc = model.document
        canvas.clearLassoSelection()
        doc.appendPage()
        doc.appendPage()
        await wait(0.3)
        let n = await writeSum(model, canvas, page: 1, y: 300)
        let ids = doc.content.pages.map(\.id)
        let onPage1 = { doc.drawing.strokes.filter { doc.pageRect(1).contains($0.renderBounds.center) }.count }
        let page1Before = onPage1()
        FeatureCheck.check("ink on page 2", n > 0 && page1Before == n, "\(page1Before) of \(n)")

        model.movePage(from: 1, to: 0)
        await wait(0.3)
        let onPage0 = doc.drawing.strokes.filter { doc.pageRect(0).contains($0.renderBounds.center) }.count
        FeatureCheck.check("move page", doc.content.pages.first?.id == ids[1] && onPage0 == n, "\(onPage0) strokes moved with it")
        model.undo()
        await wait(0.3)
        FeatureCheck.check("move page undo", doc.content.pages.map(\.id) == ids && onPage1() == n)

        model.setPageSize(.a4Landscape)
        await wait(0.3)
        FeatureCheck.check("page size", doc.content.pageSize == .a4Landscape && onPage1() == n,
                           "\(doc.content.pageSize), \(onPage1()) strokes on page 2")
        model.undo()
        await wait(0.3)
        FeatureCheck.check("page size undo", doc.content.pageSize == .letter && onPage1() == n)

        model.clearPage(1)
        await wait(0.3)
        FeatureCheck.check("clear page", onPage1() == 0 && doc.content.pages.count == 3)
        model.undo()
        await wait(0.3)
        FeatureCheck.check("clear page undo", onPage1() == n)

        // Undoing a move after a page was added since keeps the new page.
        model.movePage(from: 1, to: 0)
        await wait(0.3)
        doc.appendPage()
        await wait(0.3)
        model.undo()
        await wait(0.3)
        FeatureCheck.check("move undo keeps added page", doc.content.pages.count == 4 && Array(doc.content.pages.prefix(3).map(\.id)) == ids
                           && onPage1() == n, "\(doc.content.pages.count) pages")

        // Ink near the bottom of a page stays on it when the pages get shorter.
        let low = await writeSum(model, canvas, page: 2, y: 980)
        let onPage2 = { doc.drawing.strokes.filter { doc.pageRect(2).contains($0.renderBounds.center) }.count }
        model.setPageSize(.a4Landscape)
        await wait(0.3)
        FeatureCheck.check("page size keeps ink on its page", onPage2() == low && onPage1() == n, "\(onPage2()) of \(low)")
        model.undo()
        await wait(0.3)
    }

    // MARK: Export

    private func checkExport(_ model: EditorModel, _ library: LibraryStore) async {
        let doc = model.document
        let size = { (url: URL) -> Int in (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0 }
        let pdf = NoteExporter.files(for: .pdf, document: doc)
        FeatureCheck.check("export PDF", pdf?.count == 1 && (pdf.map { size($0[0]) } ?? 0) > 2000, "\(pdf.map { size($0[0]) } ?? 0) bytes")
        let images = NoteExporter.files(for: .images, document: doc) ?? []
        FeatureCheck.check("export images", images.count == doc.content.pages.count && images.allSatisfy { size($0) > 2000 },
                           "\(images.count) files")
        guard let file = NoteExporter.files(for: .noteFile, document: doc)?.first else {
            FeatureCheck.check("export note file", false)
            return
        }
        FeatureCheck.check("export note file", file.pathExtension == "margin" && size(file) > 1000, "\(size(file)) bytes")
        do {
            let imported = try library.importNoteFile(at: file)
            let copy = NoteDocument.load(meta: imported)
            FeatureCheck.check("import note file", imported.id != doc.id && copy.content.pages.count == doc.content.pages.count
                               && copy.drawing.strokes.count == doc.drawing.strokes.count
                               && copy.content.elements.count == doc.content.elements.count
                               && library.notes.contains { $0.id == imported.id },
                               "\(copy.content.pages.count) pages, \(copy.drawing.strokes.count) strokes")
        } catch {
            FeatureCheck.check("import note file", false, error.localizedDescription)
        }

        // A note file naming files outside its folder is refused.
        var content = NoteContent()
        content.attachments = [TutorAttachment(id: "a1", name: "worksheet.pdf", kind: .pdf, mimeType: "application/pdf",
                                               localFile: "../../..", sizeBytes: 1)]
        let crafted = NoteArchive(meta: NoteMeta(title: "Crafted"), content: content, drawing: Data(), assets: [:])
        let refused: Bool
        if let data = try? crafted.encoded() {
            do { _ = try NoteArchive.decode(data); refused = false } catch { refused = true }
        } else {
            refused = false
        }
        FeatureCheck.check("crafted note file refused", refused && doc.assetURL("../../x").path == doc.assetsFolder.appendingPathComponent("x").path)
    }

    // MARK: Colours

    private func checkColours(_ model: EditorModel, _ canvas: NoteCanvasViewController) async {
        let favourites = ColorFavorites.shared
        let added = favourites.add("#123456")
        FeatureCheck.check("favourite add", added && favourites.contains("#123456") && !favourites.add("#123456"))
        favourites.remove("#123456")
        FeatureCheck.check("favourite remove", !favourites.contains("#123456"))

        // Eyedropper on a fat red stroke.
        let doc = model.document
        model.tools.kind = .pen
        await wait(0.3)
        let o = doc.pageOrigin(0)
        let line = (0...30).map { CGPoint(x: o.x + 500 + CGFloat($0) * 4, y: o.y + 900) }
        var d = doc.drawing
        d.strokes.append(Handwriting.pkStroke(line, color: UIColor(hex: "#E03131"), width: 14))
        doc.replaceDrawing(d, actionName: "Draw")
        await wait(0.3)
        var picked: String?
        canvas.beginEyedropper { picked = $0 }
        canvas.finishEyedropper(at: CGPoint(x: o.x + 560, y: o.y + 900))
        let rgb = picked.map(ColorSampler.rgb(hex:))
        let reddish = rgb.map { $0.r > 180 && $0.g < 110 && $0.b < 110 } ?? false
        FeatureCheck.check("eyedropper", reddish, picked ?? "nothing picked")
        canvas.beginEyedropper { picked = $0 }
        canvas.finishEyedropper(at: CGPoint(x: o.x + 700, y: o.y + 990))
        FeatureCheck.check("eyedropper on paper", picked?.uppercased() == "#FFFFFF", picked ?? "nothing picked")
    }
}
