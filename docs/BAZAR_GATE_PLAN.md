# Bazar Gate Plan (`bazar-gate.glb`)

✅ **Shipped.** Placed at 59.145677, 37.946260, `rotation_y` 256°, `scale` 5.9 (~5 m tall), box
collision + two door signs (bazar-sign left, no-entry right). Sign placement is data-driven via
per-sign `u`/`v`/`front`/`size` fractions in the JSON entry (tune without code).

## Goal

Place the market gate `bazar-gate.glb` at OSM point **59.145658, 37.946375**, standing
**perpendicular across service road `219861574`** (i.e. the gate blocks/spans the road like a
bazaar entrance arch). Requirements:

1. The gate must have **collision** (the car is physically stopped by it).
2. **Left door** carries `bazar-sign.png`.
3. **Right door** carries `bazar-no-entry.png`.

## Established facts (from investigation)

### Assets (currently only on disk, NOT in the project)
- `/Users/alekseiaksenov/Desktop/OSM material/bazar-gate.glb` (~10 MB, embedded textures)
- `/Users/alekseiaksenov/Desktop/OSM material/bazar-sign.png` (~145 KB)
- `/Users/alekseiaksenov/Desktop/OSM material/bazar-no-entry.png` (~90 KB)

→ Copy into the project and let the Godot editor import them (never hand-write `.import`, per
the tree-system gotcha). Proposed paths:
- `models/bazar_gate/bazar-gate.glb`
- `models/bazar_gate/bazar-sign.png`, `models/bazar_gate/bazar-no-entry.png`

### Gate model geometry
- **Single mesh** `Mesh_0`, single material `Material_0`, 4 embedded images. **There are NO
  separate left/right door submeshes** → per-door textures cannot be a material override; they
  must be **separate textured quads** placed over each door half.
- Model-space bbox: **X [-0.957 .. 0.955]** (width 1.912), **Y [-0.425 .. 0.423]** (height 0.848),
  **Z [-0.095 .. 0.094]** (depth 0.189).
- Interpretation: thin in Z → the gate is a flat panel. **Span axis = local X**, **face normal =
  local Z**, **up = local Y**. Pivot is ~centered (base at Y ≈ -0.425).
- Left/right door halves ≈ X∈[-0.95, 0] and X∈[0, 0.95]; door faces at Z ≈ ±0.095.

### Placement point & road bearing
- Target point 59.145658, 37.946375 lies **0.33 m from the centerline of way 219861574**
  (segment index 1 of 3 nodes) — i.e. essentially ON the road. Way tags confirm it is the
  `service` road in question.
- Road direction at that segment (local frame, X=east, Z=north): **(+83.45, −21.23)** →
  **bearing ≈ 104.3°**.
- To stand the gate **across** the road, its face normal (local Z) must point **along** the road
  direction → starting **`rotation_y ≈ 104°`**. (Perpendicular-span candidates 14° / 194° are the
  wrong reading — they'd lay the gate flat along the road.) **Confirm visually and flip by
  ±180° / ±90° if reversed** — decide from the on-screen result, do not re-derive (trust-visual rule).

### Existing placement system: `custom_models`
- JSON: `decorations/russia/cherepovets/building_overrides.json` → `custom_models[]`.
  Parsed by `osm/decoration_layer.gd` (`get_custom_models()`), placed by
  `osm/osm_terrain_generator.gd::_place_custom_models_for_chunk()` (~line 18515).
- Per-entry fields today: `model`, `lat`, `lon`, `scale`, `rotation_y` (deg), `y_offset`,
  `visibility_range`, `clear_trees_radius`.
- It instantiates the GLB, grounds at `_sample_elevation + y_offset`, scales uniformly, rotates
  by `rotation_y`, sets visibility range, removes shadows. **It adds NO collision and NO signs.**
- Models with `visibility_range ≤ 300` are parented to the chunk node → auto-freed on chunk
  unload and re-created on reload (no duplicate accumulation). The gate fits this path; no extra
  dedup needed.

### Collision layers (so the car is blocked)
- Buildings use `collision_layer = 2`; roads/curbs/walls use `collision_layer = 1`. The player
  car (GEVP) has `collision_mask = 7` (layers 1+2+4) → it collides with both. The gate should be
  a `StaticBody3D` on **layer 1** (wall-like static world), `mask = 0`.

## Proposed implementation

**Recommended: extend `custom_models`** (data-driven, reusable) rather than a one-off function.

### 1. Import assets
Copy the three files into `models/bazar_gate/`; trigger an editor rescan so `.import` files are
generated. Verify the GLB imports as one `MeshInstance3D`.

### 2. Add optional fields to a `custom_models` entry
Extend `building_override.gd` / `decoration_layer.gd` parsing + `_place_custom_models_for_chunk`
to honor two optional fields:
- `collision`: `"box"` → wrap the instance in a `StaticBody3D` (layer 1, mask 0) with a
  `BoxShape3D` sized from the model's **real-vertex** bbox × `scale` (NOT `get_aabb` — the
  cone-levitation/get-aabb gotcha; box half-extents from actual vertices). Box centered on the
  gate's center, so it spans the doors and is ~0.19·scale thick.
