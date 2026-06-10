# Overhead Utility Wires Between Street Lamps — Implementation Plan

Status: ✅ **IMPLEMENTED & verified in-engine (Cherepovets, day/night, reload-deterministic) — 2026-06-10.**
Code: `osm/osm_terrain_generator.gd` (clipped-walk wire pipeline + pooled night sparks).

**Key adaptation vs. plan (documented):** the lamp walker places lamps from **clipped per-chunk** polylines and
the 17 m spacing phase **resets at each chunk boundary**, so recomputing from the FULL polyline (plan §2) would
NOT reproduce real lamp positions → floating wires. Instead the wire enqueue mirrors the **lamp** enqueue (same
`_clip_polyline_to_rect`), so `_compute_lamp_anchors(clipped_pts, width)` is bit-identical to placed lamps.
Anchor validity replicates the exact lamp gates. Ownership = the clipped chunk (simpler than midpoint). Trade-off:
a wire gap at chunk borders (minor, realistic). Lamp walker left UNCHANGED (plan §2 fallback path); only its 3
literals were promoted to the shared `LAMP_*` consts. Twin-cable resolves **per-(way,side) run** (consistent
double-runs read more like real feeders than per-span alternation), not per individual span.

**Attachment gotcha (fixed):** the lamp GLB's **pole shaft is NOT at the model origin** — verified from the mesh,
the shaft centroid is at local **(+0.77, 0)** and stays vertical to ~5.0 m, while the origin floats in the gap
between pole and the arm/head (head at local −0.6). Attaching wires at the origin made them **levitate beside the
pole, under the lamp** (the same class of bug as the billboard lamp). Fix: wires attach at the **pole-shaft world
XZ** = origin + `Basis(UP, lamp_yaw) * (WIRE_POLE_LOCAL_X, 0, 0)` (same yaw `_add_lamp_to_batch` applies), and at
**`WIRE_ATTACH_Y = 4.6 m`** on the straight shaft **below** the arm — matching real overhead lines on pole crossarms.

Goal: string old overhead utility wires between *some* existing street lamps, and at
night let a *few* wire joints occasionally drop subtle bluish sparks that fall and fade.
Target vibe: post-Soviet provincial street — sparse, believable, **not** cyberpunk. Not
every lamp connected, not every joint sparking, visible mostly at night, no meaningful FPS cost.

---

## 1. What the codebase study established (grounding)

All references are to `osm/osm_terrain_generator.gd` unless noted.

### Street lamps
- Lamps are placed on `highway ∈ {motorway, trunk, primary, secondary, tertiary}`, enqueued
  **clipped per chunk** at line 5318-5323 into `_deferred_lamp_queue` as `{points, width, parent}`.
- `_generate_street_lamps_incremental` (19630): budget-resumable walker. **Spacing = 17.0 m**
  (line 19634), **lateral offset = `road_width/2 + 0.5`** (19635), **both sides when
  `road_width ≥ 12.0`** (19683). Per-lamp gates: not in intersection contour, not in parking,
  not near road (`_is_point_near_road(...,0.1)`), not in water; placed only if `_loaded_chunks.has(ck)`.
- `_add_lamp_to_batch` (17265): dedup via `_created_lamp_positions["<int x>_<int z>"]`. Lamps go
  into one `MultiMeshInstance3D` per chunk; per-lamp `StaticBody3D "LampCol"` cylinder (r 0.12, h 5.5).
- **Lamp model**: normalized to **6.0 m** tall (line 1600), Y=0 at base. Light/arm offset
  `_lamp_light_offset ≈ Vector3(-0.6, aabb.end.y − 0.17, 0)` → top-of-pole ≈ **Y 5.6–5.8 m**.
- **Critical limitation**: *there is no reusable store of lamp anchors grouped by road/side/sequence.*
  `_created_lamp_positions` holds **position keys only** (no way_id, no side, no order).
  `_lamp_batch_data` is erased after finalization. So wires cannot read back "the lamps on this road, in order."

