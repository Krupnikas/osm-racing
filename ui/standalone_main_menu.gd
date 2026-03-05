extends Control

## Главное меню (отдельная сцена, без 3D мира в фоне)
## Два режима:
## 1. Свободная езда (Старт) - загружает main.tscn с выбранной локацией
## 2. Гонки - загружает race_scene.tscn с выбранным треком

const RaceTrackScript = preload("res://race/race_tracks.gd")
const TestTracksScript = preload("res://race/test_tracks.gd")

# Доступные локации для свободной езды: название -> [широта, долгота]
const LOCATIONS := {
	"Череповец": [59.150406, 37.948805],
	"Москва (Отрадное)": [55.860580, 37.599646],
	"Тбилиси (Важа-Пшавела)": [41.723972, 44.730502],
	"Дубай (Крик)": [25.208591, 55.344100],
}

var _current_mode: String = "sprint"  # "sprint" или "checkpoint"
var _map_selected_lat: float = 0.0
var _map_selected_lon: float = 0.0


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	# Применяем сохранённые настройки громкости
	var config := ConfigFile.new()
	if config.load("user://graphics.cfg") == OK:
		var music_vol: float = config.get_value("audio", "music_volume", 80.0)
		var sfx_vol: float = config.get_value("audio", "sfx_volume", 80.0)
		var music_idx := AudioServer.get_bus_index("Music")
		if music_idx >= 0:
			AudioServer.set_bus_volume_db(music_idx, linear_to_db(music_vol / 100.0))
		var sfx_idx := AudioServer.get_bus_index("SFX")
		if sfx_idx >= 0:
			AudioServer.set_bus_volume_db(sfx_idx, linear_to_db(sfx_vol / 100.0))

	# Музыка автоматически запускается в MusicManager._ready()

	# Генерируем кнопки трасс для режима гонок
	_populate_tracks()

	# Добавляем кнопку "Выбрать на карте" и "Тестовые трассы" в главное меню
	_add_map_button()
	_add_test_tracks_button()

	# Автостарт через командную строку: --autostart [location_index] [--lat X --lon Y]
	var args := OS.get_cmdline_user_args()
	var cmd_lat := 0.0
	var cmd_lon := 0.0
	for i in range(args.size()):
		if args[i] == "--perftest":
			print("StandaloneMenu: Starting performance test")
			get_tree().change_scene_to_file("res://tests/performance_test.tscn")
			return
		if args[i] == "--lat" and i + 1 < args.size():
			cmd_lat = float(args[i + 1])
		if args[i] == "--lon" and i + 1 < args.size():
			cmd_lon = float(args[i + 1])
	var has_custom_coords := cmd_lat != 0.0 and cmd_lon != 0.0
	for i in range(args.size()):
		if args[i] == "--autostart":
			if has_custom_coords:
				print("StandaloneMenu: Autostart at --lat %.6f --lon %.6f" % [cmd_lat, cmd_lon])
				_start_free_roam_at_coords(cmd_lat, cmd_lon)
				return
			elif i + 1 < args.size():
				var idx := int(args[i + 1])
				var locations := LOCATIONS.keys()
				if idx >= 0 and idx < locations.size():
					print("StandaloneMenu: Autostart location %d: %s" % [idx, locations[idx]])
					_start_free_roam(locations[idx])
					return


func _populate_tracks(mode: String = "") -> void:
	"""Создать кнопки для трасс указанного режима"""
	var tracks: Array
	if mode == "sprint":
		tracks = RaceTrackScript.get_sprint_tracks()
	elif mode == "checkpoint":
		tracks = RaceTrackScript.get_checkpoint_tracks()
	else:
		tracks = RaceTrackScript.get_all_tracks()
	var container = get_node_or_null("TracksPanel/VBox/TracksContainer")
	if not container:
		push_error("TracksContainer not found!")
		return

	# Очищаем контейнер
	for child in container.get_children():
		child.queue_free()

	# Создаём кнопки для каждой трассы
	for track in tracks:
		if not track:
			continue
		var btn := Button.new()
		btn.text = track.track_name
		btn.custom_minimum_size = Vector2(300, 60)
		btn.add_theme_font_size_override("font_size", 24)
		btn.pressed.connect(_on_track_selected.bind(track))
		container.add_child(btn)


func _add_map_button() -> void:
	"""Добавить кнопку 'Выбрать на карте' в главное меню"""
	var vbox = get_node_or_null("VBox")
	if not vbox:
		return
	var start_button = vbox.get_node_or_null("StartButton")
	if not start_button:
		return

	var btn := Button.new()
	btn.name = "MapButton"
	btn.text = "🗺 ВЫБРАТЬ НА КАРТЕ"
	btn.custom_minimum_size = Vector2(400, 70)
	btn.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	btn.add_theme_color_override("font_hover_color", Color(0.5, 1, 0.5, 1))
	btn.add_theme_font_size_override("font_size", 36)
	btn.pressed.connect(_on_map_pressed)

	var start_index := start_button.get_index()
	vbox.add_child(btn)
	vbox.move_child(btn, start_index + 1)


