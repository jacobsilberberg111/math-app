import UIKit

/// The `map`, `chart` and `climate_graph` tools: real geographic data fetched by the app (the
/// tutor picks datasets and places; it never supplies the statistics).
extension CanvasActionExecutor {
    private static let highlightColors = ["#F2C200", "#E8590C", "#2F9E44", "#7048E8", "#D6336C", "#0C8599"]

    private func geoError(_ e: Error) -> Error {
        if e is CancellationError || e is ToolInputError { return e }
        if let g = e as? GeoServiceError { return ToolInputError(message: g.message) }
        return ToolInputError(message: "\(e.localizedDescription)")
    }

    /// A {place} or {lat, lon} object (or a bare string) → point and display name.
    private func geoLocation(_ v: JSONValue, world: GeoWorld) async throws -> (GeoPoint, String?) {
        if let s = v.stringValue, !s.trimmed.isEmpty {
            let (p, name) = try await GeoMapBuilder.locate(s, world: world, places: GeoAssets.places)
            return (p, name)
        }
        if let lat = v["lat"]?.doubleValue, let lon = v["lon"]?.doubleValue {
            guard abs(lat) <= 90, abs(lon) <= 540 else { throw ToolInputError(message: "lat must be −90…90 and lon −180…180.") }
            var l = lon
            if l > 180 { l -= 360 }
            return (GeoPoint(lon: l, lat: lat), v["place"]?.stringValue)
        }
        if let s = v["place"]?.stringValue, !s.trimmed.isEmpty {
            let (p, name) = try await GeoMapBuilder.locate(s, world: world, places: GeoAssets.places)
            return (p, name)
        }
        throw ToolInputError(message: "Each marker or route point needs a place name or lat and lon.")
    }

    // MARK: map

