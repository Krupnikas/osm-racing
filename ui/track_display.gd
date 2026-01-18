extends CanvasLayer

## Отображает название текущего трека в левом нижнем углу

var label: Label
var animation_player: AnimationPlayer
var show_duration := 5.0  # Сколько секунд показывать титр

func _ready() -> void:
	print("TrackDisplay: _ready() called")

	# Создаём Label
	label = Label.new()
	label.name = "Label"
	label.add_theme_font_size_override("font_size", 24)
	label.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	label.add_theme_constant_override("shadow_offset_x", 2)
	label.add_theme_constant_override("shadow_offset_y", 2)

	# Используем anchors для позиционирования в левом нижнем углу
	label.anchor_left = 0.0
	label.anchor_top = 1.0
	label.anchor_right = 0.0
	label.anchor_bottom = 1.0
	label.offset_left = 20.0
	label.offset_top = -60.0
	label.offset_right = 600.0
	label.offset_bottom = -20.0

	label.modulate.a = 0.0  # Начинаем невидимым

	add_child(label)
	print("TrackDisplay: Label created and added")

	# Создаём AnimationPlayer для анимации появления/исчезновения
	animation_player = AnimationPlayer.new()
	animation_player.name = "AnimationPlayer"
	add_child(animation_player)
	print("TrackDisplay: AnimationPlayer created")

	_create_animations()
	print("TrackDisplay: Animations created")

	# Подключаемся к MusicManager
	await get_tree().process_frame
	print("TrackDisplay: Checking for MusicManager")
	if has_node("/root/MusicManager"):
		var music_manager = get_node("/root/MusicManager")
		print("TrackDisplay: MusicManager found")
		# Подключаемся к сигналу начала трека (создадим его в MusicManager)
		if music_manager.has_signal("track_started"):
			music_manager.track_started.connect(_on_track_started)
			print("TrackDisplay: Connected to track_started signal")

			# Показываем текущий трек, если он уже играет
			var current_index: int = music_manager.current_track_index
			print("TrackDisplay: Current track index: ", current_index)
			if current_index >= 0 and current_index < music_manager.playlist.size():
				var filename: String = music_manager.playlist[current_index].get_file()
				var info: Array = music_manager.track_info.get(filename, ["Unknown Artist", "Unknown Track"])
				var artist: String = info[0]
				var title: String = info[1]
				print("TrackDisplay: Showing initial track: %s - %s" % [artist, title])
				_on_track_started(title, artist)
		else:
			print("TrackDisplay: ERROR - track_started signal not found!")
	else:
		print("TrackDisplay: ERROR - MusicManager not found!")

func _create_animations() -> void:
	# Анимация появления
	var anim_show := Animation.new()
	var track_idx := anim_show.add_track(Animation.TYPE_VALUE)
	anim_show.track_set_path(track_idx, "Label:modulate:a")
	anim_show.track_insert_key(track_idx, 0.0, 0.0)
	anim_show.track_insert_key(track_idx, 0.5, 1.0)
	anim_show.length = 0.5

	var anim_lib := AnimationLibrary.new()
	anim_lib.add_animation("show", anim_show)

	# Анимация исчезновения
	var anim_hide := Animation.new()
	track_idx = anim_hide.add_track(Animation.TYPE_VALUE)
	anim_hide.track_set_path(track_idx, "Label:modulate:a")
	anim_hide.track_insert_key(track_idx, 0.0, 1.0)
	anim_hide.track_insert_key(track_idx, 0.5, 0.0)
	anim_hide.length = 0.5

	anim_lib.add_animation("hide", anim_hide)

	animation_player.add_animation_library("", anim_lib)

func _on_track_started(track_name: String, artist: String) -> void:
	print("TrackDisplay: _on_track_started called with: %s - %s" % [artist, track_name])

	# Обновляем текст
	label.text = "%s – %s" % [artist, track_name]
	print("TrackDisplay: Label text set to: ", label.text)
	print("TrackDisplay: Label modulate.a before animation: ", label.modulate.a)

	# Показываем титр
	animation_player.play("show")
	print("TrackDisplay: Playing 'show' animation")

	# Запускаем таймер для скрытия
	await get_tree().create_timer(show_duration).timeout

	print("TrackDisplay: Playing 'hide' animation")
	animation_player.play("hide")

func show_track(track_name: String, artist: String) -> void:
	"""Публичный метод для показа трека"""
	_on_track_started(track_name, artist)
