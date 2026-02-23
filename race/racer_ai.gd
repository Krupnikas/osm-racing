extends VehicleBase
class_name RacerAI

## AI-контроллер для соперников в гоночном режиме
## Наследует VehicleBase для единой физики с игроком
## Использует Pure Pursuit steering для следования по маршруту

enum AIState { FROZEN, RACING, RECOVERING, FINISHED }

# Маршрут гонки
var race_route: RaceRoute
var race_progress: float = 0.0  # Дистанция от старта (метры)
var race_position: int = 0      # Место в гонке (1, 2, 3...)
var current_segment_idx: int = 0  # Текущий сегмент маршрута

# Состояние AI
var ai_state := AIState.FROZEN
var target_speed: float = 50.0  # Целевая скорость в км/ч

# Параметры AI (для вариативности поведения)
@export var skill_level: float = 0.8      # 0.5-1.0, влияет на точность
@export var aggression: float = 0.5       # 0.0-1.0, влияет на скорость в поворотах
@export var racer_name: String = "AI"     # Имя для UI

# Константы Pure Pursuit
const LOOKAHEAD_MIN := 12.0
const LOOKAHEAD_MAX := 35.0
const BRAKE_DISTANCE := 35.0  # Увеличено для раннего обнаружения
const UPDATE_INTERVAL := 0.05  # 50ms - более частое обновление
const CORRIDOR_WIDTH := 7.0  # Ширина коридора (совпадает с RaceBarriers.BARRIER_OFFSET)

# Восстановление после застревания
var stuck_timer: float = 0.0
var recovery_timer: float = 0.0
var recovery_attempts: int = 0
const STUCK_THRESHOLD := 3.0        # Секунд без движения
const STUCK_SPEED := 3.0            # км/ч - считаем застрявшим
const RECOVERY_REVERSE_TIME := 2.0  # Секунд ехать назад
const MAX_RECOVERY_ATTEMPTS := 3    # После этого - респавн

# Raycast для obstacle detection
var obstacle_check_ray: RayCast3D

# Внутренние переменные
var update_timer := 0.0
# Цвета для рандомизации
const RACER_COLORS := [
	Color(0.9, 0.1, 0.1),   # Красный
	Color(0.1, 0.4, 0.9),   # Синий
	Color(0.1, 0.8, 0.2),   # Зелёный
	Color(0.9, 0.6, 0.1),   # Оранжевый
	Color(0.7, 0.1, 0.9),   # Фиолетовый
	Color(0.1, 0.9, 0.9),   # Бирюзовый
	Color(0.9, 0.9, 0.1),   # Жёлтый
	Color(0.9, 0.3, 0.6),   # Розовый
]


func _ready() -> void:
	super._ready()

	# Настраиваем привод (AWD для лучшего контроля)
	for wheel in wheels_front:
		wheel.use_as_traction = true
	for wheel in wheels_rear:
		wheel.use_as_traction = true

	# Создаём raycast для obstacle detection
	# Layer 1 = Player (bit 0 = 1)
	# Layer 2 = Buildings (bit 1 = 2)
	# Layer 3 = Terrain (bit 2 = 4)
	# Layer 4 = NPCTraffic (bit 3 = 8)
	# Layer 8 = RaceOpponents (bit 7 = 128) - НЕ включаем (гонка!)
	obstacle_check_ray = RayCast3D.new()
	obstacle_check_ray.enabled = true
	obstacle_check_ray.collision_mask = 2 | 8  # Здания (2) и NPC трафик (8), не соперники
	obstacle_check_ray.hit_from_inside = false
	add_child(obstacle_check_ray)

	# Добавляем в группу для идентификации
	add_to_group("race_opponent")

	# Рандомизируем параметры AI для вариативности
	skill_level = randf_range(0.85, 1.0)
	aggression = randf_range(0.5, 0.9)
	target_speed = randf_range(70.0, 90.0)


