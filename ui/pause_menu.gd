extends Control

## Меню паузы - работает и в гонке, и в свободной езде

signal resumed
signal restarted
signal exited_to_menu

var _is_paused := false
var _is_race_mode := false  # Гонка или свободная езда


func _ready() -> void:
	visible = false
	# Устанавливаем process_mode чтобы работать во время паузы
	process_mode = Node.PROCESS_MODE_ALWAYS

	# Определяем режим - если есть RaceManager с активным треком, это гонка
	await get_tree().process_frame
	var race_manager = get_tree().current_scene.find_child("RaceManager", true, false)
	if race_manager and race_manager.get("current_track") != null:
		_is_race_mode = true
	elif RaceState.selected_track != null:
		_is_race_mode = true
	else:
		_is_race_mode = false

	# Настраиваем UI в зависимости от режима
	_update_ui_for_mode()


func _update_ui_for_mode() -> void:
	"""Обновить UI в зависимости от режима (гонка/свободная езда)"""
	var restart_btn = get_node_or_null("CenterContainer/Panel/VBox/Margin/Content/Buttons/RestartButton")
	if restart_btn:
		if _is_race_mode:
			restart_btn.text = "Заново"
			restart_btn.visible = true
		else:
			# В свободной езде можно перезагрузить локацию
			restart_btn.text = "Перезагрузить"
			restart_btn.visible = true


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):  # ESC
		if _is_paused:
			_resume()
		else:
			_pause()
		get_viewport().set_input_as_handled()


func _pause() -> void:
	"""Поставить игру на паузу"""
	_is_paused = true
	visible = true
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _resume() -> void:
	"""Продолжить игру"""
	_is_paused = false
	visible = false
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	resumed.emit()


func _on_resume_pressed() -> void:
	_resume()


func _on_restart_pressed() -> void:
	"""Перезапустить - полная перезагрузка сцены"""
	_is_paused = false
	get_tree().paused = false
	restarted.emit()
	get_tree().reload_current_scene()


func _on_main_menu_pressed() -> void:
	"""Выйти в главное меню"""
	_is_paused = false
	get_tree().paused = false

	# Переключаем музыку
	if MusicManager:
		MusicManager.play_next_track()

	exited_to_menu.emit()
	get_tree().change_scene_to_file("res://ui/standalone_main_menu.tscn")
