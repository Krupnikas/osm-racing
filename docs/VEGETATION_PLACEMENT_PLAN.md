# Vegetation Placement Plan — layered roadside greenery

**Status:** 📋 PLANNED, awaiting go-ahead. NO code yet. Goal: kill the "flat verge grass / empty
mid-ground" problem with a layered, performance-conscious, post-Soviet-provincial vegetation system.
Assets analyzed (`~/Desktop/OSM material`): `birch_trees_pack.glb`, `low_poly_shrub_2.glb`,
`nettle.glb`, `dandelion_clover_strawberry.glb`.

Vibe guardrails: **rhythm + lived-in neglect, NOT a park simulator or fantasy forest.** Sparse,
believable, weighted toward worn/utilitarian. Birch rows give vertical rhythm; bushes break flat
verges; nettles/weeds sell neglect; flowers are subtle lawn detail only.

**Revision r2 — v1 scope refinements (review-agreed):** birch road-classes are a tunable
(`veg_row_classes`, default primary/secondary/tertiary, trunk off); residential rows only where
side-gates pass confidently (patchy is fine); furniture clearance reuses EXISTING hashes only (lamps/
fences soft); **medians cut from v1** (no reliable signal); L3/L4 capped by **patches**, not raw
instances; **L4 flowers are last + conditional** on texture verification (cut if broken); strict
**land-then-verify per layer** behind per-layer enable flags. Confirmed in code: furniture position
hashes exist (`_billboard_pos_hash`, `_prop_pos_hash`, `_created_sign_positions`,
`_created_bus_stop_positions`, `_lamp_lights_by_chunk`); there is NO median/dual-carriageway signal.

Per-layer enable flags: `enable_veg_rows`, `enable_veg_shrubs`, `enable_veg_weeds`, `enable_veg_flowers`.

---

## 1. What exists today (studied hooks, with file refs)

### 1.1 Tree placement (LOD MultiMesh) — `osm/osm_terrain_generator.gd`
- Models: leaf `models/trees/leaf/scene.gltf` (~3987 v), pine `models/trees/pine/scene.gltf` (~2720 v); pivot normalized (XZ-centred, base Y=0).
- `_generate_trees_in_polygon(points, parent, dense)` (~`:18650`): bbox→area→`max_trees = min(area*density, 600)`; **deterministic** scatter via `fmod(seed + i*prime, 1)` hashes (no `randf`, thread-safe); deterministic yaw + scale 0.5–1.5; gates: `_is_point_near_road_threadsafe(pt,5,road_hash)`, `_is_point_near_building_threadsafe(pt,2,…)`, `_is_point_in_water_threadsafe(…)`, `Geometry2D.is_point_in_polygon`; elevation via `_sample_elevation_static`; 15% pine in dense (`PINE_MIX_RATIO`).
- Dispatch by tag: `natural=wood/tree_row` + `landuse=forest` → dense; `leisure=park/garden` → sparse; JSON `landuse_tree_override`. **Everything else (grass/meadow/residential/scrub/industrial/commercial) → ground texture only, NO trees** (`_create_*_immediate` ~`:11804`–`:11983`). This is the gap.
- Render: per-chunk `_tree_batch_data` → up to 6 `MultiMeshInstance3D` (leaf/pine × LOD); LOD0 0–250 m, LOD1 decimated (effectively off), LOD2 billboard cross-plane 150–250 m (`TREE_LOD2_BEGIN/END`, `shaders/tree_billboard.gdshader`, unshaded + alpha-scissor + cull_disabled, `VISIBILITY_RANGE_FADE_SELF`). Collision: near-road trees only. Built on worker thread, applied per chunk; unloads with chunk.

