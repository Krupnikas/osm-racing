extends Control

signal start_game
signal quit_game

@export var terrain_generator_path: NodePath
@export var car_path: NodePath
@export var world_root_path: NodePath

var _terrain_generator: Node3D
var _car: Node3D
var _world_root: Node3D
var _is_loading := false

func _ready() -> void:
	# Показываем курсор в меню
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	visible = true

	# Получаем ссылки на объекты
	await get_tree().process_frame
	if terrain_generator_path:
		_terrain_generator = get_node(terrain_generator_path)
	if car_path:
		_car = get_node(car_path)
	if world_root_path:
		_world_root = get_node(world_root_path)

	# Подключаем сигналы от генератора террейна
	if _terrain_generator:
		_terrain_generator.initial_load_started.connect(_on_load_started)
		_terrain_generator.initial_load_progress.connect(_on_load_progress)
		_terrain_generator.initial_load_complete.connect(_on_load_complete)

	# Скрываем мир до загрузки
	_hide_world()

func _on_start_pressed() -> void:
	if _is_loading:
		return

	_is_loading = true

	# Скрываем основное меню, показываем экран загрузки
	$VBox.visible = false
	$LoadingPanel.visible = true
	$LoadingPanel/VBox/ProgressBar.value = 0
	$LoadingPanel/VBox/StatusLabel.text = "Подготовка..."

	# Начинаем загрузку террейна
	if _terrain_generator:
		_terrain_generator.start_loading()
	else:
		# Если нет генератора - сразу показываем игру
		_start_game()

func _on_load_started() -> void:
	$LoadingPanel/VBox/StatusLabel.text = "Загрузка карты..."

func _on_load_progress(loaded: int, total: int) -> void:
	var progress := 0.0
	if total > 0:
		progress = float(loaded) / float(total) * 100.0
	$LoadingPanel/VBox/ProgressBar.value = progress
	$LoadingPanel/VBox/StatusLabel.text = "Загрузка чанков: %d / %d" % [loaded, total]

func _on_load_complete() -> void:
	$LoadingPanel/VBox/ProgressBar.value = 100
	$LoadingPanel/VBox/StatusLabel.text = "Готово!"

	# Небольшая задержка для отображения 100%
	await get_tree().create_timer(0.3).timeout

	_start_game()

func _start_game() -> void:
	_is_loading = false

	# Показываем мир
	_show_world()

	# Скрываем меню
	visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	start_game.emit()

func _hide_world() -> void:
	# Скрываем машину
	if _car:
		_car.visible = false
		# Замораживаем физику машины
		if _car is RigidBody3D:
			_car.freeze = true

func _show_world() -> void:
	# Показываем машину
	if _car:
		_car.visible = true
		# Размораживаем физику машины
		if _car is RigidBody3D:
			_car.freeze = false

func _on_controls_pressed() -> void:
	$ControlsPanel.visible = not $ControlsPanel.visible

func _on_quit_pressed() -> void:
	quit_game.emit()
	get_tree().quit()

func _on_back_pressed() -> void:
	$ControlsPanel.visible = false

func _input(event: InputEvent) -> void:
	# Escape открывает/закрывает меню (но не во время загрузки)
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if _is_loading:
			return
		if not visible:
			show_menu()

func show_menu() -> void:
	visible = true
	$VBox.visible = true
	$LoadingPanel.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().paused = true

func hide_menu() -> void:
	visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	get_tree().paused = false
