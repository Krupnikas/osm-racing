extends Node3D
class_name Tram

## USSR tram (KTM-5) — follows tram waypoints
## Node3D for movement + child StaticBody3D for collision

var road_network: Node  # RoadNetwork
var waypoint_path: Array = []
var current_waypoint_index: int = 0
var speed: float = 0.0
var max_speed: float = 8.33  # ~30 km/h in m/s

# GLTF model: front = +X, ~25.8m long, ~3.4m tall, ~6.4m wide
const MODEL_SCALE := 0.58
const MODEL_Y_OFFSET := 0.05  # Lift slightly above rails

var _headlight_l: OmniLight3D
var _headlight_r: OmniLight3D
var _taillight_l: OmniLight3D
var _taillight_r: OmniLight3D
var _model_node: Node3D
var _logged_stuck: bool = false


func _ready() -> void:
	_load_model()
	_create_lights()
	_create_collision()


func _load_model() -> void:
	var gltf_scene: PackedScene = load("res://models/ussr_tram/scene.gltf")
	if not gltf_scene:
		push_warning("Tram: Failed to load GLTF model, using fallback box")
		_create_fallback_mesh()
		return

	_model_node = gltf_scene.instantiate()
	_model_node.rotation.y = -PI / 2.0
	_model_node.scale = Vector3(MODEL_SCALE, MODEL_SCALE, MODEL_SCALE)
	# Center model on Node3D origin: negate raw mesh center offsets after rotation
	# X center: raw Y center = 1.705 (after Sketchfab Y↔Z swap), negate to center
	# Z center: raw X center = 12.945 (length axis, maps to Z after -90° rotation), negate to center
	_model_node.position = Vector3(
		-1.705 * MODEL_SCALE,
		MODEL_Y_OFFSET,
		-12.945 * MODEL_SCALE
	)
	add_child(_model_node)
	_fix_glass_materials(_model_node)


func _fix_glass_materials(node: Node) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh:
			for surf_idx in mi.mesh.get_surface_count():
				var mat: Material = mi.get_active_material(surf_idx)
				if mat is StandardMaterial3D:
					var smat := mat as StandardMaterial3D
					if "Glass" in smat.resource_name or "glass" in smat.resource_name:
						var glass := StandardMaterial3D.new()
						glass.albedo_color = Color(0.6, 0.75, 0.85, 0.3)
						glass.metallic = 0.4
						glass.roughness = 0.05
						glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
						glass.cull_mode = BaseMaterial3D.CULL_DISABLED
						mi.set_surface_override_material(surf_idx, glass)
	for child in node.get_children():
		_fix_glass_materials(child)


func _create_fallback_mesh() -> void:
	var body_mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(2.5, 3.2, 14.0)
	body_mesh.mesh = box
	body_mesh.position = Vector3(0, 1.9, 0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.75, 0.15, 0.15)
	body_mesh.material_override = mat
	add_child(body_mesh)
	_model_node = body_mesh


func _create_lights() -> void:
	var half_len: float = 25.8 * MODEL_SCALE * 0.5
	var half_w: float = 6.4 * MODEL_SCALE * 0.5 * 0.6
	var light_h: float = 3.4 * MODEL_SCALE * 0.7

	_headlight_l = OmniLight3D.new()
	_headlight_l.light_color = Color(1.0, 0.95, 0.8)
	_headlight_l.light_energy = 2.0
	_headlight_l.omni_range = 15.0
	_headlight_l.omni_attenuation = 1.5
	_headlight_l.position = Vector3(-half_w, light_h, half_len)
	_headlight_l.shadow_enabled = false
	add_child(_headlight_l)

	_headlight_r = OmniLight3D.new()
	_headlight_r.light_color = Color(1.0, 0.95, 0.8)
	_headlight_r.light_energy = 2.0
	_headlight_r.omni_range = 15.0
	_headlight_r.omni_attenuation = 1.5
	_headlight_r.position = Vector3(half_w, light_h, half_len)
	_headlight_r.shadow_enabled = false
	add_child(_headlight_r)

	_taillight_l = OmniLight3D.new()
	_taillight_l.light_color = Color(1.0, 0.1, 0.05)
	_taillight_l.light_energy = 1.0
	_taillight_l.omni_range = 8.0
	_taillight_l.omni_attenuation = 2.0
	_taillight_l.position = Vector3(-half_w, light_h, -half_len)
	_taillight_l.shadow_enabled = false
	add_child(_taillight_l)

	_taillight_r = OmniLight3D.new()
	_taillight_r.light_color = Color(1.0, 0.1, 0.05)
	_taillight_r.light_energy = 1.0
	_taillight_r.omni_range = 8.0
	_taillight_r.omni_attenuation = 2.0
	_taillight_r.position = Vector3(half_w, light_h, -half_len)
	_taillight_r.shadow_enabled = false
	add_child(_taillight_r)

	_set_lights_enabled(false)


