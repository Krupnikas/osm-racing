extends AudioStreamPlayer3D

## Звук визга резины при скольжении колес
## Работает аналогично engine_sound.gd

@export var vehicle: Vehicle
@export var slip_threshold := 0.05  # Минимальное скольжение для начала звука (снижено с 0.15)
@export var max_pitch := 1.5  # Максимальный pitch при сильном скольжении

var _debug_timer := 0.0

func _init() -> void:
	print("TireSquealSound: _init() called")

func _ready() -> void:
	print("TireSquealSound: _ready() called")
	print("TireSquealSound: vehicle = ", vehicle)
	print("TireSquealSound: parent = ", get_parent())
	print("TireSquealSound: stream = ", stream)
	if stream:
		print("TireSquealSound: Stream loaded OK, path = ", stream.resource_path if "resource_path" in stream else "no path")
	else:
		push_error("TireSquealSound: FATAL - No stream assigned!")

	# Пробуем сыграть тестовый звук
	print("TireSquealSound: Attempting test play...")
	play()
	await get_tree().create_timer(0.5).timeout
	stop()
	print("TireSquealSound: Test play completed")

func _physics_process(delta):
	if not vehicle:
		return

	# Debug каждые 2 секунды
	_debug_timer += delta
	if _debug_timer > 2.0:
		_debug_timer = 0.0

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

	# Debug вывод
	if _debug_timer == 0.0:
		print("TireSquealSound: max_slip=%.3f, threshold=%.3f, playing=%s" % [max_slip, slip_threshold, playing])

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
