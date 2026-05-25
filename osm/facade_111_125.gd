extends RefCounted
class_name Facade111_125

## Building-specific facade prototype for OSM way 45836637
## (Северное Шоссе 39, 111-125 panel series, Cherepovets).
##
## Replaces only the vertical wall surfaces between foundation_y and roof_y.
## Existing roof / parapet / foundation / pediment logic in
## _create_3d_building_with_custom_texture is preserved (call that function
## with skip_walls=true, then call Facade111_125.new().build(...) here).
##
## See `decorations/russia/cherepovets/111-125_atoms/` for the 26 source PNGs.

const ATOM_DIR := "res://decorations/russia/cherepovets/111-125_atoms/"
const FACADE_SHADER := preload("res://osm/facade_111_125.gdshader")

# Porch (concrete stair) shape constants.
const PORCH_RISER_M := 0.17                # one step
const PORCH_TREAD_M := 0.30                # step depth
const PORCH_LANDING_M := 0.40              # extra top-platform depth
const PORCH_SAMPLES := 5                   # terrain-sample points along slot width
const PORCH_SAMPLE_OUTWARD_M := 0.4        # sample this far in front of the wall
const PORCH_SEAT_INTO_GROUND_M := 0.05     # bottom step buried into terrain
const PORCH_MIN_HEIGHT_M := 0.05           # below this, don't bother
const PORCH_WIDTH_INSET_M := 0.15          # narrow the porch slightly vs the slot
const PORCH_ATOM := "small-wall-1"         # concrete texture reuse

# Railing shape — slim metal handrail on each side of the stair stack.
const RAIL_HEIGHT_M := 0.9
const RAIL_THICKNESS_M := 0.04
const RAIL_COLOR := Color(0.25, 0.25, 0.28)

# Entrance light placed near the top of the entrance overlay.
const ENTRANCE_LIGHT_COLOR := Color(1.0, 0.9, 0.72)
const ENTRANCE_LIGHT_ENERGY := 4.0
const ENTRANCE_LIGHT_RANGE := 6.0
const ENTRANCE_LIGHT_OFFSET_DOWN_M := 0.25 # below floor top (just under the lintel)
const ENTRANCE_LIGHT_OFFSET_OUT_M := 0.3   # in front of the wall

# Canopy (козырёк) — flat concrete slab above the entrance texture.
const CANOPY_THICKNESS_M := 0.2
const CANOPY_DEPTH_M := 1.4
const CANOPY_OVERHANG_M := 0.15            # canopy extends past slot edges
const CANOPY_ATOM := PORCH_ATOM            # reuse concrete

const ENTRANCE_LAMP_SCRIPT := preload("res://osm/entrance_lamp.gd")

# Px/m scales: 512 px wall = 3.2 m bay (horizontal); 512 px wall = 1 floor
# (vertical). 1 floor height is derived per-building from
# (roof_y - foundation_y) / 12 — so vertical scale is dynamic.
const PX_PER_M_X := 160.0
const NOMINAL_FLOOR_PX := 512.0   # one full atom height = one floor
const SEAM_PX := 30.0              # horizontal seam height in pixels
const VSEAM_TILE_PX := 572.0       # vertical seam texture height = 512 + 2*30

# Z-offsets along wall outward normal (m). Layers must not be coplanar.
const Z_WALL := 0.000
const Z_OVERLAY := 0.015
const Z_HSEAM := 0.030
const Z_VSEAM := 0.045

# Building geometry
const TOTAL_FLOORS := 12

# Edge classification threshold (m). 111-125 long sides ~60–70m, short sides ~12m.
const LONG_SIDE_THRESHOLD_M := 30.0

# Архетип "111-125-12" — серия 111-125, 12 этажей.
# Все дома этого архетипа собираются по одному и тому же рецепту с
# фиксированным RNG-seed, поэтому варианты атомов (wall-1/2/3,
# mid-balcony-1..5, window-1..6 и т.д.) выпадают в одинаковых местах у
# всех домов серии — они выглядят идентично, отличаясь только размером и
# ориентацией полигона.
const ARCHETYPE_ID := "111-125-12"

# Фиксированный RNG-seed для выбора вариантов атомов. Использован
# way_id Северного Шоссе 39 — каноничный дом, по которому отлажен рецепт.
const ARCHETYPE_SEED := 45836637

# OSM way ids, относящиеся к этому архетипу.
#   45836637 — Северное Шоссе 39
#   45836638 — Северное Шоссе 37
#   45836639 — Северное Шоссе 35
const ARCHETYPE_WAY_IDS: Array = [45836637, 45836638, 45836639]

# Сохранено для обратной совместимости со старыми ссылками в коде.
const TARGET_WAY_ID := ARCHETYPE_SEED

static func is_target_way(way_id: int) -> bool:
	return way_id in ARCHETYPE_WAY_IDS

# Slot's world-XZ centre is deduped against `override.entrances` lat/lon
# (converted to local XZ by the caller). If the slot centre is within this
# radius of an OSM-defined entrance, the facade does NOT spawn an extra
# ResidentialEntrance — the existing _add_residential_entrances path already
# handles that location. 6 m is chosen because OSM lat/lon snap to the
# closest wall *point*, not to a slot centre, so the actual offset between
# the snapped OSM position and the facade slot centre is ~5 m on the front
# of 111-125 buildings — anything tighter than 6 m fails to dedup and we
# end up with two entrance groups at the same spot.
const NEARBY_ENTRANCE_RADIUS_M := 6.0

# ── Recipes ────────────────────────────────────────────────────────────────

# Upper-floor pattern for the long side (used by floors 1..11).
const LONG_UPPER := [
	"mid-wall",
	"mid-balcony",
	"window",
	"decorative-balcony",
	"window",
	"mid-balcony",
	"window",
	"window",
	"mid-balcony",
	"window",
	"long-wall-decorative-balcony",
	"window",
	"mid-balcony",
	"mid-wall",
]

# Ground-floor pattern for the long side. The two upper-pattern slots that
# carry decorative balconies (positions 3 and 10) become "wall + mid-wall
# with entrance" pairs on the ground — 16 slots total. Each pair's nominal
# width is 3.2 + 4.8 = 8.0 m but visually occupies the same 6.4 m as the
# upper deco-balcony it replaces; _build_side compresses each pair locally
# so all other slots align vertically with the upper-floor boundaries.
const LONG_GROUND := [
	"mid-wall",
	"mid-balcony",
	"window",
	"small-wall",                 # ← pair 1 (replaces upper deco-balcony at pos 3)
	"mid-wall-entrance",
	"window",
	"mid-balcony",
	"window",
	"window",
	"mid-balcony",
	"window",
	"small-wall",                 # ← pair 2 (replaces upper long-wall-deco-balcony at pos 10)
	"mid-wall-entrance",
	"window",
	"mid-balcony",
	"mid-wall",
]

