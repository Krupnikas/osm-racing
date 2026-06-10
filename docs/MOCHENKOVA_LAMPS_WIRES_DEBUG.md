# Mochenkova — street lamps go dark while driving + no wires on streamed chunks

Status: **RESOLVED & user-confirmed (2026-06-10).** File: `osm/osm_terrain_generator.gd`.

## RESOLUTION (the actual root causes — NOT the renderer-limit theory below)

**Lamp bug — `_finalize_lamp_batches_for_chunk` was destructive on re-finalize.** While
streaming, a chunk's lamps arrive across several frames (multiple roads applied over time),
so finalize runs more than once per chunk, each call carrying ONLY the lamps batched since
the last finalize (batch_data is erased each time). The old code FREED the chunk's existing
lights and rebuilt from that partial batch → it destroyed the lamps created by the earlier
finalize while leaving their pole MultiMesh behind ⇒ "poles but no light" on the streets you
drive onto. At static spawn (initial load) every chunk finalizes once with its full batch, so
the bug was invisible there. **Fix: finalize is now ADDITIVE** — it appends the new batch's
lights and never frees the existing ones (poles accumulate the same way). Confirmed: after
driving, lamp count holds (was collapsing 57→9; now 57→62) and near lamps stay lit.

**Wire bug — drain CLEARED jobs for not-yet-loaded chunks.** A road result can be applied
(wire job enqueued) a few frames before its chunk is registered in `_loaded_chunks` (worker
race). The drain cleared any job whose chunk wasn't loaded, permanently dropping it in that
window. **Fix: SKIP (keep) jobs for not-loaded chunks and wait;** `_unload_chunk` already
erases the queue for chunks truly gone. Confirmed: wires now place on streamed chunks while
driving (walked/placed/keys grow; were frozen).

Enhancements added same pass: **continuous wires** (no run/gap per side) and **broken lamps
(~1/19, deterministic by position) are the spark+smoke source** (dark + bluish arc + vapour),
replacing the old wire-joint spark trigger; spark rate/pool increased.

The §B–§G material below is the investigation log (kept for reference). The renderer-
simultaneous-light-limit theory in §F was a DEAD END — disproved by the additive-finalize fix.

---

(Original session-2 investigation notes follow.)

> This doc is the **complete record of everything tried** so nothing is repeated.
> Read §A (ground truth), §B (confirmed-by-test), §C (ruled OUT — do NOT retry),
> §D (changes made), §E (open / next), before touching anything.

---

## §A. Ground truth (user observations — authoritative, do NOT re-verify)

This is about **STREET LAMPS only**. Car headlights / brake / underglow are OUT OF
SCOPE — never investigate them again.

1. Street lamps **glow** when fresh / at spawn (static).
2. As you **drive**, the lamps **near you go dark** — poles stay, light stops. The
   lamps **ahead/far still work** ("near dark, far lit").
3. Stopping the car does **not** bring them back.
4. Tied to **how many lamps have accumulated** / how far you've driven.
5. **Location-specific:** reproduces near **улица Моченкова**; the user could **not**
   reproduce it in other locations.
6. Decisive repro (user): **spawn directly at Mochenkova → lamps glow → drive → they
   go out, even though still nearby.**

Do NOT keep re-confirming the symptom. It is confirmed. Find the cause and fix it.

---

## §B. Confirmed BY TEST this session (facts to build on)

1. **Lamp lights are created correctly, 1:1 with poles.** `_add_lamp_to_batch`
   appends a transform (pole) AND a light_data together (lines ~17590/17595);
   `_finalize_lamp_batches_for_chunk` builds the pole MultiMesh and then
   `_spawn_lamp_light` per light_data. Logged `LAMP-FIN ... poles=N lights=N
   (light_data=N)` always equal. Position ≈ 5.8 m above the surface, energy 2.6,
   `visible = _is_night_mode and not broken`. **Confirmed during real driving too**
   (LAMP-FIN events with `initLoad=false` appear when actually driving with throttle).
2. **No lamp-light leak.** Tracked count `_lamp_lights_by_chunk` stays bounded
   (~20–67); unload frees them (`LAMP-UNLOAD chunk=… freed N lights`, line ~3055)
   and `_lamp_lights_root.get_child_count()` matches the tracked total.
3. **A single lamp DOES light the road at normal energy.** Boost test (energy 200,
   range 50) made the road blaze; even at energy 2.6 with few lights a pool is
   visible top-down (`docs/cfgA_few_normal.png`). So the light, its position, its
   `light_cull_mask` (=all), and the road material are all fine.
