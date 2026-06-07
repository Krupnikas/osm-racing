extends Node3D

## Player (GEVP) setup for the Chevrolet Aveo 5 LT 2009 (FWD economy hatch).
##
## Pipeline-generated (see docs/CAR_INTEGRATION_PIPELINE.md). Tier C: SketchUp export with
## garbage material tokens. Wheels are found by passing the tyre/rim tokens
## ("chevy_aveo_54uher"/"45uher") as CarWheelRig extra mat keys; the hardened lateral
## filter trims body strays. Body paint = main panel material "chevy_aveo_65i5wejnytjhmf".
## Lamp materials aren't identifiable → lighting via placed white-front/red-rear lamps.
## Native forward = +Z → GEVP scene rotates 180°.

const CarWheelRig := preload("res://tools/car_wheel_rig.gd")
const WHEEL_MATS := ["chevy_aveo_54uher", "chevy_aveo_45uher"]
const PAINT_MAT := "chevy_aveo_65i5wejnytjhmf"

const BODY_COLORS := {
	"silver_birch": Color(0.761, 0.757, 0.737),
	"black": Color(0.020, 0.020, 0.020),
	"sports_blue": Color(0.118, 0.369, 0.620),
	"dark_tarnished_silver": Color(0.412, 0.416, 0.404),
	"cashmere": Color(0.722, 0.667, 0.549),
	"merlot": Color(0.325, 0.078, 0.129),
	"tahiti_green": Color(0.184, 0.420, 0.353),
	"misty_blue": Color(0.576, 0.667, 0.722),
}
var body_color := BODY_COLORS["silver_birch"]

var _vehicle: Node
var _night_manager: Node
var _is_night := false
var _brake_lights: Array[OmniLight3D] = []
var _headlights: Array[SpotLight3D] = []
var _head_mats: Array[StandardMaterial3D] = []      # front lens materials (glow at night)
var _tail_glow_mats: Array[StandardMaterial3D] = [] # rear lens materials (glow + brake)

const FRONT_LAMP_MATS := ["chevy_aveo_342yhwwesrtfnhdtf"]  # headlight lens → warm white
const REAR_LAMP_MATS := ["chevy_aveo_34yg4wersbrdf"]       # taillight lens → red


# Make the REAL lamp lens meshes emissive (matches lens shape, sits in the body).
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
			if is_front:
				mat.emission = Color(1.0, 0.96, 0.85)
				mat.emission_energy_multiplier = 0.0
				_head_mats.append(mat)
			else:
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
	print("Chevrolet Aveo setup complete")


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
		push_warning("Aveo: wheel rig failed: " + str(rig.get("note", "")))
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
				mat.metallic = 0.3
				mat.metallic_specular = 0.8
				mat.roughness = 0.3


func _setup_lights() -> void:
	for x in [-0.60, 0.60]:
		var l := OmniLight3D.new()
		l.name = "BrakeLight"
		l.position = Vector3(x, 0.86, 1.86)
		l.omni_range = 1.6
		l.light_energy = 0.4
		l.light_color = Color(1.0, 0.05, 0.05)
		l.shadow_enabled = false
		l.visible = _is_night
		get_parent().add_child(l)
		_brake_lights.append(l)
	for x in [-0.62, 0.62]:
		var l := SpotLight3D.new()
		l.name = "Headlight"
		l.position = Vector3(x, 0.78, -1.78)
		l.rotation_degrees = Vector3(-4, 0, 0)
		l.spot_range = 30.0
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
