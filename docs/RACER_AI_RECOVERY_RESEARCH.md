# Racer AI — Recovery "floor-it-and-spin" bug: research + fix plan

**Symptom (user, 2026-07-09):** after an opponent hits a lamp pole and reverses free, it **floors the throttle from near-standstill**, breaks traction, **spins out several times**, and takes a long time to recover.

**Status:** ✅ **SHIPPED — P1 (traction clamp) only.** P3 and P2 were implemented, measured to regress, and dropped (details below). User confirmed in-game: spin calmer + reverse-loop gone.

## Outcome (2026-07-09)
- **Step 0 measurement (RACE_SLIPLOG, now removed):** normal racing wheel-slip is tiny (p99 ≈ 0.8 m/s, **0% of frames > 2 m/s**) and velocity-vs-tangent heading p99 ≈ 25°. → any threshold-gated fix is a no-op in normal driving.
- **P1 — TORCS `filterTCL` traction clamp: SHIPPED.** In `_update_ai_driver`, `throttle_input = _filter_tcl(throttle_input)`; cuts throttle when driven-wheel overspeed (ω·r − v) > `TCL_SLIP=2.0`, bleeding over `TCL_RANGE=10.0` m/s. Bench `recover` **and** `poles` came out **byte-identical to baseline** (P1 never fires on the flat bench) — proves it's a pure no-op except during real wheelspin. This is the actual fix for "floors it → wheelspin → spin."
- **P2 — throttle × heading coupling: DROPPED.** It measured *velocity*-vs-tangent; right after a reverse the car still coasts backward → P2 read ~180° and choked the forward throttle → false-stuck → **reverse-stop-reverse loop** (user-visible). Bench: P1+P2 `recover` = reverse_events 3 / recover_ticks 216 vs baseline **2 / 144**; P1-only = 2 / 144. Also near-no-op benefit (fires >60°, but real-track p99=25°). Removed.
- **P3 — post-recovery settle speed-cap: DROPPED.** Capping speed to 14 km/h post-recovery **trapped the car against a wall** it kept nudging (bench `recover` prog collapsed 636 → 54, recover_ticks 144 → 360). Reducing steer-gain in settle also stopped it steering away from obstacles. Not tunable away; removed.
- **Bench addition (kept):** `ai_bench.gd` now reports `max_yaw` + `spin_ticks` per opponent (spin metric). Note limitation: the flat bench does **not** reproduce the real curb-pole spin (head-on wall = no spin; 3-car `poles` spins only from chaotic pileups), so the fix was confirmed **visually in-game**, not on the bench.

---

## 1. Root cause (verified in our code)

The over-acceleration+spin is the sum of four things, all present in our code:

