import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Lays out a flowchart: layers along the flow (longest path from the start), crossings reduced
/// by barycentre ordering, long edges routed through the layers between, and edges that loop
/// back drawn around the side. Cycles go round a circle instead.
enum FlowchartLayout {
    struct Edge: Equatable {
        var from: Int
        var to: Int
        /// The route, ending at the target's border (the arrowhead goes on the last point).
        var points: [CGPoint]
        /// Where the edge's label goes (its centre), if it has one.
        var labelAt: CGPoint?
        var isBack: Bool
        /// Cycle diagrams curve their arrows outward through this point.
        var control: CGPoint?
    }

    struct Result: Equatable {
        var frames: [CGRect]
        var edges: [Edge]
        var size: CGSize
    }

    static let gapAlong: CGFloat = 46
    static let gapAcross: CGFloat = 34
    static let backLane: CGFloat = 26
    static let margin: CGFloat = 12

    /// - Parameters:
    ///   - sizes: each node's box size, in node order.
    ///   - edges: (from, to, hasLabel) as node indices.
    static func layout(sizes: [CGSize], edges: [(Int, Int, Bool)], direction: FlowDirection) -> Result {
        let n = sizes.count
        guard n > 0 else { return Result(frames: [], edges: [], size: .zero) }
        let valid = edges.filter { $0.0 >= 0 && $0.0 < n && $0.1 >= 0 && $0.1 < n && $0.0 != $0.1 }
        if direction == .cycle { return cycle(sizes: sizes, edges: valid) }
        let down = direction == .down

        // Work in "flow" coordinates: `along` is the flow direction (y when down), `across` the other.
        func along(_ s: CGSize) -> CGFloat { down ? s.height : s.width }
        func across(_ s: CGSize) -> CGFloat { down ? s.width : s.height }

        // 1. Back edges: edges into a node still on the DFS stack (visiting in node order).
        var out = [[Int]](repeating: [], count: n)
        for (i, e) in valid.enumerated() { out[e.0].append(i) }
        var state = [Int](repeating: 0, count: n) // 0 new, 1 on stack, 2 done
        var back = Set<Int>()
        var hasIncoming = [Bool](repeating: false, count: n)
        for e in valid { hasIncoming[e.1] = true }
        func dfs(_ v: Int) {
            state[v] = 1
            for ei in out[v] {
                let w = valid[ei].1
                if state[w] == 1 { back.insert(ei) } else if state[w] == 0 { dfs(w) }
            }
            state[v] = 2
        }
        for v in 0..<n where !hasIncoming[v] && state[v] == 0 { dfs(v) }
        for v in 0..<n where state[v] == 0 { dfs(v) }

        // 2. Layers: longest path over the forward edges (Kahn order).
        var indeg = [Int](repeating: 0, count: n)
        var fwd = [[Int]](repeating: [], count: n)
        for (i, e) in valid.enumerated() where !back.contains(i) {
            fwd[e.0].append(e.1)
            indeg[e.1] += 1
        }
        var layer = [Int](repeating: 0, count: n)
        var queue = (0..<n).filter { indeg[$0] == 0 }
        var qi = 0
        while qi < queue.count {
            let v = queue[qi]; qi += 1
            for w in fwd[v] {
                layer[w] = max(layer[w], layer[v] + 1)
                indeg[w] -= 1
                if indeg[w] == 0 { queue.append(w) }
            }
        }

        // 3. Dummy nodes for edges spanning several layers, so they route around boxes.
        var nodeAcross = sizes.map(across)
        var nodeAlong = sizes.map(along)
        var nodeLayer = layer
        var chains: [Int: [Int]] = [:] // forward edge index → node sequence incl. dummies
        for (i, e) in valid.enumerated() where !back.contains(i) {
            var seq = [e.0]
            if layer[e.1] - layer[e.0] > 1 {
                for l in (layer[e.0] + 1)..<layer[e.1] {
                    nodeAcross.append(8); nodeAlong.append(0); nodeLayer.append(l)
                    seq.append(nodeAcross.count - 1)
                }
            }
            seq.append(e.1)
            chains[i] = seq
        }
        let total = nodeAcross.count
        var parents = [[Int]](repeating: [], count: total)
        var children = [[Int]](repeating: [], count: total)
        for seq in chains.values {
            for k in 0..<(seq.count - 1) {
                children[seq[k]].append(seq[k + 1])
                parents[seq[k + 1]].append(seq[k])
            }
        }
        let layerCount = (nodeLayer.max() ?? 0) + 1
        var rows = [[Int]](repeating: [], count: layerCount)
        for v in 0..<total { rows[nodeLayer[v]].append(v) }

        // 4. Order within layers: barycentre sweeps down and up.
        var pos = [Double](repeating: 0, count: total)
        func renumber(_ r: Int) { for (k, v) in rows[r].enumerated() { pos[v] = Double(k) } }
        for r in 0..<layerCount { renumber(r) }
        for _ in 0..<4 {
            for r in 1..<max(1, layerCount) {
                rows[r].sort { bary($0, parents, pos) < bary($1, parents, pos) }
                renumber(r)
            }
            if layerCount > 1 {
                for r in stride(from: layerCount - 2, through: 0, by: -1) {
                    rows[r].sort { bary($0, children, pos) < bary($1, children, pos) }
                    renumber(r)
                }
            }
        }

        // 5. Across positions: each node near its parents' average, keeping order and gaps.
        var centre = [CGFloat](repeating: 0, count: total)
        for r in 0..<layerCount {
            let row = rows[r]
            var desired: [CGFloat] = row.map { v in
                let ps = parents[v]
                return ps.isEmpty ? .nan : ps.map { centre[$0] }.reduce(0, +) / CGFloat(ps.count)
            }
            // Nodes without parents sit next to their neighbours.
            var x: CGFloat = 0
            for (k, v) in row.enumerated() {
                if desired[k].isNaN { desired[k] = x + nodeAcross[v] / 2 }
                x = desired[k] + nodeAcross[v] / 2 + gapAcross
            }
            // Enforce order and spacing, then shift the row back toward where it wanted to be.
            var placed = desired
            for k in 1..<max(1, row.count) {
                let minC = placed[k - 1] + nodeAcross[row[k - 1]] / 2 + gapAcross + nodeAcross[row[k]] / 2
                if placed[k] < minC { placed[k] = minC }
            }
            let shift = zip(desired, placed).map { $0 - $1 }.reduce(0, +) / CGFloat(max(1, row.count))
            for (k, v) in row.enumerated() { centre[v] = placed[k] + shift }
        }
        let minLeft = (0..<total).map { centre[$0] - nodeAcross[$0] / 2 }.min() ?? 0
        for v in 0..<total { centre[v] -= minLeft }
        let acrossExtent = (0..<total).map { centre[$0] + nodeAcross[$0] / 2 }.max() ?? 0

        // Along positions: each layer as deep as its tallest box, labels get extra room.
        var layerStart = [CGFloat](repeating: 0, count: layerCount)
        var layerDepth = [CGFloat](repeating: 0, count: layerCount)
        for r in 0..<layerCount { layerDepth[r] = rows[r].map { nodeAlong[$0] }.max() ?? 0 }
        var cursor: CGFloat = 0
        for r in 0..<layerCount {
            layerStart[r] = cursor
            cursor += layerDepth[r] + gapAlong
        }

        func rect(_ v: Int) -> CGRect {
            let a0 = layerStart[nodeLayer[v]] + (layerDepth[nodeLayer[v]] - nodeAlong[v]) / 2
            let c0 = centre[v] - nodeAcross[v] / 2
            return down ? CGRect(x: c0, y: a0, width: nodeAcross[v], height: nodeAlong[v])
                        : CGRect(x: a0, y: c0, width: nodeAlong[v], height: nodeAcross[v])
        }
        var frames = (0..<n).map(rect)

        // 6. Routes.
        var routed: [Edge] = []
        var lanes = 0
        let labelled = Set(valid.enumerated().filter { $0.element.2 }.map(\.offset))
        for (i, e) in valid.enumerated() {
            let a = frames[e.0], b = frames[e.1]
            if let seq = chains[i] {
                var pts: [CGPoint] = [down ? CGPoint(x: a.midX, y: a.maxY) : CGPoint(x: a.maxX, y: a.midY)]
                for d in seq.dropFirst().dropLast() {
                    let r = rect(d)
                    pts.append(down ? CGPoint(x: r.midX, y: r.minY) : CGPoint(x: r.minX, y: r.midY))
                    pts.append(down ? CGPoint(x: r.midX, y: r.maxY) : CGPoint(x: r.maxX, y: r.midY))
                }
                pts.append(down ? CGPoint(x: b.midX, y: b.minY) : CGPoint(x: b.minX, y: b.midY))
                // Labels ("Yes", "No") sit just after the edge leaves its source.
                var label: CGPoint?
                if labelled.contains(i) {
                    let p0 = pts[0], p1 = pts[1]
                    label = CGPoint(x: p0.x + (p1.x - p0.x) * 0.35 + (down ? 10 : 0), y: p0.y + (p1.y - p0.y) * 0.35 + (down ? 0 : -10))
                }
                routed.append(Edge(from: e.0, to: e.1, points: pts, labelAt: label, isBack: false))
            } else {
                // Back edge: out of the source's side, along a lane past everything, into the target's side.
                lanes += 1
                let lane = (down ? acrossExtent : (alongExtentCross(frames))) + backLane * CGFloat(lanes)
                let pts: [CGPoint]
                if down {
                    pts = [CGPoint(x: a.maxX, y: a.midY), CGPoint(x: lane, y: a.midY), CGPoint(x: lane, y: b.midY), CGPoint(x: b.maxX, y: b.midY)]
                } else {
                    pts = [CGPoint(x: a.midX, y: a.maxY), CGPoint(x: a.midX, y: lane), CGPoint(x: b.midX, y: lane), CGPoint(x: b.midX, y: b.maxY)]
                }
                let label: CGPoint? = labelled.contains(i) ? CGPoint(x: (pts[1].x + pts[2].x) / 2 + (down ? 12 : 0), y: (pts[1].y + pts[2].y) / 2 + (down ? 0 : 12)) : nil
                routed.append(Edge(from: e.0, to: e.1, points: pts, labelAt: label, isBack: true))
            }
        }

        // Shift everything inside a margin.
        var bounds = frames.reduce(CGRect.null) { $0.union($1) }
        for e in routed { for p in e.points { bounds = bounds.union(CGRect(x: p.x, y: p.y, width: 0, height: 0)) } }
        let dx = margin - bounds.minX, dy = margin - bounds.minY
        frames = frames.map { $0.offsetBy(dx: dx, dy: dy) }
        routed = routed.map { e in
            var c = e
            c.points = e.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            c.labelAt = e.labelAt.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            return c
        }
        let extra: CGFloat = routed.contains { $0.labelAt != nil } ? 30 : 0
        return Result(frames: frames, edges: routed,
                      size: CGSize(width: bounds.width + 2 * margin + (down ? extra : 0), height: bounds.height + 2 * margin + (down ? 0 : extra)))
    }

