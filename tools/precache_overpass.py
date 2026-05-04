#!/usr/bin/env python3
"""
Pre-cache Overpass API data for the game.

Generates the same cache files that the game's OSMLoader produces,
so chunks load instantly from cache instead of waiting for Overpass.

Usage:
    # Cache entire Cherepovets (auto-fetches city bbox from Nominatim):
    python3 tools/precache_overpass.py --city Cherepovets

    # Cache with explicit bbox:
    python3 tools/precache_overpass.py --bbox 59.10,37.85,59.18,38.05

    # Cache radius around spawn point:
    python3 tools/precache_overpass.py --radius-km 2.0

    # Dry run (show what would be fetched):
    python3 tools/precache_overpass.py --city Cherepovets --dry-run
"""

import json
import math
import os
import time
import argparse
import threading
import urllib.request
import urllib.parse
from concurrent.futures import ThreadPoolExecutor, as_completed

# === Game constants (must match osm_terrain_generator.gd / osm_loader.gd) ===
START_LAT = 59.149886  # from main.tscn
START_LON = 37.949370
CHUNK_SIZE = 210.0     # from main.tscn
QUERY_RADIUS = 315     # maxf(210, 150) + 210/2 = 315
CACHE_VERSION = 6

REMOTE_SERVERS = [
    "http://mc.skrup.ru:12346/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass-api.de/api/interpreter",
    "https://z.overpass-api.de/api/interpreter",
    "https://lz4.overpass-api.de/api/interpreter",
]
LOCAL_PORT = 12346
LOCAL_SERVER = f"http://localhost:{LOCAL_PORT}/api/interpreter"

# Defaults for remote mode (overridden for --local)
MAX_CONCURRENT = 4
PER_SERVER_INTERVAL = 1.0
HTTP_TIMEOUT = 60

CACHE_DIR = os.path.expanduser(
    "~/Library/Application Support/Godot/app_userdata/OSM Racing/osm_cache/"
)

# Active server list (set in main based on --local flag)
OVERPASS_SERVERS = []

# Thread-safe state
_server_locks = None
_server_last_req = None
_server_next = [0]
_counter_lock = threading.Lock()
_print_lock = threading.Lock()


def get_cache_key(lat: float, lon: float, radius: int) -> str:
    return f"osm_v{CACHE_VERSION}_{lat:.4f}_{lon:.4f}_{radius}.json"


def fetch_city_bbox(city_name: str) -> tuple:
    """Fetch city bounding box from Nominatim API. Returns (min_lat, min_lon, max_lat, max_lon)."""
    params = urllib.parse.urlencode({
        "city": city_name,
        "format": "json",
        "limit": 1,
    })
    url = f"https://nominatim.openstreetmap.org/search?{params}"
    req = urllib.request.Request(url)
    req.add_header("User-Agent", "OSMRacing-Precache/1.0")

    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json.loads(resp.read().decode("utf-8"))

    if not data:
        raise ValueError(f"City '{city_name}' not found on Nominatim")

    bb = data[0]["boundingbox"]  # [min_lat, max_lat, min_lon, max_lon]
    name = data[0].get("display_name", city_name)
    bbox = (float(bb[0]), float(bb[2]), float(bb[1]), float(bb[3]))
    print(f"City: {name}")
    print(f"  Nominatim bbox: {bbox[0]:.4f},{bbox[1]:.4f} -> {bbox[2]:.4f},{bbox[3]:.4f}")
    return bbox


def build_overpass_query(center_lat: float, center_lon: float, radius_m: int) -> str:
    lat_delta = radius_m / 111000.0
    lon_delta = radius_m / (111000.0 * math.cos(math.radians(center_lat)))
    b = f"{center_lat - lat_delta},{center_lon - lon_delta},{center_lat + lat_delta},{center_lon + lon_delta}"
    return f"""[out:json][timeout:30];
(
  way["highway"]({b});
  way["railway"="tram"]({b});
  way["building"]({b});
  way["landuse"]({b});
  way["natural"]({b});
  way["leisure"]({b});
  way["waterway"]({b});
  way["amenity"]({b});
  relation["building"]({b});
  relation["amenity"]({b});
  relation["highway"="pedestrian"]({b});
  relation["leisure"]({b});
  relation["natural"="water"]({b});
  relation["waterway"="riverbank"]({b});
  relation["man_made"="bridge"]({b});
  node["man_made"="chimney"]({b});
  node["natural"="tree"]({b});
  node["traffic_sign"]({b});
  node["highway"="street_lamp"]({b});
  node["entrance"]({b});
  node["shop"]({b});
  node["amenity"]({b});
  node["highway"="bus_stop"]({b});
  node["amenity"="bus_station"]({b});
  node["public_transport"="platform"]({b});
  node["public_transport"="station"]({b});
  node["railway"="tram_stop"]({b});
);
out body geom;
>;
out skel qt;
"""