### Determinism
- House hash style: `(way_id * 2654435761 + idx * 40503) & 0x7FFFFFFF` (e.g. line 19892). **No `randf` for
  persistent choices.** (Note: the existing 5%-broken-lamp uses `randf` and is therefore *not* reload-stable —
  so sparks must **not** key off broken state; we roll our own deterministic selection.)

### Chunk streaming / cleanup (the billboard precedent we mirror)
- Roads feed decorations; billboards (line 5327-5333) enqueue **FULL unclipped** `full_smoothed_points`
  + `way_id` so spacing is **global arc-length** and each candidate is assigned to **its own midpoint chunk**
  during the walk. This is the pattern that solves chunk-boundary gaps — we copy it for wires.
- Per-chunk dedup + unload cleanup pattern (lines 3037-3052): `_created_*_keys` (semantic global) +
  `_*_keys_by_chunk` (for unload erase). Chunk node freed at 3083 (`queue_free`) takes its child meshes with it.
- Reset clears per-feature dicts in two places: ~line 1974 and ~3220-3244.
- `_budgeted_add_child(parent, child)` (24145) for spreading node-adds across frames.

### Night mode
- `night_mode/night_mode_manager.gd`: scene node (in main.tscn), `signal night_mode_changed(enabled)`,
  `var is_night`, `enable_night_mode()` / `disable_night_mode()`. Also sets global shader uniform
  `is_night_global`.
- Terrain gen connects once via `_connect_to_night_mode` → `_on_night_mode_changed(enabled)` (20816),
  which sets `_is_night_mode` and walks chunks. **`_on_night_mode_changed` is the single hook** for day↔night.
- Convention: any `SpotLight3D/OmniLight3D` named **"LampLight"** auto-toggles
  `visible = night and not is_broken` in `_recursive_update_lights` (20855). Billboards reuse this.

### Existing VFX
- Project standard is **GPUParticles3D** (no CPUParticles3D anywhere). Proven cheap pattern in
  `car/audio/collision_sound.gd`: `one_shot=true`, emissive `StandardMaterial3D`, self-free via
  `get_tree().create_timer(...).timeout → queue_free`.
- Rain is a single 16k-particle GPUParticles3D in NightModeManager (toggled on/off).
- **No pooling of VFX nodes** exists (only NPC traffic pools). No existing spark/electrical effect besides
  collision sparks. No TIME-animated 3D emissive flicker.

---

## 2. Architecture decision

**Wires are generated by a separate deferred per-chunk wire processor that recomputes the lamp-anchor
sequence from the FULL road polyline (not from placed lamp nodes), mirroring the billboard pipeline.**

Why recompute instead of reading placed lamps:
- There is no anchor store to read (see §1). Adding one would have to survive the chunk-clipped,
  budget-resumable lamp walker and would still be split at chunk borders.
- The lamp placement is a pure deterministic function of `(full_road_polyline, road_width)`. Recomputing it
  from `full_smoothed_points` gives the **complete, gap-free** anchor sequence per road regardless of how
  chunks clip it — exactly why billboards already use `full_smoothed_points`.

**Drift guard**: promote the lamp constants to shared module constants and factor the anchor math into one
pure helper used by *both* the lamp walker and the wire processor, so they can never diverge:

```
const LAMP_SPACING := 17.0          # (replaces local var at 19634)
const LAMP_SIDE_OFFSET_PAD := 0.5   # offset = road_width/2 + pad
const LAMP_BOTH_SIDES_WIDTH := 12.0

# pure, no node access, no randf — returns ordered candidate anchors for one road
func _compute_lamp_anchors(full_points, road_width) -> Array
#   → [ {pos: Vector2, side: int(+1/-1), idx: int, dir: Vector2}, ... ]  ordered along the road, per side
```

**Staged, safe refactor (must NOT alter existing lamp placement):**
1. Implement `_compute_lamp_anchors` **in parallel** — a new pure helper; touch nothing in the lamp walker yet.
2. **Validate it against reality**: for several roads/chunks, compare the helper's anchor positions, spacing,
   side selection, offsets, and ordering against the lamp walker's *actual* placements (a debug dump or
   visual marker overlay). They must match.
