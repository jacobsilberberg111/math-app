import UIKit

/// The `geometry` tool: a polygon with its side, angle and vertex labels placed for the tutor.
extension CanvasActionExecutor {
    func geometry(_ args: ToolArgs) throws -> Outcome {
        let page = try resolvePage(args.int("page"))
        var poly: [CGPoint] = []
        var names: [String?] = []
        for v in args.array("vertices") {
            guard let x = v["x"]?.doubleValue, let y = v["y"]?.doubleValue, x.isFinite, y.isFinite else { continue }
            poly.append(CGPoint(x: x, y: y))
            let name = v["name"]?.stringValue?.trimmed ?? ""
            names.append(name.isEmpty ? nil : name)
        }
        guard poly.count >= 3 else { throw ToolInputError(message: "Give at least 3 vertices with x and y.") }
        let b = ShapeGeometry.bounds(poly)
        guard b.width >= 20 || b.height >= 20 else { throw ToolInputError(message: "The figure is too small; make it at least 80 pt across.") }

        func vertexIndex(_ value: JSONValue?) -> Int? {
            guard let value else { return nil }
            if case .number(let n) = value { let i = Int(n.rounded()) - 1; return poly.indices.contains(i) ? i : nil }
            guard let s = value.stringValue?.trimmed, !s.isEmpty else { return nil }
            if let i = names.firstIndex(where: { $0 == s }) { return i }
            if let i = names.firstIndex(where: { $0?.lowercased() == s.lowercased() }) { return i }
            if let n = Int(s), poly.indices.contains(n - 1) { return n - 1 }
            return nil
        }

        let hex = color(args.string("color"))
        let width = CGFloat(min(6, max(1, args.double("width") ?? 2.2)))
        var strokes: [[CGPoint]] = [poly + [poly[0]]]
        var labels: [(text: String, place: (CGSize) -> CGPoint)] = []
        var problems: [String] = []

        // Sides
        var sideExtra: [Int: CGFloat] = [:]
        for s in args.array("sides") {
            guard let i = vertexIndex(s["from"]), let j = vertexIndex(s["to"]) else {
                problems.append("a side refers to an unknown vertex"); continue
            }
            let n = poly.count
            let side: Int
            if (i + 1) % n == j { side = i } else if (j + 1) % n == i { side = j } else {
                problems.append("\(names[i] ?? "\(i + 1)")–\(names[j] ?? "\(j + 1)") isn't a side"); continue
            }
            if let ticks = s["ticks"]?.intValue, ticks > 0 {
                strokes += GeometryLayout.sideTicks(poly, side: side, count: ticks)
                sideExtra[side] = 5
            }
            if let text = s["text"]?.stringValue?.trimmed, !text.isEmpty {
                let extra = sideExtra[side] ?? 0
                labels.append((text: text, place: { GeometryLayout.sideLabelCenter(poly, side: side, labelSize: $0, extra: extra) }))
            }
        }

        // Angles
        for a in args.array("angles") {
            guard let i = vertexIndex(a["vertex"]) else { problems.append("an angle refers to an unknown vertex"); continue }
            let isRight = GeometryLayout.isRightAngle(poly, i)
            let mark = a["mark"]?.stringValue ?? (isRight ? "right" : "arc")
            var r = GeometryLayout.arcRadius(poly, i)
            switch mark {
            case "right":
                strokes.append(GeometryLayout.rightAngleMark(poly, i))
                r = max(r, 12)
            case "double_arc":
                strokes.append(GeometryLayout.angleArc(poly, i, radius: r))
                strokes.append(GeometryLayout.angleArc(poly, i, radius: r + 4))
                r += 4
            case "none":
                break
            default:
                strokes.append(GeometryLayout.angleArc(poly, i, radius: r))
            }
            if let text = a["text"]?.stringValue?.trimmed, !text.isEmpty {
                let arc = r
                labels.append((text: text, place: { GeometryLayout.angleLabelCenter(poly, i, labelSize: $0, arcRadius: arc) }))
            }
        }

        // Vertex names
        for (i, name) in names.enumerated() {
            guard let name else { continue }
            labels.append((text: name, place: { GeometryLayout.vertexLabelCenter(poly, i, labelSize: $0) }))
        }

        guard let e = inkElement(page: page, strokes: strokes, colorHex: hex, width: width, purpose: .box) else {
            throw ToolInputError(message: "Nothing to draw.")
        }
        addInk(e)
        var ids = [e.id]
        for l in labels {
            let content = TextContent(text: l.text, style: .handwriting, fontSize: 17, colorHex: hex, rich: true)
            let w = ElementRenderer.fittedTextWidth(content, author: .tutor, maxWidth: 160, env: env)
            let h = ElementRenderer.measureText(content, author: .tutor, width: w, env: env).height
            let c = l.place(CGSize(width: w, height: h))
            let label = addTutorElement(page: page, frame: CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h), kind: .text(content))
            ids.append(label.id)
        }
        var result = "Drew \(e.id), a \(poly.count)-sided figure on page \(page + 1) covering \(describe(e.frame))"
        if ids.count > 1 { result += "; labels \(ids.dropFirst().joined(separator: ", "))" }
        result += "."
        if !problems.isEmpty { result += " Skipped: " + problems.joined(separator: "; ") + "." }
        return Outcome(result: result, isError: false,
                       action: ChatAction(symbol: "triangle", summary: "Drew a figure on p.\(page + 1)", elementIDs: ids, page: page))
    }
}
