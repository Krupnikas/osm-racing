# Police Emergency Lights + Siren — Codebase Research

📋 **Research only — nothing implemented, modified, or imported.** This documents how police cars
currently exist and where a future "occasional police car with flashing lights + 3D `police-siren.mp3`"
feature should integrate safely. Source: current tree at repo root `/Users/alekseiaksenov/osm-racing`.

Feature being researched:
```text
Occasionally police cars should drive with flashing lights and a 3D siren sound using police-siren.mp3.
```

Line numbers verified directly are exact; a few audio/lighting ones are marked `≈` (from broad reads,
verify before editing). All paths are repo-relative unless noted.

---

## 1. Where police cars are defined / spawned

- **Police car = "Lada 2109 ДПС"** (ДПС = Russian traffic police). It is a normal NPC traffic vehicle —
  **not a bespoke system**.
- Scene: `res://traffic/npc_lada_2109.tscn` → model `res://car/models/lada_2109_dps/scene.gltf`.
  DPS livery (white body + blue stripe) applied by `car/lada_2109_setup.gd` (`_apply_dps_colors()` in `_ready`).
- **Moving traffic:** `traffic/traffic_manager.gd` — `npc_lada_scene` preloaded (line 67); chosen in
  `_get_npc_from_pool()` in the `if rand < 0.05:` branch (lines 481‑482, `car_type = "Lada 2109 DPS"`).
  **≈5% of moving traffic.**
- **Parked cars (separate system):** `osm/osm_terrain_generator.gd` — `_parked_lada_scene = preload("res://traffic/npc_lada_2109.tscn")`
  (≈line 1066), used by `_spawn_parked_cars()` at ≈20% of parking-lot cars, with `car.set_process(false)`.

## 2. Moving, parked, or both?

**Both** — the *same* scene is used for moving traffic (TrafficManager pool) and parked cars (terrain
generator parking lots). Both are `NPCCar` (VehicleBody3D) instances; parked ones just have AI disabled.

## 3. Reliable identification

**No reliable runtime identifier exists today.**
- `car_type = "Lada 2109 DPS"` is a **local variable** inside `_get_npc_from_pool()` — never stored.
- No `add_to_group(...)`, no `set_meta(...)` in `traffic_manager.gd` (grep confirms none).
- All NPCs share `class_name NPCCar` (`traffic/npc_car.gd:2`) — does not distinguish police.
- Only current discriminator: `npc.scene_file_path` contains `npc_lada_2109` (fragile).

**Plan recommendation:** at the single spawn site that already knows (the `npc_lada_scene` branch of
`_get_npc_from_pool`), tag the instance — `npc.add_to_group("police")` or `npc.set_meta("is_police", true)`
(ideally also a real `car_type` field on `NPCCar`). Do **not** rely on the filename.

## 4. Traffic vehicle lifecycle (files / functions)

- Manager `traffic/traffic_manager.gd` (extends `Node`) **globally owns** NPCs. Caps/ranges:
  `max_npcs := 30` (line 8), `spawn_distance := 200.0` (line 9), `despawn_distance := 300.0` (line 10).
- Spawn: `_update_spawning()` → `_attempt_spawn_in_chunk()` → `_get_npc_from_pool()` (≈line 463); instance
  added under `get_parent()` and appended to `active_npcs` (line 333). **Object pool**: `inactive_npcs` /
  `active_npcs` (lines 43‑44), pre-warmed at startup.
- Per-vehicle AI: each `NPCCar` runs its **own** `_physics_process(delta)` (`traffic/npc_car.gd:111`),
  AI throttled to `UPDATE_INTERVAL := 0.1` (100 ms); pure-pursuit steering over `RoadNetwork` waypoints
  (`traffic/road_network.gd`). Per-vehicle state lives on the node (`waypoint_path`, `target_speed`,
  `ai_state`, timers, `_lights`).
- TrafficManager `_process()` does only spawn/despawn bookkeeping (centralized); driving is per-car.

## 5. Despawn / chunk cleanup

- **Globally owned, NOT chunk-owned** — chunk unload (`road_network.clear_chunk()`) drops waypoints, not cars.
- Despawn triggers: distance `> 300 m` (`_update_despawning()`, ≈line 389) + stuck / off-road / loop
  detection in `npc_car.gd` (each `request_despawn.emit()`).
- Cleanup = **return to pool** (`_return_npc_to_pool()`, ≈line 606): removed from `active_npcs`, state reset,
  `process_mode = PROCESS_MODE_DISABLED`, `visible = false`, pushed to `inactive_npcs`.
