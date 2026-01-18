extends AudioStreamPlayer
class_name EngineSound

## Звук двигателя на основе оборотов

@export var min_volume := -8.0
@export var max_volume := 2.0

var _car: Car = null
var _stream_ready := false

func _ready() -> void:
	bus = "SFX"
	volume_db = min_volume
	pitch_scale = 0.5

	# Создаём звук
	stream = _generate_engine_loop()
	_stream_ready = true

	# Ищем машину
	var parent = get_parent()
	if parent is Car:
		_car = parent

func _process(delta: float) -> void:
	if not _stream_ready:
		return

	# Ищем машину
	if not _car:
		var parent = get_parent()
		if parent is Car:
			_car = parent
		return

	# Не играем если машина заморожена (в меню)
	if _car.freeze:
		if playing:
			stop()
		return

	# Запускаем если не играет
	if not playing:
		play()

	# Обороты
	var rpm: float = _car.get_rpm()
	var rpm_norm: float = clamp((rpm - _car.idle_rpm) / (_car.max_rpm - _car.idle_rpm), 0.0, 1.0)

	# Pitch: 0.5 -> 2.0
	pitch_scale = lerp(pitch_scale, 0.5 + rpm_norm * 1.5, delta * 10.0)

	# Громкость
	volume_db = lerp(min_volume, max_volume, rpm_norm * 0.5 + _car.throttle_input * 0.5)

func _generate_engine_loop() -> AudioStreamWAV:
	var sample_rate := 44100
	var base_freq := 100.0
	var samples := int(sample_rate / base_freq)

	var data := PackedByteArray()
	data.resize(samples * 2)

	for i in range(samples):
		var phase := float(i) / float(samples)

		var sample := sin(phase * TAU) * 0.4
		sample += sin(phase * 2.0 * TAU) * 0.3
		sample += sin(phase * 4.0 * TAU) * 0.15
		sample = clamp(sample * 0.7, -0.95, 0.95)

		var sample_int := int(sample * 32767)
		data[i * 2] = sample_int & 0xFF
		data[i * 2 + 1] = (sample_int >> 8) & 0xFF

	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = sample_rate
	wav.stereo = false
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_begin = 0
	wav.loop_end = samples
	wav.data = data

	return wav
