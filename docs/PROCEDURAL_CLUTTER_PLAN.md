# Procedural Interactive Clutter — Plan

## Design intent
"Occasional objects here and there" — **moderate** density: lived-in, not a playground.
Each piece is **interactive**: hit it → it flies / flops + plays a material-appropriate
sound, and (phase 2) **deforms a little**. Placement is **procedural and deterministic**
(same seed → same clutter every reload, no popping), derived from OSM anchors we already
extract, gated so it never clutters where it would be annoying.

## Model inventory
All five live in `~/Desktop/OSM material/`. They get copied to `models/<name>/` and
imported exactly like the Ладья (self-contained GLB with embedded textures; let the Godot
editor generate `.import`). **Raw extents below are pre-node-transform** — final in-engine
scale is tuned visually (the Ладья needed 10.5×), so treat sizes as relative hints only.

| Model | Sub-objects | Raw extent X×Y×Z (m) | Tris | Role |
|---|---|---|---|---|
| `green_metal_waste_bin` | 1 mesh | 1.15 × 1.90 × 1.15 | 1903 | Metal urn at crossings |
| `road_works_stylized_pack` | **3 meshes** (identified on bench) | cone≈0.5 / tripod≈0.7 / disc≈0.7 | 1112/1344/1580 | **orange traffic cone** + **folding tripod warning-sign stand** + **manhole cover / round disc** |
| `warning_sign_barrier` | 1 mesh | 2.31 × 1.45 × 1.19 | 412 | A-frame "ДОРОЖНЫЕ РАБОТЫ" gateway / race hazard |
| `low_poly_trash_bag` | 1 mesh | (has small node scale) | 961 | Soft litter bag, flops |
| `dirty_crumpled_pieces_of_paper` | **6 meshes** | 0.15–0.55 each | 16–72 | 6 paper-scrap variants for school litter |

**None have blend shapes / morph targets** — so deform is shader/scale-driven, not morph-driven (see Deform).

## Architecture — dormant ↔ live hybrid
A MultiMesh instance cannot move, so interactive clutter has two states:

- **Dormant:** rendered as a per-type **MultiMesh** instance (cheap, hundreds, no physics).
- **Live:** within ~**35 m** of the car, the nearest dormant instances are swapped for real
  `RigidBody3D`s drawn from a **pool capped at ~40**. On contact → impulse + sound + deform.
  A live body stays live-but-**sleeping** until its chunk unloads (keeps dents/positions
  stable without re-baking dents into a MultiMesh).

Pieces:
- **`ClutterManager`** node under `Main` (sibling of `TrafficManager`): owns the RigidBody
  pool, the activation radius check against the car, contact → impulse/sound/deform.
- **Per-chunk clutter pass** in `osm_terrain_generator.gd` (alongside trees/lamps): collects
  anchors in the chunk, applies rules, emits **dormant records** `{type, transform, mass_tier}`
  + the per-type MultiMesh.
- Reuses existing primitives: chunk-seed hash (`chunk_x*73856093 + chunk_z*19349669`),
  `way_id`/`node_id` hashing, `_is_point_near_road`, `_is_point_near_building`,
  `_is_point_in_water`, `_is_point_in_any_parking`, `_sample_elevation`, `_latlon_to_local`.

## Placement rules (per object)
1. **Metal bin → pedestrian crossings.** One bin per OSM `highway=crossing` node (tune: maybe
   not all), offset to the **sidewalk corner** by the pole. Hashed by crossing-node id → never
   in the roadway, stable. Mass tier **medium-springy**, metal clang, rolls/flies, dent shader.
2. **Cones → arterial lane-narrowing worksite.** `hash(way_id) % N == 0` selects ~one worksite
   per N long **primary/secondary** ways (`N` = "not too often" knob). **Excludes**
   residential/service/footway. Site = cone taper pinching one lane into a mini-chicane.
   Biases that make it feel deliberate: prefer **long straight arterial segments** and/or
   **bridge/ramp approaches** (already detected). Mass tier **featherweight**, plastic clatter,
   squash.
