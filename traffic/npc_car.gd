extends VehicleBase
class_name NPCCar

## AI-контролируемый автомобиль для трафика
## Наследуется от VehicleBase для общей физики
## Использует Pure Pursuit steering для следования по waypoint path

enum AIState { DRIVING, STOPPED, YIELDING }

# AI navigation
var waypoint_path: Array = []  # Array[RoadNetwork.Waypoint]
var current_waypoint_index: int = 0
var target_speed: float = 30.0
var chosen_lane: int = 0  # Выбранная полоса (0 = крайняя правая, 1 = вторая справа)

# AI parameters
const LOOKAHEAD_MIN := 8.0  # Минимальный lookahead
const LOOKAHEAD_MAX := 20.0  # Максимальный lookahead
const BRAKE_DISTANCE := 12.0  # Дистанция торможения
const FOLLOWING_DISTANCE := 10.0  # Дистанция следования за препятствием
const CAUTIOUS_FACTOR := 0.95  # Множитель скорости (почти полная скорость)
const UPDATE_INTERVAL := 0.1  # Интервал обновления AI (100ms)
const CAR_WIDTH := 2.0  # Ширина машины в метрах
const LANE_WIDTH := 3.5  # Стандартная ширина полосы в метрах

# Internal state (AI-specific)
var ai_state := AIState.DRIVING
var update_timer := 0.0

# Raycast для obstacle detection
var obstacle_check_ray: RayCast3D
var spawn_grace_timer := 0.0  # Grace period after spawn

# Night mode lights
var _lights: Node3D
var _lights_enabled := false

# Colors for randomization
const NPC_COLORS := [
	Color(0.8, 0.1, 0.1),  # Красный
	Color(0.1, 0.3, 0.8),  # Синий
	Color(0.9, 0.9, 0.9),  # Белый
	Color(0.1, 0.1, 0.1),  # Чёрный
	Color(0.2, 0.7, 0.2),  # Зелёный
	Color(0.9, 0.7, 0.1),  # Жёлтый
	Color(0.5, 0.5, 0.5),  # Серый
	Color(0.6, 0.2, 0.8),  # Фиолетовый
]


func _ready() -> void:
	# Вызываем базовый _ready (собирает колёса)
	super._ready()

	# Настраиваем привод (AWD)
	for wheel in wheels_front:
		wheel.use_as_traction = true
	for wheel in wheels_rear:
		wheel.use_as_traction = true

	# Создаём raycast для obstacle detection
	obstacle_check_ray = RayCast3D.new()
	obstacle_check_ray.enabled = true
	obstacle_check_ray.collision_mask = 2 | 4  # Buildings + NPCs (НЕ terrain!)
	obstacle_check_ray.hit_from_inside = false
	add_child(obstacle_check_ray)

	# Создаём освещение
	_setup_lights()

	# Подключаемся к NightModeManager
	await get_tree().process_frame
	_connect_to_night_mode()


func _physics_process(delta: float) -> void:
	# Обновляем grace timer
	if spawn_grace_timer > 0.0:
		spawn_grace_timer -= delta

	# Обновляем AI с интервалом
	update_timer += delta
	if update_timer >= UPDATE_INTERVAL:
		update_timer = 0.0
		_update_ai_driver()
		# Debug disabled for performance
		# _debug_wheel_contact()

	# Вызываем базовую физику (скорость, руление, силы, auto-shift)
	_base_physics_process(delta)

	# Обновляем стоп-сигналы и задний ход
	_update_light_states()

	# Debug: если застряли на месте слишком долго, сбрасываем состояние
	if current_speed_kmh < 1.0 and ai_state == AIState.STOPPED:
		if randf() < 0.01:  # 1% шанс каждый frame
			ai_state = AIState.DRIVING


# ===== РЕАЛИЗАЦИЯ АБСТРАКТНЫХ МЕТОДОВ VehicleBase =====

func _get_steering_input() -> float:
	"""Возвращает AI steering input (рассчитан в _update_ai_driver)"""
	return steering_input


