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

# Physics optimization: колеса отключены для всех NPC

# Internal state (AI-specific)
var ai_state := AIState.DRIVING
var update_timer := 0.0
var stuck_timer := 0.0  # Таймер застревания (не движемся > 10 сек = despawn)
var off_road_timer := 0.0  # Таймер езды по траве (> 1 сек = despawn)
var _waiting_for_chunk := false   # Стоим у границы чанка, ждём когда появятся next_waypoints
var _chunk_retry_timer := 0.0    # Таймер повторной проверки next_waypoints
var _chunk_wait_elapsed := 0.0   # Суммарное время ожидания чанка
const CHUNK_RETRY_INTERVAL := 1.0
const CHUNK_WAIT_MAX := 8.0      # Через 8 сек — настоящий тупик, разворачиваемся

# Штраф за повторные дороги: предпочитаем дороги, по которым давно не ехали
var _recent_road_ids: Dictionary = {}  # road_id → timestamp (сек), для штрафа повторов
var _known_road_ids: Dictionary = {}   # road_id → true, никогда не истекает, для детектора петли
const ROAD_REPEAT_TTL := 45.0
var _stale_extend_count := 0   # Сколько extend подряд не добавили новых road_id
var _loop_braking := false     # Плавно тормозим перед деспавном из петли
var _loop_stop_timer := 0.0    # Время стояния после остановки из петли

# Raycast для obstacle detection
var obstacle_check_ray: RayCast3D
var spawn_grace_timer := 0.0  # Grace period after spawn

# Сигнал для TrafficManager - машина застряла и должна быть despawn'ена
signal request_despawn

# Night mode lights
var _lights: Node3D
var _lights_enabled := false
var _is_night := false
var _is_raining := false

# Police emergency (Wave: police lights + siren). Modes assigned ONLY by TrafficManager for
# MOVING police NPCs; parked police never get a mode. Lightbar + siren are OWNED children so
# they free with the car — but because cars are POOLED (reused), they MUST also be reset on
# return-to-pool via stop_police_emergency() (a looping siren must never outlive the car).
enum PoliceEmergencyMode { SILENT, LIGHTS_ONLY, LIGHTS_AND_SIREN }
const POLICE_SIREN_PATH := "res://audio/sfx/police-siren.mp3"
# Rotating blue beacon (real Russian проблесковый маяк): a SpotLight3D beaming forward + a bit
# down, spinning around Y at the existing roof blue-lamp position, plus a small emissive dome.
# v1 = BLUE only (red/orange beacons are future). NO procedural lightbar — the model already has
# the lamp meshes; we only add the rotating beam + glow.
const BEACON_SPIN := TAU * 1.1        # ~1.1 rev/sec
const BEACON_TILT_DEG := -22.0        # beam points forward + a bit down
const BEACON_LAMP_LOCAL := Vector3(0.33, 1.21, -0.17)  # blue roof cone on the Lada 2109 ДПС (car-local; MCP-measured)
var police_emergency_mode: int = PoliceEmergencyMode.SILENT
var emergency_active := false
var emergency_siren_enabled := false
var police_siren_max_distance := 80.0  # set by TrafficManager before activation
var _emergency_time_left := 0.0
var _police_beacon: Node3D = null          # spinning pivot at the blue lamp
var _beacon_light: SpotLight3D = null
var _beacon_glow_mat: StandardMaterial3D = null
var _police_siren: AudioStreamPlayer3D = null

# Wheel rotation
var _wheel_mesh_nodes: Array[MeshInstance3D] = []
var _wheel_radius := 0.3

