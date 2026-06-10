# Roadside Props — Kiosks & Transformer Boxes — Implementation Plan

Status: ✅ **IMPLEMENTED & verified in-engine (day/night) — 2026-06-10.** Procedural kiosks (at bus stops) +
transformer boxes (verges near buildings), grounded/centred from real vertices, collidable, subtle kiosk night
glow, deterministic sparse placement, + manual `roadside_props` JSON placement by lat/lon. Assets imported to
`models/roadside_props/`. Code: `osm/osm_terrain_generator.gd` (`_init_prop_defs`, `_generate_road_props_incremental`,
`_spawn_prop`, gates) + `osm/decoration_layer.gd` (`roadside_props` parse).

**Deferred from this pass (honest):** props currently sit on the **grass verge at a setback** (like lamps,
already lifted `PROP_LIFT`); the **sidewalk-polygon snap** (§5) is NOT yet implemented — the verge result looks
good in-scene, so the polygon snap is a follow-up refinement. Kiosk↔box compete for the same bus-stop spots via
the 25 m spacing (kiosk usually wins) — placement at contested spots is mildly load-order dependent.

Goal: sprinkle **newspaper kiosks** and **dirty electrical/transformer boxes** along the streets so the
verge reads "inhabited provincial city" — **sparse, believable, properly avoiding** roads, water, buildings,
junctions, parking, bridges and other roadside furniture. This is the remaining street-furniture half of
Phase 6 (kiosks + transformer boxes), reusing the billboard/wire placement infrastructure.

---

## 0. Assets (on the Desktop, to import)
- `~/Desktop/OSM material/newspaper-kiosk-1.glb` (4.4 MB)
- `~/Desktop/OSM material/newspaper-kiosk-2.glb` (1.8 MB)
- `~/Desktop/OSM material/dirty_electrical_box.glb` (4.0 MB)

None are in the project yet. Step 1 of the build copies them into `models/roadside_props/` and lets the Godot
editor generate `.import` (per the **.import gotcha** in memory: never hand-write `.import`; run
`--editor --quit`). The `.import` files ARE committed (Godot best practice).

---

## 1. Asset prep (must do before placement — avoids levitation/sinking & oversize)
For each model, at load time (mirroring `_init_lamp_meshes` / `_load_tree_mesh_normalized`):
1. **Normalize scale to real-world height** (target height per type — see §3), not the GLB's authored scale.
2. **Ground from REAL vertices, not the stored AABB.** Per [[clutter_getaabb_gotcha]] imported GLBs can carry
   a junk inflated AABB → props levitate/sink. Compute the true **min-Y of actual vertices** and offset so the
   base sits exactly on terrain. (This is the same root cause as the recent "bus stops sinking" fix and the
   wire pole-offset fix — verify in-scene at close range.)
3. **Find the model's footprint + front-face in local space** (centroid/extents in XZ). Kiosks have a service
   window — that face must point toward the sidewalk/road. Determine the front axis per model now so orientation
   (§5) is correct, NOT guessed (this is exactly what bit the lamp pole/wire attachment).
4. **Vert budget check** — report tri counts; decimate if any is heavy (kiosk-2 at 1.8 MB is fine; 4 MB ones may
   be dense). Cap so per-chunk batches stay cheap.

Caches: `_prop_meshes[type]` (normalized mesh or PackedScene), `_prop_base_offset[type]` (real min-Y),
`_prop_footprint[type]` (collision half-extents), `_prop_front_axis[type]`.

---

## 2. Architecture — one config-driven prop system (mirror the billboard pipeline)
Rather than two parallel systems, **one procedural roadside-prop placer parameterised by a per-type config**,
so kiosks, boxes (and future props: phone booths, postboxes…) all share the pipeline. Mirrors the **billboard**
road-walk (proven): full unclipped road polyline → global arc-length spacing → each candidate assigned to **its
own midpoint chunk** → semantic dedup → position registry → unload/reset cleanup.

```
const PROP_CONFIG := {
  "kiosk":  { models:[k1,k2], height:2.6, roads:[...], spacing:..., setback:..., area:"commercial",
              footprint:Vector2(1.1,1.0), faces_road:true,  night_glow:true },
  "ebox":   { model:ebox,     height:1.2, roads:[...], spacing:..., setback:..., area:"any",
              footprint:Vector2(0.5,0.35), faces_road:false, night_glow:false },
}
```