def _nodes_equal(a, b):
    return abs(float(a["lat"]) - float(b["lat"])) < 1e-7 and abs(float(a["lon"]) - float(b["lon"])) < 1e-7


def _join_relation_rings(member_ways):
    """Join outer member ways head-to-tail into closed rings."""
    rings = []
    pending = list(member_ways)
    while pending:
        current = pending.pop(0)
        ring_nodes = list(current["nodes"])
        ring_way_ref = current["way_ref"]
        while True:
            if len(ring_nodes) < 2:
                break
            first = ring_nodes[0]
            last = ring_nodes[-1]
            if _nodes_equal(first, last):
                break  # closed
            found_idx = -1
            found_reverse = False
            for i, w in enumerate(pending):
                w_nodes = w["nodes"]
                if not w_nodes:
                    continue
                if _nodes_equal(w_nodes[0], last):
                    found_idx = i
                    found_reverse = False
                    break
                if _nodes_equal(w_nodes[-1], last):
                    found_idx = i
                    found_reverse = True
                    break
            if found_idx < 0:
                break
            next_member = pending.pop(found_idx)
            next_nodes = list(next_member["nodes"])
            if found_reverse:
                next_nodes.reverse()
            ring_nodes.extend(next_nodes[1:])
        if len(ring_nodes) >= 3:
            if not _nodes_equal(ring_nodes[0], ring_nodes[-1]):
                ring_nodes.append(ring_nodes[0])
        rings.append({"nodes": ring_nodes, "way_ref": ring_way_ref})
    return rings


