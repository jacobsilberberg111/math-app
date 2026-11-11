import UIKit

/// The bundled geography, loaded on first use.
enum GeoAssets {
    static let world: GeoWorld? = load("geo_world") { try GeoWorld(data: $0) }
    static let places: GeoPlaces? = load("geo_places") { try GeoPlaces(data: $0) }
    static let koppen: KoppenData? = load("geo_koppen") { try KoppenData(data: $0) }

    private static func load<T>(_ name: String, _ make: (Data) throws -> T) -> T? {
        guard let url = AppResources.url(name, ext: "json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? make(data)
    }
}

/// Draws MapContent: an atlas-style map card with title, map, legend, scale bar, north arrow and
/// source (BOLTSS), under the student's ink.
@MainActor
enum MapRenderer {
    /// Core Graphics paths for a built scene.
    final class Paths {
        var fills: [(CGPath, UIColor)] = []
        var land = CGMutablePath()
        var noData: CGPath?
        var coast = CGMutablePath()
        var borders = CGMutablePath()
        var stateBorders = CGMutablePath()
        var lakes = CGMutablePath()
        var saltLakes = CGMutablePath()
        var rivers: [(CGPath, CGFloat)] = []
        var graticule = CGMutablePath()
        var special: [(CGPath, UIColor, Bool)] = []
        var sphere: CGPath?
        var koppen: [(CGPath, UIColor)] = []
        var highlightFills: [(CGPath, UIColor)] = []
        var highlightOutlines: [(CGPath, UIColor)] = []
        var noDataBounds: CGRect = .null
    }

    private struct Entry {
        let content: MapContent
        let size: CGSize
        let scene: MapScene
        let paths: Paths
    }

    private static var cache: [Entry] = []

    /// Text size with the fonts the map draws with (UIFont and NSString measuring are thread-safe).
    nonisolated static func measure(_ text: String, _ size: CGFloat, _ bold: Bool) -> CGSize {
        let f = NoteFonts.sans(size: size, weight: bold ? .semibold : .regular)
        let s = (text as NSString).size(withAttributes: [.font: f])
        return CGSize(width: ceil(s.width), height: ceil(s.height))
    }

    /// The scene for this content at this size (cached).
    static func cachedScene(for m: MapContent, size: CGSize) -> (scene: MapScene, paths: Paths)? {
        let key = CGSize(width: size.width.rounded(), height: size.height.rounded())
        if let i = cache.firstIndex(where: { $0.size == key && $0.content == m }) {
            let e = cache[i]
            if i != cache.count - 1 {
                cache.remove(at: i)
                cache.append(e)
            }
            return (e.scene, e.paths)
        }
        guard let world = GeoAssets.world else { return nil }
        let scene = MapScene.build(m, size: key, world: world, koppen: m.style == .climate ? GeoAssets.koppen : nil,
                                   places: GeoAssets.places, measure: MapRenderer.measure)
        let paths = makePaths(scene)
        cache.append(Entry(content: m, size: key, scene: scene, paths: paths))
        if cache.count > 10 { cache.removeFirst() }
        return (scene, paths)
    }

    private static func addRings(_ rings: [[CGPoint]], to p: CGMutablePath) {
        for r in rings where r.count >= 3 {
            p.addLines(between: r)
            p.closeSubpath()
        }
    }

    private static func addLines(_ lines: [[CGPoint]], to p: CGMutablePath) {
        for l in lines where l.count >= 2 { p.addLines(between: l) }
    }

