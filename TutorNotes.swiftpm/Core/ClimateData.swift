import Foundation

/// A place found by the Open-Meteo geocoding API.
struct ClimatePlace: Equatable {
    var name: String
    var lat: Double
    var lon: Double
    var country: String?
    var countryCode: String?
    var admin1: String?
    var elevation: Double?
    var population: Int?

    /// "Dubbo, New South Wales, Australia".
    var displayName: String {
        var parts = [name]
        if let a = admin1, !a.isEmpty, a != name { parts.append(a) }
        if let c = country, !c.isEmpty { parts.append(c) }
        return parts.joined(separator: ", ")
    }

    /// "Dubbo, NSW" for Australian places, "Lagos, Nigeria" elsewhere.
    var shortName: String {
        if countryCode == "AU", let a = admin1, let abbr = ClimatePlace.auStates[a] { return "\(name), \(abbr)" }
        if let c = country, !c.isEmpty, c != name { return "\(name), \(c)" }
        return name
    }

    static let auStates = ["New South Wales": "NSW", "Victoria": "Vic.", "Queensland": "Qld", "South Australia": "SA",
                           "Western Australia": "WA", "Tasmania": "Tas.", "Northern Territory": "NT", "Australian Capital Territory": "ACT"]

    var coordinateText: String {
        "\(GeoFormat.trim(abs(lat), 1))°\(lat >= 0 ? "N" : "S") \(GeoFormat.trim(abs(lon), 1))°\(lon >= 0 ? "E" : "W")"
    }
}

/// Monthly climate averages (January…December).
struct ClimateNormals: Equatable {
    var place: ClimatePlace
    var startYear: Int
    var endYear: Int
    /// Mean daily temperature per month (°C).
    var temp: [Double]
    var tempMax: [Double]?
    var tempMin: [Double]?
    /// Mean monthly rainfall total (mm).
    var rain: [Double]

    var annualRain: Double { rain.reduce(0, +) }
    var annualMeanTemp: Double {
        let days = [31.0, 28.25, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return zip(temp, days).map { $0 * $1 }.reduce(0, +) / days.reduce(0, +)
    }
    var tempRange: Double { (temp.max() ?? 0) - (temp.min() ?? 0) }
    var wettestMonth: Int { rain.indices.max { rain[$0] < rain[$1] } ?? 0 }
    var driestMonth: Int { rain.indices.min { rain[$0] < rain[$1] } ?? 0 }
    var warmestMonth: Int { temp.indices.max { temp[$0] < temp[$1] } ?? 0 }
    var coolestMonth: Int { temp.indices.min { temp[$0] < temp[$1] } ?? 0 }
}

enum ClimateData {
    static let monthInitials = ["J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D"]
    static let monthNames = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
    static let monthShort = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    static let startYear = 1991
    static let endYear = 2020