- ⚠️ **Cars are POOLED (reused), not freed.** Any emergency state + child siren/lights must be **reset on
  pool-return**, not only on `queue_free`.

## 6. Police model / lightbar structure

- GLTF `car/models/lada_2109_dps/scene.gltf`: body / wheels / mirror / `taxycap` (roof element) + an
  **empty `Flashlight` node**, but **no lightbar mesh, no red/blue lamp nodes, no emissive light materials,
  no spare slots** → a lightbar must be **procedural**.
- Roof position derivable: `Model` scaled 0.1 with offset ≈ `(0, 0.56, 0)`; existing light meshes sit at
  Y≈0.55‑0.6, so a roof bar ≈ Y 0.7‑0.8 in car-local space (attach to a roof child / `Flashlight`).
- **Reusable integration model:** `npc_car.gd:_setup_lights()` (lines 686‑691) creates a
  `night_mode/npc_car_lights.gd` instance as a **child Node3D** (`_lights`), which spawns the car's
  head/tail/reverse lights (SpotLight3D/OmniLight3D + emissive `BoxMesh` proxies) and is freed with the car.
  **The lightbar + siren should follow this exact "owned child" pattern.**

## 7. Light / emission / blink patterns to reuse

- **Blink driver (best reuse):** `osm/osm_terrain_generator.gd` `_tl_update_blink()` + `_tl_bulb_mat()` — a
  **centralized** per-frame loop driving `emission_energy_multiplier` of shared `StandardMaterial3D`s via
  `sin(t + per_id_phase)`, with day/night energy (`tl_blink_energy_day 3.5` / `night 7.0`) and per-light
  phase offset. Ideal for red/blue alternation (two materials, opposite phase).
- Car emissive lights: `night_mode/npc_car_lights.gd` (`emission_enabled`/`emission`/
  `emission_energy_multiplier` on BoxMesh; SpotLight3D/OmniLight3D **no shadows**), toggled by
  `_refresh_lights()` on `night_mode_changed`/rain. Player analogues in `car/spark_setup.gd`.
- Night toggling: `night_mode/night_mode_manager.gd` broadcasts `night_mode_changed`.
- Culling: `visibility_range_end` + `VISIBILITY_RANGE_FADE_SELF` (road signs 120‑130 m, lamps 80‑150 m).
- **Material gotcha:** procedural `ArrayMesh` without UVs breaks `StandardMaterial3D` lighting — use
  primitives (`QuadMesh`/`BoxMesh`, auto-UV) or a `ShaderMaterial`.

## 8. Audio patterns to reuse

- **3D audio reference (closest analogue):** `car/audio/bmw_layered_engine_sound.gd` —
  `AudioStreamPlayer3D`, `attenuation_model = ATTENUATION_INVERSE_DISTANCE`, `max_distance` 105‑125 m,
  `unit_size` 12‑14 m, positioned offset, **child of the car**, paused/resumed with freeze.
- **One-shot SFX pattern:** clutter (`osm_terrain_generator.gd ≈11349`) + watermelon
  (`models/market/market_watermelon_stand.gd ≈560`) spawn an `AudioStreamPlayer3D` (`max_distance` 60‑70,
  `unit_size` 6‑8) and self-free via `finished.connect(queue_free)`. **Does NOT fit a looping siren** (a
  loop never emits `finished`).
- Buses: `audio/default_bus_layout.tres` → **Master / Music / SFX**. Engine/collision/UI use **SFX**.
  Siren → **SFX**.
- ⚠️ **Critical risk:** a looping siren must be **a child of the police car** and explicitly **stopped/freed
  on despawn**. Because cars are pooled, stop it in `_return_npc_to_pool` / `set_emergency(false)`, not only
  on `queue_free`.

## 9. Recommended v1 integration point

**Inside the existing traffic NPC system — no new system.**
- **Tag + decide at spawn:** in `traffic_manager._get_npc_from_pool()` police branch — mark the car and roll
  the rare emergency chance there (TrafficManager knows the global active set → can enforce a cap).
- **State + visuals on the car:** add an `emergency` state to `NPCCar` and create a `PoliceLightbar` + siren
  as **owned children** mirroring `_setup_lights()` (`npc_car.gd:686`); reset in the pool-return path.
- **Blink:** prefer a **centralized** tick (TrafficManager iterating only active emergency cars, à la
  `_tl_update_blink`) over per-car `_process`.

## 10. Recommended v1 emergency-mode state model

