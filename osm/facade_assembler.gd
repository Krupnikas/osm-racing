extends RefCounted
class_name FacadeAssembler

## Generic procedural facade builder.
##
## Loads archetype JSON files from ARCHETYPES_DIR, selects one by
## building:material + floor count + way_id hash, then tiles molecules
## across each building edge and emits wall/overlay/seam/roofbottom quads.
##
## Fallback path: if no archetype matches or no textures exist on disk, the
## caller keeps its existing flat-texture code unchanged.

const ARCHETYPES_DIR := "res://decorations/russia/cherepovets/facades/"
# Archetype JSONs are loaded from every dir here into one shared cache. select_archetype()
# filters by `category`, so Cherepovets (panel/brick/garage) and DCH (modern) never mix.
# Add more city dirs here to register their facade packs.
const ARCHETYPE_DIRS := [
	"res://decorations/russia/cherepovets/facades/",
	"res://decorations/uae/dubai_creek_harbour/facades/",
]
const WALL_SHADER := preload("res://osm/facade_111_125.gdshader")

# Slot role → {bg atom-category, overlay atom-category, width in metres,
#              overlay_offset_top_px}.
# "overlay_offset_top_px": gap from the top of the floor to the top of the
# overlay, measured in nominal pixels (same convention as facade_111_125.gd:
# 512 px = one full floor height, 160 px = 1 metre horizontally).
# Balconies (offset 0) fill from the top edge down; windows are inset.
const SLOT_CATALOG: Dictionary = {
	"wall":            {"bg": "wall",           "overlay": "",            "width_m": 3.2, "overlay_offset_top_px": 0},
	"mid-wall":        {"bg": "mid-wall",        "overlay": "",            "width_m": 4.8, "overlay_offset_top_px": 0},
	"long-wall":       {"bg": "long-wall",       "overlay": "",            "width_m": 6.4, "overlay_offset_top_px": 0},
	"window":          {"bg": "wall",            "overlay": "window",      "width_m": 3.2, "overlay_offset_top_px": 80},
	"mid-window":      {"bg": "mid-wall",        "overlay": "mid-window",  "width_m": 4.8, "overlay_offset_top_px": 80},
	"mid-balcony":     {"bg": "mid-wall",        "overlay": "mid-balcony", "width_m": 4.8, "overlay_offset_top_px": 0},
	"long-balcony":    {"bg": "long-wall",       "overlay": "long-balcony","width_m": 6.4, "overlay_offset_top_px": 0},
	"roofbottom":      {"bg": "roofbottom",      "overlay": "",             "width_m": 3.2, "overlay_offset_top_px": 0},
	"long-roofbottom": {"bg": "long-roofbottom", "overlay": "",             "width_m": 6.4, "overlay_offset_top_px": 0},
	"long-garage":     {"bg": "long-wall",       "overlay": "long-garage",  "width_m": 6.4, "overlay_offset_top_px": 0},
	"technical-louver":{"bg": "technical-louver","overlay": "",            "width_m": 3.2, "overlay_offset_top_px": 0},
}

# Pixel-to-metre scale for overlay sizing — must match atom texture authoring.
# 160 px/m horizontal, 512 px = one nominal floor height (same as facade_111_125.gd).
const PX_PER_M     := 160.0
const NOMINAL_FLOOR_PX := 512.0

# Fraction of available wall height occupied by the roofbottom crown band.
const CROWN_FRACTION := 0.08
# Fraction of floor height used for horizontal seam thickness.
const SEAM_FRACTION := 0.06
# Fixed vertical seam width in metres (≈ 30 px at 160 px/m).
const VSEAM_W_M := 0.1875

const Z_WALL   := 0.000
const Z_OVERLAY := 0.015
const Z_HSEAM  := 0.030
const Z_VSEAM  := 0.045

# Static cache: archetype id → resolved archetype Dictionary.
static var _cache: Dictionary = {}
# Static texture cache: path → Texture2D|null.
static var _tex_cache: Dictionary = {}

# Per-build mesh accumulators: atom_path → {verts, uvs, normals, indices, alpha}.
var _batches: Dictionary = {}
var _seed: int = 0
var _slot_extrusion: Dictionary = {}  # role → {depth_m, shape}

# Materials with emission textures created during the last build() call.
# Caller should append these to its night-mode tracking array.
var emission_materials: Array[ShaderMaterial] = []

