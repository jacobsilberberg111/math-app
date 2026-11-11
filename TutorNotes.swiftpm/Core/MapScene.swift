import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Measures a single line of text: (text, font size, bold) → size. The renderer passes UIKit's
/// measurement; tests use an estimate.
typealias MapTextMeasure = (String, CGFloat, Bool) -> CGSize

/// A piece of text placed on the map element (coordinates relative to the element's top-left).
struct MapSceneText: Equatable {
    var text: String
    var rect: CGRect
    var size: CGFloat
    var bold: Bool = false
    var italic: Bool = false
    var colorHex: String = "#1F2328"
    /// Draw a white halo behind the text so it reads over the map.
    var halo: Bool = false
}

struct MapLegendEntry: Equatable {
    /// `heading` is text only and starts a new legend row.
    enum Kind: Equatable { case fill, hatch, outline, line, dot, heading }
    var kind: Kind
    var swatch: CGRect
    var colorHex: String
    var text: MapSceneText
}

struct MapScaleBar: Equatable {
    var origin: CGPoint
    /// Alternating black/white segments.
    var segments: [CGRect]
    var labels: [MapSceneText]
    var note: MapSceneText?
}

/// Where everything goes on a map element: title, map, legend, scale bar, north arrow, source.
/// Cheap (no geometry), so it's also used to describe the map to the tutor.
struct MapLayout: Equatable {
    var size: CGSize
    var title: MapSceneText?
    var subtitle: MapSceneText?
    var mapRect: CGRect
    var frame: MapFrame
    var legendTitle: MapSceneText?
    var legend: [MapLegendEntry]
    var scaleBar: MapScaleBar?
    var northArrow: CGRect
    var caption: MapSceneText?

    static let pad: CGFloat = 10
    static let titleSize: CGFloat = 16
    static let legendSize: CGFloat = 10.5
    static let captionSize: CGFloat = 9.5
    static let footerHeight: CGFloat = 32