3. **`warning_sign_barrier`.** Two sparse homes: (a) the **entry gateway** of the cone worksite
   above; (b) occasional **race-route hazard** at a corner/chicane (RaceManager knows the track).
   Mass tier **heavy**: topples + slides, doesn't launch.
4. **Trash bag → flops, doesn't fly far.** Placement near bins (overflow), service/back of
   buildings, courtyards near dumpster enclosures. Sparse. Mass tier **soft-heavy**: high
   linear + angular damping, low bounce → lurches ~0.5 m and stops. Soft "fwump", light squash.
5. **Crumpled paper → school proximity.** Detect `amenity=school`/`kindergarten`; lay a litter
   field with **density falloff from the gate**. Bulk rendered as **static MultiMesh** (6 variants
   = variety); only the handful **on the drivable surface** become **ultra-light** physics that
   puff/flutter (near-zero mass, high air drag — swirl, don't launch). Soft paper rustle.
6. **Штендеры (sandwich boards) → parked.** Design hook kept (outside ground-floor shops, from
   the storefront detector) but **not built** until a model exists.

## Mass tiers & physics feel
| Tier | Objects | mass | damping / bounce | behaviour |
|---|---|---|---|---|
| Featherweight | cones | ~1.5 kg | low | scatter wildly |
| Medium-springy | metal bin | ~8 kg | low damp, some bounce | rolls + flies, clangs |
| Heavy | warning_sign_barrier | ~12 kg | med | topples, slides, no launch |
| Soft-heavy | trash bag | ~6 kg | **high** damp, ~0 bounce | flops ~0.5 m, stops |
| Weightless | paper scraps | ~0.05 kg | **high air drag** | puff / flutter / swirl |

## Audio
Per-material one-shots on first hard contact: **metal clang** (bin), **plastic clatter**
(cones), **wood/plastic knock** (barrier), **soft fwump** (bag), **paper rustle** (scraps).
SFX assets TBD (source/record). Spatialized via `AudioStreamPlayer3D`.

## Deform (phase 2 — fly + sound ship first)
- **Permanent dent — vertex-displacement shader** on the **metal bin**: up to ~4 impact points
  as uniforms (local-space hit pos + depth + radius); vertex shader pushes verts inward within
  each radius. No extra meshes, cheap, stays dented.
- **Squash-and-stretch — transient scale** on **cones + trash bag**: impact spikes a
  non-uniform scale that eases back partway. Near-free, reads well for plastic/soft.
- **Paper:** no deform (already crumpled — just flutters).

## Testing methodology (self-test before wiring into the city)
Isolated bench scene `tests/clutter_bench.tscn` (flat ground + light + fixed camera) so each
model is validated in clean conditions. Driven via `execute_game_script` + screenshots. Three
axes per model:

- **Size.** Instance → add to tree → measure **global AABB**. Auto-scale to a real-world target
  (bin 1.0 m tall, cone 0.6 m, barrier ~1.1 m, bag 0.6 m, paper ~0.25 m longest side). Screenshot
  beside a **1 m red reference cube** (and optionally the player car) to sanity-check by eye, and
  print the measured dims so scale is a number, not a guess.
- **Collision.** Wrap in `RigidBody3D` with the candidate collider (bin → cylinder, cone →
  cylinder approx, barrier/bag/paper → box; upgrade to convex hull if the box reads wrong), drop
  from ~3 m onto the ground. **Pass = rests stably** (no jitter, no sink, no fall-through). Cross-check
  with `get_collision_info` / the collision visualizer.
- **Effects.** Apply a lateral **central impulse ≈ mass × 8 m/s** (a ~30 km/h clip), capture a
  frame sequence, and **log resting distance**. Pass criteria per tier: cones scatter several m,
  bin rolls/flies + clang, barrier topples without launching, **bag flops < ~0.5 m**, paper
  flutters/swirls. Sound = log "played" on first contact (can't hear in headless). Deform (phase 4)
  = feed an impact point to the dent shader / trigger the squash and screenshot before/after.

The bench stays in `tests/` and is reused to re-validate after each phase.

**Bench findings (first pass — bin / barrier / bag):**
- Auto-scale-by-AABB works (handles the bag's cm units). Validated scaled sizes & scales:
  bin → **0.60 × 1.0 × 0.60 m** (scale 0.526, cylinder collider), barrier → **1.9 w × 1.2 t**
  (scale 0.83, box), bag → **0.87 × 0.65 m** (scale 0.0065, box).
- Collision: barrier + bag rest stably; the green bin is **on legs/a post** and stands upright
  **when spawned at rest** (a 2.5 m drop tips it — so placement must drop ~0 m, not from height).
- Effects (clean **velocity-set hit ≈ 7 m/s**, not impulse×mass): bin slid **2.2 m** upright,
  barrier **1.9 m**, **bag flopped only 0.71 m** — desired relative feel (bag = soft, won't fly).
- **Test gotcha:** the played scene runs in **real time across MCP tool round-trips** (~25 s of
  physics elapsed between calls once), so a near-frictionless body coasts off the stage. Always
  `get_tree().paused = true` immediately before measuring/screenshotting.
- Cone / tripod / manhole physics validated in Phase 2 after splitting the pack.

## ClutterManager (the backbone — `clutter/clutter_manager.gd`)
**Lesson learned the hard way:** the per-chunk infrastructure queue is fine for dense, near-player
items (crossing bins) but **loses sparse/far clutter** (worksite cones): nodes added to chunk
nodes during streaming get silently removed by chunk regeneration/trim, and only ~2 of every 18
cones survived. Fix = a **persistent `ClutterManager`** node (child of `OSMTerrain`, NOT of any
chunk):
- Terrain registers **dormant records** (`{type, pos}`) — idempotent by rounded position.
- The manager spawns the real frozen `RigidBody` only within `ACTIVATE_R` (140 m) of the player
  and frees it past `DEACTIVATE_R` (175 m); records persist, so clutter reliably reappears.
- Build budget (6/scan @ 5 Hz) avoids frame spikes. `_create_bin_immediate`/`_create_cone_immediate`
  return the body; the manager parents it to itself (at world origin) and tracks it for despawn.
- Both bins and cones now route through it (`register("bin"|"cone", pos)`); clear on location change.

## Build order
- **Phase 0 — assets.** ✅ Copied 5 models into `models/`, imported. Cone identified = pack piece 1.
- **Phase 1 — bins at crossings.** ✅ Committed `9727ec7`; migrated onto the ClutterManager.
- **Phase 2 — roadworks cones.** ✅ Complete 6-cone lane-narrowing taper on arterials, via the
  ClutterManager. Player-only reaction, plastic hit/drop sounds. (Tripod + manhole pack pieces parked.)
- **Phase 1 — backbone + crossing bins.** `ClutterManager` + dormant/live pool + first rule
  (bins at crossings). First visible win + first physics test.
- **Phase 2 — roadworks kit.** Cones + `warning_sign_barrier`, arterial worksite trigger, taper.
- **Phase 3 — litter set.** Trash bags + paper-near-schools (static scatter + few dynamic).
- **Phase 4 — deform + audio polish.** Dent shader (bin) + squash (cones/bag) + all SFX.

## Open items / TBD
- Identify the 3 road-works pack pieces and their roles (visual inspection after import).
- Final in-engine scales for every model.
- `N` (worksite rarity), bin-per-crossing ratio, litter density/falloff numbers.
- SFX assets.
- Confirm OSM coverage of `highway=crossing` and `amenity=school` in the Cherepovets data.