# Phase S: per-edge tiled bay pattern from the last build() — {edge_idx: Array of
# {role, t_left, t_right}}. Lets the storefront row align to the exact facade bay grid.
var edge_patterns: Dictionary = {}


# ── Archetype selection ────────────────────────────────────────────────────

## Select the best archetype for a building, or return {} if none qualifies.
## `material_tag` is the raw value of the OSM `building:material` tag.
## `floors` is the number of storeys (from building:levels or estimated).
static func select_archetype(way_id: int, material_tag: String, floors: int, group_key: String = "") -> Dictionary:
	_ensure_loaded()
	var category := _tag_to_category(material_tag)
	if category.is_empty():
		return {}
	var candidates: Array = []
	for arch_id: String in _cache:
		var arch: Dictionary = _cache[arch_id]
		if arch.get("category", "") != category:
			continue
		if floors < int(arch.get("min_floors", 1)) or floors > int(arch.get("max_floors", 99)):
			continue
		candidates.append(arch)
	if candidates.is_empty():
		return {}
	# Stable sort so pick order is deterministic regardless of file-system order.
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a["id"]) < str(b["id"]))
	# Same complex/group key -> same archetype (e.g. Creek Gate Tower 1 & 2); fall back
	# to way_id when no group key so standalone buildings stay varied.
	var h: int
	if not group_key.is_empty():
		h = hash(group_key) & 0x7FFFFFFF
	else:
		h = (way_id * 2654435761) & 0x7FFFFFFF
	return candidates[h % candidates.size()]


## Returns true if the archetype's primary ("wall") atom texture exists on disk.
## Fast probe — avoids full ResourceLoader.load overhead.
static func has_atoms(archetype: Dictionary) -> bool:
	if archetype.is_empty():
		return false
	var ra: Dictionary = archetype.get("_resolved_atoms", {})
	var wall_paths = ra.get("wall", [])
	if wall_paths is Array and not (wall_paths as Array).is_empty():
		return ResourceLoader.exists((wall_paths as Array)[0])
	return false


# ── Public build ───────────────────────────────────────────────────────────

## Build facade walls for one building polygon.
## `floor_count` — actual storeys from OSM (0 = estimate from height).
## `parent` — the building's Node3D; MeshInstance3D children are added here.
func build(
		points: PackedVector2Array,
		building_height: float,
		base_elev: float,
		parent: Node3D,
		foundation_h: float,
		way_id: int,
		archetype: Dictionary,
		floor_count: int = 0) -> void:
	if points.size() < 3 or archetype.is_empty():
		return
	_batches.clear()
	emission_materials.clear()
	edge_patterns.clear()
	_seed = way_id
	_slot_extrusion = archetype.get("slot_extrusion", {})

	var foundation_y := base_elev + foundation_h
	var roof_y       := base_elev + building_height
	var avail_h      := roof_y - foundation_y
	if avail_h <= 0.5:
		return

	if floor_count <= 0:
		floor_count = maxi(2, roundi(avail_h / 3.2))

	var has_crown  := bool(archetype.get("has_roofbottom", false))
	var crown_h    := avail_h * CROWN_FRACTION if has_crown else 0.0
	var floor_h    := (avail_h - crown_h) / float(floor_count)
	var seam_h     := floor_h * SEAM_FRACTION

	var is_ccw := _is_polygon_ccw(points)

	# Pre-compute edge lengths for long/short classification.
	# An edge is "long" if its length >= the shorter of its two adjacent edges.
	var n_pts := points.size()
	var edge_lens: PackedFloat32Array
	edge_lens.resize(n_pts)
	for i in range(n_pts):
		edge_lens[i] = points[i].distance_to(points[(i + 1) % n_pts])

	for edge_idx in range(n_pts):
		var p1: Vector2 = points[edge_idx]
		var p2: Vector2 = points[(edge_idx + 1) % n_pts]
		var edge_len := edge_lens[edge_idx]
		if edge_len < 2.0:
			continue
		var prev_len := edge_lens[(edge_idx - 1 + n_pts) % n_pts]
		var next_len := edge_lens[(edge_idx + 1) % n_pts]
		var edge_class := "long" if edge_len >= minf(prev_len, next_len) else "short"
		_build_edge(p1, p2, edge_len, foundation_y, floor_h, seam_h,
				crown_h, floor_count, is_ccw, edge_idx, archetype, edge_class)

	# Commit accumulated geometry as MeshInstance3D children.
	for atom_path: String in _batches.keys():
		var batch: Dictionary = _batches[atom_path]
		var verts: PackedVector3Array = batch["verts"]
		if verts.size() == 0:
			continue
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX]  = verts
		arrays[Mesh.ARRAY_TEX_UV]  = batch["uvs"]
		arrays[Mesh.ARRAY_NORMAL]  = batch["normals"]
		arrays[Mesh.ARRAY_COLOR]   = batch["colors"]
		arrays[Mesh.ARRAY_INDEX]   = batch["indices"]
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = _make_material(atom_path, bool(batch["alpha"]))
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		mi.name = "FacadeAssembler_" + atom_path.get_file().get_basename()
		parent.add_child(mi)