# Static cache for merged meshes (по типу NPC сцены)
static var _merged_mesh_cache: Dictionary = {}  # scene_path → ArrayMesh

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

	# ОПТИМИЗАЦИЯ: Отключаем физику колес у ВСЕХ NPC (1 body вместо 5)
	_disable_wheel_physics()

	# ОПТИМИЗАЦИЯ: Объединяем mesh NPC в один для уменьшения draw calls
	_merge_meshes()

	# Настраиваем привод (AWD) - не используется, но оставляем для совместимости
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

	# Вращаем колёса
	_update_wheel_rotation(delta)

	# Обновляем стоп-сигналы и задний ход
	_update_light_states()

	# Плавная остановка из петли → деспавн
	if _loop_braking:
		if current_speed_kmh < 1.0:
			_loop_stop_timer += delta
			if _loop_stop_timer > 1.5:
				request_despawn.emit()
		stuck_timer = 0.0
		return

	# Если ждём загрузки соседнего чанка — тихо перепроверяем раз в секунду
	if _waiting_for_chunk:
		_chunk_wait_elapsed += delta
		if _chunk_wait_elapsed >= CHUNK_WAIT_MAX:
			# Чанк так и не загрузился — настоящий тупик, разворачиваемся
			_do_uturn()
		else:
			_chunk_retry_timer -= delta
			if _chunk_retry_timer <= 0.0:
				_chunk_retry_timer = CHUNK_RETRY_INTERVAL
				_extend_path()
		stuck_timer = 0.0  # Не считать ожидание чанка за застревание
	# Despawn если не движемся больше 10 секунд (исключая ожидание чанка)
	elif current_speed_kmh < 3.0:
		stuck_timer += delta
		if stuck_timer > 10.0:
			request_despawn.emit()
			stuck_timer = 0.0
	else:
		stuck_timer = 0.0

	# Despawn если выехали на траву (далеко от waypoint пути)
	if _is_off_road():
		off_road_timer += delta
		if off_road_timer > 1.0:  # 1 секунда на траве = despawn
			request_despawn.emit()
			off_road_timer = 0.0
	else:
		off_road_timer = 0.0


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
	if waypoint_path.is_empty() or _waiting_for_chunk or _loop_braking:
		# Нет пути / ждём чанк / тормозим из петли — стоим ровно
		ai_state = AIState.STOPPED
		throttle_input = 0.0
		brake_input = 1.0
		steering_input = 0.0
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
		var dir_flat := Vector3(last_wp.direction.x, 0, last_wp.direction.z)
		# Защита от нулевого вектора
		if dir_flat.length_squared() < 0.0001:
			return last_wp.position
		var right_vector := Vector3(-dir_flat.z, 0, dir_flat.x).normalized()
		return last_wp.position + right_vector * lane_offset

	return Vector3.ZERO


func _calculate_lane_offset(wp: Variant) -> float:
	"""Вычисляет смещение от центра way для текущей полосы"""
	var lanes: int = wp.lanes_count if wp.lanes_count > 0 else 1
	var effective_lane: int = min(chosen_lane, lanes - 1)

	if wp.is_oneway:
		# Oneway: waypoint в центре ПРОЕЗЖЕЙ ЧАСТИ (одна сторона дороги).
		# Полосы распределены симметрично вокруг центра.
		# width = ширина проезжей части (напр. 7.0m для 2 полос по 3.5m)
		# Lane 0 (правая): offset > 0, Lane 1 (левая): offset < 0
		var lane_w: float = wp.width / float(lanes)
		return wp.width / 2.0 - lane_w * (0.5 + effective_lane)
	else:
		# Bidirectional: waypoint в центре ВСЕЙ дороги.
		# NPC всегда смещается ВПРАВО (правостороннее движение).
		# width = ширина всей дороги, half_road = ширина одного направления
		var half_road: float = wp.width / 2.0
		var lane_w: float = half_road / float(lanes)
		return half_road - lane_w * (0.5 + effective_lane)


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
		var wp_dir := Vector3(wp.direction.x, 0, wp.direction.z)
		# Защита от нулевого вектора
		if wp_dir.length_squared() < 0.0001:
			continue
		wp_dir = wp_dir.normalized()
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

	# Продвигаем индекс мимо всех пройденных wp (не только одного за кадр)
	while distance < 10.0 and current_waypoint_index < waypoint_path.size() - 1:
		current_waypoint_index += 1
		if current_waypoint_index < waypoint_path.size():
			distance = global_position.distance_to(waypoint_path[current_waypoint_index].position)

	# Обрезаем старые вейпоинты чтобы массив не рос бесконечно
	if current_waypoint_index > 20:
		var trim := current_waypoint_index - 5
		waypoint_path = waypoint_path.slice(trim)
		current_waypoint_index -= trim

	# Если приближаемся к концу пути - продлеваем его
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


