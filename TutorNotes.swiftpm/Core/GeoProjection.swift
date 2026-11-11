import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

enum MapProjectionKind: String, Codable, CaseIterable {
    /// Natural Earth I (Šavrič et al. 2011): a compromise world projection.
    case naturalEarth = "natural_earth"
    /// Robinson (1963), the classic atlas world map.
    case robinson
    /// Plate carrée scaled by cos(standard latitude): used for regional maps.
    case equirectangular

    var displayName: String {
        switch self {
        case .naturalEarth: return "Natural Earth"
        case .robinson: return "Robinson"
        case .equirectangular: return "Equirectangular"
        }
    }

    /// Pseudocylindrical: parallels are straight horizontal lines.
    var isWorld: Bool { self != .equirectangular }
}

/// Raw projection maths. Longitudes passed in are relative to the central meridian (−180…180)
/// and results are in "unit" coordinates with y up.
struct GeoProjection: Equatable {
    var kind: MapProjectionKind
    var centralLon: Double
    var standardLat: Double = 0

    static let robinsonTable: [(x: Double, y: Double)] = [
        (1.0000, 0.0000), (0.9986, 0.0620), (0.9954, 0.1240), (0.9900, 0.1860), (0.9822, 0.2480),
        (0.9730, 0.3100), (0.9600, 0.3720), (0.9427, 0.4340), (0.9216, 0.4958), (0.8962, 0.5571),
        (0.8679, 0.6176), (0.8350, 0.6769), (0.7986, 0.7346), (0.7597, 0.7903), (0.7186, 0.8435),
        (0.6732, 0.8936), (0.6213, 0.9394), (0.5722, 0.9761), (0.5322, 1.0000),
    ]

    /// Wraps an absolute longitude to −180…180 around the central meridian.
    func relative(_ lon: Double) -> Double {
        var d = (lon - centralLon).truncatingRemainder(dividingBy: 360)
        if d < -180 { d += 360 }
        if d >= 180 { d -= 360 }
        return d
    }

    /// x scale factor at a latitude (x = factor · λ in radians).
    func xFactor(lat: Double) -> Double {
        let phi = lat * .pi / 180
        switch kind {
        case .naturalEarth:
            let p2 = phi * phi, p4 = p2 * p2
            return 0.8707 - 0.131979 * p2 + p4 * (-0.013791 + p4 * (0.003971 * p2 - 0.001529 * p4))
        case .robinson:
            return 0.8487 * GeoProjection.robinsonInterp(abs(lat)).x
        case .equirectangular:
            return cos(standardLat * .pi / 180)
        }
    }

    func y(lat: Double) -> Double {
        let phi = max(-90, min(90, lat)) * .pi / 180
        switch kind {
        case .naturalEarth:
            let p2 = phi * phi, p4 = p2 * p2
            return phi * (1.007226 + p2 * (0.015085 + p4 * (-0.044475 + 0.028874 * p2 - 0.005916 * p4)))
        case .robinson:
            let v = 1.3523 * GeoProjection.robinsonInterp(abs(lat)).y
            return lat < 0 ? -v : v
        case .equirectangular:
            return phi
        }
    }

    func forward(relLon: Double, lat: Double) -> (x: Double, y: Double) {
        (xFactor(lat: lat) * relLon * .pi / 180, y(lat: lat))
    }

    /// Latitude for a projected y, or nil beyond the poles.
    func lat(y: Double) -> Double? {
        let yMax = self.y(lat: 90)
        guard abs(y) <= yMax + 1e-9 else { return nil }
        switch kind {
        case .equirectangular:
            return y * 180 / .pi
        case .naturalEarth, .robinson:
            // Bisection on the monotonic y(lat).
            var lo = -90.0, hi = 90.0
            for _ in 0..<60 {
                let mid = (lo + hi) / 2
                if self.y(lat: mid) < y { lo = mid } else { hi = mid }
            }
            return (lo + hi) / 2
        }
    }

    func inverse(x: Double, y: Double) -> (relLon: Double, lat: Double)? {
        guard let lat = lat(y: y) else { return nil }
        let f = xFactor(lat: lat)
        guard f > 1e-9 else { return nil }
        let rel = x / f * 180 / .pi
        guard abs(rel) <= 180 + 1e-6 else { return nil }
        return (rel, lat)
    }