# ── Edge construction ──────────────────────────────────────────────────────

func _build_edge(p1: Vector2, p2: Vector2, edge_len: float,
		foundation_y: float, floor_h: float, seam_h: float,
		crown_h: float, floor_count: int,
		is_ccw: bool, edge_idx: int,
		archetype: Dictionary, edge_class: String = "any") -> void:
	var edge_dir := (p2 - p1).normalized()
	var outward_2d: Vector2
	if is_ccw:
		outward_2d = Vector2(edge_dir.y, -edge_dir.x)
	else:
		outward_2d = Vector2(-edge_dir.y, edge_dir.x)
	var normal_3d := Vector3(outward_2d.x, 0.0, outward_2d.y)

	# Tile molecules across this edge (same pattern for every floor).
	var pattern := _tile_wall(edge_len, edge_idx, archetype, edge_class)
	if pattern.is_empty():
		return
	edge_patterns[edge_idx] = pattern  # Phase S: expose bay grid for storefront alignment

	var has_seams: bool = bool(archetype.get("has_seams", true))

	# 1. Wall backgrounds + overlays, per floor.
	for floor_idx in range(floor_count):
		var y_bot := foundation_y + floor_idx * floor_h
		var y_top := y_bot + floor_h
		for slot: Dictionary in pattern:
			var role: String  = slot["role"]
			var t_l: float    = slot["t_left"]
			var t_r: float    = slot["t_right"]
			var info: Dictionary = SLOT_CATALOG[role].duplicate()
			var _so: Dictionary = archetype.get("slot_overrides", {})
			if _so.has(role):
				info.merge(_so[role], true)

			# Full-cell archetypes (modern Gulf towers): the role's OWN opaque atom is
			# the whole-cell background (edge-to-edge), not a small overlay on a wall.
			# Redirects window/balcony/louver roles; falls back if that atom is missing.
			if str(archetype.get("atom_mode", "overlay")) == "full_cell":
				var _ra2: Dictionary = archetype.get("_resolved_atoms", {})
				if _ra2.has(role) and not (_ra2[role] as Array).is_empty():
					info["bg"] = role
					info["overlay"] = ""

			var bg_path := _pick_atom(info["bg"], floor_idx, edge_idx, slot["slot_idx"], 0, archetype)
			if not bg_path.is_empty():
				_emit_quad(p1, edge_dir, outward_2d, normal_3d,
						t_l, t_r, y_bot, y_top, Z_WALL, bg_path, false)

			var ov_cat: String = info["overlay"]
			if not ov_cat.is_empty():
				var ov_path := _pick_atom(ov_cat, floor_idx, edge_idx, slot["slot_idx"], 1, archetype)
				if not ov_path.is_empty():
					# Size the overlay from the texture's native pixel dimensions,
					# exactly as facade_111_125.gd does: slot scale applied to width,
					# NOMINAL_FLOOR_PX applied to height, then offset from top.
					var ov_tex := _load_tex(ov_path)
					if ov_tex != null:
						var slot_scale: float = (t_r - t_l) / float(info["width_m"])
						var ov_w_m: float = (float(ov_tex.get_width())  / PX_PER_M) * slot_scale
						var ov_h_m: float = (float(ov_tex.get_height()) / NOMINAL_FLOOR_PX) * floor_h
						var ov_off: float  = (float(info["overlay_offset_top_px"]) / NOMINAL_FLOOR_PX) * floor_h
						var centre_t := (t_l + t_r) * 0.5
						var ov_y_top := y_top - ov_off
						var ov_y_bot := ov_y_top - ov_h_m
						var glow_r := _glow_chance(floor_idx, edge_idx, slot["slot_idx"]) if not _emission_path_for(ov_path).is_empty() else 1.0
						var ext_info: Dictionary = _slot_extrusion.get(role, {})
						var ext_depth: float = float(ext_info.get("depth_m", 0.0))
						var ext_shape: String = str(ext_info.get("shape", "box"))
						if ext_depth > 0.0 and not bg_path.is_empty():
							# Front face background: full slot at extrusion depth.
							_emit_quad(p1, edge_dir, outward_2d, normal_3d,
									t_l, t_r, y_bot, y_top, ext_depth, bg_path, false)
						var z_off_final: float = (ext_depth + Z_OVERLAY) if ext_depth > 0.0 else Z_OVERLAY
						_emit_quad(p1, edge_dir, outward_2d, normal_3d,
								centre_t - ov_w_m * 0.5, centre_t + ov_w_m * 0.5,
								ov_y_bot, ov_y_top, z_off_final, ov_path, true, glow_r)
						if ext_depth > 0.0 and not bg_path.is_empty():
							_dispatch_slot_extrusion(p1, edge_dir, outward_2d,
									centre_t - ov_w_m * 0.5, centre_t + ov_w_m * 0.5,
									y_bot, y_top, ext_depth, ext_shape, bg_path)

	# 2. Roofbottom crown band (if the archetype has it).
	if crown_h > 0.001:
		var y_bot := foundation_y + floor_count * floor_h
		var y_top := y_bot + crown_h
		for slot: Dictionary in pattern:
			var role: String   = slot["role"]
			var info: Dictionary = SLOT_CATALOG[role]
			var bg_width: float  = float(info["width_m"])
			var crown_role := "long-roofbottom" if bg_width >= 6.0 else "roofbottom"
			var cp := _pick_atom(crown_role, floor_count, edge_idx, slot["slot_idx"], 0, archetype)
			if not cp.is_empty():
				_emit_quad(p1, edge_dir, outward_2d, normal_3d,
						slot["t_left"], slot["t_right"], y_bot, y_top, Z_WALL, cp, false)

	if not has_seams:
		return

	# 3. Horizontal seams between floors.
	for bi in range(floor_count - 1):
		var y_c   := foundation_y + (bi + 1) * floor_h
		var y_s_b := y_c - seam_h * 0.5
		var y_s_t := y_c + seam_h * 0.5
		for slot: Dictionary in pattern:
			var role: String   = slot["role"]
			var info: Dictionary = SLOT_CATALOG[role]
			var w: float = float(info["width_m"])
			var seam_cat: String
			if w >= 6.0:
				seam_cat = "horizontal-long-seam"
			elif w >= 4.0:
				seam_cat = "horizontal-mid-seam"
			else:
				seam_cat = "horizontal-seam"
			var sp := _pick_atom(seam_cat, bi, edge_idx, slot["slot_idx"], 0, archetype)
			if not sp.is_empty():
				_emit_quad(p1, edge_dir, outward_2d, normal_3d,
						slot["t_left"], slot["t_right"], y_s_b, y_s_t, Z_HSEAM, sp, true)

	# 4. Vertical seams at slot boundaries.
	for si in range(1, pattern.size()):
		var t_seam: float = pattern[si]["t_left"]
		var vp := _pick_atom("vertical-seam", 0, edge_idx, si, 0, archetype)
		if vp.is_empty():
			continue
		var half_w := VSEAM_W_M * 0.5
		for floor_idx in range(floor_count):
			var y_bot := maxf(foundation_y + floor_idx * floor_h - seam_h, foundation_y)
			var y_top := minf(foundation_y + (floor_idx + 1) * floor_h + seam_h,
					foundation_y + floor_count * floor_h)
			_emit_quad(p1, edge_dir, outward_2d, normal_3d,
					t_seam - half_w, t_seam + half_w, y_bot, y_top, Z_VSEAM, vp, true)


