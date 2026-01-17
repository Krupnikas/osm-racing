extends Control

signal start_game
signal quit_game

func _ready() -> void:
	# Показываем курсор в меню
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	visible = true

func _on_start_pressed() -> void:
	visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	start_game.emit()

func _on_controls_pressed() -> void:
	$ControlsPanel.visible = not $ControlsPanel.visible

func _on_quit_pressed() -> void:
	quit_game.emit()
	get_tree().quit()

func _on_back_pressed() -> void:
	$ControlsPanel.visible = false

func _input(event: InputEvent) -> void:
	# Escape открывает/закрывает меню
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if not visible:
			show_menu()

func show_menu() -> void:
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().paused = true

func hide_menu() -> void:
	visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	get_tree().paused = false
