# Local Overpass API for OSM Racing

Pre-caches Overpass API data so chunks load instantly from disk.

## Prerequisites

- Docker Desktop running
- `osmium-tool`: `brew install osmium-tool`

## Quick start — all cities at once

```bash
cd tools/overpass-docker

# Download OSM data, extract cities, init Docker containers
./setup_cities.sh

# Precache all cities
./precache_all.sh
```

This sets up 4 containers:

| City | Port | Geofabrik region |
|------|------|-----------------|
| Cherepovets | 12346 | Northwestern Federal District |
| Moscow | 12347 | Central Federal District |
| Tbilisi | 12348 | Georgia |
| Dubai | 12349 | GCC States |

## Setup a single city

```bash
cd tools/overpass-docker

# Only Moscow
./setup_cities.sh moscow

# Then precache
cd ../..
python3 tools/precache_overpass.py --city Moscow --local --port 12347
```

## Precache commands

```bash
# Cherepovets (port 12346, default)
python3 tools/precache_overpass.py --city Cherepovets --local

# Moscow (port 12347)
python3 tools/precache_overpass.py --city Moscow --local --port 12347

# Tbilisi (port 12348)
python3 tools/precache_overpass.py --city Tbilisi --local --port 12348

# Dubai (port 12349)
python3 tools/precache_overpass.py --city Dubai --local --port 12349

# Dry run (show chunk count without fetching)
python3 tools/precache_overpass.py --city Dubai --local --port 12349 --dry-run
```

## Managing containers

```bash
# Stop all
docker stop overpass-cherepovets overpass-moscow overpass-tbilisi overpass-dubai

# Start all
docker start overpass-cherepovets overpass-moscow overpass-tbilisi overpass-dubai

# Remove all (keeps data volumes)
docker rm overpass-cherepovets overpass-moscow overpass-tbilisi overpass-dubai

# Remove data volumes too
docker volume rm overpass_db_cherepovets overpass_db_moscow overpass_db_tbilisi overpass_db_dubai
```

## Notes

- Cache dir: `~/Library/Application Support/Godot/app_userdata/OSM Racing/osm_cache/`
- The script skips already cached chunks — safe to re-run
- Add `--dry-run` to see what would be fetched
- PBF downloads are large (600MB–1.3GB) but only needed once
- City extracts are small (2–30MB), init takes 30s–2min each
