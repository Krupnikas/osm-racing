# Road Bending Debug Log

## Problem
Road 45481833 near crossing node 13310617642 appears to bend/break sideways before the pedestrian crossing, creating a gap where no texture is rendered. The road is ABSOLUTELY STRAIGHT in OSM data.

## Affected Objects
- **Road way**: 45481833
- **Crossing node**: 13310617642
- **Location**: Near ice palace spawn point (59.089216, 37.917488)

## Investigation Log

### Step 1: Initial Analysis
- Status: COMPLETED
- Explored road rendering pipeline: `_compute_road_geometry_thread()` builds mesh vertices using perpendicular offsets from smoothed centerline

### Step 2: Debug Output for Way 45481833
- Added debug prints for raw/smoothed/validated/final points and perpendiculars
- Found critical issue in chunk 0,-1:

```
final[1] = (2.943, 6.172)
final[2] = (1.012, 0.766)    ← perp INVERTED: (-0.9427, 0.3337)
final[3] = (1.082, 0.962)    ← this point is CLOSER to start than final[2]!
```

**Root Cause**: Catmull-Rom smoothing created a micro-loop near the crossing node. After `_validate_road_direction`, two very close points remained in reverse order (0.21m apart, going backwards). This caused the perpendicular at final[2] to flip 180°, creating a "butterfly" mesh crossing.

### Step 3: Fix — Backtracking Point Removal
- Added second pass in `_validate_road_direction()` to remove:
  1. Points where consecutive segments reverse direction (dot < 0)
  2. Points very close to previous (<0.5m) that create kinks
- Result: chunk 0,-1 went from 8→7 points, problematic point removed
- All perpendiculars now consistent (~0.94, -0.34)
- Status: SUCCESS ✓

---

## Problem 2: Z-fighting at intersection of roads 60119987 and 84060676

### Step 1: Investigation
- Roads share common OSM node at (103.532, -455.699)
- Way 60119987: primary, width=12, height_offset=0.010
- Way 84060676: primary_link, width=5, height_offset=0.006 (was missing from match → fell to default)
- z_offset (hash-based) up to 3mm could invert height ordering

### Step 2: Fix Attempt — Link height + z_offset reduction
- Added `_link` types to height match (primary_link → 0.011, above primary 0.010)
- Reduced z_offset factor from 0.00003 to 0.000005 (max 0.5mm instead of 3mm)
- **Result: FAILED** — z-fighting still present
- User feedback: "parabolic shape, mainly on main road 60119987"
- This suggests the z-fighting is NOT between the two roads, but between the road and something else (intersection patch? chunk overlap?)

### Step 3: Hypothesis — intersection patch vs road mesh
- Checked `_create_intersection_patch`: uses `height_offset + 0.005` = 0.015 for primary. Higher than road (0.010). Not the cause.
- Checked crossings: height 0.016-0.017, also higher. Not the cause.

### Step 4: Fix Attempt — Consistent z_offset via local_points[0] hash
- z_offset was computed from `points[0]` (AFTER clip to chunk), so same road had different heights in different chunks
- Changed to hash from `local_points[0]` (BEFORE clip) so all chunks get same z_offset for same road
- Confirmed: way 60119987 now hash=40, total_h=0.01020 in both chunks
- **Result: FAILED** — z-fighting still present, unchanged
- The z-fighting is NOT caused by inter-chunk height mismatch

### Step 5: Deeper investigation
- Confirmed z_offset now consistent (hash=40 in all chunks)
- **Result: STILL FAILED** — z-fighting unchanged
- Not inter-chunk z_offset mismatch
- Way 60119987 present in 13 cache files, road mesh rendered from multiple chunks but with consistent height
- Chunk `1,-2` processed 4 times but none produced vertices (all outside chunk bbox after clip)
- User visual feedback: "two gray surfaces (roads) flickering, parabolic curved shape on one side, converging to a point on the other"
- This shape = exactly where primary_link (84060676) mesh overlaps primary (60119987) mesh
- The link curves away from primary, creating overlap that starts wide and narrows to a point
- Confirms: z-fighting IS between the two road meshes at their junction

### Step 6: Fix Attempt — Increase link height to 0.015 (5mm above primary)
- primary: 0.01020, primary_link: 0.01525. Gap = 5mm
- **Result: PARTIALLY WORKED but WRONG APPROACH**
- Z-fighting changed shape — parabolic tail still remains
- Link being higher made its lane markings extend visibly over the primary road — incorrect visual
- Conclusion: the z-fighting is NOT between link and primary road
- The raised link merely MASKED part of it; remaining parabolic tail proves another surface is fighting
- **Must revert link height change** — it creates incorrect visuals (link markings over primary)