    static func robinsonInterp(_ absLat: Double) -> (x: Double, y: Double) {
        let t = max(0, min(90, absLat)) / 5
        let i = min(17, Int(t))
        let f = t - Double(i)
        let a = robinsonTable[i], b = robinsonTable[i + 1]
        return (a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f)
    }
}

/// A projection fitted into a rectangle on the page: converts lon/lat to points and back.
struct MapFrame: Equatable {
    let projection: GeoProjection
    /// Where the map is drawn (element coordinates).
    let mapRect: CGRect
    /// Points per projected unit.
    let scale: Double
    /// Screen position of projected (0, 0).
    let originX: Double
    let originY: Double
    /// World maps show the whole globe; regional maps a lon/lat window.
    let isWorld: Bool
    /// The lon/lat window that is visible (regional maps; world maps cover everything).
    let view: GeoBBox

    func project(relLon: Double, lat: Double) -> CGPoint {
        let p = projection.forward(relLon: relLon, lat: lat)
        return CGPoint(x: originX + scale * p.x, y: originY - scale * p.y)
    }

    /// Absolute longitude: on a regional map it is taken in the view's frame (so 190 and −170 agree).
    func project(lon: Double, lat: Double) -> CGPoint {
        if isWorld { return project(relLon: projection.relative(lon), lat: lat) }
        let l = view.nearestLon(lon)
        return project(relLon: l - projection.centralLon, lat: lat)
    }

    func project(_ p: GeoPoint) -> CGPoint { project(lon: p.lon, lat: p.lat) }

    func geo(at p: CGPoint) -> GeoPoint? {
        guard let r = projection.inverse(x: (Double(p.x) - originX) / scale, y: (originY - Double(p.y)) / scale) else { return nil }
        var lon = r.relLon + projection.centralLon
        if lon > 180 { lon -= 360 }
        if lon < -180 { lon += 360 }
        return GeoPoint(lon: lon, lat: r.lat)
    }

    /// Points per degree of longitude at a latitude (pseudocylindrical maps vary with latitude).
    func pointsPerDegreeLon(lat: Double) -> Double { scale * projection.xFactor(lat: lat) * .pi / 180 }

    /// Points per degree, roughly (for choosing detail).
    var pointsPerDegree: Double { scale * .pi / 180 }

    /// Kilometres per point along a parallel at `lat`.
    func kmPerPoint(lat: Double) -> Double {
        let kmPerDeg = 111.32 * cos(lat * .pi / 180)
        return kmPerDeg / max(1e-9, pointsPerDegreeLon(lat: lat))
    }

    /// The latitude the scale bar is true at: the standard parallel, or the equator on world maps.
    var scaleLatitude: Double { isWorld ? 0 : projection.standardLat }

    /// Fits a world map (whole globe) or a regional window into `rect`. A regional window grows to
    /// fill the rectangle (the requested area stays fully visible, centred).
    static func fit(kind: MapProjectionKind, view: GeoBBox?, centralLon: Double, in rect: CGRect) -> MapFrame {
        let w = Double(max(rect.width, 1)), h = Double(max(rect.height, 1))
        if view == nil {
            let proj = GeoProjection(kind: kind, centralLon: centralLon)
            let xMax = proj.xFactor(lat: 0) * .pi, yMax = proj.y(lat: 90)
            let s = min(w / (2 * xMax), h / (2 * yMax))
            return MapFrame(projection: proj, mapRect: rect, scale: s, originX: Double(rect.midX), originY: Double(rect.midY),
                            isWorld: true, view: GeoBBox(west: centralLon - 180, south: -90, east: centralLon + 180, north: 90))
        }
        var v = view!
        let stdLat = max(-75, min(75, v.centerLat))
        let proj = GeoProjection(kind: .equirectangular, centralLon: v.centerLon, standardLat: stdLat)
        let k = proj.xFactor(lat: 0)
        let pw = v.width * .pi / 180 * k, ph = v.height * .pi / 180
        let s = min(w / max(pw, 1e-9), h / max(ph, 1e-9))
        // Grow the window to the rectangle's shape.
        let visW = w / s * 180 / .pi / k, visH = h / s * 180 / .pi
        var south = v.centerLat - visH / 2, north = v.centerLat + visH / 2
        if north > 90 { south -= north - 90; north = 90 }
        if south < -90 { north += -90 - south; south = -90 }
        north = min(90, north)
        v = GeoBBox(west: v.centerLon - visW / 2, south: south, east: v.centerLon + visW / 2, north: north)
        let originY = Double(rect.midY) + s * ((south + north) / 2) * .pi / 180
        return MapFrame(projection: proj, mapRect: rect, scale: s, originX: Double(rect.midX), originY: originY, isWorld: false, view: v)
    }
}

