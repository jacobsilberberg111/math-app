import Foundation

// Real-world datasets for maps and charts: the curated catalog, parsing World Bank and Our World
// in Data responses, choosing a year, binning into classes and summarising for the tutor.

enum GeoProvider: String, Codable {
    case worldBank = "worldbank"
    case owid

    var displayName: String { self == .worldBank ? "World Bank" : "Our World in Data" }
}

struct GeoDataset: Equatable {
    let id: String
    let title: String
    let provider: GeoProvider
    /// World Bank indicator code or Our World in Data grapher slug.
    let code: String
    let unit: String
    let topic: String
    /// Colour ramp name (GeoPalette).
    let palette: String
    /// Values above and below zero (growth rates, net migration): a diverging ramp centred on 0.
    let diverging: Bool
    /// An Our World in Data chart with the same (or a very close) indicator, used when the World
    /// Bank API is down. Its own title, unit and citation are shown.
    let fallback: String?

    init(_ id: String, _ title: String, _ provider: GeoProvider, _ code: String, unit: String, topic: String,
         palette: String = "blues", diverging: Bool = false, fallback: String? = nil) {
        self.id = id
        self.title = title
        self.provider = provider
        self.code = code
        self.unit = unit
        self.topic = topic
        self.palette = palette
        self.diverging = diverging
        self.fallback = fallback
    }
}

/// Every entry was checked against the live APIs (codes, slugs and coverage) in November 2026.
enum GeoCatalog {
    static let topics = ["Population and places", "Wellbeing and development", "Health and disease", "Environment"]

