import UIKit
import Vision

/// Reads handwriting on-device (Vision) and puts what it finds into lines of text.
enum InkTextRecognizer {
    /// A run of recognised text and where it sits in the image (normalised, origin bottom-left).
    struct Fragment {
        var text: String
        var box: CGRect
    }

    /// The lines of text in the image, top to bottom. Empty when nothing was recognised.
    nonisolated static func recognize(_ image: UIImage) throws -> [String] {
        guard let cgImage = padded(image) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        // The default skips text under 1/32 of the image's height, which loses lines when many are selected.
        request.minimumTextHeight = 0.01
        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        let fragments = (request.results ?? []).compactMap { observation -> Fragment? in
            guard let text = observation.topCandidates(1).first?.string, !text.trimmed.isEmpty else { return nil }
            return Fragment(text: text.trimmed, box: observation.boundingBox)
        }
        return lines(from: fragments)
    }

    /// The ink on a margin of white: text touching the image's edge tends to be missed.
    nonisolated private static func padded(_ image: UIImage, margin: CGFloat = 24) -> CGImage? {
        let size = CGSize(width: image.size.width + 2 * margin, height: image.size.height + 2 * margin)
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { rc in
            UIColor.white.setFill()
            rc.fill(CGRect(origin: .zero, size: size))
            image.draw(at: CGPoint(x: margin, y: margin))
        }.cgImage
    }

    // MARK: Ordering

    /// Groups fragments that sit on the same line (their heights overlap), then reads the lines top
    /// to bottom and each line left to right. Vision's y axis points up, so the top has the largest y.
    nonisolated static func lines(from fragments: [Fragment]) -> [String] {
        var rows: [(minY: CGFloat, maxY: CGFloat, fragments: [Fragment])] = []
        for fragment in fragments.sorted(by: { $0.box.midY > $1.box.midY }) {
            let box = fragment.box
            let overlaps = rows.map { row -> CGFloat in
                max(0, min(row.maxY, box.maxY) - max(row.minY, box.minY))
            }
            if let i = overlaps.indices.max(by: { overlaps[$0] < overlaps[$1] }), overlaps[i] > 0.5 * box.height {
                rows[i].minY = min(rows[i].minY, box.minY)
                rows[i].maxY = max(rows[i].maxY, box.maxY)
                rows[i].fragments.append(fragment)
            } else {
                rows.append((box.minY, box.maxY, [fragment]))
            }
        }
        return rows.sorted { $0.minY + $0.maxY > $1.minY + $1.maxY }.map { row in
            row.fragments.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ")
        }
    }
}