# Ground-floor entrance-zone pair indices (start of each "small-wall +
# mid-wall-entrance" pair). Each pair sums to 1.6 + 4.8 = 6.4 m, matching
# the 6.4 m the upper-floor deco-balcony slot occupies — so all other slot
# boundaries align vertically across floors without any per-pair scaling.
const LONG_GROUND_ENTRANCE_PAIRS := [3, 11]

# Short-side pattern (12 floors uniform, no special ground).
const SHORT := [
	"long-wall",
	"long-wall-decorative-window",
]

# ── Slot definitions ───────────────────────────────────────────────────────
# Each slot has a nominal width (m), a list of background atom variants
# (file basenames in ATOM_DIR, no extension), and optionally an overlay or
# list of overlay variants plus the px offset from the floor top.

const SLOT_DEFS := {
	"wall": {
		"width_m": 3.2,
		"bg_variants": ["wall-1", "wall-2", "wall-3"],
		"overlay_variants": [],
		"overlay_offset_top_px": 0,
	},
	"small-wall": {
		# Real 256x512 cut from wall-1 (saved as small-wall-1.png). Used
		# in the ground-floor "small-wall + mid-wall-entrance" pair so
		# the pair sums to 6.4 m exactly without any local slot
		# compression — and so the entrance texture doesn't overshoot
		# its slot edge.
		"width_m": 1.6,
		"bg_variants": ["small-wall-1"],
		"overlay_variants": [],
		"overlay_offset_top_px": 0,
	},
	"mid-wall": {
		"width_m": 4.8,
		"bg_variants": ["mid-wall-1"],
		"overlay_variants": [],
		"overlay_offset_top_px": 0,
	},
	"long-wall": {
		"width_m": 6.4,
		"bg_variants": ["long-wall-1"],
		"overlay_variants": [],
		"overlay_offset_top_px": 0,
	},
	"mid-balcony": {
		# The mid-balcony PNGs have a transparent surround (~34 % of the
		# texture is alpha=0), so they are alpha overlays painted on a
		# mid-wall background — not self-contained modules.
		"width_m": 4.8,
		"bg_variants": ["mid-wall-1"],
		"overlay_variants": ["mid-balcony-1", "mid-balcony-2", "mid-balcony-3", "mid-balcony-4", "mid-balcony-5"],
		"overlay_offset_top_px": 0,
	},
	"window": {
		"width_m": 3.2,
		"bg_variants": ["wall-1", "wall-2", "wall-3"],
		"overlay_variants": ["window-1", "window-2", "window-3", "window-4", "window-5", "window-6"],
		"overlay_offset_top_px": 80,
	},
	"decorative-balcony": {
		"width_m": 6.4,
		"bg_variants": ["long-wall-1"],
		"overlay_variants": ["long-decorative-balcony-1"],
		"overlay_offset_top_px": 60,
	},
	"long-wall-decorative-balcony": {
		# Collapsed to the same construction as "decorative-balcony"; two
		# names in the user's recipe map to the same texture pair.
		"width_m": 6.4,
		"bg_variants": ["long-wall-1"],
		"overlay_variants": ["long-decorative-balcony-1"],
		"overlay_offset_top_px": 60,
	},
	"mid-wall-entrance": {
		# Entrance fills the full ground-floor height of a mid-wall slot
		# (entrance-1 is 768×512 = same dimensions as mid-wall-1).
		"width_m": 4.8,
		"bg_variants": ["mid-wall-1"],
		"overlay_variants": ["entrance-1"],
		"overlay_offset_top_px": 0,
	},
	"long-wall-decorative-window": {
		"width_m": 6.4,
		"bg_variants": ["long-wall-1"],
		"overlay_variants": ["decorative-window-1"],
		"overlay_offset_top_px": 60,
	},
}

# Texture pixel dimensions for overlay/seam sizing.
const TEX_DIMS := {
	"decorative-window-1": Vector2(400, 320),
	"entrance-1": Vector2(768, 512),
	"long-decorative-balcony-1": Vector2(920, 320),
	"window-1": Vector2(320, 320),
	"window-2": Vector2(320, 320),
	"window-3": Vector2(320, 320),
	"window-4": Vector2(320, 320),
	"window-5": Vector2(320, 320),
	"window-6": Vector2(320, 320),
	"mid-balcony-1": Vector2(768, 512),
	"mid-balcony-2": Vector2(768, 512),
	"mid-balcony-3": Vector2(768, 512),
	"mid-balcony-4": Vector2(768, 512),
	"mid-balcony-5": Vector2(768, 512),
	"horiz-seam-1": Vector2(512, 30),
	"horiz-mid-seam-1": Vector2(768, 30),
	"horiz-long-seam-1": Vector2(1024, 30),
	"horiz-decorative-seam-1": Vector2(512, 30),
	"horiz-long-decorative-seam-1": Vector2(1024, 30),
	"vert-seam-1": Vector2(30, 572),
	"vert-decorative-seam-1": Vector2(60, 572),
}

# Cache of loaded textures (shared between buildings if multiple use this archetype later).
static var _tex_cache: Dictionary = {}

# Per-build accumulators: atom_id -> { "verts": PackedVector3Array, ... }
var _batches: Dictionary = {}
var _seed: int = 0
# Stash for entrance spawn: filled by `build()`, used by `_build_side` when
# it encounters a `mid-wall-entrance` slot.
var _terrain_gen: Node3D = null
var _override_entrances_local: Array = []  # Array[Vector2] in local XZ
var _parent_node: Node3D = null


# ── Public API ─────────────────────────────────────────────────────────────