4. **After real driving, the near lamps are `visible=true` / `is_visible_in_tree()`
   true but DO NOT GLOW.** So scene-tree visibility is NOT the failure and is NOT a
   valid proof of shading. The GPU is dropping them → **renderer simultaneous-light
   limit (clustered Forward+).** This matches "near dark, far lit" (near froxels are
   more crowded) and "accumulates with how many loaded."
5. **Toggling all street-lamp lights on/off changed the scene very little** — because
   the near ones are already dropped by the renderer in both states.
6. **Frozen-teleport is NOT a faithful repro** — with the car frozen and teleported,
   NO chunk finalizes lamps (`LAMP-FIN initLoad=false` count = 0) and total only
   decays. Real throttle-driving DOES finalize lamps. So earlier "no finalize while
   driving" conclusions from teleport were an artifact. **Repro only by real driving.**
7. Scene has ~108–132 SpotLight3D total: ~50 street lamps + ~74 car headlights
   (NPC+player). (Noted only to explain the light budget — car lights are out of scope.)
8. There are also **entrance OmniLights** ("EntranceLamp", line ~21366,
   `energy = 2.6 if is_night`) added per building entrance — numerous in dense
   residential areas like Mochenkova; they also consume the renderer light budget.

---

## §C. RULED OUT by test/code — do NOT investigate these again

- **Ground/road shader can't receive spot light** — FALSE. `shaders/ground.gdshader`
  has no custom `light()` and no `unshaded` render_mode → uses Godot default lighting
  (includes spot/omni). Also the shader is shared by ALL terrain, so if it couldn't
  receive spots, NO lamp would ever glow — but most do.
- **Lamp-light leak (count grows unbounded while driving)** — FALSE (§B2).
- **Pole/light count mismatch (poles without lights)** — FALSE; always 1:1 (§B1).
- **Broken-lamp roll darkening streets** — `is_broken = randf() < 0.05` (lines 17594,
  18234) is only 5% and can't darken whole streets. (It IS non-deterministic / re-rolls
  on reload — a minor separate nit, not this bug.)
- **Floating-origin / world-offset shift leaving lights behind** — FALSE. `_world_offset`
  is set ONCE at spawn (lines 797–798) and never reassigned during gameplay.
- **Wrong light Y / elevation** — FALSE; lights sit ~5.8 m above the surface (§B3).
- **Chunk-visibility / behind-camera cull hiding the lights** — N/A; lights are parented
  to the global `LampLightsRoot`, not the chunk node.
- **`_recursive_update_lights`** — only touches nodes literally named "LampLight" inside
  chunks; our street-lamp SpotLights are unnamed and in the global root → untouched.
- **CAR lights (headlights/brake/underglow)** — OUT OF SCOPE. Do not touch.

---

## §D. Changes already MADE this session (in code now)

1. **Re-enabled `_cull_lamp_lights()`** call in `_process` (after
   `_process_deferred_lamp_lights`, line ~1882). Keeps the nearest-N street lamps
   `visible`, hides the rest; throttled every 6 frames, night-only.
2. **`LAMP_MAX_ACTIVE_LIGHTS` changed from `const` to `var`** (line ~412) so the cap can
   be tuned live; added `var lamp_cull_enabled := true` to disable the cull for tests.
   Cap currently **48**. **Tested: cap 48 does NOT fix it** (lamps still drop). Cap 16
   was about to be tried when the scene died — NOT yet tested.
3. **`spot_range` 15 → 12** at the three lamp-light creation sites (smaller range →
   fewer froxels touched → less overlap). Already in.
4. **Bug A (wires): `WIRE_SLICE_USEC` guaranteed per-frame wire-drain slice** (const
   ~line 419) + reworked the wire section in `_process_road_queue` (line ~14007) to use
   a deadline measured from "now" instead of the shared frame budget. **Tested by real
   driving: did NOT fix wires** — `walked` stays frozen and `keys=0` after driving, i.e.
   the wire walk still isn't running on streamed chunks (jobs likely enqueued for chunks
   that aren't in `_loaded_chunks` when the drain runs, or not enqueued at all). Needs
   more work; see §E.
5. **Bug A secondary (applied, correct but not sufficient): wire span key + spark-joint
   key are now WORLD-POSITION based** instead of `(way,side,k)` (which collided across
   chunks because k resets per chunk-clip). Lines ~20439, ~20509.
6. **TEMP: `main.tscn` spawn moved to Mochenkova** (OSMTerrain + CoordsLabel
   start_lat=59.143258 start_lon=37.954389). **MUST REVERT** to 59.146174 / 37.939085
   when done.