/// Re-centring on a central meridian and clipping to the visible window, before projecting.
enum GeoClip {
    /// Pieces of a ring inside −180…180 around `centralLon`, as (relative lon, lat). Rings are
    /// planar polygons in the source's −180…180 frame, so shifting by ±360 and clipping to the
    /// strip never smears a polygon across the map.
    static func recenterRing(_ ring: [GeoPoint], centralLon: Double) -> [[GeoPoint]] {
        guard ring.count >= 3 else { return [] }
        var minX = Double.infinity, maxX = -Double.infinity
        let rel = ring.map { p -> GeoPoint in
            let x = p.lon - centralLon
            minX = min(minX, x); maxX = max(maxX, x)
            return GeoPoint(lon: x, lat: p.lat)
        }
        var out: [[GeoPoint]] = []
        for k in [-1.0, 0, 1] {
            let lo = minX + 360 * k, hi = maxX + 360 * k
            if hi <= -180 || lo >= 180 { continue }
            let shifted = k == 0 ? rel : rel.map { GeoPoint(lon: $0.lon + 360 * k, lat: $0.lat) }
            if lo >= -180 && hi <= 180 { out.append(shifted); continue }
            var piece = clipPolygon(shifted, axis: .lon, value: -180, keepGreater: true)
            piece = clipPolygon(piece, axis: .lon, value: 180, keepGreater: false)
            if piece.count >= 3 { out.append(piece) }
        }
        return out
    }

    static func recenterLine(_ line: [GeoPoint], centralLon: Double) -> [[GeoPoint]] {
        guard line.count >= 2 else { return [] }
        let rel = line.map { GeoPoint(lon: $0.lon - centralLon, lat: $0.lat) }
        let minX = rel.map(\.lon).min() ?? 0, maxX = rel.map(\.lon).max() ?? 0
        var out: [[GeoPoint]] = []
        for k in [-1.0, 0, 1] {
            let lo = minX + 360 * k, hi = maxX + 360 * k
            if hi <= -180 || lo >= 180 { continue }
            let shifted = k == 0 ? rel : rel.map { GeoPoint(lon: $0.lon + 360 * k, lat: $0.lat) }
            if lo >= -180 && hi <= 180 { out.append(shifted); continue }
            out.append(contentsOf: clipLine(shifted, to: GeoBBox(west: -180, south: -90.0001, east: 180, north: 90.0001)))
        }
        return out
    }

    enum Axis { case lon, lat }

    /// Sutherland–Hodgman against one axis-aligned half-plane.
    static func clipPolygon(_ poly: [GeoPoint], axis: Axis, value: Double, keepGreater: Bool) -> [GeoPoint] {
        guard poly.count >= 3 else { return [] }
        func coord(_ p: GeoPoint) -> Double { axis == .lon ? p.lon : p.lat }
        func inside(_ p: GeoPoint) -> Bool { keepGreater ? coord(p) >= value : coord(p) <= value }
        func cross(_ a: GeoPoint, _ b: GeoPoint) -> GeoPoint {
            let t = (value - coord(a)) / (coord(b) - coord(a))
            return axis == .lon ? GeoPoint(lon: value, lat: a.lat + (b.lat - a.lat) * t)
                                : GeoPoint(lon: a.lon + (b.lon - a.lon) * t, lat: value)
        }
        var out: [GeoPoint] = []
        out.reserveCapacity(poly.count + 4)
        var prev = poly[poly.count - 1]
        var prevIn = inside(prev)
        for cur in poly {
            let curIn = inside(cur)
            if curIn {
                if !prevIn { out.append(cross(prev, cur)) }
                out.append(cur)
            } else if prevIn {
                out.append(cross(prev, cur))
            }
            prev = cur
            prevIn = curIn
        }
        return out
    }

