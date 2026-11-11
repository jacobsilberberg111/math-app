import UIKit

/// The `flowchart`, `label_diagram` and `find_diagram` tools.
extension CanvasActionExecutor {
    // MARK: Flowchart

    func flowchartTool(_ args: ToolArgs) throws -> Outcome {
        let page = try resolvePage(args.int("page"))
        var nodes: [FlowNode] = []
        var seen = Set<String>()
        for (i, n) in args.array("nodes").enumerated() {
            guard let text = n["text"]?.stringValue?.trimmed, !text.isEmpty else {
                throw ToolInputError(message: "Node \(i + 1) has no text.")
            }
            var id = n["id"]?.stringValue?.trimmed ?? ""
            if id.isEmpty || seen.contains(id) { id = "n\(i + 1)" }
            seen.insert(id)
            let shape = n["shape"]?.stringValue.flatMap(FlowShape.init(rawValue:)) ?? .process
            let colorHex = n["color"]?.stringValue.map { color($0) }
            nodes.append(FlowNode(id: id, text: text, shape: shape, colorHex: colorHex))
        }
        guard !nodes.isEmpty else { throw ToolInputError(message: "nodes must list at least one box.") }
        guard nodes.count <= 40 else { throw ToolInputError(message: "That's \(nodes.count) boxes; keep a flowchart to 40 or fewer (split it into two).") }
        let direction = args.string("direction").flatMap(FlowDirection.init(rawValue:)) ?? .down
        var edges: [FlowEdge] = []
        var unknown: [String] = []
        for e in args.array("edges") {
            guard let from = e["from"]?.stringValue, let to = e["to"]?.stringValue else { continue }
            for id in [from, to] where !seen.contains(id) { unknown.append(id) }
            let label = e["label"]?.stringValue?.trimmed ?? ""
            edges.append(FlowEdge(from: from, to: to, label: label.isEmpty ? nil : label))
        }
        if !unknown.isEmpty {
            throw ToolInputError(message: "Arrows refer to unknown node ids: \(Set(unknown).sorted().joined(separator: ", ")). Node ids are: \(nodes.map(\.id).joined(separator: ", ")).")
        }
        if edges.isEmpty && direction != .cycle && nodes.count > 1 {
            // A plain sequence: join the boxes in order.
            edges = zip(nodes, nodes.dropFirst()).map { FlowEdge(from: $0.id, to: $1.id, label: nil) }
        }
        let content = FlowchartContent(title: args.string("title"), direction: direction, nodes: nodes, edges: edges,
                                       colorHex: color(args.string("color"), default: "#1F2328"))
        let natural = FlowchartRenderer.naturalSize(content)
        let maxW = min(area.width - 32, args.cg("max_width") ?? area.width - 32)
        let maxH = document.isFreeform ? 1400 : pageHeight - 80
        let s = min(1, maxW / max(natural.width, 1), maxH / max(natural.height, 1))
        let size = CGSize(width: ceil(natural.width * s), height: ceil(natural.height * s))
        let requested = CGRect(x: args.cg("x") ?? area.midX - size.width / 2, y: args.cg("y") ?? area.minY + 100, width: size.width, height: size.height)
        let (frame, _) = layout.place(requested, page: page)
        let e = addTutorElement(page: page, frame: frame, kind: .flowchart(content))
        let boxes = zip(nodes, FlowchartRenderer.nodeFrames(content, in: frame)).map { "\($0.id) \($1.roundedForDisplay)" }
        return Outcome(result: "Flowchart \(e.id) on page \(page + 1) at \(describe(frame))\(s < 0.99 ? " (scaled to \(Int(s * 100))% to fit)" : ""). Boxes: " + boxes.joined(separator: "; "),
                       isError: false, action: ChatAction(symbol: "arrow.triangle.branch", summary: "Flowchart on p.\(page + 1)", elementIDs: [e.id], page: page))
    }

    // MARK: Labels

