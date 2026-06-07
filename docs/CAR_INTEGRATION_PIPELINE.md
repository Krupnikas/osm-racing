# New-car integration pipeline

A repeatable, reliable process for adding a new car model (player **and** NPC) to
the game. Validated end-to-end on the first car — **Ford Focus ST 2006**.

> Status: pipeline established + first car shipped & verified in-game. The rest of
> the batch is applied **one car at a time** through the same stages (do not batch
> all at once).

Source models live in `~/Desktop/OSM material/`; the colour mapping is
`new_cars_color_mapping.md` (project root).

---

## 0. Architecture this plugs into (where things live)

- **Player cars are GEVP** (`addons/gevp/scripts/vehicle.gd`). A player car scene is
  `addons/gevp/scenes/<id>_car.tscn`: `RigidBody3D`(vehicle.gd) + `CollisionShape3D`
  (Box) + a model node (the GLB) carrying a per-car `*_setup.gd` + four `RayCast3D`
  (wheel.gd), each with a child `wheel_node` Node3D that **spins** (`rotation.x`) and
  **travels** with suspension (`position.y`). Forward = **−Z**.
- **Player registry:** `settings/car_settings.gd` → `CARS` (scene path + physics
  stats) and `DISPLAY_STATS` (UI bars). Stats are applied at spawn by
  `apply_car_stats()`. Price: `career/career_state.gd` → `CAR_PRICES`. Spec line:
  `ui/car_selection.gd` → `CAR_SPEC_LINES`. The selection UI auto-discovers any id in
  `CARS`.
- **NPC cars are `VehicleBody3D`** (`traffic/npc_car.gd`) + four `VehicleWheel3D`. Scene
  is `traffic/npc_<id>.tscn` with a model node carrying `*_npc_setup.gd`. Forward =
  **+Z**. `npc_car.gd._merge_meshes()` merges the body for draw-call savings and
  collects meshes named *wheel/tire/rim* into `_wheel_mesh_nodes`, which
  `_update_wheel_rotation()` spins. NPC lights: `night_mode/npc_car_lights.gd`
  (per-model split spot/omni lights, toggled by night/rain).
- **NPC registry:** `traffic/traffic_manager.gd` — a `PackedScene` var + `preload` in
  `_ready` + append in `_warmup_mesh_cache` + a weight slot in `_get_npc_from_pool`.
- **Reference cars** (compare new work against these):
  - **Nexia** — stable **full-car integration** reference: general scene setup, working
    player-car behaviour, day/night glass + head/tail lights.
  - **Matiz** — ideal **model-wheel** reference: real model wheels, visual wheel rotation,
    reparenting onto the spinning GEVP wheel nodes, and grounding.
  - **Ford Focus ST 2006** — first **validated end-to-end pipeline** reference, and the best
    reference for **imported GLBs with merged wheel meshes**: quadrant-splitting a merged
    `Tire`/`Rim` mesh, recentring the wheel geometry, body-paint recolour, dual player+NPC
    integration, and a full report + checklist (§4, §6). Any new car with merged,
    material-grouped wheels should compare its wheel setup against the Focus ST one.

---

## 1. Reusable tooling (built once, used for every car)

- **`tools/car_model_analyzer.gd`** — load a model (external `.glb/.gltf` via
  `GLTFDocument`, or a `res://` import) and print a diagnostic: real-vertex AABB
  (never `get_aabb()` — imported boxes are inflated), length axis, scale factor to a
  target real length, per-part class (wheel/glass/light_front/light_rear/body/…),
  wheel centres + radius + wheelbase/track, head/tail-light candidates, body
  materials. Drives every later decision.
- **`tools/car_wheel_rig.gd`** — many GLBs group geometry **by material**, so all four
  wheels are one merged `Tire`/`Rim` mesh that cannot be reparented and would *orbit*
  if rotated. `build(model_root)` splits the wheel meshes into four XZ quadrants,
  **recentres** each quadrant's geometry on its own wheel centre, and emits four
  `wheel_FL/FR/RL/RR` containers (hiding the originals). Each container spins in place,
  so it works for both the GEVP reparent path (player) and `npc_car.gd`'s
  `_update_wheel_rotation` (NPC). Models that already ship four separate wheel nodes
  don't need this (reparent them Matiz-style).