func _is_off_road() -> bool:
	"""Проверяет находится ли машина вне дороги (raycast вниз)"""
	# Используем raycast вниз чтобы определить тип поверхности
	var space_state := get_world_3d().direct_space_state
	var from := global_position + Vector3(0, 1.0, 0)
	var to := global_position + Vector3(0, -2.0, 0)

	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 1  # Terrain layer (дороги и земля)
	query.exclude = [self]

	var result := space_state.intersect_ray(query)
	if result.is_empty():
		return true  # Нет поверхности под машиной = не на дороге

	# Проверяем группу коллайдера
	var collider = result.get("collider")
	if collider and collider.is_in_group("Road"):
		return false  # На дороге

	# Grass, Park или что-то другое = не на дороге
	return true


func _do_uturn() -> void:
	"""Разворачивается по prev_waypoints когда впереди настоящий тупик."""
	_waiting_for_chunk = false
	_chunk_wait_elapsed = 0.0
	if waypoint_path.is_empty():
		request_despawn.emit()
		return
	# Штампуем road_id тупика как «недавно посещённый» с запасом,
	# чтобы _choose_next_waypoint избегал его на следующем перекрёстке.
	var dead_end_road_id: int = waypoint_path[-1].road_id
	_recent_road_ids[dead_end_road_id] = Time.get_ticks_msec() / 1000.0
	var cur = waypoint_path[-1]
	var reversed: Array = []
	for i in range(20):
		if cur.prev_waypoints.is_empty():
			break
		cur = cur.prev_waypoints[0]
		reversed.append(cur)
	if reversed.size() < 3:
		request_despawn.emit()
		return
	waypoint_path.append_array(reversed)


func _resync_waypoint_index() -> void:
	"""После ожидания чанка NPC мог физически уехать вперёд.
	Находим ближайший вейпоинт к текущей позиции и ставим индекс на него."""
	if waypoint_path.is_empty():
		return
	var best_dist := INF
	var best_idx := current_waypoint_index
	var search_end := mini(waypoint_path.size(), current_waypoint_index + 30)
	for i in range(current_waypoint_index, search_end):
		var d := global_position.distance_to(waypoint_path[i].position)
		if d < best_dist:
			best_dist = d
			best_idx = i
	current_waypoint_index = best_idx


