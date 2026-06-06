extends Node3D

## Player (GEVP) setup for the Mitsubishi Lancer Evolution X MR 2008 (AWD sport sedan).
##
## Pipeline-generated (see docs/CAR_INTEGRATION_PIPELINE.md). Tier B: real-world scale
## (~1.0), SEPARATE corner wheels (FL/FR/RL/RR, each misc/tyre/wheel/rotor) grouped +
## recentred by CarWheelRig, then reparented onto the GEVP wheel nodes.
##
## Native forward = +Z (rear logo/muffler at −Z) → GEVP scene rotates the model 180°.
## Body paint material = "Vehicle_Exterior_mm_ext". Lamp lenses share ONE material
## ("Vehicle_Exterior_mm_lights") across front+rear, so they are NOT mesh-emissive here;
## lighting is via placed white headlight SpotLights (front) + red taillight OmniLights
## (rear, baseline at night + brighten on brake).

const CarWheelRig := preload("res://tools/car_wheel_rig.gd")

const BODY_COLORS := {
	"octane_blue": Color(0.063, 0.298, 0.569),
	"rally_red": Color(0.710, 0.110, 0.133),
	"wicked_white": Color(0.941, 0.937, 0.906),
	"apex_silver": Color(0.749, 0.753, 0.745),
	"graphite_gray": Color(0.306, 0.314, 0.329),
	"phantom_black": Color(0.027, 0.031, 0.043),
}
var body_color := BODY_COLORS["octane_blue"]

const PAINT_MAT := "vehicle_exterior_mm_ext"

var _vehicle: Node
var _night_manager: Node
var _is_night := false
var _brake_lights: Array[OmniLight3D] = []
var _headlights: Array[SpotLight3D] = []


func _ready() -> void:
	_vehicle = get_parent()
	await get_tree().process_frame
	_rig_wheels()
	_change_body_color()
	_setup_taillights()
	_setup_headlights()
	print("Lancer Evo X setup complete")


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
	_update_taillight_brightness()


func _rig_wheels() -> void:
	var rig: Dictionary = CarWheelRig.build(self)
	if not rig.get("ok", false):
		push_warning("Evo X: wheel rig failed: " + str(rig.get("note", "")))
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
				mat.roughness = 0.2
				mat.clearcoat_enabled = true
				mat.clearcoat = 0.8


func _setup_taillights() -> void:
	# rear = vehicle +Z; red omni lights (baseline at night + brighten on brake)
	for x in [-0.62, 0.62]:
		var l := OmniLight3D.new()
		l.name = "BrakeLight"
		l.position = Vector3(x, 0.78, 1.95)
		l.omni_range = 1.6
		l.light_energy = 0.4
		l.light_color = Color(1.0, 0.05, 0.05)
		l.shadow_enabled = false
		l.visible = _is_night
		get_parent().add_child(l)
		_brake_lights.append(l)


func _setup_headlights() -> void:
	# front = vehicle -Z; white spotlights (visible at night)
	for x in [-0.66, 0.66]:
		var l := SpotLight3D.new()
		l.name = "Headlight"
		l.position = Vector3(x, 0.72, -1.95)
		l.rotation_degrees = Vector3(-4, 0, 0)
		l.spot_range = 32.0
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