Invoke from an MCP editor script:
```gdscript
var A = load("res://tools/car_model_analyzer.gd")
_mcp_print(A.format_report(A.analyze("/abs/path/model.glb", {"target_length": 4.34})))
```

---

## 2. Per-car stages

1. **Import** — copy the `.glb` to `car/models/<id>/<id>.glb` (or extract the `.zip`
   and find the `scene.gltf`); trigger an editor filesystem scan; let Godot generate
   `.import` (never hand-write it). Stable id from the filename
   (`ford_focus_st_2006`, `mazda_6_sedan_2011`, …).
2. **Analyse** — run `car_model_analyzer` with a real target length. Read off: scale
   factor, length axis, **which end is the front** (taillight `red_glass` / grille),
   wheel centres + radius, wheelbase/track, body material, light parts.
3. **Player scene** — clone `addons/gevp/scenes/matiz_car.tscn`. Set the model
   transform (scale = factor, rotate 180° iff native front = +Z so it faces −Z, small
   Y so wheels touch ground), Box collision sized to the body, and the four wheel
   RayCasts at the analysed corners (front at −Z) with `tire_radius` = analysed radius.
   Write `car/<id>_setup.gd`: run the wheel rig, reparent containers onto the nearest
   GEVP `wheel_node`, recolour the body paint material, emissive tail + brake
   SpotLights at +Z, headlight SpotLights (forward beam) at −Z (visible only at night).
4. **NPC scene** — clone `traffic/npc_matiz.tscn`. Model **not** rotated if native
   front = +Z (NPC forward = +Z); wheels front at +Z. Write `car/<id>_npc_setup.gd`:
   run the wheel rig **synchronously** in `_ready` (so wheels exist before the parent's
   `_merge_meshes`), pick a random colour, then after one frame recolour the **merged
   instance's** Paint surface as a *per-instance* `surface_override_material` (the
   merged mesh is cached + shared, so mutating the shared material gives no variety).
   Add a model entry to `npc_car_lights.gd` (detected by the model node name).
5. **Register** — add to `CARS` + `DISPLAY_STATS` (player stats), `CAR_PRICES`,
   `CAR_SPEC_LINES`, and `traffic_manager` (var + preload + warmup + weight).
6. **Test via MCP** — drive-test on the **flat test track** `res://race/test_track_scene.tscn`
   (city curbs leave a wheel airborne → false "won't drive"; the track has a `Car` node +
   flat ground). Swap the car in, verify `velocity·−Z > 0`, all 4 wheels contact, wheels
   spin, grounded. Toggle night and verify lights from **THREE angles — front, rear,
   top-down**: front/rear lenses themselves are alight (white front, red rear, real lens
   shape), top-down shows the lights are inside the body footprint (§5, §5b). Spawn NPC
   instances for grounding + per-instance colour variety. **Confirm night actually went dark
   before judging headlights**, and **freeze the body before teleporting** a moving car
   (teleport-at-speed glitches it skyward).

---

## 3. Definition of Done (a car is integrated only when ALL of these pass)

A car is **NOT** done just because the model imports, the scene opens, it shows in the
showroom, or an NPC scene exists. Those are necessary, not sufficient. A car is done
only when every gate below holds — **if any one fails, the car is not complete** (leave
it in progress, or quarantine it per §8, and say so in the report).

**Import & transform**
- imported into the correct project folder (`car/models/<id>/`)
- normalised to a plausible real-world scale
- orientation verified — the *visual* front moves in the correct gameplay forward
  direction (player −Z, NPC +Z)

**Wheels**
- uses the real model wheels where the model provides them
- visual wheels rotate while driving
- front wheels steer visually (if the physics system supports steer)
- wheel positions match the physics / suspension corners reasonably

**Grounding & collision**
- the car stands correctly on the road — no visible floating, no sinking
- the collision shape is plausible and does not itself lift or sink the car

**Body & colour**
- the body-paint material is correctly identified
- colour variants apply **only** to body paint — never glass, tyres, lights, or interior

**Player**
- the player / showroom version works (drivable)
- the showroom preview scale + orientation look correct
- the selectable car spawns correctly in gameplay

