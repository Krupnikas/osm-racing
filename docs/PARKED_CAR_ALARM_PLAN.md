# Implementation Plan: Parked Car Alarm + Flashing Lights

**Status:** PLAN ONLY — no code/scenes/assets created or modified yet. Awaiting go-ahead.
**Date:** 2026-06-19 (v1.2 — **play-one-full-sound-then-stop** (not loop) + **two random sound variations**;
prior v1.1: collision-proof-first, softened file list, ignore-while-active re-hit, cap-safety hardening,
debug-hook fallback location).
**Source of truth:** [PARKED_CAR_ALARM_RESEARCH.md](PARKED_CAR_ALARM_RESEARCH.md) (all §refs below point there).
**Mirrors:** the shipped police feature (`traffic/npc_car.gd` siren/beacon + `traffic/traffic_manager.gd` cap/GC/debug).

**Feature:** When the player crashes hard enough into a parked car, that car triggers an ordinary multi-tone
car alarm — a **randomly chosen one of two** 3D positional alarm sounds played **once through** (not looped),
with the car's lights flashing **only while that sound plays**. When the sound finishes one full pass the
alarm stops, lights go back to normal, and the car enters cooldown. Rate-limited per car, globally capped,
fully cleaned up on chunk unload. Parked police (ДПС) Ladas use the **ordinary car alarm**, not the police
siren/beacon.

---

## 1. Files to change

**Expected (minimal) blast radius:**

| File | Change | Why |
|---|---|---|
| `osm/osm_terrain_generator.gd` | In `_spawn_parked_cars` (`:10717`): after `set_process(false)` (`:10768`), enable `contact_monitor = true` + `max_contacts_reported = 4` on the car and add a `ParkedCarAlarm` child. ~5 lines, one site. (Plus, only if §11 needs it, a debug entrypoint.) | Parked cars emit no contact events today (§4); the alarm needs `body_entered`. |
| **new** `traffic/parked_car_alarm.gd` | The whole feature (see §2). | Self-contained component. |
| `audio/sfx/car_alarm_multitone.mp3` + `audio/sfx/car_alarm_2.mp3` (+ generated `.import`s) | Two new assets (see §3). | The two alarm sound variations. |

**Allowed-if-needed (keep minimal, document why in the final report):** a *tiny* helper on
`traffic/npc_car.gd` or `night_mode/npc_car_lights.gd` — e.g. `set_all_lights_visible(on)` or a getter for
the lights child — **only** if driving the existing lights from the component proves too brittle. v1 should
first try calling the existing `enable_lights()`/`disable_lights()` directly, so this edit may not be needed,
but it is **not** hard-blocked. No `.tscn`/GLTF edits.

---

## 2. New files / components to add

- **`traffic/parked_car_alarm.gd`** — `class_name ParkedCarAlarm extends Node3D`. One self-contained child
  component attached to each parked car. Owns: trigger handler, alarm/cooldown timers, the 3D audio player,
  the blink driver, the global-cap accounting, and all cleanup. No scene file needed (created in code, like
  `NPCCarLights`). Default `set_process(false)`; turns its own `_process` on only while alarming (§15 of research).

No new autoload, no new manager, no new traffic system.

---

## 3. Asset import / variation pool (TWO sounds, played once)

Two ordinary car-alarm sounds form a variation pool (one chosen at random per trigger, §5). Both source
files are confirmed present:

| Source (confirmed) | Size | Target project path |
|---|---|---|
| `~/Downloads/Multi-Tone-Car-Alarm-Siren.mp3` | 1.37 MB | `res://audio/sfx/car_alarm_multitone.mp3` |
| `~/Downloads/car-alarm.mp3` (also `~/Desktop/OSM material/car-alarm.mp3`) | 193 KB | `res://audio/sfx/car_alarm_2.mp3` |