    func labelDiagramTool(_ args: ToolArgs) throws -> Outcome {
        if let id = args.string("labels_id") { return try revealLabels(id, args) }
        let page: Int
        let target: CGRect
        var targetID: String?
        if let id = args.string("element_id") {
            let el = try element(id)
            page = el.pageIndex
            target = el.frame
            targetID = id
        } else {
            page = try resolvePage(args.int("page"))
            guard let x = args.cg("x"), let y = args.cg("y"), let w = args.cg("width"), let h = args.cg("height"), w > 10, h > 10 else {
                throw ToolInputError(message: "Give element_id (the picture to label) or page, x, y, width and height for the region.")
            }
            target = CGRect(x: x, y: y, width: w, height: h)
        }
        let quiz = args.bool("quiz") ?? false
        let colorHex = color(args.string("color"), default: "#1F2328")
        let font = NoteFonts.sans(size: 15, weight: .medium)
        var inputs: [LabelLayout.Input] = []
        var texts: [String] = []
        let near = target.insetBy(dx: -24, dy: -24)
        for (i, l) in args.array("labels").enumerated() {
            guard let text = l["text"]?.stringValue?.trimmed, !text.isEmpty,
                  let x = l["x"]?.doubleValue, let y = l["y"]?.doubleValue else {
                throw ToolInputError(message: "Label \(i + 1) needs text, x and y.")
            }
            let p = CGPoint(x: x, y: y)
            guard near.contains(p) else {
                throw ToolInputError(message: "Label \"\(text)\" points at (\(Int(x)), \(Int(y))), outside the picture at \(describe(target)). Give page coordinates of a point on the part.")
            }
            texts.append(text)
            inputs.append(LabelLayout.Input(size: LabelRenderer.boxSize(text: text, number: i + 1, quiz: quiz, font: font), anchor: p))
        }
        guard !inputs.isEmpty else { throw ToolInputError(message: "labels must list at least one label.") }
        guard inputs.count <= 24 else { throw ToolInputError(message: "Keep it to 24 labels or fewer.") }
        let title = args.string("title")
        let bounds = (document.isFreeform ? area : CGRect(origin: .zero, size: document.pageSize)).insetBy(dx: 12, dy: 12)
        let boxes = LabelLayout.place(inputs, target: target, bounds: bounds)
        let covers = args.array("cover").compactMap { c -> CGRect? in
            guard let x = c["x"]?.doubleValue, let y = c["y"]?.doubleValue, let w = c["width"]?.doubleValue, let h = c["height"]?.doubleValue, w > 0, h > 0 else { return nil }
            return CGRect(x: x, y: y, width: w, height: h)
        }
        var frame = boxes.reduce(target) { $0.union($1) }
        for c in covers { frame = frame.union(c) }
        if title != nil { frame = frame.union(CGRect(x: target.minX, y: target.minY - LabelRenderer.titleHeight - 4, width: max(200, target.width), height: LabelRenderer.titleHeight)) }
        frame = frame.insetBy(dx: -6, dy: -6)
        let o = frame.origin
        let labels = zip(inputs, boxes).enumerated().map { i, pair in
            DiagramLabel(number: i + 1, text: texts[i],
                         anchor: CGPoint(x: pair.0.anchor.x - o.x, y: pair.0.anchor.y - o.y),
                         box: pair.1.offsetBy(dx: -o.x, dy: -o.y))
        }
        let content = LabelSetContent(title: title, labels: labels, covers: covers.map { $0.offsetBy(dx: -o.x, dy: -o.y) },
                                      quiz: quiz, colorHex: colorHex, targetElementID: targetID)
        let e = addTutorElement(page: page, frame: frame, kind: .labels(content))
        let list = labels.map { "\($0.number) \"\($0.text)\" box \($0.box.offsetBy(dx: o.x, dy: o.y).roundedForDisplay)" }.joined(separator: "; ")
        let what = quiz ? "Labelling quiz \(e.id) with \(labels.count) numbered blanks (answers hidden)" : "Labels \(e.id)"
        return Outcome(result: "\(what) on page \(page + 1) at \(describe(frame)): \(list).", isError: false,
                       action: ChatAction(symbol: "tag", summary: quiz ? "Label quiz on p.\(page + 1)" : "Labels on p.\(page + 1)", elementIDs: [e.id], page: page))
    }

    private func revealLabels(_ id: String, _ args: ToolArgs) throws -> Outcome {
        let el = try element(id)
        guard case .labels(var l) = el.kind else { throw ToolInputError(message: "\(id) isn't a labels element.") }
        let numbers = Set(args.array("reveal").compactMap { $0.intValue })
        for i in l.labels.indices where numbers.isEmpty || numbers.contains(l.labels[i].number) {
            l.labels[i].revealed = true
        }
        let updated = l
        noteModified(el)
        document.update(id, actionName: "Tutor") { $0.kind = .labels(updated) }
        return Outcome(result: "Revealed \(numbers.isEmpty ? "all answers" : "answers " + numbers.sorted().map(String.init).joined(separator: ", ")) on \(id).",
                       isError: false, action: ChatAction(symbol: "eye", summary: "Revealed labels", elementIDs: [id], page: el.pageIndex))
    }

    // MARK: Finding diagrams

