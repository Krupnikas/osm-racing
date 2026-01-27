extends AudioStreamPlayer3D

## Звук визга резины при скольжении колес
## Best practice: сравниваем линейную скорость колеса с расчетной через угловую скорость

@export var vehicle: Vehicle
@export var slip_threshold := 2.0  # м/с разница для начала звука
@export var max_slip := 8.0  # м/с разница для максимальной громкости

func _physics_process(_delta):
	if not vehicle:
		return

	# Не играть звук если машина заморожена или скрыта
	if vehicle.freeze or not vehicle.visible:
		if playing:
			stop()
		return

	# Вычисляем максимальное скольжение среди всех колес
	var max_slip_speed := 0.0
	var wheels := [
		vehicle.front_left_wheel,
		vehicle.front_right_wheel,
		vehicle.rear_left_wheel,
		vehicle.rear_right_wheel
	]

	for wheel in wheels:
		if wheel and wheel.is_colliding():
			# Линейная скорость колеса (скорость точки контакта с дорогой)
			var wheel_linear_velocity := wheel.local_velocity.length()

			# Расчетная скорость на основе угловой скорости вращения колеса
			var wheel_rotational_speed := abs(wheel.spin * wheel.tire_radius)

			# Разница = величина скольжения (проскальзывание/блокировка)
			var slip_speed := abs(wheel_linear_velocity - wheel_rotational_speed)
			max_slip_speed = max(max_slip_speed, slip_speed)

	# Если скольжение выше порога - включаем звук
	if max_slip_speed > slip_threshold:
		if not playing:
			play()

		# Нормализуем скольжение для pitch и громкости
		var slip_normalized := clampf((max_slip_speed - slip_threshold) / (max_slip - slip_threshold), 0.0, 1.0)

		# Pitch: от 1.0 до 1.6 (выше = более пронзительный визг)
		pitch_scale = 1.0 + (slip_normalized * 0.6)

		# Громкость: от 0.3 до 0.85
		var volume_factor := 0.3 + (slip_normalized * 0.55)
		volume_db = linear_to_db(volume_factor)
	else:
		# Скольжение слишком маленькое - выключаем звук
		if playing:
			stop()