- Flat `audio/sfx/<name>.mp3` convention (like `police-siren.mp3`, `clutter_*_hit.mp3`).
- **Import steps (on go-ahead):**
  1. Copy both MP3s to their target paths.
  2. Let Godot generate the `.import`s by launching the editor once (`--editor --quit`) or via MCP — **do not
     hand-write `.import`** (project gotcha).
  3. **Play ONCE, do NOT loop.** Leave the `.import` default `loop=false` AND do **not** set
     `AudioStreamMP3.loop = true` at runtime (unlike the police siren). Each alarm plays one full pass and
     stops (see §7). The stop is driven by the player's `finished` signal (+ a safety timeout).
  4. Verify each plays cleanly start-to-finish in-engine and note each clip's natural length (used for the
     safety-timeout sizing in §6).
- Streams are `load()`ed once and cached in a small array (the variation pool); selection is per-trigger (§5).
- **If a target asset is missing at runtime:** drop it from the pool and log it; if BOTH are missing, keep
  the code path but play nothing (no fake/substitute audio) — research/plan rule.

---

## 4. Parked car spawn integration

In `_spawn_parked_cars` (`osm/osm_terrain_generator.gd:10717`), per spawned `car`, right after the existing
`car.set_process(false)` (`:10768`) and before/after `parent.add_child(car)` (`:10774`):

```
car.contact_monitor = true
car.max_contacts_reported = 4
var alarm := preload("res://traffic/parked_car_alarm.gd").new()
alarm.name = "ParkedCarAlarm"
car.add_child(alarm)   # component connects to car.body_entered in its _ready
```

- Attach to **all** parked cars (box/taxi/Lada alike). The component is inert until triggered (its `_process`
  is off; it only holds a `body_entered` connection), so idle cost ≈ enabling `contact_monitor` (same as bins).
- The component reads its parent (the parked car) via `get_parent()` in `_ready`; no spawner-side wiring beyond
  the three lines.
- Police-Lada parked cars get the **same** component — no police logic involved.

---

## 5. Collision / impact trigger design

- **STEP 0 — prove the collision event FIRST (gating milestone, before any audio/lights):** wire only
  `contact_monitor=true` + `max_contacts_reported=4` at spawn (§4), connect `body_entered`, and log **only**
  when `other.is_in_group("player")`. Run `res://main.tscn` and ram a parked car. Confirm the player
  collision event actually fires on the parked car. Do **not** build audio/lights until this is proven.
- **If `VehicleBody3D.body_entered` does NOT fire reliably for parked cars:** do **not** hack around it with
  per-frame scans. Fall back to a small **child `Area3D`** on the parked car with a **player-only** mask
  (layer 0 / mask 1 = player), `body_entered` on the Area — the exact cone/bag pattern (research §5). The
  rest of the design (component, audio, lights, cap, cleanup) is identical; only the event source swaps.
  Speed is still read from the entering body's `linear_velocity` (an Area gives the body, not contact data).
- **Where `contact_monitor` is enabled:** at spawn (§4), on the parked `VehicleBody3D`. VehicleBody3D extends
  RigidBody3D, so it supports `contact_monitor` + `body_entered`.