    func findDiagramTool(_ args: ToolArgs) async throws -> Outcome {
        let query = try args.requireString("query")
        let page = try resolvePage(args.int("page"))
        let candidates: [DiagramSearch.Candidate]
        do {
            candidates = try await DiagramSearch.search(query)
        } catch let e as DiagramSearch.SearchError {
            throw ToolInputError(message: e.message)
        }
        guard !candidates.isEmpty else {
            throw ToolInputError(message: "No diagrams found for \"\(query)\". Try simpler nouns (e.g. \"heart diagram\"), or draw it with draw/flowchart.")
        }
        let pick = max(1, min(candidates.count, args.int("pick") ?? 1))
        let chosen = candidates[pick - 1]
        let image: UIImage
        do {
            image = try await DiagramSearch.image(chosen)
        } catch let e as DiagramSearch.SearchError {
            throw ToolInputError(message: e.message)
        }
        try Task.checkCancellation()
        guard let asset = document.storeImage(image) else { throw ToolInputError(message: "Couldn't save the image.") }
        let aspect = image.size.height / max(image.size.width, 1)
        var w = min(600, max(160, args.cg("width") ?? 380), area.width - 48)
        var h = w * aspect
        if h > 560 { h = 560; w = h / max(aspect, 0.01) }
        let creditHeight: CGFloat = 16
        let requested = CGRect(x: args.cg("x") ?? area.midX - w / 2, y: args.cg("y") ?? area.minY + 100, width: w, height: h + creditHeight + 4)
        let (spot, _) = layout.place(requested, page: page)
        let frame = CGRect(x: spot.minX, y: spot.minY, width: w, height: h)
        let img = addTutorElement(page: page, frame: frame, kind: .image(ImageContent(assetID: asset)))
        let credit = TextContent(text: chosen.credit, style: .typed, fontSize: 10, colorHex: "#8A939E", rich: false)
        let creditFrame = CGRect(x: frame.minX, y: frame.maxY + 3, width: max(w, 260), height: creditHeight)
        let creditElement = addTutorElement(page: page, frame: creditFrame, kind: .text(credit), reveal: false)
        let others = candidates.enumerated().filter { $0.offset != pick - 1 }.prefix(5)
            .map { "\($0.offset + 1). \($0.element.displayName)" }.joined(separator: "; ")
        var result = "Placed \"\(chosen.displayName)\" as image \(img.id) on page \(page + 1) at \(describe(frame)), credit \(creditElement.id) under it. "
        result += "The attached copy has page-coordinate grid lines every 50 pt, so you can read the page position of any part. "
        if !others.isEmpty { result += "Other candidates (call again with pick after deleting this one): \(others)." }
        var images: [Data] = []
        if let jpeg = gridded(image, frame: frame) { images.append(jpeg) }
        return Outcome(result: result, isError: false,
                       action: ChatAction(symbol: "photo", summary: "Diagram: \(chosen.displayName.truncated(40))", elementIDs: [img.id, creditElement.id], page: page),
                       images: images)
    }

    /// The image as it sits on the page, with page-coordinate grid lines every 50 pt, labelled.
    private func gridded(_ image: UIImage, frame: CGRect) -> Data? {
        let scale = min(2, 900 / max(frame.width, frame.height))
        let size = CGSize(width: frame.width * scale, height: frame.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { rc in
            let ctx = rc.cgContext
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
            let font = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor(red: 0.1, green: 0.35, blue: 0.85, alpha: 1),
                                                        .backgroundColor: UIColor.white.withAlphaComponent(0.8)]
            ctx.setStrokeColor(UIColor(red: 0.2, green: 0.45, blue: 0.95, alpha: 0.35).cgColor)
            ctx.setLineWidth(1)
            var x = (frame.minX / 50).rounded(.up) * 50
            while x < frame.maxX {
                let px = (x - frame.minX) * scale
                ctx.move(to: CGPoint(x: px, y: 0))
                ctx.addLine(to: CGPoint(x: px, y: size.height))
                ctx.strokePath()
                NSAttributedString(string: "\(Int(x))", attributes: attrs).draw(at: CGPoint(x: px + 2, y: 2))
                x += 50
            }
            var y = (frame.minY / 50).rounded(.up) * 50
            while y < frame.maxY {
                let py = (y - frame.minY) * scale
                ctx.move(to: CGPoint(x: 0, y: py))
                ctx.addLine(to: CGPoint(x: size.width, y: py))
                ctx.strokePath()
                NSAttributedString(string: "\(Int(y))", attributes: attrs).draw(at: CGPoint(x: 2, y: py + 2))
                y += 50
            }
        }
        return rendered.jpegData(compressionQuality: 0.72)
    }
}
