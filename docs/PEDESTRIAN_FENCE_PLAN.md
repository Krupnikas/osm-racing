# Pedestrian Fence Plan — `russian_city_fence.glb`

**Status:** 📋 planned, awaiting go-ahead. NO code / no asset surgery yet.
**Asset:** `~/Desktop/OSM material/russian_city_fence.glb` (Sketchfab "Russian City Fence", CC-BY-4.0).
**Goal:** Procedurally place Soviet-style metal pedestrian guard-rail fences at major-road crossings near intersections.
**v1 scope = static placement ONLY** (position, scale, orientation, visual fit). Segment **shatter is Phase 2** (documented in §8, NOT built in v1). Mesh **deformation/bending is out of scope entirely** for now.

---

## 1. The asset is composite (good — no manual cutting)

The GLB is **not** one mesh; it is ~22 separate mesh-primitives in a nested Sketchfab/FBX hierarchy (root scale 0.001, grouped **by material**):

| Group | Count | Physical part |
|---|---|---|
| `node_id141` (Material_158) | 2 | end posts (left/right ends of the run) |
| `node_id151` (Material_170) | 5 | vertical posts (evenly spaced) |
| `node_id131…138` (Material_207) | 8 | decorative infill panels (≈2 per bay × 4 bays) |
| `node_id143` (Material_164) | 2 | top + bottom horizontal rails |
| `node_id156` (Material_185) | 4 | post-top finials/caps |
| `root_Material_133` (textured) | 1 | textured plate (plaque/decal) |