    /// Legend entries: (kind, colour, text).
    static func legendItems(_ m: MapContent, koppenClasses: [Int]) -> (title: String?, items: [(MapLegendEntry.Kind, String, String)]) {
        var items: [(MapLegendEntry.Kind, String, String)] = []
        var title: String?
        switch m.style {
        case .data:
            if let c = m.choropleth {
                let labels = GeoBinning.labels(c.breaks)
                for (i, l) in labels.enumerated() { items.append((.fill, i < c.colors.count ? c.colors[i] : "#CCCCCC", l)) }
                items.append((.hatch, "#E3E5E8", "No data"))
                var t = c.indicator
                if let u = c.unit, !u.isEmpty { t += " (\(u))" }
                title = t + ", " + c.yearLabel
            }
        case .climate:
            if m.koppenGroupsOnly {
                let present = Set(koppenClasses.compactMap { Koppen.groupIndex($0) })
                for (i, g) in Koppen.groups.enumerated() where present.contains(i) || koppenClasses.isEmpty {
                    items.append((.fill, g.hex, "\(g.letter)  \(g.name)"))
                }
                title = "Köppen–Geiger climate groups, 1991–2020"
            } else if koppenClasses.count > 14 {
                // Many classes (world maps): one row per group, codes only.
                for g in Koppen.groups {
                    let ids = koppenClasses.filter { Koppen.cls($0)?.group == g.letter }
                    guard !ids.isEmpty else { continue }
                    items.append((.heading, g.hex, "\(g.letter) \(g.name.components(separatedBy: " (").first ?? g.name)"))
                    for id in ids { if let k = Koppen.cls(id) { items.append((.fill, k.hex, k.code)) } }
                }
                title = "Köppen–Geiger climate zones, 1991–2020"
            } else {
                for id in koppenClasses { if let k = Koppen.cls(id) { items.append((.fill, k.hex, "\(k.code)  \(k.name)")) } }
                title = "Köppen–Geiger climate zones, 1991–2020"
            }
        case .political, .outline:
            break
        }
        for h in m.highlights ?? [] {
            guard let l = h.label, !l.isEmpty else { continue }
            items.append((m.style == .data || m.style == .climate ? .outline : .fill, h.colorHex, l))
        }
        for r in m.routes ?? [] {
            guard let l = r.label, !l.isEmpty else { continue }
            if items.contains(where: { $0.2 == l }) { continue }
            items.append((.line, r.colorHex ?? MapStyleColors.route, l))
        }
        return (title, items)
    }

    static func compute(_ m: MapContent, size: CGSize, measure: MapTextMeasure, koppenClasses: [Int] = []) -> MapLayout {
        let w = size.width
        var y = pad
        var title: MapSceneText?
        var subtitle: MapSceneText?
        if let t = m.title, !t.isEmpty {
            let s = measure(t, titleSize, true)
            title = MapSceneText(text: t, rect: CGRect(x: pad + 2, y: y, width: min(s.width, w - 2 * pad), height: s.height), size: titleSize, bold: true)
            y += s.height + 2
        }
        if let st = m.subtitle, !st.isEmpty {
            let s = measure(st, 11, false)
            subtitle = MapSceneText(text: st, rect: CGRect(x: pad + 2, y: y, width: min(s.width, w - 2 * pad), height: s.height), size: 11, colorHex: "#57606A")
            y += s.height + 2
        }
        if title != nil || subtitle != nil { y += 4 }

        // Legend: entries flow left to right in rows.
        let (legendTitleText, items) = legendItems(m, koppenClasses: koppenClasses)
        var legend: [MapLegendEntry] = []
        var legendTitle: MapSceneText?
        var legendHeight: CGFloat = 0
        if !items.isEmpty || legendTitleText != nil {
            var ly: CGFloat = 0
            if let lt = legendTitleText {
                let s = measure(lt, legendSize, true)
                legendTitle = MapSceneText(text: lt, rect: CGRect(x: pad + 2, y: 0, width: min(s.width, w - 2 * pad), height: s.height), size: legendSize, bold: true)
                ly += s.height + 3
            }
            let rowH: CGFloat = 15
            let sw: CGFloat = m.style == .data ? 22 : 13
            var x = pad + 2
            var rowStartY = ly
            let colGap: CGFloat = 12
            // Climate legends line up in columns; data legends sit side by side.
            let hasHeadings = items.contains { $0.0 == .heading }
            let fixedCol: CGFloat? = items.count > 6 && !hasHeadings ? max(130, items.map { measure($0.2, legendSize - 0.5, false).width + sw + 6 }.max() ?? 130) : nil
            let headingW = hasHeadings ? (items.filter { $0.0 == .heading }.map { measure($0.2, legendSize - 0.5, true).width }.max() ?? 60) + 10 : 0
            for (kind, hex, text) in items {
                if kind == .heading {
                    if x > pad + 2 { rowStartY += rowH }
                    let ts = measure(text, legendSize - 0.5, true)
                    legend.append(MapLegendEntry(kind: .heading, swatch: .zero, colorHex: hex,
                                                 text: MapSceneText(text: text, rect: CGRect(x: pad + 2, y: rowStartY + 7.5 - ts.height / 2, width: ts.width, height: ts.height),
                                                                    size: legendSize - 0.5, bold: true, colorHex: "#30363D")))
                    x = pad + 2 + headingW
                    continue
                }
                let ts = measure(text, legendSize - 0.5, false)
                let entryW = fixedCol ?? (sw + 5 + ts.width)
                if x + entryW > w - pad && x > pad + 2 {
                    x = pad + 2 + headingW
                    rowStartY += rowH
                }
                let swatch = kind == .line ? CGRect(x: x, y: rowStartY + 6, width: sw, height: 3)
                    : CGRect(x: x, y: rowStartY + 2.5, width: sw, height: 10)
                legend.append(MapLegendEntry(kind: kind, swatch: swatch, colorHex: hex,
                                             text: MapSceneText(text: text, rect: CGRect(x: x + sw + 5, y: rowStartY + 7.5 - ts.height / 2, width: ts.width, height: ts.height),
                                                                size: legendSize - 0.5, colorHex: "#30363D")))
                x += entryW + colGap
            }
            legendHeight = items.isEmpty ? ly : rowStartY + rowH
        }

        let footerTop = size.height - pad - footerHeight
        let legendTop = footerTop - legendHeight - (legendHeight > 0 ? 4 : 0)
        let mapRect = CGRect(x: pad, y: y, width: w - 2 * pad, height: max(40, legendTop - y - 6))
        if let lt = legendTitle { legendTitle = MapSceneText(text: lt.text, rect: lt.rect.offsetBy(dx: 0, dy: legendTop), size: lt.size, bold: true) }
        legend = legend.map { e in
            var c = e
            c.swatch = e.swatch.offsetBy(dx: 0, dy: legendTop)
            c.text.rect = e.text.rect.offsetBy(dx: 0, dy: legendTop)
            return c
        }

        let frame = MapFrame.fit(kind: m.projectionKind, view: m.bbox, centralLon: m.centralLon ?? 0, in: mapRect)

        // Footer: scale bar, north arrow, source.
        let lat = frame.scaleLatitude
        let kmPerPt = frame.kmPerPoint(lat: lat)
        let bar = GeoNice.scaleBar(kmPerPoint: kmPerPt, maxPoints: Double(min(130, w * 0.24)))
        var scale: MapScaleBar?
        if bar.km > 0 && bar.points >= 20 {
            let segs = bar.points >= 60 ? 4 : 2
            let segW = CGFloat(bar.points) / CGFloat(segs)
            let origin = CGPoint(x: pad + 4, y: footerTop + 8)
            var rects: [CGRect] = []
            for i in 0..<segs { rects.append(CGRect(x: origin.x + CGFloat(i) * segW, y: origin.y, width: segW, height: 4)) }
            var labels: [MapSceneText] = []
            for (i, v) in [(0, 0.0), (segs / 2, bar.km / 2), (segs, bar.km)] where i == 0 || i == segs || segs == 4 {
                let t = i == segs ? GeoNice.kmLabel(v) : GeoFormat.short(v)
                let s = measure(t, 8.5, false)
                labels.append(MapSceneText(text: t, rect: CGRect(x: origin.x + CGFloat(i) * segW - (i == 0 ? 0 : s.width / 2), y: origin.y + 6, width: s.width, height: s.height), size: 8.5, colorHex: "#30363D"))
            }
            var note: MapSceneText?
            if frame.isWorld {
                let t = "Scale at the Equator"
                let s = measure(t, 7.5, false)
                note = MapSceneText(text: t, rect: CGRect(x: origin.x, y: origin.y - s.height - 1, width: s.width, height: s.height), size: 7.5, colorHex: "#6B7280")
            } else if abs(lat) > 15 {
                let t = "Scale at \(GeoNice.latLabel((lat * 10).rounded() / 10))"
                let s = measure(t, 7.5, false)
                note = MapSceneText(text: t, rect: CGRect(x: origin.x, y: origin.y - s.height - 1, width: s.width, height: s.height), size: 7.5, colorHex: "#6B7280")
            }
            scale = MapScaleBar(origin: origin, segments: rects, labels: labels, note: note)
        }
        let scaleRight = (scale?.labels.map(\.rect.maxX).max() ?? pad) + 14
        let north = CGRect(x: scaleRight, y: footerTop + 1, width: 18, height: footerHeight - 4)
        var caption: MapSceneText?
        if let src = m.source, !src.isEmpty {
            let left = north.maxX + 14
            let avail = w - pad - left
            var s = measure(src, captionSize, false)
            var text = src
            if s.width > avail {
                // Two lines at most: break at the last space that fits.
                let words = src.split(separator: " ")
                var line1 = ""
                for word in words {
                    let candidate = line1.isEmpty ? String(word) : line1 + " " + word
                    if measure(candidate, captionSize, false).width > avail { break }
                    line1 = candidate
                }
                let rest = String(src.dropFirst(line1.count)).trimmingCharacters(in: .whitespaces)
                text = line1 + (rest.isEmpty ? "" : "\n" + rest)
                let s2 = measure(rest, captionSize, false)
                s = CGSize(width: min(avail, max(measure(line1, captionSize, false).width, s2.width)), height: s.height * 2)
            }
            caption = MapSceneText(text: text, rect: CGRect(x: w - pad - min(s.width, avail), y: footerTop + (footerHeight - s.height) / 2, width: min(s.width, avail), height: s.height),
                                   size: captionSize, italic: true, colorHex: "#57606A")
        }
        return MapLayout(size: size, title: title, subtitle: subtitle, mapRect: mapRect, frame: frame, legendTitle: legendTitle,
                         legend: legend, scaleBar: scale, northArrow: north, caption: caption)
    }

    /// Height of everything except the map itself, for sizing a new map element.
    static func chromeHeight(_ m: MapContent, width: CGFloat, measure: MapTextMeasure, koppenClasses: [Int] = []) -> CGFloat {
        let probe = compute(m, size: CGSize(width: width, height: 2000), measure: measure, koppenClasses: koppenClasses)
        return 2000 - probe.mapRect.height
    }

    /// A good map-area height for the region at this width.
    static func naturalMapHeight(_ m: MapContent, width: CGFloat) -> CGFloat {
        let w = Double(width - 2 * pad)
        if m.bbox == nil {
            let p = GeoProjection(kind: m.projectionKind, centralLon: 0)
            return CGFloat(w * p.y(lat: 90) / (p.xFactor(lat: 0) * .pi))
        }
        let b = m.bbox!
        let k = cos(max(-75, min(75, b.centerLat)) * .pi / 180)
        let h = w * b.height / max(1e-6, b.width * k)
        return CGFloat(min(max(h, w * 0.45), w * 1.25))
    }
}

enum MapStyleColors {
    static let sea = "#D9ECF7"
    static let seaOutline = "#EEF6FB"
    static let coast = "#4A5A6A"
    static let border = "#7D8B99"
    static let stateBorder = "#8E9AA6"
    static let lake = "#D9ECF7"
    static let river = "#4F8FD0"
    static let land = "#FFFFFF"
    static let climateLand = "#EDEDED"
    static let noData = "#E3E5E8"
    static let graticule = "#9FB3C8"
    static let route = "#C2255C"
    static let marker = "#E03131"
    static let ocean = "#4A7BA7"
    /// Soft fills for political maps (Natural Earth MAPCOLOR7 1…7).
    static let political = ["#F6E7B4", "#D7EAC8", "#F4CFC6", "#D5D9F2", "#F8DDB0", "#CDE7E4", "#E9D3EC"]
}

struct MapSceneMarker: Equatable {
    var center: CGPoint
    var symbol: String
    var colorHex: String
    var label: MapSceneText?
    var lon: Double
    var lat: Double
    var name: String?
}

struct MapSceneRoute: Equatable {
    /// Per segment: start, control point (quadratic curve), end.
    var segments: [(CGPoint, CGPoint, CGPoint)]
    var colorHex: String
    var dashed: Bool
    var arrow: Bool
    var width: CGFloat
    var label: MapSceneText?