### 1.2 Road-walk placement pipelines (reusable for ROWS)
- Billboards/props/fences all walk road polylines via a **deferred per-chunk queue** drained in `_process_road_queue` with a μs budget (no frame spikes): `_deferred_prop_road_queue` → `_generate_road_props_incremental(type,points,way_id,highway,width,…)` (~`:21031`); `_deferred_pfence_queue` → `_pfence_*`.
- Road-seg spatial hash carries `{p1,p2,width,way_id,bridge,highway}` (`_query_road_hash(cell,ck)`); `ROAD_WIDTHS` (trunk14/primary12/secondary10/tertiary8/residential6/service4…).
- Pedestrian-fence helpers I just built are directly reusable: `_find_road_edge_point(on,off,ck)` (binary-search the real curb), `_pfence_vehicle_road_clearance(p)` (signed dist to nearest carriageway, width≥4 only — footways excluded), `_pfence_nearest_intersection(center,r)` (hash + linear fallback), `_is_point_on_vehicle_road(p,margin,ck)`, `_intersection_positions/_intersection_curb_contours`.
- Dedup + ownership pattern (fences/billboards): global `_created_*_keys` + per-chunk `_*_keys_by_chunk`, cleared on `_unload_chunk` (→ deterministic rebuild on reload), reset in the regen path.

### 1.3 Spatial indexes / gates available
- Roads `_chunk_road_hashes`; buildings `_chunk_building_hashes` + `_chunk_building_poly_hashes`; water (`_is_point_in_water`/`_threadsafe`); parking `_parking_spatial_hash` + `_is_point_in_any_parking`; intersections `_intersection_*`.
- **Footway polygons** exist: `_union_footway_polys` + `_build_sidewalk_kerbs` (footways are unioned polygons; `enable_sidewalk_curbs`). Sidewalk geometry = a real "verge inner edge" we can use.
- Landuse polygons reach us as queue items `{type:landuse/leisure/natural, nodes, tags, way_id, parent}` (~`:4506`–`:4830`), clipped per chunk by `_clip_polygon_to_chunk`; `_get_polygon_center`.

### 1.4 Rendering conventions to follow
- One MultiMesh per (mesh, chunk); deterministic transforms; `visibility_range_end` + `VISIBILITY_RANGE_FADE_SELF` for culling; shared materials; shadows off for cheap props; collision only where it matters; worker-thread for polygon scatter, budgeted deferred queue for road-walks.

---

## 2. Architecture overview

Four independent **layers**, each its own enable flag, MultiMesh set, deterministic keys, and chunk
ownership. Namespaced `veg_` to stay clear of the existing tree system (`_tree_*`) and iron-bar
`_fence_*`.

| Layer | Asset | Generation source | Render | Collision |
|---|---|---|---|---|
| L1 Street-line trees | birch (3 variants) | **road-walk** along major verges | per-chunk MultiMesh ×3 variants, LOD/billboard | near-road only (thin) |
| L2 Bushes/shrubs | `low_poly_shrub_2` | hybrid: verge road-walk clusters + landuse-polygon scatter | per-chunk MultiMesh | none |
| L3 Weeds/nettles | `nettle` | **patch** scatter in neglected zones + along iron fences/road edges | per-chunk MultiMesh | none |
| L4 Flowers/ground cover | `dandelion_clover_strawberry` | sparse **patch** scatter inside lawn/park/yard polygons | per-chunk MultiMesh, very short range | none |

Shared infra (new, `veg_*`): per-chunk `_veg_batch[ck][layer][variant] = Array[Transform3D]`,
`_veg_keys_by_chunk`, `_created_veg_keys`, deferred road-walk queue for L1, worker-thread scatter for
L2–L4 (reuse the existing tree worker dispatch + thread-safe gates). All cleared on unload + reset.

---

## 3. Asset prep / variant metadata / scale calibration (Milestone 2–3)

- Copy the 4 GLBs into `models/vegetation/`; import; **scale from real transformed leaf vertices**
  (`mesh.get_aabb()` walking baked node transforms — the established get_aabb gotcha), NOT stored AABB.