    func mapTool(_ args: ToolArgs) async throws -> Outcome {
        guard let world = GeoAssets.world else { throw ToolInputError(message: "Map outlines aren't available in this build of the app.") }
        let page = try resolvePage(args.int("page"))
        var m = MapContent()
        m.title = args.string("title")
        m.subtitle = args.string("subtitle")

        let bbox = args.array("bbox").compactMap(\.doubleValue)
        let region: GeoMapBuilder.Region
        do { region = try GeoMapBuilder.region(args.string("region"), bbox: bbox.isEmpty ? nil : bbox, world: world) } catch { throw geoError(error) }
        m.region = region.name
        m.bbox = region.bbox
        if region.bbox == nil { m.centralLon = region.centralLon }
        if let p = args.string("projection") {
            guard MapProjectionKind(rawValue: p) != nil else { throw ToolInputError(message: "projection must be natural_earth, robinson or equirectangular.") }
            m.projection = p
        }

        let datasetArg = args.string("dataset")
        let layerArg = (args.string("layer") ?? (datasetArg != nil ? "data" : "political")).lowercased()
        let style: MapStyle
        switch layerArg {
        case "political", "countries": style = .political
        case "outline", "blank", "blank_outline": style = .outline
        case "climate", "climate_zones", "koppen", "köppen", "biomes": style = .climate
        case "data", "choropleth": style = .data
        default: throw ToolInputError(message: "layer must be political, outline, climate_zones or data.")
        }
        m.layer = style.rawValue
        m.labels = args.bool("labels")
        m.states = args.bool("states")
        m.graticule = args.bool("graticule")
        m.latitudeLines = args.bool("latitude_lines")
        m.rivers = args.bool("rivers")
        m.oceanLabels = args.bool("ocean_labels")
        if let d = args.string("climate_detail") {
            guard d == "full" || d == "groups" else { throw ToolInputError(message: "climate_detail must be full or groups.") }
            m.climateDetail = d
        }

        // Highlights: named places only (categories, not data).
        var highlights: [MapHighlight] = []
        for (i, h) in args.array("highlights").enumerated() {
            let names = (h["places"]?.arrayValue ?? []).compactMap(\.stringValue)
            guard !names.isEmpty else { throw ToolInputError(message: "Each highlight needs places: a list of countries or Australian states.") }
            var codes: [String] = []
            var unknown: [String] = []
            for n in names {
                if let s = world.state(n) { codes.append(s.id) } else if let c = world.country(n) { codes.append(c.code) } else { unknown.append(n) }
            }
            if !unknown.isEmpty {
                throw ToolInputError(message: "Unknown places in highlights: \(unknown.joined(separator: ", ")). Use country names or ISO3 codes (e.g. Indonesia, IDN) or Australian states (NSW, Victoria).")
            }
            let hex = color(h["color"]?.stringValue, default: CanvasActionExecutor.highlightColors[i % CanvasActionExecutor.highlightColors.count])
            highlights.append(MapHighlight(codes: codes, colorHex: hex, label: h["label"]?.stringValue))
        }
        if !highlights.isEmpty { m.highlights = highlights }

        var markerNotes: [String] = []
        do {
            var markers: [MapMarker] = []
            for mk in args.array("markers") {
                let (p, name) = try await geoLocation(mk, world: world)
                let label = mk["label"]?.stringValue ?? name
                markers.append(MapMarker(lon: p.lon, lat: p.lat, label: (label?.isEmpty ?? true) ? nil : label,
                                         colorHex: mk["color"]?.stringValue.map { color($0) }, symbol: mk["symbol"]?.stringValue))
            }
            if !markers.isEmpty { m.markers = markers }
            var routes: [MapRoute] = []
            for r in args.array("routes") {
                var pts: [GeoPoint] = []
                for stop in r["points"]?.arrayValue ?? [] { pts.append(try await geoLocation(stop, world: world).0) }
                guard pts.count >= 2 else { throw ToolInputError(message: "Each route needs at least two points.") }
                routes.append(MapRoute(points: pts, label: r["label"]?.stringValue, colorHex: r["color"]?.stringValue.map { color($0) },
                                       dashed: r["dashed"]?.boolValue, arrow: r["arrow"]?.boolValue, curved: r["curved"]?.boolValue))
            }
            if !routes.isEmpty { m.routes = routes }
        } catch { throw geoError(error) }

        // Data and captions.
        var dataSummary = ""
        switch style {
        case .data:
            guard let ds = datasetArg else { throw ToolInputError(message: "A data map needs a dataset (catalog id, worldbank:CODE or owid:slug).") }
            guard let dataset = GeoCatalog.resolve(ds) else {
                throw ToolInputError(message: "Unknown dataset '\(ds)'. Use a catalog id (e.g. life_expectancy, hdi, co2_per_capita), worldbank:CODE or owid:slug.")
            }
            do {
                let built = try await GeoMapBuilder.choropleth(dataset, year: args.int("year"), world: world)
                m.choropleth = built.0
                m.source = built.caption
                dataSummary = built.summary
            } catch { throw geoError(error) }
            if m.title == nil { m.title = "\(m.choropleth!.indicator), \(m.choropleth!.yearLabel)" }
        case .climate:
            m.source = "Source: Beck et al. (2023), Köppen–Geiger climate classification 1991–2020 (CC BY 4.0)"
            if m.title == nil { m.title = "Climate zones: \(region.name)" }
        case .political, .outline:
            m.source = "Source: Natural Earth (public domain)"
            if m.title == nil { m.title = region.name }
        }

        // Size: the region's natural shape plus the legend and footer.
        let width = min(area.width - 32, max(300, args.cg("width") ?? min(560, area.width - 80)))
        let height = args.cg("height").map { min(area.height - 40, max(220, $0)) }
            ?? MapRenderer.preferredSize(m, width: width, maxHeight: area.height - 40).height
        let requested = CGRect(x: args.cg("x") ?? area.midX - width / 2, y: args.cg("y") ?? area.minY + 80, width: width, height: height)
        let (frame, nudged) = layout.place(requested, page: page)
        let e = addTutorElement(page: page, frame: frame, kind: .map(m))

        // Tell the tutor what's where.
        var result = "Map \(e.id) on page \(page + 1) at \(describe(frame))\(nudged ? " (moved to free space)" : ""). "
        result += MapRenderer.tutorDescription(m, frame: frame)
        if !dataSummary.isEmpty { result += " Data: " + dataSummary }
        if let markers = m.markers, let koppen = GeoAssets.koppen {
            for mk in markers {
                let cls = Koppen.cls(koppen.classAt(lon: mk.lon, lat: mk.lat))
                markerNotes.append("\(mk.label ?? "marker") (\(GeoNice.latLabel((mk.lat * 100).rounded() / 100)), \(GeoNice.lonLabel((mk.lon * 100).rounded() / 100))\(cls.map { ", Köppen \($0.code) \($0.name)" } ?? ""))")
            }
            result += " Marker locations: " + markerNotes.joined(separator: "; ") + "."
        }
        if let scene = MapRenderer.cachedScene(for: m, size: frame.size)?.scene {
            let offMap = (m.markers?.count ?? 0) - scene.markers.count
            if offMap > 0 { result += " \(offMap) marker\(offMap == 1 ? " is" : "s are") outside the visible area." }
        }
        result += " Remember to point out the BOLTSS elements and describe the pattern (general trend, specific examples with data, anomalies)."
        return Outcome(result: result, isError: false,
                       action: ChatAction(symbol: "map", summary: m.title.map { "Map: \($0.truncated(40))" } ?? "Map on p.\(page + 1)", elementIDs: [e.id], page: page))
    }