- **Where `body_entered` is connected:** in `ParkedCarAlarm._ready()` → `get_parent().body_entered.connect(_on_body_entered)`
  (or the child Area's `body_entered` in the fallback).
- **Handler `_on_body_entered(other: Node)` checks, in order (each failure logs a distinct reason under the
  debug flag, §11):**
  1. `other.is_in_group("player")` — else reject (`reason=non_player`). (Player car is a GEVP `VehicleBody3D`
     in group `"player"`, research §5.)
  2. **not already `alarm_active` — else IGNORE the hit entirely** (do not restart sound, do not restart the
     blink, do not switch the selected variation, do not extend the run); optionally log `reason=already_active`.
  3. cooldown elapsed: `Time.get_ticks_msec() - _last_stop_ms >= cooldown_ms` — else reject (`reason=cooldown`).
  4. speed gate: `other.linear_velocity.length() >= trigger_speed` — else reject (`reason=below_threshold`).
  5. global cap not full (§9) — else reject (`reason=cap_full`).
  6. variation pool non-empty (at least one asset loaded, §3) — else reject (`reason=no_audio`).
  - All pass → `start_alarm()`, which **picks one random stream** from the pool for this run (§6/§7).
- **Speed read (v1):** direct `other.linear_velocity.length()` in m/s — the canonical `_on_clutter_hit`
  pattern (research §6, `:11316`). The collision physically registers because the player's mask (7) includes
  the parked car's layer (4).
- **Why tiny touches don't trigger:** the speed gate at `trigger_speed` (start ~5–6 m/s ≈ 18–22 km/h).
- **Threshold tuning:** start at 5.0–6.0 m/s, tune in the self-test (§12) by ramming at known speeds (HUD
  shows km/h). Expose as an exported/const var for easy adjustment.
- **Velocity history:** NOT in v1. The fence uses a 10-frame approach-history because shatter must not
  false-*negative* at exactly the contact frame; for an alarm a slightly missed weak hit is harmless. Add the
  history fallback (mirror `_pfence_player_approach_vel`) only if testing shows real hits being missed.

---

## 6. Alarm state model (on `ParkedCarAlarm`) — **audio-run model**

The alarm runs for **exactly one full pass of the chosen sound**, not a fixed timer. A fixed timer survives
only as a **safety net** in case the `finished` signal never fires or the stream length is unreadable.

```
# tunables (const or @export)
trigger_speed        := 5.5     # m/s, gate
fallback_timeout_max := 22.0    # s — SAFETY ONLY (prevent a stuck alarm); not the design driver
cooldown_min_ms      := 20000   # ms
cooldown_max_ms      := 45000   # ms
blink_hz             := 3.0     # Hz
audio_max_distance   := 80.0
audio_unit_size      := 10.0
# variation pool (loaded once)
_alarm_streams       : Array[AudioStream] = []   # [car_alarm_multitone, car_alarm_2] minus any missing
# runtime state
alarm_active         := false
_selected_stream     : AudioStream = null        # fixed for this run
_alarm_player        : AudioStreamPlayer3D = null
_fallback_left       := 0.0                       # safety countdown
_blink_t             := 0.0
_last_stop_ms        := -100000  # so first hit isn't gated by cooldown
_counted_in_cap      := false    # guards double inc/dec of the global cap
```

- **`start_alarm()`:** pick `_selected_stream = _alarm_streams[randi() % size]`; ensure the AudioStreamPlayer3D
  (lazy-create), set its `stream = _selected_stream`, `play()`; connect its `finished` → `_on_alarm_finished`
  (one-shot connect, or check inside); set `_fallback_left = min(fallback_timeout_max, stream_length + 1.0)`
  if the length is readable else `fallback_timeout_max`; increment global cap + `_counted_in_cap=true`;
  `alarm_active=true`; `set_process(true)`; debug log (which variation, expected length).
- **`_process(delta)`** (runs only while active): advance `_blink_t`, toggle lights at `blink_hz`
  (`sin(_blink_t*TAU*blink_hz) > 0`, §8); `_fallback_left -= delta`; if `<=0` → `stop_alarm("fallback")`.
- **`_on_alarm_finished()`:** the normal path — `stop_alarm("finished")`.
- **`stop_alarm(reason)`:** stop + disconnect audio; turn flashing OFF and restore lights via the parent's
  `_refresh_lights()` (§8); release cap (if `_counted_in_cap`); `alarm_active=false`; `_selected_stream=null`;
  `_last_stop_ms = now`; `set_process(false)`; debug log (reason).
- Cooldown is **timestamp-based** (checked at trigger), so idle/cooling cars do zero per-frame work.
- **Stop happens when EITHER** the player's `finished` fires (normal) **OR** `_fallback_left` hits 0 (safety).
  Do **not** rely on `finished.connect(queue_free)` as the cleanup — `stop_alarm()` owns lights/cooldown/cap.
- **Re-hit policy (ignore-while-active):** while `alarm_active`, further hits are dropped (§5 step 2) — no
  sound restart, no variation switch, no blink restart, no run extension. After the sound finishes AND
  cooldown expires, a future hit starts a fresh run with a newly-rolled random variation.

---

## 7. Audio design

- `AudioStreamPlayer3D` only (never `AudioStreamPlayer`/2D), created lazily in `start_alarm()` (not for every
  parked car) and reused. Settings (3D conventions from the police siren, research §9/§11):
  - `bus = "SFX"`, `attenuation_model = ATTENUATION_INVERSE_DISTANCE`,
  - `unit_size = audio_unit_size` (~10), `max_distance = audio_max_distance` (~80),
  - `stream = _selected_stream` (the per-run random pick, §6).
- **Ownership is explicit and local to the HIT car:**
  - the `AudioStreamPlayer3D` is a **child of THAT parked car's `ParkedCarAlarm` component** (which is a child
    of the hit car) → its world position is the car's position and tracks it;
  - give it a small local offset near the cabin/engine (e.g. `position = Vector3(0, 0.8, 0)`), not the origin floor;
  - do **NOT** attach the alarm audio to the terrain generator, to any global/shared manager, to the
    player/camera, or to a 2D/global `AudioStreamPlayer`.
  - Each alarming car owns its own player → if several alarm at once, every sound emits from its own car
    position independently (verified in self-test).
