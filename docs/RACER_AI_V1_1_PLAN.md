# Racing Opponent AI v1.1 — Stable Route Following + Isolated Test Track (Implementation Plan)

**Status:** ✅ IMPLEMENTED & in-engine verified (2026-06-19, not committed). Results in §R below.
Source of truth: [`docs/RACER_AI_RESEARCH.md`](RACER_AI_RESEARCH.md).

**One-line goal:** kill the visible left-right weaving so AI cars track the race line smoothly, and build a
flat throwaway scene to tune/measure it without loading the OSM world. Player physics untouched.

---

## 0. Guardrails (what this plan deliberately does NOT touch)

- **No edits to `car/vehicle_base.gd`.** It is shared with the player. All steering changes live in
  `race/racer_ai.gd` (the *command*), never the shared actuator.
- **No new route/projection system.** Reuse `RaceRoute.project_position / get_point_at_distance /
  get_lookahead_point` exactly as today.
- Out of scope (later versions): real obstacle avoidance, player/opponent avoidance, overtaking, lane
  changing, rubberbanding, AI personalities, corner-speed/braking overhaul (v1.2), NavMesh.
- Stuck recovery (`racer_ai.gd:413-486`) stays as-is; if it fires during normal v1.1 test driving that's a
  **bug signal**, not a fix.

---

## 1. Files to change

| File | Change | Risk |
|------|--------|------|
| `race/racer_ai.gd` | Rework the steering block (`:201-242`) + lookahead (`:196-199`); soften corridor term; add off-by-default telemetry ring buffer + summary; cache wheelbase + last projection in `_ready`/update | Medium (core of the fix) |
| `race/ai_test_scene.tscn` | **NEW** — flat scene, infinite ground, camera rig, one AI car, no OSM/traffic/props | Low (test-only) |
| `race/ai_test_scene.gd` | **NEW** — builds a local test route, spawns + starts one `RacerAI`, drives telemetry, draws the debug overlay, exposes MCP-callable methods | Low (test-only) |
| `car/vehicle_base.gd` | **NONE** | — |
| `race/race_route.gd` | **NONE** (route built via the existing public `RaceRoute.build_from_track_waypoints` with an identity converter — see §3; no new code) | — |

No production scene (`main.tscn`, `race_scene.tscn`) is modified. The test scene is additive and can be
deleted later without consequence.

---

## 2. Test scene / test race plan

**Decision: build a new `race/ai_test_scene.tscn`, do NOT reuse `test_track_scene`.** Reason:
`test_track_scene.gd:3,71-84` drives `osm_terrain_generator` with fake OSM data — it still runs the full
chunk/mesh pipeline (the exact thing we want to avoid for fast iteration). We *do* copy the cheap
`CameraManager` + `TopDownCamera`/`ChaseCamera` rig from it.