## Build the facade walls for Северное Шоссе 39 between foundation_y and roof_y.
## Adds one or more MeshInstance3D children to `parent` (one per unique texture).
## Does NOT generate roof, parapet, foundation, pediment — caller (the existing
## _create_3d_building_with_custom_texture with skip_walls=true) handles those.
##
## `terrain_gen` is the OSMTerrainGenerator; used to spawn ResidentialEntrance
## groups at facade `mid-wall-entrance` slots. `override_entrances_local` is
## the list of OSM override entrances in local XZ — used to dedup so the
## facade doesn't add a duplicate group on top of one already spawned by
## OSMTerrainGenerator._add_residential_entrances.
func build(points: PackedVector2Array, building_height: float, base_elev: float, parent: Node3D, foundation_h: float, way_id: int, terrain_gen: Node3D = null, override_entrances_local: Array = []) -> void:
	if points.size() < 3:
		return

	# All buildings of this archetype use the SAME RNG seed so they pick
	# identical atom variants. `way_id` is still threaded through for
	# logs / future per-building overrides.
	_seed = ARCHETYPE_SEED
	_batches.clear()
	_terrain_gen = terrain_gen
	_override_entrances_local = override_entrances_local
	_parent_node = parent

	var foundation_y: float = base_elev + foundation_h
	var roof_y: float = base_elev + building_height
	var avail_h: float = roof_y - foundation_y
	if avail_h <= 0.5:
		return

	var floor_h: float = avail_h / float(TOTAL_FLOORS)
	var seam_h: float = floor_h * SEAM_PX / NOMINAL_FLOOR_PX

	# Polygon winding determines which side is outward.
	var is_ccw: bool = _is_polygon_ccw(points)

	for i in range(points.size()):
		var p1: Vector2 = points[i]
		var p2: Vector2 = points[(i + 1) % points.size()]
		var length: float = p1.distance_to(p2)
		if length < 1.0:
			continue
		var is_long_side: bool = length >= LONG_SIDE_THRESHOLD_M
		_build_side(p1, p2, length, foundation_y, floor_h, seam_h, is_ccw, is_long_side, i)
	# Print diagnostic so we can verify the recipe matched expected side counts.
	# (One-shot per build; remove later.)
	var n_long: int = 0
	var n_short: int = 0
	for i in range(points.size()):
		var p1: Vector2 = points[i]
		var p2: Vector2 = points[(i + 1) % points.size()]
		var l: float = p1.distance_to(p2)
		if l >= LONG_SIDE_THRESHOLD_M:
			n_long += 1
		elif l >= 1.0:
			n_short += 1
	print("[Facade111_125] archetype=%s way=%d edges=%d long=%d short=%d is_ccw=%s avail_h=%.1fm floor_h=%.2fm" % [ARCHETYPE_ID, way_id, points.size(), n_long, n_short, str(is_ccw), avail_h, floor_h])

	# Commit batches as MeshInstance3D children.
	for atom_id in _batches.keys():
		var batch: Dictionary = _batches[atom_id]
		var verts: PackedVector3Array = batch["verts"]
		if verts.size() == 0:
			continue
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_TEX_UV] = batch["uvs"]
		arrays[Mesh.ARRAY_NORMAL] = batch["normals"]
		arrays[Mesh.ARRAY_INDEX] = batch["indices"]

		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = _make_material(atom_id, batch["alpha"])
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		mi.name = "Facade111_125_" + atom_id
		parent.add_child(mi)


# ── Side construction ──────────────────────────────────────────────────────

