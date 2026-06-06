extends Node3D

## Player (GEVP) setup for the Audi TT 3.2 DSG Quattro 2003 (AWD coupe).
##
## Pipeline-generated (see docs/CAR_INTEGRATION_PIPELINE.md). Same Sketchfab
## "F_M_*_High" family as Focus ST / Civic Si: merged Tire/Rim/Caliper wheels split
## by CarWheelRig. Native forward = +Z → player scene rotates model 180° (front −Z),
## scales ~99.83. Body paint material = "phong1"; taillights = "red_glass"; front
## lamp meshes contain "LightCluster"/"LightRefracted".

const CarWheelRig := preload("res://tools/car_wheel_rig.gd")

const BODY_COLORS := {
	"brilliant_red": Color(0.706, 0.071, 0.106),
	"brilliant_black": Color(0.020, 0.020, 0.020),
	"brilliant_white": Color(0.941, 0.937, 0.906),
	"light_silver": Color(0.749, 0.757, 0.749),
	"dolomite_gray": Color(0.424, 0.431, 0.439),
	"denim_blue": Color(0.125, 0.224, 0.357),
	"imola_yellow": Color(0.890, 0.702, 0.102),
	"misano_red": Color(0.620, 0.082, 0.110),
}
var body_color := BODY_COLORS["brilliant_red"]

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
	print("Audi TT setup complete")


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
		push_warning("Audi TT: wheel rig failed: " + str(rig.get("note", "")))
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
		if not (mesh is MeshInstance3D):
			continue
		var sc: int = mesh.get_surface_override_material_count()
		if sc == 0 and mesh.mesh:
			sc = mesh.mesh.get_surface_count()
		for i in range(sc):
			var mat: Material = mesh.get_surface_override_material(i)
			if not mat and mesh.mesh:
				var orig: Material = mesh.mesh.surface_get_material(i)
				if orig:
					mat = orig.duplicate()
					mesh.set_surface_override_material(i, mat)
			if not mat:
				continue
			var mn := mat.resource_name.to_lower()
			if mn == "phong1" and mat is StandardMaterial3D:
				mat.albedo_color = body_color
				mat.metallic = 0.4
				mat.metallic_specular = 0.85
				mat.roughness = 0.18
				mat.clearcoat_enabled = true
				mat.clearcoat = 0.9
				mat.clearcoat_roughness = 0.1


func _setup_taillights() -> void:
	for mesh in _find_all_meshes(self):
		if not (mesh is MeshInstance3D):
			continue
		var sc: int = mesh.mesh.get_surface_count() if mesh.mesh else 0
		for i in range(sc):
			var mat: Material = mesh.get_surface_override_material(i)
			if not mat and mesh.mesh:
				var orig: Material = mesh.mesh.surface_get_material(i)
				if orig:
					mat = orig.duplicate()
					mesh.set_surface_override_material(i, mat)
			if mat is StandardMaterial3D and mat.resource_name.to_lower() == "red_glass":
				mat.emission_enabled = true
				mat.emission = Color(1.0, 0.08, 0.08)
				mat.emission_energy_multiplier = 0.6
				_taillight_materials.append(mat)
	for x in [-0.55, 0.55]:
		var l := SpotLight3D.new()
		l.name = "BrakeLight"
		l.position = Vector3(x, 0.64, 1.70)
		l.rotation_degrees = Vector3(0, 180, 0)
		l.spot_range = 2.0
		l.spot_angle = 90.0
		l.light_energy = 0.3
		l.light_color = Color(1.0, 0.0, 0.0)
		l.shadow_enabled = false
		get_parent().add_child(l)
		_brake_lights.append(l)


func _setup_headlights() -> void:
	for mesh in _find_all_meshes(self):
		if not (mesh is MeshInstance3D):
			continue
		var nm: String = mesh.name.to_lower()
		if "lightcluster" in nm or "lightrefracted" in nm:
			var sc: int = mesh.mesh.get_surface_count() if mesh.mesh else 0
			for i in range(sc):
				var mat: Material = mesh.get_surface_override_material(i)
				if not mat and mesh.mesh:
					var orig: Material = mesh.mesh.surface_get_material(i)
					if orig:
						mat = orig.duplicate()
						mesh.set_surface_override_material(i, mat)
				if mat is StandardMaterial3D:
					mat.emission_enabled = true
					mat.emission = Color(1.0, 0.96, 0.85)
					mat.emission_energy_multiplier = 0.4
	for x in [-0.60, 0.60]:
		var l := SpotLight3D.new()
		l.name = "Headlight"
		l.position = Vector3(x, 0.62, -1.85)
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