    /// Clips a polygon to a box (degenerate edges along the box are fine for filling: draw with a
    /// clip to the map rectangle so they never show).
    static func clipPolygon(_ poly: [GeoPoint], to box: GeoBBox) -> [GeoPoint] {
        var minX = Double.infinity, maxX = -Double.infinity, minY = Double.infinity, maxY = -Double.infinity
        for p in poly {
            minX = min(minX, p.lon); maxX = max(maxX, p.lon); minY = min(minY, p.lat); maxY = max(maxY, p.lat)
        }
        if maxX < box.west || minX > box.east || maxY < box.south || minY > box.north { return [] }
        if minX >= box.west && maxX <= box.east && minY >= box.south && maxY <= box.north { return poly }
        var p = poly
        if minX < box.west { p = clipPolygon(p, axis: .lon, value: box.west, keepGreater: true) }
        if maxX > box.east { p = clipPolygon(p, axis: .lon, value: box.east, keepGreater: false) }
        if minY < box.south { p = clipPolygon(p, axis: .lat, value: box.south, keepGreater: true) }
        if maxY > box.north { p = clipPolygon(p, axis: .lat, value: box.north, keepGreater: false) }
        return p.count >= 3 ? p : []
    }

    /// Clips a polyline to a box, splitting it where it leaves (Liang–Barsky per segment).
    static func clipLine(_ line: [GeoPoint], to box: GeoBBox) -> [[GeoPoint]] {
        var out: [[GeoPoint]] = []
        var cur: [GeoPoint] = []
        func inside(_ p: GeoPoint) -> Bool { p.lon >= box.west && p.lon <= box.east && p.lat >= box.south && p.lat <= box.north }
        for i in 0..<max(0, line.count - 1) {
            let a = line[i], b = line[i + 1]
            guard let (t0, t1) = liangBarsky(a, b, box) else {
                if cur.count >= 2 { out.append(cur) }
                cur = []
                continue
            }
            let p0 = GeoPoint(lon: a.lon + (b.lon - a.lon) * t0, lat: a.lat + (b.lat - a.lat) * t0)
            let p1 = GeoPoint(lon: a.lon + (b.lon - a.lon) * t1, lat: a.lat + (b.lat - a.lat) * t1)
            if cur.isEmpty || t0 > 0 {
                if cur.count >= 2 { out.append(cur) }
                cur = [p0]
            }
            cur.append(p1)
            if t1 < 1 {
                if cur.count >= 2 { out.append(cur) }
                cur = []
            }
        }
        if cur.count >= 2 { out.append(cur) }
        _ = inside
        return out
    }

    private static func liangBarsky(_ a: GeoPoint, _ b: GeoPoint, _ box: GeoBBox) -> (Double, Double)? {
        var t0 = 0.0, t1 = 1.0
        let dx = b.lon - a.lon, dy = b.lat - a.lat
        let ps = [-dx, dx, -dy, dy]
        let qs = [a.lon - box.west, box.east - a.lon, a.lat - box.south, box.north - a.lat]
        for i in 0..<4 {
            let p = ps[i], q = qs[i]
            if p == 0 {
                if q < 0 { return nil }
            } else {
                let r = q / p
                if p < 0 { if r > t1 { return nil }; if r > t0 { t0 = r } } else { if r < t0 { return nil }; if r < t1 { t1 = r } }
            }
        }
        return (t0, t1)
    }

