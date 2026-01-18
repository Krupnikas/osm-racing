extends Node
class_name UISounds

## Процедурные звуки для UI

var _hover_player: AudioStreamPlayer
var _click_player: AudioStreamPlayer
var _sample_rate := 44100.0

func _ready() -> void:
	# Создаём плееры для звуков
	_hover_player = AudioStreamPlayer.new()
	_hover_player.bus = "SFX"
	_hover_player.volume_db = -15.0
	add_child(_hover_player)

	_click_player = AudioStreamPlayer.new()
	_click_player.bus = "SFX"
	_click_player.volume_db = -10.0
	add_child(_click_player)

	# Генерируем звуки
	_hover_player.stream = _generate_hover_sound()
	_click_player.stream = _generate_click_sound()

	# Подключаемся ко всем кнопкам в родителе
	await get_tree().process_frame
	_connect_buttons(get_parent())

func _connect_buttons(node: Node) -> void:
	if node is Button:
		node.mouse_entered.connect(_on_button_hover)
		node.pressed.connect(_on_button_click)

	for child in node.get_children():
		_connect_buttons(child)

func _on_button_hover() -> void:
	_hover_player.play()

func _on_button_click() -> void:
	_click_player.play()

func _generate_hover_sound() -> AudioStreamWAV:
	# Короткий высокий "блип" при наведении
	var duration := 0.05
	var samples := int(duration * _sample_rate)
	var data := PackedByteArray()
	data.resize(samples * 2)  # 16-bit audio

	var freq := 800.0
	var phase := 0.0

	for i in range(samples):
		var t := float(i) / _sample_rate
		var envelope := 1.0 - (t / duration)  # Затухание
		envelope = envelope * envelope  # Квадратичное затухание

		var sample := sin(phase * TAU) * envelope * 0.3
		phase += freq / _sample_rate

		# Конвертируем в 16-bit signed
		var sample_int := int(clamp(sample, -1.0, 1.0) * 32767)
		data[i * 2] = sample_int & 0xFF
		data[i * 2 + 1] = (sample_int >> 8) & 0xFF

	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = int(_sample_rate)
	stream.stereo = false
	stream.data = data
	return stream

func _generate_click_sound() -> AudioStreamWAV:
	# Более низкий "клик" при нажатии
	var duration := 0.08
	var samples := int(duration * _sample_rate)
	var data := PackedByteArray()
	data.resize(samples * 2)

	var freq := 400.0
	var phase := 0.0

	for i in range(samples):
		var t := float(i) / _sample_rate

		# Атака + затухание
		var envelope := 0.0
		if t < 0.01:
			envelope = t / 0.01  # Быстрая атака
		else:
			envelope = 1.0 - ((t - 0.01) / (duration - 0.01))  # Затухание
		envelope = envelope * envelope

		# Два тона для более богатого звука
		var sample := sin(phase * TAU) * 0.4
		sample += sin(phase * TAU * 1.5) * 0.2
		sample *= envelope

		phase += freq / _sample_rate

		var sample_int := int(clamp(sample, -1.0, 1.0) * 32767)
		data[i * 2] = sample_int & 0xFF
		data[i * 2 + 1] = (sample_int >> 8) & 0xFF

	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = int(_sample_rate)
	stream.stereo = false
	stream.data = data
	return stream