def parse_osm_data(data: dict, center_lat: float, center_lon: float) -> dict:
    """Replicates OSMLoader._parse_osm_data() from GDScript."""
    nodes = {}
    ways = []
    way_by_id = {}
    point_objects = []
    entrance_nodes = []
    poi_nodes = []
    bus_stops = []
    tram_stops = []
    pedestrian_areas = []
    bridge_decks = []

    for el in data.get("elements", []):
        if el.get("type") == "node":
            nid = el["id"]
            nodes[nid] = {"lat": el["lat"], "lon": el["lon"]}

            tags = el.get("tags", {})
            if tags:
                if "entrance" in tags:
                    entrance_nodes.append({
                        "lat": el["lat"], "lon": el["lon"], "tags": tags
                    })

                if ("shop" in tags or "amenity" in tags) and ("name" in tags or "brand" in tags):
                    poi_nodes.append({
                        "id": el["id"], "lat": el["lat"], "lon": el["lon"], "tags": tags
                    })

                is_bus_stop = tags.get("highway") == "bus_stop"
                is_bus_station = tags.get("amenity") == "bus_station"
                pt = tags.get("public_transport", "")
                is_platform = pt in ("platform", "station")
                if is_bus_stop or is_bus_station or is_platform:
                    bus_stops.append({
                        "lat": el["lat"], "lon": el["lon"], "tags": tags
                    })

                if tags.get("railway") == "tram_stop":
                    tram_stops.append({
                        "lat": el["lat"], "lon": el["lon"], "tags": tags
                    })

                point_objects.append({
                    "lat": el["lat"], "lon": el["lon"], "tags": tags
                })

    for el in data.get("elements", []):
        if el.get("type") == "way":
            way_nodes = []
            for nid in el.get("nodes", []):
                if nid in nodes:
                    way_nodes.append(nodes[nid])

            if len(way_nodes) > 1:
                tags = el.get("tags", {})
                way_data = {
                    "id": el["id"],
                    "nodes": way_nodes,
                    "tags": tags,
                }
                ways.append(way_data)
                way_by_id[el["id"]] = way_nodes

    # Relations
    relation_member_way_ids = set()
    for el in data.get("elements", []):
        if el.get("type") == "relation":
            tags = el.get("tags", {})
            is_building_relation = "building" in tags or "amenity" in tags
            outer_member_ways = []  # list of {nodes, way_ref}
            for member in el.get("members", []):
                if member.get("type") == "way" and member.get("role", "outer") == "outer":
                    ref_id = member.get("ref", 0)
                    if is_building_relation and ref_id > 0:
                        relation_member_way_ids.add(ref_id)

                    member_nodes = []
                    geometry = member.get("geometry", [])
                    if geometry:
                        for pt in geometry:
                            member_nodes.append({
                                "lat": pt.get("lat", 0.0),
                                "lon": pt.get("lon", 0.0),
                            })
                    elif ref_id in way_by_id:
                        member_nodes.extend(way_by_id[ref_id])
                    if len(member_nodes) >= 2:
                        outer_member_ways.append({"nodes": member_nodes, "way_ref": ref_id})

            outer_rings = _join_relation_rings(outer_member_ways)

            if outer_rings:
                if tags.get("man_made") == "bridge":
                    for ring in outer_rings:
                        if len(ring["nodes"]) > 2:
                            bridge_decks.append({
                                "nodes": ring["nodes"],
                                "tags": tags,
                                "relation_id": el.get("id", 0),
                            })
                elif tags.get("highway") == "pedestrian" and tags.get("area") == "yes":
                    for ring in outer_rings:
                        if len(ring["nodes"]) > 2:
                            pedestrian_areas.append(ring["nodes"])
                else:
                    for ring in outer_rings:
                        if len(ring["nodes"]) > 2:
                            ways.append({
                                "id": ring["way_ref"],
                                "nodes": ring["nodes"],
                                "tags": tags,
                            })

    # Deduplicate building ways that are relation members
    if relation_member_way_ids:
        for wd in ways:
            wid = wd.get("id", 0)
            if wid and wid in relation_member_way_ids:
                t = wd.get("tags", {})
                t.pop("building", None)
                t.pop("amenity", None)

    # Convert node keys to strings (GDScript JSON stores dict keys as strings)
    str_nodes = {str(float(k)): v for k, v in nodes.items()}

    return {
        "center_lat": center_lat,
        "center_lon": center_lon,
        "nodes": str_nodes,
        "ways": ways,
        "point_objects": point_objects,
        "entrance_nodes": entrance_nodes,
        "poi_nodes": poi_nodes,
        "bus_stops": bus_stops,
        "tram_stops": tram_stops,
        "pedestrian_areas": pedestrian_areas,
        "bridge_decks": bridge_decks,
    }


def snap_to_global_grid(lat: float, lon: float) -> tuple:
    """Snap coordinates to a global grid aligned with CHUNK_SIZE.
    MUST match GDScript in osm_terrain_generator.gd exactly:
      1. Snap lat first (lat_step from chunk_size/111000)
      2. Use snapped lat for cos() in lon_step
      3. Snap lon with that lon_step
    Uses GDScript-compatible rounding: snapped(x, 0.0001) = floor(x/0.0001 + 0.5) * 0.0001"""
    lat_step = CHUNK_SIZE / 111000.0
    lat_idx = round(lat / lat_step)
    snapped_lat = _gd_snapped(lat_idx * lat_step, 0.0001)
    lon_step = CHUNK_SIZE / (111000.0 * math.cos(math.radians(snapped_lat)))
    lon_idx = round(lon / lon_step)
    snapped_lon = _gd_snapped(lon_idx * lon_step, 0.0001)
    return (snapped_lat, snapped_lon)


def _gd_snapped(value: float, step: float) -> float:
    """Replicate Godot's snapped() function: floor(value/step + 0.5) * step, then round to avoid float drift."""
    return round(math.floor(value / step + 0.5) * step, 10)


def generate_chunks_for_bbox(min_lat: float, min_lon: float, max_lat: float, max_lon: float):
    """Generate (chunk_lat, chunk_lon) for all game chunks covering the bbox using global grid."""
    lat_step = CHUNK_SIZE / 111000.0
    lon_step = CHUNK_SIZE / (111000.0 * math.cos(math.radians((min_lat + max_lat) / 2)))

    # Grid indices covering the bbox
    lat_min_idx = int(math.floor(min_lat / lat_step))
    lat_max_idx = int(math.ceil(max_lat / lat_step))
    lon_min_idx = int(math.floor(min_lon / lon_step))
    lon_max_idx = int(math.ceil(max_lon / lon_step))

    chunks = set()
    for lat_idx in range(lat_min_idx, lat_max_idx + 1):
        for lon_idx in range(lon_min_idx, lon_max_idx + 1):
            lat = lat_idx * lat_step
            lon = lon_idx * lon_step
            # Re-snap to handle rounding (matches game's roundf behavior)
            slat, slon = snap_to_global_grid(lat, lon)
            chunks.add((round(slat, 7), round(slon, 7)))

    chunks = sorted(chunks)
    n_lat = lat_max_idx - lat_min_idx + 1
    n_lon = lon_max_idx - lon_min_idx + 1
    print(f"  Grid: {n_lon} x {n_lat} = {len(chunks)} chunks")
    return chunks