    static func == (a: MapSceneRoute, b: MapSceneRoute) -> Bool {
        a.colorHex == b.colorHex && a.dashed == b.dashed && a.arrow == b.arrow && a.width == b.width && a.label == b.label
            && a.segments.count == b.segments.count
            && zip(a.segments, b.segments).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2 }
    }
}

/// Labels for oceans and seas (placement only).
enum MapWaterLabels {
    static let all: [(name: String, lon: Double, lat: Double, ocean: Bool)] = [
        ("Pacific Ocean", -135, 2, true), ("Pacific Ocean", 165, 22, true), ("Atlantic Ocean", -28, 8, true),
        ("Indian Ocean", 78, -18, true), ("Southern Ocean", 100, -58, true), ("Arctic Ocean", 0, 84, true),
        ("Indian Ocean", 104, -26, true), ("Pacific Ocean", 172, -28, true),
        ("Tasman Sea", 160, -38, false), ("Coral Sea", 155, -16, false), ("Timor Sea", 126, -11.8, false),
        ("Arafura Sea", 135.5, -9.3, false), ("Great Australian Bight", 131, -35.8, false), ("Gulf of Carpentaria", 139.5, -14.2, false),
        ("Mediterranean Sea", 18, 34.6, false), ("Caribbean Sea", -75, 15, false), ("Gulf of Mexico", -90, 25, false),
        ("Arabian Sea", 65, 15, false), ("Bay of Bengal", 88, 15, false), ("South China Sea", 114, 12, false),
        ("Philippine Sea", 132, 18, false), ("Sea of Japan", 135, 40, false), ("North Sea", 3, 56, false),
        ("Baltic Sea", 19, 57.5, false), ("Black Sea", 34, 43.3, false), ("Red Sea", 38, 20, false), ("Caspian Sea", 51, 42, false),
        ("Bering Sea", -178, 58, false), ("Gulf of Guinea", 2, 1.5, false), ("Hudson Bay", -85, 60, false),
        ("Persian Gulf", 51.5, 27, false), ("Java Sea", 111, -5, false), ("Banda Sea", 127, -5.5, false),
        ("Solomon Sea", 153, -8, false), ("East China Sea", 126, 29, false), ("Bass Strait", 145.5, -39.6, false),
    ]
}

/// Everything a map draws, projected into element coordinates. Built once per content and size.
final class MapScene {
    struct CountryShape {
        let code: String
        let name: String
        var rings: [[CGPoint]]
        var bounds: CGRect
        var fillHex: String?
    }

    let layout: MapLayout
    var countries: [CountryShape] = []
    var noDataCodes: [String] = []
    var coast: [[CGPoint]] = []
    var borders: [[CGPoint]] = []
    var stateBorders: [[CGPoint]] = []
    /// State id → rings (for highlights).
    var stateRings: [String: [[CGPoint]]] = [:]
    var lakes: [(rings: [[CGPoint]], salt: Bool)] = []
    var rivers: [(rank: Int, lines: [[CGPoint]])] = []
    var graticule: [[CGPoint]] = []
    var specialLines: [(lines: [[CGPoint]], colorHex: String, dashed: Bool)] = []
    /// World maps: the outline of the globe.
    var sphere: [CGPoint]?
    /// Köppen fills: colour → quads.
    var koppen: [(colorHex: String, quads: [[CGPoint]])] = []
    var koppenClasses: [Int] = []
    /// Highlights drawn as fills or outlines: colour → rings.
    var highlightFills: [(colorHex: String, rings: [[CGPoint]])] = []
    var highlightOutlines: [(colorHex: String, rings: [[CGPoint]])] = []
    /// Highlighted places too small to see: a ring around them.
    var highlightDots: [(center: CGPoint, colorHex: String)] = []
    var labels: [MapSceneText] = []
    var markers: [MapSceneMarker] = []
    var routes: [MapSceneRoute] = []

    init(layout: MapLayout) { self.layout = layout }

