import Foundation

/// A real-data map on the page: outline, political, climate-zone (Köppen-Geiger) or choropleth
/// map with highlights, markers and routes. Rendered by MapRenderer.
///
/// Every field is optional so notes saved by older versions (or newer ones with more fields)
/// still decode. Real-world values in `choropleth` are always fetched by the app, never typed by
/// the tutor.
struct MapContent: Codable, Equatable {
    var title: String?
    /// "Source: … (year)" caption for any real data shown.
    var source: String?
    var subtitle: String?
    /// Name of the area shown, e.g. "Australia" or "World (Pacific-centred)".
    var region: String?
    /// Regional window; nil for a whole-world map.
    var bbox: GeoBBox?
    /// Central meridian of a world map (0, or 150 for a Pacific-centred map).
    var centralLon: Double?
    /// MapProjectionKind raw value (natural_earth, robinson, equirectangular).
    var projection: String?
    /// MapStyle raw value (political, outline, climate, data).
    var layer: String?
    var labels: Bool?
    var states: Bool?
    var graticule: Bool?
    var latitudeLines: Bool?
    var rivers: Bool?
    var oceanLabels: Bool?
    /// Köppen detail: "full" (all classes) or "groups" (A, B, C, D, E).
    var climateDetail: String?
    var choropleth: MapChoropleth?
    var highlights: [MapHighlight]?
    var markers: [MapMarker]?
    var routes: [MapRoute]?

    var style: MapStyle { MapStyle(rawValue: layer ?? "") ?? (choropleth != nil ? .data : .political) }
    var projectionKind: MapProjectionKind {
        if let p = projection, let k = MapProjectionKind(rawValue: p) { return k }
        return .naturalEarth
    }
    var isWorld: Bool { bbox == nil }
    var showLabels: Bool { labels ?? (style == .political) }
    var showStates: Bool {
        if let s = states { return s }
        guard let b = bbox else { return false }
        // Default on when Australia fills most of the view.
        return b.west < 140 && b.east > 140 && b.south < -26 && b.north > -26 && b.width < 75
    }
    var showGraticule: Bool { graticule ?? (style == .outline) }
    var showLatitudeLines: Bool { latitudeLines ?? false }
    var showRivers: Bool { rivers ?? ((style == .political || style == .outline) && (bbox.map { $0.width < 70 } ?? false)) }
    var showOceanLabels: Bool { oceanLabels ?? (style == .political) }
    var koppenGroupsOnly: Bool { climateDetail == "groups" }
}

enum MapStyle: String, CaseIterable {
    /// Countries in soft colours with names.
    case political
    /// Blank outline map to label (white land, pale sea).
    case outline
    /// Köppen-Geiger climate zones.
    case climate
    /// Choropleth of a real dataset.
    case data

    var displayName: String {
        switch self {
        case .political: return "Political"
        case .outline: return "Blank outline"
        case .climate: return "Climate zones"
        case .data: return "Data"
        }
    }
}

/// Values fetched from World Bank or Our World in Data, by ISO3 code, with the classes they were
/// binned into.
struct MapChoropleth: Codable, Equatable {
    /// Catalog id (e.g. "life_expectancy"), if the dataset came from the catalog.
    var dataset: String?
    /// "World Bank" or "Our World in Data".
    var provider: String
    /// Indicator code (World Bank) or grapher slug (Our World in Data).
    var code: String
    var indicator: String
    var unit: String?
    /// "2022", or "latest available, 2016–2023" when countries come from different years.
    var yearLabel: String
    var values: [String: Double]
    /// Per-country year when years differ.
    var years: [String: Int]?
    /// Interior class boundaries (ascending): class i is values < breaks[i]; the last class is the rest.
    var breaks: [Double]
    /// One colour per class (breaks.count + 1).
    var colors: [String]
    var diverging: Bool?
    /// Original data citation, e.g. "UNDP, Human Development Report (2025)".
    var citation: String?

    func classIndex(_ v: Double) -> Int {
        for (i, b) in breaks.enumerated() where v < b { return i }
        return breaks.count
    }

    func color(for code: String) -> String? {
        guard let v = values[code] else { return nil }
        let i = classIndex(v)
        return i < colors.count ? colors[i] : colors.last
    }
}

/// Countries or Australian states coloured as a category (not data), e.g. "Places with
/// endemic malaria", "Countries I've visited". The legend shows the label.
struct MapHighlight: Codable, Equatable {
    /// ISO3 country codes or state ids (AU-NSW).
    var codes: [String]
    var colorHex: String
    var label: String?
}

struct MapMarker: Codable, Equatable {
    var lon: Double
    var lat: Double
    var label: String?
    var colorHex: String?
    /// dot, star, square, triangle, pin.
    var symbol: String?
}

