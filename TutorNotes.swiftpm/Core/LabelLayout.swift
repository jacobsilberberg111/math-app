import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Places diagram labels in neat columns beside the picture: each label goes on the side nearer
/// its anchor, sorted by height, nudged apart so none overlap, with a leader line to the anchor.
enum LabelLayout {
    struct Input {
        var size: CGSize
        /// The point on the picture, in page coordinates.
        var anchor: CGPoint
    }

    static let gap: CGFloat = 6
    static let offset: CGFloat = 22

    /// Label boxes in page coordinates, in input order.
    /// - Parameters:
    ///   - target: the picture (or region) being labelled.
    ///   - bounds: where labels may go (the page's usable area).
    static func place(_ labels: [Input], target: CGRect, bounds: CGRect) -> [CGRect] {
        guard !labels.isEmpty else { return [] }
        let maxW = labels.map(\.size.width).max() ?? 0
        let roomLeft = target.minX - bounds.minX - offset
        let roomRight = bounds.maxX - target.maxX - offset
        var left: [Int] = [], right: [Int] = []
        for (i, l) in labels.enumerated() {
            var goLeft = l.anchor.x < target.midX
            if goLeft && roomLeft < min(maxW, 60) { goLeft = false }
            if !goLeft && roomRight < min(maxW, 60) && roomLeft >= min(maxW, 60) { goLeft = true }
            if goLeft { left.append(i) } else { right.append(i) }
        }
        // Keep the columns roughly balanced when one side is crowded and the other has room.
        func height(_ ids: [Int]) -> CGFloat { ids.reduce(0) { $0 + labels[$1].size.height + gap } }
        while height(right) > target.height * 1.3, height(left) + 40 < height(right), roomLeft >= min(maxW, 60),
              let move = right.min(by: { labels[$0].anchor.x < labels[$1].anchor.x }) {
            right.removeAll { $0 == move }
            left.append(move)
        }
        while height(left) > target.height * 1.3, height(right) + 40 < height(left), roomRight >= min(maxW, 60),
              let move = left.max(by: { labels[$0].anchor.x < labels[$1].anchor.x }) {
            left.removeAll { $0 == move }
            right.append(move)
        }
        var out = [CGRect](repeating: .zero, count: labels.count)
        for (ids, isLeft) in [(left, true), (right, false)] {
            let sorted = ids.sorted { labels[$0].anchor.y < labels[$1].anchor.y }
            let tops = spread(sorted.map { (labels[$0].anchor.y - labels[$0].size.height / 2, labels[$0].size.height) },
                              minY: bounds.minY, maxY: bounds.maxY)
            for (k, i) in sorted.enumerated() {
                let s = labels[i].size
                let x = isLeft ? max(bounds.minX, target.minX - offset - s.width) : min(bounds.maxX - s.width, target.maxX + offset)
                out[i] = CGRect(x: x, y: tops[k], width: s.width, height: s.height)
            }
        }
        return out
    }

    /// Positions boxes (wanted top, height), in order, so they don't overlap and stay in range,
    /// each as close to where it wanted to be as possible.
    static func spread(_ items: [(CGFloat, CGFloat)], minY: CGFloat, maxY: CGFloat) -> [CGFloat] {
        guard !items.isEmpty else { return [] }
        var tops = items.map { max(minY, $0.0) }
        // Push down past the one above…
        for k in 1..<tops.count {
            tops[k] = max(tops[k], tops[k - 1] + items[k - 1].1 + gap)
        }
        // …then up from the bottom limit if the column ran off the end.
        let last = tops.count - 1
        if tops[last] + items[last].1 > maxY {
            tops[last] = maxY - items[last].1
            if last > 0 {
                for k in stride(from: last - 1, through: 0, by: -1) {
                    tops[k] = min(tops[k], tops[k + 1] - items[k].1 - gap)
                }
            }
        }
        // Centre runs of touching boxes on their wanted positions (where there's room).
        var i = 0
        while i < tops.count {
            var j = i
            while j + 1 < tops.count && tops[j + 1] <= tops[j] + items[j].1 + gap + 0.5 { j += 1 }
            if j > i {
                let wanted = (i...j).map { items[$0].0 }.reduce(0, +) / CGFloat(j - i + 1)
                let actual = (i...j).map { tops[$0] }.reduce(0, +) / CGFloat(j - i + 1)
                var shift = wanted - actual
                let lowerRoom = (i > 0 ? tops[i] - (tops[i - 1] + items[i - 1].1 + gap) : tops[i] - minY)
                let upperRoom = (j + 1 < tops.count ? tops[j + 1] - gap : maxY) - (tops[j] + items[j].1)
                shift = max(-lowerRoom, min(upperRoom, shift))
                for k in i...j { tops[k] += shift }
            }
            i = j + 1
        }
        return tops
    }

    /// Where a leader line leaves its label box: the middle of the side facing the anchor.
    static func leaderStart(box: CGRect, anchor: CGPoint) -> CGPoint {
        let y = min(max(anchor.y, box.minY + 4), box.maxY - 4)
        if anchor.x >= box.maxX { return CGPoint(x: box.maxX + 3, y: box.midY) }
        if anchor.x <= box.minX { return CGPoint(x: box.minX - 3, y: box.midY) }
        return CGPoint(x: box.midX, y: anchor.y < box.minY ? box.minY - 3 : (anchor.y > box.maxY ? box.maxY + 3 : y))
    }
}
