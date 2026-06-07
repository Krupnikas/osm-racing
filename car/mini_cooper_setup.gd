extends Node3D

## Player (GEVP) setup for the Mini Cooper S F56 2014 (FWD hot hatch).
## Sketchfab GLB (clean textured materials — no FBX polish needed). Native forward = +Z
## (glass_light front at +Z, red_glass rear at -Z) → GEVP rotates the model 180°. Wheels via
## CarWheelRig (default keys match the "...Wheel..." material). Real lamp lenses: front
## "glass_light" (warm white), rear "red_glass" (red). Body paint = "*Paint*"/"*Coloured*".

const CarWheelRig := preload("res://tools/car_wheel_rig.gd")
const LampEmissive := preload("res://tools/lamp_emissive.gd")
const FRONT_LAMP_KEYS := ["glass_light"]
const REAR_LAMP_KEYS := ["red_glass"]

const BODY_COLORS := {
	"chili_red": Color(0.710, 0.086, 0.125),
	"midnight_black": Color(0.035, 0.039, 0.051),
	"pepper_white": Color(0.941, 0.910, 0.847),
	"thunder_grey": Color(0.333, 0.341, 0.353),
	"electric_blue": Color(0.082, 0.396, 0.663),
	"british_racing_green": Color(0.071, 0.196, 0.149),
	"volcanic_orange": Color(0.851, 0.541, 0.122),
	"moonwalk_grey": Color(0.486, 0.490, 0.478),
}
var body_color := BODY_COLORS["chili_red"]

var _vehicle: Node
var _night_manager: Node
var _is_night := false
var _brake_lights: Array[OmniLight3D] = []
var _headlights: Array[SpotLight3D] = []
var _head_mats: Array = []
var _tail_glow_mats: Array = []


func _ready() -> void:
	_vehicle = get_parent()
	await get_tree().process_frame
	_rig_wheels()
	_change_body_color()
	_setup_lights()
	var r: Dictionary = LampEmissive.apply_by_name(self, FRONT_LAMP_KEYS, REAR_LAMP_KEYS, 0.0, 0.7, false, false)
	_head_mats = r["head"]
	_tail_glow_mats = r["tail"]
	print("Mini Cooper S setup complete")


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
				if is_instance_valid(l): l.visible = _is_night
			for l in _brake_lights:
				if is_instance_valid(l): l.visible = _is_night
			for m in _head_mats:
				if is_instance_valid(m): m.emission_energy_multiplier = 1.3 if _is_night else 0.0
	_update_taillight_brightness()


func _rig_wheels() -> void:
	var rig: Dictionary = CarWheelRig.build(self)
	if not rig.get("ok", false):
		push_warning("Mini: wheel rig failed: " + str(rig.get("note", "")))
		return
	if not _vehicle or not _vehicle.get("front_left_wheel"):
		return
	var nodes := [
		_vehicle.front_left_wheel.wheel_node, _vehicle.front_right_wheel.wheel_node,
		_vehicle.rear_left_wheel.wheel_node, _vehicle.rear_right_wheel.wheel_node,
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
			cont.reparent(best, true); cont.position = Vector3.ZERO; cont.visible = true
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
			if mat is StandardMaterial3D:
				var mn := mat.resource_name.to_lower()
				if "paint" in mn or "coloured" in mn or "carp" in mn:
					mat.albedo_color = body_color
					mat.metallic = 0.6
					mat.metallic_specular = 0.85
					mat.roughness = 0.25


func _setup_lights() -> void:
	# NOTE: no rear brake OmniLights — the emissive "red_glass" corner lenses ARE the taillights
	# (they brake-brighten in _update_taillight_brightness); placed omnis read as central points.
	# front white headlight SpotLights (vehicle -Z = front), night
	for x in [-0.62, 0.62]:
		var l := SpotLight3D.new()
		l.name = "Headlight"; l.position = Vector3(x, 0.7, -1.85)
		l.rotation_degrees = Vector3(-4, 0, 0)
		l.spot_range = 30.0; l.spot_angle = 45.0; l.light_energy = 3.0
		l.light_color = Color(1.0, 0.95, 0.82); l.shadow_enabled = false; l.visible = _is_night
		get_parent().add_child(l); _headlights.append(l)


func _update_taillight_brightness() -> void:
	var braking := false
	if _vehicle and "brake_input" in _vehicle:
		braking = _vehicle.brake_input > 0.1
	for l in _brake_lights:
		if is_instance_valid(l): l.light_energy = 3.0 if braking else 0.4
	for m in _tail_glow_mats:
		if is_instance_valid(m): m.emission_energy_multiplier = 2.2 if braking else 0.7
