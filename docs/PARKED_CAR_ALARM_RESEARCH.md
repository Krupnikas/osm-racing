# Research: Parked Car Alarm + Flashing Lights

**Status:** Research only — no code, scenes, or assets created/modified.
**Date:** 2026-06-19
**Scope:** Where parked cars live, how impacts are already detected/graded, and which existing
audio/lights/blink/manager/debug patterns a future "crash → car alarm + flashing lights" feature
should reuse. All claims are grounded with `file:line` references. Lines verified directly are marked
✔; lines surfaced by sub-agent search and not re-opened are marked ≈ (approximate, re-check on impl).

Related shipped feature this mirrors: **[POLICE_SIREN_RESEARCH.md](POLICE_SIREN_RESEARCH.md)** +
the police emergency implementation in `traffic/npc_car.gd` / `traffic/traffic_manager.gd`.

---

## 1. Where parked cars are spawned

- Single spawner: **`_spawn_parked_cars(parking_points, parent)`** — `osm/osm_terrain_generator.gd:10717` ✔.
- Call chain: OSM `amenity=parking` → `_create_parking()` (`:10492` ≈) → `_spawn_parked_cars(points, parent)`
  (`≈:10530`). The `parent` passed in is the **chunk node** (e.g. `Chunk_1,2`).
- Per parking lot: **0–2 cars**, `randi() % 3` (`:10723` ✔). Positions via `_find_parking_spot()`
  (`:10777`), oriented along the lot ±5° (`:10764` ✔), random color via `_apply_parked_car_color()` (`:10772`).
- Model mix (`:10749–10754` ✔): **60%** `_parked_car_scene` (`traffic/npc_car.tscn`, generic box),
  **20%** `_parked_taxi_scene` (`traffic/npc_taxi.tscn`, Lada 2109 taxi), **20%** `_parked_lada_scene`
  (`traffic/npc_lada_2109.tscn`, Lada 2109 ДПС).
- This is the **only** parked-car path. Moving traffic is a different system (`traffic/traffic_manager.gd`,
  pooled). There is no separate "roadside" or decoration-layer car spawner.

> Note: ~20% of parked cars use the police Lada scene, but parked cars are **never** given police
> emergency mode (that is rolled only for moving traffic in `traffic_manager._maybe_activate_police_emergency`).

---

## 2. Parked car ownership / chunk cleanup behavior

