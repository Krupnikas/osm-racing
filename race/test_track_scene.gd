extends Node3D

## Сцена тестовой трассы — использует osm_terrain_generator с фейковыми OSM-данными

const FakeOSMData = preload("res://osm/fake_osm.gd")

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
	"test_npc": Vector3(80, 1.0, 0),
	"test_elevation": Vector3(80, 1.0, 0),
}

## Повороты спавна (Y rotation в радианах)
const SPAWN_ROTATIONS := {
	"test_flat": 0.0,
	"test_suspension": PI,  # 180° — лицом к трассе (Z+)
	"test_npc": 0.0,
	"test_elevation": 0.0,
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

	# Провайдер данных — FakeOSM отдаёт данные в формате osm_loader
	var tid := _track_id
	_terrain.test_data_provider = func(lat: float, lon: float, size: float) -> Dictionary:
		return FakeOSMData.get_data(tid, lat, lon, size)

	# Elevation (если есть)
	var elev: Dictionary = FakeOSMData.get_elevation(tid, "0,0", 0.0, 0.0)
	if not elev.is_empty():
		_terrain.test_elevation_provider = func(key: String, lat: float, lon: float) -> Dictionary:
			return FakeOSMData.get_elevation(tid, key, lat, lon)
		_terrain.enable_elevation = true
		_terrain.elevation_scale = 1.0
		_terrain.elevation_grid_resolution = 32

	# Доп. настройки по треку
	if _track_id == "test_elevation":
		_terrain.enable_buildings = true
	if _track_id == "test_npc":
		_setup_traffic_manager()

	# Подключаемся к сигналу завершения загрузки
	_terrain.initial_load_complete.connect(_on_generation_complete)

	# Запускаем генерацию
	_terrain.reset_terrain()
	await get_tree().process_frame
	_terrain.start_loading()


func _on_generation_complete() -> void:
	print("TestTrackScene: Track generated, spawning car")

	# Ждём несколько кадров чтобы физика зарегистрировала коллизии terrain mesh
	for i in 3:
		await get_tree().process_frame

	# Позиционируем машину на старте
	var spawn_pos: Vector3 = SPAWN_POSITIONS.get(_track_id, Vector3(0, 1.0, 0))

	# Для elevation треков — находим высоту terrain рейкастом
	if _terrain and _terrain.enable_elevation:
		var space_state := get_world_3d().direct_space_state
		var from := Vector3(spawn_pos.x, 100.0, spawn_pos.z)
		var to := Vector3(spawn_pos.x, -100.0, spawn_pos.z)
		var query := PhysicsRayQueryParameters3D.create(from, to)
		query.collision_mask = 1
		var result := space_state.intersect_ray(query)
		if not result.is_empty():
			spawn_pos.y = result.position.y + 1.5
			print("TestTrackScene: raycast hit at y=%.2f, spawn_y=%.2f" % [result.position.y, spawn_pos.y])
		else:
			spawn_pos.y = 2.0
			print("TestTrackScene: raycast miss, using default spawn_y=2.0")

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


func _setup_traffic_manager() -> void:
	## Создаём TrafficManager как sibling OSMTerrain (нужен для _extract_road_for_traffic)
	var TrafficManagerScript = preload("res://traffic/traffic_manager.gd")
	var traffic_mgr = TrafficManagerScript.new()
	traffic_mgr.name = "TrafficManager"
	# Много NPC
	traffic_mgr.max_npcs = 100
	traffic_mgr.npcs_per_chunk = 15
	traffic_mgr.spawn_distance = 300.0
	traffic_mgr.despawn_distance = 400.0
	traffic_mgr.min_spawn_separation = 10.0
	add_child(traffic_mgr)
	print("TestTrackScene: TrafficManager created (max_npcs=100, per_chunk=15)")