7. **Debug instrumentation added** (all gated by `lamp_debug`, must be removed/gated
   before commit): `LAMP-FIN` print (finalize poles vs lights), `LAMP-UNLOAD` print,
   `_wire_dbg_ran_frames`, and the `LAMP-DBG` status line now shows `activeCap`,
   `ranFrames`, `Q`.

---

## §E. Tests RUN (so they are not repeated) + their verdicts

| Test | Method | Result |
|---|---|---|
| Count vs distance (leak?) | step-teleport, count scene SpotLights | bounded 108→132; **no leak** |
| Hide all but nearest 6 lamps | live, cull on | foiled — cull overwrote it |
| Hide all but nearest 6 (cull off) | live | near road unchanged (but observed from bad angle) |
| All lamps ON vs OFF | live, top-down | little change → lamps already dropped |
| Hide 74 car headlights | live | near lamps did **not** obviously re-light (ambiguous angle) |
| Boost 1 lamp energy 200 | live, top-down | **blazes** → light works, road receives it |
| cfgA (6 lamps normal) vs cfgB (all 122) | top-down on one lamp | pool present in both → that lamp not dropped at this density |
| Spawn AT Mochenkova, static | screenshot | lamps **glow** |
| Spawn AT Mochenkova, real drive (throttle) | screenshot + counts | lamps go dark near car; `total` 57→~35; near visible but not glowing |
| Frozen-teleport "drive" | — | **artifact**, no finalize; discard |

Observation caveat: wide chase-cam shots are unreliable for judging near lamp pools
(they fall beside/behind the car). Use top-down or aim at a specific pole.

---

## §F. Current best hypothesis (still to PROVE)

Forward+ **clustered renderer drops street-lamp SpotLights once too many lights are
active in the froxels near the camera**. The competing load near the player = street
lamps + entrance OmniLights + car headlights. As you drive into a denser area (Mochenkova
residential/avenue) the count crosses the limit and the nearest lamps stop being shaded
even though `visible=true`. The existing nearest-N cull is the right shape of fix, but
**cap 48 is above the effective limit**, so it doesn't help yet.

NOT yet proven: that lowering the street-lamp cap (e.g. 24/16/8) actually re-lights the
near lamps while driving. The keep-6 live test was inconclusive due to camera angle.

Alternative still possible: a switching-logic bug specific to street lamps that I have
not found (user strongly suspects the on/off decision / "a limit"). The cull is the only
per-frame thing that toggles these lights; `_update_lamp_night_mode` runs only on toggle.

---

## §G. Next steps (do these; don't repeat §C/§E)

1. **Find the working cap by REAL driving** (throttle, not teleport): drive to a spot
   where near lamps are dark, then lower `LAMP_MAX_ACTIVE_LIGHTS` live (24 → 16 → 8) and
   screenshot from the driver/chase view each time. The cap where the **nearest** lamps
   re-light = the renderer's effective budget for lamps in that scene.
2. If even a very low lamp cap doesn't re-light them, the competing lights (entrance
   OmniLights especially, very numerous in residential Mochenkova) are eating the budget
   → the cull must also bound those, or street lamps need priority. Test by hiding ALL
   non-street-lamp lights (entrance OmniLights + car SpotLights) and checking the lamps.
3. Once the cap works while driving, also verify day/night toggle and that the nearest
   lamps are never culled.
4. **Wires (Bug A):** instrument why `walked` stays frozen on streamed chunks during real
   driving — log, per frame, whether `_apply_road_result` enqueues wire jobs for the
   newly-loaded chunks and whether those chunk keys are in `_loaded_chunks` when the wire
   section runs. Fix accordingly (likely: wires enqueued under a chunk key that isn't
   "loaded" yet at drain time, so `wr_arr.clear()` drops them).
5. Revert §D6 (spawn point) and remove §D7 (debug logs) before any commit.

---

## §H. Repro recipe (for next time — use REAL driving)

- Spawn is currently Mochenkova (§D6). Launch `res://main.tscn`, wait for load.
- `NightModeManager.enable_night_mode()`.
- Drive with throttle: `simulate_action("Throttle", true)` … wait … `(…, false)`.
  The GEVP car DOES drive this way (reached 26 m/s, moved ~280 m in 3 s). Do NOT freeze
  + teleport — that is not a faithful repro.
- Watch `LAMP-DBG` status line in `~/Library/Application Support/Godot/app_userdata/OSM
  Racing/logs/godot.log` and screenshot the driver view.