- Parked cars are added as children of the **chunk node**: `parent.add_child(car)` (`:10774` ✔).
- **Not pooled, not tracked.** Unlike moving NPCs (`active_npcs`/`inactive_npcs` in the traffic manager),
  parked cars have no registry and no `request_despawn` connection (that signal is only wired in the
  traffic manager's `_get_npc_from_pool`, not here).
- Cleanup is implicit: `_unload_chunk(chunk_key)` (`osm/osm_terrain_generator.gd:3341` ≈) calls
  `chunk_node.queue_free()` (`≈:3639`) when the player leaves — **freeing the chunk frees all its
  parked-car children**. Reloading the chunk re-rolls fresh random cars (no persistence).
- **Implication for the alarm:** because there is no central registry, the safest owner of alarm state is
  the parked-car node itself (or a child component of it), so it is freed together with the car on chunk
  unload — no dangling looping audio. See §16.

---

## 3. Parked car node / body / collision type

- Root is **`VehicleBody3D`** (class `NPCCar` extends `VehicleBase`), same scenes as traffic, instantiated
  parked. Scenes: `traffic/npc_car.tscn`, `traffic/npc_taxi.tscn`, `traffic/npc_lada_2109.tscn`.
- Physics (uniform): `mass = 1400`, **`collision_layer = 4`** (NPC/vehicle), **`collision_mask = 1`**
  (terrain only), manual center of mass `(0,-0.3,0)`. Child `CollisionShape3D` = `BoxShape3D`
  (npc_car ~`(1.9,0.6,4.4)`; taxi/lada `(1.68,1.2,4.33)`). 4 `VehicleWheel3D`.
- **Critical runtime state set at spawn** (`:10766–10769` ✔):
  - `car.set_process(false)` — disables the node's `_process`. **No `freeze` is set; `_physics_process`
    stays ON** (comment: "физика остаётся для столкновений").
  - So a parked car still resolves physics collisions and runs `_physics_process`, but its `_process`
    (where the police beacon spin/timer lives) is OFF.
- **This is the inverse of the police-freeze case** (police debug froze the body with
  `set_physics_process(false)` but kept `_process`). For parked cars `_process` is dead and
  `_physics_process` is live — so any self-driven alarm tick must NOT rely on the parent's `_process`.
  A **child component** has its own independent process flags and can blink in `_process` regardless of
  the parent's `set_process(false)` (this is how `NPCCarLights` already works as a child). See §14/§18.

---

## 4. Do parked cars currently receive collision events?

- **No.** Parked cars do **not** set `contact_monitor` / `max_contacts_reported` (no such call in the
  parked-car spawn path), so they resolve physics but emit **no `body_entered` / contact signals** today.
- They are physical blockers: the player can ram them and they push/respond (mass 1400, layer 4, mask 1),
  but nothing is notified.
- To get an event, the feature must either (a) enable `contact_monitor = true` + `max_contacts_reported`
  on the parked car at spawn and connect `body_entered`, or (b) add a child `Area3D` trigger. Both
  patterns are already used elsewhere (§5).

---

## 5. Existing collision/impact systems to reuse

All in `osm/osm_terrain_generator.gd` unless noted. Two proven shapes:

**(a) Frozen-kinematic RigidBody + `contact_monitor` + `body_entered`** (bins, fences, signs):
- Bin: `freeze_mode = KINEMATIC`, `contact_monitor = true`, `max_contacts_reported = 6` (`:11386–11387` ✔)
  → `body_entered` → **`_on_clutter_hit(other, rb, hit_key, drop_key)`** (`:11304` ✔).
- Pedestrian fence shatter: frozen RigidBody, `contact_monitor=true` (`≈:23777`), `body_entered`; shatters
  if approach speed ≥ `pfence_shatter_speed = 10.5 m/s` (~38 km/h) using a **10-frame velocity history**
  `_pfence_player_approach_vel()` (`≈:23819`) — because instantaneous speed at contact has already dropped.
  Cap `PFENCE_MAX_SHATTERED = 6`, piece TTL `9 s`.
- Road signs: knock-over RigidBody, `body_entered` (`osm/road_signs.gd:172` ≈), impulse
  `clamp(car_speed*20, 100, 800)`.

**(b) Child `Area3D` trigger (layer 0 / mask 1 = player only) + `body_entered`** (cones, bags, planned
watermelons): used when the body itself has mask 0 while frozen so it never slows the car; the Area wakes
it. Cone `_on_cone_trigger` (`≈:11643`), bag `_on_bag_trigger` (`≈:11451`), watermelon plan uses one
root Area3D as a "single decision point" (`docs/WATERMELON_STAND_PLAN.md`).

**Player identity + reuse:** every handler reads `other_body.is_in_group("player")` (`:11308` ✔). The
player car is a GEVP `VehicleBody3D` in group `"player"`. There is **no global "player crashed" signal**
in `car/vehicle_base.gd`; each prop detects the player itself via its own monitor/area. The alarm should
follow the **bin pattern exactly** (it is already a car-vs-frozen-body case): enable `contact_monitor` on
the parked car, connect `body_entered`, gate on `is_in_group("player")`.

> Do not add a global per-frame scan — the established pattern is event-driven `body_entered`.

---

## 6. Best way to estimate impact strength

- Canonical pattern (`_on_clutter_hit` `:11316–11320` ✔): read the hitter's speed directly:
  ```gdscript
  var car_speed := 0.0
  if other_body is RigidBody3D:    car_speed = other_body.linear_velocity.length()   # m/s
  elif other_body is VehicleBody3D: car_speed = other_body.linear_velocity.length()
  ```
- Existing thresholds (m/s): fence shatter **10.5** (~38 km/h), watermelon high-speed **8.33** (30 km/h),
  bag burst **16.67** (60 km/h), clutter low-speed impulse clamp **2–14** / cone **6–24**.
- Accuracy caveat (from the fence system): speed sampled at the exact `body_entered` frame is already
  reduced by the contact. For a clean trigger threshold, the fence keeps a short **velocity history** and
  takes the max approach speed (`_pfence_player_approach_vel`, `≈:23819`). For an alarm a simpler
  `linear_velocity.length()` read is acceptable, but the history trick is available if false-negatives appear.
- **Suggested v1 threshold (to validate on impl):** ignore < ~5 m/s (~18 km/h) scrapes; trigger at
  ≥ ~5–6 m/s. Tune in-engine. (Lower than the fence/bag because the intent is "bumped a car," not "destroyed it.")
- km/h conversion is `m/s * 3.6` (HUD `ui/hud.gd:72` ≈).

---

## 7. Recommended alarm state location

- **A child component on the parked car**, mirroring `_setup_lights()` → `NPCCarLights`
  (`traffic/npc_car.gd:707–714` ✔) and the police siren child. A child:
  - is freed with the car on chunk unload → audio + state auto-cleaned (§2, §16);
  - has independent process flags → can blink in its own `_process` despite the parent's
    `set_process(false)` (§3);
  - keeps parked cars otherwise untouched (no manager/registry needed).
- Suggested per-car state on that component: `alarm_active`, `alarm_time_left`, `cooldown_left`,
  `_alarm_player` (AudioStreamPlayer3D), `_blink_t`, cached light materials/nodes, `last_trigger_ms`.
- A **lightweight global cap** still needs a shared counter (§8, §12) — but that can be a single static/int
  on a tiny manager or passed in by the spawner, not a heavy system.

---

## 8. Recommended alarm duration / cooldown

- Per-car timers on the component (like police `_emergency_time_left` self-tick, `npc_car.gd:766–779` ✔).
- Suggested v1 (validate on impl): **duration 8–15 s**, **cooldown 20–45 s** after it ends, both per-car.
- Re-hit during an active alarm should **refresh the duration but not restart the sound** (guard with
  `alarm_active`), matching the clutter "single-fire" meta guards (`clutter_hit_done`, `:11334` ✔).
- A global cap (§12) is the only cross-car timer needed.

---

## 9. Existing 3D audio patterns to reuse

- **One-shot 3D SFX** (impact sounds) — `_play_clutter_sfx(body, key)` (`:11349–11359` ✔):
  `AudioStreamPlayer3D`, `max_distance = 70`, `unit_size = 8`, **child of the hit body**, `play()`,
  `finished.connect(queue_free)`. (Fence variant `≈:23903`: `max_distance 80`, `unit_size 9`.)
- **Looping 3D SFX** (the right model for a continuous alarm) — police siren
  `_start_police_siren()` / `_stop_police_siren()` (`traffic/npc_car.gd:825–877` ✔):
  - `AudioStreamPlayer3D`, `bus = "SFX"`, `attenuation_model = ATTENUATION_INVERSE_DISTANCE`,
    `unit_size = 8`, `max_distance = police_siren_max_distance` (default 80), child of car at `(0,1,0)`.
  - MP3 looped **at runtime**: `(stream as AudioStreamMP3).loop = true` (the `.import` keeps `loop=false`).
  - Stopped + reset on pool return so a reused car never inherits a running siren.
- Engine (`car/audio/bmw_layered_engine_sound.gd`): `AudioStreamPlayer3D`, SFX bus,
  `ATTENUATION_INVERSE_DISTANCE`, `unit_size 14`, `max_distance 125` — confirms the project-wide 3D
  attenuation convention.
- Bus layout `audio/default_bus_layout.tres`: **Master / Music / SFX** (all positional SFX → SFX).

---

## 10. Recommended alarm sound asset path

- Existing SFX live in `audio/sfx/` (verified): `police-siren.mp3`, `clutter_{bin,bag,cone}_hit.mp3`,
  `clutter_*_drop.mp3`, `pfence_hit.mp3`, `pfence_drop.mp3`, `watermelon_touch.mp3`,
  `watermelon_high_speed.mp3`.
- Recommended path matching convention: **`res://audio/sfx/car_alarm.mp3`** (or
  `car_alarm_russian_6tone.mp3`). A multi-tone car-alarm MP3 was already downloaded to
  `~/Downloads/Multi-Tone-Car-Alarm-Siren.mp3` (192 kbps, 44.1 kHz, stereo) — import-on-go-ahead, verify
  it loops seamlessly (set `loop=true` at runtime as the siren does, since `.import` defaults to no loop).

---

## 11. How to guarantee distance-based 3D audio

- Use `AudioStreamPlayer3D` (never `AudioStreamPlayer`/2D) on the SFX bus, child of the parked car so its
  position follows the car. Use `ATTENUATION_INVERSE_DISTANCE`, `unit_size ≈ 8–12`, `max_distance ≈ 60–90`
  (siren uses 80). Beyond `max_distance` it is inaudible; this is exactly the siren setup, proven 3D.
- Optional cheap pre-gate: do not even start the alarm if the player is far (the spawner/cap can skip),
  matching "do not start alarm if player is too far away" — but `max_distance` already silences distant ones.

---

## 12. How to avoid audio spam

- **Per-car single-fire guard**: don't restart an already-`alarm_active` car each contact frame (clutter
  meta-guard pattern, `:11334` ✔); refresh duration only.
