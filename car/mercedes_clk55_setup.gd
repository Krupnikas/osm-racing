extends Node3D

## Player (GEVP) setup for the Mercedes-Benz CLK 55 AMG 2003 (RWD luxury coupe).
##
## Pipeline-generated (see docs/CAR_INTEGRATION_PIPELINE.md). Tier C: 127-part model with
## LOD-duplicate wheels + steering wheel + calipers — the HARDENED CarWheelRig lateral
## filter handles those automatically. Native forward = +Z (front Glass_light_1 at +Z).
## GEVP scene rotates the model 180°. Body paint = "CarPaint". Lamp lenses are
## distinguished by MATERIAL (node names are all identical): front = "Glass_light_1",
## rear = "Light_glass".

const CarWheelRig := preload("res://tools/car_wheel_rig.gd")

const BODY_COLORS := {
	"brilliant_silver": Color(0.761, 0.769, 0.765),
	"obsidian_black": Color(0.067, 0.067, 0.075),
	"alabaster_white": Color(0.933, 0.925, 0.886),
	"tiefschwarz": Color(0.020, 0.020, 0.020),
	"iridium_silver": Color(0.784, 0.788, 0.776),
	"graphite_green": Color(0.149, 0.192, 0.176),
	"chablis": Color(0.722, 0.678, 0.604),
	"mineral_green": Color(0.220, 0.259, 0.212),
}
var body_color := BODY_COLORS["brilliant_silver"]

const PAINT_MAT := "carpaint"

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
	_recolor_and_lights()
	print("Mercedes CLK 55 AMG setup complete")


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
		push_warning("CLK: wheel rig failed: " + str(rig.get("note", "")))
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


func _recolor_and_lights() -> void:
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
			if not (mat is StandardMaterial3D):
				continue
			var mn := mat.resource_name.to_lower()
			if mn == PAINT_MAT:
				mat.albedo_color = body_color
				mat.metallic = 0.5
				mat.metallic_specular = 0.9
				mat.roughness = 0.16
				mat.clearcoat_enabled = true
				mat.clearcoat = 0.9
			elif mn == "glass_light_1":  # front headlight glass
				mat.emission_enabled = true
				mat.emission = Color(1.0, 0.96, 0.85)
				mat.emission_energy_multiplier = 0.5
			elif mn == "light_glass":    # rear taillight glass
				mat.emission_enabled = true
				mat.emission = Color(1.0, 0.05, 0.05)
				mat.emission_energy_multiplier = 0.6
				_taillight_materials.append(mat)
	# white headlight SpotLights (front = vehicle -Z), night
	for x in [-0.60, 0.60]:
		var l := SpotLight3D.new()
		l.name = "Headlight"
		l.position = Vector3(x, 0.50, -2.05)
		l.rotation_degrees = Vector3(-4, 0, 0)
		l.spot_range = 32.0
		l.spot_angle = 45.0
		l.light_energy = 3.0
		l.light_color = Color(1.0, 0.95, 0.82)
		l.shadow_enabled = false
		l.visible = _is_night
		get_parent().add_child(l)
		_headlights.append(l)
	# red brake SpotLights (rear = vehicle +Z)
	for x in [-0.61, 0.61]:
		var l := SpotLight3D.new()
		l.name = "BrakeLight"
		l.position = Vector3(x, 0.66, 2.10)
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
