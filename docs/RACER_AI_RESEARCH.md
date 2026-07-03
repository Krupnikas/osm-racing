# Racing Opponent AI — Research Report

**Scope:** factual analysis of the current racing-opponent AI. No code/scene/asset changes were
made. All references are `file:line`. Ends with a readiness verdict + recommended v1 scope.

---

## 1. Files inspected

| File | Role |
|------|------|
| `race/racer_ai.gd` | The whole AI driver (steering, throttle/brake, avoidance, stuck recovery) |
| `car/vehicle_base.gd` | Shared vehicle physics: turns steer/throttle/brake inputs into motion (player + AI) |
| `race/race_route.gd` | Route geometry: `project_position`, `get_point_at_distance`, `get_lookahead_point` |
| `race/race_manager.gd` | Opponent spawn, route assignment, countdown/start, finish order |
| `race/race_tracks.gd` | Track definitions (waypoints + dense route points) |
| `race/race_grid.gd` | Starting-grid position math |
| `race/race_barriers.gd` | ±7 m corridor barriers + `G` visibility toggle |
| `traffic/npc_car.gd` | (Comparison only) traffic NPC AI — separate system |
| `race/test_track_scene.{tscn,gd}` | Flat test track (no OSM) |

---

## 2. How opponents are spawned

- `race/race_manager.gd:442` `_spawn_opponents()`. Count = `OPPONENT_COUNT := 3` (`race_manager.gd:17`).
- Scenes cycled from `OPPONENT_SCENES` (`race_manager.gd:12`): `racer_nexia.tscn`, `racer_vaz2107.tscn`,
  `racer_logan.tscn`, chosen by `i % size` (`race_manager.gd:468`).
- Grid placement from `race/race_grid.gd` (`calculate_positions`, `race_manager.gd:459`).
- Each opponent: `set_race_route(route)` then `freeze_for_countdown()` (`race_manager.gd:496`), stored in
  `_opponents` (`race_manager.gd:65`, append at `:502`). Added to group `"race_opponent"` (`racer_ai.gd:81`).
- Naming: `racer_name` export (default `"AI"`, `racer_ai.gd:23`); manager assigns `"AI 1/2/3"`.
- Finish order: `_finish_order` array in `race_manager.gd` (player name `"Игрок"`), consumed by the HUD
  standings (`get_live_standings`).

---

## 3. Opponent node / body / controller type

`RacerAI extends VehicleBase extends VehicleBody3D` (`racer_ai.gd:1`, `vehicle_base.gd:1`). So opponents are
**Godot `VehicleBody3D`** — the same physics base the player uses. The AI script *is* the root of each
opponent scene. AWD is forced on (`racer_ai.gd:63-66`: all 4 wheels `use_as_traction = true`).

- `collision_layer = 128` (bit 7 → "RaceOpponents"), `collision_mask = 131` (Player+Buildings+Terrain).
- AI raycast `collision_mask = 2 | 8` (Buildings + NPC traffic) — **explicitly excludes other opponents**
  (`racer_ai.gd:73`) **and the player** (Player = layer 1, not in `2|8`).

---

## 4. How the route is assigned

- The manager builds one `RaceRoute` (via `RaceRoute.build_from_track_waypoints`, `race_route.gd:29`) and
  hands the same instance to every opponent through `set_race_route()` (`racer_ai.gd:123`).
- At green light, `start_racing()` (`racer_ai.gd:138`) seeds `current_segment_idx` / `race_progress` by
  projecting the spawn position once (`racer_ai.gd:147-151`). This seeding is essential — without it the car
  starts at `progress = 0` and the projection can latch backward.

---

## 5. Current route-following algorithm

Runs inside `_update_ai_driver()` every `UPDATE_INTERVAL = 0.05` s (20 Hz) (`racer_ai.gd:99-102`,`179`):

1. `_update_race_progress()` — `project_position(global_position, current_segment_idx)`, **forward-only**:
   progress/segment advance only if `projection.distance > race_progress` (`racer_ai.gd:283-287`).
2. Finish check `race_route.is_finished(race_progress)` (`racer_ai.gd:191`).
3. **Pure-pursuit target:** `speed_factor = clamp(speed/80, 0, 1)`,
   `lookahead = lerp(12, 35, speed_factor)` (`racer_ai.gd:196-197`), then
   `lookahead_point = get_lookahead_point(race_progress, lookahead)` =
   `get_point_at_distance(race_progress + lookahead)` (`race_route.gd:379`).

It **does** use the `RaceRoute` helpers (`project_position`, `get_point_at_distance`,
`get_lookahead_point`) — and uses them in the standard way. The flaw is not the helpers; it's how the target
distance and steering gain are defined (see §9).