- **Per-car cooldown** after the alarm ends (§8).
- **Global cap** of concurrently sounding alarms: mirror the police siren cap —
  `police_emergency_max_active_sirens = 1`, tracked in `_active_police_sirens`, enforced + GC'd in
  `_update_police_emergency` (`traffic/traffic_manager.gd:64–74, 762–790` ✔). Suggested v1 cap **2–3**.
- **Where the cap lives:** there is no parked-car manager today and parked cars are chunk-owned with no
  registry. Cheapest options: (i) a tiny static counter shared by the alarm component, incremented on
  start / decremented on stop+free; or (ii) hang the counter on an existing always-present node
  (e.g. the terrain generator, which already owns clutter/fence props). Avoid building a heavy new global.

---

## 13. Do parked cars already have usable headlights/lights?

- The NPC scenes do get a full lights child via **`_setup_lights()` → `NPCCarLights`**
  (`traffic/npc_car.gd:707–714` ✔, `night_mode/npc_car_lights.gd`): per-model `SpotLight3D` headlights
  (range 40, angle 45, energy 2, no shadow), `OmniLight3D` taillights (red), and **emissive `BoxMesh`
  proxy meshes** (headlight emission energy ~4, taillight ~1.5/6 braking). Some models use real lens meshes
  (`car/npc_real_lens.gd`).