### Step 7: Terrain corridor hypothesis — RULED OUT
- Not link vs primary (raising link only masked part)
- Not intersection patch (at height_offset + 0.005, confirmed higher)
- Not inter-chunk mismatch (consistent hash now)
- Hypothesized: **terrain corridor edge** — the grass terrain polygon boundary where road corridor was cut out
- **RULED OUT**: terrain mesh is at Y=0.22, roads at Y=0.01. 21cm gap — z-fighting impossible between them.

### Step 8: Reverted link height changes
- primary_link reverted to share height with primary (0.010)
- secondary_link reverted to share height with secondary (0.008)
- motorway_link/trunk_link reverted to share height with motorway/trunk (0.012)
- Link types now use same lane-based texture as parent (`("ow%d" if is_oneway else "bi%d") % lanes`)

### Step 9: Discovery — DUPLICATE CHUNK LOADS
- Added debug prints showing chunk and margin info per road
- **CRITICAL FINDING**: Way 60119987 processed MULTIPLE TIMES in same chunk:
  - chunk `0,-2`: 2 times
  - chunk `1,-2`: 3 times
  - chunk `-2,-2`: 2 times (in later run)
- Also confirmed: `"Chunk X data loaded"` appears multiple times:
  - chunk `-2,0`: 3 times
  - chunk `-2,-2`: 3 times
  - chunk `-1,-1`: 3 times
  - chunk `0,-2`: 2 times
- **Root cause**: `_on_chunk_data_loaded` callback fires multiple times for same chunk. Likely from failover retries (HTTP timeout → retry to different Overpass server, but original response also arrives later). Both callbacks pass the `_loading_chunks.has(chunk_key)` check because chunk is not removed from `_loading_chunks` until finalization.
- This creates duplicate road meshes at identical height → z-fighting

### Step 10: Fix Attempt — Dedup guard (stage != "")
- Added guard: if `_chunk_state[chunk_key].stage` is not empty, reject callback
- **Result: BROKE EVERYTHING** — game hung on chunk loading
- `_chunk_state` is initialized with stage `"requested"` before HTTP request starts
- Guard rejected ALL callbacks because stage was already `"requested"`
- Documented and fixed immediately

### Step 11: Fix Attempt — Dedup guard (stage not in ["", "requested"])
- Changed guard to only reject if stage is beyond `"requested"` (i.e., `"http_loaded"` or later)
- **Result: FAILED** — duplicates still present
- Chunk `-2,-2` still loaded 3 times, way 60119987 still processed 3 times in that chunk
- Problem: multiple callbacks arrive nearly simultaneously, all while stage is still `"requested"`. First callback sets stage to `"http_loaded"`, but by then the second is already past the guard check.
- Need atomic dedup: remove from `_loading_chunks` immediately on first callback, or use a separate `_chunk_data_received` set

### Step 12: Fix Attempt — Atomic dedup via `_loading_chunks.erase` + `_loaded_chunks`
- Moved `_loading_chunks.erase(chunk_key)` and `_loaded_chunks[chunk_key] = true` to start of callback
- Idea: duplicate callback hits `not _loading_chunks.has()` check and is rejected
- **Result: BROKE CHUNK LOADING** — chunks stopped appearing (no textures, no buildings, minimap worked)
- `_loaded_chunks[chunk_key] = true` made system think chunk was fully loaded before generation
- Unload/reload cycle couldn't reload because `_loaded_chunks.has()` returned true