- **PLAY ONCE — do NOT loop.** Do **not** set `AudioStreamMP3.loop = true` (the key difference vs the siren).
  Each alarm is one full pass.
- **Stop is event-driven:** connect the player's **`finished`** signal → `_on_alarm_finished()` →
  `stop_alarm("finished")`. **Do NOT use `finished.connect(queue_free)`** as the cleanup strategy — the
  component's own `stop_alarm()` must run so lights, cooldown, and the global cap are handled. A
  `_fallback_left` safety timeout (§6) also calls `stop_alarm("fallback")` if `finished` never fires.
- `stop()` the player on any `stop_alarm()` / `_exit_tree`.
- Distance behavior is guaranteed by AudioStreamPlayer3D + inverse-distance + `max_distance` (loud near,
  quiet mid, inaudible past ~80 m, never global). `max_distance` already silences distant ones.

---

## 8. Flashing lights design

**Primary (reuse `NPCCarLights`, present on every parked car via `_setup_lights` in NPCCar `_ready`):**
- The component grabs the parent's lights child (`NPCCar._lights`, an `NPCCarLights`). Its public API is
  `enable_lights()` / `disable_lights()` (toggle `.visible` on `headlight[_left/right]` SpotLight3D +
  `taillight*` OmniLight3D + the emissive `headlight_mesh*`/`taillight_mesh*` BoxMeshes; `_lights_enabled`
  guard; **not** internally day/night-gated — caller decides). Verified `night_mode/npc_car_lights.gd:709–747`.
- **Blink:** alternate `enable_lights()` / `disable_lights()` at `blink_hz` from the component's `_process`.
  The emissive headlight meshes (emission energy ~4) read clearly **in daylight**, satisfying day-visibility.
- **Lifecycle (lights follow the sound):** flashing runs **only while the selected sound plays**. The instant
  the sound finishes (or the safety timeout fires), `stop_alarm()` turns flashing OFF and restores the car's
  normal lights — no silent flashing continues, and the component's `_process` is disabled after cleanup.
- **Day/night override:** while alarm active, the alarm owns the lights (flashes regardless of NightMode).
  On `stop_alarm()`, call the parent's `NPCCar._refresh_lights()` to restore the correct night/day/rain state
  (parked car in day → lights back off).
- If a finer/cheaper blink is wanted, toggle the emissive meshes' material `emission_energy_multiplier`
  directly (traffic-light style) instead of whole-node visibility — optional refinement, same hook.

