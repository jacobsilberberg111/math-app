import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A data download or lookup that failed, with a message fit for the student or the tutor.
struct GeoServiceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Downloads for maps, charts and climate graphs: World Bank indicators, Our World in Data
/// charts, Open-Meteo place search and ERA5 climate. Responses are cached in memory and in the
/// Caches folder. Requests carry a generic User-Agent and nothing about the student.
actor GeoDataService {
    static let shared = GeoDataService()

    private var memory: [String: Data] = [:]
    private var memoryOrder: [String] = []
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.httpAdditionalHeaders = ["User-Agent": "Margin/1.0 (iPad study app)"]
        session = URLSession(configuration: config)
    }

    static var currentYear: Int { Calendar(identifier: .gregorian).component(.year, from: Date()) }

    // MARK: Fetching

    /// GET with a retry on network errors; falls back to an expired cached copy when offline.
    func fetch(_ url: URL, maxAge: TimeInterval, label: String, timeout: TimeInterval = 20, attempts: Int = 2) async throws -> Data {
        let key = url.absoluteString
        if let d = memory[key] { return d }
        if let d = diskRead(key, maxAge: maxAge) {
            remember(key, d)
            return d
        }
        var lastError: Error?
        var statusText: String?
        for attempt in 0..<max(1, attempts) {
            try Task.checkCancellation()
            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = timeout
                let (data, resp) = try await session.data(for: req)
                if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    if http.statusCode == 404 { throw GeoServiceError(message: "\(label): not found.") }
                    statusText = "it answered with an error (HTTP \(http.statusCode))"
                    if attempt + 1 < attempts { try? await Task.sleep(nanoseconds: 700_000_000) }
                    continue
                }
                remember(key, data)
                diskWrite(key, data)
                return data
            } catch let e as GeoServiceError {
                throw e
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                lastError = error
                statusText = nil
                if attempt + 1 < attempts { try? await Task.sleep(nanoseconds: 500_000_000) }
            }
        }
        if let stale = diskRead(key, maxAge: .infinity) { return stale }
        let reason = statusText ?? ((lastError as? URLError)?.code == .timedOut ? "it took too long to answer" : (lastError?.localizedDescription ?? "no connection"))
        throw GeoServiceError(message: "Couldn't get data from \(label): \(reason). Try again in a minute, or check the internet connection.")
    }

    private func remember(_ key: String, _ data: Data) {
        if memory[key] == nil { memoryOrder.append(key) }
        memory[key] = data
        while memoryOrder.count > 8 {
            memory[memoryOrder.removeFirst()] = nil
        }
    }

    private static func fileName(_ key: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in key.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return String(format: "%016llx.dat", h)
    }

    private var cacheDir: URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("GeoData", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func diskRead(_ key: String, maxAge: TimeInterval) -> Data? {
        guard let dir = cacheDir else { return nil }
        let url = dir.appendingPathComponent(GeoDataService.fileName(key))
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date, Date().timeIntervalSince(date) < maxAge else { return nil }
        return try? Data(contentsOf: url)
    }

    private func diskWrite(_ key: String, _ data: Data) {
        guard let dir = cacheDir else { return }
        try? data.write(to: dir.appendingPathComponent(GeoDataService.fileName(key)), options: .atomic)
    }

    // MARK: Datasets

    static func worldBankURL(code: String, countries: String = "all", from: Int, to: Int, perPage: Int = 20000) -> URL? {
        guard let enc = code.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://api.worldbank.org/v2/country/\(countries)/indicator/\(enc)?format=json&per_page=\(perPage)&date=\(from):\(to)")
    }

    static func owidURLs(slug: String) -> (csv: URL, meta: URL)? {
        guard GeoCatalog.isSlug(slug),
              let csv = URL(string: "https://ourworldindata.org/grapher/\(slug).csv?v=1&csvType=full&useColumnShortNames=true"),
              let meta = URL(string: "https://ourworldindata.org/grapher/\(slug).metadata.json?v=1&csvType=full&useColumnShortNames=true") else { return nil }
        return (csv, meta)
    }

    /// Every country's values for a dataset (recent years, or the requested one). When the World
    /// Bank API fails, tries its most-recent-value query, then the dataset's Our World in Data
    /// equivalent (the returned table's provider says which source answered).
    func indicator(_ d: GeoDataset, requestedYear: Int?) async throws -> GeoIndicatorTable {
        switch d.provider {
        case .worldBank:
            let to = GeoDataService.currentYear
            let from = requestedYear.map { min($0, to - 15) } ?? to - 15
            guard let url = GeoDataService.worldBankURL(code: d.code, from: from, to: requestedYear.map { max($0, from) } ?? to) else {
                throw GeoServiceError(message: "'\(d.code)' isn't a valid World Bank indicator code.")
            }
            let primary: Data
            do {
                // The World Bank API sometimes stalls or answers 502: try once, then fall back.
                primary = try await fetch(url, maxAge: 7 * 86_400, label: "the World Bank", timeout: 15, attempts: 1)
            } catch let first {
                if first is CancellationError { throw first }
                // Partial outages: the latest-value query is often still served.
                if requestedYear == nil, let enc = d.code.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                   let latest = URL(string: "https://api.worldbank.org/v2/country/all/indicator/\(enc)?format=json&per_page=20000&mrnev=1"),
                   let data = try? await fetch(latest, maxAge: 7 * 86_400, label: "the World Bank", timeout: 12, attempts: 1),
                   let t = try? GeoDataParser.worldBank(data, code: d.code), !t.rows.isEmpty {
                    return t
                }
                if let slug = d.fallback {
                    return try await owidTable(slug)
                }
                throw first
            }
            do { return try GeoDataParser.worldBank(primary, code: d.code) } catch { throw GeoServiceError(message: "\(error)") }
        case .owid:
            return try await owidTable(d.code)
        }
    }

    private func owidTable(_ slug: String) async throws -> GeoIndicatorTable {
        guard let urls = GeoDataService.owidURLs(slug: slug) else { throw GeoServiceError(message: "'\(slug)' isn't a valid Our World in Data chart name.") }
        let csvData: Data
        do {
            csvData = try await fetch(urls.csv, maxAge: 7 * 86_400, label: "Our World in Data")
        } catch let e as GeoServiceError where e.message.contains("not found") {
            throw GeoServiceError(message: "Our World in Data has no chart called '\(slug)'. Use the slug from a grapher URL, e.g. 'life-expectancy' from ourworldindata.org/grapher/life-expectancy.")
        }
        let meta = try? await fetch(urls.meta, maxAge: 7 * 86_400, label: "Our World in Data")
        guard let csv = String(data: csvData, encoding: .utf8) else { throw GeoServiceError(message: "Our World in Data sent unreadable data for '\(slug)'.") }
        do { return try GeoDataParser.owid(csv: csv, metadata: meta, slug: slug) } catch { throw GeoServiceError(message: "\(error)") }
    }

    /// A few countries' values over time.
    func timeSeries(_ d: GeoDataset, countries: [String], from: Int, to: Int) async throws -> GeoIndicatorTable {
        func owid(_ slug: String) async throws -> GeoIndicatorTable {
            var t = try await owidTable(slug)
            let set = Set(countries)
            t.rows = t.rows.filter { set.contains($0.code) && $0.year >= from && $0.year <= to }
            return t
        }
        switch d.provider {
        case .worldBank:
            guard let url = GeoDataService.worldBankURL(code: d.code, countries: countries.joined(separator: ";"), from: from, to: to, perPage: 5000) else {
                throw GeoServiceError(message: "'\(d.code)' isn't a valid World Bank indicator code.")
            }
            do {
                let data = try await fetch(url, maxAge: 7 * 86_400, label: "the World Bank", timeout: 15, attempts: 1)
                do { return try GeoDataParser.worldBank(data, code: d.code) } catch { throw GeoServiceError(message: "\(error)") }
            } catch {
                if error is CancellationError { throw error }
                if let slug = d.fallback, (error as? GeoServiceError)?.message.hasPrefix("World Bank:") != true { return try await owid(slug) }
                throw error
            }
        case .owid:
            return try await owid(d.code)
        }
    }

    // MARK: Places and climate

    func geocode(_ name: String, count: Int = 10, countryCode: String? = nil) async throws -> [ClimatePlace] {
        guard let url = ClimateData.geocodingURL(name, count: count, countryCode: countryCode) else { throw GeoServiceError(message: "Couldn't search for '\(name)'.") }
        let data = try await fetch(url, maxAge: 30 * 86_400, label: "the place search")
        do { return try ClimateData.parseGeocoding(data) } catch { throw GeoServiceError(message: "\(error)") }
    }

    /// 1991–2020 monthly normals from 30 years of daily ERA5 data (about 360 KB, usually 1–2 s).
    func climateNormals(_ place: ClimatePlace) async throws -> ClimateNormals {
        guard let url = ClimateData.archiveURL(lat: place.lat, lon: place.lon) else { throw GeoServiceError(message: "Bad coordinates.") }
        let data = try await fetch(url, maxAge: 180 * 86_400, label: "the climate archive (Open-Meteo)")
        do { return try ClimateData.normals(fromArchive: data, place: place) } catch { throw GeoServiceError(message: "\(error)") }
    }
}

