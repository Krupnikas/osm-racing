# Traffic Lights & Stop-Lines — Implementation Plan (v1)

**Status:** 📋 Planned — awaiting approval. No code written yet.
**Source of truth:** the answered research questionnaire (folded in below). Placement is OSM-driven, not the old center-placed model.

---

## 0. Scope (locked decisions)

- Place traffic lights at OSM `highway=traffic_signals` nodes, on the correct side of the approach, facing approaching cars.
- Replace/disable the old procedural placeholder lights (intersection-center).
- Lights can glow; **v1 lighting mode = blinking yellow** (emissive only). Architecture leaves a hook for a future red/yellow/green cycle.
- Draw **stop lines** on signalized approaches, upstream of (never overlapping) the pedestrian crossing.
- Deterministic chunk streaming/reload, dedup by stable OSM node id.
- Self-tested by the implementer (launch `main.tscn`, inspect every loaded signal), not handed to the user.

---

## 1. Codebase findings (anchors the plan relies on)

| Concern | Current state | File:line |
|---|---|---|
| Overpass query (runtime) | No `highway=traffic_signals`; arg list is `% [bbox × 28]` | osm/osm_loader.gd:247-282 |
| Node parse | `point_objects` keep only `{lat,lon,tags}` (id dropped); `poi_nodes` keep `id` | osm/osm_loader.gd:392-442 |
| Returned data dict | `{nodes, ways, point_objects, poi_nodes, bus_stops, ...}` | osm/osm_loader.gd:~559-571 |
| Cache version (runtime) | `CACHE_VERSION := 7`, key `osm_v%d_..` | osm/osm_loader.gd:28, 145-150 |
| Cache version (precache) | `CACHE_VERSION = 6` (**already divergent**), own query+parser | tools/precache_overpass.py:37, 98-130, 185+ |
| Old placeholder light | spawned at intersection node when `("primary"/"secondary") in road_types and node_road_count>=3`; placed at center + axis offset | osm/osm_terrain_generator.gd:4658-4674 |
| Placeholder builder | static pole + box + 3 emissive spheres, no orientation, no dedup, `_infrastructure_queue` | osm/osm_terrain_generator.gd:23425-23538 |
| `enable_traffic_lights` flag | export, default true | osm/osm_terrain_generator.gd:122 |
| Intersection data | positions/radii/angles/types/roads/contours/curb_contours/spatial_hash | osm/osm_terrain_generator.gd:198-207 |
| Per-arm data | `_intersection_roads[i]=[{direction,width},..]` (no class/oneway/way_id) | osm/osm_terrain_generator.gd:4138-4150 |
| Nearest helpers | `_find_nearest_intersection`, `_find_nearby_intersection`, `_pfence_nearest_intersection` (linear fallback) | :26720, :26742, :22135 |
| Curb finder | `_find_road_edge_point(p1,p1_on_road,p2,ck)` | osm/osm_terrain_generator.gd:19437-19448 |
| Right-hand-traffic frame | `curb_sign` (-1 left/+1 right), `lane_dir = tangent*(-curb_sign)`, `center_dir = -curb_dir`; `RIGHT_SIDE_OFFSET:=0.75` | :11437-11443; traffic/road_network.gd:64 |
| Nearest road | `_find_nearest_road_at_point`, road spatial hash `_query_road_hash` | (used by pfence ~:22205) |
| Crossing geometry | `_detect_road_crossing`→`road_info{mid,road_dir,road_width,road_p1,road_p2}`; `_build_crossing_strip`→2-pt curb-to-curb | :19333, :19418 |
| Marking render | ArrayMesh quad + `marking_texture` in wet_road.gdshader; per-chunk per-texture_key batch | shaders/wet_road.gdshader:92-94; :8572-8584 |
| Marking z-stack | crossing +0.017, intersection +0.016, base below, hash jitter 0–0.0005 | :8502, :8650-8652 |
| Marking texture registry | `_road_textures["marking_<key>"]`, generated in texture_generator.gd | :1093, :9004-9021; textures/texture_generator.gd:775-897 |
| Deferred-retry pattern | `_deferred_pfence_queue`, `PFENCE_RETRY`, `pfence_max_retries:=300`, processed with frame budget in `_process` | :22029-22099, :14424-14426 |
| Dedup pattern | `_created_<x>_keys` + `_<x>_keys_by_chunk[ck]`, erased on unload | :3369-3399 |
| Real-light cap | `LAMP_MAX_ACTIVE_LIGHTS:=48`, distance cull, shadows off | :438, :18145-18163 |
| Emissive pattern | StandardMaterial3D `emission_enabled`, energy ~5–15 (lamp globe/bulb) | :18687-18690, :23966-23968 |
| Night API | autoload `NightModeManager`, `signal night_mode_changed(enabled)`, uniform `is_night_global` | night_mode/night_mode_manager.gd:7 |
| Debug marker pattern | `_pfence_debug_marker(ck,pos,color)` unshaded sphere in group; gated logs `_emit_road_debug` | :22464-22478, :17535-17559 |
| Furniture clearance | `_prop_near_furniture`, `PROP_MIN_SPACING:=25`, integer-grid furniture hash | :22913-22946 |
| Closest analog to copy | **pedestrian-fence system** (anchor-to-intersection, side via `sdot`, curb projection, deferred-retry) | :22094-22217 |

