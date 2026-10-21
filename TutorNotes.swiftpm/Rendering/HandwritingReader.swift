import UIKit
import PencilKit
import Vision

/// A line of recognised handwriting: its text, and where it and each of its words sit in the note.
struct RecognisedLine: Sendable {
    struct Word: Sendable {
        /// Character offsets into the line's text.
        var start: Int
        var end: Int
        /// Document coordinates.
        var rect: CGRect
    }

    var text: String
    /// Document coordinates.
    var rect: CGRect
    var words: [Word]

    /// The part of the line a character range falls on: the union of the words it touches.
    func box(covering range: Range<Int>) -> CGRect {
        let hit = words.filter { $0.end > range.lowerBound && $0.start < range.upperBound }
        guard let first = hit.first else { return rect }
        return hit.dropFirst().reduce(first.rect) { $0.union($1.rect) }
    }
}

/// A part of the note whose ink is read as one image: a page, or a tile of a freeform board.
struct InkRegion {
    struct Key: Hashable {
        var x: Int
        var y: Int
    }

    var key: Key
    var page: Int
    /// Document coordinates.
    var rect: CGRect
    /// Changes whenever the ink in the region does, so an earlier reading can be reused.
    var signature: Int
}

/// Reads handwriting with Vision and keeps track of where every word is, so find can highlight it.
/// (HandwritingIndexer only needs the text, for library search.)
enum HandwritingReader {
    /// Boards are read in tiles this big (document points), like the library index does.
    static let tileSize: CGFloat = 1600

    /// The pages (or board tiles) that have ink, nearest `anchor` first, at most `limit` of them.
    @MainActor
    static func regions(for doc: NoteDocument, near anchor: CGPoint, limit: Int = 60) -> [InkRegion] {
        let bounds = doc.drawing.strokes.map(\.renderBounds)
        guard !bounds.isEmpty else { return [] }
        var found: [InkRegion] = []

        func add(page: Int, rect: CGRect) {
            var hasher = Hasher()
            var count = 0
            for b in bounds where b.intersects(rect) {
                hasher.combine(Int(b.minX.rounded()))
                hasher.combine(Int(b.minY.rounded()))
                hasher.combine(Int(b.width.rounded()))
                hasher.combine(Int(b.height.rounded()))
                count += 1
            }
            guard count > 0 else { return }
            hasher.combine(count)
            hasher.combine(doc.content.pages[safe: page]?.paper.color.isDark ?? false)
            found.append(InkRegion(key: InkRegion.Key(x: Int(rect.minX), y: Int(rect.minY)), page: page, rect: rect, signature: hasher.finalize()))
        }

        if doc.isFreeform {
            let board = CGRect(origin: .zero, size: doc.pageSize)
            let inked = bounds.reduce(CGRect.null) { $0.union($1) }.intersection(board)
            guard !inked.isNull else { return [] }
            let t = tileSize
            var y = floor(inked.minY / t) * t
            while y < inked.maxY {
                var x = floor(inked.minX / t) * t
                while x < inked.maxX {
                    let tile = CGRect(x: x, y: y, width: t, height: t).intersection(board)
                    if !tile.isNull { add(page: 0, rect: tile) }
                    x += t
                }
                y += t
            }
        } else {
            for i in doc.content.pages.indices { add(page: i, rect: doc.pageRect(i)) }
        }
        found.sort { $0.rect.center.distance(to: anchor) < $1.rect.center.distance(to: anchor) }
        return Array(found.prefix(limit))
    }

    /// The region's ink on white at 2x (1.5x for board tiles, which are bigger), ready for Vision.
    /// Dark paper keeps its colour: the light ink written on it would vanish against white.
    @MainActor
    static func image(of region: InkRegion, in doc: NoteDocument) -> CGImage? {
        let scale: CGFloat = doc.isFreeform ? 1.5 : 2
        let paper = doc.content.pages[safe: region.page]?.paper.color ?? .white
        let background = paper.isDark ? UIColor(hex: paper.hex) : UIColor.white
        let size = region.rect.size
        let origin = doc.pageOrigin(region.page)
        let ink = PageRenderer.inkImage(doc, page: region.page, scale: scale,
                                        region: region.rect.offsetBy(dx: -origin.x, dy: -origin.y))
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { rc in
            background.setFill()
            rc.fill(CGRect(origin: .zero, size: size))
            ink.draw(in: CGRect(origin: .zero, size: size))
        }
        return image.cgImage
    }

    /// Reads an image of `rect` (document coordinates), line by line. Blocks: call off the main actor.
    static func recognize(_ image: CGImage, in rect: CGRect) -> [RecognisedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return [] }

        var lines: [RecognisedLine] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let words = wordBoxes(in: candidate.string) { range in
                (try? candidate.boundingBox(for: range)).map { docRect($0.boundingBox, in: rect) }
            }
            lines.append(RecognisedLine(text: candidate.string, rect: docRect(observation.boundingBox, in: rect), words: words))
        }
        return lines
    }

    /// A Vision box (normalised, origin at the bottom left, relative to the image) in document
    /// coordinates, for an image covering `region`.
    static func docRect(_ box: CGRect, in region: CGRect) -> CGRect {
        CGRect(x: region.minX + box.minX * region.width, y: region.minY + (1 - box.maxY) * region.height,
               width: box.width * region.width, height: box.height * region.height)
    }

    /// The words of a line: runs between spaces, so a lone "=" or "+" in working has a box too.
    /// `box` finds where a word sits; words it can't place are left out.
    static func wordBoxes(in text: String, box: (Range<String.Index>) -> CGRect?) -> [RecognisedLine.Word] {
        var words: [RecognisedLine.Word] = []
        var i = text.startIndex
        var offset = 0
        while i < text.endIndex {
            if text[i].isWhitespace {
                i = text.index(after: i)
                offset += 1
                continue
            }
            let start = i, startOffset = offset
            while i < text.endIndex, !text[i].isWhitespace {
                i = text.index(after: i)
                offset += 1
            }
            if let rect = box(start..<i) {
                words.append(RecognisedLine.Word(start: startOffset, end: offset, rect: rect))
            }
        }
        return words
    }
}