/// Builds map content from a request: shared by the `map` tool and the Insert → Map sheet.
enum GeoMapBuilder {
    struct Region {
        var name: String
        var bbox: GeoBBox?
        var centralLon: Double
    }

    static var presetList: String { MapRegionPreset.all.map(\.id).joined(separator: ", ") }

    /// A preset, a country or Australian state (zoomed to it), or a lon/lat box.
    static func region(_ query: String?, bbox: [Double]?, world: GeoWorld) throws -> Region {
        if let b = bbox, !b.isEmpty {
            guard b.count == 4, b.allSatisfy(\.isFinite) else { throw GeoServiceError(message: "bbox needs four numbers: [west, south, east, north] in degrees.") }
            var (w, s, e, n) = (b[0], b[1], b[2], b[3])
            guard s < n, s >= -90, n <= 90, w >= -360, e <= 540 else { throw GeoServiceError(message: "bbox must be [west, south, east, north] with south < north (latitudes −90…90).") }
            if e <= w { e += 360 }
            guard e - w <= 360, e - w >= 0.5, n - s >= 0.5 else { throw GeoServiceError(message: "bbox must span at least 0.5° and at most 360°.") }
            if w < -180 { w += 360; e += 360 }
            let box = GeoBBox(west: w, south: s, east: e, north: n)
            return Region(name: query ?? "\(GeoNice.lonLabel(w))–\(GeoNice.lonLabel(e)), \(GeoNice.latLabel(s))–\(GeoNice.latLabel(n))", bbox: box, centralLon: box.centerLon)
        }
        guard let q = query?.trimmingCharacters(in: .whitespaces), !q.isEmpty else { return Region(name: "World", bbox: nil, centralLon: 0) }
        if let p = MapRegionPreset.find(q) { return Region(name: p.name, bbox: p.bbox, centralLon: p.centralLon) }
        if let s = world.state(q), let b = GeoGeometry.bbox(s.rings) {
            return Region(name: s.name, bbox: padded(b), centralLon: b.centerLon)
        }
        if let c = world.country(q) { return Region(name: c.name, bbox: padded(c.focus), centralLon: c.focus.centerLon) }
        throw GeoServiceError(message: "Unknown region '\(q)'. Use one of: \(presetList); or a country name (e.g. Indonesia), an Australian state (e.g. NSW); or bbox [west, south, east, north].")
    }

