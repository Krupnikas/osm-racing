extends AudioStreamPlayer3D

## Звук визга резины при скольжении колес
## Проигрывает звук пропорционально величине slip_vector

@export var vehicle: Vehicle
@export var volume_multiplier := 1.0  # Множитель громкости
@export var slip_threshold := 0.15  # Минимальное скольжение для начала звука

# Генерируем процедурный звук визга (белый шум с фильтром)
var _audio_generator: AudioStreamGenerator
var _playback: AudioStreamGeneratorPlayback
var _phase := 0.0
var _target_volume := 0.0
var _current_volume := 0.0

func _ready() -> void:
	# Создаём генератор звука
	_audio_generator = AudioStreamGenerator.new()
	_audio_generator.mix_rate = 22050.0  # Более низкий sample rate для визга
	_audio_generator.buffer_length = 0.1

	stream = _audio_generator
	autoplay = true
	max_db = 6.0
	volume_db = -80.0  # Начинаем с тишины
	unit_size = 20.0  # Радиус слышимости
	max_distance = 100.0

	# Ждём пока playback будет готов
	await get_tree().process_frame
	_playback = get_stream_playback()

func _physics_process(delta: float) -> void:
	if not vehicle or not _playback:
		return

	# Не играть звук если машина заморожена или скрыта
	if vehicle.freeze or not vehicle.visible:
		_target_volume = 0.0
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

	# Вычисляем целевую громкость на основе скольжения
	if max_slip > slip_threshold:
		var slip_amount := clampf((max_slip - slip_threshold) / (1.0 - slip_threshold), 0.0, 1.0)
		_target_volume = slip_amount * volume_multiplier
	else:
		_target_volume = 0.0

	# Плавно интерполируем громкость
	_current_volume = lerpf(_current_volume, _target_volume, delta * 10.0)

	# Устанавливаем громкость
	if _current_volume < 0.01:
		volume_db = -80.0
	else:
		volume_db = linear_to_db(_current_volume)

func _process(delta: float) -> void:
	if not _playback:
		return

	# Генерируем звук визга (фильтрованный белый шум)
	var frames_available := _playback.get_frames_available()
	if frames_available > 0:
		_generate_squeal_sound(frames_available)

func _generate_squeal_sound(frame_count: int) -> void:
	var increment := TAU / _audio_generator.mix_rate

	for i in range(frame_count):
		# Белый шум
		var noise := randf_range(-1.0, 1.0)

		# Добавляем тональность через синусоиду (визг имеет высокий тон)
		var tone := sin(_phase * 800.0)  # ~800 Hz базовая частота

		# Смешиваем шум и тон (70% шум, 30% тон)
		var sample := (noise * 0.7 + tone * 0.3) * _current_volume

		# Записываем в оба канала
		_playback.push_frame(Vector2(sample, sample))

		_phase += increment
		if _phase > TAU:
			_phase -= TAU
