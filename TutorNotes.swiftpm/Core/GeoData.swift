import Foundation

// Bundled geography: Natural Earth countries, Australian states, rivers, lakes, populated places
// and the Köppen-Geiger climate grids, decoded from Resources/geo_*.json (built by
// tools/build_geo_data.py; the format is documented there).

struct GeoPoint: Codable, Equatable {
    var lon: Double
    var lat: Double
}

/// A longitude/latitude box. `east` is always greater than `west`; boxes across the antimeridian
/// run past 180 (e.g. 165…190 for New Zealand and the Chatham Islands).
struct GeoBBox: Codable, Equatable {
    var west: Double
    var south: Double
    var east: Double
    var north: Double

    var width: Double { east - west }
    var height: Double { north - south }
    var centerLon: Double { (west + east) / 2 }
    var centerLat: Double { (south + north) / 2 }

    func expanded(byFraction f: Double, minDegrees: Double = 0) -> GeoBBox {
        let dx = max(width * f, minDegrees), dy = max(height * f, minDegrees)
        return GeoBBox(west: west - dx, south: max(-90, south - dy), east: east + dx, north: min(90, north + dy))
    }

    /// Whether the point is inside, allowing for the box running past ±180.
    func contains(lon: Double, lat: Double) -> Bool {
        guard lat >= south && lat <= north else { return false }
        for k in [-360.0, 0, 360] where lon + k >= west && lon + k <= east { return true }
        return false
    }

    /// `lon` shifted by a multiple of 360 to be as close as possible to the box's centre.
    func nearestLon(_ lon: Double) -> Double {
        lon + 360 * ((centerLon - lon) / 360).rounded()
    }
}

enum GeoDataError: Error, CustomStringConvertible {
    case badFormat(String)
    var description: String {
        switch self {
        case .badFormat(let s): return "Bad geo data: \(s)"
        }
    }
}

enum GeoCodec {
    /// Decodes the arc stream: per arc a varint count, then zigzag-varint deltas from the previous
    /// point (carried across arcs), in units of 1/q degree offset by (180, 90).
    static func decodeArcs(base64: String, q: Double) throws -> [[GeoPoint]] {
        guard let data = Data(base64Encoded: base64) else { throw GeoDataError.badFormat("arcs are not base64") }
        let bytes = [UInt8](data)
        var i = 0
        func varint() throws -> Int {
            var result = 0, shift = 0
            while true {
                guard i < bytes.count else { throw GeoDataError.badFormat("truncated varint") }
                let b = Int(bytes[i])
                i += 1
                result |= (b & 0x7F) << shift
                if b < 0x80 { return result }
                shift += 7
                if shift > 56 { throw GeoDataError.badFormat("varint too long") }
            }
        }
        func zigzag(_ n: Int) -> Int { (n >> 1) ^ -(n & 1) }
        var arcs: [[GeoPoint]] = []
        var x = 0, y = 0
        while i < bytes.count {
            let n = try varint()
            var arc: [GeoPoint] = []
            arc.reserveCapacity(n)
            for _ in 0..<n {
                x += zigzag(try varint())
                y += zigzag(try varint())
                arc.append(GeoPoint(lon: Double(x) / q - 180, lat: Double(y) / q - 90))
            }
            arcs.append(arc)
        }
        return arcs
    }

    /// Joins arcs into a ring (TopoJSON style: ~i is arc i reversed).
    static func ring(_ refs: [Int], arcs: [[GeoPoint]]) -> [GeoPoint] {
        var pts: [GeoPoint] = []
        for r in refs {
            let idx = r >= 0 ? r : ~r
            guard idx < arcs.count else { continue }
            let a = r >= 0 ? arcs[idx] : arcs[idx].reversed()
            if pts.isEmpty { pts.append(contentsOf: a) } else { pts.append(contentsOf: a.dropFirst()) }
        }
        return pts
    }

