# Watermelon Pallet Stands near the Market Gate — Implementation Plan

📋 **Planned — awaiting go-ahead.** Exact anchor provided. No code/assets created yet.

Two interactive market watermelon displays at the **user-chosen authoritative anchor**
`59.145658, 37.946375` (by the bazar gate). Each = a pallet base + a 4-layer watermelon pyramid +
2 display slices. Low-speed car hit → individual watermelons scatter/roll off; ≥30 km/h hit → burst
into red pulp + green-rind debris. **Preferred build: individual frozen watermelon bodies** (visual
MultiMesh only as a fallback). Placement is exact — no auto-relocation (§6).

---

## 1. Codebase findings (file:function references)

### Interactive / destructible prop precedents (the closest pattern to reuse)
- **Clutter system** — `clutter/clutter_manager.gd` (distance activation `ACTIVATE_R=140`,
  `DEACTIVATE_R=175`, `register(type,pos,meta)`, `_records`, `_seen` dedup, `_build`, distance-based
  `queue_free`) + builders in `osm/osm_terrain_generator.gd`:
  - Cone (frozen-KINEMATIC RigidBody + **Area3D player trigger**): `_create_cone_immediate` (~11364),
    `_on_cone_trigger` (~11442). Area3D: `collision_layer=0, mask=1` (player only), wakes the body.
  - Bin (frozen RigidBody + `body_entered`): build ~11160, `_on_clutter_hit` (~11094).
  - Bag + **burst-into-debris** at high speed: `_on_bag_trigger`/`_burst_bag_into_paper` (~11267–11346)
    — the template for our pulp burst (spawn N light RigidBodies, set `linear_velocity` directly,
    `create_timer(...).timeout → queue_free` cleanup).
  - Paving-works **composite** prop (Node3D container with roller+barrier+cones):
    `_register_paving_works_on_way` (~11585), build ~11504. Precedent for a multi-part stand.
- **Speed read at impact (clutter/signs convention):**
  ```gdscript
  if other_body is RigidBody3D: car_speed = other_body.linear_velocity.length()
  elif other_body is VehicleBody3D: car_speed = other_body.linear_velocity.length()
  ```
  (`_on_clutter_hit` ~11106, `_on_bag_trigger` ~11261, `_on_sign_hit` ~10766). Speed is **m/s**.
