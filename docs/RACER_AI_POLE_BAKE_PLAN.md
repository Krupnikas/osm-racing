# Racer AI — Pole-Bake Plan (known lamp positions → danger map)

**Problem.** Rivals occasionally clip lamp poles "on a seemingly flat/straight place" (user feedback, real
game). Root cause = the classic **thin-obstacle ray-gap**: 16 sphere-cast feelers ~12° apart, a lamp pole
subtends <1° at reach → it slips *between* feelers until too late. Widening/densening feelers (tried) makes it
*worse* in pole-lined stretches (over-reacts, weaves between rows).

**Fix (Fray / F1 2011).** Give rivals the **exact pole positions along the route** and write them into the
context-steering danger map **by position** — the car knows precisely where every pole is, threads them, and
"sees" them *around corners*. This is the § B′ race-bake from
[`RACER_AI_INDUSTRY_RESEARCH.md`](RACER_AI_INDUSTRY_RESEARCH.md#reality) and the P2 fix from the
[implementation plan](RACER_AI_IMPLEMENTATION_PLAN.md), now spec'd concretely.

**Status:** 📋 plan (planning). No code yet — awaiting go-ahead.

---

## 0. Key insight — this is NOT blocked by the terrain WIP

The M9 elevation enablers were blocked because they need a *new method inside* `osm_terrain_generator.gd`
(226 lines of your uncommitted WIP). **The pole-bake does not touch that file** — it only *calls existing
public methods* and *reads the scene tree*:

| Need | How | Touches WIP file? |
|---|---|---|
| Force-load route chunks | `preload_route_chunks(latlon_waypoints)` — **exists** (`osm:17819`), public, and it **does NOT pin** (just enqueues async load; chunks unload normally after) | **No** (call only) |
| Know when a chunk's lamps exist | `is_chunk_fully_ready(chunk_key)` — **exists** (`osm:29880`), public | **No** (call only) |
| Get lamp positions | Walk the scene for `StaticBody3D` named **`LampCol`** (`osm:18424`) → `global_position` | **No** (scene read) |

So the whole feature lives in **`race/race_manager.gd`** (bake orchestration — agreed scope) + **`race/racer_ai.gd`**
(consume) + **`main.gd`** (the scout/verify tool, test-only). We can build it now.

---

## 1. Pipeline (4 steps — scout first, per your idea)

```
[1] BAKE+SCOUT (OFFLINE, once): render route, force-load its chunks, harvest LampCol → WRITE a committed
              JSON cache (data/race_poles/<track>.json) + an overhead screenshot to eyeball it. Re-run
              ONLY when the route or OSM data changes (a build step, NOT per-race).
[2] LOAD (RUNTIME): race start just LOADS the committed JSON → spatial hash → opponents. Instant, no
              force-load, no LOADING-window cost. (Optional: live-harvest fallback if the JSON is absent.)
[3] WIRE    racer_ai: query poles near the car → write them into the danger map by POSITION
              (inflated band + skirt, corridor-gated) — precise, no ray-gap, sees around corners
[4] VERIFY  bench "curb_poles" scenario (pole_hits→0, alley doesn't regress) + your drive in main.tscn
```

### 1.5 Cache once, don't compute every race (recommended — your question)
The route is **fixed and coded** (`fanera_sprint`) and lamp positions are **deterministic** (OSM road
polylines + a fixed offset) → the poles along it are **identical every run**. So we bake **once, offline**
into a **committed data file** and just **load** it at race start:

- **Offline (a dev/build step):** the Step-1 scout tool *is* the generator — it force-loads the route, harvests
  `LampCol`, and writes `data/race_poles/fanera_sprint.json` (a `PackedVector3Array`/list of XZ). Commit it.
- **Runtime:** `race_manager` loads that JSON (kilobytes, instant) → spatial hash → opponents. **Zero
  force-load, zero LOADING cost, zero per-race compute** — exactly the "cache/hardcode for the race" you asked
  for. (A data file beats literal GDScript hardcoding — same speed, but regenerable and diff-able.)
- **Staleness guard:** stamp the JSON with the **OSM cache version + route id (or a checksum)**; if it doesn't
  match at load time, log a warning and fall back to a live harvest (or just skip → feeler-only). Regenerate
  the JSON whenever the route/OSM data/lamp-placement logic changes — a one-line re-run of the scout tool.
- **Per track:** one JSON per race track, keyed by track id; new tracks each get baked once.

So the runtime path is dead-simple and cheap; the only place we ever force-load is the offline generator.

---

## 2. Step 1 — SCOUT: "render the route, see where the lamps stand" (your idea)

The smart de-risking first move. A new **env-gated debug tool in `main.gd`** (test-only, like the existing
`RACE_LINEDUMP`), e.g. `RACE_POLEDUMP=1`:

1. Build the `fanera_sprint` route (as the race does).
2. Call `_terrain.preload_route_chunks(track.route_points)` (lat/lon waypoints).
3. **Wait** until the route's chunk keys all report `is_chunk_fully_ready` (poll a few frames; bounded timeout).
4. **Harvest**: `get_tree().current_scene.find_children("LampCol", "StaticBody3D", true, false)` → collect each
   `global_position`. Also project each onto the racing line to get **(arc, lateral offset)** — this tells us
   whether poles sit at the curb (avoidable, big lateral) or intrude toward the line (need threading).
5. **Dump**: print `=>POLE` lines (count, and per-pole `arc / lateral / xz`) + write a JSON, so we can read it
   headless.
6. **(optional) Visual** via the **`godot-verify` skill**: overhead ortho screenshot of the route ribbon with
   a marker at each harvested pole → literally *see* where they stand relative to the line. This is exactly
   "отрендерить маршрут и посмотреть, куда встанут фонари."

**What Step 1 answers (before we touch the AI):**
- Does the harvest work (do we get all poles, at correct positions)?
- How many poles, and how close to the racing line? (Determines the danger inflation + whether corridor-gating
  is even needed.)
- Do poles ever sit *on* the line (need real threading) or only at curbs (the car just needs to not drift into
  them)?
- Does `preload_route_chunks` load the whole route within the LOADING window, and how long does it take
  (cost/risk for Step 2)?

**Cost/risk flagged here:** the route is ~2 km / 24 waypoints → `preload_route_chunks` enqueues *all* route
chunks + neighbors at once. Loading + elevation (network) for the whole route may exceed the ~13 s LOADING
window. Step 1 measures this. If too slow, Step 2 harvests **incrementally** (load a stretch → harvest →
let it unload → next stretch) instead of all-at-once.

---

## 3. Step 2 — LOAD the committed cache at race start (baked offline by Step 1)

The **offline generator** is the Step-1 scout tool (`main.gd RACE_POLEDUMP`): it force-loads the route,
harvests `LampCol` global_positions, dedups by rounded XZ, and writes
`data/race_poles/fanera_sprint.json` (list of XZ + a `{osm_version, route_id}` header). That JSON is
**committed**. At **runtime**, `race/race_manager.gd` (race-start path, after `_build_race_route`) just loads it:

```gdscript
func _load_route_poles() -> void:
    var path := "res://data/race_poles/%s.json" % _track.id
    if not FileAccess.file_exists(path):
        return                                  # graceful: no cache → AI stays feeler-only (no regression)
    var data := JSON.parse_string(FileAccess.get_file_as_string(path))
    if data == null or data.get("osm_version", "") != _terrain.osm_cache_version:
        push_warning("pole cache stale/missing for %s → feeler-only" % _track.id)
        return                                  # staleness guard → fall back (or trigger a re-bake)
    _pole_cache = _build_pole_spatial_hash(data["poles"])   # ~20 m XZ grid hash, O(1) near-queries
    for opp in _opponents:
        if opp.has_method("set_pole_cache"):
            opp.set_pole_cache(_pole_cache)
```

No `preload_route_chunks`, no harvest, no waiting at runtime — instant. (Optional: if the JSON is missing, a
live-harvest fallback could run, but the committed cache is the primary path.)

**Design points:**
- **Zero per-race compute / zero LOADING cost** — the only force-load ever happens in the offline generator.
- **Persistence:** we keep *data* (a Vector3 spatial hash), not chunks → no FPS pin. Poles don't move → valid
  the whole race.
- **Spatial hash** keyed by ~20 m XZ cells so per-tick the AI queries only the handful of poles near it.
- **Staleness guard** via the `{osm_version, route_id}` header (regenerate the JSON when route/OSM changes).
- **Trees?** Same mechanism could bake near-road trees, but they share layer 2 with buildings and are far more
  numerous → **deferred**; poles first (the reported problem).
- **Fallback:** missing/stale cache → current feeler-only behavior (no regression, just no improvement).

---

## 4. Step 3 — WIRE poles into the danger map (racer_ai.gd)

Add `set_pole_cache(cache)` + a query, and feed known poles into `_context_steer`'s danger map alongside the
feelers (which stay for dynamic/unknown hazards):

```gdscript
# in _context_steer, BEFORE/ALONGSIDE the feeler loop:
for pole in _pole_cache.query_near(global_position, CTX_REACH_MAX + 4.0):
    var rel := Vector2(pole.x - global_position.x, pole.z - global_position.z)
    var dist := rel.length()
    if dist > reach: continue
    # corridor gate: ignore poles well outside the drivable path (baked half-width + margin)
    if _pole_lateral_from_line(pole) > _bb_half_ahead + POLE_CORRIDOR_MARGIN: continue
    # bearing → slot(s); write inflated danger (band = pole_r + car_half + margin) + skirt to neighbours
    var bearing := <angle of rel relative to _bb_forward>
    var slot := <nearest slot index for bearing>
    var prox := clampf(1.0 - dist / reach, 0.0, 1.0)
    danger[slot] = max(danger[slot], prox); stat[slot] = true
    # + spill to neighbour slots by the inflation width (skirt) — same as CTX_SPILL
```

**Why this fixes both failure modes:**
- **Single roadside pole on a straight (your bug):** it's now in the danger map *by exact position* from far
  away (no ray-gap, no waiting for a feeler to graze it) → the car eases off the line just enough, precisely.
- **Pole-lined alley (the bench regression):** exact positions → the car writes danger *only* where poles
  actually are, not a fuzzy fat sphere → it threads the gap instead of weaving between rows.
- **Around corners:** known positions don't need line-of-sight → the car prepares before the corner (Fray's
  headline advantage over raycasting).

