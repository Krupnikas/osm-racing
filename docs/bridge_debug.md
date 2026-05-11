# Bridge ↔ Road Junction Gap — Debug Log

**Status:** Unsolved. Stop attempting fixes until root cause is verified.

## Governing Rule (NON-NEGOTIABLE)

**Никаких воркэраундов. Не закрываем части гэпа. Делаем слитное, равное по ширине полотно, в стык, абсолютно как на карте.**

- Closing only the longitudinal gap is NOT a result.
- Closing only the lateral gap is NOT a result.
- Width mismatch is NOT acceptable. Z-fight overlap is NOT acceptable.
- The success criterion is binary: fully seamless edge-to-edge alignment, or not done.
- No synthetic stitch geometry, no snap-to-outline, no inside-polygon overrides, no shift hacks. Root cause only.
- Every attempt and observation must be written here as it happens.

## The Problem

OSM data for Октябрьский мост:
- Polygon `man_made=bridge` (relation 13095564) has vertex 17 at coord (59.1172106, 37.9035319).
- Way 43844947 (`secondary_link cutting=yes layer=-1`) has node[0] at the SAME coord.
- Way 43844912 (`secondary_link bridge=yes layer=1`) shares node[0] with 43844947 (= polygon vertex).
- **In OSM, road and polygon connect EXACTLY at vertex 17 — no gap, no offset.**

In the game, there is a visible HORIZONTAL gap between the road approach and the bridge edge.

## Verified Facts

### Polygon geometry near junction (vertex 17 = node[0] of 43844947)
```
[-3] idx=14 ( -1.45,  -34.30) m  — 34m south, almost on road axis
[-2] idx=15 ( +6.36,   -1.04) m  — 6m east of node, 1m south
[-1] idx=16 ( +5.54,   -0.91) m  — 5.5m east, 0.9m south
[+0] idx=17 (  0.00,    0.00) m  — TARGET (= shared with road)
[+1] idx=18 ( -5.92,   +0.97) m  — 6m west, 1m north
[+2] idx=19 (-21.19,  -53.38) m  — 21m west, 53m south (jumps far)
[+3] idx=20 (-22.23,  -32.92) m
```

**Polygon at vertex 17 spans ~12 m perpendicular to the road** (vertex 16 east → vertex 18 west). Vertex 17 itself sits on the centerline. Road approach width = ~6 m. Polygon includes lanes + sidewalks/railings.

### Stage 2A.3 Y formula
- `_deck_surface_y_at(point, polygon, 1, ref_elev)` returns deck_top=130 for points projecting into long-axis middle.
- For node[0] (lat 59.1172, polygon long axis south at 59.1089 north at 59.1181), projection lands in middle (100m from north end, 922m from south end). Returns deck_top=130.
- Bridge mesh's vertex 17 Y = `_deck_surface_y_at(vertex 17, polygon, 1, ref_elev)` = 130.
- Road sampler at node[0] returns SAME value via Stage 2A.3 unified function. Match guaranteed.

### Road processing pipeline (`_compute_road_geometry_thread`)
1. `local_points` = OSM nodes converted to local XZ. `local_points[0]` = node[0].
2. **`_link` shift (line ~4532):** for `_link` highway types (incl. secondary_link), shifts `local_points[0]` by `parent_hw=5` m FORWARD along road direction (away from junction). Comment: "to avoid Z-fight with parent road".
3. `_smooth_road_corners(local_points)` → smoothed Catmull-Rom polyline.
4. Chunk clipping (line ~4593) with margin = width/2 ≈ 3 m.
5. Validate, clip again, insert chunk-edge points, subdivide for elevation.
6. Mesh build: per-vertex Y via `_road_sample_y_for_way` (Stage 2A.3).

### Bridge mesh (`_create_bridge_deck_mesh`, NOT modified)
- Triangulates polygon outline directly. Vertex 17 IS a triangulation vertex.
- Each polygon vertex's Y = `_deck_surface_y_at(v, polygon, 1, ref_elev)` = deck_top for lateral edges.

## Approaches Tried (and failed)

### 1. Stage 2A way-aware ramp (initial Stage 2A)
**What:** Sampler `sample_road_y_for_way(way_id, point, ...)` filters candidates by way_id. Project onto ramp polyline, blend with `lerp(portal_y, terrain_y, smoothstep)`.
**Result:** Road elevated to deck level. APPLY logs show cand=130. **But the formula DIVERGED from `_deck_surface_y_at` near polygon edge** — at d=27m, sampler returns 123, bridge formula returns 130 → 7m mismatch at outline.

### 2. Stage 2A.3 unified formula
**What:** Replaced ramp-polyline blend with `_deck_surface_y_at(point, polygon, 1, ref_elev)` directly. Same formula bridge mesh uses → guaranteed match.
**Result:** APPLY logs show cand=130 throughout. Y formulas now agree. **Visual gap still present.** → Y is correct; gap is HORIZONTAL/structural, not Y-related.

### 3. CLIP polyline against polygon
**What:** `Geometry2D.clip_polyline_with_polygon(points, polygon)` to truncate road to outside-polygon parts only.
**Result:** Road truncated correctly (49 → 42 verts). Last vertex on polygon edge. **Gap persists.** Y at last vertex = ramp blend value (≠ bridge mesh Y) — root of original divergence.

### 4. Polygon-edge boundary insertion (`STITCH`)
**What:** Insert synthetic vertex AT polygon edge crossing in road polyline.
**Result:** STITCH fires for some chunks. Boundary vertex at outline. **Gap persists.** Sampler may return terrain (perpendicular distance > 4 m to ramp polyline).