- `signs`: array of `{texture, side: "left"|"right"}` → for each, build a `MeshInstance3D` with a
  `QuadMesh` + unshaded `StandardMaterial3D` (`albedo_texture` = sign, `TRANSPARENCY_ALPHA` if the
  PNG has alpha, `BILLBOARD_DISABLED`, `cull_disabled`), parented to the gate instance at the
  door-half center in local space, nudged off the face along local +Z (the road-approach side) by
  a few cm to avoid z-fighting (also `render_priority`/`no_depth_test`-free, just an offset).
  Quad size ≈ door half (≈ 0.9 × 0.7 of model units before the instance scale; tune visually).

### 3. JSON entry (values to bake)
```jsonc
{
  "comment": "Bazar gate across service road 219861574",
  "model": "res://models/bazar_gate/bazar-gate.glb",
  "lat": 59.145658, "lon": 37.946375,
  "rotation_y": 104.0,            // road bearing; verify + flip visually
  "scale": 3.0,                    // start: ~5.7 m wide × ~2.5 m tall; tune to span the road
  "y_offset": 0.0,                 // OR auto-ground from real min-Y (see §4)
  "visibility_range": 200.0,
  "collision": "box",
  "signs": [
    { "texture": "res://models/bazar_gate/bazar-sign.png",     "side": "left"  },
    { "texture": "res://models/bazar_gate/bazar-no-entry.png", "side": "right" }
  ]
}
```

### 4. Grounding & scale
- **Ground from real vertices**: the gate base is at model-Y −0.425; placement should lift the
  instance by `0.425 · scale` so the base meets the road (compute from real verts in code, or bake
  into `y_offset`). Prefer auto-grounding in the placement code (consistent with the manhole/cone
  lessons) over a magic `y_offset`.
- **Scale**: model proportions are 2.25:1 (wide:tall). Start `scale ≈ 3.0` (≈5.7 m wide, 2.5 m
  tall) so the arch comfortably spans the narrow service road + verges; tune on screen.

## Anti-bugs / gotchas to respect
- **get_aabb is unreliable** for grounding & collision sizing — use `surface_get_arrays()` real
  vertices (cone-levitation gotcha).
- **Perpendicular orientation**: bake `rotation_y ≈ 104°`, then confirm in-engine and flip rather
  than re-deriving the handedness (trust-visual rule).
- **Left/right is viewer-relative**: "left door" = the viewer's left when facing the signed face.
  If the signs land on the wrong doors, swap the X sign of the two quad offsets — don't re-argue
  the geometry.
- **Which face shows the signs**: place both signs on the road-approach face (+Z first); flip to
  −Z if they end up on the back.
- **Sign z-fighting**: small outward offset from the door face; thin quads, no depth issues.
- **Chunk reload**: gate is `visibility_range ≤ 300` → tied to chunk lifecycle, no dedup needed,
  but verify it isn't double-placed if `_place_custom_models_for_chunk` runs twice.
- **Gate on the road**: the point is on the carriageway; the StaticBody will block the service
  road by design (this is intended — a market gate). Confirm it doesn't trap the player with no
  way around if that road is a required route.

## Verification (in-engine, one launch, then stop)
1. Drive the car into the gate → it is **blocked** (collision works), not passed through.
2. Gate **spans the road perpendicular**, base **on the ground**, sensible size.
3. **Left door = bazar-sign**, **right door = no-entry**, both on the approach face, not z-fighting.
4. No console errors; gate reappears correctly after driving away and back (chunk reload).

## Open decisions (for go-ahead)
- **Scale / final size** — start 3.0, or a specific gate height?
- **Collision footprint** — full slab box (recommended) vs. two posts only (car could clip the
  arch gap)? Box is simplest and fully blocks.
- **Approach face** — both signs on the side facing oncoming traffic; confirm which direction is
  "into the bazar."