Feelers stay (cars, debris, anything unbaked). Known-pole danger is *added*, not a replacement.

---

## 5. Step 4 — VERIFY

- **Bench (autonomous):**
  - Add a **`curb_poles`** scenario: poles on **one** side of a straight (real roadside, not the both-sides
    alley), fed to the AI via `set_pole_cache` (so it's the *known-position* path, not just colliders). DoD:
    **pole_hits = 0** while holding the line.
  - Re-run the existing **`poles`** (both-sides alley) scenario → must **not** regress (precise positions →
    no over-react; expect it to *improve* toward 0 too).
  - `overtake` / `linefollow` unchanged (no new weave).
- **main.tscn (needs you):** drive alongside → confirm no more pole clips on straights. The scout screenshot
  (Step 1) already gives visual confidence before this.

---

## 6. Open questions / decisions to confirm

1. **Bake cost during LOADING** (Step 1 measures it). All-at-once vs incremental harvest. If the route can't
   fully load in the LOADING window → incremental, or a coarse pre-warm + top-up as the car streams.
2. **`preload_route_chunks` input** is **lat/lon** `Vector2` waypoints — `_track.route_points` are those
   (confirmed: the debug caller passes `track.route_points`). Good.
3. **Chunk-ready ≠ lamps-placed?** `is_chunk_fully_ready` = stage "ready"; need to confirm `LampCol` colliders
   exist by then (lamp finalize is budgeted). If not, harvest a frame or two later / poll lamp count until it
   stabilizes. (Step 1 will show.)
4. **Corridor gate width** — use the baked line `half` + margin, or a fixed ~5 m. Step 1's lateral histogram
   tells us.
5. **Danger strength/inflation** for a known pole vs a feeler hit — tune so the car gives ~car-width berth
   without over-swerving.
6. **Trees** — deferred (numerous, layer-shared). Revisit if trees also get clipped.
7. **`race_manager.gd` WIP?** Confirm it's clean before editing (bake orchestration goes there). `main.gd` is
   already test-only/uncommitted.

---

## 7. Build order (each step shippable & verifiable)

1. **Scout + generate the cache** (`main.gd RACE_POLEDUMP`): run once headless → force-load route → harvest
   `LampCol` → **write `data/race_poles/fanera_sprint.json`** + one `godot-verify` overhead screenshot.
   *Decide from real data* whether/how to proceed (go/no-go + tuning input) and **commit the JSON**. No AI change.
2. **Load** (`race_manager` reads the committed JSON → spatial hash → set on opponents) + a `get`-only debug
   print. Verify opponents receive N poles, instantly, with no LOADING cost.
3. **Wire** (`racer_ai` danger-by-position) + bench `curb_poles` scenario → pole_hits 0, alley no regress.
4. **main.tscn** drive-confirm with you.

*Compiled 2026-07-08. Extends the § B′ race-bake (Reality Check) and P2 (implementation plan). Crucially, it
avoids the `osm_terrain_generator.gd` WIP by calling existing public methods + reading `LampCol` scene nodes,
so it's unblocked. Plan only — awaiting go-ahead.*