### 5. Inside-polygon override
**What:** When `way_owns_ramp` and point inside polygon, return deck Y directly.
**Result:** Caused vertical wall artifacts (some inside-polygon vertices at deck Y, some not, mixed).

### 6. Through-pass filter
**What:** In `_detect_polygon_bridges`, reject ways without inside-polygon node connecting to bridge=yes.
**Result:** Fixed under-bridge-road-lifted regression. ✅ Kept.

### 7. Smart EXTEND polyline
**What:** Cast tangent ray from polyline endpoint toward polygon edge. Insert intersection.
**Result:** EXTEND fired in wrong direction for chunks where polyline runs AWAY from polygon. Created artifacts.

### 8. SNAP polyline to polygon outline
**What:** Move endpoint to closest polygon outline point if within 5 m.
**Result:** Endpoints on outline (per FINAL log d=0.00). **Gap still visible.** Mesh edges may not align with polygon edges.

### 9. Polygon-proximity gate in sampler
**What:** If point inside or within 5 m of polygon outline, use deck Y formula. Smoothstep blend beyond.
**Result:** Edge vertices near polygon now sample at deck Y. **Some visual progress** ("патчка появилась на уровне рампы"). But gap persists at edge.

### 10. Skip `_link` shift for bridge endpoints
**What:** When `_bridge_endpoint_touches_any(node_lat, node_lon)` true, don't shift `local_points[0]`.
**Result:** Road's first vertex AT polygon vertex coord (FINAL d=0.00). **Gap still persists** per user. Reverted.

### 11. Reverse `_link` shift for bridge endpoints
**What:** Shift `local_points[0]` BACKWARD into polygon by `parent_hw` so road mesh OVERLAPS bridge mesh.
**Result:** Road overlaps polygon by 5 m, but **width didn't match** polygon outline shape. Visible artifact patch. User: "это воркэраунды!"

## Hypotheses for Root Cause

### Hypothesis A: Mesh edges don't align (most likely)
- Bridge polygon mesh has vertex 17, with adjacent edges going to vertex 16 (5.54 m east) and vertex 18 (5.92 m west).
- Road mesh has vertex at node[0] (= vertex 17), with edges going perpendicular to road (l[0], r[0] at ±half_width = ±3 m).
- At vertex 17, the two meshes share ONE POINT but their adjacent edges go in DIFFERENT directions.
- Mesh triangulation needs to share EDGES (not just points) to render seamlessly.
- Even if Y values match exactly, the meshes only "kiss" at one point — no shared edge → triangular gaps possible due to floating-point or texture differences.

### Hypothesis B: Polygon's wider extent at node[0] (12 m total) vs road width (6 m)
- Polygon's perpendicular extent (vertex 16 → 18 = 11.46 m) > road width (~6 m).
- Bridge mesh edge perpendicular at vertex 17: from vertex 16 to vertex 17 to vertex 18. Direction along ~6m east + ~6m west = roughly perpendicular to road but with an angle.
- Road mesh edge perpendicular at l[0]/r[0]: exactly perpendicular to road direction at ±3 m.
- Even if road extends INTO polygon (overlap), the polygon edge near vertex 17 doesn't align with road's perpendicular line.
- Result: triangle of polygon NOT covered by road, triangle of road NOT covered by polygon → both visible as separate textures.

### Hypothesis C: Smoothing or chunk-clipping moves road's first vertex away from node[0]
- Catmull-Rom smoothing might add control points; first point usually preserved but verify.
- Chunk clipping on a road that sits exactly on chunk boundary may interpolate.
- FINAL log shows d=0.00 from polygon outline — first vertex IS on outline, but might not be EXACT node[0] coord.

### Hypothesis D: User sees texture seam, not geometry gap
- Road mesh asphalt texture vs bridge mesh deck texture differ.
- At boundary: clean texture transition might LOOK like a small gap.
- But user reports actual missing geometry visible (grass through gap).

## Diagnostics (in progress)

### Visual debug overlay (added 2026-05-07)
**What:** Extended BridgeRampDetector overlay to draw:
- Cyan spheres at every polygon outline vertex (Y at deck height).
- Magenta sphere at each ramp-owning road's first centerline vertex AFTER all `_compute_road_geometry_thread` processing (smoothing, _link shift, clipping, subdivide).
- Yellow line between road's first vertex and the nearest polygon vertex (visualizes the gap directly).
- Index labels on polygon vertices for quick identification.
**Trigger:** Same `bridge_ramp_debug` flag (F9).
**Plumbing:** Worker thread cannot directly write to detector overlay. Pass the road's first vertex data through a shared dictionary keyed by way_id+chunk_key. Detector reads in `_redraw_overlay` from this dictionary.

## To-Do (Verification First, Code Later)

1. **Visualize**: at game runtime, draw debug markers at:
   - Polygon vertices 15, 16, 17, 18, 19 (3D position).
   - Road's local_points[0] BEFORE and AFTER `_link` shift.
   - Road's smoothed_points[0] AFTER chunk clip.
   - Road's mesh first vertex AFTER all processing.
   - Compare exact positions visually.
2. **Examine `_create_bridge_deck_mesh` triangulation**: does it really use polygon outline verbatim, or does it inset / decimate / re-triangulate?
3. **Print actual polygon vertex Y** vs **actual road first vertex Y** at runtime: are they truly identical?
4. **Render road mesh with distinct color**: identify exactly which pixels belong to road vs bridge in user's screenshot. Confirm what fills the visual "gap".

