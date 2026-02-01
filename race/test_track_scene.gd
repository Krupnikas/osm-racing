extends Node3D

## Сцена тестовой трассы — использует osm_terrain_generator с захардкоженными данными

const TrackData = preload("res://race/test_track_data.gd")

@export var car_path: NodePath
@export var hud_path: NodePath
@export var terrain_path: NodePath

var _car  # Node3D (Vehicle extends RigidBody3D)
var _hud
var _terrain  # OSMTerrainGenerator
var _track_id: String = ""

## Позиции спавна для каждого трека (в локальных метрах)
const SPAWN_POSITIONS := {
	"test_flat": Vector3(80, 1.0, 0),
	"test_suspension": Vector3(0, 1.0, 5),
}

## Повороты спавна (Y rotation в радианах)
const SPAWN_ROTATIONS := {
	"test_flat": 0.0,
	"test_suspension": PI,  # 180° — лицом к трассе (Z+)
}


func _ready() -> void:
	await get_tree().process_frame

	if car_path:
		_car = get_node_or_null(car_path)
	if hud_path:
		_hud = get_node_or_null(hud_path)
	if terrain_path:
		_terrain = get_node_or_null(terrain_path)

	print("TestTrackScene: car=", _car, " hud=", _hud, " terrain=", _terrain)

	# Замораживаем машину на время генерации
	if _car and _car is RigidBody3D:
		_car.freeze = true
		_car.visible = false

	# Определяем какую трассу генерировать
	_track_id = RaceState.test_track_id
	if _track_id == "":
		_track_id = "test_flat"
	RaceState.test_track_id = ""  # Очищаем

	print("TestTrackScene: Generating track: ", _track_id)

	if not _terrain:
		push_error("TestTrackScene: OSMTerrain node not found!")
		return

	# Настраиваем провайдер данных (lambda обёртки для статических методов)
	match _track_id:
		"test_flat":
			_terrain.test_data_provider = func(lat: float, lon: float, size: float) -> Dictionary:
				return TrackData.get_flat_track_data(lat, lon, size)
		"test_suspension":
			_terrain.test_data_provider = func(lat: float, lon: float, size: float) -> Dictionary:
				return TrackData.get_suspension_track_data(lat, lon, size)
			_terrain.test_elevation_provider = func(key: String, lat: float, lon: float) -> Dictionary:
				return TrackData.get_suspension_elevation(key, lat, lon)
			_terrain.enable_elevation = true
			_terrain.elevation_scale = 1.0
			_terrain.elevation_grid_resolution = 32

	# Подключаемся к сигналу завершения загрузки
	_terrain.initial_load_complete.connect(_on_generation_complete)

	# Запускаем генерацию
	_terrain.reset_terrain()
	await get_tree().process_frame
	_terrain.start_loading()


func _on_generation_complete() -> void:
	print("TestTrackScene: Track generated, spawning car")

	# Ждём кадр чтобы физика зарегистрировала коллизии трассы
	await get_tree().process_frame

	# Позиционируем машину на старте
	var spawn_pos: Vector3 = SPAWN_POSITIONS.get(_track_id, Vector3(0, 1.0, 0))

	print("TestTrackScene: spawn_pos=", spawn_pos)

	if _car:
		if _car is RigidBody3D:
			_car.freeze = true
			_car.linear_velocity = Vector3.ZERO
			_car.angular_velocity = Vector3.ZERO
		_car.global_position = spawn_pos
		var spawn_rot: float = SPAWN_ROTATIONS.get(_track_id, 0.0)
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
