# LOD System

Chunk-based Level of Detail system for extending visible world beyond the 500m full-detail zone.

## LOD Levels

| Level | Distance | Content | Cost per chunk |
|-------|----------|---------|----------------|
| LOD0 | 0-500m | Full detail: roads, curbs, lamps, buildings with textures/windows, trees, signs, collisions | ~15 RS instances |
| LOD1 | disabled (=LOD0) | Medium: flat grass, textured buildings, billboard trees. Currently disabled due to freezes during LOD1 building pipeline. | ~5 RS instances |
| LOD2 | 500-1000m | Minimal: flat grass with elevation, solid-color building boxes, no windows/trees/roads | ~1-4 RS instances |

## Configuration (`osm_terrain_generator.gd` exports)

```
lod0_distance = 500.0    # Full detail radius
lod1_distance = 500.0    # Set = lod0 to disable LOD1
lod2_distance = 1000.0   # Minimal detail radius
lod_hysteresis = 50.0    # Extra distance before downgrading LOD
enable_lod = true        # Master switch (false = LOD0 only)
enable_behind_camera_cull = true  # Hide chunks behind camera
behind_cull_dot = -0.4   # LOD0 cull threshold (dot product)
lod_cull_dot = -0.2      # LOD2 cull threshold (less aggressive)
```

## Architecture

### Chunk Loading Pipeline

1. `_get_needed_chunks()` — computes all chunks within lod2_distance, assigns LOD level by distance. **Skips LOD2 chunks behind camera** (dot < -0.3) to reduce count by ~60%.
2. `_enqueue_chunk_load_request()` — priority queue sorted by `_chunk_priority_score()`.
3. OSM data + elevation load in parallel (async HTTP, disk-cached).
4. LOD0: full pipeline (worker thread Phase 1+2 + main thread Phase 3).
5. LOD2: simplified pipeline via `_generate_lod_chunk()` → `_process_lod_chunk_queue()`.

### LOD2 Simplified Pipeline (`_process_lod_chunk_queue`)

- Runs on main thread, no worker threads, no spatial hashes.
- Budget: 4 chunks/frame (8 during initial loading).
- Queue sorted by `_chunk_priority_score()` each frame.
- **Waits for elevation data** before generating — prevents terrain at y=0.
- Generates:
  1. `_create_flat_terrain()` — 5x5 subdivided quad with grass material + elevation sampling.
  2. `_generate_lod2_buildings()` — all buildings batched into single ArrayMesh per color group. Walls + triangulated roof cap. Winding-aware normals (`normal_sign` from `_is_polygon_ccw`).
- No collision, no shadows, no roads, no trees, no decorations.

### LOD Transitions

When a chunk's desired LOD changes (e.g., LOD2 → LOD0 as player approaches):

1. Old RS instances saved to `_lod_transition_rs` (kept visible during rebuild).
2. Chunk unloaded and re-requested at new LOD level.
3. When new chunk finishes activation: old instances immediately hidden (`instance_set_visible(false)`) then freed after 50ms.

### Chunk Priority (`_chunk_priority_score`)

Determines load order, activation order, and queue processing order:

- **x0.25** (highest priority): chunks in 45-degree cone ahead of car velocity vector.
- **x1.0** (normal): chunks in front of camera.
- **x4.0** (lowest): chunks behind camera.

Uses cached `_cached_velocity_dir` (car's `linear_velocity` normalized, falls back to camera forward when stationary).

### Culling (Behind-Camera Only)

No frustum culling — LOD system handles distance, culling only hides chunks behind camera.

- Chunks within 1.5x chunk_size (315m) from car: always visible.
- LOD0 beyond that: hidden if dot < `behind_cull_dot` (-0.4).
- LOD2 beyond that: hidden if dot < `lod_cull_dot` (-0.2).
- Cooldown: LOD0 chunks get 3-second immunity after activation (prevents flash).
- Activating chunks never culled (conflict with lazy activation).

### Lazy Activation

RS instances created invisible, then shown in batches:

- Budget: 20 RS instances/frame (shared across all chunks, prioritized).
- During initial loading: unlimited (loading screen covers stutter).
- Sorted by `_chunk_priority_score` — forward/close chunks activate first.

## Lessons Learned

### Godot Frustum Planes Convention

**DO NOT USE frustum plane AABB tests** — removed after multiple failed attempts. Godot's `Camera3D.get_frustum()` returns planes where:
- `distance_to(point) = normal.dot(point) - d`
- Inside frustum = `distance_to < 0` (despite source code negating normals suggesting inward-pointing)
- AABB outside test should be `d - r > 0.0`, NOT `d + r < 0.0`

The sign convention is confusing and led to bugs where chunks inside the frustum were incorrectly culled. Simple dot-product behind-camera test is more reliable and sufficient.

### Per-Object visibility_range_end

**Removed from all objects.** LOD should be chunk-based only.

Previously, buildings/fences/signs had individual `visibility_range_end` values (150-400m) that caused them to disappear independently of chunk visibility. This looked like "blinking" — chunk node stayed visible (windows OK) but RS instances disappeared at their individual distance thresholds.

Affected locations that were fixed:
- Building walls RS instances: had `vis_max = render_distance` (400m) via `_rs_add_mesh()`
- Building wall MeshInstance3D: had `visibility_range_end = render_distance`
- Window MultiMeshInstance3D: had `visibility_range_end = render_distance`
- Traffic sign poles/faces: had `visibility_range_end = 150`
- Traffic light spheres: had `visibility_range_end = 300`
- Residential/mars entrances: had `visibility_range_end = 200/250`

Exception: custom decoration models from JSON config keep their `visibility_range` setting.

### LOD2 Must Wait for Elevation

LOD2 chunks are generated immediately when OSM data arrives, but elevation is async. Without waiting, terrain renders at y=0. Fix: `_process_lod_chunk_queue` defers chunks until `_chunk_elevation_data` is available.

### Loading Too Many Chunks at Once

With 1000m LOD2 radius and 210m chunks, ~80 chunks are needed. Loading all simultaneously caused freezes. Mitigations:
- LOD2 behind camera not requested at all (cuts ~60%)
- LOD chunk queue sorted by priority (forward first)
- Processing budget: 4 LOD chunks/frame
- Activation budget: 20 RS instances/frame

## Camera Settings

```
camera.far = lod2_distance * 1.25 (1250m)
shadow_max_distance = render_distance (350m)
fog_density = 0.0003 (light atmospheric haze)
fog_aerial_perspective = 0.7
```

## Files

- `osm/osm_terrain_generator.gd` — all LOD logic (monolith, ~22K lines)
  - `_get_needed_chunks()` — chunk selection + LOD assignment
  - `_chunk_priority_score()` — velocity-aware priority
  - `_generate_lod_chunk()` / `_process_lod_chunk_queue()` — LOD2 pipeline
  - `_create_flat_terrain()` — LOD terrain mesh
  - `_generate_lod2_buildings()` — LOD2 building boxes
  - `_update_chunk_culling()` — behind-camera culling
  - `_process_chunk_activation()` — lazy RS instance activation
- `tests/chunk_load_test.gd` — flyover test with P-key settings panel
- `tests/elevation_flyover_test.gd` — elevation test with P-key settings panel