    // MARK: chart

    func chartTool(_ args: ToolArgs) async throws -> Outcome {
        let page = try resolvePage(args.int("page"))
        let typeArg = (args.string("type") ?? "bar").lowercased()
        let aliases = ["column": "bar", "columns": "bar", "bar_horizontal": "horizontal_bar", "hbar": "horizontal_bar", "line_graph": "line", "climate_graph": "climate"]
        guard let kind = ChartKind(rawValue: aliases[typeArg] ?? typeArg) else {
            throw ToolInputError(message: "type must be bar, horizontal_bar, line, scatter, pie or climate.")
        }
        var c = ChartContent()
        c.kind = kind.rawValue
        c.title = args.string("title")
        c.subtitle = args.string("subtitle")
        c.xLabel = args.string("x_label")
        c.yLabel = args.string("y_label")
        c.y2Label = args.string("y2_label")
        c.bestFit = args.bool("best_fit")
        c.yMin = args.double("y_min")
        c.yMax = args.double("y_max")
        c.showValues = args.bool("show_values")
        if let lo = c.yMin, let hi = c.yMax, lo >= hi { throw ToolInputError(message: "y_min must be less than y_max.") }

        if let data = args.json["data"], data.objectValue != nil {
            // Real-world statistics: fetched, never typed.
            guard let ds = data["dataset"]?.stringValue, let dataset = GeoCatalog.resolve(ds) else {
                throw ToolInputError(message: "data.dataset must be a catalog id (e.g. life_expectancy), worldbank:CODE or owid:slug.")
            }
            guard let world = GeoAssets.world else { throw ToolInputError(message: "Country data isn't available in this build.") }
            let names = (data["countries"]?.arrayValue ?? []).compactMap(\.stringValue)
            guard (1...6).contains(names.count) else { throw ToolInputError(message: "data.countries needs 1 to 6 countries.") }
            var codes: [String] = []
            for n in names {
                guard let ctry = world.country(n) else { throw ToolInputError(message: "Unknown country '\(n)'. Use a country name or ISO3 code.") }
                codes.append(ctry.code)
            }
            let now = GeoDataService.currentYear
            let from = data["start_year"]?.intValue ?? 1990, to = min(now, data["end_year"]?.intValue ?? now)
            guard from < to else { throw ToolInputError(message: "start_year must be before end_year.") }
            let table: GeoIndicatorTable
            do { table = try await GeoDataService.shared.timeSeries(dataset, countries: codes, from: from, to: to) } catch { throw geoError(error) }
            var series: [ChartSeries] = []
            var missing: [String] = []
            for (i, code) in codes.enumerated() {
                let rows = table.rows.filter { $0.code == code }.sorted { $0.year < $1.year }
                if rows.isEmpty { missing.append(world.country(code: code)?.name ?? code); continue }
                series.append(ChartSeries(name: world.country(code: code)?.name ?? code, points: rows.map { [Double($0.year), $0.value] },
                                          colorHex: ChartPalette.color(i)))
            }
            guard !series.isEmpty else { throw ToolInputError(message: "\(table.title) has no data for \(names.joined(separator: ", ")) in \(from)–\(to).") }
            // Catalog title and unit, unless the World Bank was down and Our World in Data answered.
            let known = GeoCatalog.datasets.contains { $0.id == dataset.id } && table.provider == dataset.provider
            let unit = known ? dataset.unit : (table.unit ?? "")
            c.kind = ChartKind.line.rawValue
            c.series = series
            c.title = c.title ?? (known ? dataset.title : table.title)
            c.xLabel = c.xLabel ?? "Year"
            let unitTitle = String(unit.prefix(1)).uppercased() + String(unit.dropFirst())
            c.yLabel = c.yLabel ?? (unit.isEmpty ? (known ? dataset.title : table.title) : unitTitle)
            let years = table.rows.map(\.year)
            let span = "\(years.min() ?? from)–\(years.max() ?? to)"
            c.source = table.provider == .worldBank ? "Source: World Bank, World Development Indicators (\(dataset.code), \(span))"
                : "Source: Our World in Data\(table.citation.map { ", from \($0)" } ?? "") (\(span))"
            let w = min(area.width - 32, max(260, args.cg("width") ?? 480))
            let h = min(area.height - 40, max(200, args.cg("height") ?? 320))
            let requested = CGRect(x: args.cg("x") ?? area.midX - w / 2, y: args.cg("y") ?? area.minY + 80, width: w, height: h)
            let (frame, nudged) = layout.place(requested, page: page)
            let e = addTutorElement(page: page, frame: frame, kind: .chart(c))
            var result = "Line chart \(e.id) on page \(page + 1) at \(describe(frame))\(nudged ? " (moved to free space)" : ""): \(c.title ?? ""). "
            for s in series {
                let pts = s.xyPoints
                let first = pts.first!, last = pts.last!
                let maxP = pts.max { $0.y < $1.y }!, minP = pts.min { $0.y < $1.y }!
                result += "\(s.name): \(GeoFormat.value(first.y)) in \(Int(first.x)) → \(GeoFormat.value(last.y)) in \(Int(last.x)) (max \(GeoFormat.value(maxP.y)) in \(Int(maxP.x)), min \(GeoFormat.value(minP.y)) in \(Int(minP.x))). "
            }
            if !missing.isEmpty { result += "No data for: \(missing.joined(separator: ", ")). " }
            result += c.source ?? ""
            result += ". " + ChartRenderer.tutorDescription(c, frame: frame)
            return Outcome(result: result, isError: false,
                           action: ChatAction(symbol: "chart.xyaxis.line", summary: "Chart: \((c.title ?? "data").truncated(40))", elementIDs: [e.id], page: page))
        }

        // Inline data (the student's own, an experiment, a worksheet or textbook).
        var categories = (args.array("categories")).map { $0.stringValue ?? ($0.doubleValue.map(JSONValue.formatNumber) ?? "") }
        if kind == .climate && categories.isEmpty { categories = ClimateData.monthInitials }
        var series: [ChartSeries] = []
        for (i, s) in args.array("series").enumerated() {
            let name = s["name"]?.stringValue ?? "Series \(i + 1)"
            var vals: [Double?]?
            if let arr = s["values"]?.arrayValue {
                vals = arr.map { (v: JSONValue) -> Double? in
                    guard let d = v.doubleValue, d.isFinite else { return nil }
                    return d
                }
            }
            let pts = points(s["points"]).map { [Double($0.x), Double($0.y)] }
            var cs = ChartSeries(name: name, values: vals, points: pts.isEmpty ? nil : pts,
                                 colorHex: s["color"]?.stringValue.map { color($0) }, axis: s["axis"]?.stringValue, style: s["style"]?.stringValue)
            if kind == .climate && cs.axis == nil && cs.style == nil {
                let rainy = ["rain", "precip", "mm"].contains { name.lowercased().contains($0) }
                cs.axis = rainy ? "right" : "left"
                cs.style = rainy ? "bar" : "line"
                if cs.colorHex == nil { cs.colorHex = rainy ? ChartPalette.rain : ChartPalette.temp }
            }
            series.append(cs)
        }
        guard !series.isEmpty else { throw ToolInputError(message: "Give series (with values per category, or points for a scatter plot), or data to fetch real statistics.") }
        guard let src = args.string("source") else {
            throw ToolInputError(message: "Inline values need 'source' saying where they came from (the student's experiment, their worksheet or textbook page). For real-world statistics use 'data' so the app downloads them — never type statistics from memory.")
        }
        switch kind {
        case .scatter:
            guard series.allSatisfy({ $0.xyPoints.count >= 2 }) else { throw ToolInputError(message: "Scatter plots need points: [[x, y], ...] with at least two points per series.") }
        case .pie:
            guard let vals = series.first?.values, vals.count == categories.count, !categories.isEmpty else {
                throw ToolInputError(message: "A pie chart needs categories and one series with one value per category.")
            }
            guard vals.allSatisfy({ ($0 ?? 0) >= 0 }), vals.contains(where: { ($0 ?? 0) > 0 }) else { throw ToolInputError(message: "Pie values must be zero or positive.") }
        case .line where series.contains(where: { !($0.points ?? []).isEmpty }):
            break
        default:
            guard !categories.isEmpty else { throw ToolInputError(message: "Give categories (labels along the axis), one per value.") }
            for s in series {
                guard let v = s.values, v.count == categories.count else {
                    throw ToolInputError(message: "Series '\(s.name)' has \(s.values?.count ?? 0) values but there are \(categories.count) categories.")
                }
            }
        }
        c.categories = categories.isEmpty ? nil : categories
        c.series = series
        c.source = src.lowercased().hasPrefix("source") ? src : "Source: \(src)"
        if kind == .climate {
            c.yLabel = c.yLabel ?? "Temperature (°C)"
            c.y2Label = c.y2Label ?? "Rainfall (mm)"
            c.xLabel = c.xLabel ?? "Month"
        }
        let defaultSize = kind == .climate ? CGSize(width: 520, height: 360) : CGSize(width: 480, height: 320)
        let w = min(area.width - 32, max(240, args.cg("width") ?? defaultSize.width))
        let h = min(area.height - 40, max(180, args.cg("height") ?? defaultSize.height))
        let requested = CGRect(x: args.cg("x") ?? area.midX - w / 2, y: args.cg("y") ?? area.minY + 80, width: w, height: h)
        let (frame, nudged) = layout.place(requested, page: page)
        let e = addTutorElement(page: page, frame: frame, kind: .chart(c))
        let result = "\(kind.displayName) \(e.id) on page \(page + 1) at \(describe(frame))\(nudged ? " (moved to free space)" : ""). " + ChartRenderer.tutorDescription(c, frame: frame)
        return Outcome(result: result, isError: false,
                       action: ChatAction(symbol: kind == .pie ? "chart.pie" : "chart.bar", summary: "Chart: \((c.title ?? kind.displayName).truncated(40))", elementIDs: [e.id], page: page))
    }