    static func padded(_ b: GeoBBox) -> GeoBBox {
        let f = max(0.12, 3 / max(1, max(b.width, b.height)))
        return b.expanded(byFraction: min(0.4, f), minDegrees: 0.8)
    }

    /// Fetches a dataset and turns it into choropleth classes, a caption and a summary.
    static func choropleth(_ d: GeoDataset, year: Int?, world: GeoWorld) async throws -> (MapChoropleth, caption: String, summary: String) {
        let table = try await GeoDataService.shared.indicator(d, requestedYear: year)
        let valid = Set(world.countries.map(\.code))
        // Our World in Data mixes projections into some series: only use past years.
        let maxYear = GeoDataService.currentYear - (table.provider == .owid ? 1 : 0)
        let choice: GeoYearChoice
        do { choice = try GeoYearChooser.choose(table, validCodes: valid, requestedYear: year, maxYear: maxYear) } catch { throw GeoServiceError(message: "\(error)") }
        var values = choice.values
        let lo = values.values.min() ?? 0, hi = values.values.max() ?? 0
        let known = GeoCatalog.datasets.contains { $0.id == d.id }
        // The World Bank was down and the Our World in Data equivalent answered instead.
        let usedFallback = table.provider != d.provider
        let diverging = known ? d.diverging : (lo < 0 && hi > 0)
        let palette = known ? d.palette : (diverging ? "rdbu" : "blues")
        let bins = GeoBinning.choropleth(values: values, palette: palette, diverging: diverging)
        var names: [String: String] = [:]
        for code in values.keys { names[code] = world.country(code: code)?.longName ?? code }
        var indicator = known && !usedFallback ? d.title : table.title
        var unit = known && !usedFallback ? d.unit : (table.unit ?? "")
        if !known || usedFallback, let open = indicator.lastIndex(of: "("), indicator.hasSuffix(")") {
            unit = String(indicator[indicator.index(after: open)..<indicator.index(before: indicator.endIndex)])
            indicator = String(indicator[..<open]).trimmingCharacters(in: .whitespaces)
        }
        var summary = GeoDataSummary.text(values: values, names: names, unit: unit.isEmpty ? nil : unit)
        if usedFallback { summary += " (The World Bank's service didn't respond, so this is Our World in Data's \"\(table.title)\", \(table.code); check its unit.)" }
        // Somaliland is mapped with Somalia's figures (the World Bank and OWID report them together).
        if let som = values["SOM"], values["SOL"] == nil { values["SOL"] = som }
        let caption: String
        switch table.provider {
        case .worldBank: caption = "Source: World Bank, World Development Indicators (\(choice.year.map { "\($0) data" } ?? choice.label))"
        case .owid: caption = "Source: Our World in Data\(table.citation.map { ", from \($0)" } ?? "") (\(choice.year.map { "\($0) data" } ?? choice.label))"
        }
        let ch = MapChoropleth(dataset: known ? d.id : nil, provider: table.provider.displayName, code: table.code, indicator: indicator,
                               unit: unit.isEmpty ? nil : unit, yearLabel: choice.label, values: values, years: choice.years,
                               breaks: bins.breaks, colors: bins.colors, diverging: diverging, citation: table.citation)
        return (ch, caption, summary)
    }

