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

## Issue 3: Sidewalk doesn't reach curb (grass gap) — FIXED

Committed `868e465`.



### History
- **March 2** (`0c066f9`, krupnikas): Added `_add_path_clipped_to_batch()` — sidewalks built as corridor polygons clipped by same road corridors as terrain. Sidewalk edges aligned perfectly with curbs.
- **March 7** (`ef6ec9e`, krupnikas): "Fix trees on roads" commit also added `Geometry2D.offset_polygon(road_corridor, 0.5)` before clipping sidewalks (line 5211). This inflates road corridors by 0.5m, pushing the sidewalk clip edge 0.5m inward from the curb.

### Root Cause
`_clip_path_polys_by_roads_and_intersections()` inflates each road corridor by 0.5m before clipping sidewalk polygons. The curb sits at the original road corridor edge. Result: 0.5m grass strip between curb and sidewalk.

Terrain clipping does NOT inflate — only sidewalk clipping does. The inflation was added as a side-effect of the trees-on-roads fix and wasn't needed for sidewalk correctness.

### Fix
Remove the 0.5m inflation from `_clip_path_polys_by_roads_and_intersections()`. Use the road corridor as-is (same as terrain clipping).

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

---

## Issue 4: Crossing at 23224748×45777988 — wrong angle + not edge-to-edge — IN PROGRESS

### Problem
Footway 45777988 crosses road 23224748. The crossing was drawn at wrong angle and didn't span edge-to-edge. `_build_crossing_strip()` used road_dir from spatial hash segment which didn't match actual road direction at intersection point.

### Attempted fix: edge points
Changed crossing logic to use actual road edge points (from `_find_road_edge_point()` binary search) instead of always using `_build_crossing_strip()`. Added fallback: use edge points when `edge_span >= road_w * 0.7`, otherwise use perpendicular strip.

### Debug output (footway 45777988)
```
# First instance (39 points):
on_road=[true, false, ..., true, ..., true,true,true,true,true, false,...]

# Crossing at i=17 (road 23224748):
  edge_span=1.72  road_w=12.00  → fallback to _build_crossing_strip()
  Problem: road_w=12 is WRONG for a 2-lane road (~6m). Spatial hash returns wrong width.
  edge_span=1.72 means only 2 on-road points very close together.

# Crossing at i=32:
  edge_span=10.62  road_w=5.00  → uses edge points (10.62 > 5*0.7=3.5)

# Second instance (20 points):
# Crossing at i=10:
  edge_span=10.73  road_w=10.00  → uses edge points
# Crossing at i=19:
  edge_span=11.05  road_w=10.00  → uses edge points
```

### Attempt 1: Use edge points, fallback to `_build_crossing_strip()` if edge_span < road_w*0.7
**Result:** FAILED — For i=17, edge_span=1.72 < road_w*0.7=8.4, so uses `_build_crossing_strip()`. But `_detect_road_crossing(last_off_road_pt, smoothed_points[i])` with distant off-road points found WRONG road (w=12, road_dir=(0.29,-0.96)). Strip drawn at wrong location/angle. User sees nothing.

### Attempt 2: Pass edge points to `_detect_road_crossing` instead of off-road points
**Result:** FAILED — Edge points (1.72m apart) are both on same side of road centerline → cross_product check fails → `road_info` empty → `is_full=false` → no crossing drawn at all.

### Attempt 3: Two-stage detection — edge points first, then off-road points with `mid` override
- First try `_detect_road_crossing(on_start, on_end)`
- If empty, try `_detect_road_crossing(last_off_road_pt, smoothed_points[i])` but override `road_info["mid"]` to on-road center
**Result:** FAILED — Off-road detection finds wrong road again. Override mid doesn't help because road_dir and road_width are still from wrong road.

### Attempt 4: `_find_nearest_road_at_point(on_mid)` — no cross-product check
Added new function that just finds nearest road segment at a point without crossing validation.
**Result:** FAILED — Same problem: nearest road at on_mid=(-117.92,-37.96) is the 12m road, not road 23224748. Spatial hash at this location has a wider road closer.

### Root cause analysis
The fundamental issue: **on-road midpoint is near TWO roads**, and the spatial hash returns the wrong one (12m instead of ~6m). All attempts to use spatial hash to identify the road at this crossing fail because a wider road is closer in the hash.

The i=17 on-road segment has only 3 points: current_pts=[pt0, pt_mid_maybe, edge_pt]. edge_span=1.72m. The footway barely touches the road — the road edge binary search (`_find_road_edge_point`) finds two points very close together because the footway crosses at a sharp angle or just clips the road corner.