- **But by default they are day-OFF.** Car lights are gated by `NightModeManager` — enabled only when
  `is_night` or `is_raining` (`npc_car.gd` `_refresh_lights`/`enable_lights`, signals from
  `night_mode/night_mode_manager.gd`). In daytime the headlights/taillights are off.
- For parked cars specifically: `_setup_lights()` runs in `_ready` regardless, so the light nodes/materials
  exist on parked cars too. The alarm can drive those existing emissive materials/lights directly.
- **Caveat for the alarm:** the feature wants flashing **visible by day and night**, so the alarm must
  override the day-off gating while active (force the emissive materials on/off itself rather than relying
  on `enable_lights()`), then restore the night-mode-governed state on stop.

---

## 14. Best way to make headlights/lights flash during alarm

Two viable approaches, both grounded:

1. **Drive the existing `NPCCarLights` emissive materials/lights** (preferred if accessible): the alarm
   component toggles the headlight/taillight **emission_energy_multiplier** (and optionally the
   SpotLight/OmniLight `light_energy`) on/off at the blink rate, overriding day gating while active and
   restoring afterwards. Reuses real headlight positions, no new GLTF work.
2. **Procedural fallback** (if the merged mesh hides the lens, as happened with the police beacon): add
   small additive **emissive quads/boxes** at the front (and optional rear) plus an optional shadowless
   `OmniLight3D`, exactly like the police beacon glow shell (`_make_beacon_glow_mat` additive/unshaded/
   depth-draw-off, `npc_car.gd` ✔). Set `cast_shadow = OFF` and `visibility_range_end ≈ 150–160`.

