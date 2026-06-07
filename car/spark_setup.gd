extends Node3D

## Player (GEVP) setup for the Chevrolet Spark 1.2 LT 2011 (FWD city hatch).
##
## Pipeline-generated (see docs/CAR_INTEGRATION_PIPELINE.md). Tier C: opaque Spanish-token
## materials. Wheels = tyres "Sparkllantas" + rims "Sparkrines"/"Sparkrines1"/"Sparkrines35"
## (the "sparkrines" substring catches all three) passed to CarWheelRig as EXTRA mat keys;
## the hardened lateral filter trims body strays. Body paint = "Spark".
## Lamp lens = a single shared material "Sparkluces" used at BOTH ends, so it is split
## per-surface by model-local centroid z (native front = +Z → warm white, rear = −Z → red).
## Native forward = +Z → GEVP scene rotates 180°.

const CarWheelRig := preload("res://tools/car_wheel_rig.gd")
const WHEEL_MATS := ["sparkllantas", "sparkrines"]  # extra mat keys (tyre + all rim variants)
const PAINT_MAT := "spark"                            # exact match (avoids Sparkint/Sparkplastic/...)
const LAMP_MATS := ["sparkluces"]                     # shared front+rear lamp lens; split by centroid z

const BODY_COLORS := {
	"summit_white": Color(0.918, 0.918, 0.906),
	"black_granite": Color(0.043, 0.043, 0.050),
	"silver": Color(0.745, 0.749, 0.741),
	"denim_blue": Color(0.176, 0.302, 0.486),
	"salsa_red": Color(0.671, 0.106, 0.118),
	"lemonade_yellow": Color(0.929, 0.792, 0.169),
	"techno_pink": Color(0.871, 0.337, 0.541),
	"jalapeno_green": Color(0.518, 0.690, 0.231),
}
var body_color := BODY_COLORS["lemonade_yellow"]

var _vehicle: Node
var _night_manager: Node
var _is_night := false
var _brake_lights: Array[OmniLight3D] = []
var _headlights: Array[SpotLight3D] = []
var _head_mats: Array[StandardMaterial3D] = []      # front lens materials (glow at night)
var _tail_glow_mats: Array[StandardMaterial3D] = [] # rear lens materials (glow + brake)


# Transform from a node up to this setup node (model-local space; native front = +Z).
func _xform_to_self(node: Node) -> Transform3D:
	var t := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != self:
		if n is Node3D:
			t = (n as Node3D).transform * t
		n = n.get_parent()
	return t


# Model-local centroid z of one surface of a mesh.
func _surface_centroid_z(mi: MeshInstance3D, surf: int) -> float:
	var arr = mi.mesh.surface_get_arrays(surf)
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	if verts.size() == 0:
		return 0.0
	var t := _xform_to_self(mi)
	var s := 0.0
	for v in verts:
		s += (t * v).z
	return s / verts.size()


# Make the REAL lamp lens meshes emissive (matches lens shape, sits in the body).
# Spark uses ONE lamp material front+rear, so split per-surface by centroid z.
func _emissive_lamps() -> void:
	for mesh in _find_all_meshes(self):
		if not (mesh is MeshInstance3D) or mesh.mesh == null:
			continue
		for i in range(mesh.mesh.get_surface_count()):
			var src: Material = mesh.mesh.surface_get_material(i)
			var mn := (src.resource_name.to_lower() if src else "")
			if not (mn in LAMP_MATS):
				continue
			var is_front: bool = _surface_centroid_z(mesh, i) >= 0.0  # native +Z = front
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
	print("Chevrolet Spark setup complete")


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
		push_warning("Spark: wheel rig failed: " + str(rig.get("note", "")))
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
	# rear red brake OmniLights (vehicle +Z), baseline at night + brighten on brake
	for x in [-0.58, 0.58]:
		var l := OmniLight3D.new()
		l.name = "BrakeLight"
		l.position = Vector3(x, 0.92, 1.72)
		l.omni_range = 1.5
		l.light_energy = 0.4
		l.light_color = Color(1.0, 0.05, 0.05)
		l.shadow_enabled = false
		l.visible = _is_night
		get_parent().add_child(l)
		_brake_lights.append(l)
	# front white headlight SpotLights (vehicle -Z), night
	for x in [-0.60, 0.60]:
		var l := SpotLight3D.new()
		l.name = "Headlight"
		l.position = Vector3(x, 0.80, -1.78)
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