    /// Lowercased, accent-free, punctuation-free form used to match names.
    static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        var out = ""
        var lastSpace = true
        for ch in folded {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastSpace = false
            } else if ch == "&" {
                if !lastSpace { out.append(" ") }
                out.append("and ")
                lastSpace = true
            } else if !lastSpace && ch != "'" && ch != "’" {
                out.append(" ")
                lastSpace = true
            }
        }
        if out.hasSuffix(" ") { out.removeLast() }
        if out.hasPrefix("the ") { out.removeFirst(4) }
        return out
    }
}

/// Countries, Australian states, rivers and lakes.
final class GeoWorld {
    struct Country {
        /// ISO 3166-1 alpha-3 (World Bank and Our World in Data use the same codes; Kosovo is XKX).
        let code: String
        let iso2: String?
        /// Short map label, e.g. "Dem. Rep. Congo".
        let name: String
        /// Long and formal names, e.g. "Democratic Republic of the Congo".
        let aliases: [String]
        let continent: String
        let region: String
        let subregion: String
        let label: GeoPoint
        /// Natural Earth's label priority (smaller shows first).
        let minLabel: Double
        /// Colour index 1…7 such that neighbours differ (Natural Earth MAPCOLOR7).
        let mapColor: Int
        /// The main landmass and nearby islands (not far-flung territories).
        let focus: GeoBBox
        /// Exterior rings anticlockwise, holes clockwise (lon right, lat up).
        let rings: [[GeoPoint]]
        let ringArcs: [[Int]]
        /// Extent of every part, including far-flung territories.
        let bounds: GeoBBox

        /// Full name for prose ("Democratic Republic of the Congo" rather than "Dem. Rep. Congo").
        let longName: String
    }

    struct State {
        let id: String
        let country: String
        let name: String
        let abbr: String
        let kind: String
        let label: GeoPoint
        let rings: [[GeoPoint]]
        let ringArcs: [[Int]]
    }

    struct River {
        let name: String
        let rank: Int
        let lines: [[GeoPoint]]
    }

    struct Lake {
        let name: String
        let rank: Int
        let salt: Bool
        let rings: [[GeoPoint]]
    }

    let arcs: [[GeoPoint]]
    let countries: [Country]
    let states: [State]
    let rivers: [River]
    let lakes: [Lake]
    /// Country arcs used once (coastline) and twice (land borders), and state arcs inside Australia.
    let coastArcs: [Int]
    let borderArcs: [Int]
    let stateBorderArcs: [Int]
    /// Country indices that share a border.
    let neighbours: [[Int]]

    private var index: [String: Int] = [:]
    private var stateIndex: [String: Int] = [:]

    private struct FileDTO: Decodable {
        let format: String
        let q: Double
        let arcs: String
        let countries: [CountryDTO]
        let states: [StateDTO]
        let rivers: [RiverDTO]
        let lakes: [LakeDTO]
    }
    private struct CountryDTO: Decodable {
        let a3: String
        let a2: String?
        let n: String
        let nl: String?
        let alt: [String]?
        let c: String
        let reg: String
        let sub: String
        let lp: [Double]
        let ml: Double
        let mc: Int?
        let bb: [Double]
        let r: [[Int]]
    }
    private struct StateDTO: Decodable {
        let id: String
        let country: String
        let n: String
        let abbr: String
        let kind: String
        let lp: [Double]
        let r: [[Int]]
    }
    private struct RiverDTO: Decodable {
        let n: String
        let rank: Int
        let l: [Int]
    }
    private struct LakeDTO: Decodable {
        let n: String
        let rank: Int
        let salt: Bool
        let r: [Int]
    }

