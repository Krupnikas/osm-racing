extends Node
class_name LaneAssist

## Режим выравнивания (Lane Assist) для машины игрока
## Автоматически рулит по дороге (Pure Pursuit как у НПС),
## игрок управляет газом/тормозом.
## Короткое нажатие стрелок = смена полосы, длинное = выход из режима.
## Клавиша Q — вкл/выкл.

# Настройки
const LOOKAHEAD_MIN := 8.0
const LOOKAHEAD_MAX := 20.0
const STEERING_GAIN := 1.5
const LANE_CHANGE_SPEED := 3.0  # Скорость интерполяции при смене полосы
const LONG_PRESS_THRESHOLD := 0.4  # Секунды для "длинного" нажатия
const PATH_BUILD_COUNT := 30  # Сколько вейпоинтов строить впереди
const SEARCH_RADIUS := 30.0  # Радиус поиска ближайшей дороги

# Состояние
var active := false
var vehicle: Node = null  # GEVP Vehicle (RigidBody3D)
var road_network: Node = null  # RoadNetwork

# Путь
var waypoint_path: Array = []
var current_waypoint_index: int = 0

# Полосы
var lane_index: int = 0  # Unified: 0..N-1 наши, N..2N-1 встречные
var chosen_lane: int = 0
var is_oncoming: bool = false
var lane_offset_current: float = 0.0
var lane_offset_target: float = 0.0

# Детекция короткого/длинного нажатия
var _steer_left_held := false
var _steer_right_held := false
var _steer_left_press_time := 0.0
var _steer_right_press_time := 0.0

# Визуализация
var _debug_marker: MeshInstance3D = null
var _last_lookahead_point := Vector3.ZERO

# Сигналы
signal lane_assist_activated
signal lane_assist_deactivated
signal lane_changed(new_lane: int)


func _ready() -> void:
	process_priority = 100  # После VehicleController
	vehicle = get_parent()
	_create_debug_marker()
	await get_tree().process_frame
	_find_road_network()


func _create_debug_marker() -> void:
	_debug_marker = MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.4
	sphere.height = 0.8
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1, 0, 0, 0.8)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sphere.material = mat
	_debug_marker.mesh = sphere
	_debug_marker.visible = false
	# Добавляем в корень сцены чтобы позиция была глобальной
	get_tree().current_scene.add_child.call_deferred(_debug_marker)


func _find_road_network() -> void:
	var traffic_mgr = get_tree().current_scene.find_child("TrafficManager", true, false)
	if traffic_mgr and traffic_mgr.has_method("get_road_network"):
		road_network = traffic_mgr.get_road_network()
	if road_network:
		print("LaneAssist: RoadNetwork found")
	else:
		print("LaneAssist: RoadNetwork not available")


func _physics_process(delta: float) -> void:
	if not vehicle:
		return

	_handle_toggle_input()
	_handle_lane_change_input(delta)

	if not active:
		return

	if not road_network:
		return

	_ensure_path()
	_update_waypoint_progress()
	_update_lane_offset(delta)

	var ai_steering := _compute_steering()
	vehicle.steering_input = ai_steering

	# Обновляем визуализацию
	_update_debug_marker()


# === Вкл/Выкл ===

func _handle_toggle_input() -> void:
	if Input.is_action_just_pressed("Lane Assist"):
		if active:
			deactivate()
		else:
			activate()


func activate() -> void:
	if not road_network:
		_find_road_network()  # Retry — TrafficManager мог появиться позже
	if not road_network:
		print("LaneAssist: Cannot activate — no road network")
		return

	var best_wp = _find_best_waypoint()
	if best_wp == null:
		print("LaneAssist: Cannot activate — no road nearby")
		return

	_build_path_from(best_wp)
	_detect_current_lane(best_wp)

	active = true
	_steer_left_held = false
	_steer_right_held = false
	lane_assist_activated.emit()
	print("LaneAssist: ACTIVATED (lane %d, oncoming=%s)" % [lane_index, is_oncoming])


func deactivate() -> void:
	active = false
	waypoint_path.clear()
	current_waypoint_index = 0
	if is_instance_valid(_debug_marker):
		_debug_marker.visible = false
	lane_assist_deactivated.emit()
	print("LaneAssist: DEACTIVATED")


# === Public API (для drag race) ===