# ── Molecule tiling ────────────────────────────────────────────────────────

# Returns Array[Dictionary] with keys: role, slot_idx, t_left, t_right.
# A single molecule is repeated N times and scaled uniformly to fill edge_len.
func _tile_wall(edge_len: float, edge_idx: int, archetype: Dictionary, edge_class: String = "any") -> Array:
	var molecules: Array = archetype.get("molecules", [])
	var forbidden: Array = archetype.get("forbidden", [])
	if molecules.is_empty():
		return []

	var eligible: Array = []
	for mol: Dictionary in molecules:
		var slots: Array = mol.get("slots", [])
		var ok := true
		for s: String in slots:
			if s in forbidden:
				ok = false
				break
		if not ok:
			continue
		# Tag filtering: molecule runs on this edge if it has "any" or matches edge_class.
		var tags: Array = mol.get("tags", ["any"])
		if not ("any" in tags or edge_class in tags):
			continue
		eligible.append(mol)
	if eligible.is_empty():
		return []

	# Stable sort so pick is deterministic across platforms.
	eligible.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a["id"]) < str(b["id"]))

	# Pick hash (same for the whole edge; used below).
	var h: int = (_seed * 12345 + edge_idx * 67891) & 0x7FFFFFFF

	# Filter to molecules that tile without heavy squishing on this edge.
	# Scale = edge_len / (n_reps * mol_w) must be >= 0.70 (at most 30% compression).
	const SCALE_MIN := 0.70
	var fitting: Array = []
	for m: Dictionary in eligible:
		var mw := _molecule_width(m)
		if mw <= 0.0:
			continue
		var n := maxi(1, roundi(edge_len / mw))
		var sc := edge_len / (float(n) * mw)
		if sc >= SCALE_MIN:
			fitting.append(m)
	# fitting iterates eligible in sorted order → already sorted.

	var mol: Dictionary
	if not fitting.is_empty():
		mol = fitting[h % fitting.size()]
	else:
		# No molecule fits without heavy compression.
		# Try the smallest eligible molecule (least-bad distortion).
		var best_mw := INF
		mol = eligible[0]
		for m: Dictionary in eligible:
			var mw := _molecule_width(m)
			if mw < best_mw:
				best_mw = mw
				mol = m
		# If even the smallest compresses >50%, give up and return plain walls.
		var n2 := maxi(1, roundi(edge_len / best_mw))
		var sc2 := edge_len / (float(n2) * best_mw)
		if sc2 < 0.5:
			return _plain_wall_pattern(edge_len)

	var mol_w := _molecule_width(mol)
	if mol_w <= 0.0:
		return []

	var n_reps := maxi(1, roundi(edge_len / mol_w))
	var scale  := edge_len / (float(n_reps) * mol_w)

	var pattern: Array = []
	var global_slot_idx := 0
	for _rep in range(n_reps):
		for slot_role: String in mol["slots"]:
			var info: Dictionary = SLOT_CATALOG.get(slot_role, {})
			var w := float(info.get("width_m", 3.2)) * scale
			pattern.append({"role": slot_role, "slot_idx": global_slot_idx, "width_m": w})
			global_slot_idx += 1

	# Compute cumulative t_left / t_right.
	var t := 0.0
	for s: Dictionary in pattern:
		s["t_left"]  = t
		t            += s["width_m"]
		s["t_right"] = t

	return pattern


