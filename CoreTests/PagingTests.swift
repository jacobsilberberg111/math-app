import Foundation

/// Canvas paging helpers: the element pixel budget, zoom snapping, Recently Deleted timing and
/// "Go to page" parsing.
func runPagingTests() {
    // Under budget: everyone gets what they asked for.
    let small = RasterBudget.scales([.init(area: 100_000, wanted: 4, onScreen: true),
                                     .init(area: 100_000, wanted: 4, onScreen: false)], budget: 10_000_000)
    check(small == [4, 4], "budget: under budget unchanged \(small)")

    // Over budget: off-screen items give way first, on-screen ones keep their scale.
    let items: [RasterBudget.Item] = [.init(area: 1_000_000, wanted: 4, onScreen: true),
                                      .init(area: 1_000_000, wanted: 4, onScreen: false)]
    let squeezed = RasterBudget.scales(items, budget: 20_000_000)
    check(squeezed[0] == 4 && squeezed[1] < 4 && squeezed[1] >= 1, "budget: off screen shrinks first \(squeezed)")
    let used = zip(items, squeezed).reduce(0) { $0 + $1.0.area * $1.1 * $1.1 }
    check(used <= 20_000_001, "budget: total within budget \(used)")

    // Even the on-screen ones shrink when they alone are too big, but never below 1x.
    let huge = RasterBudget.scales([.init(area: 10_000_000, wanted: 6, onScreen: true)], budget: 40_000_000)
    check(approx(huge[0], 2), "budget: on screen shrinks to fit \(huge)")
    let floor = RasterBudget.scales([.init(area: 100_000_000, wanted: 6, onScreen: true)], budget: 1_000_000)
    check(floor[0] == 1, "budget: floor at 1x \(floor)")
    let zoomedOut = RasterBudget.scales([.init(area: 100_000_000, wanted: 0.6, onScreen: true)], budget: 1_000_000)
    check(zoomedOut[0] == 0.6, "budget: zoomed out keeps its lower scale \(zoomedOut)")

    check(!RasterBudget.needsRedraw(current: 4, target: 4.2), "redraw: small change skipped")
    check(RasterBudget.needsRedraw(current: 2, target: 4), "redraw: zoom change redraws")

    check(ZoomSnap.snapsToFit(zoom: 1.05, fit: 1), "snap: 5% off snaps")
    check(ZoomSnap.snapsToFit(zoom: 0.94, fit: 1), "snap: 6% under snaps")
    check(!ZoomSnap.snapsToFit(zoom: 1.2, fit: 1), "snap: 20% stays")
    check(!ZoomSnap.snapsToFit(zoom: 1, fit: 1), "snap: already fit")

    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    check(!TrashPolicy.isExpired(deletedAt: now.addingTimeInterval(-29 * 86_400), now: now), "trash: 29 days kept")
    check(TrashPolicy.isExpired(deletedAt: now.addingTimeInterval(-30 * 86_400), now: now), "trash: 30 days purged")
    check(TrashPolicy.daysLeft(deletedAt: now, now: now) == 30, "trash: 30 days left on day one")
    check(TrashPolicy.daysLeft(deletedAt: now.addingTimeInterval(-29.5 * 86_400), now: now) == 0, "trash: last day")

    check(PageJump.index(from: " 12 ", pageCount: 33) == 11, "jump: number")
    check(PageJump.index(from: "99", pageCount: 33) == 32, "jump: clamps high")
    check(PageJump.index(from: "0", pageCount: 33) == 0, "jump: clamps low")
    check(PageJump.index(from: "x", pageCount: 33) == nil, "jump: not a number")
}