    /// Köppen classes inside the requested view (for the legend), most common first then by code.
    static func koppenClasses(_ m: MapContent, koppen: KoppenData, width: CGFloat) -> [Int] {
        let view = m.bbox ?? GeoBBox(west: -180, south: -90, east: 180, north: 90)
        let w = Double(max(100, width - 2 * MapLayout.pad))
        let ppd = m.bbox == nil ? w / 360 / 0.87 : w / max(1, view.width * cos(max(-75, min(75, view.centerLat)) * .pi / 180))
        guard let g = koppen.grid(for: view, pointsPerDegree: ppd) ?? koppen.grids.first else { return [] }
        var counts = [Int](repeating: 0, count: 31)
        let c0 = Int(floor((view.west - g.west) / g.res)), c1 = Int(ceil((view.east - g.west) / g.res))
        let r0 = max(0, Int(floor((g.north - view.north) / g.res))), r1 = min(g.rows, Int(ceil((g.north - view.south) / g.res)))
        guard r1 > r0 else { return [] }
        for r in r0..<r1 {
            for cc in c0..<max(c0 + 1, c1) {
                var c = cc
                if g.isGlobal { c = ((c % g.cols) + g.cols) % g.cols } else if c < 0 || c >= g.cols { continue }
                let v = Int(g.cells[r * g.cols + c])
                if v > 0 && v <= 30 { counts[v] += 1 }
            }
        }
        let total = counts.reduce(0, +)
        return (1...30).filter { counts[$0] > 0 && Double(counts[$0]) >= Double(total) * 0.0005 }
    }

    static func build(_ m: MapContent, size: CGSize, world: GeoWorld, koppen: KoppenData?, places: GeoPlaces?, measure: MapTextMeasure) -> MapScene {
        let classes = (m.style == .climate && koppen != nil) ? koppenClasses(m, koppen: koppen!, width: size.width) : []
        let layout = MapLayout.compute(m, size: size, measure: measure, koppenClasses: classes)
        let scene = MapScene(layout: layout)
        scene.koppenClasses = classes
        scene.populate(m, world: world, koppen: koppen, measure: measure)
        return scene
    }

    // MARK: Projection helpers

    private var frame: MapFrame { layout.frame }

    /// The relative-longitude window to keep (regional maps), with a margin beyond the frame.
    private var clipBox: GeoBBox? {
        guard !frame.isWorld else { return nil }
        let v = frame.view
        let c = frame.projection.centralLon
        let mx = max(1, v.width * 0.04), my = max(1, v.height * 0.04)
        return GeoBBox(west: v.west - c - mx, south: max(-90, v.south - my), east: v.east - c + mx, north: min(90, v.north + my))
    }

    private func projectRing(_ ring: [GeoPoint], tolerance: CGFloat) -> [[CGPoint]] {
        var out: [[CGPoint]] = []
        for piece in GeoClip.recenterRing(ring, centralLon: frame.projection.centralLon) {
            var p = piece
            if let box = clipBox { p = GeoClip.clipPolygon(p, to: box) }
            guard p.count >= 3 else { continue }
            let pts = GeoClip.thin(p.map { frame.project(relLon: $0.lon, lat: $0.lat) }, tolerance: tolerance, closed: true)
            if pts.count >= 3 { out.append(pts) }
        }
        return out
    }

    private func projectLine(_ line: [GeoPoint], tolerance: CGFloat) -> [[CGPoint]] {
        var out: [[CGPoint]] = []
        for piece in GeoClip.recenterLine(line, centralLon: frame.projection.centralLon) {
            let parts = clipBox.map { GeoClip.clipLine(piece, to: $0) } ?? [piece]
            for p in parts {
                let pts = GeoClip.thin(p.map { frame.project(relLon: $0.lon, lat: $0.lat) }, tolerance: tolerance, closed: false)
                if pts.count >= 2 { out.append(pts) }
            }
        }
        return out
    }