func _molecule_width(mol: Dictionary) -> float:
	var total := 0.0
	for slot_role: String in mol.get("slots", []):
		total += float(SLOT_CATALOG.get(slot_role, {"width_m": 3.2})["width_m"])
	return total


# Fallback pattern for edges too short for any molecule: plain wall tiles, no overlays.
func _plain_wall_pattern(edge_len: float) -> Array:
	var n := maxi(1, roundi(edge_len / 3.2))
	var slot_w := edge_len / float(n)
	var pattern: Array = []
	var t := 0.0
	for i in range(n):
		pattern.append({"role": "wall", "slot_idx": i, "width_m": slot_w,
				"t_left": t, "t_right": t + slot_w})
		t += slot_w
	return pattern


# ── Atom resolution ────────────────────────────────────────────────────────

# Deterministic pseudo-random atom pick; returns "" if atom is missing on disk.
func _pick_atom(category: String, floor_idx: int, edge_idx: int, slot_idx: int, kind: int, archetype: Dictionary) -> String:
	var ra: Dictionary = archetype.get("_resolved_atoms", {})
	var paths = ra.get(category, [])
	if not (paths is Array) or (paths as Array).is_empty():
		return ""
	var arr: Array = paths as Array
	var h: int = _seed
	h = h * 1103515245 + 12345 + floor_idx * 7919
	h = h * 1103515245 + 12345 + edge_idx  * 6151
	h = h * 1103515245 + 12345 + slot_idx  * 4093
	h = h * 1103515245 + 12345 + kind      * 2053
	h = h & 0x7FFFFFFF
	var path: String = arr[h % arr.size()]
	# Presence check (cached).
	if not _tex_cache.has(path):
		_tex_cache[path] = ResourceLoader.exists(path)
	return path if _tex_cache[path] else ""