    // MARK: climate_graph

    func climateGraphTool(_ args: ToolArgs) async throws -> Outcome {
        let page = try resolvePage(args.int("page"))
        var place: ClimatePlace
        if let lat = args.double("lat"), let lon = args.double("lon") {
            guard abs(lat) <= 90, abs(lon) <= 180 else { throw ToolInputError(message: "lat must be −90…90 and lon −180…180.") }
            var name = args.string("place") ?? GeoNice.latLabel((lat * 10).rounded() / 10) + " " + GeoNice.lonLabel((lon * 10).rounded() / 10)
            var country: String?
            if args.string("place") == nil, let near = GeoAssets.places?.nearest(to: GeoPoint(lon: lon, lat: lat), maxKm: 40) {
                name = "near \(near.name)"
                country = GeoAssets.world?.country(code: near.country)?.name
            }
            place = ClimatePlace(name: name, lat: lat, lon: lon, country: country)
        } else {
            let q = try args.requireString("place")
            do { place = try await GeoMapBuilder.climatePlace(q) } catch { throw geoError(error) }
        }
        let normals: ClimateNormals
        do { normals = try await GeoDataService.shared.climateNormals(place) } catch { throw geoError(error) }
        let chart = ClimateData.chart(normals, title: args.string("title"), showMaxMin: args.bool("max_min") ?? true)
        let w = min(area.width - 32, max(300, args.cg("width") ?? 520))
        let h = min(area.height - 40, max(240, args.cg("height") ?? 360))
        let requested = CGRect(x: args.cg("x") ?? area.midX - w / 2, y: args.cg("y") ?? area.minY + 80, width: w, height: h)
        let (frame, nudged) = layout.place(requested, page: page)
        let e = addTutorElement(page: page, frame: frame, kind: .chart(chart))
        var result = "Climate graph \(e.id) on page \(page + 1) at \(describe(frame))\(nudged ? " (moved to free space)" : ""). " + ClimateData.summary(normals)
        if let k = GeoAssets.koppen, let cls = Koppen.cls(k.classAt(lon: place.lon, lat: place.lat)) {
            result += " Köppen–Geiger zone here: \(cls.code) (\(cls.name))."
        }
        result += " Caption: \(ClimateData.caption). ERA5 averages a ~25 km grid, so at coastal or mountain places it can differ from the local weather station (wet tropical coasts such as Cairns read lower) — say so if the student compares it with a BOM or textbook graph."
        return Outcome(result: result, isError: false,
                       action: ChatAction(symbol: "cloud.sun.rain", summary: "Climate graph: \(place.shortName.truncated(30))", elementIDs: [e.id], page: page))
    }
}
