extends AudioStreamPlayer3D

## Звук визга резины при скольжении колес
## Работает аналогично engine_sound.gd - звук всегда играет, громкость регулируется

@export var vehicle: Vehicle
@export var min_slip_for_sound := 0.02  # Начинаем тихо при малом скольжении
@export var max_pitch := 1.8  # Максимальный pitch при сильном скольжении

func _physics_process(_delta):
	if not vehicle:
		return

	# Не играть звук если машина заморожена или скрыта (как у двигателя)
	if vehicle.freeze or not vehicle.visible:
		if playing:
			stop()
		return

	# Включить звук если не играет (как у двигателя - всегда включен)
	if not playing:
		play()

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

	# Pitch зависит от величины скольжения (аналогично RPM у двигателя)
	# При скольжении 0.0 -> pitch 1.0, при 0.5+ -> pitch max_pitch
	pitch_scale = 1.0 + (clampf(max_slip / 0.5, 0.0, 1.0) * (max_pitch - 1.0))

	# Громкость зависит от скольжения
	# Если нет скольжения - полная тишина (-80 dB)
	if max_slip < min_slip_for_sound:
		volume_db = -80.0  # Практически беззвучно
	else:
		# Нормализуем скольжение от min_slip_for_sound до 0.3 (сильное скольжение)
		var slip_normalized := clampf((max_slip - min_slip_for_sound) / (0.3 - min_slip_for_sound), 0.0, 1.0)
		# Диапазон громкости: от 0.2 до 0.9 (чуть тише двигателя)
		var volume_factor := (slip_normalized * 0.7) + 0.2
		volume_db = linear_to_db(volume_factor)
