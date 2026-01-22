extends VehicleBody3D
class_name VehicleBase

## Базовый класс для всех транспортных средств
## Содержит общую физику колёс, двигателя, рулежки и трансмиссии
##
## Наследники должны переопределить:
## - _get_steering_input() - возвращает [-1.0 .. 1.0]
## - _get_throttle_input() - возвращает [0.0 .. 1.0]
## - _get_brake_input() - возвращает [0.0 .. 1.0]
##
## И вызывать _base_physics_process(delta) в своём _physics_process

# ===== ЭКСПОРТИРУЕМЫЕ ПАРАМЕТРЫ =====

## Физика двигателя
@export_group("Engine")
@export var max_engine_power := 450.0  ## Максимальная мощность двигателя (Н·м)
@export var max_rpm := 7000.0  ## Максимальные обороты
@export var idle_rpm := 900.0  ## Обороты холостого хода
@export var gear_ratios: Array[float] = [-3.5, 0.0, 3.5, 2.2, 1.4, 1.0, 0.8]  ## Передаточные числа (R, N, 1-5)
@export var final_drive := 3.7  ## Главная передача

## Рулевое управление
@export_group("Steering")
@export var max_steering_angle := 35.0  ## Максимальный угол поворота колёс (градусы)
@export var steering_speed := 3.0  ## Скорость поворота руля
@export var steering_return_speed := 5.0  ## Скорость возврата руля

## Тормоза
@export_group("Brakes")
@export var brake_force := 30.0  ## Сила основных тормозов

# ===== ВНУТРЕННЕЕ СОСТОЯНИЕ =====

# Колёса
var wheels_front: Array[VehicleWheel3D] = []
var wheels_rear: Array[VehicleWheel3D] = []

# Трансмиссия
var current_gear := 2  # 0=R, 1=N, 2-6=1-5 передачи
var current_rpm := 0.0
var current_speed_kmh := 0.0

# Временные переменные для управления (заполняются наследниками)
var steering_input := 0.0
var throttle_input := 0.0
var brake_input := 0.0


# ===== LIFECYCLE =====

func _ready() -> void:
	_collect_wheels()


# ===== АБСТРАКТНЫЕ МЕТОДЫ (для переопределения в наследниках) =====

func _get_steering_input() -> float:
	"""Возвращает текущий input рулежки [-1.0 .. 1.0]
	Должен быть переопределён в наследниках"""
	return 0.0


func _get_throttle_input() -> float:
	"""Возвращает текущий input газа [0.0 .. 1.0]
	Должен быть переопределён в наследниках"""
	return 0.0


func _get_brake_input() -> float:
	"""Возвращает текущий input тормоза [0.0 .. 1.0]
	Должен быть переопределён в наследниках"""
	return 0.0


# ===== ОБЩИЕ МЕТОДЫ ФИЗИКИ =====

func _collect_wheels() -> void:
	"""Собирает все VehicleWheel3D в массивы по типу"""
	for child in get_children():
		if child is VehicleWheel3D:
			if child.use_as_steering:
				wheels_front.append(child)
			else:
				wheels_rear.append(child)


func _update_speed() -> void:
	"""Обновляет текущую скорость в км/ч"""
	var velocity_local := linear_velocity.length()
	current_speed_kmh = velocity_local * 3.6


func get_speed_kmh() -> float:
	"""Возвращает текущую скорость в км/ч"""
	return current_speed_kmh


func _apply_steering(delta: float) -> void:
	"""Применяет рулежку с учётом скорости"""
	# Максимальный угол уменьшается на скорости
	var speed_factor: float = clamp(1.0 - current_speed_kmh / 200.0, 0.3, 1.0)
	var max_steer: float = deg_to_rad(max_steering_angle) * speed_factor

	# Целевой угол
	var target_steer: float = steering_input * max_steer

	# Скорость поворота руля
	var steer_speed: float
	if abs(steering_input) > 0.1:
		steer_speed = steering_speed
	else:
		steer_speed = steering_return_speed

	steering = lerp(steering, target_steer, steer_speed * delta)


func _apply_forces() -> void:
	"""Применяет силы двигателя и тормозов"""
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
	brake = brake_input * brake_force


func _get_torque_curve(rpm_normalized: float) -> float:
	"""Возвращает множитель крутящего момента [0.0 .. 1.0] по RPM

	Простая кривая крутящего момента:
	- Низкие обороты (< 0.2): слабый крутящий момент (0.4-0.8)
	- Средние обороты (0.2-0.6): нарастание до пика (0.8-1.0)
	- Высокие обороты (> 0.6): падение мощности (1.0-0.7)
	"""
	if rpm_normalized < 0.2:
		return lerp(0.4, 0.8, rpm_normalized / 0.2)
	elif rpm_normalized < 0.6:
		return lerp(0.8, 1.0, (rpm_normalized - 0.2) / 0.4)
	else:
		return lerp(1.0, 0.7, (rpm_normalized - 0.6) / 0.4)


func _auto_shift() -> void:
	"""Автоматическое переключение передач"""
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
	var shift_up_rpm := max_rpm * 0.85
	var shift_down_rpm := max_rpm * 0.3

	if current_rpm > shift_up_rpm and current_gear < gear_ratios.size() - 1:
		current_gear += 1  # Повышаем передачу
	elif current_rpm < shift_down_rpm and current_gear > 2:
		current_gear -= 1  # Понижаем передачу


func _get_average_wheel_rpm() -> float:
	"""Возвращает среднее значение RPM ведущих колёс"""
	if wheels_rear.is_empty():
		return 0.0

	var avg_rotation := 0.0
	for wheel in wheels_rear:
		avg_rotation += abs(wheel.get_rpm())

	return avg_rotation / wheels_rear.size()


# ===== PHYSICS UPDATE =====

func _base_physics_process(delta: float) -> void:
	"""Базовая физика - вызывается наследниками в их _physics_process

	Обрабатывает:
	- Получение input от наследников
	- Обновление скорости
	- Применение рулежки
	- Применение сил двигателя и тормозов
	- Автоматическое переключение передач
	"""
	# Получаем input от наследников
	steering_input = _get_steering_input()
	throttle_input = _get_throttle_input()
	brake_input = _get_brake_input()

	# Обновляем физику
	_update_speed()
	_apply_steering(delta)
	_apply_forces()
	_auto_shift()