    private static func makePaths(_ s: MapScene) -> Paths {
        let p = Paths()
        var byColor: [String: CGMutablePath] = [:]
        var order: [String] = []
        let noData = CGMutablePath()
        let noDataSet = Set(s.noDataCodes)
        for c in s.countries {
            addRings(c.rings, to: p.land)
            if noDataSet.contains(c.code) {
                addRings(c.rings, to: noData)
                p.noDataBounds = p.noDataBounds.union(c.bounds)
            }
            guard let hex = c.fillHex else { continue }
            if byColor[hex] == nil { byColor[hex] = CGMutablePath(); order.append(hex) }
            addRings(c.rings, to: byColor[hex]!)
        }
        p.fills = order.map { (byColor[$0]!, UIColor(hex: $0)) }
        if !noDataSet.isEmpty { p.noData = noData }
        addLines(s.coast, to: p.coast)
        addLines(s.borders, to: p.borders)
        addLines(s.stateBorders, to: p.stateBorders)
        for l in s.lakes { addRings(l.rings, to: l.salt ? p.saltLakes : p.lakes) }
        var riverPaths: [Int: CGMutablePath] = [:]
        for r in s.rivers {
            let k = r.rank <= 2 ? 0 : (r.rank <= 4 ? 1 : 2)
            if riverPaths[k] == nil { riverPaths[k] = CGMutablePath() }
            addLines(r.lines, to: riverPaths[k]!)
        }
        p.rivers = riverPaths.keys.sorted().map { (riverPaths[$0]!, [1.3, 0.95, 0.7][$0]) }
        addLines(s.graticule, to: p.graticule)
        p.special = s.specialLines.map { line in
            let path = CGMutablePath()
            addLines(line.lines, to: path)
            return (path, UIColor(hex: line.colorHex), line.dashed)
        }
        if let sp = s.sphere {
            let path = CGMutablePath()
            path.addLines(between: sp)
            path.closeSubpath()
            p.sphere = path
        }
        p.koppen = s.koppen.map { k in
            let path = CGMutablePath()
            for q in k.quads { path.addLines(between: q); path.closeSubpath() }
            return (path, UIColor(hex: k.colorHex))
        }
        p.highlightFills = s.highlightFills.map { h in
            let path = CGMutablePath()
            addRings(h.rings, to: path)
            return (path, UIColor(hex: h.colorHex))
        }
        p.highlightOutlines = s.highlightOutlines.map { h in
            let path = CGMutablePath()
            addRings(h.rings, to: path)
            return (path, UIColor(hex: h.colorHex))
        }
        return p
    }

    /// A good card size for a map: the region's shape at this width, plus title, legend and footer.
    static func preferredSize(_ m: MapContent, width: CGFloat, maxHeight: CGFloat) -> CGSize {
        let classes = m.style == .climate ? (GeoAssets.koppen.map { MapScene.koppenClasses(m, koppen: $0, width: width) } ?? []) : []
        let chrome = MapLayout.chromeHeight(m, width: width, measure: MapRenderer.measure, koppenClasses: classes)
        let mapH = min(max(MapLayout.naturalMapHeight(m, width: width), 180), 660)
        return CGSize(width: width, height: min(maxHeight, max(220, mapH + chrome)))
    }

    // MARK: Drawing

    static func draw(_ m: MapContent, rect: CGRect, progress: CGFloat, env: RenderEnvironment, ctx: CGContext) {
        let chromeAlpha = min(1, progress / 0.25)
        // Card.
        ctx.setFillColor(UIColor.white.withAlphaComponent(0.96 * chromeAlpha).cgColor)
        ctx.addPath(UIBezierPath(roundedRect: rect, cornerRadius: 10).cgPath)
        ctx.fillPath()
        ctx.setStrokeColor(UIColor(hex: "#D0D7E2").withAlphaComponent(chromeAlpha).cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(UIBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 10).cgPath)
        ctx.strokePath()

        guard rect.width > 60, rect.height > 60, let built = cachedScene(for: m, size: rect.size) else {
            UIGraphicsPushContext(ctx)
            NSAttributedString(string: "Map data unavailable", attributes: [.font: NoteFonts.sans(size: 13, weight: .medium), .foregroundColor: UIColor.secondaryLabel])
                .draw(at: CGPoint(x: rect.minX + 12, y: rect.minY + 12))
            UIGraphicsPopContext()
            return
        }
        let scene = built.scene, paths = built.paths
        let layout = scene.layout
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        // The student may have resized the element since the scene was cached at a rounded size.
        let sx = rect.width / max(1, scene.layout.size.width), sy = rect.height / max(1, scene.layout.size.height)
        if abs(sx - 1) > 0.001 || abs(sy - 1) > 0.001 { ctx.scaleBy(x: sx, y: sy) }

        let mapP = max(0, min(1, (progress - 0.05) / 0.7))
        let eased = mapP * mapP * (3 - 2 * mapP)
        let mr = layout.mapRect

        ctx.saveGState()
        ctx.clip(to: CGRect(x: mr.minX, y: mr.minY, width: mr.width * eased, height: mr.height))
        drawMap(m, scene: scene, paths: paths, ctx: ctx)
        ctx.restoreGState()

        // Neatline.
        ctx.setStrokeColor(UIColor(hex: "#4A5A6A").withAlphaComponent(chromeAlpha).cgColor)
        ctx.setLineWidth(scene.sphere == nil ? 1.2 : 0.9)
        if let sphere = paths.sphere {
            ctx.addPath(sphere)
            ctx.strokePath()
        } else {
            ctx.stroke(mr)
        }

        UIGraphicsPushContext(ctx)
        let labelAlpha = max(0, min(1, (progress - 0.65) / 0.3))
        if labelAlpha > 0 {
            ctx.saveGState()
            ctx.clip(to: mr)
            for t in scene.labels { drawText(t, alpha: labelAlpha) }
            for mk in scene.markers { if let l = mk.label { drawText(l, alpha: labelAlpha) } }
            for r in scene.routes { if let l = r.label { drawText(l, alpha: labelAlpha) } }
            ctx.restoreGState()
        }
        drawChrome(layout, alpha: chromeAlpha, ctx: ctx)
        UIGraphicsPopContext()
        ctx.restoreGState()
    }

