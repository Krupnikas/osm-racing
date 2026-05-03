#!/usr/bin/env python3
"""Fetch one OSM chunk around each World Map location's spawn point and
save it into the project (ui/assets/location_chunks/) so the World Map
screen can render a tiny preview without touching the game's runtime
cache or its full OSM loader.
"""

import json
import os
import sys
import urllib.request
import urllib.parse
import math
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)
OUT_DIR = os.path.join(PROJECT, "ui", "assets", "location_chunks")

LOCATIONS = [
    ("cherepovets",     59.150406, 37.948805),
    ("noviy_vek",       59.123567, 37.982864),
    ("ledoviy_dvorets", 59.089216, 37.917488),
    ("oktyabrsky_most", 59.113453, 37.903733),
    ("moscow",          55.860580, 37.599646),
    ("tbilisi",         41.723972, 44.730502),
    ("dubai",           25.208591, 55.344100),
]

# ~315m radius — same QUERY_RADIUS the game uses, so the preview frames
# the spawn point with the same surroundings the player sees on load.
RADIUS_M = 315

REMOTE_SERVERS = [
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass-api.de/api/interpreter",
    "https://z.overpass-api.de/api/interpreter",
    "https://lz4.overpass-api.de/api/interpreter",
]


def overpass_query(lat: float, lon: float, radius_m: int) -> str:
    lat_d = radius_m / 111000.0
    lon_d = radius_m / (111000.0 * math.cos(math.radians(lat)))
    bb = f"{lat - lat_d},{lon - lon_d},{lat + lat_d},{lon + lon_d}"
    return f"""[out:json][timeout:30];
(
  way["highway"]({bb});
  way["building"]({bb});
  way["natural"]({bb});
  way["waterway"]({bb});
  way["landuse"]({bb});
);
out body geom;
>;
out skel qt;
"""


def fetch(name: str, lat: float, lon: float) -> bool:
    out_path = os.path.join(OUT_DIR, f"{name}.json")
    if os.path.exists(out_path):
        print(f"  [skip ] {name} -> {out_path}")
        return True

    query = overpass_query(lat, lon, RADIUS_M)
    body = urllib.parse.urlencode({"data": query}).encode()

    for server in REMOTE_SERVERS:
        try:
            req = urllib.request.Request(server, data=body)
            req.add_header("Content-Type", "application/x-www-form-urlencoded")
            with urllib.request.urlopen(req, timeout=60) as resp:
                raw = resp.read().decode("utf-8")

            data = json.loads(raw)

            # Strip down to the smallest payload we need for a 2D preview:
            # roads (highway), buildings, water — node + way geometries only.
            ways = []
            for el in data.get("elements", []):
                if el.get("type") != "way":
                    continue
                geom = el.get("geometry") or []
                if len(geom) < 2:
                    continue
                tags = el.get("tags", {})
                kind = None
                if "highway" in tags:
                    kind = "road"
                elif "building" in tags:
                    kind = "building"
                elif tags.get("natural") == "water" or "waterway" in tags:
                    kind = "water"
                elif "landuse" in tags:
                    kind = "landuse"
                if kind is None:
                    continue
                ways.append({
                    "kind": kind,
                    "tags": {k: tags.get(k) for k in ("highway", "building", "natural", "waterway", "landuse") if k in tags},
                    "pts": [[p["lat"], p["lon"]] for p in geom],
                })

            preview = {
                "center": [lat, lon],
                "radius_m": RADIUS_M,
                "ways": ways,
            }
            os.makedirs(OUT_DIR, exist_ok=True)
            with open(out_path, "w") as f:
                json.dump(preview, f)

            print(f"  [ok   ] {name}: {len(ways)} ways  ({server.split('/')[2]})")
            return True

        except Exception as e:
            print(f"  ..    {name}: {server.split('/')[2]} -> {e}")
            time.sleep(1)
            continue

    print(f"  [FAIL ] {name}")
    return False


def main() -> int:
    print(f"Fetching {len(LOCATIONS)} location previews to {OUT_DIR}\n")
    fails = 0
    for name, lat, lon in LOCATIONS:
        if not fetch(name, lat, lon):
            fails += 1
        time.sleep(1)
    print(f"\nDone. Failures: {fails}")
    return 0 if fails == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