# ── Quad emission ──────────────────────────────────────────────────────────

func _emit_quad(p1: Vector2, edge_dir: Vector2, outward_2d: Vector2,
		normal_3d: Vector3, t_left: float, t_right: float,
		y_bot: float, y_top: float, z_offset: float,
		atom_path: String, alpha: bool, glow_r: float = 1.0) -> void:
	if not _batches.has(atom_path):
		_batches[atom_path] = {
			"verts":   PackedVector3Array(),
			"uvs":     PackedVector2Array(),
			"normals": PackedVector3Array(),
			"colors":  PackedColorArray(),
			"indices": PackedInt32Array(),
			"alpha":   alpha,
		}
	var batch: Dictionary = _batches[atom_path]
	var anchor_l := p1 + edge_dir * t_left  + outward_2d * z_offset
	var anchor_r := p1 + edge_dir * t_right + outward_2d * z_offset
	var verts: PackedVector3Array   = batch["verts"]
	var uvs: PackedVector2Array     = batch["uvs"]
	var normals: PackedVector3Array = batch["normals"]
	var colors: PackedColorArray    = batch["colors"]
	var indices: PackedInt32Array   = batch["indices"]
	var idx := verts.size()
	verts.append(Vector3(anchor_l.x, y_bot, anchor_l.y))
	verts.append(Vector3(anchor_r.x, y_bot, anchor_r.y))
	verts.append(Vector3(anchor_r.x, y_top, anchor_r.y))
	verts.append(Vector3(anchor_l.x, y_top, anchor_l.y))
	uvs.append(Vector2(0.0, 1.0)); uvs.append(Vector2(1.0, 1.0))
	uvs.append(Vector2(1.0, 0.0)); uvs.append(Vector2(0.0, 0.0))
	normals.append(normal_3d); normals.append(normal_3d)
	normals.append(normal_3d); normals.append(normal_3d)
	var c := Color(glow_r, 1.0, 1.0, 1.0)
	colors.append(c); colors.append(c); colors.append(c); colors.append(c)
	indices.append(idx);     indices.append(idx + 1); indices.append(idx + 2)
	indices.append(idx);     indices.append(idx + 2); indices.append(idx + 3)
	batch["verts"]   = verts
	batch["uvs"]     = uvs
	batch["normals"] = normals
	batch["colors"]  = colors
	batch["indices"] = indices


# ── Balcony box extrusion ──────────────────────────────────────────────────

# General quad emitter with explicit 3D vertices. Same batch structure as
# _emit_quad. Used for non-vertical faces (top slab, side walls of balcony box).
func _emit_quad_raw(v0: Vector3, v1: Vector3, v2: Vector3, v3: Vector3,
		normal_3d: Vector3, atom_path: String,
		alpha: bool = false, glow_r: float = 1.0) -> void:
	if not _batches.has(atom_path):
		_batches[atom_path] = {
			"verts":   PackedVector3Array(),
			"uvs":     PackedVector2Array(),
			"normals": PackedVector3Array(),
			"colors":  PackedColorArray(),
			"indices": PackedInt32Array(),
			"alpha":   alpha,
		}
	var batch: Dictionary = _batches[atom_path]
	var verts: PackedVector3Array   = batch["verts"]
	var uvs: PackedVector2Array     = batch["uvs"]
	var normals: PackedVector3Array = batch["normals"]
	var colors: PackedColorArray    = batch["colors"]
	var indices: PackedInt32Array   = batch["indices"]
	var idx := verts.size()
	verts.append(v0); verts.append(v1); verts.append(v2); verts.append(v3)
	uvs.append(Vector2(0.0, 1.0)); uvs.append(Vector2(1.0, 1.0))
	uvs.append(Vector2(1.0, 0.0)); uvs.append(Vector2(0.0, 0.0))
	normals.append(normal_3d); normals.append(normal_3d)
	normals.append(normal_3d); normals.append(normal_3d)
	var c := Color(glow_r, 1.0, 1.0, 1.0)
	colors.append(c); colors.append(c); colors.append(c); colors.append(c)
	indices.append(idx);     indices.append(idx + 1); indices.append(idx + 2)
	indices.append(idx);     indices.append(idx + 2); indices.append(idx + 3)
	batch["verts"]   = verts
	batch["uvs"]     = uvs
	batch["normals"] = normals
	batch["colors"]  = colors
	batch["indices"] = indices