### Step 13: Fix Attempt — Separate `_chunk_data_received` dictionary
- Added `var _chunk_data_received: Dictionary = {}` — tracks which chunks received HTTP data
- Guard: `if _chunk_data_received.has(chunk_key): return` before processing
- Cleared on unload and reset
- **Result: PARTIALLY WORKED** — z-fighting gone, but rounding textures also disappeared
- Chunk `1,-1` still showed 5 loads due to unload/reload cycles (normal behavior)
- But WAY 60119987 still showed duplicates per chunk (dedup didn't fully work for close callbacks)

### Step 14: Finding — Rounding textures disappeared with z-fighting
- User observation: z-fighting AND road rounding textures disappeared simultaneously
- Root cause of missing roundings: unrelated to dedup — caused by merging `primary_link`/`secondary_link` into parent match cases in Step 8
- Merging changed `primary_link` texture from `"residential"` to lane-based (`"bi4"`) — wrong texture for narrow link roads
- **Fix**: separated link types back to own match cases with `texture_key = "residential"` but at SAME height as parent (0.010 for primary_link, 0.008 for secondary_link)

### Step 15: Current hypothesis — sharp angle smoothing at link junction
- The z-fighting may be caused by Catmull-Rom smoothing creating overlapping geometry where link meets primary at a sharp angle
- Link road 84060676 diverges from primary 60119987 — sharp angle at junction
- Smoothing could extend link mesh backward, overlapping with primary mesh
- Needs investigation: check smoothed points of link road near junction point

### Step 16: Verification — z-fighting returned with link textures
- Restored link types to separate match cases with `texture_key = "residential"`, same height as parent
- **Result: z-fighting RETURNED**
- Rounding textures restored — confirming they come from the link road itself
- **CRITICAL INSIGHT**: z-fighting disappears when link uses SAME texture as primary (lane-based), returns when link uses DIFFERENT texture ("residential")
- This proves: z-fighting IS between link mesh and primary mesh at their overlap zone
- The overlap is invisible when both use same texture (identical pixels), but visible as z-fighting when textures differ
- Dedup fix was a red herring — it coincidentally changed rendering but didn't fix root cause
- **Root cause confirmed**: Catmull-Rom smoothing extends link road mesh backward past junction point, creating overlap with primary road mesh. Both at same height (0.010) but different textures → z-fighting

### Step 17: Investigating smoothing overlap at junction
- Hypothesis: smoothing of link road 84060676 extends its geometry backward into primary road 60119987 territory
- Need to check smoothed vs raw points of link near shared junction node

### Step 18: Smoothed points analysis confirms overlap
- Link raw[0] = (103.532, -455.699) = same as primary raw[5] — shared junction node
- Primary width=12m (half=6m), link width=5m (half=2.5m)
- Link mesh (5m wide) starts entirely INSIDE primary mesh (12m wide) at junction
- Smoothed link points [0]-[3] run along primary road direction before diverging
- This creates a wide overlap zone: link "residential" texture over primary "bi4" texture at same height → z-fighting
- The "parabolic" shape = link road narrowing as it curves away from primary
- **Raising link height (Step 6)** partially worked because it lifted most of overlap, but "tail" remained where smoothing extended beyond simple offset

### Step 19: Fix — Trim link mesh at junction overlap
- For `_link` road types: trim smoothed points that are within `parent_half_width + 0.5m` of junction node
- parent_half_width: primary=6m, secondary=5m, motorway/trunk=7m
- Trim both start and end (link may connect to parent at both ends)
- Only trim if remaining polyline has >= 2 points
- This removes the link mesh from the overlap zone entirely

### Step 20: Trim too aggressive — FAILED
- Removed ALL rounding textures at ALL intersections
- Trim distance `parent_half_w + 0.5m` was too large — link roads are mostly "roundings"
- Reverted trim completely

### Step 21: Angle analysis — USER HYPOTHESIS CONFIRMED
- Link raw[1] angle = **39.3°** — sharp turn right after junction node
- Catmull-Rom smoothing creates 3 extra points (smoothed[1]-[3]) at distances 1.9m, 4.65m, 7.57m from junction
- Points smoothed[0]-[2] (0m to 4.65m) are FULLY inside primary mesh (half_w = 6m)
- Primary road is perfectly straight (all angles 0.0°)
- Even without smoothing, raw[0] is at the CENTER of primary road — link mesh always starts inside
- Smoothing makes it worse: more mesh triangles in the overlap zone, extending up to 7.57m
- **This IS the z-fighting**: link "residential" texture overlapping primary "bi4" texture at same height

### Step 22: Fix Attempt — Shift link raw[0] to parent road edge before smoothing
- Instead of trimming smoothed points (Step 19), shift raw[0] along link direction by parent_half_w BEFORE smoothing
- Idea: link starts at edge of parent road, smoothing creates curve from there, no overlap
- Also shift last point (link may connect to parent at both ends)
- Shift capped at 50% of segment length to avoid overshooting
- **Result: FAILED — z-fighting WITH BOTH SIDES of link**
- User: "ФАЙТИНГ С ОБЕИХ СТОРОН ЛИНКА"
- Shifting both ends created gaps AND z-fighting at both junction points
- The shift distance (6m) was correct for one end but wrong for the other (which may connect to a different-width road)
- Also: shifting raw[0] by 6m still leaves link mesh partially inside primary (link has 2.5m half-width, so edge extends 2.5m beyond shifted center — still inside 6m parent edge)

### Summary of ALL attempts:
| # | Approach | Result |
|---|---------|--------|
| 2 | Link height + z_offset reduction | FAILED |
| 4 | Consistent z_offset hash | FAILED |
| 6 | Raise link 5mm | PARTIAL — markings visible, tail remains |
| 8 | Merge link with parent texture | Z-fighting gone but roundings gone too |
| 10-13 | Dedup guards | Various failures, not root cause |
| 19-20 | Trim smoothed points | ALL roundings gone |
| 22 | Shift raw[0] to parent edge | FAILED — z-fighting both sides |

### Current Status: IN PROGRESS
- The ONLY approach that eliminated z-fighting was using same texture (Step 8), but that removes visual roundings
- Need approach that keeps "residential" texture on link but prevents z-fighting
- Remaining untried: raise link by minimal amount (1mm) — Step 6 used 5mm which was too much