    /// Drops points closer than `tolerance` to the last kept one (screen space).
    static func thin(_ pts: [CGPoint], tolerance: CGFloat, closed: Bool) -> [CGPoint] {
        guard pts.count > 2 else { return pts }
        let t2 = tolerance * tolerance
        var out: [CGPoint] = [pts[0]]
        out.reserveCapacity(pts.count / 2)
        for p in pts.dropFirst().dropLast() {
            let l = out[out.count - 1]
            let dx = p.x - l.x, dy = p.y - l.y
            if dx * dx + dy * dy >= t2 { out.append(p) }
        }
        out.append(pts[pts.count - 1])
        if closed && out.count < 3 { return [] }
        return out
    }
}

/// Distances and steps for scale bars, graticules and legends.
enum GeoNice {
    /// Largest 1-2-5 × 10ⁿ value not above `x`.
    static func floor125(_ x: Double) -> Double {
        guard x > 0, x.isFinite else { return 0 }
        let mag = pow(10, floor(log10(x)))
        let n = x / mag
        let f: Double = n >= 5 ? 5 : (n >= 2 ? 2 : 1)
        return f * mag
    }

    /// A scale bar no longer than `maxPoints`: (km shown, length in points).
    static func scaleBar(kmPerPoint: Double, maxPoints: Double) -> (km: Double, points: Double) {
        let km = floor125(kmPerPoint * maxPoints)
        return (km, km / max(kmPerPoint, 1e-9))
    }

    /// Graticule spacing for a span of degrees.
    static func graticuleStep(span: Double) -> Double {
        switch span {
        case ..<4: return 1
        case ..<10: return 2
        case ..<25: return 5
        case ..<70: return 10
        case ..<150: return 15
        default: return 30
        }
    }

    static func latLabel(_ lat: Double) -> String {
        let v = abs(lat)
        let s = v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
        return lat == 0 ? "0°" : "\(s)°\(lat > 0 ? "N" : "S")"
    }

    static func lonLabel(_ lon: Double) -> String {
        var l = lon.truncatingRemainder(dividingBy: 360)
        if l > 180 { l -= 360 }
        if l < -180 { l += 360 }
        let v = abs(l)
        let s = v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
        return (l == 0 || v == 180) ? "\(s)°" : "\(s)°\(l > 0 ? "E" : "W")"
    }

    static func kmLabel(_ km: Double) -> String {
        km >= 1000 ? GeoFormat.grouped(km) + " km" : (km >= 1 ? "\(Int(km)) km" : "\(Int(km * 1000)) m")
    }
}

/// Number formatting for legends, captions and tool results.
enum GeoFormat {
    static func grouped(_ v: Double) -> String {
        let n = Int(v.rounded())
        let s = String(abs(n))
        var out = ""
        for (i, ch) in s.reversed().enumerated() {
            if i > 0 && i % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return (n < 0 ? "-" : "") + String(out.reversed())
    }

    /// Compact value with sensible precision: 0.123, 1.23, 12.3, 123, 1,234, 12.3k → "12,345";
    /// millions and billions are spelled ("1.4 billion").
    static func value(_ v: Double, unitHint: String? = nil) -> String {
        guard v.isFinite else { return "–" }
        let a = abs(v)
        if a >= 1e9 { return trim(v / 1e9, 2) + " billion" }
        if a >= 1e6 { return trim(v / 1e6, 1) + " million" }
        if a >= 1000 { return grouped(v) }
        if a >= 100 { return trim(v, 0) }
        if a >= 10 { return trim(v, 1) }
        if a >= 1 { return trim(v, 2) }
        if a == 0 { return "0" }
        return trim(v, 3)
    }

    /// Short form for legends: 1.2k, 3.4M, 2.1B.
    static func short(_ v: Double) -> String {
        let a = abs(v)
        if a >= 1e9 { return trim(v / 1e9, 1) + "B" }
        if a >= 1e6 { return trim(v / 1e6, 1) + "M" }
        if a >= 1e4 { return trim(v / 1e3, 0) + "k" }
        if a >= 1000 { return grouped(v) }
        if a >= 100 { return trim(v, 0) }
        if a >= 10 { return trim(v, 1) }
        if a >= 1 { return trim(v, 2) }
        return a == 0 ? "0" : trim(v, 3)
    }

    static func trim(_ v: Double, _ decimals: Int) -> String {
        var s = String(format: "%.\(decimals)f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        if s == "-0" { s = "0" }
        return s
    }
}
