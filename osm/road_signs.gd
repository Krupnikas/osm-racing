extends RefCounted
## Generic road-sign BUILD library (Wave 0 foundation).
##
## SCOPE / OWNERSHIP (see docs/ROAD_SIGNS_IMPLEMENTATION_PLAN.md §2, §7):
## This module owns ONLY stateless build assets — the sign-definition table, the
## country/style texture registry, material caching, and the pole+plate mesh builder.
## It does NOT own road lookup, curb projection, furniture clearance, elevation
## sampling, chunk parenting, or debug markers — those stay in osm_terrain_generator.gd.
## Everything here is unit-callable with plain data: give it a type + world transform
## (+ parent) and it returns a node. It never needs to *find* where a sign goes.
##
## v1 PLATE POLICY: one QuadMesh whose PNG (alpha-scissor) carries the visible
## silhouette — no per-shape geometry. The `shape` field is recorded for a future
## `_sign_plate_mesh` but is not required to render correctly in v1.

# ------------------------------------------------------------------ definitions
# One entry per sign TYPE. New types are added here (data) + a registry mapping +
# a generator-side placement function — no new mesh code.
const SIGN_DEFS := {
	"bus_stop": {
		"type": "bus_stop",
		"shape": "rect",              # v1: rendered as quad+alpha regardless
		"plate_size": Vector2(0.5, 0.77),  # ~PNG aspect (256x393 portrait)
		"pole_height": 2.6,
		"double_sided": true,
		"destructible": true,
		"collision_layer": 4,
		"collision_mask": 7,
		"mass": 15.0,
		"visibility_range": 130.0,
	},
}

# ------------------------------------------------------------- style registry
# Country/style profiles → type → texture path (or {variant: path} for variant types).
# The DEFAULT profile maps the provided artwork. Registering a path here does NOT
# spawn anything (a type only spawns when a generator placement function drives it),
# so future-wave faces are pre-registered safely.
const STYLE_TABLE := {
	"default": {
		"bus_stop":   "res://textures/signs/bus_stop.png",
		"roundabout": "res://textures/signs/roundabout.png",
		"main_road":  "res://textures/signs/main_road.png",
		"speed_limit": {
			"20": "res://textures/signs/speed_limit_20.png",
			"40": "res://textures/signs/speed_limit_40.png",
			"60": "res://textures/signs/speed_limit_60.png",
			"90": "res://textures/signs/speed_limit_90.png",
		},
	},
	# Smoke-test profile: overrides exactly one face to prove the resolution order
	# swaps it without touching placement code (plan §14, country-override test).
	"test_override": {
		"bus_stop": "res://textures/signs/parking.png",
	},
}

var _front_mat_cache: Dictionary = {}   # "profile|type|variant" → StandardMaterial3D
var _back_mat: StandardMaterial3D = null
var _pole_mat: StandardMaterial3D = null

# ------------------------------------------------------------- texture registry
## Resolve a face texture through the style registry. Returns null when no mapping
## exists or the file is missing (caller logs the reason + skips — never crashes).
## Resolution order: <profile>.<type>.<variant> → <profile>.<type>
##                 → default.<type>.<variant>  → default.<type>
func resolve_face(type: String, variant: String = "", profile: String = "default") -> Texture2D:
	var path := _resolve_path(profile, type, variant)
	if path == "" or not ResourceLoader.exists(path):
		return null
	return load(path)

func _resolve_path(profile: String, type: String, variant: String) -> String:
	var order: Array = []
	if profile != "default":
		order.append([profile, type, variant])
		order.append([profile, type, ""])
	order.append(["default", type, variant])
	order.append(["default", type, ""])
	for o in order:
		var p := _lookup(o[0], o[1], o[2])
		if p != "":
			return p
	return ""

func _lookup(profile: String, type: String, variant: String) -> String:
	if not STYLE_TABLE.has(profile):
		return ""
	var pt: Dictionary = STYLE_TABLE[profile]
	if not pt.has(type):
		return ""
	var entry = pt[type]
	if entry is String:
		return entry if variant == "" else ""
	elif entry is Dictionary:
		if variant != "" and entry.has(variant):
			return str(entry[variant])
	return ""

