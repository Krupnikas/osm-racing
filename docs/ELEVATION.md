# Elevation System

Real-world terrain elevation using SRTM30m data from OpenTopoData API.

## Overview

The game samples a 10x10 grid of elevation points per chunk from SRTM30m (30m native resolution). All surfaces — roads, terrain, sidewalks, parking lots, intersections, buildings, fences, lamps, vegetation — follow this elevation data.

Elevation is interpolated bilinearly between grid points. To match this interpolation precisely, large polygons and long road segments are subdivided at grid boundaries so each small piece lies on the correct bilinear surface.

## Architecture

### Files

| File | Role |
|------|------|
| `osm/elevation_loader.gd` | Fetches elevation data from API, caches to disk |
| `osm/osm_terrain_generator.gd` | Samples elevation, applies to all meshes |
| `tests/elevation_flyover_test.tscn` | Visual test scene for elevation |

### Data Flow

```
1. Chunk requested
2. ElevationLoader checks disk cache (user://osm_cache/elev_v4_*.json)
3. If miss → HTTP request to api.opentopodata.org/v1/srtm30m
4. API returns 100 elevation values (10x10 grid)
5. Grid stored in _chunk_elevation_data[chunk_key]
6. All mesh generation samples from this grid via _sample_elevation()
```

### Grid Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| GRID_RES | 10 | 10x10 = 100 points per chunk |
| GRID_STEP | 30m | Native SRTM30m resolution |
| GRID_PADDING | 30m | Overlap beyond chunk boundary each side |
| Coverage | 270m | 9 intervals x 30m = 270m (chunk is 210m) |
| Cache version | v4 | `elev_v4_{lat}_{lon}_{size}.json` |

### Rate Limiting

The OpenTopoData API allows 1 request/second. `ElevationLoader` enforces this with a static queue:
- `MAX_ACTIVE_REQUESTS = 1`
- `REQUEST_INTERVAL_MS = 1100` (slightly over 1s)
- All ElevationLoader instances share the queue via static vars

Elevation data persists in `_chunk_elevation_data` across chunk reloads — once fetched, it stays in memory for the session.

## Elevation Sampling

`_sample_elevation(world_x, world_z)` returns the interpolated height at any world position:

1. Finds which chunk contains the position
2. Looks up the 10x10 grid for that chunk
3. Computes normalized position within grid
4. Bilinear interpolation of 4 surrounding grid points

A static variant `_sample_elevation_static()` is used by worker threads (receives grid data explicitly instead of reading instance vars).

## Surface Subdivision

To avoid flat quads that diverge from the bilinear elevation surface, all surfaces are subdivided before applying elevation.

### Polygon surfaces (terrain, sidewalks, parking, intersections, landuse)

`_split_polygon_by_grid(poly, 10.0)` clips each polygon into 10m grid cells using `Geometry2D.intersect_polygons()`. Each cell is then triangulated independently. This ensures vertices exist at grid boundaries where elevation changes.

Applies to:
- Terrain ground mesh (`_finalize_terrain_mesh`)
- Sidewalk paths (`_add_path_polys_to_batch`)
- Parking surfaces (`_create_parking_surface`)
- Pedestrian areas (`_create_pedestrian_area`)
- Landuse/water polygons (`_create_polygon_mesh_with_texture`)
- Intersection patches (`_create_intersection_patch`)

### Road mesh (worker thread)

`_subdivide_for_elevation(points)` inserts vertices at every 10m grid crossing along a polyline. This runs in the worker thread after `_insert_chunk_edge_points()` so road quads are small enough to follow elevation.

The corridor centerline (used for terrain cutouts) is also subdivided before building corridors, so the cutout shape matches the elevated road mesh.

### Point objects (buildings, fences, lamps, signs, vegetation)

These sample elevation at their base position. Buildings use ground elevation at their footprint center. Fences sample elevation at each post position. Lamps and signs sample at their placement point.

## Feature Flag

```gdscript
@export var enable_elevation := true
```

When disabled, `_sample_elevation()` returns 0.0 — all surfaces are flat at Y=0.

CLI: `--terrain-only` disables buildings/vegetation/lamps but keeps elevation active.

## Testing

### Elevation Flyover Test

Scene: `tests/elevation_flyover_test.tscn`

Flies camera south at 100km/h for 60s over chess-pattern chunks. Terrain+roads only by default.

```bash
# Tbilisi (default, hilly terrain)
/Applications/Godot.app/Contents/MacOS/Godot --path . tests/elevation_flyover_test.tscn

# With all features
/Applications/Godot.app/Contents/MacOS/Godot --path . tests/elevation_flyover_test.tscn -- --with-all

# All chunks (no checkerboard)
/Applications/Godot.app/Contents/MacOS/Godot --path . tests/elevation_flyover_test.tscn -- --no-chess
```

Flags: `--no-chess`, `--with-buildings`, `--with-lamps`, `--with-curbs`, `--with-vegetation`, `--with-all`

Results saved to `user://elevation_flyover_test.json` and `.csv`.

## Cache

Elevation cache files: `~/Library/Application Support/Godot/app_userdata/OSM Racing/osm_cache/elev_v4_*.json`

Each file contains one chunk's 10x10 grid (~2KB). Safe to delete — will be re-fetched from API (slowly, 1 req/sec).