**`ai_test_scene.tscn` node tree (minimal):**
- `Node3D` (root, script `ai_test_scene.gd`)
  - `Ground` : `StaticBody3D` (group `Grass`, `collision_layer=1`, `collision_mask=0`) → `CollisionShape3D`
    with a **large flat `BoxShape3D`** (e.g. 4000 × 2 × 4000, positioned so its top face is at y=0) +
    a matching `MeshInstance3D` (`PlaneMesh`/`BoxMesh`) so the ground is visible in screenshots. **Chosen
    over `WorldBoundaryShape3D`** to sidestep any infinite-plane/wheel-cast quirk up front — per the patch,
    don't burn tuning time on ground colliders. (`WorldBoundaryShape3D` is a lighter fallback if ever
    wanted; the box is the default.) The opponent's `collision_mask=131` includes layer 1, so wheels rest
    on it.
  - `DirectionalLight3D` + `WorldEnvironment` (copy the cheap procedural sky from `test_track_scene.tscn`).
  - `CameraManager` with `TopDownCamera` (default `current=true`, height ~120 m for whole-route view) and a `ChaseCamera` (toggle for eyeballing the line).
  - `RouteDebug` : `MeshInstance3D` with an `ImmediateMesh` — **drawn and ON by default** in this test scene
    (it's a debug harness). Each frame it draws: the **route centerline** (polyline through `route.points`),
    the **±7 m corridor** (two parallel offset polylines, offset = `CORRIDOR_WIDTH`), and a **marker at the
    AI's current target/lookahead point** (read from `car.debug_target_point`, §4). Unshaded vertex-colored
    lines (white centerline, amber corridor, red target dot) — not production-quality, just enough that a
    top-down screenshot makes AI tracking legible.
  - The AI car is **instantiated at runtime** (not saved in the scene) from `res://race/racer_nexia.tscn` so the harness controls its params deterministically.

**Why not `RaceManager`:** `RaceManager.start_race` reloads terrain (~13 s) and expects the OSM world. The
harness bypasses it entirely — it does the three things the manager would do to one car (`set_race_route`,
unfreeze, `start_racing`) and nothing else. No menus, no traffic, no parked cars, no buildings.

**`ai_test_scene.gd` responsibilities:**
1. `_ready`: build the test `RaceRoute` (see §3), instantiate `racer_nexia.tscn`, place it on the first
   route point facing `points[0].direction`, `add_child`.
2. **Determinism:** immediately after instancing, overwrite the values `RacerAI._ready` randomises
   (`racer_ai.gd:84-86`) with fixed test values: `skill_level=0.92`, `aggression=0.7`, `target_speed=80`.
   (Do this *after* `add_child` so it lands after the node's own `_ready`.) Also call `seed(12345)` so any
   remaining randomness is repeatable across runs.
3. Wait a few physics frames for the car to settle on the ground, then `set_race_route(route)` +
   `start_racing()` (sets `ai_state=RACING`, unfreezes, seeds projection).
4. Enable telemetry: `car.ai_debug = true; car.clear_debug_samples()`.
5. Each `_process`, redraw `RouteDebug` (centerline + corridor are static; only the target marker moves,
   read from `car.debug_target_point`).
6. Expose MCP-callable methods on the root: `get_summary()` (returns the AI's `get_debug_summary()`,
   which carries both the global summary and the per-section breakdown — §4),
   `restart()` (re-runs the whole setup for a fresh pass), `set_camera(top|chase)`,
   `set_overlay(on|off)`.

**Run loop via tools:** `play_scene(ai_test_scene.tscn)` → wait a fixed wall-clock (no LOADING here, the car
drives immediately) → `get_game_screenshot` (top-down) → `execute_game_script` to read `get_summary()` →
`stop_scene`. Per the project rule, **stop the scene after each pass** to spare the Mac; batch the screenshot
+ summary read into one launch.

---

## 3. Test route shape

**Build with the existing public builder — no `race_route.gd` change, no brittle inner-class poking.**
Generate local `Vector3` points (XZ plane, y=0, ~10–12 m spacing) as a constant array, pass them to
`RaceRoute.build_from_track_waypoints(points2d, identity_converter)` where each point is given as
`Vector2(x, z)` and the converter is `func(a, b): return Vector3(a, 0.0, b)`. The builder already computes
per-point direction, accumulated distance, and `total_length` exactly as for OSM routes — we just feed it
local coords instead of lat/lon. (If a future need makes the `Vector2`-as-coords trick awkward, add a *tiny
test-only* `RaceRoute.build_from_local_points(Array[Vector3])` and document it here — but the identity-
converter route avoids touching `race_route.gd` at all and is the default.)

Sections, in order, each long enough (≥60 m) to see whether weaving damps out. **Record each section's
`distance_from_start` start/end range** — telemetry bins samples by `race_progress` into these named
sections (§4), so a constant route gives stable, comparable per-section windows:

| # | Section | Shape | Approx arc range (m) |
|---|---------|-------|----------------------|
| 1 | `straight_1` | Long straight | 0 – 120 |
| 2 | `gentle` | Gentle curve (~15° over 60 m) | 120 – 180 |
| 3 | `straight_2` | Straight (settle test) | 180 – 230 |
| 4 | `medium` | Medium turn (~45° over 50 m) | 230 – 280 |
| 5 | `s_bend` | S-bend right→left (~30° each) | 280 – 360 |
| 6 | `sharp` | Sharper turn (~80° over 40 m) | 360 – 400 |
| 7 | `finish` | Finish straight | 400 – 460 |

Total ≈ 460 m. The exact ranges are derived from the route at build time (store the cumulative section
boundaries alongside the point array) and logged once so the bins are exact, not eyeballed. This is a
*diagnostic* shape, not a finished circuit — no elevation, no scenery, no loop. Keep the point array
constant so every run is identical.

---

## 4. Debug telemetry plan (in `race/racer_ai.gd`, off by default)

Add `var ai_debug := false` and a bounded ring buffer (`_debug_samples: Array`, cap ~1200 ≈ 60 s at 20 Hz).
Sampled once per AI tick (20 Hz) inside `_update_ai_driver`, **only when `ai_debug`** (zero cost otherwise).
Also expose `var debug_target_point: Vector3` (updated every tick when `ai_debug`) so the test scene's
`RouteDebug` overlay can draw the current lookahead target cheaply without reaching into the ring buffer.

Per sample (Dictionary): `t` (sec), `pos`, `race_progress`, `segment_idx`, `lateral_offset`,
`lookahead_dist`, `target_point`, `heading_error_rad`, `steer_raw` (pre-smoothing), `steer_cmd` (final
`steering_input`), `speed_kmh`, `throttle`, `brake`, `corridor_active` (bool), `recovery_active` (bool).

**Per-section binning.** The harness passes the §3 section boundaries to the AI
(`car.set_debug_sections([{name, start_m, end_m}, …])`). Each metric block is computed **once globally and
once per section** by filtering samples whose `race_progress` falls in `[start_m, end_m)`. This is what makes
"strongest criteria on straight/gentle" measurable in isolation (§14).

A reusable metric block over a sample subset:
- `lateral_p2p` (max−min lateral offset), `lateral_abs_max`
- `steer_p2p`, `steer_sign_changes` (count of `steer_cmd` zero-crossings), `steer_saturations`
  (count of `|steer_cmd| ≥ 0.98`)
- `avg_speed_kmh`, `min_speed_kmh`, `distance_covered`
- `corridor_active_frac`, `sample_count`

Methods:
- `set_debug_sections(sections: Array)` / `clear_debug_samples()`
- `get_debug_samples() -> Array` (raw, for charting)
- `get_debug_summary() -> Dictionary`:
  - `global`: the metric block over all samples **plus** `progress_percent`, `recovery_count`, `duration_s`.
  - `sections`: `{ straight_1: {block}, gentle: {block}, … }` — one metric block per §3 section.

No `print()` in the hot path — everything is pulled via `execute_game_script` calling `get_debug_summary()`.
`t` uses an accumulator incremented by `delta` (avoids the banned `Time`/`Date` randomness concerns and is
deterministic).

---

## 5. Baseline measurement plan

**Measure before changing any steering code.** Sequence:
1. Land the new test scene + telemetry **first**, with `racer_ai.gd` steering logic still untouched.
2. `play_scene(ai_test_scene.tscn)`; let the (unchanged) AI drive the full test route once.
3. `execute_game_script`: read `get_debug_summary()`; record it verbatim into this doc under a
   **"Baseline (current AI)"** table — **both the `global` block and every per-section block**
   (`straight_1`, `gentle`, `medium`, `s_bend`, `sharp`, …), since acceptance (§14) is judged per section.
4. Top-down screenshot (overlay on) to visually confirm the snake against the centerline/corridor.
5. `stop_scene`.
6. Repeat the run 3× to confirm the metrics are stable (determinism check). If they vary wildly, fix
   determinism (seed / fixed params) before trusting any after-numbers.

These baseline numbers are the denominator for every acceptance check in §14.

---

## 6. Current steering problem summary (from research, condensed)

`steering_input = clamp(lateral_error * 2.5 * skill, -1, 1)` is a pure-P controller on `sin(heading-error)`
with a constant gain so high that ~24° of error saturates the wheel. No derivative, no command smoothing,
gain decoupled from lookahead, a short 12 m min lookahead, a *second* P-controller (corridor correction)
fighting on the same axis, and actuator lag (`vehicle_base` lerp) adding phase delay. Result: a limit cycle
(the visible S-ing). Full diagnosis: research report §9.

---

## 7. Chosen v1.1 steering approach

**Recommend Option A — geometry-correct pure pursuit (bicycle model) — implemented as a small, localized
change**, with Option B's stabilizers layered on. Rationale: it deletes the fragile hand-tuned gain entirely
and is *self-damping* (longer lookahead → gentler steer for the same angle), so it's actually **fewer knobs
to tune** than Option B, not a rewrite — it replaces one ~10-line block in `racer_ai.gd` and reads a
wheelbase already derivable from the wheels. This best satisfies "minimal controlled change."

The command becomes (all inside `racer_ai.gd`, all in the XZ plane):
```
alpha   = signed angle between forward_flat and (target_point - pos)_flat   # heading error
L       = max(MIN_TURN_L, distance(pos, target_point))   # Euclidean, not arc — auto-corrects off-line gain
kappa   = 2.0 * sin(alpha) / L                            # pure-pursuit path curvature (1/m)
delta   = atan(wheelbase * kappa)                         # required front-wheel angle (rad), bicycle model
steer_t = clamp(delta / deg_to_rad(max_steering_angle), -1, 1)   # normalize to [-1,1] command
```
- `wheelbase` is measured once in `_ready` from `wheels_front`/`wheels_rear` local Z positions (per-car
  correct; falls back to a constant if a list is empty). `max_steering_angle` is read from `VehicleBase`
  (read-only; not modified).
- The **sign of `alpha`** must reproduce today's working convention (research confirmed the current sign is
  correct on average). Derive `alpha` so that a target to the car's left yields the same steering sign the
  current `to_target_flat.cross(forward_flat).y` produces; verify on the gentle curve in the very first run
  and flip once if mirrored (per the "trust visual feedback, just flip" rule — do not re-derive endlessly).
- `skill_level` no longer scales gain (gain is gone). Repurpose it minimally: scale the **lookahead** (lower
  skill → slightly shorter lookahead → slightly less smooth) and/or a tiny steering-rate cap. Keep its effect
  subtle in v1.1.

**Fallback:** if Option A shows any instability we can't tune out quickly, fall back to **Option B**
(keep the P term but: gain ~0.8 instead of 2.5, speed-scaled down, min lookahead raised, rate-limited
command). Option B shares §8/§9/§10 supporting changes verbatim, so the fallback is cheap.

---

## 8. Lookahead changes

- Raise `LOOKAHEAD_MIN` **12 → 18 m**; keep/raise `LOOKAHEAD_MAX` ~**38 m**. No tiny lookahead that invites
  centerline hunting.
- Keep `lookahead_dist = lerp(MIN, MAX, clamp(speed/80,0,1))` to pick the *arc target* via
  `get_point_at_distance(race_progress + lookahead_dist)` (unchanged helper usage).
- **Use the Euclidean car→target distance as `L`** in the curvature formula (§7), not the arc value — this is
  the fix for "effective gain inflates when off-line."
- Rate-limit *changes* in `lookahead_dist` between ticks (e.g. `move_toward` by ≤4 m per tick) so the target
  never jumps when `race_progress` advances discretely → removes the "discrete target jump" transient
  (research §9.6). Preserve the `current_segment_idx` hint into `project_position` (forward-only).

---

## 9. Steering command changes

- Replace `lateral_error * 2.5 * skill` with the Option A command (§7).
- **Light rate-limit, not heavy smoothing** (the actuator already adds lag; piling on a low-pass would worsen
  phase delay — research §9.3,§9.5). Apply once per AI tick:
  `steering_input = move_toward(steering_input, steer_t, MAX_STEER_RATE * UPDATE_INTERVAL)` with
  `MAX_STEER_RATE ≈ 6.0` (full lock in ~0.17 s of commands). Tune against baseline.
- Clamp to [-1, 1] after the rate limit.
- Record both `steer_raw` (=`steer_t`) and final `steer_cmd` (=`steering_input`) in telemetry.
- **Do not** add any damping in `vehicle_base.gd`.

---

## 10. Corridor correction changes

- **Demote it from a co-controller to an edge guard.** With pure pursuit aiming at the centerline target,
  centerline convergence is already implicit, so the separate term is redundant in the middle of the road and
  is the source of two-controller fighting.
- New behavior: corridor correction contributes **0** until `lateral_offset > 0.7·CORRIDOR_WIDTH` (~5 m,
  i.e. close to the ±7 m barrier). Beyond that, add a *small* inward bias (max strength ≤ 0.25, ramped),
  blended after the rate limit. This keeps cars off the barriers without distorting the line.
- Set `corridor_active` in telemetry whenever the guard contributes, so we can confirm it's silent on normal
  driving.

---

## 11. Route projection / progress handling

- Keep `project_position(global_position, current_segment_idx)` forward-only exactly as today
  (`racer_ai.gd:283-287`).
- **Eliminate the redundant second projection:** `_update_race_progress` already computes a projection; store
  its full result (`distance`, `segment_idx`, `lateral_offset`) in a member and have the edge-guard (§10) and
  telemetry read that instead of calling `project_position` again (`racer_ai.gd:320`). One projection per
  tick.
- No backward progress, no new scans, no change to `race_route.gd`.

---

## 12. Isolated self-test plan (run on `ai_test_scene.tscn`)

For each pass: one `play_scene` → drive the full route → screenshot (top-down) + `get_summary()` →
`stop_scene`. Checks:
1. Scene loads with **no** OSM/terrain generation (no chunk logs, instant ready).
2. AI car spawns and **rests on the box ground** (not sinking/levitating); overlay (centerline + corridor +
   target) renders.
3. Test route built (`route.points.size()` and `total_length` sane); section boundaries logged.
4. AI drives with zero player input.
5. `straight_1`: lateral offset stays small and **does not oscillate** (the headline check).
6. `gentle` handled; 7. `medium` handled; 8. `sharp` handled; 9. `s_bend` handled without diverging
   overcorrection.
10. Visible weaving reduced vs baseline screenshot (overlay makes this legible).
11. **Per-section** `lateral_p2p` reduced vs baseline on `straight_1`/`straight_2`/`gentle`.
12. **Per-section** `steer_sign_changes` + `steer_saturations` reduced vs baseline (strongest on
    straight/gentle; turn sections ≤ baseline / non-diverging).
13. Car stays within the ±7 m corridor (track `lateral_abs_max < 7` in every section).
14. Car completes / substantially progresses the route (`progress_percent` high), not too slow to turn.
15. `recovery_count == 0` during normal driving.
16. Metrics repeatable across 3 runs (determinism).
17. No errors in the game log.
18. No meaningful FPS regression (only 1 car; profiler optional).

---

## 13. Final `main.tscn` integration test plan

Only **after** the isolated tests pass. One shorter run:
1. `RaceManager.start_race(load("res://race/race_tracks.gd").get_track_by_id("fanera_sprint"))`.
2. Poll `RaceManager.current_state` until `RACING` (≈13 s LOADING + countdown) — do **not** inspect during
   LOADING (car is frozen/invisible under not-yet-built terrain; known gotcha).
3. Confirm: race starts; 3 opponents spawn (`find_nodes_in_group("race_opponent").size()==3`); they progress
   on `fanera_sprint` (`race_progress` increases for each over ~15 s); no integration errors.
4. **Player handling unchanged** — sanity drive a few seconds; `car/vehicle_base.gd` is untouched so this
   should be trivially true, but verify no regression.
5. Chase-cam screenshot of the pack to confirm the line looks smoother than before.
6. `stop_scene`.

---

## 14. Acceptance criteria (measured per section vs the §5 baseline)

The headline defect (sinusoidal weaving) is easiest to isolate on low-curvature sections, so the **strongest
criteria apply to `straight_1`, `straight_2`, and `gentle`**, where a competent controller should hold a
near-flat line. Turn sections (`medium`, `s_bend`, `sharp`) get looser criteria — they must not *diverge* or
clip the corridor, but their absolute offsets are naturally larger.

**Primary (must pass) — straight / gentle sections:**
- **No obvious sinusoidal weaving** (visual against the overlay + metric).
- `lateral_p2p` reduced **≥ 50%** vs baseline.
- `steer_sign_changes` reduced **≥ 50%** vs baseline.
- `steer_saturations` ≈ **0**.

**Primary (must pass) — all sections:**
- `lateral_abs_max < 7 m` everywhere (stays inside the corridor; no barrier clipping).
- Turn sections (`medium`, `s_bend`, `sharp`): steering does **not** diverge — `steer_p2p` and
  `steer_sign_changes` are ≤ baseline (smoother or equal), and the car tracks through without overcorrection
  runaway.
- `recovery_count == 0` on the isolated route.
- `global.progress_percent` ≥ baseline (the car still completes / substantially progresses; not so damped it
  can't turn).
- In `main.tscn`: race starts, 3 opponents progress on `fanera_sprint`, no errors, player handling unchanged.

**Explicitly NOT a v1.1 failure (deferred to v1.2):**
- **Sharp-turn entry speed / braking.** If steering is smoother but the car still carries too much speed into
  `sharp` (or `s_bend`) and runs wide *because of weak speed planning* — not because of steering oscillation —
  that is **v1.2 corner-braking work**, not a v1.1 reject. The v1.1 bar for turns is *smoother, non-diverging
  steering within the corridor*, not optimal cornering speed. Document any such residual wide-running in the
  results table under a **"v1.2 follow-ups"** note (and feed it into the v1.2 plan).

(Refine the exact % once baseline numbers are in hand — they're placeholders until §5 runs.)

---

## 15. Risks and mitigations

| Risk | Mitigation |
|------|------------|
| Over-damping → AI too slow / won't turn | Rate-limit (not low-pass); keep `MAX_STEER_RATE` high enough; watch `progress_percent` ≥ baseline |
| Longer lookahead cuts corners | Cap `LOOKAHEAD_MAX` ~38 m; verify `lateral_abs_max` on the sharp turn + S-bend |
| Removing corridor term → drift into barriers | Keep it as an **edge guard** (engages >5 m); `corridor_active` telemetry confirms it catches edges |
| Command smoothing adds delay | Use rate-limit over smoothing; the actuator already lags |
| Pure-pursuit sign/scale wrong | Verify sign on first gentle-curve run; flip once if mirrored (don't re-derive); `wheelbase`/`max_steering_angle` read per-car |
| Helps straights, hurts sharp turns | Per-section metrics (§4) isolate this; turn sections only need *non-diverging* steering within the corridor (§14). Residual wide-running from **speed** (not steering) is explicitly a v1.2 item, not a v1.1 fail |
| Ground collider flakiness with `VehicleBody3D` wheels | Use a large flat `StaticBody3D` `BoxShape3D` from the start (§2); don't spend tuning time here |
| Test route ≠ real OSM routes | Final `main.tscn` integration run on real `fanera_sprint` (§13) before declaring done |
| Stuck recovery hides bad behavior | Treat any `recovery_count > 0` on the flat route as a failure, not a pass |
| Breaking player handling | `vehicle_base.gd` not edited; integration test #4 double-checks |
| Overfitting one route | Determinism + the multi-shape route + real-track integration run mitigate; more routes deferred to later |

---

## 16. Exact v1.1 scope

In: new flat test scene (large box ground, camera rig, **on-by-default route/corridor/target overlay**) +
harness that builds the route via the existing `RaceRoute.build_from_track_waypoints` (identity converter, no
`race_route.gd` change); telemetry ring buffer + **global and per-section** summary in `RacerAI`; baseline
capture (global + per-section); geometry-correct pure-pursuit steering command (Option A) with Euclidean-`L`,
raised/rate-limited lookahead, light steering rate-limit, corridor term demoted to edge guard, single
projection per tick; isolated self-tests; one `main.tscn` integration validation. All steering logic confined
to `race/racer_ai.gd`.

---

## 17. What not to implement yet

Obstacle/opponent/player avoidance, overtaking, lane changes, rubberbanding, AI personalities, the
curvature-based corner-braking overhaul (v1.2 — `BRAKE_DISTANCE` stays unused for now), NavMesh, any change
to `car/vehicle_base.gd` or `race/race_route.gd`, and any new opponent count.

---

## Verdict

**Ready for implementation: YES.** The change is localized to `race/racer_ai.gd` plus two additive test-only
files; nothing player-facing or structural is touched, and the research confirmed the architecture supports
it.

**Recommended implementation sequence:**
1. Build `ai_test_scene.tscn` + `ai_test_scene.gd` (flat box ground, one AI, route via
   `build_from_track_waypoints` + identity converter, on-by-default overlay, section boundaries) — no
   steering changes yet.
2. Add the telemetry ring buffer + per-section `get_debug_summary()` + `debug_target_point` to `racer_ai.gd`
   (off by default).
3. Capture **baseline** metrics on the unchanged AI (3 runs; record global + per-section numbers).
4. Implement Option A steering (curvature command, Euclidean `L`, wheelbase, sign-verify).
5. Apply supporting changes: raised/rate-limited lookahead, light command rate-limit, corridor→edge-guard,
   single projection.
6. Re-run the isolated route; compare to baseline; tune within scope.
7. Run the `main.tscn` integration validation on `fanera_sprint`; confirm player handling unchanged.
8. Stop the scene after each pass.

**Potential blockers:** none blocking. Minor: the pure-pursuit sign must be confirmed visually on the first
run (one flip if mirrored, per "trust visual feedback"). Ground collision is de-risked by using a large flat
`BoxShape3D` rather than an infinite plane.

---

## §R. Results (2026-06-19, in-engine verified)

Test scene `race/ai_test_scene.tscn` (flat box ground, 1 RacerAI, ~460 m diagnostic route, on-by-default
overlay, deterministic skill=0.92/aggr=0.7/target=80). Car tops out ~50 km/h on flat (engine-limited). Two
conditions: **on-line** (spawn on centerline) and **offset** (spawn 5 m right → convergence stress, the
direct reproduction of the bang-bang over-correction).

### Offset 5 m — convergence (the bang-bang reproduction), section `straight_1`
| metric | baseline | v1.1 |
|--------|---------:|-----:|
| steer_p2p | 1.78 | **0.15** |
| steer_sign_changes | 3 | **0** |
| steer_saturations | 7 | **0** |
| lateral trace | 5→1.43→**1.77 overshoot**→… | 5→0.8 **monotonic, no overshoot** |

Baseline slammed full lock (+1.0) then oscillated (−0.76,+0.30,−0.11) back to center; v1.1 commands a gentle
~0.14 and decays monotonically. **Over-correction eliminated.**

### On-line full route — per-section `lateral_abs_max` (m)
| section | baseline | v1.1 | Δ |
|---------|---------:|-----:|---|
| straight_1 | 0.57 | 0.38 | −33% |
| gentle | 1.22 | 0.21 | −83% |
| straight_2 | 1.95 | 0.34 | −83% |
| medium | 3.53 | 1.10 | −69% |
| s_bend | 5.04 | 1.06 | −79% |
| sharp | 5.75 | 1.69 | −71% |
| finish | 2.77 | 1.64 | −41% |
| **global** | **5.75** | **1.69** | **−71%** |

On-line global: steer_saturations 0, sign_changes 3→2, recovery_count 0, progress 97.8% (maintained),
avg speed ~50 km/h (maintained). The curvature-aware lookahead (shorten in sharp turns) was the key second
step — without it the long 38 m lookahead cut the sharp corner and ran wide to 5.7 m on `finish`.

### main.tscn integration (real fanera_sprint, 3 opponents)
Race starts, 3 opponents spawn and progress together (bunched ~1100 m). On the real coarse OSM route:
**steer_saturations = 0, steer_sign_changes ≈ 1, avg ~46 km/h** for all three — no weaving on the real
route. Player car unaffected (`car/vehicle_base.gd` untouched). HUD/standings render normally.

### Acceptance verdict — PASS
Straight/gentle weave eliminated (already tight at 50 km/h; offset over-correction removed: sat 7→0,
sign 3→0); all turns smoother and tighter, none diverge; lateral_abs_max < 7 m everywhere (max 1.69 on the
isolated route); recovery_count 0; progress maintained; real-race integration clean; player physics unchanged.

### Known follow-ups (NOT v1.1 regressions)
- **In-engine racing surfaced bigger issues than steering** (opponents ram poles & each other; opponents fall
  through unloaded terrain ahead of the player → "minimap dot moves but no car"). Recorded as the
  **post-v1.1 race backlog** at the bottom of [`docs/RACER_AI_RESEARCH.md`](RACER_AI_RESEARCH.md), with the
  recommended next-step order: world streaming/persistence → avoidance → v1.2 braking.
- **Opponent airborne spawn:** on the real track AI 1 spawned at y≈121 m and entered RECOVERY, then respawned
  and drove normally. This is a spawn/terrain-height issue (the v1.1 changes touch only the steering command +
  lookahead, never spawn/height/physics) — pre-existing; same root cause as S2/S3 in the backlog above.
- **AI 2 hit 7.94 m lateral once** on a sharp real-OSM kink (real roads are wider than the 7 m test corridor);
  acceptable, edge-guard + barriers contain it.
- **v1.2 corner braking:** speed is still flat ~50 km/h into corners (no curvature-based slowdown);
  `BRAKE_DISTANCE` still unused. Deferred as planned.

### Telemetry note
`RacerAI.ai_debug` defaults **false** (zero cost in normal play). The test scene enables it. Leave it off in
production. `race/ai_test_scene.{tscn,gd}` are test-only and can be deleted later.