**Fallback (only if the merged mesh hides the lenses / lights aren't drivable — the police beacon hit this):**
- Component creates its own small additive emissive quads/boxes at the front (and optional rear), like the
  police beacon glow shell (`_make_beacon_glow_mat`: unshaded, `BLEND_MODE_ADD`, depth-draw off), plus an
  optional shadowless `OmniLight3D`. `cast_shadow = OFF`, `visibility_range_end ≈ 150–160`. No GLTF edits.

**Process gotcha (critical, research §3/§14):** the parent parked car has `set_process(false)`, so the blink
MUST run in the **component's own `_process`** (children keep independent process flags) — never the car's
`_process`. Only `alarm_active` components have `_process` on.

---

## 9. Global cap design

- **Mechanism:** a Godot 4 `static var _active_alarm_count := 0` on `ParkedCarAlarm` itself (shared across all
  instances; no manager needed — parked cars have no registry, research §12). Plus `static var max_active_alarms := 3`.
- **Flow (safety rules):**
  - At trigger (§5 step 5): reject if `_active_alarm_count >= max_active_alarms` (`reason=cap_full`).
  - **Increment only AFTER a successful `start_alarm()`**; set `_counted_in_cap = true` at the same moment.
  - **Decrement only if this component owns a slot** (`_counted_in_cap`). A slot is released in EVERY stop
    path: `stop_alarm("finished")` (normal — sound done), `stop_alarm("fallback")` (safety timeout),
    `_exit_tree()`/PREDELETE-while-active (car freed/chunk unload), and `force_all_..._off()`. Immediately
    clear `_counted_in_cap = false` so the slot can't be released twice (**guards double-decrement**).
  - **Clamp** after every decrement: `_active_alarm_count = maxi(0, _active_alarm_count)` (never < 0).
- **`force_all_parked_car_alarms_off()` must also REPAIR cap state:** stop every active component, then reset
  `_active_alarm_count = 0` (authoritative reset) so any drift is healed.
- **Debug audit:** `print_active_parked_car_alarm_count()` prints `_active_alarm_count` AND, where practical,
  a live recount of actually-active components found in the tree — flag a mismatch (catches a leaked/missed slot).
- Suggested `max_active_alarms = 3` (2–3 range).
- Alternative considered: counter on the terrain generator — rejected as needless coupling; the static var is
  simpler and self-contained.

---

## 10. Cleanup / unload behavior

- **Normal stop (timeout):** stop audio; restore lights via `_refresh_lights()`; release cap slot; start
  cooldown (`_last_stop_ms`); `set_process(false)`.
- **Chunk unload / car freed:** parked cars are `queue_free()`d wholesale with the chunk (research §2). The
  component is a **child**, so it is freed too. In `_exit_tree()` (and/or `_notification(NOTIFICATION_PREDELETE)`):
  stop + free the audio player; if `_counted_in_cap`, release the cap slot. → no dangling audio, no leaked cap.
- **No return-to-pool reset needed** (parked cars are freed, not pooled — unlike traffic NPCs).
- `is_instance_valid()` guards around the parent/lights before touching them in async/teardown paths.

---

## 11. Debug hooks

A `static var parked_car_alarm_debug := false` flag on `ParkedCarAlarm` (off by default) gating `[ALARM] ...`
prints. Mirror the police debug surface (research §17). Since there's no parked-car manager, **first choice**
is to expose the test entrypoints as **static functions** on `ParkedCarAlarm` (callable from MCP
`execute_game_script`), which locate parked cars by walking loaded chunks for nodes with a `ParkedCarAlarm`
child near the player.

**Fallback (if static methods are awkward from MCP, or can't reliably reach the running scene tree / loaded
chunk nodes):** expose the same debug methods as instance methods on the always-present
`osm/osm_terrain_generator.gd` (it already owns the chunks and parked cars), delegating to the component.
Do **not** add a new autoload/global manager just for debug. Decide which path works during STEP 0 and note it.

Entrypoints (on whichever host is chosen):

- `ParkedCarAlarm.force_nearest_parked_car_alarm_on()`
- `ParkedCarAlarm.force_all_parked_car_alarms_off()`
- `ParkedCarAlarm.print_active_parked_car_alarm_count()` (prints `_active_alarm_count` + per-car states)
- `ParkedCarAlarm.spawn_or_find_debug_parked_car_near_player()` (find nearest; if none, note it — spawning a
  standalone parked car is optional/secondary)
- `ParkedCarAlarm.simulate_alarm_impact_on_nearest_parked_car(speed)` (calls the trigger path with a synthetic speed)

Debug log points: component attached; collision detected; rejected (non_player / below_threshold / cooldown /
cap_full / already_active); alarm started (with rolled duration); alarm stopped; cap slot released; chunk-unload cleanup.

---

## 12. Self-test plan (in `res://main.tscn`, via godot-mcp; do not delegate to user)

Loop: `play_scene main.tscn` → drive/`execute_game_script` to force/inspect → `get_game_screenshot` /
read logs → `stop_scene` after each pass (energy memory). Use `parked_car_alarm_debug=true`.

0. **Both** alarm assets imported & loadable (`car_alarm_multitone.mp3`, `car_alarm_2.mp3`); pool size = 2
   (or report which is missing).
1. Parked cars still spawn normally (find a parking lot; confirm 0–2 cars).
2. Parked cars still block/collide physically (ram one; it resists/pushes).
3. Light scrape below threshold → **no** alarm (debug shows `below_threshold`).
4. Hard hit ≥ threshold → alarm starts (debug `alarm started` with the chosen variation name).
5. Alarm audio originates from the **hit** car — the `AudioStreamPlayer3D` is a child of that car's component,
   and its `global_position` equals the hit car's (not the player/camera/terrain-generator).
6. True 3D positional: stand next to that exact car → **loud**; move away → volume **fades**; past
   `max_distance` → **inaudible**. Confirm the source stays at the car as the player/camera moves (pan/volume
   track the car, not the listener).
7. Close = loud. 8. Medium = quieter. 9. Far (> max_distance) = inaudible. 10. Not global/city-wide.
10b. **Multi-car positions:** trigger two parked cars at once (if reachable) → each sound emits from its own
   car's position (different locations), not co-located/global.
11. Lights flash while active (screenshot mid-blink on + mid-blink off).
12. Flashing visible by day; re-check at night (`NightModeManager.enable_night_mode()`).
13. **Plays once, then stops:** the alarm runs one full pass of the chosen sound and stops — it does **not**
    loop forever (watch the `finished` log / verify it isn't restarting).
14. **Variation:** force several alarms; confirm random selection can pick **both** sounds over multiple runs.
15. **Lights stop on finish:** the instant the sound finishes, flashing stops, the car returns to normal
    day/night light state, and cooldown begins (debug `stop reason=finished`, then `cooldown`).
16. **Cap released on finish:** `_active_alarm_count` drops by one after the sound ends (`print_active_..._count`).
17. Re-hit during active alarm does **not** restart/switch/extend (debug `already_active`, audio keeps playing
    the same variation).
18. Cooldown blocks immediate re-trigger (debug `cooldown`); after cooldown a new hit rolls a fresh variation.
19. Global cap: trigger several lots; only ≤ `max_active_alarms` sound at once (`print_active_..._count`).
20. Chunk unload (drive away ~unload_distance) **during playback** stops sound + flashing + releases the cap;
    no dangling sound after the car disappears.
21. No relevant errors in the log.
22. No significant FPS/loading regression (PerformanceProfiler at a fixed viewpoint before/after).
23. Fallback safety: if `finished` is forced to not fire (or a 0-length read), the alarm still stops via the
    `_fallback_left` timeout (verify the safety net, e.g. via a debug-forced run).

Stop the scene after each visual/audio/log check.

---

## 13. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Blink put on the car's `_process` (dead, `set_process(false)`) | Blink in the **component's** `_process`; explicit comment + self-test #11. |
| Audio outlives the car | Child ownership + `stop()` in `_exit_tree`/PREDELETE (§10). |
| `finished` signal never fires → stuck alarm/lights | `_fallback_left` safety timeout also calls `stop_alarm("fallback")` (§6); self-test #23. |
| One asset missing | Pool drops it + logs; uses the other; both missing → no audio, code path intact (§3). |
| Day-off light gating hides the flash | Alarm drives `enable_lights`/`disable_lights` directly (not gated) and restores via `_refresh_lights` on stop (§8). |
| Merged mesh hides real lenses | Procedural additive-emissive fallback ready (§8). |
| Cap double-decrement (stop + exit_tree) | `_counted_in_cap` flag guards it (§9). |
| `VehicleBody3D.body_entered` doesn't fire reliably on parked cars | Prove in STEP 0 (§5); if it fails, swap to a player-only child `Area3D` — same rest of design. No scans. |
| `contact_monitor` on all parked cars = physics cost | Same pattern as clutter bins; `max_contacts_reported=4`; idle component `_process` off. Watch FPS in self-test #20. |
| False triggers from gentle bumps | Speed gate + single-fire guard + cooldown (§5/§6). |
| Audio spam | Global cap 2–3 (§9). |
| Parked police Lada wrongly using police siren | Component is generic; no police code path touched (§4). |
| `≈` line numbers in research (`_unload_chunk`, fence) | Re-confirm exact lines at implementation time. |

---

## 14. Exact v1 scope

**In:** generic `ParkedCarAlarm` child on every parked car; `body_entered` + player + speed-gate trigger;
**two** 3D alarm-sound variations (random pick per trigger) **played once through** (stop on `finished`, with
a safety-timeout net); rhythmic flashing of existing headlights/taillights **only while the sound plays**
(with procedural fallback); per-car cooldown (20–45 s); global cap (3); full cleanup on finish/stop/unload;
debug hooks; self-test in `main.tscn`.

**Out (future):** more than two sound variations; looping/continuous alarm; car-deformation/visual damage;
glass/debris; alarm "owner runs out and yells"; alarm auto-stop when the player drives far away (beyond
`max_distance` silence); moving-traffic reactions; persistence across chunk reload; haptics/HUD callouts.

---

## 15. What NOT to implement yet

Nothing is implemented until go-ahead. When greenlit, do not: import the MP3 before confirming the path;
hand-write the `.import`; touch car GLTFs; build a new global manager/autoload; add a per-frame scan over all
parked cars; ship the procedural-light fallback enabled if the real lights work; enable `parked_car_alarm_debug`
by default.

**Parked police (ДПС) Ladas stay ordinary:** do NOT connect this feature to the police emergency
siren/beacon system, and do NOT reuse `police-siren.mp3`. A parked ДПС Lada triggers the **same ordinary
car alarm** (one of `res://audio/sfx/car_alarm_multitone.mp3` / `car_alarm_2.mp3`) as every other parked car.

Also do NOT: loop the alarm sound; keep lights flashing after the sound finishes; add a third+ variation;
make the fixed timeout the primary stop (it is a safety net only).

---

**Ready for implementation: yes** (pending your go-ahead — per the plan-don't-implement rule).

**Recommended implementation sequence:**
1. **STEP 0 — collision proof FIRST (§5):** spawn integration with `contact_monitor`/`max_contacts_reported`
   + `body_entered` + a player-only log; run `main.tscn`, ram a parked car, confirm the event fires. If it
   doesn't, switch to the child `Area3D` fallback and re-verify. Also decide the debug-host (component-static
   vs terrain-generator, §11) here. **Do not proceed until the event is proven.**
2. Import **both** MP3s (§3) to `car_alarm_multitone.mp3` / `car_alarm_2.mp3`; verify each plays once cleanly
   and note its length.
3. Write `traffic/parked_car_alarm.gd`: variation pool load, trigger handler with all gates + debug logs,
   `start_alarm` (random pick + `finished` connect + fallback timeout), `_on_alarm_finished`, `stop_alarm`,
   static cap (clamp + `_counted_in_cap`), `_exit_tree` cleanup — **audio first** (no lights yet). Headless-lint.
   Self-test #0–10, 13–14, 16–20, 23 (trigger + 3D audio + play-once + variation + cap + cleanup + cooldown + fallback).
4. Add flashing lights via `NPCCarLights` (§8). Self-test #11–12, 15 (flash + stop-on-finish + restore). Add
   procedural fallback only if the real lights aren't visually usable (document why if so).
5. Finish debug hooks incl. the cap audit (§9/§11). Full self-test #0–23 in `main.tscn`. Tune
   `trigger_speed`/`blink_hz`/distances.
6. Report (per §"Final report" additions: both source/target paths, availability, selection, play-once,
   finished→cleanup, fallback value, lights-stop proof, cap-release proof, deviations); commit on request.

**Final report additions (v1.2):** both source asset paths found; both imported target paths; whether both
variations were available; how random selection works; that sounds play once (not loop); how `finished`
triggers cleanup; the fallback timeout value; proof lights stop when the sound finishes; proof the cap is
released on finish; any missing asset or deviation.

**Potential blockers:**
- If `NPCCar._lights` isn't reachable or the merged mesh hides lenses → use the procedural fallback (already planned).
- If `AudioStreamPlayer3D.finished` is unreliable → the `_fallback_left` safety timeout covers it (§6).
- None expected to block reaching a working v1.