### What has NOT been tried
1. **Don't use spatial hash for road_dir/road_width at all for short segments** — use the footway's own off-road→on-road→off-road direction to determine crossing angle, and use a fixed reasonable width
2. **Extend edge points outward** — take direction from edge_pt[0]→edge_pt[1], extend both points outward along that direction to span a reasonable road width (e.g., 8m)
3. **Use the off-road points DIRECTLY as crossing endpoints** — `last_off_road_pt` and `smoothed_points[i]` are by definition on opposite sides of the road. Clip them to road corridor to get exact edge-to-edge crossing
4. **Investigate WHY edge_span is only 1.72m** — the road is ~6m wide, so _find_road_edge_point should produce points ~6m apart. Maybe the binary search or the on_road classification is wrong at this location.

### Next step: Option 4 — investigate the 1.72m edge_span
If the road is ~6m and the footway crosses it, edge points should be ~6m apart. 1.72m suggests either:
- The footway only clips the road corner (not a full crossing)
- `_find_road_edge_point` binary search converges to wrong location
- The on_road array at i=17 is wrong (point 17 is not really on road 23224748)

Need to print the actual coordinates of smoothed_points[16], smoothed_points[17], smoothed_points[18] and the edge points to understand the geometry.

### Investigation results (detailed coordinates)
```
# 39-point instance, i=17 crossing:
off→on at i=17: edge_pt=(-117.10, -37.72)  prev=(-112.29, -36.31) cur=(-117.47, -37.83)
on→off at i=18: edge_pt=(-118.75, -38.19)  prev=(-117.47, -37.83) cur=(-122.87, -39.38)
edge_span = 1.72m (entry to exit)
```
OSM confirms: node 2590150339 (59.1240011, 37.9801471) is SHARED between footway 45777988 and road 23224748. Crossing is real and full.

**Why edge_span=1.72m:** Smoothed points are ~5.5m apart. Footway crosses road at moderate angle. Only ONE sample point (i=17) lands on-road. Binary search converges entry/exit edge points close together (1.72m) because both binary searches converge toward the same region between consecutive sample points.

**Why crossing is invisible:** `_build_crossing_strip` and `_find_nearest_road_at_point` both find a DIFFERENT wider road (12m) near the on-road midpoint. Strip is drawn perpendicular to that wrong road, centered at its edge — far from the actual crossing location on road 23224748.

### Attempt 5: Use footway direction for short on-road segments
For edge_span < 4m: build crossing using footway direction (last_off_road → next_off_road), centered at on-road midpoint, spanning 8m. Don't rely on spatial hash at all.

Key insight: `last_off_road_pt` = (-112.29, -36.31) and `smoothed_points[i]` = (-122.87, -39.38) are on opposite sides of the road by definition. Their direction IS the crossing direction. Distance = ~11m, so 8m road width fits.

**Result:** Crossing coordinates look correct in debug: `final=[(-112.16, -36.29), (-123.69, -39.63)]` (~12m span along footway direction). But user still sees nothing!

### Discovery: Crossing mesh never built — batch finalization ordering bug

**Root cause found:** `_process_footway_incremental()` adds crossing data to `_road_batch_data[chunk_key]["crossing"]` via `_add_road_to_batch_fast()`. But footway processing runs INSIDE `_process_road_queue()` BEFORE the finalization round-robin. If the chunk was already finalized (removed from `_pending_batch_chunks`), the newly added crossing/intersection batch data is NEVER built into a mesh.

**Execution order in `_process_road_queue()`:**
1. Apply road results from worker threads
2. Process deferred footways → adds "crossing"/"intersection" to `_road_batch_data`
3. Finalization round-robin → builds meshes from `_road_batch_data` for chunks in `_pending_batch_chunks`

If step 3 already completed for this chunk in a previous frame, new batch data from step 2 is orphaned.

### Fix: Re-enqueue chunk after adding crossing
After `_add_road_to_batch_fast()` for crossing, check if chunk is in `_pending_batch_chunks`. If not, add it. This ensures the finalization picks up the new crossing data.

**Result:** Re-enqueue implemented. Debug confirms `[DBG FINALIZE] chunk=-1,-1 key=crossing verts=24` — crossing mesh IS built. But user STILL can't see it.

### Attempt 6: Debug marker (red cube) at crossing midpoint

Added bright red emissive cube (MeshInstance3D) at crossing midpoint via scene tree (`parent.add_child`). Cube IS visible at the correct location on Архангельская — confirms crossing coordinates are correct. But crossing mesh (via RenderingServer `_rs_add_mesh`) is invisible.

**Discovery: Z-fighting with primary road.** Primary road `height_offset=0.010` + random `z_offset` (up to 0.003) = up to **0.013**. Crossing `height_offset=0.013` + its own `z_offset` (could be 0) = **0.013**. Road mesh can render ON TOP of crossing mesh.

Secondary roads (height_offset=0.008) don't have this problem — 0.005 gap is enough.