# ----------------------------------------------------------------- the builder
## Build one pole+plate sign at an already-resolved world transform.
## `world_pos`/`yaw` are computed by the GENERATOR from road context (right-curb
## invariant); this function performs no road lookup. Returns the root Node3D, or
## null if the type/texture is unavailable (caller logs the reason).
## opts: { profile, visibility_range, hit_handler:Callable }
func build(type: String, variant: String, world_pos: Vector3, yaw: float, parent: Node3D, opts: Dictionary = {}) -> Node3D:
	if not SIGN_DEFS.has(type):
		return null
	if parent == null or not is_instance_valid(parent):
		return null
	var def: Dictionary = SIGN_DEFS[type]
	var profile := str(opts.get("profile", "default"))
	var tex := resolve_face(type, variant, profile)
	if tex == null:
		return null
	var destructible := bool(def.get("destructible", true))

	# Root body: frozen-kinematic RigidBody (knock-over via _on_sign_hit) or static.
	var root: Node3D
	if destructible:
		var rb := RigidBody3D.new()
		rb.freeze = true
		rb.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		rb.collision_layer = int(def.get("collision_layer", 4))
		rb.collision_mask = int(def.get("collision_mask", 7))
		rb.mass = float(def.get("mass", 15.0))
		rb.contact_monitor = true
		rb.max_contacts_reported = 4
		root = rb
	else:
		var sb := StaticBody3D.new()
		sb.collision_layer = int(def.get("collision_layer", 4))
		sb.collision_mask = 0
		root = sb
	root.name = "RoadSign_%s" % type
	root.position = world_pos
	root.rotation.y = yaw
	root.add_to_group("road_sign")
	root.set_meta("sign_type", type)
	if variant != "":
		root.set_meta("sign_variant", variant)

	var pole_h := float(def.get("pole_height", 2.5))
	var vis := float(opts.get("visibility_range", def.get("visibility_range", 130.0)))

	# Pole collider (pole-focused; the plate has no bespoke collider in v1).
	var cs := CollisionShape3D.new()
	var col_shape := CylinderShape3D.new()
	col_shape.radius = 0.06
	col_shape.height = pole_h
	cs.shape = col_shape
	cs.position.y = pole_h * 0.5
	root.add_child(cs)

	# Pole mesh.
	var pole := MeshInstance3D.new()
	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = 0.03
	pole_mesh.bottom_radius = 0.04
	pole_mesh.height = pole_h
	pole.mesh = pole_mesh
	pole.material_override = _pole_material()
	pole.position.y = pole_h * 0.5
	pole.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pole.visibility_range_end = vis
	pole.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	root.add_child(pole)

	# Plate — front faces local +Z (matches crossing/TL convention: yaw aims +Z at
	# the oncoming driver). PNG alpha-scissor gives the visible silhouette.
	var size: Vector2 = def.get("plate_size", Vector2(0.6, 0.6))
	var plate_y := pole_h - size.y * 0.5 - 0.05
	var cache_key := "%s|%s|%s" % [profile, type, variant]

	# Plate construction mirrors the shipped crossing sign so the pole reads as the
	# sign's MOUNT, not a defect: the FRONT quad sits clearly ahead of the pole
	# surface (~0.032 at plate height) so the pole never z-fights/pokes through the
	# face; the BACK quad sits INSIDE the pole radius so there is no side gap between
	# plate and pole (the pole anchors the plate).
	var front := MeshInstance3D.new()
	var front_mesh := QuadMesh.new()
	front_mesh.size = size
	front.mesh = front_mesh
	front.material_override = _front_material(cache_key, tex)
	front.position = Vector3(0, plate_y, 0.05)
	front.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	front.visibility_range_end = vis
	front.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	root.add_child(front)

	if bool(def.get("double_sided", true)):
		var back := MeshInstance3D.new()
		var back_mesh := QuadMesh.new()
		back_mesh.size = size
		back.mesh = back_mesh
		back.material_override = _back_material()
		back.position = Vector3(0, plate_y, 0.025)
		back.rotation.y = PI
		back.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		back.visibility_range_end = vis
		back.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		root.add_child(back)

	# Destructibility wiring stays generator-owned: the caller passes _on_sign_hit.
	if destructible and opts.has("hit_handler"):
		var h: Callable = opts["hit_handler"]
		if h.is_valid():
			(root as RigidBody3D).body_entered.connect(h.bind(root))

	parent.add_child(root)
	return root

# ----------------------------------------------------------------- materials
# Front material per (profile|type|variant): LIT alpha-scissor (no emission → no
# night glow; QuadMesh has UVs so lighting is correct). Cached to avoid per-sign mats.
func _front_material(cache_key: String, tex: Texture2D) -> StandardMaterial3D:
	if _front_mat_cache.has(cache_key):
		return _front_mat_cache[cache_key]
	var m := StandardMaterial3D.new()
	m.albedo_texture = tex
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	m.alpha_scissor_threshold = 0.5
	m.metallic = 0.3
	m.roughness = 0.5
	m.cull_mode = BaseMaterial3D.CULL_BACK
	_front_mat_cache[cache_key] = m
	return m

func _back_material() -> StandardMaterial3D:
	if _back_mat == null:
		_back_mat = StandardMaterial3D.new()
		_back_mat.albedo_color = Color(0.45, 0.45, 0.42)  # matches _crossing_sign_back_mat
		_back_mat.metallic = 0.6
		_back_mat.roughness = 0.7
	return _back_mat

func _pole_material() -> StandardMaterial3D:
	if _pole_mat == null:
		_pole_mat = StandardMaterial3D.new()
		_pole_mat.albedo_color = Color(0.5, 0.5, 0.5)
		_pole_mat.metallic = 0.8
	return _pole_mat
