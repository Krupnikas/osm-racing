# Billboard Placement — Implementation Plan

**Status:** ✅ IMPLEMENTED & verified in-engine 2026-06-09 (Cherepovets — Северное шоссе + проспект Победы; day/night; reload-determinism confirmed). Files: `osm/osm_terrain_generator.gd`, `osm/decoration_layer.gd`, `textures/billboards/small-city/`. Density (spacing/residential radius) left as in-game tuning per §11. Original design notes below.

> **Implementation deltas from the plan:** the building-footprint index is a **global** cell hash (not per-chunk) — neighbor-aware by construction (a building parsed by any chunk's fetch is seen), with a >600 m bbox guard (a relation-sized bbox would otherwise loop millions of cells on the main thread → freeze). The top lamp reuses the existing night system by **naming the SpotLight `"LampLight"`** (auto-toggled by `_recursive_update_lights`, auto-freed with the chunk node) — no parallel manager. Sidewalk gate deferred (footway data sparse; verge setback + anti-clip keep boards off the immediate edge). Verified: pool=34, gates clean (residential_within/clip_within=false on placed boards), residential streets = 0 boards, reload → identical positions.

> **Revision note (latest):** building gate is now **differentiated** — ~20–25 m from **residential**, only a ~4–5 m anti-clip margin from **non-residential/unknown** (so boards can sit near shops/industry but never clip a facade); the building index must be **neighbor-aware**; the top lamp is **night-only** (integrated with the night-mode light system, shadowless, short-range); orientation (perpendicular vs slight angle) is a **visual tuning** decision; dedup uses **semantic keys**; no hard per-chunk cap.

Procedural placement of advertising billboards (рекламные щиты) along major roads, streamed with the chunk system, placed on roadside verge — clear of residential frontage, never clipping any facade. Built on the existing street-lamp "strew along a road" infrastructure.

---

## 1. Goal & scope

Sparse, realistic roadside billboards that:
- appear only on **major through-roads** (`highway = trunk | primary`), never residential/small streets;
- stand on **allowed roadside/verge terrain** (grass/dirt — anything not a forbidden surface), off sidewalks/parking/carriageway/water/junctions; kept **~20–25 m from residential** buildings (no boards at apartment windows) but allowed near **non-residential** frontage behind only a ~4–5 m anti-clip margin (boards near shops/industry are fine, just never clipping a facade);
- stream in/out correctly with chunks, stable across reloads (deterministic);
- reuse the existing two-sided pole+frame billboard model and our prepared 1024×512 textures.

**Out of scope (v1):** wall-mounted boards on commercial buildings, transit-stop ads, digital/animated boards, big-city map support. (All are legal per ФЗ‑38 and can be later phases.)

---

## 2. Norms basis (why these rules)

- **ГОСТ Р 52044‑2003** (the road-safety technical regulation): ≥0.6 m from carriageway edge, ≥5 m clearance from a sign/light/crossing *ahead*, never over the carriageway / on medians / barriers / bridges. → our verge offset + clearance gates.
- **ФЗ‑38 «О рекламе», ст. 19:** placement follows a curated municipal *схема размещения* (so they punctuate, not blanket); mounting on apartment-building common property needs an owners' vote (so boards avoid residential in practice); refusal ground = spoiling the *внешний архитектурный облик* of established (residential/historic) areas. → hence **strong residential avoidance (~20–25 m)** + **sparse spacing**, while still allowing boards near commercial/industrial frontage (where they actually live) behind a small anti-clip margin (§6) — legally faithful, not just aesthetic.
- **Standard board = 6 m × 3 m = exactly 2:1** — which is why our textures were normalized to **1024×512** and the frame `size` should be `[6.0, 3.0]`.

---

## 3. Assets (decided)

- **One pool per city, content-matched.** `big-city` vs `small-city` folders are about poster *content* relevance (Moscow/SPb/Ekб/Kazan vs smaller towns), **not** billboard size — same physical board.
- **Cherepovets → `small-city` set (34 images)**; `big-city` (28) reserved for a future Moscow-class map.
- Source already processed: `~/Desktop/OSM material/billboards/{big-city,small-city}/*.jpg`, all **1024×512, best-quality JPEG** (originals backed up in `billboards_backup/`).
- Real OSM has only **4** `advertising=billboard` nodes in Cherepovets (`59.137529,37.911312`; `59.143306,37.970461`; `59.147367,37.929371`; `59.147480,37.928607`) — negligible, so placement must be procedural. The 4 may be honored as exact extras (§7.6).

---

## 4. Architecture — mirror the street-lamp pipeline

Lamps already solve "strew objects along major roads across chunk boundaries." We follow that pattern, with one refinement (global arc-length spacing).

**Why chunking isn't a problem:** OSM data is fetched at radius ≈315 m ([osm_terrain_generator.gd:2776](../osm/osm_terrain_generator.gd#L2776)), larger than `chunk_size = 210 m` ([:73](../osm/osm_terrain_generator.gd#L73)), so when a chunk is processed the parsed roads/buildings/landuse for ~100 m beyond every edge are already in memory as spatial hashes. Adjacency queries run against **parsed data**, never against instantiated neighbor chunks — exactly how lamp placement already avoids roads/water/intersections.

Pipeline stages (sibling to lamps):
1. **Enqueue** (Phase 3): for each way with `highway ∈ {trunk, primary}`, push to a new `_deferred_billboard_road_queue` keyed by chunk. (Lamp analog: [:5253](../osm/osm_terrain_generator.gd#L5253).)
2. **Walk & sample** (incremental, budgeted): step the polyline dropping candidates at global arc-length intervals, offset to the verge. (Lamp analog: [_generate_street_lamps_incremental:19533](../osm/osm_terrain_generator.gd#L19533).)
3. **Gate** each candidate (§6).
4. **Assign to chunk & build**: candidate's chunk = `floor(pos/chunk_size)`; place only if `_loaded_chunks.has(ck)`; elevation via `_sample_elevation` ([:16451](../osm/osm_terrain_generator.gd#L16451)) + pole height; mesh via the existing builder.

---

## 5. Data pieces to build

### 5.1 Texture pool
- Copy `small-city/*.jpg` (and `big-city/` for the future) into `res://textures/billboards/small-city/`.
- Run Godot `--editor --quit` once to generate `.import` files (never hand-write them).
- Pool loader: **scan the folder once**, **sort the paths** (deterministic order — no random/unsorted directory iteration), and **cache** them — either preload the `Texture2D`s into an array at startup, or keep sorted paths and lazy-load via Godot's resource cache. **No repeated directory scanning during placement.** Texture selection is **deterministic from `way_id + candidate_idx`** (§7.3). Cherepovets selects `small-city` (gate on `_is_cherepovets_location()`); structure leaves room for `big-city`.

### 5.2 Building-footprint spatial index (the only genuinely new data structure)
The existing `_chunk_building_poly_hashes` stores polygon *segments* (for avoidance). For the gates we want a cheap "is there a building footprint near point X, and is it residential?" test. Add, during Phase-1 building parsing ([~:3574](../osm/osm_terrain_generator.gd#L3574)):
- store every building footprint (centroid + bbox/radius, ref to its polygon, **+ a residential/non-residential flag**) in a spatial hash `_building_footprint_hash` (30–60 m cells). Two query helpers:
  - `_building_clip_within(point, ~4–5 m, ck) -> bool` — inside or near **any** building (anti-clipping);
  - `_residential_within(point, ~20–25 m, ck) -> bool` — inside or near a **residential** building only.
- **Residential flag (kept simple):** residential = `building ∈ {apartments, residential, house, detached, dormitory, terrace}`; non-residential = `commercial, retail, industrial, warehouse, office, garage(s), kiosk, service, supermarket, …`. **Unknown/untyped → treated as non-residential** for v1 (gets only the ~4–5 m anti-clip margin); **no new residential fallback logic** unless an existing classifier already provides it.
- **Neighbor-aware (required):** both helpers must search **all spatial-hash cells overlapping the query radius**, including cells whose data came from neighbouring chunks / the fetch overlap — never only the current chunk's buildings. The ~315 m fetch radius already covers ~100 m beyond each edge, so the neighbour data is present; the query just has to look at those cells. (If it checked only the current chunk, the residential gate would be load-order dependent — see §7.3.)
- `landuse=residential` vs `commercial/industrial/retail` (via `_point_in_polygon_2d` [:23819](../osm/osm_terrain_generator.gd#L23819)) is an **optional** secondary signal only; not required for v1.

### 5.3 Billboard builder
Use [`DecorationLayer.create_billboard_mesh`](../osm/decoration_layer.gd#L324): construct a `BillboardDecoration` on the fly (chosen texture, `size=[6.0,3.0]`, `pole_height≈4.5`, two-sided), call the builder. `cast_shadow = OFF`, `visibility_range_end ≈ 350 m`, parented to the chunk so it unloads with it.
- **Lighting = external top lamp, not self-emission.** Add a small **lamp fixture at the top-center of the frame** pointing **down at the board surface** — a provincial simple fixture. The board material **must not glow on its own** (at most a very subtle response); drop the old `has_backlight` self-emission as the primary effect.
- **Performance / night-gating (required):** do **not** create always-on `SpotLight3D`s in daylight. Wire billboard lamps into the **existing night-mode light system** (same lifecycle as street lamps / `_deferred_lamp_lights` / `NightModeManager`): **enabled only at night**, **shadowless**, **short range**, **visibility-ranged / distance-culled**. If a deferred lamp-light infrastructure already exists, reuse it rather than inventing a separate lighting lifecycle.
- **Shared-builder safety:** `create_billboard_mesh` is also used by the hand-placed `billboards.json` path. Put the top-lamp behind an explicit **opt-in flag** (e.g. `with_top_lamp`) so procedural boards get it and existing hand-placed boards are **unchanged** unless explicitly opted in.

### 5.4 Deferred queue + processor
- New `_deferred_billboard_road_queue: Dictionary` (chunk_key → Array of way refs). (Distinct from the existing hand-placed `_deferred_billboard_queue` for `billboards.json`, which stays.)
- Incremental Phase-3 processor with a time budget, modeled on the lamp processor ([~:13603](../osm/osm_terrain_generator.gd#L13603)).

---

## 6. Placement gates (per candidate)

**Allowed surface:** allowed roadside/verge terrain (grass, dirt, generic roadside) — i.e. anything **not** a forbidden surface (no positive "is-grass" test). **Forbidden:** sidewalks, parking, the road/carriageway, water, intersections/junction areas, inside any building, within ~4–5 m of **any** building (anti-clip), within ~20–25 m of **residential** buildings, and (best-effort) inside fenced-off parcels.

**Evaluation order — cheap → expensive** (early-exit before any polygon test):
1. **road eligibility + bridge skip** — `highway ∈ {trunk, primary}`; skip segments flagged `bridge`;
2. **spacing / candidate index** — is this an actual candidate slot along the way (§7.1);
3. **semantic dedup key** — already placed? (§7.2) → skip;
4. **chunk loaded / ownership** — candidate's chunk is loaded;
5. **cheap physical checks** — not on a crossing road (`_is_point_near_road` [:19971](../osm/osm_terrain_generator.gd#L19971)); not in a junction (`_is_point_in_intersection_shape` [:23787](../osm/osm_terrain_generator.gd#L23787), keep ≥~10 m from junction centers); not in water (`_is_point_in_water` [:19945](../osm/osm_terrain_generator.gd#L19945)); not in parking (`_is_point_in_any_parking` [:19915](../osm/osm_terrain_generator.gd#L19915));
6. **sidewalk check** — not on a sidewalk, if footway data is available (footway polygons from the curb/sidewalk system — `_union_footway_polys`);
7. **anti-clip — near ANY building** — `_building_clip_within(point, ~4–5 m)` → reject if inside any footprint or within ~4–5 m (never clip/hug a facade; all building types incl. unknown);
8. **residential exclusion** — `_residential_within(point, ~20–25 m)` → reject (keeps boards off apartment/house frontage; commercial/industrial pass this step);
9. **(optional) landuse / residential polygon** — only if needed and not too expensive; not required for v1.

**Side choice:** test both verge sides; place on whichever passes the gates with more open ground; if neither passes, skip the candidate.

**Orientation (two-sided board) — a visual tuning decision, not hard-coded yet.** Base intent: board **plane roughly perpendicular to the road**, visible faces pointing roughly **along the road**, so approaching traffic sees the surface (each face serves one direction). But pure-perpendicular may read as a thin edge for too much of a high-speed drive-by, so:
- **test pure perpendicular first**;
- **also test a modest deterministic yaw offset (~15–25° off perpendicular)**, turned slightly toward the lane / driving direction, for more screen presence at speed;
- pick in-game by readability; keep the offset **deterministic and subtle** — boards must never look randomly rotated or misaligned.

---

## 7. Determinism, dedup, boundaries, OSM nodes

### 7.1 Global arc-length spacing (refinement over lamps)
Lamps clip-to-rect then walk, which restarts spacing at each chunk edge — fine at 17 m, but would cluster sparse billboards at boundaries. Instead, walk the **full OSM way by cumulative arc-length from node 0**, drop a candidate every **S ≈ 150–250 m** (tunable; sparser on `primary` than `trunk`), assign each to its own chunk. Spacing is then global and identical regardless of which chunk triggered the way.

**Known v1 limitation:** this is global **per OSM way**, not per continuous real-world road corridor. If OSM splits one physical road into several ways, spacing may restart at way boundaries. **Acceptable for v1.** If visible clustering appears at way joins, a later improvement can group connected ways by `name`/`ref`/`highway` class and walk the merged corridor.

### 7.2 Deduplication (semantic keys)
The same way appears in several overlapping fetches, so we must dedup — but prefer a **deterministic semantic key**, not a rounded world position (fragile around overlapping fetches, way splits, parallel roads, sub-metre coordinate differences):
- procedural: `bb_proc_%s_%d % [way_id, candidate_idx]`;
- real OSM nodes (§7.6): `bb_osm_%s % node_id`.
Optionally add a quantized position or chunk key as a *secondary* safeguard. Stored in `_created_billboard_keys`, cleared on `_unload_chunk`/reset like lamps' `_created_lamp_positions` ([:17172](../osm/osm_terrain_generator.gd#L17172)).

### 7.3 Determinism
- Candidate positions are deterministic from way geometry + fixed S.
- Texture pick, verge side, yaw offset: hash `way_id * 2654435761 + candidate_idx` (project standard, [:9665](../osm/osm_terrain_generator.gd#L9665)). **No `randf()`** (it varies per load).
- **Gate outcomes must be deterministic too.** The residential/anti-clip gates must query a **neighbor-aware** building index (§5.2) covering the full fetch overlap, not just the current chunk's buildings — otherwise a candidate near a chunk edge could pass or fail depending on chunk **load order**, silently breaking reload-stability. With region-complete queries the gate result is fixed for a given world position.

### 7.4 Chunk ownership & cleanup
Billboard parented to the chunk node containing its position; placed only when that chunk is loaded; freed on chunk unload. Add `_deferred_billboard_road_queue.erase(ck)` and `_created_billboard_keys` cleanup to `_unload_chunk` / the reset paths.

### 7.5 Performance
Sparse by construction (S spacing + gates). Each board ≈ 2 textured quads + a few frame boxes; the top lamp is a **night-only, shadowless, short-range, distance-culled** light run by the existing night-mode lamp system (§5.3) — **no always-on daytime `SpotLight3D`s**. Shadows off, visibility-ranged, budgeted `add_child`. Expect ≲ a few dozen in view → negligible. Keep a hard per-frame *placement-work* budget like the lamp processor. **No hard per-chunk billboard cap for v1** — spacing + gates are the density controls. (Watch the night-time active light count; revisit only if the profiler flags it.)

### 7.6 Honor the 4 real OSM billboards (optional, cheap)
Add `node["advertising"](%s);` to the Overpass query ([osm_loader.gd:266–277](../osm/osm_loader.gd#L266)), bump `CACHE_VERSION 7 → 8` ([:28](../osm/osm_loader.gd#L28)), parse advertising nodes, place them as exact billboards (use `sides` tag → 1/2-sided), keyed `bb_osm_<node_id>` (§7.2).
- **Bypass the procedural-placement gates** — these are real mapped spots, so skip spacing/candidate-index (§7.1), the residential exclusion (gate 8), and the anti-clip / non-residential margin (gate 7). We trust the mapper's location.
- **Still apply the physical-safety gates** — a node can be mis-mapped, so keep: **not in water**, **not on the road/carriageway**, **not inside a building footprint** (`_building_clip_within` with margin 0 — reject only true overlap, *not* the 4–5 m clearance), and **grounded correctly** (`_sample_elevation` + pole height). If a node fails a safety gate, skip it rather than force an unsafe board.

---

## 8. Implementation order (milestones)

1. **Assets in-engine:** copy `small-city/` → `res://textures/billboards/small-city/`, import, verify `load()` works. Pool loader + selection.
2. **Builder path:** procedural `BillboardDecoration` → `create_billboard_mesh`, `size=[6,3]`, top-lamp behind the opt-in flag (hand-placed boards untouched). Drop **one** test board at a known open-verge spot; verify scale, grounding, orientation, top-lamp **position**, and **night-only** lighting (lamp off in day, on at night).
3. **Building-footprint index:** build `_building_footprint_hash` (with residential flag) + **neighbor-aware** `_building_clip_within` (~4–5 m) and `_residential_within` (~20–25 m); debug print/marker to confirm both tests, including across a chunk boundary.
4. **Road walk + queue + processor:** enqueue trunk/primary ways, global arc-length candidates, deferred incremental build. **Debug-dense mode** (small S, gates relaxed) to confirm placement/spacing, then restore.
5. **Gates:** wire all gates in cheap→expensive order (§6); verify boards keep ~20–25 m off residential but **appear near commercial/industrial** (≥~4–5 m anti-clip), skip sidewalks/junctions/water/parking, and pick the open verge side.
6. **Dedup + unload + determinism:** confirm no doubles across boundaries, stable across reloads, clean unload.
7. **(Optional) OSM nodes:** query + place the 4 real ones.
8. **Tune & verify:** spacing/offset/visibility; FPS at an arterial; A/B screenshot. Remove temp logs.

---

## 9. Tuning parameters (initial guesses, verify live)

| Param | Initial |
|---|---|
| Eligible roads | `highway ∈ {trunk, primary}` |
| Spacing `S` | trunk ~150 m, primary ~250 m |
| Verge setback | road_width/2 + ~2.5 m |
| Anti-clip margin (any building) | ~4–5 m |
| Residential exclusion radius | ~20–25 m |
| Junction clearance | ~10 m |
| Board size | `[6.0, 3.0]` m (2:1), pole ~4.5 m |
| Orientation | base: plane ⊥ road; **try** ~15–25° yaw toward lane — pick in-game (two-sided) |
| Visibility range | ~350 m |
| Top lamp | `top_lamp_enabled=true`, `top_lamp_night_only=true`, `top_lamp_shadows=false`, `top_lamp_short_range=true`; position = top-center, aimed down at board; exact intensity/range tuned in-game |

---

## 10. Verification / testing

- Spawn near a trunk/commercial arterial (north/east Cherepovets); confirm boards on trunk/primary, on allowed verge terrain, **near commercial/industrial frontage is OK** (just never clipping a facade, ≥~4–5 m), **never within ~20–25 m of residential**, correct spacing, grounded, readable orientation, lamp **off in day / on at night**.
- Drive a residential street → **zero** billboards.
- Reload/re-enter chunk → identical placement (determinism), no duplicates at boundaries; confirm a candidate beside a building that **straddles a chunk boundary** is gated correctly (neighbor-aware index) and identically across reloads.
- FPS ≥ baseline at the test spot; draw-call delta small.
- MCP: launch `res://main.tscn` (the driving scene, **not** the menu), frame with a debug camera, screenshot.

---

## 11. Open questions / tune-in-game

- Spacing feel: ~150/250 m ok, or sparser?
- Residential exclusion ~20–25 m and anti-clip ~4–5 m — comfortable, or adjust?
- Orientation: pure perpendicular vs ~15–25° yaw — decide in-game by readability at speed.
- Top-lamp intensity/range/colour — tune live to read as a simple roadside fixture (not a glowing panel).
- (Resolved) Roads = trunk + primary. Building gate = differentiated (residential strong / non-residential anti-clip). Lighting = night-only external top lamp. Dedup = semantic keys. OSM nodes = optional/later. No per-chunk cap.

---

## 12. Files touched (summary)

- `osm/osm_terrain_generator.gd` — building-footprint index w/ residential flag + neighbor-aware `_building_clip_within` / `_residential_within`, enqueue (Phase 3), incremental processor, gates, semantic dedup, night-only lamp lifecycle (reuse deferred lamp-light system), unload cleanup, optional advertising-node placement.
- `osm/decoration_layer.gd` — `create_billboard_mesh` gains an opt-in `with_top_lamp` flag (hand-placed `billboards.json` boards unchanged); pool loader may live here.
- `osm/osm_loader.gd` — (optional) add `node["advertising"]`, bump `CACHE_VERSION`.
- `res://textures/billboards/small-city/*.jpg` (+ `.import`) — new assets.
- No change to the existing hand-placed `billboards.json` path.