**NPC**
- the NPC version works
- NPC wheels rotate while moving
- NPC colours vary per instance
- NPC headlights / taillights are the REAL emissive lens meshes (NOT proxy boxes) — via
  `npc_keep_unmerged` + `real_lens_lights` (§5c)

**Lights (player + NPC) — emissive real lens, never proxy boxes (§5b/§5c)**
- player AND NPC head/tail glow is the actual lamp-lens mesh made emissive (lens-shaped)
- front lenses warm-white, rear lenses red; energy toggles with night
- **verified at night from 3 angles (front / rear / top-down) for BOTH the player and the NPC**
  (§5d) — lenses alight, lights inside the body footprint

**Registry & verification**
- stats, price, display name, spec line, and NPC spawn weight are all added
- the car passes MCP runtime testing in the real game scene
- the integration report **and** checklist are written

---

## 4. Per-car integration report

Every completed car must produce a written report, preferably at:

```
docs/car_pipeline/<car_id>_integration_report.md
```

plus the pass/fail verification checklist (`docs/car_pipeline/<car_id>_checklist.md`,
as in §6). Optionally also emit a machine-readable measurements file:

```
docs/car_pipeline/<car_id>_measurements.json
```

holding the same key numbers in structured form, so future integrations can compare
cars against each other (scale, wheelbase, track, radius, vert count, …).

The report should record:
- source file
- `car_id`
- display name
- chosen target length / target dimensions
- original real-vertex AABB
- final scaled AABB
- scale factor
- native forward direction
- final player orientation
- final NPC orientation
- wheel-detection method — *separate wheel nodes* / *merged-wheel split* / *fallback or manual*
- wheel centres
- wheel radius
- wheelbase
- track width
- grounding measurements
- light-detection method
- headlight positions
- taillight positions
- body material names
- colour source from `new_cars_color_mapping.md`
- player scene path
- NPC scene path
- registry changes
- price
- stats
- NPC spawn weight
- MCP test result
- screenshot / evidence paths, if available
- known risks / limitations
- final pass/fail checklist

The optional JSON file should mirror the same key numbers in structured form.

**This is not bureaucracy.** The report exists so a future LLM or debugging pass does
not have to re-discover the same facts — which end is the front, the scale factor, where
the lamp blocks are, why a model was rejected. Writing it once stops the next loop from
rediscovering it.

---

## 5. Hard-won gotchas

- **`:=` type inference** fails on values whose type GDScript can't see (`dict["k"]`,
  `node.mesh`, untyped loop vars). Use an explicit `var x: T =`. Headless-compile every
  new script: `Godot --headless --path . --script /tmp/check.gd` (load() the file).
- **Real-vertex AABB only** — `get_aabb()` on imported GLBs is inflated; grounding/scale
  off it floats or shrinks the model.
- **Merged wheels** are the norm for Sketchfab `F_M_*_High` exports — split them, don't
  reparent one blob. Recentre each quadrant or it orbits instead of spinning.
- **NPC colour variety** must be a per-instance `surface_override_material` on the
  `MergedMesh` (the merge is cached and materials are shared across instances).
- **Wheel-rig timing for NPC:** build the rig **before** the first `await` in the npc
  setup so the containers exist when the parent `NPCCar._ready → _merge_meshes` runs.
- **Forward direction:** verify with `velocity·(−basis.z) > 0` while accelerating **and**
  a front-view screenshot — never by eye alone.
- **Grounding:** trust the visual (visible-mesh bottom vs wheel bottom vs the surface
  the car rests on). A single down-raycast reads ~1 m off where road-collision layers
  overlap at junctions.
- **Model organisation varies wildly** — analyse before committing (see §7).
- **Lights must be the REAL lens mesh made emissive — never a proxy box.** A `SpotLight3D`
  beam with a dark lens looks like "light coming from nowhere"; a `BoxMesh` proxy at the
  lamp mismatches the lens shape and pokes outside the body. Both were rejected in review.
  Emissive the actual lamp-lens mesh so the glow matches the lens shape and sits in the body.
- **Verify lights at night from THREE angles — front, rear, AND top-down — for every car.**
  Front/rear confirm the lenses themselves are alight (white front, red rear); top-down
  confirms the light sources/lenses are inside the car-body footprint, not floating outside.
