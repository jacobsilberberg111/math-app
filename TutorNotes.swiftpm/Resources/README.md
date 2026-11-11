# Bundled data

Files here ship inside the app (Package.swift `resources: [.process("Resources")]`; project.yml
lists this folder too). Load them with `AppResources.url(_:ext:)`.

## Geo data

Used by maps (`map` tool, Insert → Map) and climate lookups. Built by
`tools/build_geo_data.py` (needs Python 3 with numpy and Pillow, and
[mapshaper](https://github.com/mbloch/mapshaper): `npm i mapshaper`):

    python3 tools/build_geo_data.py --mapshaper node_modules/.bin/mapshaper --cache /tmp/geo-cache

The script downloads every source itself; the format is documented at the top of the script and
decoded by `Core/GeoData.swift`.

| File | Contents | Source and licence |
|---|---|---|
| `geo_world.json` (≈280 KB) | 242 countries (ISO3 codes, names, continent, label points; France and Norway get their real codes, Kosovo XKX) as a shared-arc topology simplified to 40% with mapshaper and quantised to 0.01°; Australian states and territories; major rivers (plus Australian rivers from the 1:10m Australian layer); lakes | [Natural Earth](https://www.naturalearthdata.com) 1:50m admin-0 and admin-1, rivers, lakes, and 1:10m Australian rivers, v5.1.2. Public domain. |
| `geo_places.json` (≈70 KB) | ≈1,300 places for markers by name: capitals, large cities, and Australian towns | Natural Earth 1:10m populated places v5.1.2. Public domain. |
| `geo_koppen.json` (≈180 KB) | Köppen–Geiger climate classes for 1991–2020 on run-length-encoded grids: world at 0.5° and 0.2° (majority of 0.1° cells), Australia at 0.1°. Coastal sea cells take the nearest land class so the layer can be clipped to the coastline. | Beck, H. E. et al. (2023). High-resolution (1 km) Köppen-Geiger maps for 1901–2099 based on constrained CMIP6 projections. *Scientific Data* 10, 724. [figshare 21789074](https://doi.org/10.6084/m9.figshare.21789074), CC BY 4.0 (credited in every climate map's caption). Colours are the paper's legend colours. |

Live data (not bundled, fetched when a map or chart is made, cached for a week in Caches/GeoData):
World Bank Indicators API (CC BY 4.0), Our World in Data grapher CSVs (CC BY 4.0; original sources
named in each caption), Open-Meteo geocoding and historical weather API (ERA5 reanalysis,
Copernicus/ECMWF; CC BY 4.0). Choropleth colour ramps follow ColorBrewer (Apache 2.0).
