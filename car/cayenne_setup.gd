extends Node3D

## Player (GEVP) setup for the Porsche Cayenne Turbo S 2009 (AWD SUV).
##
## Pipeline-generated (see docs/CAR_INTEGRATION_PIPELINE.md). Tier C: opaque material
## names (Spanish). Wheels use materials "llanta" (tyre) + "rin"/"CAYENNE_rin" (rim) +
## "disk" — passed to CarWheelRig as EXTRA mat keys; the hardened lateral filter keeps
## only the 4 corners. Body paint = "CAYENNE". Lamp lenses share one material
## ("CAYENNE_luz", front+rear) so lighting is via placed white headlight SpotLights +
## red taillight OmniLights (Evo-style). Native forward = +Z → GEVP scene rotates 180°.

const CarWheelRig := preload("res://tools/car_wheel_rig.gd")
const WHEEL_MATS := ["llanta", "rin"]  # extra mat keys (Spanish tyre/rim)
const PAINT_MAT := "cayenne"

const BODY_COLORS := {
	"meteor_gray": Color(0.294, 0.306, 0.314),
	"basalt_black": Color(0.067, 0.067, 0.067),
	"crystal_silver": Color(0.784, 0.788, 0.780),
	"sand_white": Color(0.910, 0.882, 0.824),
	"gts_red": Color(0.690, 0.098, 0.133),
	"marine_blue": Color(0.082, 0.173, 0.306),
	"olive_green": Color(0.247, 0.290, 0.196),
	"nordic_gold": Color(0.706, 0.627, 0.420),
}
var body_color := BODY_COLORS["meteor_gray"]

var _vehicle: Node
var _night_manager: Node
var _is_night := false
var _brake_lights: Array[OmniLight3D] = []
var _headlights: Array[SpotLight3D] = []
var _head_mats: Array[StandardMaterial3D] = []      # front lens materials (glow at night)
var _tail_glow_mats: Array[StandardMaterial3D] = [] # rear lens materials (glow + brake)

const FRONT_LAMP_MATS := ["cayenne_luz"]    # headlight lens → warm white
const REAR_LAMP_MATS := ["cayenne_luz2"]    # taillight lens → red


# Real-vertex centroid z of a mesh in model-local space (native front = +Z).
func _centroid_z(mi: MeshInstance3D) -> float:
	if mi.mesh == null or mi.mesh.get_surface_count() == 0:
		return 0.0
	var arr = mi.mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	if verts.size() == 0:
		return 0.0
	var t := _xform_to_self(mi)
	var s := 0.0
	for v in verts:
		s += (t * v).z
	return s / verts.size()


func _xform_to_self(node: Node) -> Transform3D:
	var t := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != self:
		if n is Node3D:
			t = (n as Node3D).transform * t
		n = n.get_parent()
	return t


# Make the REAL lamp lens meshes emissive (matches lens shape, sits in the body).
# Split front (native +Z → warm white) vs rear (−Z → red) by each mesh's centroid.
func _emissive_lamps() -> void:
	for mesh in _find_all_meshes(self):
		if not (mesh is MeshInstance3D) or mesh.mesh == null:
			continue
		for i in range(mesh.mesh.get_surface_count()):
			var src: Material = mesh.mesh.surface_get_material(i)
			var mn := (src.resource_name.to_lower() if src else "")
			var is_front: bool = mn in FRONT_LAMP_MATS
			var is_rear: bool = mn in REAR_LAMP_MATS
			if not (is_front or is_rear):
				continue
			var mat: Material = mesh.get_surface_override_material(i)
			if not mat:
				mat = src.duplicate()
				mesh.set_surface_override_material(i, mat)
			if not (mat is StandardMaterial3D):
				continue
			mat.emission_enabled = true
			if is_front:   # headlight lens — glows at night
				mat.emission = Color(1.0, 0.96, 0.85)
				mat.emission_energy_multiplier = 0.0
				_head_mats.append(mat)
			else:          # taillight lens — always on, brighter on brake
				mat.emission = Color(1.0, 0.05, 0.05)
				mat.emission_energy_multiplier = 0.7
				_tail_glow_mats.append(mat)


func _ready() -> void:
	_vehicle = get_parent()
	await get_tree().process_frame
	_rig_wheels()
	_change_body_color()
	_setup_lights()
	_emissive_lamps()
	print("Porsche Cayenne setup complete")