    private static func drawMap(_ m: MapContent, scene: MapScene, paths: Paths, ctx: CGContext) {
        let mr = scene.layout.mapRect
        let sea = UIColor(hex: m.style == .outline ? "#E6F1F9" : MapStyleColors.sea)
        // Sea.
        ctx.setFillColor(sea.cgColor)
        if let sphere = paths.sphere {
            ctx.addPath(sphere)
            ctx.fillPath()
            ctx.addPath(sphere)
            ctx.clip()
        } else {
            ctx.fill(mr)
        }

        // Land fills.
        for (path, color) in paths.fills {
            ctx.addPath(path)
            ctx.setFillColor(color.cgColor)
            ctx.fillPath(using: .winding)
        }

        // Köppen-Geiger zones, clipped to the coastline.
        if !paths.koppen.isEmpty {
            ctx.saveGState()
            ctx.addPath(paths.land)
            ctx.clip(using: .winding)
            for (path, color) in paths.koppen {
                ctx.addPath(path)
                ctx.setFillColor(color.cgColor)
                ctx.fillPath()
            }
            ctx.restoreGState()
        }

        // No data: grey with hatching.
        if let nd = paths.noData, !paths.noDataBounds.isNull {
            ctx.saveGState()
            ctx.addPath(nd)
            ctx.clip(using: .winding)
            ctx.setStrokeColor(UIColor(hex: "#B5BCC5").cgColor)
            ctx.setLineWidth(0.6)
            let b = paths.noDataBounds.intersection(mr)
            if !b.isNull {
                var x = b.minX - b.height
                while x < b.maxX {
                    ctx.move(to: CGPoint(x: x, y: b.maxY))
                    ctx.addLine(to: CGPoint(x: x + b.height, y: b.minY))
                    x += 4
                }
                ctx.strokePath()
            }
            ctx.restoreGState()
        }

        for (path, color) in paths.highlightFills {
            ctx.addPath(path)
            ctx.setFillColor(color.withAlphaComponent(0.85).cgColor)
            ctx.fillPath(using: .winding)
        }

        // Lakes and rivers.
        ctx.addPath(paths.lakes)
        ctx.setFillColor(sea.cgColor)
        ctx.fillPath(using: .evenOdd)
        ctx.addPath(paths.saltLakes)
        ctx.setFillColor(UIColor(hex: "#EEF4F8").cgColor)
        ctx.fillPath(using: .evenOdd)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for (path, width) in paths.rivers {
            ctx.addPath(path)
            ctx.setStrokeColor(UIColor(hex: MapStyleColors.river).cgColor)
            ctx.setLineWidth(width)
            ctx.strokePath()
        }

        // Graticule.
        if !paths.graticule.isEmpty {
            ctx.addPath(paths.graticule)
            ctx.setStrokeColor(UIColor(hex: MapStyleColors.graticule).withAlphaComponent(0.75).cgColor)
            ctx.setLineWidth(0.5)
            ctx.strokePath()
        }

        // Borders, then coastlines.
        let dataLike = m.style == .data
        ctx.addPath(paths.borders)
        ctx.setStrokeColor((dataLike ? UIColor.white : UIColor(hex: m.style == .outline ? "#5C6B7A" : MapStyleColors.border)).cgColor)
        ctx.setLineWidth(dataLike ? 0.6 : 0.55)
        ctx.strokePath()
        if !paths.stateBorders.isEmpty {
            ctx.addPath(paths.stateBorders)
            ctx.setStrokeColor(UIColor(hex: m.style == .climate ? "#3D4A57" : MapStyleColors.stateBorder).cgColor)
            ctx.setLineWidth(0.7)
            ctx.setLineDash(phase: 0, lengths: [3, 2])
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }
        ctx.addPath(paths.coast)
        ctx.setStrokeColor(UIColor(hex: MapStyleColors.coast).cgColor)
        ctx.setLineWidth(0.8)
        ctx.strokePath()
        ctx.addPath(paths.lakes)
        ctx.addPath(paths.saltLakes)
        ctx.setStrokeColor(UIColor(hex: MapStyleColors.coast).withAlphaComponent(0.6).cgColor)
        ctx.setLineWidth(0.4)
        ctx.strokePath()

        for (path, color) in paths.highlightOutlines {
            ctx.addPath(path)
            ctx.setStrokeColor(UIColor.white.cgColor)
            ctx.setLineWidth(3.6)
            ctx.strokePath()
            ctx.addPath(path)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(2)
            ctx.strokePath()
        }
        for dot in scene.highlightDots {
            let r: CGFloat = 5
            let c = CGRect(x: dot.center.x - r, y: dot.center.y - r, width: 2 * r, height: 2 * r)
            ctx.setStrokeColor(UIColor(hex: dot.colorHex).cgColor)
            ctx.setLineWidth(1.8)
            ctx.strokeEllipse(in: c)
        }

        for (path, color, dashed) in paths.special {
            ctx.addPath(path)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(1.2)
            if dashed { ctx.setLineDash(phase: 0, lengths: [5, 3]) }
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }

        // Routes and markers on top.
        for r in scene.routes { drawRoute(r, ctx: ctx) }
        for mk in scene.markers { drawMarker(mk, ctx: ctx) }
    }