| # | Our behaviour | Where |
|---|---|---|
| A | **Throttle is a raw P-controller on `target−current` that saturates to 1.0 from a stop.** Car ≈0 km/h, line-profile target high → `speed_error` huge → `throttle = clampf(speed_error/8, 0.3, 1.0)` = **1.0**. Min is 0.3 (can't crawl). | [racer_ai.gd:975-983](../race/racer_ai.gd#L975-L983) |
| B | **No traction / launch control downstream.** `engine_force = max_engine_power·rpm_factor·throttle·gear·final_drive` — full throttle → full force at 0 m/s → **wheelspin**. No slip clamp, no ramp. | [vehicle_base.gd:122-142](../car/vehicle_base.gd#L122-L142) |
| C | **No throttle↔steering coupling.** Full throttle applied *while* steering hard to correct a large post-reverse heading error → oversteer → spin. Full steering lock is available at low speed (`speed_factor≈1.0`). | [vehicle_base.gd:106](../car/vehicle_base.gd#L106), throttle at [racer_ai.gd:982](../race/racer_ai.gd#L982) |
| D | **No post-recovery settle.** `_execute_recovery` snaps `ai_state=RACING`; next frame the full-throttle controller fires. Reverse (`throttle=-0.9`) → abrupt full-forward while still misaligned. | [racer_ai.gd:1666](../race/racer_ai.gd#L1666), [racer_ai.gd:1685](../race/racer_ai.gd#L1685) |

**The decisive finding:** TORCS' `getAccel` uses the *same* P-controller shape we do (`if allowedspeed > speed+margin: accel=1.0`) — it only survives because **`filterTCL` sits downstream** and claws throttle back the instant the wheels overspeed. **We have the P-controller but not the clamp.** So the single highest-leverage missing piece is a traction clamp.

---

## 2. How the market solves it (cited)

### Traction / wheelspin clamp — TORCS `filterTCL` (berniw/olethros)
Runs the AI's throttle through a slip clamp every frame, in **absolute m/s** (not normalized slip ratio — the ratio blows up as `v→0`, exactly our case):
```
slip = driven_wheel_surface_speed − car_speed         // ω·r − v
if slip > TCL_SLIP(2.0):  accel -= min(accel, (slip−TCL_SLIP)/TCL_RANGE(10.0))
```
A little slip (≤2 m/s) is optimal grip; beyond that throttle bleeds out over the next 10 m/s of slip. Sources: berniw TORCS tutorial ch.3; kartikmohta/torcs-driver `driver.cpp`; olethros.

### Progressive throttle at AAA scale — Forza Motorsport (2023)
Turn 10 called out that FM7 AI could only command **100%/0%** throttle (bang-bang) → traction loss; the rebuild switched to a NN controller giving **continuous progressive throttle** to "avoid traction loss." (forza.net; aiandgames.com) → the fix even at AAA is "stop commanding binary full throttle."

### Throttle↔steering coupling = the friction circle
Tyre force is bounded: `√(a_long² + a_lat²) ≤ μ·g` (traction ellipse / g-g). So
```
a_long_max = sqrt( (μ·g)² − a_lat² ),   a_lat = v²·κ = v²/R
```
Hard cornering (`a_lat→μg`) leaves ~0 longitudinal → any throttle spins. Cheap arcade realizations (common-knowledge, = first-order of the above): `throttle *= cos(steer)` and/or `throttle *= clamp(1 − |heading_err|/limit, 0, 1)`. The heading-error form is the one that directly kills OUR bug (post-reverse heading error is large → throttle auto-drops to ~0 until the nose points down-road). Sources: Pacejka 2006; Brach SAE 2011-01-0094; g-g diagram refs.

### Post-recovery "settle" — Game AI Pro Ch.38 §38.5.5 `Recover` (Tomlinson & Melder)
Dedicated Recover state, staged exactly as we want: **"stabilize the car, stop sliding, slow down… drive to the nearest edge at a *modest speed*… Once on-track, stable, and facing the correct way,"** hand back to Normal Driving. Uses **utility hysteresis** (integrate: +10/m off-track, +10 per wheel without grip, −20/frame; exit only when genuinely straight+gripping) so it can't drop out mid-fishtail. Exposes **per-tire slip** so Recover only exits when no wheel slides. Assetto Corsa's shipped analog: `Slowwhenpushed≈0.3` (ease off after contact/loss-of-control). Open-world racers hide the cautious re-launch behind the rubber-band/catch-up layer (Melder, Game AI Pro 2013).

### Speed formulas (autonomous racing, for the grip-circle option)
Pure pursuit: `κ = 2·sin(η)/L_d`, `v_max = √(μ·g·R) = √(a_lat_max/κ)`, brake trigger `d=(v_t²−v_c²)/(2a)` (Coulter CMU 1992; Sensors 2017 PMC5492420). Stanley folds a **softening `k_s`** into `δ = ψ_e + atan(k·e_cte/(k_s+v))` to avoid blow-up/oscillation at low `v` (arXiv:2011.08729). MAP/F1TENTH: geometric controllers must be augmented with a grip constraint (arXiv:2209.04346).

---

## 3. "Как у них vs как у нас"

| Technique (market) | Our code today | Gap |
|---|---|---|
| Traction clamp on throttle (`filterTCL`) | none | **missing** — the core fix |
| Progressive (non-binary) throttle | P-ctrl but min 0.3, saturates to 1.0 | partial; saturates from a stop |
| Throttle ↓ with steering/heading error | none | **missing** |
| Reduced steer lock at low speed | inverse: full lock ≤ low speed (`speed_factor≈1`) | **wrong direction for a stop** |
| Post-recovery settle state + hysteresis | snaps straight to RACING full-pace | **missing** |
| Throttle rate limit / launch ramp | none | missing (cheap insurance) |
| Grip-circle longitudinal accel limit | raw speed-error→throttle | missing (deeper fix) |

We already have the hooks to fix it cheaply: driven-wheel `VehicleWheel3D` in `wheels_rear/front` + `_get_average_wheel_rpm()` ([vehicle_base.gd:192](../car/vehicle_base.gd#L192)) for slip; `heading_error` already computed ([racer_ai.gd:946](../race/racer_ai.gd#L946)); a `RECOVERING` state already exists.

---

## 4. Fix plan (prioritized — first 3 kill the symptom)

Scope everything to **AI only** (clamp `throttle_input` inside `racer_ai.gd`), so the **player's feel is untouched**. No edits to `vehicle_base.gd` behaviour for the player path.

**P1 — Traction-control clamp (TORCS filterTCL).** New `_filter_tcl(throttle)` in racer_ai.gd, applied to `throttle_input` after it's set (RACING and reverse). `wheel_ms = avg(driven wheel rpm)/60·2π·wheel_radius`; `slip = wheel_ms − speed_ms`; if `slip>2.0`: `throttle -= min(throttle,(slip−2)/10)`. Absolute overspeed (stable at v≈0). *DoD:* on a from-standstill launch next to a pole, wheel-slip stays bounded; no multi-spin. Cheapest, highest leverage.

**P2 — Throttle × heading-error coupling.** In the RACING throttle branch: `throttle_input *= clamp(1 − |heading_error|/HEAD_LIMIT, 0.15, 1.0)` (HEAD_LIMIT ≈ 35–45°). Optionally also `*= cos(steer)`. *DoD:* while the nose is >~40° off the tangent, throttle is near-idle; car straightens before it powers up.

**P3 — Post-recovery settle window.** After `_execute_recovery` completes, enter a ~1–1.5 s settle: cap `v_want ≤ ~10 km/h` and reduce steer gain; exit only when `|heading_error|` small AND no wheel slipping (hysteresis, per Game AI Pro). *DoD:* transition reverse→race is smooth (no fishtail); measured spins-per-recovery → 0.

**P4 (optional, deeper) — Grip-circle accel limit.** Replace raw `speed_error/8` with `a_cmd ≤ √((μg)² − (v²κ)²)` → throttle via torque map. Removes standstill saturation at the source.

**P5 (optional, cheap insurance) — Throttle rate limit.** `throttle_input = move_toward(prev, cmd, RATE·dt)` — turns any 0→1 step into a launch ramp.

### Self-test (bench, no user driving)
Add a `curb_pole_recovery` scenario to `race/ai_bench.gd`: spawn opponent stopped against a pole, release, and log per-frame **max wheel-slip**, **yaw-rate**, **time-to-resume-pace**, **spin count** (|heading change|>150° events). Baseline vs after P1→P3. Targets: spin_count=0, time-to-pace < ~2.5 s, peak wheel-slip < ~4 m/s. Then one main-menu drive-confirm.

---

## 5. Sources
Game AI Pro Ch.38 (Tomlinson & Melder) — gameaipro.com PDF · Melder rubber-band (Game AI Pro 2013) · Biasillo, AI Game Programming Wisdom 2002 · TORCS berniw/olethros `filterTCL` · SuperTuxKart skidding_ai.cpp · Forza Motorsport 2023 AI rebuild (forza.net, aiandgames.com) · Pacejka 2006; Brach SAE 2011-01-0094 · Coulter CMU 1992; Stanley arXiv:2011.08729; MAP arXiv:2209.04346; Sensors 2017 PMC5492420.
