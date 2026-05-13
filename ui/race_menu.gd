extends Control

## Меню выбора режима гонки и трассы

const RaceTrackScript = preload("res://race/race_tracks.gd")

signal race_selected(track)
signal back_pressed

@export var race_manager_path: NodePath

var _race_manager  # RaceManager
var _current_mode: String = "sprint"  # "sprint" или "checkpoint"


func _ready() -> void:
	visible = false

	await get_tree().process_frame

	if race_manager_path:
		_race_manager = get_node_or_null(race_manager_path)

	# Генерируем кнопки для трасс
	_populate_tracks()


func _populate_tracks(mode: String = "") -> void:
	"""Создать кнопки для трасс указанного режима"""
	var tracks: Array
	if mode == "sprint":
		tracks = RaceTrackScript.get_sprint_tracks()
	elif mode == "checkpoint":
		tracks = RaceTrackScript.get_checkpoint_tracks()
	else:
		tracks = RaceTrackScript.get_all_tracks()

	var container := $TracksPanel/VBox/TracksContainer

	# Очищаем контейнер
	for child in container.get_children():
		child.queue_free()

	# Создаём кнопки для каждой трассы
	for track in tracks:
		var btn := Button.new()
		btn.text = track.track_name
		btn.custom_minimum_size = Vector2(300, 60)
		btn.add_theme_font_size_override("font_size", 24)
		btn.pressed.connect(_on_track_selected.bind(track))
		container.add_child(btn)


func show_menu() -> void:
	visible = true
	$ModesPanel.visible = true
	$TracksPanel.visible = false


func hide_menu() -> void:
	visible = false


func _on_sprint_pressed() -> void:
	"""Выбран режим Спринт - показываем выбор трассы"""
	_current_mode = "sprint"
	_populate_tracks("sprint")
	$ModesPanel.visible = false
	$TracksPanel.visible = true


func _on_checkpoint_pressed() -> void:
	"""Выбран режим Чекпоинт - показываем выбор трассы"""
	_current_mode = "checkpoint"
	_populate_tracks("checkpoint")
	$ModesPanel.visible = false
	$TracksPanel.visible = true


func _on_modes_back_pressed() -> void:
	hide_menu()
	back_pressed.emit()


func _on_tracks_back_pressed() -> void:
	"""Назад из трасс в режимы"""
	$TracksPanel.visible = false
	$ModesPanel.visible = true


func _on_track_selected(track) -> void:
	"""Выбрана трасса - запускаем гонку"""
	hide_menu()
	race_selected.emit(track)

	# Показываем HUD и снимаем паузу
	var hud := get_tree().current_scene.find_child("HUD", true, false)
	if hud and hud.has_method("show_hud"):
		hud.show_hud()
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	if _race_manager:
		_race_manager.start_race(track)