func _process(_delta: float) -> void:
	if not is_instance_valid(_night_manager):
		var scene := get_tree().current_scene
		if scene:
			_night_manager = scene.find_child("NightModeManager", true, false)
	if _night_manager and _night_manager.get("is_night") != null:
		var n: bool = _night_manager.get("is_night")
		if n != _is_night:
			_is_night = n
			for l in _headlights:
				if is_instance_valid(l):
					l.visible = _is_night
			for l in _brake_lights:
				if is_instance_valid(l):
					l.visible = _is_night
			for m in _head_mats:
				if is_instance_valid(m):
					m.emission_energy_multiplier = 1.3 if _is_night else 0.0
	_update_taillight_brightness()


func _rig_wheels() -> void:
	var rig: Dictionary = CarWheelRig.build(self, CarWheelRig.DEFAULT_NAME_KEYS, CarWheelRig.DEFAULT_MAT_KEYS, WHEEL_MATS)
	if not rig.get("ok", false):
		push_warning("Cayenne: wheel rig failed: " + str(rig.get("note", "")))
		return
	if not _vehicle or not _vehicle.get("front_left_wheel"):
		return
	var nodes := [
		_vehicle.front_left_wheel.wheel_node,
		_vehicle.front_right_wheel.wheel_node,
		_vehicle.rear_left_wheel.wheel_node,
		_vehicle.rear_right_wheel.wheel_node,
	]
	var containers: Dictionary = rig["containers"]
	for q in containers.keys():
		var cont: Node3D = containers[q]
		var wp: Vector3 = cont.global_position
		var best: Node3D = null
		var best_d := 1e20
		for wn in nodes:
			var d: float = wp.distance_squared_to(wn.global_position)
			if d < best_d:
				best_d = d; best = wn
		if best:
			cont.reparent(best, true)
			cont.position = Vector3.ZERO
			cont.visible = true
			_set_visible_recursive(cont)


func _set_visible_recursive(n: Node) -> void:
	if n is GeometryInstance3D:
		n.visible = true
	for c in n.get_children():
		_set_visible_recursive(c)


func _find_all_meshes(node: Node) -> Array:
	var out: Array = []
	if node is MeshInstance3D:
		out.append(node)
	for c in node.get_children():
		out.append_array(_find_all_meshes(c))
	return out


func _change_body_color() -> void:
	for mesh in _find_all_meshes(self):
		if not (mesh is MeshInstance3D) or mesh.mesh == null:
			continue
		for i in range(mesh.mesh.get_surface_count()):
			var mat: Material = mesh.get_surface_override_material(i)
			if not mat:
				var orig: Material = mesh.mesh.surface_get_material(i)
				if orig:
					mat = orig.duplicate()
					mesh.set_surface_override_material(i, mat)
			if mat is StandardMaterial3D and mat.resource_name.to_lower() == PAINT_MAT:
				mat.albedo_color = body_color
				mat.metallic = 0.4
				mat.metallic_specular = 0.85
				mat.roughness = 0.25


func _setup_lights() -> void:
	# rear red OmniLights (vehicle +Z), baseline at night + brighten on brake
	for x in [-0.65, 0.65]:
		var l := OmniLight3D.new()
		l.name = "BrakeLight"
		l.position = Vector3(x, 0.92, 2.20)
		l.omni_range = 1.8
		l.light_energy = 0.4
		l.light_color = Color(1.0, 0.05, 0.05)
		l.shadow_enabled = false
		l.visible = _is_night
		get_parent().add_child(l)
		_brake_lights.append(l)
	# front white headlight SpotLights (vehicle -Z), night
	for x in [-0.70, 0.70]:
		var l := SpotLight3D.new()
		l.name = "Headlight"
		l.position = Vector3(x, 0.92, -2.20)
		l.rotation_degrees = Vector3(-4, 0, 0)
		l.spot_range = 34.0
		l.spot_angle = 45.0
		l.light_energy = 3.0
		l.light_color = Color(1.0, 0.95, 0.82)
		l.shadow_enabled = false
		l.visible = _is_night
		get_parent().add_child(l)
		_headlights.append(l)


func _update_taillight_brightness() -> void:
	var braking := false
	if _vehicle and "brake_input" in _vehicle:
		braking = _vehicle.brake_input > 0.1
	for l in _brake_lights:
		if is_instance_valid(l):
			l.light_energy = 3.0 if braking else 0.4
	for m in _tail_glow_mats:
		if is_instance_valid(m):
			m.emission_energy_multiplier = 2.2 if braking else 0.7