---

## 6. Current steering algorithm

`racer_ai.gd:201-242`:

```
to_target_flat = flatten(lookahead_point - global_position)
forward_flat   = flatten(-basis.z)
lateral_error  = to_target_flat.cross(forward_flat).y        # ≈ sin(angle to target)
steering_input = clamp(lateral_error * 2.5 * skill_level, -1, 1)
```

This is a **pure proportional controller on the heading-to-target angle** with constant gain
`2.5 × skill_level` (skill randomised 0.85–1.0 → gain ≈ 2.1–2.5). **No derivative, no integral, no command
smoothing, no rate limit, gain not scaled by lookahead or speed.**

Then two more terms can modify it:
- **Obstacle override/blend** (`racer_ai.gd:218-236`) when the raycast hits something.
- **Corridor correction** (`racer_ai.gd:237-242`, `_calculate_corridor_correction` `:313`): a *second* P
  term that pushes back toward the centerline once `lateral_offset > 0.4·CORRIDOR_WIDTH` (2.8 m), strength
  up to 0.6, **added** to steering — but only when no obstacle is detected.

**Actuator stage** (`vehicle_base.gd:103-119`): the *command* is converted to a wheel angle with
speed-reduced max lock (`×clamp(1 − speed/200, 0.3, 1)`), then `steering = lerp(steering, target, 3·delta)`
(turn) / `5·delta` (return). So the only filtering anywhere is this ~0.33 s actuator lag — which adds phase
delay to the loop rather than damping it.

---

## 7. Current throttle / brake algorithm

`racer_ai.gd:244-272` (skipped when a critical obstacle is overriding):

- `turn_sharpness = _get_turn_sharpness_ahead()` (`:289`).
- `safe_speed` stepped down by sharpness bands, modulated by `aggression`:
  `>0.4 → ×0.85–0.95`, `>0.7 → ×0.65–0.8`, `>0.9 → ×0.5–0.65`.
- `speed_error = safe_speed − current_speed_kmh`; `< −10` brake `clamp(−err/30, 0.2, 0.6)`;
  `< 0` ease off (throttle 0.1); else throttle `clamp(err/8, 0.3, 1.0)` (aggressive accel, min 0.3).
- Applied to `engine_force` / `brake` in `vehicle_base.gd:122-142`, with auto-shift (`:164`).
- `BRAKE_DISTANCE := 35.0` (`racer_ai.gd:28`) is **declared but never read** — dead constant.

---

## 8. Are `RaceRoute` helpers used correctly?

Yes, mechanically. `project_position` is called forward-only with a segment hint (efficient, monotonic),
`get_point_at_distance` interpolates within a segment, `get_lookahead_point` is the documented arc-ahead
helper. The problems are *how the outputs are consumed*, not bugs in the helpers:

- The lookahead point is an **arc distance ahead of the car's projection**, not a Euclidean distance ahead of
  the car. When the car is laterally off-line, the real car→target distance shrinks, silently raising the
  effective steering gain.
- `project_position` is computed **twice per tick** (once in `_update_race_progress`, again inside
  `_calculate_corridor_correction` `:320`) — redundant, though cheap at 24 points.

---

## 9. Why the AI drives in a sinusoid (diagnosis)

Ranked by likely contribution:

1. **High constant proportional gain on a near-bang-bang error (primary).** `lateral_error` is ~`sin(angle)`
   in [−1, 1]; gain 2.5 means a ~24° heading error (`sin ≈ 0.4`) already saturates steering to full lock.
   With no proportional band and no derivative term, the controller slams full lock → overshoots the
   centerline → slams full opposite lock = a textbook limit cycle. This is the core of the "S-ing".
2. **Lookahead decoupled from gain.** Proper pure pursuit uses curvature `2·sin(α)/L`, which self-damps:
   longer lookahead `L` → smaller correction for the same angle. Here gain is a fixed hand-tuned 2.5
   *independent of L*, so the natural geometric damping is gone, and the short min lookahead (12 m at low
   speed) makes it worse.
3. **Actuator lag inside the loop.** The `lerp(steering, target, 3·delta)` (~0.33 s) is phase delay, not
   damping; in a feedback loop with high gain it *promotes* oscillation.
4. **Two stacked P-controllers on the same axis.** Pursuit-angle steering + corridor-offset correction have
   different references and fight each other near the edges of the corridor.
5. **No command smoothing / rate limit** — only the laggy actuator filter, which is the wrong tool for
   stability.