func _physics_process(delta: float) -> void:
	match ai_state:
		AIState.FROZEN:
			# Заморожены до старта - ничего не делаем
			throttle_input = 0.0
			brake_input = 1.0
			steering_input = 0.0

		AIState.RACING:
			# Обновляем AI с интервалом
			update_timer += delta
			if update_timer >= UPDATE_INTERVAL:
				update_timer = 0.0
				_update_ai_driver()

			# Проверяем застревание
			_check_stuck(delta)

		AIState.RECOVERING:
			# Выполняем восстановление
			_execute_recovery(delta)

		AIState.FINISHED:
			# Финишировали - тормозим
			throttle_input = 0.0
			brake_input = 0.5
			steering_input = 0.0

	# Вызываем базовую физику
	_base_physics_process(delta)


# ===== ПУБЛИЧНЫЕ МЕТОДЫ =====

func set_race_route(route: RaceRoute) -> void:
	"""Устанавливает маршрут гонки"""
	race_route = route
	race_progress = 0.0
	current_segment_idx = 0


func freeze_for_countdown() -> void:
	"""Замораживает машину для обратного отсчёта"""
	ai_state = AIState.FROZEN
	freeze = true
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO


func start_racing() -> void:
	"""Начинает гонку"""
	ai_state = AIState.RACING
	freeze = false
	stuck_timer = 0.0
	recovery_attempts = 0

	# Инициализируем начальную позицию на маршруте
	# Это критично - без этого AI застрянет с progress=0
	if race_route:
		var projection := race_route.project_position(global_position, 0)
		current_segment_idx = projection.segment_idx
		race_progress = projection.distance


func finish_race() -> void:
	"""Завершает гонку для этого AI"""
	ai_state = AIState.FINISHED


func get_race_progress() -> float:
	"""Возвращает прогресс по маршруту (дистанция от старта)"""
	return race_progress


# ===== РЕАЛИЗАЦИЯ АБСТРАКТНЫХ МЕТОДОВ VehicleBase =====

func _get_steering_input() -> float:
	return steering_input


func _get_throttle_input() -> float:
	return throttle_input


func _get_brake_input() -> float:
	return brake_input


# ===== AI ЛОГИКА =====