- `birch_trees_pack.glb`: **split the 3 birch sub-meshes** into 3 cached variant meshes (real height ~17 m). Treat like the pedestrian-fence pre-merge: walk leaves, bake transforms, keep 3 separate `ArrayMesh` + each one's footprint/scale. Material: BLEND → **alpha-scissor (MASK)**, double-sided.
- `low_poly_shrub_2.glb`: real ~4 m clump → target placement scale ~**1.5–2.5 m** (calibrate to real verts). MASK kept. Skip `low_poly_shrub.glb` (OPAQUE).
- `nettle.glb`: real ~1.45 m, 20 tris → use as-is height; OPAQUE → **alpha-scissor if texture has cutout** (verify; else leave opaque).
- `dandelion_clover_strawberry.glb`: native ~758 m → **heavy downscale** (calibrate to a ~1.5–3 m patch from real verts, ≈ ×0.003); **verify the 3 textures actually bind** (baseColor currently empty — may need an import remap or a material override); MASK.
- Store calibrated `{mesh, scale, footprint_radius, base_y}` per asset/variant in a `_veg_defs` dict (mirrors `_prop_defs`).

---

## 4. Layer 1 — street-line birch rows (road-walk)

**Source:** road-walk (NOT landuse polygons), so rows exist on streets regardless of landuse.

**Road-class gate (decisions):**
- Birch road-classes are a **tunable array**: `veg_row_classes` (default `["primary","secondary","tertiary"]`). `trunk` is **off by default** (a birch avenue on a trunk reads too formal/wrong) but stays in the config so it can be flipped on after visual testing — do NOT hard-code the trunk exclusion anywhere it's hard to change. `motorway`, `service`, footways excluded.
- **Residential** (`residential`, length ≥ ~60 m, not service/living_street) is allowed **only when the side-space gates pass confidently** — clear verge/sidewalk-side space, not too close to a building facade, no parking/courtyard-driveway conflict (driveways mapped as `highway=service` are caught by the carriageway gate for free), no road/sidewalk overlap. **If a side is uncertain, skip that side.** Do not force residential rows; **patchy residential rows are acceptable and fit the provincial look.**
- **Both sides** by default (Soviet streets are tree-lined both sides), each side validated independently and dropped where it can't sit (mirrors the fence both-curb + reject-on-road logic).
- **Density by class:** bigger road = *sparser* spacing (birches read as a stately avenue), smaller road = tighter. Initial: spacing ≈ `clamp(8 + road_width, 12, 22)` m — primary ~22 m, tertiary ~16 m, residential ~12–14 m. Tunable per class.

**Lateral placement:**
- Sit on the **verge / sidewalk side**: offset = `road_width/2 + veg_row_offset` (initial `veg_row_offset ≈ 1.5–2.5 m`, beyond the lamp/sidewalk line), anchored to the **real road edge** via `_find_road_edge_point` (curve-following, like the fence), then pushed outward.
- Birch trunk radius is small; trunk at the verge, canopy overhangs — fine.