func set_lane(unified_index: int) -> void:
	var wp = _get_current_waypoint()
	if wp == null:
		return
	var lanes: int = wp.lanes_count if wp.lanes_count > 0 else 1
	var total := lanes * 2
	lane_index = clamp(unified_index, 0, total - 1)
	_apply_lane_index(wp)


func follow_road() -> void:
	activate()


func is_active() -> bool:
	return active


# === Поиск дороги ===

func _find_best_waypoint():
	var pos: Vector3 = vehicle.global_position
	var forward: Vector3 = -vehicle.global_transform.basis.z
	forward.y = 0
	if forward.length_squared() < 0.0001:
		return road_network.get_nearest_waypoint(pos)
	forward = forward.normalized()

	# Ищем вейпоинты в радиусе
	var candidates: Array = road_network.get_waypoints_in_radius(pos, SEARCH_RADIUS)
	if candidates.is_empty():
		return road_network.get_nearest_waypoint(pos)

	# Приоритет: ближайший попутный (dot > 0)
	var best_same_dir = null
	var best_same_dist := INF
	var best_any = null
	var best_any_dist := INF

	for wp in candidates:
		var dist: float = pos.distance_to(wp.position)
		if dist < best_any_dist:
			best_any_dist = dist
			best_any = wp
		var dir_dot: float = forward.dot(wp.direction)
		if dir_dot > 0.0 and dist < best_same_dist:
			best_same_dist = dist
			best_same_dir = wp

	# Если есть попутный — берём его, иначе ближайший любой
	if best_same_dir:
		return best_same_dir
	return best_any


# === Построение и продление пути ===

func _build_path_from(start_wp) -> void:
	waypoint_path.clear()
	current_waypoint_index = 0
	waypoint_path.append(start_wp)

	var current = start_wp
	for i in range(PATH_BUILD_COUNT):
		var next = _get_next_waypoint(current)
		if next == null or next in waypoint_path:
			break
		waypoint_path.append(next)
		current = next

	# Продвигаем индекс к ближайшему вейпоинту впереди машины
	_advance_to_nearest_ahead()


func _advance_to_nearest_ahead() -> void:
	## Находим ближайший вейпоинт в пути и ставим индекс на него.
	## Это нужно чтобы lookahead начинался от ближайшего вейпоинта,
	## а не от начала пути (которое может быть далеко позади).
	var pos: Vector3 = vehicle.global_position
	var best_idx := 0
	var best_dist := INF
	for i in range(waypoint_path.size()):
		var dist: float = pos.distance_to(waypoint_path[i].position)
		if dist < best_dist:
			best_dist = dist
			best_idx = i
	current_waypoint_index = best_idx


func _extend_path() -> void:
	if waypoint_path.is_empty():
		return
	var last_wp = waypoint_path[-1]

	var current = last_wp
	var new_waypoints := []
	for i in range(15):
		var next = _get_next_waypoint(current)
		if next == null or next in waypoint_path or next in new_waypoints:
			break
		new_waypoints.append(next)
		current = next

	waypoint_path.append_array(new_waypoints)


func _get_next_waypoint(current):
	## Возвращает следующий вейпоинт (самое прямое продолжение).
	## Кольцевые дороги замкнуты через next_waypoints в road_network.
	return _choose_next_waypoint_straight(current)


func _choose_next_waypoint_straight(current):
	## Всегда выбирает самое прямое продолжение (не как НПС с 40% поворотов)
	if current.next_waypoints.is_empty():
		return null
	if current.next_waypoints.size() == 1:
		return current.next_waypoints[0]

	var best_wp = null
	var best_dot := -INF
	for wp in current.next_waypoints:
		var d: float = current.direction.dot(wp.direction)
		if d > best_dot:
			best_dot = d
			best_wp = wp
	return best_wp


func _update_waypoint_progress() -> void:
	if waypoint_path.is_empty() or current_waypoint_index >= waypoint_path.size():
		return
	var current_wp = waypoint_path[current_waypoint_index]
	var distance: float = vehicle.global_position.distance_to(current_wp.position)
	if distance < 10.0 and current_waypoint_index < waypoint_path.size() - 1:
		current_waypoint_index += 1

	# Обрезаем старые вейпоинты чтобы массив не рос бесконечно
	if current_waypoint_index > 20:
		var trim := current_waypoint_index - 5
		waypoint_path = waypoint_path.slice(trim)
		current_waypoint_index -= trim

	var waypoints_ahead := waypoint_path.size() - current_waypoint_index
	if waypoints_ahead < 5:
		_extend_path()


