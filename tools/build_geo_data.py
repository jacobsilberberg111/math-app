#!/usr/bin/env python3
"""Builds the geography data bundled with Margin (TutorNotes.swiftpm/Resources/geo_*.json).

Sources (all downloaded by this script into --cache):
  * Natural Earth v5.1.2 (public domain), https://www.naturalearthdata.com
      ne_50m_admin_0_countries, ne_50m_admin_1_states_provinces (Australia only),
      ne_50m_rivers_lake_centerlines, ne_10m_rivers_australia, ne_50m_lakes,
      ne_10m_populated_places_simple
  * Köppen-Geiger climate classification 1991-2020, Beck et al. (2023), CC BY 4.0
      "High-resolution (1 km) Köppen-Geiger maps for 1901-2099 based on constrained CMIP6
      projections", Scientific Data 10, 724. figshare article 21789074, koppen_geiger_tif.zip.

Requirements: python3 with numpy and Pillow, and mapshaper (npm i mapshaper; pass its path
with --mapshaper). Usage:

    python3 tools/build_geo_data.py --mapshaper /path/to/node_modules/.bin/mapshaper \
        --cache /tmp/geo-cache

Output format (decoded by Core/GeoData.swift):
  geo_world.json   {"format": "margin-geo-1", "q": 100, "arcs": base64, "countries": [...],
                    "states": [...], "rivers": [...], "lakes": [...]}
     Coordinates are quantized to 1/q degree: X = round((lon + 180) * q), Y = round((lat + 90) * q).
     "arcs" is a sequence of arcs; each arc is varint(count) followed by count points, each a
     pair of zigzag varints holding the difference from the previous point (the running point
     carries on from one arc to the next, starting at 0,0). Country and state rings are lists of
     arc indices as in TopoJSON (~i means arc i reversed); exterior rings run anticlockwise
     (positive area with lon right and lat up) and holes clockwise. Rivers are lists of lines,
     lakes lists of rings, each a single arc index.
  geo_places.json  {"format": "margin-places-1", "places": [[name, lon, lat, iso3, pop, flag, admin1]]}
     flag 1 = national capital, 2 = state/province capital, 0 = other.
  geo_koppen.json  {"format": "margin-koppen-1", "grids": [{"id", "res", "west", "north", "cols",
                    "rows", "rle"}]} where rle (base64) is, row by row from the north, runs of
     byte(class 0-30) + varint(length). Class 0 is sea; coastal sea cells are filled with the
     nearest land class so the layer can be clipped to the coastline.
"""

import argparse
import base64
import io
import json
import math
import os
import subprocess
import sys
import urllib.request
import zipfile

NE_BASE = "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/v5.1.2/geojson/"
KG_URL = "https://ndownloader.figshare.com/files/61012822"  # koppen_geiger_tif.zip (Beck et al. 2023)
Q = 100
SIMPLIFY = "40%"

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(HERE, "..", "TutorNotes.swiftpm", "Resources")


def fetch(url, path):
    if os.path.exists(path) and os.path.getsize(path) > 0:
        return path
    print("downloading", url)
    req = urllib.request.Request(url, headers={"User-Agent": "geo-data-builder"})
    with urllib.request.urlopen(req, timeout=600) as r, open(path + ".part", "wb") as f:
        while True:
            chunk = r.read(1 << 20)
            if not chunk:
                break
            f.write(chunk)
    os.replace(path + ".part", path)
    return path


def mapshaper(ms, args):
    cmd = [ms] + args
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        sys.exit("mapshaper failed: " + res.stderr)


# ---------------------------------------------------------------- encoding

def varint(n, out):
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return


def zigzag(n):
    return (n << 1) if n >= 0 else ((-n << 1) - 1)


class ArcStore:
    def __init__(self):
        self.arcs = []  # lists of (X, Y) ints

    @staticmethod
    def quantize(pts):
        out = []
        for lon, lat in pts:
            p = (int(round((lon + 180) * Q)), int(round((lat + 90) * Q)))
            if not out or out[-1] != p:
                out.append(p)
        if len(out) == 1:
            out.append(out[0])
        return out

    def add(self, pts):
        self.arcs.append(self.quantize(pts))
        return len(self.arcs) - 1

    def encode(self):
        out = bytearray()
        px = py = 0
        for a in self.arcs:
            varint(len(a), out)
            for x, y in a:
                varint(zigzag(x - px), out)
                varint(zigzag(y - py), out)
                px, py = x, y
        return base64.b64encode(bytes(out)).decode()


