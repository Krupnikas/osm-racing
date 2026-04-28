#!/bin/bash
set -e

# Setup local Overpass API Docker containers for all game cities.
# Prerequisites: Docker Desktop running, osmium-tool installed (brew install osmium-tool)
#
# Usage:
#   ./setup_cities.sh           # Setup all cities
#   ./setup_cities.sh moscow    # Setup only Moscow
#   ./setup_cities.sh tbilisi dubai  # Setup Tbilisi and Dubai

cd "$(dirname "$0")"

# === City definitions ===
# Format: name|port|geofabrik_region|pbf_filename|bbox_for_extract
declare -A CITY_PORT=(
  [cherepovets]=12346
  [moscow]=12347
  [tbilisi]=12348
  [dubai]=12349
)

declare -A CITY_PBF_URL=(
  [cherepovets]="https://download.geofabrik.de/russia/northwestern-fed-district-latest.osm.pbf"
  [moscow]="https://download.geofabrik.de/russia/central-fed-district-latest.osm.pbf"
  [tbilisi]="https://download.geofabrik.de/europe/georgia-latest.osm.pbf"
  [dubai]="https://download.geofabrik.de/asia/gcc-states-latest.osm.pbf"
)

declare -A CITY_PBF_FILE=(
  [cherepovets]="northwestern-fed-district.osm.pbf"
  [moscow]="central-fed-district.osm.pbf"
  [tbilisi]="georgia.osm.pbf"
  [dubai]="gcc-states.osm.pbf"
)

# Bounding boxes: lon_min,lat_min,lon_max,lat_max (osmium format)
declare -A CITY_BBOX=(
  [cherepovets]="37.67,59.06,38.05,59.19"
  [moscow]="37.45,55.75,37.75,55.95"
  [tbilisi]="44.65,41.65,44.85,41.80"
  [dubai]="55.05,25.05,55.55,25.35"
)

# Nominatim city name for precache
declare -A CITY_PRECACHE_NAME=(
  [cherepovets]="Cherepovets"
  [moscow]="Moscow"
  [tbilisi]="Tbilisi"
  [dubai]="Dubai"
)

ALL_CITIES=(cherepovets moscow tbilisi dubai)

# Determine which cities to process
if [ $# -eq 0 ]; then
  CITIES=("${ALL_CITIES[@]}")
else
  CITIES=("$@")
fi

echo "=== OSM Racing: Local Overpass Setup ==="
echo "Cities: ${CITIES[*]}"
echo ""

# Check prerequisites
if ! command -v docker &>/dev/null; then
  echo "ERROR: docker not found. Install Docker Desktop first."
  exit 1
fi

if ! docker info &>/dev/null; then
  echo "ERROR: Docker daemon not running. Start Docker Desktop first."
  exit 1
fi

if ! command -v osmium &>/dev/null; then
  echo "ERROR: osmium-tool not found. Install with: brew install osmium-tool"
  exit 1
fi

mkdir -p source

for city in "${CITIES[@]}"; do
  port="${CITY_PORT[$city]}"
  pbf_url="${CITY_PBF_URL[$city]}"
  pbf_file="${CITY_PBF_FILE[$city]}"
  bbox="${CITY_BBOX[$city]}"
  container="overpass-${city}"
  extract="${city}.osm.bz2"

  echo ""
  echo "━━━ ${city^^} (port ${port}) ━━━"

  # Step 1: Download region PBF if not present
  if [ ! -f "$pbf_file" ]; then
    echo "Downloading ${pbf_file}..."
    curl -L -o "$pbf_file" "$pbf_url"
  else
    echo "PBF already exists: ${pbf_file}"
  fi

  # Step 2: Extract city bbox
  if [ ! -f "source/${extract}" ]; then
    echo "Extracting ${city} (bbox: ${bbox})..."
    osmium extract --bbox "$bbox" "$pbf_file" -o "$extract" --overwrite
    cp "$extract" "source/"
  else
    echo "Extract already exists: source/${extract}"
  fi

  # Step 3: Check if container already exists and is initialized
  if docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
    echo "Container ${container} already exists."
    if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
      echo "  Already running on port ${port}."
    else
      echo "  Starting..."
      docker start "$container"
      sleep 3
    fi
    continue
  fi

  # Step 4: Initialize Overpass database
  echo "Initializing Overpass database for ${city}..."
  docker run --rm \
    -e OVERPASS_META=yes \
    -e OVERPASS_MODE=init \
    -e OVERPASS_PLANET_URL="file:///db/source/${extract}" \
    -e OVERPASS_RULES_LOAD=10 \
    -e OVERPASS_USE_AREAS=false \
    -v "overpass_db_${city}:/db" \
    -v "$(pwd)/source:/db/source" \
    --name "${container}-init" \
    wiktorn/overpass-api

  echo "Database initialized for ${city}."

  # Step 5: Start the container
  echo "Starting ${container} on port ${port}..."
  docker run -d \
    -v "overpass_db_${city}:/db" \
    -v "$(pwd)/run.sh:/run.sh:ro" \
    --entrypoint /bin/bash \
    -p "${port}:80" \
    --restart unless-stopped \
    --name "$container" \
    wiktorn/overpass-api \
    /run.sh

  sleep 5

  # Fix permissions
  docker exec "$container" chmod 755 /db/ /db/db/ 2>/dev/null || true

  # Verify
  echo -n "Verifying API... "
  for i in $(seq 1 10); do
    if curl -s -d "data=[out:json];node(1);out 1;" \
        "http://localhost:${port}/api/interpreter" 2>/dev/null | \
        python3 -c "import json,sys; json.load(sys.stdin); print('OK')" 2>/dev/null; then
      break
    fi
    sleep 3
  done

  echo "${city} ready on http://localhost:${port}"
done

echo ""
echo "=== All containers ready ==="
echo ""
echo "To precache a city:"
for city in "${CITIES[@]}"; do
  port="${CITY_PORT[$city]}"
  name="${CITY_PRECACHE_NAME[$city]}"
  echo "  python3 tools/precache_overpass.py --city ${name} --local --port ${port}"
done
echo ""
echo "To precache ALL cities at once:"
echo "  ./tools/overpass-docker/precache_all.sh"