### Attempt 7: Raise crossing height_offset to 0.017

Changed crossing from 0.013→0.017, intersection from 0.012→0.016. This guarantees crossing is above any road (max road=0.012+0.003=0.015).

**Result:** CROSSING IS NOW VISIBLE! Zebra stripes appear at the red cube location on Архангельская. But crossing doesn't span edge-to-edge — gaps between crossing edges and curbs.

### Attempt 8: Add +2m overshoot to crossing span

For short edge_span crossings, changed `half_span = road_w * 0.5` → `half_span = road_w * 0.5 + 2.0` to compensate for angled footway crossing. Also increased default from 4.0→5.0.

**Result:** FAILED — user reports "ничего не изменилось" (nothing changed). The +2m overshoot may not be enough, OR the re-enqueue creates a second finalization that overwrites the first, OR the issue is that `road_w=12` is already too large and the crossing extends far beyond the actual road.

### Analysis: Why edge-to-edge fails

The road is drawn 12m wide (ROAD_WIDTHS["primary"]=12.0) but it's a oneway=yes, lanes=2 road (~7m real width). The crossing uses `road_w=12` from the spatial hash, creating a 16m span (12+4 overshoot). The crossing extends ~4-5m into grass on each side. The visible portion on the road IS edge-to-edge (12m of road covered by 16m strip), but the crossing may appear offset from center.

**Root issue:** ROAD_WIDTHS doesn't account for oneway/lanes. A primary oneway 2-lane road gets 12m width instead of ~7m. This affects:
1. Road surface width (too wide)
2. Spatial hash road_w (inflated)
3. Crossing span (based on inflated road_w)
4. Curb placement (at 12m, not 7m)

### Attempt 8 re-test: confirmed with clean restart

After killing Godot and clean restart, screenshot shows crossing IS visible and wider than attempt 7. But it's OFF-CENTER: extends into grass on LEFT, doesn't reach curb on RIGHT.

### Attempt 9: Center crossing on off-road midpoint instead of edge_pts midpoint

Screenshot confirms: crossing extends into grass on LEFT but doesn't reach curb on RIGHT. `on_mid` = midpoint of edge_pts (1.72m segment near one edge of road). Edge_pts cluster near one side because only 1 sample point lands on-road.

**Fix:** Center crossing at `(last_off_road_pt + smoothed_points[i]) * 0.5` — midpoint of the two off-road points which are on OPPOSITE sides of the road. This is the true road center for a through-crossing.

- `last_off_road_pt` = (-112.29, -36.31) — before road
- `smoothed_points[i]` = (-122.87, -39.38) — after road
- New center = (-117.58, -37.845) vs old on_mid = (-117.92, -37.96)

### Attempt 9 result: FAILED
Centering on off-road midpoint didn't help — road itself is still drawn 12m wide, so crossing at 7m center doesn't match 12m curbs.

### Attempt 10: Lane-aware road widths — FIXED

**Root cause confirmed:** `ROAD_WIDTHS["primary"] = 12.0` is for a 4-lane bidirectional primary. Road 23224748 is `oneway=yes, lanes=2` — should be `2 × 3.5 = 7m`.

**Fix:** Added `_get_road_width(tags)` static helper:
- If `lanes` tag present and valid (1-8): `lanes * LANE_WIDTH` (3.5m per lane)
- Otherwise: fallback to `ROAD_WIDTHS.get(highway_type, 5.0)`

Replaced all 5 `ROAD_WIDTHS.get()` calls that have access to `tags`:
1. Spatial hash (Phase 1+2 worker) — line 3042
2. Intersection detection — line 3114
3. Spatial hash (chunk processing) — line 3756
4. `_add_road_segments_to_hash` — line 3912
5. `_compute_road_geometry_thread` (road surface mesh) — line 3934

One `ROAD_WIDTHS.get()` left unchanged (line 3610): intersection circle sizing uses road type string only (no tags), fine as-is.

**Result:** Road 23224748 now drawn 7m wide. Road surface, curbs, spatial hash, and crossing all use correct width. Crossing spans edge-to-edge.

---

## Changes Summary (updated)

| File | Change |
|------|--------|
| `osm_terrain_generator.gd` | `LANE_WIDTH = 3.5`, `_get_road_width(tags)` static helper |
| `osm_terrain_generator.gd` | 5× replaced `ROAD_WIDTHS.get()` → `_get_road_width(tags)` |
| `osm_terrain_generator.gd` | Crossing height_offset 0.013→0.017, intersection 0.012→0.016 |
| `osm_terrain_generator.gd` | Short edge_span: center on off-road midpoint, use footway direction |
| `osm_terrain_generator.gd` | Re-enqueue chunk for batch finalization after adding crossing |