**5 vertical posts → 4 bays (пролёта) per instance.** Confirmed with the user. For v1 the asset is used **whole** — no splitting into per-segment bodies (that's Phase 2).

> ⚠️ Sketchfab nesting + 0.001 scale + odd per-node transforms. At placement, **scale via real transformed leaf-mesh vertices** (`mesh.get_aabb()` walking leaf MeshInstances), NOT the stored AABB — see [clutter_getaabb_gotcha](../.claude/projects/-Users-alekseiaksenov-osm-racing/memory/clutter_getaabb_gotcha.md). Full scale-verification checklist in §10.

---

## 2. Placement rules (from the user — authoritative)

Fences go at intersections that have a **pedestrian crossing (зебра)** across a **major** road.

- **Road-type gate:** crossed road must be major. OSM verified: Северное шоссе = `primary`, Советский = `secondary`, Окинина = `residential`.
  → gate = `highway ∈ {trunk, primary, secondary}`. Residential / unclassified / service / living_street → **excluded**. `tertiary` → **excluded** (confirmed).
- **Along the curb**, parallel to the road.
- **One side of the zebra only** — NOT the junction side; the **"body of the road" (through-road) side** (the open continuing carriageway). See §3 for the exact "far zebra edge" definition.
- **Both curbs** of the road (left + right edge).
- **Exactly 12 bays = 3 instances** placed end-to-end, **per curb**. v1 rule for all qualifying sites — see §5.
- **T-intersections included**, but only along arms that are major roads (the Северное-Шоссе-like arms, not the minor stem). See §3 for T handling.
- **4-way intersections:** rule applies **per major arm** independently, same scheme.

**Canonical example** — Северное Шоссе × Пионерская (T-shaped, one crossing across the highway), order along the highway:

```
…highway → intersection (+zebra) → FENCE (12 bays / 3 instances) → highway…   ← per curb, ×2 curbs
```

---

## 3. Placement algorithm (grounded in existing systems)

All hooks already exist in `osm/osm_terrain_generator.gd`:

**Crossing detection (reuse):** `footway=crossing` ways + `_detect_road_crossing(on_start, on_end, ck)` → `_build_crossing_strip(road_info, width)` → `cross_pts`. This already yields, for each zebra: the crossing strip across a road (centre, the road's local direction = perpendicular to the strip, and the two curb endpoints). Same path that drives `_enqueue_crossing_signs(...)` (`enable_crossing_signs`).

**Intersection data (reuse):** `_intersection_positions[i]` (centre), `_intersection_roads[i]` = `[{direction:Vector2, width:float}]` (arms), `_intersection_angles[i]` (wide-road direction), `_intersection_curb_contours[i]` (inflated junction contour for clipping), `_find_nearby_intersection(pos, r)`, `_is_equal_intersection(i)`. Road widths: `ROAD_WIDTHS` (trunk 14 / primary 12 / secondary 10).

Per detected crossing strip:

### 3.1 Gate
- Crossed road's `highway` ∈ `{trunk, primary, secondary}`, else skip.
- **Trust tagged crossings only (#8):** require `is_tagged_crossing` (`item.tags.get("footway") == "crossing"`). Do **not** place on geometric-only crossings from `_detect_road_crossing` (that path fires for any footway passing over a road → not necessarily a real zebra). The user confirmed real zebras are tagged at the target sites.

### 3.2 Anchor to a junction (deferred — NOT skip-on-first-miss)
`i = _find_nearby_intersection(crossing_centre, ~30 m)`.
- ⚠️ **Race:** crossing detection runs on the **main thread** during road processing (~`:8271`), but intersections (Phase 1+2) are built on a **worker thread** and applied later (`:3697`/`:3722`, applied `:1829`). So on first evaluation the anchoring intersection may not exist yet → a naive "skip" would **permanently** drop a valid site. **Do not skip on first miss.**
- **Mitigation (mirror the wire deferred-queue):** enqueue the crossing site into `_deferred_fence_queue[ck]` and drain each frame. If `_find_nearby_intersection` returns -1, **keep the job** (retry next frame); only erase it in `_unload_chunk(ck)`. Precedents: `_deferred_wire_road_queue` (skip-if-not-loaded) and the existing `_pending_batch_chunks` re-enqueue right inside the crossing block.
- A crossing with a genuinely **no** nearby intersection (mid-block) is dropped only after its chunk stays loaded and stable — i.e. it never anchors. (Practically: drop if still unanchored when the chunk has finished finalizing.) Mid-block = no fence (confirmed).

### 3.3 `away_dir` and the "far zebra edge" (made explicit)
- `road_axis` = unit direction of the crossed road (from `cross_pts` / the matching arm in `_intersection_roads[i]`).
- `away_dir` = `road_axis` signed so it points **from the intersection centre, through the crossing, and into the continuing body of the road**:
  `away_dir = road_axis * sign(dot(crossing_centre − intersection_centre, road_axis))`.
- The zebra strip has two edges along the road. The fence run **starts from the zebra edge that is FARTHER from the intersection centre along `away_dir`** (the body-of-road edge).
  - **Never** start from the edge closer to the intersection.
  - **Never** place any part of the fence on the intersection side of the crossing.
- **Post-crossing gap:** start the run a small gap past the far zebra edge:
  `fence_after_crossing_gap ≈ 0.3–0.8 m` (tunable) — enough to not overlap the zebra strip, small enough that the fence doesn't visually start detached from the crossing.

Intent that the geometry must read as: **"guide pedestrians to the crossing and stop them crossing immediately after it"** — not random decoration near the junction.

### 3.4 Both curbs + lateral offset (clarified)
The two curb lines are perpendicular to `road_axis`, on either side. Lateral offset from the road centreline:
```text
fence_lateral_offset = road_width / 2 + sidewalk_side_fence_offset
```
- `road_width / 2` reaches the **carriageway edge**;
- `sidewalk_side_fence_offset` moves the fence **outward, onto the sidewalk/verge side** (so it sits on the inner/sidewalk edge of the curb, never in the lane);
- initial tuning: close to the curb but clear of the lane.

**Snap to the REAL curb, not an analytic line (#3):** the rendered curb is smoothed and **flares in the junction mouth** — a straight `road_width/2` line diverges from the visible curb exactly where the fence sits (right after the zebra). Use real geometry:
- The two **curb endpoints of the zebra are already computed** — `cross_pts[0]`/`cross_pts[1]` are the road-edge points found via `_find_road_edge_point(...)`. Use the one on each curb as that curb's run anchor.
- For each instance base further along the run, **re-project onto the actual road edge** with `_find_road_edge_point(...)` (or nearest point on the road corridor / the `_build_sidewalk_kerbs` polyline) at that step, instead of marching a straight offset line. So the run follows the curve.
- Then push outward by `sidewalk_side_fence_offset` along the local edge normal.

For **each** curb:
- run start = curb-side zebra edge (`cross_pts`) + `fence_after_crossing_gap` along `away_dir`, at `fence_lateral_offset`;
- lay **3 instances** end-to-end along `away_dir`: at `start`, `start + L·away_dir`, `start + 2L·away_dir` (L = real one-instance length from §10), each base re-projected to the real edge;
- yaw = local edge tangent (≈`atan2(away_dir.x, away_dir.z)`) so the fence lies parallel to the curb, **front face toward the carriageway**;
- **slope handling (#5):** ground via `_sample_elevation(...)` and **pitch each instance to the local grade** — sample elevation at the instance's two ends along `away_dir` and tilt about the lateral axis so a ~8–10 m rigid instance doesn't float/sink at its far end on hills. Each of the 3 instances is grounded+pitched independently.

**Visual checks (per §9):** not on the driving lane; follows the curb (not a straight chord across a curve); not stranded mid-sidewalk where curb data allows better; parallel to the road; front face toward traffic.

### 3.5 T-intersection handling (strengthened)
- At a T, place fences **only along major-road arms**. If the crossing is across the major continuing road, fences go along that continuing major road's body side, **both curbs**.
- **Do NOT** place along the minor stem side if that stem is not major.
- Канонический пример Северное Шоссе × Пионерская: забор идёт вдоль Северного Шоссе после зебры (где шоссе продолжается); **никакого** забора вдоль рукава Пионерской (он не major).
- On a 4-way, evaluate each major arm's crossing **independently** by the same rule.

### 3.6 Ambiguity → skip (don't guess)
If the body-of-road side can't be determined **confidently**, **skip the site** rather than risk wrong-side placement (see §4):
- `dot(crossing_centre − intersection_centre, road_axis)` near zero / unstable → don't blindly guess;
- use intersection arm directions / road class / crossing geometry to disambiguate first;
- if still ambiguous → skip and debug-mark the skipped site (reason).

### 3.7 Avoidance / clipping
Don't overlap the zebra strip; clip against `_intersection_curb_contours[i]` so the run never intrudes into the junction; (optional) skip a bay that collides with a building footprint or driveway. Dedup by **stable site key** (§5) so the same site isn't placed twice across chunk reloads.

### 3.8 Divided carriageway (#9)
If the major road is mapped as **two parallel ways** (dual carriageway) or carries `oneway=yes`, the single-centreline "both curbs at ±road_width/2" model breaks (the two ways have their own outer curbs + a median between them).
- **Detect:** crossed way has `oneway=yes`, or the crossing strip span (`edge_span`) is much smaller than a full bidirectional `road_width`, or a near-parallel sibling major way exists within a median's distance.
- **Handle:** treat each carriageway's **outer** curb as a separate run (no fence on the median side), and flag the site for the §9 visual check.
- If the carriageway topology is **inconsistent/unclear** → fall through to the §4 wrong-side rule and **skip**.

**Result per crossing-on-major-arm:** 2 curbs × 3 instances = **6 GLB instances** (12 bays per curb). At a 4-way with N major arms crossed, repeat per arm.

---

## 4. Hard rule: wrong side is worse than no fence

A misplaced fence is more damaging than a missing one. **Skip the site (and optionally debug-log the reason)** if any of these is uncertain:
- ambiguous intersection;
- ambiguous road axis;
- ambiguous away-from-junction side;
- crossing geometry looks inconsistent;
- curb endpoints can't be determined confidently.

**Never** place a fence where there's a serious risk it appears: before the zebra · inside the intersection · along the wrong road arm · on the minor stem · on the driving lane.

---

## 5. Length & site identity

### 5.1 Exactly 12 bays = 3 instances per curb (v1 rule — do not reduce)
- one GLB instance ≈ 4 bays; target per curb = **exactly 12 bays** → **exactly 3 instances** end-to-end.
- per crossing-on-major-arm: 2 curbs × 3 instances = 6 GLB instances; each curb gets exactly 12 bays.
- **No road-class-dependent shortening in v1.** Secondary roads are **not** shorter by default. Only **bay width / asset scale** may be tuned visually (§10) — **never the bay count**.

### 5.2 Stable site key — OSM id first (#4)
`intersection_idx` depends on parse/generation order + overlapping chunk fetches → fragile. The crossing footway **way_id is available** (`item.get("way_id", 0)` in the crossing block), so make it the **primary** key:
```text
pf_<crossing_way_id>_<away_side>_<curb_side>_<instance_ix>        # PRIMARY — stable across reloads
pf_q_<qx>_<qz>_<axis_bucket>_<curb_side>_<instance_ix>           # FALLBACK only if way_id missing (id==0)
```
- `away_side` = sign of `dot(crossing_centre − intersection_centre, road_axis)`; `curb_side` ∈ {L,R}.
- Geometry-quantized key is **fallback only** — float jitter across reload/fetch-order can shift a quantization bucket → rare double-spawn (battled this with wire position-keys). Prefer the id.
- `intersection_idx` may ride along as a **debug field only**, never the sole dedup key.

**Goal:** no duplicates across reloads; same site → same key on reload; overlapping chunk fetches don't double-spawn.

---

## 6. Persistence / streaming / rendering (v1 — keep it simple)

**Chosen for v1 — Option A (static, chunk-owned), because the codebase already does exactly this for repeated props:**
- compute deterministic fence sites; render them **batched per chunk** (see below); recreate deterministically on reload; dedup by the stable site key (§5.2);
- this also survives the existing chunk lifecycle cleanly (`_unload_chunk` erases the chunk's fence batch + deferred jobs).

**Rendering (#6 — batch, don't spawn ~130 nodes/crossing):** one qualifying site = 6 instances × ~22 primitives. Do NOT create raw `MeshInstance3D` per primitive. Mirror the per-chunk MultiMesh pattern used for windows/lamps/trees:
- **Pre-merge once at load:** combine the GLB's leaf primitives into a single `ArrayMesh` with a few surfaces grouped by material (strip the junk plate per §10). Cache it.
- **Per chunk:** one `MultiMeshInstance3D` (per surface) holding the transforms of all fence instances in that chunk. Cheap, few draw calls.

**Collision (#2 — v1 fence must be SOLID):** "static placement" must not mean "drive-through". Add a `StaticBody3D` per instance (or merged per chunk) with a simple aggregate collider (a thin box along the run, or a couple of box shapes), on **collision layer 1** — matching lamps / transformer-boxes so cars stop on it (per [[roadside_props]]). NOT layer 4 (that's for knock-over clutter). Ground to elevation (§3.6 slope handling).

**Phase 2 swap (don't let v1 batching block it):** when a fence instance is hit (Phase 2), remove its slot from the chunk MultiMesh + its aggregate collider, and instantiate the **un-merged** GLB split into per-leaf frozen `RigidBody3D` segments (layer 4) at that transform. So v1's merged/MultiMesh representation and Phase 2's split representation coexist by swapping one instance at a time.

**Option B (dormant records, clutter-manager style)** is deferred to Phase 2, where activate-near-player + destroyed-state persistence become useful. Not needed for static v1.

---

## 7. v1 ⟷ Phase 2 boundary (explicit)

**v1 implements ONLY:** static fence placement — correct position, scale, orientation, visual fit; dedup; stable reloads.

**v1 explicitly does NOT include:** runtime splitting into `RigidBody3D` segments · impact shatter · flying pieces · per-leaf convex collider generation · persistence of broken/destructed state. Phase-2 complexity must not block or contaminate v1. The first goal is **correct static placement and visual fit**.

---

## 8. Phase 2 — разлёт (shatter on impact ≥ 40 km/h) — implementation plan

**Status:** 📋 planned, awaiting go-ahead. Trigger speed confirmed with user: **≥ 40 km/h (11.1 m/s)**. Below that → nothing happens (no bend; deformation stays out of scope). Reuses the existing hit→impulse mechanic — no new subsystem.

**Grounding in the v1 build:** a fence instance today = a slot in the per-chunk `MultiMesh` (visual) + a per-instance `StaticBody3D` collider (layer 1). Two changes enable shatter:

1. **Detection — swap the collider type.** Replace each instance's `StaticBody3D` with a **frozen kinematic `RigidBody3D`** (`freeze = true`, `FREEZE_MODE_KINEMATIC`, `contact_monitor = true`, `max_contacts_reported`), same as signs/clutter (`_on_clutter_hit` ~`:10832`, `_on_sign_hit` ~`:10520`). Frozen-kinematic = still solid / cars still stop on it (v1 behavior preserved), but now it reports `body_entered`. On hit: if the other body is the car AND `car.linear_velocity.length() >= PFENCE_SHATTER_SPEED` → shatter THIS instance.

2. **Second cached asset — the split segments.** Alongside the merged `_pfence_mesh`, build `_pfence_segments` once at load: the SAME baked/scaled leaf meshes (Material_133 stripped) kept **separate**, each as `{mesh, local_xform}` in instance space. (Same bake as §1; just don't merge.)

**On a qualifying hit (instance `i`):**
- Hide instance `i` in the MultiMesh (set its transform to zero-scale) and free its kinematic collider.
- Spawn each leaf segment as a `RigidBody3D` (collision **layer 4** = destructible, mask = ground+statics) at `instance_xform * local_xform`, with the segment mesh + a convex collider, mass ∝ segment size.
- Impulse per piece = `(radial_from_contact + car_velocity) * k` + small random torque → pieces fan out from the contact point and tumble. The struck instance shatters fully; (optional) a softer impulse to the immediate neighbour instance.
- **Cleanup / cap:** pieces despawn after they sleep (settle) or after a TTL / when the player leaves the radius; cap concurrent shattered instances (despawn oldest beyond the cap). Event-driven, so idle cost is unchanged.

**Persistence of broken state — DECIDED: (a) NO persistence across chunk reload.**
- Flown pieces despawn (TTL / sleep / chunk unload). Shattered instances stay broken **only while the chunk is loaded** (tracked in `_pfence_shattered[ck]`, cleared on `_unload_chunk`); on reload the fence **rebuilds intact**. Clean and cheap.

**Tunables (Phase 2):** `PFENCE_SHATTER_SPEED` (11.1 m/s), impulse scale `k`, random torque, piece TTL, max concurrent shattered instances.

**Out of scope (unchanged):** bending/deformation; below-threshold reaction.

---

## 9. Mandatory visual verification (in the driving scene)

### 9.1 Canonical site — Северное Шоссе × Пионерская (T)
Required checks:
- a zebra crossing exists across Северное Шоссе;
- fences appear **after** the zebra on the **continuing** Северное Шоссе side;
- fences do **not** appear on the intersection side of the zebra;
- fences do **not** appear along the Пионерская stem side;
- fences on **both curbs** of Северное Шоссе;
- each curb has **exactly 3 instances = 12 bays**;
- fences **parallel** to Северное Шоссе;
- fences on the sidewalk/verge side of the curb, **not in the lane**;
- **front face toward the carriageway**;
- no overlap with the zebra; no intrusion into the intersection contour;
- scale looks right.

### 9.2 At least one 4-way major-road intersection
- same per-major-arm rule applied **independently**;
- no duplicates;
- each relevant crossing's fences start on the **body-of-road** side.

---

## 10. Asset scale verification

- Measure scale from **real transformed leaf-mesh vertices**; do **not** trust the stored AABB (Sketchfab nesting + 0.001 root scale + odd per-node transforms).
- Compute the real **instance length L** after import/scale.
- Verify **1 instance = 4 bays**.
- Verify **3 instances align end-to-end** with no visible gaps or overlap.
- Use debug ruler/markers if helpful.
- Tune **bay width target** visually (≈2.0–2.5 m/bay → L ≈ 8–10 m) — **never change the bay count**.
- **Strip the junk plate (#7):** `root_Material_133` is a single textured quad (4 verts, scale 0.002) — a classic Sketchfab backdrop/shadow plane, not part of the railing. When pre-merging surfaces (§6), **whitelist only the structural materials** (158 end posts / 170 posts / 207 panels / 164 rails / 185 finials) and drop `Material_133`. Verify visually it's gone (no floating textured rectangle) and that 185 finials are genuinely caps, not another artifact.

---

## 11. Decisions (confirmed with the user)

1. **`tertiary` → excluded.** Gate stays `{trunk, primary, secondary}`.
2. **Mid-block crossings → skipped.**
3. **Lateral position → inner (sidewalk-side) edge of the curb**, front face toward carriageway.
4. **Exactly 12 bays = 3 instances per curb** — intended length, not to be reduced.
5. **Both curbs.**
6. **Phase 2 shatter documented but NOT in v1.** Mesh deformation/bending out of scope.

**Defaults (tune later, no input needed):** bay width ≈2.0–2.5 m; `fence_after_crossing_gap` ≈0.3–0.8 m; shatter granularity per-segment (Phase 2).

---

## 12. Keep-unchanged checklist

- Asset `russian_city_fence.glb`; composite; no manual cutting for v1.
- Gate `{trunk, primary, secondary}`; `tertiary`/residential/unclassified/service/living_street excluded.
- Mid-block crossings skipped. Both curbs. Exactly 12 bays = 3 instances/curb.
- Lateral: sidewalk side of curb, front face toward carriageway.
- Phase 2 destruction documented, not implemented in v1. Mesh deformation out of scope.
- Tunables exported where appropriate.

---

## 13. Tunables (exported)

`enable_pedestrian_fences`, major-road set, bays-per-site (12, fixed in v1), bay width, `sidewalk_side_fence_offset`, `fence_after_crossing_gap`, intersection search radius (~30 m). *(Phase 2 only:* shatter speed threshold, impact radius, impulse scale, random torque, activate/deactivate radii.*)*

---

## 14. Risk mitigations (code-grounded) — audit table

| # | Concern | Mitigation | Code hook / precedent | Where |
|---|---|---|---|---|
| 1 | Crossing found before its intersection is built (worker-thread race) → permanent skip | Deferred `_deferred_fence_queue[ck]`, drain per frame, **retry on -1**, erase only on unload; drop as mid-block only once chunk is stable | `_deferred_wire_road_queue` skip-if-not-loaded; `_pending_batch_chunks` re-enqueue (~`:8323`); worker build `:3697`/`:3722`, apply `:1829` | §3.2 |
| 2 | v1 fence not solid → car drives through | `StaticBody3D` + aggregate box collider on **layer 1** (solid, like lamps/boxes), not layer 4 | `_create_*_immediate` collision setup; [[roadside_props]] (StaticBody layer 1) | §6 |
| 3 | Analytic offset line ≠ real flared/smoothed curb near junction | Anchor at `cross_pts` (real road edges) + re-project each base via `_find_road_edge_point` / kerb polyline; clip to junction contour | `_find_road_edge_point` (used at `:8284`), `_build_sidewalk_kerbs` (`:8732`), `_intersection_curb_contours` | §3.4 |
| 4 | Order-fragile dedup key → double-spawn | **way_id-primary** key; geometry-quantized fallback only | `item.get("way_id", 0)` in crossing block; wire position-key lesson | §5.2 |
| 5 | 8–10 m rigid instance floats/sinks on slope | Per-instance ground + **pitch to local grade** (sample elev at both ends) | `_sample_elevation(x,y)` | §3.4 |
| 6 | ~130 raw MeshInstances per crossing | Pre-merge GLB → few-surface mesh; **per-chunk MultiMesh** | window/lamp/tree MultiMesh-per-chunk pattern | §6 |
| 7 | Junk textured plate renders as floating rectangle | Whitelist structural materials, **drop `Material_133`** at merge | GLB analysis (single quad, scale 0.002) | §10 |
| 8 | Geometric crossings aren't real zebras | Require `is_tagged_crossing` (`footway=crossing`) only | `is_tagged_crossing` (`:8271`) | §3.1 |
| 9 | Dual carriageway breaks both-curbs / road_width/2 | Detect (`oneway`, small span, parallel sibling); per-outer-curb runs; skip if topology unclear | crossing `edge_span`, way tags | §3.8 |

**Net effect on v1 blockers:** #1 (defer+retry) and #2 (StaticBody layer 1) — resolved in-plan; #3 (curb snap) is the main visual-fit work. All hooks already exist in `osm/osm_terrain_generator.gd` — no new subsystem.

---

## 15. Self-testing requirement — no user-assisted verification

Implementation is not complete until the coding agent has tested the feature independently.

The agent must not ask the user to verify basic placement, orientation, scale, or visual correctness. The agent must reproduce and inspect the result in the running project.

**Required:**
- launch the actual driving scene directly (`res://main.tscn`), not the menu;
- load the target Cherepovets location directly;
- navigate/teleport/drive to the canonical test site: **Северное Шоссе × Пионерская**;
- also test at least one **4-way major-road intersection**;
- use debug camera / editor camera / MCP screenshots / close-up views as needed;
- visually inspect placement from normal driving distance and from close-up;
- fix issues found during inspection without asking the user to confirm obvious visual bugs.

**The agent must verify by itself:**
- fences appear after the zebra on the continuing body-of-road side;
- fences do not appear on the intersection side;
- fences do not appear along the minor stem at the canonical T-intersection;
- fences are on both curbs;
- each curb has exactly 3 instances = 12 bays;
- fences follow the visible curb, including flared/smoothed curb geometry;
- fences are not in the driving lane;
- fences are not floating or sunk into terrain;
- fences are pitched correctly on slopes;
- fences do not overlap the zebra or intrude into the intersection contour;
- front face points toward the carriageway;
- scale is correct and the junk `Material_133` plate is not visible;
- collisions work: the car cannot drive through the static v1 fence.

The agent must use **close-up visual checks**, not just logs or code reasoning.

**If something is ambiguous or wrong** (wrong side of zebra · wrong road arm · wrong curb · bad scale · floating/sinking · lane overlap · duplicate spawn · missing collider) → the agent must **debug and fix it independently**.

The agent may report uncertainty **only after** it has exhausted reasonable self-debugging steps and has concrete evidence explaining what cannot be resolved from the code/game scene.

**Final report must include:**
- what direct scene was launched;
- which locations were tested;
- what visual checks were performed;
- what close-up checks were performed;
- whether screenshots/debug camera views were used;
- whether the canonical Северное Шоссе × Пионерская case passed;
- whether the 4-way major-road case passed;
- whether collisions were tested;
- any remaining limitations.

**Do not claim the feature is done if the scene was not launched and visually inspected.**