    private static func bounds(_ rings: [[CGPoint]]) -> CGRect {
        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for r in rings { for p in r { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) } }
        return minX.isFinite ? CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY) : .null
    }

    /// Point for an absolute lon/lat if it's on the visible map.
    func point(lon: Double, lat: Double) -> CGPoint? {
        let p = frame.project(lon: lon, lat: lat)
        guard layout.mapRect.insetBy(dx: -1, dy: -1).contains(p) else { return nil }
        if frame.isWorld, let s = sphere, !MapScene.inside(p, s) { return nil }
        return p
    }

    /// Smallest river (largest Natural Earth rank) worth drawing at this scale.
    static func riverRankLimit(pointsPerDegree ppd: Double) -> Int {
        switch ppd {
        case ..<3: return 2
        case ..<7: return 4
        case ..<14: return 5
        case ..<25: return 6
        case ..<45: return 7
        default: return 8
        }
    }

    /// Splits a coastline arc where it runs along a cut in the data rather than a real coast: the
    /// ±180° meridian (Russia, Fiji, Antarctica are split there) and the South Pole line.
    static func realCoast(_ arc: [GeoPoint]) -> [[GeoPoint]] {
        func artificial(_ a: GeoPoint, _ b: GeoPoint) -> Bool {
            (a.lat < -89.9 && b.lat < -89.9) || (abs(a.lon) > 179.99 && abs(b.lon) > 179.99 && a.lon * b.lon > 0)
        }
        var out: [[GeoPoint]] = []
        var run: [GeoPoint] = []
        for i in 0..<arc.count {
            if i > 0 && artificial(arc[i - 1], arc[i]) {
                if run.count >= 2 { out.append(run) }
                run = [arc[i]]
            } else {
                run.append(arc[i])
            }
        }
        if run.count >= 2 { out.append(run) }
        return out
    }

    static func inside(_ p: CGPoint, _ poly: [CGPoint]) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y) {
                let x = a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x)
                if p.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    // MARK: Build

    private func populate(_ m: MapContent, world: GeoWorld, koppen: KoppenData?, measure: MapTextMeasure) {
        let tol: CGFloat = 0.45
        let mapRect = layout.mapRect
        let ppd = frame.pointsPerDegree

        if frame.isWorld {
            // The globe's outline: the ±180 meridians and the pole lines.
            var s: [CGPoint] = []
            for lat in stride(from: -90.0, through: 90.0, by: 2) { s.append(frame.project(relLon: 180, lat: lat)) }
            for lat in stride(from: 90.0, through: -90.0, by: -2) { s.append(frame.project(relLon: -180, lat: lat)) }
            sphere = s
        }

        // Highlights by code.
        var highlightOf: [String: String] = [:]
        for h in m.highlights ?? [] { for c in h.codes { highlightOf[c] = h.colorHex } }
        let fillHighlights = m.style == .political || m.style == .outline

        // Countries.
        for c in world.countries {
            var rings: [[CGPoint]] = []
            for r in c.rings { rings.append(contentsOf: projectRing(r, tolerance: tol)) }
            guard !rings.isEmpty else { continue }
            let b = MapScene.bounds(rings)
            guard b.intersects(mapRect.insetBy(dx: -2, dy: -2)) else { continue }
            var fill: String?
            switch m.style {
            case .political: fill = MapStyleColors.political[max(0, min(6, c.mapColor - 1))]
            case .outline: fill = MapStyleColors.land
            case .climate: fill = MapStyleColors.climateLand
            case .data:
                if let ch = m.choropleth, let col = ch.color(for: c.code) { fill = col } else {
                    fill = MapStyleColors.noData
                    if c.code != "ATA" { noDataCodes.append(c.code) }
                }
            }
            if fillHighlights, let h = highlightOf[c.code] { fill = h }
            countries.append(CountryShape(code: c.code, name: c.name, rings: rings, bounds: b, fillHex: fill))
        }

        // Coastlines and borders.
        for a in world.coastArcs {
            for run in MapScene.realCoast(world.arcs[a]) { coast.append(contentsOf: projectLine(run, tolerance: tol)) }
        }
        for a in world.borderArcs { borders.append(contentsOf: projectLine(world.arcs[a], tolerance: tol)) }

        // Australian states.
        let showStates = m.showStates
        let needStateRings = (m.highlights ?? []).contains { $0.codes.contains { $0.hasPrefix("AU-") } }
        if showStates {
            for a in world.stateBorderArcs { stateBorders.append(contentsOf: projectLine(world.arcs[a], tolerance: tol)) }
        }
        if showStates || needStateRings {
            for s in world.states {
                var rings: [[CGPoint]] = []
                for r in s.rings { rings.append(contentsOf: projectRing(r, tolerance: tol)) }
                if !rings.isEmpty { stateRings[s.id] = rings }
            }
        }

        // Highlights.
        var fills: [String: [[CGPoint]]] = [:], outlines: [String: [[CGPoint]]] = [:]
        var order: [String] = []
        for h in m.highlights ?? [] {
            for code in h.codes {
                let rings: [[CGPoint]]
                if code.hasPrefix("AU-") { rings = stateRings[code] ?? [] } else { rings = countries.first { $0.code == code }?.rings ?? [] }
                guard !rings.isEmpty else { continue }
                if !order.contains(h.colorHex) { order.append(h.colorHex) }
                if fillHighlights { fills[h.colorHex, default: []] += rings } else { outlines[h.colorHex, default: []] += rings }
                let b = MapScene.bounds(rings)
                if b.width < 5 && b.height < 5 {
                    var center = CGPoint(x: b.midX, y: b.midY)
                    if let c = world.country(code: code), let p = point(lon: c.label.lon, lat: c.label.lat) { center = p }
                    highlightDots.append((center, h.colorHex))
                }
            }
        }
        highlightFills = order.compactMap { k in fills[k].map { (k, $0) } }
        highlightOutlines = order.compactMap { k in outlines[k].map { (k, $0) } }

        // Lakes (big enough to see) and rivers.
        for l in world.lakes {
            var rings: [[CGPoint]] = []
            for r in l.rings { rings.append(contentsOf: projectRing(r, tolerance: tol)) }
            guard !rings.isEmpty else { continue }
            let b = MapScene.bounds(rings)
            if b.width < 2.2 && b.height < 2.2 { continue }
            guard b.intersects(mapRect) else { continue }
            lakes.append((rings, l.salt))
        }
        if m.showRivers {
            let maxRank = MapScene.riverRankLimit(pointsPerDegree: ppd)
            for r in world.rivers where r.rank <= maxRank {
                var lines: [[CGPoint]] = []
                for l in r.lines { lines.append(contentsOf: projectLine(l, tolerance: tol)) }
                if !lines.isEmpty { rivers.append((r.rank, lines)) }
            }
        }

        // Graticule and special latitudes.
        var taken: [CGRect] = []
        if m.showLatitudeLines { buildLatitudeLines(measure: measure, taken: &taken) }
        if m.showGraticule { buildGraticule(measure: measure, taken: &taken) }

        // Köppen-Geiger.
        if m.style == .climate, let k = koppen { buildKoppen(m, koppen: k) }

        // Labels, markers, routes.
        buildMarkers(m, world: world, measure: measure, taken: &taken)
        buildRoutes(m, measure: measure, taken: &taken)
        if m.showLabels {
            buildCountryLabels(m, world: world, measure: measure, taken: &taken, highlightOf: highlightOf)
        } else if !(m.highlights ?? []).isEmpty && m.labels != false {
            buildCountryLabels(m, world: world, measure: measure, taken: &taken, highlightOf: highlightOf, onlyHighlighted: true)
        }
        if m.showOceanLabels {
            buildWaterLabels(measure: measure, taken: &taken)
        }
        if m.showRivers && m.showLabels { buildRiverLabels(world: world, measure: measure, taken: &taken) }
    }

    private func buildGraticule(measure: MapTextMeasure, taken: inout [CGRect]) {
        let step: Double
        let v = frame.view
        if frame.isWorld { step = 30 } else { step = GeoNice.graticuleStep(span: max(v.width, v.height)) }
        let c = frame.projection.centralLon
        // Meridians.
        var lon = (floor((v.west) / step)) * step
        while lon <= v.east + 1e-9 {
            let rel = lon - c
            if frame.isWorld && (rel <= -180 || rel >= 180) { lon += step; continue }
            var line: [GeoPoint] = []
            for lat in stride(from: max(-90, v.south), through: min(90, v.north), by: frame.isWorld ? 2 : max(0.25, v.height / 60)) {
                line.append(GeoPoint(lon: rel, lat: lat))
            }
            let parts = clipBox.map { GeoClip.clipLine(line, to: $0) } ?? [line]
            for p in parts { graticule.append(p.map { frame.project(relLon: $0.lon, lat: $0.lat) }) }
            if !frame.isWorld {
                let pt = frame.project(relLon: rel, lat: v.south)
                if pt.x > layout.mapRect.minX + 18 && pt.x < layout.mapRect.maxX - 18 {
                    let t = GeoNice.lonLabel(lon)
                    let s = measure(t, 8, false)
                    addFixed(MapSceneText(text: t, rect: CGRect(x: pt.x - s.width / 2, y: layout.mapRect.maxY - s.height - 2, width: s.width, height: s.height),
                                          size: 8, colorHex: "#486581", halo: true), taken: &taken)
                }
            } else if abs(rel) < 179 {
                let pt = frame.project(relLon: rel, lat: 0)
                let t = GeoNice.lonLabel(lon)
                let s = measure(t, 7.5, false)
                addFixed(MapSceneText(text: t, rect: CGRect(x: pt.x + 2, y: pt.y + 1, width: s.width, height: s.height), size: 7.5, colorHex: "#486581", halo: true), taken: &taken)
            }
            lon += step
        }
        // Parallels.
        var lat = ceil(max(-90, v.south) / step) * step
        while lat <= min(90, v.north) + 1e-9 {
            if abs(lat) < 90 {
                var line: [GeoPoint] = []
                let w = frame.isWorld ? -180 : v.west - c, e = frame.isWorld ? 180 : v.east - c
                for x in stride(from: w, through: e, by: max(0.5, (e - w) / 90)) { line.append(GeoPoint(lon: x, lat: lat)) }
                let parts = clipBox.map { GeoClip.clipLine(line, to: $0) } ?? [line]
                for p in parts { graticule.append(p.map { frame.project(relLon: $0.lon, lat: $0.lat) }) }
                let pt = frame.project(relLon: frame.isWorld ? -180 : v.west - c, lat: lat)
                if pt.y > layout.mapRect.minY + 10 && pt.y < layout.mapRect.maxY - 18 && (frame.isWorld ? lat != 0 : true) {
                    let t = GeoNice.latLabel(lat)
                    let s = measure(t, frame.isWorld ? 7.5 : 8, false)
                    let x = frame.isWorld ? pt.x - s.width - 2 : layout.mapRect.minX + 3
                    addFixed(MapSceneText(text: t, rect: CGRect(x: max(layout.mapRect.minX, x), y: pt.y - s.height / 2, width: s.width, height: s.height),
                                          size: frame.isWorld ? 7.5 : 8, colorHex: "#486581", halo: true), taken: &taken)
                }
            }
            lat += step
        }
    }

    private func buildLatitudeLines(measure: MapTextMeasure, taken: inout [CGRect]) {
        let lines: [(String, Double, String, Bool)] = [
            ("Equator", 0, "#C92A2A", false), ("Tropic of Cancer", 23.44, "#E8590C", true), ("Tropic of Capricorn", -23.44, "#E8590C", true),
            ("Arctic Circle", 66.56, "#1971C2", true), ("Antarctic Circle", -66.56, "#1971C2", true),
        ]
        let v = frame.view
        let c = frame.projection.centralLon
        for (name, lat, hex, dashed) in lines where lat >= v.south && lat <= v.north {
            let w = frame.isWorld ? -180 : v.west - c, e = frame.isWorld ? 180 : v.east - c
            var line: [GeoPoint] = []
            for x in stride(from: w, through: e, by: max(0.5, (e - w) / 60)) { line.append(GeoPoint(lon: x, lat: lat)) }
            let parts = clipBox.map { GeoClip.clipLine(line, to: $0) } ?? [line]
            let pts = parts.map { $0.map { frame.project(relLon: $0.lon, lat: $0.lat) } }
            specialLines.append((pts, hex, dashed))
            // Label at the western end (open ocean on world maps), else the eastern end.
            let left = frame.project(relLon: w, lat: lat), right = frame.project(relLon: e, lat: lat)
            let t = name + (lat == 0 ? "" : " \(GeoFormat.trim(abs(lat), 1))°\(lat > 0 ? "N" : "S")")
            let s = measure(t, 8, true)
            let inset: CGFloat = frame.isWorld ? 10 : 4
            let candidates = [CGPoint(x: max(left.x, layout.mapRect.minX) + inset, y: left.y - s.height - 1),
                              CGPoint(x: min(right.x, layout.mapRect.maxX) - s.width - inset, y: right.y - s.height - 1)]
            for c in candidates {
                let before = labels.count
                addFixed(MapSceneText(text: t, rect: CGRect(x: c.x, y: c.y, width: s.width, height: s.height), size: 8, bold: true, colorHex: hex, halo: true), taken: &taken)
                if labels.count > before { break }
            }
        }
    }

    private func buildKoppen(_ m: MapContent, koppen: KoppenData) {
        let v = frame.view
        guard let g = koppen.grid(for: frame.isWorld ? GeoBBox(west: -180, south: -90, east: 180, north: 90) : v,
                                  pointsPerDegree: frame.pointsPerDegree) else { return }
        let c = frame.projection.centralLon
        let groups = m.koppenGroupsOnly
        var quads: [Int: [[CGPoint]]] = [:]
        let box = clipBox
        let r0 = frame.isWorld ? 0 : max(0, Int(floor((g.north - v.north) / g.res)) - 1)
        let r1 = frame.isWorld ? g.rows : min(g.rows, Int(ceil((g.north - v.south) / g.res)) + 1)
        guard r1 > r0 else { return }
        func emit(_ cls: Int, _ rel0: Double, _ rel1: Double, _ latTop: Double, _ latBot: Double) {
            var a = rel0, b = rel1
            if let box {
                a = max(a, box.west); b = min(b, box.east)
                guard b > a else { return }
            }
            let key = groups ? (Koppen.groupIndex(cls) ?? 0) : cls
            let q = [frame.project(relLon: a, lat: latTop), frame.project(relLon: b, lat: latTop),
                     frame.project(relLon: b, lat: latBot), frame.project(relLon: a, lat: latBot)]
            quads[key, default: []].append(q)
        }
        for r in r0..<r1 {
            let latTop = g.north - Double(r) * g.res, latBot = latTop - g.res
            var col = 0
            let rowStart = r * g.cols
            while col < g.cols {
                let v0 = g.cells[rowStart + col]
                var end = col + 1
                while end < g.cols && g.cells[rowStart + end] == v0 { end += 1 }
                if v0 != 0 {
                    let lon0 = g.west + Double(col) * g.res, lon1 = g.west + Double(end) * g.res
                    var rel0 = lon0 - c
                    if rel0 < -180 { rel0 += 360 } else if rel0 >= 180 { rel0 -= 360 }
                    let rel1 = rel0 + (lon1 - lon0)
                    if rel1 > 180 {
                        emit(Int(v0), rel0, 180, latTop, latBot)
                        emit(Int(v0), -180, rel1 - 360, latTop, latBot)
                    } else {
                        emit(Int(v0), rel0, rel1, latTop, latBot)
                    }
                }
                col = end
            }
        }
        self.koppen = quads.keys.sorted().map { key in
            let hex = groups ? Koppen.groups[max(0, min(4, key))].hex : (Koppen.cls(key)?.hex ?? "#CCCCCC")
            return (hex, quads[key]!)
        }
    }

    /// Adds a label at a fixed spot unless it would collide with one already placed.
    private func addFixed(_ t: MapSceneText, taken: inout [CGRect]) {
        let padded = t.rect.insetBy(dx: -2, dy: -1)
        guard !taken.contains(where: { $0.intersects(padded) }) else { return }
        taken.append(padded)
        labels.append(t)
    }

    private func place(_ text: String, at anchor: CGPoint, size: CGFloat, bold: Bool = false, italic: Bool = false,
                       colorHex: String, measure: MapTextMeasure, taken: inout [CGRect], offsets: [CGPoint]? = nil, halo: Bool = true) -> MapSceneText? {
        let s = measure(text, size, bold)
        let candidates = offsets ?? [CGPoint(x: -s.width / 2, y: -s.height / 2)]
        let inner = layout.mapRect.insetBy(dx: 2, dy: 2)
        for o in candidates {
            let r = CGRect(x: anchor.x + o.x, y: anchor.y + o.y, width: s.width, height: s.height)
            guard inner.contains(r) else { continue }
            let padded = r.insetBy(dx: -2, dy: -1)
            if taken.contains(where: { $0.intersects(padded) }) { continue }
            taken.append(padded)
            return MapSceneText(text: text, rect: r, size: size, bold: bold, italic: italic, colorHex: colorHex, halo: halo)
        }
        return nil
    }

    private func buildMarkers(_ m: MapContent, world: GeoWorld, measure: MapTextMeasure, taken: inout [CGRect]) {
        for mk in m.markers ?? [] {
            guard let p = point(lon: mk.lon, lat: mk.lat) else { continue }
            let hex = mk.colorHex ?? MapStyleColors.marker
            taken.append(CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
            markers.append(MapSceneMarker(center: p, symbol: mk.symbol ?? "dot", colorHex: hex, label: nil, lon: mk.lon, lat: mk.lat, name: mk.label))
        }
        for i in markers.indices {
            guard let text = markers[i].name, !text.isEmpty else { continue }
            let p = markers[i].center
            let s = measure(text, 10.5, true)
            let offsets = [CGPoint(x: 7, y: -s.height / 2), CGPoint(x: -7 - s.width, y: -s.height / 2),
                           CGPoint(x: -s.width / 2, y: -8 - s.height), CGPoint(x: -s.width / 2, y: 7),
                           CGPoint(x: 6, y: -s.height - 2), CGPoint(x: 6, y: 2), CGPoint(x: -6 - s.width, y: -s.height - 2), CGPoint(x: -6 - s.width, y: 2)]
            markers[i].label = place(text, at: p, size: 10.5, bold: true, colorHex: "#1F2328", measure: measure, taken: &taken, offsets: offsets)
                ?? MapSceneText(text: text, rect: CGRect(x: p.x + 7, y: p.y - s.height / 2, width: s.width, height: s.height), size: 10.5, bold: true, halo: true)
        }
    }

    private func buildRoutes(_ m: MapContent, measure: MapTextMeasure, taken: inout [CGRect]) {
        for r in m.routes ?? [] {
            let pts = r.points.map { frame.project(lon: $0.lon, lat: $0.lat) }
            guard pts.count >= 2 else { continue }
            var segs: [(CGPoint, CGPoint, CGPoint)] = []
            for i in 0..<(pts.count - 1) {
                let a = pts[i], b = pts[i + 1]
                let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                var ctl = mid
                if r.curved ?? true {
                    let dx = b.x - a.x, dy = b.y - a.y
                    let len = sqrt(dx * dx + dy * dy)
                    if len > 1 {
                        // Bulge to the left of travel (upwards for west-to-east routes).
                        let k: CGFloat = 0.18
                        ctl = CGPoint(x: mid.x + dy / len * len * k * (dx >= 0 ? 1 : -1), y: mid.y - dx / len * len * k * (dx >= 0 ? 1 : -1))
                    }
                }
                segs.append((a, ctl, b))
            }
            var label: MapSceneText?
            if let text = r.label, !text.isEmpty {
                let s = segs[segs.count / 2]
                // Midpoint of the quadratic curve.
                let mp = CGPoint(x: 0.25 * s.0.x + 0.5 * s.1.x + 0.25 * s.2.x, y: 0.25 * s.0.y + 0.5 * s.1.y + 0.25 * s.2.y)
                let sz = measure(text, 9.5, true)
                label = place(text, at: mp, size: 9.5, bold: true, colorHex: r.colorHex ?? MapStyleColors.route, measure: measure, taken: &taken,
                              offsets: [CGPoint(x: -sz.width / 2, y: -sz.height - 3), CGPoint(x: -sz.width / 2, y: 3), CGPoint(x: 4, y: -sz.height / 2), CGPoint(x: -4 - sz.width, y: -sz.height / 2)])
            }
            routes.append(MapSceneRoute(segments: segs, colorHex: r.colorHex ?? MapStyleColors.route, dashed: r.dashed ?? false,
                                        arrow: r.arrow ?? true, width: CGFloat(r.width ?? 2.2), label: label))
        }
    }

    private func buildCountryLabels(_ m: MapContent, world: GeoWorld, measure: MapTextMeasure, taken: inout [CGRect],
                                    highlightOf: [String: String], onlyHighlighted: Bool = false) {
        let shapes = Dictionary(countries.map { ($0.code, $0) }, uniquingKeysWith: { a, _ in a })
        // States first on maps that show them.
        if m.showStates {
            for s in world.states.sorted(by: { ($0.kind == "State" ? 0 : 1, $0.name) < ($1.kind == "State" ? 0 : 1, $1.name) }) {
                if onlyHighlighted && highlightOf[s.id] == nil { continue }
                guard let p = point(lon: s.label.lon, lat: s.label.lat), let rings = stateRings[s.id] else { continue }
                let b = MapScene.bounds(rings)
                let full = measure(s.name, 9.5, true)
                let text = full.width < b.width * 0.85 ? s.name : s.abbr
                if b.width < 6 && highlightOf[s.id] == nil { continue }
                if let t = place(text, at: p, size: 9.5, bold: true, colorHex: "#3D4A57", measure: measure, taken: &taken) { labels.append(t) }
            }
        }
        let ranked = world.countries.compactMap { c -> (GeoWorld.Country, CountryShape)? in
            guard let s = shapes[c.code] else { return nil }
            return (c, s)
        }.sorted { a, b in
            let ka = (highlightOf[a.0.code] != nil ? 0 : 1, a.0.minLabel, -Double(a.1.bounds.width * a.1.bounds.height))
            let kb = (highlightOf[b.0.code] != nil ? 0 : 1, b.0.minLabel, -Double(b.1.bounds.width * b.1.bounds.height))
            return ka < kb
        }
        for (c, shape) in ranked {
            let highlighted = highlightOf[c.code] != nil
            if onlyHighlighted && !highlighted { continue }
            if m.showStates && c.code == "AUS" && frame.view.width < 60 { continue }
            guard let p = point(lon: c.label.lon, lat: c.label.lat) else { continue }
            let big = shape.bounds.width > 90
            let size: CGFloat = big ? 10.5 : 9
            let text = c.name
            let s = measure(text, size, false)
            // Only label countries big enough to hold most of their name (or highlighted ones).
            if !highlighted && s.width > shape.bounds.width * 1.6 + 6 { continue }
            if !highlighted && shape.bounds.width < 7 && shape.bounds.height < 7 { continue }
            let offsets = highlighted ? [CGPoint(x: -s.width / 2, y: -s.height / 2), CGPoint(x: 5, y: -s.height / 2), CGPoint(x: -5 - s.width, y: -s.height / 2),
                                         CGPoint(x: -s.width / 2, y: 4), CGPoint(x: -s.width / 2, y: -s.height - 4)] : nil
            if let t = place(text, at: p, size: size, bold: highlighted, colorHex: "#2B3540", measure: measure, taken: &taken, offsets: offsets) {
                labels.append(t)
            }
        }
    }

    private func buildWaterLabels(measure: MapTextMeasure, taken: inout [CGRect]) {
        let regional = !frame.isWorld && frame.view.width < 90
        for w in MapWaterLabels.all where w.ocean || regional {
            guard let p = point(lon: w.lon, lat: w.lat) else { continue }
            // Skip labels that would sit on land.
            if countries.contains(where: { $0.bounds.contains(p) && $0.rings.contains { MapScene.inside(p, $0) } }) { continue }
            if let t = place(w.name, at: p, size: w.ocean ? 10 : 8.5, italic: true, colorHex: MapStyleColors.ocean, measure: measure, taken: &taken, halo: false) {
                labels.append(t)
            }
        }
    }

    private func buildRiverLabels(world: GeoWorld, measure: MapTextMeasure, taken: inout [CGRect]) {
        var seen = Set<String>()
        let labelRank = max(3, MapScene.riverRankLimit(pointsPerDegree: frame.pointsPerDegree) - 1)
        for r in world.rivers where r.rank <= labelRank && !seen.contains(r.name) {
            // The middle of the river's longest visible line.
            var best: [CGPoint] = []
            for l in r.lines {
                for part in projectLine(l, tolerance: 0.45) where part.count > best.count { best = part }
            }
            guard best.count >= 4 else { continue }
            var length: CGFloat = 0
            for i in 1..<best.count { length += hypot(best[i].x - best[i - 1].x, best[i].y - best[i - 1].y) }
            guard length >= 50 else { continue }
            let mid = best[best.count / 2]
            guard layout.mapRect.insetBy(dx: 10, dy: 10).contains(mid) else { continue }
            let s = measure(r.name, 8.5, false)
            if let t = place(r.name, at: mid, size: 8.5, italic: true, colorHex: "#2B6CB0", measure: measure, taken: &taken,
                             offsets: [CGPoint(x: 3, y: -s.height - 1), CGPoint(x: 3, y: 1), CGPoint(x: -s.width - 3, y: -s.height - 1)]) {
                labels.append(t)
                seen.insert(r.name)
            }
        }
    }
}