**Process gotcha (important):** the parent parked car has `set_process(false)` (§3). Put the blink in the
**alarm child component's own `_process`** (children keep independent process flags) OR in
`_physics_process` (which is ON for parked cars). Do NOT add the blink to the parent's `_process` and
expect it to run on a parked car.

No GLTF modification is needed for either approach.

---

## 15. Recommended blink / update pattern

- Two existing references:
  - **Centralized** traffic-light blink `_tl_update_blink(delta)` (`osm/osm_terrain_generator.gd:≈30003`):
    one accumulator, `sin(t + phase) > 0` on/off, **iterates only loaded lights**, per-id phase for desync,
    `tl_blink_hz = 1.1`.
  - **Per-object self-driven** police beacon in `npc_car.gd:_process` (`:766–779` ✔): early-returns unless
    active → only active effects cost anything.
- Recommended for the alarm: **per-car self-driven** (the alarm component's own `_process`/`_physics_process`),
  early-returning when `not alarm_active`, so **only actively-alarming cars do per-frame work** — satisfying
  "do not update every parked car every frame." Blink **2–4 Hz** via `sin(t * TAU * hz) > 0` toggling both
  front lights together (optionally tails), one timer drives sound duration + blink together.

---

## 16. Cleanup risks and solution

- **Top risk (same as the siren):** a looping `AudioStreamPlayer3D` must never outlive the car. Parked cars
  are `queue_free()`d wholesale when the chunk unloads (§2). Making the alarm a **child of the car** means
  it (and its audio) is freed automatically — the cleanest guarantee. Additionally stop audio in
  `_exit_tree()`/`_notification(NOTIFICATION_PREDELETE)` of the component as a belt-and-suspenders.
- **No pool-reuse risk** for parked cars (they are freed, not pooled — unlike traffic NPCs). So there is no
  "reset on return-to-pool" requirement here, but DO restore the night-mode light state if the alarm is
  cancelled on a still-living car.
- **Global cap leak risk:** if a car is freed mid-alarm, its slot must be released. Decrement the global
  counter from the component's `_exit_tree`/PREDELETE, not only from the normal stop path (mirrors the
  traffic manager GC pass that releases siren slots when a car vanishes, `:778–790` ✔).
- **Chunk-hidden vs freed:** chunks are freed (not just hidden) on unload, so visibility-toggle leaks are
  not a concern here; still, gate per-frame work on `alarm_active` so a re-shown car costs nothing.

---

## 17. Debug / test hooks (for later — do NOT implement now)

Mirror the police hooks (`traffic/traffic_manager.gd:801–911` ✔: `force_nearest_police_*`,
`spawn_debug_police_car_near_player`, `print_active_police_emergency_count`, `_*_summary`, `police_debug`):
- `force_nearest_parked_car_alarm_on()` / `force_all_parked_car_alarms_off()`
- `print_active_parked_car_alarm_count()`
- `spawn_or_find_debug_parked_car_near_player()`
- `simulate_alarm_impact_on_nearest_parked_car(speed)`
- a `parked_car_alarm_debug` flag for `[ALARM] ...` prints.

These pair well with the godot-mcp self-test loop used for the police feature (`play_scene` test track →
`execute_game_script` to force/inspect → `get_game_screenshot` → `stop_scene`).