def topo_arcs(topo):
    """TopoJSON arcs as absolute lon/lat lists (handles quantized and plain output)."""
    tr = topo.get("transform")
    arcs = []
    for a in topo["arcs"]:
        if tr:
            x = y = 0
            pts = []
            for dx, dy in a:
                x += dx
                y += dy
                pts.append((x * tr["scale"][0] + tr["translate"][0], y * tr["scale"][1] + tr["translate"][1]))
            arcs.append(pts)
        else:
            arcs.append([(p[0], p[1]) for p in a])
    return arcs


def ring_points(ring, arcs):
    pts = []
    for i in ring:
        a = arcs[i] if i >= 0 else list(reversed(arcs[~i]))
        pts.extend(a if not pts else a[1:])
    return pts


def signed_area(pts):
    s = 0.0
    for i in range(len(pts)):
        x1, y1 = pts[i]
        x2, y2 = pts[(i + 1) % len(pts)]
        s += x1 * y2 - x2 * y1
    return s / 2


def polygons_of(geom):
    if geom.get("type") == "Polygon":
        return [geom["arcs"]]
    if geom.get("type") == "MultiPolygon":
        return geom["arcs"]
    return []


def oriented_rings(geom, arcs):
    """Rings (arc index lists) with exteriors anticlockwise and holes clockwise, plus each
    exterior's points (for bounding boxes)."""
    rings, exteriors = [], []
    for poly in polygons_of(geom):
        for k, ring in enumerate(poly):
            pts = ring_points(ring, arcs)
            area = signed_area(pts)
            want_positive = k == 0
            if (area > 0) != want_positive and area != 0:
                ring = [~i for i in reversed(ring)]
                pts = list(reversed(pts))
            rings.append(ring)
            if k == 0:
                exteriors.append(pts)
    return rings, exteriors


# ---------------------------------------------------------------- countries

def country_code(p):
    for k in ("ISO_A3", "ISO_A3_EH"):
        v = p.get(k)
        if v and v != "-99":
            # Two Australian external territories carry AUS as their "EH" code; keep them apart.
            if k == "ISO_A3_EH" and p.get("ADM0_A3") in ("IOA", "ATC"):
                break
            return v
    adm = p.get("ADM0_A3")
    return {"KOS": "XKX"}.get(adm, adm)