- **Fence shatter (≥40 km/h)** — `osm/osm_terrain_generator.gd`: threshold `pfence_shatter_speed := 10.5`
  (line 755, "~38 km/h, just under 40"), player **approach-velocity history** kept in `_process`
  (~1939) and read via `_pfence_player_approach_vel()`, threshold check ~22527, shard spawn
  `_pfence_spawn_pieces` (~22580: shards on `layer 4`, `mask 1|2` so they don't fight the car),
  TTL `pfence_piece_ttl := 9.0` (760), FIFO cap of 6 instances (~22572), double-trigger guard
  `_pfence_shattered[ck][idx]` (~22550).
- **Sign hit** — `_on_sign_hit` (~10766): `body_entered.connect(_on_sign_hit.bind(body))`, body is
  frozen `FREEZE_MODE_KINEMATIC` then `freeze=false` + `apply_central_impulse(dir*clamp(speed*20,…))`.

### Speed / km/h
- Player car (GEVP) exposes `vehicle.speed` (m/s) — `addons/gevp/scripts/vehicle.gd:646`
  (`speed = local_velocity.length()`). From a collision body ref, `body.linear_velocity.length()`.
- km/h conversion is `* 3.6` — `ui/hud.gd:71-72` (`_current_speed = speed_ms * 3.6`),
  `traffic/near_miss_detector.gd:45`. **30 km/h = 8.333 m/s.**

### Collision layers (established)
- **1** = road + player (player car `collision_layer=1`, `collision_mask=7`).
- **2** = static obstacles (buildings, walls). **4** = clutter / destructible / debris.
- Debris spawned on layer 4 with mask `1` (ground only) or `1|2`, and an
  `add_collision_exception_with(car)` so the car doesn't get stuck on its own debris (cone pattern ~11455).

### Manual placement / chunk ownership
- **`custom_models`** JSON (`decorations/russia/cherepovets/building_overrides.json`) parsed in
  `osm/decoration_layer.gd:226` (`get_custom_models()`), placed by
  `osm/osm_terrain_generator.gd:_place_custom_models_for_chunk` (~18519): lat/lon → `_latlon_to_local`
  → owns by chunk (`parent.add_child`) when `visibility_range ≤ 300`, freed on chunk unload;
  self-parented + `_placed_bridge_model_keys` dedup when large-range. **This is what the bazar gate
  uses** (now extended with `collision`/`signs`/`auto_ground`).
- **`roadside_props`** JSON (manual kiosk/box by coordinate) — `decoration_layer.gd:245`,
  `get_roadside_props()` (320). Another manual-by-coordinate precedent.
- **Prop registry** `_prop_defs` (~683) + `_init_prop_defs`/`_prop_compute_bounds` (~22918) — bounds
  from instantiated GLB; `foot` footprint, `base_y`, per-type `target_h`, `scale`.
- **Deferred/infra queues**: `_infrastructure_queue` (298), `_deferred_*_queue` dicts (282), time-budgeted
  `_process_infrastructure_queue` (~15394). **Chunk unload** `_unload_chunk` (~3202): erases per-chunk
  dicts, filters queues by `parent` ref, `queue_free`s lights. Chunk children auto-freed with the chunk.

### Asset/scale helpers (reuse — do NOT trust raw `get_aabb`)
- `_scene_real_vertex_aabb(root) -> AABB` (18594) — model-local AABB from **real transformed
  vertices** (the cone-levitation/get_aabb gotcha). Wrote it for the bazar gate; reuse for grounding/scale.
- `_prop_compute_bounds` (22918), `_extract_pack_mesh` (11050) — similar real-vertex bounds + scale.

### Particles / decals / debris
- **GPUParticles3D** pattern exists: manhole night steam — `_build_manhole_steam_resources` (~23320:
  Gradient→GradientTexture2D puff, `StandardMaterial3D` billboard, `QuadMesh` draw pass,
  `ParticleProcessMaterial` with emission shape / velocity / `gravity` / `scale_curve` / `color_ramp`
  / turbulence) + instancing in `_create_manhole_cover` (~23418, `one`-shot-able). **Reuse for the
  red pulp burst** (recolor pink-red, gravity down, `one_shot=true`, short lifetime).
- **Decals**: none in project (`Decal.new` only used historically for manholes, now removed). Tire
  tracks (`tracks/tire_track_manager.gd`) are a CPU `Image` shader-mask, not a general decal system.
  → **v1 skips ground splatter decals** (optional future).
- No generic debris/shard pool exists; fence/bag spawn ad-hoc bodies. We'll add a small pulp spawner.

---

## 2. Asset / import plan

All three assets are on disk: `~/Desktop/OSM material/{pallet,watermelon,watermelon-slice}.glb`.
Copy into the project and let the editor import (never hand-write `.import`):
```
models/market/pallet.glb
models/market/watermelon.glb
models/market/watermelon-slice.glb
```
Read-only GLB inspection (already done):

| asset | verts | tris | model bbox (x,y,z) | notes |
|---|---|---|---|---|
| pallet | 496 | 260 | 120.1 × 80.2 × 62.7 | ⚠ Y not obviously the thin axis — **verify orientation** |
| watermelon | 459 | 768 | 1.99 × 2.00 × 1.99 | clean ~2-unit **sphere**, origin-centered → sphere collider, rolls |
| watermelon-slice | 1057 | 1982 | 2.0 × 1.67 × 2.0 | half-dome (y −1.0..0.67), 1 material |

Validation at import (real verts, not raw AABB):
- **pallet**: determine the true flat footprint and thickness from `_scene_real_vertex_aabb`; the
  120:80 face is the 3:2 EU-pallet footprint, so the model may be authored Z-up or need a −90° X
  rotation to lie flat. Reorient so it lies flat, scale footprint to **~1.2 m × 0.8 m**, thickness
  ~0.14 m. **This is the #1 thing to check visually.**
- **watermelon**: scale 2 units → **~0.26 m diameter** (scale ≈ 0.13). Collider = `SphereShape3D`
  radius = real_radius·scale (rolls believably). 768 tris × ~24/stand × 2 ≈ 37k tris — acceptable for
  individual frozen watermelon bodies in v1 because only two stands exist and frozen bodies do not
  actively simulate while intact. Reuse shared mesh/material resources where possible. Visual-only
  MultiMesh is allowed only as a fallback if frozen individual bodies prove unstable, jittery, or too
  expensive.
- **slice**: scale to ~0.30 m; 2 per stand. Sit flat side down on the top layer.
- Materials: watermelon `Material`, slice `watermelon`, pallet `Pallet_LPinitialShadingGroup`. For
  pulp we do **not** reuse these textures — use flat low-poly materials (see §11).

---

## 3. Display composition algorithm (one stand)

Build a self-contained scene **`models/market/market_watermelon_stand.tscn`** with script
**`car/.../market_watermelon_stand.gd`** (a state machine; self-contained like the NPC setups), so
the terrain generator just instantiates it. Root = `Node3D` "MarketWatermelonStand".

Children built in `_ready()` from real-vertex bounds:
1. **Pallet** — `MeshInstance3D` (pallet mesh, grounded so its base sits at root y=0 via
   `_scene_real_vertex_aabb` min-Y), + a `StaticBody3D`+`BoxShape3D` (a **thin slab** matching the
   pallet thickness only) on **layer 1** so the car can roll up onto it like a low kerb. This is the
   pallet, not the pile — it must NOT be a tall box around the fruit.
2. **Watermelon pile** — **preferred:** ~24 individual `RigidBody3D` watermelons, each with its own
   `SphereShape3D` collider, frozen `FREEZE_MODE_KINEMATIC`, at the deterministic 4-layer transforms
   (§4, §5), on **layer 4** (mask 0 while frozen). Their sphere colliders ARE the physical shape of
   the pile — there is no separate big box around the fruit. `pallet_top_y = pallet_thickness`.
   (Fallback path: one `MultiMeshInstance3D` instead — see §7.)
3. **Slices** — 2 `MeshInstance3D` (slice mesh) on the top layer, naturally tilted (become bodies on hit).
4. **No large solid stand box.** Do NOT add a tall `BoxShape3D` enclosing the whole pile — that makes
   the car hit an invisible concrete block and slide the stand as one object. The pallet slab (layer 1)
   + the watermelons' own sphere colliders (frozen, layer 4) provide all the collision the car feels.
   (Only if the fallback MultiMesh path is used and some collision is required before spawn, add a
   **tightly-fitted** low collider that hugs the actual pile silhouette — never an oversized box.)
5. **Trigger** — one `Area3D`, `collision_layer=0, mask=1` (player only), `body_entered` → the single
   guarded impact-decision handler (cone-trigger pattern). This is the ONE decision point; individual
   watermelons never decide the smash themselves.

Store the per-instance watermelon transforms in `_layout: Array[Transform3D]` (model space) regardless
of path. Everything parented to root → inherits placement transform/scale.

Grounding & scale: pallet base at terrain; watermelons rest on pallet top; nothing floats/clips
(verified via real-vertex min-Y of each asset). Orientation from the stand's yaw (root rotation).

---

## 4. Four-layer pallet-filling layout strategy

Footprint after scaling ≈ **1.2 m (X) × 0.8 m (Z)**; watermelon diameter `d ≈ 0.26 m`,
radius `r`. Leave a small edge margin `m ≈ 0.6·r` so fruit slightly overhangs but not absurdly.
Usable footprint ≈ (1.2 − 2m) × (0.8 − 2m).

Layers (counts are the design target; final tuned visually):

| layer | footprint shrink | grid | count | center y |
|---|---|---|---|---|
| 1 (bottom, widest) | 100% usable | 4 × 3 | **12** | `pallet_top + r` |
| 2 | ~78% | 3 × 2, offset into gaps | **6** | `+ d·0.78` |
| 3 | ~58% | 2 × 2 | **4** | `+ d·0.78` |
| 4 (top) | ~38% | center cluster | **2** | `+ d·0.78` |

Total ≈ **24 watermelons** + **2 slices** on the layer-4 top. Each upper layer is nestled over the
gaps of the one below (offset by ~`0.5·d` in X/Z) so the silhouette reads as a tidy pyramid and the
bottom layer covers most of the pallet (no large empty pallet visible).

**Not a perfect grid.** The grid above is only the *starting* slot layout; on top of it, add small
**deterministic** irregularity so it reads as a hand-stacked market pile, not a procedural
checkerboard:
- per-slot positional jitter `±0.25·r` in X/Z and `±0.06·r` in Y (kept small enough that nothing
  floats/clips and, in the preferred frozen-body path, spheres still just-touch rather than overlap);
- per-fruit yaw/tilt/scale variation (§5);
- optionally drop or shift one or two slots in the upper layers so the pile isn't perfectly symmetric.
All of this comes from the deterministic seed (§5) — **no `randf()`** — so the pile is identical every
load and (preferred path) the frozen bodies sit exactly where they were authored. The bottom layer
must still cover most of the pallet footprint and the whole thing must still read as a dense, abundant,
tidy pyramid — irregular, not messy.

These positions are believable resting spots, so when the frozen bodies unfreeze (or, fallback, are
spawned at `_layout`) on a low-speed hit they settle/roll naturally.

Parameters exported for tuning: `layer_counts := [12,6,4,2]`, `layer_shrink := [1.0,0.78,0.58,0.38]`,
`nest_factor := 0.78`, `edge_margin_frac := 0.6`, `pos_jitter_frac := 0.25`, `watermelon_diameter`
(auto from asset).

---

## 5. Watermelon transform variation strategy

Deterministic per instance — **no `randf()` for persistent layout** (matches the project's
hash-seed convention). Seed = `hash("%d_%d" % [stand_index, watermelon_index])`; derive a local
`RandomNumberGenerator` with `rng.seed = seed` (or pull values from `hash` bit-slices). Per fruit:
- yaw: full `0..TAU`;
- pitch/roll: `±8°`;
- uniform scale: `0.9..1.1`;
- positional jitter: `±0.02 m` X/Z, `±0.01 m` Y (within the slot, never enough to float/clip).

Each watermelon body (preferred path) — or MultiMesh instance (fallback) — gets its own
`Transform3D`; for subtle rind-tint variation use per-instance `COLOR` (MultiMesh) or a duplicated
material tint (bodies). Combined with the §4 positional jitter and per-layer slot offsets, the pile
reads as hand-stacked, **not a perfect grid**. The 2 **slices** get their own deterministic tilt
(`±12°`) and yaw so they look hand-placed. Goal: reused meshes read as different fruits.

---

## 6. Manual placement / anchor strategy — the anchor is AUTHORITATIVE

**Exact placement only. No auto-spawn, no search, no relocation.** The stands appear at the
user-configured anchor (+ configured offset for the 2nd) and nowhere else. There is **no default
guessed coordinate** — if no anchor is configured, **nothing spawns** (do not invent a "near the
gate" position).

**Provided anchor (authoritative):** `lat 59.145658, lon 37.946375` (the original bazar-gate point).

Config — a new JSON section (extend the decoration loader, mirroring `roadside_props`),
`building_overrides.json → "market_stands": [ ... ]`:
```jsonc
{
  "comment": "Watermelon pallet stands — exact manual placement, anchor authoritative",
  "lat": 59.145658, "lon": 37.946375,  // REQUIRED anchor (no default; if absent → skip)
  "yaw": 256.0,                         // optional (default below); applied as-is, never overridden
  "stand_count": 2,
  "spacing": 1.6,                       // optional, metres between the two stands
  "scale": 1.0
}
```
Placement: parsed in `decoration_layer.gd` (new `get_market_stands()`), placed by a new
`_place_market_stands_for_chunk(chunk_key, parent)` called from chunk build alongside
`_place_custom_models_for_chunk` (~4832), owned by the anchor's chunk.

**Allowed automatic behavior** (only these):
- ground to terrain at the provided anchor via `_sample_elevation` (Y only — never X/Z drift);
- apply the configured `yaw` (default = bazar gate's 256° if `yaw` omitted; still applied verbatim,
  not "optimized");
- place stand #2 by the configured `spacing/2` offset **along the frontage** (local X of the yaw
  basis), i.e. `±spacing/2`. Offset direction/axis is fixed by config, not chosen heuristically;
- show preview/debug markers + bounds.

**Not allowed:** auto-selecting a different location; nudging/sliding the stands off the anchor for
any reason (overlap, road, wall, driveway, slope); `_move_object_off_road`-style relocation; spawning
at a fallback coordinate. The anchor wins, always.

**Overlap handling (debug, do not relocate):** if the placed stand's bounds intersect the gate / road
/ wall / driveway, draw the debug bounds, `push_warning`/gated-log a clear message with the anchor and
what it overlaps, and **keep the configured position**. The developer/user then adjusts the anchor by
editing config — the system never moves it for them.

---

## 7. Frozen / intact pyramid strategy

**Preferred v1: individual frozen watermelon bodies.** Each watermelon is its own `RigidBody3D`
with a `SphereShape3D` collider, frozen `FREEZE_MODE_KINEMATIC` (infinite mass, no simulation — the
cone/bin convention, `_create_cone_immediate` ~11364). With only ~24 fruit/stand × 2 stands ≈ 48
bodies (and only while the chunk is loaded), this is acceptable and is the most faithful to the
desired interaction: the SAME bodies that hold the pile are the ones that unfreeze and roll on a
low-speed hit. Frozen-KINEMATIC bodies do not simulate, so the pile stays perfectly stable — no
jitter, slide, collapse, or slow explosion before impact.

Anti-pop measures (so they don't burst apart the instant they unfreeze):
- lay out the spheres **just touching, not interpenetrating** (slot spacing ≥ `d` per layer; upper
  layers rest in the dimples between lower spheres so contacts are shallow);
- on unfreeze, apply only modest impulses (§9) and let gravity settle them;
- if needed, set a small `contact/solver` margin and `linear_damp`/`angular_damp` so contacts relax
  rather than explode.

**Fallback only if frozen bodies prove unstable / too expensive / unavoidably jittery:** render the
intact pile as a `MultiMeshInstance3D` (1 draw call, per-instance varied transforms — still reads as
separate fruit, not a blob) and **store every watermelon transform in `_layout`**; on a low-speed hit
hide the MultiMesh and spawn `RigidBody3D` watermelons at those stored transforms so the result still
looks like the original pyramid physically collapsing. This is a fallback, not the default — choose it
only if §7's preferred path can't be made stable.

Either path satisfies "real separate watermelons, not a merged blob." Always store `_layout`
(model-space `Transform3D` per fruit) regardless of path, so debris/spawn code is path-independent.

---

## 8. Collision & speed classification

- **No fake concrete box.** The stand must not behave like one big invisible solid. Physical shape =
  the **pallet slab** (thin, layer 1) + the **individual frozen watermelon sphere colliders** (layer 4).
  No tall box around the pile. (Fallback MultiMesh path: if any pre-spawn collider is needed, it must
  hug the actual pile silhouette tightly and stay low — never an oversized box.)
- **Single decision point**: the stand-root `Area3D.body_entered(body)` handler decides low-vs-high
  ONCE. Guard with `if _state != State.INTACT: return` plus a `_triggered` bool — no double-fire, and
  the individual watermelons never run their own smash decision (they only react to the state switch
  the root performs). This is what prevents "every watermelon triggers the same smash."
- **Impact speed**: prefer **relative/approach speed** — `var v = body.linear_velocity` then
  `impact = max(0, v.dot((global_position - body.global_position).normalized()))` (velocity projected
  toward the stand). Fallback: `v.length()`. Both in m/s.
- **Classification**: `const SMASH_SPEED := 8.33` (30 km/h, exported `@export var smash_speed_mps`).
  `impact >= smash_speed → HIGH_SPEED_SMASHED` else `LOW_SPEED_HIT_ROLLING`.
- **Layers**: pallet slab layer 1; frozen watermelons layer 4 / mask 0 (don't shove the car while
  frozen — the car still bumps the spheres because car mask 7 includes layer 4); trigger Area3D
  layer 0 / mask 1 (player only). After unfreeze/spawn, bodies → layer 4, mask 1 (ground) +
  `add_collision_exception_with(car)` (cone pattern ~11455) so they scatter individually and the car
  doesn't snag on its own debris.
- Because the pile is real separate spheres (not one box), a low-speed hit naturally pushes only the
  fruit it touches first — the stand does **not** slide as one object.
- Log the classification once (gated): `[WMELON] stand N hit at X.X km/h → LOW/HIGH`.

States: `INTACT → (LOW_SPEED_HIT_ROLLING | HIGH_SPEED_SMASHED) → SETTLED/CLEANUP`.

---

## 9. Low-speed rolling behavior (< 30 km/h)

**Preferred path (frozen bodies):**
1. For each watermelon body: `freeze = false`, switch `collision_mask` to 1 (ground), and
   `add_collision_exception_with(car)`. These are the SAME bodies that formed the pile — no respawn.
2. Apply a modest outward impulse (impact dir + small upward) + random torque, scaled
   `clampf(impact, 2.0, 8.0)` and strongest on the fruit nearest the impact (cone/bin pattern), so
   several detach and roll off the pallet while others tumble down in place.
3. Unfreeze the 2 slices too (they may slide/fall).

**Fallback path (MultiMesh):** hide the MultiMesh + slice meshes; spawn `RigidBody3D` watermelons at
the stored `_layout` poses (sphere collider, mass ~2–3, layer 4, mask 1, car exception) and apply the
same impulses — the result must still look like the original pyramid collapsing.

Common:
4. Pallet stays (static slab) — v1 does not move the pallet.
5. No pulp. Result is clearly **individual watermelons separating/rolling**, never one solid object
   sliding away.
6. TTL cleanup (§11). State → SETTLED.

---

## 10. High-speed smash behavior (≥ 30 km/h)

1. Remove the intact watermelon bodies + slices (`queue_free` the frozen bodies, or in the fallback
   path hide the MultiMesh) before spawning debris — never let the original bodies fly as well.
2. Spawn **pulp debris** (§11): ~16–24 red flesh chunks + ~6 green rind shards (capped), with strong
   outward impulses from the impact direction (`clampf(impact, 8.0, 20.0)`), upward component, spin.
3. Spawn **one red particle burst** (one-shot GPUParticles3D, ~0.5–0.8 s).
4. Optional: 1–2 rolling half-watermelons (slice mesh on a body) for readability.
5. Optional future: short-lived flat red ground quad (we have no decal system — skip v1).
6. Cap total debris; TTL cleanup; state → CLEANUP.

Juicy + readable as smashed watermelon, **not gore** (see colour choice in §11).

---

## 11. Debris / pulp effect strategy

No existing debris pool → add a small spawner (modeled on `_burst_bag_into_paper` ~11298):
- **Flesh chunks**: low-poly (small `BoxMesh`/octahedron or a shared tiny `SphereMesh`) with an
  unlit-ish `StandardMaterial3D`, **watermelon-flesh pink-red** `Color(0.86, 0.18, 0.27)` (NOT dark
  blood-red — this is the key "fruit not gore" signal), a few darker-red and a couple with tiny black
  "seed" speck tint. Mass ~0.15, layer 4 mask 1, `gravity_scale 1`, set `linear_velocity` directly
  (fan from impact dir + up), `angular_velocity` random.
- **Rind shards**: same body, green `Color(0.20, 0.55, 0.22)` with a thin curved/triangular mesh.
- **Particle burst**: clone the manhole-steam builder (`_build_manhole_steam_resources` ~23320) but
  pink-red `color_ramp`, `gravity = (0,-3,0)`, `spread ~60°`, `one_shot=true`, `lifetime ~0.6`,
  `amount ~24`, small puff quad. `emitting=true` on spawn; free after lifetime.
- **Cleanup**: per-body `get_tree().create_timer(rand 4–6 s).timeout → queue_free` (bag pattern);
  the burst frees itself; everything also dies on chunk unload (parented to chunk/stand).
- **Cap**: hard ceiling (e.g. ≤ 30 bodies/stand) so a smash never floods the scene.

---

## 12. Chunking / persistence

- **Chunk-owned** by the anchor's chunk (parent = chunk node), like `custom_models`. Built in
  `_place_market_stands_for_chunk` when that chunk loads; auto-freed on `_unload_chunk`.
- Dedup key `market_watermelon_stand_<index>` in a `_placed_market_stands` set to avoid double-spawn
  on reload races (mirror `_placed_bridge_model_keys`).
- **Reset on reload acceptable for v1**: drive away (chunk unloads) → return → stand is INTACT again.
  Debris is chunk-parented (or TTL'd) so it's cleaned with the chunk. Destroyed-state persistence is
  noted as **optional future** (would need a per-anchor `destroyed` flag survive unload).

---

## 13. Debug tools (default OFF)

`@export var wmelon_debug := false` gating all of:
- anchor marker (small sphere) + per-stand bounds box (debug draw / `ImmediateMesh`);
- show the Area3D trigger extents;
- print each watermelon's transform on build (gated, once);
- show current state + frozen/active;
- on hit: print impact speed in **km/h** + classification (low/high) once;
- log every state transition;
- **force-test methods** callable via MCP `execute_game_script`: `force_low_speed_hit()`,
  `force_high_speed_smash()`, `reset_to_intact()`.
Logs gated behind `wmelon_debug` (no spam).

---

## 14. Self-test checklist (in-scene, do not delegate to the user)

Launch `res://main.tscn` directly (never the menu), and verify — **stop the scene after each pass (heat)**:
1. **Placement is exact:** both stands appear at the configured anchor `59.145658, 37.946375` (+ the
   configured `spacing` offset for stand #2) — confirm the stand world position matches the anchor's
   `_latlon_to_local` (only Y differs, from grounding). **No hidden auto-relocation.**
2. Debug anchor marker sits exactly on the configured anchor; stand #2 offset = configured `spacing`;
   yaw matches configured `yaw`.
3. If the stand overlaps the gate/road/wall, confirm it **logged a warning and kept the configured
   position** (did NOT move itself) — then anchor is adjusted by editing config, not by the system.
4. Grounded; watermelons on the pallet; no float/clip.
5. Each pile is **exactly 4 layers** and fills most of the pallet width & length (no big empty pallet).
6. Pyramid is perfectly stable before impact (no jitter/slide/collapse over time).
7. Watermelons look **varied & irregular** (yaw/tilt/scale/jitter) — a hand-stacked pile, NOT a perfect
   grid/checkerboard and not copy-pasted; slices look hand-placed.
8. Close-up screenshot + driving-distance screenshot both read well.
9. **Slow hit** (< 30 km/h): individual watermelons detach, roll off, fall — NOT one solid object
   sliding; the stand does not behave like a concrete box.
10. **Fast hit** (≥ 30 km/h via `force_high_speed_smash()` or driving): red pulp + green rind burst,
    reads as smashed watermelon, **not blood/gore**.
11. No major FPS spike on smash; debris capped; cleanup works (bodies gone after TTL / chunk unload).
12. Reload (drive away & back): stand resets to intact cleanly at the same exact anchor.
Use MCP: `play_scene res://main.tscn`, teleport player to the anchor, `get_game_screenshot`,
`force_*` methods, `get_output_log ERROR`, `stop_scene`.

---

## 15. Implementation milestones

1. Copy + import the 3 GLBs; validate real-vertex bounds; **resolve pallet orientation/scale**.
2. Build `market_watermelon_stand.tscn` + script: pallet slab + 4-layer pyramid of **individual
   frozen-KINEMATIC watermelon bodies** (sphere colliders) + 2 slices, grounded, stable, scaled.
   (Milestone: one rock-stable pile that never jitters, screenshot. If unstable → MultiMesh fallback.)
3. Verify 4 layers fill most of the pallet; tune `layer_counts`/`shrink`/`nest`; confirm it's not a
   perfect grid.
4. Deterministic transform variation + positional jitter (watermelons + slices).
5. JSON `market_stands` anchor (authoritative, no default) + `_place_market_stands_for_chunk` +
   2-stand offset/yaw applied verbatim + debug marker/preview.
6. Area3D single-decision trigger (no fake box); read impact speed; classify (km/h log).
7. Low-speed: **unfreeze the existing bodies** (fallback: spawn at `_layout`), impulses, roll-off.
8. High-speed: remove intact bodies + pulp/rind chunks + particle burst + impulses.
9. Debris cleanup (TTL + cap + chunk unload).
10. Chunk ownership/reset + dedup key.
11. Debug tools + force-test methods.
12. Full in-scene self-test (close + far, slow + fast, FPS, cleanup, reload).

---

## 16. Risks & fallback behavior

- **Pallet orientation/scale unknown** (bbox 120×80×62.7, Y not clearly thin) — must verify the flat
  axis from real verts and reorient; fallback: rotate −90° X and/or swap, worst case substitute a
  simple `BoxMesh` pallet. Highest-uncertainty item.
- **Frozen-stack pop on unfreeze** (preferred path) — bodies that interpenetrate explode when
  unfrozen. Mitigate: lay spheres just-touching (slot ≥ d, upper layers in dimples), keep jitter
  small, unfreeze with modest impulses + damping; if it still pops or jitters, fall back to the
  MultiMesh path (§7) which spawns at clean poses.
- **"Gore" perception** — pink-red flesh + green rind + seed specks, bright not dark; tune colour
  visually. If still reads as blood, lighten toward `Color(0.92,0.30,0.38)` and add more green rind.
- **Perf** — ~48 frozen-KINEMATIC bodies total (no simulation while frozen) + capped, TTL'd debris +
  `visibility_range_end` on meshes (~150 m); only 2 stands. If the frozen-body count ever bites, the
  MultiMesh fallback drops it to 2 draw calls + spawn-on-hit.
- **Pallet orientation/scale** — see above (#1 risk).
- **No decal system** — skip ground splatter for v1 (optional future flat quad).
- **Double-trigger / per-fruit triggers** — eliminated by the single root Area3D + `_state` guard.
- **Unwanted relocation** — explicitly disallowed (§6); the anchor is authoritative, overlaps are
  logged not fixed.

---

## 17. Open questions (non-blocking; sensible defaults chosen)

1. **Exact anchor point** — ✅ provided: **`59.145658, 37.946375`** (authoritative; §6). No default
   guessing; stands spawn only here.
2. **Yaw source** — default to the bazar gate's 256° (frontage along the gate); override via JSON,
   applied verbatim (never auto-optimized). Confirm at placement visually & flip if reversed.
3. **Spacing & side** — default 1.6 m apart along the frontage; tune via JSON. Confirm visually that
   neither stand blocks the carriageway (if it does: log + keep, then adjust the anchor/spacing in
   config — the system won't move them).
