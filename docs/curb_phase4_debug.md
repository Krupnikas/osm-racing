# Phase 4 — Street Section (curbs + concrete sidewalk + verge) — Debug Log

Goal (from `docs/SOVIET_VIBE_PLAN.md` Phase 4): restore the readable Soviet street section
**road → worn markings → raised curb → concrete sidewalk → (fenced) grass verge → trees → buildings**,
without breaking the bridge-seamless rule, batching/LOD, or the day/night contract.

## Why this was deferred before

`memory/curb_junction_debug.md` records **8 failed attempts**. Re-reading them, every one was
fighting the *same* sub-problem: **footway/sidewalk-to-sidewalk junctions** — curbs appearing in the
middle of pedestrian-crossing corners where two long footway ways cross. Root causes they hit:
- removing a curb *segment* removes **both** edges (can't drop one side at a T-junction);
- footways are often **one long segment** (whole street) → segment-intersect over-deletes everything;
- no sweet spot between aggressive (holes) and conservative (no trim).

The resolution back then was a blunt one: **zero `curb_height` for every highway class**, so there
are currently **no curbs at all**.

## Root-cause re-frame (what the 8 attempts missed)

Reading the live code (2026-06-05):

- Curbs are generated along **both edges of the carriageway** — `_process_curb_segments` takes the
  road centerline ± `road_width*0.5`. `width` = `_get_road_width` = lanes×3.5 / ROAD_WIDTHS, i.e. the
  **carriageway only** (residential 6 m, secondary 10 m…). So a curb at `width*0.5` sits exactly at the
  carriageway edge — precisely where a real curb belongs (road | curb | sidewalk).
- Curbs are queued **only when `curb_height > 0`** (`osm_terrain_generator.gd:5201`).
- **Road–road junctions are already solved**: `_init_curb_mesh_state` marks curb segments invalid via
  `_is_point_in_intersection_shape(...)` so curbs don't cross car intersections.
- **Bridges are already solved**: `_process_curb_queue` skips curbs whose points lie on a bridge deck
  (`_any_point_on_bridge_deck`), and bridges build their own sidewalk+curb. Bridge-seam rule respected.
- The collision is a thin (2 cm) **mountable top-slab** on every 3rd segment — a curb bump, not a wall.

**Key insight:** the hard, 8-times-failed problem only exists when **footways themselves** get raised
curbs (footway×footway corners). If curbs are raised **only on vehicle carriageways** and footways stay
flat (`curb_height = 0`), that entire failure class never arises — and we still get the road→curb→
sidewalk transition the reference shows.

## Plan

- **4a — Curbs:** raise `curb_height` (~0.14 m) for urban vehicle roads only:
  `residential, unclassified, tertiary(+_link), secondary(+_link), primary(+_link)`.
  Keep `0.0` for: `motorway/trunk(+_link)` (fast roads, barriers not urban curbs),
  `footway/path/cycleway/track` (the sidewalks themselves — flat, avoids the junction saga),
  `tram/tram_rails`, `service` (driveways/parking — start at 0, revisit).
- **4b — Concrete sidewalk:** swap footway (`"path"`) texture from Asphalt022 to a concrete look
  (procedural `create_concrete_texture`/`create_sidewalk_texture` exist). Texture-only, low risk.
- **4c — Verge:** weedier/greener verge grass; optional low fence band via existing fence material.

## Attempts

### #1 (Phase4a) — Raise curbs on vehicle carriageways only  ❌ WRONG TASK
- **Change:** `curb_height = 0.14` for residential/unclassified/tertiary(+link)/secondary(+link)/
  primary(+link); all others stay `0.0`.
- **Result:** User feedback — this added a **second** pair of curbs on roads. **Road curbs already
  exist and work.** REVERTED. The actual task is **curbs on the SIDEWALKS (footways)**.

---

## Re-frame #2 — corrected architecture (2026-06-05, after live inspection)

The whole world is **roads carved DOWN into a raised grass plane**:
- All terrain/grass sits at `elevation + 0.22` (`_create_deferred_terrain`-side mesh, `sidewalk_height=0.22`).
- The **"road curb that works"** is the vertical face of each **terrain (grass) polygon edge** where it
  borders a road — a 0.22 m step with `_curb_material` (`osm_terrain_generator.gd:17995-18095`).
- **Street footways (sidewalks)** are just **flat Asphalt022 texture strips painted on the raised grass**
  (`_add_path_polys_to_batch`, height_offset 0.23, ~1 cm proud) — **no kerb of their own**. That's why
  they read as flat paths on grass.
- Bridge sidewalks DO have a kerb (`_create_on_deck_footway:7076`) but that's a special bridge path — not
  the model for ground streets.

### User's spec for sidewalk kerbs (verbatim intent)
1. Kerb only on the **OUTSIDE** of the sidewalk.
2. At sidewalk×sidewalk junctions: **only the outer perimeter** is bordered — **no kerb through the middle**.
3. Where a sidewalk is **directly adjacent to a car road** (no grass between): **no kerb** there (road
   curb already does the job).

### Approach (why it beats the 8 failed polyline attempts)
The old attempts extruded kerbs on footway **polylines** (centerline ± width/2); crossing polylines put
kerbs through junction interiors. Instead, footways are already **polygons** (clipped by roads/
intersections/parking). So:
- **Union all footway polygons per chunk** (`_union_footway_polys`, `Geometry2D.merge_polygons`) → junction
  interior edges vanish by construction; only the outer perimeter remains (rule 2, for free).
- For each merged-boundary edge, sample a point just **outside**; if it lands on a vehicle road
  (`_is_point_on_vehicle_road_neighborhood`) → **skip** (rule 3). Else extrude a concrete kerb (rule 1).
- Done at chunk finalization (`_finalize_road_batches_for_chunk`) where all footways are together.

### #2 (Phase4) — Unioned-outline sidewalk kerbs  ✅ WORKS
- **Change:** `_union_footway_polys` + `_build_sidewalk_kerbs`; gated by `enable_sidewalk_curbs`.
  Kerb: concrete strip (`_curb_material`), ~0.12 m wide.
- **Debug verification (red/blue test at the junction):** painted kept-edges RED, road-suppressed
  edges BLUE. Counters: **calls=8 chunks, loops=53, kept=373, skipped(road)=287**.
  Screens: `screenshots/curb_sw_redblue.png`, `curb_sw_redblue_wide.png`.
  All three rules confirmed visually:
  1. ✅ Kerb (red) only on outer / grass-facing edges.
  2. ✅ Union → clean perimeters, no kerb through sidewalk-junction middles.
  3. ✅ Road-adjacent edges (blue) suppressed — along the top-road sidewalk you can see the
     blue road-side line parallel to the red grass-side kerb.
- **Note:** top-down badly understates coverage — a 0.12 m kerb is ~2 px from 80 m up. Oblique
  shows true coverage.
- **Finalize:** swap red/blue debug material → `_curb_material` (concrete), height tuning below.

### #3 (Phase4) — Incomplete coverage on long footways  ✅ ROOT-CAUSED & FIXED
- **Symptom (user):** the kerb (and even the green raw-footway debug outline) "abruptly ends" while
  the sidewalk continues per the OSM map. Specifically **way 365255428** (a 2-point, ~156 m footway,
  faces grass) got **no kerb at all**, while short footways nearby did.
- **Root cause — ELEVATION, as the user suspected:** the kerb was built one quad per *whole* polygon
  edge, sampling elevation only at the two endpoints → a straight **chord**. The slab follows terrain
  on a 5 m grid, but the chord doesn't. Measured along 365255428: endpoints 120.41→118.34 m, but the
  terrain **rises to 121.18 m at t=0.25**. The chord there sits ~1 m **below** the grass surface →
  kerb buried/invisible. Short footways don't span enough terrain to bury, so they showed kerbs.
- **Fix:** subdivide every boundary edge into ~3 m sub-segments and sample elevation per sub-point
  (`_swkerb_add_quad`), so the kerb follows the terrain like the slab. Road-adjacency (rule 3) is now
  tested **per sub-segment** too (more accurate on long edges).
- **Verification:** kept-edge count **373 → 2642** (long edges now many sub-quads). With vegetation
  off (`curb_sw_fixed_noveg.png`), 365255428's red kerb runs its **full length following the terrain**.
- **Then:** re-enable vegetation, swap debug material → concrete, remove debug meshes/counters.
