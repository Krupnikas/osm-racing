extends Node3D

## Player (GEVP) setup for the Subaru Impreza WRX STI 2011 hatchback (AWD).
##
## Pipeline-generated (see docs/CAR_INTEGRATION_PIPELINE.md). Tier C: messy 139-part
## model — but the HARDENED CarWheelRig (real-vertex lateral stray filter) splits the
## wheels cleanly without per-car hacks (it drops the steering wheel + bumper that the
## name filter false-matched via "wheel"/"trim"→"rim").
##
## Native forward = +Z (rear TailLight/bumper at −Z). GEVP scene rotates the model 180°.
## Body paint = "wrxM_CarPaint_Max1". Lamps are NICELY NAMED: meshes containing
## "headlight" (front) and "taillight" (rear) — emissive by node name.

const CarWheelRig := preload("res://tools/car_wheel_rig.gd")

const BODY_COLORS := {
	"world_rally_blue": Color(0.106, 0.306, 0.608),
	"lightning_red": Color(0.710, 0.110, 0.137),
	"satin_white": Color(0.941, 0.933, 0.902),
	"spark_silver": Color(0.749, 0.761, 0.765),
	"dark_gray": Color(0.267, 0.282, 0.294),
	"obsidian_black": Color(0.031, 0.035, 0.047),
	"plasma_blue": Color(0.145, 0.188, 0.341),
}
var body_color := BODY_COLORS["world_rally_blue"]

const PAINT_MAT := "wrxm_carpaint_max1"

var _vehicle: Node
var _night_manager: Node
var _is_night := false
var _taillight_materials: Array[StandardMaterial3D] = []
var _brake_lights: Array[SpotLight3D] = []
var _headlights: Array[SpotLight3D] = []


func _ready() -> void:
	_vehicle = get_parent()
	await get_tree().process_frame
	_rig_wheels()
	_change_body_color()
	_setup_lights()
	print("Subaru WRX STI setup complete")


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
	_update_taillight_brightness()


func _rig_wheels() -> void:
	var rig: Dictionary = CarWheelRig.build(self)
	if not rig.get("ok", false):
		push_warning("STI: wheel rig failed: " + str(rig.get("note", "")))
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


func _dup_mat(mesh: MeshInstance3D, i: int) -> Material:
	var mat: Material = mesh.get_surface_override_material(i)
	if not mat and mesh.mesh:
		var orig: Material = mesh.mesh.surface_get_material(i)
		if orig:
			mat = orig.duplicate()
			mesh.set_surface_override_material(i, mat)
	return mat


func _change_body_color() -> void:
	for mesh in _find_all_meshes(self):
		if not (mesh is MeshInstance3D) or mesh.mesh == null:
			continue
		for i in range(mesh.mesh.get_surface_count()):
			var mat := _dup_mat(mesh, i)
			if mat is StandardMaterial3D and mat.resource_name.to_lower() == PAINT_MAT:
				mat.albedo_color = body_color
				mat.metallic = 0.4
				mat.metallic_specular = 0.85
				mat.roughness = 0.2
				mat.clearcoat_enabled = true
				mat.clearcoat = 0.8


func _setup_lights() -> void:
	# Emissive named lamp meshes: headlight* (warm white), taillight* (red).
	for mesh in _find_all_meshes(self):
		if not (mesh is MeshInstance3D) or mesh.mesh == null:
			continue
		var nm: String = mesh.name.to_lower()
		var is_head := "headlight" in nm
		var is_tail := "taillight" in nm
		if not (is_head or is_tail):
			continue
		for i in range(mesh.mesh.get_surface_count()):
			var mat := _dup_mat(mesh, i)
			if mat is StandardMaterial3D:
				mat.emission_enabled = true
				if is_head:
					mat.emission = Color(1.0, 0.96, 0.85)
					mat.emission_energy_multiplier = 0.5
				else:
					mat.emission = Color(1.0, 0.05, 0.05)
					mat.emission_energy_multiplier = 0.6
					_taillight_materials.append(mat)
	# forward headlight SpotLights (front = vehicle -Z), visible at night
	for x in [-0.55, 0.55]:
		var l := SpotLight3D.new()
		l.name = "Headlight"
		l.position = Vector3(x, 0.64, -1.94)
		l.rotation_degrees = Vector3(-4, 0, 0)
		l.spot_range = 32.0
		l.spot_angle = 45.0
		l.light_energy = 3.0
		l.light_color = Color(1.0, 0.95, 0.82)
		l.shadow_enabled = false
		l.visible = _is_night
		get_parent().add_child(l)
		_headlights.append(l)
	# rear brake SpotLights (rear = vehicle +Z)
	for x in [-0.68, 0.68]:
		var l := SpotLight3D.new()
		l.name = "BrakeLight"
		l.position = Vector3(x, 0.85, 1.88)
		l.rotation_degrees = Vector3(0, 180, 0)
		l.spot_range = 2.0
		l.spot_angle = 90.0
		l.light_energy = 0.3
		l.light_color = Color(1.0, 0.0, 0.0)
		l.shadow_enabled = false
		get_parent().add_child(l)
		_brake_lights.append(l)


func _update_taillight_brightness() -> void:
	var braking := false
	if _vehicle and "brake_input" in _vehicle:
		braking = _vehicle.brake_input > 0.1
	for m in _taillight_materials:
		if is_instance_valid(m):
			m.emission_energy_multiplier = 2.0 if braking else 0.6
	for l in _brake_lights:
		if is_instance_valid(l):
			l.light_energy = 2.0 if braking else 0.3