Until these are answered, stop pattern-matching fixes.

## What Currently Stays (verified working)

- Stage 2A way-aware sampler with `_ramps_by_way_id` filter (prevents cross-road contamination).
- Stage 2A.3 `_deck_surface_y_at` formula in sampler (Y matches bridge mesh — verified via APPLY logs).
- Through-pass filter in detector (under-bridge roads not lifted).
- Polygon-proximity gate in sampler (within 5 m of polygon outline → deck Y).
- Smoothstep blend from deck Y to terrain Y over ramp distance (smooth visible ramp).

## What Was Reverted (caused new artifacts)

- `_link` shift skip for bridge endpoints.
- Reverse `_link` shift.
- Polyline EXTEND/SNAP toward polygon outline.
- Inside-polygon Y override (`_deck_surface_y_at_cached`).
- Skip terrain corridor cut for ramp-owning ways (caused road-disappear bug).

## Visual Debug Findings (2026-05-07)

After adding 3D markers via `record_road_endpoints`:

**At Octyabrsky south abutment (43844947):**
- **Cyan cross** (polygon outline vertex 17): ~20 cm outside the visible bridge mesh edge.
- **Magenta cross** (road's first vertex AFTER all processing): ~40 cm outside the visible road mesh edge.
- **Yellow line** between them: visible at deck level. Length ≈ `_link` shift distance = `min(parent_hw=5, half_segment_length) ≈ 2.71 m`.

### Two GAP components identified:
1. **`_link` shift gap** (~2.7 m): the dominant gap. road mesh's `local_points[0]` is shifted forward by `parent_hw` to avoid Z-fighting with parent road. For bridge endpoints, no parent road mesh exists (only on-deck markings on polygon mesh) — shift unnecessary.
2. **Bridge mesh inset** (~20 cm): bridge mesh edge sits slightly inward from polygon outline vertex. Likely a triangulation artifact in `_create_bridge_deck_mesh` (not investigated yet).
3. **Road mesh inset** (~40 cm): road mesh edge sits slightly inward from `local_points[0]`. Possibly from Catmull-Rom smoothing's first control point or lane marking inset.

Removing component (1) — skip `_link` shift for bridge endpoints — closes the main 2.7 m gap. Remaining ~60 cm (sum of insets 2+3) is small but possibly still visible.

## Remaining Issue

Visible HORIZONTAL discontinuity between elevated road approach (43844947) and bridge polygon mesh (Октябрьский) at the abutment. Map shows them touching exactly. Game shows them not touching.

User insists this is a real geometric gap, NOT a texture seam.

## Visual Debug Findings (2026-05-07, after `_link` shift skip applied)

Screenshot at south abutment of Октябрьский, third-person:
- Main longitudinal 2.7 m gap CLOSED (no more "yellow line" visible at deck level).
- New observation: **lateral mismatch on both sides of road** at the abutment.
  - **Bridge side (looking from road toward bridge):** small gap, sometimes road overlaps onto polygon → **Z-fighting** at deck level.
  - **Ramp side (looking from bridge toward road):** larger gap, terrain visible BETWEEN road edge and polygon edge along the lateral direction.
- Road approach is visibly NARROWER than the polygon at the abutment.

This matches Hypothesis B: polygon's perpendicular extent at vertex 17 (~12 m, vertex 16 east 5.54 m + vertex 18 west 5.92 m) > road approach width (~6 m). The lateral edges of road quad don't align with polygon outline edges 16→17 and 17→18.

User directive: must be **fully seamless**, road must visually match polygon's abutment edge shape, not just touch at one point. NO workarounds.

## Next Investigation Targets

1. `_create_bridge_deck_mesh`: how polygon outline is triangulated. Are vertices 16, 17, 18 all on the abutment edge of mesh? Is there inset / texture margin?
2. Road mesh perpendicular generation (in `_compute_road_geometry_thread`): how l[0]/r[0] computed at first vertex? Hardcoded perpendicular to road tangent at half_width? Or aware of bridge polygon edge direction?
3. Polygon outline edges 16-17 and 17-18 directions vs road tangent at vertex 17. Compute angle difference. If polygon edge ≠ road perpendicular, the only way to seam is to make road's first quad's perpendicular edge follow polygon outline (insert two extra mesh vertices at vertex 16 and 18 positions).
4. Width/lane-count check: road `secondary_link` reports what width? Polygon at this abutment represents the DECK width, which includes lanes + sidewalks + railings. Road approach on map (in OSM editor) — is it a single way or multiple parallel ways with sidewalks?

## Geometry-verified Root Cause (2026-05-07, real OSM data)

OSM cache: `osm_v6_59.1178_37.9024_315.json` (Sheksna chunk, 49-vertex polygon for relation 13095564).

### Topology at v17 (lat 59.1172106, lon 37.9035319)
Three roads + two footways converge in OSM data, but ALL at exact lat/lon coordinates:

| Way | tags | nodes | meets at |
|-----|------|-------|----------|
| **43844912** | secondary_link bridge=yes layer=+1 lanes=2 | 4 | node[3] = v17 (END at south abutment, on deck) |
| **43844947** | secondary_link cutting=yes layer=-1 lanes=2 | 12 | node[0] = v17 (START going north into cut/under deck) |
| **128566919** | footway bridge=yes layer=+1 | 6 | node[0] = **v16** (NOT v17), east sidewalk on deck |
| **128505215** | footway (no layer) | 4 | node[3] = **v16** (NOT v17), east cut-side sidewalk |

**Polygon outline at v17 region (49 vertices total, dz=south positive):**
```
v15 ( +6.36, +1.04)   south 1.04 m, east 6.36 m
v16 ( +5.54, +0.91)   sidewalks meet here
v17 (  0.00,  0.00)   road meets here
v18 ( -5.92, -0.97)   nothing meets here (asymmetric)
v19 (-21.20, +53.38)  far southwest — long jump from v18
```

Polygon abutment edge v16→v17→v18 is essentially a single tilted line:
- v17→v16 direction: (0.987, 0.162), **angle 9.33° from east**
- v18→v17 direction: (0.987, 0.162), **angle 9.31° from east**
- The two segments share the same tilt — polygon abutment edge is one straight-ish line tilted 9.3° from horizontal.

### Road geometry at v17 (way 43844947 node[0])
Tangent at node[0]: from node[0] (0,0) to node[1] (1.06, -5.32). Length 5.42 m.
- Tangent normalized: (0.196, -0.981) — heading mostly north, slight east.
- Tangent angle: -78.73° from east (or 11.27° west of due north).
- Perpendicular: (0.981, 0.196) — leading edge from l[0] to r[0].
- Half-width: lanes=2 × LANE_WIDTH(3.5) / 2 = **3.5 m**.
- l[0] = (−3.43, −0.68), r[0] = (+3.43, +0.68).
- Leading edge angle: **11.27° from east**.

### Quantified seam mismatch

| Side | Road edge Z | Polygon edge Z | Δ | Result |
|------|-------------|----------------|---|--------|
| East (X=+3.5) | +0.684 (south) | +0.575 (less south) | road 0.110 m further south | **GAP**: 0.11 m strip of bare ground between road and polygon |
| West (X=−3.5) | −0.684 (north) | −0.574 (less north) | road 0.111 m further north | **OVERLAP**: road extends 0.11 m past polygon edge, into polygon — Z-fight |

Direct match to user's screenshot: «Со стороны моста меньше / файтит» = west side overlap (Z-fight). «Со стороны рампы больше / дыра» = east side bare-ground gap.

### Lateral width mismatch

| Side | Road extends to | Polygon extends to | Polygon-only zone |
|------|-----------------|---------------------|--------------------|
| East | r[0] at +3.43 m | v15 at +6.36 m | 2.93 m of bridge mesh past road |
| West | l[0] at −3.43 m | v18 at −5.92 m | 2.49 m of bridge mesh past road |

Road approach is 7 m wide. Polygon abutment is 12.28 m wide (v15 to v18). Polygon extends ~2.5–3 m laterally past road on each side — this is sidewalks + railings + safety zones in the deck.

### Asymmetry: missing west sidewalk

OSM data has TWO footways converging at **v16** (east abutment): bridge-side `128566919` and cut-side `128505215`. Both end exactly at v16 (X=+5.54). 

**No equivalent footway converges at v18** (west). The west sidewalk is either elsewhere, mapped under different way IDs, or absent in OSM. Polygon vertex 18 has no road/footway way attached.

### Z-fight beyond abutment (additional component)

Way 43844947 has node[0] at v17 (south abutment), node[1] at (1.06, −5.32) — 5.32 m **north** of v17, **inside** polygon (polygon extends from v17 northward as bridge deck). All 12 nodes of 43844947 lie inside polygon area (X in [−45, +2], Z in [−73, 0]).

Result: road approach mesh sits inside polygon area for its entire length near v17. Both the polygon mesh (deck) and road mesh occupy the same Z when ramp Y matches deck Y. → continuous Z-fight along the road's first ~5 m. As ramp Y descends (going north), separation grows and Z-fight diminishes.

This is why "со стороны моста" overlap is everywhere there's road inside polygon, not just at the 0.11 m wedge at the abutment line.

### Why current code produces this seam

1. `_create_bridge_deck_mesh` triangulates polygon outline verbatim (no inset). Mesh edge is exactly v15→v16→v17→v18 polyline.
2. `_compute_road_geometry_thread` builds road quad's leading edge as `Vector2(-tangent.y, tangent.x) * half_width` — perpendicular to road tangent. No awareness of polygon abutment shape.
3. The two edges (road's leading edge and polygon's abutment edge) meet at v17 only; their slopes differ by 1.95° and they don't coincide.
4. Road mesh is not clipped to outside-polygon, so it extends inside polygon and Z-fights with bridge mesh.
5. Footway 128566919 (bridge-side sidewalk) ends at v16; the game renders it at deck Y via on-deck footway path, but its geometry is its own polyline, not aligned to polygon outline.
6. No west sidewalk way at v18 in OSM → cannot fill that 2.49 m lateral wedge from any way data.

### `_link` shift skip — not a workaround, root-cause fix

The `_link` shift was designed to avoid Z-fight at junctions where a link road's first vertex (centerline of parent road) would overlap the parent road's MESH. For bridge endpoints (43844947 starts at polygon vertex v17), the "parent" at the junction is the bridge **polygon mesh**, not a road mesh.

- Shift purpose: move link's first vertex away from parent ROAD mesh.
- Shift direction: along the link tangent (here: northward at v17, **deeper into polygon**).
- Effect at bridge endpoint: shift moves road's first vertex deeper into polygon — increases Z-fight, doesn't reduce it. Also creates a 2.7 m visible gap between v17 and where road actually starts.

**Skipping the shift for bridge endpoints is the correct root-cause fix**, not a workaround. The original heuristic doesn't apply when the parent at the junction is a polygon mesh.

### What "fully seamless" requires (no code yet)

For the result the user demands ("слитное, равное по ширине полотно, в стык, как на карте"):

1. **Road mesh's leading edge must coincide with polygon abutment polyline** at the abutment.
   - Replace road's perpendicular leading edge (l[0]→r[0]) with a polyline that traces the polygon abutment from one edge of the road to the other.
   - For 43844947: use polygon edges from `intersect(road_west_edge, polygon)` through v17 to `intersect(road_east_edge, polygon)`. This means inserting v17 as a midpoint of road's leading edge, with perpendicular replaced by the polygon-abutment-direction at that segment.

2. **Road mesh must be clipped to outside-polygon area only.** Inside polygon, no road mesh — only polygon mesh + on-deck lane markings.
   - The on-deck lane markings dispatch currently fires for `bridge=yes && on_deck`. For 43844947 (cutting=yes) inside polygon, the dispatch does NOT fire — so road mesh is rendered inside polygon, causing Z-fight.
   - Either: classify cutting=yes-on-bridge-polygon as on-deck for marking purposes, OR clip road mesh to outside polygon, OR both.

3. **Lateral width must match between road approach and polygon at abutment.**
   - Polygon at v17 region is 12.28 m wide, road approach is 7 m wide. The 2.5–3 m wedges on each side (east: 2.93 m, west: 2.49 m) are sidewalks + railings.
   - Sidewalks 128505215 (east cut-side footway) and 128566919 (east bridge-side footway) need to be rendered at deck Y near v17. The west sidewalk is missing in OSM — cannot fix from data alone.
   - Even with both sidewalks, the ~1 m railing zone outside the sidewalks is polygon-only. That's expected (railings don't have walkable surface) — only requires polygon mesh to extend laterally to v15/v18, which it already does.

