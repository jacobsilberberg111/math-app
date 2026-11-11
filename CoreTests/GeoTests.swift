import Foundation

/// Maps, charts and climate graphs: data decoding, projections, clipping, layout, binning,
/// dataset parsing and climate normals.
func runGeoTests() {
    let resources = FileManager.default.currentDirectoryPath + "/TutorNotes.swiftpm/Resources/"
    func load(_ name: String) -> Data? { FileManager.default.contents(atPath: resources + name) }

    // MARK: Codec
    do {
        // Two arcs: (0,0)->(1,1) and (1,1)->(3,0) in units of 1/q; zigzag deltas carried across arcs.
        // q = 1, offsets (180, 90): point (180, 90) units = lon 0, lat 0.
        var bytes: [UInt8] = []
        func varint(_ n: Int) { var v = n; repeat { var b = UInt8(v & 0x7F); v >>= 7; if v > 0 { b |= 0x80 }; bytes.append(b) } while v > 0 }
        func zz(_ n: Int) -> Int { n >= 0 ? n << 1 : ((-n) << 1) - 1 }
        varint(2); varint(zz(180)); varint(zz(90)); varint(zz(1)); varint(zz(1))
        varint(2); varint(zz(0)); varint(zz(0)); varint(zz(2)); varint(zz(-1))
        let arcs = try GeoCodec.decodeArcs(base64: Data(bytes).base64EncodedString(), q: 1)
        check(arcs.count == 2 && arcs[0] == [GeoPoint(lon: 0, lat: 0), GeoPoint(lon: 1, lat: 1)], "arc 0 \(arcs)")
        check(arcs[1] == [GeoPoint(lon: 1, lat: 1), GeoPoint(lon: 3, lat: 0)], "arc 1 carries the running point \(arcs)")
        let ring = GeoCodec.ring([0, ~1], arcs: [[GeoPoint(lon: 0, lat: 0), GeoPoint(lon: 1, lat: 0), GeoPoint(lon: 1, lat: 1)], [GeoPoint(lon: 0, lat: 0), GeoPoint(lon: 1, lat: 1)]])
        check(ring == [GeoPoint(lon: 0, lat: 0), GeoPoint(lon: 1, lat: 0), GeoPoint(lon: 1, lat: 1), GeoPoint(lon: 0, lat: 0)], "ring joins arcs, ~i reverses: \(ring)")
    } catch { check(false, "codec threw \(error)") }
    check(GeoCodec.normalize("  Côte d’Ivoire ") == "cote divoire", "normalize accents: \(GeoCodec.normalize("Côte d’Ivoire"))")
    check(GeoCodec.normalize("The Bahamas") == "bahamas", "normalize 'the'")
    check(GeoCodec.normalize("Bosnia & Herzegovina") == "bosnia and herzegovina", "normalize &: \(GeoCodec.normalize("Bosnia & Herzegovina"))")

    // MARK: Bundled world
    guard let worldData = load("geo_world.json"), let world = try? GeoWorld(data: worldData) else {
        check(false, "geo_world.json loads")
        return
    }
    check(world.countries.count > 200, "countries \(world.countries.count)")
    check(world.states.count == 9, "Australian states and territories \(world.states.count)")
    for code in ["AUS", "FRA", "NOR", "XKX", "IDN", "RUS", "FJI", "NZL", "BRA", "USA", "COD", "TWN"] {
        check(world.country(code: code) != nil, "has \(code)")
    }
    check(world.country("France")?.code == "FRA" && world.country("Norway")?.code == "NOR", "France/Norway have real ISO codes")
    check(world.country("DR Congo")?.code == "COD" && world.country("Democratic Republic of the Congo")?.code == "COD", "Congo aliases")
    check(world.country("Ivory Coast")?.code == "CIV" && world.country("cote d'ivoire")?.code == "CIV", "Côte d'Ivoire aliases")
    check(world.country("UK")?.code == "GBR" && world.country("United States")?.code == "USA" && world.country("ind")?.code == "IND", "short aliases")
    check(world.country("Korea, Rep.")?.code == "KOR" && world.country("Viet Nam")?.code == "VNM", "World Bank spellings")
    check(world.state("NSW")?.id == "AU-NSW" && world.state("Victoria")?.id == "AU-VIC" && world.state("au-qld")?.name == "Queensland", "state lookup")
    if let fra = world.country(code: "FRA") {
        check(fra.focus.west > -6 && fra.focus.east < 11 && fra.focus.south > 40, "France's focus is the mainland (not French Guiana): \(fra.focus)")
    }
    if let usa = world.country(code: "USA") { check(usa.focus.west > -130, "USA focus excludes Alaska \(usa.focus)") }
    if let rus = world.country(code: "RUS") { check(rus.focus.east > 180, "Russia's focus runs past 180° \(rus.focus)") }
    check(world.coastArcs.count > 300 && world.borderArcs.count > 200, "coast \(world.coastArcs.count) / border \(world.borderArcs.count) arcs")
    if let aus = world.countries.firstIndex(where: { $0.code == "AUS" }), let png = world.countries.firstIndex(where: { $0.code == "PNG" }),
       let fra = world.countries.firstIndex(where: { $0.code == "FRA" }), let deu = world.countries.firstIndex(where: { $0.code == "DEU" }) {
        check(world.neighbours[aus].isEmpty, "Australia has no land neighbours")
        check(world.neighbours[fra].contains(deu), "France borders Germany")
        _ = png
    }
    check(world.stateBorderArcs.count >= 8, "internal state borders \(world.stateBorderArcs.count)")
    check(world.countryAt(lon: 151.2, lat: -33.9)?.code == "AUS", "Sydney is in Australia")
    check(world.countryAt(lon: 2.35, lat: 48.86)?.code == "FRA", "Paris is in France")
    check(world.countryAt(lon: 28.2, lat: -29.5)?.code == "LSO", "a point in Lesotho is Lesotho, not South Africa")
    check(world.countryAt(lon: 160, lat: -30) == nil, "Tasman Sea is not in a country")
    // Exterior rings are anticlockwise (positive area) so land clips with the nonzero rule work.
    if let zaf = world.country(code: "ZAF") {
        func area(_ r: [GeoPoint]) -> Double {
            var s = 0.0
            for i in 0..<r.count { let a = r[i], b = r[(i + 1) % r.count]; s += a.lon * b.lat - b.lon * a.lat }
            return s / 2
        }
        let areas = zaf.rings.map(area)
        check(areas.contains { $0 > 0 } && areas.contains { $0 < 0 }, "South Africa has an exterior and a hole (Lesotho): \(areas.map { Int($0) })")
    }
    if let bbox = world.bbox(countries: ["NZL", "FJI"]) {
        check(bbox.width < 40, "NZ + Fiji stay together across 180°: \(bbox)")
    }

    // MARK: Places
    if let placesData = load("geo_places.json"), let places = try? GeoPlaces(data: placesData) {
        check(places.places.count > 1000, "places \(places.places.count)")
        let syd = places.find("Sydney", world: world)
        check(syd?.country == "AUS" && abs((syd?.lat ?? 0) + 33.9) < 0.3, "Sydney \(String(describing: syd))")
        check(places.find("Paris, France", world: world)?.country == "FRA", "Paris, France")
        check(places.find("Dubbo", world: world)?.admin1 == "New South Wales", "Dubbo is in the bundle")
        check(places.find("Wagga Wagga", world: world) != nil, "Wagga Wagga")
        check(places.find("Atlantis", world: world) == nil, "unknown place")
        check(places.find("Lagos (Nigeria)", world: world)?.country == "NGA", "qualifier in brackets")
        check(places.find("Canberra", world: world)?.capital == 1, "Canberra is a national capital")
    } else { check(false, "geo_places.json loads") }

    // MARK: Köppen
    if let kd = load("geo_koppen.json"), let koppen = try? KoppenData(data: kd) {
        check(koppen.grids.count == 3, "three grids")
        func code(_ lon: Double, _ lat: Double) -> String { Koppen.cls(koppen.classAt(lon: lon, lat: lat))?.code ?? "sea" }
        check(code(151.21, -33.87) == "Cfa", "Sydney is Cfa: \(code(151.21, -33.87))")
        check(code(133.88, -23.70) == "BWh", "Alice Springs is BWh: \(code(133.88, -23.70))")
        check(code(130.84, -12.46) == "Aw", "Darwin is Aw: \(code(130.84, -12.46))")
        check(code(103.85, 1.29).hasPrefix("A"), "Singapore is tropical: \(code(103.85, 1.29))")
        check(code(37.6, 55.75) == "Dfb", "Moscow is Dfb: \(code(37.6, 55.75))")
        check(code(-0.13, 51.5) == "Cfb", "London is Cfb: \(code(-0.13, 51.5))")
        check(code(-47.0, 75.0) == "EF", "Greenland ice is EF: \(code(-47.0, 75.0))")
        check(koppen.classAt(lon: -140, lat: 0) == 0, "mid-Pacific is sea")
        check(koppen.grid(for: GeoBBox(west: 112, south: -44, east: 154, north: -10), pointsPerDegree: 12)?.id == "australia-0.1", "Australia uses its 0.1° grid")
        check(koppen.grid(for: GeoBBox(west: -180, south: -90, east: 180, north: 90), pointsPerDegree: 1.7)?.id == "world-0.5", "world map uses 0.5°")
        check(koppen.grid(for: GeoBBox(west: -25, south: 34, east: 45, north: 71), pointsPerDegree: 7.5)?.id == "world-0.2", "Europe uses 0.2°")
        let ausMap = MapContent(region: "Australia", bbox: GeoBBox(west: 111.5, south: -44.5, east: 155, north: -9.5), layer: "climate")
        let ausClasses = MapScene.koppenClasses(ausMap, koppen: koppen, width: 560)
        let ausCodes = Set(ausClasses.compactMap { Koppen.cls($0)?.code })
        check(ausCodes.isSuperset(of: ["Af", "Aw", "BWh", "BSh", "Cfa", "Cfb", "Csa"]), "Australian climate classes \(ausCodes.sorted())")
        check(!ausCodes.contains("Dfc") && !ausCodes.contains("EF"), "no subarctic or ice cap in the Australia view")

        // A world climate scene: quads for many classes, legend matches.
        let measure: MapTextMeasure = { t, s, b in CGSize(width: CGFloat(t.count) * s * (b ? 0.6 : 0.55), height: s * 1.25) }
        let wc = MapContent(title: "World climate zones", source: "Source: Beck et al. (2023)", layer: "climate")
        let t0 = Date()
        let scene = MapScene.build(wc, size: CGSize(width: 560, height: 520), world: world, koppen: koppen, places: nil, measure: measure)
        let dt = Date().timeIntervalSince(t0)
        check(scene.koppen.count > 20 && scene.koppen.reduce(0) { $0 + $1.quads.count } > 3000, "world Köppen quads \(scene.koppen.count) classes")
        let swatches = scene.layout.legend.filter { $0.kind != .heading }
        check(swatches.count == scene.koppenClasses.count && scene.layout.legend.count == swatches.count + 5, "climate legend grouped by A–E: \(scene.layout.legend.count) vs \(scene.koppenClasses.count)")
        check(dt < 3, "world climate scene builds quickly (\(String(format: "%.2f", dt)) s on Linux)")
        let groups = MapScene.build(MapContent(layer: "climate", climateDetail: "groups"), size: CGSize(width: 560, height: 400), world: world, koppen: koppen, places: nil, measure: measure)
        check(groups.koppen.count == 5 && groups.layout.legend.count == 5, "groups map: 5 colours, 5 legend entries (\(groups.koppen.count), \(groups.layout.legend.count))")
    } else { check(false, "geo_koppen.json loads") }

    // MARK: Projections
    let ne = GeoProjection(kind: .naturalEarth, centralLon: 0)
    // d3-geo naturalEarth1Raw(π, 0) = (0.8707π, 0); at 90° y = 1.4224, x factor 0.4797.
    check(approx(ne.forward(relLon: 180, lat: 0).x, 0.8707 * Double.pi, 1e-9), "NE x at equator")
    check(approx(ne.y(lat: 90), 1.4224, 2e-3), "NE pole y \(ne.y(lat: 90))")
    for (lon, lat) in [(30.0, 45.0), (-120.0, -60.0), (170.0, 10.0), (0.0, 80.0)] {
        let f = ne.forward(relLon: lon, lat: lat)
        let inv = ne.inverse(x: f.x, y: f.y)
        check(inv.map { approx($0.relLon, lon, 1e-6) && approx($0.lat, lat, 1e-6) } == true, "NE inverse \(lon),\(lat) -> \(String(describing: inv))")
    }
    let rob = GeoProjection(kind: .robinson, centralLon: 0)
    check(approx(rob.y(lat: 90), 1.3523, 1e-9) && approx(rob.xFactor(lat: 45), 0.8487 * 0.8962, 1e-9), "Robinson table values")
    check(approx(rob.y(lat: -45), -1.3523 * 0.5571, 1e-9), "Robinson southern hemisphere")
    let r2 = rob.inverse(x: rob.forward(relLon: -75, lat: 33).x, y: rob.forward(relLon: -75, lat: 33).y)
    check(r2.map { approx($0.relLon, -75, 1e-6) && approx($0.lat, 33, 1e-6) } == true, "Robinson inverse \(String(describing: r2))")
    check(GeoProjection(kind: .naturalEarth, centralLon: 150).relative(-170) == 40, "relative longitude across 180°")

    // Fitting: world map fills its rectangle without overflowing.
    let worldFrame = MapFrame.fit(kind: .naturalEarth, view: nil, centralLon: 0, in: CGRect(x: 10, y: 40, width: 540, height: 400))
    let east = worldFrame.project(lon: 180 - 1e-9, lat: 0), west = worldFrame.project(lon: -180, lat: 0)
    check(abs(east.x - 550) < 0.5 && abs(west.x - 10) < 0.5, "world fills width \(west.x)…\(east.x)")
    check(worldFrame.project(lon: 0, lat: 90).y >= 40 - 0.5, "world fits height")
    if let g = worldFrame.geo(at: worldFrame.project(lon: 151.2, lat: -33.9)) {
        check(approx(g.lon, 151.2, 1e-6) && approx(g.lat, -33.9, 1e-6), "screen → lon/lat round trip \(g)")
    } else { check(false, "geo(at:)") }
    let ausFrame = MapFrame.fit(kind: .equirectangular, view: GeoBBox(west: 111.5, south: -44.5, east: 155, north: -9.5), centralLon: 0,
                                in: CGRect(x: 0, y: 0, width: 500, height: 420))
    let tl = ausFrame.project(lon: 111.5, lat: -9.5), br = ausFrame.project(lon: 155, lat: -44.5)
    check(tl.x >= -0.5 && tl.y >= -0.5 && br.x <= 500.5 && br.y <= 420.5, "requested area fully visible \(tl) \(br)")
    check(ausFrame.view.width >= 43.5 - 1e-6 && ausFrame.view.height >= 35 - 1e-6, "view grows to fill the frame \(ausFrame.view)")
    // cos(mid-latitude) scaling: 1° of longitude is cos(27°) of 1° of latitude.
    let d1 = ausFrame.project(lon: 130, lat: -27).x - ausFrame.project(lon: 129, lat: -27).x
    let d2 = ausFrame.project(lon: 130, lat: -28).y - ausFrame.project(lon: 130, lat: -27).y
    check(approx(Double(d1 / d2), cos(27 * Double.pi / 180), 1e-2), "equirectangular aspect \(d1 / d2)")
    // Scale: about 111 km per degree of latitude.
    let kmPerPt = ausFrame.kmPerPoint(lat: ausFrame.projection.standardLat)
    check(approx(kmPerPt * Double(d2), 111.32 * 1, 0.02), "km per point \(kmPerPt)")
    let bar = GeoNice.scaleBar(kmPerPoint: kmPerPt, maxPoints: 120)
    check([500.0, 1000, 200].contains(bar.km) && bar.points <= 120 && bar.points > 40, "scale bar \(bar)")
    check(GeoNice.floor125(740) == 500 && GeoNice.floor125(0.03) == 0.02 && GeoNice.floor125(1999) == 1000, "1-2-5 rounding")
    check(GeoNice.latLabel(-33.5) == "33.5°S" && GeoNice.lonLabel(-150) == "150°W" && GeoNice.lonLabel(190) == "170°W", "degree labels")

    // MARK: Clipping and the antimeridian
    // A ring straddling 180° in a Pacific-centred view stays one compact piece.
    let fijiLike = [GeoPoint(lon: 177, lat: -18), GeoPoint(lon: 180, lat: -18), GeoPoint(lon: 180, lat: -16), GeoPoint(lon: 177, lat: -16)]
    let pieces = GeoClip.recenterRing(fijiLike, centralLon: 150)
    check(pieces.count == 1 && pieces[0].allSatisfy { $0.lon >= 27 && $0.lon <= 30 }, "ring near 180° re-centred \(pieces)")
    // Antarctica-like ring spanning all longitudes is cut at the new antimeridian (no smear).
    let band = [GeoPoint(lon: -180, lat: -70), GeoPoint(lon: 180, lat: -70), GeoPoint(lon: 180, lat: -90), GeoPoint(lon: -180, lat: -90)]
    let cut = GeoClip.recenterRing(band, centralLon: 150)
    check(cut.count == 2 && cut.allSatisfy { r in r.allSatisfy { $0.lon >= -180 - 1e-9 && $0.lon <= 180 + 1e-9 } }, "polar ring split at 150°E's antimeridian: \(cut.count)")
    let totalWidth = cut.map { r in (r.map(\.lon).max() ?? 0) - (r.map(\.lon).min() ?? 0) }.reduce(0, +)
    check(approx(totalWidth, 360, 1e-6), "split pieces cover 360° \(totalWidth)")
    let line = [GeoPoint(lon: 160, lat: 0), GeoPoint(lon: 179, lat: 0)]
    check(GeoClip.recenterLine(line, centralLon: -10).count == 2, "a line across the new antimeridian is split")
    let clipped = GeoClip.clipPolygon([GeoPoint(lon: 0, lat: 0), GeoPoint(lon: 10, lat: 0), GeoPoint(lon: 10, lat: 10), GeoPoint(lon: 0, lat: 10)],
                                      to: GeoBBox(west: 5, south: -5, east: 20, north: 5))
    check(clipped.count == 4 && clipped.allSatisfy { $0.lon >= 5 && $0.lat <= 5 }, "Sutherland–Hodgman box clip \(clipped)")
    let lines = GeoClip.clipLine([GeoPoint(lon: -10, lat: 0), GeoPoint(lon: 10, lat: 0), GeoPoint(lon: 10, lat: 20), GeoPoint(lon: -10, lat: 20)],
                                 to: GeoBBox(west: -5, south: -5, east: 15, north: 15))
    check(lines.count == 1 && lines[0].count == 3 && lines[0].first?.lon == -5 && lines[0].last?.lat == 15, "polyline clip \(lines)")
    let thin = GeoClip.thin((0...100).map { CGPoint(x: CGFloat($0) * 0.1, y: 0) }, tolerance: 1, closed: false)
    check(thin.count == 11 || thin.count == 12, "thinning \(thin.count)")

    // MARK: Map scenes
    let measure: MapTextMeasure = { t, s, b in CGSize(width: CGFloat(t.count) * s * (b ? 0.6 : 0.55), height: s * 1.25) }
    let pacific = MapContent(title: "The Pacific", region: "Pacific Islands", bbox: GeoBBox(west: 140, south: -30, east: 220, north: 15), layer: "political", labels: true)
    let ps = MapScene.build(pacific, size: CGSize(width: 560, height: 420), world: world, koppen: nil, places: nil, measure: measure)
    let mapRect = ps.layout.mapRect
    // Nothing smears: every projected country ring fits within a sane width.
    let maxRingWidth = ps.countries.flatMap(\.rings).map { r in (r.map(\.x).max() ?? 0) - (r.map(\.x).min() ?? 0) }.max() ?? 0
    check(maxRingWidth < mapRect.width * 1.3, "no ring smears across a Pacific map (\(maxRingWidth))")
    check(ps.countries.contains { $0.code == "FJI" } && ps.countries.contains { $0.code == "VUT" } && ps.countries.contains { $0.code == "WSM" }, "Fiji, Vanuatu and Samoa drawn on the Pacific map")
    if let fj = ps.countries.first(where: { $0.code == "FJI" }) {
        check(mapRect.insetBy(dx: -5, dy: -5).contains(CGPoint(x: fj.bounds.midX, y: fj.bounds.midY)) && fj.bounds.width < 60, "Fiji is compact and on the map \(fj.bounds)")
    }
    let world0 = MapScene.build(MapContent(title: "World", layer: "political", labels: true, graticule: true, latitudeLines: true),
                                size: CGSize(width: 560, height: 380), world: world, koppen: nil, places: nil, measure: measure)
    check(world0.labels.contains { $0.text == "Australia" } && world0.labels.contains { $0.text == "Brazil" }, "world labels include big countries")
    check(world0.labels.contains { $0.text.hasPrefix("Tropic of Capricorn") } && world0.specialLines.count == 5, "latitude lines")
    let maxWorldRing = world0.countries.flatMap(\.rings).map { r in (r.map(\.x).max() ?? 0) - (r.map(\.x).min() ?? 0) }.max() ?? 0
    check(maxWorldRing <= world0.layout.mapRect.width + 1, "world rings within the map \(maxWorldRing)")
    let overlaps = world0.labels.enumerated().contains { i, a in world0.labels.enumerated().contains { j, b in i < j && !a.halo && !b.halo && a.rect.insetBy(dx: 1, dy: 1).intersects(b.rect.insetBy(dx: 1, dy: 1)) } }
    check(!overlaps, "country labels don't overlap")
    let pacificWorld = MapScene.build(MapContent(centralLon: 150, layer: "outline"), size: CGSize(width: 560, height: 320), world: world, koppen: nil, places: nil, measure: measure)
    let maxPW = pacificWorld.countries.flatMap(\.rings).map { r in (r.map(\.x).max() ?? 0) - (r.map(\.x).min() ?? 0) }.max() ?? 0
    check(maxPW <= pacificWorld.layout.mapRect.width + 1, "Pacific-centred world: rings within the globe (\(maxPW))")
    if let aus = pacificWorld.countries.first(where: { $0.code == "AUS" }) {
        check(abs(aus.bounds.midX - pacificWorld.layout.mapRect.midX) < 60, "Australia near the middle of a Pacific-centred map")
    }
    // Markers, routes and highlights.
    var mk = MapContent(title: "Australia", region: "Australia", bbox: MapRegionPreset.find("australia")!.bbox, layer: "outline", labels: false)
    mk.markers = [MapMarker(lon: 151.21, lat: -33.87, label: "Sydney"), MapMarker(lon: 0, lat: 51.5, label: "London (off the map)")]
    mk.routes = [MapRoute(points: [GeoPoint(lon: 151.21, lat: -33.87), GeoPoint(lon: 115.86, lat: -31.95)], label: "Flight")]
    mk.highlights = [MapHighlight(codes: ["AU-NSW"], colorHex: "#FFD43B", label: "New South Wales")]
    let ms = MapScene.build(mk, size: CGSize(width: 520, height: 460), world: world, koppen: nil, places: nil, measure: measure)
    check(ms.markers.count == 1 && ms.markers[0].label?.text == "Sydney", "only visible markers are drawn")
    check(ms.routes.count == 1 && ms.routes[0].segments.count == 1, "route")
    check(ms.highlightFills.count == 1 && !ms.stateBorders.isEmpty, "state highlight and borders")
    check(ms.layout.legend.contains { $0.text.text == "New South Wales" }, "highlight label in legend")
    check(ms.layout.scaleBar != nil && ms.layout.caption == nil, "scale bar present")
    check(MapRegionPreset.find("Murray-Darling Basin")?.id == "murray_darling" && MapRegionPreset.find("asia pacific")?.id == "asia_pacific", "preset aliases")
    let conv = MapDescriber.conversion(ms.layout, origin: CGPoint(x: 40, y: 100))
    check(conv.contains("x = ") && conv.contains("lat"), "conversion text \(conv)")
    // The formula in the text agrees with the projection.
    let sydney = ms.layout.frame.project(lon: 151.21, lat: -33.87)
    let v = ms.layout.frame.view
    let kx = ms.layout.frame.pointsPerDegreeLon(lat: 0), ky = ms.layout.frame.scale * Double.pi / 180
    let x0 = Double(ms.layout.frame.project(lon: v.west, lat: 0).x), y0 = Double(ms.layout.frame.project(lon: v.west, lat: 0).y)
    check(approx(x0 + kx * (151.21 - v.west), Double(sydney.x), 1e-6) && approx(y0 - ky * -33.87, Double(sydney.y), 1e-6), "linear lon/lat formula")
    let worldConv = MapDescriber.conversion(world0.layout, origin: .zero)
    check(worldConv.contains("30°S: y=") && worldConv.contains("k="), "world conversion table")

    // MARK: Datasets
    check(GeoCatalog.datasets.count >= 30 && Set(GeoCatalog.datasets.map(\.id)).count == GeoCatalog.datasets.count, "catalog ids unique")
    check(GeoCatalog.resolve("life_expectancy")?.code == "SP.DYN.LE00.IN", "catalog id")
    check(GeoCatalog.resolve("SP.DYN.LE00.IN")?.id == "life_expectancy", "catalog by code")
    check(GeoCatalog.resolve("worldbank:EN.POP.DNST")?.code == "EN.POP.DNST", "worldbank: prefix")
    check(GeoCatalog.resolve("worldbank:SH.XYZ.ABC")?.provider == .worldBank, "free-form World Bank code")
    check(GeoCatalog.resolve("owid:share-of-population-urban")?.provider == .owid, "owid: prefix")
    check(GeoCatalog.resolve("owid:../etc") == nil && GeoCatalog.resolve("worldbank:a b") == nil, "unsafe codes rejected")
    check(GeoCatalog.promptList.contains("hdi (Human Development Index"), "prompt list")

    let wbJSON = #"""
    [{"page":1,"pages":1,"per_page":20000,"total":6},[
     {"indicator":{"id":"SP.DYN.LE00.IN","value":"Life expectancy at birth, total (years)"},"country":{"id":"AU","value":"Australia"},"countryiso3code":"AUS","date":"2023","value":83.1,"unit":"","obs_status":"","decimal":0},
     {"indicator":{"id":"SP.DYN.LE00.IN","value":"Life expectancy at birth, total (years)"},"country":{"id":"AU","value":"Australia"},"countryiso3code":"AUS","date":"2022","value":83.0},
     {"indicator":{"id":"SP.DYN.LE00.IN","value":"Life expectancy at birth, total (years)"},"country":{"id":"NG","value":"Nigeria"},"countryiso3code":"NGA","date":"2023","value":54.5},
     {"indicator":{"id":"SP.DYN.LE00.IN","value":"Life expectancy at birth, total (years)"},"country":{"id":"JP","value":"Japan"},"countryiso3code":"JPN","date":"2023","value":null},
     {"indicator":{"id":"SP.DYN.LE00.IN","value":"Life expectancy at birth, total (years)"},"country":{"id":"JP","value":"Japan"},"countryiso3code":"JPN","date":"2022","value":84.0},
     {"indicator":{"id":"SP.DYN.LE00.IN","value":"Life expectancy at birth, total (years)"},"country":{"id":"1W","value":"World"},"countryiso3code":"WLD","date":"2023","value":73.2}]]
    """#
    do {
        let t = try GeoDataParser.worldBank(Data(wbJSON.utf8), code: "SP.DYN.LE00.IN")
        check(t.rows.count == 5 && t.unit == "years" && t.title.hasPrefix("Life expectancy"), "World Bank parse \(t.rows.count) \(t.unit ?? "-")")
        let valid: Set<String> = ["AUS", "NGA", "JPN", "FRA"]
        let c = try GeoYearChooser.choose(t, validCodes: valid, requestedYear: nil, maxYear: 2026)
        check(c.label == "2022" || c.label == "2023" || c.label.hasPrefix("latest"), "year choice \(c.label)")
        check(c.values["WLD"] == nil, "aggregates dropped")
        let c22 = try GeoYearChooser.choose(t, validCodes: valid, requestedYear: 2022, maxYear: 2026)
        check(c22.values == ["AUS": 83.0, "JPN": 84.0], "requested year \(c22.values)")
        do {
            _ = try GeoYearChooser.choose(t, validCodes: valid, requestedYear: 1990, maxYear: 2026)
            check(false, "missing year should throw")
        } catch { check("\(error)".contains("2022"), "missing year lists years: \(error)") }
    } catch { check(false, "World Bank parse threw \(error)") }
    do {
        _ = try GeoDataParser.worldBank(Data(#"[{"message":[{"id":"120","key":"Invalid value","value":"The provided parameter value is not valid"}]}]"#.utf8), code: "XX.BAD")
        check(false, "WB error should throw")
    } catch { check("\(error)".contains("XX.BAD"), "WB error message names the code: \(error)") }

    // Survey-style data (few countries per year) falls back to each country's latest value.
    var survey = GeoIndicatorTable(provider: .worldBank, code: "SI.POV.DDAY", title: "Poverty", unit: "%", citation: nil, rows: [])
    let codes = (0..<40).map { String(format: "C%02d", $0) }
    for (i, c) in codes.enumerated() { survey.rows.append(.init(code: c, name: c, year: 2014 + i % 9, value: Double(i))) }
    if let sc = try? GeoYearChooser.choose(survey, validCodes: Set(codes), requestedYear: nil, maxYear: 2026) {
        check(sc.values.count == 40 && sc.years != nil && sc.label.hasPrefix("latest available"), "latest-available fallback \(sc.label) \(sc.values.count)")
    } else { check(false, "survey choice") }

    let csv = "entity,code,year,hdi__sex_total,owid_region\nAustralia,AUS,2023,0.958,Oceania\n\"Bonaire, Sint Eustatius and Saba\",BES,2023,0.8,\nKosovo,OWID_KOS,2023,0.76,Europe\nWorld,OWID_WRL,2023,0.756,\nAfrica,,2023,0.56,\n"
    let meta = #"{"chart":{"title":"Human Development Index","citation":"UNDP, Human Development Report (2025)"},"columns":{"hdi__sex_total":{"titleShort":"Human Development Index","unit":"","type":"Numeric"},"owid_region":{"type":"Continent"}}}"#
    do {
        let t = try GeoDataParser.owid(csv: csv, metadata: Data(meta.utf8), slug: "human-development-index")
        check(t.rows.count == 3 && t.rows.contains { $0.code == "XKX" } && t.rows.contains { $0.name == "Bonaire, Sint Eustatius and Saba" }, "OWID parse \(t.rows)")
        check(t.citation == "UNDP, Human Development Report (2025)" && t.title == "Human Development Index", "OWID metadata")
    } catch { check(false, "OWID parse threw \(error)") }
    check(GeoDataParser.parseCSV("a,\"b \"\"q\"\"\",c\r\n1,2,3") == [["a", "b \"q\"", "c"], ["1", "2", "3"]], "CSV quotes and CRLF")

    // Binning.
    let vals = (1...100).map { Double($0) }
    let qb = GeoBinning.quantileBreaks(vals, classes: 5)
    check(qb.count == 4 && approx(qb[0], 21, 0.05) && approx(qb[3], 80, 0.05), "quantile breaks \(qb)")
    check(GeoBinning.round2(1234) == 1200 && GeoBinning.round2(0.0456) == 0.046 && GeoBinning.round2(-37.4) == -37, "round to 2 s.f.")
    let div = GeoBinning.choropleth(values: ["A": -3, "B": -1, "C": 0.5, "D": 1, "E": 2, "F": 4, "G": 6], palette: "rdbu", diverging: true)
    check(div.breaks.contains(0) && div.colors.count == div.breaks.count + 1, "diverging breaks around zero \(div)")
    let ch = MapChoropleth(provider: "World Bank", code: "X", indicator: "X", yearLabel: "2023", values: ["AUS": 5, "NGA": 50], breaks: [10, 20], colors: ["#1", "#2", "#3"])
    check(ch.color(for: "AUS") == "#1" && ch.color(for: "NGA") == "#3" && ch.color(for: "FRA") == nil, "class lookup")
    check(GeoBinning.labels([10, 20]) == ["< 10", "10 – 20", "≥ 20"], "legend labels \(GeoBinning.labels([10, 20]))")
    check(GeoFormat.value(1_412_000_000) == "1.41 billion" && GeoFormat.value(83.12) == "83.1" && GeoFormat.short(25_400) == "25k", "number formats")
    let summary = GeoDataSummary.text(values: ["AUS": 83.1, "NGA": 54.5, "JPN": 84.7], names: ["AUS": "Australia", "NGA": "Nigeria", "JPN": "Japan"], unit: "years")
    check(summary.contains("Highest: Japan 84.7") && summary.contains("Australia: 83.1 (rank 2 of 3"), "summary \(summary)")

    // MARK: Charts
    let s1 = ChartScale.nice(min: 0, max: 87, maxTicks: 6, includeZero: true)
    check(s1.lo == 0 && s1.hi >= 87 && s1.ticks.count <= 7, "nice scale \(s1) \(s1.ticks)")
    let s2 = ChartScale.nice(min: -3.2, max: 14.9, maxTicks: 6)
    check(s2.lo <= -3.2 && s2.hi >= 14.9 && s2.ticks.contains(0), "scale through zero \(s2.ticks)")
    check(ChartScale.label(2.5, step: 2.5) == "2.5" && ChartScale.label(1000, step: 500) == "1,000" && ChartScale.label(0.3, step: 0.1) == "0.3", "tick labels")
    let fit = ChartFit.leastSquares([(1, 3), (2, 5), (3, 7), (4, 9)])
    check(fit.map { approx($0.slope, 2) && approx($0.intercept, 1) && approx($0.r, 1) } == true, "best fit \(String(describing: fit))")
    check(fit?.equation == "y = 2x + 1", "equation \(fit?.equation ?? "")")
    let pie = ChartPie.slices([1, 1, 2])
    check(pie.count == 3 && approx(pie[2].percent, 50) && approx(pie[2].end, 2 * Double.pi), "pie slices")
    let chartJSON = try? JSONEncoder().encode(ChartContent(title: "t", kind: "bar", categories: ["a"], series: [ChartSeries(name: "s", values: [1, nil])]))
    if let chartJSON, let back = try? JSONDecoder().decode(ChartContent.self, from: chartJSON) {
        check(back.series?[0].values == [1, nil], "chart round trip keeps missing values")
    } else { check(false, "chart encode") }
    check((try? JSONDecoder().decode(ChartContent.self, from: Data("{}".utf8))) != nil, "empty chart decodes (old notes)")
    check((try? JSONDecoder().decode(MapContent.self, from: Data(#"{"title":"Old map","futureField":3}"#.utf8)))?.title == "Old map", "old/new map JSON decodes")

    // MARK: Climate normals
    var dates: [String] = [], temp: [Double?] = [], rain: [Double?] = []
    let monthDays = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    for y in 1991...1992 {
        for m in 1...12 {
            for d in 1...monthDays[m - 1] {
                dates.append(String(format: "%04d-%02d-%02d", y, m, d))
                temp.append(Double(m) + (y == 1992 ? 1 : 0))
                rain.append(m == 1 && d == 1 ? nil : 1)
            }
        }
    }
    do {
        let n = try ClimateData.normals(dates: dates, temp: temp, tempMax: temp.map { $0.map { $0 + 5 } }, tempMin: temp.map { $0.map { $0 - 5 } },
                                        rain: rain, place: ClimatePlace(name: "Testville", lat: -33, lon: 151))
        check(approx(n.temp[0], 1.5) && approx(n.temp[11], 12.5), "monthly mean temperature across years \(n.temp)")
        check(approx(n.rain[1], 28) && approx(n.rain[0], 31), "monthly rainfall totals (missing day filled pro rata) \(n.rain[0]) \(n.rain[1])")
        check(approx(n.annualRain, 365) && n.wettestMonth == 0 || n.wettestMonth == 2, "annual rainfall \(n.annualRain)")
        check(approx(n.tempMax?[5] ?? 0, 11.5), "mean max")
        let chart = ClimateData.chart(n)
        check(chart.chartKind == .climate && chart.categories?.count == 12 && chart.allSeries.first?.onRight == true, "climate chart")
        check(chart.source?.contains("ERA5") == true && chart.source?.contains("1991–2020") == true, "climate caption")
        let text = ClimateData.summary(n)
        check(text.contains("Jan 1.5") && text.contains("Annual rainfall 365 mm"), "climate summary \(text)")
    } catch { check(false, "normals threw \(error)") }
    let omDates = (1...12).map { String(format: "\"2000-%02d-01\",\"2000-%02d-02\"", $0, $0) }.joined(separator: ",")
    let omT = (1...12).map { _ in "22.5,23.5" }.joined(separator: ","), omR = (1...12).map { _ in "0.0,4.2" }.joined(separator: ",")
    let om = #"{"latitude":-33.85,"longitude":151.2,"elevation":39.0,"daily":{"time":["# + omDates + #"],"temperature_2m_mean":["# + omT + #"],"temperature_2m_max":["# + omT + #"],"temperature_2m_min":["# + omT + #"],"precipitation_sum":["# + omR + #"]}}"#
    if let n = try? ClimateData.normals(fromArchive: Data(om.utf8), place: ClimatePlace(name: "Sydney", lat: -33.87, lon: 151.21)) {
        check(n.place.elevation == 39 && approx(n.temp[0], 23) && approx(n.rain[5], 4.2), "Open-Meteo archive JSON \(n.temp[0]) \(n.rain[5])")
    } else { check(false, "archive JSON parse") }
    let geo = #"{"results":[{"id":1,"name":"Dubbo","latitude":-32.24,"longitude":148.6,"elevation":264.0,"country_code":"AU","country":"Australia","admin1":"New South Wales","population":43516}],"generationtime_ms":0.5}"#
    if let r = try? ClimateData.parseGeocoding(Data(geo.utf8)) {
        check(r.count == 1 && r[0].shortName == "Dubbo, NSW" && r[0].displayName == "Dubbo, New South Wales, Australia", "geocoding parse \(r)")
    } else { check(false, "geocoding parse") }
    check((try? ClimateData.parseGeocoding(Data(#"{"generationtime_ms":0.3}"#.utf8)))?.isEmpty == true, "no geocoding results")
    check(ClimateData.archiveURL(lat: -33.87, lon: 151.21)?.absoluteString.contains("models=era5") == true, "archive URL")
    check(ClimateData.geocodingURL("Richmond", countryCode: "au")?.absoluteString.contains("countryCode=AU") == true, "geocoding country filter")
    let rich = [ClimatePlace(name: "Richmond", lat: 37.5, lon: -77.4, country: "United States", countryCode: "US", admin1: "Virginia"),
                ClimatePlace(name: "Richmond", lat: -33.6, lon: 150.75, country: "Australia", countryCode: "AU", admin1: "New South Wales")]
    check(!ClimateData.matches(rich[0], qualifier: "NSW") && ClimateData.matches(rich[1], qualifier: "NSW") && ClimateData.matches(rich[1], qualifier: "new south wales"), "qualifier matching")
    check(ClimateData.australianQualifier("Qld") && ClimateData.australianQualifier("Tasmania") && !ClimateData.australianQualifier("Nigeria"), "Australian qualifiers")
    runClimateAxisTests()
}

/// Twin climate-graph axes share gridlines and zero.
func runClimateAxisTests() {
    let a = ChartScale.climateAxes(tempMin: 4.3, tempMax: 33, rainMax: 75, maxTicks: 7)
    check(a.temp.lo == 0 && a.temp.hi >= 33 && a.rain.lo == 0 && a.rain.hi >= 75, "Dubbo axes \(a)")
    let kt = (a.temp.hi - a.temp.lo) / a.temp.step, kr = (a.rain.hi - a.rain.lo) / a.rain.step
    check(abs(kt - kr) < 1e-9, "same number of intervals \(kt) \(kr)")
    let b = ChartScale.climateAxes(tempMin: -12, tempMax: 18, rainMax: 260, maxTicks: 7)
    check(b.temp.lo < 0 && b.rain.lo < 0 && abs(b.temp.fraction(0) - b.rain.fraction(0)) < 1e-9 && b.rain.hi >= 260, "zero lines up with frosty winters \(b)")
}