**Reality check baked into the plan:** OSM does mark these signals, but the pipeline does not fetch them today, so without §2 the feature renders zero lights and looks "done."

---

## 2. Data-pipeline changes

1. **Runtime query** — osm/osm_loader.gd:247-282
   - Add one line inside the union: `node["highway"="traffic_signals"](%s);`
   - Add one more `bbox` to the `% [...]` arg list (28 → 29) — **easy off-by-one to miss; the query silently substitutes wrong if the count is off.**
2. **Cache version** — osm/osm_loader.gd:28: `CACHE_VERSION := 7` → `8`. Comment: "v8: added node[highway=traffic_signals]". This forces a refetch; stale v7 caches are ignored (otherwise zero lights).
3. **Precache script** — tools/precache_overpass.py
   - `build_overpass_query` (:98-130): add the same `node["highway"="traffic_signals"]({b});` line.
   - `CACHE_VERSION = 6` → `8` (**align to the loader**, currently divergent — if it stays 6 the precached files won't match the loader's `osm_v8_` key and will never be cache-hit).
   - `parse_osm_data` (:185+): add the same traffic-signal extraction as §3 and include it in the serialized cache dict.
4. **Cache invalidation note:** because both the loader and precache produce `osm_v8_*`, any existing `osm_v6_*`/`osm_v7_*` files are dead weight (harmless, ignored). Optional: a one-line note in INSTALL/CHANGELOG that re-precache is needed.

**Verify (M1):** after the change, log the count of `traffic_signals` parsed per area; expect non-zero in central Cherepovets.

---

## 3. Parser / data-model changes

- **osm/osm_loader.gd `_parse_osm_data`** (the node loop at :392-442): add a branch mirroring `poi_nodes` so the **id is preserved**:
  - if `tags.get("highway","") == "traffic_signals"`: append to a new `traffic_signals` array `{ "id": element.id, "lat", "lon", "tags" }`.
  - Add `"traffic_signals": traffic_signals` to the returned dict (~:559-571).
  - **Verify the generic `point_objects` path does not also act on this node.** A `highway=traffic_signals` node currently *also* lands in `point_objects` (it has tags). Before assuming that's harmless, **check whether any generic prop / point-object placement step consumes `point_objects`** (osm_terrain_generator.gd "points" phase, ~:4680+) and would create something from a signal node. If so, **either exclude `highway=traffic_signals` from `point_objects`** (skip the generic append for it) **or gate it out in the consumer**. The **dedicated `traffic_signals` array is the only source for traffic-light placement**, and **no generic prop/placeholder object may be created from a traffic-signal node** (else duplicate/garbage objects appear even when the TL system is correct).
- **tools/precache_overpass.py `parse_osm_data`**: same extraction + include `"traffic_signals"` in the cached JSON, so precached caches carry it.
- **Consumer** — osm/osm_terrain_generator.gd: read `osm_data.get("traffic_signals", [])` in a new processing step (see §4). Each entry keeps its `id` (the dedup key root) and `tags` (read optional `direction` / `traffic_signals:direction`).

