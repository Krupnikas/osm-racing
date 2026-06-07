extends Node3D

## Player (GEVP) setup for the Volga GAZ-3110 (RWD Russian sedan, low-poly).
##
## Pipeline-generated (see docs/CAR_INTEGRATION_PIPELINE.md). Tier B: the model is
## ALREADY real-world scale (~1.0) and ships SEPARATE corner wheels (WheelFL/FR/RL/RR,
## each a small group of sub-meshes). CarWheelRig still groups them by XZ quadrant and
## recentres each so it spins in place, then they reparent onto the GEVP wheel nodes.
##
## Native forward = +Z (front lamps Light/Light2 at +Z, rear lamp Light3 at −Z) → the
## GEVP scene rotates the model 180° (front −Z). Body paint material = "BodyColor".
## Lamps are bespoke (no red_glass): front = materials "Light"/"Light2", rear = "Light3".

const CarWheelRig := preload("res://tools/car_wheel_rig.gd")

const BODY_COLORS := {
	"white": Color(0.941, 0.937, 0.894),
	"buran": Color(0.749, 0.761, 0.761),
	"scat": Color(0.408, 0.420, 0.439),
	"anthracite": Color(0.184, 0.188, 0.196),
	"cyclone": Color(0.118, 0.247, 0.388),
	"malakhit": Color(0.137, 0.263, 0.208),
	"red_wine": Color(0.357, 0.078, 0.125),
	"avanturine": Color(0.067, 0.078, 0.094),
}
var body_color := BODY_COLORS["white"]

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
	_setup_taillights()
	_setup_headlights()
	print("Volga GAZ-3110 setup complete")


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


func _remove_stray_wheels() -> void:
	# A 17-vert grille emblem is named "Body_WheelBody" → the rig would mis-group it
	# into a front wheel quadrant. Drop any body mesh named like a wheel first.
	for mi in find_children("*", "MeshInstance3D", true, false):
		var nm := str(mi.name)
		if nm.begins_with("Body") and "Wheel" in nm:
			mi.free()


func _rig_wheels() -> void:
	_remove_stray_wheels()
	var rig: Dictionary = CarWheelRig.build(self)
	if not rig.get("ok", false):
		push_warning("Volga: wheel rig failed: " + str(rig.get("note", "")))
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


func _dup_material(mesh: MeshInstance3D, i: int) -> Material:
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
			var mat := _dup_material(mesh, i)
			if mat is StandardMaterial3D and mat.resource_name.to_lower() == "bodycolor":
				mat.albedo_color = body_color
				mat.metallic = 0.3
				mat.metallic_specular = 0.8
				mat.roughness = 0.25


func _setup_taillights() -> void:
	# rear lamp = material "Light3"; emissive red + brake spotlights at vehicle +Z
	for mesh in _find_all_meshes(self):
		if not (mesh is MeshInstance3D) or mesh.mesh == null:
			continue
		for i in range(mesh.mesh.get_surface_count()):
			var mat := _dup_material(mesh, i)
			if mat is StandardMaterial3D and mat.resource_name.to_lower() == "light3":
				mat.emission_enabled = true
				mat.emission = Color(1.0, 0.05, 0.05)
				mat.emission_energy_multiplier = 0.6
				_taillight_materials.append(mat)
	for x in [-0.65, 0.65]:
		var l := SpotLight3D.new()
		l.name = "BrakeLight"
		l.position = Vector3(x, 0.72, 2.25)
		l.rotation_degrees = Vector3(0, 180, 0)
		l.spot_range = 2.0
		l.spot_angle = 90.0
		l.light_energy = 0.3
		l.light_color = Color(1.0, 0.0, 0.0)
		l.shadow_enabled = false
		get_parent().add_child(l)
		_brake_lights.append(l)


func _setup_headlights() -> void:
	# front lamps = materials "Light"/"Light2"; emissive warm white + forward spotlights at vehicle -Z
	for mesh in _find_all_meshes(self):
		if not (mesh is MeshInstance3D) or mesh.mesh == null:
			continue
		for i in range(mesh.mesh.get_surface_count()):
			var mat := _dup_material(mesh, i)
			if mat is StandardMaterial3D:
				var mn := mat.resource_name.to_lower()
				if mn == "light" or mn == "light2":
					mat.emission_enabled = true
					mat.emission = Color(1.0, 0.96, 0.85)
					mat.emission_energy_multiplier = 0.4
	for x in [-0.70, 0.70]:
		var l := SpotLight3D.new()
		l.name = "Headlight"
		l.position = Vector3(x, 0.64, -2.20)
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
	for m in _taillight_materials:
		if is_instance_valid(m):
			m.emission_energy_multiplier = 2.0 if braking else 0.6
	for l in _brake_lights:
		if is_instance_valid(l):
			l.light_energy = 2.0 if braking else 0.3