func _extend_path() -> void:
	"""Продлевает путь когда машина приближается к концу"""
	_waiting_for_chunk = false  # Сбрасываем; переставим если снова тупик
	_chunk_wait_elapsed = 0.0
	if waypoint_path.is_empty():
		return

	# Берём последний waypoint в текущем пути
	var last_wp = waypoint_path[waypoint_path.size() - 1]

	# Если у него нет следующих waypoints — возможно, соседний чанк ещё не загружен.
	# Ставим флаг и ждём: process_pending_connections() наполнит next_waypoints
	# как только чанк появится, и мы подхватим это при следующей проверке.
	if last_wp.next_waypoints.is_empty():
		_waiting_for_chunk = true
		_chunk_retry_timer = CHUNK_RETRY_INTERVAL
		return

	# Строим продолжение пути на 15 waypoints вперёд
	var current = last_wp
	var new_waypoints := []
	var visited := {}  # Быстрая проверка циклов
	var is_turning := false

	for i in range(15):
		if current.next_waypoints.is_empty():
			break

		# Выбираем следующий waypoint, пропуская уже добавленные
		var next = _choose_next_waypoint(current, visited)
		if next == null:
			break

		# Проверяем это поворот или прямо
		var dir_dot: float = current.direction.dot(next.direction)
		if dir_dot < 0.7:  # Угол > ~45 градусов = поворот
			is_turning = true

		visited[next] = true
		_recent_road_ids[next.road_id] = Time.get_ticks_msec() / 1000.0
		new_waypoints.append(next)
		current = next

	# При повороте на новую дорогу выбираем новую полосу
	if is_turning and new_waypoints.size() > 0:
		var new_road_wp = new_waypoints[0]
		_choose_random_lane(new_road_wp)

	# Добавляем новые waypoints к существующему пути
	var was_waiting := _chunk_wait_elapsed > 0.0 or _chunk_retry_timer < CHUNK_RETRY_INTERVAL
	waypoint_path.append_array(new_waypoints)

	# Если NPC ждал пока соединение появится, он мог физически уехать вперёд
	# пока current_waypoint_index стоял на месте. Ресинхронизируем индекс
	# к ближайшему вейпоинту чтобы lookahead не указывал назад.
	if was_waiting:
		_resync_waypoint_index()

	# Детектор петли: если все road_id в этом extend уже были известны — NPC в замкнутом кольце.
	# Используем _known_road_ids (никогда не истекает) как эталон «уже видели».
	var all_known := true
	for wp in new_waypoints:
		if not _known_road_ids.has(wp.road_id):
			all_known = false
			_known_road_ids[wp.road_id] = true

	if new_waypoints.is_empty() or all_known:
		_stale_extend_count += 1
		if _stale_extend_count >= 3:
			_loop_braking = true
	else:
		_stale_extend_count = 0

	# Чистим устаревшие записи road_ids
	var now_sec := Time.get_ticks_msec() / 1000.0
	for rid in _recent_road_ids.keys():
		if now_sec - _recent_road_ids[rid] > ROAD_REPEAT_TTL:
			_recent_road_ids.erase(rid)


func _choose_next_waypoint(current, exclude: Dictionary = {}) -> Variant:
	"""Выбирает следующий waypoint с приоритетом прямого направления.
	60% шанс ехать прямо, 40% шанс повернуть. Пропускает wp из exclude."""
	if current.next_waypoints.is_empty():
		return null

	# Фильтруем исключённые
	var candidates := []
	for wp in current.next_waypoints:
		if wp not in exclude:
			candidates.append(wp)
	if candidates.is_empty():
		return null

	if candidates.size() == 1:
		return candidates[0]

	# Разделяем кандидатов на свежих (давно не ехали) и недавних (были < ROAD_REPEAT_TTL сек)
	var now_c := Time.get_ticks_msec() / 1000.0
	var fresh: Array = []
	var stale: Array = []
	for wp in candidates:
		var last_visit: float = _recent_road_ids.get(wp.road_id, -INF)
		if now_c - last_visit < ROAD_REPEAT_TTL:
			stale.append(wp)
		else:
			fresh.append(wp)
	# Предпочитаем свежие дороги; если их нет — используем недавние (деваться некуда)
	var pool := fresh if not fresh.is_empty() else stale

	# Находим waypoint с наиболее близким направлением (прямо) в пуле
	var straight_wp = null
	var best_dot := -INF
	var turn_candidates := []

	for wp in pool:
		var dir_dot: float = current.direction.dot(wp.direction)
		if dir_dot > best_dot:
			best_dot = dir_dot
			straight_wp = wp
		if dir_dot < 0.7:  # Это поворот
			turn_candidates.append(wp)

	# 60% шанс ехать прямо
	if randf() < 0.6 and straight_wp != null:
		return straight_wp

	# 40% шанс повернуть (если есть куда)
	if not turn_candidates.is_empty():
		return turn_candidates[randi() % turn_candidates.size()]

	# Fallback - едем прямо
	return straight_wp


# === Night Mode Lights ===