    init(data: Data) throws {
        let dto = try JSONDecoder().decode(FileDTO.self, from: data)
        guard dto.format == "margin-geo-1" else { throw GeoDataError.badFormat("unknown format \(dto.format)") }
        let arcs = try GeoCodec.decodeArcs(base64: dto.arcs, q: dto.q)
        self.arcs = arcs
        func point(_ a: [Double]) -> GeoPoint { GeoPoint(lon: a.first ?? 0, lat: a.count > 1 ? a[1] : 0) }
        countries = dto.countries.map { c in
            let rings = c.r.map { GeoCodec.ring($0, arcs: arcs) }
            return Country(code: c.a3, iso2: c.a2, name: c.n, aliases: c.alt ?? [], continent: c.c, region: c.reg, subregion: c.sub,
                    label: point(c.lp), minLabel: c.ml, mapColor: c.mc ?? 1,
                    focus: c.bb.count == 4 ? GeoBBox(west: c.bb[0], south: c.bb[1], east: c.bb[2], north: c.bb[3]) : GeoBBox(west: -180, south: -90, east: 180, north: 90),
                    rings: rings, ringArcs: c.r, bounds: GeoGeometry.bbox(rings) ?? GeoBBox(west: -180, south: -90, east: 180, north: 90),
                    longName: c.nl ?? c.n)
        }
        states = dto.states.map { s in
            State(id: s.id, country: s.country, name: s.n, abbr: s.abbr, kind: s.kind, label: point(s.lp),
                  rings: s.r.map { GeoCodec.ring($0, arcs: arcs) }, ringArcs: s.r)
        }
        rivers = dto.rivers.map { River(name: $0.n, rank: $0.rank, lines: $0.l.filter { $0 < arcs.count }.map { arcs[$0] }) }
        lakes = dto.lakes.map { Lake(name: $0.n, rank: $0.rank, salt: $0.salt, rings: $0.r.filter { $0 < arcs.count }.map { arcs[$0] }) }

        // Arc use: once = coast, twice = shared border.
        var users: [Int: [Int]] = [:]
        for (ci, c) in dto.countries.enumerated() {
            for ring in c.r { for r in ring { users[r >= 0 ? r : ~r, default: []].append(ci) } }
        }
        var coast: [Int] = [], border: [Int] = []
        var nb = [Set<Int>](repeating: [], count: dto.countries.count)
        for (arc, u) in users {
            let distinct = Set(u)
            if distinct.count >= 2 {
                border.append(arc)
                let list = Array(distinct)
                for a in list { for b in list where a != b { nb[a].insert(b) } }
            } else {
                coast.append(arc)
            }
        }
        coastArcs = coast.sorted()
        borderArcs = border.sorted()
        neighbours = nb.map { Array($0).sorted() }
        var stateUsers: [Int: Int] = [:]
        for s in dto.states { for ring in s.r { for r in ring { stateUsers[r >= 0 ? r : ~r, default: 0] += 1 } } }
        stateBorderArcs = stateUsers.filter { $0.value >= 2 }.map(\.key).sorted()

        for (i, c) in countries.enumerated() {
            for key in [c.code, c.name] + c.aliases + (c.iso2.map { [$0] } ?? []) {
                let k = GeoCodec.normalize(key)
                if index[k] == nil { index[k] = i }
            }
        }
        for (alias, code) in GeoWorld.commonAliases {
            if let i = countries.firstIndex(where: { $0.code == code }) { index[GeoCodec.normalize(alias)] = i }
        }
        for (i, s) in states.enumerated() {
            for key in [s.id, s.name, s.abbr] { stateIndex[GeoCodec.normalize(key)] = i }
        }
        stateIndex["nsw"] = states.firstIndex { $0.id == "AU-NSW" }
        stateIndex["qld"] = states.firstIndex { $0.id == "AU-QLD" }
        stateIndex["vic"] = states.firstIndex { $0.id == "AU-VIC" }
    }