# Emit top, left, and right faces of a rectangular balcony box.
# t_l/t_r define the box width along the edge; y_bot/y_top its vertical range;
# depth is the protrusion distance along outward_2d. bg_path = wall atom texture.
func _emit_balcony_box_sides(p1: Vector2, edge_dir: Vector2, outward_2d: Vector2,
		t_l: float, t_r: float, y_bot: float, y_top: float,
		depth: float, bg_path: String) -> void:
	var wall_l := p1 + edge_dir * t_l
	var wall_r := p1 + edge_dir * t_r
	var ext_l  := wall_l + outward_2d * depth
	var ext_r  := wall_r + outward_2d * depth
	var wl_bot := Vector3(wall_l.x, y_bot, wall_l.y)
	var wl_top := Vector3(wall_l.x, y_top, wall_l.y)
	var wr_bot := Vector3(wall_r.x, y_bot, wall_r.y)
	var wr_top := Vector3(wall_r.x, y_top, wall_r.y)
	var el_bot := Vector3(ext_l.x,  y_bot, ext_l.y)
	var el_top := Vector3(ext_l.x,  y_top, ext_l.y)
	var er_bot := Vector3(ext_r.x,  y_bot, ext_r.y)
	var er_top := Vector3(ext_r.x,  y_top, ext_r.y)
	var left  := Vector3(-edge_dir.x, 0.0, -edge_dir.y)
	var right := Vector3(edge_dir.x,  0.0,  edge_dir.y)
	# TOP slab
	_emit_quad_raw(wl_top, wr_top, er_top, el_top, Vector3.UP, bg_path)
	# BOTTOM slab (floor of balcony)
	_emit_quad_raw(el_bot, er_bot, wr_bot, wl_bot, Vector3.DOWN, bg_path)
	# LEFT side
	_emit_quad_raw(wl_bot, el_bot, el_top, wl_top, left, bg_path)
	# RIGHT side
	_emit_quad_raw(er_bot, wr_bot, wr_top, er_top, right, bg_path)


# Dispatch extrusion by shape. Extension point for future shapes (erker, etc.).
func _dispatch_slot_extrusion(p1: Vector2, edge_dir: Vector2, outward_2d: Vector2,
		t_l: float, t_r: float, y_bot: float, y_top: float,
		depth: float, shape: String, bg_path: String) -> void:
	match shape:
		"box":
			_emit_balcony_box_sides(p1, edge_dir, outward_2d,
					t_l, t_r, y_bot, y_top, depth, bg_path)


# Returns 1.0 (glow) with ~30% probability, deterministically per window instance.
func _glow_chance(floor_idx: int, edge_idx: int, slot_idx: int) -> float:
	var h: int = _seed
	h = h * 1103515245 + 12345 + floor_idx * 7919
	h = h * 1103515245 + 12345 + edge_idx  * 6151
	h = h * 1103515245 + 12345 + slot_idx  * 4093
	h = h & 0x7FFFFFFF
	return 1.0 if (h % 100) < 30 else 0.0


# ── Material ───────────────────────────────────────────────────────────────

func _make_material(atom_path: String, _alpha: bool) -> Material:
	var mat := ShaderMaterial.new()
	mat.shader = WALL_SHADER
	mat.set_shader_parameter("albedo_texture", _load_tex(atom_path))
	mat.set_shader_parameter("roughness_base", 0.78)
	var emit_path := _emission_path_for(atom_path)
	if not emit_path.is_empty():
		mat.set_shader_parameter("emission_texture", _load_tex(emit_path))
		mat.set_shader_parameter("night_factor", 0.0)
		emission_materials.append(mat)
	return mat