    static let datasets: [GeoDataset] = [
        // Population and places (changing places, urbanisation, migration).
        GeoDataset("population_density", "Population density", .worldBank, "EN.POP.DNST", unit: "people per km²", topic: topics[0], palette: "purples"),
        GeoDataset("population", "Population", .worldBank, "SP.POP.TOTL", unit: "people", topic: topics[0], palette: "purples", fallback: "population"),
        GeoDataset("urban_population", "Urban population", .worldBank, "SP.URB.TOTL.IN.ZS", unit: "% of population", topic: topics[0], palette: "oranges", fallback: "share-of-population-urban"),
        GeoDataset("urban_growth", "Urban population growth", .worldBank, "SP.URB.GROW", unit: "% per year", topic: topics[0], palette: "rdbu", diverging: true),
        GeoDataset("population_growth", "Population growth", .worldBank, "SP.POP.GROW", unit: "% per year", topic: topics[0], palette: "rdbu", diverging: true),
        GeoDataset("fertility_rate", "Fertility rate", .worldBank, "SP.DYN.TFRT.IN", unit: "births per woman", topic: topics[0], palette: "purples", fallback: "children-per-woman-un"),
        GeoDataset("net_migration", "Net migration", .worldBank, "SM.POP.NETM", unit: "people per year", topic: topics[0], palette: "brbg", diverging: true),
        GeoDataset("migrant_share", "International migrants", .worldBank, "SM.POP.TOTL.ZS", unit: "% of population", topic: topics[0], palette: "ylgnbu", fallback: "migrant-stock-share"),
        // Wellbeing and development.
        GeoDataset("gdp_per_capita", "GDP per person", .worldBank, "NY.GDP.PCAP.CD", unit: "US$", topic: topics[1], palette: "greens", fallback: "gdp-per-capita-worldbank"),
        GeoDataset("gdp_per_capita_ppp", "GDP per person (PPP)", .worldBank, "NY.GDP.PCAP.PP.CD", unit: "international $", topic: topics[1], palette: "greens", fallback: "gdp-per-capita-worldbank"),
        GeoDataset("gni_per_capita", "GNI per person", .worldBank, "NY.GNP.PCAP.CD", unit: "US$ (Atlas method)", topic: topics[1], palette: "greens"),
        GeoDataset("hdi", "Human Development Index", .owid, "human-development-index", unit: "index, 0–1", topic: topics[1], palette: "ylgnbu"),
        GeoDataset("life_satisfaction", "Life satisfaction (happiness)", .owid, "happiness-cantril-ladder", unit: "score, 0–10", topic: topics[1], palette: "ylgn"),
        GeoDataset("life_expectancy", "Life expectancy at birth", .worldBank, "SP.DYN.LE00.IN", unit: "years", topic: topics[1], palette: "ylgnbu", fallback: "life-expectancy"),
        GeoDataset("extreme_poverty", "Extreme poverty (below $3 a day)", .owid, "share-of-population-in-extreme-poverty", unit: "% of population", topic: topics[1], palette: "reds"),
        GeoDataset("undernourishment", "Undernourishment", .worldBank, "SN.ITK.DEFC.ZS", unit: "% of population", topic: topics[1], palette: "oranges", fallback: "prevalence-of-undernourishment"),
        GeoDataset("drinking_water", "Access to basic drinking water", .worldBank, "SH.H2O.BASW.ZS", unit: "% of population", topic: topics[1], palette: "blues"),
        GeoDataset("safe_drinking_water", "Safely managed drinking water", .worldBank, "SH.H2O.SMDW.ZS", unit: "% of population", topic: topics[1], palette: "blues"),
        GeoDataset("sanitation", "Access to basic sanitation", .worldBank, "SH.STA.BASS.ZS", unit: "% of population", topic: topics[1], palette: "blues"),
        GeoDataset("electricity_access", "Access to electricity", .worldBank, "EG.ELC.ACCS.ZS", unit: "% of population", topic: topics[1], palette: "ylorrd", fallback: "share-of-the-population-with-access-to-electricity"),
        GeoDataset("internet_users", "Internet users", .worldBank, "IT.NET.USER.ZS", unit: "% of population", topic: topics[1], palette: "purples", fallback: "share-of-individuals-using-the-internet"),
        GeoDataset("literacy", "Adult literacy rate", .worldBank, "SE.ADT.LITR.ZS", unit: "% of people 15+", topic: topics[1], palette: "greens"),
        GeoDataset("secondary_school", "Secondary school enrolment", .worldBank, "SE.SEC.ENRR", unit: "% gross", topic: topics[1], palette: "greens"),
        // Health and disease.
        GeoDataset("child_mortality", "Child mortality (under 5)", .worldBank, "SH.DYN.MORT", unit: "deaths per 1,000 live births", topic: topics[2], palette: "reds", fallback: "child-mortality"),
        GeoDataset("infant_mortality", "Infant mortality", .worldBank, "SP.DYN.IMRT.IN", unit: "deaths per 1,000 live births", topic: topics[2], palette: "reds", fallback: "infant-mortality"),
        GeoDataset("maternal_mortality", "Maternal mortality", .worldBank, "SH.STA.MMRT", unit: "deaths per 100,000 live births", topic: topics[2], palette: "reds", fallback: "maternal-mortality"),
        GeoDataset("malaria_incidence", "Malaria incidence", .worldBank, "SH.MLR.INCD.P3", unit: "cases per 1,000 people at risk", topic: topics[2], palette: "ylorrd", fallback: "incidence-of-malaria"),
        GeoDataset("tb_incidence", "Tuberculosis incidence", .worldBank, "SH.TBS.INCD", unit: "cases per 100,000 people", topic: topics[2], palette: "ylorrd", fallback: "incidence-of-tuberculosis-sdgs"),
        GeoDataset("hiv_prevalence", "HIV prevalence", .worldBank, "SH.DYN.AIDS.ZS", unit: "% of people aged 15–49", topic: topics[2], palette: "reds", fallback: "share-of-population-infected-with-hiv-ihme"),
        GeoDataset("measles_immunisation", "Measles immunisation", .worldBank, "SH.IMM.MEAS", unit: "% of children 12–23 months", topic: topics[2], palette: "greens", fallback: "share-of-children-vaccinated-against-measles"),
        GeoDataset("physicians", "Doctors", .worldBank, "SH.MED.PHYS.ZS", unit: "per 1,000 people", topic: topics[2], palette: "blues", fallback: "physicians-per-1000-people"),
        GeoDataset("health_spending", "Health spending per person", .worldBank, "SH.XPD.CHEX.PC.CD", unit: "US$", topic: topics[2], palette: "greens"),
        // Environment.
        GeoDataset("co2_per_capita", "CO₂ emissions per person", .owid, "co-emissions-per-capita", unit: "tonnes per person", topic: topics[3], palette: "ylorrd"),
        GeoDataset("forest_area", "Forest cover", .worldBank, "AG.LND.FRST.ZS", unit: "% of land area", topic: topics[3], palette: "greens", fallback: "forest-area-as-share-of-land-area"),
        GeoDataset("agricultural_land", "Agricultural land", .worldBank, "AG.LND.AGRI.ZS", unit: "% of land area", topic: topics[3], palette: "ylgn"),
        GeoDataset("arable_land", "Arable land", .worldBank, "AG.LND.ARBL.ZS", unit: "% of land area", topic: topics[3], palette: "ylgn"),
        GeoDataset("protected_areas", "Protected areas", .worldBank, "ER.PTD.TOTL.ZS", unit: "% of territory", topic: topics[3], palette: "greens"),
        GeoDataset("renewable_energy", "Renewable energy", .worldBank, "EG.FEC.RNEW.ZS", unit: "% of final energy use", topic: topics[3], palette: "greens"),
        GeoDataset("water_stress", "Water stress", .worldBank, "ER.H2O.FWST.ZS", unit: "% of freshwater withdrawn", topic: topics[3], palette: "oranges"),
        GeoDataset("air_pollution", "Air pollution (PM2.5)", .worldBank, "EN.ATM.PM25.MC.M3", unit: "µg/m³, annual mean", topic: topics[3], palette: "purples", fallback: "pm25-air-pollution"),
    ]