def generate_chunks_for_radius(radius_km: float):
    """Generate (chunk_lat, chunk_lon) for all chunks within radius_km of start, using global grid."""
    lat_step = CHUNK_SIZE / 111000.0
    lon_step = CHUNK_SIZE / (111000.0 * math.cos(math.radians(START_LAT)))
    meters = radius_km * 1000

    # Convert radius to grid index range
    dlat = meters / 111000.0
    dlon = meters / (111000.0 * math.cos(math.radians(START_LAT)))

    lat_min_idx = int(math.floor((START_LAT - dlat) / lat_step))
    lat_max_idx = int(math.ceil((START_LAT + dlat) / lat_step))
    lon_min_idx = int(math.floor((START_LON - dlon) / lon_step))
    lon_max_idx = int(math.ceil((START_LON + dlon) / lon_step))

    chunks = []
    for lat_idx in range(lat_min_idx, lat_max_idx + 1):
        for lon_idx in range(lon_min_idx, lon_max_idx + 1):
            slat, slon = snap_to_global_grid(lat_idx * lat_step, lon_idx * lon_step)
            # Check distance from start
            dy = (slat - START_LAT) * 111000.0
            dx = (slon - START_LON) * 111000.0 * math.cos(math.radians(START_LAT))
            if math.sqrt(dx**2 + dy**2) <= meters + CHUNK_SIZE:
                chunks.append((round(slat, 7), round(slon, 7)))
    return chunks


def _pick_server() -> int:
    with _counter_lock:
        idx = _server_next[0] % len(OVERPASS_SERVERS)
        _server_next[0] += 1
    return idx


def _tprint(msg: str):
    with _print_lock:
        print(msg, flush=True)


def fetch_chunk(lat: float, lon: float, stats: dict) -> bool:
    """Fetch one chunk from Overpass, parse, and save to cache."""
    cache_key = get_cache_key(lat, lon, QUERY_RADIUS)
    cache_path = os.path.join(CACHE_DIR, cache_key)

    if os.path.exists(cache_path):
        with _counter_lock:
            stats["skipped"] += 1
        return True

    query = build_overpass_query(lat, lon, QUERY_RADIUS)
    encoded = urllib.parse.urlencode({"data": query}).encode("utf-8")

    for attempt in range(len(OVERPASS_SERVERS) * 2):
        server_idx = _pick_server()
        server_url = OVERPASS_SERVERS[server_idx]
        server_name = server_url.split("/")[2]

        # Per-server rate limit
        with _server_locks[server_idx]:
            now = time.time()
            wait = PER_SERVER_INTERVAL - (now - _server_last_req[server_idx])
            if wait > 0:
                time.sleep(wait)
            _server_last_req[server_idx] = time.time()

        try:
            req = urllib.request.Request(server_url, data=encoded)
            req.add_header("Content-Type", "application/x-www-form-urlencoded")
            with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
                raw = resp.read().decode("utf-8")

            data = json.loads(raw)
            parsed = parse_osm_data(data, lat, lon)

            os.makedirs(CACHE_DIR, exist_ok=True)
            with open(cache_path, "w") as f:
                json.dump(parsed, f)

            with _counter_lock:
                stats["fetched"] += 1
                total = stats["fetched"] + stats["skipped"]

            n_ways = len(parsed["ways"])
            _tprint(f"  OK [{total}/{stats['total']}] {cache_key} -- {n_ways} ways ({server_name})")
            return True

        except urllib.error.HTTPError as e:
            if e.code in (429, 503):
                _tprint(f"  .. {server_name} rate limited ({e.code}), waiting 10s...")
                time.sleep(10)
            else:
                _tprint(f"  !! HTTP {e.code} from {server_name}")
                time.sleep(2)
        except Exception as e:
            _tprint(f"  !! {server_name}: {e}")
            time.sleep(2)

    with _counter_lock:
        stats["failed"] += 1
    _tprint(f"  XX FAILED {cache_key}")
    return False