def focus_bbox(exteriors):
    """Bounding box of the country's main landmass plus the islands chained to it (gaps under
    4.5 degrees), so France means mainland France and Corsica, not French Guiana, and the USA
    the contiguous states. Longitudes may run past 180 for countries across the antimeridian."""
    rings = []
    for pts in exteriors:
        area = abs(signed_area(pts)) * math.cos(math.radians(sum(p[1] for p in pts) / len(pts)))
        rings.append((area, pts))
    rings.sort(key=lambda r: -r[0])
    main = rings[0][1]
    main_lon = sum(p[0] for p in main) / len(main)

    def shifted(pts):
        c = sum(p[0] for p in pts) / len(pts)
        k = round((main_lon - c) / 360)
        return [(x + 360 * k, y) for x, y in pts]

    def sample(pts, n=120):
        step = max(1, len(pts) // n)
        return pts[::step]

    included = [main]
    candidates = [shifted(r[1]) for r in rings[1:]]
    changed = True
    while changed:
        changed = False
        rest = []
        for c in candidates:
            sc = sample(c)
            near = False
            for inc in included:
                si = sample(inc)
                for x1, y1 in sc:
                    for x2, y2 in si:
                        dx = (x1 - x2) * math.cos(math.radians((y1 + y2) / 2))
                        if dx * dx + (y1 - y2) ** 2 < 4.5 ** 2:
                            near = True
                            break
                    if near:
                        break
                if near:
                    break
            if near:
                included.append(c)
                changed = True
            else:
                rest.append(c)
        candidates = rest
    xs = [p[0] for r in included for p in r]
    ys = [p[1] for r in included for p in r]
    w, e = min(xs), max(xs)
    if w < -180:
        w, e = w + 360, e + 360
    return [round(w, 2), round(min(ys), 2), round(e, 2), round(max(ys), 2)]


# Countries whose chained islands would stretch the default view (Svalbard, the Lau group).
FOCUS_OVERRIDES = {"NOR": [4.5, 57.9, 31.2, 71.2], "FJI": [176.8, -19.3, 181.6, -15.6]}


def build_world(ms, cache, work):
    countries_src = fetch(NE_BASE + "ne_50m_admin_0_countries.geojson", os.path.join(cache, "ne_50m_admin_0_countries.geojson"))
    states_src = fetch(NE_BASE + "ne_50m_admin_1_states_provinces.geojson", os.path.join(cache, "ne_50m_admin_1_states_provinces.geojson"))
    rivers_src = fetch(NE_BASE + "ne_50m_rivers_lake_centerlines.geojson", os.path.join(cache, "ne_50m_rivers_lake_centerlines.geojson"))
    lakes_src = fetch(NE_BASE + "ne_50m_lakes.geojson", os.path.join(cache, "ne_50m_lakes.geojson"))
    au_rivers_src = fetch(NE_BASE + "ne_10m_rivers_australia.geojson", os.path.join(cache, "ne_10m_rivers_australia.geojson"))

    c_topo = os.path.join(work, "countries.topojson")
    mapshaper(ms, ["-i", countries_src,
                   "-filter-fields", "ADM0_A3,ISO_A3,ISO_A3_EH,ISO_A2,ISO_A2_EH,NAME,NAME_LONG,ADMIN,FORMAL_EN,CONTINENT,REGION_UN,SUBREGION,LABEL_X,LABEL_Y,MIN_LABEL,MAPCOLOR7",
                   "-simplify", SIMPLIFY, "weighted", "keep-shapes",
                   "-o", "format=topojson", "no-quantization", c_topo])
    s_topo = os.path.join(work, "states.topojson")
    mapshaper(ms, ["-i", states_src, "-filter", "adm0_a3 == 'AUS'",
                   "-filter-fields", "name,iso_3166_2,postal,type_en,latitude,longitude",
                   "-simplify", SIMPLIFY, "weighted", "keep-shapes",
                   "-o", "format=topojson", "no-quantization", s_topo])
    r_json = os.path.join(work, "rivers.geojson")
    mapshaper(ms, ["-i", rivers_src, "-filter", "featurecla == 'River' && !!name",
                   "-filter-fields", "name,scalerank", "-simplify", SIMPLIFY, "weighted",
                   "-o", "format=geojson", r_json])
    au_json = os.path.join(work, "rivers_au.geojson")
    mapshaper(ms, ["-i", au_rivers_src, "-filter", "!!name", "-filter-fields", "name,scalerank",
                   "-simplify", "25%", "weighted", "-o", "format=geojson", au_json])
    l_json = os.path.join(work, "lakes.geojson")
    mapshaper(ms, ["-i", lakes_src, "-filter-fields", "name,scalerank,featurecla",
                   "-simplify", SIMPLIFY, "weighted", "keep-shapes",
                   "-o", "format=geojson", l_json])

    store = ArcStore()
    out = {"format": "margin-geo-1", "q": Q,
           "source": "Natural Earth 1:50m v5.1.2 (public domain), simplified with mapshaper " + SIMPLIFY}

    # Countries.
    topo = json.load(open(c_topo))
    arcs = topo_arcs(topo)
    base = len(store.arcs)
    for a in arcs:
        store.add(a)
    countries = []
    seen = set()
    for g in next(iter(topo["objects"].values()))["geometries"]:
        p = g["properties"]
        rings, exteriors = oriented_rings(g, arcs)
        if not rings:
            continue
        code = country_code(p)
        if code in seen:
            code = p["ADM0_A3"]
        seen.add(code)
        rec = {"a3": code}
        a2 = p.get("ISO_A2") if p.get("ISO_A2") not in (None, "-99") else p.get("ISO_A2_EH")
        if a2 and a2 != "-99":
            rec["a2"] = a2
        rec["n"] = p["NAME"]
        if p.get("NAME_LONG") and p["NAME_LONG"] != p["NAME"]:
            rec["nl"] = p["NAME_LONG"]
        aliases = []
        for k in ("NAME_LONG", "ADMIN", "FORMAL_EN"):
            v = p.get(k)
            if v and v != p["NAME"] and v not in aliases:
                aliases.append(v)
        if aliases:
            rec["alt"] = aliases
        rec["c"] = p["CONTINENT"]
        rec["reg"] = p["REGION_UN"]
        rec["sub"] = p["SUBREGION"]
        rec["lp"] = [round(p["LABEL_X"], 2), round(p["LABEL_Y"], 2)]
        rec["ml"] = p["MIN_LABEL"]
        rec["mc"] = p["MAPCOLOR7"]
        rec["bb"] = FOCUS_OVERRIDES.get(code) or focus_bbox(exteriors)
        rec["r"] = [[(i + base) if i >= 0 else ~(~i + base) for i in ring] for ring in rings]
        countries.append(rec)
    out["countries"] = countries

    # Australian states and territories.
    topo = json.load(open(s_topo))
    arcs = topo_arcs(topo)
    base = len(store.arcs)
    for a in arcs:
        store.add(a)
    states = []
    for g in next(iter(topo["objects"].values()))["geometries"]:
        p = g["properties"]
        rings, _ = oriented_rings(g, arcs)
        if not rings:
            continue
        iso = p["iso_3166_2"]
        if not iso.startswith("AU-") or "~" in iso:
            iso = "AU-JBT"  # Jervis Bay Territory has no ISO 3166-2 code
        states.append({"id": iso, "country": "AUS", "n": p["name"], "abbr": iso.split("-")[1],
                       "kind": p["type_en"], "lp": [round(p["longitude"], 2), round(p["latitude"], 2)],
                       "r": [[(i + base) if i >= 0 else ~(~i + base) for i in ring] for ring in rings]})
    out["states"] = states

    # Rivers (lines) and lakes (rings), each line its own arc.
    # Rivers: world rivers at 1:50m, plus Australian rivers from the 1:10m Australian layer that
    # the 1:50m set lacks (Murrumbidgee, Lachlan, Namoi…); their scale ranks 10–13 become 5–8.
    def in_australia(lines):
        return all(112 <= x <= 154 and -44 <= y <= -10 for l in lines for x, y in l)

    rivers = []
    au_names_50m = set()
    for path, au in ((r_json, False), (au_json, True)):
        for f in json.load(open(path))["features"]:
            g = f["geometry"]
            if not g:
                continue
            lines = g["coordinates"] if g["type"] == "MultiLineString" else [g["coordinates"]]
            lines = [l for l in lines if len(l) >= 2]
            name = f["properties"]["name"]
            if not lines:
                continue
            if not au and in_australia(lines):
                au_names_50m.add(name)
            if au and name in au_names_50m:
                continue
            rank = f["properties"]["scalerank"]
            if au:
                rank = max(5, rank - 5)
            rivers.append({"n": name, "rank": rank, "l": [store.add(l) for l in lines]})
    out["rivers"] = rivers
    lakes = []
    for f in json.load(open(l_json))["features"]:
        g = f["geometry"]
        if not g:
            continue
        polys = g["coordinates"] if g["type"] == "MultiPolygon" else [g["coordinates"]]
        idx = []
        for poly in polys:
            for k, ring in enumerate(poly):
                pts = ring
                area = signed_area(pts)
                if (area > 0) != (k == 0) and area != 0:
                    pts = list(reversed(pts))
                idx.append(store.add(pts))
        pr = f["properties"]
        lakes.append({"n": pr.get("name") or "", "rank": pr.get("scalerank") or 0,
                      "salt": pr.get("featurecla") == "Alkaline Lake", "r": idx})
    out["lakes"] = lakes
    out["arcs"] = store.encode()
    return out


# ---------------------------------------------------------------- places

def build_places(cache):
    src = fetch(NE_BASE + "ne_10m_populated_places_simple.geojson", os.path.join(cache, "ne_10m_populated_places_simple.geojson"))
    places = []
    for f in json.load(open(src))["features"]:
        p = f["properties"]
        cla = p.get("featurecla") or ""
        national = cla.startswith("Admin-0 capital") and not cla.endswith("alt")
        if not (p["scalerank"] <= 5 or national or p["adm0_a3"] == "AUS"):
            continue
        if cla in ("Scientific station", "Meteorological Station", "Historic place"):
            continue
        flag = 1 if national else (2 if cla.startswith("Admin-1 capital") else 0)
        lon, lat = f["geometry"]["coordinates"]
        places.append([p["name"], round(lon, 3), round(lat, 3), p["adm0_a3"], int(p["pop_max"] or 0), flag, p.get("adm1name") or ""])
    places.sort(key=lambda r: -r[4])
    return {"format": "margin-places-1",
            "source": "Natural Earth 1:10m populated places v5.1.2 (public domain)", "places": places}


# ---------------------------------------------------------------- Köppen-Geiger

def build_koppen(cache):
    import numpy as np
    from PIL import Image

    zpath = fetch(KG_URL, os.path.join(cache, "koppen_geiger_tif.zip"))
    with zipfile.ZipFile(zpath) as z:
        a05 = np.array(Image.open(io.BytesIO(z.read("1991_2020/koppen_geiger_0p5.tif"))))
        a01 = np.array(Image.open(io.BytesIO(z.read("1991_2020/koppen_geiger_0p1.tif"))))
    assert a05.shape == (360, 720) and a01.shape == (1800, 3600)

    def dilate(a, iters):
        a = a.copy()
        for _ in range(iters):
            zero = a == 0
            if not zero.any():
                break
            best = np.zeros_like(a)
            for dy, dx in [(0, 1), (0, -1), (1, 0), (-1, 0), (1, 1), (1, -1), (-1, 1), (-1, -1)]:
                sh = np.roll(np.roll(a, dy, 0), dx, 1)
                if dy == 1:
                    sh[0, :] = 0
                if dy == -1:
                    sh[-1, :] = 0
                best = np.where((best == 0) & (sh > 0), sh, best)
            a = np.where(zero, best, a)
        return a

    def mode_pool(a, k):
        h, w = a.shape
        blocks = a.reshape(h // k, k, w // k, k).transpose(0, 2, 1, 3).reshape(h // k, w // k, k * k)
        out = np.zeros((h // k, w // k), np.uint8)
        land = (blocks > 0).sum(axis=2)
        counts = np.stack([(blocks == c).sum(axis=2) for c in range(31)], axis=2)
        counts[:, :, 0] = 0
        out = counts.argmax(axis=2).astype(np.uint8)
        out[land * 2 < k * k] = 0
        return out

    def rle(a):
        out = bytearray()
        for row in a:
            v, c = int(row[0]), 0
            for x in row:
                x = int(x)
                if x == v:
                    c += 1
                else:
                    out.append(v)
                    varint(c, out)
                    v, c = x, 1
            out.append(v)
            varint(c, out)
        return base64.b64encode(bytes(out)).decode()

    grids = [{"id": "world-0.5", "res": 0.5, "west": -180, "north": 90, "cols": 720, "rows": 360, "rle": rle(dilate(a05, 2))}]
    a02 = mode_pool(a01, 2)
    grids.append({"id": "world-0.2", "res": 0.2, "west": -180, "north": 90, "cols": 1800, "rows": 900, "rle": rle(dilate(a02, 3))})
    # Australia at 0.1°: lon 112..154, lat -9..-44 (rows 990..1340, cols 2920..3340).
    au = a01[990:1340, 2920:3340]
    grids.append({"id": "australia-0.1", "res": 0.1, "west": 112, "north": -9, "cols": 420, "rows": 350, "rle": rle(dilate(au, 5))})
    return {"format": "margin-koppen-1",
            "source": "Beck et al. (2023), Köppen-Geiger 1991-2020, CC BY 4.0", "grids": grids}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mapshaper", required=True, help="path to the mapshaper executable")
    ap.add_argument("--cache", required=True, help="directory for downloads and intermediate files")
    ap.add_argument("--out", default=OUT_DIR)
    args = ap.parse_args()
    os.makedirs(args.cache, exist_ok=True)
    work = os.path.join(args.cache, "work")
    os.makedirs(work, exist_ok=True)

    for name, data in (("geo_world.json", build_world(args.mapshaper, args.cache, work)),
                       ("geo_places.json", build_places(args.cache)),
                       ("geo_koppen.json", build_koppen(args.cache))):
        path = os.path.join(args.out, name)
        with open(path, "w") as f:
            json.dump(data, f, separators=(",", ":"), ensure_ascii=False)
        print(name, os.path.getsize(path), "bytes")


if __name__ == "__main__":
    main()