6. **Discrete target jumps.** Forward-only `race_progress` advances in 20 Hz steps; when it jumps (corner
   cut / lateral drift), the arc-ahead target jumps, producing steering transients.

The cross-product sign is *correct on average* (cars do follow the route), so sign is not the cause —
the cause is gain/damping, not direction.

---

## 10. Speed planning / corner prediction

Exists but is weak:

- `_get_turn_sharpness_ahead()` (`:289`) compares the car's **current heading** to the route direction at
  +10/+20/+30 m and takes the max angle. This is **heading-relative**, so it conflates "I'm mis-aimed right
  now" with "there is a corner ahead," and it ignores true path curvature (angle *between* two future route
  segments). It also looks only 30 m ahead (~1.4 s at 80 km/h) — too short for real braking.
- `safe_speed` reduction is reasonable in shape but capped (never below 0.5×) and not physically grounded
  (no `v = √(a_lat · R)`).
- `target_speed` is randomised 70–90 km/h once (`racer_ai.gd:86`) and fixed thereafter; no rubberbanding.

**Data already available to do this properly:** `RaceRoute.points[i].direction` and `distance_from_start`
give exact path tangents — true curvature = angle between consecutive segment directions over a
speed-scaled lookahead window; `BRAKE_DISTANCE` is already declared for exactly this and currently unused.

---

## 11. Obstacle detection / avoidance

- One `RayCast3D` per car (`racer_ai.gd:74`), 3 directions (center ±0.3·right) (`:360-364`),
  reach `clamp(speed·0.4, 8, 25)` m (`:351`), `force_raycast_update` each (`:372`).
- `collision_mask = 2 | 8` → sees **Buildings + NPC traffic only**.
- **Ignores: the player, other race opponents, and (almost certainly) parked cars / props / fences / signs**
  unless those sit on the Buildings layer. So opponents can interpenetrate each other and shove through the
  player, and never brake for parked clutter.
- Response: urgency (proximity), steer away from the hit side, hard override above urgency 0.6 (throttle 0.3
  / brake 0.4), blend below; center hits pick a side from current steering (`:401-406`).
- Corridor correction (§6) is the only other lateral safety, and it's disabled while an obstacle is detected.

Traffic NPCs (`traffic/npc_car.gd`) have their own simpler boolean raycast (mask `2|4`) — a *separate*
system; racing AI is actually the more sophisticated of the two, but blind to the most important racing
actors (player + rivals).

---

## 12. Overtaking / racing behavior

**None of it exists.**
- No overtaking, no side selection, no blocking/drafting/defending.
- No rubberbanding to the player.
- Every car targets the **exact centerline** (corridor correction actively pulls them all onto the same
  line), so they bunch and trade paint instead of racing lines.
- The only per-car variation is `skill_level`, `aggression`, `target_speed` (randomised at `_ready`,
  `racer_ai.gd:84-86`) and body colour — `aggression`/`skill` feed only gain and corner speed, not behavior.

---

## 13. Road width / lanes / lateral offsets

- `RaceRoute` stores **centerline only** (`RoutePoint{position, direction, distance_from_start}`,
  `race_route.gd:8`). No width, no lane count.
- Drivable width is a single global constant `CORRIDOR_WIDTH = 7.0` (`racer_ai.gd:30`), matched by barriers
  at `±BARRIER_OFFSET = 7.0` (`race_barriers.gd`). So there is ~7 m each side to work with, but nothing
  assigns cars distinct lateral offsets — and corridor correction fights any offset.
- OSM road/lane width tags are *not* threaded into the route. A safe lateral-offset band (e.g. ±2–3 m,
  per-car) could be added without new geometry, since the corridor already guarantees that width.

---

## 14. Stuck detection / recovery

Present and reasonable (`racer_ai.gd:413-486`):
- Stuck = `current_speed_kmh < 3` for `> 3` s (`STUCK_THRESHOLD`).
- Recovery: reverse 2 s with random steering + `apply_central_force(backward·3000)` (`:438-456`).
- After `MAX_RECOVERY_ATTEMPTS = 3` → `_respawn_on_track()` teleports 20 m back on the route, re-orients,
  zeroes velocity (`:459-486`).
- Note: the teleport fallback can *mask* navigation bugs (a car that S-es into a wall just respawns).

---

## 15. Race progress / finish logic

- Progress = forward-only arc distance from `project_position` (`racer_ai.gd:275-287`); cannot regress.
- Finish = `race_progress >= total_length − 10` (`race_route.gd:386`).
- `RaceManager` records `_finish_order`; standings read opponent `get_race_progress()` each frame.
- Consequence: progress is purely arc-length, so a car that **cuts a corner or drifts wide still accrues
  progress** as long as its projection advances — there is no checkpoint gate on opponents. This aligns with
  the HUD standings (which already consume `get_race_progress()`), so improvements here won't break the HUD.

