import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

func runDiagramTests() {
    let box = CGSize(width: 120, height: 40)

    // A straight chain flows down in order, one box per layer, centred on one line.
    let chain = FlowchartLayout.layout(sizes: [box, box, box], edges: [(0, 1, false), (1, 2, false)], direction: .down)
    check(chain.frames.count == 3 && chain.edges.count == 2, "chain counts")
    check(chain.frames[0].maxY < chain.frames[1].minY && chain.frames[1].maxY < chain.frames[2].minY, "chain goes down")
    check(abs(chain.frames[0].midX - chain.frames[2].midX) < 0.5, "chain is straight")
    check(chain.edges.allSatisfy { !$0.isBack }, "no back edges in a chain")
    let e0 = chain.edges[0]
    check(abs(e0.points.first!.y - chain.frames[0].maxY) < 0.5 && abs(e0.points.last!.y - chain.frames[1].minY) < 0.5, "edge runs box to box")

    // A decision with two branches that rejoin, and a loop back to the start.
    let sizes = [box, CGSize(width: 140, height: 80), box, box, box]
    let flow = FlowchartLayout.layout(sizes: sizes, edges: [(0, 1, false), (1, 2, true), (1, 3, true), (2, 4, false), (3, 4, false), (4, 0, true)], direction: .down)
    check(abs(flow.frames[2].minY - flow.frames[3].minY) < 0.5, "branches share a layer")
    check(!flow.frames[2].intersects(flow.frames[3]), "branches don't overlap")
    check(flow.edges.filter(\.isBack).count == 1, "one loop back")
    let back = flow.edges.first(where: \.isBack)!
    check(back.points.allSatisfy { $0.x >= flow.frames.map(\.maxX).max()! - 0.5 } || back.points.count == 4, "loop runs down the side")
    check(flow.edges.filter { $0.labelAt != nil }.count == 3, "labelled edges get label positions")
    for i in 0..<flow.frames.count { for j in (i + 1)..<flow.frames.count { check(!flow.frames[i].intersects(flow.frames[j]), "no overlap \(i) \(j)") } }
    check(flow.frames.allSatisfy { $0.minX >= 0 && $0.minY >= 0 && $0.maxX <= flow.size.width && $0.maxY <= flow.size.height }, "fits its size")

    // A long edge skipping a layer routes through the gap rather than through a box.
    let skip = FlowchartLayout.layout(sizes: [box, box, box], edges: [(0, 1, false), (1, 2, false), (0, 2, false)], direction: .down)
    let long = skip.edges.first { $0.from == 0 && $0.to == 2 }!
    check(long.points.count == 4, "long edge has a bend point pair: \(long.points.count)")
    check(!long.points.dropFirst().dropLast().contains { skip.frames[1].insetBy(dx: 1, dy: 1).contains($0) }, "long edge avoids the middle box")

    // Left to right.
    let right = FlowchartLayout.layout(sizes: [box, box], edges: [(0, 1, false)], direction: .right)
    check(right.frames[0].maxX < right.frames[1].minX && abs(right.frames[0].midY - right.frames[1].midY) < 0.5, "right flows right")

    // Cycles: around a circle, every stage to the next.
    let cyc = FlowchartLayout.layout(sizes: [box, box, box, box], edges: [], direction: .cycle)
    check(cyc.edges.count == 4 && cyc.edges.allSatisfy { $0.control != nil }, "cycle edges")
    for i in 0..<4 { for j in (i + 1)..<4 { check(!cyc.frames[i].intersects(cyc.frames[j]), "cycle no overlap \(i) \(j)") } }
    check(cyc.frames[0].midY < cyc.frames[2].midY, "cycle starts at the top")

    // Bad input is ignored, not a crash.
    let bad = FlowchartLayout.layout(sizes: [box], edges: [(0, 5, false), (0, 0, false)], direction: .down)
    check(bad.frames.count == 1 && bad.edges.isEmpty, "bad edges dropped")

    // Labels: left anchors go left, right anchors right, no overlaps, inside the bounds.
    let target = CGRect(x: 300, y: 200, width: 220, height: 260)
    let bounds = CGRect(x: 40, y: 40, width: 736, height: 976)
    let s = CGSize(width: 110, height: 24)
    var inputs = (0..<5).map { LabelLayout.Input(size: s, anchor: CGPoint(x: 330, y: 300 + CGFloat($0) * 4)) }
    inputs.append(LabelLayout.Input(size: s, anchor: CGPoint(x: 500, y: 260)))
    let placed = LabelLayout.place(inputs, target: target, bounds: bounds)
    check(placed.count == 6, "label count")
    check(placed[5].minX >= target.maxX, "right anchor labelled on the right")
    check(placed.prefix(5).allSatisfy { $0.maxX <= target.minX }, "left anchors on the left")
    for i in 0..<6 { for j in (i + 1)..<6 { check(!placed[i].insetBy(dx: 0, dy: 1).intersects(placed[j]), "labels don't overlap \(i) \(j)") } }
    check(placed.allSatisfy { bounds.contains($0) }, "labels inside bounds")
    let ys = placed.prefix(5).map(\.minY)
    check(ys == ys.sorted(), "labels keep their anchors' order")

    // A picture against the left edge puts everything on the right.
    let edgeTarget = CGRect(x: 50, y: 200, width: 300, height: 300)
    let edge = LabelLayout.place([LabelLayout.Input(size: s, anchor: CGPoint(x: 60, y: 300))], target: edgeTarget, bounds: bounds)
    check(edge[0].minX >= edgeTarget.maxX, "no room on the left")

    // spread: crowded boxes near the bottom are pushed up inside the range.
    let tops = LabelLayout.spread([(990, 30), (995, 30), (1000, 30)], minY: 0, maxY: 1000)
    check(tops[2] + 30 <= 1000.5 && tops[1] + 30 + LabelLayout.gap <= tops[2] + 0.5, "spread fits: \(tops)")
}
