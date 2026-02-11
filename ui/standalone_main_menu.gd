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


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	# Музыка автоматически запускается в MusicManager._ready()

	# Генерируем кнопки трасс для режима гонок
	_populate_tracks()

	# Добавляем кнопку "Тестовые трассы" в главное меню
	_add_test_tracks_button()

	# Автостарт через командную строку: --autostart [location_index]
	var args := OS.get_cmdline_args()
	for i in range(args.size()):
		if args[i] == "--perftest":
			print("StandaloneMenu: Starting performance test")
			get_tree().change_scene_to_file("res://tests/performance_test.tscn")
			return
		if args[i] == "--autostart" and i + 1 < args.size():
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

	# Загружаем сцену тестовой трассы (без OSM)
	get_tree().change_scene_to_file("res://race/test_track_scene.tscn")
