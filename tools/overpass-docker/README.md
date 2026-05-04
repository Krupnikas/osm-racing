# Overpass API for OSM Racing

Two setups: a **remote server** (mc.skrup.ru) used by the game at runtime, and **local Docker** for precaching.

## Remote server (mc.skrup.ru)

A single Overpass instance on `mc.skrup.ru:12346` serves all 4 game cities. It is the first server in the game's fallback list (`osm_loader.gd`).

### Architecture

- **Server**: `sergey@mc.skrup.ru` (4 CPU, 8GB RAM, Ubuntu)
- **Overpass container**: `overpass-cities` on port 12346, Docker volume `overpass_db_all` (local disk)
- **Source data**: `~/jotta/overpass/` (Jottacloud via rclone FUSE mount, 1PB)
- **Why local disk for DB**: Overpass dispatcher uses Unix domain sockets, which don't work on FUSE mounts. Source PBF/bz2 files live on jotta, but the running DB must be on a real filesystem.

### Cities in the instance

| City | Geofabrik region | PBF file | Extract bbox |
|------|-----------------|----------|-------------|
| Cherepovets | Northwestern Fed. District | northwestern.osm.pbf | 37.67,59.06,38.05,59.19 |
| Moscow | Central Fed. District | central.osm.pbf | 37.45,55.75,37.75,55.95 |
| Tbilisi | Georgia | georgia.osm.pbf | 44.65,41.65,44.85,41.80 |
| Dubai | GCC States | gcc-states.osm.pbf | 55.05,25.05,55.55,25.35 |

All 4 city extracts are merged into `all_cities.osm.bz2` (~103MB) and loaded into one Overpass instance.

### Managing the remote container

```bash
ssh sergey@mc.skrup.ru

# Status
docker ps | grep overpass

# Restart
docker restart overpass-cities

# Logs
docker logs overpass-cities --tail 20

# Stop
docker stop overpass-cities

# Start
docker start overpass-cities
```

### Adding a new city

```bash
ssh sergey@mc.skrup.ru

# 1. Download region PBF to jotta
curl -L -o ~/jotta/overpass/REGION.osm.pbf 'https://download.geofabrik.de/...'

# 2. Extract city bbox (lon_min,lat_min,lon_max,lat_max)
docker run --rm --entrypoint osmium -v ~/jotta/overpass:/data \
  stefda/osmium-tool extract --bbox LON_MIN,LAT_MIN,LON_MAX,LAT_MAX \
  /data/REGION.osm.pbf -o /data/CITY.osm.pbf --overwrite

# 3. Merge all city PBFs
docker run --rm --entrypoint osmium -v ~/jotta/overpass:/data \
  stefda/osmium-tool merge \
  /data/cherepovets.osm.pbf /data/moscow.osm.pbf /data/tbilisi.osm.pbf \
  /data/dubai.osm.pbf /data/CITY.osm.pbf \
  -o /data/all_cities.osm.pbf --overwrite

# 4. Convert to bz2
docker run --rm --entrypoint osmium -v ~/jotta/overpass:/data \
  stefda/osmium-tool cat /data/all_cities.osm.pbf \
  -o /data/all_cities.osm.bz2 --overwrite

# 5. Stop old container, remove volume, re-init
docker stop overpass-cities && docker rm overpass-cities
docker volume rm overpass_db_all

docker run --rm \
  -e OVERPASS_META=yes -e OVERPASS_MODE=init \
  -e OVERPASS_PLANET_URL=file:///db/source/all_cities.osm.bz2 \
  -e OVERPASS_RULES_LOAD=10 -e OVERPASS_USE_AREAS=false \
  -v overpass_db_all:/db -v ~/jotta/overpass:/db/source \
  wiktorn/overpass-api

# 6. Start container
docker run -d \
  -v overpass_db_all:/db \
  -v ~/jotta/overpass/run.sh:/run.sh:ro \
  --entrypoint /bin/bash \
  -p 12346:80 --restart unless-stopped \
  --name overpass-cities \
  wiktorn/overpass-api /run.sh

# 7. Verify
curl -s -d 'data=[out:json];node(1);out 1;' http://localhost:12346/api/interpreter
```

### Files on jotta (`~/jotta/overpass/`)

```
northwestern.osm.pbf   # 608MB - Geofabrik region (can delete after extract)
central.osm.pbf        # 861MB - Geofabrik region (can delete after extract)
georgia.osm.pbf        #  95MB - Geofabrik region (can delete after extract)
gcc-states.osm.pbf     # 600MB - Geofabrik region (can delete after extract)
cherepovets.osm.pbf    # 1.7MB - city extract
moscow.osm.pbf         #  31MB - city extract
tbilisi.osm.pbf        #  11MB - city extract
dubai.osm.pbf          #  23MB - city extract
all_cities.osm.pbf     #  67MB - merged
all_cities.osm.bz2     # 103MB - merged, used for Overpass init
run.sh                 # entrypoint script (fixes permissions, starts supervisord)
```

### RAM usage

~500MB–1GB for 4 small city extracts. The server has 8GB total, fits fine. For planet.osm.pbf (entire world) you'd need 32–64GB RAM — not feasible on this server.

---

## Local Docker (for precaching)

Pre-caches Overpass API data so chunks load instantly from disk cache.

### Prerequisites

- Docker Desktop running
- `osmium-tool`: `brew install osmium-tool`

### Quick start — all cities at once

```bash
cd tools/overpass-docker

# Download OSM data, extract cities, init Docker containers
./setup_cities.sh

# Precache all cities
./precache_all.sh
```

This sets up 4 separate containers (one per city):

| City | Port |
|------|------|
| Cherepovets | 12346 |
| Moscow | 12347 |
| Tbilisi | 12348 |
| Dubai | 12349 |

### Setup a single city

```bash
cd tools/overpass-docker
./setup_cities.sh moscow

cd ../..
python3 tools/precache_overpass.py --city Moscow --local --port 12347
```

### Precache commands

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

### Managing local containers

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

- Game cache dir: `~/Library/Application Support/Godot/app_userdata/OSM Racing/osm_cache/`
- The precache script skips already cached chunks — safe to re-run
- Add `--dry-run` to see what would be fetched
- Region PBF downloads are large (600MB–1.3GB) but only needed once
- City extracts are small (2–30MB), Overpass init takes 30s–2min each