func _get_throttle_input() -> float:
	"""Возвращает AI throttle input (рассчитан в _update_ai_driver)"""
	return throttle_input


func _get_brake_input() -> float:
	"""Возвращает AI brake input (рассчитан в _update_ai_driver)"""
	return brake_input


func _update_ai_driver() -> void:
	"""Основная логика AI водителя"""
	if waypoint_path.is_empty():
		# Нет пути - стоим
		ai_state = AIState.STOPPED
		throttle_input = 0.0
		brake_input = 1.0
		steering_input = 0.0
		return

	# Проверяем приближение к тупику (конец пути без продолжения)
	var at_dead_end := _is_approaching_dead_end()
	if at_dead_end:
		# Тормозим до полной остановки
		throttle_input = 0.0
		brake_input = 1.0
		steering_input = 0.0
		ai_state = AIState.STOPPED
		return

	# Pure Pursuit steering с адаптивным lookahead
	# Чем быстрее едем, тем дальше смотрим
	var speed_factor: float = clamp(current_speed_kmh / 40.0, 0.0, 1.0)
	var lookahead_dist: float = lerp(LOOKAHEAD_MIN, LOOKAHEAD_MAX, speed_factor)

	var lookahead_point: Vector3 = _get_lookahead_point(lookahead_dist)
	if lookahead_point != Vector3.ZERO:
		var to_target := lookahead_point - global_position
		var to_target_flat := Vector3(to_target.x, 0, to_target.z)
		var forward := -global_transform.basis.z
		var forward_flat := Vector3(forward.x, 0, forward.z)

		# Защита от нулевых векторов (машина перевернулась или цель совпадает с позицией)
		if to_target_flat.length_squared() < 0.0001 or forward_flat.length_squared() < 0.0001:
			steering_input = 0.0
		else:
			to_target_flat = to_target_flat.normalized()
			forward_flat = forward_flat.normalized()

			# Вычисляем lateral error через cross product (только Y компонента)
			# forward.cross(to_target).y: положительный если цель справа, отрицательный если слева
			# steering > 0 = поворот влево, steering < 0 = поворот вправо
			# Поэтому нужен знак минус: если цель справа, крутим вправо (отрицательный steering)
			var lateral_error := forward_flat.cross(to_target_flat).y

			# Проверяем что lookahead достаточно далеко
			var distance_to_lookahead := global_position.distance_to(lookahead_point)
			if distance_to_lookahead < 2.0:
				# Слишком близко - едем прямо
				steering_input = 0.0
			else:
				# Steering пропорционален lateral error с ограничением
				# Минус потому что положительный lateral_error (цель справа) требует поворота вправо (steering < 0)
				steering_input = clamp(-lateral_error * 1.5, -1.0, 1.0)
	else:
		# Нет lookahead point - едем прямо
		steering_input = 0.0

	# Obstacle detection и speed control
	# Пропускаем проверку препятствий в течение grace period после spawn
	# ВРЕМЕННО ОТКЛЮЧЕНО для тестирования плавных поворотов
	if false and spawn_grace_timer <= 0.0 and _check_obstacle_ahead():
		# Препятствие впереди - тормозим
		throttle_input = 0.0
		brake_input = 1.0
		ai_state = AIState.STOPPED
	else:
		# Проверяем насколько крутой поворот впереди
		var turn_sharpness := _get_turn_sharpness_ahead()

		# Вычисляем безопасную скорость для поворота (более мягкие ограничения)
		var safe_turn_speed := target_speed
		if turn_sharpness > 0.4:  # Средний поворот
			safe_turn_speed = target_speed * 0.7
		if turn_sharpness > 0.7:  # Крутой поворот
			safe_turn_speed = target_speed * 0.5
		if turn_sharpness > 0.9:  # Очень крутой поворот
			safe_turn_speed = target_speed * 0.35

		# Едем с безопасной скоростью
		var desired_speed: float = min(target_speed, safe_turn_speed)
		var speed_error: float = desired_speed - current_speed_kmh

		if speed_error < -8.0:  # Слишком быстро - тормозим (увеличен порог)
			throttle_input = 0.0
			brake_input = clamp(-speed_error / 25.0, 0.2, 0.8)  # Более мягкое торможение
		else:  # Ускоряемся или поддерживаем
			throttle_input = clamp(speed_error / 12.0, 0.1, 1.0) * CAUTIOUS_FACTOR  # Минимум 0.1 газа
			brake_input = 0.0

		ai_state = AIState.DRIVING

		# Обновляем waypoint если близко к текущему
		_update_waypoint_progress()