func _build_side(p1: Vector2, p2: Vector2, edge_length: float, foundation_y: float, floor_h: float, seam_h: float, is_ccw: bool, is_long_side: bool, edge_idx: int) -> void:
	var edge_dir: Vector2 = (p2 - p1).normalized()
	# CCW polygons viewed from +Y down → outward normal is right of edge_dir.
	# In Godot's XZ ground plane, that's (edge_dir.y, -edge_dir.x) for CCW.
	var outward_2d: Vector2
	if is_ccw:
		outward_2d = Vector2(edge_dir.y, -edge_dir.x)
	else:
		outward_2d = Vector2(-edge_dir.y, edge_dir.x)
	var normal_3d := Vector3(outward_2d.x, 0.0, outward_2d.y)

	var upper_pattern: Array = LONG_UPPER if is_long_side else SHORT
	var ground_pattern: Array = LONG_GROUND if is_long_side else SHORT
	var upper_nominal: float = _pattern_nominal_length(upper_pattern)
	# All floors use the upper pattern's nominal length as the scaling
	# basis, so slot boundaries align vertically across floors. The ground
	# floor's "wall + mid-wall-entrance" pairs (8.0 m nominal each) are
	# locally compressed inside this scale so each pair fits into the 6.4 m
	# previously occupied by the upper-floor deco-balcony slot it replaces.
	var scale: float = edge_length / upper_nominal

	# 1. Wall backgrounds + overlays, per floor.
	for floor_idx in range(TOTAL_FLOORS):
		var is_ground: bool = (floor_idx == 0)
		var pattern: Array = ground_pattern if is_ground else upper_pattern
		var y_bot: float = foundation_y + floor_idx * floor_h
		var y_top: float = y_bot + floor_h

		var t: float = 0.0
		for slot_idx in range(pattern.size()):
			var role: String = pattern[slot_idx]
			var slot: Dictionary = SLOT_DEFS[role]
			var slot_w: float = float(slot["width_m"]) * scale
			var t_next: float = t + slot_w

			# Background quad.
			var bg_id: String = _pick_variant(slot["bg_variants"], floor_idx, edge_idx, slot_idx, 0)
			_emit_quad(p1, edge_dir, outward_2d, normal_3d, t, t_next, y_bot, y_top, Z_WALL, bg_id, false, is_ccw)

			# Overlay quad, if any.
			var overlay_variants: Array = slot.get("overlay_variants", [])
			if overlay_variants.size() > 0:
				var ov_id: String = _pick_variant(overlay_variants, floor_idx, edge_idx, slot_idx, 1)
				var ov_dim: Vector2 = TEX_DIMS[ov_id]
				# Overlay width scales with slot horizontal scale; overlay
				# height scales with the floor height.
				var ov_w_m: float = (ov_dim.x / PX_PER_M_X) * scale
				var ov_h_m: float = (ov_dim.y / NOMINAL_FLOOR_PX) * floor_h
				var ov_off_top: float = (float(slot["overlay_offset_top_px"]) / NOMINAL_FLOOR_PX) * floor_h
				var center_t: float = (t + t_next) * 0.5
				var ov_left_t: float = center_t - ov_w_m * 0.5
				var ov_right_t: float = center_t + ov_w_m * 0.5
				var ov_y_top: float = y_top - ov_off_top
				var ov_y_bot: float = ov_y_top - ov_h_m
				_emit_quad(p1, edge_dir, outward_2d, normal_3d, ov_left_t, ov_right_t, ov_y_bot, ov_y_top, Z_OVERLAY, ov_id, true, is_ccw)

			# Spawn a bare porch (stairs + railings + entrance light) at
			# each ground-floor mid-wall-entrance slot. OSM lat/lon
			# residential entrances are explicitly disabled for this
			# building in osm_terrain_generator.gd, so no dedup needed.
			if is_ground and role == "mid-wall-entrance":
				_spawn_facade_porch(p1, edge_dir, outward_2d, normal_3d, t, t_next, y_bot, y_top, is_ccw)

			t = t_next

	# 2. Horizontal seams: one per inter-floor boundary, segmented along the
	# upper pattern (same segmentation reused for every horizontal seam).
	# Seams adjacent to the entrance group on the ground floor below also
	# use the decorative variant — the entrance is decorated, so it
	# inherits the deco-balcony seam rule.
	for boundary_idx in range(TOTAL_FLOORS - 1):
		var y_seam_center: float = foundation_y + (boundary_idx + 1) * floor_h
		var y_seam_bot: float = y_seam_center - seam_h * 0.5
		var y_seam_top: float = y_seam_center + seam_h * 0.5
		var is_lowest_boundary: bool = (boundary_idx == 0)

		var t: float = 0.0
		for slot_idx in range(upper_pattern.size()):
			var role: String = upper_pattern[slot_idx]
			var slot: Dictionary = SLOT_DEFS[role]
			var slot_w: float = float(slot["width_m"]) * scale

			# Decorative seam if the slot above OR the corresponding
			# ground slot directly below (only the lowest inter-floor
			# seam) is a deco zone (deco balcony or entrance group).
			var is_deco_above: bool = _is_decorative_zone_role(role)
			var is_deco_below: bool = false
			if is_lowest_boundary and is_long_side:
				# The upper slot at index `slot_idx` is replaced by either
				# 1 or 2 ground slots in the same horizontal band — flag
				# decorative if any of them is decorative.
				is_deco_below = _ground_band_is_decorative(slot_idx)
			var is_deco: bool = is_deco_above or is_deco_below

			var seam_id: String = _pick_horiz_seam(float(slot["width_m"]), is_deco)
			_emit_quad(p1, edge_dir, outward_2d, normal_3d, t, t + slot_w, y_seam_bot, y_seam_top, Z_HSEAM, seam_id, true, is_ccw)
			t += slot_w

	# 3. Vertical seams.
	# Upper-pattern boundaries get a full-height stack (one tile per
	# floor); ground-only boundaries (inside compressed entrance pairs)
	# get a single ground-floor tile. Decorative-seam rule treats both
	# deco-balcony AND mid-wall-entrance neighbors as decorative — the
	# entrance reads visually as a decorative zone, same as the balcony
	# above it.
	var upper_boundaries: Array = _internal_boundaries_uniform(upper_pattern, scale, false, false)
	var ground_boundaries: Array = _internal_boundaries_uniform(ground_pattern, scale, true, is_long_side)

	for b in upper_boundaries:
		var t_seam: float = b["t"]
		var is_deco: bool = _is_decorative_zone_role(b["left"]) or _is_decorative_zone_role(b["right"])
		# Inherit decorative seam from the ground floor's band at this
		# horizontal position too: an entrance group directly below the
		# upper deco-balcony justifies the wider seam across the whole
		# height (visual continuity).
		if is_long_side and not is_deco:
			is_deco = _ground_band_pair_is_decorative_at(t_seam, upper_pattern, scale)
		var seam_id: String = "vert-decorative-seam-1" if is_deco else "vert-seam-1"
		var seam_w_m: float = TEX_DIMS[seam_id].x / PX_PER_M_X
		for floor_idx in range(TOTAL_FLOORS):
			var y_bot: float = foundation_y + floor_idx * floor_h - seam_h
			var y_top: float = foundation_y + (floor_idx + 1) * floor_h + seam_h
			y_bot = maxf(y_bot, foundation_y)
			y_top = minf(y_top, foundation_y + TOTAL_FLOORS * floor_h)
			_emit_quad(p1, edge_dir, outward_2d, normal_3d, t_seam - seam_w_m * 0.5, t_seam + seam_w_m * 0.5, y_bot, y_top, Z_VSEAM, seam_id, true, is_ccw)

	# Ground-only boundaries (inside compressed entrance pairs).
	for b in ground_boundaries:
		var t_seam: float = b["t"]
		if _has_near_boundary(upper_boundaries, t_seam, 0.3):
			continue
		# The boundary inside a "small-wall + mid-wall-entrance" pair gets
		# NO seam — the decorative seam wraps the whole pair on the
		# outside (those outer seams are already handled by the
		# upper-pattern vertical-seam loop above), and the user wants the
		# small wall and the entrance to read as a single visual unit.
		if b["left"] == "small-wall" and b["right"] == "mid-wall-entrance":
			continue
		var is_deco: bool = _is_decorative_zone_role(b["left"]) or _is_decorative_zone_role(b["right"])
		var seam_id: String = "vert-decorative-seam-1" if is_deco else "vert-seam-1"
		var seam_w_m: float = TEX_DIMS[seam_id].x / PX_PER_M_X
		var y_bot: float = foundation_y - seam_h
		var y_top: float = foundation_y + floor_h + seam_h
		y_bot = maxf(y_bot, foundation_y)
		_emit_quad(p1, edge_dir, outward_2d, normal_3d, t_seam - seam_w_m * 0.5, t_seam + seam_w_m * 0.5, y_bot, y_top, Z_VSEAM, seam_id, true, is_ccw)


# ── Entrance porch (stairs + railings + lamp) ──────────────────────────────