func _update_ai_driver() -> void:
	"""Основная логика AI водителя"""
	if not race_route or race_route.points.is_empty():
		throttle_input = 0.0
		brake_input = 1.0
		steering_input = 0.0
		return

	# Обновляем прогресс по маршруту (только вперёд!)
	_update_race_progress()

	# Проверяем финиш
	if race_route.is_finished(race_progress):
		finish_race()
		return

	# Pure Pursuit steering с адаптивным lookahead
	var speed_factor: float = clamp(current_speed_kmh / 80.0, 0.0, 1.0)
	var lookahead_dist: float = lerp(LOOKAHEAD_MIN, LOOKAHEAD_MAX, speed_factor)

	var lookahead_point: Vector3 = race_route.get_lookahead_point(race_progress, lookahead_dist)

	if lookahead_point != Vector3.ZERO:
		var to_target := lookahead_point - global_position
		var to_target_flat := Vector3(to_target.x, 0, to_target.z).normalized()
		var forward := -global_transform.basis.z
		var forward_flat := Vector3(forward.x, 0, forward.z).normalized()

		# Lateral error через cross product
		var lateral_error := to_target_flat.cross(forward_flat).y

		# Steering пропорционален lateral error
		# skill_level влияет на точность реакции
		# Множитель 2.5 для более агрессивных поворотов
		steering_input = clamp(lateral_error * 2.5 * skill_level, -1.0, 1.0)
	else:
		steering_input = 0.0

	# Проверка препятствий и расчёт объезда (Craig Reynolds steering behaviors)
	var obstacle_data := _check_obstacle_ahead()

	if obstacle_data.detected:
		if obstacle_data.urgency > 0.6:
			# Здание/стена близко — жёсткий override, полностью уходим от препятствия
			steering_input = obstacle_data.avoidance_steering
			throttle_input = 0.3
			brake_input = 0.4
		else:
			# Далёкое препятствие — плавный blend
			var blend_factor: float = 0.3 + obstacle_data.urgency * 0.5
			steering_input = lerp(steering_input, obstacle_data.avoidance_steering, blend_factor)
			steering_input = clamp(steering_input, -1.0, 1.0)

			# Притормаживаем пропорционально urgency
			if obstacle_data.urgency > 0.3:
				throttle_input = lerp(0.7, 0.3, obstacle_data.urgency)
				brake_input = lerp(0.05, 0.3, obstacle_data.urgency)

	# Коррекция для удержания в коридоре маршрута
	# НЕ применяем если obstacle avoidance активен — приоритет безопасности
	var corridor_correction := 0.0
	if not obstacle_data.detected:
		corridor_correction = _calculate_corridor_correction()
		steering_input = clamp(steering_input + corridor_correction, -1.0, 1.0)

	# Контроль скорости (всегда, с учётом поворотов)
	var turn_sharpness := _get_turn_sharpness_ahead()

	# Безопасная скорость для поворота
	# aggression влияет на то, как сильно замедляемся (выше = меньше торможение)
	var safe_speed := target_speed
	if turn_sharpness > 0.4:
		safe_speed = target_speed * lerp(0.85, 0.95, aggression)
	if turn_sharpness > 0.7:
		safe_speed = target_speed * lerp(0.65, 0.8, aggression)
	if turn_sharpness > 0.9:
		safe_speed = target_speed * lerp(0.5, 0.65, aggression)

	# Если нет критического препятствия, применяем нормальный контроль скорости
	if not obstacle_data.detected or obstacle_data.urgency <= 0.7:
		var speed_error: float = safe_speed - current_speed_kmh

		if speed_error < -10.0:
			# Сильно превышаем - тормозим
			throttle_input = 0.0
			brake_input = clamp(-speed_error / 30.0, 0.2, 0.6)
		elif speed_error < 0.0:
			# Немного превышаем - отпускаем газ
			throttle_input = 0.1
			brake_input = 0.0
		else:
			# Ускоряемся агрессивно
			throttle_input = clamp(speed_error / 8.0, 0.3, 1.0)
			brake_input = 0.0


func _update_race_progress() -> void:
	"""Обновляет прогресс по маршруту (только вперёд!)"""
	if not race_route:
		return

	# Проецируем позицию на маршрут, начиная от текущего сегмента
	var projection := race_route.project_position(global_position, current_segment_idx)

	# Обновляем только если прогресс увеличился (НЕ возвращаемся)
	if projection.distance > race_progress:
		race_progress = projection.distance
		current_segment_idx = projection.segment_idx


func _get_turn_sharpness_ahead() -> float:
	"""Определяет крутизну поворота впереди (0.0 = прямо, 1.0 = разворот)"""
	if not race_route or race_route.points.size() < 2:
		return 0.0

	var forward := -global_transform.basis.z
	var forward_flat := Vector3(forward.x, 0, forward.z).normalized()

	var max_angle := 0.0

	# Смотрим на 30м вперёд
	var check_distances := [10.0, 20.0, 30.0]
	for dist in check_distances:
		var point_data := race_route.get_point_at_distance(race_progress + dist)
		var point_dir := Vector3(point_data.direction.x, 0, point_data.direction.z).normalized()

		if point_dir.length() > 0.1:
			var angle := forward_flat.angle_to(point_dir)
			max_angle = max(max_angle, angle)

	# Нормализуем угол к [0..1] (90° = 1.0)
	return clamp(max_angle / (PI / 2.0), 0.0, 1.0)


