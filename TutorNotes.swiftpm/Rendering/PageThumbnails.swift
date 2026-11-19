import UIKit
import PencilKit

/// Page thumbnails for the Pages sheet: drawn at screen scale, the paper, PDF and ink off the main
/// thread, and kept per page so a page that hasn't changed doesn't redraw (and one that has shows
/// its old picture until the new one is ready).
@MainActor
final class PageThumbnails {
    static let shared = PageThumbnails()

    /// What a thumbnail was drawn from; it's redrawn when any of it changes.
    private struct Key: Equatable {
        var page: Page
        var pageSize: PageSize
        var width: CGFloat
        var elements: [CanvasElement]
        var ink: Int
    }

    private final class Entry {
        let key: Key
        let image: UIImage
        init(key: Key, image: UIImage) {
            self.key = key
            self.image = image
        }
    }

    private struct InkIndex {
        var note: ObjectIdentifier
        var revision: Int
        var strokes: [[PKStroke]]
        var prints: [Int]
    }

    private let cache = NSCache<NSUUID, Entry>()
    /// Each page's strokes and their fingerprint, from one pass over the note's ink, reused until it changes.
    private var inkIndex: InkIndex?

    private init() {
        cache.totalCostLimit = 96 * 1024 * 1024
    }

    /// The last picture made of a page, possibly out of date, if the pages are still that shape.
    func latest(_ pageID: UUID, pageSize: PageSize) -> UIImage? {
        guard let e = cache.object(forKey: pageID as NSUUID), e.key.pageSize == pageSize else { return nil }
        return e.image
    }

    /// Lets go of the ink sorted by page (when the Pages sheet closes).
    func releaseInk() {
        inkIndex = nil
    }

    func thumbnail(_ doc: NoteDocument, page index: Int, width: CGFloat, scale screenScale: CGFloat) async -> UIImage? {
        guard doc.content.pages.indices.contains(index) else { return nil }
        // Boards have one page; this sheet isn't shown for them.
        if doc.isFreeform { return PageRenderer.thumbnail(doc, page: index, width: width) }
        let page = doc.content.pages[index]
        let ink = inkFor(doc)
        let elements = doc.elements(onPage: index)
        let key = Key(page: page, pageSize: doc.content.pageSize, width: width * screenScale, elements: elements,
                      ink: ink.prints[safe: index] ?? 0)
        if let e = cache.object(forKey: page.id as NSUUID), e.key == key { return e.image }

        let pageSize = doc.pageSize
        let k = width / pageSize.width
        let size = CGSize(width: width, height: (pageSize.height * k).rounded())
        let scale = max(1, screenScale)
        // Items are drawn here (their renderer belongs to the main actor), on their own layers.
        let env = PageRenderer.environment(for: doc)
        let under = PageThumbnails.layer(elements.filter { !$0.drawsAboveInk }, size: size, k: k, scale: scale, env: env)
        let over = PageThumbnails.layer(elements.filter(\.drawsAboveInk), size: size, k: k, scale: scale, env: env)
        let pdf = page.pdfAssetID.flatMap { doc.pdf($0) }
        var drawing = PKDrawing()
        drawing.strokes = ink.strokes[safe: index] ?? []
        let inkRect = doc.pageRect(index)
        let image = await Task.detached(priority: .userInitiated) {
            PageThumbnails.compose(size: size, scale: scale, k: k, page: page, pageSize: pageSize, pdf: pdf,
                                   under: under, over: over, ink: drawing, inkRect: inkRect)
        }.value
        let cost = Int(size.width * scale * size.height * scale * 4)
        cache.setObject(Entry(key: key, image: image), forKey: page.id as NSUUID, cost: cost)
        return image
    }

    // MARK: Drawing

    private static func layer(_ elements: [CanvasElement], size: CGSize, k: CGFloat, scale: CGFloat, env: RenderEnvironment) -> UIImage? {
        guard !elements.isEmpty else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { rc in
            rc.cgContext.scaleBy(x: k, y: k)
            for e in elements { ElementRenderer.draw(e, in: rc.cgContext, rect: e.frame, env: env) }
        }
    }

    nonisolated private static func compose(size: CGSize, scale: CGFloat, k: CGFloat, page: Page, pageSize: CGSize, pdf: CGPDFDocument?,
                                            under: UIImage?, over: UIImage?, ink: PKDrawing, inkRect: CGRect) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let bounds = CGRect(origin: .zero, size: size)
        return UIGraphicsImageRenderer(size: size, format: format).image { rc in
            let ctx = rc.cgContext
            ctx.saveGState()
            ctx.scaleBy(x: k, y: k)
            PaperRenderer.drawPage(page, size: pageSize, in: CGRect(origin: .zero, size: pageSize), ctx: ctx, pdf: pdf)
            ctx.restoreGState()
            under?.draw(in: bounds)
            if !ink.strokes.isEmpty {
                // Always light: dark mode must never invert the ink colours.
                var inkImage = UIImage()
                UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                    inkImage = ink.image(from: inkRect, scale: scale * k)
                }
                inkImage.draw(in: bounds)
            }
            over?.draw(in: bounds)
        }
    }

    // MARK: Ink by page

    /// Sorts the note's strokes onto the pages they touch, with a fingerprint per page so a
    /// thumbnail only redraws when its own ink changed.
    private func inkFor(_ doc: NoteDocument) -> InkIndex {
        let note = ObjectIdentifier(doc)
        if let i = inkIndex, i.note == note, i.revision == doc.revision, i.strokes.count == doc.content.pages.count { return i }
        let count = doc.content.pages.count
        var strokes = Array(repeating: [PKStroke](), count: count)
        var hashers = Array(repeating: Hasher(), count: count)
        for s in doc.drawing.strokes {
            let b = s.renderBounds
            guard !b.isNull, b.minY.isFinite, b.maxY.isFinite else { continue }
            let first = doc.pageIndex(at: CGPoint(x: 0, y: b.minY)), last = doc.pageIndex(at: CGPoint(x: 0, y: b.maxY))
            for p in first...max(first, last) where doc.pageRect(p).intersects(b) || first == last {
                strokes[p].append(s)
                hashers[p].combine(Double(b.minX))
                hashers[p].combine(Double(b.minY))
                hashers[p].combine(Double(b.width))
                hashers[p].combine(Double(b.height))
                hashers[p].combine(s.path.count)
                hashers[p].combine(s.path.creationDate.timeIntervalSinceReferenceDate)
                hashers[p].combine(s.ink.inkType.rawValue)
                hashers[p].combine(s.ink.color)
            }
        }
        let index = InkIndex(note: note, revision: doc.revision, strokes: strokes, prints: hashers.map { $0.finalize() })
        inkIndex = index
        return index
    }
}