func _create_collision() -> void:
	var body := StaticBody3D.new()
	# Layer 1 = same as terrain — car (mask=15) DEFINITELY collides with layer 1
	body.collision_layer = 1
	body.collision_mask = 0
	var col_shape := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	var length: float = 25.8 * MODEL_SCALE
	var width: float = 2.5
	var height: float = 3.4 * MODEL_SCALE
	shape.size = Vector3(width, height, length)
	col_shape.shape = shape
	col_shape.position = Vector3(0, height * 0.5 + MODEL_Y_OFFSET, 0)
	body.add_child(col_shape)
	add_child(body)


func _set_lights_enabled(enabled: bool) -> void:
	if _headlight_l:
		_headlight_l.visible = enabled
	if _headlight_r:
		_headlight_r.visible = enabled
	if _taillight_l:
		_taillight_l.visible = enabled
	if _taillight_r:
		_taillight_r.visible = enabled


func set_path(path: Array) -> void:
	waypoint_path = path
	current_waypoint_index = 0
	speed = max_speed * 0.5


func _physics_process(delta: float) -> void:
	if waypoint_path.is_empty():
		return

	var night_manager = get_node_or_null("/root/Main/NightModeManager")
	if night_manager and night_manager.has_method("is_night"):
		_set_lights_enabled(night_manager.is_night())

	speed = move_toward(speed, max_speed, 2.0 * delta)

	if current_waypoint_index >= waypoint_path.size():
		_extend_path()
		if current_waypoint_index >= waypoint_path.size():
			if not _logged_stuck:
				var last_wp = waypoint_path[waypoint_path.size() - 1] if not waypoint_path.is_empty() else null
				var next_count: int = last_wp.next_waypoints.size() if last_wp else -1
				print("[TRAM] STUCK: path exhausted, idx=%d, path_size=%d, last_wp_next=%d, pos=%s" % [current_waypoint_index, waypoint_path.size(), next_count, str(global_position)])
				_logged_stuck = true
			return

	_logged_stuck = false
	var target_wp = waypoint_path[current_waypoint_index]
	var target_pos: Vector3 = target_wp.position
	var to_target: Vector3 = target_pos - global_position
	to_target.y = 0
	var dist: float = to_target.length()

	if dist < 5.0:
		current_waypoint_index += 1
		if current_waypoint_index >= waypoint_path.size():
			_extend_path()
		return

	var move_dir: Vector3 = to_target.normalized()
	global_position += move_dir * speed * delta
	global_position.y = target_pos.y

	var target_angle := atan2(move_dir.x, move_dir.z)
	global_rotation.y = lerp_angle(global_rotation.y, target_angle, 5.0 * delta)


func _extend_path() -> void:
	if waypoint_path.is_empty():
		return
	var last_wp = waypoint_path[waypoint_path.size() - 1]
	var current = last_wp
	var added: int = 0
	var stop_reason: String = "max_iter"
	for i in range(20):
		if current.next_waypoints.is_empty():
			stop_reason = "dead_end(no_next)"
			break
		var next = current.next_waypoints[0]
		if next in waypoint_path:
			stop_reason = "loop_detected"
			break
		waypoint_path.append(next)
		current = next
		added += 1
	if added == 0:
		print("[TRAM] _extend_path FAILED: %s, last_wp_pos=%s, next_count=%d" % [stop_reason, str(last_wp.position), last_wp.next_waypoints.size()])
	if current_waypoint_index > 10:
		waypoint_path = waypoint_path.slice(current_waypoint_index - 2)
		current_waypoint_index = 2