func _setup_lights() -> void:
	"""Создаёт источники света для NPC машины"""
	const NPCCarLightsScript = preload("res://night_mode/npc_car_lights.gd")
	_lights = NPCCarLightsScript.new()
	add_child(_lights)
	_lights.setup_lights(self)


# === Police emergency: rotating blue beacon + 3D siren ===

## Apply a police emergency mode. SILENT = off; LIGHTS_ONLY = rotating blue beacon, no siren;
## LIGHTS_AND_SIREN = rotating beacon + looping 3D siren. The manager decides the mode (incl.
## the siren cap); this just applies it. duration<0 leaves the timer untouched.
func set_police_emergency_mode(mode: int, duration: float = -1.0) -> void:
	police_emergency_mode = mode
	if duration >= 0.0:
		_emergency_time_left = duration
	match mode:
		PoliceEmergencyMode.SILENT:
			emergency_active = false
			emergency_siren_enabled = false
			_stop_police_siren()
			_hide_police_beacon()
		PoliceEmergencyMode.LIGHTS_ONLY:
			emergency_active = true
			emergency_siren_enabled = false
			_stop_police_siren()
			_ensure_police_beacon()
			if _police_beacon:
				_police_beacon.visible = true
		PoliceEmergencyMode.LIGHTS_AND_SIREN:
			emergency_active = true
			_ensure_police_beacon()
			if _police_beacon:
				_police_beacon.visible = true
			_start_police_siren()


func get_police_emergency_mode() -> int:
	return police_emergency_mode


func is_police_emergency_active() -> bool:
	return emergency_active and police_emergency_mode != PoliceEmergencyMode.SILENT


func has_police_siren_active() -> bool:
	return emergency_siren_enabled and police_emergency_mode == PoliceEmergencyMode.LIGHTS_AND_SIREN


## Full reset to SILENT — MUST be called by the manager on return-to-pool / despawn so a pooled
## (reused) car never inherits a running siren, a spinning beacon, or a stale timer.
func stop_police_emergency() -> void:
	set_police_emergency_mode(PoliceEmergencyMode.SILENT)
	_emergency_time_left = 0.0


## Self-driven beacon spin + duration countdown. Runs in _process (NOT _physics_process) so it
## keeps spinning while the car is physics-frozen for debug/screenshots (we only ever disable
## _physics_process there). Cheap early-out for the non-emergency cars. When the timer runs out
## the car reverts to SILENT itself; the manager's GC pass releases the siren cap next frame.
func _process(delta: float) -> void:
	if not emergency_active:
		return
	if _police_beacon and is_instance_valid(_police_beacon):
		_police_beacon.rotation.y += BEACON_SPIN * delta
	if _emergency_time_left > 0.0:
		_emergency_time_left -= delta
		if _emergency_time_left <= 0.0:
			set_police_emergency_mode(PoliceEmergencyMode.SILENT)


