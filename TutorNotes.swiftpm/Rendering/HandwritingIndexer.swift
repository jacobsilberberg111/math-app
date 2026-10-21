import UIKit
import Vision

/// Recognises handwriting on-device (Vision) so the library can search inside notes.
@MainActor
enum HandwritingIndexer {
    static func index(_ doc: NoteDocument) async -> String? {
        var images: [CGImage] = []
        for i in doc.content.pages.indices.prefix(40) where !doc.strokes(onPage: i).isEmpty {
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