- `NPCCar`: `var emergency_active := false`, a `set_emergency(on)` (creates/shows or hides/stops lightbar +
  siren child) + a duration timer; **cleared in `_return_npc_to_pool`** (alongside the other per-NPC resets).
- Lightbar = one child Node3D: two emissive quads/boxes (red + blue, opposite blink phase) + optional 2
  **shadowless** OmniLight3D. Siren = one child looping `AudioStreamPlayer3D` (SFX bus).
- Gate: emergency only on cars in `active_npcs` that are police-tagged (excludes parked, per v1).

## 11. Rarity / cap suggestions

- Emergency only on **moving** police; police are already ≈5% of ≤30 NPCs (typically 0‑2 present).
- Roll a small chance (≈15‑25% of *spawned* police) **and** enforce a **global cap of 1‑2 active sirens**;
  lights may exceed siren count but stay capped/culled.
- Emergency lasts a limited duration (≈20‑45 s) then reverts, freeing the cap slot.

## 12. Performance / culling constraints

- Existing radii: 200 m spawn / 300 m despawn. **Siren audible distance should be smaller** (≈60‑90 m like
  other SFX). **Lights** use `visibility_range_end` (≈150 m), **no shadows**.
- Each car already runs `_physics_process`; a few emissive writes per active emergency car are cheap. Prefer
  a **centralized blink loop over active emergency cars only** (no new per-car `_process`). Pooled/disabled
  cars do no work (`PROCESS_MODE_DISABLED`).

## 13. Debug / self-test hooks for the plan

Mirror existing conventions (`@export var *_debug`; `force_*` methods on `market_watermelon_stand.gd`;
`traffic_manager.get_debug_info()`), driven via godot-mcp `execute_game_script` + `get_game_screenshot`:
- `force_nearest_police_emergency_on()` / `force_all_police_emergency_off()`
- `spawn_debug_police_car_near_player()` (reuse `_get_npc_from_pool` + a near waypoint)
- `print_active_police_emergency_count()` (also fold into `get_debug_info()`)
- `@export var police_debug := false` for verbose logs/markers.

## 14. Asset path for `police-siren.mp3`

- **Found, not yet in repo:** `~/Desktop/OSM material/police-siren.mp3` (confirmed by `find`).
- **Recommended project path:** `res://audio/sfx/police-siren.mp3` (matches the SFX convention —
  `audio/sfx/watermelon_*.mp3`, `clutter_*.mp3`). On import: set **loop = on**, route to the **SFX** bus.
  Do not import during research.

## 15. Risks & pitfalls

- **Siren outliving the car (top risk):** cars are **pooled/reused** — stop+reset the siren in
  `_return_npc_to_pool` and `set_emergency(false)`, not only on free. Looping streams never emit `finished`,
  so the `finished.connect(queue_free)` SFX pattern won't clean them up.
- **No identifier today** — add a group/meta at spawn; never depend on the GLTF filename.
- **Parked police cars** share the scene → v1 excludes them (not in `active_npcs`, AI off); gate on the
  police tag + active state.
- **Audio spam** — without a global cap, multiple police could siren at once; enforce 1‑2.
- **Material/UV gotcha** for the procedural lightbar; **no shadows** on the lights.
- **Pooling-reset completeness** — emergency timer, lightbar visibility, and siren playing-state must all
  reset with the rest of the per-NPC state on return-to-pool.

## 16. Open questions (only if blocking)

1. Should emergency police **drive differently** (faster / weave) or just light+siren in normal flow?
   (Affects AI scope; v1 can be light+siren only.)
2. Lights **day+night or night-only**? (Real sirens run day+night; existing NPC lights are night/rain-only —
   decide whether emergency overrides that.)
3. Provided MP3 loop quality (seamless loop?) — affects import settings.

---

## Recommendation

```text
Ready for implementation plan: yes
Recommended v1 approach: Extend the existing traffic NPC system, not a new one. Tag the police Lada in
traffic_manager._get_npc_from_pool() and roll a rare emergency chance there under a global 1–2 cap. Add an
`emergency` state to NPCCar with an OWNED child lightbar (procedural red/blue emissive quads + shadowless
OmniLights, blinked by a centralized loop à la _tl_update_blink) and a single looping AudioStreamPlayer3D
(police-siren.mp3 → res://audio/sfx/, SFX bus, ~60–90 m, INVERSE_DISTANCE). Reuse the npc_car _setup_lights()
child pattern. Critically, stop+reset the siren/lights in _return_npc_to_pool (cars are pooled, not freed).
Moving police only; parked excluded in v1.
```