## Build the rotating blue beacon at the roof blue cone: a spinning pivot carrying (a) a SpotLight
## that beams forward + a bit down and sweeps as the pivot spins, and (b) an additive emissive cone
## shell + soft halo so the lamp glows over its dark plastic texture (day & night). v1 = BLUE only.
func _ensure_police_beacon() -> void:
	if _police_beacon != null and is_instance_valid(_police_beacon):
		return
	_police_beacon = Node3D.new()
	_police_beacon.name = "PoliceBeacon"
	add_child(_police_beacon)
	_police_beacon.position = BEACON_LAMP_LOCAL
	# Sweeping beam — blue SpotLight pointing forward (-Z) tilted a bit down; sweeps as the pivot spins.
	_beacon_light = SpotLight3D.new()
	_beacon_light.name = "BeaconBeam"
	_beacon_light.light_color = Color(0.25, 0.45, 1.0)
	_beacon_light.light_energy = 5.0
	_beacon_light.spot_range = 22.0
	_beacon_light.spot_angle = 30.0
	_beacon_light.spot_attenuation = 1.0
	_beacon_light.shadow_enabled = false
	_beacon_light.rotation_degrees = Vector3(BEACON_TILT_DEG, 0.0, 0.0)
	_police_beacon.add_child(_beacon_light)
	# Glowing cone shell over the model's blue cone (additive, unshaded, no depth write so it never
	# z-fights the merged body mesh) — makes the lamp itself read as lit instead of dark plastic.
	var cone := MeshInstance3D.new()
	cone.name = "BeaconGlowCone"
	var cm := CylinderMesh.new()
	cm.top_radius = 0.014
	cm.bottom_radius = 0.05
	cm.height = 0.08
	cm.radial_segments = 16
	cone.mesh = cm
	cone.position = Vector3(0.0, 0.04, 0.0)
	_beacon_glow_mat = _make_beacon_glow_mat(Color(0.35, 0.6, 1.0), Color(0.3, 0.55, 1.0, 0.9), 6.0)
	cone.material_override = _beacon_glow_mat
	cone.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	cone.visibility_range_end = 160.0
	_police_beacon.add_child(cone)
	# Soft halo for bloom around the lamp.
	var halo := MeshInstance3D.new()
	halo.name = "BeaconHalo"
	var hm := SphereMesh.new()
	hm.radius = 0.075
	hm.height = 0.15
	halo.mesh = hm
	halo.position = Vector3(0.0, 0.05, 0.0)
	halo.material_override = _make_beacon_glow_mat(Color(0.25, 0.45, 1.0), Color(0.25, 0.45, 1.0, 0.2), 1.6)
	halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	halo.visibility_range_end = 160.0
	_police_beacon.add_child(halo)


