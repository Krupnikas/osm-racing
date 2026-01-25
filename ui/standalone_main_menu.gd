extends Control

## Главное меню (отдельная сцена, без 3D мира в фоне)
## Два режима:
## 1. Свободная езда (Старт) - загружает main.tscn с выбранной локацией
## 2. Гонки - загружает race_scene.tscn с выбранным треком

const RaceTrackScript = preload("res://race/race_tracks.gd")

# Доступные локации для свободной езды: название -> [широта, долгота]
const LOCATIONS := {
	"Череповец": [59.150406, 37.948805],
	"Москва (Отрадное)": [55.860580, 37.599646],
	"Тбилиси (Важа-Пшавела)": [41.723972, 44.730502],
	"Дубай (Крик)": [25.208591, 55.344100],
}


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	# Музыка автоматически запускается в MusicManager._ready()

	# Генерируем кнопки трасс для режима гонок
	_populate_tracks()


func _populate_tracks() -> void:
	"""Создать кнопки для всех доступных трасс"""
	var tracks = RaceTrackScript.get_all_tracks()
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


# === Главное меню ===

func _on_start_pressed() -> void:
	"""Свободная езда - показать выбор локации"""
	$VBox.visible = false
	$LocationPanel.visible = true


func _on_races_pressed() -> void:
	"""Гонки - показать выбор режима"""
	$VBox.visible = false
	$ModesPanel.visible = true


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