3. Only **after** that match is confirmed, refactor `_generate_street_lamps_incremental` to call the helper,
   keeping its existing per-lamp gates + budget logic. Re-verify lamps look identical (count/positions).
4. **Fallback if exact matching proves risky**: leave the lamp walker untouched and use the helper for **wires
   only**, documenting the drift risk. (Wire anchors still get validated by the same gates — see below — so a
   small drift cannot produce a floating wire; it would at worst shift a wire span slightly.)

The goal is zero behavioral change to street lamps. The shared-helper path is preferred; the wires-only path
is the safe escape hatch.

### Wire anchors must correspond to REAL placed lamps (gate validation)
Recomputing anchors from the polyline gives *candidate* positions. A candidate is only a real lamp if it passes
the lamp gates — so **a wire end must pass the same relevant placement gates a lamp checks**, or it would attach
to a post that doesn't exist (floating wire). Before using any anchor for a wire end:
- not inside an intersection contour — `_is_point_in_intersection_shape(pos, false, ck) >= 0`;
- not in parking — `_is_point_in_any_parking(pos, ck)`;
- not near/crossing the road the lamp-side check uses — `_is_point_near_road(pos, 0.1, ck)`;
- not in water — `_is_point_in_water(pos, ck)`;
- its chunk is loaded / ownership handled (same `_loaded_chunks.has(ck)` condition lamps use).

Design (Option A, preferred): the shared helper returns candidates, and a **shared validation function applies
the lamp gates**, used by *both* lamp placement and wire generation where practical. Option B (fallback): the
wire processor calls that same anchor-validation before using an anchor. **A wire is built only when BOTH of its
end anchors validate as real lamps.** The span cap (§3) is still useful but is **not** a substitute for anchor
validity — it cannot tell a missing lamp from a long span.

### Wire ownership & dedup
- Enqueue, alongside the billboard enqueue (line 5327), a wire job **only for roads that qualify**
  (see §3 road policy), FULL points: `{points, way_id, highway, width}` into `_deferred_wire_queue[ck]`.
- A wire connects two **consecutive same-side anchors** `(idx, idx+1)`. Its identity is the global key
  `"w_<way_id>_<side>_<idx>"`. It is **owned by the chunk containing the wire midpoint**. The processor for
  chunk CK only creates wires whose midpoint chunk == CK → unambiguous ownership, no double-build.
- Dedup/cleanup mirrors billboards: `_created_wire_keys` (global) + `_wire_keys_by_chunk[ck]`. On unload
  erase the chunk's keys (line ~3041 block); the merged wire mesh frees with the chunk node. On reset, clear both.

---

## 3. Placement logic & gates

### Which roads — big roads included, density scaled by class
Overhead utility wires belong on big arterials too in a post-Soviet provincial city (lamp posts, roadside
verges, commercial strips, older/industrial approaches), not just side streets. **Wires and billboards
coexist** on trunk/primary — they're different visual roles (billboards = sparse roadside objects; wires =
overhead infrastructure on the lamps). Clutter is controlled by **density + span cap + intersection/building
gates**, not by excluding big roads.

- **Eligible**: `highway ∈ {trunk, primary, secondary, tertiary}`.
- **Excluded**: `motorway`, **bridges**, **tunnels**, junction/intersection spans, and obviously unsuitable
  segments (anchors failing gates).
- **Trunk/primary scope** — **general placement** wherever anchors pass gates; **no land-use gate** in v1
  (gating to commercial/industrial needs a land-use query and more failure modes, and the low density already
  keeps it believable). If pure-residential big-road frontage reads wrong in testing, add a *soft* density bias
  using the existing residential-footprint index — a later refinement, not v1.
