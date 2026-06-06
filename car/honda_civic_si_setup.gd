extends Node3D

## Player (GEVP) setup for the Honda Civic Si 2006.
##
## Pipeline-generated per-car setup script (see docs/CAR_INTEGRATION_PIPELINE.md).
## Same Sketchfab "F_M_*_High" family as the reference Ford Focus ST: all four
## wheels live in merged Tire/Rim/Caliper/BrakeDisc meshes, so CarWheelRig splits
## them into four recentred, spinnable containers which are reparented onto the GEVP
## wheel nodes so the real model wheels spin + steer + travel with the suspension.
##
## Model native forward = +Z. The GEVP scene rotates the model 180° (forward = -Z)
## and scales ~101. Body paint material = "capaint"; taillights = "red_glass";
## front lamp meshes contain "LightCluster"/"LightRefracted".

const CarWheelRig := preload("res://tools/car_wheel_rig.gd")

# Official Honda Civic Si colours (from new_cars_color_mapping.md). Player default
# is the iconic Rallye Red; full list exposed for future showroom colour selection.
const BODY_COLORS := {
	"taffeta_white": Color(0.949, 0.945, 0.910),
	"alabaster_silver": Color(0.749, 0.753, 0.733),
	"galaxy_gray": Color(0.333, 0.337, 0.353),
	"nighthawk_black": Color(0.035, 0.039, 0.071),
	"rallye_red": Color(0.714, 0.098, 0.125),
	"habanero_red": Color(0.616, 0.176, 0.114),
	"fiji_blue": Color(0.090, 0.306, 0.604),
}
var body_color := BODY_COLORS["rallye_red"]

const DEBUG_FORWARD := false  # green FORWARD arrow for orientation verification

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
	if DEBUG_FORWARD:
		_add_forward_arrow()
	print("Honda Civic Si setup complete")


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


# ---- wheels --------------------------------------------------------------

func _rig_wheels() -> void:
	var rig: Dictionary = CarWheelRig.build(self)
	if not rig.get("ok", false):
		push_warning("Civic Si: wheel rig failed: " + str(rig.get("note", "")))
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


# ---- body colour ---------------------------------------------------------

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
			if mn == "capaint" and mat is StandardMaterial3D:
				mat.albedo_color = body_color
				mat.metallic = 0.4
				mat.metallic_specular = 0.85
				mat.roughness = 0.18
				mat.clearcoat_enabled = true
				mat.clearcoat = 0.9
				mat.clearcoat_roughness = 0.1


# ---- lights --------------------------------------------------------------

func _setup_taillights() -> void:
	# emissive red_glass + brake spotlights at the rear (vehicle +Z)
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
	for x in [-0.6, 0.6]:
		var l := SpotLight3D.new()
		l.name = "BrakeLight"
		l.position = Vector3(x, 0.86, 1.98)
		l.rotation_degrees = Vector3(0, 180, 0)
		l.spot_range = 2.0
		l.spot_angle = 90.0
		l.light_energy = 0.3
		l.light_color = Color(1.0, 0.0, 0.0)
		l.shadow_enabled = false
		get_parent().add_child(l)
		_brake_lights.append(l)


func _setup_headlights() -> void:
	# emissive light cluster + forward spotlights at the front (vehicle -Z)
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
	for x in [-0.62, 0.62]:
		var l := SpotLight3D.new()
		l.name = "Headlight"
		l.position = Vector3(x, 0.70, -1.92)
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


# ---- debug ---------------------------------------------------------------

func _add_forward_arrow() -> void:
	var arrow := MeshInstance3D.new()
	arrow.name = "FORWARD_ARROW"
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.06
	cyl.bottom_radius = 0.06
	cyl.height = 1.5
	arrow.mesh = cyl
	arrow.rotation_degrees = Vector3(90, 0, 0)
	arrow.position = Vector3(0, 1.2, -1.6)
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0, 1, 0)
	m.emission_enabled = true
	m.emission = Color(0, 1, 0)
	arrow.material_override = m
	get_parent().add_child(arrow)
	var lbl := Label3D.new()
	lbl.text = "FORWARD"
	lbl.position = Vector3(0, 1.8, -2.2)
	lbl.modulate = Color(0, 1, 0)
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	get_parent().add_child(lbl)