    private static func drawRoute(_ r: MapSceneRoute, ctx: CGContext) {
        guard let last = r.segments.last else { return }
        let path = CGMutablePath()
        path.move(to: r.segments[0].0)
        for s in r.segments { path.addQuadCurve(to: s.2, control: s.1) }
        let color = UIColor(hex: r.colorHex)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(path)
        ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(r.width + 2)
        ctx.strokePath()
        ctx.addPath(path)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(r.width)
        if r.dashed { ctx.setLineDash(phase: 0, lengths: [6, 4]) }
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        if r.arrow {
            let from = hypot(last.2.x - last.1.x, last.2.y - last.1.y) > 1 ? last.1 : last.0
            ElementRenderer.drawArrowHead(at: last.2, from: from, size: 7 + r.width * 2, color: color, ctx: ctx)
        }
    }

    private static func drawMarker(_ mk: MapSceneMarker, ctx: CGContext) {
        let c = mk.center
        let color = UIColor(hex: mk.colorHex)
        ctx.setFillColor(color.cgColor)
        ctx.setStrokeColor(UIColor.white.cgColor)
        ctx.setLineWidth(1.5)
        switch mk.symbol {
        case "star":
            let path = CGMutablePath()
            for i in 0..<10 {
                let r: CGFloat = i % 2 == 0 ? 7 : 3
                let a = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
                let p = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.closeSubpath()
            ctx.addPath(path)
            ctx.drawPath(using: .fillStroke)
        case "square":
            ctx.addRect(CGRect(x: c.x - 4.5, y: c.y - 4.5, width: 9, height: 9))
            ctx.drawPath(using: .fillStroke)
        case "triangle":
            ctx.move(to: CGPoint(x: c.x, y: c.y - 6))
            ctx.addLine(to: CGPoint(x: c.x + 5.5, y: c.y + 4))
            ctx.addLine(to: CGPoint(x: c.x - 5.5, y: c.y + 4))
            ctx.closePath()
            ctx.drawPath(using: .fillStroke)
        default:
            ctx.addEllipse(in: CGRect(x: c.x - 4.5, y: c.y - 4.5, width: 9, height: 9))
            ctx.drawPath(using: .fillStroke)
        }
    }

    private static func font(for t: MapSceneText) -> UIFont {
        if t.italic { return UIFont.italicSystemFont(ofSize: t.size) }
        return NoteFonts.sans(size: t.size, weight: t.bold ? .semibold : .regular)
    }

    /// Call between UIGraphicsPushContext/PopContext.
    private static func drawText(_ t: MapSceneText, alpha: CGFloat) {
        let f = font(for: t)
        let color = UIColor(hex: t.colorHex).withAlphaComponent(alpha)
        let multiline = t.text.contains("\n")
        if t.halo {
            let halo = NSAttributedString(string: t.text, attributes: [.font: f, .strokeColor: UIColor.white.withAlphaComponent(0.9 * alpha),
                                                                         .strokeWidth: NSNumber(value: Double(260 / max(6, t.size)))])
            if multiline { halo.draw(in: t.rect.insetBy(dx: -2, dy: -1)) } else { halo.draw(at: t.rect.origin) }
        }
        let s = NSAttributedString(string: t.text, attributes: [.font: f, .foregroundColor: color])
        if multiline { s.draw(in: t.rect.insetBy(dx: -2, dy: -1)) } else { s.draw(at: t.rect.origin) }
    }

    private static func drawChrome(_ layout: MapLayout, alpha: CGFloat, ctx: CGContext) {
        guard alpha > 0 else { return }
        if let t = layout.title {
            let l = ElementRenderer.richLayout(t.text, font: NoteFonts.sans(size: t.size, weight: .semibold), width: layout.size.width - 2 * MapLayout.pad, rich: true)
            l.draw(in: ctx, origin: t.rect.origin, color: UIColor(hex: "#1F2328").withAlphaComponent(alpha))
        }
        if let s = layout.subtitle { drawText(s, alpha: alpha) }
        if let lt = layout.legendTitle { drawText(lt, alpha: alpha) }
        for e in layout.legend {
            let c = UIColor(hex: e.colorHex).withAlphaComponent(alpha)
            let r = e.swatch
            switch e.kind {
            case .heading:
                break
            case .fill:
                ctx.setFillColor(c.cgColor)
                ctx.fill(r)
                ctx.setStrokeColor(UIColor(hex: "#8A949E").withAlphaComponent(alpha).cgColor)
                ctx.setLineWidth(0.5)
                ctx.stroke(r)
            case .hatch:
                ctx.setFillColor(c.cgColor)
                ctx.fill(r)
                ctx.saveGState()
                ctx.clip(to: r)
                ctx.setStrokeColor(UIColor(hex: "#B5BCC5").withAlphaComponent(alpha).cgColor)
                ctx.setLineWidth(0.6)
                var x = r.minX - r.height
                while x < r.maxX {
                    ctx.move(to: CGPoint(x: x, y: r.maxY))
                    ctx.addLine(to: CGPoint(x: x + r.height, y: r.minY))
                    x += 4
                }
                ctx.strokePath()
                ctx.restoreGState()
                ctx.setStrokeColor(UIColor(hex: "#8A949E").withAlphaComponent(alpha).cgColor)
                ctx.setLineWidth(0.5)
                ctx.stroke(r)
            case .outline:
                ctx.setStrokeColor(c.cgColor)
                ctx.setLineWidth(2)
                ctx.stroke(r.insetBy(dx: 1, dy: 1))
            case .line:
                ctx.setFillColor(c.cgColor)
                ctx.fill(r)
            case .dot:
                ctx.setFillColor(c.cgColor)
                ctx.fillEllipse(in: CGRect(x: r.midX - 4, y: r.midY - 4, width: 8, height: 8))
            }
            drawText(e.text, alpha: alpha)
        }
        if let sb = layout.scaleBar {
            for (i, seg) in sb.segments.enumerated() {
                ctx.setFillColor((i % 2 == 0 ? UIColor(hex: "#1F2328") : UIColor.white).withAlphaComponent(alpha).cgColor)
                ctx.fill(seg)
            }
            if let first = sb.segments.first, let last = sb.segments.last {
                ctx.setStrokeColor(UIColor(hex: "#1F2328").withAlphaComponent(alpha).cgColor)
                ctx.setLineWidth(0.8)
                ctx.stroke(first.union(last))
            }
            for l in sb.labels { drawText(l, alpha: alpha) }
            if let n = sb.note { drawText(n, alpha: alpha) }
        }
        drawNorthArrow(layout.northArrow, alpha: alpha, ctx: ctx)
        if let c = layout.caption { drawText(c, alpha: alpha) }
    }

    private static func drawNorthArrow(_ r: CGRect, alpha: CGFloat, ctx: CGContext) {
        let dark = UIColor(hex: "#1F2328").withAlphaComponent(alpha)
        let n = NSAttributedString(string: "N", attributes: [.font: NoteFonts.sans(size: 10, weight: .bold), .foregroundColor: dark])
        let ns = n.size()
        n.draw(at: CGPoint(x: r.midX - ns.width / 2, y: r.minY))
        let top = CGPoint(x: r.midX, y: r.minY + ns.height + 1)
        let bottom = r.maxY - 1
        let w = r.width / 2 - 2
        // Left half filled, right half outlined: the classic map north arrow.
        ctx.setFillColor(dark.cgColor)
        ctx.move(to: top)
        ctx.addLine(to: CGPoint(x: r.midX - w, y: bottom))
        ctx.addLine(to: CGPoint(x: r.midX, y: bottom - 4))
        ctx.closePath()
        ctx.fillPath()
        ctx.setStrokeColor(dark.cgColor)
        ctx.setLineWidth(0.9)
        ctx.setLineJoin(.round)
        ctx.move(to: top)
        ctx.addLine(to: CGPoint(x: r.midX + w, y: bottom))
        ctx.addLine(to: CGPoint(x: r.midX, y: bottom - 4))
        ctx.addLine(to: CGPoint(x: r.midX - w, y: bottom))
        ctx.closePath()
        ctx.strokePath()
    }

    // MARK: Tutor description

    /// What the map shows and how lon/lat map onto page coordinates for the element's current
    /// frame, so the tutor can annotate places precisely.
    static func tutorDescription(_ m: MapContent, frame: CGRect) -> String {
        var s = "\(m.title.map { "\"\($0)\" " } ?? "")\(m.style.displayName.lowercased()) map of \(m.region ?? (m.isWorld ? "the world" : "a region"))"
        if m.isWorld { s += " (\(m.projectionKind.displayName)\(abs(m.centralLon ?? 0) > 0.1 ? ", Pacific-centred" : ""))" }
        s += "."
        if let c = m.choropleth {
            s += " Data: \(c.indicator)\(c.unit.map { " (\($0))" } ?? ""), \(c.yearLabel), \(c.provider)."
            var names: [String: String] = [:]
            for code in c.values.keys { names[code] = GeoAssets.world?.country(code: code)?.longName ?? code }
            s += " " + GeoDataSummary.text(values: c.values.filter { $0.key != "SOL" }, names: names, unit: nil, count: 3)
        }
        if m.style == .climate {
            if let built = cachedScene(for: m, size: frame.size) {
                let codes = built.scene.koppenClasses.compactMap { Koppen.cls($0)?.code }
                s += " Köppen–Geiger classes shown: \(codes.joined(separator: ", "))."
            }
        }
        for h in m.highlights ?? [] {
            s += " Highlighted \(h.codes.joined(separator: ", "))\(h.label.map { " as \"\($0)\"" } ?? "")."
        }
        guard let scene = cachedScene(for: m, size: frame.size)?.scene else { return s }
        let origin = frame.origin
        let mr = scene.layout.mapRect.offsetBy(dx: origin.x, dy: origin.y)
        s += " Map area on the page: \(mr.roundedForDisplay). " + MapDescriber.conversion(scene.layout, origin: origin)
        if !scene.markers.isEmpty {
            s += " Markers: " + scene.markers.map { mk in
                "\(mk.name ?? "marker") at page (\(Int((mk.center.x + origin.x).rounded())), \(Int((mk.center.y + origin.y).rounded())))"
            }.joined(separator: "; ") + "."
        }
        if let src = m.source { s += " Caption: \(src)." }
        return s
    }
}