# At each ground-floor mid-wall-entrance slot we build a minimal concrete
# porch: multi-step stairs from sampled terrain to the bottom of the
# entrance texture (= foundation_y / floor y_bot for the ground row), two
# slim metal handrails on the sides, and a warm OmniLight3D just under the
# top of the door texture. No doors / canopy / coloured wall — the
# entrance overlay PNG already supplies that visual.
func _spawn_facade_porch(p1: Vector2, edge_dir: Vector2, outward_2d: Vector2, normal_3d: Vector3, t_left: float, t_right: float, foundation_y: float, y_top: float, is_ccw: bool) -> void:
	if _parent_node == null:
		return

	var slot_w: float = t_right - t_left
	var porch_w: float = maxf(0.3, slot_w - 2.0 * PORCH_WIDTH_INSET_M)
	var t_centre: float = (t_left + t_right) * 0.5
	var porch_t_left: float = t_centre - porch_w * 0.5
	var porch_t_right: float = t_centre + porch_w * 0.5

	# Sample terrain at multiple points across the porch front face to
	# capture sloping ground.
	var ground_min: float = INF
	if _terrain_gen != null and _terrain_gen.has_method("_sample_elevation"):
		for i in range(PORCH_SAMPLES):
			var t_n: float = float(i) / float(PORCH_SAMPLES - 1)
			var t_along: float = lerpf(porch_t_left, porch_t_right, t_n)
			var sample_pt: Vector2 = p1 + edge_dir * t_along + outward_2d * PORCH_SAMPLE_OUTWARD_M
			var e: float = _terrain_gen._sample_elevation(sample_pt.x, sample_pt.y)
			if e < ground_min:
				ground_min = e
	if ground_min == INF:
		ground_min = foundation_y  # safe fallback — produces no stairs

	var porch_top_y: float = foundation_y
	var porch_bot_y: float = ground_min - PORCH_SEAT_INTO_GROUND_M
	var height: float = porch_top_y - porch_bot_y

	# Stairs (only if the drop is meaningful).
	var n_steps: int = 0
	var actual_riser: float = 0.0
	if height >= PORCH_MIN_HEIGHT_M:
		n_steps = maxi(1, int(ceilf(height / PORCH_RISER_M)))
		actual_riser = height / float(n_steps)
		for i in range(n_steps):
			# i=0 is the TOP step (against the wall); i=n_steps-1 is the
			# bottom (furthest from wall).
			var step_top: float = porch_top_y - i * actual_riser
			var step_bot: float = step_top - actual_riser
			var out_inner: float = i * PORCH_TREAD_M
			var out_outer: float = out_inner + PORCH_TREAD_M
			if i == 0:
				out_outer += PORCH_LANDING_M
			_emit_porch_tread(p1, edge_dir, outward_2d, porch_t_left, porch_t_right, out_inner, out_outer, step_top)
			_emit_porch_riser(p1, edge_dir, outward_2d, normal_3d, porch_t_left, porch_t_right, out_outer, step_bot, step_top, is_ccw)

	# Railings — one on each side, running from the wall along the side of
	# the stair stack. Built as standalone MeshInstance3D children of the
	# building parent (separate dark metal material).
	var n_steps_for_rail: int = maxi(n_steps, 1)
	var total_depth: float = float(n_steps_for_rail) * PORCH_TREAD_M + PORCH_LANDING_M
	_emit_porch_railing(p1, edge_dir, outward_2d, porch_t_left,  porch_top_y, porch_bot_y, total_depth)
	_emit_porch_railing(p1, edge_dir, outward_2d, porch_t_right, porch_top_y, porch_bot_y, total_depth)

	# Box collision for the two railings + the stair stack. Single
	# StaticBody3D for the whole porch so the car bumps into the rails
	# and can't drive through the stairs.
	_emit_porch_collision(p1, edge_dir, outward_2d, porch_t_left, porch_t_right, porch_top_y, porch_bot_y, total_depth)

	# Canopy (козырёк) — concrete slab above the entrance texture,
	# extending outward over the porch.
	_emit_porch_canopy(p1, edge_dir, outward_2d, normal_3d, t_left, t_right, y_top, is_ccw)

	# Entrance lamp — OmniLight3D that lights only at night
	# (EntranceLamp listens to NightModeManager.night_mode_changed).
	var lamp_t: float = t_centre
	var lamp_anchor: Vector2 = p1 + edge_dir * lamp_t + outward_2d * ENTRANCE_LIGHT_OFFSET_OUT_M
	var lamp: OmniLight3D = ENTRANCE_LAMP_SCRIPT.new()
	lamp.position = Vector3(lamp_anchor.x, y_top - ENTRANCE_LIGHT_OFFSET_DOWN_M, lamp_anchor.y)
	lamp.light_color = ENTRANCE_LIGHT_COLOR
	lamp.light_energy = ENTRANCE_LIGHT_ENERGY
	lamp.omni_range = ENTRANCE_LIGHT_RANGE
	lamp.omni_attenuation = 1.5
	lamp.shadow_enabled = false
	_parent_node.add_child(lamp)


# Horizontal step top — a quad with normal pointing +Y.
func _emit_porch_tread(p1: Vector2, edge_dir: Vector2, outward_2d: Vector2, t_l: float, t_r: float, out_inner: float, out_outer: float, y: float) -> void:
	var p_bl: Vector2 = p1 + edge_dir * t_l + outward_2d * out_inner   # back-left (closer to wall)
	var p_br: Vector2 = p1 + edge_dir * t_r + outward_2d * out_inner
	var p_fr: Vector2 = p1 + edge_dir * t_r + outward_2d * out_outer   # front-right (outer edge)
	var p_fl: Vector2 = p1 + edge_dir * t_l + outward_2d * out_outer
	var v_bl := Vector3(p_bl.x, y, p_bl.y)
	var v_br := Vector3(p_br.x, y, p_br.y)
	var v_fr := Vector3(p_fr.x, y, p_fr.y)
	var v_fl := Vector3(p_fl.x, y, p_fl.y)
	# Winding bl → fl → fr → br gives geometric face normal +Y (face up).
	_emit_quad_corners(PORCH_ATOM, v_bl, v_fl, v_fr, v_br, Vector3.UP)


# Vertical step front — same orientation as a wall quad (faces outward).
func _emit_porch_riser(p1: Vector2, edge_dir: Vector2, outward_2d: Vector2, normal_3d: Vector3, t_l: float, t_r: float, out_face: float, y_bot: float, y_top: float, is_ccw: bool) -> void:
	_emit_quad(p1, edge_dir, outward_2d, normal_3d, t_l, t_r, y_bot, y_top, out_face, PORCH_ATOM, false, is_ccw)