func _calculate_corridor_correction() -> float:
	"""Коррекция руления для удержания в коридоре маршрута.
	Определяет с какой стороны от маршрута AI и толкает к центру."""
	if not race_route:
		return 0.0

	# Проецируем позицию на маршрут
	var projection := race_route.project_position(global_position, current_segment_idx)
	var lateral_dist: float = projection.lateral_offset  # Всегда положительное расстояние

	# Определяем СТОРОНУ: cross product направления маршрута и вектора к AI
	var route_data: Dictionary = race_route.get_point_at_distance(projection.distance)
	var route_pos: Vector3 = route_data.position
	var route_dir: Vector3 = route_data.direction
	var to_ai := global_position - route_pos
	# cross.y > 0 → AI справа от маршрута, < 0 → слева
	var side_sign: float = sign(route_dir.cross(to_ai).y)

	# Порог - 40% от ширины коридора
	var threshold := CORRIDOR_WIDTH * 0.4

	if lateral_dist > threshold:
		var excess: float = lateral_dist - threshold
		var max_excess: float = CORRIDOR_WIDTH * 0.6
		var correction_strength: float = clamp(excess / max_excess, 0.0, 1.0) * 0.6
		# Рулим В СТОРОНУ маршрута (противоположно стороне AI)
		return -side_sign * correction_strength

	return 0.0


func _check_obstacle_ahead() -> Dictionary:
	"""Проверяет наличие препятствия впереди и возвращает данные для объезда.
	Использует метод Craig Reynolds - латеральная сила направлена ОТ препятствия."""
	var result := {"detected": false, "avoidance_steering": 0.0, "urgency": 0.0}

	var speed_kmh: float = max(10.0, current_speed_kmh)
	# Дистанция проверки: короткая, чтобы не реагировать на далёкие здания вдоль дороги
	var check_distance: float = clamp(speed_kmh * 0.4, 8.0, 25.0)

	var from := global_position + Vector3(0, 1.0, 0)
	var forward := -global_transform.basis.z
	forward.y = 0
	forward = forward.normalized()
	var right := forward.cross(Vector3.UP).normalized()

	# 3 луча: центральный и боковые (без крайних — они ловят здания сбоку от дороги)
	var rays := [
		{"dir": forward, "weight": 1.0},                                # Центр
		{"dir": (forward + right * 0.3).normalized(), "weight": 0.9},   # Немного справа
		{"dir": (forward - right * 0.3).normalized(), "weight": 0.9},   # Немного слева
	]

	var closest_distance := INF
	var obstacle_side := 0.0  # < 0 = слева, > 0 = справа

	for ray_data in rays:
		obstacle_check_ray.global_position = from
		obstacle_check_ray.target_position = ray_data.dir * check_distance
		obstacle_check_ray.force_raycast_update()

		if obstacle_check_ray.is_colliding():
			var hit_point := obstacle_check_ray.get_collision_point()
			var distance := from.distance_to(hit_point)

			if distance < closest_distance:
				closest_distance = distance
				result.detected = true

				# Определяем с какой стороны препятствие
				var to_obstacle := (hit_point - from).normalized()
				obstacle_side = right.dot(to_obstacle)  # + = справа, - = слева

	if result.detected:
		# Urgency: 1.0 = очень близко, 0.0 = далеко
		# Используем квадратичную функцию для более резкой реакции вблизи
		var raw_urgency: float = clamp(1.0 - (closest_distance / check_distance), 0.0, 1.0)
		var urgency: float = raw_urgency * raw_urgency  # Квадрат для нелинейности
		result.urgency = raw_urgency  # Но для blend используем линейный

		# Avoidance steering: руль В ПРОТИВОПОЛОЖНУЮ сторону от препятствия
		# Если препятствие справа (obstacle_side > 0), рулим влево (steering > 0)
		# Если препятствие слева (obstacle_side < 0), рулим вправо (steering < 0)
		# Умеренная сила объезда для плавных дуг
		var avoidance_strength: float = (0.3 + urgency * 0.5)
		result.avoidance_steering = -sign(obstacle_side) * clamp(avoidance_strength, 0.0, 0.8)

		# Если препятствие прямо по центру - выбираем сторону на основе текущего руления или маршрута
		if abs(obstacle_side) < 0.4:
			# Объезжаем в сторону куда уже рулим, или влево по умолчанию
			var preferred_side: float = 1.0  # По умолчанию влево
			if abs(steering_input) > 0.1:
				preferred_side = sign(steering_input)
			result.avoidance_steering = preferred_side * clamp(avoidance_strength, 0.0, 0.8)

	return result