/// A route or flow arrow (migration, the spread of a disease, a journey).
struct MapRoute: Codable, Equatable {
    var points: [GeoPoint]
    var label: String?
    var colorHex: String?
    var dashed: Bool?
    var arrow: Bool?
    var curved: Bool?
    /// Line width in points (default 2.2).
    var width: Double?
}

/// Named areas the map tool and the insert sheet offer.
struct MapRegionPreset: Equatable {
    let id: String
    let name: String
    /// nil = whole world.
    let bbox: GeoBBox?
    let centralLon: Double

    static let all: [MapRegionPreset] = [
        MapRegionPreset(id: "world", name: "World", bbox: nil, centralLon: 0),
        MapRegionPreset(id: "world_pacific", name: "World (Pacific-centred)", bbox: nil, centralLon: 150),
        MapRegionPreset(id: "australia", name: "Australia", bbox: GeoBBox(west: 111.5, south: -44.5, east: 155, north: -9.5), centralLon: 133),
        MapRegionPreset(id: "nsw", name: "New South Wales", bbox: GeoBBox(west: 140.5, south: -38, east: 154, north: -28), centralLon: 147),
        MapRegionPreset(id: "murray_darling", name: "Murray–Darling Basin", bbox: GeoBBox(west: 137.5, south: -38.5, east: 153, north: -24), centralLon: 145),
        MapRegionPreset(id: "oceania", name: "Oceania", bbox: GeoBBox(west: 110, south: -50, east: 200, north: 2), centralLon: 155),
        MapRegionPreset(id: "asia_pacific", name: "Asia–Pacific", bbox: GeoBBox(west: 65, south: -48, east: 190, north: 52), centralLon: 128),
        MapRegionPreset(id: "pacific_islands", name: "Pacific Islands", bbox: GeoBBox(west: 140, south: -30, east: 220, north: 15), centralLon: 180),
        MapRegionPreset(id: "southeast_asia", name: "Southeast Asia", bbox: GeoBBox(west: 92, south: -12, east: 142, north: 24), centralLon: 117),
        MapRegionPreset(id: "east_asia", name: "East Asia", bbox: GeoBBox(west: 95, south: 18, east: 150, north: 54), centralLon: 122),
        MapRegionPreset(id: "south_asia", name: "South Asia", bbox: GeoBBox(west: 60, south: 5, east: 98, north: 38), centralLon: 79),
        MapRegionPreset(id: "asia", name: "Asia", bbox: GeoBBox(west: 25, south: -12, east: 150, north: 62), centralLon: 88),
        MapRegionPreset(id: "middle_east", name: "Middle East", bbox: GeoBBox(west: 25, south: 12, east: 63, north: 42), centralLon: 44),
        MapRegionPreset(id: "europe", name: "Europe", bbox: GeoBBox(west: -25, south: 34, east: 45, north: 71.5), centralLon: 10),
        MapRegionPreset(id: "africa", name: "Africa", bbox: GeoBBox(west: -19, south: -36, east: 53, north: 38), centralLon: 17),
        MapRegionPreset(id: "north_america", name: "North America", bbox: GeoBBox(west: -170, south: 7, east: -50, north: 75), centralLon: -110),
        MapRegionPreset(id: "central_america", name: "Central America and the Caribbean", bbox: GeoBBox(west: -118, south: 5, east: -59, north: 33), centralLon: -88),
        MapRegionPreset(id: "south_america", name: "South America", bbox: GeoBBox(west: -82, south: -56, east: -34, north: 13), centralLon: -58),
    ]

    static func find(_ s: String) -> MapRegionPreset? {
        let k = GeoCodec.normalize(s).replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
        if let p = all.first(where: { $0.id == k }) { return p }
        let aliases: [String: String] = [
            "the_world": "world", "globe": "world", "world_map": "world", "pacific_world": "world_pacific",
            "world_pacific_centred": "world_pacific", "world_pacific_centered": "world_pacific", "pacific_centred_world": "world_pacific",
            "asiapacific": "asia_pacific", "asia_and_the_pacific": "asia_pacific", "the_pacific": "pacific_islands", "pacific": "pacific_islands",
            "south_east_asia": "southeast_asia", "se_asia": "southeast_asia", "new_south_wales": "nsw",
            "murray_darling_basin": "murray_darling", "mdb": "murray_darling", "americas_north": "north_america",
            "caribbean": "central_america", "latin_america": "south_america", "middle_east_and_north_africa": "middle_east",
        ]
        if let id = aliases[k] { return all.first { $0.id == id } }
        return all.first { GeoCodec.normalize($0.name) == GeoCodec.normalize(s) }
    }
}
