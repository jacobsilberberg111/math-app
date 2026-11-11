import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Where a template's sections go: split over as many pages as they need (about `capacity`
/// weight units per page), each page's writing height shared out by weight, with section tops
/// snapped to the paper's ruled lines.
enum TemplateLayout {
    struct Slot: Equatable {
        var page: Int
        var top: CGFloat
        var height: CGFloat
    }

    /// - Parameters:
    ///   - firstTop: where sections start on the first page (below the title).
    ///   - top: where sections start on later pages.
    ///   - bottom: the lowest y sections may use.
    ///   - lineSpacing: ruled-line spacing to snap to (0 for none), with lines starting at `lineOrigin`.
    static func slots(weights: [Double], firstTop: CGFloat, top: CGFloat, bottom: CGFloat,
                      capacity: Double = 4.2, lineSpacing: CGFloat = 0, lineOrigin: CGFloat = 0) -> [Slot] {
        guard !weights.isEmpty else { return [] }
        // Greedy pages: start a new page when the next section would overfill this one.
        var pages: [[Int]] = [[]]
        var used = 0.0
        for (i, w) in weights.enumerated() {
            let w = max(0.1, w)
            if !pages[pages.count - 1].isEmpty && used + w > capacity {
                pages.append([])
                used = 0
            }
            pages[pages.count - 1].append(i)
            used += w
        }
        var out = [Slot](repeating: Slot(page: 0, top: 0, height: 0), count: weights.count)
        for (p, items) in pages.enumerated() {
            let start = p == 0 ? firstTop : top
            let total = items.reduce(0.0) { $0 + max(0.1, weights[$1]) }
            let available = max(0, bottom - start)
            var y = start
            for i in items {
                var t = y
                if lineSpacing > 0 {
                    // The first ruled line at or below y: headings sit on it.
                    let k = ((t - lineOrigin) / lineSpacing).rounded(.up)
                    t = max(start, lineOrigin + k * lineSpacing)
                }
                let h = available * CGFloat(max(0.1, weights[i]) / total)
                out[i] = Slot(page: p, top: t, height: max(0, y + h - t))
                y += h
            }
        }
        return out
    }
}