    /// Everyday names and World Bank / Our World in Data spellings that differ from Natural Earth's.
    static let commonAliases: [(String, String)] = [
        ("USA", "USA"), ("US", "USA"), ("United States", "USA"), ("America", "USA"), ("United States of America", "USA"),
        ("UK", "GBR"), ("Britain", "GBR"), ("Great Britain", "GBR"),
        ("Russia", "RUS"), ("Russian Federation", "RUS"), ("South Korea", "KOR"), ("Korea, Rep.", "KOR"), ("Korea", "KOR"),
        ("North Korea", "PRK"), ("Korea, Dem. People's Rep.", "PRK"), ("DRC", "COD"), ("DR Congo", "COD"),
        ("Democratic Republic of Congo", "COD"), ("Congo, Dem. Rep.", "COD"), ("Congo-Kinshasa", "COD"),
        ("Republic of the Congo", "COG"), ("Congo, Rep.", "COG"), ("Congo-Brazzaville", "COG"), ("Congo", "COG"),
        ("Ivory Coast", "CIV"), ("Cote d'Ivoire", "CIV"), ("Czech Republic", "CZE"), ("Swaziland", "SWZ"), ("Eswatini", "SWZ"),
        ("Burma", "MMR"), ("East Timor", "TLS"), ("Timor Leste", "TLS"), ("PNG", "PNG"), ("UAE", "ARE"),
        ("Laos", "LAO"), ("Lao PDR", "LAO"), ("Viet Nam", "VNM"), ("Vietnam", "VNM"), ("Iran", "IRN"), ("Iran, Islamic Rep.", "IRN"),
        ("Syria", "SYR"), ("Syrian Arab Republic", "SYR"), ("Turkiye", "TUR"), ("Türkiye", "TUR"), ("Turkey", "TUR"),
        ("Macedonia", "MKD"), ("Cape Verde", "CPV"), ("Bosnia", "BIH"), ("Gambia", "GMB"), ("Gambia, The", "GMB"),
        ("Bahamas", "BHS"), ("Bahamas, The", "BHS"), ("Egypt, Arab Rep.", "EGY"), ("Yemen, Rep.", "YEM"), ("Venezuela, RB", "VEN"),
        ("Kyrgyz Republic", "KGZ"), ("Slovak Republic", "SVK"), ("Micronesia, Fed. Sts.", "FSM"), ("West Bank and Gaza", "PSE"),
        ("Palestine", "PSE"), ("Holland", "NLD"), ("Vatican City", "VAT"), ("NZ", "NZL"), ("Aotearoa", "NZL"),
        ("South Sudan", "SSD"), ("Central African Republic", "CAF"), ("Equatorial Guinea", "GNQ"), ("Dominican Republic", "DOM"),
        ("Solomon Islands", "SLB"), ("Marshall Islands", "MHL"), ("Western Sahara", "ESH"), ("Taiwan", "TWN"),
        ("Hong Kong", "HKG"), ("Brunei", "BRN"), ("Moldova", "MDA"), ("Bolivia", "BOL"), ("Tanzania", "TZA"),
        ("Saint Lucia", "LCA"), ("St. Lucia", "LCA"), ("Kosovo", "XKX"), ("Greenland", "GRL"),
    ]

    func countryIndex(_ query: String) -> Int? {
        let k = GeoCodec.normalize(query)
        if let i = index[k] { return i }
        // "Republic of X" / "X Republic" style leftovers.
        for prefix in ["republic of ", "kingdom of ", "state of "] where k.hasPrefix(prefix) {
            if let i = index[String(k.dropFirst(prefix.count))] { return i }
        }
        return nil
    }

    func country(_ query: String) -> Country? { countryIndex(query).map { countries[$0] } }
    func country(code: String) -> Country? { countries.first { $0.code == code } }

    func state(_ query: String) -> State? {
        stateIndex[GeoCodec.normalize(query)].map { states[$0] }
    }

    /// The country containing the point, if any (even-odd test over its rings).
    func countryAt(lon: Double, lat: Double) -> Country? {
        for c in countries where c.bounds.contains(lon: lon, lat: lat) {
            var inside = false
            for ring in c.rings where GeoGeometry.pointInRing(lon: lon, lat: lat, ring) { inside.toggle() }
            if inside { return c }
        }
        return nil
    }

    /// Bounding box of everything listed (countries or states), in a longitude frame chosen to
    /// keep them together across the antimeridian.
    func bbox(countries codes: [String], states ids: [String] = []) -> GeoBBox? {
        var boxes = codes.compactMap { country(code: $0)?.focus }
        for id in ids {
            guard let s = states.first(where: { $0.id == id }) else { continue }
            if let b = GeoGeometry.bbox(s.rings) { boxes.append(b) }
        }
        guard var u = boxes.first else { return nil }
        for b in boxes.dropFirst() {
            let shift = 360 * ((u.centerLon - b.centerLon) / 360).rounded()
            u = GeoBBox(west: min(u.west, b.west + shift), south: min(u.south, b.south),
                        east: max(u.east, b.east + shift), north: max(u.north, b.north))
        }
        return u
    }
}