func _add_test_tracks_button() -> void:
	"""Добавить кнопку Тестовые трассы в главное меню"""
	var vbox = get_node_or_null("VBox")
	if not vbox:
		push_error("VBox not found!")
		return

	# Найдём StartButton чтобы вставить кнопку после неё
	var start_button = vbox.get_node_or_null("StartButton")
	if not start_button:
		push_error("StartButton not found!")
		return

	# Создаём кнопку
	var btn := Button.new()
	btn.name = "TestTracksButton"
	btn.text = "🔧 ТЕСТОВЫЕ ТРАССЫ"
	btn.custom_minimum_size = Vector2(400, 70)
	btn.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	btn.add_theme_color_override("font_hover_color", Color(0.5, 0.8, 1, 1))
	btn.add_theme_font_size_override("font_size", 36)
	btn.pressed.connect(_on_test_tracks_pressed)

	# Вставляем после StartButton
	var start_index = start_button.get_index()
	vbox.add_child(btn)
	vbox.move_child(btn, start_index + 1)


# === Главное меню ===

func _on_start_pressed() -> void:
	"""Свободная езда - показать выбор локации"""
	$VBox.visible = false
	$LocationPanel.visible = true


func _on_races_pressed() -> void:
	"""Гонки - показать выбор режима"""
	$VBox.visible = false
	$ModesPanel.visible = true


func _on_car_selection_pressed() -> void:
	"""Выбор машины"""
	$VBox.visible = false
	$CarSelection.show_selection()


func _on_controls_pressed() -> void:
	"""Показать управление"""
	$VBox.visible = false
	$ControlsPanel.visible = true


func _on_settings_pressed() -> void:
	"""Показать настройки"""
	$VBox.visible = false
	$SettingsPanel.visible = true
	_sync_audio_sliders()


func _on_quit_pressed() -> void:
	"""Выход из игры"""
	get_tree().quit()


func _on_test_tracks_pressed() -> void:
	"""Тестовые трассы - показать выбор тестовой трассы"""
	$VBox.visible = false
	var test_panel = get_node_or_null("TestTracksPanel")
	if test_panel:
		test_panel.visible = true
	else:
		# Если панель не существует, создаём её программно
		_create_test_tracks_panel()


# === Выбор локации (свободная езда) ===

func _on_location_back_pressed() -> void:
	$LocationPanel.visible = false
	$VBox.visible = true


func _on_cherepovets_pressed() -> void:
	_start_free_roam("Череповец")


func _on_moscow_pressed() -> void:
	_start_free_roam("Москва (Отрадное)")


func _on_tbilisi_pressed() -> void:
	_start_free_roam("Тбилиси (Важа-Пшавела)")


func _on_dubai_pressed() -> void:
	_start_free_roam("Дубай (Крик)")


func _start_free_roam_at_coords(lat: float, lon: float) -> void:
	"""Запустить свободную езду по произвольным координатам (--lat --lon)"""
	print("MainMenu: Starting free roam at %.6f, %.6f" % [lat, lon])
	RaceState.free_roam_location = LOCATIONS.keys()[0]
	RaceState.free_roam_lat = lat
	RaceState.free_roam_lon = lon
	RaceState.selected_track = null
	if MusicManager:
		MusicManager.play_next_track()
	get_tree().change_scene_to_file.call_deferred("res://main.tscn")


func _start_free_roam(location_name: String) -> void:
	"""Запустить свободную езду в выбранной локации"""
	print("MainMenu: Starting free roam in ", location_name)

	# Сохраняем локацию для main.tscn
	var coords: Array = LOCATIONS[location_name]
	RaceState.free_roam_location = location_name
	RaceState.free_roam_lat = coords[0]
	RaceState.free_roam_lon = coords[1]
	RaceState.selected_track = null  # Не гонка

	# Переключаем музыку
	if MusicManager:
		MusicManager.play_next_track()

	# Сразу загружаем сцену - она сама покажет прогресс
	get_tree().change_scene_to_file("res://main.tscn")


# === Режим гонок ===

func _on_modes_back_pressed() -> void:
	$ModesPanel.visible = false
	$VBox.visible = true


func _on_sprint_pressed() -> void:
	"""Спринт - показать выбор трассы"""
	_current_mode = "sprint"
	_populate_tracks("sprint")
	$ModesPanel.visible = false
	$TracksPanel.visible = true


