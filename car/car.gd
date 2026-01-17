extends VehicleBody3D
class_name Car

## Настройки двигателя
@export_group("Engine")
@export var max_engine_power := 300.0  ## Максимальная мощность двигателя (Н·м)
@export var max_rpm := 7000.0  ## Максимальные обороты
@export var idle_rpm := 900.0  ## Обороты холостого хода
@export var gear_ratios: Array[float] = [-3.5, 0.0, 3.5, 2.2, 1.4, 1.0, 0.8]  ## Передаточные числа (R, N, 1-5)
@export var final_drive := 3.7  ## Главная передача
@export var auto_transmission := true  ## Автоматическая КПП

## Настройки управления
@export_group("Steering")
@export var max_steering_angle := 35.0  ## Максимальный угол поворота колёс (градусы)
@export var steering_speed := 3.0  ## Скорость поворота руля
@export var steering_return_speed := 5.0  ## Скорость возврата руля

## Настройки тормозов
@export_group("Brakes")
@export var brake_force := 30.0  ## Сила основных тормозов
@export var handbrake_force := 50.0  ## Сила ручного тормоза

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

# Внутренние переменные
var current_gear := 1  # 0=R, 1=N, 2-6=1-5 передачи
var current_rpm := 0.0
var current_speed_kmh := 0.0
var throttle_input := 0.0
var steering_input := 0.0
var brake_input := 0.0
var handbrake_input := 0.0

# Ссылки на колёса
var wheels_front: Array[VehicleWheel3D] = []
var wheels_rear: Array[VehicleWheel3D] = []

# Сигналы для UI
signal speed_changed(speed_kmh: float)
signal rpm_changed(rpm: float)
signal gear_changed(gear: int)


func _ready() -> void:
	# Находим колёса
	for child in get_children():
		if child is VehicleWheel3D:
			if child.use_as_steering:
				wheels_front.append(child)
			else:
				wheels_rear.append(child)

	# Настраиваем привод
	_setup_drivetrain()

	# Добавляем в группу для поиска
	add_to_group("car")


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
	_update_speed()
	_update_engine(delta)
	_apply_steering(delta)
	_apply_forces()
	_apply_stability_control(delta)

	# Auto transmission
	if auto_transmission:
		_auto_shift()


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


func _update_speed() -> void:
	# Скорость в км/ч
	var velocity_local := linear_velocity.length()
	current_speed_kmh = velocity_local * 3.6
	speed_changed.emit(current_speed_kmh)


func _update_engine(delta: float) -> void:
	if current_gear == 1:  # Нейтраль
		current_rpm = lerp(current_rpm, idle_rpm + throttle_input * 3000.0, delta * 5.0)
	else:
		# Рассчитываем обороты от скорости
		var gear_ratio: float = gear_ratios[current_gear]
		var wheel_rpm := 0.0

		if wheels_rear.size() > 0:
			# Средняя угловая скорость ведущих колёс
			var avg_rotation := 0.0
			for wheel in wheels_rear:
				avg_rotation += abs(wheel.get_rpm())
			avg_rotation /= wheels_rear.size()
			wheel_rpm = avg_rotation

		var engine_rpm: float = wheel_rpm * abs(gear_ratio) * final_drive
		engine_rpm = clamp(engine_rpm, idle_rpm, max_rpm)

		# Плавное изменение оборотов
		current_rpm = lerp(current_rpm, engine_rpm, delta * 10.0)

	current_rpm = clamp(current_rpm, idle_rpm, max_rpm)
	rpm_changed.emit(current_rpm)


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

		# Применяем TCS
		if traction_control:
			wheel_force = _apply_traction_control(wheel_force)

		engine_force = wheel_force

	# Тормоза
	if brake_input > 0:
		brake = brake_force * brake_input
	elif handbrake_input > 0:
		brake = handbrake_force * handbrake_input
	else:
		brake = 0.0


func _get_torque_curve(rpm_normalized: float) -> float:
	# Простая кривая крутящего момента
	# Максимум около 0.5-0.7 от max RPM
	if rpm_normalized < 0.2:
		return lerp(0.4, 0.8, rpm_normalized / 0.2)
	elif rpm_normalized < 0.6:
		return lerp(0.8, 1.0, (rpm_normalized - 0.2) / 0.4)
	else:
		return lerp(1.0, 0.7, (rpm_normalized - 0.6) / 0.4)


func _apply_traction_control(force: float) -> float:
	if not traction_control:
		return force

	# Проверяем пробуксовку
	for wheel in wheels_rear:
		var slip := wheel.get_skidinfo()
		if slip < 1.0 - tc_slip_threshold:
			# Уменьшаем силу при пробуксовке
			force *= slip + 0.3

	return force


func _apply_stability_control(_delta: float) -> void:
	if not stability_control:
		return

	# Получаем угловую скорость по Y (рысканье)
	var yaw_rate := angular_velocity.y

	# Если машина вращается слишком быстро
	if abs(yaw_rate) > deg_to_rad(sc_angle_threshold):
		# Применяем тормозную силу для стабилизации
		var correction: float = sign(yaw_rate) * 0.3
		apply_torque(Vector3(0, -correction * mass, 0))


func _auto_shift() -> void:
	if current_gear <= 1:
		return

	var shift_up_rpm := max_rpm * 0.85
	var shift_down_rpm := max_rpm * 0.35

	# Повышение передачи
	if current_rpm > shift_up_rpm and current_gear < gear_ratios.size() - 1:
		current_gear += 1
		gear_changed.emit(current_gear)
	# Понижение передачи
	elif current_rpm < shift_down_rpm and current_gear > 2:
		current_gear -= 1
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