enum GeoGeometry {
    static func pointInRing(lon: Double, lat: Double, _ ring: [GeoPoint]) -> Bool {
        guard ring.count > 2 else { return false }
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i], b = ring[j]
            if (a.lat > lat) != (b.lat > lat) {
                let x = a.lon + (lat - a.lat) / (b.lat - a.lat) * (b.lon - a.lon)
                if lon < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    static func bbox(_ rings: [[GeoPoint]]) -> GeoBBox? {
        var w = Double.infinity, s = Double.infinity, e = -Double.infinity, n = -Double.infinity
        for r in rings {
            for p in r {
                w = min(w, p.lon); e = max(e, p.lon); s = min(s, p.lat); n = max(n, p.lat)
            }
        }
        return w.isFinite ? GeoBBox(west: w, south: s, east: e, north: n) : nil
    }

    /// Great-circle distance in km.
    static func distanceKm(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let r = 6371.0088
        let p1 = a.lat * .pi / 180, p2 = b.lat * .pi / 180
        let dp = p2 - p1, dl = (b.lon - a.lon) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }
}

// MARK: - Places

/// Cities and towns for placing markers by name (Natural Earth populated places: capitals, large
/// cities and Australian towns).
final class GeoPlaces {
    struct Place: Equatable {
        let name: String
        let lon: Double
        let lat: Double
        let country: String
        let population: Int
        /// 1 national capital, 2 state or province capital, 0 other.
        let capital: Int
        let admin1: String

        var point: GeoPoint { GeoPoint(lon: lon, lat: lat) }
    }

    let places: [Place]
    private var byName: [String: [Int]] = [:]

    init(data: Data) throws {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["places"] as? [[Any]] else { throw GeoDataError.badFormat("places") }
        var list: [Place] = []
        for r in rows where r.count >= 6 {
            guard let name = r[0] as? String, let lon = (r[1] as? NSNumber)?.doubleValue, let lat = (r[2] as? NSNumber)?.doubleValue else { continue }
            list.append(Place(name: name, lon: lon, lat: lat, country: r[3] as? String ?? "", population: (r[4] as? NSNumber)?.intValue ?? 0,
                              capital: (r[5] as? NSNumber)?.intValue ?? 0, admin1: r.count > 6 ? (r[6] as? String ?? "") : ""))
        }
        places = list
        for (i, p) in list.enumerated() { byName[GeoCodec.normalize(p.name), default: []].append(i) }
    }

    /// "Sydney", "Paris, France", "Richmond, NSW", "Lagos (Nigeria)". Larger places win ties.
    func find(_ query: String, world: GeoWorld?) -> Place? {
        var q = query.replacingOccurrences(of: "(", with: ",").replacingOccurrences(of: ")", with: "")
        q = q.trimmingCharacters(in: .whitespaces)
        let parts = q.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = parts.first, !first.isEmpty else { return nil }
        let candidates = (byName[GeoCodec.normalize(first)] ?? []).map { places[$0] }
        guard !candidates.isEmpty else { return nil }
        if parts.count > 1 {
            let qual = parts[1]
            let qn = GeoCodec.normalize(qual)
            let code = world?.country(qual)?.code
            let stateName = world?.state(qual)?.name
            if let hit = candidates.first(where: { c in
                c.country == code || GeoCodec.normalize(c.admin1) == qn || (stateName.map { GeoCodec.normalize($0) == GeoCodec.normalize(c.admin1) } ?? false)
            }) { return hit }
        }
        return candidates.max { $0.population < $1.population }
    }