# Slim dark-metal railing on one side of the stair stack. Drawn as a single
# thin vertical quad rising from the bottom step's outer edge to the top
# platform's wall edge, sloping along the stair angle.
func _emit_porch_railing(p1: Vector2, edge_dir: Vector2, outward_2d: Vector2, t_along: float, porch_top_y: float, porch_bot_y: float, total_depth: float) -> void:
	# 4 corners of the railing quad (viewed from outside the building):
	#   tw = top corner against wall
	#   to = top corner at outer edge of platform
	#   bo = bottom corner at outer edge of platform (sloping handrail end)
	# We draw the railing as a TRAPEZOID: high near wall, sloping down to
	# the outer end where it meets the bottom step.
	var anchor_wall: Vector2 = p1 + edge_dir * t_along
	var anchor_outer: Vector2 = anchor_wall + outward_2d * total_depth
	var rail_top_wall_y: float = porch_top_y + RAIL_HEIGHT_M
	var rail_top_outer_y: float = porch_bot_y + RAIL_HEIGHT_M
	# Build a thin box: extrude the trapezoid by RAIL_THICKNESS_M along the
	# horizontal in-edge direction. To keep things simple and one-sided we
	# emit two faces (front + back).
	var thick_dir: Vector2 = edge_dir * RAIL_THICKNESS_M * 0.5
	var p_outer_a: Vector2 = anchor_wall - thick_dir
	var p_outer_b: Vector2 = anchor_wall + thick_dir
	var p_far_a: Vector2 = anchor_outer - thick_dir
	var p_far_b: Vector2 = anchor_outer + thick_dir
	# Two facing quads. Each is a vertical trapezoid in world space.
	# Quad A (facing edge_dir-positive side):
	var v_tl_a := Vector3(p_outer_b.x, rail_top_wall_y,  p_outer_b.y)
	var v_tr_a := Vector3(p_far_b.x,   rail_top_outer_y, p_far_b.y)
	var v_br_a := Vector3(p_far_b.x,   porch_bot_y,      p_far_b.y)
	var v_bl_a := Vector3(p_outer_b.x, porch_top_y,      p_outer_b.y)
	# Quad B (facing edge_dir-negative side):
	var v_tl_b := Vector3(p_outer_a.x, rail_top_wall_y,  p_outer_a.y)
	var v_tr_b := Vector3(p_far_a.x,   rail_top_outer_y, p_far_a.y)
	var v_br_b := Vector3(p_far_a.x,   porch_bot_y,      p_far_a.y)
	var v_bl_b := Vector3(p_outer_a.x, porch_top_y,      p_outer_a.y)
	# Use a separate batch keyed "porch-rail" with a dark metal material.
	# Normals approximate — direction-disagnostic since the railing is
	# viewed from both sides via cull_disabled.
	var n_a := Vector3(edge_dir.x, 0.0, edge_dir.y)
	var n_b := -n_a
	_emit_quad_corners("__porch_rail__", v_bl_a, v_tl_a, v_tr_a, v_br_a, n_a)
	_emit_quad_corners("__porch_rail__", v_br_b, v_tr_b, v_tl_b, v_bl_b, n_b)


# Concrete canopy (козырёк) above the entrance overlay. Thin horizontal
# slab at the door's top, extending outward over the porch. Built as a
# closed 6-face box; back face omitted (it's flush with the wall and
# would only ever be seen from inside the building).
func _emit_porch_canopy(p1: Vector2, edge_dir: Vector2, outward_2d: Vector2, normal_3d: Vector3, slot_t_left: float, slot_t_right: float, y_door_top: float, is_ccw: bool) -> void:
	var c_t_l: float = slot_t_left - CANOPY_OVERHANG_M
	var c_t_r: float = slot_t_right + CANOPY_OVERHANG_M
	var y_bot: float = y_door_top
	var y_top: float = y_door_top + CANOPY_THICKNESS_M
	var out_far: float = CANOPY_DEPTH_M  # outward from wall

	# Front-face anchors (along outward at out_far).
	# We'll express positions via the wall+outward parameterisation and
	# rely on _emit_quad_corners for the freely-oriented faces.

	# Helper: anchor of a point at (t_along, outward_d, y).
	# (declared inline as small closures via local funcs would be heavy in
	#  GDScript — just compute Vector3 directly here.)

	# Top face (normal +Y) — bl=back-left, fl=front-left, fr=front-right, br=back-right.
	var p_bl_top: Vector2 = p1 + edge_dir * c_t_l
	var p_br_top: Vector2 = p1 + edge_dir * c_t_r
	var p_fl_top: Vector2 = p_bl_top + outward_2d * out_far
	var p_fr_top: Vector2 = p_br_top + outward_2d * out_far
	_emit_quad_corners(CANOPY_ATOM,
		Vector3(p_bl_top.x, y_top, p_bl_top.y),
		Vector3(p_fl_top.x, y_top, p_fl_top.y),
		Vector3(p_fr_top.x, y_top, p_fr_top.y),
		Vector3(p_br_top.x, y_top, p_br_top.y),
		Vector3.UP)

	# Bottom face (normal -Y) — reverse winding so geometric face normal
	# points down (visible from below where the user stands).
	_emit_quad_corners(CANOPY_ATOM,
		Vector3(p_bl_top.x, y_bot, p_bl_top.y),
		Vector3(p_br_top.x, y_bot, p_br_top.y),
		Vector3(p_fr_top.x, y_bot, p_fr_top.y),
		Vector3(p_fl_top.x, y_bot, p_fl_top.y),
		Vector3.DOWN)

	# Front face (normal outward).
	_emit_quad(p1, edge_dir, outward_2d, normal_3d, c_t_l, c_t_r, y_bot, y_top, out_far, CANOPY_ATOM, false, is_ccw)

	# Left side (normal -edge_dir) — connects wall edge to front edge on the
	# t=c_t_l plane.
	var n_left := Vector3(-edge_dir.x, 0.0, -edge_dir.y)
	var p_wall_l: Vector2 = p1 + edge_dir * c_t_l
	var p_front_l: Vector2 = p_wall_l + outward_2d * out_far
	_emit_quad_corners(CANOPY_ATOM,
		Vector3(p_wall_l.x,  y_bot, p_wall_l.y),
		Vector3(p_front_l.x, y_bot, p_front_l.y),
		Vector3(p_front_l.x, y_top, p_front_l.y),
		Vector3(p_wall_l.x,  y_top, p_wall_l.y),
		n_left)

	# Right side (normal +edge_dir).
	var n_right := Vector3(edge_dir.x, 0.0, edge_dir.y)
	var p_wall_r: Vector2 = p1 + edge_dir * c_t_r
	var p_front_r: Vector2 = p_wall_r + outward_2d * out_far
	_emit_quad_corners(CANOPY_ATOM,
		Vector3(p_wall_r.x,  y_bot, p_wall_r.y),
		Vector3(p_wall_r.x,  y_top, p_wall_r.y),
		Vector3(p_front_r.x, y_top, p_front_r.y),
		Vector3(p_front_r.x, y_bot, p_front_r.y),
		n_right)