func _on_checkpoint_pressed() -> void:
	"""Чекпоинт - показать выбор трассы"""
	_current_mode = "checkpoint"
	_populate_tracks("checkpoint")
	$ModesPanel.visible = false
	$TracksPanel.visible = true


func _on_tracks_back_pressed() -> void:
	$TracksPanel.visible = false
	$ModesPanel.visible = true


func _on_track_selected(track) -> void:
	"""Выбрана трасса - загружаем сцену гонки"""
	print("MainMenu: Selected track: ", track.track_name)

	# Сохраняем выбранный трек
	RaceState.selected_track = track
	RaceState.free_roam_location = ""  # Это гонка, не свободная езда

	# Переключаем музыку
	if MusicManager:
		MusicManager.play_next_track()

	# Сразу загружаем сцену - она сама покажет прогресс
	get_tree().change_scene_to_file("res://race/race_scene.tscn")


# === Управление ===

func _on_controls_back_pressed() -> void:
	$ControlsPanel.visible = false
	$VBox.visible = true


# === Настройки ===

func _on_settings_back_pressed() -> void:
	$SettingsPanel.visible = false
	$VBox.visible = true


func _sync_audio_sliders() -> void:
	var config := ConfigFile.new()
	var music_vol := 80.0
	var sfx_vol := 80.0
	if config.load("user://graphics.cfg") == OK:
		music_vol = config.get_value("audio", "music_volume", 80.0)
		sfx_vol = config.get_value("audio", "sfx_volume", 80.0)
	var music_slider := $SettingsPanel/VBox/MusicVolBox/MusicVolSlider as HSlider
	if music_slider:
		music_slider.set_value_no_signal(music_vol)
	var music_label := $SettingsPanel/VBox/MusicVolBox/MusicVolValue as Label
	if music_label:
		music_label.text = "%.0f%%" % music_vol
	var sfx_slider := $SettingsPanel/VBox/SFXVolBox/SFXVolSlider as HSlider
	if sfx_slider:
		sfx_slider.set_value_no_signal(sfx_vol)
	var sfx_label := $SettingsPanel/VBox/SFXVolBox/SFXVolValue as Label
	if sfx_label:
		sfx_label.text = "%.0f%%" % sfx_vol


func _apply_and_save_audio(music_vol: float, sfx_vol: float) -> void:
	var music_idx := AudioServer.get_bus_index("Music")
	if music_idx >= 0:
		AudioServer.set_bus_volume_db(music_idx, linear_to_db(music_vol / 100.0))
	var sfx_idx := AudioServer.get_bus_index("SFX")
	if sfx_idx >= 0:
		AudioServer.set_bus_volume_db(sfx_idx, linear_to_db(sfx_vol / 100.0))
	# Сохраняем в конфиг
	var config := ConfigFile.new()
	config.load("user://graphics.cfg")  # Загружаем существующий чтобы не потерять другие настройки
	config.set_value("audio", "music_volume", music_vol)
	config.set_value("audio", "sfx_volume", sfx_vol)
	config.save("user://graphics.cfg")


func _on_music_vol_changed(value: float) -> void:
	var sfx_slider := $SettingsPanel/VBox/SFXVolBox/SFXVolSlider as HSlider
	var sfx_val := sfx_slider.value if sfx_slider else 80.0
	_apply_and_save_audio(value, sfx_val)
	var label := $SettingsPanel/VBox/MusicVolBox/MusicVolValue as Label
	if label:
		label.text = "%.0f%%" % value


func _on_sfx_vol_changed(value: float) -> void:
	var music_slider := $SettingsPanel/VBox/MusicVolBox/MusicVolSlider as HSlider
	var music_val := music_slider.value if music_slider else 80.0
	_apply_and_save_audio(music_val, value)
	var label := $SettingsPanel/VBox/SFXVolBox/SFXVolValue as Label
	if label:
		label.text = "%.0f%%" % value


# === Тестовые трассы ===

func _create_test_tracks_panel() -> void:
	"""Создать панель выбора тестовых трасс программно"""
	var panel := Panel.new()
	panel.name = "TestTracksPanel"
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -300
	panel.offset_right = 300
	panel.offset_top = -250
	panel.offset_bottom = 250
	panel.visible = true
	add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 30
	vbox.offset_top = 30
	vbox.offset_right = -30
	vbox.offset_bottom = -30
	panel.add_child(vbox)

	# Title
	var title := Label.new()
	title.text = "Тестовые трассы"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 36)
	vbox.add_child(title)

	# Spacer
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 25)
	vbox.add_child(spacer)

	# Test track buttons
	var test_tracks = TestTracksScript.get_all_test_tracks()
	for track in test_tracks:
		var btn := Button.new()
		btn.text = track["track_name"]
		btn.custom_minimum_size = Vector2(0, 60)
		btn.add_theme_font_size_override("font_size", 28)
		btn.pressed.connect(_on_test_track_selected.bind(track))
		vbox.add_child(btn)

		# Описание под кнопкой
		if track.has("description"):
			var desc := Label.new()
			desc.text = track["description"]
			desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			desc.add_theme_font_size_override("font_size", 16)
			desc.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7, 1))
			vbox.add_child(desc)

	# Spacer
	var spacer2 := Control.new()
	spacer2.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(spacer2)

	# Back button
	var back_btn := Button.new()
	back_btn.text = "Назад"
	back_btn.custom_minimum_size = Vector2(0, 60)
	back_btn.add_theme_font_size_override("font_size", 28)
	back_btn.pressed.connect(_on_test_tracks_back_pressed)
	vbox.add_child(back_btn)