- **Wheel-rig substring false-positives:** `_collect_wheel_meshes` matches name/material
  substrings, so `"…Trim…"`→`"rim"` and `"SteeringWheel"`→`"wheel"` drag bumpers/steering
  wheels into the rig. The hardened rig now drops centreline strays on separate-wheel models
  (see §5b). Also affects NPC wheel-spin collection — rename or rely on the filter.
- **Opaque/foreign wheel materials:** some models name wheels `llanta`/`rin` (Spanish),
  `chevy_aveo_*`, `Sparkrines`, etc. The analyzer reports "0 wheels", but the meshes exist —
  pass those tokens to `CarWheelRig.build(..., extra_mat_keys=[...])`.

---

## 5b. Lights — emissive the real lens (front white / rear red)

The lamp glow must come from the car's **actual lamp-lens mesh**, made emissive — matching
the lens shape and sitting inside the body. Keep the placed `SpotLight3D` (forward beam) and
brake `OmniLight3D`/`SpotLight3D` for illumination, but the lens itself must visibly glow.

Identify the lens and assign colour by, in order of preference:
1. **Separate lens material per end** (best): `red_glass`/`Light_glass`/`TailLight*` = rear
   (red); `LightCluster`/`LightRefracted`/`Glass_light_1`/`HeadLight*` = front (warm white).
   Emissive each by material name. (Civic, RX-8, Audi, STI, CLK, Volga, Focus.)
2. **Per-mesh z-split** when front and rear are SEPARATE meshes that share a material: for
   each mesh, real-vertex centroid z (native front = +Z) → front white / rear red.
3. **Explicit front/rear material lists** when one mesh *spans* both ends (centroid ≈ 0 so
   z-split fails): hard-code `FRONT_LAMP_MATS`/`REAR_LAMP_MATS`. (Cayenne `cayenne_luz`=front,
   `cayenne_luz2`=rear.) If a single material truly covers both ends and can't be split,
   emissive it warm-white (front headlights are the priority) and let the rear red OmniLight
   carry the rear; note the limitation.

Toggle: front headlight emission energy = 0 by day, ~1.3 at night (tie to NightModeManager);
rear emission baseline ~0.6, ~2.0 on `brake_input > 0.1`. Reusable helper pattern lives in
`car/cayenne_setup.gd` / `car/aveo_setup.gd` / `car/spark_setup.gd` (`_emissive_lamps`).

**Finding the lens material (do this, don't guess):** dump the REAL
`mesh.mesh.surface_get_material(i).resource_name` for every surface — names are often
TRUNCATED in notes/analysis (e.g. `chevy_aveo_342yhwwes` was really
`chevy_aveo_342yhwwesrtfnhdtf`). When names are opaque (Spanish/SketchUp tokens), **probe**:
set a distinct bright emissive (cyan/magenta/yellow) on each candidate material and screenshot
front + rear + top — the colour reveals exactly which mesh is the headlight vs taillight vs
fog vs reflector. Only then write `FRONT_LAMP_MATS`/`REAR_LAMP_MATS`. Express positions in the
car-LOCAL frame (`car.global_transform.affine_inverse() * world_centroid`) — GEVP forward is
−Z, so front lenses sit at local −Z.

## 5c. Lights on the NPC — the mesh-merge trap (MUST READ)

NPC cars are **not** like the player. `traffic/npc_car.gd._merge_meshes()` bakes every body
MeshInstance into a single cached `MergedMesh` (one surface per material) and HIDES the
originals (wheels are kept separate to spin). Consequences for lights:
- A per-surface emissive override on the original lens meshes **never renders** — that mesh is
  hidden behind the merged mesh. (This is why a player car can glow correctly while its NPC
  twin stays dark — same material, same energy.)
- In the merged mesh the lamp material is ONE surface fusing front+rear lenses, so you cannot
  split white/red there.

The shared `night_mode/npc_car_lights.gd` historically drew **rectangular `BoxMesh` proxy
lamps** for NPCs — the exact lens-shape mismatch we reject. Correct approach (shipped for
Spark, generalized in `npc_car.gd` + `npc_car_lights.gd`):
1. In the car's `*_npc_setup.gd`, **synchronously before its `await`** (so before the parent's
   `_merge_meshes()` runs), for each lamp-lens mesh: `mesh.set_meta("npc_keep_unmerged", true)`
   and apply the same per-surface front/rear emissive override as the player.