---

## 16. Debug / test tools available

- `RaceManager.race_hud_debug` flag (`race_manager.gd:69`) → `[RaceHUD]` prints only (HUD, not AI).
- `race/race_grid.gd:debug_grid_layout()` prints grid (start only).
- `race/race_barriers.gd` — press **G** to toggle corridor-barrier visibility (useful to see the 7 m band).
- `race/test_track_scene.tscn` (flat, no OSM) for isolated physics.
- `debug/performance_profiler.gd` in race scenes.
- **No live AI gizmos** (no target-point draw, no steering/speed telemetry, no route line). RacerAI only
  `print()`s on recovery/respawn (`:435,464`), and those prints go to the *game process*, not the MCP editor
  log.
- **Start a race in `main.tscn`:** `RaceManager.start_race(load("res://race/race_tracks.gd").get_track_by_id("fanera_sprint"))`,
  then poll `RaceManager.current_state` until `RACING` (≈13 s LOADING + 3 s countdown) before inspecting.
  To watch AI: `find_nodes_in_group("race_opponent")`, read `global_position` / `current_speed_kmh` /
  `steering_input` / `race_progress` over time via `execute_game_script`. **No fast-forward exists** — a
  full sprint takes the real driving time.

**Minimal instrumentation worth adding later** (not now): an optional debug flag on RacerAI that records
`{lookahead_point, steering_input, target_speed, turn_sharpness, lateral_offset}` into a static ring buffer
readable via `execute_game_script`, so steering can be charted without manual driving.

---

## 17. Performance constraints

- Only 3 opponents — comfortable headroom.
- AI planning at 20 Hz (`UPDATE_INTERVAL = 0.05`), steering/throttle applied every physics frame via
  `_base_physics_process` (`vehicle_base.gd:208`). Good split.
- Per tick: 3 `force_raycast_update`, 2 `project_position` (one redundant), a handful of
  `get_point_at_distance`. Bounded by 24 route points → negligible.
- Headroom is fine to add: true-curvature scan, a wider obstacle cast set, and a per-car lateral offset.
  Adding opponents/player to the obstacle mask is the only change with a real behavioral (not perf) risk.

---

## 18. Minimal safe improvement path (staged — NOT a plan to execute yet)

**v1.1 — Stable route following (kills the sinusoid).** Highest value, lowest risk, no new systems:
- Replace the fixed-gain P with proper pure-pursuit curvature (`steer ∝ 2·sin(α)/L`) *or* keep P but
  (a) measure lookahead Euclidean from the car, (b) lower the gain, (c) scale gain down with speed,
  (d) add a derivative / command rate-limit, (e) lengthen the min lookahead.
- Unify or drop the second (corridor) P-controller so two loops don't fight.
- Treat the actuator lerp as actuation, not stabilization.

**v1.2 — Speed planning.** Use real path curvature from `RoutePoint.direction` over a speed-scaled window;
physically motivated `safe_speed = √(a_lat · R)`; actually use `BRAKE_DISTANCE`; brake earlier, accelerate
out smoothly.

**v1.3 — Obstacle avoidance that sees the race.** Add opponents + player (+ parked-car layer) to the cast
mask; add side-clearance checks; pick a temporary lateral offset instead of only steering; emergency brake;
keep the existing stuck/respawn.

**v1.4 — Racing behavior.** Per-car lateral lane offset within the 7 m corridor; basic overtaking
(offset to the open side of a slower car); wire the already-existing `skill`/`aggression`/`target_speed`
into believable personalities; optional gentle rubberband.

---

## 19. Risks and pitfalls

- `vehicle_base.gd` is **shared with the player** — re-tuning steering response there affects the player;
  keep AI changes inside `racer_ai.gd` (the command), not the shared actuator, unless intentional.
- Adding opponents to the obstacle mask can make the **start grid** brake on each other; gate avoidance by
  relative speed/closing rate.
- Removing corridor correction without fixing pursuit could let cars wander into barriers.
- The respawn teleport masks navigation failures — fix steering before trusting "it finishes."
- Per-car lateral offset must respect the ±7 m barriers or cars will clip them.
- Don't introduce NavMesh — the centerline route + corridor is sufficient and the bug is control-loop tuning,
  not pathfinding.

---

## 20. Open questions (non-blocking)

