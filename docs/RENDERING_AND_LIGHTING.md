# Rendering & Lighting — Look-Dev System

Art-direction targets: **day ≈ GTA V** (warm sunny, punchy filmic contrast), **night ≈ NFS Underground**
(dark neon-lit street, moody moonlight, wet reflective asphalt, heavy bloom).

## Single source of truth

There is exactly one place to edit each time-of-day. The game (`main.tscn`) and the screenshot test
scene (`tests/visual_lookdev.tscn`) both consume these — so **what you see in the look-dev screenshots is
exactly what the game renders**. No copies, no drift.

| Time of day | Edit here | Applied via |
|---|---|---|
| **Day** (Environment + Sun) | [`rendering/world_lighting.tscn`](../rendering/world_lighting.tscn) | Instanced by `main.tscn` and `tests/visual_lookdev.tscn` |
| **Night / Dusk / Rain** | [`night_mode/night_mode_manager.gd`](../night_mode/night_mode_manager.gd) | Runtime mutation of the same Environment + RenderingServer globals |

`world_lighting.tscn` contains the `WorldEnvironment` (tonemap, glow, fog, colour adjustments, ambient) and
the sun `DirectionalLight3D` (colour, energy, angle, shadows). Both `main.tscn` and the look-dev scene
`instance` it. The night manager and `graphics_settings.gd` locate these nodes with recursive
`find_child("WorldEnvironment"/"DirectionalLight3D", true, false)`, so instancing does not break lookups.

> Do **not** re-add an inline `Environment` or `DirectionalLight3D` to `main.tscn` — that reintroduces the
> duplication this system removed.

## Current tuned values

### Day (`world_lighting.tscn`) — GTA V direction
- Tonemap **ACES** (`tonemap_mode=3`), exposure `1.05`, white `6.0` (was AgX — desaturated/flat)
- Sun **warm** `Color(1, 0.93, 0.8)`, energy `1.25` (was cool-white `0.95,0.95,1` @ `1.0`)
- `adjustment_contrast=1.12`, `adjustment_saturation=1.12` (was `1.08` / `0.9`)
- `ambient_light_energy=0.85` (deeper shadows), glow `intensity=0.2 bloom=0.05 threshold=1.1`
- Fog `aerial_perspective=0.5`, `light_color(0.8,0.82,0.85)`, `sun_scatter=0.35` (less blue haze)

### Night (`night_mode_manager.gd`) — NFS Underground direction
- Tonemap **ACES** (holds neon saturation; AgX killed it), exposure `1.28`
- Glow `intensity=1.5 bloom=0.35 threshold=0.55` SCREEN blend, `adjustment_saturation=1.22` (`NIGHT_SATURATION`)
- Ambient `Color(0.06,0.08,0.16)` energy `0.48` (saturated dark blue, readable)
- **Moon** `DirectionalLight3D` energy `0.55`, cool `Color(0.62,0.74,1.0)`, high overhead angle
  `rotation_degrees(-52,40,0)`, soft penumbra `light_angular_distance=1.5`
  (was near-horizon `-15°` → harsh raking shadows)
- Volumetric fog density `0.0035` (was `0.008` — too dense/dark)
- Wet asphalt reflections: SSR + `wetness_global` shader path, enabled on rain (`toggle_rain` / R key)

Day↔night restore: `night_mode_manager._find_scene_components()` captures the day Environment/sun values on
`_ready` and `disable_night_mode()` tweens back to them (incl. `adjustment_saturation`).

## Look-dev screenshot workflow

Scene: `tests/visual_lookdev.tscn` — loads a real cached location (Pionerskaya, Cherepovets), snaps a
frozen hero car onto the nearest road waypoint facing **south (+Z)**, places a gameplay chase camera behind
it, then auto-captures **day / dusk / night / night_rain** to `screenshots/visual/*.png`.

```bash
# full set (day, dusk, night, night_rain)
/Applications/Godot.app/Contents/MacOS/Godot --path . tests/visual_lookdev.tscn -- --load-wait=14

# single phase
... tests/visual_lookdev.tscn -- --only=day        # or dusk | night | rain
```

