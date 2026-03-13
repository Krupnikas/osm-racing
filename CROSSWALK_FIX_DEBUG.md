# Crosswalk Over Road Fix Debug Log

## Bug Description
Two related issues after switching to per-chunk parallel generation:
1. Footpath surface at height 0.23 renders over roads (not clipped by road corridors)
2. Missing zebra crossings where footway 52328712 crosses road 188983269

---

## Issue 1: Footpath renders over road — FIXED

### Root Cause
`_add_path_clipped_to_batch()` clips footpath polygons against `_chunk_terrain_roads` from 3x3 neighbourhood. With async chunk loading, terrain_roads count grows over time — early footways clipped with incomplete data.

### Fix: Deferred clipping at finalization
- `_add_path_clipped_to_batch()` stores raw polygons in `_deferred_path_polys[chunk_key]`
- `_finalize_road_batches_for_chunk()` flushes with full road corridor data
- Extracted: `_clip_path_polys_by_roads_and_intersections()`, `_add_path_polys_to_batch()`

---

## Issue 2: Missing zebra — FIXED (two sub-bugs)

### Sub-bug A: `_is_full_road_crossing` edge case
`after_pt` exactly coincided with road segment endpoint → `cross_product = 0.0` → `cross_b * cross_a = 0` not `< 0` → false.

**Fix:** Changed to `<= 0.0` with guard `absf(cross_before) > 0.01 or absf(cross_after) > 0.01`.

### Sub-bug B: Crossing only covered half the road
Crossing strip was drawn along footway ON-points (only 2 points near one road edge). For a sparse footway crossing a wide road, this covers a fraction of the width.

**Fix:** New `_detect_road_crossing()` returns road geometry (direction, width, segment). New `_build_crossing_strip()` builds a 2-point polyline perpendicular to road, spanning full road width. Crossing is now drawn across the entire road, centered at the footway-road intersection.

---

## Additional: Cross-chunk road detection
Added `_is_point_on_vehicle_road_neighborhood()` — queries road hash from 3x3 chunk neighbourhood. Ensures footways near chunk boundaries detect roads in adjacent chunks. (Turned out not to be the root cause for way 52328712 since its on-road points were in chunk -1,0 which had the road hash, but fixes potential edge cases.)

---

## Changes Summary

| File | Change |
|------|--------|
| `osm_terrain_generator.gd` | `_deferred_path_polys` dict + flush in `_finalize_road_batches_for_chunk()` |
| `osm_terrain_generator.gd` | `_clip_path_polys_by_roads_and_intersections()` — extracted clipping logic |
| `osm_terrain_generator.gd` | `_add_path_polys_to_batch()` — extracted batch insertion |
| `osm_terrain_generator.gd` | `_detect_road_crossing()` — returns road info dict (replaces bool-only check) |
| `osm_terrain_generator.gd` | `_build_crossing_strip()` — full-width perpendicular crossing strip |
| `osm_terrain_generator.gd` | `_is_point_on_vehicle_road_neighborhood()` — 3x3 chunk road hash query |
| `osm_terrain_generator.gd` | Fixed `_is_full_road_crossing()` zero cross-product edge case |
| `osm_terrain_generator.gd` | Cleanup: `_deferred_path_polys` in `_drop_chunk_runtime_state()` + global clear |