func _ensure_path() -> void:
	if waypoint_path.is_empty() or current_waypoint_index >= waypoint_path.size():
		var wp = _find_best_waypoint()
		if wp:
			_build_path_from(wp)
			_detect_current_lane(wp)
		else:
			deactivate()


func _get_current_waypoint():
	if waypoint_path.is_empty() or current_waypoint_index >= waypoint_path.size():
		return null
	return waypoint_path[current_waypoint_index]


# === Pure Pursuit steering ===

func _compute_steering() -> float:
	var speed_kmh: float = vehicle.speed * 3.6
	var speed_factor: float = clamp(speed_kmh / 40.0, 0.0, 1.0)
	var lookahead_dist: float = lerp(LOOKAHEAD_MIN, LOOKAHEAD_MAX, speed_factor)

	var lookahead_point := _get_lookahead_point(lookahead_dist)
	_last_lookahead_point = lookahead_point
	if lookahead_point == Vector3.ZERO:
		return 0.0

	var to_target: Vector3 = lookahead_point - vehicle.global_position
	var to_target_flat: Vector3 = Vector3(to_target.x, 0, to_target.z)
	var forward: Vector3 = -vehicle.global_transform.basis.z
	var forward_flat: Vector3 = Vector3(forward.x, 0, forward.z)

	if to_target_flat.length_squared() < 0.0001 or forward_flat.length_squared() < 0.0001:
		return 0.0

	to_target_flat = to_target_flat.normalized()
	forward_flat = forward_flat.normalized()

	var lateral_error: float = forward_flat.cross(to_target_flat).y
	var forward_dot: float = forward_flat.dot(to_target_flat)
	var veh_pos: Vector3 = vehicle.global_position
	var distance_to_lookahead: float = veh_pos.distance_to(lookahead_point)

	if distance_to_lookahead < 2.0:
		return 0.0

	# Если цель почти позади (антипараллельные вектора) — cross ~= 0,
	# добавляем bias чтобы машина начала разворот
	if forward_dot < -0.5 and abs(lateral_error) < 0.1:
		lateral_error = 1.0  # Поворот вправо для разворота

	return clamp(lateral_error * STEERING_GAIN, -1.0, 1.0)


func _update_debug_marker() -> void:
	if not is_instance_valid(_debug_marker):
		return
	if _last_lookahead_point == Vector3.ZERO:
		_debug_marker.visible = false
		return
	_debug_marker.visible = true
	_debug_marker.global_position = _last_lookahead_point + Vector3(0, 0.5, 0)


func _get_lookahead_point(distance: float) -> Vector3:
	if waypoint_path.is_empty():
		return Vector3.ZERO

	var current_pos: Vector3 = vehicle.global_position
	var accumulated_dist := 0.0

	for i in range(current_waypoint_index, waypoint_path.size()):
		var wp = waypoint_path[i]
		var wp_pos: Vector3 = wp.position
		var dist_to_wp: float = current_pos.distance_to(wp_pos)

		if accumulated_dist + dist_to_wp >= distance:
			var remaining := distance - accumulated_dist
			var diff: Vector3 = wp_pos - current_pos
			var move_dir: Vector3
			if diff.length_squared() < 0.0001:
				move_dir = wp.direction
			else:
				move_dir = diff.normalized()
			var center_point: Vector3 = current_pos + move_dir * remaining

			# Для оффсета всегда используем направление вейпоинта,
			# а не diff — чтобы оффсет не зеркалился когда вейпоинт позади
			var wp_dir := Vector3(wp.direction.x, 0, wp.direction.z)
			if wp_dir.length_squared() < 0.0001:
				wp_dir = move_dir
			else:
				wp_dir = wp_dir.normalized()
			var right_vector := Vector3(-wp_dir.z, 0, wp_dir.x)
			return center_point + right_vector * lane_offset_current

		accumulated_dist += dist_to_wp
		current_pos = wp_pos

	# Конец пути — последний вейпоинт
	if waypoint_path.size() > 0:
		var last_wp = waypoint_path[-1]
		var dir_flat := Vector3(last_wp.direction.x, 0, last_wp.direction.z)
		if dir_flat.length_squared() < 0.0001:
			return last_wp.position
		var right_vector := Vector3(-dir_flat.z, 0, dir_flat.x).normalized()
		return last_wp.position + right_vector * lane_offset_current

	return Vector3.ZERO


# === Полосы ===

