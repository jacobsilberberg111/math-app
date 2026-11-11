import Foundation

/// Tool definitions for real-data maps, charts and climate graphs. Static (the tool list must be
/// identical in every request for prompt caching), with the dataset catalog built in.
enum GeoTools {
    private typealias T = TutorTools

    /// {place} or {lat, lon}, used by markers and route points.
    private static let location: JSONValue = T.object([
        ("place", T.prop("string", "City, town, Australian state or country, e.g. \"Sydney\", \"Dubbo, NSW\", \"Lagos, Nigeria\", \"Kenya\". Looked up for you.")),
        ("lat", T.prop("number", "Latitude in degrees (south negative); use with lon instead of place.")),
        ("lon", T.prop("number", "Longitude in degrees (west negative).")),
    ], required: [])

    private static let colorString = T.prop("string", "Colour: red, blue, green, purple, orange, black, teal, pink, gray, yellow, or #RRGGBB.")

    static let definitions: [JSONValue] = [
        T.tool("map",
               """
               Draw an atlas-quality map from real geographic data (Natural Earth outlines; Köppen–Geiger climate zones; World Bank / Our World in Data statistics fetched live by the app). Every map gets a title, border, legend, scale bar, north arrow and source caption (BOLTSS). Layers: "political" (coloured countries, names), "outline" (blank outline map for the student to label: no names unless labels=true), "climate_zones" (Köppen–Geiger 1991–2020, Beck et al. 2023; climate_detail "groups" shows just A/B/C/D/E — good for biomes), "data" (choropleth of a dataset).
               NEVER type statistics yourself: for real-world numbers choose a `dataset` and the app downloads the values and picks the latest year with good coverage (or `year`). You may add categorical highlights (named countries/states in a colour with a legend label, e.g. "Countries visited", "Malaria-endemic (WHO 2023)") — never invent values in labels.
               Dataset catalog (use the id): \(GeoCatalog.promptList)
               Any other World Bank indicator: "worldbank:CODE" (e.g. worldbank:SP.RUR.TOTL.ZS); any Our World in Data grapher chart: "owid:slug" (the slug from ourworldindata.org/grapher/<slug>). Unknown codes return an error.
               Regions: \(MapRegionPreset.all.map(\.id).joined(separator: ", ")); or a country or Australian state name to zoom on it (e.g. "Indonesia", "NSW"); or bbox [west, south, east, north] (east may exceed 180 to cross the date line). World maps use Natural Earth projection (or robinson/equirectangular); "world_pacific" centres on the Pacific like Australian atlases. Australia maps show state borders.
               The result gives the map's element id, a data summary (highest/lowest countries, Australia's value and rank) and a formula converting lon/lat to page coordinates for this map, so you can annotate places with your other tools. Inserting a new map is the only way to change one: to revise it, delete the old map and draw a new one.
               """,
               T.object([
                ("page", T.page), ("x", T.x), ("y", T.y),
                ("width", T.prop("number", "Card width in points (default 560, fits the page).")),
                ("height", T.prop("number", "Card height (default: fits the region's shape plus legend).")),
                ("title", T.prop("string", "Map title, e.g. \"Life expectancy at birth, 2023\" or \"Climate zones of Australia\".")),
                ("subtitle", T.prop("string", "Optional line under the title.")),
                ("region", T.prop("string", "Region preset, country or Australian state (default world).")),
                ("bbox", ["type": "array", "items": ["type": "number"], "description": "[west, south, east, north] in degrees; overrides region."]),
                ("projection", T.enumProp(["natural_earth", "robinson", "equirectangular"], "World maps only (regional maps are equirectangular, scaled for their latitude).")),
                ("layer", T.enumProp(["political", "outline", "climate_zones", "data"], "What the map shows (default political; data when dataset is given).")),
                ("dataset", T.prop("string", "Catalog id, worldbank:CODE or owid:slug (layer data).")),
                ("year", T.prop("integer", "Data year (default: latest year with good coverage).")),
                ("climate_detail", T.enumProp(["full", "groups"], "Köppen detail: every class (default; world maps group the legend by A–E) or just the five main groups.")),
                ("labels", T.prop("boolean", "Country (and state) names (default on for political, off otherwise).")),
                ("states", T.prop("boolean", "Australian state and territory borders (default on when Australia fills the view).")),
                ("graticule", T.prop("boolean", "Lines of latitude and longitude with degree labels (default on for outline maps).")),
                ("latitude_lines", T.prop("boolean", "Equator, tropics and polar circles, labelled.")),
                ("rivers", T.prop("boolean", "Major rivers (default on for regional political/outline maps).")),
                ("ocean_labels", T.prop("boolean", "Ocean and sea names (default on for political maps).")),
                ("highlights", ["type": "array", "description": "Categorical highlights: places filled (or outlined on data/climate maps) in a colour, with a legend label.",
                                "items": T.object([
                                    ("places", ["type": "array", "items": ["type": "string"], "description": "Country names or ISO3 codes, or Australian states (NSW, Victoria…)."]),
                                    ("color", colorString),
                                    ("label", T.prop("string", "Legend text for this group.")),
                                ], required: ["places"])]),
                ("markers", ["type": "array", "description": "Points: cities, sites, outbreaks, the student's school.",
                             "items": T.object([
                                ("place", T.prop("string", "Place name (looked up), or use lat/lon.")),
                                ("lat", T.prop("number", "Latitude.")), ("lon", T.prop("number", "Longitude.")),
                                ("label", T.prop("string", "Label (default: the place name; \"\" for none).")),
                                ("color", colorString),
                                ("symbol", T.enumProp(["dot", "star", "square", "triangle"], "Default dot.")),
                             ], required: [])]),
                ("routes", ["type": "array", "description": "Arrows along a route: migration, trade, the spread of a disease, a journey.",
                            "items": T.object([
                                ("points", ["type": "array", "items": location, "description": "Stops in order (at least two)."]),
                                ("label", T.prop("string", "Short label, also shown in the legend.")),
                                ("color", colorString),
                                ("dashed", T.prop("boolean", "Dashed line.")),
                                ("curved", T.prop("boolean", "Curved flow arrow (default true).")),
                                ("arrow", T.prop("boolean", "Arrowhead at the end (default true).")),
                             ], required: ["points"])]),
               ], required: ["page"])),

        T.tool("chart",
               """
               Draw a chart card: "bar" (vertical columns), "horizontal_bar", "line", "scatter" (optional line of best fit), "pie", or "climate" (rainfall columns on the right axis + temperature line on the left — use climate_graph to make one for a real place). Axis titles with units, nice ticks, legend, title and source caption are drawn for you.
               Inline values are ONLY for data the student or their worksheet/textbook supplied, or results of an experiment; give `source` saying where they came from. For real-world statistics use `data` instead and the app downloads them (World Bank or Our World in Data time series for 1–6 countries, drawn as a line graph) — never type statistics from memory.
               """,
               T.object([
                ("page", T.page), ("x", T.x), ("y", T.y),
                ("width", T.prop("number", "Default 480 (520 for climate).")),
                ("height", T.prop("number", "Default 320 (360 for climate).")),
                ("type", T.enumProp(["bar", "horizontal_bar", "line", "scatter", "pie", "climate"], "Chart type.")),
                ("title", T.prop("string", "Chart title.")),
                ("subtitle", T.prop("string", "Optional line under the title.")),
                ("x_label", T.prop("string", "x-axis title with units, e.g. \"Time (min)\".")),
                ("y_label", T.prop("string", "y-axis title with units, e.g. \"Temperature (°C)\".")),
                ("y2_label", T.prop("string", "Right axis title (series with axis right).")),
                ("categories", ["type": "array", "items": ["type": "string"], "description": "Category labels for bar/line/pie (one per value). Climate charts default to months J–D."]),
                ("series", ["type": "array", "description": "Data series.",
                            "items": T.object([
                                ("name", T.prop("string", "Series name for the legend.")),
                                ("values", ["type": "array", "items": ["type": ["number", "null"]], "description": "One value per category (null = missing)."]),
                                ("points", ["type": "array", "items": ["type": "array", "items": ["type": "number"]], "description": "[x, y] pairs for scatter (or a line with numeric x)."]),
                                ("color", colorString),
                                ("axis", T.enumProp(["left", "right"], "Which y axis (default left).")),
                                ("style", T.enumProp(["bar", "line", "dashed"], "Override how the series is drawn (e.g. mixed bar + line).")),
                             ], required: ["name"])]),
                ("best_fit", T.prop("boolean", "Scatter: draw the least-squares line of best fit (its equation and r are returned).")),
                ("y_min", T.prop("number", "Force the y-axis minimum.")),
                ("y_max", T.prop("number", "Force the y-axis maximum.")),
                ("show_values", T.prop("boolean", "Write each bar's value on it.")),
                ("source", T.prop("string", "Where inline values came from, e.g. \"Class experiment, 12 May\" or \"Textbook p. 214\". Required with inline values.")),
                ("data", T.object([
                    ("dataset", T.prop("string", "Catalog id (see the map tool), worldbank:CODE or owid:slug.")),
                    ("countries", ["type": "array", "items": ["type": "string"], "description": "1–6 countries (names or ISO3)."]),
                    ("start_year", T.prop("integer", "Default 1990.")),
                    ("end_year", T.prop("integer", "Default: latest.")),
                ], required: ["dataset", "countries"])),
               ], required: ["page", "type"])),

        T.tool("climate_graph",
               """
               Make a standard geography climate graph for a real place: monthly rainfall columns (mm, right axis) and mean temperature line (°C, left axis), plus mean daily max and min, from 30 years of daily ERA5 reanalysis (1991–2020 averages, fetched by the app from Open-Meteo). Give a place name ("Dubbo", "Cairns, QLD", "Manaus, Brazil") or lat/lon. The result lists all 12 monthly values, annual rainfall, temperature range and the place's Köppen–Geiger zone so you can discuss it (seasonality, wet/dry seasons, hemisphere).
               """,
               T.object([
                ("page", T.page), ("x", T.x), ("y", T.y),
                ("place", T.prop("string", "Place name, optionally with state or country.")),
                ("lat", T.prop("number", "Latitude (with lon) instead of a name.")),
                ("lon", T.prop("number", "Longitude.")),
                ("title", T.prop("string", "Default \"Climate graph: <place>\".")),
                ("max_min", T.prop("boolean", "Also draw mean daily max and min temperature (default true).")),
                ("width", T.prop("number", "Default 520.")),
                ("height", T.prop("number", "Default 360.")),
               ], required: ["page"])),
    ]
}