    /// For left-to-right charts, back edges run below everything.
    private static func alongExtentCross(_ frames: [CGRect]) -> CGFloat {
        frames.map(\.maxY).max() ?? 0
    }

    private static func bary(_ v: Int, _ links: [[Int]], _ pos: [Double]) -> Double {
        let l = links[v]
        guard !l.isEmpty else { return pos[v] }
        return l.map { pos[$0] }.reduce(0, +) / Double(l.count)
    }

    /// Stages around a circle, in node order, with arrows curving between them.
    private static func cycle(sizes: [CGSize], edges: [(Int, Int, Bool)]) -> Result {
        let n = sizes.count
        let maxW = sizes.map(\.width).max() ?? 0, maxH = sizes.map(\.height).max() ?? 0
        // Big enough that neighbouring boxes don't touch.
        let step = 2 * CGFloat.pi / CGFloat(max(n, 1))
        let needed = (max(maxW, maxH) + gapAcross) / max(0.3, 2 * sin(step / 2))
        let r = max(needed, n <= 2 ? maxH + 40 : 0, 90)
        let rx = r + maxW * 0.15, ry = r
        let cx = rx + maxW / 2 + margin, cy = ry + maxH / 2 + margin
        var frames: [CGRect] = []
        for i in 0..<n {
            let t = -CGFloat.pi / 2 + step * CGFloat(i)
            let c = CGPoint(x: cx + rx * cos(t), y: cy + ry * sin(t))
            frames.append(CGRect(x: c.x - sizes[i].width / 2, y: c.y - sizes[i].height / 2, width: sizes[i].width, height: sizes[i].height))
        }
        let centre = CGPoint(x: cx, y: cy)
        let list = edges.isEmpty && n > 1 ? (0..<n).map { ($0, ($0 + 1) % n, false) } : edges
        let routed = list.map { e -> Edge in
            let a = frames[e.0], b = frames[e.1]
            let start = borderPoint(of: a, toward: CGPoint(x: b.midX, y: b.midY))
            let end = borderPoint(of: b, toward: CGPoint(x: a.midX, y: a.midY))
            let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            // Bulge away from the centre.
            let vx = mid.x - centre.x, vy = mid.y - centre.y
            let len = max(1, (vx * vx + vy * vy).squareRoot())
            let control = CGPoint(x: mid.x + vx / len * 22, y: mid.y + vy / len * 22)
            return Edge(from: e.0, to: e.1, points: [start, end], labelAt: e.2 ? CGPoint(x: control.x + vx / len * 14, y: control.y + vy / len * 14) : nil,
                        isBack: false, control: control)
        }
        let size = CGSize(width: 2 * cx, height: 2 * cy)
        return Result(frames: frames, edges: routed, size: size)
    }

    /// Where the line from a box's centre toward a point leaves the box.
    static func borderPoint(of r: CGRect, toward p: CGPoint) -> CGPoint {
        let c = CGPoint(x: r.midX, y: r.midY)
        let dx = p.x - c.x, dy = p.y - c.y
        guard dx != 0 || dy != 0 else { return c }
        let sx = dx == 0 ? CGFloat.infinity : (r.width / 2) / abs(dx)
        let sy = dy == 0 ? CGFloat.infinity : (r.height / 2) / abs(dy)
        let s = min(sx, sy)
        return CGPoint(x: c.x + dx * s, y: c.y + dy * s)
    }
}