Data model passed around per signal:
```
{ id:int, pos:Vector2 (local XZ), tags:Dictionary }
```

---

## 4. Placement algorithm

### 4.1 Terminology (defined precisely; no camera/player-relative terms)

- **road_dir (tangent):** unit vector along the matched road way at the nearest segment.
- **approach_dir:** unit vector a car drives **as it approaches the intersection** = from the signal toward the intersection along the road. **Primary source = intersection geometry:** `sdot = (signal_pos - inter_center).dot(road_dir)`; `approach_dir = road_dir * -signf(sdot)`.
- **`direction`/`traffic_signals:direction` tags — use with care:** these `forward/backward` values are only meaningful relative to the **original OSM way node order**. Apply them **only if** the matched `road_dir` is known to be aligned with that way order (i.e. the segment direction provably follows the way's node sequence). If the matched local segment direction is **not guaranteed** to follow OSM way order, **do not** apply `forward/backward` — fall back to the geometry-inferred `approach_dir` above and **log the tag as informational only**. (Blindly applying `forward/backward` to an arbitrary local segment can flip the light to the wrong approach.)
- **lane_dir:** reuse the existing frame (:11437-11443). For the approaching kerb-side lane, `lane_dir == approach_dir`; `curb_sign = +1` selects the **right curb** for right-hand traffic.
- **upstream / downstream:** upstream = `-approach_dir` (back, away from intersection); downstream = `+approach_dir` (into the intersection).
- **near-side / far-side:** near-side = the curb the approaching car reaches **before** entering the junction (upstream of the intersection curb contour). far-side = across the junction. v1 places on the **near-side**.
- **right curb:** the carriageway edge on the right of `approach_dir`, found with `_find_road_edge_point(...)` then offset outward by a small curb offset (reuse the fence's `pfence_sidewalk_offset`-style constant). Side chosen via `curb_sign=+1` — **do not re-derive raw perpendicular signs; reuse the project frame and confirm visually.**
- **facing direction:** the signal head faces the oncoming car, i.e. faces **upstream**. `yaw` orients the head toward `-approach_dir` (so an approaching driver sees the lit face). Use the existing `atan2` idiom (as crossing signs do, :10764).

### 4.2 Steps (per signal node)

1. lat/lon → local XZ (existing geo→local conversion).
2. **Match road:** `_find_nearest_road_at_point(pos)` within radius (e.g. 25 m). No road → reject `noroad` (logged). Get `road_dir`, `width`, `way_id`.
3. **Match intersection:** `_find_nearest_intersection(pos, R)` then `_pfence_nearest_intersection` fallback. **Not found yet → return RETRY** (deferred queue, §8). Exhausted retries with still no intersection → before rejecting, check whether the signal can reasonably be associated with a nearby signalized crossing / junction context; if it genuinely cannot, **reject and log as `midblock_signal_v2`** (a *deliberate v2-scope skip*, e.g. pedestrian/mid-block signal — **not** a generic `nointer` failure). This keeps the logs honest: a clearly-named v2 limitation, not a mysterious failed placement.
4. **approach_dir** per §4.1: geometry-inferred. Use a `direction`/`traffic_signals:direction` tag **only** when `road_dir` is known to follow OSM way order; otherwise ignore it for orientation and log it as informational (anti-flip safeguard, §13).
5. **Right-curb projection:** from `pos`, project to the right curb of the approaching lane via `_find_road_edge_point` + curb offset, `curb_sign=+1`.
6. **Along-road position:** keep the light near the signal's along-road position but ensure it is **near-side** (upstream of, or at, the intersection curb contour) — clamp so it never lands inside `_intersection_curb_contours[i]`.
7. **yaw:** face `-approach_dir`.
8. **Dedup — two layers:**
   - **Primary (chunk-overlap):** key `tl_<node_id>` — prevents the same OSM node placing twice across overlapping chunk fetches (§8).
   - **Secondary (approach-level):** one traffic light per signalized approach in v1. Key `tl_app_<intersection_key>_<way_id>_<approach_side>`, with a quantized-position fallback when `intersection_key`/`way_id` is unavailable (`approach_side` = the `signf(sdot)` from §4.1). If several distinct node ids resolve to the same approach key, **keep the best candidate, log the rest as `dup_approach`**.
   - **Best candidate** = (a) closest to the inferred stop position / approach, (b) not inside the intersection contour, (c) successfully projects to the right curb. (Node-id dedup alone does **not** prevent two different nodes on one approach — this layer does.)
   - Distinct approaches each get their own light.
9. Enqueue build at the chunk that **owns the light position** (§8).

### 4.3 Replace the old placeholder

- Gate the placeholder branch at osm/osm_terrain_generator.gd:4668 behind the new path: when OSM signals drive placement (new flag `enable_osm_traffic_signals`, default true), **do not** call `_create_traffic_light` from the intersection loop. The yield-sign branch (non-signalized) is unaffected.
- Net: exactly one system places lights. (`enable_traffic_lights` remains the master on/off for the visual.)

---

## 5. Stop-line algorithm

Drawn **only** for approaches that received a light.

### 5.1 Geometry

- **Shape — a transverse bar across the lane (NOT a road-parallel strip).** Build it explicitly so the implementation cannot accidentally lay a long white stripe along the road:
  - The bar's **long axis runs ACROSS** the approaching lane — from the road **centerline toward the right curb** of `approach_dir`. This long axis is **perpendicular to `road_dir`** (parallel to `perp`).
  - The bar's **depth/thickness ≈ 0.4 m, measured ALONG `approach_dir`** (i.e. along the road). This is the short dimension.
  - **Span (long axis):** approaching-direction lanes only — centerline → right curb for a two-way road; full width for a one-way approach. Use the same lane frame as §4.
  - Sanity invariant: `cross_axis ⟂ road_dir`, and `depth_along_road (≈0.4 m) ≪ span_across_lane`. If those are ever reversed, the bar is wrong.
- **Along-road position:**
  - **If a zebra exists** on this approach (search crossing strips near the intersection on `way_id` within radius): place the stop line at `zebra_upstream_edge - gap`, `gap ≈ 1.0–1.5 m`, upstream = `-approach_dir`. The zebra's upstream edge = crossing center minus half its along-road depth (depth = footway visual width from `_build_crossing_strip` context).
  - **Else (no zebra):** place at `intersection_curb_contour_boundary_along_approach - gap`, `gap ≈ 1.0 m` upstream. Use `_intersection_curb_contours[i]` projected onto the approach axis; fall back to the intersection ellipse radius along the approach if the contour is empty.

### 5.2 No-overlap guarantee

- Hard constraint: `stopline_downstream_edge <= zebra_upstream_edge - min_gap`. If the computed position would overlap the zebra, push further upstream. If the approach is too short to fit the bar + gap, **shrink the gap to a floor, then skip with a logged reason** (`sl_nofit`) rather than overlap.

### 5.3 Rendering (reuse road batch)

- Add a new marking texture **`stopline`** (a solid white bar) generated in textures/texture_generator.gd and registered as `_road_textures["marking_stopline"]`.
- Emit the bar via the existing road-batch path so it is **batched per chunk** and shares the marking shader.
- **Y-offset slot:** `+0.018` (above crossing `0.017`, below nothing relevant) + the existing hash jitter → no z-fighting.

**⚠️ Verify the helper's `pts`/`width` semantics before using it — do not copy the call blindly.** The `_add_road_to_batch_fast(...)` call shown elsewhere in this doc is **illustrative**. First read the helper to determine how it interprets its arguments:

- **If `pts` is a centerline expanded by `width` perpendicular to that centerline:** pass a **short segment along `approach_dir`, length ≈ 0.4 m** as `pts`, and `width = span_across_lane` (centerline → right curb).
- **If `pts` is the long axis directly:** pass the **across-lane segment (centerline → right curb)** as `pts`, and `width/depth = 0.4 m`.

Whichever path, the generated quad **must** satisfy the §5.1 invariant: long axis ⟂ `road_dir`; along-road depth ≈ 0.4 m; span runs centerline → right curb. **If the resulting quad comes out road-parallel, the call is wrong** — re-map the arguments. (This is exactly the kind of mistake the §5.1 invariant and the §11 self-test exist to catch.)

### 5.4 Ownership / dedup

- Stop line is part of the chunk's road batch; dedup with key `sl_<node_id>` so incremental re-finalize doesn't double-add. Owned by the chunk containing the stop-line midpoint.

### 5.5 Scheduling vs road-batch finalization (implementation risk)

Traffic-light placement can resolve **late** (deferred retry waiting on intersection data, §8). The chunk's road batch may already be finalized by then, so a stop line must not be silently dropped. The implementation must pick one safe strategy:

- generate the stop line **before** the chunk's road batch is finalized (gate finalization until the chunk's signals have resolved or exhausted retries), **or**
- support **safe late insertion** of a marking into an already-finalized batch (append + re-finalize that chunk's marking surface), **or**
- **defer the stop-line job** (its own queue) until the relevant road batch can accept it, re-enqueueing while the batch is busy.

**Hard rule: never drop a stop line just because its signal resolved after road-batch finalization.** A late-resolved light must still get its stop line (track unmatched `sl_<node_id>` jobs and verify they all drain). See self-test (§11) and risks (§13).

---

## 6. Traffic-light procedural model

Mirror the existing builder (osm/osm_terrain_generator.gd:23445) with three changes: **orientation, separable bulbs, mode hook.**

- Root `Node3D` at `(pos.x, elev, pos.y)`, `rotation.y = yaw` (faces oncoming traffic).
- Pole: CylinderMesh (h≈4.5, r≈0.08–0.1), dark metallic, shadows off.
- Head: BoxMesh (~0.35×1.0×0.25), near-black, shadows off, on the traffic-facing side.
- Three SphereMesh bulbs (r≈0.1) at descending Y (red top, yellow mid, green bottom), each with its **own StandardMaterial3D** kept in the per-light record so they're individually controllable.
- v1 state: **red & green emission OFF** (dim albedo), **yellow emission driven by the blink driver** (§7).
- Collision: StaticBody3D + CylinderShape3D (as today), layer 2.
- `visibility_range_end ≈ 300`; shadows off on all parts.
- **Future hook:** a per-light record `{ root, mat_red, mat_yellow, mat_green, mode, phase, node_key, app_key }` and a `mode` enum (`BLINK_YELLOW`, future `CYCLE`) so a later signal-timing controller can drive red/yellow/green without touching geometry. `node_key`/`app_key` are stored on the record (not recomputed at cleanup) — see §8.

---

## 7. Blinking-yellow architecture (emissive only)

- **No `Light3D` per bulb** (48-light cap). Yellow blink is **emissive material energy** toggled over time.
- **Single shared driver, no per-light scripts:** keep a registry (e.g. `_tl_blink_registry` array, or `_tl_records_by_chunk`) of yellow materials + per-light phase. One loop in the generator's existing `_process` (or a tiny dedicated manager node) updates them:
  - `on = sin(TIME * BLINK_FREQ + phase) > 0` → set `mat_yellow.emission_energy_multiplier = on ? E : 0`.
  - `phase = fmod(float(node_id) * GOLDEN, TAU)` → **deterministic per-light offset** (lights don't blink in lockstep; reproducible across reloads).
- **Day/night:** blinking yellow is a caution mode → **visible day and night**. Subscribe to `NightModeManager.night_mode_changed` to raise emission energy at night (e.g. day E≈3, night E≈6) for readability.
- **Cheaper alt (optional, note only):** a shared ShaderMaterial using `TIME` + `INSTANCE_CUSTOM` phase moves blink to the GPU with zero CPU, but needs per-instance custom data; deferred past v1 since v1 uses individual instances. Recommend the single-`_process` registry for v1.

---

## 8. Chunking / dedup / streaming

- **Stable keys (two layers, per §4.2 step 8):** primary `"tl_%d" % node_id` (chunk-overlap dedup; node id from §3 guarantees it across ~150 m fetch overlap), and secondary `"tl_app_%s_%d_%d" % [intersection_key, way_id, approach_side]` (one light per approach; quantized fallback when ids unavailable). Stop lines: `"sl_%d" % node_id`.
- **State:** `_created_tl_keys: Dictionary` (node-id), `_created_tl_app_keys: Dictionary` (approach), `_tl_keys_by_chunk: Dictionary` (ck → Array[String]), `_tl_records_by_chunk` (for blink + cleanup). **Each placed light's record stores both its `node_key` and its `app_key`** so cleanup erases both dedup dicts without recomputing the approach key (which can drift if intersection data changed). Stop lines tracked via `_created_sl_keys` (their meshes live in the road batch).
- **Per-chunk ownership:** by the **light position** (curb point), not by whichever fetch saw the node first. Only place when the owning chunk is loaded; the key guards cross-fetch duplicates.
- **Deferred-retry queue:** `_deferred_tl_queue[ck]` mirroring `_deferred_pfence_queue`; drained in `_process` with a frame budget; entries return `TL_OK / TL_RETRY / TL_REJECT`. Retry while intersection/road data is not ready (worker race), up to `tl_max_retries` (e.g. 300, like fences); keep jobs whose chunk is still loaded; drop jobs for unloaded chunks.
- **Cleanup on unload** (in `_unload_chunk`, alongside :3369-3399): for each record in the chunk (via `_tl_records_by_chunk[ck]`), erase **its stored `node_key` from `_created_tl_keys` and its stored `app_key` from `_created_tl_app_keys`** (use the stored keys — do **not** recompute the approach key); erase `_tl_keys_by_chunk[ck]`; remove the chunk's blink-registry entries; erase pending `_deferred_tl_queue[ck]`; light nodes free with the chunk. Stop-line meshes free with the road-batch chunk; erase `_created_sl_keys` for that chunk.
- **Reset / regen** (the path that clears other systems, ~:2257/:3582): clear `_created_tl_keys`, `_created_tl_app_keys`, `_tl_keys_by_chunk`, `_tl_records_by_chunk`, `_created_sl_keys`, `_deferred_tl_queue`, and the blink registry.

---

## 9. Interaction / conflict rules

Priority: **traffic lights & stop lines > pedestrian fences / crossing signs / props / vegetation / decorative clutter.**

**Operational ordering (must be ENFORCED, not assumed).** "Lights take priority" is only true if the generation order or the clearance checks make it true. Guarantee it by **one** of:

- **(A) Order:** traffic lights are placed **and registered in the furniture hash before** pedestrian fences / crossing signs / props / vegetation finalize for that chunk — so those systems already see the light cell as occupied; **or**
- **(B) Late-aware consult:** because lights can resolve via deferred retry (§8), each lower-priority system **consults the traffic-light furniture hash during its own deferred-retry / finalization step** (not only once at first pass), so a late-placed light still wins.

Pick (A) where ordering is naturally guaranteed; otherwise (B). Do **not** rely on priority without one of these in place.

- **Zebra / crossing:** stop line strictly upstream, never overlapping (§5.2). The light pole must not stand on the crossing strip — nudge along the curb if it would.
- **Pedestrian fences:** coexist (fences already start after the crossing). With ordering (A)/(B), a fence bay that collides with the light cell **skips that bay** (light wins).
- **Crossing signs / billboards / bus stops / props / vegetation / decorative clutter:** the light registers in the furniture hash (`_prop_near_furniture` family); these lower-priority systems treat the light cell as occupied and yield to it.
- **Essential collisions (lamps / existing essential objects):** the light is allowed to **nudge along the curb before final placement** rather than overwrite an essential object — i.e. the light yields position to lamps but wins against decorative/lower-priority furniture.
- **Old placeholder lights:** disabled via §4.3 — guaranteed not to co-spawn.
- **Road markings (lane/center lines):** stop line uses a distinct texture_key and a higher Y slot, so it composits over lane lines without z-fighting.

---

## 10. Debug tooling (default OFF)

- Flag `tl_debug: bool = false` (export or var, like `pfence_debug`). Logs routed through the gated emitters (`_emit_road_debug`-style); never spam by default.
- `_tl_debug_marker(ck, world_pos, color)` modeled on `_pfence_debug_marker` (unshaded sphere, grouped for cleanup). Visualize:
  - raw OSM node (one color) + node id (log),
  - matched road segment (line), matched intersection (line to center), matched approach arm (arrow),
  - lane/approach direction (arrow), right-curb projection (sphere), final light position (sphere), facing direction (arrow),
  - stop-line position (line) + the zebra edge used (line),
  - rejection/retry reason + dedup key + blink-registry entry (log).
- Counters: `_tl_dbg = {placed, noroad, nointer, midblock_signal_v2, dup_node, dup_approach, retry, sl_drawn, sl_nofit, sl_late}` — printed once per area load so totals reconcile (`placed + every rejection bucket == signals seen`; `midblock_signal_v2` and `dup_approach` are distinct, named buckets, not lumped into `nointer`).

---

## 11. Visual / self-test checklist (implementer must do this; not the user)

Run via MCP: `execute_game_script` to set up + query, `get_game_screenshot` to inspect, then **`stop_scene` after every pass** (energy/heat).

- Launch `res://main.tscn` directly (not through the menu); load the target Cherepovets area directly.
- Inspect **multiple real OSM signal locations**: at least one 4-way and one T-junction (if present), and ≥1 signalized approach with a zebra.
- **Reconciliation assert:** every loaded OSM signal has either a placed light or a logged valid rejection (`placed + rejected == total`, from §10 counters).
- Stop lines are **upstream** of zebras and never overlap (measure along approach axis).
- Lights **face approaching cars** (visual + yaw vs `-approach_dir`).
- Lights are **not at the intersection center** (assert distance from `_intersection_positions[i]` > threshold; assert on a curb).
- **No duplicates after chunk reload** (reload chunks, compare light counts / keys).
- **Blinking yellow** visible (capture two frames at different TIME; yellow emission differs; red/green dark).
- Confirm the **old placeholder** no longer spawns (no center light).
- **Direction tag did not flip the approach:** on approaches with a `direction`/`traffic_signals:direction` tag, confirm the chosen `approach_dir` matches intersection geometry (tag respected only when way-order alignment held; otherwise logged informational).
- **Stop lines are transverse bars, not road-parallel strips:** verify each stop line's long axis is ⟂ `road_dir` and its along-road depth ≈ 0.4 m (assert the §5.1 invariant, plus visual).
- **One light per approach** after secondary dedup (no two heads on the same approach; `dup_approach` count matches the extras dropped).
- **Lower-priority furniture does not overlap the light:** confirm no fence bay / crossing sign / prop / vegetation occupies the light cell.
- **Mid-block skips are labeled:** every skipped signal with no junction is logged as `midblock_signal_v2`, none mislabeled as `nointer`.
- **Late-resolved stop lines still appear:** force a signal to resolve via deferred retry (after its chunk's road batch finalized) and confirm its stop line is still drawn (`sl_late` drains to zero; no silent drop).
- **Stop-line helper semantics verified first:** confirm the chosen `_add_road_to_batch_fast` argument mapping was checked against the helper's real `pts`/`width` interpretation (§5.3) before relying on it.
- **Stop-line final mesh invariant asserted:** transverse across the lane (long axis ⟂ `road_dir`), not road-parallel, along-road depth ≈ 0.4 m (debug-draw the actual quad, not just the inputs).
- **Records carry both keys:** each placed light stores `node_key` and `app_key`; after unload/reload both `_created_tl_keys` and `_created_tl_app_keys` are clear (no stale entries blocking re-placement).
- **No generic-pipeline duplicates:** confirm the generic `point_objects` path created nothing from any `highway=traffic_signals` node (count generic props before/after; signals contribute zero).

---

## 12. Implementation milestones

1. **M1 — Pipeline + parser + data model** (§2, §3). Verify refetch + non-zero signal count logged.
2. **M2 — Placement core** (§4): match road/intersection, project to right curb, orient; **replace placeholder** (§4.3). Visual-verify a few approaches.
3. **M3 — Procedural oriented model + blinking yellow** (§6, §7).
4. **M4 — Stop lines** (§5) via road batch (zebra-aware, no-overlap).
5. **M5 — Chunking/dedup/streaming + deferred retry + cleanup** (§8). Reload test.
6. **M6 — Conflict integration** (§9): fences/furniture/old placeholder.
7. **M7 — Debug tooling** (§10).
8. **M8 — Full self-test sweep + tuning** (§11).

(M1–M2 are the critical path; nothing renders until M1's query+version+parse are correct.)

---

## 13. Risks & fallback behavior

| Anti-bug | Guard / fallback |
|---|---|
| Forgot to fetch `traffic_signals` | §2 step 1; M1 verifies non-zero count |
| Stale cache → zero lights | Bump `CACHE_VERSION` to 8 in **both** loader and precache (§2) |
| Off-by-one in query arg list | Add the 29th `bbox`; M1 sanity-checks the substituted query |
| Lost node id → duplicate lights | Preserve id in parser (§3); dedup `tl_<id>` (§8) |
| Old center placeholder still spawning | Gate §4.3; self-test §11 visual confirm |
| Light on centerline / at center | Project to right curb + near-side clamp (§4); assert in self-test |
| Wrong side of road | Reuse `curb_sign`/`lane_dir`; confirm visually, don't re-derive |
| Light faces away | yaw → `-approach_dir`; assert in self-test |
| Stop line after / overlapping zebra | Upstream rule + hard no-overlap clamp (§5.2) |
| Z-fighting | Stop line Y slot 0.018 + hash jitter |
| Too many real lights | Emissive only, no per-bulb Light3D (§7) |
| Per-light script overhead | Single shared blink loop over a registry (§7) |
| Signals vanish/dup on streamed chunks | Stable key + per-chunk lists + unload cleanup (§8) |
| Skipped due to intersection race | Deferred-retry queue, not skip (§8) |
| Conflict with fences/signs/lamps/props | Furniture hash + priority order (§9) |
| Intersection never resolves (mid-block signal) | After max retries + association check, **reject + log `midblock_signal_v2`** (named v2-scope skip, not generic `nointer`); §4.2 step 3, §14 |
| Crossing geometry missing/ambiguous | Stop line falls back to intersection-curb-contour rule (§5.1) |
| Approach too short for stop line | Shrink gap to floor, else skip + log `sl_nofit` (§5.2) |
| `direction`/`traffic_signals:direction` flips light to wrong approach | Apply tag only when `road_dir` follows OSM way order; else geometry-infer + log informational (§4.1) |
| Stop line built road-parallel (long stripe) instead of transverse | Explicit cross-lane geometry + ⟂ invariant (§5.1); asserted in self-test |
| Road-batch helper `pts`/`width` mis-mapped → wrong quad orientation | Verify helper semantics before use; map args to satisfy the §5.1 invariant (§5.3) |
| Generic `point_objects` path creates extra object from a signal node | Exclude `traffic_signals` from generic consumption; dedicated array is sole source (§3); self-test counts zero |
| Approach key recomputed wrong at cleanup → stale dedup entry blocks re-placement | Store `node_key`+`app_key` on the record; erase stored keys, don't recompute (§6, §8) |
| Multiple lights on one approach (two node ids) | Secondary approach dedup `tl_app_*`, keep best, log `dup_approach` (§4.2 step 8, §8) |
| Lower-priority furniture overlaps the light ("priority" not enforced) | Enforced ordering (A) place+register before others finalize, or (B) others consult the TL hash in their deferred step (§9) |
| Stop line dropped when signal resolves after road-batch finalization | One of: pre-finalize gen / safe late insertion / deferred SL job; never silently drop (§5.5); `sl_late` self-test |

---

## 14. Open questions (defaults chosen; flag only if you disagree)

1. **Mid-block pedestrian signals** (a `traffic_signals` node not at any junction): v1 **rejects + logs as `midblock_signal_v2`** (no floating roadside light), only after checking it can't be associated with a nearby signalized crossing/junction. Standalone mid-block lights = explicit v2 scope add. *Default: reject (clearly labeled).*
2. **Stop-line span:** approaching-direction lanes only (half a two-way road). *Default: yes — matches real stop-line markings.*

(Neither blocks starting M1.)
