# Racer AI — Faithful Redesign Plan (algorithm-grounded, no workarounds)

**Status:** 🚧 IN PROGRESS — Phases 1–4 implemented & shipped on `aas-vibe`; racecraft + NPC avoidance still open. Plan written 2026-07-06, progress log updated 2026-07-07.

**Why this doc exists:** the previous rework was hand-rolled *approximations* of known algorithms plus
fine-tuning, and produced ~1% real improvement. This plan re-implements each part **faithfully to the
published/shipping algorithm it's based on**, deletes the workarounds, and is verified honestly (ground
truth, not `race_progress`). Every component cites the source it must match.

---

## 📊 PROGRESS & CURRENT STATE (updated 2026-07-07)

Shipped & pushed on `aas-vibe` — commits `da193ac9`, `e62970f9`, `53918051` (files: `race/racer_ai.gd`,
`race/racer_vaz2107.tscn`, `race/race_manager.gd`, + `preload_route_elevation` in
`osm/osm_terrain_generator.gd`). Test harness (`RACE_AUTOTEST` / `RACE_DRIVETEST` / `RACE_BLOCKTEST` +
stream logger) lives in `main.gd` and is **test-only, uncommitted**.

### ✅ Done
- **[A] K1999 racing line + [B] friction speed profile** — built once in `set_race_route`; verified 100%
  on-road (with route elevation preloaded). Straights at profile top, corners clip apex + brake.
- **[C] Pure pursuit on the line** — one clean target; **killed the sinusoid** (weave ~0 in the verifier).
- **[D] Context steering (Fray)** — danger classified by **NODE, not layer** (layer 1 mixes ground + poles +
  player): `Road`/`Grass` ignored; `race_opponent`/`player`/`car` = dynamic, avoided **only when AHEAD (±60°)**
  so a car being overtaken holds its line; poles/buildings/trees = static (slow + go around). Feelers are a
  **thick sphere ShapeCast** so thin poles/walls aren't missed between rays.
