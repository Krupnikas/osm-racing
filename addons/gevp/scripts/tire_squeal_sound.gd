extends AudioStreamPlayer3D

## Звук визга резины при скольжении колес
## Best practice: сравниваем линейную скорость колеса с расчетной через угловую скорость

@export var vehicle: Vehicle
@export var slip_threshold: float = 1.0  # Порог slip_vector.length() для звука
@export var max_slip: float = 4.0  # Максимальный slip_vector.length() для полной громкости

var _debug_timer: float = 0.0

func _ready() -> void:
	print("TireSquealSound: Ready! vehicle=%s, threshold=%.2f, max_slip=%.2f" % [vehicle, slip_threshold, max_slip])

func _physics_process(delta: float) -> void:
	if not vehicle:
		return

	# Не играть звук если машина заморожена или скрыта
	if vehicle.freeze or not vehicle.visible:
		if playing:
			stop()
		return

	# Вычисляем скольжение для каждого колеса и находим максимальное
	var max_slip_speed: float = 0.0
	var slipping_wheels: int = 0  # Количество скользящих колес
	# Array без типизации, т.к. колеса могут быть null
	var wheels: Array = [
		vehicle.front_left_wheel,
		vehicle.front_right_wheel,
		vehicle.rear_left_wheel,
		vehicle.rear_right_wheel
	]

	for wheel: Variant in wheels:
		if wheel != null and wheel.is_colliding():
			# Проверяем что колесо на дороге (Road), а не на траве/грязи
			if wheel.surface_type != "Road":
				continue

			# ПРАВИЛЬНО: используем slip_vector из физики колеса
			# slip_vector.x = lateral slip (боковое скольжение)
			# slip_vector.y = longitudinal slip (продольное скольжение)
			# Оба нормализованы от 0 до 1
			var slip_magnitude: float = wheel.slip_vector.length()

			# Считаем колесо скользящим если превышен порог
			if slip_magnitude > slip_threshold:
				slipping_wheels += 1
				if slip_magnitude > max_slip_speed:
					max_slip_speed = slip_magnitude

	# Debug отключен - раскомментируй для диагностики
	#_debug_timer += delta
	#if _debug_timer > 0.5:
	#	_debug_timer = 0.0
	#	print("TireSqueal: max_slip=%.3f, wheels=%d, threshold=%.3f, playing=%s" % [
	#		max_slip_speed, slipping_wheels, slip_threshold, playing
	#	])
	#	var first_wheel: Variant = wheels[0] if wheels.size() > 0 else null
	#	if first_wheel != null and first_wheel.is_colliding():
	#		var w: Wheel = first_wheel as Wheel
	#		print("  FL: slip_vec=(%.3f, %.3f) len=%.3f, vel=(%.2f, %.2f, %.2f), spin=%.2f" % [
	#			w.slip_vector.x, w.slip_vector.y, w.slip_vector.length(),
	#			w.local_velocity.x, w.local_velocity.y, w.local_velocity.z, w.spin
	#		])

	# Если хотя бы одно колесо скользит - включаем звук
	if slipping_wheels > 0:
		if not playing and stream != null:
			play()

		# Нормализуем скольжение для громкости
		var slip_range: float = max_slip - slip_threshold
		var slip_normalized: float = 0.0
		if slip_range > 0.001:  # Защита от деления на ноль
			slip_normalized = clampf((max_slip_speed - slip_threshold) / slip_range, 0.0, 1.0)
		else:
			slip_normalized = 1.0  # Максимальная громкость если range слишком маленький

		# Pitch: от 0.4 до 0.7 в зависимости от силы скольжения
		pitch_scale = 0.4 + (slip_normalized * 0.3)

		# Громкость: от 0.3 до 1.0 в зависимости от силы скольжения
		var volume_factor: float = 0.3 + (slip_normalized * 0.7)
		volume_db = linear_to_db(volume_factor)
	else:
		# Скольжение слишком маленькое - выключаем звук
		if playing:
			stop()