# StaticBody3D with box collision shapes for the porch railings and stairs,
# attached as a child of the building parent so the car bumps off rails
# and can't drive through the stair stack.
func _emit_porch_collision(p1: Vector2, edge_dir: Vector2, outward_2d: Vector2, t_left: float, t_right: float, porch_top_y: float, porch_bot_y: float, total_depth: float) -> void:
	if _parent_node == null:
		return
	var body := StaticBody3D.new()
	body.collision_layer = 2
	body.collision_mask = 0

	# Wall-tangent and outward direction vectors in 3D.
	var t_dir := Vector3(edge_dir.x, 0.0, edge_dir.y)
	var out_dir := Vector3(outward_2d.x, 0.0, outward_2d.y)

	# Rail height max y (approx): the higher edge of the trapezoid sits at
	# porch_top_y + RAIL_HEIGHT_M.
	var rail_top_y: float = porch_top_y + RAIL_HEIGHT_M
	var rail_height: float = rail_top_y - porch_bot_y
	var rail_centre_y: float = (rail_top_y + porch_bot_y) * 0.5

	# Two railings (left + right).
	for t_along in [t_left, t_right]:
		var anchor_wall: Vector2 = p1 + edge_dir * t_along
		var centre_2d: Vector2 = anchor_wall + outward_2d * (total_depth * 0.5)
		var rail_centre := Vector3(centre_2d.x, rail_centre_y, centre_2d.y)
		var rail_shape := BoxShape3D.new()
		rail_shape.size = Vector3(RAIL_THICKNESS_M, rail_height, total_depth)
		var rail_collider := CollisionShape3D.new()
		rail_collider.shape = rail_shape
		# Orient the box: local +X along edge_dir, local +Z along outward.
		var basis := Basis(t_dir, Vector3.UP, out_dir)
		rail_collider.transform = Transform3D(basis, rail_centre)
		body.add_child(rail_collider)

	# One big block under the whole stair stack so the car doesn't drive
	# through it. Box covers from the wall to the porch's outer edge,
	# width = (t_right - t_left), height = porch top - porch bot.
	if porch_top_y > porch_bot_y:
		var slot_centre: Vector2 = p1 + edge_dir * ((t_left + t_right) * 0.5) + outward_2d * (total_depth * 0.5)
		var stair_centre := Vector3(slot_centre.x, (porch_top_y + porch_bot_y) * 0.5, slot_centre.y)
		var stair_shape := BoxShape3D.new()
		stair_shape.size = Vector3(t_right - t_left, porch_top_y - porch_bot_y, total_depth)
		var stair_collider := CollisionShape3D.new()
		stair_collider.shape = stair_shape
		var stair_basis := Basis(t_dir, Vector3.UP, out_dir)
		stair_collider.transform = Transform3D(stair_basis, stair_centre)
		body.add_child(stair_collider)

	_parent_node.add_child(body)


# Generic 4-corner quad emitter. Vertices v0..v3 must be wound CCW viewed
# from the face's FRONT (`normal` direction). Triangulation 0,1,2 + 0,2,3.
func _emit_quad_corners(atom_id: String, v0: Vector3, v1: Vector3, v2: Vector3, v3: Vector3, normal: Vector3) -> void:
	if not _batches.has(atom_id):
		_batches[atom_id] = {
			"verts": PackedVector3Array(),
			"uvs": PackedVector2Array(),
			"normals": PackedVector3Array(),
			"indices": PackedInt32Array(),
			"alpha": false,
		}
	var batch: Dictionary = _batches[atom_id]
	var verts: PackedVector3Array = batch["verts"]
	var uvs: PackedVector2Array = batch["uvs"]
	var normals: PackedVector3Array = batch["normals"]
	var indices: PackedInt32Array = batch["indices"]
	var idx: int = verts.size()
	verts.append(v0); verts.append(v1); verts.append(v2); verts.append(v3)
	uvs.append(Vector2(0.0, 1.0))
	uvs.append(Vector2(0.0, 0.0))
	uvs.append(Vector2(1.0, 0.0))
	uvs.append(Vector2(1.0, 1.0))
	normals.append(normal); normals.append(normal); normals.append(normal); normals.append(normal)
	indices.append(idx); indices.append(idx + 1); indices.append(idx + 2)
	indices.append(idx); indices.append(idx + 2); indices.append(idx + 3)
	batch["verts"] = verts
	batch["uvs"] = uvs
	batch["normals"] = normals
	batch["indices"] = indices


# ── Emission helpers ───────────────────────────────────────────────────────

func _emit_quad(p1: Vector2, edge_dir: Vector2, outward_2d: Vector2, normal_3d: Vector3, t_left: float, t_right: float, y_bot: float, y_top: float, z_offset: float, atom_id: String, alpha: bool, is_ccw: bool) -> void:
	if not _batches.has(atom_id):
		_batches[atom_id] = {
			"verts": PackedVector3Array(),
			"uvs": PackedVector2Array(),
			"normals": PackedVector3Array(),
			"indices": PackedInt32Array(),
			"alpha": alpha,
		}
	var batch: Dictionary = _batches[atom_id]

	# Compute 4 corners in world space.
	var anchor_l: Vector2 = p1 + edge_dir * t_left + outward_2d * z_offset
	var anchor_r: Vector2 = p1 + edge_dir * t_right + outward_2d * z_offset
	var v_bl := Vector3(anchor_l.x, y_bot, anchor_l.y)
	var v_br := Vector3(anchor_r.x, y_bot, anchor_r.y)
	var v_tr := Vector3(anchor_r.x, y_top, anchor_r.y)
	var v_tl := Vector3(anchor_l.x, y_top, anchor_l.y)

	var verts: PackedVector3Array = batch["verts"]
	var uvs: PackedVector2Array = batch["uvs"]
	var normals: PackedVector3Array = batch["normals"]
	var indices: PackedInt32Array = batch["indices"]

	var idx: int = verts.size()
	verts.append(v_bl)
	verts.append(v_br)
	verts.append(v_tr)
	verts.append(v_tl)
	# UV: BL=(0,1), BR=(1,1), TR=(1,0), TL=(0,0) — texture right-side-up
	# on the wall as viewed from outside (texture top at wall top).
	# Same convention used by _create_3d_building_with_custom_texture in
	# osm_terrain_generator.gd.
	uvs.append(Vector2(0.0, 1.0))
	uvs.append(Vector2(1.0, 1.0))
	uvs.append(Vector2(1.0, 0.0))
	uvs.append(Vector2(0.0, 0.0))
	# Assigned vertex normal points OUTWARD (computed from polygon winding
	# in _build_side). The shader uses this for lighting; cull_disabled in
	# the material means front/back face winding doesn't matter visually.
	normals.append(normal_3d)
	normals.append(normal_3d)
	normals.append(normal_3d)
	normals.append(normal_3d)
	# Winding matches osm_terrain_generator.gd's wall builder so we stay
	# consistent with the rest of the codebase.
	indices.append(idx + 0)
	indices.append(idx + 1)
	indices.append(idx + 2)
	indices.append(idx + 0)
	indices.append(idx + 2)
	indices.append(idx + 3)
	# is_ccw is kept in the signature for future use but no longer changes
	# winding (cull_disabled makes both faces visible).
	var _unused := is_ccw

	batch["verts"] = verts
	batch["uvs"] = uvs
	batch["normals"] = normals
	batch["indices"] = indices