- **Speed** — **governed by the friction profile** (removed the artificial 46–62 km/h cap that made rivals
  half the player's speed), differentiated per car, global `RACER_SPEED_SCALE = 0.72` (tunable).
- **Racecraft basics** — distinct drivers (`_pace`/`_corner` anti-correlated → trade places on straights vs
  corners) + **slipstream/draft** + **catch-up-only** cohesion (no gluing).
- **[E] Recovery** (Game AI Pro ch.38) — stuck = *no route progress* **AND** *actually stopped* (progress
  freezes off-route too, which caused false reverses on fast cars); **reverse via wheels** (negative throttle
  pulls the car out — a gentle force/velocity is defeated by friction); respawn only after repeated failed
  reverses.
- **[F] Suspension** — VAZ-2107 chassis collider raised (0.45→0.6) so it clears curbs.
- **Under-map / FPS** — real cause was **terrain elevation loading flat-then-rising over the network**, not
  chunk unloading. Fix = **route elevation preload** (light height data, `preload_route_elevation`) so terrain
  comes up correct sooner **+ kinematic terrain-LOD**: rivals far from the camera ride the racing line and
  **sit on the real terrain each frame (raycast)** so they track it up as elevation loads and are never
  buried; full physics/wheel-to-wheel resumes within 200 m of the player. The earlier chunk-pin
  (`unload_distance=3000`) that kept everything loaded — **the FPS killer** — was removed.
- **Honest testing** — ground-truth verifier in `main.tscn` (`RACE_AUTOTEST`) + a **moving-camera drive-test**
  (`RACE_DRIVETEST`) that actually reproduces streaming/unload, a block-test, and a stream-state logger.

### ❗ Current problems (open)
1. **Rivals don't convincingly COMPETE** — they don't visibly overtake/jockey. Profiles + draft + cohesion
   aren't enough; needs deliberate **attack-vs-hold / overtake / block** behaviour (racecraft theme A).
2. **Hit poles where they shouldn't** — on corners or while avoiding something else. ShapeCast helped but
   apex-overshoot at speed + feeler gaps remain.
3. **NPC traffic avoidance NOT implemented** — opponents drive **through** NPC traffic cars. Opponent body
   `collision_mask = 131` excludes NPCTraffic (layer-8 value 8); feelers *do* see layer 8 but the classify/
   response for NPC traffic isn't wired. TODO: detect + go around NPC traffic (and decide whether to collide).
4. **Intermittent off-route** — a rival occasionally loses the route (rare `FAIL:stuck/slow`).
5. **Speed feel** — `RACER_SPEED_SCALE=0.72` still being tuned against the player.
6. **Possible FPS from thick feelers** — 16 sphere ShapeCasts / opponent / 20 Hz; optimise if profiling shows cost.
7. **Terrain-level elevation pop** — chunks still generate flat then rise (the racer LOD only hides it for
   rivals). A deeper fix is making chunk terrain wait for (preloaded) elevation before generating.

---

## 0. Goal & success criteria

Rivals that **actually race like drivers**, verified in the real `fanera_sprint` race (`main.tscn`, real
OSM city with elevation, curbs, buildings, poles, trees, traffic):

| Problem (observed) | Success criterion |
|---|---|
| Sinusoid / weaving | Steady steering: sign-changes near 0 on straights; smooth single-arc through corners |
| Hit poles/trees "for nothing" | Avoids static hazards in the drivable path without leaving the line elsewhere |
| Stuck on curbs | Cars ride over/along curbs; ground truth: `under_map=0%`, no permanent standstill |
| Not racing (bunch/crawl) | `onroad_moving` high; cars hold a racing line, overtake, keep pace |
| Recover after a crash | Detected + returned **onto the track surface** (never under it), rarely needed |

Ground-truth verifier already built (`main.gd`, env `RACE_AUTOTEST`): downward ray → under-map/off-road,
`world_dist` (can't be faked by `race_progress`), weave = steer sign-flips **while genuinely on-road-moving**.

---

## 1. Root cause of the current failure (each with its canonical source)

### 1.1 Pure pursuit — the target is corrupted
- **Canonical:** aim at **one** point on a **smooth** path; steering `δ = atan(2·L·sin α / ld)`, look-ahead
  `ld` scaled with speed. Weaves *only* if `ld` too short **or the target/path is not smooth & stable**.
  Source: Coulter 1992 (CMU pure pursuit), Snider 2009 CMU report "Automatic Steering Methods for
  Autonomous Automobile Path Tracking".
- **Current code (`racer_ai.gd`):** every tick the aim point is shifted by `lane_offset` + a **live,
  neighbour-dependent** `_neighbor_separation` + a **side-flipping** `_dodge_side`. The aim point jitters and
  flips frame-to-frame → limit cycle → **this is the sinusoid.**

### 1.2 Context steering — never actually implemented
- **Canonical (Andrew Fray, *Game AI Pro 2* ch.18; shipped in F1 2011):** two arrays over N candidate
  **directions** — an **interest map** (`interest[d]` = alignment of slot `d` with the desired heading) and a
  **danger map** (`danger[d]` = obstacle proximity in `d`). Combine by **masking dangerous slots then choosing
  among the interest map** (Fray: lowest-danger set → highest-interest → tiebreak toward current heading; the
  Godot recipe: zero interest where danger, then weighted-sum the rest). It picks a **direction** — it never
  sums opposing chase/flee vectors, so it cannot cancel or flip-flop, and treats poles/trees/cars uniformly.
  Sources: Fray blog "Steering Behaviours Are Doing It Wrong" + "Context Behaviours Know How To Share";
  Godot implementation: kidscancode `godot_recipes/.../ai/context_map`.
- **Current code:** a 3-ray "shove the target sideways" heuristic (`_line_obstruction`) whose dodge side
  **flips** by which ray is clear → flip-flop weave, and only ~forward rays → **misses poles/trees off the
  nose** (exactly the observed "hits posts for nothing").

### 1.3 K1999 racing line — mine is Laplacian smoothing, not K1999
- **Canonical (VDrift `src/k1999.cpp`, R. Coulom's K1999):** each point carries a lane param `t∈[0,1]`
  (0 = left edge, 1 = right edge). Curvature `GetRInverse(prev,cur,next) = 2·det / √(n1·n2·n3)`. Set each
  point's curvature toward the **neighbour-distance-weighted average** of its neighbours' curvatures via a
  Newton step on `t`, **clamped to the track boundaries** (with inside/outside safety margins). Descending
  step sizes 128→1, ~`100·√step` iterations. Produces a true minimum-curvature line that clips apexes.
- **Current code (`_build_race_line`):** Laplacian smoothing (pull each point to the midpoint of its
  neighbours) + corridor clamp. That only shrinks/straightens the polyline, leaves curvature ripples (→ more
  weave), and is not a racing line.

### 1.4 Speed control — ad-hoc bands, not a friction-limited profile
- **Canonical:** corner speed from the friction circle `v = √(a_lat / |κ|) = √(a_lat·R)`, made feasible by a
  **forward–backward integration** so braking points are placed before corners. Sources: Kapania et al. 2019
  "A Sequential Two-Step Algorithm…" (arXiv 1902.00606); Heilmeier/Xue min-curvature + QSS speed profile.
- **Current code:** `_corner_speed_limit()` scans a few points and takes a min — closer, but not a proper
  forward/backward profile; and it fights the avoidance's speed hacks.

### 1.5 Suspension — physics, not AI (your curb observation)
- **Finding:** the three opponent scenes share `wheel_radius=0.32, wheel_rest_length=0.35,
  suspension_travel=0.3`, but **VAZ-2107 sits lower** — front/rear wheels at local **Y=0.5** vs **0.55** on
  Nexia/Logan, and a smaller body mesh (scale 0.67). Lower ground clearance → chassis catches curbs.
- This is a `VehicleWheel3D`/geometry fix, independent of the driving code. Godot `VehicleWheel3D` ride height
  is governed by the wheel's local Y and `suspension_travel`/`wheel_rest_length`; a curb-catch is the chassis
  collider contacting the curb before the wheel can climb it.

---

## 2. Target architecture (single responsibility per stage, no cross-talk)

A clean pipeline. Each stage has one job and does not mutate another stage's data (the previous design's
core mistake was avoidance mutating the pursuit target).

```
Once per race (offline, shared):
  [A] Racing line  = K1999(centerline, left/right boundaries)   → dense points + tangent + curvature
  [B] Speed profile = forward/backward friction pass over [A]    → v_target(arc)

Every AI tick (per car):
  arc  = project(pos) onto [A]                       (monotonic, forward-biased)
  [C] Lateral  : ld = f(speed); aim = [A].point(arc+ld); desired_dir = (aim-pos)   (pure pursuit)
  [D] Avoidance: context_dir = ContextSteer(desired_dir, hazards)  (interest/danger over N dirs)
                 → if nothing dangerous, context_dir == desired_dir  (ZERO interference)
  steering = pure_pursuit_delta(context_dir, ld)                    (one clean δ)
  [E] Speed    : v_want = min([B].v(arc+small), context_speed_scale); throttle/brake from (v_want - speed)
  [F] Recovery : if stuck/flipped/off-surface → rescue onto surface (STK)
```

**Racecraft is emergent, not hacked:** all cars target the same optimal line; a car ahead becomes **danger**
in the follower's forward slots, so context steering picks an adjacent clear direction → overtake; different
per-car `target_speed` spreads the field. No static `lane_offset`, no `separation` push. (This is how
GT-Sophy and context-steering racers behave; sources in `RACER_AI_BEST_PRACTICES_RESEARCH.md`.)

---

## 3. Component specs (faithful to source)

### [A] Racing line — real K1999 (port of VDrift `k1999.cpp`)
**Inputs:** `race_route.points` (coarse centerline), corridor half-width `W` (currently 7 m; see Q1).
**Build:**
1. **Boundaries:** for centerline point `c_i` with unit tangent `t_i`, `perp_i = rotate90(t_i)`;
   `left_i = c_i + perp_i·W`, `right_i = c_i − perp_i·W`. (If OSM lane width is available, prefer it — Q1.)
2. **Resample** centerline + boundaries to uniform spacing `ds ≈ 3 m` (closed? no — point-to-point sprint).
3. **Lane parameter** `t_i∈[0,1]`, init 0.5 (centerline). Point = `t_i·right_i + (1−t_i)·left_i`.
4. **K1999 iterate** (verbatim from VDrift):
   - `curv_i = GetRInverse(p_{i-1}, p_i, p_{i+1})` with `2·det/√(n1·n2·n3)` (see 1.3).
   - `lPrev=|p_i−p_{i-1}|`, `lNext=|p_i−p_{i+1}|`.
   - `TargetCurv = (lNext·curv_{i-1} + lPrev·curv_{i+1}) / (lNext+lPrev)`.
   - Newton step on `t`: perturb `dLane=1e-4`, recompute curvature at the perturbed point → `dCurv`;
     `t_i += (dLane/dCurv)·(TargetCurv − curv_i)`  *(match VDrift's exact sign/'`Security`' term when porting)*.
   - **Clamp** `t_i` to `[IntLane, 1−ExtLane]` (right turn) or `[ExtLane, 1−IntLane]` (left) with margins
     `SideDistInt=1.0`, `SideDistExt=2.0` scaled by track width, plus a `Security` term `lPrev·lNext/(8·R)`.
   - Step sizes 128→1 (halving); `~100·√step` passes each (fewer if lap is short — tune iteration **count**
     to convergence, not behaviour).
5. **Output:** array `{pos, tangent, curvature, arc}` per point. Precompute **once** at `set_race_route`
   (shared by all cars — the line is the same; per-car differences come from [D]/speed, not the line).
**Source to match:** https://github.com/VDrift/vdrift/blob/master/src/k1999.cpp (+ DeepRacer K1999 port
`cdthompson/deepracer-k1999-race-lines` for a readable Python reference of the same update).

### [B] Speed profile — friction-limited forward/backward pass
1. `v_corner_i = √(a_lat_max / max(|curv_i|, ε))` — friction-circle corner cap (`a_lat_max` arcade-tuned,
   one constant, not per-corner tuning).
2. **Backward pass** (braking): from finish to start, `v_i = min(v_i, √(v_{i+1}² + 2·a_brake·ds))`.
3. **Forward pass** (accel): from start to finish, `v_i = min(v_i, √(v_{i-1}² + 2·a_accel·ds))`, and
   `v_i = min(v_i, top_speed)`.
4. AI targets `v_target(arc + small_preview)`; throttle/brake from `(v_target − speed)`.
**Source to match:** Kapania 2019 forward–backward (arXiv 1902.00606); friction circle `v=√(a_lat·R)`.

### [C] Lateral — canonical pure pursuit (unchanged law, clean target)
- `ld = clamp(K_LD · speed, LD_MIN, LD_MAX)` (speed-scaled look-ahead; Snider: `ld` is the gain — longer =
  smoother, shorter = tighter/oscillatory).
- `aim = [A].point_at_arc(arc + ld)` — **one** point on the racing line. **No lane/dodge/separation shift.**
- `α = signed_angle(heading, aim − pos)`; `δ = atan(2·L·sin α / ld)`; `steer = δ / deg2rad(max_steer)`.
- Wheelbase `L` measured from wheels (already done).
**Source to match:** Coulter 1992 / Snider 2009 CMU.

### [D] Avoidance — real context steering (Fray + Godot recipe), as a *direction filter*
- **Slots:** `N ≈ 16` unit directions; for a car use a **forward arc** (e.g. −100°..+100° around heading) so
  it never chooses to reverse. (Full 360° like the Godot recipe is for omnidirectional agents.)
- **Interest:** `interest[d] = max(0, dir_d · desired_dir)` where `desired_dir` is the pure-pursuit direction
  from [C]. Peaks at the pursuit direction → **when clear, the winner IS the pursuit direction (zero
  interference).**
- **Danger:** cast a feeler in each `dir_d` to `reach = clamp(k·speed, …)`. A hit contributes
  `danger[d] += proximity` (closer = higher), **and spills to neighbour slots** (so we don't graze a pole).
  Hazard set = poles, trees, buildings **inside the drivable corridor**, other cars, player, traffic. Gate:
  hits whose closest point projects **outside** the corridor are roadside scenery → ignored (keeps the line).
- **Combine (choose one, match a source):**
  - *Fray:* take the min-danger slot set; among them pick max interest; tiebreak toward current heading.
  - *Godot recipe:* zero `interest[d]` where `danger[d]` high, then `chosen = Σ dir_d·interest[d]`, normalize.
  Use the **weighted-sum** variant (smoother for a vehicle) + **blend with last frame** for hysteresis
  (Fray's "free hysteresis") to kill flip-flop.
- **Output:** `context_dir`. Feed **that** into [C]'s `δ` (replace `desired_dir`). Also derive a speed scale
  (if the best clear direction is far off the pursuit direction, reduce `v_want`).
**Source to match:** Fray *Game AI Pro 2* ch.18 + https://kidscancode.org/godot_recipes/3.x/ai/context_map/.

### [E] Recovery — SuperTuxKart rescue (keep the good parts already built)
- **Detect:** no forward progress over a window (have) **+** repeated-collision "stuck" (STK `isStuck`/
  `m_collision_ticks`) **+** flipped (`roll>60°`, STK). 
- **Rescue onto surface:** raycast **down** to terrain height (STK `TerrainInfo/getHoT`), place on it,
  reorient to the racing-line tangent, small forward velocity. (Already implemented via `_ground_y_at` — keep;
  this is the one piece that was genuinely correct.)
- With proper driving + the suspension fix, recovery should be **rare**; treat frequent recovery as a bug
  signal, not a crutch.
**Source to match:** SuperTuxKart `kart.cpp` rescue conditions (see `RACER_AI_SIM_REUSE.md`).

### [F] Suspension / ground clearance (physics; needs your visual confirm)
- Raise clearance on the low car(s) — **VAZ-2107** first. Grounded options (Godot `VehicleWheel3D` docs):
  raise `wheel_rest_length` (body rides higher) and/or move wheel local Y so the chassis collider sits above
  curb height (~0.15 m); ensure the chassis collision shape doesn't extend below the axle. Change **only the
  clearance**, keep grip/handling. Exact values proposed at implementation time; **you verify visually**.

---

## 4. What gets DELETED (the workarounds)

- `lane_offset` added to the pursuit target, and its randomisation.
- `_neighbor_separation()` (live-neighbour target jitter).
- `_line_obstruction()` dodge-flip / line-shift heuristic → replaced by [D].
- `_build_race_line()` Laplacian → replaced by real K1999 [A].
- Ad-hoc speed bands / avoidance speed hacks → replaced by [B] + [D] speed scale.

**Kept (correct):** honest verifier (`main.gd RACE_AUTOTEST`), rescue-onto-surface (`_ground_y_at`), wheelbase
measurement, forward-only progress projection (with the far-segment guard).

---

## 5. Verification (honest, per phase)

Every phase verified with the ground-truth verifier **and** your eyes (you offered):
- `under_map` must stay 0%; `world_dist` real (not teleport jumps); weave counted only while on-road-moving.
- Phase gates below. Metrics are *evidence*, your visual read is the final judge (headless can't see a curb).

---

## 6. Phasing (build + verify in this order)

1. **[A] K1999 line + [B] speed profile**, offline. Verify by dumping the line (and drawing it in the flat
   harness overlay): smooth, clips apexes, stays in corridor; curvature/ speed sane. No car behaviour yet.
2. **[C] pure pursuit on the line, avoidance OFF.** Single car. Verify: follows the line, **no weave**, takes
   corners smoothly at profiled speed. This isolates "steering is correct" before any avoidance.
3. **[D] context steering ON.** Add poles/trees/cars. Verify: avoids hazards in-path, **no flip-flop**, and on
   a clear road `context_dir==desired_dir` (zero interference → still no weave). Overtaking emerges with 3 cars.
4. **[E] recovery refinements + [F] suspension.** Verify curb behaviour visually; recoveries should be rare.
5. **Full 3-car real race**, honest verifier + visual. Iterate only within-algorithm (no new workarounds).

---

## 7. Decisions (user, 2026-07-06) — these override §3 where they differ

**Q1 — Boundaries = real OSM road width + off-road tolerance (NFS-style).**
- The racing line [A] is optimised **within the actual OSM road** (road is fastest → prefer it). Road width is
  available: the terrain generator stores per-segment `{points, width}` (`get_road_segments_in_radius`,
  `_chunk_terrain_roads`). Sample road width along the route to set `left/right` edges (fallback to a default
  where unavailable), instead of a flat ±7 m.
- **Drivable ≠ hard-bounded:** going onto the **sidewalk/grass is allowed** (not a failure) when it helps —
  just slower. The **only hard obstacles are buildings, poles, trees, cars** (collision layer 2 + dynamic).
  So the honest verifier must treat "on sidewalk/grass" as OK (not off-road-fail); only under-map / immobile
  / building-hit are failures. Context steering [D] danger = buildings/poles/trees/cars (hard), **not** the
  road edge. A mild "prefer-road" bias (higher interest on-road) keeps them on the quick line but lets them
  cut onto grass to make a corner or a pass — exactly like NFS/Forza.

**Q2 — NFS/Forza-style racecraft, one good line + emergent overtaking; do NOT touch drag / lane modes.**
- Behave like NFS/Forza: hold a fast line, jockey, overtake, occasionally cut a corner. Implemented as **one
  optimised line [A] + context-steering [D]** handling car-vs-car (a rival ahead = danger → go around);
  per-car `target_speed` variety spreads the field. **Dropping the static per-car `lane_offset` hack.**
- **Isolation guarantee:** all changes are confined to `race/racer_ai.gd` + the three opponent car scenes.
  The **L "lane driving" and drag-race mode are the *player's* `car/lane_assist.gd`** (its API is explicitly
  "для drag race") — untouched. `racer_ai.gd` only *reads* the player's position (as a hazard). **No AI
  drag-race support will be added.** Player car, `vehicle_base.gd`, `race_route.gd`, `lane_assist.gd`: not
  modified.

**Q3 — Suspension is (likely) the curb bug — confirmed direction.**
- A car **stopping dead at a curb is wrong** (should hop over/along it). Fix ground clearance / suspension on
  the low car(s) — VAZ-2107 first — so it rides over curbs. You'll eyeball the result.

**Q4 — Arcade feel = "do what the best in genre do" (NFS).**
- No exact numbers required: pick **arcade-grippy, fast, forgiving** constants (high `a_lat`, high top speed,
  smooth braking); off-road excursions, mild drift, and slowing to hit an apex are all fine. Tuned to feel
  like NFS, not sim-conservative; you're the final visual judge.

---

## 8. Sources (to match implementation against)
- Pure pursuit: Snider 2009 CMU report; Coulter 1992.
- Context steering: A. Fray, *Game AI Pro 2* ch.18; blog "Steering Behaviours Are Doing It Wrong" /
  "Context Behaviours Know How To Share"; Godot recipe kidscancode `ai/context_map`.
- Racing line: VDrift `src/k1999.cpp` (R. Coulom K1999); `cdthompson/deepracer-k1999-race-lines`.
- Speed profile: Kapania et al. 2019 (arXiv 1902.00606); friction circle.
- Rescue / arcade AI: SuperTuxKart `kart.cpp` (see `RACER_AI_SIM_REUSE.md`,
  `RACER_AI_BEST_PRACTICES_RESEARCH.md`).

---

## 9. Genuine integration gaps & risks — READ BEFORE BUILDING

These are real unknowns/wiring the specs above assume but the current code does **not** provide. Resolve each
(or confirm the fallback) before/while building the relevant phase. If a gap can't be closed cleanly, **stop
and ask — do not paper over it with a workaround** (that is the exact failure mode this redesign exists to
undo).

1. **Road-width source is not wired into the AI (blocks [A] boundaries, §3[A]/§7-Q1).**
   `racer_ai.gd` has no reference to the OSM terrain generator, which is what owns per-segment road width
   (`get_road_segments_in_radius(Vector3, r) -> [{p1,p2,width}]`, `_chunk_terrain_roads`). At
   `set_race_route()` (called after terrain has loaded in the real race) obtain the terrain node (e.g.
   `get_tree().current_scene.get_node_or_null("OSMTerrain")`) and sample width along each route point to
   build the `left/right` edges. **Verify the data is actually populated at race-start time** (chunk loading
   is async). **Fallback if unavailable:** a sensible default half-width, and surface that we fell back so the
   human knows the line is corridor-based, not road-accurate.

2. **Arc mapping between the new K1999 line and `race_progress`/finish (blocks [C], progress/HUD).**
   Keep `race_progress` and `is_finished()` on the **original `race_route`** — `RaceManager`, the HUD, and
   `get_race_progress()` depend on its arc/`total_length`; do not change their meaning. The K1999 line is a
   **separate** array pursued for steering only. Map between the two by arc distance (they share nearly the
   same length). Pitfall: don't index the racing line by the route's `race_progress` blindly if the K1999
   resample changed total length — build the racing line's own cumulative-arc table and convert.

3. **Honest verifier semantics must change for the new "off-road is OK" rule (§7-Q1).**
   The verifier in `main.gd` currently treats off-road as failure. Per your decision, **sidewalk/grass is
   allowed**; only **under-map, permanent immobility (`world_dist≈0`), and building/pole/tree collision** are
   failures. Update the verdict logic accordingly before using it to judge the new build, or it will red-flag
   correct NFS-style corner-cuts.

4. **Verify in `main.tscn`, not the flat harness — the load-bearing lesson.**
   `race/ai_test_scene.tscn` has no elevation/curbs/real-city geometry and previously produced false
   "it works" results. Use it only to *visualise* the Phase-1 racing line. **All behaviour verification runs
   against the real `main.tscn` honest verifier.**

5. **"Prefer road" bias needs a definition, not a magic number (§7-Q1).**
   The NFS-style "on-road is faster, grass allowed" behaviour should come from the model, not tuning: e.g.
   the speed profile [B] is lower off-road (less grip) and/or a small constant interest bonus for on-road
   directions in [D] — pick the *mechanism* first (grip-by-surface is the physically honest one), then one
   constant, and let the human eyeball it.

6. **Suspension change must not alter handling (§3[F]).**
   Raising VAZ-2107 clearance (wheel local Y and/or `wheel_rest_length`/`suspension_travel`) changes ride
   height — verify it still drives the same otherwise (grip, no bounce/instability) and that the chassis
   collider no longer catches curb height (~0.15 m). Human confirms visually.