# ===== СИСТЕМА ВОССТАНОВЛЕНИЯ =====

func _check_stuck(delta: float) -> void:
	"""Проверяет, застряла ли машина"""
	if current_speed_kmh < STUCK_SPEED:
		stuck_timer += delta
		if stuck_timer > STUCK_THRESHOLD:
			_start_recovery()
	else:
		stuck_timer = 0.0
		recovery_attempts = 0


func _start_recovery() -> void:
	"""Начинает процедуру восстановления"""
	recovery_attempts += 1

	if recovery_attempts > MAX_RECOVERY_ATTEMPTS:
		# Слишком много попыток - респавн на трассу
		_respawn_on_track()
	else:
		# Пробуем выехать задом
		ai_state = AIState.RECOVERING
		recovery_timer = RECOVERY_REVERSE_TIME
		print("RacerAI: ", racer_name, " starting recovery attempt ", recovery_attempts)


func _execute_recovery(delta: float) -> void:
	"""Выполняет процедуру восстановления (едем задом)"""
	recovery_timer -= delta

	if recovery_timer > 0:
		# Едем назад
		throttle_input = 0.0
		brake_input = 0.0
		# Включаем задний ход через отрицательный throttle (если поддерживается)
		# Или просто откатываемся
		steering_input = randf_range(-0.5, 0.5)  # Случайный поворот

		# Применяем силу назад
		var backward := global_transform.basis.z
		apply_central_force(backward * 3000.0)
	else:
		# Восстановление завершено
		ai_state = AIState.RACING
		stuck_timer = 0.0


func _respawn_on_track() -> void:
	"""Телепортирует машину обратно на трассу"""
	if not race_route or race_route.points.is_empty():
		return

	print("RacerAI: ", racer_name, " respawning on track at progress ", race_progress)

	# Находим точку на маршруте немного позади текущего прогресса
	var respawn_distance: float = max(0.0, race_progress - 20.0)
	var point_data: Dictionary = race_route.get_point_at_distance(respawn_distance)

	# Телепортируем
	global_position = point_data.position + Vector3(0, 1.5, 0)

	# Поворачиваем в направлении движения
	var dir: Vector3 = point_data.direction
	if dir.length() > 0.1:
		var yaw := atan2(dir.x, dir.z)
		global_rotation = Vector3(0, yaw, 0)

	# Сбрасываем физику
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO

	# Возвращаемся к гонке
	ai_state = AIState.RACING
	stuck_timer = 0.0
	recovery_attempts = 0


# ===== ВИЗУАЛЬНЫЕ НАСТРОЙКИ =====

func randomize_appearance() -> void:
	"""Рандомизирует внешний вид машины"""
	var color: Color = RACER_COLORS[randi() % RACER_COLORS.size()]
	_apply_body_color(color)


func _apply_body_color(color: Color) -> void:
	"""Применяет цвет к кузову машины"""
	# Ищем все MeshInstance3D и применяем цвет к материалам кузова
	for child in get_children():
		if child is MeshInstance3D:
			var mesh_instance := child as MeshInstance3D
			if mesh_instance.name.to_lower().contains("body") or \
			   mesh_instance.name.to_lower().contains("chassis") or \
			   mesh_instance.name.to_lower().contains("hood"):
				var mat := StandardMaterial3D.new()
				mat.albedo_color = color
				mat.metallic = 0.6
				mat.roughness = 0.35
				mesh_instance.material_override = mat