4. **Polygon outline tilt of 9.3° must be respected by road's leading edge.**
   - Currently road leading edge is at 11.27° (perpendicular to road tangent). Polygon at 9.32°. 1.95° difference.
   - To make them coincide: either use polygon tangent for road's leading edge (insert two extra vertices on road's leading edge at the polygon tangent angle), or accept that road uses a piecewise-linear leading edge bending at v17 (already polygon's shape).

### Summary of remaining gaps after current code state

| Component | Current state | Closes if... |
|-----------|---------------|--------------|
| 2.7 m longitudinal `_link` shift gap | **Closed** (shift skipped for bridge endpoints) | already done — root-cause fix |
| 0.11 m east bare-ground gap | **Open** | road's leading edge follows polygon abutment slope (currently perpendicular to road, not parallel to polygon) |
| 0.11 m west polygon overhang | **Open** | same as above |
| Z-fight along road inside polygon | **Open** | road mesh clipped to outside polygon, OR rendered as on-deck lane markings only (like bridge=yes ways do) |
| 2.93 m east polygon-only past road | **Open** | east sidewalk meshes (128505215 + 128566919) rendered at deck Y at the abutment |
| 2.49 m west polygon-only past road | **Stuck** | OSM has no west sidewalk way at v18; cannot fill from data — render polygon-only as deck (already correct) |
| 9.3° vs 11.3° tilt mismatch | **Open** | road's leading edge replaced with polygon-abutment-aligned polyline through v17 |

## Attempt #12: perp override at bridge endpoints (root-cause fix, planned 2026-05-07)

**What:** at the road approach's first/last vertex, if it sits at a polygon vertex (`_bridge_endpoint_touches_any`) AND the way owns a ramp (`way_owns_ramp`), replace `perp[0]` / `perp[n-1]` with the polygon's outline direction at that vertex (`(poly[i+1] - poly[i-1]).normalized()`).

**Effect:**
- `l[0] = points[0] - perp_polygon * half_w` lies on polygon edge `v17→v18`.
- `r[0] = points[0] + perp_polygon * half_w` lies on polygon edge `v17→v16`.
- The road's leading edge becomes **co-planar with polygon abutment line** — no Z-offset, no angular mismatch.
- Closes both the 0.11 m east bare-ground gap and the 0.11 m west polygon-overhang/Z-fight.
- Closes the 1.95° tilt mismatch.

**Verified consistent with data (Python check on real OSM):**
- `(v18→v16).normalized()` = (0.987, 0.162). Replacing perp[0] (0.981, 0.196) with (0.987, 0.162):
  - new l[0] = (−3.45, −0.567) → matches polygon edge v17→v18 at X=−3.45 (Z=−0.566). Δ < 1 mm.
  - new r[0] = (+3.45, +0.567) → matches polygon edge v17→v16 at X=+3.45 (Z=+0.567). Δ < 1 mm.

**Not addressed by this attempt (separate issues):**
- Lateral wedge: 2.93 m east + 2.49 m west of polygon-only past road. Polygon mesh covers it (asphalt texture); user may still perceive a "narrowing" trapezoid. Needs sidewalk way rendering at deck Y to be perfectly smooth.
- Z-fight inside polygon: not a concern here — verified that all 11 of 12 nodes of way 43844947 are OUTSIDE polygon (the road exits polygon immediately after v17). Road mesh and polygon mesh don't overlap inside polygon. Only the abutment-line micro-strip (now closed by this attempt) was a Z-fight zone.

**Why not a workaround:** road's leading edge is intrinsically a transverse polyline at the bridge endpoint. Its direction must equal the bridge's abutment direction at that vertex — that IS the geometric definition of "butting into the bridge". Making perp[0] follow road tangent is the original simplification that breaks at bridge endpoints. Replacing it with polygon tangent is the correct geometry, not a patch.

**Bug found on first launch (2026-05-07):** initial implementation took `next_v - prev_v` from polygon outline. Polygon winding orientation is independent of road's left/right convention, so `next_v - prev_v` came out POINTING THE OPPOSITE WAY to the road perp at v17 (polygon walks east→west across the abutment, road perp points east). Result: `l[0]` and `r[0]` swapped → first quad twisted into an X → degenerate mesh, no ramp visible at all. Fix: sign-correct the polygon tangent against the original road perp via `dot < 0 → flip`. Documented as cautionary tale.

**Result of Attempt #12 (perp override only) per user screenshot:** the 0.11 m east bare-ground gap CLOSED on the bridge side. Z-fight on west side gone. Remaining lateral gap right of road approach (the 2.93 m east polygon-only wedge) still visible. User sees road mesh asphalt on the ground at terrain Y in this wedge zone. → not a Y-bug; it's the visible lateral width mismatch where polygon (12 m) extends past road (7 m), with terrain showing through the wedge between them.

## Attempt #13: snap `l[0]/r[0]` directly to polygon neighbor vertices (planned 2026-05-07)

**What:** instead of overriding `perp[0]` direction, snap `left_pts[0]` and `right_pts[0]` directly to the polygon's two adjacent vertices at the bridge endpoint. For Октябрьский south abutment with way 43844947's `node[0] = v17`, this becomes `left_pts[0] = v18`, `right_pts[0] = v15` (or sign-swapped). Sign decided by dot of (`neighbor - points[0]`) against the original road perp.

**Effect:** road quad's leading edge length = polygon abutment width (12.4 m, not 7 m). Leading edge endpoints = polygon vertices v18 and v15 EXACTLY. Road mesh and polygon mesh share v18, v15, and v17 (centerline) as common geometric points. The polygon abutment polyline (v18→v17→v16→v15) lies along the road quad's leading edge — fully seamless edge alignment.

**Trade-off:** road quad's first segment becomes a TRAPEZOID — wider at the abutment (12 m), narrowing to road's standard half-width (3.5 m on each side, total 7 m) at the next vertex (~5 m down the way). Slope rate: (12 - 7) / 2 / 5 = 50 cm of taper per meter of road. Visible but smooth, mimics real-world deck-to-carriageway transitions.

**Replaces Attempt #12** (perp override) since direct l/r override is a stricter form of the same fix — perp override moves l/r along polygon outline at half_w distance; direct override moves them all the way to the polygon CORNER vertices (5.6–6 m, not 3.5 m).

**Result of Attempt #13 (snap l/r to neighbors) per user screenshot:**
- ✅ "Уширитель" (widening trapezoid) appeared at v17 — road quad's leading edge becomes 12 m wide as planned.
- ❌ Lane markings on widened section heavily DEFORMED. Road texture has lane marks baked in at fixed UV.x positions (e.g. 0, ±0.25, ±0.5). With trapezoidal quad, GPU linearly interpolates UV.x across the trapezoid — lane marks curve inward from wide end to narrow end, looking warped.
- ❌ "Asphalt on the ground" past expander remains. Likely due to: (a) `l[0] = v18` extends BEYOND chunk boundary at this chunk's clip rect, so neighbouring chunk's road-mesh (with normal half_w) overlaps in this lateral region, possibly causing visible duplicate at terrain Y, OR (b) descent ramp's natural smoothstep curve at the start (t=0 → 0%) gives only ~38 cm Y drop in first 5 m, the rest of the descent visible as terrain-level asphalt.

**Decision: revert to Attempt #12 (perp override only).** Polygon mesh already covers the lateral wedge from road edge (3.5 m) to polygon outline (v15/v18 at 5.5–6 m) at deck Y. Road quad stays standard 7 m width — no UV stretch, no chunk overlap, no marking deformation. Lateral seam at the abutment line (the 0.11 m east bare-ground gap that perp override closes) is the only thing the override needs to fix.

Width mismatch perception by user remains: visible "narrowing" from polygon-deck-width (12 m) to road-carriageway-width (7 m) at the abutment. This is REAL data — bridge deck IS wider than carriageway. Solving it requires lifting cut-side sidewalk ways (footways 128505215 east, none on west) to deck Y at the abutment so they fill the visible lateral wedge with proper sidewalk surfaces. That is a separate, larger change scope.

## Attempt #14: redo Attempt #12 (perp override) but apply to left_pts/right_pts directly (planned 2026-05-07)

**What:** instead of overriding `perpendiculars[0]` (which the loop downstream uses to compute left_pts/right_pts), compute the desired `left_pts[0]`/`right_pts[0]` directly using the polygon-tangent perpendicular and standard `half_w`. Bypasses the loop's logic for the first/last vertex without modifying perpendiculars (which is also used elsewhere downstream for normals etc.).

**Effect:** identical to Attempt #12 (l[0]/r[0] lie on polygon outline at half_w distance from centerline along polygon abutment direction), but cleaner separation: perpendiculars array stays untouched; only left_pts/right_pts at endpoints are overridden.

## Failed extension: increase RAMP_BUDGET 35 → 75 (reverted 2026-05-07)

**Hypothesis:** the visible "asphalt on the ground from the ramp" is the post-35m portion of way 43844947 (length 73 m) — past the ramp budget the road sits at terrain Y. Extending RAMP_BUDGET to 75 m would make the entire way ramped with a gentler descent.

**Result:** REJECTED by user. Side effect: detector's walker walks further, registering OTHER under-bridge roads (43844912 sibling and possibly other connecting drivable ways) as part of the ramp's polyline. They got lifted to deck Y when the user expected them to remain at terrain (they pass UNDER the bridge, not connect to it). Visibly broke under-bridge layout.

**Lesson:** RAMP_BUDGET caps not just the ramp's visual length but also the walker's reach across drivable graph. Lengthening it pulls in adjacent roads. This is by design for SHORT side-street ramps that legitimately ramp up to bridges, but it's not a per-way knob — can't turn it up just for one cut road.

**Real cause of "asphalt on the ground" remains unidentified.** It is NOT the post-35m portion of way 43844947 (revert restored old visibility but problem persists per user).

## Attempt #15 (REJECTED): boundary tolerance in `_deck_surface_y_at_cached`

**Hypothesis:** lane markings drawn by `_create_on_deck_lane_markings` for bridge=yes ways use `_deck_surface_y_at_cached(p)` per-vertex Y. For a way whose endpoint coincides with a polygon vertex (e.g. way 43844912 has `node[3] = v17` = vertex 17 of Октябрьский deck), `Geometry2D.is_point_in_polygon(v17, polygon)` returns FALSE — boundary points are not "strictly inside". The function then falls through to `_sample_elevation` and returns terrain Y. Lane marking at that vertex sinks 5 m below polygon mesh, becoming visible on the ground under the bridge.

User's report: "это точно часть дороги от рампы, а не тротуар" — what they see has white center markings (a 2-lane road's lane divider). Under the bridge, terrain-level dashed white line ≈ "лента разметки на земле".

