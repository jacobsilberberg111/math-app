import UIKit

/// Helpers for exporting a note as PDF or images.
extension PageRenderer {
    /// Longest side of an exported board image, in pixels.
    static let maxImageSide: CGFloat = 4096

    /// PDF metadata: the note's title and the app that made it.
    static func pdfFormat(for doc: NoteDocument) -> UIGraphicsPDFRendererFormat {
        var info: [String: Any] = [kCGPDFContextCreator as String: "Margin"]
        let title = doc.meta.title.trimmed
        if !title.isEmpty { info[kCGPDFContextTitle as String] = title }
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = info
        return format
    }

    /// The part of a board that exports: everything on it with a margin, at least a letter page,
    /// kept on the board. Nil only for a degenerate board.
    static func boardExportRegion(_ doc: NoteDocument) -> CGRect? {
        let board = CGRect(origin: .zero, size: doc.pageSize)
        var region = (doc.boardContentBounds ?? CGRect(x: 0, y: 0, width: 816, height: 1056)).insetBy(dx: -48, dy: -48)
        region.origin.x = max(0, region.minX)
        region.origin.y = max(0, region.minY)
        region.size.width = max(region.width, 816)
        region.size.height = max(region.height, 1056)
        region = region.intersection(board)
        return region.isEmpty ? nil : region
    }

    /// One PNG per page at 2x, named "<title> – Page N.png", in a fresh folder. A board is a
    /// single PNG of its exported region, scaled down to fit `maxImageSide`.
    static func exportImages(_ doc: NoteDocument) -> [URL]? {
        guard !doc.content.pages.isEmpty, let folder = ExportFiles.makeFolder() else { return nil }
        let title = ExportFiles.safeName(doc.meta.title)
        let env = environment(for: doc)
        do {
            if doc.isFreeform {
                guard let region = boardExportRegion(doc) else { return nil }
                let scale = min(2, maxImageSide / max(region.width, region.height))
                let data = pngData(size: region.size, scale: scale) { ctx in
                    ctx.translateBy(x: -region.minX, y: -region.minY)
                    drawPage(doc, page: 0, ctx: ctx, inkScale: max(0.05, scale), env: env, region: region)
                }
                let url = folder.appendingPathComponent(title + ".png")
                try data.write(to: url, options: .atomic)
                return [url]
            }
            var urls: [URL] = []
            for i in doc.content.pages.indices {
                let data = autoreleasepool {
                    pngData(size: doc.pageSize, scale: 2) { ctx in
                        drawPage(doc, page: i, ctx: ctx, inkScale: 2, env: env)
                    }
                }
                let url = folder.appendingPathComponent("\(title) – Page \(i + 1).png")
                try data.write(to: url, options: .atomic)
                urls.append(url)
            }
            return urls
        } catch {
            return nil
        }
    }

    /// Draws `size` points at `scale` pixels per point into an opaque, 8-bit PNG (a plain sRGB
    /// image even on wide-colour displays).
    private static func pngData(size: CGSize, scale: CGFloat, draw: (CGContext) -> Void) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let pixels = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        return UIGraphicsImageRenderer(size: pixels, format: format).pngData { rc in
            rc.cgContext.scaleBy(x: scale, y: scale)
            draw(rc.cgContext)
        }
    }
}