    func nearest(to p: GeoPoint, maxKm: Double = 60) -> Place? {
        var best: (Place, Double)?
        for pl in places where abs(pl.lat - p.lat) < 2 {
            let d = GeoGeometry.distanceKm(p, pl.point)
            if d <= maxKm && d < (best?.1 ?? .infinity) { best = (pl, d) }
        }
        return best?.0
    }
}

// MARK: - Köppen-Geiger

struct KoppenClass {
    let id: Int
    let code: String
    let name: String
    let hex: String

    var group: Character { code.first ?? "?" }
}

/// Köppen-Geiger classes with the colours of Beck et al. (2023).
enum Koppen {
    static let classes: [KoppenClass] = [
        KoppenClass(id: 1, code: "Af", name: "Tropical rainforest", hex: "#0000FF"),
        KoppenClass(id: 2, code: "Am", name: "Tropical monsoon", hex: "#0078FF"),
        KoppenClass(id: 3, code: "Aw", name: "Tropical savanna", hex: "#46AAFA"),
        KoppenClass(id: 4, code: "BWh", name: "Hot desert", hex: "#FF0000"),
        KoppenClass(id: 5, code: "BWk", name: "Cold desert", hex: "#FF9696"),
        KoppenClass(id: 6, code: "BSh", name: "Hot steppe (semi-arid)", hex: "#F5A500"),
        KoppenClass(id: 7, code: "BSk", name: "Cold steppe (semi-arid)", hex: "#FFDC64"),
        KoppenClass(id: 8, code: "Csa", name: "Mediterranean, hot summer", hex: "#FFFF00"),
        KoppenClass(id: 9, code: "Csb", name: "Mediterranean, warm summer", hex: "#C8C800"),
        KoppenClass(id: 10, code: "Csc", name: "Mediterranean, cold summer", hex: "#969600"),
        KoppenClass(id: 11, code: "Cwa", name: "Humid subtropical, dry winter", hex: "#96FF96"),
        KoppenClass(id: 12, code: "Cwb", name: "Subtropical highland, dry winter", hex: "#64C864"),
        KoppenClass(id: 13, code: "Cwc", name: "Subpolar highland, dry winter", hex: "#329632"),
        KoppenClass(id: 14, code: "Cfa", name: "Humid subtropical", hex: "#C8FF50"),
        KoppenClass(id: 15, code: "Cfb", name: "Temperate oceanic", hex: "#64FF50"),
        KoppenClass(id: 16, code: "Cfc", name: "Subpolar oceanic", hex: "#32C800"),
        KoppenClass(id: 17, code: "Dsa", name: "Continental, dry hot summer", hex: "#FF00FF"),
        KoppenClass(id: 18, code: "Dsb", name: "Continental, dry warm summer", hex: "#C800C8"),
        KoppenClass(id: 19, code: "Dsc", name: "Subarctic, dry summer", hex: "#963296"),
        KoppenClass(id: 20, code: "Dsd", name: "Subarctic, dry summer, very cold winter", hex: "#966496"),
        KoppenClass(id: 21, code: "Dwa", name: "Continental, dry winter, hot summer", hex: "#AAAFFF"),
        KoppenClass(id: 22, code: "Dwb", name: "Continental, dry winter, warm summer", hex: "#5A78DC"),
        KoppenClass(id: 23, code: "Dwc", name: "Subarctic, dry winter", hex: "#4B50B4"),
        KoppenClass(id: 24, code: "Dwd", name: "Subarctic, dry winter, very cold winter", hex: "#320087"),
        KoppenClass(id: 25, code: "Dfa", name: "Humid continental, hot summer", hex: "#00FFFF"),
        KoppenClass(id: 26, code: "Dfb", name: "Humid continental, warm summer", hex: "#37C8FF"),
        KoppenClass(id: 27, code: "Dfc", name: "Subarctic", hex: "#007D7D"),
        KoppenClass(id: 28, code: "Dfd", name: "Subarctic, very cold winter", hex: "#00465F"),
        KoppenClass(id: 29, code: "ET", name: "Tundra", hex: "#B2B2B2"),
        KoppenClass(id: 30, code: "EF", name: "Ice cap", hex: "#666666"),
    ]