**Fix:** in `_deck_surface_y_at_cached`, if `is_point_in_polygon` returns false BUT point is within 0.5 m of polygon outline, treat as inside. Use `_min_dist_to_polygon_outline` (already exists).

**Affects:** all callers of `_deck_surface_y_at_cached` — primarily `_create_on_deck_lane_markings` and `_create_on_deck_footway`. Both produce mesh elements that overlay the polygon deck and must align with polygon Y at endpoints.

**Result:** REJECTED. User reports no improvement (asphalt still visible on ground), and possibly INCREASED ground asphalt. The visible asphalt was NOT lane markings — it was the road approach mesh itself past the 35m ramp budget. Reverted.

## Attempt #16: extend ramp polyline along cutting=yes way to its full length (planned 2026-05-07)

**Hypothesis (CORRECT, per user):** the visible "asphalt on the ground from the ramp" IS the post-RAMP_BUDGET portion of way 43844947. The way is 73 m long but the ramp polyline only extends 35 m from v17. Past 35 m, `sample_road_y_for_way` returns no candidate (d > total_length) and the road quad falls through to terrain Y. That portion sits 5 m below the deck-top of the bridge — visible as a flat road on the ground.

Naïve fix (raise RAMP_BUDGET globally) was tried in Attempt #15.5 and REJECTED: the walker continues across way edge into adjacent ways, lifting unrelated under-bridge roads onto the bridge ramp.

