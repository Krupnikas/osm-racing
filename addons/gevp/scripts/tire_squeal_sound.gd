extends AudioStreamPlayer3D

## Звук визга резины при скольжении колес
##
## Использует slip_vector из физики колеса (Wheel.gd):
## - slip_vector.x = lateral slip (боковое скольжение при поворотах)
## - slip_vector.y = longitudinal slip (продольное скольжение при разгоне/торможении)
##
## Типичные значения slip_vector.length():
## - 0.0 - 0.5: нормальное движение без скольжения
## - 0.5 - 1.0: лёгкое скольжение (резкие повороты)
## - 1.0 - 1.5: заметное скольжение (агрессивные повороты, торможение ручником)
## - 1.5+: сильное скольжение (дрифт, блокировка колёс)
##
## Рекомендуемый порог: 1.0 (срабатывает при торможении ручником и дрифте)
##
## ГДЕ МЕНЯТЬ ПОРОГ:
## 1. В сцене машины (напр. addons/gevp/scenes/nexia_car.tscn) - узел TireSquealSound
##    Это значение переопределяет значение из скрипта!
## 2. Или в инспекторе Godot: выбрать TireSquealSound -> slip_threshold

@export var vehicle: Vehicle
## Порог slip_vector.length() для включения звука визга.
## Рекомендуемое значение: 1.0 (торможение ручником, дрифт)
@export var slip_threshold: float = 1.0
## Максимальное значение slip для полной громкости (0-100%)
@export var max_slip: float = 4.0

var _debug_timer: float = 0.0

func _ready() -> void:
	pass  # Debug print отключен

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
	#	var wheel_names := ["FL", "FR", "RL", "RR"]
	#	for i in range(wheels.size()):
	#		var w: Variant = wheels[i]
	#		if w != null and w.is_colliding():
	#			print("  %s: slip=(%.3f,%.3f) len=%.3f surf=%s spin=%.1f" % [
	#				wheel_names[i], w.slip_vector.x, w.slip_vector.y, w.slip_vector.length(),
	#				w.surface_type, w.spin
	#			])

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
