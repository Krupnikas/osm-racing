extends Node3D

## Player (GEVP) setup for the LADA 2110 (FWD sedan, real-world scale ~1.0).
## FBX import, same family as Priora/Samara. Native forward = -Z = GEVP forward -Z → NO
## rotation. Separate corner wheels via CarWheelRig. Real lamp lenses: emissive inner bulbs
## "headlight_light"/"headlight_highbeam" (front white), "headlight_stop" (rear red); clear
## transparent cover; metallic paint + glass windows + glossy optics (shared substring polish).

const CarWheelRig := preload("res://tools/car_wheel_rig.gd")
const LampEmissive := preload("res://tools/lamp_emissive.gd")
const Polish := preload("res://car/lada_samara_setup.gd")  # shared substring polish_surface
const FRONT_LAMP_KEYS := ["headlight_light", "headlight_highbeam"]
const REAR_LAMP_KEYS := ["stop"]

const BODY_COLORS := {
	"snow_queen": Color(0.769, 0.776, 0.765),
	"crystal": Color(0.749, 0.757, 0.741),
	"triumph_red": Color(0.557, 0.180, 0.212),
	"milky_way": Color(0.231, 0.239, 0.259),
	"quartz_gray": Color(0.345, 0.357, 0.357),
	"amulet_green": Color(0.122, 0.290, 0.231),
	"regatta_blue": Color(0.122, 0.255, 0.416),
	"niagara": Color(0.141, 0.353, 0.388),
}
var body_color := BODY_COLORS["niagara"]

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
	for mesh in _find_all_meshes(self):
		if mesh is MeshInstance3D and mesh.mesh:
			for i in range(mesh.mesh.get_surface_count()):
				var mat: Material = mesh.get_surface_override_material(i)
				if not mat:
					var orig: Material = mesh.mesh.surface_get_material(i)
					if orig:
						mat = orig.duplicate(); mesh.set_surface_override_material(i, mat)
				Polish.polish_surface(mat, body_color)
	_setup_lights()
	var r: Dictionary = LampEmissive.apply_by_name(self, FRONT_LAMP_KEYS, [], 0.0, 0.7, false, false)
	_head_mats = r["head"]
	_tail_glow_mats = r["tail"]
	# rear taillights = REAR half of the spanning "headlight_glass" surface (corner clusters);
	# the central "headlight_stop" is NOT part of the rear lights, so it stays dark.
	_tail_glow_mats.append_array(LampEmissive.split_surface(self, "headlight_glass", false, 0.7, false, "blenda"))
	print("LADA 2110 setup complete")


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
		push_warning("2110: wheel rig failed: " + str(rig.get("note", "")))
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


func _setup_lights() -> void:
	for x in [-0.6, 0.6]:
		var l := OmniLight3D.new()
		l.name = "BrakeLight"; l.position = Vector3(x, 0.8, 2.05)
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
		if is_instance_valid(l): l.light_energy = 3.0 if braking else 0.4
	for m in _tail_glow_mats:
		if is_instance_valid(m): m.emission_energy_multiplier = 2.2 if braking else 0.7