**Targeted fix:** detect when the FIRST way of a ramp has `cutting=yes` tag. Cutting roads represent a road descending into a cut on the other side of the bridge — the cut continues at ground level past the way's end and any adjacent road there is at ground level (NOT on a ramp). For such ways:
1. Skip RAMP_BUDGET cap → walk the full way regardless of length.
2. At way edge → terminate with `"cutting_edge"` (do NOT continue to adjacent ways).

**Effect on way 43844947 (73 m, cutting=yes):**
- Walker walks all 73 m of the way.
- Ramp.total_length = 73 m.
- Smoothstep operates over 73 m → gentle 14% grade descent (was 28% over 35 m).
- No "post-ramp flat-on-ground" portion within the way.
- Walker terminates at way end → adjacent roads NOT lifted.

**Effect on other ramps:** none. RAMP_BUDGET still 35 m for non-cutting ways. Behaviour unchanged.

## Flyover Test for Bridge Ramp Debugging

### Running the test

Start from coordinates south of the bridge so it gets loaded as the camera flies south:

```bash
# Октябрьский мост — start south of south abutment
/Applications/Godot.app/Contents/MacOS/Godot --path . tests/elevation_flyover_test.tscn \
  -- --test-lat=59.1195566 --test-lon=37.9037360 --no-chess --with-all
```