func _get_lookahead_point(distance: float) -> Vector3:
	"""Находит lookahead point на пути на заданном расстоянии, со смещением в выбранную полосу"""
	if waypoint_path.is_empty():
		return Vector3.ZERO

	var current_pos := global_position
	var accumulated_dist := 0.0

	for i in range(current_waypoint_index, waypoint_path.size()):
		var wp = waypoint_path[i]
		var wp_pos: Vector3 = wp.position
		var dist_to_wp := current_pos.distance_to(wp_pos)

		if accumulated_dist + dist_to_wp >= distance:
			# Нашли точку на нужном расстоянии
			var center_point: Vector3
			var direction: Vector3

			var remaining := distance - accumulated_dist
			# Интерполируем от current_pos (текущая позиция на пути) к wp_pos
			# Защита от нулевого вектора при совпадающих точках
			var diff := wp_pos - current_pos
			if diff.length_squared() < 0.0001:
				direction = wp.direction  # Используем направление waypoint'а
			else:
				direction = diff.normalized()
			center_point = current_pos + direction * remaining

			# Вычисляем смещение в полосу
			var lane_offset := _calculate_lane_offset(wp)
			var right_vector := Vector3(-direction.z, 0, direction.x).normalized()
			return center_point + right_vector * lane_offset

		accumulated_dist += dist_to_wp
		current_pos = wp_pos

	# Если дошли до конца пути - возвращаем последний waypoint со смещением
	if waypoint_path.size() > 0:
		var last_wp = waypoint_path[-1]
		var lane_offset := _calculate_lane_offset(last_wp)
		var right_vector := Vector3(-last_wp.direction.z, 0, last_wp.direction.x).normalized()
		return last_wp.position + right_vector * lane_offset

	return Vector3.ZERO


func _calculate_lane_offset(wp: Variant) -> float:
	"""Вычисляет смещение от центра дороги для текущей полосы"""
	# Waypoint находится в центре дороги
	# Нужно сместиться вправо в нашу полосу
	#
	# Логика для правостороннего движения:
	# - Центр дороги = 0
	# - Правая половина дороги = полосы в нашем направлении
	# - Ширина одного направления = width / 2
	# - Если 2 полосы: полоса 0 = правая, полоса 1 = левая (ближе к центру)
	# - Если 1 полоса: полоса 0 = единственная

	var lanes: int = wp.lanes_count if wp.lanes_count > 0 else 1
	var half_road: float = wp.width / 2.0  # Ширина нашей стороны дороги
	var lane_width: float = half_road / lanes  # Ширина одной полосы

	# Смещение в центр нашей полосы
	# Полоса 0 = крайняя правая = смещение на (half_road - lane_width/2)
	# Полоса 1 = вторая справа = смещение на (half_road - lane_width * 1.5)
	var effective_lane: int = min(chosen_lane, lanes - 1)  # Не выходим за пределы полос
	var offset: float = half_road - lane_width * (0.5 + effective_lane)

	return offset


func _check_obstacle_ahead() -> bool:
	"""Проверяет наличие препятствия впереди через raycast"""
	var speed_kmh: float = max(5.0, current_speed_kmh)
	var check_distance: float = max(BRAKE_DISTANCE, speed_kmh * 0.3)

	# Raycast вперёд от центра машины НА УРОВНЕ КАПОТА (не вниз!)
	var from := global_position + Vector3(0, 1.0, 0)  # Поднимаем выше
	var forward := -global_transform.basis.z
	forward.y = 0  # Строго горизонтально, не вниз!
	forward = forward.normalized()

	obstacle_check_ray.global_position = from
	obstacle_check_ray.target_position = forward * check_distance
	obstacle_check_ray.force_raycast_update()

	if not obstacle_check_ray.is_colliding():
		return false

	# Есть препятствие впереди
	return true