### Two placement sources
1. **Procedural** (the road-walk above) — sparse, gated, deterministic.
2. **Manual by coordinates** — a JSON list (reuse the `custom_models` mechanism in
   `decorations/.../building_overrides.json`, or a sibling `roadside_props` block) where you hand-place a prop:
   `{type, lat, lon, rotation_y?, scale?}`. Manual props **bypass the procedural siting/spacing gates** (you
   chose the spot) but **still pass the physical-safety + grounding path** (snap to surface, correct base
   offset, collision) and are deduped by a `pr_manual_<lat>_<lon>` key. Same loader path as
   `_place_custom_models_for_chunk` (line 17795), so this is a small extension, not a new system.

New state (mirrors `_deferred_billboard_road_queue` & friends):
- `@export var enable_roadside_props := true`
- `_deferred_prop_road_queue: Dictionary`  (chunk_key → Array[{points, way_id, highway, width, type, _idx}])
- `_created_prop_keys: Dictionary`          (global semantic key `pr_<type>_<way>_<idx>` → true)
- `_prop_keys_by_chunk: Dictionary`         (unload key cleanup)
- `_prop_pos_hash: Dictionary` + `_prop_pos_by_chunk: Dictionary` (cross-prop spacing + unload cleanup, like `_billboard_pos_hash`)

Enqueue at the road-apply site (next to the lamp/billboard/wire enqueues, ~line 5366): for each eligible
`highway`, push **one job per prop type** that road qualifies for, with FULL `full_smoothed_points`.
Processor: a budgeted `_generate_road_props_incremental(type, …)` walking arc-length at `spacing(type)`,
calling `_try_place_prop` per candidate (mirrors `_generate_road_billboards_incremental` /
`_try_place_road_billboard` / `_place_road_billboard`). Runs in the per-frame drain after the wire processor.

Cleanup: erase `_prop_keys_by_chunk[ck]` keys from `_created_prop_keys`, remove `_prop_pos_by_chunk[ck]` from
`_prop_pos_hash`, on chunk unload (~line 3104 block) and in both reset blocks — exactly like billboards.

---

## 3. Per-type placement config (the "where" + "how often")

| | **Newspaper kiosk** | **Transformer / electrical box** |
|---|---|---|
| Models | kiosk-1 + kiosk-2 (deterministic variant by hash) | dirty_electrical_box |
| Target height | ~2.6 m | ~1.2 m |
| Roads | `primary, secondary, tertiary` (busier pedestrian streets) | `secondary, tertiary, residential, unclassified` (utilitarian, anywhere with a verge) |
| Area preference | **at/near bus stops + intersections/corners ONLY — never mid-block.** No commercial/residential distinction (dropped per your call). | **on the verge near a building it would feed** (courtyards, residential/industrial frontage); **never** out in open parks/greens far from buildings |
| Spacing (global arc-length) | **very sparse** — start ~400–500 m, gated to a bus-stop/junction (so spacing is effectively "≤1 per eligible corner") | sparse — start ~220–300 m |
| Setback from road edge | `road_width/2 + ~2.5 m` (on the verge, like lamps/billboards) | `road_width/2 + ~1.5 m` (closer, hugs the verge) |
| Orientation | **service window faces the road/sidewalk** (front-axis → road tangent) | long side parallel to road; facing not critical |
| Night | **subtle** warm **interior glow** (lit kiosk window — "a bit", not a beacon) | none |

"Not too frequent" is the explicit ask → start at the sparse end (kiosks rare, boxes occasional) and only
dial up after seeing it in-scene. Density is a hash gate (`hash(way,idx) % keep == 0`) layered on the spacing.
**Plus manual placement** (§2.2): you can drop a kiosk/box at exact `lat/lon` via JSON for hero spots,
independent of the procedural sparsity.

---

## 4. Avoidance gates (ordered cheap → expensive — the "proper avoidance")
A candidate at world-XZ `pos` (verge point, chunk loaded) must pass ALL of these before placement. Most reuse
existing helpers already used by lamps/billboards:
1. **Not on / crossing a road** — `_is_point_near_road(pos, footprint_radius + 0.3, ck)` (use the prop's
   footprint so a wide kiosk never overhangs the carriageway).
2. **Not in a road junction** — `_is_point_in_intersection_shape(pos, false, ck) >= 0`. (Kiosks are placed
   *near* intersections but on the verge, never inside the junction contour.)
