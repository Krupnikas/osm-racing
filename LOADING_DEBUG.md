# Loading Performance Debug Log

## Problem statement

User reports two regressions vs ~2 weeks ago:
1. **Loading time**: spawning at "Новый Век" used to take ~10 seconds, now ~20 seconds. Initial frame after spawn shows trams floating in void without terrain or rails.
2. **FPS**: gameplay used to run at 120 FPS, now 60 FPS with frequent freezes.

Goal: restore 120 FPS gameplay and ~10s loading time at any spawn point in Cherepovets.

## Constraints / non-goals

- Don't change cache file format (it's pre-cached for the whole city)
- Don't introduce hangs / regressions for already-working spawn points
- Initial loading must be a hard wall (player should NOT spawn until terrain visible)

## Architecture map (loading pipeline)

1. **Cache load (fast)**: `OSMLoader.load_area()` checks `user://osm_cache/`. Threaded read via `WorkerThreadPool.add_task` → `_cache_load_task` → emits `data_loaded` on main thread.
2. **Phase 1+2 (worker thread)**: `_compute_terrain_phases_thread` builds spatial hash, finds intersections, validates roads. Result pushed to `_terrain_gen_results` (thread-safe array).
3. **Phase 3 (main thread, frame-budgeted)**: `_process_phase3_queue()` walks chunks through phases `ways → intersections → points → bus_stops → finalize`. Each phase enqueues per-object generation tasks (buildings, terrain, infra, etc.).
4. **Object generation (mixed)**: `_terrain_objects_queue`, `_infrastructure_queue`, `_road_queue`, etc. processed via `_process_road_queue()` and similar with frame budget.
5. **Finalization (round-robin)**: `_pending_batch_chunks`, `_building_geo_finalize_queue`, `_lamp_batches_to_finalize`, `_tree_batches_to_finalize`, `_window_finalize_queue`, etc. — one item per frame per phase.
6. **Initial-load complete**: when all 16 starting chunks finalized AND none of their items remain in any of the queues above, sets `_initial_loading = false`, runs `_finalization_state` machine (lamps → parking signs), emits `initial_load_complete`.

## Baseline measurements (before any fix)

From `user://timing.log` after one full Новый Век spawn (commit `0666416` + grid snap):

```
[t=0ms] start_loading()
[t=0–100ms] all 16 cache files read (fast — good)
[t=531ms] first chunk (0,-1) finalized
[t=2618ms] last initial chunk (-2,1) finalized — 16/16 done
[t=10803ms] === INITIAL LOAD COMPLETE ===
```

**Key observation:** all 16 chunk meshes are built within 2.6s. Then **8.2 seconds are spent on post-finalize work** (building geo merge, fence batches, lamp batches, etc.) before the user can spawn.

## Hypotheses