    /// The five main groups, for a simpler map.
    static let groups: [(letter: Character, name: String, hex: String)] = [
        ("A", "Tropical", "#1F6FD6"), ("B", "Arid (desert and steppe)", "#E8603C"), ("C", "Temperate", "#5CB85C"),
        ("D", "Continental (cold)", "#8E6CC8"), ("E", "Polar", "#A8A8A8"),
    ]

    static func cls(_ id: Int) -> KoppenClass? { id >= 1 && id <= classes.count ? classes[id - 1] : nil }

    static func groupIndex(_ id: Int) -> Int? {
        guard let c = cls(id) else { return nil }
        return groups.firstIndex { $0.letter == c.group }
    }
}

/// The Köppen-Geiger grids (1991–2020): world at 0.5° and 0.2°, Australia at 0.1°.
final class KoppenData {
    struct Grid {
        let id: String
        let res: Double
        let west: Double
        let north: Double
        let cols: Int
        let rows: Int
        let cells: [UInt8]

        var bbox: GeoBBox { GeoBBox(west: west, south: north - Double(rows) * res, east: west + Double(cols) * res, north: north) }

        func value(lon: Double, lat: Double) -> Int {
            var x = lon
            if isGlobal {
                x = west + (lon - west).truncatingRemainder(dividingBy: 360)
                if x < west { x += 360 }
            }
            let c = Int(floor((x - west) / res)), r = Int(floor((north - lat) / res))
            guard c >= 0, c < cols, r >= 0, r < rows else { return 0 }
            return Int(cells[r * cols + c])
        }

        /// Covers every longitude.
        var isGlobal: Bool { abs(Double(cols) * res - 360) < 1e-6 }
    }

    let grids: [Grid]

    init(data: Data) throws {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["grids"] as? [[String: Any]] else { throw GeoDataError.badFormat("koppen") }
        var out: [Grid] = []
        for g in list {
            guard let id = g["id"] as? String, let res = (g["res"] as? NSNumber)?.doubleValue,
                  let west = (g["west"] as? NSNumber)?.doubleValue, let north = (g["north"] as? NSNumber)?.doubleValue,
                  let cols = (g["cols"] as? NSNumber)?.intValue, let rows = (g["rows"] as? NSNumber)?.intValue,
                  let rle = g["rle"] as? String, let data = Data(base64Encoded: rle) else { continue }
            let bytes = [UInt8](data)
            var cells = [UInt8](repeating: 0, count: cols * rows)
            var i = 0, pos = 0
            while i < bytes.count && pos < cells.count {
                let v = bytes[i]
                i += 1
                var n = 0, shift = 0
                while i < bytes.count {
                    let b = Int(bytes[i])
                    i += 1
                    n |= (b & 0x7F) << shift
                    if b < 0x80 { break }
                    shift += 7
                }
                let end = min(cells.count, pos + n)
                if v != 0 { for k in pos..<end { cells[k] = v } }
                pos = end
            }
            out.append(Grid(id: id, res: res, west: west, north: north, cols: cols, rows: rows, cells: cells))
        }
        grids = out
    }

    /// The coarsest grid whose cells are at most `maxCellPoints` across on the page (else the
    /// finest), preferring grids that cover the whole view.
    func grid(for view: GeoBBox, pointsPerDegree: Double, maxCellPoints: Double = 1.6) -> Grid? {
        let covering = grids.filter { g in
            g.isGlobal || (view.west >= g.bbox.west - 1 && view.east <= g.bbox.east + 1 && view.south >= g.bbox.south - 1 && view.north <= g.bbox.north + 1)
        }.sorted { $0.res > $1.res }
        return covering.first { $0.res * pointsPerDegree <= maxCellPoints } ?? covering.last ?? grids.first
    }

    /// The class at a point, from the finest grid that covers it.
    func classAt(lon: Double, lat: Double) -> Int {
        for g in grids.sorted(by: { $0.res < $1.res }) where g.isGlobal || g.bbox.contains(lon: lon, lat: lat) {
            let v = g.value(lon: lon, lat: lat)
            if v != 0 || g.isGlobal { return v }
        }
        return 0
    }
}