Flags: `--only=day|dusk|night|rain`, `--load-wait=SECONDS`, `--shot-lat= --shot-lon=`,
`--cam-pos=x,y,z --cam-look=x,y,z`, `--free` (WASD+RMB free camera to scout angles), `--no-quit`.

- **dusk** = the "half day→night" look: capture mid-transition (streetlights on, sun half-dimmed, blue-hour sky).
- Baselines preserved as `screenshots/visual/*_baseline.png` for before/after.
- **Clean exit:** the tool ends with `OS.kill(OS.get_process_id())` (SIGKILL) on purpose. `get_tree().quit()`
  crashes on engine teardown (`WorkerThreadPool::finish()` destroys pending bound-Callables of a half-torn-down
  GDScript → SIGSEGV + macOS crash dialog). PNGs are flushed synchronously before the kill, so nothing is lost.

## Iteration loop
1. Edit `world_lighting.tscn` (day) or `night_mode_manager.gd` (night).
2. Run the look-dev scene (`--only=<phase>` for speed).
3. Read `screenshots/visual/<phase>.png`, compare to the reference target, adjust, repeat.

## LOD0 ↔ LOD2 terrain seam (fixed)

Distant chunks render as flat LOD2 terrain (`_create_flat_terrain`) instead of the detailed
LOD0 mesh. A visible seam appeared at the LOD0/LOD2 boundary — the far grass looked **dark**.
Root cause and fixes (all in [osm/osm_terrain_generator.gd](../osm/osm_terrain_generator.gd)):

1. **Inverted winding (the big one).** LOD2's flat-terrain triangles were wound backwards. The
   grass shader ([shaders/ground.gdshader](../shaders/ground.gdshader)) is `render_mode cull_disabled`,
   so the top surface became a **back face** → Godot negates the shading normal to point *down* →
   the grass faced away from the sun → rendered near-black. LOD0 had correct winding. Fixed by
   flipping the LOD2 index winding so the top is a front face (normal up, lit) — matches LOD0.
2. **Material.** LOD2 used a separate `_ground_shader_material_lod2`; now aliased to the same
   `_ground_shader_material` as LOD0 (identical shader/textures/params).
3. **Ground plane.** The under-terrain ground plane used a grey `StandardMaterial`; now uses the
   grass material so it can never show as a grey line at an edge.
4. **T-junction cracks.** LOD2 used a 10m grid (`grid_res=21`) vs LOD0's 5m grid, so boundary
   vertices didn't line up (cracks where the terrain curves between 10m points). LOD2 now uses
   `grid_res=42` (5m, 43×43 verts — matches LOD0 and the upscaled elevation grid) → boundary
   vertices coincide 1:1, seamless height.

Height offset (`0.11`), UV scale (world×0.25), normals (UP), and elevation function are already
identical between LOD0 and LOD2, so with the above the transition is seamless.

### LOD seam test
[tests/lod_seam_test.tscn](../tests/lod_seam_test.tscn) forces the player's own chunk to LOD0 and
all neighbours to flat LOD2 (via `lod0_distance=105` < chunk size), buildings/vegetation off, camera
at the shared edge looking across — to verify the grass transition.
```bash
Godot --path . tests/lod_seam_test.tscn                       # ground-level seam view
DEBUG_LOD2_MAGENTA=1 Godot --path . tests/lod_seam_test.tscn   # tint LOD2 magenta to see the boundary
```
Flags: `--cam-h=`, `--cam-back=`, `--cam-pitch=`, `--lod0-dist=` (raise to force everything LOD0 for
A/B comparison), `--load-wait=`. The `DEBUG_LOD2_MAGENTA` env var (handled in `_create_flat_terrain`)
tints LOD2 flat terrain magenta for debugging.

## Optional NFS-U pushes not yet done
- Cyan/magenta neon **area lights** near signage/underpasses casting onto the road (current street lamps are
  warm sodium only).
- Subtle **vignette + chromatic aberration** in the night grade (`shaders/color_grading.gdshader` has screen
  access; `ui/scanlines.gdshader` has an unused vignette/chroma implementation to reuse).
- Reflective **dry-night** asphalt (SSR currently only engages while wet/raining).