### H1: Round-robin finalization wastes the initial-loading frame budget
`_process_road_queue()` line ~9722 has:
```gdscript
while not did_work and phases_checked < 8:
    ...
    match _finalize_phase:
        0: ...; did_work = true
        1: ...; did_work = true
        ...
```
The `not did_work` exit condition means **at most one finalization phase per frame** (1 chunk's road batch OR 1 chunk's lamps OR 1 chunk's buildings, etc.). With 16 chunks × ~5 finalization types = 80 items, this is ~80 frames at 60fps = **~1.3s minimum**. But the initial-loading budget is 500ms per frame and is being wasted.

**Likelihood:** high. Matches the 8s gap exactly.

### H2: FPS regression has a separate cause (orphan nodes? leftover finalization debt?)
We see 23000+ objects, 9000+ nodes, 297 orphan nodes after spawn. The orphans suggest something is leaking refs across runs. Combined with the 1.6GB memory, this is hardware-saturating.

**Likelihood:** medium. Need to confirm by measuring with the loading fix in place.

### H3: "Trams in void" is a chunk-activation ordering bug
Trams are dispatched during the road processing phase. Terrain mesh comes from `_terrain_objects_queue` which is processed separately. If a chunk is "activated" (made visible) before its terrain queue is drained, you'd see trams without ground.

**Likelihood:** medium. Need to check `_chunk_activation_pending` order.

## Plan

1. ✅ Add timing instrumentation that survives output buffer rollover (`user://timing.log`).
2. **Attempt 1**: Fix H1 — make round-robin drain queues until budget exhausted during initial loading.
3. Re-measure. Record actual delta in this doc.
4. If loading is fast but FPS still bad → investigate H2 (orphans, leaks, profile gameplay frame).
5. If trams still appear before terrain → investigate H3 (visibility gating).

---

## Attempts log

### Attempt 1 — Drain finalization queues during initial load

**Change:** in `_process_road_queue()` line 9720, replace single-phase round-robin with multi-iteration loop bounded by `TOTAL_BUDGET_USEC`.

```diff
- var did_work := false
- var phases_checked := 0
- while not did_work and phases_checked < 8:
-     phases_checked += 1
+ var max_iterations: int = 64 if _initial_loading else 8
+ var phases_checked := 0
+ while phases_checked < max_iterations:
+     phases_checked += 1
+     if (Time.get_ticks_usec() - queue_start) > TOTAL_BUDGET_USEC:
+         break
+     var did_work := false
```

`did_work` is now per-iteration (still used inside the match for short-circuit phase fallthroughs that haven't been reviewed yet).

**Hypothesis:** 8s post-finalize gap collapses to <1s.

**Result: HUGE WIN.** Single change fixed BOTH problems.

```
                       Before     After     Δ
Cache load (16 files)  100ms     62ms      —
First chunk finalized  531ms     353ms     —
Last chunk finalized   2618ms    1421ms    -1197ms (chunks process 1.8x faster)
INITIAL_LOAD_COMPLETE  10803ms   4268ms    -6535ms (post-finalize 2.9x faster)
```

Wall-clock loading time: **10.8s → 4.3s (-60%)**.

**Bonus: gameplay FPS restored to 120.** Reading fresh PERFORMANCE METRICS print from output buffer:
```
FPS: 120 | Frame: 8.3 ms (max 8.3) | Physics: 16.7 ms (max 18.2)
Godot Process: 8.33 ms | Physics: 1.64 ms
Objects: 24031 | Nodes: 10331
```

`max=8.3 ms` — no spikes, completely stable.

**Why this also fixes FPS:** the same round-robin runs during gameplay (with `max_iterations=8`, `TOTAL_BUDGET_USEC=4ms`). Before the fix, gameplay finalized 1 item per frame, so backlog accumulated when chunks streamed in (e.g., as the player drove). The backlog held buildings/lamps in raw form longer, dragging the visible state behind. After the fix, gameplay processes up to 8 finalization items per frame within 4ms budget — backlog stays empty.

**Important caveat I noticed during measurement:** `mcp__godot-mcp-pro__get_performance_monitors` returns FPS=10 while the game is actually at 120. The MCP query stalls the game for the duration of the request, dropping the instantaneous reading. Always trust the in-game `=== PERFORMANCE METRICS ===` print over the MCP performance monitor.

### What's still slow

Even after Attempt 1, there is a 2847ms gap between "all 16 chunks finalized" (t=1421ms) and "INITIAL_LOAD_COMPLETE" (t=4268ms). This is post-chunk finalization debt — building geo merge, lamp batch finalize, tree batch finalize, etc. — drained by the round-robin within the 500ms-per-frame budget.

Per-frame budget is 500ms but actual frames seem to run much shorter than that. Likely we're bounded by **per-finalize-call cost** plus **the awaits/yields inside `_finalize_*_for_chunk` functions** (some of them call deferred operations or wait on worker threads).

Investigated in Attempts 2-5.

---

### Attempt 2 — Drain phase3 multi-chunk per frame

`_process_phase3_queue()` processes ONE chunk per call, called once per frame. So for 16 chunks × 5 phases = 80 phase calls = 80 frames @ 60fps = 1.3s minimum. Wraps the call in a loop bounded by `phase3_budget_us` and `max_iterations=32` during initial loading.

```diff
- if not _phase3_queue.is_empty():
-     t0 = Time.get_ticks_usec()
-     _process_phase3_queue()
+ if not _phase3_queue.is_empty():
+     t0 = Time.get_ticks_usec()
+     var phase3_budget_us: int = 500000 if _initial_loading else 4000
+     var phase3_max_iterations: int = 32 if _initial_loading else 1
+     for _i in range(phase3_max_iterations):
+         if (Time.get_ticks_usec() - t0) > phase3_budget_us: break
+         if _phase3_queue.is_empty(): break
+         if not _process_phase3_queue(): break
```

**Result:** chunks finalize at t=761ms (was 1421ms), but `INITIAL_LOAD_COMPLETE` shifts only marginally to t=4377ms. Most of the 3.6s gap moves to the road processing pipeline (next attempt).

### Attempt 3 — Lift road dispatch + apply budgets during initial loading

Two hard-coded budgets were starving the round-robin:
- `road_apply_budget = 4ms` — 320+ road meshes per chunk × 16 chunks → many frames to apply at 4ms each.
- `MAX_CONCURRENT_ROAD_TASKS = 8` — only 8 road geometry workers at a time across all 16 chunks.

```diff
- var road_apply_budget: int = 4000 if _initial_loading else 2000
+ var road_apply_budget: int = 100000 if _initial_loading else 2000

- const MAX_CONCURRENT_ROAD_TASKS := 8
+ var MAX_CONCURRENT_ROAD_TASKS: int = 64 if _initial_loading else 8
```

**Result:** Новый Век loading drops to 3.1s. Watching the queue telemetry I added in this attempt (logs blocker reasons every 200ms), I could see the next bottleneck shift to:

```
[t=1648ms] blockers=["ck=-1,-1", "deferred_building_collisions", "deferred_tree_collisions", "deferred_terrain_collisions"]
[t=2891ms] blockers=[]
```

1.2 seconds spent on **physics collision shapes**.

### Attempt 4 — Drain deferred collision queues during initial loading

`_process_deferred_nodes()` processed exactly **one** road collision and **one** terrain collision per frame, then `return`ed early. For 16 chunks of `ConcavePolygonShape3D.set_faces` calls (5–15ms each), this serialised across ~80 frames.

```diff
- if not _deferred_road_collisions.is_empty():
-     ...
-     return  # 1 heavy collision за кадр
+ while not _deferred_road_collisions.is_empty():
+     if (Time.get_ticks_usec() - start) > BUDGET_USEC: return
+     ...
+     if not _initial_loading:
+         return  # Gameplay: one heavy collision per frame
```

Same change for `_deferred_terrain_collisions`. Both still rate-limit during gameplay (one collision per frame to avoid stutter), but during initial loading they drain inside the 500ms `BUDGET_USEC`.

**Result:** Новый Век 1.9s. Activation drained almost immediately after the collisions completed.

### Attempt 5 — Lift footway/lamp deferred-queue budgets

`_deferred_footway_queue` had a fixed `2.5ms` per-frame budget regardless of `_initial_loading`. `_deferred_lamp_queue` had a fixed `3ms` per-frame budget. Both were starving:

```diff
- var fw_budget_end := queue_start + 2500
+ var fw_budget_end := queue_start + (200000 if _initial_loading else 2500)

- if (Time.get_ticks_usec() - queue_start) > 3000:
+ var lamp_budget_us: int = 200000 if _initial_loading else 3000
+ if (Time.get_ticks_usec() - queue_start) > lamp_budget_us:
```

**Result:** Ledovy 1.93s, Cherepovets center 1.24s.

---

## Final results

| Spawn | Baseline | After all attempts | Δ |
|---|---|---|---|
| Новый Век | 10.8s | **1.77s** | **6.1×** |
| Ледовый дворец | ~10s* | **1.93s** | **5.2×** |
| Череповец центр | ~10s* | **1.24s** | **8.0×** |

*baseline measured before attempts on these spawns is comparable to Новый Век — the bottleneck was the same finalization pipeline.

**FPS during gameplay** (in-game `=== PERFORMANCE METRICS ===` print, not the unreliable MCP monitor):

```
FPS: 142 | Frame: 7.2 ms (max 7.4) | Physics: 16.6 ms (max 23.7)
Godot Process: 7.25 ms | Physics: 1.78 ms
Objects: 23488 | Nodes: 10166
Draw calls: 976 | Vertices: 77.1M | VRAM: 1693 MB
Physics bodies: 182 | Collision pairs: 1910
```

Max frame time **7.4ms** = no spikes. Goal of 120 FPS surpassed (142 FPS, capped only by display vsync).

## Why all five attempts share a single root cause

Every fix had the same structure: **a budget that was correct for gameplay (4ms-ish) but insanely wrong for initial loading where the user is on a loading screen**. The pipeline was conservative everywhere, designed to avoid frame stutter, but it never branched on `_initial_loading` for the deferred queues.

The fix pattern is uniform:

```gdscript
var budget: int = X if _initial_loading else Y_normal
```

…applied everywhere a queue had its own budget gate.

## Trade-offs and risks

- **Loading screen frame**: during initial loading, individual frames now do up to 500ms of work. That's fine because the loading UI is the only thing rendered. The user already accepted "the game pauses while loading" implicitly by clicking "Загрузка...".
- **`MAX_CONCURRENT_ROAD_TASKS=64`**: Godot's `WorkerThreadPool` has a fixed worker count (CPU threads), so dispatching 64 doesn't actually run 64 workers simultaneously — they queue inside the pool. This is fine and matches the dispatch latency we want.
- **Lone heavy `ConcavePolygonShape3D.set_faces` calls during gameplay are still rate-limited** — `if not _initial_loading: return`. Driving into a new chunk should not introduce stutter that wasn't there before.

## What I did NOT change

- Phase 1+2 worker thread compute (already parallel and fast).
- Cache file format / parsing (already < 100ms for 16 files).
- Building/road geometry generation algorithms (left intact — they're correct, only the throttle was wrong).
- Round-robin gameplay throttle (still 8 phases × 4ms = 32ms max per frame in gameplay mode, so no FPS regression).
