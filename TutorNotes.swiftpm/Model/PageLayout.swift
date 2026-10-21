import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Page sizes

extension PageSize {
    static let letterLandscape = PageSize(width: letter.height, height: letter.width)
    static let a4Landscape = PageSize(width: a4.height, height: a4.width)

    /// The sizes a note's pages can be switched between.
    static let options: [PageSize] = [.letter, .a4, .letterLandscape, .a4Landscape]

    var isLandscape: Bool { width > height }

    var title: String {
        switch self {
        case .letter: return "Letter"
        case .a4: return "A4"
        case .letterLandscape: return "Letter Landscape"
        case .a4Landscape: return "A4 Landscape"
        default: return "Custom"
        }
    }
}

// MARK: - Page remapping

/// How a page operation relocated the pages: where each one went, and the page size before and
/// after. The document uses it to carry ink, items and the paper session along, and anything else
/// that remembers a page number (the tutor's undo records, the editor's selection) can follow too.
struct PageRemap {
    /// `destination[old]` is the index now held by the page that was at `old`.
    var destination: [Int]
    var oldSize: PageSize
    var newSize: PageSize
    /// The document layout that ink positions are measured in.
    var topMargin: CGFloat
    var pageGap: CGFloat

    /// Page `from` moved so it ends up at index `to`.
    static func move(from: Int, to: Int, count: Int, size: PageSize, topMargin: CGFloat, pageGap: CGFloat) -> PageRemap {
        var order = Array(0..<count)   // order[new] = old
        order.insert(order.remove(at: from), at: to)
        var destination = Array(repeating: 0, count: count)
        for (new, old) in order.enumerated() { destination[old] = new }
        return PageRemap(destination: destination, oldSize: size, newSize: size, topMargin: topMargin, pageGap: pageGap)
    }

    /// Every page stays where it is but the pages change size.
    static func resize(from old: PageSize, to new: PageSize, count: Int, topMargin: CGFloat, pageGap: CGFloat) -> PageRemap {
        PageRemap(destination: Array(0..<count), oldSize: old, newSize: new, topMargin: topMargin, pageGap: pageGap)
    }

    /// The remap that undoes this one.
    var inverse: PageRemap {
        var back = Array(repeating: 0, count: destination.count)
        for (old, new) in destination.enumerated() where back.indices.contains(new) { back[new] = old }
        return PageRemap(destination: back, oldSize: newSize, newSize: oldSize, topMargin: topMargin, pageGap: pageGap)
    }

    /// Where the page that was at `old` is now.
    func page(_ old: Int) -> Int { destination.indices.contains(old) ? destination[old] : old }

    /// The page, in the old layout, that a document y falls on (the nearest one for the margins and gaps).
    func oldPage(atDocY y: CGFloat) -> Int {
        guard y.isFinite, !destination.isEmpty else { return 0 }
        let stride = oldSize.height + pageGap
        let raw = ((y - topMargin + pageGap / 2) / stride).rounded(.down)
        return Int(max(0, min(CGFloat(destination.count - 1), raw)))
    }

    /// How far ink at document y (in the old layout) moves down the document.
    func inkOffset(atDocY y: CGFloat) -> CGFloat {
        let old = oldPage(atDocY: y)
        return CGFloat(page(old)) * (newSize.height + pageGap) - CGFloat(old) * (oldSize.height + pageGap)
    }

    /// `frame` (page coordinates), nudged back inside a page of `size` if it would overflow.
    static func nudged(_ frame: CGRect, into size: PageSize) -> CGRect {
        var f = frame
        f.origin.x = max(0, min(frame.minX, size.width - frame.width))
        f.origin.y = max(0, min(frame.minY, size.height - frame.height))
        return f
    }

    /// The element on its new page. Frames are page-relative, so they only change if the new page
    /// is too small to hold them where they were.
    func remapped(_ element: CanvasElement) -> CanvasElement {
        var e = element
        e.pageIndex = page(e.pageIndex)
        if newSize != oldSize { e.frame = PageRemap.nudged(e.frame, into: newSize) }
        return e
    }

    /// The past paper with its question and results pages renumbered.
    func remapped(_ paper: PaperSession) -> PaperSession {
        var p = paper
        for i in p.questions.indices { p.questions[i].page = page(p.questions[i].page) }
        p.resultsPage = p.resultsPage.map { page($0) }
        return p
    }
}