    /// A catalog id, "worldbank:CODE" or "owid:slug". A bare World Bank code (letters and dots,
    /// e.g. SP.DYN.LE00.IN) or a grapher slug (lowercase-with-hyphens) also works.
    static func resolve(_ s: String) -> GeoDataset? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let low = t.lowercased()
        if let d = datasets.first(where: { $0.id == low || $0.id == low.replacingOccurrences(of: " ", with: "_") }) { return d }
        if let d = datasets.first(where: { $0.code.lowercased() == low }) { return d }
        if let d = datasets.first(where: { GeoCodec.normalize($0.title) == GeoCodec.normalize(t) }) { return d }
        if low.hasPrefix("worldbank:") || low.hasPrefix("wb:") {
            let code = String(t[t.index(after: t.firstIndex(of: ":")!)...]).trimmingCharacters(in: .whitespaces).uppercased()
            guard isWorldBankCode(code) else { return nil }
            return GeoDataset("worldbank:\(code)", code, .worldBank, code, unit: "", topic: "Other")
        }
        if low.hasPrefix("owid:") {
            let slug = String(low.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard isSlug(slug) else { return nil }
            return GeoDataset("owid:\(slug)", slug, .owid, slug, unit: "", topic: "Other")
        }
        if isWorldBankCode(t.uppercased()) && t.contains(".") { return GeoDataset("worldbank:\(t.uppercased())", t.uppercased(), .worldBank, t.uppercased(), unit: "", topic: "Other") }
        if isSlug(low) && low.contains("-") { return GeoDataset("owid:\(low)", low, .owid, low, unit: "", topic: "Other") }
        return nil
    }

    static func isWorldBankCode(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 40 && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" } && s.first!.isLetter
    }

    static func isSlug(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 120 && s.allSatisfy { ($0.isLetter && $0.isLowercase) || $0.isNumber || $0 == "-" }
    }

    /// One line per dataset for the tool description.
    static var promptList: String {
        topics.map { topic in
            "\(topic): " + datasets.filter { $0.topic == topic }.map { "\($0.id) (\($0.title), \($0.unit))" }.joined(separator: "; ")
        }.joined(separator: "\n")
    }
}