func _get_turn_sharpness_ahead() -> float:
	"""Определяет крутизну поворота впереди (0.0 = прямо, 1.0 = разворот)"""
	# Нужно минимум 2 waypoint'а впереди для анализа поворота
	if waypoint_path.is_empty() or current_waypoint_index >= waypoint_path.size() - 1:
		return 0.0

	# Берём 3-5 waypoints вперёд для анализа
	var look_distance := 25.0  # Смотрим на 25м вперёд
	var forward := -global_transform.basis.z
	var forward_flat := Vector3(forward.x, 0, forward.z)

	# Защита от нулевого вектора (машина перевернулась)
	if forward_flat.length_squared() < 0.0001:
		return 0.0
	forward_flat = forward_flat.normalized()

	var max_angle := 0.0

	# Проходим по следующим waypoints
	for i in range(current_waypoint_index, min(current_waypoint_index + 5, waypoint_path.size())):
		var wp = waypoint_path[i]
		var dist_to_wp := global_position.distance_to(wp.position)

		if dist_to_wp > look_distance:
			break

		# Вычисляем угол между текущим направлением и направлением к waypoint
		var wp_dir := Vector3(wp.direction.x, 0, wp.direction.z).normalized()
		var angle := forward_flat.angle_to(wp_dir)

		max_angle = max(max_angle, angle)

	# Нормализуем угол к [0..1] (90° = 1.0)
	return clamp(max_angle / (PI / 2.0), 0.0, 1.0)


func _update_waypoint_progress() -> void:
	"""Обновляет текущий waypoint если машина близко к нему"""
	if waypoint_path.is_empty() or current_waypoint_index >= waypoint_path.size():
		return

	var current_wp = waypoint_path[current_waypoint_index]
	var distance := global_position.distance_to(current_wp.position)

	# Если близко к waypoint - переходим к следующему
	if distance < 10.0 and current_waypoint_index < waypoint_path.size() - 1:
		current_waypoint_index += 1

	# НОВОЕ: Если приближаемся к концу пути - продлеваем его
	var waypoints_ahead := waypoint_path.size() - current_waypoint_index
	if waypoints_ahead < 5:  # Осталось меньше 5 waypoints
		_extend_path()


func set_path(new_waypoints: Array) -> void:
	"""Устанавливает новый путь для следования"""
	waypoint_path = new_waypoints
	current_waypoint_index = 0
	spawn_grace_timer = 2.0  # 2 секунды на разгон без проверки препятствий

	if not waypoint_path.is_empty():
		var first_wp = waypoint_path[0]
		target_speed = first_wp.speed_limit * CAUTIOUS_FACTOR
		# Выбираем случайную полосу при старте
		_choose_random_lane(first_wp)
	else:
		target_speed = 30.0


func _choose_random_lane(wp: Variant) -> void:
	"""Выбирает случайную полосу на основе количества полос"""
	var lanes: int = wp.lanes_count if wp.lanes_count > 0 else 1
	chosen_lane = randi() % lanes


func randomize_color() -> void:
	"""Устанавливает случайный цвет кузова"""
	var color: Color = NPC_COLORS[randi() % NPC_COLORS.size()]

	# Применяем цвет к видимым частям кузова
	if has_node("Chassis"):
		var chassis = get_node("Chassis")
		# Всегда создаём новый материал чтобы не шарить между инстансами
		var mat = StandardMaterial3D.new()
		mat.albedo_color = color
		mat.metallic = 0.7
		mat.roughness = 0.3
		chassis.material_override = mat

	if has_node("Hood"):
		var hood = get_node("Hood")
		# Всегда создаём новый материал
		var mat = StandardMaterial3D.new()
		mat.albedo_color = color
		mat.metallic = 0.7
		mat.roughness = 0.3
		hood.material_override = mat


# === Физика теперь в VehicleBase ===
# Все методы физики (_update_speed, _apply_steering, _apply_forces,
# _get_torque_curve, _auto_shift) теперь в базовом классе


