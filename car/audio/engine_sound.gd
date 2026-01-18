extends AudioStreamPlayer
class_name EngineSound

## Процедурный звук двигателя на основе оборотов

@export var min_volume := -25.0  ## Громкость на холостых (dB)
@export var max_volume := -8.0   ## Громкость на максимальных оборотах (dB)

var _car: Car = null
var _audio_generator: AudioStreamGenerator
var _playback: AudioStreamGeneratorPlayback = null

# Параметры синтеза звука
var _phase := 0.0
var _phase2 := 0.0
var _phase3 := 0.0
var _sample_rate := 22050.0
var _current_freq := 25.0
var _target_freq := 25.0
var _initialized := false

func _ready() -> void:
	# Настраиваем аудио
	bus = "Master"
	volume_db = min_volume
	process_mode = Node.PROCESS_MODE_ALWAYS  # Работаем даже на паузе

	# Создаём генератор звука
	_audio_generator = AudioStreamGenerator.new()
	_audio_generator.mix_rate = _sample_rate
	_audio_generator.buffer_length = 0.1

	stream = _audio_generator
	play()

	print("EngineSound: Started")

func _process(delta: float) -> void:
	# Ищем машину если ещё не нашли
	if not _car:
		var parent = get_parent()
		if parent is Car:
			_car = parent
			print("EngineSound: Found car")
		else:
			return

	# Получаем playback если ещё не получили
	if not _playback:
		_playback = get_stream_playback()
		if _playback:
			print("EngineSound: Got playback")
		return

	# Получаем обороты двигателя
	var rpm := _car.get_rpm()
	var max_rpm := _car.max_rpm
	var idle_rpm := _car.idle_rpm

	# Нормализованные обороты (0-1)
	var rpm_normalized := (rpm - idle_rpm) / (max_rpm - idle_rpm)
	rpm_normalized = clamp(rpm_normalized, 0.0, 1.0)

	# Целевая частота (25-90 Гц)
	_target_freq = lerp(25.0, 90.0, rpm_normalized)

	# Плавное изменение частоты
	_current_freq = lerp(_current_freq, _target_freq, delta * 8.0)

	# Громкость зависит от оборотов и газа
	var throttle := _car.throttle_input
	var vol := lerp(min_volume, max_volume, rpm_normalized * 0.5 + throttle * 0.5)
	volume_db = vol

	# Заполняем буфер
	_fill_buffer()

func _fill_buffer() -> void:
	if not _playback:
		return

	var frames_available := _playback.get_frames_available()
	if frames_available <= 0:
		return

	var inc1 := _current_freq / _sample_rate
	var inc2 := _current_freq * 2.0 / _sample_rate
	var inc3 := _current_freq * 0.5 / _sample_rate

	for i in range(frames_available):
		# Основной тон
		var sample := sin(_phase * TAU) * 0.4

		# Гармоники
		sample += sin(_phase2 * TAU) * 0.25
		sample += sin(_phase3 * TAU) * 0.2

		# Шум
		sample += (randf() - 0.5) * 0.12

		# Мягкое ограничение
		sample = clamp(sample, -0.9, 0.9)

		_playback.push_frame(Vector2(sample, sample))

		_phase = fmod(_phase + inc1, 1.0)
		_phase2 = fmod(_phase2 + inc2, 1.0)
		_phase3 = fmod(_phase3 + inc3, 1.0)
