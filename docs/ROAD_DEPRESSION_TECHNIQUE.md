# Road surface carving — physical depressions / pits (reusable technique)

Status: **shipped** for roadwork depressions. This is a general technique for
carving any *local* road-surface feature that must be **both visual and physical**
(pits, sunken patches, and — with positive displacement — speed bumps, ramps).

Screenshot of the result: `screenshots/cones_road_pit_after.png`.

## The hard requirement
The car must *physically* enter the feature. The road already has a large batched
`ConcavePolygonShape3D` collider. If any flat collider remains over the feature, the
wheel raycast (GEVP / `VehicleWheel3D`) hits the higher flat surface and the car never
dips. So a stacked patch under an unchanged road is useless — you must modify the road
itself.

## The one place that makes this clean
`osm/osm_terrain_generator.gd::_finalize_road_batches_for_chunk()` builds, per
`(chunk_key, texture_key)` batch:
- **visual** = `ArrayMesh` from `batch["vertices"/"uvs"/"uv2s"/"normals"/"indices"]` → `_rs_add_mesh(... Transform3D.IDENTITY)` (world-space, not a scene node).
- **collision** = `RoadBatchCollision_<tk>` from the **same** `batch["vertices"]/["indices"]`.

**Carve the batch arrays right after the `vertices.size()==0` guard, before the mesh
and the deferred collision are created.** Then visual and collision are the *same
vertices* by construction — no stale flat collider, no visual/collision disagreement.
Hook: `if enable_road_depressions and _road_depressions.has(chunk_key): _apply_road_depressions(...)`.

## The robust carve: grid-displace (NOT collar-stitch)
Road quads are huge (≤5 m long × 6–12 m wide), so a 1–1.5 m feature sits **inside one
quad's two triangles** — there are no vertices there to move.

**What works (`_carve_road_depression`):**
1. Split batch triangles into `keep` vs `rem` (overlap the footprint rect, in the
   feature's local `(dir, perp·side)` frame — `_tri_overlaps_rect`).
2. For **each** removed triangle, re-tessellate it into a uniform barycentric grid
   (`R = clampi(ceil(maxEdge/0.25), 2, 26)`), and push each grid vertex down by a smooth
   **depth field** (`_depression_depth`: 0 outside an irregular ellipse → `depth` at the
   bottom, deterministic sine jitter on the rim from a `way_id` seed).
3. UV/UV2 are **barycentric-interpolated from the host triangle** → continuous asphalt,
   same `texture_key` batch → same material on floor *and* walls automatically.
4. Normals from the **depth-field gradient** (finite difference) so the walls shade —
   flat-up normals make the pit nearly invisible.

A grid **always fully tiles** the triangle, so a hole is structurally impossible.

**What FAILED (don't repeat):** "remove the host triangle, stitch a collar (boundary
loop + ellipse ring) around the bowl." The collar triangulation (angle-zip *and*
`Geometry2D` keyhole/Delaunay) kept producing degenerate/empty results on a 3-vertex
host loop → a **triangular through-hole** with only the bowl bottom partly covering it
(cars fell through). Burned a lot of time here. Grid-displace replaced it entirely.

## Gotchas that cost time
- **Winding:** Godot's road faces are **clockwise-from-above → geometric normal points
  DOWN** (verified: 200/200 flat road faces had `normal.y < 0`). New triangles must
  match — `_push_tri` orients to `normal.y <= 0`. Get this wrong and every new face is a
  **back-face**: invisible through-hole in the visual *and* the collision raycast misses
  it (`ConcavePolygonShape3D.backface_collision = false`).
- **COW safety:** `var v = batch["vertices"]` is copy-on-write; appends don't touch the
  batch until you assign `batch["vertices"] = v` at the very end. So any early `return
  false` leaves the road untouched (fallback = no feature, never a broken road).
- **Overlapping road batches at intersections:** the worksite landed on a junction with
  `residential` (113.80) over an intersection patch (113.45, 0.35 m lower). The car drives
  on the **highest** layer, so carving just that one works — lower patches sit below the
  bowl and don't block. No need to relocate.
- **Registration timing:** registered in `_maybe_enqueue_road_works` (main thread, runs
  before finalize), deduped, and **cleared on chunk unload** (`_road_depressions.erase`)
  so it re-carves on reload (otherwise the `done` flag + dedup skip it).

## Knobs
- `enable_road_depressions` (bool), `debug_road_depressions` (bool, logs `[DEPRESSION]`
  + per-stage FAIL reasons).
- Size/shape in `_register_road_depression`: `depth` (0.10 m), `L` along-road (1.0 m),
  `W` across (auto 0.7–1.5 m to fit the cone-fenced strip), `slope` (0.22 m).
- Placement: in the strip **between the cone line and the curb** (`side`), near taper
  station ~cone #4 where the outboard strip is widest; skipped on roads too narrow.

## To extend later
- **Speed bump / ramp:** same carve, positive displacement (negate the depth field).
- **Manhole / patch:** depth ≈ 0, swap UV/material region (needs a second texture_key or
  a shader mask).
- **Multiple per worksite / clustered potholes:** register several descriptors per chunk.