func _is_approaching_dead_end() -> bool:
	"""Проверяет приближается ли машина к тупику (конец пути без продолжения)"""
	if waypoint_path.is_empty():
		return false

	# Проверяем последний waypoint в пути
	var last_wp = waypoint_path[waypoint_path.size() - 1]

	# Если у последнего waypoint есть продолжение - не тупик
	if not last_wp.next_waypoints.is_empty():
		return false

	# Это тупик - проверяем расстояние до него
	var distance_to_end := global_position.distance_to(last_wp.position)

	# Начинаем тормозить за 15м до тупика
	return distance_to_end < 15.0


func _extend_path() -> void:
	"""Продлевает путь когда машина приближается к концу"""
	if waypoint_path.is_empty():
		return

	# Берём последний waypoint в текущем пути
	var last_wp = waypoint_path[waypoint_path.size() - 1]

	# Если у него нет следующих waypoints - всё, тупик
	if last_wp.next_waypoints.is_empty():
		return

	# Строим продолжение пути на 15 waypoints вперёд
	var current = last_wp
	var new_waypoints := []
	var is_turning := false

	for i in range(15):
		if current.next_waypoints.is_empty():
			break

		# Выбираем следующий waypoint (60% прямо, 40% поворот)
		var next
		if current.next_waypoints.size() == 1:
			next = current.next_waypoints[0]
		else:
			var rand := randf()
			if rand < 0.6:
				next = current.next_waypoints[0]  # Прямо
			else:
				next = current.next_waypoints[randi() % current.next_waypoints.size()]  # Поворот
				is_turning = true

		# Проверяем что waypoint ещё не в пути (избегаем циклов и дубликатов)
		if next in waypoint_path or next in new_waypoints:
			break

		new_waypoints.append(next)
		current = next

	# При повороте на новую дорогу выбираем новую полосу
	if is_turning and new_waypoints.size() > 0:
		var new_road_wp = new_waypoints[0]
		_choose_random_lane(new_road_wp)

	# Добавляем новые waypoints к существующему пути
	waypoint_path.append_array(new_waypoints)


# === Night Mode Lights ===

func _setup_lights() -> void:
	"""Создаёт источники света для NPC машины"""
	const NPCCarLightsScript = preload("res://night_mode/npc_car_lights.gd")
	_lights = NPCCarLightsScript.new()
	add_child(_lights)
	_lights.setup_lights(self)


func _connect_to_night_mode() -> void:
	"""Подключается к NightModeManager"""
	var night_manager := get_tree().current_scene.find_child("NightModeManager", true, false)
	if night_manager:
		night_manager.night_mode_changed.connect(_on_night_mode_changed)
		# Если уже ночь - включаем свет
		if night_manager.is_night:
			enable_lights()


func _on_night_mode_changed(enabled: bool) -> void:
	if enabled:
		enable_lights()
	else:
		disable_lights()


func enable_lights() -> void:
	"""Включает освещение"""
	if _lights_enabled:
		return
	_lights_enabled = true
	if _lights:
		_lights.enable_lights()


func disable_lights() -> void:
	"""Выключает освещение"""
	if not _lights_enabled:
		return
	_lights_enabled = false
	if _lights:
		_lights.disable_lights()


func _update_light_states() -> void:
	"""Обновляет стоп-сигналы и задний ход"""
	if not _lights or not _lights_enabled:
		return

	# Вызываем напрямую - мы знаем что NPCCarLights имеет эти методы
	_lights.set_braking(brake_input > 0.1)
	_lights.set_reversing(current_gear == 0)


func _debug_wheel_contact() -> void:
	"""Отладка: проверяет контакт колёс с землёй"""
	var all_wheels = wheels_front + wheels_rear
	var in_contact := 0

	for wheel in all_wheels:
		if wheel.is_in_contact():
			in_contact += 1

	# Debug warnings disabled for performance
	#if in_contact == 0:
	#	print("⚠️ NPC %s: NO WHEELS IN CONTACT!" % name)
	pass