- Is `BRAKE_DISTANCE` intended for distance-to-corner braking (currently dead)? Assumed yes for v1.2.
- Acceptable to give each opponent a fixed lateral lane offset within the corridor (changes the "all on
  centerline" look)? Assumed yes for v1.4.

---

## Verdict

**Ready for implementation plan: YES.** The architecture (shared `VehicleBody3D` physics, centerline
`RaceRoute` + helpers, 7 m corridor, 20 Hz planner, stuck/respawn) is sound and can support every staged
improvement without a rewrite. The sinusoid is a control-tuning problem, not a structural one.

**Recommended AI v1 improvement scope:** **v1.1 — Stable route following.** Tame the steering loop
(geometry-correct pure pursuit / lower & speed-scaled gain + derivative + Euclidean lookahead, unify the
corridor term). This alone removes the most visible defect and makes everything downstream testable.

**Best first implementation target:** the steering block in `racer_ai.gd:201-242` plus the
lookahead-distance definition (`:196-199`) — leave `car/vehicle_base.gd` untouched so the player is
unaffected.

**How to test in `res://main.tscn`:** start
`RaceManager.start_race(load("res://race/race_tracks.gd").get_track_by_id("fanera_sprint"))`; poll
`RaceManager.current_state` until `RACING`; then over ~10–20 s sample each `race_opponent`'s
`lateral_offset` (via `RaceRoute.project_position`) and `steering_input` through `execute_game_script` and
confirm the lateral offset stops oscillating (peak-to-peak should collapse). Screenshot from a chase/top
view to eyeball the line, then `stop_scene` to spare the Mac. Add the optional RacerAI debug ring-buffer
(§16) if charting is needed.

---

## Post-v1.1 race backlog (surfaced in-engine, 2026-06-19)

After v1.1 (stable steering) shipped, real in-city racing exposed issues beyond steering. Recorded here so
the roadmap (§18) is complete. **Root causes below are strong hypotheses from the v1.1 code reading, NOT yet
code-verified end-to-end — each fix must start with a short code-confirmation step.**

### Player-observed symptoms
- **S1 — Opponents ram poles & each other.** They drive into street lamp poles/столбы and into one another,
  worst right off the start line.
- **S2 — Route terrain not fully loaded ahead.**
- **S3 — Opponents "vanish" when far ahead.** The minimap dot keeps advancing, but there's no actual car when
  the player catches up.

### Likely root causes (confirm before fixing)
- **S1:** the AI obstacle raycast mask is `2 | 8` (Buildings + NPC traffic) — it does **not** include other
  opponents (layer 128) or the player (layer 1), so opponents never *steer* to avoid each other or the player
  (`race/racer_ai.gd` `_ready` + `_check_obstacle_ahead`). Street lamp poles may also sit on a layer the cast
  can't see (needs a layer check). And the start grid likely spawns cars close enough to touch immediately.
- **S2 / S3 (same root cause):** terrain streams around the **player**; an opponent that outruns the loaded
  radius loses ground collision and falls into the void. The minimap dot tracks `race_progress` projected onto
  the route (pure geometry — no terrain needed), so it keeps moving while the real car has fallen / gone STUCK
  / entered a respawn loop → "dot moves, no car." This is almost certainly the **same** root cause as the
  y≈121 m airborne opponent seen during v1.1 verification.

### Roadmap update (supersedes the §18 ordering)
1. **NEW — Race world streaming / opponent persistence  ← RECOMMENDED NEXT (highest impact).**
   Keep opponents in the loaded world: preload + hold the full route's chunks for the race duration (the track
   `waypoints` preload hook already exists in `race/race_tracks.gd`), or stream terrain around opponents too;
   ensure opponents are scene-owned (not chunk-freed) and never despawned ahead of the player; give opponent
   spawns the same terrain height-snap the player gets; stop the minimap implying a car that isn't physically
   present. **Until opponents stay grounded ahead of the player, steering/braking/avoidance don't matter.**
2. **v1.3 — Obstacle avoidance (expanded for S1):** opponents avoid each other (add layer 128 to the sensed
   set, gated by closing speed so the grid doesn't lock up), avoid poles/lamps (put them on a sensed layer or
   add that layer to the mask), avoid the player; de-overlap the start grid.
3. **v1.2 — Speed planning (corner braking):** curvature-based safe speed; actually use `BRAKE_DISTANCE`.
   Originally "next", now deprioritized behind the two bugs above since it's the least player-visible.

### Recommended next step
Fix **S2/S3 (world streaming / opponent persistence)** first — it's why the race feels broken. Then S1
(avoidance), then v1.2 braking. Start with a focused read-only investigation (lamp/pole collision layers;
terrain chunk load/unload around player; route preload lifetime; whether opponents are chunk-freed; minimap
dot source) before writing any fix.