- **Density scales with road class** — big roads sparser, side streets denser/more atmospheric. **Locked
  starting tuning** (still tune live in-scene, but these are the chosen defaults):

  | Class | Share of run slots filled | Run / gap (spans) | Feel |
  |---|---|---|---|
  | `trunk` | ~15% | run 2–4 / gap 5–9 | rare, isolated stretches |
  | `primary` | ~28% | run 3–5 / gap 4–7 | occasional |
  | `secondary` | ~45% | run 4–7 / gap 3–5 | the workhorse look |
  | `tertiary` | ~55% | run 4–8 / gap 2–4 | dense, residential-strung |

  Rationale: the overhead-web look lives on small streets; arterials lean toward standalone masts — so tertiary
  feels visibly "wired," trunk feels like an exception.

### Which spans get a wire — deterministic RUNS, not independent per-span keep/drop
Independent per-span hashing gives an artificial dotted look (on/off/on/off). Instead string **deterministic
short runs**: several consecutive spans connected, then a gap, repeated down each side.
- A **run** = N consecutive spans; then a **gap** of M spans; repeat. Run/gap lengths are **road-class
  dependent**, per the locked table above (trunk run 2–4 / gap 5–9 … tertiary run 4–8 / gap 2–4), realizing
  the per-class density shares.
- Run/gap **lengths and phase are deterministic** from `(way_id, side, anchor_idx, road_class)` via the house
  hash — no `randf` for run placement, run length, or any persistent choice. (One robust scheme: a per-(way,side)
  hash seeds a deterministic walk that alternates run/gap lengths drawn from class-dependent ranges by hashing
  the running index; a span is wired iff it falls in a "run" stretch.)
- `wire_debug_dense` bypasses runs and connects **every valid consecutive pair** for inspection (§9).

Per-span gates (applied to spans selected by the run logic):
1. **Both end anchors valid** — each passes the lamp gates (§2 "Wire anchors must correspond to real lamps").
   This is the primary guard against floating wires.
2. **Span cap**: skip if `dist(anchor_i, anchor_{i+1}) > WIRE_MAX_SPAN` (≈ **40 m**). Normal span ≈ 17 m.
   Useful, but **not** a substitute for anchor validity.
3. **No crossing intersections**: skip if midpoint (or either endpoint) is inside an intersection contour —
   `_is_point_in_intersection_shape(mid, false, ck) >= 0`.
4. **Same side only**: never connect left-anchor to right-anchor (no cross-carriageway wires in v1).

### Building avoidance — softer than billboards
Wires are overhead (~5.4 m) and may pass near facades in reality, so avoidance is **deliberately gentle**:
- Sample 3–5 points along the **XZ chord**; reject the span only if a sample point is **inside** a building
  footprint (a clear through-building crossing). Reuse the existing cell-hash footprint index.
- **Do NOT apply the billboard-style ~4–5 m anti-clip margin** — at street scale it would strip too many wires
  in dense blocks. Use a clear inside-footprint test only.
- Add a small extra margin **later, only if** in-scene testing shows wires visibly clipping facades.

### Attachment geometry — derive height from the lamp model
- Anchor world XZ from `_compute_lamp_anchors`; ground Y via `get_surface_y(x,z)` (same as lamps).
- **Prefer deriving the attachment height from the same lamp-model data the lamp system already uses** — the
  normalized 6.0 m model / its AABB / the `_lamp_light_offset` arm height — so wires track the real post head
  even if the model changes. Attach **just below the lamp arm/head** (not at the bulb): e.g. a small fixed
  drop below `_lamp_light_offset.y`.
- **Fallback** if reading those constants is awkward at wire-build time: `WIRE_ATTACH_Y ≈ 5.4 m`
  (`ground_y + WIRE_ATTACH_Y`). Verify the exact value visually in-scene either way.

---

## 4. Wire geometry

**Chosen representation: a low-segment catenary tube built with `SurfaceTool`, all wires in a chunk merged
into ONE `ArrayMesh` / one `MeshInstance3D`.** This matches the project's per-chunk-merge architecture and
keeps draw calls at +1 per chunk.

Options considered:
| Option | Verdict |
|---|---|
| Flat 2-tri ribbon | Cheapest, but vanishes edge-on and looks like a decal; rejected. |
| **3–4-sided extruded tube (SurfaceTool), ~6–8 length segments** | **Chosen** — reads as a cable from any angle, still tiny (~50–70 tris/span), merges cleanly. |
| Curve3D/Path3D + CSG/PathFollow | Overkill, runtime cost, no benefit. |
| MultiMesh of cylinder segments | More instances/overhead than one merged mesh; rejected. |