# Returns the emission mask path for an atom, or "" if none exists.
# Convention: "window-1.png" → "window-emission-1.png" in the same dir.
func _emission_path_for(atom_path: String) -> String:
	var dir  := atom_path.get_base_dir() + "/"
	var file := atom_path.get_file()          # e.g. "window-1.png"
	var base := file.get_basename()           # e.g. "window-1"
	# Strip trailing -N digit(s) from base name, insert "-emission-N"
	var dash := base.rfind("-")
	if dash < 0:
		return ""
	var prefix := base.substr(0, dash)        # e.g. "window"
	var suffix := base.substr(dash + 1)       # e.g. "1"
	var emit_path := dir + prefix + "-emission-" + suffix + ".png"
	if not _tex_cache.has(emit_path):
		_tex_cache[emit_path] = ResourceLoader.exists(emit_path)
	if _tex_cache[emit_path]:
		return emit_path
	return ""


func _load_tex(path: String) -> Texture2D:
	if _tex_cache.has(path) and _tex_cache[path] is Texture2D:
		return _tex_cache[path]
	var tex: Texture2D = null
	if ResourceLoader.exists(path):
		tex = load(path)
	_tex_cache[path] = tex
	return tex


# ── Archetype loading ──────────────────────────────────────────────────────

static func _ensure_loaded() -> void:
	if not _cache.is_empty():
		return
	for adir: String in ARCHETYPE_DIRS:
		var dir := DirAccess.open(adir)
		if dir == null:
			continue
		dir.list_dir_begin()
		var fname := dir.get_next()
		while fname != "":
			if fname.ends_with(".json"):
				var f := FileAccess.open(adir + fname, FileAccess.READ)
				if f:
					var json := JSON.new()
					if json.parse(f.get_as_text()) == OK:
						var raw: Dictionary = json.get_data()
						var resolved := _resolve_atoms(raw)
						_cache[str(raw.get("id", fname))] = resolved
					f.close()
			fname = dir.get_next()
		dir.list_dir_end()


# Pre-resolve all atom file references into absolute paths so runtime code
# never has to think about atom_dir or the {dir, files} override form.
static func _resolve_atoms(raw: Dictionary) -> Dictionary:
	var out := raw.duplicate(true)
	var atom_dir: String = raw.get("atom_dir", "")
	var raw_atoms: Dictionary = raw.get("atoms", {})
	var resolved: Dictionary = {}
	for cat: String in raw_atoms:
		var val = raw_atoms[cat]
		if val is Array:
			var paths: Array = []
			for fname in val:
				paths.append(atom_dir + str(fname) + ".png")
			resolved[cat] = paths
		elif val is Dictionary:
			var other_dir: String = str(val.get("dir", atom_dir))
			var paths: Array = []
			for fname in val.get("files", []):
				paths.append(other_dir + str(fname) + ".png")
			resolved[cat] = paths
	out["_resolved_atoms"] = resolved
	return out


# Derive a stable "complex" key from a building name by stripping a trailing
# tower/building/phase number or cardinal, so all towers of one development
# (e.g. "Creek Gate Tower 1/2", "The Cove Building 1/2") share one archetype.
static func complex_key(raw: String) -> String:
	var s := raw.strip_edges().to_lower()
	if s.is_empty():
		return ""
	var re := RegEx.new()
	re.compile("\\s*(?:tower|building|block|bldg|phase)?\\s*(?:north|south|east|west|[0-9]+|[ivx]{1,4}|[a-d])\\s*$")
	var m := re.search(s)
	if m != null and m.get_start() > 0:
		s = s.substr(0, m.get_start()).strip_edges()
	return s


static func _tag_to_category(tag: String) -> String:
	if tag == "panel" or tag == "large_panel":
		return "panel"
	if tag == "brick":
		return "brick"
	if tag == "garage":
		return "garage"
	if tag == "modern":
		return "modern"
	return ""


# ── Geometry helpers ───────────────────────────────────────────────────────

static func _is_polygon_ccw(points: PackedVector2Array) -> bool:
	var signed_area := 0.0
	var n := points.size()
	for i in range(n):
		var j := (i + 1) % n
		signed_area += points[i].x * points[j].y - points[j].x * points[i].y
	return signed_area > 0.0