**Full bridge ramp inspection** — fly from north abutment to south abutment, covering all 5 ramps.
The polygon's northernmost point is ~59.1181 and southernmost ~59.1089.
Start north of the bridge, fly south through the entire span:

```bash
# North→South: all ramps visible (N main ramps first, then lateral exit, then S main ramps)
/Applications/Godot.app/Contents/MacOS/Godot --path . tests/elevation_flyover_test.tscn \
  -- --path=59.1190,37.9025:59.1080,37.9055 \
  --no-chess --with-all --cam-height=40
```

What to check at each ramp:
1. **North ramps** (~59.1181): ways 82697420 + 78314252 meet ground roads 39643699 + 39643698
2. **NE lateral exit** (~59.1171, 37.9010): way 78314250 arm tip
3. **South lateral exit** (~59.1172, 37.9035): way 43844912 meets 43844947 (cutting=yes)
4. **South ramps** (~59.1089): ways 82697419 + 116079419 meet ground roads 39644855 + 45481836

Look for: grass gap at ramp base, Z-fight, deck mesh covering road approach.

Path mode — fly a custom route along deck edges:

```bash
# Fly along the south end of the bridge deck
/Applications/Godot.app/Contents/MacOS/Godot --path . tests/elevation_flyover_test.tscn \
  -- --path=59.1170,37.9040:59.1190,37.9040:59.1210,37.9030:59.1230,37.9030 \
  --no-chess --with-all --cam-height=30
```

