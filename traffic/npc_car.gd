extends VehicleBody3D
class_name NPCCar

## AI-контролируемый автомобиль для трафика
## Использует Pure Pursuit steering для следования по waypoint path

enum AIState { DRIVING, STOPPED, YIELDING }

# AI navigation
var waypoint_path: Array = []  # Array[RoadNetwork.Waypoint]
var current_waypoint_index: int = 0
var target_speed: float = 30.0

# AI parameters
const LOOKAHEAD_MIN := 8.0  # Минимальный lookahead
const LOOKAHEAD_MAX := 20.0  # Максимальный lookahead
const BRAKE_DISTANCE := 12.0  # Дистанция торможения
const FOLLOWING_DISTANCE := 10.0  # Дистанция следования за препятствием
const CAUTIOUS_FACTOR := 0.8  # Множитель скорости (осторожное вождение)
const UPDATE_INTERVAL := 0.1  # Интервал обновления AI (100ms)
const CAR_WIDTH := 2.0  # Ширина машины в метрах
const RIGHT_LANE_OFFSET := 1.2  # Смещение вправо от центра (чуть больше полкорпуса)

# Vehicle parameters (слабее чем player car)
@export var max_engine_power := 150.0
@export var max_rpm := 6000.0
@export var idle_rpm := 900.0
@export var gear_ratios: Array[float] = [-3.5, 0.0, 3.5, 2.2, 1.4, 1.0, 0.8]
@export var final_drive := 3.7
@export var max_steering_angle := 30.0  # Более осторожное руление
@export var steering_speed := 3.0
@export var steering_return_speed := 5.0
@export var brake_force := 30.0

# Internal state
var ai_state := AIState.DRIVING
var update_timer := 0.0
var current_gear := 2  # Стартуем с 1й передачи
var current_rpm := 0.0
var current_speed_kmh := 0.0
var throttle_input := 0.0
var steering_input := 0.0
var brake_input := 0.0

# Raycast для obstacle detection
var obstacle_check_ray: RayCast3D
var spawn_grace_timer := 0.0  # Grace period after spawn

# Wheels references
var wheels_front: Array[VehicleWheel3D] = []
var wheels_rear: Array[VehicleWheel3D] = []

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
	# Находим колёса
	for child in get_children():
		if child is VehicleWheel3D:
			if child.use_as_steering:
				wheels_front.append(child)
			else:
				wheels_rear.append(child)

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


func _physics_process(delta: float) -> void:
	# Обновляем grace timer
	if spawn_grace_timer > 0.0:
		spawn_grace_timer -= delta

	# Обновляем AI с интервалом
	update_timer += delta
	if update_timer >= UPDATE_INTERVAL:
		update_timer = 0.0
		_update_ai_driver()

	# Применяем управление каждый frame
	_update_speed()
	_apply_steering(delta)
	_apply_forces()
	_auto_shift()

	# Debug: если застряли на месте слишком долго, сбрасываем состояние
	if current_speed_kmh < 1.0 and ai_state == AIState.STOPPED:
		if randf() < 0.01:  # 1% шанс каждый frame
			ai_state = AIState.DRIVING


func _update_ai_driver() -> void:
	"""Основная логика AI водителя"""
	if waypoint_path.is_empty():
		# Нет пути - стоим
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
		var to_target_flat := Vector3(to_target.x, 0, to_target.z).normalized()
		var forward := -global_transform.basis.z
		var forward_flat := Vector3(forward.x, 0, forward.z).normalized()

		# Вычисляем lateral error через cross product (только Y компонента)
		var lateral_error := to_target_flat.cross(forward_flat).y

		# Проверяем что lookahead достаточно далеко
		var distance_to_lookahead := global_position.distance_to(lookahead_point)
		if distance_to_lookahead < 2.0:
			# Слишком близко - едем прямо
			steering_input = 0.0
		else:
			# Steering пропорционален lateral error с ограничением
			steering_input = clamp(lateral_error * 1.5, -1.0, 1.0)
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
	"""Находит lookahead point на пути на заданном расстоянии, со смещением вправо"""
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
			if i > current_waypoint_index:
				var prev_wp = waypoint_path[i - 1]
				direction = (wp_pos - prev_wp.position).normalized()
				center_point = prev_wp.position + direction * remaining
			else:
				center_point = wp_pos
				direction = wp.direction

			# Вычисляем вектор вправо (для правостороннего движения)
			var right_vector := Vector3(-direction.z, 0, direction.x).normalized()
			return center_point + right_vector * RIGHT_LANE_OFFSET

		accumulated_dist += dist_to_wp
		current_pos = wp_pos

	# Если дошли до конца пути - возвращаем последний waypoint со смещением
	if waypoint_path.size() > 0:
		var last_wp = waypoint_path[-1]
		var right_vector := Vector3(-last_wp.direction.z, 0, last_wp.direction.x).normalized()
		return last_wp.position + right_vector * RIGHT_LANE_OFFSET

	return Vector3.ZERO


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
	if waypoint_path.is_empty() or current_waypoint_index >= waypoint_path.size() - 2:
		return 0.0

	# Берём 3-5 waypoints вперёд для анализа
	var look_distance := 25.0  # Смотрим на 25м вперёд
	var forward := -global_transform.basis.z
	var forward_flat := Vector3(forward.x, 0, forward.z).normalized()

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
	else:
		target_speed = 30.0