/// How lon/lat maps onto the page for a map element, in words the tutor can use.
enum MapDescriber {
    /// `origin` is the element's top-left on the page.
    static func conversion(_ layout: MapLayout, origin: CGPoint) -> String {
        let f = layout.frame
        let ox = Double(origin.x), oy = Double(origin.y)
        func fmt(_ v: Double) -> String { GeoFormat.trim(v, 2) }
        if !f.isWorld {
            let v = f.view
            let kx = f.pointsPerDegreeLon(lat: 0)
            let ky = f.scale * .pi / 180
            let x0 = Double(f.project(lon: v.west, lat: v.centerLat).x) + ox
            let y0 = Double(f.project(lon: v.west, lat: 0).y) + oy
            var s = "Visible area lon \(GeoNice.lonLabel(v.west))–\(GeoNice.lonLabel(v.east)), lat \(GeoNice.latLabel((v.south * 10).rounded() / 10))–\(GeoNice.latLabel((v.north * 10).rounded() / 10)). "
            s += "Page position of a place (equirectangular): x = \(fmt(x0)) + \(fmt(kx))·(lon − \(fmt(v.west))), y = \(fmt(y0)) − \(fmt(ky))·lat"
            s += " (east longitudes positive, south latitudes negative"
            if v.east > 180 { s += "; for longitudes west of 180° use lon + 360" }
            s += ")."
            return s
        }
        let c = f.projection.centralLon
        let cx = Double(f.project(relLon: 0, lat: 0).x) + ox
        var rows: [String] = []
        for lat in [75.0, 60, 45, 30, 15, 0, -15, -30, -45, -60] {
            let y = Double(f.project(relLon: 0, lat: lat).y) + oy
            rows.append("\(GeoNice.latLabel(lat)): y=\(Int(y.rounded())), k=\(fmt(f.pointsPerDegreeLon(lat: lat)))")
        }
        return "World map (\(f.projection.kind.displayName), central meridian \(GeoNice.lonLabel(c))). Page position of a place: x = \(fmt(cx)) + k·(lon − \(fmt(c))) with lon − \(fmt(c)) wrapped into −180…180, and y and k by latitude (interpolate between rows): " + rows.joined(separator: "; ") + "."
    }
}