**Gates (reject a candidate tree if):**
- on/within `veg_road_clear` (~1.0 m) of any **vehicle carriageway** (`_pfence_vehicle_road_clearance`);
- inside/near a **building footprint** (`_is_point_near_building_threadsafe`, ~1.5 m) — no trees in facades;
- in **water** / **parking** (`_is_point_in_any_parking`);
- within `~20 m` of an **intersection centre** (`_pfence_nearest_intersection`) → keep junctions/sightlines clear (Soviet streets thin out at corners anyway);
- within `~6 m` of a **crossing/zebra** (reuse the tagged-crossing detection);
- **Furniture clearance — reuse EXISTING hashes only, no new index subsystem; NOT a v1 blocker.** A small helper `_veg_furniture_clear(point, radius)` queries what already exists: `_billboard_pos_hash`, `_prop_pos_hash`, `_created_sign_positions`, `_created_bus_stop_positions` (and `_lamp_lights_by_chunk` if needed). Keep **hard** clearance for **billboards, crossing/yield/important signs, and bus stops** (don't bury signage). **Lamp posts and fences are SOFT/optional** — trees beside lamps/fences are realistic in Soviet/provincial streets; only add lamp/fence clearance later if visual testing shows real clipping. Ship L1 without depending on a perfect furniture system.
- (optional) skip if it would overlap an L2 shrub cluster centre (see §8 conflict rules).

**Run structure (rhythm with gaps, like wires/fences):** walk each qualifying road; place at regular
spacing; allow **deterministic gaps** (e.g. skip a slot where a gate fails, or a hashed ~1-in-N gap) so
rows feel natural, not CNC-perfect. Stop a run at intersections; restart past them.

**Variant + jitter (deterministic):** pick birch variant `= hash(run_key, slot) % 3`; yaw + scale
(0.85–1.15) from the same hash (no `randf`). Slight lateral jitter (±0.3 m) so the row isn't a ruler line.

**Collision:** near-road birches get a thin capsule/cylinder StaticBody (layer 1) **only within ~30 m of
the carriageway** and capped per chunk (reuse the existing near-road tree-collision policy); distant
ones visual-only.

---

## 5. Layer 2 — bushes / shrubs (`low_poly_shrub_2`)

**Allowed (small clusters, not continuous hedges):**
- road **verges** (sparse clusters), **including `trunk` and `primary` verges where the gates pass** — shrubs are lower-risk than birch rows and keep big-road approaches from reading as totally flat verges. Still sparse + gated, never continuous hedges.
- inside/around **`leisure=park/garden`** and **`landuse=residential`** courtyards (polygon scatter);
- **edges of vacant `industrial`/`commercial`/`brownfield`** land and along the **iron-bar fences** (`_add_fence_to_batch` zones) — Soviet scrubby edges.

**(v1 cut) Medians:** removed from v1 — there's no reliable median/dual-carriageway signal in the
data (only `oneway`/lanes for textures), so guessing risks shrubs in lanes / messy junctions for
little payoff. *Future phase: median shrubs only if a reliable explicit median-strip signal exists.*

**Forbidden:** on roads/sidewalks/crossings, in water/parking, through building footprints or fences,
in dense central pavement, on `forest` polygons (already full of trees).

**Cluster logic:** deterministic **cluster seeds** (a ~25–40 m grid cell hashed per zone) → 2–5 shrubs
per cluster within a small radius (deterministic offsets), not uniform scatter. Density by zone:
residential/park medium, industrial-edge low, verge low. **Cap ≤ ~40 shrubs/chunk.**

**(optional simplification) Verge shrubs may piggyback the L1 road-walk:** drop some shrub clusters in
deterministic gaps between birch row slots instead of running a separate verge road-walk — naturally
interleaves trees + shrubs and is simpler. Keep the separate **polygon scatter** for parks, yards,
industrial edges, and neglected zones. Use only if it simplifies the code without hurting the look.

**Scale variation:** 1.5–2.5 m, deterministic. **Visual-only, no collision.** One MultiMesh/chunk.
Visibility range ~**150 m** + fade.

---

## 6. Layer 3 — weeds / nettles (`nettle`)

**Patch-based** (not uniform): deterministic **patch seeds** on a ~20 m grid, only in **neglected
zones**:
- `landuse=industrial/brownfield/construction/railway`, vacant lots, `natural=scrub`/`grassland`;
- **edges** of parking lots and lower-class road verges (residential/service);
- **along the iron-bar fences** and **behind buildings** (building-edge offset, away from facades faced to the street);
- occasional thin roadside patches on residential streets.

**Avoid:** carriageway, sidewalks/crossings, building interiors, **clean central areas**, and **parks**
(nettles in a kept park read wrong — only allow in explicitly scrub/neglected leisure).

**Patch structure + caps:** cap **PATCHES, not raw instances** (visual noise comes from too many
sprinkled patches). v1: **≤ 8 nettle patches per chunk**, each **3–6 cards** in a ~1.5–2.5 m blob
(deterministic offsets) → **~40–60 instances/chunk max**. Scale 0.8–1.3, deterministic yaw. **No
collision.** Visibility range **~60 m** (small; distant pop-in invisible). One MultiMesh/chunk. Start
sparse; raise the patch cap only if the scene still feels empty.

---

## 7. Layer 4 — flowers / clover / dandelion ground cover (`dandelion_clover_strawberry`) — LAST + CONDITIONAL

**This is the final, optional layer.** Do NOT implement or enable L4 until: L1 birch rows are stable,
L2 shrubs are stable, L3 nettles are stable, AND the dandelion/clover/strawberry **textures bind
correctly** and **scale is visually verified**. **If texture binding stays broken or scale stays
fiddly, skip L4 for now** — it's the highest "too cute / park-simulator" risk and the only layer with
an unresolved asset problem (empty baseColor). Target = subtle lawn detail, never decorative clutter.

**Sparse decorative patches**, only on **kept green**:
- `leisure=park/garden`, `landuse=grass/meadow/recreation_ground`, residential **courtyard lawns**,
  identifiable **school/kindergarten** yards (`amenity=school/kindergarten` polygons if available).
- Near residential, never on roads. **Not on major road verges. Not in industrial/brownfield/neglected zones** (those get nettles).

**Avoid:** roads, sidewalks, parking, water, intersections, industrial/brownfield.

**Patch structure + caps:** cap **PATCHES** — v1: **≤ 5 flower patches per chunk**, each **3–6 cards**
→ **~20–30 instances/chunk max**. **Heavy downscale** (calibrated ~1.5–3 m patch). **Short visibility
range ~50 m**, maybe chunk-local / near-player only. **No collision.** Start sparse; raise only if needed.

---

## 8. Placement zones, asset matrix, and conflict rules

**Zones → allowed layers:**

| Zone (source) | Birch rows | Shrubs | Nettles | Flowers |
|---|---|---|---|---|
| Road verge — major (primary/secondary/tertiary) | ✅ rows | ✅ sparse clusters | ▵ residential/edge only | ✕ |
| Road verge — trunk / big approach | ✕ (tunable via `veg_row_classes`) | ✅ sparse, gated | ▵ edge only | ✕ |
| Road verge — residential | ✅ selected (confident side-gates only) | ✅ | ✅ occasional | ✕ |
| Park / garden (leisure) | (existing trees) | ✅ | ✕ (unless scrub) | ✅ |
| Grass / meadow / recreation (landuse) | ✕ | ▵ | ▵ | ✅ |
| Residential courtyard/yard | ▵ | ✅ | ▵ edges | ✅ |
| Industrial / commercial / brownfield / vacant | ✕ | ✅ edges | ✅ | ✕ |
| Building edge (street-facing) | ✕ (facade gate) | ▵ | ✅ behind | ✕ |
| Iron-fence edge | ✕ | ✅ | ✅ | ✕ |

(✅ primary, ▵ occasional/gated, ✕ forbidden)

**Conflict / priority rules (resolve in this order):**
1. Roads/sidewalks/crossings/parking/water/buildings/fences are **hard exclusions** for all layers (each layer runs the relevant gate).
2. **Birch rows win** over shrubs/weeds within their slot radius (don't scatter a shrub through a row tree). Layers placed in order L1→L2→L3→L4; later layers consult earlier layers' position hash (cheap cell lookup) and skip if too close.
3. Shrubs/weeds **never** spawn through fences/buildings (poly + edge gates).
4. Flowers **never** under road props or on any non-lawn zone.
5. Keep **intersections/crossings clear** for all layers (sightline + the "don't bury signs" gate).
6. Global per-chunk caps per layer prevent clutter blowups even if zones overlap.

---

## 9. Determinism + keys (no `randf` for anything persistent)

Hash style = project standard (`(id * 2654435761 + salt) & 0x7FFFFFFF`) + the thread-safe `fmod(seed+i*prime,1)` scatter used by trees. Keys:
- **Birch row tree:** `vt_<road_way_id>_<side>_<slot_index>` (slot = integer step along the run). Variant/yaw/scale from `hash(key)`.
- **Shrub cluster:** `vs_<zone_id|way_id>_<cellx>_<celly>` (cluster grid cell); per-shrub offset from `hash(key, j)`.
- **Weed patch:** `vw_<zone_id>_<cellx>_<celly>` on the ~20 m grid.
- **Flower patch:** `vf_<poly_way_id>_<patch_index>`.

All registered in `_created_veg_keys` (+ per-chunk list) so reload reproduces identical placement and
chunk-boundary candidates dedup (the same key from two chunks places once).

---

## 10. Streaming & ownership

- **Per-chunk ownership:** all instances parented to the chunk node → freed on `_unload_chunk`; `_veg_batch[ck]` + `_veg_keys_by_chunk[ck]` erased there (clearing the chunk's keys from `_created_veg_keys` so reload rebuilds — the established no-persistence pattern).
- **Generation source per layer:**
  - L1 birch rows: **deferred road-walk queue** (`_deferred_veg_row_queue`), drained in `_process_road_queue` under a small μs slice (mirrors fences/props) — main thread, budgeted.
  - L2–L4: **worker-thread polygon/patch scatter** (reuse the tree worker dispatch + thread-safe gates), results applied per chunk on the main thread as MultiMesh — no main-thread scatter cost.
- **Reset:** clear all `_veg_*` dicts in the regen/reset path (alongside the existing `_reset_wire_state` / tree clears).
- No frame spikes: budgeted drain for L1; worker thread for L2–L4; per-chunk MultiMesh built in one `_budgeted_add_child`.

---

## 11. Rendering / LOD / performance budget (conservative)

- **MultiMesh per chunk per asset-variant** (birch ×3, shrub ×1, nettle ×1, flower ×1) → ≤ ~6 MultiMesh nodes/chunk added by this system. Shared materials (one per asset).
- **Alpha-scissor everywhere** (no BLEND) to avoid transparency sorting cost.
- **Shadows:** birch LOD0 only (cheap, few); shrubs/weeds/flowers **shadows OFF**.
- **Visibility ranges (initial):** birch ~250 m (+ optional billboard LOD reuse of the tree billboard path); shrubs ~150 m; nettles ~60 m; flowers ~50 m. All `VISIBILITY_RANGE_FADE_SELF`.
- **Caps (initial, tune up only if empty):** per chunk — birch ≤ 60, shrub ≤ 40; **nettle ≤ 8 PATCHES (~40–60 instances), flower ≤ 5 PATCHES (~20–30 instances)** — cap patches, not raw instances (noise = too many sprinkled patches). Per road run birch ≤ ~12/side between intersections; per polygon shrub scaled by area with a hard cap.
- **No collision** except near-road birches (thin, ≤ ~30 m of carriageway, per-chunk capped).
- **Draw-call budget:** stays within the existing vegetation MultiMesh budget (per `OPTIMIZATION_PLAN.md`); re-measure FPS/draws after each layer; back off caps if regressions.

---

## 12. Import / material fixes (Milestone 2)

- birch: split pack → 3 variants; BLEND → **alpha-scissor/MASK**; double-sided; verify ~17 m real height.
- shrub: use only `low_poly_shrub_2.glb` (MASK); skip `low_poly_shrub.glb`.
- nettle: verify cutout → **alpha-scissor** if so; confirm ~1.45 m.
- dandelion: **verify 3 textures bind** (baseColor empty → may need `.import` remap or material override); calibrate **heavy downscale** from real verts.
- All: don't create `.import` by hand — let the editor import; **scale from real transformed verts**.

---

## 13. Debug tools (default OFF)

`veg_debug` flag gates everything:
- candidate-point markers (color per layer); rejection-reason tally (on-road / building / water / parking / intersection / furniture / too-close-to-other-layer);
- birch **run** visualization (line + slot markers, like the fence green dots);
- shrub/weed/flower **patch/cluster bounds** (wire spheres);
- per-chunk per-layer **instance counts** (one-line log);
- `veg_force_dense` (relaxed spacing/caps for stress test); per-layer `enable_veg_rows / _shrubs / _weeds / _flowers` toggles.

---

## 14. Visual verification checklist (mandatory, in-engine)

Launch `res://main.tscn` directly (not the menu), load a Cherepovets location directly; test day (and
night if relevant); inspect at driving distance + close-up; screenshots/debug camera as needed. Self-test, don't ask the user to verify.

- roadsides no longer flat/empty; verges read inhabited;
- birch rows rhythmic but **not** artificially perfect; thin out at intersections;
- shrubs fill verges/medians **without blocking roads** or clipping fences/buildings;
- nettles look like **neglected detail** in scrubby/industrial/edge spots — not random giant plants, not in clean parks;
- flowers are **subtle** lawn detail — not huge, not obviously repeated, only on kept green;
- **nothing** in driving lanes, on zebras, in parking, in water; none floating or sunk; scale believable;
- density not too high; **FPS stable** (profiler within budget; compare before/after);
- reload determinism: drive away + back → identical placement, no duplicates at chunk borders.

Suggested test sites: Северное шоссе / Советский проспект (major rows), a residential block (courtyard
shrubs/flowers), an industrial edge (nettles), a park (flowers + existing trees).

---

## 15. Implementation milestones

1. **Study** current tree/veg/chunk/MultiMesh systems — ✅ done (see §1).
2. Import + validate the 4 assets; fix alpha; verify dandelion textures.
3. Asset/variant metadata + **scale calibration** from real verts (`_veg_defs`); split birch pack into 3.
4. **Prototype one birch row** on one known major road (manual), verify scale/orientation/curb-follow/grounding/no-on-road.
5. Deterministic **road-row placement** (L1) full: gates, both-side, runs+gaps, variants, caps, near-road collision, deferred queue, dedup, unload/reset.
6. **Shrub layer** (L2): verge clusters + polygon scatter.
7. **Weed patch layer** (L3): neglected-zone patches + fence/edge.
8. **Flower/ground-cover layer** (L4): sparse lawn/park/yard patches.
9. **Conflict/gate** cross-checks between layers + intersection/sign clearances.
10. **Batching/LOD/culling** pass; visibility ranges; shadows; caps; alpha-scissor.
11. **Debug visualization** (default off).
12. **Visual density tuning** in-engine (per §14).
13. **Performance test** (FPS/draws before/after; back off caps if needed).
14. **Cleanup + final report**; commit only when asked.

**Strict layer-by-layer landing (HARD RULE — do not enable all layers at once):** each layer has its
own enable flag (`enable_veg_rows` / `_shrubs` / `_weeds` / `_flowers`). Required order:
1. L1 birch rows only → 2. tune + visually verify L1 → 3. perf-check L1 →
4. add L2 shrubs → 5. tune + verify L1+L2 → 6. perf-check L1+L2 →
7. add L3 nettles → 8. tune + verify L3 → 9. perf-check L1+L2+L3 →
10. add L4 flowers **only if** the asset is verified (textures bind, scale ok) and earlier layers are stable.
This isolates any visual-noise / FPS regression to a single layer. Final report includes **per-layer
instance/patch counts + perf observations**.

---

## 16. Open questions

**Resolved in r2:** (1) residential birch = length ≥ 60 m, both sides, **confident side-gates only**, skip-per-side, patchy OK. (2) Both sides, drop-per-side on gate failure. (3) **Medians dropped from v1** (no reliable signal). (furniture) reuse existing hashes, lamps/fences soft. (caps) patch-based. (L4) last + conditional.

Remaining (resolve during coding):
4. **Neglect zones** — does the OSM data carry `brownfield`/`construction`/`landfill`/`railway` landuse here, or mostly `industrial`? Tune L3 source set to what's actually present in Cherepovets cache.
5. **School/kindergarten yards** — are `amenity=school/kindergarten` polygons available for L4 targeting, or fold into generic residential/grass?
6. **Dandelion textures** — do they bind after import, or need a material override? (blocks L4 if broken.)
7. **Billboard LOD for birch** — reuse the tree cross-plane billboard at 150–250 m, or just `visibility_range_end` cull at ~250 m for v1? (default: cull for v1, add billboard later if perf allows.)
8. **Interaction with the existing tree system** — keep fully separate (`veg_*`), or feed birches into the existing `_tree_*` MultiMesh? (default: separate, to avoid disturbing the proven tree path.)