func _make_material(atom_id: String, _alpha: bool) -> Material:
	# Porch railings use a plain dark metal — no texture, no facade shader.
	if atom_id == "__porch_rail__":
		var rail_mat := StandardMaterial3D.new()
		rail_mat.albedo_color = RAIL_COLOR
		rail_mat.metallic = 0.5
		rail_mat.roughness = 0.5
		rail_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		return rail_mat

	# Use the facade-specific shader (mirrors building_wall_custom convention:
	# cull_disabled + diffuse_lambert_wrap + back-face NORMAL flip).
	# StandardMaterial3D's plain Lambert leaves vertical walls black under
	# top-down sun lighting; the project's wall shaders use lambert_wrap to
	# avoid that. Adjacent 111-125 buildings (37, 35) look correctly lit
	# because they go through this shader path.
	# Alpha-scissor is enabled unconditionally in the shader — for opaque
	# atoms (wall/mid-wall/long-wall/mid-balcony/entrance/decorative
	# balcony) the PNG alpha channel is 1.0 everywhere, so the scissor is
	# a no-op; for true alpha overlays (window-N) it discards the
	# transparent surround properly. See gdshader comment.
	var mat := ShaderMaterial.new()
	mat.shader = FACADE_SHADER
	mat.set_shader_parameter("albedo_texture", _load_atom(atom_id))
	mat.set_shader_parameter("roughness_base", 0.78)
	return mat


func _load_atom(atom_id: String) -> Texture2D:
	if _tex_cache.has(atom_id):
		return _tex_cache[atom_id]
	var path: String = ATOM_DIR + atom_id + ".png"
	var tex: Texture2D = null
	if ResourceLoader.exists(path):
		tex = load(path)
	_tex_cache[atom_id] = tex
	return tex


# ── Pattern utilities ──────────────────────────────────────────────────────

func _pattern_nominal_length(pattern: Array) -> float:
	var total: float = 0.0
	for role in pattern:
		total += float(SLOT_DEFS[role]["width_m"])
	return total


func _internal_boundaries_uniform(pattern: Array, scale: float, _is_ground: bool, _is_long_side: bool) -> Array:
	# Internal boundaries (between slot i and i+1) at uniform scale.
	# The ground pattern has its own slot widths that sum to the same
	# nominal length as the upper pattern (60.8 m), so no per-pair
	# scaling is needed — each "small-wall + mid-wall-entrance" pair
	# naturally takes the 6.4 m occupied by the deco-balcony slot above.
	var result: Array = []
	var t: float = 0.0
	for slot_idx in range(pattern.size()):
		var role: String = pattern[slot_idx]
		var w: float = float(SLOT_DEFS[role]["width_m"]) * scale
		var t_next: float = t + w
		if slot_idx < pattern.size() - 1:
			result.append({"t": t_next, "left": role, "right": pattern[slot_idx + 1]})
		t = t_next
	return result


# Map an upper-floor slot index to the ground-floor slots that occupy the
# same horizontal band. Returns true if any of those ground slots is a
# decorative zone (deco-balcony or entrance group), used so a horizontal
# seam at the lowest inter-floor boundary inherits the decorative variant
# when the floor below has an entrance under that segment.
func _ground_band_is_decorative(upper_slot_idx: int) -> bool:
	# Upper LONG_UPPER slots 3 and 10 are deco; the ground replaces each
	# with a 2-slot entrance pair (wall + mid-wall-entrance) starting at
	# LONG_GROUND_ENTRANCE_PAIRS indices. Other upper indices map 1:1 with
	# the same offset shift after each pair.
	var role: String = LONG_UPPER[upper_slot_idx]
	if _is_decorative_zone_role(role):
		return true
	return false


# At a given upper-pattern boundary `t`, check whether the ground floor's
# slot pair below the adjacent upper slot is a decorative zone. Used so a
# vertical seam at an upper-pattern boundary widens to the decorative
# variant when the ground floor has an entrance below it.
func _ground_band_pair_is_decorative_at(_t: float, _upper_pattern: Array, _scale: float) -> bool:
	# Boundaries between two upper slots that map to entrance pairs on the
	# ground are exactly the boundaries adjacent to upper deco-balcony
	# slots (positions 2-3, 3-4, 9-10, 10-11). _is_decorative_zone_role
	# already covers those in the calling code via the upper roles, so
	# this function is a no-op for the current recipe — left in place for
	# future cases where ground decoration doesn't share an upper boundary.
	return false


func _has_near_boundary(boundaries: Array, t_target: float, tolerance_m: float) -> bool:
	for b in boundaries:
		if absf(float(b["t"]) - t_target) <= tolerance_m:
			return true
	return false


func _is_deco_balcony_role(role: String) -> bool:
	return role == "decorative-balcony" or role == "long-wall-decorative-balcony"


# A "decorative zone" is any role that should pull the wider 60 px
# vertical seam and the long decorative horizontal seam — both the
# decorative balconies (upper floors) and the mid-wall-entrance (ground
# floor). The user's intent: the entrance reads as a decorative element
# matching the balcony stack directly above it.
func _is_decorative_zone_role(role: String) -> bool:
	return _is_deco_balcony_role(role) or role == "mid-wall-entrance"


func _pick_horiz_seam(slot_width_m: float, is_deco: bool) -> String:
	if is_deco:
		return "horiz-long-decorative-seam-1"
	if slot_width_m >= 6.0:
		return "horiz-long-seam-1"
	elif slot_width_m >= 4.0:
		return "horiz-mid-seam-1"
	else:
		return "horiz-seam-1"


# Deterministic variant pick. Different `kind` values (0=bg, 1=overlay) so
# bg and overlay don't always rotate together.
func _pick_variant(variants: Array, floor_idx: int, edge_idx: int, slot_idx: int, kind: int) -> String:
	if variants.is_empty():
		return ""
	if variants.size() == 1:
		return variants[0]
	var h: int = _seed
	h = h * 1103515245 + 12345 + floor_idx * 7919
	h = h * 1103515245 + 12345 + edge_idx * 6151
	h = h * 1103515245 + 12345 + slot_idx * 4093
	h = h * 1103515245 + 12345 + kind * 2053
	h = h & 0x7FFFFFFF
	return variants[h % variants.size()]


# Shoelace — matches the canonical `_is_polygon_ccw` in osm_terrain_generator.gd
# so the outward-normal direction computed in `_build_side` matches the
# normal_sign convention used throughout the existing wall code.
func _is_polygon_ccw(points: PackedVector2Array) -> bool:
	var signed_area: float = 0.0
	var n: int = points.size()
	for i in range(n):
		var j: int = (i + 1) % n
		signed_area += points[i].x * points[j].y
		signed_area -= points[j].x * points[i].y
	return signed_area > 0.0