/// One fetched indicator: rows of (country code, year, value).
struct GeoIndicatorTable: Equatable {
    struct Row: Equatable {
        var code: String
        var name: String
        var year: Int
        var value: Double
    }

    var provider: GeoProvider
    var code: String
    var title: String
    var unit: String?
    /// The original source, e.g. "UNDP, Human Development Report (2025)".
    var citation: String?
    var rows: [Row]

    var years: [Int] { Array(Set(rows.map(\.year))).sorted() }
}

enum GeoParseError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case .message(let s): return s
        }
    }
}

enum GeoDataParser {
    /// World Bank API v2 JSON: [meta, [records]] or [{"message": [...]}] on error.
    static func worldBank(_ data: Data, code: String) throws -> GeoIndicatorTable {
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [Any], let first = top.first else {
            throw GeoParseError.message("The World Bank returned something unexpected for \(code).")
        }
        if let meta = first as? [String: Any], let msg = meta["message"] as? [[String: Any]] {
            let text = msg.compactMap { $0["value"] as? String }.joined(separator: " ")
            throw GeoParseError.message("World Bank: \(text.isEmpty ? "unknown indicator" : text) (\(code)). Check the indicator code, e.g. SP.DYN.LE00.IN.")
        }
        guard top.count >= 2, let records = top[1] as? [[String: Any]] else {
            throw GeoParseError.message("The World Bank has no data for \(code).")
        }
        var title = code
        var rows: [GeoIndicatorTable.Row] = []
        for r in records {
            if let ind = r["indicator"] as? [String: Any], let v = ind["value"] as? String, !v.isEmpty { title = v }
            guard let iso = r["countryiso3code"] as? String, iso.count == 3,
                  let dateS = r["date"] as? String, let year = Int(dateS.prefix(4)),
                  let value = (r["value"] as? NSNumber)?.doubleValue, value.isFinite else { continue }
            let name = (r["country"] as? [String: Any])?["value"] as? String ?? iso
            rows.append(.init(code: iso, name: name, year: year, value: value))
        }
        var unit: String?
        // Titles end with the unit in brackets: "Life expectancy at birth, total (years)".
        if let open = title.lastIndex(of: "("), title.hasSuffix(")") {
            unit = String(title[title.index(after: open)..<title.index(before: title.endIndex)])
        }
        return GeoIndicatorTable(provider: .worldBank, code: code, title: title, unit: unit, citation: "World Bank, World Development Indicators", rows: rows)
    }