---

## 18. Recommended v1 architecture

**Option A — parked car owns a small `ParkedCarAlarm` child component** (recommended).

- **Spawn:** in `_spawn_parked_cars` enable `contact_monitor = true` + `max_contacts_reported = 4` on the
  car and attach (or lazily attach on first hit) the alarm component. (Minimal change to the spawner.)
- **Trigger:** car `body_entered` → component checks `other.is_in_group("player")` and
  `other.linear_velocity.length() ≥ threshold` (bin pattern, §5/§6). If passing and not already active and
  not in cooldown and global cap not exceeded → start.
- **Audio:** looping `AudioStreamPlayer3D` child (SFX bus, inverse-distance, unit 8, max_dist 80, runtime
  loop) — siren settings (§9/§11).
- **Lights:** component blinks the existing `NPCCarLights` emissive materials (or procedural fallback) at
  2–4 Hz in its **own `_process`** (independent of the parent's `set_process(false)`), overriding day gating.
- **Lifecycle:** self-tick duration → stop → start cooldown; freed with the car on chunk unload (audio
  auto-stops); release global-cap slot in `_exit_tree`/PREDELETE.
- **Cap:** a single shared counter (static on the component or on the terrain generator).

**Why not the alternatives:**
- *B (spawner attaches + spawner ticks):* the spawner/terrain generator would need a per-frame registry of
  alarm cars — more plumbing than A, and the component already gets free cleanup via child lifetime.
- *C (player collision code calls alarm):* there is no player crash signal to hook (§5); would require
  adding contact monitoring to the player and a scan to find which parked car was hit — more invasive.
- *D (reuse a destructible-prop system):* parked cars aren't registered as clutter/props; retrofitting them
  into that pipeline is heavier than a dedicated child component that copies the same patterns.

---

## 19. Risks & pitfalls

- **`set_process(false)` on parked cars** kills the parent's `_process` — blink must live in the child's
  own `_process` or in `_physics_process` (§3, §14). Easy to get wrong.
- **Looping audio outliving the car** — child ownership + `_exit_tree` stop (§16).
- **Day-off light gating** — alarm must override `NightModeManager` gating to be visible by day, then
  restore it (§13).
- **Merged mesh hiding real lenses** — the police beacon hit exactly this (`_merge_meshes` bakes lamp
  meshes); have the procedural emissive fallback ready (§14).
- **False triggers** from gentle bumps — speed gate + single-fire guard + cooldown (§6/§8/§12).
- **Audio spam** from many lots — global cap 2–3 (§12).
- **Performance** — only `alarm_active` cars do per-frame work; everything else early-returns (§15).
- **Police-Lada parked cars** look like police but must use the **car alarm**, not the police siren/beacon
  (do not cross the wires).
- **Approximate line numbers** (≈) in §2/§5 (`_unload_chunk`, fence shatter, road signs) should be
  re-confirmed when implementing.

---

## 20. Open questions (only if blocking)

- None blocking. Two tuning decisions deferred to in-engine testing: the exact **trigger speed threshold**
  (start ~5–6 m/s) and whether to flash **tail lights too** or headlights only.

---

**Ready for implementation plan: yes.**

**Recommended v1 approach:** A `ParkedCarAlarm` child component on the parked car. Enable
`contact_monitor` on the parked car at spawn; on `body_entered` from the player above a speed threshold
(reusing the `_on_clutter_hit` speed read), start a looping 3D `AudioStreamPlayer3D` (police-siren audio
settings) and blink the existing `NPCCarLights` emissive lights at 2–4 Hz from the component's own
`_process` (overriding day gating). Self-expire after 8–15 s, then 20–45 s per-car cooldown; a global cap
of 2–3 concurrent alarms via a shared counter; full cleanup guaranteed by child lifetime + `_exit_tree`
audio-stop and cap-slot release. Debug hooks mirror the police `force_*`/`spawn_debug_*`/`print_*` set.
