import Foundation

/// How sharply to draw the items near the screen without running out of memory. Each item wants
/// its screen scale (already capped per item); if together they'd need more pixels than the
/// budget, the ones off screen give way first, then the ones on screen.
enum RasterBudget {
    struct Item {
        /// Points squared.
        var area: Double
        var wanted: Double
        var onScreen: Bool
    }

    static func scales(_ items: [Item], budget: Double, floor: Double = 1) -> [Double] {
        var out = items.map(\.wanted)
        func pixels(_ idx: [Int]) -> Double { idx.reduce(0) { $0 + items[$1].area * out[$1] * out[$1] } }
        func shrink(_ idx: [Int], to room: Double) {
            let total = pixels(idx)
            guard total > room else { return }
            let k = room > 0 ? (room / total).squareRoot() : 0
            // Never below 1x (blurry but legible), unless the item wanted less anyway (zoomed out).
            for i in idx { out[i] = max(min(floor, items[i].wanted), out[i] * k) }
        }
        let on = items.indices.filter { items[$0].onScreen }
        let off = items.indices.filter { !items[$0].onScreen }
        shrink(on, to: budget)
        shrink(off, to: max(0, budget - pixels(on)))
        return out
    }

    /// Whether a view drawn at `current` should redraw at `target`: small changes (a slightly
    /// different budget share, a nudge of the zoom) aren't worth redrawing everything for.
    static func needsRedraw(current: Double, target: Double) -> Bool {
        abs(current - target) > max(0.05, current * 0.08)
    }
}

/// Zoom that ends close to fitting the page width snaps to it, so the page lines up with the
/// screen edges again instead of sitting a few points off.
enum ZoomSnap {
    static let tolerance = 0.08

    static func snapsToFit(zoom: Double, fit: Double) -> Bool {
        guard fit > 0 else { return false }
        let off = abs(zoom - fit)
        return off > 0.001 && off / fit < tolerance
    }
}

/// Notes deleted from the library wait in Recently Deleted for 30 days before they're removed.
enum TrashPolicy {
    static let keepDays = 30

    static func isExpired(deletedAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(deletedAt) >= Double(keepDays) * 86_400
    }

    /// Whole days until the note is removed for good (0 on its last day).
    static func daysLeft(deletedAt: Date, now: Date = Date()) -> Int {
        let left = Double(keepDays) * 86_400 - now.timeIntervalSince(deletedAt)
        return max(0, Int((left / 86_400).rounded(.down)))
    }
}

/// Parses what was typed in "Go to page": a page number, clamped to the note.
enum PageJump {
    static func index(from text: String, pageCount: Int) -> Int? {
        guard pageCount > 0, let n = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return min(max(n, 1), pageCount) - 1
    }
}