func _on_test_tracks_back_pressed() -> void:
	var test_panel = get_node_or_null("TestTracksPanel")
	if test_panel:
		test_panel.visible = false
	$VBox.visible = true


func _on_test_track_selected(track: Dictionary) -> void:
	"""Выбрана тестовая трасса - загружаем процедурную сцену (без OSM)"""
	print("MainMenu: Selected test track: ", track["track_name"])

	# Сохраняем ID тестовой трассы
	RaceState.test_track_id = track["track_id"]
	RaceState.selected_track = null
	RaceState.free_roam_location = ""

	# Переключаем музыку
	if MusicManager:
		MusicManager.play_next_track()

	# Загружаем сцену (кастомную или стандартную тестовую)
	var scene_path: String = track.get("scene_path", "res://race/test_track_scene.tscn")
	get_tree().change_scene_to_file(scene_path)


# === Карта мира ===

func _on_map_pressed() -> void:
	"""Открыть карту мира"""
	$VBox.visible = false
	var map_panel = get_node_or_null("MapPanel")
	if not map_panel:
		_create_map_panel()
		map_panel = $MapPanel
	map_panel.visible = true
	$MapPanel/WorldMap.show_map()


func _create_map_panel() -> void:
	"""Создать полноэкранную панель с картой мира"""
	var panel := Panel.new()
	panel.name = "MapPanel"
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.visible = false
	add_child(panel)

	# WorldMap control
	var world_map_script := preload("res://ui/world_map.gd")
	var world_map := Control.new()
	world_map.set_script(world_map_script)
	world_map.name = "WorldMap"
	world_map.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.add_child(world_map)

	world_map.location_selected.connect(_on_map_location_selected)

	# Кнопка "Назад" (верхний левый угол)
	var back_btn := Button.new()
	back_btn.name = "BackButton"
	back_btn.text = "← Назад"
	back_btn.custom_minimum_size = Vector2(150, 50)
	back_btn.add_theme_font_size_override("font_size", 24)
	back_btn.position = Vector2(20, 50)
	back_btn.pressed.connect(_on_map_back_pressed)
	panel.add_child(back_btn)

	# Кнопка "НАЧАТЬ ЗДЕСЬ" (внизу по центру, скрыта до выбора точки)
	var start_btn := Button.new()
	start_btn.name = "StartHereButton"
	start_btn.text = "▶ НАЧАТЬ ЗДЕСЬ"
	start_btn.custom_minimum_size = Vector2(350, 70)
	start_btn.add_theme_font_size_override("font_size", 32)
	start_btn.add_theme_color_override("font_color", Color(1, 1, 1))
	start_btn.add_theme_color_override("font_hover_color", Color(0.5, 1, 0.5, 1))
	start_btn.anchor_left = 0.5
	start_btn.anchor_right = 0.5
	start_btn.anchor_top = 1.0
	start_btn.anchor_bottom = 1.0
	start_btn.offset_left = -175
	start_btn.offset_right = 175
	start_btn.offset_top = -120
	start_btn.offset_bottom = -50
	start_btn.visible = false
	start_btn.pressed.connect(_on_start_here_pressed)
	panel.add_child(start_btn)


func _on_map_back_pressed() -> void:
	"""Закрыть карту, вернуться в главное меню"""
	$MapPanel/WorldMap.hide_map()
	$MapPanel.visible = false
	$MapPanel/StartHereButton.visible = false
	$VBox.visible = true


func _on_map_location_selected(lat: float, lon: float) -> void:
	"""Пользователь выбрал точку на карте"""
	_map_selected_lat = lat
	_map_selected_lon = lon
	$MapPanel/StartHereButton.visible = true
	$MapPanel/StartHereButton.text = "▶ НАЧАТЬ ЗДЕСЬ (%.4f, %.4f)" % [lat, lon]


func _on_start_here_pressed() -> void:
	"""Начать свободную езду в выбранной на карте точке"""
	$MapPanel/WorldMap.hide_map()
	$MapPanel.visible = false
	_start_free_roam_at_coords(_map_selected_lat, _map_selected_lon)
