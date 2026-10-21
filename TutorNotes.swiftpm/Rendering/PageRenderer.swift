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

    /// Ink rendered for a page (or just `region` of it, in page coordinates), always with light
    /// appearance so dark mode never inverts colours.
    static func inkImage(_ doc: NoteDocument, page: Int, scale: CGFloat, drawing: PKDrawing? = nil, region: CGRect? = nil) -> UIImage {
        let rect = region.map { doc.docRect($0, page: page) } ?? doc.pageRect(page)
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = (drawing ?? doc.drawing).image(from: rect, scale: scale)
        }
        return image
    }

    /// Draws one page (paper, PDF, elements, ink) into `ctx` at page coordinates. With `region`,
    /// only that part is drawn (needed for freeform boards, which can be huge).
    static func drawPage(_ doc: NoteDocument, page index: Int, ctx: CGContext, inkScale: CGFloat, env: RenderEnvironment,
                         patternAlpha: CGFloat = 1, excludeElement: String? = nil, region: CGRect? = nil) {
        let size = doc.pageSize
        let page = doc.content.pages[index]
        let pageRect = CGRect(origin: .zero, size: size)
        let area = region?.intersection(pageRect) ?? pageRect
        guard !area.isNull, area.width > 0, area.height > 0 else { return }
        if doc.isFreeform {
            PaperRenderer.drawBoard(page.paper, region: area, ctx: ctx, patternAlpha: patternAlpha)
        } else {
            PaperRenderer.drawPage(page, size: size, in: pageRect, ctx: ctx, pdf: page.pdfAssetID.flatMap { doc.pdf($0) }, patternAlpha: patternAlpha)
        }
        let elements = doc.elements(onPage: index).filter {
            $0.id != excludeElement && (region == nil || $0.frame.insetBy(dx: -40, dy: -40).intersects(area))
        }
        for e in elements where !e.drawsAboveInk {
            ElementRenderer.draw(e, in: ctx, rect: e.frame, env: env)
        }
        let ink = inkImage(doc, page: index, scale: inkScale, region: region == nil ? nil : area)
        UIGraphicsPushContext(ctx)
        ink.draw(in: area)
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
        /// The part of the page shown (page coordinates), and pixels per point.
        var region: CGRect
        var scale: CGFloat
    }

    /// Longest side of a board snapshot, in pixels (larger images are downscaled by the API anyway).
    static let maxSnapshotSide: CGFloat = 1568

    /// A page image at exactly 1 px per page point, with a faint labelled coordinate grid so the
    /// tutor can place things precisely, and an optional highlighted focus region.
    /// With `region` (page coordinates; used for freeform boards) only that part is shown, scaled
    /// down if needed so its longest side fits `maxSnapshotSide`; the grid labels stay in page
    /// coordinates either way.
    static func snapshot(_ doc: NoteDocument, page index: Int, focus: CGRect? = nil, grid: Bool = true, region: CGRect? = nil) -> Snapshot? {
        guard doc.content.pages.indices.contains(index) else { return nil }
        let pageRect = CGRect(origin: .zero, size: doc.pageSize)
        let area = (region?.intersection(pageRect) ?? pageRect).integral
        guard !area.isNull, area.width > 8, area.height > 8 else { return nil }
        let scale = region == nil ? 1 : min(1, maxSnapshotSide / max(area.width, area.height))
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let env = environment(for: doc, forSnapshot: true)
        let image = UIGraphicsImageRenderer(size: area.size, format: format).image { rc in
            let ctx = rc.cgContext
            ctx.translateBy(x: -area.minX, y: -area.minY)
            drawPage(doc, page: index, ctx: ctx, inkScale: max(0.4, 1.5 * scale), env: env, patternAlpha: 0.55, region: region == nil ? nil : area)
            if grid { drawCoordinateGrid(in: area, ctx: ctx, labelScale: 1 / scale) }
            if let focus {
                ctx.setStrokeColor(UIColor(hex: "#1C64F2").cgColor)
                ctx.setLineWidth(2 / scale)
                ctx.setLineDash(phase: 0, lengths: [8 / scale, 5 / scale])
                ctx.stroke(focus.insetBy(dx: -2, dy: -2))
                ctx.setLineDash(phase: 0, lengths: [])
            }
        }
        guard let data = image.jpegData(compressionQuality: 0.82) else { return nil }
        return Snapshot(pageIndex: index, jpeg: data, pixelSize: CGSize(width: area.width * scale, height: area.height * scale),
                        region: area, scale: scale)
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
            drawPage(doc, page: index, ctx: ctx, inkScale: scale, env: env, patternAlpha: 0.5, region: r)
        }
        return image.jpegData(compressionQuality: 0.85)
    }

    /// Faint blue lines every 50 points (labelled every 100) across `rect`, in page coordinates.
    /// `labelScale` > 1 when the image will be shown smaller than 1 px per point: lines and labels
    /// are drawn thicker and sparser so they stay readable.
    static func drawCoordinateGrid(in rect: CGRect, ctx: CGContext, labelScale: CGFloat = 1) {
        let color = UIColor(red: 0.2, green: 0.45, blue: 0.95, alpha: 1)
        let step: CGFloat = labelScale > 2.2 ? 100 : 50
        let labelStep: CGFloat = step * 2
        ctx.saveGState()
        ctx.setStrokeColor(color.withAlphaComponent(0.10).cgColor)
        ctx.setLineWidth(0.5 * labelScale)
        var x = (floor(rect.minX / step) + 1) * step
        while x < rect.maxX {
            ctx.move(to: CGPoint(x: x, y: rect.minY))
            ctx.addLine(to: CGPoint(x: x, y: rect.maxY))
            x += step
        }
        var y = (floor(rect.minY / step) + 1) * step
        while y < rect.maxY {
            ctx.move(to: CGPoint(x: rect.minX, y: y))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
            y += step
        }
        ctx.strokePath()
        UIGraphicsPushContext(ctx)
        let font = UIFont.monospacedDigitSystemFont(ofSize: 9 * labelScale, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color.withAlphaComponent(0.55)]
        x = (floor(rect.minX / labelStep) + 1) * labelStep
        while x < rect.maxX {
            NSAttributedString(string: "\(Int(x))", attributes: attrs).draw(at: CGPoint(x: x + 2 * labelScale, y: rect.minY + 2 * labelScale))
            x += labelStep
        }
        y = (floor(rect.minY / labelStep) + 1) * labelStep
        while y < rect.maxY {
            NSAttributedString(string: "\(Int(y))", attributes: attrs).draw(at: CGPoint(x: rect.minX + 2 * labelScale, y: y + labelScale))
            y += labelStep
        }
        UIGraphicsPopContext()
        ctx.restoreGState()
    }

    // MARK: Thumbnails

    static func thumbnail(_ doc: NoteDocument, page: Int = 0, width: CGFloat = 360) -> UIImage {
        if doc.isFreeform { return boardThumbnail(doc, width: width) }
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

    /// Library cards are portrait (about 0.77 wide per tall); boards show the part with content.
    static let cardAspect: CGFloat = 0.77

    /// The region of a board worth showing in a thumbnail: everything on it, padded and widened
    /// to the card's shape (the top-left corner of an empty board).
    static func boardThumbnailRegion(_ doc: NoteDocument) -> CGRect {
        var r = (doc.boardContentBounds ?? CGRect(x: 0, y: 0, width: 700, height: 700 / cardAspect)).insetBy(dx: -40, dy: -40)
        if r.width < 700 { r = r.insetBy(dx: -(700 - r.width) / 2, dy: 0) }
        if r.width / r.height > cardAspect {
            r = r.insetBy(dx: 0, dy: -(r.width / cardAspect - r.height) / 2)
        } else {
            r = r.insetBy(dx: -(r.height * cardAspect - r.width) / 2, dy: 0)
        }
        r.origin.x = max(0, r.minX)
        r.origin.y = max(0, r.minY)
        return r
    }

    static func boardThumbnail(_ doc: NoteDocument, width: CGFloat) -> UIImage {
        let region = boardThumbnailRegion(doc)
        let scale = width / region.width
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let env = environment(for: doc)
        let paper = doc.content.pages.first?.paper ?? .standard
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: region.height * scale), format: format).image { rc in
            let ctx = rc.cgContext
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -region.minX, y: -region.minY)
            // The region can run past the board's edge; fill it all with the paper first.
            PaperRenderer.drawBoard(paper, region: region, ctx: ctx)
            if !doc.content.pages.isEmpty {
                drawPage(doc, page: 0, ctx: ctx, inkScale: max(0.5, scale * 2), env: env, region: region)
            }
        }
    }

    // MARK: PDF export

    static func exportPDF(_ doc: NoteDocument) -> URL? {
        let size = doc.pageSize
        let safeTitle = doc.meta.title.replacingOccurrences(of: "/", with: "-").trimmed
        let url = FileManager.default.temporaryDirectory.appendingPathComponent((safeTitle.isEmpty ? "Note" : safeTitle) + ".pdf")
        if doc.isFreeform { return exportBoardPDF(doc, to: url) }
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

    /// A board exports as one PDF page covering everything on it.
    private static func exportBoardPDF(_ doc: NoteDocument, to url: URL) -> URL? {
        let board = CGRect(origin: .zero, size: doc.pageSize)
        var region = (doc.boardContentBounds ?? CGRect(x: 0, y: 0, width: 816, height: 1056)).insetBy(dx: -48, dy: -48)
        region.origin.x = max(0, region.minX)
        region.origin.y = max(0, region.minY)
        region.size.width = max(region.width, 816)
        region.size.height = max(region.height, 1056)
        region = region.intersection(board)
        guard !region.isNull else { return nil }
        // PDF pages top out around 14,400 points a side; very large boards are scaled to fit.
        let pageScale = min(1, 14_400 / max(region.width, region.height))
        let pageSize = CGSize(width: region.width * pageScale, height: region.height * pageScale)
        // Keep the ink bitmap to roughly 40 megapixels.
        let inkScale = min(3, max(0.5, sqrt(40_000_000 / (region.width * region.height))))
        let env = environment(for: doc)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))
        do {
            try renderer.writePDF(to: url) { rc in
                rc.beginPage()
                let ctx = rc.cgContext
                ctx.scaleBy(x: pageScale, y: pageScale)
                ctx.translateBy(x: -region.minX, y: -region.minY)
                drawPage(doc, page: 0, ctx: ctx, inkScale: inkScale, env: env, region: region)
            }
            return url
        } catch {
            return nil
        }
    }
}