func randomize_color() -> void:
	"""Устанавливает случайный цвет кузова"""
	var color: Color = NPC_COLORS[randi() % NPC_COLORS.size()]

	# Применяем цвет к видимым частям кузова
	if has_node("Chassis"):
		var chassis = get_node("Chassis")
		if chassis.material_override:
			chassis.material_override.albedo_color = color
		else:
			var mat = StandardMaterial3D.new()
			mat.albedo_color = color
			mat.metallic = 0.7
			mat.roughness = 0.3
			chassis.material_override = mat

	if has_node("Hood"):
		var hood = get_node("Hood")
		if hood.material_override:
			hood.material_override.albedo_color = color
		else:
			var mat = StandardMaterial3D.new()
			mat.albedo_color = color
			mat.metallic = 0.7
			mat.roughness = 0.3
			hood.material_override = mat


# === Методы из Car (переиспользование физики) ===

func _update_speed() -> void:
	var velocity_local := linear_velocity.length()
	current_speed_kmh = velocity_local * 3.6


func get_speed_kmh() -> float:
	return current_speed_kmh


func _apply_steering(delta: float) -> void:
	# Максимальный угол уменьшается на скорости
	var speed_factor: float = clamp(1.0 - current_speed_kmh / 200.0, 0.3, 1.0)
	var max_steer: float = deg_to_rad(max_steering_angle) * speed_factor

	# Целевой угол
	var target_steer: float = steering_input * max_steer

	# Скорость поворота
	var steer_speed: float
	if abs(steering_input) > 0.1:
		steer_speed = steering_speed
	else:
		steer_speed = steering_return_speed

	steering = lerp(steering, target_steer, steer_speed * delta)


func _apply_forces() -> void:
	if current_gear == 1:  # Нейтраль
		engine_force = 0.0
	else:
		# Расчёт силы от двигателя
		var gear_ratio: float = gear_ratios[current_gear]
		var rpm_factor := _get_torque_curve(current_rpm / max_rpm)
		var torque := max_engine_power * rpm_factor * throttle_input

		# Сила на колёсах
		var wheel_force := torque * gear_ratio * final_drive

		# Ограничение по оборотам
		if current_rpm >= max_rpm * 0.98:
			wheel_force *= 0.5

		engine_force = wheel_force

	# Тормоза
	if brake_input > 0:
		brake = brake_force * brake_input
	else:
		brake = 0.0


func _get_torque_curve(rpm_normalized: float) -> float:
	# Простая кривая крутящего момента
	if rpm_normalized < 0.2:
		return lerp(0.4, 0.8, rpm_normalized / 0.2)
	elif rpm_normalized < 0.6:
		return lerp(0.8, 1.0, (rpm_normalized - 0.2) / 0.4)
	else:
		return lerp(1.0, 0.7, (rpm_normalized - 0.6) / 0.4)


func _auto_shift() -> void:
	"""Автоматическая коробка передач"""
	if current_gear == 0:  # Reverse
		if current_speed_kmh < 2.0:
			current_gear = 2  # Переход на 1ю
		return

	if current_gear == 1:  # Neutral
		current_gear = 2
		return

	# Forward gears (2-6 = 1-5)
	# Упрощенная логика переключения
	var wheel_rpm := _get_average_wheel_rpm()
	var engine_rpm: float = wheel_rpm * abs(gear_ratios[current_gear]) * final_drive

	current_rpm = clamp(engine_rpm, idle_rpm, max_rpm)

	# Переключаем передачи на базе RPM
	if current_rpm > max_rpm * 0.85 and current_gear < 6:
		current_gear += 1  # Повышаем передачу
	elif current_rpm < max_rpm * 0.3 and current_gear > 2:
		current_gear -= 1  # Понижаем передачу


func _get_average_wheel_rpm() -> float:
	"""Возвращает среднее значение RPM ведущих колёс"""
	if wheels_rear.is_empty():
		return 0.0

	var avg_rotation := 0.0
	for wheel in wheels_rear:
		avg_rotation += abs(wheel.get_rpm())

	return avg_rotation / wheels_rear.size()


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

		new_waypoints.append(next)
		current = next

	# Добавляем новые waypoints к существующему пути
	waypoint_path.append_array(new_waypoints)