Parameters (initial, tune in-game):
- **Radius** ≈ 0.025 m (2.5 cm). **Sides** = 3 (triangular prism — invisible at this scale, cheapest).
- **Length segments** = 8. **Catenary sag**: `sag = clamp(span_len * 0.05, 0.25, 1.2)` m; midpoint dips by
  `sag`, parabolic approx `y(t) = lerp(y0,y1,t) − sag * 4 * t * (1−t)`.
- **Twin-cable variation (LOCKED IN, trivially disableable):** *some* spans carry **2 parallel sagging cables**
  instead of 1 — a small lateral/vertical offset between them (~0.15 m) reads as a real utility bundle. Both
  cables go into the **same merged chunk mesh**, so the cost is a few extra tris, no extra draw call. Which spans
  are twin is a **deterministic** choice (§5). A single `WIRE_TWIN_ENABLE` flag (or twin-denominator = ∞) turns
  it fully off if it ever looks busy.
- **Material**: one shared `StandardMaterial3D`, **`SHADING_MODE_UNSHADED`**, dark — initial
  `Color(0.06,0.06,0.07)`. Unshaded sidesteps the documented "ArrayMesh without UV = broken lighting" gotcha
  and matches the bridge-marking precedent (line 5588). `cull_disabled` not needed (closed tube). Created once,
  reused across all chunks.
- **Visual tuning (do this live, not by spec):** don't force pure black unless it actually reads right in-game
  — dark **grey** around `Color(0.06,0.06,0.07)` is the starting point. Daytime wires should be **visible but
  not noisy**; nighttime wires may be **subtle** (the sparks + street lighting carry the night read). Keep the
  material cheap and shared regardless of the final color.
- **Shadows**: `cast_shadow = SHADOW_CASTING_SETTING_OFF`.
- **LOD / culling**: `visibility_range_end = 250.0`, `VISIBILITY_RANGE_FADE_SELF`. Wires beyond ~250 m
  read as noise anyway.
- **No collision, no physics, no dynamic rope.** Cars never interact with overhead wires.

---

## 5. Determinism

Every **persistent** choice uses the house hash, never `randf`:
- **Run/gap placement** (which spans are wired): deterministic from `(way_id, side, anchor_idx, road_class)`.
  Run and gap lengths are drawn from class-dependent ranges by hashing the running index, seeded per
  `(way_id, side)` — so the same side of the same road always produces the same runs and gaps (§3). Never
  per-span independent keep/drop, never `randf`.
- **Twin-cable selection** (which spans get 2 cables, §4): deterministic from `(way_id, side, idx)` via the
  house hash — e.g. twin iff `(h % WIRE_TWIN_DENOM) == 0`. Reload-stable; no `randf`.
- **Spark-eligible joint set** (MUST be reload-stable): `hs = (way_id * 2654435761 + idx * 40503 + side_bit *
  668265263) & 0x7FFFFFFF`; eligible iff `hs % SPARK_JOINT_DENOM == 0`. **`SPARK_JOINT_DENOM ≈ 20`** → only
  ~1-in-20 wired joints ever sparks; the rest never do. This set is identical on every reload.
