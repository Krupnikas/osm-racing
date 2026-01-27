extends AudioStreamPlayer3D

## Звук визга резины при скольжении колес
## Работает аналогично engine_sound.gd

@export var vehicle: Vehicle
@export var slip_threshold := 0.15  # Минимальное скольжение для начала звука
@export var max_pitch := 1.5  # Максимальный pitch при сильном скольжении

func _physics_process(_delta):
	if not vehicle:
		return

	# Не играть звук если машина заморожена или скрыта
	if vehicle.freeze or not vehicle.visible:
		if playing:
			stop()
		return

	# Вычисляем максимальное скольжение среди всех колес
	var max_slip := 0.0
	var wheels := [
		vehicle.front_left_wheel,
		vehicle.front_right_wheel,
		vehicle.rear_left_wheel,
		vehicle.rear_right_wheel
	]

	for wheel in wheels:
		if wheel and wheel.is_colliding():
			# Комбинированное скольжение (латеральное + продольное)
			var slip_magnitude := wheel.slip_vector.length()
			max_slip = max(max_slip, slip_magnitude)

	# Если скольжение выше порога - включаем звук
	if max_slip > slip_threshold:
		if not playing:
			play()

		# Нормализуем скольжение от threshold до 1.0
		var slip_normalized := clampf((max_slip - slip_threshold) / (1.0 - slip_threshold), 0.0, 1.0)

		# Pitch зависит от величины скольжения (чем больше - тем выше)
		pitch_scale = 1.0 + (slip_normalized * (max_pitch - 1.0))

		# Громкость тоже зависит от скольжения
		volume_db = linear_to_db(slip_normalized * 0.8 + 0.2)  # Диапазон 0.2-1.0
	else:
		# Скольжение слишком маленькое - выключаем звук
		if playing:
			stop()