    /// `countryCode` (ISO 3166-1 alpha-2) limits results to one country.
    static func geocodingURL(_ name: String, count: Int = 8, countryCode: String? = nil) -> URL? {
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")
        var items = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "count", value: String(count)),
                     URLQueryItem(name: "language", value: "en"), URLQueryItem(name: "format", value: "json")]
        if let cc = countryCode, cc.count == 2 { items.append(URLQueryItem(name: "countryCode", value: cc.uppercased())) }
        c?.queryItems = items
        return c?.url
    }

    /// Whether a place matches a qualifier such as "NSW", "Queensland", "Nigeria" or "NG".
    static func matches(_ r: ClimatePlace, qualifier: String) -> Bool {
        let n = GeoCodec.normalize(qualifier)
        if [r.admin1, r.country, r.countryCode].compactMap({ $0 }).contains(where: { GeoCodec.normalize($0) == n }) { return true }
        if let a = r.admin1, let abbr = ClimatePlace.auStates[a], GeoCodec.normalize(abbr) == n { return true }
        if r.countryCode == "AU" && ["australia", "aus", "au"].contains(n) { return true }
        return false
    }

    /// AU for Australian state names and abbreviations.
    static func australianQualifier(_ q: String) -> Bool {
        let n = GeoCodec.normalize(q)
        let names = ClimatePlace.auStates.keys.map(GeoCodec.normalize) + ClimatePlace.auStates.values.map(GeoCodec.normalize)
        return names.contains(n) || ["nsw", "qld", "vic", "tas", "nt", "act", "sa", "wa", "australia"].contains(n)
    }

    /// 30 years of daily ERA5 data (about 360 KB, usually 1–2 s).
    static func archiveURL(lat: Double, lon: Double) -> URL? {
        var c = URLComponents(string: "https://archive-api.open-meteo.com/v1/archive")
        c?.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", lat)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", lon)),
            URLQueryItem(name: "start_date", value: "\(startYear)-01-01"),
            URLQueryItem(name: "end_date", value: "\(endYear)-12-31"),
            URLQueryItem(name: "daily", value: "temperature_2m_mean,temperature_2m_max,temperature_2m_min,precipitation_sum"),
            URLQueryItem(name: "models", value: "era5"),
            URLQueryItem(name: "timezone", value: "GMT"),
        ]
        return c?.url
    }

    static func parseGeocoding(_ data: Data) throws -> [ClimatePlace] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeoParseError.message("The place search returned something unexpected.")
        }
        if obj["error"] as? Bool == true { throw GeoParseError.message("Place search: \(obj["reason"] as? String ?? "error")") }
        let results = obj["results"] as? [[String: Any]] ?? []
        return results.compactMap { r in
            guard let name = r["name"] as? String, let lat = (r["latitude"] as? NSNumber)?.doubleValue,
                  let lon = (r["longitude"] as? NSNumber)?.doubleValue else { return nil }
            return ClimatePlace(name: name, lat: lat, lon: lon, country: r["country"] as? String, countryCode: r["country_code"] as? String,
                                admin1: r["admin1"] as? String, elevation: (r["elevation"] as? NSNumber)?.doubleValue,
                                population: (r["population"] as? NSNumber)?.intValue)
        }
    }

    /// Monthly normals from Open-Meteo's daily archive: the mean of each year's monthly mean
    /// temperature and of each year's monthly rainfall total (months missing more than a fifth of
    /// their days are skipped), as in WMO climate normals.
    static func normals(fromArchive data: Data, place: ClimatePlace) throws -> ClimateNormals {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeoParseError.message("The climate archive returned something unexpected.")
        }
        if obj["error"] as? Bool == true { throw GeoParseError.message("Climate archive: \(obj["reason"] as? String ?? "error")") }
        guard let daily = obj["daily"] as? [String: Any], let time = daily["time"] as? [String] else {
            throw GeoParseError.message("The climate archive has no daily data for this place.")
        }
        func series(_ k: String) -> [Double?] {
            (daily[k] as? [Any] ?? []).map { ($0 as? NSNumber)?.doubleValue }
        }
        var p = place
        if let e = (obj["elevation"] as? NSNumber)?.doubleValue, p.elevation == nil { p.elevation = e }
        return try normals(dates: time, temp: series("temperature_2m_mean"), tempMax: series("temperature_2m_max"),
                           tempMin: series("temperature_2m_min"), rain: series("precipitation_sum"), place: p)
    }

    static func normals(dates: [String], temp: [Double?], tempMax: [Double?], tempMin: [Double?], rain: [Double?], place: ClimatePlace) throws -> ClimateNormals {
        // key = year * 12 + month0
        struct Acc { var sum = 0.0; var n = 0; var days = 0 }
        var t: [Int: Acc] = [:], tx: [Int: Acc] = [:], tn: [Int: Acc] = [:], r: [Int: Acc] = [:]
        var years = Set<Int>()
        for (i, d) in dates.enumerated() {
            let parts = d.split(separator: "-")
            guard parts.count >= 2, let y = Int(parts[0]), let m = Int(parts[1]), m >= 1, m <= 12 else { continue }
            let key = y * 12 + (m - 1)
            years.insert(y)
            for (store, arr) in [(0, temp), (1, tempMax), (2, tempMin), (3, rain)] {
                var acc: Acc
                switch store {
                case 0: acc = t[key] ?? Acc()
                case 1: acc = tx[key] ?? Acc()
                case 2: acc = tn[key] ?? Acc()
                default: acc = r[key] ?? Acc()
                }
                acc.days += 1
                if i < arr.count, let v = arr[i], v.isFinite { acc.sum += v; acc.n += 1 }
                switch store {
                case 0: t[key] = acc
                case 1: tx[key] = acc
                case 2: tn[key] = acc
                default: r[key] = acc
                }
            }
        }
        func monthly(_ accs: [Int: Acc], total: Bool) -> [Double]? {
            var out: [Double] = []
            for m in 0..<12 {
                var vals: [Double] = []
                for y in years {
                    guard let a = accs[y * 12 + m], a.days > 0, Double(a.n) >= 0.8 * Double(a.days) else { continue }
                    vals.append(total ? a.sum * Double(a.days) / Double(a.n) : a.sum / Double(a.n))
                }
                guard !vals.isEmpty else { return nil }
                out.append(vals.reduce(0, +) / Double(vals.count))
            }
            return out
        }
        guard let temps = monthly(t, total: false), let rains = monthly(r, total: true) else {
            throw GeoParseError.message("Not enough climate data for \(place.name) (the archive had gaps).")
        }
        return ClimateNormals(place: place, startYear: years.min() ?? startYear, endYear: years.max() ?? endYear,
                              temp: temps, tempMax: monthly(tx, total: false), tempMin: monthly(tn, total: false), rain: rains)
    }

    static let caption = "Source: ERA5 reanalysis (Copernicus/ECMWF) via Open-Meteo, 1991–2020 average"

    /// The standard climate graph: rainfall columns (right axis, mm) and the mean temperature
    /// line (left axis, °C), with mean daily maximum and minimum as thin dashed lines.
    static func chart(_ n: ClimateNormals, title: String? = nil, showMaxMin: Bool = true) -> ChartContent {
        var series = [ChartSeries(name: "Rainfall (mm)", values: n.rain.map { $0 }, colorHex: ChartPalette.rain, axis: "right", style: "bar"),
                      ChartSeries(name: "Mean temperature (°C)", values: n.temp.map { $0 }, colorHex: ChartPalette.temp, axis: "left", style: "line")]
        if showMaxMin, let mx = n.tempMax, let mn = n.tempMin {
            series.append(ChartSeries(name: "Mean max (°C)", values: mx.map { $0 }, colorHex: "#F08C00", axis: "left", style: "dashed"))
            series.append(ChartSeries(name: "Mean min (°C)", values: mn.map { $0 }, colorHex: "#7048E8", axis: "left", style: "dashed"))
        }
        var sub = "\(n.place.coordinateText)"
        if let e = n.place.elevation { sub += " · \(Int(e.rounded())) m above sea level" }
        let note = "Annual rainfall \(GeoFormat.grouped(n.annualRain)) mm · Mean temperature \(GeoFormat.trim(n.annualMeanTemp, 1)) °C · Range \(GeoFormat.trim(n.tempRange, 1)) °C"
        return ChartContent(title: title ?? "Climate graph: \(n.place.shortName)", source: caption, kind: ChartKind.climate.rawValue,
                            categories: monthInitials, series: series, xLabel: "Month", yLabel: "Temperature (°C)",
                            y2Label: "Rainfall (mm)", subtitle: sub, note: note)
    }

    /// What the tutor is told: every monthly value, so it can discuss the graph.
    static func summary(_ n: ClimateNormals) -> String {
        func list(_ v: [Double], _ d: Int) -> String { zip(monthShort, v).map { "\($0) \(GeoFormat.trim($1, d))" }.joined(separator: ", ") }
        var s = "\(n.place.displayName) (\(n.place.coordinateText)"
        if let e = n.place.elevation { s += ", \(Int(e.rounded())) m" }
        s += "), ERA5 \(n.startYear)–\(n.endYear) averages. "
        s += "Mean temperature °C: \(list(n.temp, 1)). "
        if let mx = n.tempMax, let mn = n.tempMin {
            s += "Mean daily max °C: \(list(mx, 1)). Mean daily min °C: \(list(mn, 1)). "
        }
        s += "Rainfall mm: \(list(n.rain, 0)). "
        s += "Annual rainfall \(GeoFormat.grouped(n.annualRain)) mm (wettest \(monthNames[n.wettestMonth]) \(Int(n.rain[n.wettestMonth].rounded())) mm, driest \(monthNames[n.driestMonth]) \(Int(n.rain[n.driestMonth].rounded())) mm). "
        s += "Annual mean temperature \(GeoFormat.trim(n.annualMeanTemp, 1)) °C; warmest month \(monthNames[n.warmestMonth]) \(GeoFormat.trim(n.temp[n.warmestMonth], 1)) °C, coolest \(monthNames[n.coolestMonth]) \(GeoFormat.trim(n.temp[n.coolestMonth], 1)) °C; annual temperature range \(GeoFormat.trim(n.tempRange, 1)) °C."
        return s
    }
}