3. **Not on a bridge deck** — `_is_point_on_bridge_deck(pos)`.
4. **Not in water** — `_is_point_in_water(pos, ck)`.
5. **Not in parking** — `_is_point_in_any_parking(pos, ck)`.
6. **Not clipping a building** — `_building_clip_within(pos, footprint_radius + margin)` (boxes may sit close
   to a facade → small margin ~0.4 m; kiosks need clearance ~1.0 m so the window isn't jammed against a wall).
   Reuses the global neighbor-aware footprint index built for billboards.
7. **Siting preference** (per type — the "where it makes sense"):
   - **Kiosks** require `_near_bus_stop_or_intersection(pos)` — within ~25 m of a bus stop
     (`_created_bus_stop_positions`) or a junction contour. **Never mid-block.** No commercial/residential
     distinction (dropped per your call).
   - **Boxes** require `_building_within(pos, ~25 m)` (reuse the footprint index) so they only sit on verges
     **near the buildings they'd feed** — never stranded out in open parks/greens.
8. **Min spacing from OTHER roadside furniture** — new `_prop_too_close(pos)` over `_prop_pos_hash`, **plus**
   checks against lamps (`_created_lamp_positions`), billboards (`_billboard_pos_hash`), bus stops
   (`_created_bus_stop_positions`), signs (`_created_sign_positions`): reject if within ~6–8 m of any. This is
   the gate that stops props colliding with / clipping existing furniture.
9. **Min spacing between props of any type** — global ≥ `PROP_MIN_SPACING` (~25 m) so two props never bunch.

`prop_debug_dense` relaxes the siting + spacing gates for validation; physical gates (road/water/building/
junction/bridge) always apply.

---

## 5. Placement surface, grounding & orientation
- **Placement surface — prefer the SIDEWALK polygon (your call).** Snap/keep the candidate where it lies inside
  a footway polygon (reuse the Phase-4 sidewalk data — `_union_footway_polys` / the footway polys per chunk).
  Ground to the **walk surface** and **lift ~4–6 cm** so the prop sits ON the pavement and does **not z-fight /
  fight the sidewalk mesh**. Where no sidewalk polygon exists, **fall back to the grass verge at a setback**
  (like lamps/billboards). Manual-coords props (§2.2) skip the snap — they sit exactly where given, still lifted.
- **Ground:** `surf_y = get_surface_y(pos.x, pos.z)` (sidewalk or terrain), then
  `inst.position.y = surf_y - prop_base_offset[type] + PROP_LIFT` (PROP_LIFT ~0.05 m) so the **real model base**
  rests on the surface (no levitation, no sinking, no z-fight). Verify at close range in-scene (the levitation
  lesson from lamps/wires).
- **Orient (kiosk):** find the road tangent at the candidate (from the walk's segment dir), set yaw so the
  model's front-axis (from §1) points toward the road/sidewalk. Two-sided check so a kiosk on the left vs right
  verge both face inward.
- **Orient (box):** align long side parallel to the road tangent.
- Slight deterministic yaw jitter (±~6°, hash-based) so props don't look robotically aligned.

---

## 6. Determinism (no `randf` for persistent choices)
House hash `(way_id * 2654435761 + idx * 40503) & 0x7FFFFFFF`, used for: keep/drop density gate, **variant**
(kiosk-1 vs kiosk-2), side of road, and the small yaw jitter. Global arc-length spacing + semantic dedup keys →
identical props on reload / chunk re-entry (verified the billboard way: reload → identical positions). No
per-chunk cap that would change with load order.

---

## 7. Geometry, collision, LOD, optional night glow
- **Instancing:** instantiate the model per placed prop (preserves the kiosk's multi-material textures), parented
  to the candidate's chunk node via `_budgeted_add_child` (spreads node-adds across frames). Counts are low
  (a handful per chunk) so individual instances are fine; if counts ever grow, switch to a per-chunk
  MultiMesh per variant (the lamp pattern). `_set_no_shadow_recursive` + `_set_visibility_range_recursive`
  (~150–200 m, fade-self) — both already exist and are used by custom models.
- **Collision:** one `StaticBody3D` + `BoxShape3D` sized from the prop footprint (kiosk ~2.0×2.6×1.2, box
  ~0.7×1.2×0.5), centered at half-height. **Collision layer matched to street lamps** (which reliably stop
  cars) so the car bumps them solidly — verify a car actually collides (the lamp uses the default layer; bus
  stops use layer 2 — confirm which the car mask hits and use that).
- **Night glow (kiosk — LOCKED ON, subtle):** a small emissive window panel + a short-range `OmniLight3D` named
  **"LampLight"** so the existing `_recursive_update_lights` auto-toggles it at night (the trick billboards
  reused) — a **subtle** warm interior light ("a bit", low energy, short range), shadowless, distance-culled,
  off by day. Boxes get none.

---

## 8. Performance budget
| Quantity | Initial cap / estimate |
|---|---|
| Kiosks per chunk | ~0–2 (very sparse, intersection-gated) |
| Boxes per chunk | ~1–4 |
| Per-prop cost | 1 instance (its surfaces) + 1 StaticBody box + optional 1 light (night) |
| Draw calls | a few per chunk; shadows off; vis range ~150–200 m fade-self |
| Spacing floors | ≥6–8 m from other furniture, ≥25 m prop-to-prop |
| Night light | only on kiosks, `LampLight`-gated → zero day cost, short range, distance-culled |
| Main-thread | budgeted incremental walk + `_budgeted_add_child` (no spikes), mirrors billboards |

Re-measure FPS/draws at a lamped corridor before/after; hold the Phase-0 baseline.

---

## 9. Debug & visualization (flags default off, logs gated)
- `prop_debug_dense` — bypass area/spacing gates (every spacing slot) to inspect coverage/clutter.
- `prop_debug_reasons` — count rejections by reason (road / building / junction / water / parking / too-close /
  not-commercial / not-near-junction) like the temporary billboard `_bb_dbg` counters (removed before commit).
- `prop_debug_markers` — drop a colored marker per placed prop + its footprint circle to eyeball avoidance.
- Standard: launch `res://main.tscn` directly; `NightModeManager.enable_night_mode()` for the kiosk glow.

---

## 10. Visual verification checklist (in the driving scene, day + night)
- [ ] Kiosks + boxes appear, **sparse** — not lining every block; kiosks read as occasional corner newsstands.
- [ ] Each prop **sits on the ground** (base flush, not floating/sunk) — close-up both types on flat + sloped terrain.
- [ ] **No prop on/over the road**, in a junction, on a bridge, in water, or in parking.
- [ ] **No prop clipping a building** facade; boxes may sit close, kiosks have clearance.
- [ ] **No prop clipping a lamp / billboard / bus stop / sign / another prop** (spacing floors working).
- [ ] Kiosk **service window faces the road/sidewalk**; both road sides face inward.
- [ ] Car **collides** with both types (drive into one — solid, not pass-through).
- [ ] Chunk reload → identical placement (determinism); no duplicates.
- [ ] Night: kiosk window glows warm (if enabled), boxes dark; day has zero prop-light cost.
- [ ] FPS ≥ baseline at a populated corridor; draw calls within budget.

---

## 11. Implementation milestones (staged)
1. Copy the 3 GLBs into `models/roadside_props/`; generate `.import` via `--editor --quit`; commit `.import`.
2. Asset prep: load + normalize each, compute real base-offset (min-Y), footprint, front-axis; log tri counts.
3. **Manual-coords placement first** (smallest, most useful): extend the `custom_models` loader to accept a
   `type` so you can drop a kiosk/box at exact `lat/lon` via JSON. Verify grounding, scale, orientation,
   collision **close-up (flat + slope)**. This nails base-offset/front-axis before any procedural work — and
   gives you the manual-placement ability you asked for immediately.
4. Prop state + config + deferred queue + enqueue + drain processor (no gates yet — place at spacing).
5. Add determinism (variant/side/keep) + semantic dedup + position registry + unload/reset cleanup.
6. Add physical gates (road/junction/bridge/water/parking/building) — verify nothing clips.
7. Add cross-furniture spacing + siting gates (kiosk → near bus-stop/junction; box → near building).
8. **Sidewalk-polygon snap + lift** (prefer footway poly, else verge setback); orientation (face-road) + yaw jitter.
9. Kiosk night glow (`LampLight`, subtle).
10. Debug flags + reason counters; tune spacing/density per type in-scene; remove instrumentation.
11. Perf pass (day/night FPS, draws), final visual A/B, then commit.

---

## 12. Locked decisions
1. **Frequency** — start **very sparse**, dial up after seeing it in-scene. **Plus a manual coordinate
   placement** path (JSON `lat/lon`, §2.2) so you can hand-place props at hero spots.
2. **Kiosk siting** — **at/near bus stops + intersections/corners ONLY, never mid-block.** Commercial-vs-
   residential frontage distinction **dropped** (not used).
3. **Box siting** — verges **near buildings they'd feed** (residential/industrial/courtyards) — "where it makes
   sense in a Soviet town"; **never** out in open parks/greens away from buildings.
4. **Kiosk night glow** — **yes, subtle** warm lit window ("a bit"). Boxes unlit.
5. **Placement surface** — **prefer the sidewalk polygon**, **lifted ~4–6 cm** so it doesn't fight the sidewalk
   mesh; fall back to grass-verge setback where there's no sidewalk.
6. **Collision** — cars physically stop on both (match the street-lamp collision layer).
