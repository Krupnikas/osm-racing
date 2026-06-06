extends Node3D

## Player (GEVP) setup for the LADA 2114 Samara (FWD hatch, real-world scale ~1.0).
## FBX import, same family as the Priora. Native forward = -Z (glassfront at -Z, stop at +Z)
## = GEVP forward -Z → NO rotation. Separate corner wheels via CarWheelRig. Real lamp lenses:
## emissive inner bulb "headlight light" (front white) / "headlight_stop" (rear red); clear
## transparent cover "headlight_glassfront/other"; metallic paint + glass windows + glossy optics
## (substring-based polish, robust across the Lada FBX name variants).

const CarWheelRig := preload("res://tools/car_wheel_rig.gd")
const LampEmissive := preload("res://tools/lamp_emissive.gd")
const FRONT_LAMP_KEYS := ["headlight light"]
const REAR_LAMP_KEYS := ["stop"]

const BODY_COLORS := {
	"white_cloud": Color(0.941, 0.937, 0.906),
	"black": Color(0.035, 0.035, 0.043),
	"quartz_gray": Color(0.345, 0.357, 0.357),
	"amulet_green": Color(0.122, 0.290, 0.231),
	"carmen_red": Color(0.545, 0.090, 0.125),
	"baltica_blue": Color(0.078, 0.212, 0.373),
	"riviera_blue": Color(0.106, 0.271, 0.427),
	"bronze_age": Color(0.541, 0.416, 0.282),
}
var body_color := BODY_COLORS["baltica_blue"]

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
	_polish_materials()
	_setup_lights()
	var r: Dictionary = LampEmissive.apply_by_name(self, FRONT_LAMP_KEYS, REAR_LAMP_KEYS, 0.0, 0.7, false, false)
	_head_mats = r["head"]
	_tail_glow_mats = r["tail"]
	print("LADA Samara setup complete")


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
	var rig: Dictionary = CarWheelRig.build(self)
	if not rig.get("ok", false):
		push_warning("Samara: wheel rig failed: " + str(rig.get("note", "")))
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


# Substring-based polish — robust across the Lada FBX name variants.
func _polish_materials() -> void:
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
			polish_surface(mat, body_color)


static func polish_surface(mat: Material, color: Color) -> void:
	if not (mat is StandardMaterial3D):
		return
	var mn := mat.resource_name.to_lower()
	if "paint" in mn:
		mat.albedo_color = color
		mat.metallic = 0.7; mat.metallic_specular = 0.9; mat.roughness = 0.22
		mat.clearcoat_enabled = true; mat.clearcoat = 0.6; mat.clearcoat_roughness = 0.08
	elif "glassfront" in mn or "glassother" in mn or "glass_front" in mn or "glass_other" in mn:
		# clear transparent lamp cover so reflectors/projectors show through
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(0.85, 0.88, 0.92, 0.10)
		mat.roughness = 0.02; mat.metallic = 0.1; mat.metallic_specular = 1.0
	elif "win" in mn:
		# windows: tinted transparent glass
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(0.05, 0.06, 0.08, 0.55)
		mat.metallic = 0.25; mat.metallic_specular = 0.9; mat.roughness = 0.05
	elif "chrome" in mn:
		mat.albedo_color = Color(0.8, 0.8, 0.82); mat.metallic = 0.95; mat.roughness = 0.12
	elif "headlight" in mn:
		# lamp housing / bulb / reflector — glossy optic look
		mat.roughness = 0.1; mat.metallic = 0.2; mat.metallic_specular = 0.9


func _setup_lights() -> void:
	for x in [-0.6, 0.6]:
		var l := OmniLight3D.new()
		l.name = "BrakeLight"; l.position = Vector3(x, 0.8, 1.85)
		l.omni_range = 1.6; l.light_energy = 0.4; l.light_color = Color(1.0, 0.05, 0.05)
		l.shadow_enabled = false; l.visible = _is_night
		get_parent().add_child(l); _brake_lights.append(l)
	for x in [-0.62, 0.62]:
		var l := SpotLight3D.new()
		l.name = "Headlight"; l.position = Vector3(x, 0.7, -2.0)
		l.rotation_degrees = Vector3(-4, 180, 0)
		l.spot_range = 30.0; l.spot_angle = 45.0; l.light_energy = 3.0
		l.light_color = Color(1.0, 0.95, 0.82); l.shadow_enabled = false; l.visible = _is_night
		get_parent().add_child(l); _headlights.append(l)


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
