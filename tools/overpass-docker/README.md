# Pre-cache OSM data for the game

Pre-caches all Overpass API data for a city so chunks load instantly from disk instead of waiting for remote servers.

## Quick start (Cherepovets, ~15 min)

### 1. Prerequisites

- Docker Desktop running
- `osmium-tool` installed: `brew install osmium-tool`

### 2. Download and prepare OSM data

```bash
cd tools/overpass-docker

# Download Northwestern Federal District PBF (~600MB)
curl -L -o northwestern-fed-district.osm.pbf \
  "https://download.geofabrik.de/russia/northwestern-fed-district-latest.osm.pbf"

# Extract Cherepovets (~2.5MB)
osmium extract --bbox 37.67,59.06,38.05,59.19 \
  northwestern-fed-district.osm.pbf -o cherepovets.osm.bz2

# Copy to source dir
mkdir -p source
cp cherepovets.osm.bz2 source/
```

### 3. Initialize local Overpass

First run — builds the database (takes ~30 seconds for Cherepovets):

```bash
# Start init mode
docker-compose -f docker-compose.init.yml up

# Wait until you see "Overpass container initialization complete. Exiting."
# Then Ctrl+C
```

### 4. Run Overpass API

```bash
docker-compose up -d

# Wait ~10 seconds, then fix permissions and verify
docker exec overpass-cherepovets chmod 755 /db/ /db/db/
curl -s -d 'data=[out:json];node(59.14,37.94,59.15,37.95);out 1;' \
  http://localhost:12346/api/interpreter | python3 -c "import json,sys; json.load(sys.stdin); print('API OK')"
```

### 5. Pre-cache the city

```bash
cd ../..  # back to project root

# Cache entire Cherepovets (~7000 chunks, ~12 min)
python3 tools/precache_overpass.py --city Cherepovets --local

# Stop Docker when done
docker stop overpass-cherepovets
```

That's it! The game will now load all Cherepovets chunks from cache.

## Verify it works

Launch the game and check the console output:
- `OSM: CACHE HIT: ...` — loaded from cache (good)
- `OSM: CACHE MISS: ...` — fetching from Overpass (should be 0 for cached cities)

## Other cities

```bash
# Any city by name (auto-fetches bbox from Nominatim):
python3 tools/precache_overpass.py --city Moscow --local

# Or explicit bbox:
python3 tools/precache_overpass.py --bbox 55.55,37.35,55.95,37.85 --local

# Radius around spawn point:
python3 tools/precache_overpass.py --radius-km 3.0 --local

# Without Docker (slow, uses public Overpass servers):
python3 tools/precache_overpass.py --city Cherepovets
```

## Notes

- Cache dir: `~/Library/Application Support/Godot/app_userdata/OSM Racing/osm_cache/`
- The script skips already cached chunks, so you can safely re-run it
- Add `--dry-run` to see what would be fetched without making requests
- The game uses a global coordinate grid so the cache works regardless of spawn position