    /// Our World in Data grapher CSV (entity,code,year,<columns>) with its metadata JSON.
    static func owid(csv: String, metadata: Data?, slug: String, column: String? = nil) throws -> GeoIndicatorTable {
        let lines = parseCSV(csv)
        guard let header = lines.first, header.count >= 4,
              header[0].lowercased() == "entity", header[1].lowercased() == "code", header[2].lowercased() == "year" else {
            throw GeoParseError.message("Our World in Data has no chart '\(slug)' (or it isn't a country-by-year chart).")
        }
        var meta: [String: Any] = [:]
        if let metadata, let m = try? JSONSerialization.jsonObject(with: metadata) as? [String: Any] { meta = m }
        let columnsMeta = meta["columns"] as? [String: [String: Any]] ?? [:]
        // The chart's main indicator: the requested column, else the first numeric one.
        var col = -1
        if let column, let i = header.firstIndex(of: column) { col = i }
        if col < 0 {
            for i in 3..<header.count {
                let type = columnsMeta[header[i]]?["type"] as? String
                if header[i] == "owid_region" { continue }
                if type == nil || type == "Numeric" || type == "Integer" || type == "Ratio" { col = i; break }
            }
        }
        guard col >= 3 else { throw GeoParseError.message("Couldn't find a numeric column in '\(slug)'.") }
        let cm = columnsMeta[header[col]] ?? [:]
        let chart = meta["chart"] as? [String: Any] ?? [:]
        var title = (cm["titleShort"] as? String) ?? (chart["title"] as? String) ?? slug
        if title.isEmpty { title = slug }
        var unit = (cm["unit"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (cm["shortUnit"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if unit == "%" { unit = "%" }
        let citation = (chart["citation"] as? String) ?? (cm["citationShort"] as? String)
        var rows: [GeoIndicatorTable.Row] = []
        for r in lines.dropFirst() where r.count > col {
            var code = r[1]
            if code == "OWID_KOS" { code = "XKX" }
            guard code.count == 3, let year = Int(r[2]), let v = Double(r[col]), v.isFinite else { continue }
            rows.append(.init(code: code, name: r[0], year: year, value: v))
        }
        guard !rows.isEmpty else { throw GeoParseError.message("'\(slug)' has no country values.") }
        return GeoIndicatorTable(provider: .owid, code: slug, title: title, unit: unit, citation: citation, rows: rows)
    }

    /// RFC 4180 CSV (quoted fields, doubled quotes, CRLF).
    static func parseCSV(_ s: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var it = s.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil
        func next() -> Unicode.Scalar? {
            if let p = pending { pending = nil; return p }
            return it.next()
        }
        while let c = next() {
            if inQuotes {
                if c == "\"" {
                    if let n = next() {
                        if n == "\"" { field.unicodeScalars.append("\"") } else { inQuotes = false; pending = n }
                    } else { inQuotes = false }
                } else {
                    field.unicodeScalars.append(c)
                }
            } else if c == "\"" {
                inQuotes = true
            } else if c == "," {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r" {
                if c == "\r", let n = next(), n != "\n" { pending = n }
                row.append(field); field = ""
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
            } else {
                field.unicodeScalars.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}

/// Which year (or years) a map shows.
struct GeoYearChoice: Equatable {
    var values: [String: Double]
    var years: [String: Int]?
    /// "2023", or "latest available, 2014–2023".
    var label: String
    var year: Int?
}

enum GeoYearChooser {
    /// With a requested year, that year's values. Otherwise the latest year that has at least 85%
    /// of the best year's coverage; if that still leaves many countries out (survey data such as
    /// poverty or literacy), each country's latest value from the last ten years.
    static func choose(_ t: GeoIndicatorTable, validCodes: Set<String>, requestedYear: Int?, maxYear: Int) throws -> GeoYearChoice {
        let rows = t.rows.filter { validCodes.contains($0.code) && $0.year <= maxYear }
        guard !rows.isEmpty else { throw GeoParseError.message("\(t.title) has no values for countries on the map.") }
        var byYear: [Int: [String: Double]] = [:]
        for r in rows { byYear[r.year, default: [:]][r.code] = r.value }
        if let y = requestedYear {
            guard let v = byYear[y], !v.isEmpty else {
                let ys = byYear.keys.sorted()
                let good = ys.filter { (byYear[$0]?.count ?? 0) >= 20 }
                throw GeoParseError.message("\(t.title) has no data for \(y). Years with data: \(range(good.isEmpty ? ys : good)).")
            }
            return GeoYearChoice(values: v, years: nil, label: String(y), year: y)
        }
        let maxCount = byYear.values.map(\.count).max() ?? 0
        let best = byYear.keys.sorted().last { (byYear[$0]?.count ?? 0) >= Int((Double(maxCount) * 0.85).rounded(.up)) } ?? byYear.keys.max()!
        let recentCodes = Set(rows.filter { $0.year >= best - 10 }.map(\.code))
        let single = byYear[best] ?? [:]
        if Double(single.count) >= 0.7 * Double(recentCodes.count) {
            return GeoYearChoice(values: single, years: nil, label: String(best), year: best)
        }
        var latest: [String: (Int, Double)] = [:]
        let newest = byYear.keys.max()!
        for r in rows where r.year >= newest - 10 {
            if let cur = latest[r.code], cur.0 >= r.year { continue }
            latest[r.code] = (r.year, r.value)
        }
        let ys = latest.values.map(\.0)
        let label = "latest available, \(ys.min() ?? newest)–\(ys.max() ?? newest)"
        return GeoYearChoice(values: latest.mapValues(\.1), years: latest.mapValues(\.0), label: label, year: nil)
    }

    static func range(_ years: [Int]) -> String {
        guard let a = years.first, let b = years.last else { return "none" }
        return a == b ? String(a) : "\(a)–\(b)"
    }
}

/// Colour ramps (after ColorBrewer, Apache 2.0).
enum GeoPalette {
    static let ramps: [String: [String]] = [
        "blues": ["#EFF3FF", "#C6DBEF", "#9ECAE1", "#6BAED6", "#4292C6", "#2171B5", "#084594"],
        "greens": ["#EDF8E9", "#C7E9C0", "#A1D99B", "#74C476", "#41AB5D", "#238B45", "#005A32"],
        "oranges": ["#FEEDDE", "#FDD0A2", "#FDAE6B", "#FD8D3C", "#F16913", "#D94801", "#8C2D04"],
        "reds": ["#FEE5D9", "#FCBBA1", "#FC9272", "#FB6A4A", "#EF3B2C", "#CB181D", "#99000D"],
        "purples": ["#F2F0F7", "#DADAEB", "#BCBDDC", "#9E9AC8", "#807DBA", "#6A51A3", "#4A1486"],
        "ylgnbu": ["#FFFFCC", "#C7E9B4", "#7FCDBB", "#41B6C4", "#1D91C0", "#225EA8", "#0C2C84"],
        "ylorrd": ["#FFFFB2", "#FED976", "#FEB24C", "#FD8D3C", "#FC4E2A", "#E31A1C", "#B10026"],
        "ylgn": ["#FFFFCC", "#D9F0A3", "#ADDD8E", "#78C679", "#41AB5D", "#238443", "#005A32"],
        "rdbu": ["#B2182B", "#EF8A62", "#FDDBC7", "#F7F7F7", "#D1E5F0", "#67A9CF", "#2166AC"],
        "brbg": ["#8C510A", "#D8B365", "#F6E8C3", "#F5F5F5", "#C7EAE5", "#5AB4AC", "#01665E"],
    ]

    static var names: [String] { ramps.keys.sorted() }

    /// `count` colours spread across a ramp (light to dark; diverging ramps low to high).
    static func colors(_ name: String, count: Int) -> [String] {
        let ramp = ramps[name] ?? ramps["blues"]!
        guard count > 1 else { return [ramp[ramp.count / 2]] }
        return (0..<count).map { i in ramp[Int((Double(i) * Double(ramp.count - 1) / Double(count - 1)).rounded())] }
    }

    /// Diverging colours for classes split around zero: `below` classes under 0, `above` over it.
    static func diverging(_ name: String, below: Int, above: Int) -> [String] {
        let ramp = ramps[name] ?? ramps["rdbu"]!
        let mid = ramp.count / 2
        func side(_ n: Int, from: Int, to: Int) -> [String] {
            guard n > 0 else { return [] }
            if n == 1 { return [ramp[(from + to) / 2]] }
            return (0..<n).map { i in ramp[from + Int((Double(i) * Double(to - from) / Double(n - 1)).rounded())] }
        }
        return side(below, from: 0, to: mid - 1) + side(above, from: mid + 1, to: ramp.count - 1)
    }
}

enum GeoBinning {
    /// Rounds to two significant figures (37.4 → 37, 1234 → 1200, 0.0456 → 0.046).
    static func round2(_ v: Double) -> Double {
        guard v != 0, v.isFinite else { return 0 }
        let mag = pow(10, floor(log10(abs(v))) - 1)
        return (v / mag).rounded() * mag
    }

    /// Class breaks at quantiles, rounded to two significant figures (so each class holds
    /// roughly the same number of countries), with duplicates removed.
    static func quantileBreaks(_ values: [Double], classes: Int) -> [Double] {
        let v = values.filter(\.isFinite).sorted()
        guard v.count >= 2, classes >= 2 else { return [] }
        var out: [Double] = []
        for i in 1..<classes {
            let q = Double(i) / Double(classes)
            let pos = q * Double(v.count - 1)
            let lo = Int(floor(pos)), hi = min(v.count - 1, lo + 1)
            let x = v[lo] + (v[hi] - v[lo]) * (pos - Double(lo))
            let r = round2(x)
            if r > (out.last ?? -Double.infinity) && r > v.first! && r <= v.last! { out.append(r) }
        }
        return out
    }

    /// Breaks for a dataset: quantiles, or for diverging data quantiles on each side of zero.
    static func breaks(_ values: [Double], classes: Int = 6, diverging: Bool) -> (breaks: [Double], below: Int) {
        guard diverging else { return (quantileBreaks(values, classes: classes), 0) }
        let neg = values.filter { $0 < 0 }, pos = values.filter { $0 >= 0 }
        let nNeg = neg.isEmpty ? 0 : max(1, min(classes - 1, Int((Double(classes) * Double(neg.count) / Double(max(1, values.count))).rounded())))
        let nPos = max(1, classes - nNeg)
        var b: [Double] = []
        if nNeg > 0 {
            b += quantileBreaks(neg, classes: nNeg).filter { $0 < 0 }
            b.append(0)
        }
        b += quantileBreaks(pos, classes: nPos).filter { $0 > 0 }
        let below = b.filter { $0 <= 0 }.count
        return (b, below)
    }

    /// Builds the choropleth classes for a set of values.
    static func choropleth(values: [String: Double], palette: String, diverging: Bool, classes: Int = 6)
        -> (breaks: [Double], colors: [String]) {
        let (b, below) = breaks(Array(values.values), classes: classes, diverging: diverging)
        let colors: [String]
        if diverging && b.contains(0) {
            colors = GeoPalette.diverging(palette, below: below, above: b.count + 1 - below)
        } else {
            colors = GeoPalette.colors(diverging ? "blues" : palette, count: b.count + 1)
        }
        return (b, colors)
    }

    /// Legend text for each class: "< 10", "10–50", "≥ 500".
    static func labels(_ breaks: [Double]) -> [String] {
        guard !breaks.isEmpty else { return ["All values"] }
        var out = ["< " + GeoFormat.short(breaks[0])]
        for i in 1..<max(1, breaks.count) where breaks.count > 1 {
            out.append(GeoFormat.short(breaks[i - 1]) + " – " + GeoFormat.short(breaks[i]))
        }
        out.append("≥ " + GeoFormat.short(breaks[breaks.count - 1]))
        return out
    }
}

/// What the tutor is told about a data map.
enum GeoDataSummary {
    static func text(values: [String: Double], names: [String: String], unit: String?, highlight: String = "AUS", count: Int = 5) -> String {
        let sorted = values.sorted { $0.value > $1.value }
        guard !sorted.isEmpty else { return "No countries have data." }
        func item(_ kv: (key: String, value: Double)) -> String { "\(names[kv.key] ?? kv.key) \(GeoFormat.value(kv.value))" }
        var s = "\(sorted.count) countries with data"
        if let u = unit, !u.isEmpty { s += " (\(u))" }
        s += ". Highest: " + sorted.prefix(count).map(item).joined(separator: ", ")
        s += ". Lowest: " + sorted.suffix(count).reversed().map(item).joined(separator: ", ")
        let vals = sorted.map(\.value).sorted()
        let median = vals.count % 2 == 1 ? vals[vals.count / 2] : (vals[vals.count / 2 - 1] + vals[vals.count / 2]) / 2
        s += ". Median \(GeoFormat.value(median))"
        if let i = sorted.firstIndex(where: { $0.key == highlight }) {
            s += ". \(names[highlight] ?? highlight): \(GeoFormat.value(sorted[i].value)) (rank \(i + 1) of \(sorted.count), highest first)"
        } else {
            s += ". \(names[highlight] ?? highlight): no data"
        }
        return s + "."
    }
}
