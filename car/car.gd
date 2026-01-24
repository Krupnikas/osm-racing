extends VehicleBase
class_name Car

## Автомобиль игрока с управлением от клавиатуры
## Наследуется от VehicleBase для общей физики
##
## Дополнительные возможности:
## - Ручной тормоз
## - TCS (антипробуксовочная система)
## - ESC (система стабилизации)
## - Тип привода (RWD/FWD/AWD)

## Настройки тормозов (дополнительные)
@export_group("Brakes")
@export var handbrake_force := 50.0  ## Сила ручного тормоза

## Автоматическая КПП
@export_group("Transmission")
@export var auto_transmission := true  ## Автоматическая КПП

## Настройки привода
@export_group("Drivetrain")
@export_enum("RWD", "FWD", "AWD") var drive_type := 2  ## 0=RWD, 1=FWD, 2=AWD
@export var awd_front_bias := 0.4  ## Распределение момента на переднюю ось (AWD)

## Настройки стабилизации
@export_group("Stability")
@export var traction_control := true  ## Антипробуксовочная система
@export var stability_control := true  ## Система стабилизации
@export var tc_slip_threshold := 0.3  ## Порог срабатывания TCS
@export var sc_angle_threshold := 30.0  ## Порог срабатывания ESC (градусы)
@export var anti_roll_bar := true  ## Стабилизатор поперечной устойчивости
@export var anti_roll_strength := 8000.0  ## Сила стабилизатора

# Внутренние переменные (специфичные для player car)
var handbrake_input := 0.0

# Ссылка на освещение
var _car_lights: Node3D

# Сигналы для UI
signal speed_changed(speed_kmh: float)
signal rpm_changed(rpm: float)
signal gear_changed(gear: int)


func _ready() -> void:
	# Вызываем базовый _ready (собирает колёса)
	super._ready()

	# Настраиваем привод
	_setup_drivetrain()

	# Добавляем в группу для поиска
	add_to_group("car")

	# Подключаемся к NightModeManager
	await get_tree().process_frame
	_setup_night_mode_connection()


func _setup_drivetrain() -> void:
	match drive_type:
		0:  # RWD
			for wheel in wheels_front:
				wheel.use_as_traction = false
			for wheel in wheels_rear:
				wheel.use_as_traction = true
		1:  # FWD
			for wheel in wheels_front:
				wheel.use_as_traction = true
			for wheel in wheels_rear:
				wheel.use_as_traction = false
		2:  # AWD
			for wheel in wheels_front:
				wheel.use_as_traction = true
			for wheel in wheels_rear:
				wheel.use_as_traction = true


func _physics_process(delta: float) -> void:
	_handle_input()

	# Вызываем базовую физику (скорость, руление, силы, auto-shift)
	_base_physics_process(delta)

	# Player-specific: engine RPM simulation
	_update_engine(delta)

	# Player-specific: stability systems
	_apply_stability_control(delta)


func _handle_input() -> void:
	# Газ/тормоз
	var accel := Input.get_action_strength("ui_up")
	var decel := Input.get_action_strength("ui_down")

	throttle_input = accel
	brake_input = decel

	# Задний ход при остановке и нажатии назад
	if current_speed_kmh < 5.0 and decel > 0 and accel == 0:
		if current_gear != 0:
			current_gear = 0
			gear_changed.emit(current_gear)
		throttle_input = decel
		brake_input = 0.0
	elif current_gear == 0 and accel > 0:
		current_gear = 2
		gear_changed.emit(current_gear)

	# Руление
	steering_input = Input.get_axis("ui_right", "ui_left")

	# Ручной тормоз
	handbrake_input = 1.0 if Input.is_action_pressed("ui_accept") else 0.0


# ===== РЕАЛИЗАЦИЯ АБСТРАКТНЫХ МЕТОДОВ VehicleBase =====

func _get_steering_input() -> float:
	"""Возвращает текущий steering input от клавиатуры"""
	return steering_input


func _get_throttle_input() -> float:
	"""Возвращает текущий throttle input от клавиатуры"""
	return throttle_input


func _get_brake_input() -> float:
	"""Возвращает текущий brake input (обычный или ручной тормоз)"""
	if handbrake_input > 0.1:
		return handbrake_input * handbrake_force / brake_force
	return brake_input




func _update_engine(delta: float) -> void:
	"""Player-specific: более детальная симуляция RPM с эффектами газа"""
	if current_gear == 1:  # Нейтраль
		current_rpm = lerp(current_rpm, idle_rpm + throttle_input * 3000.0, delta * 5.0)
	else:
		# Рассчитываем обороты от скорости
		var gear_ratio: float = gear_ratios[current_gear]
		var wheel_rpm := _get_average_wheel_rpm()

		var engine_rpm: float = wheel_rpm * abs(gear_ratio) * final_drive
		engine_rpm = clamp(engine_rpm, idle_rpm, max_rpm)

		# Плавное изменение оборотов
		current_rpm = lerp(current_rpm, engine_rpm, delta * 10.0)

	current_rpm = clamp(current_rpm, idle_rpm, max_rpm)
	rpm_changed.emit(current_rpm)

	# Эмитим сигнал скорости (после обновления в base)
	speed_changed.emit(current_speed_kmh)






func _apply_stability_control(_delta: float) -> void:
	"""Player-specific: ESC система стабилизации"""
	if not stability_control:
		return

	# Получаем угловую скорость по Y (рысканье)
	var yaw_rate := angular_velocity.y

	# Если машина вращается слишком быстро
	if abs(yaw_rate) > deg_to_rad(sc_angle_threshold):
		# Применяем тормозную силу для стабилизации
		var correction: float = sign(yaw_rate) * 0.3
		apply_torque(Vector3(0, -correction * mass, 0))


# Переопределяем auto_shift чтобы эмитить сигнал
func _auto_shift() -> void:
	var old_gear := current_gear
	super._auto_shift()  # Вызываем базовый метод
	if current_gear != old_gear:
		gear_changed.emit(current_gear)


# Публичные методы для внешнего доступа
func get_speed_kmh() -> float:
	return current_speed_kmh


func get_rpm() -> float:
	return current_rpm


func get_gear() -> int:
	return current_gear


func get_gear_name() -> String:
	match current_gear:
		0: return "R"
		1: return "N"
		_: return str(current_gear - 1)


func reset_position(pos: Vector3, rot: Vector3 = Vector3.ZERO) -> void:
	global_position = pos
	rotation = rot
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO


func _setup_night_mode_connection() -> void:
	# Ищем CarLights
	_car_lights = find_child("CarLights", false)

	# Ищем NightModeManager
	var night_manager := get_tree().current_scene.find_child("NightModeManager", true, false)
	if night_manager:
		night_manager.night_mode_changed.connect(_on_night_mode_changed)
		# Если уже ночь - включаем свет
		if night_manager.is_night:
			_on_night_mode_changed(true)


func _on_night_mode_changed(enabled: bool) -> void:
	if _car_lights and _car_lights.has_method("enable_lights"):
		if enabled:
			_car_lights.enable_lights()
		else:
			_car_lights.disable_lights()


func is_braking() -> bool:
	return brake_input > 0.1
