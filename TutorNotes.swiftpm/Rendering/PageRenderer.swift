import UIKit
import PencilKit

/// Renders whole pages off-screen: snapshots the tutor looks at, thumbnails, and PDF export.
@MainActor
enum PageRenderer {
    static func environment(for doc: NoteDocument, forSnapshot: Bool = false) -> RenderEnvironment {
        let settings = AppSettings.shared
        return RenderEnvironment(hand: settings.tutorHand, tutorHex: settings.tutorInkHex,
                                 image: { [weak doc] id in doc?.image(id) }, forSnapshot: forSnapshot)
    }

    /// Ink rendered for a page, always with light appearance so dark mode never inverts colours.
    static func inkImage(_ doc: NoteDocument, page: Int, scale: CGFloat, drawing: PKDrawing? = nil) -> UIImage {
        let rect = doc.pageRect(page)
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = (drawing ?? doc.drawing).image(from: rect, scale: scale)
        }
        return image
    }

    /// Draws one page (paper, PDF, elements, ink) into `ctx` at page coordinates.
    static func drawPage(_ doc: NoteDocument, page index: Int, ctx: CGContext, inkScale: CGFloat, env: RenderEnvironment,
                         patternAlpha: CGFloat = 1, excludeElement: String? = nil) {
        let size = doc.pageSize
        let page = doc.content.pages[index]
        let pageRect = CGRect(origin: .zero, size: size)
        PaperRenderer.drawPage(page, size: size, in: pageRect, ctx: ctx, pdf: page.pdfAssetID.flatMap { doc.pdf($0) }, patternAlpha: patternAlpha)
        let elements = doc.elements(onPage: index).filter { $0.id != excludeElement }
        for e in elements where !e.drawsAboveInk {
            ElementRenderer.draw(e, in: ctx, rect: e.frame, env: env)
        }
        let ink = inkImage(doc, page: index, scale: inkScale)
        UIGraphicsPushContext(ctx)
        ink.draw(in: pageRect)
        UIGraphicsPopContext()
        for e in elements where e.drawsAboveInk {
            ElementRenderer.draw(e, in: ctx, rect: e.frame, env: env)
        }
    }

    // MARK: Tutor snapshots

    struct Snapshot {
        var pageIndex: Int
        var jpeg: Data
        var pixelSize: CGSize
    }

    /// A page image at exactly 1 px per page point, with a faint labelled coordinate grid so the
    /// tutor can place things precisely, and an optional highlighted focus region.
    static func snapshot(_ doc: NoteDocument, page index: Int, focus: CGRect? = nil, grid: Bool = true) -> Snapshot? {
        guard doc.content.pages.indices.contains(index) else { return nil }
        let size = doc.pageSize
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let env = environment(for: doc, forSnapshot: true)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { rc in
            let ctx = rc.cgContext
            drawPage(doc, page: index, ctx: ctx, inkScale: 1.5, env: env, patternAlpha: 0.55)
            if grid { drawCoordinateGrid(size: size, ctx: ctx) }
            if let focus {
                ctx.setStrokeColor(UIColor(hex: "#1C64F2").cgColor)
                ctx.setLineWidth(2)
                ctx.setLineDash(phase: 0, lengths: [8, 5])
                ctx.stroke(focus.insetBy(dx: -2, dy: -2))
                ctx.setLineDash(phase: 0, lengths: [])
            }
        }
        guard let data = image.jpegData(compressionQuality: 0.82) else { return nil }
        return Snapshot(pageIndex: index, jpeg: data, pixelSize: size)
    }

    /// A sharper crop of a region (2x), so small handwriting is legible to the tutor.
    static func regionCrop(_ doc: NoteDocument, page index: Int, region: CGRect) -> Data? {
        guard doc.content.pages.indices.contains(index) else { return nil }
        let size = doc.pageSize
        let r = region.insetBy(dx: -16, dy: -16).intersection(CGRect(origin: .zero, size: size))
        guard !r.isNull, r.width > 8, r.height > 8 else { return nil }
        let scale = min(2.5, 1400 / max(r.width, r.height))
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let env = environment(for: doc, forSnapshot: true)
        let image = UIGraphicsImageRenderer(size: r.size, format: format).image { rc in
            let ctx = rc.cgContext
            ctx.translateBy(x: -r.minX, y: -r.minY)
            drawPage(doc, page: index, ctx: ctx, inkScale: scale, env: env, patternAlpha: 0.5)
        }
        return image.jpegData(compressionQuality: 0.85)
    }

    static func drawCoordinateGrid(size: CGSize, ctx: CGContext) {
        let color = UIColor(red: 0.2, green: 0.45, blue: 0.95, alpha: 1)
        ctx.saveGState()
        ctx.setStrokeColor(color.withAlphaComponent(0.10).cgColor)
        ctx.setLineWidth(0.5)
        var x: CGFloat = 50
        while x < size.width {
            ctx.move(to: CGPoint(x: x, y: 0))
            ctx.addLine(to: CGPoint(x: x, y: size.height))
            x += 50
        }
        var y: CGFloat = 50
        while y < size.height {
            ctx.move(to: CGPoint(x: 0, y: y))
            ctx.addLine(to: CGPoint(x: size.width, y: y))
            y += 50
        }
        ctx.strokePath()
        UIGraphicsPushContext(ctx)
        let font = UIFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color.withAlphaComponent(0.55)]
        x = 100
        while x < size.width {
            NSAttributedString(string: "\(Int(x))", attributes: attrs).draw(at: CGPoint(x: x + 2, y: 2))
            x += 100
        }
        y = 100
        while y < size.height {
            NSAttributedString(string: "\(Int(y))", attributes: attrs).draw(at: CGPoint(x: 2, y: y + 1))
            y += 100
        }
        UIGraphicsPopContext()
        ctx.restoreGState()
    }

    // MARK: Thumbnails

    static func thumbnail(_ doc: NoteDocument, page: Int = 0, width: CGFloat = 360) -> UIImage {
        let size = doc.pageSize
        let scale = width / size.width
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let env = environment(for: doc)
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: size.height * scale), format: format).image { rc in
            let ctx = rc.cgContext
            ctx.scaleBy(x: scale, y: scale)
            if doc.content.pages.indices.contains(page) {
                drawPage(doc, page: page, ctx: ctx, inkScale: max(0.5, scale * 2), env: env)
            }
        }
    }

    // MARK: PDF export

    static func exportPDF(_ doc: NoteDocument) -> URL? {
        let size = doc.pageSize
        let safeTitle = doc.meta.title.replacingOccurrences(of: "/", with: "-").trimmed
        let url = FileManager.default.temporaryDirectory.appendingPathComponent((safeTitle.isEmpty ? "Note" : safeTitle) + ".pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size))
        let env = environment(for: doc)
        do {
            try renderer.writePDF(to: url) { rc in
                for i in doc.content.pages.indices {
                    rc.beginPage()
                    drawPage(doc, page: i, ctx: rc.cgContext, inkScale: 3, env: env)
                }
            }
            return url
        } catch {
            return nil
        }
    }
}
