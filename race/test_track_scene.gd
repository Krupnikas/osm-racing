extends Node3D

## Сцена тестовой трассы (без OSM, процедурная генерация)

@export var car_path: NodePath
@export var hud_path: NodePath

var _car  # Node3D (Vehicle extends RigidBody3D)
var _hud
var _track_generator: TestTrackGenerator


func _ready() -> void:
	await get_tree().process_frame

	if car_path:
		_car = get_node_or_null(car_path)
	if hud_path:
		_hud = get_node_or_null(hud_path)

	print("TestTrackScene: car=", _car, " hud=", _hud)

	# Замораживаем машину на время генерации
	if _car and _car is RigidBody3D:
		_car.freeze = true
		_car.visible = false

	# Определяем какую трассу генерировать
	var track_id := RaceState.test_track_id
	if track_id == "":
		track_id = "test_flat"
	RaceState.test_track_id = ""  # Очищаем

	print("TestTrackScene: Generating track: ", track_id)

	# Создаём генератор и генерируем трассу
	_track_generator = TestTrackGenerator.new()
	_track_generator.name = "TestTrackGenerator"
	add_child(_track_generator)
	_track_generator.generation_complete.connect(_on_generation_complete)
	_track_generator.generate(track_id)


func _on_generation_complete() -> void:
	print("TestTrackScene: Track generated, spawning car")

	# Ждём кадр чтобы физика зарегистрировала коллизии трассы
	await get_tree().process_frame

	# Позиционируем машину на старте
	var spawn_pos := _track_generator.get_spawn_position()
	var spawn_rot := _track_generator.get_spawn_rotation()

	print("TestTrackScene: spawn_pos=", spawn_pos, " spawn_rot=", spawn_rot)

	if _car:
		if _car is RigidBody3D:
			_car.freeze = true
			_car.linear_velocity = Vector3.ZERO
			_car.angular_velocity = Vector3.ZERO
		_car.global_position = spawn_pos
		_car.rotation = Vector3(0, spawn_rot, 0)
		await get_tree().process_frame
		_car.visible = true
		if _car is RigidBody3D:
			_car.freeze = false
		print("TestTrackScene: Car placed at ", _car.global_position)

	# Показываем HUD
	if _hud and _hud.has_method("show_hud"):
		_hud.show_hud()

	# Захватываем мышку
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	# Музыка
	if MusicManager:
		MusicManager.play_random_track()

	print("TestTrackScene: Ready to drive!")