def main():
    global OVERPASS_SERVERS, MAX_CONCURRENT, PER_SERVER_INTERVAL, HTTP_TIMEOUT

    parser = argparse.ArgumentParser(description="Pre-cache Overpass data for the game")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--city", type=str,
                       help="City name — bbox fetched from Nominatim (e.g. Cherepovets)")
    group.add_argument("--bbox", type=str,
                       help="Explicit bbox: min_lat,min_lon,max_lat,max_lon")
    group.add_argument("--radius-km", type=float,
                       help="Radius around start point in km")
    parser.add_argument("--local", action="store_true",
                        help="Use local Docker Overpass (fast, no rate limits)")
    parser.add_argument("--port", type=int, default=0,
                        help="Local Overpass port (default: 12346)")
    parser.add_argument("--dry-run", action="store_true",
                        help="Only show what would be fetched")
    args = parser.parse_args()

    # Configure servers
    if args.local:
        port = args.port if args.port else LOCAL_PORT
        OVERPASS_SERVERS = [f"http://localhost:{port}/api/interpreter"]
        MAX_CONCURRENT = 8       # Local server can handle more
        PER_SERVER_INTERVAL = 0  # No rate limit needed
        HTTP_TIMEOUT = 30
        print(f"Mode: LOCAL Overpass (Docker, port {port})")
    else:
        OVERPASS_SERVERS = REMOTE_SERVERS
        print("Mode: REMOTE Overpass servers")

    # Determine chunks
    if args.city:
        bbox = fetch_city_bbox(args.city)
        chunks = generate_chunks_for_bbox(*bbox)
        label = args.city
    elif args.bbox:
        parts = [float(x) for x in args.bbox.split(",")]
        if len(parts) != 4:
            parser.error("--bbox must be min_lat,min_lon,max_lat,max_lon")
        chunks = generate_chunks_for_bbox(*parts)
        label = f"bbox {args.bbox}"
    else:
        chunks = generate_chunks_for_radius(args.radius_km)
        label = f"{args.radius_km}km radius"

    already_cached = sum(
        1 for lat, lon in chunks
        if os.path.exists(os.path.join(CACHE_DIR, get_cache_key(lat, lon, QUERY_RADIUS)))
    )

    to_fetch = len(chunks) - already_cached
    if args.local:
        est_min = to_fetch * 0.5 / MAX_CONCURRENT / 60
        est_max = to_fetch * 3 / MAX_CONCURRENT / 60
    else:
        est_min = to_fetch * 10 / MAX_CONCURRENT / 60
        est_max = to_fetch * HTTP_TIMEOUT / MAX_CONCURRENT / 60
    print(f"\nPre-cache: {len(chunks)} chunks ({label})")
    print(f"  Start point: {START_LAT}, {START_LON}")
    print(f"  Already cached: {already_cached}")
    print(f"  To fetch: {to_fetch}")
    print(f"  Estimated time: ~{max(1, est_min):.0f}-{est_max:.0f} min")
    print(f"  Cache dir: {CACHE_DIR}")

    if args.dry_run:
        print("\nDry run -- no requests sent.")
        return

    if to_fetch == 0:
        print("\nAll chunks already cached!")
        return

    print(f"\nFetching with {MAX_CONCURRENT} threads, {len(OVERPASS_SERVERS)} server(s)...\n")

    global _server_locks, _server_last_req
    _server_locks = [threading.Lock() for _ in OVERPASS_SERVERS]
    _server_last_req = [0.0] * len(OVERPASS_SERVERS)

    stats = {"fetched": 0, "skipped": already_cached, "failed": 0,
             "total": len(chunks)}

    start_time = time.time()

    with ThreadPoolExecutor(max_workers=MAX_CONCURRENT) as pool:
        futures = [pool.submit(fetch_chunk, lat, lon, stats) for lat, lon in chunks]
        for f in as_completed(futures):
            try:
                f.result()
            except Exception as e:
                _tprint(f"  !! Unexpected error: {e}")

    elapsed = time.time() - start_time
    print(f"\nDone in {elapsed:.0f}s -- fetched: {stats['fetched']}, "
          f"skipped: {stats['skipped']}, failed: {stats['failed']}")


if __name__ == "__main__":
    main()