func _calculate_lane_offset_for(wp, lane: int, oncoming: bool) -> float:
	var lanes: int = wp.lanes_count if wp.lanes_count > 0 else 1
	var half_road: float = wp.width / 2.0
	var lane_width: float = half_road / lanes
	var effective_lane: int = min(lane, lanes - 1)
	var offset: float = half_road - lane_width * (0.5 + effective_lane)
	if oncoming:
		offset = -offset
	return offset


func _detect_current_lane(wp) -> void:
	var pos: Vector3 = vehicle.global_position
	var to_car: Vector3 = pos - wp.position
	to_car.y = 0
	var right_vec := Vector3(-wp.direction.z, 0, wp.direction.x).normalized()
	var lateral: float = to_car.dot(right_vec)

	var lanes: int = wp.lanes_count if wp.lanes_count > 0 else 1
	var half_road: float = wp.width / 2.0
	var lane_width: float = half_road / lanes

	if lateral >= 0:
		is_oncoming = false
		var lane_f: float = (half_road - lateral) / lane_width - 0.5
		chosen_lane = clampi(roundi(lane_f), 0, lanes - 1)
	else:
		is_oncoming = true
		var abs_lateral: float = abs(lateral)
		var lane_f: float = (half_road - abs_lateral) / lane_width - 0.5
		chosen_lane = clampi(roundi(lane_f), 0, lanes - 1)

	if is_oncoming:
		lane_index = (2 * lanes - 1) - chosen_lane
	else:
		lane_index = chosen_lane
	lane_offset_current = _calculate_lane_offset_for(wp, chosen_lane, is_oncoming)
	lane_offset_target = lane_offset_current


func _apply_lane_index(wp) -> void:
	var lanes: int = wp.lanes_count if wp.lanes_count > 0 else 1
	if lane_index < lanes:
		is_oncoming = false
		chosen_lane = lane_index
	else:
		is_oncoming = true
		# Зеркалим: index=lanes → ближняя встречная (chosen_lane = lanes-1),
		# index=2*lanes-1 → дальняя встречная (chosen_lane = 0)
		chosen_lane = (2 * lanes - 1) - lane_index
	lane_offset_target = _calculate_lane_offset_for(wp, chosen_lane, is_oncoming)


func _update_lane_offset(delta: float) -> void:
	lane_offset_current = lerp(lane_offset_current, lane_offset_target, LANE_CHANGE_SPEED * delta)


func _change_lane(direction: int) -> void:
	## direction: -1 = влево, +1 = вправо
	## Влево = увеличиваем lane_index (к центру/встречке)
	## Вправо = уменьшаем lane_index (к краю)
	var wp = _get_current_waypoint()
	if wp == null:
		return

	var lanes: int = wp.lanes_count if wp.lanes_count > 0 else 1
	var total := lanes * 2
	var new_index: int = lane_index - direction  # LEFT(-1) -> +1, RIGHT(+1) -> -1
	new_index = clampi(new_index, 0, total - 1)

	if new_index == lane_index:
		return

	lane_index = new_index
	_apply_lane_index(wp)
	lane_changed.emit(lane_index)
	print("LaneAssist: lane=%d (oncoming=%s)" % [lane_index, is_oncoming])


# === Короткое/длинное нажатие ===

func _handle_lane_change_input(delta: float) -> void:
	if not active:
		_steer_left_held = false
		_steer_right_held = false
		return

	# LEFT
	if Input.is_action_just_pressed("Steer Left"):
		_steer_left_press_time = 0.0
		_steer_left_held = true
	if _steer_left_held:
		if Input.is_action_pressed("Steer Left"):
			_steer_left_press_time += delta
			if _steer_left_press_time >= LONG_PRESS_THRESHOLD:
				deactivate()
				_steer_left_held = false
				return
		else:
			if _steer_left_press_time < LONG_PRESS_THRESHOLD:
				_change_lane(-1)  # Влево
			_steer_left_held = false

	# RIGHT
	if Input.is_action_just_pressed("Steer Right"):
		_steer_right_press_time = 0.0
		_steer_right_held = true
	if _steer_right_held:
		if Input.is_action_pressed("Steer Right"):
			_steer_right_press_time += delta
			if _steer_right_press_time >= LONG_PRESS_THRESHOLD:
				deactivate()
				_steer_right_held = false
				return
		else:
			if _steer_right_press_time < LONG_PRESS_THRESHOLD:
				_change_lane(1)  # Вправо
			_steer_right_held = false