2. Set `get_parent().set_meta("real_lens_lights", true)` (also before the await).
3. `_merge_meshes()` skips meshes flagged `npc_keep_unmerged` (leaves them visible, like
   wheels) and `_create_light_meshes()` skips its proxy boxes when the NPC root has
   `real_lens_lights`. The shared SpotLight beams + taillight OmniLights are still created.
4. Toggle lens emission in the npc-setup `_process` by polling `NightModeManager.is_night`
   (0 by day, front ~1.3 / rear ~1.8 at night).

Template: `car/spark_npc_setup.gd`. NOTE the static `_merged_mesh_cache` — when iterating you
must STOP & re-PLAY the scene to rebuild it (otherwise a stale merge that still contains the
lamp surface causes z-fighting with the now-visible lens meshes).

## 5d. Verify lights — night, 3 angles, EVERY variant

For **both** the player AND the NPC of every car: enable night via
`NightModeManager.enable_night_mode()` (NOT `is_night = true` — that leaves the scene in
daylight), confirm the sky actually went dark, then screenshot **front, rear, and top-down**.
Pass criteria: front lenses warm-white-lit and rear lenses red-lit (the lens mesh itself
glows, matching its shape), and top-down shows every light source/lens inside the body
footprint (nothing floating outside). A code edit is NOT "done" until these shots confirm it.

---

## 6. First car report — Ford Focus ST 2006

- **Chosen because:** in the user's preferred shortlist, normal hatch shape, **cleanest
  semantic materials** (`Paint` body, `red_glass` tail, `chrome`, separate glass/
  interior) at a moderate 28k verts → clean recolour + lights. Its only hard problem
  (4 wheels merged into one `Tire`/`Rim` mesh) is solved by the reusable quadrant-split,
  which also de-risks the other merged-wheel models in the batch.
- **id:** `ford_focus_st_2006`. **scale factor:** ×100.05 → L 4.34 / W 1.96 / H 1.66 m.
- **Orientation:** native front = +Z → player model rotated 180° (front −Z); NPC not
  rotated (front +Z). Verified driving forward in-game.
- **Wheels:** merged → split into 4 (radius **0.319 m**, wheelbase 2.64 m, track 1.53 m
  — match the real Focus Mk2). Player: reparented onto GEVP wheel nodes, spin + steer +
  travel. NPC: spun by `npc_car.gd`.
- **Grounding:** wheels on the road, body bottom ≈ wheel bottoms; no float/sink.
- **Lights:** headlights on the real front cluster with forward beam (night); tail =
  emissive `red_glass`, bright + road pool when braking; NPC head/tail via
  `npc_car_lights.gd` `FORD_FOCUS` entry.
- **Colours:** body-paint-only recolour from the 8 official Focus ST colours; NPC random
  (weighted common). Player default = Performance Blue.
- **Stats:** torque 850 / rpm 6500 / FD 3.8 / gears [3.5,2.3,1.7,1.3,1.0]; display
  accel .78 / speed .80 / handling .78; **price 450 000 ₽**; NPC weight **3 %** (rare
  hot-hatch). Spec: `2006 · 2.5L · 225 HP · FWD · 1392 KG`.
- **Evidence:** `screenshots/ford_focus_st_npc_colors.png` (3 NPC colours, grounded),
  `screenshots/ford_focus_st_showroom_preview.png`. Full checklist (all ✅):
  `docs/car_pipeline/ford_focus_st_2006_checklist.md`.

### Files created
`tools/car_model_analyzer.gd`, `tools/car_wheel_rig.gd`,
`car/ford_focus_st_setup.gd`, `car/ford_focus_st_npc_setup.gd`,
`addons/gevp/scenes/ford_focus_st_car.tscn`, `traffic/npc_ford_focus_st.tscn`,
`car/models/ford_focus_st/` (imported), this doc + the checklist + 2 screenshots.

