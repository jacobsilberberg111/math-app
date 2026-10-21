import UIKit
import Vision

/// Recognises handwriting on-device (Vision) so the library can search inside notes.
@MainActor
enum HandwritingIndexer {
    static func index(_ doc: NoteDocument) async -> String? {
        var images: [CGImage] = doc.isFreeform ? boardImages(doc) : []
        for i in doc.content.pages.indices.prefix(40) where !doc.isFreeform && !doc.strokes(onPage: i).isEmpty {
            let size = doc.pageSize
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1.5
            format.opaque = true
            let ink = PageRenderer.inkImage(doc, page: i, scale: 1.5)
            let img = UIGraphicsImageRenderer(size: size, format: format).image { rc in
                UIColor.white.setFill()
                rc.fill(CGRect(origin: .zero, size: size))
                ink.draw(in: CGRect(origin: .zero, size: size))
            }
            if let cg = img.cgImage { images.append(cg) }
        }
        var text = doc.typedText
        if !images.isEmpty {
            let recognized = await Task.detached(priority: .utility) {
                HandwritingIndexer.recognize(images)
            }.value
            text += "\n" + recognized
        }
        let trimmed = text.trimmed
        return trimmed.isEmpty ? nil : String(trimmed.prefix(20_000))
    }

    /// A board can be far bigger than a page, so read it in page-sized tiles that have ink.
    private static func boardImages(_ doc: NoteDocument) -> [CGImage] {
        guard let bounds = doc.boardContentBounds else { return [] }
        let tile: CGFloat = 1600
        let strokes = doc.drawing.strokes.map(\.renderBounds)
        var images: [CGImage] = []
        var y = floor(bounds.minY / tile) * tile
        while y < bounds.maxY && images.count < 40 {
            var x = floor(bounds.minX / tile) * tile
            while x < bounds.maxX && images.count < 40 {
                let region = CGRect(x: x, y: y, width: tile, height: tile)
                if strokes.contains(where: { $0.intersects(region) }) {
                    let format = UIGraphicsImageRendererFormat()
                    format.scale = 1
                    format.opaque = true
                    let ink = PageRenderer.inkImage(doc, page: 0, scale: 1, region: region)
                    let img = UIGraphicsImageRenderer(size: region.size, format: format).image { rc in
                        UIColor.white.setFill()
                        rc.fill(CGRect(origin: .zero, size: region.size))
                        ink.draw(in: CGRect(origin: .zero, size: region.size))
                    }
                    if let cg = img.cgImage { images.append(cg) }
                }
                x += tile
            }
            y += tile
        }
        return images
    }

    nonisolated static func recognize(_ images: [CGImage]) -> String {
        var out: [String] = []
        for cg in images {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            try? handler.perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            out.append(lines.joined(separator: " "))
        }
        return out.joined(separator: "\n")
    }
}