- **Spark timing — clarified (don't overengineer):**
  - *Deterministic / persistent*: eligible-vs-not, a rough **period bucket**, a **phase offset**, and any
    **intensity variant** are derived from the joint hash (so joints aren't synchronized and the *feel* is
    stable).
  - *Not required to reproduce*: the exact wall-clock instant a burst fires. Runtime scheduling may be cosmetic
    — it just must **not synchronize all joints** and must **not use persistent random state**. Transient,
    non-persistent jitter inside a frame is fine.
- Result: identical wires and an identical spark-eligible joint **set** on every reload / chunk reload (verified
  the billboard way: reload → identical positions); spark *timing* is allowed to differ run-to-run.

---

## 6. Spark effect (night-only, pooled, capped)

**Representation: a tiny global pool of one-shot `GPUParticles3D` "spark burst" emitters, repositioned to an
eligible joint and fired on a staggered deterministic schedule. Only runs at night.**

Why pooled bursts (not a persistent emitter per joint): a persistent particle system per joint = dozens of idle
GPU systems. A small pool (cap = pool size) hard-bounds active systems and costs nothing when idle.

### Joint registry
- As wires are created, register each spark-eligible **lamp attachment joint** world position:
  `_spark_joints_by_chunk[ck] = [Vector3,...]` + a flat `_spark_joints` array (or spatial cells) for the scheduler.
  Cleared on unload/reset like the wire keys. **Locked: v1 sparks at lamp attachment joints only, not mid-wire**
  (sparks reading as a faulty connection *at the pole* is the believable image; mid-wire is a later option).

### Manager (`WireSparkManager`, child of OSMTerrain root)
- `_ready`: build a pool of **`SPARK_POOL = 5`** GPUParticles3D, each `one_shot=true`, `emitting=false`,
  `amount ≈ 10`, `lifetime ≈ 0.8 s`, hidden. ParticleProcessMaterial: small downward spread, initial velocity
  ~1.5–3 m/s mostly down, gravity `(0,-9,0)`. Draw mesh: tiny `QuadMesh` (~0.04 m) billboard or `SphereMesh` r0.03.
  - **Preferred look**: a **color ramp blue/cyan→transparent** over lifetime (`emission` cyan/blue
    `Color(0.4,0.7,1.0)`, energy ~4, alpha → 0) → sparks "fade while falling".
  - **Fallback** (if a gradient/color-ramp is fiddly in current project conventions): a plain **bluish emissive**
    particle material with **short lifetime + decreasing scale (scale curve → 0) + low amount + subtle
    brightness + downward motion**. Shrinking-to-nothing reads as a fade without a color ramp.
  - **Hard visual requirement either way**: sparks **fall and disappear/fade before reaching the ground** —
    tune lifetime vs. velocity/gravity so they extinguish mid-air, not on the pavement.
- Connect to `NightModeManager.night_mode_changed`. **Day**: `set_process(false)`, all emitters hidden,
  `emitting=false` → effectively zero cost. **Night**: `set_process(true)`.
- `_process(delta)` (night only):
  - Maintain a small accumulator; every `SPARK_INTERVAL` (**~3–5 s**, locked: err rare/believable, not a light
    show) attempt **one** burst.
  - Candidate joints = eligible joints within `SPARK_VIEW_DIST` (**~90 m**) of the camera/car **and** roughly in
    front (cheap dot-product cull). Pick deterministically by current-time-bucket × joint hash so it looks
    irregular but isn't `randf`.
  - Grab a free pool emitter (one whose last burst finished). If none free → skip (cap reached). Move it to the
    joint, `restart()` + `emitting=true` (one-shot auto-stops). No per-joint nodes, no timers-to-free.
- This satisfies: only a subset of joints; only at night; occasional; bluish; fall + fade; global particle cap =
  `SPARK_POOL * amount` ≈ 50; per-area cap via the single-burst-per-interval scheduler; distance-culled.

`SPARK_JOINT_DENOM ≈ 20` (locked) → only ~1-in-20 wired joints is *ever* eligible → most joints never spark.

---

## 7. Night-mode integration (no parallel lifecycle)

- Reuse the existing single hook: the spark manager subscribes to `NightModeManager.night_mode_changed`
  (the same signal terrain gen uses). No new day/night state machine.
- **Wires themselves are visible day and night** (old cables hang in daylight too) — they're static geometry,
  no per-frame cost, so no need to gate them on night.
- **Sparks are strictly night-gated**: the manager's `_process` is disabled during the day (`set_process(false)`),
  so there is provably no spark CPU/GPU cost in daytime. (We do *not* rely on `PROCESS_MODE_DISABLED`; an explicit
  `set_process(false)` + hidden emitters is the project pattern.)
- Optional polish (later): if a lamp is "broken" we could bias a nearby joint toward sparking — but broken is
  `randf`-based and not reload-stable, so v1 keeps spark eligibility on its own deterministic hash.

---

## 8. Performance budget & risk analysis

| Quantity | Initial cap / estimate |
|---|---|
| Wires per chunk | ~5–20 spans (deterministic runs on `{trunk,primary,secondary,tertiary}`, density scaled by class) |
| Wire mesh per chunk | **1** merged `MeshInstance3D` / `ArrayMesh`, ~0.5–1.5k tris |
| Extra draw calls | **+1 per loaded chunk** (merged), shadows off |
| Max wire span | `WIRE_MAX_SPAN ≈ 40 m` |
| Wire visibility range | 250 m, fade-self |
| Twin-cable spans | deterministic subset → a few extra tris, **no extra draw call** (same merged mesh) |
| Spark-eligible joints | ~1-in-20 wired joints (`SPARK_JOINT_DENOM ≈ 20`) |
| Active spark emitters (global) | `SPARK_POOL = 5` (hard cap) |
| Active spark particles (global) | ≤ ~50 (5 × ~10) |
| Spark burst cadence | 1 attempt / **3–5 s**, culled to ~90 m + frustum |
| Spark cost in daytime | **0** (`_process` disabled, emitters hidden) |
| Memory | shared material (1) + small pool nodes (5) + per-chunk merged mesh |

Risks & mitigations:
- **Anchor drift / floating wires** → shared `_compute_lamp_anchors` helper + shared constants, **plus** the
  per-anchor lamp-gate validation that requires both ends to be real lamps (§2). Staged refactor verifies lamp
  placement is unchanged before adoption.
- **Main-thread spike when building many wire tubes** → wire processor is budget-resumable per chunk (mirror the
  lamp/billboard incremental pattern; commit the merged mesh once per chunk, add via `_budgeted_add_child`).
- **Spaghetti look** → deterministic run/gap selection (class-scaled density) + span cap + intersection
  rejection + through-building rejection; `wire_debug_dense` to audit coverage.
- **Sparks too busy / too bright** → low pool, long interval, low amount, low emission energy; all tunable consts.
- **Building footprint sampling cost** → reuse the existing cell-hash index; sample only 3–5 points per span.

---

## 9. Debug & visualization

Behind flags (default off), logs gated:
- `wire_debug_dense` — string every valid consecutive pair (bypass run/gap logic) to inspect coverage/clutter.
- `wire_debug_show_joints` — drop a small bright marker at each spark-eligible joint to verify selection.
- `wire_debug_reasons` — count rejections by reason (span-too-long / intersection / building / not-selected),
  printed like the temporary `_bb_dbg` counters used while debugging billboards (then removed).
- `spark_debug_force` — force-fire a burst at the nearest eligible joint each interval regardless of cadence,
  for quick visual checks.
- Night testing: drive day, then `NightModeManager.enable_night_mode()` (per memory: call the method; setting
  `is_night=true` directly leaves daylight).
- All debug logs/markers gated by the flags and removed/disabled before commit (as done for billboards).

---

## 10. Visual verification checklist (in the actual driving scene)

Launch **`res://main.tscn` directly** (not the menu), MCP editor open, Cherepovets spawn. Always stop the scene
after screenshots.

Daytime:
- [ ] Wires hang between lamp tops with believable **sag**, attach at the pole head (~5.4 m), not floating.
- [ ] **Sparse** — short runs, not a continuous net; no spaghetti.
- [ ] **No wires through buildings**; none span across intersections oddly.
- [ ] On `{trunk,primary,secondary,tertiary}` with **visibly sparser** runs on trunk/primary than on
      secondary/tertiary; **none** on motorway, bridges, or tunnels.
- [ ] **No floating wires** — every wire end sits on a real lamp post (anchor-gate validation working).
- [ ] Wires read fine alongside billboards on trunk/primary (not cluttered).
- [ ] Twin-cable spans read as a believable bundle (not two clipping lines); toggle off cleanly if too busy.
- [ ] Reload chunk (drive away and back) → wires reappear **identically** (determinism).
- [ ] No FPS regression vs. pre-feature; **zero spark cost** (particle count 0 in daytime).

Nighttime (`enable_night_mode()`):
- [ ] Only a **few** joints spark; most never do.
- [ ] Sparks are **subtle, bluish**, **fall downward**, and **fade out** while falling.
- [ ] Bursts are **occasional** and **not synchronized** across wires.
- [ ] Active particle count stays bounded (≤ ~50); FPS stable while driving a lamped street.
- [ ] Toggling back to day stops all sparks immediately.

---

## 11. Implementation milestones (staged)

1. Promote lamp constants + implement pure `_compute_lamp_anchors` **in parallel**; dump/overlay its anchors
   and **verify they match actual lamp placements** (spacing/side/offset/order). Do NOT touch the lamp walker yet.
2. Add the **shared anchor-gate validation** (intersection/parking/road/water/chunk-loaded). Only after step-1
   match is confirmed, refactor the lamp walker onto the helper and re-verify lamps are identical — else keep the
   walker as-is and use the helper for wires only (documented fallback).
3. Add wire member state (queues, key dicts, joint registry) + reset/unload cleanup hooks (mirror billboards).
4. Prototype: build **one** static catenary tube between two known **validated** anchors; verify sag/height
   (derived from lamp model)/material in-scene.
5. Wire processor: per chunk, recompute anchors from full points, **validate both ends**, connect midpoint-owned
   consecutive pairs, merge into one mesh. (No run logic yet — all valid pairs.)
6. Add deterministic **run/gap selection** (class-scaled density) + span cap + dedup keys.
7. Add gates: intersection, through-building (soft), road-class policy `{trunk,primary,secondary,tertiary}`,
   exclude motorway/bridge/tunnel. Verify no spaghetti / no through-building / no floating wires.
8. Spark manager: pool + night signal hook + day `set_process(false)`; one prototype burst at a fixed joint.
9. Joint registry + scheduler (distance/frustum cull, deterministic eligibility + staggered timing, hard cap).
10. Debug flags + reason counters; tune sag, thickness, color, per-class density, spark interval/color/energy.
11. Full perf pass (day vs night FPS, particle count, draw calls), remove debug instrumentation, final visual A/B.

---

## 12. Settled defaults & deferred items

All earlier open questions are now **decided** (defaults locked in §§3–6). These remain tunable in-scene but
the build targets these values.

**Locked decisions:**
1. **Road class** — `{trunk, primary, secondary, tertiary}`; exclude motorway/bridge/tunnel/junction (§3).
2. **Per-class density** — trunk ~15% (run 2–4/gap 5–9), primary ~28% (3–5/4–7), secondary ~45% (4–7/3–5),
   tertiary ~55% (4–8/2–4). Deterministic run/gap, no `randf` (§3, §5).
3. **Trunk/primary scope** — general placement, **no land-use gate** in v1; residential soft-bias is a later
   refinement only if testing shows it (§3).
4. **Styling** — one uniform cable style, **plus the twin-cable variation** (a deterministic subset of spans
   gets 2 parallel cables; `WIRE_TWIN_ENABLE` to disable) (§4, §5). No clutter-vs-billboard special-casing —
   per-class density handles it.
5. **Spark location** — **lamp attachment joints only** (§6).
6. **Spark frequency** — ~1 burst attempt every **3–5 s** globally; **~1-in-20** joints ever eligible
   (`SPARK_JOINT_DENOM ≈ 20`) (§5, §6).
7. **Visibility range** — wires **250 m** (fade-self); sparks **~90 m** + frustum cull (§4, §6).

**Deferred to a later phase (explicitly NOT in v1):**
- **Cross-carriageway wires** — street-spanning cables between opposite lamps (real Soviet look, higher clutter
  + cross-side pairing logic). Parked as a future toggle.
- **Mid-wire sparks** — sparks away from the pole.
- **Per-class styling variety** (e.g. heavier bundles on industrial approaches) and the **residential
  density soft-bias** noted in §3.
