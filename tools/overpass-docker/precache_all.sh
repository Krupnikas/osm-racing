#!/bin/bash
set -e

# Precache all game cities from local Overpass Docker containers.
# Run setup_cities.sh first to create the containers.

cd "$(dirname "$0")/../.."

echo "=== Precaching all cities ==="

declare -A CITIES=(
  [Cherepovets]=12346
  [Moscow]=12347
  [Tbilisi]=12348
  [Dubai]=12349
)

for city in Cherepovets Moscow Tbilisi Dubai; do
  port="${CITIES[$city]}"
  echo ""
  echo "━━━ ${city} (port ${port}) ━━━"

  # Check if container is running
  container="overpass-$(echo "$city" | tr '[:upper:]' '[:lower:]')"
  if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
    echo "SKIP: container ${container} not running"
    continue
  fi

  python3 tools/precache_overpass.py --city "$city" --local --port "$port"
done

echo ""
echo "=== All cities precached ==="