### Files modified
`settings/car_settings.gd` (CARS + DISPLAY_STATS), `career/career_state.gd`
(CAR_PRICES), `ui/car_selection.gd` (CAR_SPEC_LINES), `traffic/traffic_manager.gd`
(var + preload + warmup + weight), `night_mode/npc_car_lights.gd` (FORD_FOCUS).

### Remaining risks
- Light/wheel positions are tuned per model — re-check each new car in-game.
- The literal menu *Select → start race* click-path was not exercised (the equivalent
  swap + `apply_car_stats` was); the data path is wired via `CARS[id].scene`.

---

## 7. Batch intelligence (measured up front — saves time on the rest)

Model organisation differs a lot; analyse before authoring:

| Model | Verts | Organisation | Notes for integration |
|---|---|---|---|
| Ford Focus ST | 28k | by material, merged wheels | **DONE** — clean reference |
| Honda Civic Si | 32k | by material, merged wheels | cleanest light materials (`lights`,`light_R`,`red_glass`); same path as Focus |
| Mazda 6 sedan | 14k | by part (FL/FR/RL/RR) but **1 body material** | wheels trivial (reparent), but recolour/lights hard (single textured body) |
| Chevrolet Aveo | 94k | garbage material names | classify by geometry, not name |
| Chevrolet Spark | 63k | 163 fragments | heavy cleanup |
| Hyundai Accent | 779k | 1 `body` material, messy wheels | **too heavy** for NPC; decimate first |
| Lada Vesta Cross | 1.0M | SketchUp `wire_*` materials | **unusable as-is** — needs re-export/remap |

Approach the rest **one at a time**: import → analyse → (clean wheels via rig if merged,
or reparent if separate) → author player + NPC → register → MCP-test → tick the
checklist. Decimate/quarantine the unusable ones (Vesta, Accent) and report why rather
than letting them block the working cars.

---

## 8. Quarantine criteria & NPC performance budget

Not every model should be integrated immediately. Some are better **quarantined** for
cleanup — decimation, re-export, material remap, wheel separation, texture relink, or
manual repair — before they're worth wiring in. Quarantining a model is a **valid,
successful pipeline outcome**: do not let one bad model block the rest of the batch.

### NPC vertex budget
NPC cars spawn in numbers and are the cost driver, so judge by vert count for NPC use:

| Tier | Verts | Rule |
|---|---|---|
| **Preferred** | < 50k | NPC-safe as-is |
| **Acceptable** | 50k–100k | OK *if* materials + scene structure are clean and the car won't be too common |
| **Risky** | 100k–150k | caution — consider merge/LOD, keep the NPC spawn weight low |
| **Quarantine by default** | > 150k | not for common NPC use unless decimated or specifically justified |
| **Heavy** | > 500k | not for *any* NPC use unless explicitly approved |
| **Unusable as-is** | 1M+ | treat as unusable until decimated / re-exported |

### Quarantine the model if
- vert count is too high for the intended NPC frequency
- the hierarchy is unusable or extremely messy
- wheels cannot be identified or separated
- wheel meshes are merged in a way the wheel rig cannot split reliably
- a single baked body material prevents a clean recolour
- glass / lights / body / interior cannot be separated enough for acceptable visuals
- material names are garbage **and** geometry classification also fails
- scale or orientation cannot be verified
- essential visible parts are missing
- imported textures are broken or missing
- collision / grounding cannot be fixed without excessive manual work
- it causes unacceptable performance or memory use

### A quarantined model gets a short note
State what is wrong and what it needs — e.g. decimation, LOD generation, Blender
cleanup, material remap, wheel separation, texture relink, re-export, or manual light
placement — so the next pass can act on it without re-diagnosing.

### Current-batch calls (from §7)
- **Hyundai Accent / Solaris** (~779k) — do **not** use as an NPC as-is; decimate first.
- **Lada Vesta Cross** (~1.0M, SketchUp `wire_*` materials) — **quarantine as-is**; needs
  re-export / material remap.
- **Ford Focus ST** (~28k) — a good NPC-safe reference.
- **Honda Civic Si** (~32k) — likely a good next candidate (same clean path as Focus).
- **Mazda 6** (~14k) — light, but may need special handling because of its single-body-
  material limitation (recolour + lights are the hard part, not the wheels).