    /// Where a named place is: bundled cities and towns, Australian states, countries, then the
    /// Open-Meteo place search.
    static func locate(_ name: String, world: GeoWorld, places: GeoPlaces?) async throws -> (GeoPoint, String) {
        if let p = places?.find(name, world: world) { return (p.point, p.name) }
        if let s = world.state(name) { return (s.label, s.name) }
        if let c = world.country(name) { return (c.label, c.name) }
        if let r = try await searchPlaces(name).first { return (GeoPoint(lon: r.lon, lat: r.lat), r.name) }
        throw GeoServiceError(message: "Couldn't find '\(name)'. Add the state or country (e.g. 'Lagos, Nigeria') or give lat and lon.")
    }

    /// Place search for "Town", "Town, State" or "Town, Country": a state or country after the
    /// comma limits the search to that country and puts matching results first.
    static func searchPlaces(_ query: String, count: Int = 10) async throws -> [ClimatePlace] {
        let parts = query.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let name = parts.first ?? query
        let qualifier = parts.count > 1 ? parts[1] : nil
        var cc: String?
        if let q = qualifier {
            if ClimateData.australianQualifier(q) { cc = "AU" } else if let c = GeoAssets.world?.country(q) { cc = c.iso2 }
        }
        var results = try await GeoDataService.shared.geocode(name, count: count, countryCode: cc)
        if let q = qualifier {
            let hits = results.filter { ClimateData.matches($0, qualifier: q) }
            results = hits + results.filter { !ClimateData.matches($0, qualifier: q) }
        }
        return results
    }

    /// The place for a climate graph from a typed name ("Dubbo", "Cairns, QLD", "Lagos, Nigeria").
    static func climatePlace(_ query: String) async throws -> ClimatePlace {
        guard let r = try await searchPlaces(query).first else {
            throw GeoServiceError(message: "Couldn't find a place called '\(query)'. Check the spelling, add the state or country (e.g. 'Dubbo, NSW'), or give lat and lon.")
        }
        return r
    }
}