## Additive, unshaded, depth-write-off glow material (shared shape for cone shell + halo).
func _make_beacon_glow_mat(emis: Color, albedo: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	m.albedo_color = albedo
	m.emission_enabled = true
	m.emission = emis
	m.emission_energy_multiplier = energy
	return m


func _hide_police_beacon() -> void:
	if _police_beacon and is_instance_valid(_police_beacon):
		_police_beacon.visible = false


func _start_police_siren() -> void:
	emergency_siren_enabled = true
	if not ResourceLoader.exists(POLICE_SIREN_PATH):
		emergency_siren_enabled = false  # asset missing — lights still work, siren gated
		return
	if _police_siren == null or not is_instance_valid(_police_siren):
		_police_siren = AudioStreamPlayer3D.new()
		_police_siren.name = "PoliceSiren"
		var st: AudioStream = load(POLICE_SIREN_PATH)
		if st is AudioStreamMP3:
			(st as AudioStreamMP3).loop = true  # looping siren (one-shot finished-connect pattern would never fire)
		_police_siren.stream = st
		_police_siren.bus = "SFX"
		_police_siren.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		_police_siren.unit_size = 8.0
		_police_siren.position = Vector3(0.0, 1.0, 0.0)
		add_child(_police_siren)
	_police_siren.max_distance = police_siren_max_distance
	if not _police_siren.playing:
		_police_siren.play()


func _stop_police_siren() -> void:
	emergency_siren_enabled = false
	if _police_siren and is_instance_valid(_police_siren) and _police_siren.playing:
		_police_siren.stop()


func _connect_to_night_mode() -> void:
	"""Подключается к NightModeManager"""
	var scene := get_tree().current_scene
	if scene == null:
		return
	var night_manager := scene.find_child("NightModeManager", true, false)
	if night_manager:
		night_manager.night_mode_changed.connect(_on_night_mode_changed)
		night_manager.rain_changed.connect(_on_rain_changed)
		# Свет включён ночью ИЛИ в дождь (как в example-rain — встречка с фарами)
		_is_night = night_manager.is_night
		_is_raining = night_manager.is_raining
		_refresh_lights()


func _on_night_mode_changed(enabled: bool) -> void:
	_is_night = enabled
	_refresh_lights()


func _on_rain_changed(enabled: bool) -> void:
	_is_raining = enabled
	_refresh_lights()


func _refresh_lights() -> void:
	if _is_night or _is_raining:
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


func _update_wheel_rotation(delta: float) -> void:
	if _wheel_mesh_nodes.is_empty():
		return
	var speed_ms: float = current_speed_kmh / 3.6
	var angular_vel: float = speed_ms / _wheel_radius
	# Spin about the car's ACTUAL lateral axis (world space), so the wheels roll the
	# right way regardless of model orientation. The old local rotate_x(-…) was correct
	# only for models rotated 180° (native -Z); for native +Z models (e.g. Audi TT) it
	# spun the wheels BACKWARDS — invisible on a smooth tire, but the disk spokes gave
	# it away. global_rotate keeps each mesh's origin (= wheel centre) and rotates about
	# the car's +X, so the wheel top rolls toward car-forward (+Z).
	var axis: Vector3 = global_transform.basis.x.normalized()
	var ang: float = angular_vel * delta
	for mesh in _wheel_mesh_nodes:
		if is_instance_valid(mesh):
			mesh.global_rotate(axis, ang)


func _disable_wheel_physics() -> void:
	"""
	ОПТИМИЗАЦИЯ: Отключает физику колес у ВСЕХ NPC.
	VehicleBody3D остается, но колеса не симулируются = 1 physics body вместо 5

	Экономия при 30 NPC: 150 bodies → 30 bodies (-80%)
	"""
	for wheel in wheels_front + wheels_rear:
		if wheel:
			wheel.set_physics_process(false)
			# Скрываем визуальные модели колёс
			for child in wheel.get_children():
				if child is MeshInstance3D:
					child.visible = false


func _merge_meshes() -> void:
	"""Объединяет все mesh NPC модели в один ArrayMesh для минимизации draw calls.
	GLTF модели типа polo имеют 200+ mesh = 200+ draw calls.
	После merge: 1 mesh с несколькими surfaces (по числу уникальных материалов).
	Использует кеш по scene path — merge вычисляется один раз для каждого типа NPC."""
	# Определяем ключ кеша по scene file
	var cache_key: String = scene_file_path
	if cache_key.is_empty():
		cache_key = name  # Fallback

	# Собираем все MeshInstance3D рекурсивно
	var mesh_instances: Array[MeshInstance3D] = []
	_collect_mesh_instances(self, mesh_instances)

	if mesh_instances.size() < 2:
		return  # Нечего объединять (простые box NPC)

	# Разделяем на колёса и кузов — колёса НЕ мержим (они будут вращаться)
	var body_meshes: Array[MeshInstance3D] = []
	for mi in mesh_instances:
		var mname: String = mi.name.to_lower()
		if "wheel" in mname or "tire" in mname or "rim" in mname or "brakedisk" in mname or "brake_disc" in mname:
			_wheel_mesh_nodes.append(mi)
		elif mi.has_meta("npc_keep_unmerged"):
			# Real lamp lens meshes: kept separate & visible so a per-surface emissive
			# override (front white / rear red, set by the car's NPC setup) renders as a
			# lens-shaped glow instead of a rectangular proxy box.
			pass
		else:
			body_meshes.append(mi)

	# Получаем радиус колеса из VehicleWheel3D
	if wheels_front.size() > 0:
		_wheel_radius = wheels_front[0].wheel_radius

	var merged_mesh: ArrayMesh

	if _merged_mesh_cache.has(cache_key):
		# Используем кешированный mesh (мгновенно)
		merged_mesh = _merged_mesh_cache[cache_key].duplicate() as ArrayMesh
	else:
		# Первый NPC этого типа — делаем полный merge (только кузов)
		merged_mesh = _build_merged_mesh(body_meshes)
		if merged_mesh and merged_mesh.get_surface_count() > 0:
			_merged_mesh_cache[cache_key] = merged_mesh

	if not merged_mesh or merged_mesh.get_surface_count() == 0:
		return

	# Скрываем оригинальные mesh кузова (колёса остаются видимыми)
	for mi in body_meshes:
		mi.visible = false

	# Создаём один MeshInstance3D с объединённым mesh
	var merged_instance := MeshInstance3D.new()
	merged_instance.name = "MergedMesh"
	merged_instance.mesh = merged_mesh
	merged_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(merged_instance)


func _build_merged_mesh(mesh_instances: Array[MeshInstance3D]) -> ArrayMesh:
	"""Строит объединённый ArrayMesh из всех видимых mesh instances."""
	# Группируем surfaces по материалу
	var material_groups: Dictionary = {}  # mat_key → {material, surfaces}
	for mi in mesh_instances:
		if not mi.visible:
			continue
		var mesh: Mesh = mi.mesh
		if not mesh:
			continue
		var local_xform: Transform3D = mi.global_transform
		for surf_idx in mesh.get_surface_count():
			var mat: Material = mi.get_active_material(surf_idx)
			var mat_key: int = mat.get_instance_id() if mat else 0
			if not material_groups.has(mat_key):
				material_groups[mat_key] = {"material": mat, "surfaces": []}
			material_groups[mat_key]["surfaces"].append({
				"mesh": mesh,
				"surface_idx": surf_idx,
				"transform": local_xform
			})

	if material_groups.is_empty():
		return null

	var merged_mesh := ArrayMesh.new()
	var inv_self: Transform3D = global_transform.affine_inverse()

	for mat_key in material_groups:
		var group: Dictionary = material_groups[mat_key]
		var mat: Material = group["material"]
		var surfaces: Array = group["surfaces"]

		var all_verts := PackedVector3Array()
		var all_normals := PackedVector3Array()
		var all_uvs := PackedVector2Array()
		var all_indices := PackedInt32Array()

		for surf_data in surfaces:
			var mesh: Mesh = surf_data["mesh"]
			var surf_idx: int = surf_data["surface_idx"]
			var xform: Transform3D = inv_self * surf_data["transform"]

			var arrays: Array = mesh.surface_get_arrays(surf_idx)
			if arrays.is_empty() or arrays[Mesh.ARRAY_VERTEX] == null:
				continue

			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
			var uvs = arrays[Mesh.ARRAY_TEX_UV]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()

			var base_vertex: int = all_verts.size()

			# Трансформируем вершины в локальное пространство NPC
			for v in verts:
				all_verts.append(xform * v)

			# Трансформируем нормали
			var normal_xform: Basis = xform.basis
			if normals.size() == verts.size():
				for n in normals:
					all_normals.append((normal_xform * n).normalized())
			else:
				for _i in verts.size():
					all_normals.append(Vector3.UP)

			# UV
			if uvs != null and uvs.size() == verts.size():
				for uv in uvs:
					all_uvs.append(uv)
			else:
				for _i in verts.size():
					all_uvs.append(Vector2.ZERO)

			# Индексы со смещением
			if indices.size() > 0:
				for idx in indices:
					all_indices.append(idx + base_vertex)
			else:
				for i in verts.size():
					all_indices.append(base_vertex + i)

		if all_verts.is_empty():
			continue

		var surface_arrays: Array = []
		surface_arrays.resize(Mesh.ARRAY_MAX)
		surface_arrays[Mesh.ARRAY_VERTEX] = all_verts
		surface_arrays[Mesh.ARRAY_NORMAL] = all_normals
		surface_arrays[Mesh.ARRAY_TEX_UV] = all_uvs
		surface_arrays[Mesh.ARRAY_INDEX] = all_indices

		merged_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_arrays)
		merged_mesh.surface_set_material(merged_mesh.get_surface_count() - 1, mat)

	return merged_mesh


func _collect_mesh_instances(node: Node, result: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		result.append(node as MeshInstance3D)
	for child in node.get_children():
		_collect_mesh_instances(child, result)