Deck polygon flyover — fly around the bridge deck perimeter:

```bash
# Fly the deck polygon outline at 50m above ground
/Applications/Godot.app/Contents/MacOS/Godot --path . tests/elevation_flyover_test.tscn \
  -- --test-lat=59.1195 --test-lon=37.9040 --path=deck \
  --no-chess --with-all --cam-height=50

# Same but in reverse direction
/Applications/Godot.app/Contents/MacOS/Godot --path . tests/elevation_flyover_test.tscn \
  -- --test-lat=59.1195 --test-lon=37.9040 --path=deck --reverse \
  --no-chess --with-all --cam-height=50
```

Key flags:
- `--no-chess` — load ALL chunks (chess pattern skips every other chunk, may miss bridge)
- `--with-all` — enable buildings, lamps, curbs, vegetation
- `--test-lat=X --test-lon=Y` — start position; camera flies south at 100 km/h
- `--cam-height=N` — camera height above terrain in meters (default 38)
- `--path=deck` — auto-build path from bridge deck polygon vertices (prints all vertex coords with lat/lon); camera flies the polygon perimeter
- `--reverse` — fly the path in reverse direction (works with `--path=deck` and `--path=...`)
- `--path=lat1,lon1:lat2,lon2:...` — fly a path through manual waypoints (camera rotates smoothly to face direction of movement; test ends when path is completed)

### Filtering diagnostic output

```bash
# Lateral exit detection (deck ramp at _link way exits)
... 2>&1 | grep "LateralExit"

# Standalone bridge road vertex dump (3D coords per vertex pair)
... 2>&1 | grep "BridgeRoad"

# All bridge diagnostics + errors
... 2>&1 | grep -E "LateralExit|BridgeRoad|SCRIPT ERROR"

# Save full log, filter after
... 2>&1 | tee /tmp/flyover.log
grep "LateralExit" /tmp/flyover.log
```

### Key diagnostic print tags

| Tag | Source function | What it shows |
|-----|----------------|---------------|
| `[LateralExitScan]` | `_detect_deck_lateral_exits` | Every `_link` bridge way evaluated: way_id, highway, midpoint, polygon count, on_deck |
| `[LateralExit]` | `_detect_deck_lateral_exits` | Registered exit: way_id, start/end, position, base_elev |
| `[BridgeRoadDump]` | `_create_bridge_road` | Road summary: way_id, ref_elev, deck_top, shared endpoints, ramp lengths |
| `[BridgeRoadVert]` | `_create_bridge_road` | Per-vertex 3D coords (left/right) — verify ramp S-curve shape |

### What to verify

1. **ref_elev alignment**: `[BridgeRoadDump] ref_elev` should be ~124.6 (abutment level), NOT ~120 (river level). If it shows river level, the deck-aware ref_elev fix (shared endpoint samples deck surface Y) isn't working.

2. **deck_top match**: standalone road's `deck_top` should be polygon's `deck_top` + `height_offset` (0.008 for secondary_link). The road sits 8mm above the deck.

3. **Ramp S-curve**: `[BridgeRoadVert]` Y values should smoothstep from ground level to deck_top. Ramp covers `ramp_end` or `ramp_start` meters from the free endpoint.

4. **Lateral exit registration**: `[LateralExitScan] on_deck=true` confirms midpoint is inside polygon. `[LateralExit]` confirms exit was registered with position and direction.

5. **base_elev=0.0**: elevation data wasn't available at detection time. The ramp code (`_deck_surface_y_at`) samples live — fallback to polygon ref_elev if still 0.

### Key ways at Октябрьский мост

| Way ID | Type | Role |
|--------|------|------|
| 78314250 | secondary, bridge=yes | Main carriageway (on_deck → lane markings) |
| 43844912 | secondary_link, bridge=yes | South exit ramp (standalone road, lateral exit from deck) |
| 43844947 | secondary, cutting=yes | South approach road (ground level, goes under bridge) |

### Querying OSM data for bridge ways

Use the Overpass API to understand what objects exist on/near the bridge:

```bash
# All bridge=yes highway ways inside the deck polygon (relation 13095564)
curl -s 'https://overpass-api.de/api/interpreter' \
  --data-urlencode 'data=[out:json];relation(13095564);map_to_area->.bridge;way(area.bridge)[highway][bridge=yes];out tags;' \
  | python3 -m json.tool

# Tags of a specific way
curl -s 'https://overpass-api.de/api/interpreter' \
  --data-urlencode 'data=[out:json];way(43844912);out tags;'

# Way geometry (nodes + lat/lon)
curl -s 'https://overpass-api.de/api/interpreter' \
  --data-urlencode 'data=[out:json];way(43844912);out geom;'

# All _link bridge ways near a coordinate
curl -s 'https://overpass-api.de/api/interpreter' \
  --data-urlencode 'data=[out:json];way(around:500,59.113,37.904)[highway~"_link$"][bridge=yes];out tags;'
```

This helps identify:
- Which ways are `_link` (arm ramps) vs main carriageways
- Whether a way is `steps`, `footway`, `primary`, etc.
- Node coordinates to understand road geometry

### In-game debug overlay (F9)

Press F9 to toggle bridge ramp debug overlay (`bridge_ramp_detector.gd`). Shows ramp zones, shared/free endpoints, and detected ramp corridors as colored markers.
