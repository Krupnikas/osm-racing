extends Node3D
class_name OSMTerrainGenerator

signal initial_load_started
signal initial_load_progress(progress: float, status: String)  # 0.0-1.0 прогресс + текст статуса
signal initial_load_complete

const OSMLoaderScript = preload("res://osm/osm_loader.gd")
const ElevationLoaderScript = preload("res://osm/elevation_loader.gd")
const TextureGeneratorScript = preload("res://textures/texture_generator.gd")
const BuildingWallShader = preload("res://osm/building_wall.gdshader")
const WetRoadMaterial = preload("res://night_mode/wet_road_material.gd")
const EntranceGroupGenerator = preload("res://osm/entrance_group_generator.gd")
const BIRCH_TREE_SCENE = preload("res://models/trees/birch/scene.gltf")

# Пути к моделям растительности Kenney Nature Kit (CC0)
const GRASS_MODEL_PATH := "res://models/vegetation/grass.glb"
const GRASS_LARGE_MODEL_PATH := "res://models/vegetation/grass_large.glb"
const BUSH_SMALL_MODEL_PATH := "res://models/vegetation/plant_bushSmall.glb"
const BUSH_MODEL_PATH := "res://models/vegetation/plant_bush.glb"
const BUSH_LARGE_MODEL_PATH := "res://models/vegetation/plant_bushLarge.glb"

# Кэш загруженных моделей растительности
var _grass_model: PackedScene
var _bush_model: PackedScene

# Кэш текстур (создаются один раз)
var _road_textures: Dictionary = {}
var _building_textures: Dictionary = {}
var _ground_textures: Dictionary = {}
var _normal_textures: Dictionary = {}  # Normal maps
var _textures_initialized := false

@export var start_lat := 59.150066
@export var start_lon := 37.949370
@export var chunk_size := 300.0  # Размер чанка в метрах
@export var load_distance := 500.0  # Дистанция подгрузки чанков
@export var unload_distance := 800.0  # Дистанция выгрузки чанков
@export var render_distance := 600.0  # Дальность прорисовки (и начало тумана)
@export var fog_enabled := true  # Включить туман для скрытия края мира
@export var car_path: NodePath
@export var camera_path: NodePath
@export var debug_print := false  # Выключить debug output для производительности
@export var enable_elevation := false  # Включить загрузку высот (экспериментально)
@export var elevation_scale := 1.0  # Масштаб высоты (1.0 = реальный)
@export var elevation_grid_resolution := 16  # Разрешение сетки высот на чанк

var osm_loader: Node
var _car: Node3D
var _camera: Camera3D
var _loaded_chunks: Dictionary = {}  # key: "x,z" -> value: Node3D (chunk node)
var _loading_chunks: Dictionary = {}  # key: "x,z" -> value: timestamp (start time in msec)
const CHUNK_LOAD_TIMEOUT := 30.0  # Таймаут загрузки чанка (секунд)
var _chunk_elevations: Dictionary = {}  # key: "x,z" -> value: elevation data
var _loading_elevations: Dictionary = {}  # Чанки с загружающимися высотами
var _elevation_queue: Array = []  # Очередь чанков для загрузки высот
var _active_elevation_requests: int = 0  # Количество активных запросов
const MAX_ELEVATION_REQUESTS := 2  # Максимум параллельных запросов
var _base_elevation := 0.0  # Базовая высота (высота стартовой точки)
var _last_check_pos := Vector3.ZERO
var _check_interval := 0.5  # Проверка каждые 0.5 сек
var _check_timer := 0.0
var _initial_loading := false  # Флаг начальной загрузки
var _initial_chunks_needed: Array[String] = []  # Чанки нужные для старта
var _initial_chunks_loaded: int = 0  # Количество загруженных начальных чанков
var _loading_paused := false  # Загрузка НЕ на паузе - автоматический старт
var _load_generation := 0  # Инкрементируется при reset для игнорирования старых callback'ов
var _entrance_nodes: Array = []  # Входы в здания/заведения из OSM
var _poi_nodes: Array = []  # Точечные заведения (shop/amenity как node)
var _parking_polygons: Array[PackedVector2Array] = []  # Полигоны парковок для исключения фонарей
var _road_segments: Array = []  # Сегменты дорог для позиционирования знаков парковки
var _road_spatial_hash: Dictionary = {}  # Spatial hash для быстрого поиска дорог
const ROAD_CELL_SIZE := 20.0  # Размер ячейки spatial hash для дорог
var _intersection_positions: Array[Vector2] = []  # Позиции перекрёстков (центры)
var _intersection_radii: Array[Vector2] = []  # Полуоси эллипсов (x=вдоль широкой дороги, y=вдоль узкой)
var _intersection_angles: Array[float] = []  # Углы поворота эллипсов (радианы, направление широкой дороги)
var _intersection_types: Array[bool] = []  # true = равнозначный (все дороги одного типа)
var _intersection_spatial_hash: Dictionary = {}  # Spatial hash для быстрого поиска перекрёстков
const INTERSECTION_CELL_SIZE := 50.0  # Размер ячейки spatial hash в метрах
var _created_lamp_positions: Dictionary = {}  # Позиции созданных фонарей для избежания дубликатов (ключ: chunk_key)
var _created_sign_positions: Dictionary = {}  # Позиции созданных знаков для избежания дубликатов
var _pending_lamps: Array = []  # Отложенные фонари (создаются после загрузки всех парковок)
var _lamps_created := false  # Флаг что фонари уже созданы
var _pending_parking_signs: Array = []  # Отложенные знаки парковки
var _finalization_state := 0  # 0=not started, 1=lamps, 2=signs, 3=done

# Многопоточная генерация зданий
var _building_queue: Array = []  # Очередь данных зданий для генерации
var _building_results: Array = []  # Готовые данные мешей из потоков
var _building_mutex: Mutex  # Для синхронизации доступа к результатам
var _pending_building_tasks: int = 0  # Счётчик активных задач в пуле
var _last_queue_size: int = 0  # Для отслеживания прогресса очереди
var _queue_stuck_time: float = 0.0  # Время зависания очереди
const QUEUE_STUCK_TIMEOUT := 5.0  # Таймаут зависшей очереди (секунд)

# Отложенная генерация инфраструктуры (фонари, знаки, светофоры)
var _infrastructure_queue: Array = []  # Очередь {type, pos, elevation, parent, ...}

# Отложенная генерация дорог и других тяжёлых объектов
var _road_queue: Array = []  # Очередь {nodes, tags, parent, elev_data}
var _curb_queue: Array = []  # Очередь бордюров (создаются после детекции перекрёстков)

# Road batching system - накопление geometry данных для mesh merging
var _road_batch_data: Dictionary = {}  # key: chunk_key -> { "highway": {vertices, uvs, normals, indices}, "primary": {...}, ...}
var _pending_batch_chunks: Array[String] = []  # Чанки с pending road batches (нужно финализировать)

# Window batching system - ONE MultiMesh per chunk instead of per-building
var _window_batch_data: Dictionary = {}  # key: chunk_key -> {transforms: Array[Transform3D], colors: Array[Color], parent: Node3D}
var _window_batch_materials: Array[ShaderMaterial] = []  # Материалы всех window batches для обновления is_night параметра
var _curb_smoothed_queue: Array = []  # Очередь сглаженных бордюров для генерации меша
var _curb_mesh_state: Dictionary = {}  # Текущее состояние генерации меша бордюра (для разбивки по кадрам)
var _curb_collision_results: Array = []  # Результаты расчёта коллизий из worker threads
var _curb_collision_mutex: Mutex  # Для синхронизации доступа к результатам коллизий

# Метрики времени для профилирования
var _perf_metrics: Dictionary = {}
var _perf_frame_count: int = 0
var _perf_enabled: bool = true

# Отложенная генерация terrain объектов (natural, landuse, leisure)
var _terrain_objects_queue: Array = []  # Очередь {type, nodes, tags, parent, elev_data}

# Очередь растительности (деревья, кусты, трава) - обрабатывается отдельно с меньшим приоритетом
var _vegetation_queue: Array = []  # Очередь {type, points, elev_data, parent, dense}

# FPS статистика для отображения на экране
var _fps_samples: Array[float] = []
var _fps_update_timer := 0.0
var _debug_label: Label = null
@export var show_debug_stats := true  # Показывать статистику на экране

# Debug визуализация границ чанков
var _show_chunk_boundaries := false
var _chunk_boundary_meshes: Dictionary = {}  # chunk_key -> MeshInstance3D

# Предиктивная загрузка чанков
@export_group("Predictive Loading")
@export var prediction_time_horizon := 15.0  # Горизонт предсказания (секунд)
@export var forward_load_multiplier := 2.0   # Множитель дистанции вперёд
@export var side_load_multiplier := 0.5      # Множитель дистанции сбоку
@export var min_speed_for_prediction := 5.0  # м/с - ниже этого радиальная загрузка

var _smoothed_velocity := Vector3.ZERO
var _velocity_smoothing := 0.7  # Фактор сглаживания скорости
var _chunk_load_queue: Array[Dictionary] = []  # Очередь загрузки {key, priority, distance}
var _current_load_count := 0
const MAX_CONCURRENT_LOADS := 3  # Макс параллельных запросов к OSM API
const PREDICTION_INTERVALS := 3  # Точки предсказания (5с, 10с, 15с)

# Сцены для припаркованных машин
var _parked_car_scene: PackedScene
var _parked_lada_scene: PackedScene
var _parked_taxi_scene: PackedScene

# Цвета для припаркованных машин
const PARKED_CAR_COLORS := [
	Color(0.8, 0.1, 0.1),  # Красный
	Color(0.1, 0.3, 0.8),  # Синий
	Color(0.9, 0.9, 0.9),  # Белый
	Color(0.1, 0.1, 0.1),  # Чёрный
	Color(0.5, 0.5, 0.5),  # Серый
	Color(0.2, 0.5, 0.2),  # Зелёный
	Color(0.9, 0.7, 0.1),  # Жёлтый
]

# Цвета для разных типов поверхностей
const COLORS := {
	"road_primary": Color(0.3, 0.3, 0.3),
	"road_secondary": Color(0.4, 0.4, 0.4),
	"road_residential": Color(0.5, 0.5, 0.5),
	"road_path": Color(0.6, 0.5, 0.4),
	"building": Color(0.6, 0.4, 0.3),
	"water": Color(0.2, 0.4, 0.7),
	"grass": Color(0.3, 0.6, 0.3),
	"forest": Color(0.2, 0.5, 0.2),
	"farmland": Color(0.7, 0.7, 0.4),
	"default": Color(0.4, 0.5, 0.4),
}

const ROAD_WIDTHS := {
	"motorway": 16.0,
	"trunk": 14.0,
	"primary": 12.0,
	"secondary": 10.0,
	"tertiary": 8.0,
	"residential": 6.0,
	"unclassified": 5.0,
	"service": 4.0,
	"footway": 2.0,
	"path": 1.5,
	"cycleway": 2.5,
	"track": 3.5,
}

func _ready() -> void:
	# Инициализируем mutex для многопоточности
	_building_mutex = Mutex.new()
	_curb_collision_mutex = Mutex.new()

	osm_loader = OSMLoaderScript.new()
	add_child(osm_loader)
	osm_loader.data_loaded.connect(_on_osm_data_loaded)
	osm_loader.load_failed.connect(_on_osm_load_failed)

	# Создаём debug label для статистики
	if show_debug_stats:
		_create_debug_label()

	# Инициализируем текстуры
	_init_textures()

	# Загружаем сцены для припаркованных машин
	_parked_car_scene = preload("res://traffic/npc_car.tscn")
	_parked_lada_scene = preload("res://traffic/npc_lada_2109.tscn")
	_parked_taxi_scene = preload("res://traffic/npc_taxi.tscn")

	# Найти машину
	if car_path:
		_car = get_node(car_path)
	else:
		# Попробуем найти автоматически
		await get_tree().process_frame
		_car = get_tree().get_first_node_in_group("car")
		if not _car:
			var car_node = get_parent().get_node_or_null("Car")
			if car_node:
				_car = car_node

	# Найти камеру (для загрузки при полёте)
	if camera_path:
		_camera = get_node(camera_path)

	# Подключаемся к NightModeManager
	await get_tree().process_frame
	_connect_to_night_mode()

	# Настраиваем дальность прорисовки и туман
	_setup_render_distance()

	print("OSM: Ready for loading (waiting for start_loading call)...")

func _init_textures() -> void:
	if _textures_initialized:
		return

	print("OSM: Initializing textures...")
	var start_time := Time.get_ticks_msec()

	# Текстуры дорог
	_road_textures["highway"] = TextureGeneratorScript.create_highway_texture(512, 4)
	_road_textures["primary"] = TextureGeneratorScript.create_primary_texture(512, 4)  # Одна сплошная в центре
	_road_textures["residential"] = TextureGeneratorScript.create_road_texture(256, 2, true, false)
	_road_textures["path"] = TextureGeneratorScript.create_sidewalk_texture(256)
	_road_textures["intersection"] = TextureGeneratorScript.create_intersection_texture(256)  # Чистый асфальт

	# Текстуры зданий (без окон - окна добавляются как 3D объекты)
	_building_textures["panel"] = TextureGeneratorScript.create_panel_building_no_windows(512, 5)
	_building_textures["brick"] = TextureGeneratorScript.create_brick_building_no_windows(512)
	_building_textures["wall"] = TextureGeneratorScript.create_wall_texture(256)
	_building_textures["roof"] = TextureGeneratorScript.create_roof_texture(256)

	# Текстуры земли - загружаем PBR текстуру травы
	var grass_img := Image.load_from_file("res://textures/Grass004_1K-JPG_Color.jpg")
	if grass_img:
		_ground_textures["grass"] = ImageTexture.create_from_image(grass_img)
	else:
		_ground_textures["grass"] = TextureGeneratorScript.create_forest_texture(256)
	_ground_textures["forest"] = TextureGeneratorScript.create_forest_texture(256)
	_ground_textures["water"] = TextureGeneratorScript.create_water_texture(256)

	# Normal maps
	_normal_textures["asphalt"] = TextureGeneratorScript.create_asphalt_normal(256)
	_normal_textures["brick"] = TextureGeneratorScript.create_brick_normal(256)
	_normal_textures["concrete"] = TextureGeneratorScript.create_concrete_normal(256)
	_normal_textures["panel"] = TextureGeneratorScript.create_panel_building_normal(512, 5, 4)

	_textures_initialized = true
	var elapsed := Time.get_ticks_msec() - start_time
	print("OSM: Textures initialized in %d ms" % elapsed)

func _process(delta: float) -> void:
	var _frame_start := Time.get_ticks_usec()

	# Обрабатываем готовые здания из worker threads (даже на паузе)
	var t0 := Time.get_ticks_usec()
	_process_building_results()
	_record_perf("building_results", Time.get_ticks_usec() - t0)

	# Обрабатываем очередь дорог (3 дороги за кадр)
	t0 = Time.get_ticks_usec()
	_process_road_queue()
	_record_perf("road_queue", Time.get_ticks_usec() - t0)

	# Обрабатываем очередь terrain объектов (2 за кадр)
	t0 = Time.get_ticks_usec()
	_process_terrain_objects_queue()
	_record_perf("terrain_queue", Time.get_ticks_usec() - t0)

	# Обрабатываем очередь инфраструктуры (1 объект за кадр)
	t0 = Time.get_ticks_usec()
	_process_infrastructure_queue()
	_record_perf("infra_queue", Time.get_ticks_usec() - t0)

	# Обрабатываем очередь растительности (1 за кадр, низкий приоритет)
	t0 = Time.get_ticks_usec()
	_process_vegetation_queue()
	_record_perf("vegetation_queue", Time.get_ticks_usec() - t0)

	# Применяем коллизии бордюров из worker threads
	t0 = Time.get_ticks_usec()
	_apply_curb_collisions()
	_record_perf("curb_collisions", Time.get_ticks_usec() - t0)

	var _frame_time := (Time.get_ticks_usec() - _frame_start) / 1000.0
	_record_perf("total_frame", int(_frame_time * 1000))

	_perf_frame_count += 1
	if _perf_enabled and _perf_frame_count % 600 == 0:  # Каждые 10 сек при 60fps
		_print_perf_metrics()

	# Обновляем debug статистику
	_update_debug_stats(delta)

	# Проверяем завершение начальной загрузки (когда очереди опустошились)
	if _initial_loading:
		_check_initial_load_complete()

	# Не обновляем чанки если загрузка на паузе
	if _loading_paused:
		return

	_check_timer += delta
	if _check_timer < _check_interval:
		return
	_check_timer = 0.0

	# Определяем позицию для загрузки чанков
	# Используем текущую активную камеру
	var player_pos := Vector3.ZERO
	var viewport := get_viewport()
	if viewport:
		var current_cam := viewport.get_camera_3d()
		if current_cam:
			player_pos = current_cam.global_position
		elif _car:
			player_pos = _car.global_position
	elif _car:
		player_pos = _car.global_position

	# Проверяем нужны ли новые чанки
	_update_chunks(player_pos)

# Начать загрузку карты
func start_loading() -> void:
	print("OSM: Starting initial loading... (generation %d)" % _load_generation)
	print("OSM: State before start: _loaded_chunks=%d, _loading_chunks=%d" % [_loaded_chunks.size(), _loading_chunks.size()])

	# ПРИНУДИТЕЛЬНАЯ очистка на случай если reset_terrain не очистил
	if _loaded_chunks.size() > 0:
		print("OSM: WARNING - _loaded_chunks not empty, clearing...")
		_loaded_chunks.clear()
	if _loading_chunks.size() > 0:
		print("OSM: WARNING - _loading_chunks not empty, clearing...")
		_loading_chunks.clear()

	_loading_paused = false
	_initial_loading = true
	_initial_chunks_loaded = 0
	_parking_polygons.clear()  # Очищаем парковки при новой загрузке
	_created_lamp_positions.clear()  # Очищаем позиции фонарей
	_pending_lamps.clear()  # Очищаем отложенные фонари
	_pending_parking_signs.clear()  # Очищаем отложенные знаки парковки
	_lamps_created = false  # Сбрасываем флаг
	_intersection_positions.clear()  # Очищаем перекрёстки
	_intersection_radii.clear()
	_intersection_angles.clear()
	_intersection_types.clear()
	_intersection_spatial_hash.clear()  # Очищаем spatial hash
	_curb_queue.clear()  # Очищаем очередь бордюров
	_curb_smoothed_queue.clear()  # Очищаем очередь сглаженных бордюров
	_curb_mesh_state.clear()  # Очищаем состояние генерации меша
	_curb_collision_mutex.lock()
	_curb_collision_results.clear()  # Очищаем очередь коллизий
	_curb_collision_mutex.unlock()

	# Определяем какие чанки нужны для старта
	# Используем позицию машины если она есть, иначе Vector3.ZERO
	var spawn_pos := Vector3.ZERO
	if _car:
		spawn_pos = _car.global_position
		print("OSM: Loading chunks around car position (%.1f, %.1f, %.1f)" % [spawn_pos.x, spawn_pos.y, spawn_pos.z])
	else:
		print("OSM: Loading chunks around spawn point (0, 0, 0)")

	_initial_chunks_needed = _get_needed_chunks(spawn_pos)
	print("OSM: Need to load %d chunks for initial area" % _initial_chunks_needed.size())

	print("OSM: Emitting initial_load_started signal...")
	initial_load_started.emit()
	print("OSM: initial_load_started signal emitted")

	# Загружаем начальные чанки
	var chunks_to_load := 0
	for chunk_key in _initial_chunks_needed:
		if not _loaded_chunks.has(chunk_key) and not _loading_chunks.has(chunk_key):
			var coords: Array = chunk_key.split(",")
			var chunk_x := int(coords[0])
			var chunk_z := int(coords[1])
			_load_chunk(chunk_x, chunk_z)
			chunks_to_load += 1
		else:
			if _loaded_chunks.has(chunk_key):
				print("OSM: Chunk %s already loaded, skipping" % chunk_key)
			if _loading_chunks.has(chunk_key):
				print("OSM: Chunk %s already loading, skipping" % chunk_key)

	print("OSM: Started loading %d chunks (total needed: %d, already loaded: %d)" % [chunks_to_load, _initial_chunks_needed.size(), _initial_chunks_needed.size() - chunks_to_load])

	# Если нет чанков для загрузки - сразу завершаем
	if chunks_to_load == 0:
		print("OSM: No chunks to load, completing immediately")
		_initial_loading = false
		initial_load_complete.emit()

# Проверяем завершение начальной загрузки
func _check_initial_load_complete() -> void:
	if not _initial_loading:
		return

	# Считаем сколько начальных чанков загружено
	var loaded_count := 0
	for chunk_key in _initial_chunks_needed:
		if _loaded_chunks.has(chunk_key):
			loaded_count += 1

	_initial_chunks_loaded = loaded_count

	# Считаем общий прогресс: 50% на чанки, 50% на очереди
	var total_chunks: int = _initial_chunks_needed.size()
	var chunk_progress: float = float(loaded_count) / float(max(1, total_chunks))  # 0.0-1.0

	# Считаем размер всех очередей
	var total_queued: int = _building_results.size() + _road_queue.size() + _terrain_objects_queue.size() + _infrastructure_queue.size() + _pending_building_tasks

	# DEBUG: Детальное логирование очередей
	if loaded_count >= total_chunks and total_queued > 0:
		print("OSM DEBUG: Chunks loaded %d/%d, but queues not empty:" % [loaded_count, total_chunks])
		print("  - _building_results: %d" % _building_results.size())
		print("  - _road_queue: %d" % _road_queue.size())
		print("  - _terrain_objects_queue: %d" % _terrain_objects_queue.size())
		print("  - _infrastructure_queue: %d" % _infrastructure_queue.size())
		print("  - _pending_building_tasks: %d" % _pending_building_tasks)

	# DEBUG: Проверяем зависшие чанки в _loading_chunks
	if loaded_count < total_chunks:
		var missing_chunks: Array[String] = []
		for chunk_key in _initial_chunks_needed:
			if not _loaded_chunks.has(chunk_key):
				missing_chunks.append(chunk_key)

		if missing_chunks.size() > 0:
			print("OSM DEBUG: Missing chunks (%d): %s" % [missing_chunks.size(), str(missing_chunks)])
			print("  - Currently loading: %s" % str(_loading_chunks.keys()))

			# Проверяем таймауты для загружающихся чанков
			var current_time := Time.get_ticks_msec()
			var timed_out_chunks: Array[String] = []
			for chunk_key in _loading_chunks.keys():
				var load_start_time: int = _loading_chunks[chunk_key]
				var elapsed_sec := float(current_time - load_start_time) / 1000.0
				if elapsed_sec > CHUNK_LOAD_TIMEOUT:
					timed_out_chunks.append(chunk_key)
					print("OSM WARNING: Chunk %s timed out after %.1f seconds!" % [chunk_key, elapsed_sec])

			# Убираем зависшие чанки и пытаемся загрузить заново
			for chunk_key in timed_out_chunks:
				_loading_chunks.erase(chunk_key)
				_current_load_count = max(0, _current_load_count - 1)
				print("OSM: Retrying timed out chunk %s..." % chunk_key)
				# Перезагружаем чанк
				var coords: Array = chunk_key.split(",")
				var chunk_x := int(coords[0])
				var chunk_z := int(coords[1])
				_load_chunk(chunk_x, chunk_z)

	# Статус
	var status: String
	if loaded_count < total_chunks:
		status = "Загрузка чанков: %d / %d" % [loaded_count, total_chunks]
	elif total_queued > 0:
		status = "Генерация объектов: %d в очереди" % total_queued
	else:
		status = "Финализация..."

	# Общий прогресс: 60% - чанки, 40% - очереди
	var total_progress: float = chunk_progress * 0.6 + (1.0 - float(total_queued) / float(max(1, total_queued + 100))) * 0.4
	total_progress = clampf(total_progress, 0.0, 1.0)

	initial_load_progress.emit(total_progress, status)

	# Все начальные чанки загружены?
	if loaded_count >= total_chunks:
		# Проверяем что все очереди обработаны (для плавности старта)
		var queues_empty := _building_results.is_empty() and _road_queue.is_empty() and _terrain_objects_queue.is_empty() and _infrastructure_queue.is_empty() and _pending_building_tasks == 0
		if not queues_empty:
			# Отслеживаем зависание очереди
			if total_queued == _last_queue_size:
				_queue_stuck_time += get_process_delta_time()
				if _queue_stuck_time >= QUEUE_STUCK_TIMEOUT:
					# Очередь зависла - принудительно сбрасываем pending tasks и переходим к финализации
					print("OSM: Queue stuck at %d items for %.1fs, forcing completion..." % [total_queued, _queue_stuck_time])
					_pending_building_tasks = 0
					_queue_stuck_time = 0.0
					# НЕ делаем return - продолжаем к финализации ниже
				else:
					# Очередь ещё не зависла, ждём дальше
					return
			else:
				# Размер очереди изменился - сбрасываем таймер и ждём
				_last_queue_size = total_queued
				_queue_stuck_time = 0.0
				return
			# Если мы тут - очередь зависла и мы форсируем завершение

		# Финализация: создаём фонари и знаки парковки СРАЗУ (без батчинга)
		if _finalization_state == 0:
			print("OSM: Starting finalization...")
			_finalization_state = 1
			initial_load_progress.emit(0.95, "Финализация: создание фонарей (%d)..." % _pending_lamps.size())
			# Создаём все фонари сразу
			_create_pending_lamps()
			print("OSM: Lamps done, starting parking signs...")
			_finalization_state = 2
			initial_load_progress.emit(0.98, "Финализация: создание знаков парковки (%d)..." % _pending_parking_signs.size())
			# Создаём все знаки парковки сразу
			_create_pending_parking_signs()
			print("OSM: Parking signs done")
			_finalization_state = 3

		_initial_loading = false
		print("OSM: Initial loading complete! %d chunks loaded" % loaded_count)

		initial_load_complete.emit()

func _update_chunks(player_pos: Vector3) -> void:
	# Определяем какие чанки нужны
	var needed_chunks := _get_needed_chunks(player_pos)

	# Загружаем недостающие
	for chunk_key in needed_chunks:
		if not _loaded_chunks.has(chunk_key) and not _loading_chunks.has(chunk_key):
			var coords: Array = chunk_key.split(",")
			var chunk_x := int(coords[0])
			var chunk_z := int(coords[1])
			_load_chunk(chunk_x, chunk_z)

	# Выгружаем далёкие чанки
	var chunks_to_unload: Array[String] = []
	for chunk_key in _loaded_chunks:
		var coords: Array = chunk_key.split(",")
		var chunk_x := int(coords[0])
		var chunk_z := int(coords[1])
		var chunk_center := Vector3(chunk_x * chunk_size, 0, chunk_z * chunk_size)
		var dist := player_pos.distance_to(chunk_center)
		if dist > unload_distance:
			chunks_to_unload.append(chunk_key)

	for chunk_key in chunks_to_unload:
		_unload_chunk(chunk_key)

func _get_needed_chunks(player_pos: Vector3) -> Array[String]:
	var result: Array[String] = []
	var player_chunk_x := int(floor(player_pos.x / chunk_size))
	var player_chunk_z := int(floor(player_pos.z / chunk_size))

	# Радиус в чанках
	var radius_chunks := int(ceil(load_distance / chunk_size))

	for dx in range(-radius_chunks, radius_chunks + 1):
		for dz in range(-radius_chunks, radius_chunks + 1):
			var cx := player_chunk_x + dx
			var cz := player_chunk_z + dz
			var chunk_center := Vector3(cx * chunk_size + chunk_size / 2, 0, cz * chunk_size + chunk_size / 2)
			if player_pos.distance_to(chunk_center) <= load_distance:
				result.append("%d,%d" % [cx, cz])

	return result


## Простая предиктивная загрузка - загружаем чанки впереди по движению
func _update_chunks_simple_predictive(player_pos: Vector3, velocity: Vector3) -> void:
	var speed := velocity.length()

	# Базовые чанки вокруг игрока (всегда)
	var needed_chunks := _get_needed_chunks(player_pos)

	# При быстром движении добавляем чанки впереди
	if speed > min_speed_for_prediction:
		var look_ahead := velocity.normalized() * load_distance * forward_load_multiplier
		var ahead_pos := player_pos + look_ahead
		var ahead_chunks := _get_needed_chunks(ahead_pos)
		for chunk_key in ahead_chunks:
			if chunk_key not in needed_chunks:
				needed_chunks.append(chunk_key)

	# Загружаем недостающие
	for chunk_key in needed_chunks:
		if not _loaded_chunks.has(chunk_key) and not _loading_chunks.has(chunk_key):
			var coords: Array = chunk_key.split(",")
			var chunk_x := int(coords[0])
			var chunk_z := int(coords[1])
			_load_chunk(chunk_x, chunk_z)

	# Выгружаем далёкие чанки (простая радиальная выгрузка)
	var chunks_to_unload: Array[String] = []
	for chunk_key in _loaded_chunks:
		var coords: Array = chunk_key.split(",")
		var chunk_x := int(coords[0])
		var chunk_z := int(coords[1])
		var chunk_center := Vector3(chunk_x * chunk_size + chunk_size / 2, 0, chunk_z * chunk_size + chunk_size / 2)
		var dist := player_pos.distance_to(chunk_center)
		if dist > unload_distance:
			chunks_to_unload.append(chunk_key)

	for chunk_key in chunks_to_unload:
		_unload_chunk(chunk_key)


## Старая сложная предиктивная загрузка (отключена)
func _update_chunks_predictive(player_pos: Vector3, velocity: Vector3) -> void:
	# Получаем приоритизированный список чанков
	var predicted_chunks := _get_predicted_chunks(player_pos, velocity)

	# Добавляем новые чанки в очередь
	for chunk_data in predicted_chunks:
		var chunk_key: String = chunk_data["key"]

		# Пропускаем уже загруженные/загружающиеся
		if _loaded_chunks.has(chunk_key) or _loading_chunks.has(chunk_key):
			continue

		# Проверяем, есть ли уже в очереди
		var in_queue := false
		for queued in _chunk_load_queue:
			if queued["key"] == chunk_key:
				# Обновляем приоритет если выше
				if chunk_data["priority"] > queued["priority"]:
					queued["priority"] = chunk_data["priority"]
				in_queue = true
				break

		if not in_queue:
			_chunk_load_queue.append(chunk_data)

	# Сортируем очередь по приоритету (убывание)
	_chunk_load_queue.sort_custom(func(a, b): return a["priority"] > b["priority"])

	# Обрабатываем очередь (ограничиваем параллельные загрузки)
	while _current_load_count < MAX_CONCURRENT_LOADS and _chunk_load_queue.size() > 0:
		var next_chunk: Dictionary = _chunk_load_queue.pop_front()
		var chunk_key: String = next_chunk["key"]

		# Повторная проверка (могло загрузиться пока ждало в очереди)
		if _loaded_chunks.has(chunk_key) or _loading_chunks.has(chunk_key):
			continue

		var coords: Array = chunk_key.split(",")
		var chunk_x := int(coords[0])
		var chunk_z := int(coords[1])
		_load_chunk_tracked(chunk_x, chunk_z)

	# Направленная выгрузка
	_unload_distant_chunks(player_pos, velocity)


## Загрузка чанка с отслеживанием количества
func _load_chunk_tracked(chunk_x: int, chunk_z: int) -> void:
	_current_load_count += 1
	_load_chunk(chunk_x, chunk_z)


## Получает приоритизированный список чанков на основе предсказания
func _get_predicted_chunks(player_pos: Vector3, velocity: Vector3) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var added_chunks: Dictionary = {}
	var speed := velocity.length()

	# При низкой скорости - радиальная загрузка
	if speed < min_speed_for_prediction:
		var radial_chunks := _get_needed_chunks(player_pos)
		for chunk_key in radial_chunks:
			result.append({
				"key": chunk_key,
				"priority": 1.0,
				"distance": _get_chunk_distance(chunk_key, player_pos)
			})
		return result

	# Направление движения (XZ плоскость)
	var move_dir := Vector3(velocity.x, 0, velocity.z).normalized()

	# 1. Сначала добавляем ближайшие чанки (безопасность)
	var immediate_chunks := _get_needed_chunks(player_pos)
	for chunk_key in immediate_chunks:
		if not added_chunks.has(chunk_key):
			added_chunks[chunk_key] = true
			result.append({
				"key": chunk_key,
				"priority": 10.0,  # Высший приоритет
				"distance": _get_chunk_distance(chunk_key, player_pos)
			})

	# 2. Добавляем чанки по предсказанным позициям
	for i in range(PREDICTION_INTERVALS):
		var t := (i + 1) * (prediction_time_horizon / PREDICTION_INTERVALS)
		var predicted_pos := player_pos + velocity * t

		# Чанки вокруг предсказанной позиции с направленным смещением
		var predicted_chunks := _get_directional_chunks(predicted_pos, move_dir, speed)

		for chunk_data in predicted_chunks:
			var chunk_key: String = chunk_data["key"]
			if not added_chunks.has(chunk_key):
				added_chunks[chunk_key] = true
				# Приоритет уменьшается с временем предсказания
				chunk_data["priority"] = 5.0 / (i + 1)
				result.append(chunk_data)

	# Сортируем по приоритету
	result.sort_custom(func(a, b): return a["priority"] > b["priority"])

	return result


## Чанки вокруг позиции с учётом направления движения
func _get_directional_chunks(center_pos: Vector3, move_dir: Vector3, speed: float) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var center_chunk_x := int(floor(center_pos.x / chunk_size))
	var center_chunk_z := int(floor(center_pos.z / chunk_size))

	# Эффективные радиусы
	var forward_radius := load_distance * forward_load_multiplier
	var side_radius := load_distance * side_load_multiplier

	# Адаптация по скорости (быстрее = дальше смотрим)
	var speed_factor: float = clampf(speed / 30.0, 1.0, 2.0)  # 30 м/с = 108 км/ч
	forward_radius *= speed_factor

	var radius_chunks := int(ceil(forward_radius / chunk_size))

	for dx in range(-radius_chunks, radius_chunks + 1):
		for dz in range(-radius_chunks, radius_chunks + 1):
			var cx := center_chunk_x + dx
			var cz := center_chunk_z + dz
			var chunk_center := Vector3(
				cx * chunk_size + chunk_size / 2,
				0,
				cz * chunk_size + chunk_size / 2
			)

			var to_chunk := chunk_center - center_pos
			to_chunk.y = 0
			var dist := to_chunk.length()

			if dist < 0.01:
				# Чанк в центре
				result.append({
					"key": "%d,%d" % [cx, cz],
					"priority": 1.0,
					"distance": dist
				})
				continue

			var dir_to_chunk := to_chunk.normalized()

			# Выравнивание с направлением движения (-1 до 1)
			var alignment := move_dir.dot(dir_to_chunk)

			# Эффективный радиус по направлению
			var effective_radius: float
			if alignment > 0:
				effective_radius = lerpf(side_radius, forward_radius, alignment)
			else:
				effective_radius = side_radius * (1.0 + alignment * 0.5)  # Сжимаем сзади

			if dist <= effective_radius:
				var dist_factor := 1.0 - (dist / forward_radius)
				var priority := (alignment + 1.0) * 0.5 * dist_factor

				result.append({
					"key": "%d,%d" % [cx, cz],
					"priority": priority,
					"distance": dist
				})

	return result


## Выгрузка чанков с учётом направления движения
func _unload_distant_chunks(player_pos: Vector3, velocity: Vector3) -> void:
	var speed := velocity.length()
	var move_dir := Vector3(velocity.x, 0, velocity.z).normalized() if speed > 0.1 else Vector3.ZERO

	var chunks_to_unload: Array[String] = []

	for chunk_key in _loaded_chunks:
		var coords: Array = chunk_key.split(",")
		var chunk_x := int(coords[0])
		var chunk_z := int(coords[1])
		var chunk_center := Vector3(
			chunk_x * chunk_size + chunk_size / 2,
			0,
			chunk_z * chunk_size + chunk_size / 2
		)

		var dist := player_pos.distance_to(chunk_center)

		# При низкой скорости - стандартная радиальная выгрузка
		if speed < min_speed_for_prediction:
			if dist > unload_distance:
				chunks_to_unload.append(chunk_key)
			continue

		# Направленная выгрузка
		var to_chunk := chunk_center - player_pos
		to_chunk.y = 0
		var dir_to_chunk := to_chunk.normalized() if to_chunk.length() > 0.01 else Vector3.ZERO
		var alignment := move_dir.dot(dir_to_chunk)

		# Пороги выгрузки по направлению
		var effective_unload_dist: float
		if alignment > 0.3:  # Впереди
			effective_unload_dist = unload_distance * 1.5
		elif alignment < -0.3:  # Сзади
			effective_unload_dist = unload_distance * 0.7
		else:  # Сбоку
			effective_unload_dist = unload_distance

		if dist > effective_unload_dist:
			chunks_to_unload.append(chunk_key)

	for chunk_key in chunks_to_unload:
		_unload_chunk(chunk_key)
		# Удаляем из очереди если там есть
		_chunk_load_queue = _chunk_load_queue.filter(func(c): return c["key"] != chunk_key)


## Расстояние до центра чанка
func _get_chunk_distance(chunk_key: String, pos: Vector3) -> float:
	var coords: Array = chunk_key.split(",")
	var chunk_x := int(coords[0])
	var chunk_z := int(coords[1])
	var chunk_center := Vector3(
		chunk_x * chunk_size + chunk_size / 2,
		0,
		chunk_z * chunk_size + chunk_size / 2
	)
	return pos.distance_to(chunk_center)


func _load_chunk(chunk_x: int, chunk_z: int) -> void:
	var chunk_key := "%d,%d" % [chunk_x, chunk_z]
	_loading_chunks[chunk_key] = Time.get_ticks_msec()  # Сохраняем время начала загрузки

	# Вычисляем центр чанка в координатах lat/lon
	var center_x := chunk_x * chunk_size + chunk_size / 2
	var center_z := chunk_z * chunk_size + chunk_size / 2

	# Конвертируем локальные координаты обратно в lat/lon
	# Z инвертирован в системе координат, поэтому вычитаем
	var chunk_lat := start_lat - center_z / 111000.0
	var chunk_lon := start_lon + center_x / (111000.0 * cos(deg_to_rad(start_lat)))

	print("OSM: Loading chunk %s at lat=%.4f, lon=%.4f" % [chunk_key, chunk_lat, chunk_lon])

	# Добавляем в очередь загрузки высот
	if enable_elevation and not _chunk_elevations.has(chunk_key) and not _loading_elevations.has(chunk_key):
		_elevation_queue.append({"key": chunk_key, "lat": chunk_lat, "lon": chunk_lon})
		_process_elevation_queue()

	# Создаём отдельный загрузчик для этого чанка
	var loader := OSMLoaderScript.new()
	add_child(loader)
	var gen := _load_generation  # Захватываем текущую генерацию
	loader.data_loaded.connect(_on_chunk_data_loaded.bind(chunk_key, loader, gen))
	loader.load_failed.connect(_on_chunk_load_failed.bind(chunk_key, loader, gen))
	loader.load_area(chunk_lat, chunk_lon, chunk_size / 2 + 100)  # +100м overlap для зданий на границах

func _load_chunk_at_position(pos: Vector3) -> void:
	var chunk_x := int(floor(pos.x / chunk_size))
	var chunk_z := int(floor(pos.z / chunk_size))
	_load_chunk(chunk_x, chunk_z)

func _unload_chunk(chunk_key: String) -> void:
	if _loaded_chunks.has(chunk_key):
		var chunk_node: Node3D = _loaded_chunks[chunk_key]
		chunk_node.queue_free()
		_loaded_chunks.erase(chunk_key)
		_chunk_elevations.erase(chunk_key)

		# Очищаем позиции фонарей и знаков в выгруженном чанке
		_clear_chunk_objects_positions(chunk_key)

		print("OSM: Unloaded chunk %s" % chunk_key)


## Очищает позиции объектов (фонарей, знаков) в границах чанка
func _clear_chunk_objects_positions(chunk_key: String) -> void:
	var coords := chunk_key.split(",")
	var chunk_x := int(coords[0])
	var chunk_z := int(coords[1])

	# Границы чанка в мировых координатах
	var min_x := chunk_x * chunk_size
	var max_x := min_x + chunk_size
	var min_z := chunk_z * chunk_size
	var max_z := min_z + chunk_size

	# Очищаем позиции фонарей в этом чанке
	var lamps_to_remove: Array = []
	for pos_key in _created_lamp_positions.keys():
		var parts: PackedStringArray = pos_key.split("_")
		if parts.size() >= 2:
			var x := int(parts[0])
			var z := int(parts[1])
			if x >= min_x and x < max_x and z >= min_z and z < max_z:
				lamps_to_remove.append(pos_key)

	for key in lamps_to_remove:
		_created_lamp_positions.erase(key)

	# Очищаем позиции знаков в этом чанке
	var signs_to_remove: Array = []
	for pos_key in _created_sign_positions.keys():
		var parts: PackedStringArray = pos_key.split("_")
		if parts.size() >= 2:
			var x := int(parts[0])
			var z := int(parts[1])
			if x >= min_x and x < max_x and z >= min_z and z < max_z:
				signs_to_remove.append(pos_key)

	for key in signs_to_remove:
		_created_sign_positions.erase(key)


# Сбрасывает все загруженные чанки (для смены локации)
func reset_terrain() -> void:
	print("OSM: Resetting terrain...")
	# Инкрементируем generation чтобы игнорировать callback'и от старых загрузок
	_load_generation += 1
	print("OSM: Load generation incremented to %d" % _load_generation)
	# Выгружаем все чанки
	var chunks_to_unload: Array[String] = []
	for chunk_key in _loaded_chunks:
		chunks_to_unload.append(chunk_key)
	for chunk_key in chunks_to_unload:
		_unload_chunk(chunk_key)

	# Сбрасываем состояние
	_loading_chunks.clear()
	_chunk_elevations.clear()
	_loading_elevations.clear()
	_elevation_queue.clear()
	_active_elevation_requests = 0
	_base_elevation = 0.0
	_initial_loading = false
	_initial_chunks_needed.clear()
	_initial_chunks_loaded = 0
	_loading_paused = true
	_finalization_state = 0  # Сбрасываем состояние финализации
	# Предиктивная загрузка
	_chunk_load_queue.clear()
	_current_load_count = 0
	_smoothed_velocity = Vector3.ZERO
	# Сбрасываем таймеры зависания
	_queue_stuck_time = 0.0
	_last_queue_size = 0

	# КРИТИЧНО: Очищаем все очереди генерации объектов
	_building_mutex.lock()
	_building_results.clear()
	_pending_building_tasks = 0
	_building_mutex.unlock()
	_curb_collision_mutex.lock()
	_curb_collision_results.clear()
	_curb_collision_mutex.unlock()
	_road_queue.clear()
	_terrain_objects_queue.clear()
	_infrastructure_queue.clear()
	_vegetation_queue.clear()
	_pending_lamps.clear()
	_pending_parking_signs.clear()
	_lamps_created = false

	# Очищаем словари позиций объектов и парковок
	_created_lamp_positions.clear()
	_created_sign_positions.clear()
	_road_segments.clear()
	_road_spatial_hash.clear()
	_parking_polygons.clear()

	print("OSM: Terrain reset complete")

func _on_osm_load_failed(error: String) -> void:
	push_error("OSM load failed: " + error)

func _on_chunk_load_failed(error: String, chunk_key: String, loader: Node, gen: int) -> void:
	# Игнорируем callback если это от старой загрузки
	if gen != _load_generation:
		print("OSM: Ignoring stale failed chunk %s (gen %d != %d)" % [chunk_key, gen, _load_generation])
		loader.queue_free()
		return

	push_error("OSM chunk %s load failed: %s" % [chunk_key, error])
	_loading_chunks.erase(chunk_key)
	_current_load_count = max(0, _current_load_count - 1)  # Декремент счётчика
	loader.queue_free()

# Обработка очереди загрузки высот (ограничение параллельных запросов)
func _process_elevation_queue() -> void:
	while _active_elevation_requests < MAX_ELEVATION_REQUESTS and _elevation_queue.size() > 0:
		var item: Dictionary = _elevation_queue.pop_front()
		var chunk_key: String = item["key"]
		var chunk_lat: float = item["lat"]
		var chunk_lon: float = item["lon"]

		if _chunk_elevations.has(chunk_key) or _loading_elevations.has(chunk_key):
			continue

		_loading_elevations[chunk_key] = true
		_active_elevation_requests += 1

		var elev_loader := ElevationLoaderScript.new()
		add_child(elev_loader)
		elev_loader.elevation_loaded.connect(_on_elevation_loaded.bind(chunk_key, elev_loader))
		elev_loader.elevation_failed.connect(_on_elevation_failed.bind(chunk_key, elev_loader))
		elev_loader.load_elevation_grid(chunk_lat, chunk_lon, chunk_size / 2 + 50, elevation_grid_resolution)

func _on_elevation_loaded(elev_data: Dictionary, chunk_key: String, loader: Node) -> void:
	print("Elevation: Chunk %s loaded" % chunk_key)
	_loading_elevations.erase(chunk_key)
	_active_elevation_requests -= 1

	# Устанавливаем базовую высоту по первому чанку
	if _base_elevation == 0.0 and chunk_key == "0,0":
		var grid: Array = elev_data.get("grid", [])
		if grid.size() > 0:
			var mid := grid.size() / 2
			_base_elevation = grid[mid][mid]
			print("Elevation: Base elevation set to %.1f m" % _base_elevation)

			# Скрываем статичную землю, теперь используем террейн-меши
			var static_ground := get_parent().get_node_or_null("StaticGround")
			if static_ground:
				static_ground.visible = false
				# Отключаем коллизию статичной земли
				static_ground.set_collision_layer_value(1, false)

	_chunk_elevations[chunk_key] = elev_data

	# Создаём меш террейна для этого чанка
	if _loaded_chunks.has(chunk_key):
		_create_terrain_mesh(chunk_key, _loaded_chunks[chunk_key])

	loader.queue_free()

	# Продолжаем обработку очереди
	_process_elevation_queue()

func _on_elevation_failed(error: String, chunk_key: String, loader: Node) -> void:
	push_warning("Elevation chunk %s failed: %s" % [chunk_key, error])
	_loading_elevations.erase(chunk_key)
	_active_elevation_requests -= 1
	loader.queue_free()

	# Продолжаем обработку очереди
	_process_elevation_queue()

func _on_osm_data_loaded(osm_data: Dictionary) -> void:
	print("OSM: Initial data loaded")
	# Запускаем генерацию асинхронно (не блокируя callback)
	_generate_terrain(osm_data, null)

func _on_chunk_data_loaded(osm_data: Dictionary, chunk_key: String, loader: Node, gen: int) -> void:
	# Игнорируем callback если это от старой загрузки (после reset_terrain)
	if gen != _load_generation:
		print("OSM: Ignoring stale chunk %s (gen %d != %d)" % [chunk_key, gen, _load_generation])
		loader.queue_free()
		return

	print("OSM: Chunk %s data loaded" % chunk_key)
	_loading_chunks.erase(chunk_key)
	_current_load_count = max(0, _current_load_count - 1)  # Декремент счётчика

	# Создаём контейнер для чанка
	var chunk_node := Node3D.new()
	chunk_node.name = "Chunk_" + chunk_key
	add_child(chunk_node)
	_loaded_chunks[chunk_key] = chunk_node

	# Если высоты уже загружены, создаём террейн
	if _chunk_elevations.has(chunk_key):
		_create_terrain_mesh(chunk_key, chunk_node)

	# Генерируем объекты асинхронно (с frame budgeting)
	_generate_chunk_async(osm_data, chunk_node, chunk_key, loader, gen)

# Асинхронная генерация чанка с frame budgeting
func _generate_chunk_async(osm_data: Dictionary, chunk_node: Node3D, chunk_key: String, loader: Node, gen: int) -> void:
	await _generate_terrain(osm_data, chunk_node, chunk_key)
	loader.queue_free()

	# После await проверяем что это не устаревшая загрузка
	if gen != _load_generation:
		print("OSM: Ignoring stale chunk generation %s (gen %d != %d)" % [chunk_key, gen, _load_generation])
		return

	# Генерируем растительность на пустых участках чанка (временно отключено)
	# _queue_chunk_vegetation(chunk_key, chunk_node)

	# Создаём фонари для этого чанка (если не начальная загрузка)
	if not _initial_loading:
		print("OSM: Post-initial chunk loaded, pending_lamps=%d" % _pending_lamps.size())
		_create_pending_lamps()

	# Если ночь уже включена - активируем свет в новом чанке
	_apply_night_mode_to_chunk(chunk_node)

	# Проверяем завершение начальной загрузки
	_check_initial_load_complete()

# Создаёт меш террейна с высотами
func _create_terrain_mesh(chunk_key: String, parent: Node3D) -> void:
	if not _chunk_elevations.has(chunk_key):
		return

	var elev_data: Dictionary = _chunk_elevations[chunk_key]
	var grid: Array = elev_data.get("grid", [])
	var grid_size: int = elev_data.get("grid_size", 0)

	if grid_size < 2:
		return

	# Парсим координаты чанка
	var coords: Array = chunk_key.split(",")
	var chunk_x := int(coords[0])
	var chunk_z := int(coords[1])

	# Позиция чанка в мире
	var chunk_origin := Vector3(chunk_x * chunk_size, 0, chunk_z * chunk_size)
	var cell_size := chunk_size / (grid_size - 1)

	var mesh := MeshInstance3D.new()
	mesh.name = "TerrainMesh"
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	# Создаём вершины
	for z in range(grid_size):
		for x in range(grid_size):
			var elevation: float = grid[z][x] - _base_elevation
			elevation *= elevation_scale

			var pos := Vector3(
				chunk_origin.x + x * cell_size,
				elevation,
				chunk_origin.z + z * cell_size
			)
			vertices.append(pos)
			uvs.append(Vector2(float(x) / (grid_size - 1), float(z) / (grid_size - 1)))

	# Вычисляем нормали и индексы
	for z in range(grid_size - 1):
		for x in range(grid_size - 1):
			var i00 := z * grid_size + x
			var i10 := z * grid_size + (x + 1)
			var i01 := (z + 1) * grid_size + x
			var i11 := (z + 1) * grid_size + (x + 1)

			# Два треугольника на ячейку
			indices.append(i00)
			indices.append(i01)
			indices.append(i10)

			indices.append(i10)
			indices.append(i01)
			indices.append(i11)

	# Вычисляем нормали
	normals.resize(vertices.size())
	for i in range(normals.size()):
		normals[i] = Vector3.UP

	# Пересчитываем нормали по треугольникам
	for i in range(0, indices.size(), 3):
		var i0 := indices[i]
		var i1 := indices[i + 1]
		var i2 := indices[i + 2]

		var v0 := vertices[i0]
		var v1 := vertices[i1]
		var v2 := vertices[i2]

		var normal := (v1 - v0).cross(v2 - v0).normalized()
		normals[i0] += normal
		normals[i1] += normal
		normals[i2] += normal

	for i in range(normals.size()):
		normals[i] = normals[i].normalized()

	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices

	var arr_mesh := ArrayMesh.new()
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.mesh = arr_mesh

	var material := StandardMaterial3D.new()
	material.albedo_color = COLORS["default"]
	mesh.material_override = material

	# Добавляем коллизию
	var body := StaticBody3D.new()
	body.name = "TerrainBody"
	body.collision_layer = 1  # Слой 1 - земля, по которой едет машина
	body.collision_mask = 1   # Реагирует на слой 1
	body.add_to_group("Grass")  # GEVP - террейн как трава (большое сопротивление)
	body.add_child(mesh)

	# Создаём коллизию из меша
	mesh.create_trimesh_collision()
	# Перемещаем коллизию в body
	for child in mesh.get_children():
		if child is StaticBody3D:
			var col_shape := child.get_child(0)
			if col_shape is CollisionShape3D:
				child.remove_child(col_shape)
				body.add_child(col_shape)
			child.queue_free()

	parent.add_child(body)

func _generate_terrain(osm_data: Dictionary, parent: Node3D, chunk_key: String = "") -> void:
	var _profile_start := Time.get_ticks_msec()
	var _profile_last := _profile_start

	# Frame budgeting counter - yield каждые N объектов для предотвращения фризов
	var objects_this_frame := 0
	const OBJECTS_PER_FRAME := 3  # Количество лёгких объектов перед yield
	var target: Node3D = parent if parent else self
	var ways: Array = osm_data.get("ways", [])
	var road_count := 0
	var building_count := 0

	# Получаем loader для конвертации координат
	var loader: Node = null
	if parent:
		# Для чанков используем временный loader с правильным центром
		loader = OSMLoaderScript.new()
		loader.center_lat = osm_data.get("center_lat", start_lat)
		loader.center_lon = osm_data.get("center_lon", start_lon)
	else:
		loader = osm_loader

	# Получаем данные высот для чанка (если есть)
	var elev_data: Dictionary = {}
	if chunk_key != "" and _chunk_elevations.has(chunk_key):
		elev_data = _chunk_elevations[chunk_key]

	# Вычисляем границы чанка для фильтрации дубликатов
	var chunk_min_x := 0.0
	var chunk_max_x := 0.0
	var chunk_min_z := 0.0
	var chunk_max_z := 0.0
	var filter_by_chunk := false

	if chunk_key != "":
		var coords: Array = chunk_key.split(",")
		var chunk_x := int(coords[0])
		var chunk_z := int(coords[1])
		chunk_min_x = chunk_x * chunk_size
		chunk_max_x = chunk_min_x + chunk_size
		chunk_min_z = chunk_z * chunk_size
		chunk_max_z = chunk_min_z + chunk_size
		filter_by_chunk = true

	# Получаем входы и POI для ТЕКУЩЕГО чанка
	# ВАЖНО: Сбрасываем POI перед обработкой каждого чанка!
	# POI используют систему координат текущего loader'а
	_entrance_nodes = osm_data.get("entrance_nodes", [])
	_poi_nodes = osm_data.get("poi_nodes", [])
	# НЕ очищаем _parking_polygons и _road_segments - накапливаем из всех чанков
	# _road_segments нужны для позиционирования знаков парковки

	if not _entrance_nodes.is_empty():
		print("OSM: Found %d entrance nodes in chunk" % _entrance_nodes.size())
	if not _poi_nodes.is_empty():
		print("OSM: Found %d POI nodes in chunk" % _poi_nodes.size())

	# Первый проход: собираем полигоны парковок (для исключения фонарей)
	for way in ways:
		var tags: Dictionary = way.get("tags", {})
		var nodes: Array = way.get("nodes", [])
		if tags.get("amenity") == "parking" and nodes.size() >= 3:
			var points: PackedVector2Array = []
			for node in nodes:
				var local: Vector2 = _latlon_to_local(node.lat, node.lon)
				points.append(local)
			_parking_polygons.append(points)

	# Сбор перекрёстков (узлы, где сходятся несколько дорог)
	# НЕ очищаем массивы - накапливаем из всех чанков (очистка в start_loading)
	var node_usage: Dictionary = {}  # node_key -> {pos: Vector2, types: Array[String], widths: Array[float], directions: Array[Vector2]}

	for way in ways:
		var tags: Dictionary = way.get("tags", {})
		var way_nodes: Array = way.get("nodes", [])

		if not tags.has("highway") or way_nodes.size() < 2:
			continue

		var highway_type: String = tags.get("highway", "")
		# Пропускаем пешеходные дорожки
		if highway_type in ["footway", "path", "cycleway", "track", "steps"]:
			continue

		var road_width: float = ROAD_WIDTHS.get(highway_type, 5.0)

		# Проверяем ВСЕ узлы дороги для детекции Т-образных перекрёстков
		for i in range(way_nodes.size()):
			var node = way_nodes[i]
			var node_key := "%.6f,%.6f" % [node.lat, node.lon]
			var local: Vector2 = _latlon_to_local(node.lat, node.lon)

			# Вычисляем направление дороги в этой точке
			var direction := Vector2.ZERO
			if i > 0:
				var prev_local: Vector2 = _latlon_to_local(way_nodes[i - 1].lat, way_nodes[i - 1].lon)
				direction = (local - prev_local).normalized()
			elif i < way_nodes.size() - 1:
				var next_local: Vector2 = _latlon_to_local(way_nodes[i + 1].lat, way_nodes[i + 1].lon)
				direction = (next_local - local).normalized()

			if not node_usage.has(node_key):
				node_usage[node_key] = {"pos": local, "types": [], "widths": [], "directions": []}

			if highway_type not in node_usage[node_key]["types"]:
				node_usage[node_key]["types"].append(highway_type)
				node_usage[node_key]["widths"].append(road_width)
				node_usage[node_key]["directions"].append(direction)

	# Определяем перекрёстки (2+ дороги сходятся)
	for node_key in node_usage:
		var info: Dictionary = node_usage[node_key]
		var types: Array = info["types"]
		var widths: Array = info["widths"]
		var directions: Array = info["directions"]
		if types.size() >= 2:
			# Проверяем на дубликат (перекрёсток уже есть рядом)
			var is_duplicate := false
			for existing_pos in _intersection_positions:
				if existing_pos.distance_to(info["pos"]) < 2.0:
					is_duplicate = true
					break
			if is_duplicate:
				continue

			_intersection_positions.append(info["pos"])

			# Находим самую широкую и вторую по ширине дорогу
			var max_width := 0.0
			var second_width := 0.0
			var max_dir := Vector2.RIGHT
			for i in range(widths.size()):
				var w: float = widths[i]
				if w > max_width:
					second_width = max_width
					max_width = w
					max_dir = directions[i]
				elif w > second_width:
					second_width = w
			if second_width == 0.0:
				second_width = max_width

			# Полуоси эллипса = половина ширины дорог
			var radius_a := max_width * 0.5  # вдоль широкой дороги
			var radius_b := second_width * 0.5  # вдоль узкой дороги
			_intersection_radii.append(Vector2(radius_a, radius_b))

			# Угол поворота = направление широкой дороги + 90 градусов
			var angle := atan2(max_dir.y, max_dir.x) + PI * 0.5
			_intersection_angles.append(angle)

			# Вычисляем максимальную разницу в приоритетах дорог
			var min_priority := 999
			var max_priority := 0
			for t in types:
				var p := _get_road_priority(t)
				min_priority = mini(min_priority, p)
				max_priority = maxi(max_priority, p)
			# true если разница в приоритетах <= 1 (нужна заплатка без разметки)
			var needs_patch := (max_priority - min_priority) <= 1
			_intersection_types.append(needs_patch)

			# Добавляем в spatial hash
			var idx := _intersection_positions.size() - 1
			_add_intersection_to_spatial_hash(info["pos"], Vector2(radius_a, radius_b), idx)

	# Второй проход: создаём все объекты
	var skipped_buildings := 0
	for way in ways:
		var tags: Dictionary = way.get("tags", {})
		var nodes: Array = way.get("nodes", [])

		if nodes.size() < 2:
			continue

		# Фильтруем по принадлежности к чанку
		if filter_by_chunk:
			# Для линейных объектов (дороги) - проверяем пересечение с чанком
			# Для полигонов (здания) - проверяем центр
			var dominated_by_chunk := false
			if tags.has("highway"):
				# Дорога принадлежит чанку если хотя бы одна точка внутри
				# Дубликаты допустимы - дороги длинные и проходят через много чанков
				for node in nodes:
					var local: Vector2 = _latlon_to_local(node.lat, node.lon)
					if local.x >= chunk_min_x and local.x < chunk_max_x and local.y >= chunk_min_z and local.y < chunk_max_z:
						dominated_by_chunk = true
						break
			elif tags.has("waterway"):
				# Водные пути (реки) - рисуем если хотя бы одна точка в чанке
				# Дубликаты допустимы, т.к. реки длинные и проходят через много чанков
				for node in nodes:
					var local: Vector2 = _latlon_to_local(node.lat, node.lon)
					if local.x >= chunk_min_x and local.x < chunk_max_x and local.y >= chunk_min_z and local.y < chunk_max_z:
						dominated_by_chunk = true
						break
			elif tags.has("building") or tags.has("amenity"):
				# Здания - рисуем если хотя бы одна точка в чанке
				# Это гарантирует что здание отрисуется хотя бы в одном чанке
				for node in nodes:
					var local: Vector2 = _latlon_to_local(node.lat, node.lon)
					if local.x >= chunk_min_x and local.x < chunk_max_x and local.y >= chunk_min_z and local.y < chunk_max_z:
						dominated_by_chunk = true
						break
			else:
				# Для остальных полигонов (landuse, natural, leisure) проверяем центр
				var center := _get_way_center(nodes)
				dominated_by_chunk = center.x >= chunk_min_x and center.x < chunk_max_x and center.y >= chunk_min_z and center.y < chunk_max_z

			if not dominated_by_chunk:
				if tags.has("building") or tags.has("amenity"):
					skipped_buildings += 1
				continue

		var _t0 := Time.get_ticks_msec()
		if tags.has("highway"):
			_create_road(nodes, tags, target, loader, elev_data)
			road_count += 1
			objects_this_frame += 1
		elif tags.has("building"):
			_create_building(nodes, tags, target, loader, elev_data)
			building_count += 1
			# Здания теперь в thread pool - не нужен await
		elif tags.has("amenity") and not tags.has("building"):
			# Amenity без building тега - создаём как здание
			_create_amenity_building(nodes, tags, target, loader, elev_data)
			building_count += 1
		elif tags.has("natural"):
			# Добавляем в очередь для отложенного создания
			_terrain_objects_queue.append({
				"type": "natural",
				"nodes": nodes,
				"tags": tags,
				"parent": target,
				"elev_data": elev_data
			})
		elif tags.has("landuse"):
			# Добавляем в очередь для отложенного создания
			_terrain_objects_queue.append({
				"type": "landuse",
				"nodes": nodes,
				"tags": tags,
				"parent": target,
				"elev_data": elev_data
			})
		elif tags.has("leisure"):
			# Добавляем в очередь для отложенного создания
			_terrain_objects_queue.append({
				"type": "leisure",
				"nodes": nodes,
				"tags": tags,
				"parent": target,
				"elev_data": elev_data
			})
		elif tags.has("waterway"):
			_create_waterway(nodes, tags, target, loader, elev_data)
			objects_this_frame += 1

		# Frame budgeting ОТКЛЮЧЕН - вызывает исчезновение бизнес-вывесок
		# См. bisect: проблема появилась в коммите 00b311f
		# if objects_this_frame >= OBJECTS_PER_FRAME:
		# 	objects_this_frame = 0
		# 	await get_tree().process_frame
		pass

	# Ищем перекрёстки (узлы, которые используются несколькими дорогами)
	# Для Т-образных перекрёстков: проверяем ВСЕ узлы дорог
	var node_road_count: Dictionary = {}  # node_key -> count (сколько дорог проходит через узел)
	var node_positions: Dictionary = {}  # node_key -> Vector2
	var node_road_types: Dictionary = {}  # node_key -> Array of highway types

	for way in ways:
		var way_tags: Dictionary = way.get("tags", {})
		var way_nodes: Array = way.get("nodes", [])

		if not way_tags.has("highway"):
			continue

		var highway_type: String = way_tags.get("highway", "")
		# Исключаем пешеходные дороги из детекции перекрёстков
		if highway_type in ["footway", "path", "cycleway", "steps", "pedestrian"]:
			continue

		if way_nodes.size() < 2:
			continue

		# Проверяем ВСЕ узлы дороги (не только концы) для детекции Т-образных перекрёстков
		for node in way_nodes:
			var node_key := "%.5f,%.5f" % [node.lat, node.lon]
			var local: Vector2 = _latlon_to_local(node.lat, node.lon)

			# Фильтруем по чанку
			if filter_by_chunk:
				if local.x < chunk_min_x or local.x >= chunk_max_x or local.y < chunk_min_z or local.y >= chunk_max_z:
					continue

			if not node_road_count.has(node_key):
				node_road_count[node_key] = 0
				node_positions[node_key] = local
				node_road_types[node_key] = []

			node_road_count[node_key] += 1
			if highway_type not in node_road_types[node_key]:
				node_road_types[node_key].append(highway_type)

	# Создаём светофоры, знаки и заплатки на перекрёстках
	var intersection_count := 0
	for node_key in node_road_count:
		if node_road_count[node_key] >= 2:  # Перекрёсток - 2+ дороги сходятся концами
			var pos: Vector2 = node_positions[node_key]
			var road_types: Array = node_road_types[node_key]
			var elevation := _get_elevation_at_point(pos, elev_data)

			# Считаем дороги для которых делаем заплатки и бордюры
			# (motorway, trunk, primary, secondary, tertiary, residential)
			var major_road_count := 0
			var max_width := 0.0
			for t in road_types:
				if t in ["motorway", "trunk", "primary", "secondary", "tertiary", "residential"]:
					major_road_count += 1
				var w: float = ROAD_WIDTHS.get(t, 6.0)
				max_width = maxf(max_width, w)
			# Ищем данные эллипса для этого перекрёстка
			var intersection_idx := _find_nearest_intersection(pos, 2.0)

			# Смещение знаков/светофоров к краю дороги (перпендикулярно направлению)
			var sign_offset := Vector2(5, 5)  # Fallback
			if intersection_idx >= 0:
				var angle: float = _intersection_angles[intersection_idx]
				# Перпендикуляр к направлению дороги
				var perp := Vector2(cos(angle), sin(angle))
				sign_offset = perp * (max_width * 0.5 + 0.5)  # К краю дороги + 0.5м

			# На крупных перекрёстках - светофор, на мелких - знаки
			var has_primary := "primary" in road_types or "secondary" in road_types
			if has_primary and node_road_count[node_key] >= 3:
				_create_traffic_light(pos + sign_offset, elevation, target)
			else:
				# На обычных перекрёстках - один знак
				_create_yield_sign(pos + sign_offset, elevation, target)

			# Создаём заплатку без разметки если есть хотя бы 1 крупная дорога (secondary+)
			if major_road_count >= 1:
				if intersection_idx >= 0:
					var radii: Vector2 = _intersection_radii[intersection_idx]
					var angle: float = _intersection_angles[intersection_idx]
					_create_intersection_patch(pos, elevation, target, radii.x, radii.y, angle)
				else:
					# Fallback: круг с радиусом = половина макс ширины
					var radius := max_width * 0.5
					_create_intersection_patch(pos, elevation, target, radius, radius, 0.0)

			intersection_count += 1

	# Обрабатываем точечные объекты (деревья, знаки, фонари)
	var point_objects: Array = osm_data.get("point_objects", [])
	var tree_count := 0
	var sign_count := 0
	var lamp_count := 0

	for obj in point_objects:
		var tags: Dictionary = obj.get("tags", {})
		var lat: float = obj.get("lat", 0.0)
		var lon: float = obj.get("lon", 0.0)
		var local: Vector2 = _latlon_to_local(lat, lon)

		# Фильтруем по чанку
		if filter_by_chunk:
			if local.x < chunk_min_x or local.x >= chunk_max_x or local.y < chunk_min_z or local.y >= chunk_max_z:
				continue

		var elevation := _get_elevation_at_point(local, elev_data)

		if tags.get("natural") == "tree":
			# Пропускаем деревья слишком близко к дорогам
			if not _is_point_near_road(local, 3.0):
				_create_tree(local, elevation, target)
				tree_count += 1
		elif tags.has("traffic_sign"):
			_create_traffic_sign(local, elevation, tags, target)
			sign_count += 1
		elif tags.get("highway") == "street_lamp":
			# Не ставим фонари на парковках
			if not _is_point_in_any_parking(local):
				_create_street_lamp(local, elevation, target)
				lamp_count += 1

	print("OSM: Generated %d roads, %d buildings, %d trees, %d signs, %d lamps, %d intersections" % [road_count, building_count, tree_count, sign_count, lamp_count, intersection_count])

	# OPTIMIZATION: Помечаем чанк для финализации road batches (когда road_queue опустеет)
	var batch_chunk_key := chunk_key if chunk_key != "" else "initial"
	if not _pending_batch_chunks.has(batch_chunk_key):
		_pending_batch_chunks.append(batch_chunk_key)
		print("OSM: Marked chunk '%s' for road batch finalization" % batch_chunk_key)

func _create_road(nodes: Array, tags: Dictionary, parent: Node3D, loader: Node, elev_data: Dictionary = {}) -> void:
	# Добавляем в очередь для отложенного создания
	_road_queue.append({
		"nodes": nodes,
		"tags": tags,
		"parent": parent,
		"elev_data": elev_data
	})

	# Сегменты дорог сохраняем сразу (нужны для знаков парковки и проверки фонарей)
	var highway_type: String = tags.get("highway", "residential")
	var width: float = ROAD_WIDTHS.get(highway_type, 5.0)
	for i in range(nodes.size() - 1):
		var p1 = _latlon_to_local(nodes[i].lat, nodes[i].lon)
		var p2 = _latlon_to_local(nodes[i + 1].lat, nodes[i + 1].lon)
		var seg := {"p1": p1, "p2": p2, "width": width}
		_road_segments.append(seg)
		_add_road_segment_to_spatial_hash(seg)


## Немедленное создание дороги (вызывается из очереди)
func _create_road_immediate(nodes: Array, tags: Dictionary, parent: Node3D, elev_data: Dictionary = {}) -> void:
	if not is_instance_valid(parent):
		return

	var highway_type: String = tags.get("highway", "residential")
	var width: float = ROAD_WIDTHS.get(highway_type, 5.0)

	var texture_key: String
	var height_offset: float
	var curb_height: float
	# Высота дорог по приоритету (большие дороги выше малых для правильного отображения на перекрёстках)
	# Увеличены offset'ы чтобы дорожная коллизия была выше террейна для GEVP
	match highway_type:
		"motorway", "trunk":
			texture_key = "highway"
			height_offset = 0.020  # Самые высокие
			curb_height = 0.020
		"primary":
			texture_key = "primary"
			height_offset = 0.018
			curb_height = 0.018
		"secondary", "tertiary":
			texture_key = "primary"
			height_offset = 0.016
			curb_height = 0.014
		"residential", "unclassified":
			texture_key = "residential"
			height_offset = 0.014
			curb_height = 0.010
		"service":
			texture_key = "residential"
			height_offset = 0.012  # Самые низкие дороги
			curb_height = 0.006
		"footway", "path", "cycleway", "track":
			texture_key = "path"
			height_offset = 0.005  # Пешеходные значительно ниже
			curb_height = 0.0
		_:
			texture_key = "residential"
			height_offset = 0.014
			curb_height = 0.008

	# OPTIMIZATION: Road batching - добавляем данные в batch вместо создания MeshInstance3D
	_add_road_to_batch(nodes, width, texture_key, height_offset, parent, elev_data)

	if curb_height > 0.0:
		# Бордюры добавляем в очередь - создадим после детекции всех перекрёстков
		_curb_queue.append({
			"nodes": nodes,
			"width": width,
			"height_offset": height_offset,
			"curb_height": curb_height,
			"parent": parent,
			"elev_data": elev_data
		})

	# Процедурная генерация фонарей вдоль дорог (позиции сохраняются для отложенного создания)
	if highway_type in ["motorway", "trunk", "primary", "secondary", "tertiary"]:
		_generate_street_lamps_along_road(nodes, width, elev_data, parent)

	# Извлекаем данные для RoadNetwork (для навигации NPC)
	_extract_road_for_traffic(nodes, tags, elev_data)

func _create_road_mesh_with_texture(nodes: Array, width: float, texture_key: String, height_offset: float, parent: Node3D, elev_data: Dictionary = {}) -> void:
	if nodes.size() < 2:
		return

	# Convert to local coordinates
	var raw_points: PackedVector2Array = []
	for node in nodes:
		var local: Vector2 = _latlon_to_local(node.lat, node.lon)
		raw_points.append(local)

	# Smooth sharp corners with Catmull-Rom interpolation
	var points: PackedVector2Array = _smooth_road_corners(raw_points)

	# Z-fighting offset based on hash
	var hash_val: int = int(abs(points[0].x * 1000 + points[0].y * 7919)) % 100
	var z_offset: float = hash_val * 0.0003

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)

	var vertices: PackedVector3Array = PackedVector3Array()
	var uvs: PackedVector2Array = PackedVector2Array()
	var normals: PackedVector3Array = PackedVector3Array()
	var indices: PackedInt32Array = PackedInt32Array()

	var uv_scale: float = 0.1
	var accumulated_length: float = 0.0
	var half_w: float = width * 0.5

	# Precompute averaged perpendiculars at each point to eliminate gaps
	var perpendiculars: PackedVector2Array = PackedVector2Array()
	for i in range(points.size()):
		var perp: Vector2
		if i == 0:
			var dir: Vector2 = (points[1] - points[0]).normalized()
			perp = Vector2(-dir.y, dir.x)
		elif i == points.size() - 1:
			var dir: Vector2 = (points[i] - points[i - 1]).normalized()
			perp = Vector2(-dir.y, dir.x)
		else:
			var dir_in: Vector2 = (points[i] - points[i - 1]).normalized()
			var dir_out: Vector2 = (points[i + 1] - points[i]).normalized()
			var perp_in: Vector2 = Vector2(-dir_in.y, dir_in.x)
			var perp_out: Vector2 = Vector2(-dir_out.y, dir_out.x)
			perp = ((perp_in + perp_out) * 0.5).normalized()
		perpendiculars.append(perp)

	# Generate 2 vertices per point (left and right edge) - shared between segments
	for i in range(points.size()):
		var p: Vector2 = points[i]
		var perp: Vector2 = perpendiculars[i]
		var h: float = _get_elevation_at_point(p, elev_data) + height_offset + z_offset

		if i > 0:
			accumulated_length += points[i - 1].distance_to(p)
		var uv_y: float = accumulated_length * uv_scale

		# Left vertex
		vertices.append(Vector3(p.x - perp.x * half_w, h, p.y - perp.y * half_w))
		uvs.append(Vector2(0.0, uv_y))
		normals.append(Vector3.UP)

		# Right vertex
		vertices.append(Vector3(p.x + perp.x * half_w, h, p.y + perp.y * half_w))
		uvs.append(Vector2(1.0, uv_y))
		normals.append(Vector3.UP)

	# Generate triangle indices (triangle strip with shared vertices)
	for i in range(points.size() - 1):
		var idx: int = i * 2

		# Triangle 1
		indices.append(idx + 0)
		indices.append(idx + 3)
		indices.append(idx + 1)

		# Triangle 2
		indices.append(idx + 0)
		indices.append(idx + 2)
		indices.append(idx + 3)

	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices

	var arr_mesh: ArrayMesh = ArrayMesh.new()
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mesh: MeshInstance3D = MeshInstance3D.new()
	mesh.mesh = arr_mesh

	# Материал с текстурой
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	if _road_textures.has(texture_key):
		material.albedo_texture = _road_textures[texture_key]
		material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		if _normal_textures.has("asphalt"):
			material.normal_enabled = true
			material.normal_texture = _normal_textures["asphalt"]
			material.normal_scale = 0.3  # Уменьшено для меньшего шума
	else:
		material.albedo_color = COLORS.get("road_residential", Color(0.4, 0.4, 0.4))

	if _is_wet_mode:
		WetRoadMaterial.apply_wet_properties(material, true, _is_night_mode)

	mesh.material_override = material

	# Создаём коллизию дороги с группой Road для GEVP
	var road_body := StaticBody3D.new()
	road_body.name = "RoadCollision"
	road_body.collision_layer = 1
	road_body.collision_mask = 1
	road_body.add_to_group("Road")  # GEVP - дорога (отличное сцепление)
	road_body.add_child(mesh)

	# Создаём trimesh коллизию из меша дороги
	mesh.create_trimesh_collision()
	for child in mesh.get_children():
		if child is StaticBody3D:
			var col_shape := child.get_child(0)
			if col_shape is CollisionShape3D:
				child.remove_child(col_shape)
				road_body.add_child(col_shape)
			child.queue_free()

	parent.add_child(road_body)

# OPTIMIZATION: Road Batching System (Mesh Merging)
# Добавляет дорогу в batch вместо создания отдельного MeshInstance3D
func _add_road_to_batch(nodes: Array, width: float, texture_key: String, height_offset: float, parent: Node3D, elev_data: Dictionary = {}) -> void:
	if nodes.size() < 2:
		return

	# Извлекаем chunk_key из parent node name
	var chunk_key := ""
	if parent.name.begins_with("Chunk_"):
		chunk_key = parent.name.substr(6)  # Убираем "Chunk_" префикс
	else:
		# Для начальной загрузки (parent = root) используем "initial"
		chunk_key = "initial"

	# DEBUG: первый вызов для каждого чанка
	if not _road_batch_data.has(chunk_key):
		print("OSM: DEBUG _add_road_to_batch - first road for chunk '%s', parent.name='%s'" % [chunk_key, parent.name])

	# Инициализируем batch data для этого чанка если ещё нет
	if not _road_batch_data.has(chunk_key):
		_road_batch_data[chunk_key] = {}

	if not _road_batch_data[chunk_key].has(texture_key):
		_road_batch_data[chunk_key][texture_key] = {
			"vertices": PackedVector3Array(),
			"uvs": PackedVector2Array(),
			"normals": PackedVector3Array(),
			"indices": PackedInt32Array(),
			"parent": parent  # Сохраняем parent для создания MeshInstance3D позже
		}

	# Convert to local coordinates and smooth
	var raw_points: PackedVector2Array = []
	for node in nodes:
		var local: Vector2 = _latlon_to_local(node.lat, node.lon)
		raw_points.append(local)

	var points: PackedVector2Array = _smooth_road_corners(raw_points)

	# Z-fighting offset
	var hash_val: int = int(abs(points[0].x * 1000 + points[0].y * 7919)) % 100
	var z_offset: float = hash_val * 0.0003

	# Генерируем geometry для этого road segment
	var batch: Dictionary = _road_batch_data[chunk_key][texture_key]
	var vertex_offset: int = batch["vertices"].size()  # Offset для индексов

	var uv_scale: float = 0.1
	var accumulated_length: float = 0.0
	var half_w: float = width * 0.5

	# Precompute averaged perpendiculars
	var perpendiculars: PackedVector2Array = PackedVector2Array()
	for i in range(points.size()):
		var perp: Vector2
		if i == 0:
			var dir: Vector2 = (points[1] - points[0]).normalized()
			perp = Vector2(-dir.y, dir.x)
		elif i == points.size() - 1:
			var dir: Vector2 = (points[i] - points[i - 1]).normalized()
			perp = Vector2(-dir.y, dir.x)
		else:
			var dir_in: Vector2 = (points[i] - points[i - 1]).normalized()
			var dir_out: Vector2 = (points[i + 1] - points[i]).normalized()
			var perp_in: Vector2 = Vector2(-dir_in.y, dir_in.x)
			var perp_out: Vector2 = Vector2(-dir_out.y, dir_out.x)
			perp = ((perp_in + perp_out) * 0.5).normalized()
		perpendiculars.append(perp)

	# Generate vertices (добавляем в существующий batch)
	for i in range(points.size()):
		var p: Vector2 = points[i]
		var perp: Vector2 = perpendiculars[i]
		var h: float = _get_elevation_at_point(p, elev_data) + height_offset + z_offset

		if i > 0:
			accumulated_length += points[i - 1].distance_to(p)
		var uv_y: float = accumulated_length * uv_scale

		# Left vertex
		batch["vertices"].append(Vector3(p.x - perp.x * half_w, h, p.y - perp.y * half_w))
		batch["uvs"].append(Vector2(0.0, uv_y))
		batch["normals"].append(Vector3.UP)

		# Right vertex
		batch["vertices"].append(Vector3(p.x + perp.x * half_w, h, p.y + perp.y * half_w))
		batch["uvs"].append(Vector2(1.0, uv_y))
		batch["normals"].append(Vector3.UP)

	# Generate indices (с учётом vertex_offset)
	for i in range(points.size() - 1):
		var idx: int = vertex_offset + i * 2

		batch["indices"].append(idx + 0)
		batch["indices"].append(idx + 3)
		batch["indices"].append(idx + 1)

		batch["indices"].append(idx + 0)
		batch["indices"].append(idx + 2)
		batch["indices"].append(idx + 3)

# Финализирует road batches для чанка - создаёт merged meshes
func _finalize_road_batches_for_chunk(chunk_key: String) -> void:
	if not _road_batch_data.has(chunk_key):
		return  # Нет дорог в этом чанке

	var chunk_batches: Dictionary = _road_batch_data[chunk_key]

	# Создаём один merged mesh для каждого типа дороги
	for texture_key in chunk_batches.keys():
		var batch: Dictionary = chunk_batches[texture_key]

		# Проверяем что есть geometry
		if batch["vertices"].size() == 0:
			continue

		# Создаём ArrayMesh из накопленных данных
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = batch["vertices"]
		arrays[Mesh.ARRAY_TEX_UV] = batch["uvs"]
		arrays[Mesh.ARRAY_NORMAL] = batch["normals"]
		arrays[Mesh.ARRAY_INDEX] = batch["indices"]

		var arr_mesh: ArrayMesh = ArrayMesh.new()
		arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

		# Создаём MeshInstance3D
		var mesh_instance := MeshInstance3D.new()
		mesh_instance.mesh = arr_mesh
		mesh_instance.name = "RoadBatch_" + texture_key
		mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF  # Дороги не должны отбрасывать тени

		# Создаём материал (копируем логику из _create_road_mesh_with_texture)
		var material: StandardMaterial3D = StandardMaterial3D.new()
		material.cull_mode = BaseMaterial3D.CULL_DISABLED  # Оставляем DISABLED как в оригинале
		if _road_textures.has(texture_key):
			material.albedo_texture = _road_textures[texture_key]
			material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
			if _normal_textures.has("asphalt"):
				material.normal_enabled = true
				material.normal_texture = _normal_textures["asphalt"]
				material.normal_scale = 0.3
		else:
			material.albedo_color = COLORS.get("road_residential", Color(0.4, 0.4, 0.4))

		if _is_wet_mode:
			WetRoadMaterial.apply_wet_properties(material, true, _is_night_mode)

		mesh_instance.material_override = material

		# Создаём коллизию для merged road mesh
		var road_body := StaticBody3D.new()
		road_body.name = "RoadBatchCollision_" + texture_key
		road_body.collision_layer = 1
		road_body.collision_mask = 1
		road_body.add_to_group("Road")  # GEVP - дорога
		road_body.add_child(mesh_instance)

		# Создаём trimesh коллизию
		mesh_instance.create_trimesh_collision()
		for child in mesh_instance.get_children():
			if child is StaticBody3D:
				var col_shape := child.get_child(0)
				if col_shape is CollisionShape3D:
					child.remove_child(col_shape)
					road_body.add_child(col_shape)
				child.queue_free()

		# Добавляем в parent (chunk node)
		var parent: Node3D = batch["parent"]

		# SAFETY: Проверяем что parent ещё существует (чанк не был выгружен)
		if not is_instance_valid(parent):
			print("OSM: ⚠️ Skipped road batch %s/%s - chunk was unloaded" % [chunk_key, texture_key])
			continue

		parent.add_child(road_body)

		# DEBUG: Всегда выводим информацию о созданных road batches
		print("OSM: ✅ Finalized road batch %s/%s: %d vertices, %d triangles, material: %s" % [
			chunk_key, texture_key, batch["vertices"].size(), batch["indices"].size() / 3,
			material.albedo_texture if material.albedo_texture else "color only"
		])

	# Очищаем batch data для этого чанка
	_road_batch_data.erase(chunk_key)

# Финализирует window batches для чанка (создаёт ONE MultiMesh для всех окон в чанке)
func _finalize_window_batches_for_chunk(chunk_key: String) -> void:
	if not _window_batch_data.has(chunk_key):
		return

	var batch: Dictionary = _window_batch_data[chunk_key]
	var transforms: Array = batch.get("transforms", [])
	var colors: Array = batch.get("colors", [])
	var parent: Node3D = batch.get("parent", null)

	# SAFETY: Проверяем что parent ещё существует (чанк не был выгружен)
	if transforms.is_empty() or not parent or not is_instance_valid(parent):
		if not is_instance_valid(parent):
			print("OSM: ⚠️ Skipped window batch %s - chunk was unloaded" % chunk_key)
		_window_batch_data.erase(chunk_key)
		return

	# Создаём MultiMesh для всех окон в чанке
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = false

	# Используем BoxMesh как базовый mesh (как в оригинале)
	var box := BoxMesh.new()
	box.size = Vector3(1.2, 1.2, 0.05)
	mm.mesh = box

	mm.instance_count = transforms.size()

	# Устанавливаем трансформы и цвета
	for i in range(transforms.size()):
		mm.set_instance_transform(i, transforms[i])
		if i < colors.size():
			mm.set_instance_color(i, colors[i])

	# Создаём материал с emissive shader (как в оригинале - inline shader)
	var shader := Shader.new()
	shader.code = """
shader_type spatial;

uniform bool is_night = false;

void fragment() {
	// Проверяем, выключено ли окно (чёрный цвет = выключено)
	bool is_off = (COLOR.r < 0.01 && COLOR.g < 0.01 && COLOR.b < 0.01);

	if (is_night && !is_off) {
		// Ночью включенные окна светятся
		// Альфа-канал = яркость (0-1)
		float brightness = COLOR.a;
		ALBEDO = COLOR.rgb * brightness;
		EMISSION = COLOR.rgb * brightness;
	} else {
		// Днём все окна тёмные, ночью выключенные тоже тёмные
		ALBEDO = vec3(0.08, 0.1, 0.12);
		EMISSION = vec3(0.0);
	}
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shader

	# Сохраняем материал для динамического обновления
	_window_batch_materials.append(mat)

	# Получаем АКТУАЛЬНОЕ состояние night mode из КЭШИРОВАННОЙ ссылки
	var is_night := false
	if _night_mode_manager and is_instance_valid(_night_mode_manager) and "is_night" in _night_mode_manager:
		is_night = _night_mode_manager.is_night

	# Устанавливаем shader параметр
	mat.set_shader_parameter("is_night", is_night)

	# DEBUG: Логируем (с детальной информацией для диагностики)
	var mode_str := "🌙 NIGHT" if is_night else "☀️ DAY"
	var mgr_status := "CACHED" if _night_mode_manager else "NOT CACHED"
	print("OSM: %s Window batch %s | night_mgr: %s | is_night value: %s" % [
		mode_str, chunk_key, mgr_status, is_night
	])

	# Создаём MultiMeshInstance3D
	var mm_instance := MultiMeshInstance3D.new()
	mm_instance.multimesh = mm
	mm_instance.material_override = mat
	mm_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mm_instance.name = "WindowBatch"

	# Добавляем к родителю (ChunkRoot)
	parent.add_child(mm_instance)

	print("OSM: ✅ Finalized window batch %s: %d windows (was %d draw calls before batching)" % [
		chunk_key, transforms.size(), transforms.size()
	])

	# Очищаем batch data для этого чанка
	_window_batch_data.erase(chunk_key)

# Обновляет is_night параметр для всех window batch материалов (вызывается при переключении ночного режима)
func update_window_night_mode(is_night: bool) -> void:
	var updated_count := 0
	for mat in _window_batch_materials:
		if is_instance_valid(mat):
			mat.set_shader_parameter("is_night", is_night)
			updated_count += 1

	var icon := "🌙" if is_night else "☀️"
	print("OSM: %s Updated %d/%d window batch materials: is_night=%s" % [
		icon, updated_count, _window_batch_materials.size(), is_night
	])

# Создаёт бордюры вдоль дороги (старая версия для обратной совместимости)
func _create_curbs(nodes: Array, road_width: float, road_height: float, curb_height: float, parent: Node3D, elev_data: Dictionary = {}) -> void:
	if nodes.size() < 2:
		return

	var raw_points: PackedVector2Array = []
	for node in nodes:
		var local: Vector2 = _latlon_to_local(node.lat, node.lon)
		raw_points.append(local)

	# Сглаживаем точки бордюров так же, как дороги
	var points: PackedVector2Array = _smooth_road_corners(raw_points)

	_create_curbs_from_points(points, road_width, road_height, curb_height, parent, elev_data)


# Создаёт бордюры из уже сглаженных точек
func _create_curbs_from_points(points: PackedVector2Array, road_width: float, road_height: float, curb_height: float, parent: Node3D, elev_data: Dictionary = {}) -> void:
	if points.size() < 2:
		return

	var curb_width := 0.15  # Ширина бордюра 15 см

	# Добавляем небольшое случайное смещение по высоте для предотвращения z-fighting
	# на пересечениях (используем хэш от первой точки дороги)
	var hash_val := int(abs(points[0].x * 1000 + points[0].y * 7919)) % 100
	var z_offset := hash_val * 0.0002  # 0-2 см случайное смещение

	# Создаём меш для бордюров
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()

	# Масштаб эллипса для удаления бордюров = 1.41 (больше заплатки)
	var curb_ellipse_scale := 1.41

	# Сначала собираем валидные сегменты (не в эллипсах)
	# Проверяем точки на краях дороги, а не на центральной линии
	var valid_segments: Array[int] = []
	for i in range(points.size() - 1):
		var p1 := points[i]
		var p2 := points[i + 1]
		var dir := (p2 - p1).normalized()
		var perp := Vector2(-dir.y, dir.x)
		var offset := perp * (road_width * 0.5)
		# Проверяем левый и правый края бордюра
		var left1 := p1 + offset
		var left2 := p2 + offset
		var right1 := p1 - offset
		var right2 := p2 - offset
		var idx_left1 := _is_point_in_intersection_ellipse(left1, curb_ellipse_scale)
		var idx_left2 := _is_point_in_intersection_ellipse(left2, curb_ellipse_scale)
		var idx_right1 := _is_point_in_intersection_ellipse(right1, curb_ellipse_scale)
		var idx_right2 := _is_point_in_intersection_ellipse(right2, curb_ellipse_scale)
		# Сегмент валиден только если ОБА края вне эллипсов
		if idx_left1 < 0 and idx_left2 < 0 and idx_right1 < 0 and idx_right2 < 0:
			valid_segments.append(i)

	if valid_segments.is_empty():
		return

	# Разбиваем на группы непрерывных сегментов
	var groups: Array[Array] = []
	var current_group: Array[int] = []
	for seg_idx in valid_segments:
		if current_group.is_empty() or current_group[current_group.size() - 1] == seg_idx - 1:
			current_group.append(seg_idx)
		else:
			if not current_group.is_empty():
				groups.append(current_group.duplicate())
			current_group = [seg_idx]
	if not current_group.is_empty():
		groups.append(current_group)

	# Генерируем бордюры для каждой группы
	for group in groups:
		var is_first_in_group := true
		var is_last_in_group := false

		for g_idx in range(group.size()):
			var i: int = group[g_idx]
			is_last_in_group = (g_idx == group.size() - 1)

			var p1 := points[i]
			var p2 := points[i + 1]

			var dir := (p2 - p1).normalized()
			var perp := Vector2(-dir.y, dir.x)

			var h1 := _get_elevation_at_point(p1, elev_data)
			var h2 := _get_elevation_at_point(p2, elev_data)

			# Высоты с z_offset для предотвращения z-fighting
			var road_y1 := h1 + road_height + z_offset
			var road_y2 := h2 + road_height + z_offset
			var curb_y1 := h1 + road_height + curb_height + z_offset
			var curb_y2 := h2 + road_height + curb_height + z_offset

			# Левый бордюр
			var left_inner1 := p1 + perp * (road_width * 0.5)
			var left_outer1 := p1 + perp * (road_width * 0.5 + curb_width)
			var left_inner2 := p2 + perp * (road_width * 0.5)
			var left_outer2 := p2 + perp * (road_width * 0.5 + curb_width)

			# Правый бордюр
			var right_inner1 := p1 - perp * (road_width * 0.5)
			var right_outer1 := p1 - perp * (road_width * 0.5 + curb_width)
			var right_inner2 := p2 - perp * (road_width * 0.5)
			var right_outer2 := p2 - perp * (road_width * 0.5 + curb_width)

			var idx := vertices.size()

			# === Левый бордюр ===
			# Внутренняя стенка (со стороны дороги)
			vertices.append(Vector3(left_inner1.x, road_y1, left_inner1.y))
			vertices.append(Vector3(left_inner2.x, road_y2, left_inner2.y))
			vertices.append(Vector3(left_inner2.x, curb_y2, left_inner2.y))
			vertices.append(Vector3(left_inner1.x, curb_y1, left_inner1.y))
			for _j in range(4):
				normals.append(Vector3(-perp.x, 0, -perp.y))

			indices.append(idx + 0)
			indices.append(idx + 1)
			indices.append(idx + 2)
			indices.append(idx + 0)
			indices.append(idx + 2)
			indices.append(idx + 3)

			idx = vertices.size()

			# Верхняя грань левого бордюра
			vertices.append(Vector3(left_inner1.x, curb_y1, left_inner1.y))
			vertices.append(Vector3(left_inner2.x, curb_y2, left_inner2.y))
			vertices.append(Vector3(left_outer2.x, curb_y2, left_outer2.y))
			vertices.append(Vector3(left_outer1.x, curb_y1, left_outer1.y))
			for _j in range(4):
				normals.append(Vector3.UP)

			indices.append(idx + 0)
			indices.append(idx + 1)
			indices.append(idx + 2)
			indices.append(idx + 0)
			indices.append(idx + 2)
			indices.append(idx + 3)

			# Торец левого бордюра в начале группы
			if is_first_in_group:
				idx = vertices.size()
				vertices.append(Vector3(left_inner1.x, road_y1, left_inner1.y))
				vertices.append(Vector3(left_outer1.x, road_y1, left_outer1.y))
				vertices.append(Vector3(left_outer1.x, curb_y1, left_outer1.y))
				vertices.append(Vector3(left_inner1.x, curb_y1, left_inner1.y))
				for _j in range(4):
					normals.append(-dir.x * Vector3(1, 0, 0) - dir.y * Vector3(0, 0, 1))
				indices.append(idx + 0)
				indices.append(idx + 1)
				indices.append(idx + 2)
				indices.append(idx + 0)
				indices.append(idx + 2)
				indices.append(idx + 3)

			# Торец левого бордюра в конце группы
			if is_last_in_group:
				idx = vertices.size()
				vertices.append(Vector3(left_inner2.x, road_y2, left_inner2.y))
				vertices.append(Vector3(left_outer2.x, road_y2, left_outer2.y))
				vertices.append(Vector3(left_outer2.x, curb_y2, left_outer2.y))
				vertices.append(Vector3(left_inner2.x, curb_y2, left_inner2.y))
				for _j in range(4):
					normals.append(dir.x * Vector3(1, 0, 0) + dir.y * Vector3(0, 0, 1))
				indices.append(idx + 0)
				indices.append(idx + 2)
				indices.append(idx + 1)
				indices.append(idx + 0)
				indices.append(idx + 3)
				indices.append(idx + 2)

			idx = vertices.size()

			# === Правый бордюр ===
			# Внутренняя стенка (со стороны дороги)
			vertices.append(Vector3(right_inner1.x, road_y1, right_inner1.y))
			vertices.append(Vector3(right_inner2.x, road_y2, right_inner2.y))
			vertices.append(Vector3(right_inner2.x, curb_y2, right_inner2.y))
			vertices.append(Vector3(right_inner1.x, curb_y1, right_inner1.y))
			for _j in range(4):
				normals.append(Vector3(perp.x, 0, perp.y))

			indices.append(idx + 0)
			indices.append(idx + 2)
			indices.append(idx + 1)
			indices.append(idx + 0)
			indices.append(idx + 3)
			indices.append(idx + 2)

			idx = vertices.size()

			# Верхняя грань правого бордюра
			vertices.append(Vector3(right_inner1.x, curb_y1, right_inner1.y))
			vertices.append(Vector3(right_inner2.x, curb_y2, right_inner2.y))
			vertices.append(Vector3(right_outer2.x, curb_y2, right_outer2.y))
			vertices.append(Vector3(right_outer1.x, curb_y1, right_outer1.y))
			for _j in range(4):
				normals.append(Vector3.UP)

			indices.append(idx + 0)
			indices.append(idx + 2)
			indices.append(idx + 1)
			indices.append(idx + 0)
			indices.append(idx + 3)
			indices.append(idx + 2)

			# Торец правого бордюра в начале группы
			if is_first_in_group:
				idx = vertices.size()
				vertices.append(Vector3(right_inner1.x, road_y1, right_inner1.y))
				vertices.append(Vector3(right_outer1.x, road_y1, right_outer1.y))
				vertices.append(Vector3(right_outer1.x, curb_y1, right_outer1.y))
				vertices.append(Vector3(right_inner1.x, curb_y1, right_inner1.y))
				for _j in range(4):
					normals.append(-dir.x * Vector3(1, 0, 0) - dir.y * Vector3(0, 0, 1))
				indices.append(idx + 0)
				indices.append(idx + 2)
				indices.append(idx + 1)
				indices.append(idx + 0)
				indices.append(idx + 3)
				indices.append(idx + 2)

			# Торец правого бордюра в конце группы
			if is_last_in_group:
				idx = vertices.size()
				vertices.append(Vector3(right_inner2.x, road_y2, right_inner2.y))
				vertices.append(Vector3(right_outer2.x, road_y2, right_outer2.y))
				vertices.append(Vector3(right_outer2.x, curb_y2, right_outer2.y))
				vertices.append(Vector3(right_inner2.x, curb_y2, right_inner2.y))
				for _j in range(4):
					normals.append(dir.x * Vector3(1, 0, 0) + dir.y * Vector3(0, 0, 1))
				indices.append(idx + 0)
				indices.append(idx + 1)
				indices.append(idx + 2)
				indices.append(idx + 0)
				indices.append(idx + 2)
				indices.append(idx + 3)

			is_first_in_group = false

	if vertices.size() == 0:
		return

	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices

	var arr_mesh := ArrayMesh.new()
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mesh := MeshInstance3D.new()
	mesh.mesh = arr_mesh
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	# Материал бордюра - серый бетон
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.6, 0.6, 0.58)
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	# Добавляем depth bias для устранения z-fighting на пересечениях
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
	mesh.material_override = material

	parent.add_child(mesh)
	# Примечание: коллизии создаются через инкрементальную систему (_finalize_curb_mesh)


## Вычисляет коллизии бордюра в worker thread
func _compute_curb_collisions_thread(task: Dictionary) -> void:
	var points: PackedVector2Array = task.points
	var groups: Array = task.groups  # Уже вычисленные валидные сегменты из главного потока
	var road_width: float = task.road_width
	var road_height: float = task.road_height
	var curb_height: float = task.curb_height
	var curb_width: float = task.curb_width
	var z_offset: float = task.z_offset
	var elev_data: Dictionary = task.elev_data

	var collision_boxes: Array = []

	# Создаём коллизии для каждого 3-го сегмента из валидных групп
	var step := 3
	for group in groups:
		var g_idx := 0
		while g_idx < group.size():
			var i: int = group[g_idx]
			# Берём конечную точку с учётом шага
			var end_g_idx := mini(g_idx + step, group.size() - 1)
			var end_i: int = group[end_g_idx]

			var p1 := points[i]
			var p2 := points[mini(end_i + 1, points.size() - 1)]

			var segment_length := p1.distance_to(p2)
			if segment_length < 0.5:
				g_idx += step
				continue

			var dir := (p2 - p1).normalized()
			var perp := Vector2(-dir.y, dir.x)

			var h1 := _get_elevation_at_point(p1, elev_data)
			var h2 := _get_elevation_at_point(p2, elev_data)
			var avg_h := (h1 + h2) / 2.0 + road_height + curb_height * 0.5 + z_offset

			var wall_angle := atan2(p2.y - p1.y, p2.x - p1.x)

			# Левый бордюр
			var left_center := (p1 + p2) / 2 + perp * (road_width * 0.5 + curb_width * 0.5)
			collision_boxes.append({
				"position": Vector3(left_center.x, avg_h, left_center.y),
				"size": Vector3(segment_length, curb_height, curb_width),
				"rotation_y": -wall_angle
			})

			# Правый бордюр
			var right_center := (p1 + p2) / 2 - perp * (road_width * 0.5 + curb_width * 0.5)
			collision_boxes.append({
				"position": Vector3(right_center.x, avg_h, right_center.y),
				"size": Vector3(segment_length, curb_height, curb_width),
				"rotation_y": -wall_angle
			})

			g_idx += step

	# Добавляем результат в очередь
	if collision_boxes.size() > 0:
		_curb_collision_mutex.lock()
		_curb_collision_results.append({
			"parent": task.parent,
			"boxes": collision_boxes
		})
		_curb_collision_mutex.unlock()


## Применяет рассчитанные коллизии бордюров (вызывается из _process)
func _apply_curb_collisions() -> void:
	if _curb_collision_results.is_empty():
		return

	_curb_collision_mutex.lock()
	var results := _curb_collision_results.duplicate()
	_curb_collision_results.clear()
	_curb_collision_mutex.unlock()

	# Применяем по 2 результата за кадр
	var applied := 0
	for result in results:
		if applied >= 2:
			# Возвращаем оставшиеся обратно
			_curb_collision_mutex.lock()
			_curb_collision_results.append(result)
			_curb_collision_mutex.unlock()
			continue

		if not is_instance_valid(result.parent):
			continue

		var body := StaticBody3D.new()
		body.collision_layer = 1
		body.collision_mask = 0
		body.add_to_group("Road")  # GEVP использует группу для определения типа поверхности

		for box in result.boxes:
			var collision := CollisionShape3D.new()
			var shape := BoxShape3D.new()
			shape.size = box.size
			collision.shape = shape
			collision.position = box.position
			collision.rotation.y = box.rotation_y
			body.add_child(collision)

		result.parent.add_child(body)
		applied += 1


# Старая версия без текстур (для совместимости)
func _create_path_mesh(nodes: Array, width: float, color: Color, height_offset: float, parent: Node3D, loader: Node, elev_data: Dictionary = {}) -> void:
	if nodes.size() < 2:
		return

	var points: PackedVector2Array = []
	for node in nodes:
		var local: Vector2 = _latlon_to_local(node.lat, node.lon)
		points.append(local)

	var mesh := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	mesh.mesh = im

	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material_override = material

	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	im.surface_set_normal(Vector3.UP)  # Нормаль вверх для дорог

	for i in range(points.size() - 1):
		var p1 := points[i]
		var p2 := points[i + 1]

		var dir := (p2 - p1).normalized()
		var perp := Vector2(-dir.y, dir.x) * width * 0.5

		# Получаем высоты для каждой точки
		var h1 := _get_elevation_at_point(p1, elev_data) + height_offset
		var h2 := _get_elevation_at_point(p2, elev_data) + height_offset

		var v1 := Vector3(p1.x - perp.x, h1, p1.y - perp.y)
		var v2 := Vector3(p1.x + perp.x, h1, p1.y + perp.y)
		var v3 := Vector3(p2.x + perp.x, h2, p2.y + perp.y)
		var v4 := Vector3(p2.x - perp.x, h2, p2.y - perp.y)

		im.surface_add_vertex(v1)
		im.surface_add_vertex(v3)
		im.surface_add_vertex(v2)

		im.surface_add_vertex(v1)
		im.surface_add_vertex(v4)
		im.surface_add_vertex(v3)

	im.surface_end()
	parent.add_child(mesh)

func _create_building(nodes: Array, tags: Dictionary, parent: Node3D, loader: Node, elev_data: Dictionary = {}) -> void:
	if nodes.size() < 3:
		return

	var points: PackedVector2Array = []
	for node in nodes:
		var local: Vector2 = _latlon_to_local(node.lat, node.lon)
		points.append(local)

	# Debug name для отладки конкретных зданий
	var addr_street: String = str(tags.get("addr:street", ""))
	var addr_housenumber: String = str(tags.get("addr:housenumber", ""))
	var debug_name := ""
	if addr_street != "" and addr_housenumber != "":
		debug_name = "%s %s" % [addr_street, addr_housenumber]

	# Определяем высоту здания из OSM данных
	var building_height := 0.0

	# Приоритет 1: точная высота в метрах
	if tags.has("height"):
		var h_str: String = str(tags.get("height", ""))
		# Убираем "m" если есть
		h_str = h_str.replace(" m", "").replace("m", "").strip_edges()
		if h_str.is_valid_float():
			building_height = float(h_str)

	# Приоритет 2: количество этажей
	if building_height <= 0.0 and tags.has("building:levels"):
		var levels_str: String = str(tags.get("building:levels", ""))
		if levels_str.is_valid_int():
			var levels := int(levels_str)
			building_height = levels * 3.2  # ~3.2м на этаж

	# Приоритет 3: тип здания
	if building_height <= 0.0:
		var building_type: String = str(tags.get("building", "yes"))
		match building_type:
			"house", "detached", "semidetached_house":
				building_height = 7.0  # 2 этажа
			"residential", "apartments":
				building_height = 15.0  # 5 этажей
			"commercial", "office":
				building_height = 12.0  # 4 этажа
			"industrial", "warehouse":
				building_height = 8.0
			"garage", "garages":
				building_height = 3.0
			"shed", "hut":
				building_height = 2.5
			"church", "cathedral":
				building_height = 20.0
			"school", "university":
				building_height = 12.0
			"hospital":
				building_height = 18.0
			_:
				building_height = 8.0  # По умолчанию ~3 этажа

	# Ограничиваем высоту разумными пределами
	building_height = clamp(building_height, 2.5, 100.0)

	# Определяем цвет здания
	var color := COLORS["building"]

	# Приоритет 1: явно указанный цвет в OSM
	if tags.has("building:colour"):
		var colour_str: String = str(tags.get("building:colour", ""))
		var parsed_color := Color.from_string(colour_str, Color(-1, -1, -1))
		if parsed_color.r >= 0:
			color = parsed_color
	elif tags.has("building:color"):
		var colour_str: String = str(tags.get("building:color", ""))
		var parsed_color := Color.from_string(colour_str, Color(-1, -1, -1))
		if parsed_color.r >= 0:
			color = parsed_color
	else:
		# Приоритет 2: цвет на основе amenity (важнее чем building type)
		var amenity_type: String = str(tags.get("amenity", ""))
		var building_type: String = str(tags.get("building", "yes"))

		# Сначала проверяем amenity - они имеют приоритет
		if amenity_type == "kindergarten":
			color = Color(0.5, 0.75, 0.9)  # Голубой для детских садов
		elif amenity_type == "school":
			color = Color(0.3, 0.5, 0.8)  # Синий для школ
		elif amenity_type == "university" or amenity_type == "college":
			color = Color(0.4, 0.45, 0.7)  # Тёмно-синий для вузов
		elif amenity_type == "hospital":
			color = Color(0.95, 0.95, 0.95)  # Белый для больниц
		elif amenity_type == "clinic":
			color = Color(0.9, 0.9, 0.95)  # Бело-голубой для поликлиник
		elif amenity_type == "pharmacy":
			color = Color(0.4, 0.75, 0.4)  # Зелёный для аптек
		elif amenity_type == "police":
			color = Color(0.3, 0.4, 0.6)  # Тёмно-синий для полиции
		elif amenity_type == "fire_station":
			color = Color(0.85, 0.3, 0.25)  # Красный для пожарных
		elif amenity_type == "place_of_worship":
			color = Color(0.95, 0.9, 0.75)  # Золотистый для церквей
		elif amenity_type == "bank":
			color = Color(0.5, 0.6, 0.5)  # Серо-зелёный для банков
		elif amenity_type == "post_office":
			color = Color(0.3, 0.45, 0.7)  # Синий для почты
		elif amenity_type in ["restaurant", "cafe", "fast_food", "bar", "pub"]:
			color = Color(0.8, 0.6, 0.4)  # Оранжево-коричневый для еды
		elif amenity_type == "fuel":
			color = Color(0.85, 0.75, 0.3)  # Жёлтый для заправок
		elif amenity_type == "theatre" or amenity_type == "cinema":
			color = Color(0.6, 0.35, 0.5)  # Пурпурный для театров/кино
		elif amenity_type == "library":
			color = Color(0.55, 0.45, 0.35)  # Коричневый для библиотек
		else:
			# Иначе по типу здания
			match building_type:
				"house", "detached", "semidetached_house":
					color = Color(0.75, 0.65, 0.55)  # Светло-бежевый
				"residential", "apartments":
					color = Color(0.7, 0.6, 0.5)  # Бежевый
				"commercial", "retail":
					color = Color(0.6, 0.65, 0.7)  # Серо-голубой
				"office":
					color = Color(0.55, 0.6, 0.65)  # Сине-серый
				"industrial":
					color = Color(0.4, 0.4, 0.45)  # Тёмно-серый для промышленных
				"warehouse":
					color = Color(0.45, 0.45, 0.5)  # Серый для складов
				"garage", "garages":
					color = Color(0.5, 0.5, 0.48)  # Серый для гаражей
				"shed", "hut":
					color = Color(0.6, 0.5, 0.4)  # Коричневый
				"church", "cathedral", "chapel":
					color = Color(0.95, 0.9, 0.75)  # Золотисто-кремовый
				"kindergarten":
					color = Color(0.5, 0.75, 0.9)  # Голубой
				"school":
					color = Color(0.3, 0.5, 0.8)  # Синий
				"university", "college":
					color = Color(0.4, 0.45, 0.7)  # Тёмно-синий
				"hospital":
					color = Color(0.95, 0.95, 0.95)  # Белый
				"hotel":
					color = Color(0.7, 0.55, 0.45)  # Тёплый коричневый
				"public":
					color = Color(0.6, 0.6, 0.55)  # Серо-оливковый
				"construction":
					color = Color(0.8, 0.7, 0.4)  # Жёлто-коричневый
				"ruins":
					color = Color(0.5, 0.45, 0.4)  # Тёмно-коричневый
				_:
					color = Color(0.65, 0.55, 0.45)  # Стандартный коричневатый

	# Получаем высоту террейна для здания (берём центр)
	var base_elev := _get_elevation_at_point(_get_polygon_center(points), elev_data)

	# Определяем тип текстуры здания
	var building_type: String = str(tags.get("building", "yes"))
	var texture_type := "panel"  # По умолчанию панельки
	if building_height > 15.0:
		texture_type = "panel"  # Высотки - панельные
	elif building_type in ["house", "detached", "semidetached_house"]:
		texture_type = "brick"  # Частные дома - кирпич
	elif building_type in ["industrial", "warehouse", "garage", "garages"]:
		texture_type = "wall"  # Промышленные - простая штукатурка
	else:
		texture_type = "brick"  # Остальное - кирпич

	# Используем многопоточную генерацию зданий
	_queue_building_for_thread(points, building_height, texture_type, parent, base_elev)

	# Добавляем вывески для заведений (amenity/shop с названием)
	# Вывески создаются синхронно т.к. они лёгкие
	_add_business_signs_simple(points, tags, parent, building_height, base_elev, loader)


func _create_parking(points: PackedVector2Array, elev_data: Dictionary, parent: Node3D) -> void:
	"""Создаёт парковку: асфальтовую поверхность + знак P (знак отложен) + припаркованные машины"""
	if points.size() < 3:
		return

	# Примечание: полигон уже добавлен в _parking_polygons в первом проходе

	# 1. Создаём асфальтовую поверхность
	_create_parking_surface(points, elev_data, parent)

	# 2. Сохраняем данные для отложенного создания знака
	# (знак создаётся после загрузки всех чанков, когда все дороги известны)
	_pending_parking_signs.append({
		"points": points,
		"elev_data": elev_data,
		"parent": parent
	})

	# 3. Добавляем припаркованные машины (0-2 штуки)
	_spawn_parked_cars(points, elev_data, parent)


func _find_parking_sign_position(parking_points: PackedVector2Array) -> Dictionary:
	"""Находит позицию для знака парковки: в дальнем от дороги углу"""
	if parking_points.size() < 3 or _road_segments.is_empty():
		return {}

	# Сначала находим ближайшую дорогу к парковке (по центру)
	var parking_center := Vector2.ZERO
	for pt in parking_points:
		parking_center += pt
	parking_center /= parking_points.size()

	var nearest_road_point := Vector2.ZERO
	var min_center_dist := INF

	for seg in _road_segments:
		var road_p1: Vector2 = seg.p1
		var road_p2: Vector2 = seg.p2
		var road_vec: Vector2 = road_p2 - road_p1
		var road_len: float = road_vec.length()
		if road_len < 0.1:
			continue
		var t: float = clamp((parking_center - road_p1).dot(road_vec) / (road_len * road_len), 0.0, 1.0)
		var closest: Vector2 = road_p1 + road_vec * t
		var dist: float = parking_center.distance_to(closest)
		if dist < min_center_dist:
			min_center_dist = dist
			nearest_road_point = closest

	if min_center_dist > 100.0:
		return {}

	# Теперь ищем угол парковки, ДАЛЬНИЙ от этой точки дороги
	var max_dist := 0.0
	var best_corner := Vector2.ZERO

	for corner in parking_points:
		var dist: float = corner.distance_to(nearest_road_point)
		if dist > max_dist:
			max_dist = dist
			best_corner = corner

	# Знак ставим в этом дальнем углу
	var to_road: Vector2 = (nearest_road_point - best_corner).normalized()
	var sign_pos: Vector2 = best_corner + to_road * 0.5  # 0.5м от угла к дороге

	# Знак смотрит в сторону дороги
	var rotation: float = atan2(to_road.x, to_road.y)

	return {"position": sign_pos, "rotation": rotation}


func _create_parking_surface(points: PackedVector2Array, elev_data: Dictionary, parent: Node3D) -> void:
	"""Создаёт асфальтовую поверхность парковки"""
	# Триангулируем полигон
	var indices := Geometry2D.triangulate_polygon(points)
	if indices.is_empty():
		return

	var mesh := MeshInstance3D.new()
	mesh.name = "ParkingSurface"

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Создаём материал с текстурой асфальта
	var material := StandardMaterial3D.new()
	material.albedo_texture = _road_textures.get("residential", null)
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.uv1_scale = Vector3(0.1, 0.1, 1.0)  # Масштаб UV для текстуры
	# Normal map
	if _normal_textures.has("asphalt"):
		material.normal_enabled = true
		material.normal_texture = _normal_textures["asphalt"]
		material.normal_scale = 0.3  # Уменьшено для меньшего шума

	if _is_wet_mode:
		WetRoadMaterial.apply_wet_properties(material, true, _is_night_mode)

	st.set_material(material)

	# Высота поверхности чуть выше земли
	var height_offset := 0.03

	# Добавляем вершины треугольников
	for i in range(0, indices.size(), 3):
		for j in range(3):
			var idx = indices[i + j]
			var p = points[idx]
			var h = _get_elevation_at_point(p, elev_data) + height_offset

			# UV координаты для текстуры
			st.set_uv(Vector2(p.x * 0.1, p.y * 0.1))
			st.set_normal(Vector3.UP)
			st.add_vertex(Vector3(p.x, h, p.y))

	mesh.mesh = st.commit()
	parent.add_child(mesh)


func _spawn_parked_cars(parking_points: PackedVector2Array, elev_data: Dictionary, parent: Node3D) -> void:
	"""Спавнит 0-2 припаркованных машины на парковке"""
	if parking_points.size() < 3:
		return

	# Количество машин: 0, 1 или 2 (случайно)
	var car_count: int = randi() % 3
	if car_count == 0:
		return

	# Вычисляем центр парковки
	var center := Vector2.ZERO
	for pt in parking_points:
		center += pt
	center /= parking_points.size()

	# Направление "вдоль" парковки (параллельно ближайшей дороге)
	var parking_dir := _get_parking_direction(parking_points, center)

	# Позиции для машин (разнесённые)
	var spawned_positions: Array[Vector2] = []

	for i in range(car_count):
		var pos := _find_parking_spot(parking_points, center, i, spawned_positions)
		if pos == Vector2.ZERO:
			continue

		spawned_positions.append(pos)

		# Выбираем случайную модель (60% коробка, 20% такси, 20% лада ДПС)
		var car: Node3D
		var rand := randf()
		if rand < 0.6:
			car = _parked_car_scene.instantiate()
		elif rand < 0.8:
			car = _parked_taxi_scene.instantiate()
		else:
			car = _parked_lada_scene.instantiate()

		# Получаем высоту
		var elevation: float = _get_elevation_at_point(pos, elev_data)

		# Позиционируем
		car.position = Vector3(pos.x, elevation, pos.y)

		# Поворот вдоль парковки (+ небольшая вариация ±5°)
		var rotation_variation: float = (randf() - 0.5) * deg_to_rad(10)
		car.rotation.y = atan2(parking_dir.x, parking_dir.y) + rotation_variation

		# Отключаем только AI/управление, физика остаётся для столкновений
		# freeze = false - машина реагирует на удары
		car.set_process(false)  # Отключаем _process (AI логику)
		# Оставляем physics_process для физики столкновений

		# Применяем случайный цвет
		_apply_parked_car_color(car)

		parent.add_child(car)


func _find_parking_spot(parking_points: PackedVector2Array, center: Vector2, index: int, existing: Array[Vector2]) -> Vector2:
	"""Находит свободное место на парковке"""
	# Смещения от центра для разных машин
	var offsets := [
		Vector2(-4, -3), Vector2(4, 3),
		Vector2(-3, 4), Vector2(3, -4),
		Vector2(0, -5), Vector2(0, 5),
	]

	for attempt in range(15):
		var offset = offsets[index % offsets.size()]
		# Добавляем случайность
		offset += Vector2(randf() - 0.5, randf() - 0.5) * (attempt * 0.5)
		var test_pos = center + offset * (1.0 + attempt * 0.2)

		# Проверяем что точка внутри парковки
		if not Geometry2D.is_point_in_polygon(test_pos, parking_points):
			continue

		# Проверяем минимальное расстояние до других машин (4м)
		var too_close := false
		for other in existing:
			if test_pos.distance_to(other) < 4.0:
				too_close = true
				break
		if too_close:
			continue

		return test_pos

	return Vector2.ZERO


func _get_parking_direction(parking_points: PackedVector2Array, center: Vector2) -> Vector2:
	"""Определяет направление 'вдоль' парковки (параллельно ближайшей дороге)"""
	if _road_segments.is_empty():
		# Если дорог нет, используем самую длинную сторону полигона
		return _get_longest_edge_direction(parking_points)

	# Находим ближайший сегмент дороги
	var min_dist := INF
	var best_road_dir := Vector2(1, 0)

	for seg in _road_segments:
		var road_p1: Vector2 = seg.p1
		var road_p2: Vector2 = seg.p2
		var road_vec: Vector2 = road_p2 - road_p1
		var road_len: float = road_vec.length()
		if road_len < 0.1:
			continue

		var t: float = clamp((center - road_p1).dot(road_vec) / (road_len * road_len), 0.0, 1.0)
		var closest: Vector2 = road_p1 + road_vec * t
		var dist: float = center.distance_to(closest)

		if dist < min_dist:
			min_dist = dist
			best_road_dir = road_vec.normalized()

	return best_road_dir


func _get_longest_edge_direction(points: PackedVector2Array) -> Vector2:
	"""Находит направление самой длинной стороны полигона"""
	var max_len := 0.0
	var best_dir := Vector2(1, 0)

	for i in range(points.size()):
		var p1 = points[i]
		var p2 = points[(i + 1) % points.size()]
		var edge = p2 - p1
		var length = edge.length()

		if length > max_len:
			max_len = length
			best_dir = edge.normalized()

	return best_dir


func _apply_parked_car_color(car: Node3D) -> void:
	"""Применяет случайный цвет к припаркованной машине"""
	var color: Color = PARKED_CAR_COLORS[randi() % PARKED_CAR_COLORS.size()]

	# Ищем меши с материалами кузова
	for child in car.get_children():
		if child is MeshInstance3D:
			var mesh_name: String = child.name.to_lower()
			# Пропускаем колёса, стёкла, фары
			if "wheel" in mesh_name or "glass" in mesh_name or "light" in mesh_name:
				continue
			if "tire" in mesh_name or "rim" in mesh_name or "brake" in mesh_name:
				continue

			# Применяем цвет к кузову
			if child.mesh and child.mesh.get_surface_count() > 0:
				var mat = child.get_active_material(0)
				if mat and mat is StandardMaterial3D:
					var new_mat = mat.duplicate()
					new_mat.albedo_color = color
					child.material_override = new_mat


func _create_parking_sign(pos: Vector2, elevation: float, rotation_y: float, parent: Node3D) -> void:
	"""Добавляет знак парковки в очередь для отложенного создания"""
	# Смещаем знак с дороги если нужно
	var safe_pos := _move_object_off_road(pos, 0.5, 5)
	if safe_pos == Vector2.ZERO:
		# Не нашли безопасное место, пропускаем
		return

	# Проверяем, не создан ли уже знак в этой позиции (избегаем дубликатов)
	var pos_key := "%d_%d" % [int(safe_pos.x), int(safe_pos.y)]
	if _created_sign_positions.has(pos_key):
		return
	_created_sign_positions[pos_key] = true

	# Добавляем в очередь для отложенного создания
	_infrastructure_queue.append({
		"type": "parking_sign",
		"pos": safe_pos,
		"elevation": elevation,
		"parent": parent,
		"rotation": rotation_y
	})


# Немедленное создание знака парковки (вызывается из очереди)
func _create_parking_sign_immediate(pos: Vector2, elevation: float, rotation_y: float, parent: Node3D) -> void:
	if not is_instance_valid(parent):
		return

	# RigidBody3D как корневой узел для физики
	var body := RigidBody3D.new()
	body.name = "ParkingSign"
	body.position = Vector3(pos.x, elevation, pos.y)
	body.rotation.y = rotation_y
	body.collision_layer = 4  # Слой 4 - разрушаемые знаки (отдельный от статики)
	body.collision_mask = 7  # Машины(1) + статика(2) + другие знаки(4)
	body.mass = 15.0
	body.freeze = true
	body.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	body.contact_monitor = true
	body.max_contacts_reported = 4  # Больше контактов для надёжности
	body.body_entered.connect(_on_sign_hit.bind(body))

	# Коллизия для столба
	var collision := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.05
	shape.height = 2.5
	collision.shape = shape
	collision.position.y = 1.25
	body.add_child(collision)

	# Столб - серый тонкий цилиндр
	var pole := MeshInstance3D.new()
	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = 0.03
	pole_mesh.bottom_radius = 0.04
	pole_mesh.height = 2.5
	pole.mesh = pole_mesh

	var pole_mat := StandardMaterial3D.new()
	pole_mat.albedo_color = Color(0.5, 0.5, 0.5)
	pole_mat.metallic = 0.8
	pole.material_override = pole_mat
	pole.position.y = 1.25
	pole.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	body.add_child(pole)

	# Знак - синий квадрат
	var sign_plate := MeshInstance3D.new()
	var sign_mesh := BoxMesh.new()
	sign_mesh.size = Vector3(0.6, 0.6, 0.02)
	sign_plate.mesh = sign_mesh

	var sign_mat := StandardMaterial3D.new()
	sign_mat.albedo_color = Color(0.1, 0.3, 0.7)  # Синий
	sign_plate.material_override = sign_mat
	sign_plate.position.y = 2.3
	sign_plate.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	body.add_child(sign_plate)

	# Буква "P" - белый текст
	var label := Label3D.new()
	label.text = "P"
	label.font_size = 200
	label.modulate = Color.WHITE
	label.outline_size = 0
	label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	label.no_depth_test = false
	label.pixel_size = 0.002
	label.position = Vector3(0, 2.3, 0.02)
	body.add_child(label)

	# Буква "P" с обратной стороны
	var label_back := Label3D.new()
	label_back.text = "P"
	label_back.font_size = 200
	label_back.modulate = Color.WHITE
	label_back.outline_size = 0
	label_back.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	label_back.no_depth_test = false
	label_back.pixel_size = 0.002
	label_back.position = Vector3(0, 2.3, -0.02)
	label_back.rotation.y = PI  # Повернуть на 180°
	body.add_child(label_back)

	parent.add_child(body)


# Обработчик столкновения со знаком - активирует физику
func _on_sign_hit(other_body: Node, rigid_body: RigidBody3D) -> void:
	# Проверяем, что столкновение с машиной (VehicleBody3D, RigidBody3D или группа "car")
	var is_vehicle := other_body is VehicleBody3D or other_body is RigidBody3D or other_body.is_in_group("car")
	if is_vehicle and other_body != rigid_body:
		# Размораживаем знак - теперь он подвержен физике
		rigid_body.freeze = false
		# Добавляем импульс в направлении от машины
		var impulse_dir: Vector3 = (rigid_body.global_position - other_body.global_position).normalized()
		impulse_dir.y = 0.3  # Немного вверх для реалистичного отлёта
		var car_speed: float = 0.0
		if other_body is RigidBody3D:
			car_speed = (other_body as RigidBody3D).linear_velocity.length()
		elif other_body is VehicleBody3D:
			car_speed = (other_body as VehicleBody3D).linear_velocity.length()
		var impulse_strength: float = clamp(car_speed * 20.0, 100.0, 800.0)
		rigid_body.apply_central_impulse(impulse_dir * impulse_strength)
		# Добавляем вращение для реалистичности
		var torque := Vector3(randf_range(-5, 5), randf_range(-2, 2), randf_range(-5, 5))
		rigid_body.apply_torque_impulse(torque * impulse_strength * 0.1)


## Немедленное создание природного объекта (вызывается из очереди)
func _create_natural_immediate(nodes: Array, tags: Dictionary, parent: Node3D, elev_data: Dictionary = {}) -> void:
	if not is_instance_valid(parent):
		return
	if nodes.size() < 3:
		return

	var natural_type: String = tags.get("natural", "")
	var texture_key := "grass"
	var is_water := false

	match natural_type:
		"water":
			texture_key = "water"
			is_water = true
		"wood", "tree_row":
			texture_key = "forest"
		"grassland", "scrub":
			texture_key = "grass"
		_:
			texture_key = "grass"

	var points: PackedVector2Array = []
	for node in nodes:
		var local: Vector2 = _latlon_to_local(node.lat, node.lon)
		points.append(local)

	# Natural объекты ниже дорог чтобы не было z-fighting
	_create_polygon_mesh_with_texture(points, texture_key, -0.02, parent, elev_data, is_water)

	# Процедурная генерация деревьев в лесах
	if natural_type in ["wood"]:
		_generate_trees_in_polygon(points, elev_data, parent, true)  # dense=true для леса


## Немедленное создание землепользования (вызывается из очереди)
func _create_landuse_immediate(nodes: Array, tags: Dictionary, parent: Node3D, elev_data: Dictionary = {}) -> void:
	if not is_instance_valid(parent):
		return
	if nodes.size() < 3:
		return

	var landuse_type: String = tags.get("landuse", "")

	var points: PackedVector2Array = []
	for node in nodes:
		var local: Vector2 = _latlon_to_local(node.lat, node.lon)
		points.append(local)

	# Индустриальные и коммерческие зоны - рисуем забор и генерируем здания внутри
	if landuse_type in ["industrial", "commercial"]:
		_create_fence(points, parent, elev_data)
		_generate_industrial_buildings(points, elev_data, parent)
		return

	var texture_key := "grass"
	var is_water := false
	match landuse_type:
		"residential":
			texture_key = "grass"  # Жилые районы - трава
		"farmland", "farm":
			texture_key = "grass"  # Поля - трава (позже можно добавить специальную текстуру)
		"forest":
			texture_key = "forest"
		"grass", "meadow", "recreation_ground":
			texture_key = "grass"
		"reservoir", "basin":
			texture_key = "water"
			is_water = true
		_:
			texture_key = "grass"

	# Landuse ниже дорог чтобы не было z-fighting
	_create_polygon_mesh_with_texture(points, texture_key, -0.02, parent, elev_data, is_water)

	# Процедурная генерация деревьев в лесах
	if landuse_type == "forest":
		_generate_trees_in_polygon(points, elev_data, parent, true)  # dense=true для леса


## Немедленное создание объекта отдыха (вызывается из очереди)
func _create_leisure_immediate(nodes: Array, tags: Dictionary, parent: Node3D, elev_data: Dictionary = {}) -> void:
	if not is_instance_valid(parent):
		return
	if nodes.size() < 3:
		return

	var leisure_type: String = tags.get("leisure", "")
	var texture_key := "grass"
	var is_water := false

	match leisure_type:
		"park", "garden":
			texture_key = "grass"
		"pitch", "stadium":
			texture_key = "grass"  # Можно добавить специальную текстуру для стадионов
		"swimming_pool":
			texture_key = "water"
			is_water = true
		_:
			texture_key = "grass"

	var points: PackedVector2Array = []
	for node in nodes:
		var local: Vector2 = _latlon_to_local(node.lat, node.lon)
		points.append(local)

	# Парки и зоны отдыха ниже дорог чтобы не было z-fighting
	_create_polygon_mesh_with_texture(points, texture_key, -0.02, parent, elev_data, is_water)

	# Добавляем коллизию с группой Park для высокого сопротивления качению
	if leisure_type in ["park", "garden", "pitch"]:
		_create_park_collision(points, elev_data, parent)

	# Процедурная генерация деревьев в парках и садах
	if leisure_type in ["park", "garden"]:
		_generate_trees_in_polygon(points, elev_data, parent)

func _create_amenity_building(nodes: Array, tags: Dictionary, parent: Node3D, loader: Node, elev_data: Dictionary = {}) -> void:
	if nodes.size() < 3:
		return

	var points: PackedVector2Array = []
	for node in nodes:
		var local: Vector2 = _latlon_to_local(node.lat, node.lon)
		points.append(local)

	var amenity_type: String = str(tags.get("amenity", ""))

	# Территории (школы, детсады, университеты, пожарные станции, полиция) - рисуем забор, а не здание
	# Здание внутри рисуется отдельно если есть building тег
	var territory_types := ["school", "kindergarten", "college", "university", "fire_station", "police"]
	if amenity_type in territory_types:
		_create_fence(points, parent, elev_data)
		return

	# Заправки не создаём как здания
	if amenity_type == "fuel":
		return

	# Парковки обрабатываем отдельно
	if amenity_type == "parking":
		_create_parking(points, elev_data, parent)
		return

	# Остальные amenity - создаём как маленькие здания
	var building_height: float
	var color: Color

	match amenity_type:
		"hospital":
			building_height = 18.0
			color = Color(0.95, 0.95, 0.95)  # Белый
		"clinic":
			building_height = 12.0
			color = Color(0.9, 0.9, 0.95)  # Бело-голубой
		"pharmacy":
			building_height = 5.0
			color = Color(0.4, 0.75, 0.4)  # Зелёный
		"police":
			building_height = 10.0
			color = Color(0.3, 0.4, 0.6)  # Тёмно-синий
		"fire_station":
			building_height = 10.0
			color = Color(0.85, 0.3, 0.25)  # Красный
		"place_of_worship", "church":
			building_height = 20.0
			color = Color(0.95, 0.9, 0.75)  # Золотистый
		"bank":
			building_height = 12.0
			color = Color(0.5, 0.6, 0.5)  # Серо-зелёный
		"post_office":
			building_height = 8.0
			color = Color(0.3, 0.45, 0.7)  # Синий
		"restaurant", "cafe", "fast_food", "bar", "pub":
			building_height = 5.0
			color = Color(0.8, 0.6, 0.4)  # Оранжево-коричневый
		"fuel":
			building_height = 4.0
			color = Color(0.85, 0.75, 0.3)  # Жёлтый
		"theatre", "cinema":
			building_height = 15.0
			color = Color(0.6, 0.35, 0.5)  # Пурпурный
		"library":
			building_height = 10.0
			color = Color(0.55, 0.45, 0.35)  # Коричневый
		_:
			building_height = 8.0
			color = Color(0.6, 0.5, 0.5)

	# Получаем высоту террейна для здания (берём центр)
	var base_elev := _get_elevation_at_point(_get_polygon_center(points), elev_data)

	_create_3d_building(points, color, building_height, parent, base_elev)

func _create_fence(points: PackedVector2Array, parent: Node3D, elev_data: Dictionary = {}) -> void:
	# Создаём забор по контуру территории
	if points.size() < 3:
		return

	var fence_height := 2.0  # Высота забора в метрах
	var fence_color := Color(0.4, 0.35, 0.3)  # Коричневый/серый
	var fence_offset := 0.3  # Отступ забора от контура здания для предотвращения z-fighting

	var mesh := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	mesh.mesh = im
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

	# Используем шейдер для правильного двустороннего освещения
	var material := ShaderMaterial.new()
	material.shader = BuildingWallShader
	material.set_shader_parameter("albedo_color", fence_color)
	material.set_shader_parameter("use_texture", false)
	mesh.material_override = material

	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)

	# Рисуем забор как стены по периметру с небольшим отступом наружу
	for i in range(points.size()):
		var p1 := points[i]
		var p2 := points[(i + 1) % points.size()]

		# Вычисляем направление наружу для отступа
		var dir := (p2 - p1).normalized()
		var outward := Vector2(-dir.y, dir.x) * fence_offset
		p1 = p1 + outward
		p2 = p2 + outward

		var h1 := _get_elevation_at_point(p1, elev_data) + 0.12
		var h2 := _get_elevation_at_point(p2, elev_data) + 0.12

		var v1 := Vector3(p1.x, h1, p1.y)
		var v2 := Vector3(p2.x, h2, p2.y)
		var v3 := Vector3(p2.x, h2 + fence_height, p2.y)
		var v4 := Vector3(p1.x, h1 + fence_height, p1.y)

		# Нормаль стены (наружу)
		var wall_normal := Vector3(-dir.y, 0, dir.x)
		im.surface_set_normal(wall_normal)

		# Внешняя сторона
		im.surface_add_vertex(v1)
		im.surface_add_vertex(v2)
		im.surface_add_vertex(v3)

		im.surface_add_vertex(v1)
		im.surface_add_vertex(v3)
		im.surface_add_vertex(v4)

	im.surface_end()

	# Добавляем коллизию для забора
	var body := StaticBody3D.new()
	body.collision_layer = 2
	body.collision_mask = 0  # Статика не проверяет коллизии
	body.add_child(mesh)

	for i in range(points.size()):
		var p1 := points[i]
		var p2 := points[(i + 1) % points.size()]

		# Применяем тот же отступ что и для визуала
		var dir := (p2 - p1).normalized()
		var outward := Vector2(-dir.y, dir.x) * fence_offset
		p1 = p1 + outward
		p2 = p2 + outward

		var wall_length := p1.distance_to(p2)
		if wall_length < 0.5:
			continue

		var h1 := _get_elevation_at_point(p1, elev_data) + 0.12
		var h2 := _get_elevation_at_point(p2, elev_data) + 0.12
		var avg_h := (h1 + h2) / 2.0

		var wall_center := Vector3((p1.x + p2.x) / 2, avg_h + fence_height / 2, (p1.y + p2.y) / 2)
		var wall_angle := atan2(p2.y - p1.y, p2.x - p1.x)

		var collision := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(wall_length, fence_height, 0.15)
		collision.shape = box
		collision.position = wall_center
		collision.rotation.y = -wall_angle

		body.add_child(collision)

	parent.add_child(body)

func _create_waterway(nodes: Array, tags: Dictionary, parent: Node3D, loader: Node, elev_data: Dictionary = {}) -> void:
	var waterway_type: String = tags.get("waterway", "")
	var width: float

	match waterway_type:
		"river":
			width = 15.0
		"stream":
			width = 3.0
		"canal":
			width = 8.0
		"ditch", "drain":
			width = 2.0
		_:
			width = 5.0

	_create_path_mesh(nodes, width, COLORS["water"], 0.03, parent, null, elev_data)

func _create_3d_building(points: PackedVector2Array, color: Color, building_height: float, parent: Node3D, base_elev: float = 0.0, _debug_name: String = "") -> void:
	# Минимум 4 точки для нормального здания (3 - треугольник, плохо)
	if points.size() < 4:
		return

	# Убираем дубликат последней точки если она совпадает с первой
	if points.size() > 1 and points[0].distance_to(points[points.size() - 1]) < 0.1:
		points.remove_at(points.size() - 1)

	if points.size() < 3:
		return

	# Проверка на слишком маленькие или вырожденные здания
	var min_x := points[0].x
	var max_x := points[0].x
	var min_z := points[0].y
	var max_z := points[0].y

	for p in points:
		min_x = min(min_x, p.x)
		max_x = max(max_x, p.x)
		min_z = min(min_z, p.y)
		max_z = max(max_z, p.y)

	var size_x := max_x - min_x
	var size_z := max_z - min_z

	# Пропускаем слишком маленькие здания (< 3м)
	if size_x < 3.0 or size_z < 3.0:
		return

	# Пропускаем слишком большие здания (возможно ошибка данных > 200м)
	if size_x > 200.0 or size_z > 200.0:
		return

	# Проверка на соотношение сторон (слишком вытянутые - вероятно ошибка)
	var min_size: float = min(size_x, size_z)
	if min_size < 0.1:
		return
	var aspect: float = max(size_x, size_z) / min_size
	if aspect > 20.0:
		return

	# Проверка на площадь (слишком маленькая площадь = плохие данные)
	var area: float = _calculate_polygon_area(points)
	if area < 10.0:  # Меньше 10 м²
		return

	var mesh := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	mesh.mesh = im
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON  # Отбрасывать тень

	# Используем шейдер для правильного двустороннего освещения
	var material := ShaderMaterial.new()
	material.shader = BuildingWallShader
	material.set_shader_parameter("albedo_color", color)
	material.set_shader_parameter("use_texture", false)
	mesh.material_override = material

	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)

	# Высоты с учётом террейна
	var floor_y := base_elev + 0.1  # Чуть выше террейна
	var roof_y := base_elev + building_height

	# Крыша - используем триангуляцию для корректной работы с невыпуклыми полигонами
	var roof_indices := Geometry2D.triangulate_polygon(points)
	if roof_indices.size() >= 3:
		im.surface_set_normal(Vector3.UP)  # Нормаль вверх для крыши
		for i in range(0, roof_indices.size(), 3):
			var p1 := points[roof_indices[i]]
			var p2 := points[roof_indices[i + 1]]
			var p3 := points[roof_indices[i + 2]]
			im.surface_add_vertex(Vector3(p1.x, roof_y, p1.y))
			im.surface_add_vertex(Vector3(p2.x, roof_y, p2.y))
			im.surface_add_vertex(Vector3(p3.x, roof_y, p3.y))

	# Стены
	for i in range(points.size()):
		var p1 := points[i]
		var p2 := points[(i + 1) % points.size()]

		var v1 := Vector3(p1.x, floor_y, p1.y)
		var v2 := Vector3(p2.x, floor_y, p2.y)
		var v3 := Vector3(p2.x, roof_y, p2.y)
		var v4 := Vector3(p1.x, roof_y, p1.y)

		# Вычисляем нормаль стены (наружу)
		var wall_dir := Vector2(p2.x - p1.x, p2.y - p1.y).normalized()
		var wall_normal := Vector3(-wall_dir.y, 0, wall_dir.x)  # Перпендикуляр
		im.surface_set_normal(wall_normal)

		# Внешняя сторона
		im.surface_add_vertex(v1)
		im.surface_add_vertex(v2)
		im.surface_add_vertex(v3)

		im.surface_add_vertex(v1)
		im.surface_add_vertex(v3)
		im.surface_add_vertex(v4)

	im.surface_end()

	var body := StaticBody3D.new()
	body.collision_layer = 2  # Слой 2 для зданий
	body.collision_mask = 0   # Статика не проверяет коллизии (машина проверяет со зданиями)
	body.add_child(mesh)

	# Создаём коллизию для каждой стены отдельно (точнее чем бокс)
	for i in range(points.size()):
		var p1 := points[i]
		var p2 := points[(i + 1) % points.size()]

		var wall_center := Vector3((p1.x + p2.x) / 2, base_elev + building_height / 2, (p1.y + p2.y) / 2)
		var wall_length := p1.distance_to(p2)

		if wall_length < 0.5:  # Пропускаем слишком короткие стены
			continue

		var wall_angle := atan2(p2.y - p1.y, p2.x - p1.x)

		var collision := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(wall_length, building_height, 0.3)  # Толщина стены 0.3м
		collision.shape = box
		collision.position = wall_center
		collision.rotation.y = -wall_angle

		body.add_child(collision)

	parent.add_child(body)


# === МНОГОПОТОЧНАЯ ГЕНЕРАЦИЯ ЗДАНИЙ ===

## Добавляет здание в очередь для генерации в worker thread
func _queue_building_for_thread(points: PackedVector2Array, building_height: float, texture_type: String, parent: Node3D, base_elev: float) -> void:
	var task_data := {
		"points": points,
		"building_height": building_height,
		"texture_type": texture_type,
		"parent": parent,
		"base_elev": base_elev
	}

	# Добавляем задачу в пул потоков
	_pending_building_tasks += 1
	WorkerThreadPool.add_task(_compute_building_mesh_thread.bind(task_data))


## Вычисляет геометрию здания в worker thread (без создания Node)
func _compute_building_mesh_thread(task_data: Dictionary) -> void:
	var points: PackedVector2Array = task_data.points
	var building_height: float = task_data.building_height
	var base_elev: float = task_data.base_elev

	# Валидация (повторяем проверки без раннего выхода - просто отмечаем как invalid)
	var valid := true

	if points.size() < 4:
		valid = false

	# Убираем дубликат последней точки
	if valid and points.size() > 1 and points[0].distance_to(points[points.size() - 1]) < 0.1:
		points = points.duplicate()
		points.remove_at(points.size() - 1)

	if valid and points.size() < 3:
		valid = false

	# Проверка размеров
	if valid:
		var min_x := points[0].x
		var max_x := points[0].x
		var min_z := points[0].y
		var max_z := points[0].y
		for p in points:
			min_x = min(min_x, p.x)
			max_x = max(max_x, p.x)
			min_z = min(min_z, p.y)
			max_z = max(max_z, p.y)
		var size_x := max_x - min_x
		var size_z := max_z - min_z
		if size_x < 3.0 or size_z < 3.0 or size_x > 200.0 or size_z > 200.0:
			valid = false
		var min_size: float = min(size_x, size_z)
		if min_size < 0.1 or max(size_x, size_z) / min_size > 20.0:
			valid = false
		# Площадь (inline расчёт для thread-safety)
		if valid:
			var area := 0.0
			var n := points.size()
			for i in range(n):
				var j := (i + 1) % n
				area += points[i].x * points[j].y
				area -= points[j].x * points[i].y
			area = abs(area) / 2.0
			if area < 10.0:
				valid = false

	if not valid:
		# Добавляем пустой результат чтобы уменьшить счётчик
		_building_mutex.lock()
		_building_results.append({"valid": false})
		_pending_building_tasks -= 1
		_building_mutex.unlock()
		return

	# === ВЫЧИСЛЕНИЕ ГЕОМЕТРИИ СТЕН ===
	var floor_y := base_elev + 0.1
	var roof_y := base_elev + building_height

	var wall_vertices := PackedVector3Array()
	var wall_uvs := PackedVector2Array()
	var wall_normals := PackedVector3Array()
	var wall_indices := PackedInt32Array()

	var uv_scale_x := 0.1
	var uv_scale_y := 0.1
	var accumulated_width := 0.0

	# Определяем направление полигона для корректных нормалей
	var is_ccw := _is_polygon_ccw(points)
	var normal_sign := 1.0 if is_ccw else -1.0

	for i in range(points.size()):
		var p1 := points[i]
		var p2 := points[(i + 1) % points.size()]
		var wall_width := p1.distance_to(p2)

		var v1 := Vector3(p1.x, floor_y, p1.y)
		var v2 := Vector3(p2.x, floor_y, p2.y)
		var v3 := Vector3(p2.x, roof_y, p2.y)
		var v4 := Vector3(p1.x, roof_y, p1.y)

		var dir := (p2 - p1).normalized()
		# Нормаль наружу - учитываем направление обхода полигона
		var normal := Vector3(-dir.y * normal_sign, 0, dir.x * normal_sign)

		var u1 := accumulated_width * uv_scale_x
		var u2 := (accumulated_width + wall_width) * uv_scale_x
		var v_bottom := 0.0
		var v_top := building_height * uv_scale_y

		var idx := wall_vertices.size()

		wall_vertices.append(v1)
		wall_vertices.append(v2)
		wall_vertices.append(v3)
		wall_vertices.append(v4)

		wall_uvs.append(Vector2(u1, v_bottom))
		wall_uvs.append(Vector2(u2, v_bottom))
		wall_uvs.append(Vector2(u2, v_top))
		wall_uvs.append(Vector2(u1, v_top))

		wall_normals.append(normal)
		wall_normals.append(normal)
		wall_normals.append(normal)
		wall_normals.append(normal)

		wall_indices.append(idx + 0)
		wall_indices.append(idx + 1)
		wall_indices.append(idx + 2)
		wall_indices.append(idx + 0)
		wall_indices.append(idx + 2)
		wall_indices.append(idx + 3)

		accumulated_width += wall_width

	# === ТРИАНГУЛЯЦИЯ КРЫШИ (тяжёлая операция) ===
	var roof_vertices := PackedVector3Array()
	var roof_uvs := PackedVector2Array()
	var roof_normals := PackedVector3Array()
	var roof_indices := PackedInt32Array()

	# Ограничиваем сложность полигонов (слишком много точек могут вызвать зависание)
	if points.size() <= 100:
		var roof_indices_2d := Geometry2D.triangulate_polygon(points)

		if roof_indices_2d.size() >= 3:
			for p in points:
				roof_vertices.append(Vector3(p.x, roof_y, p.y))
				roof_uvs.append(Vector2(p.x * 0.1, p.y * 0.1))
				roof_normals.append(Vector3.UP)
			for idx in roof_indices_2d:
				roof_indices.append(idx)

	# Сохраняем результат
	var result := {
		"valid": true,
		"points": points,
		"building_height": building_height,
		"texture_type": task_data.texture_type,
		"parent": task_data.parent,
		"base_elev": base_elev,
		"wall_vertices": wall_vertices,
		"wall_uvs": wall_uvs,
		"wall_normals": wall_normals,
		"wall_indices": wall_indices,
		"roof_vertices": roof_vertices,
		"roof_uvs": roof_uvs,
		"roof_normals": roof_normals,
		"roof_indices": roof_indices
	}

	_building_mutex.lock()
	_building_results.append(result)
	_pending_building_tasks -= 1
	_building_mutex.unlock()


## Применяет результат вычислений на главном потоке (создаёт Node)
func _apply_building_mesh_result(result: Dictionary) -> void:
	if not result.valid:
		return

	# Проверяем валидность parent до присваивания
	if not is_instance_valid(result.get("parent")):
		return
	var parent: Node3D = result.parent

	var texture_type: String = result.texture_type
	var building_height: float = result.building_height
	var base_elev: float = result.base_elev
	var points: PackedVector2Array = result.points

	# === СОЗДАНИЕ МЕША СТЕН ===
	var wall_arrays := []
	wall_arrays.resize(Mesh.ARRAY_MAX)
	wall_arrays[Mesh.ARRAY_VERTEX] = result.wall_vertices
	wall_arrays[Mesh.ARRAY_TEX_UV] = result.wall_uvs
	wall_arrays[Mesh.ARRAY_NORMAL] = result.wall_normals
	wall_arrays[Mesh.ARRAY_INDEX] = result.wall_indices

	var wall_mesh := ArrayMesh.new()
	wall_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, wall_arrays)

	var wall_mesh_instance := MeshInstance3D.new()
	wall_mesh_instance.mesh = wall_mesh
	wall_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	# Visibility range для автоматического скрытия далёких зданий
	wall_mesh_instance.visibility_range_end = 400.0
	wall_mesh_instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED

	# Материал стен
	var wall_material := ShaderMaterial.new()
	wall_material.shader = BuildingWallShader
	if _building_textures.has(texture_type):
		wall_material.set_shader_parameter("albedo_texture", _building_textures[texture_type])
		wall_material.set_shader_parameter("use_texture", true)
	else:
		wall_material.set_shader_parameter("albedo_color", Color(0.7, 0.6, 0.5))
		wall_material.set_shader_parameter("use_texture", false)
	wall_mesh_instance.material_override = wall_material

	# === СОЗДАНИЕ МЕША КРЫШИ ===
	if result.roof_indices.size() >= 3:
		var roof_arrays := []
		roof_arrays.resize(Mesh.ARRAY_MAX)
		roof_arrays[Mesh.ARRAY_VERTEX] = result.roof_vertices
		roof_arrays[Mesh.ARRAY_TEX_UV] = result.roof_uvs
		roof_arrays[Mesh.ARRAY_NORMAL] = result.roof_normals
		roof_arrays[Mesh.ARRAY_INDEX] = result.roof_indices

		var roof_mesh := ArrayMesh.new()
		roof_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, roof_arrays)

		var roof_mesh_instance := MeshInstance3D.new()
		roof_mesh_instance.mesh = roof_mesh
		roof_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

		var roof_material := StandardMaterial3D.new()
		roof_material.cull_mode = BaseMaterial3D.CULL_BACK  # Оптимизация: включить backface culling
		if _building_textures.has("roof"):
			roof_material.albedo_texture = _building_textures["roof"]
			roof_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		else:
			roof_material.albedo_color = Color(0.4, 0.35, 0.3)
		roof_mesh_instance.material_override = roof_material

		wall_mesh_instance.add_child(roof_mesh_instance)

	# Физическое тело
	var body := StaticBody3D.new()
	body.collision_layer = 2
	body.collision_mask = 0  # Статика не проверяет коллизии
	body.add_child(wall_mesh_instance)
	parent.add_child(body)

	# Коллизии и декорации - отложенно
	_create_building_collisions_deferred.call_deferred(body, points, base_elev, building_height)
	_add_building_night_decorations.call_deferred(wall_mesh_instance, points, building_height, parent)


## Обрабатывает готовые результаты из worker threads (вызывается из _process)
func _process_building_results() -> void:
	if _building_results.is_empty():
		return

	var t0 := Time.get_ticks_usec()
	_building_mutex.lock()
	var results_to_process := _building_results.duplicate()
	_building_results.clear()
	_building_mutex.unlock()

	# Сортируем здания по близости к игроку (если много в очереди)
	if results_to_process.size() > 10 and _car:
		var t_sort := Time.get_ticks_usec()
		_sort_building_results_by_distance(results_to_process, _car.global_position)
		_record_perf("building_sort", Time.get_ticks_usec() - t_sort)

	# Применяем 1 здание за кадр для максимальной плавности
	var t_apply := Time.get_ticks_usec()
	_apply_building_mesh_result(results_to_process[0])
	_record_perf("building_apply", Time.get_ticks_usec() - t_apply)

	# Возвращаем оставшиеся обратно в очередь
	if results_to_process.size() > 1:
		_building_mutex.lock()
		for i in range(1, results_to_process.size()):
			_building_results.append(results_to_process[i])
		_building_mutex.unlock()


## Создаёт debug label для отображения статистики
func _create_debug_label() -> void:
	var canvas := CanvasLayer.new()
	canvas.layer = 100
	add_child(canvas)

	_debug_label = Label.new()
	_debug_label.position = Vector2(10, 100)
	_debug_label.add_theme_font_size_override("font_size", 14)
	_debug_label.add_theme_color_override("font_color", Color.WHITE)
	_debug_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	_debug_label.add_theme_constant_override("shadow_offset_x", 1)
	_debug_label.add_theme_constant_override("shadow_offset_y", 1)
	canvas.add_child(_debug_label)


## Обновляет debug статистику на экране
func _update_debug_stats(delta: float) -> void:
	if not show_debug_stats or not _debug_label:
		return

	# Собираем FPS samples
	var fps := 1.0 / delta if delta > 0 else 0.0
	_fps_samples.append(fps)
	if _fps_samples.size() > 120:  # Храним 2 секунды при 60 FPS
		_fps_samples.remove_at(0)

	# Обновляем label каждые 0.25 сек
	_fps_update_timer += delta
	if _fps_update_timer < 0.25:
		return
	_fps_update_timer = 0.0

	# Вычисляем статистику
	var sorted_fps := _fps_samples.duplicate()
	sorted_fps.sort()
	var avg_fps := 0.0
	for f in _fps_samples:
		avg_fps += f
	avg_fps /= max(1, _fps_samples.size())

	var min_fps: float = sorted_fps[0] if sorted_fps.size() > 0 else 0.0
	var p1_idx := int(sorted_fps.size() * 0.01)
	var fps_1pct: float = sorted_fps[p1_idx] if p1_idx < sorted_fps.size() else 0.0

	# Размеры очередей
	var road_q := _road_queue.size()
	var terrain_q := _terrain_objects_queue.size()
	var infra_q := _infrastructure_queue.size()
	var building_q := _building_results.size()

	_debug_label.text = """FPS: %.0f (avg: %.0f, 1%%: %.0f, min: %.0f)
Queues:
  Roads: %d
  Terrain: %d
  Infra: %d
  Buildings: %d
Chunks: %d loaded""" % [fps, avg_fps, fps_1pct, min_fps, road_q, terrain_q, infra_q, building_q, _loaded_chunks.size()]


## Обрабатывает очередь дорог (3 дороги за кадр)
func _process_road_queue() -> void:
	if _road_queue.is_empty():
		# OPTIMIZATION: Финализируем все pending road batches
		for chunk_key in _pending_batch_chunks:
			_finalize_road_batches_for_chunk(chunk_key)
		_pending_batch_chunks.clear()

		# OPTIMIZATION: Финализируем все pending window batches
		for chunk_key in _window_batch_data.keys():
			_finalize_window_batches_for_chunk(chunk_key)

		# Когда все дороги созданы, обрабатываем бордюры
		_process_curb_queue()
		return

	# Сортируем очередь по расстоянию до игрока (каждые 30 элементов)
	if _road_queue.size() > 30 and _car:
		var t0 := Time.get_ticks_usec()
		_sort_queue_by_distance(_road_queue, _car.global_position)
		_record_perf("road_sort", Time.get_ticks_usec() - t0)

	# Обрабатываем 3 дороги за кадр (фиксированное количество для предсказуемости)
	var max_per_frame := 3
	var processed := 0

	while not _road_queue.is_empty() and processed < max_per_frame:
		var item: Dictionary = _road_queue.pop_front()
		if not is_instance_valid(item.get("parent")):
			continue
		var t0 := Time.get_ticks_usec()
		_create_road_immediate(item.nodes, item.tags, item.parent, item.elev_data)
		_record_perf("road_create", Time.get_ticks_usec() - t0)
		processed += 1


## Обрабатывает очередь бордюров (после того как все перекрёстки определены)
func _process_curb_queue() -> void:
	# Этап 1: Сглаживание точек — 2 бордюра за кадр
	var smoothed_count := 0
	while not _curb_queue.is_empty() and smoothed_count < 2:
		var item: Dictionary = _curb_queue.pop_front()
		if is_instance_valid(item.parent) and item.nodes.size() >= 2:
			var t0 := Time.get_ticks_usec()
			var raw_points: PackedVector2Array = []
			for node in item.nodes:
				var local: Vector2 = _latlon_to_local(node.lat, node.lon)
				raw_points.append(local)
			_record_perf("curb_latlon", Time.get_ticks_usec() - t0)

			# Сглаживаем точки (полное сглаживание как для дорог)
			t0 = Time.get_ticks_usec()
			var smoothed_points: PackedVector2Array = _smooth_road_corners(raw_points)
			_record_perf("curb_smooth", Time.get_ticks_usec() - t0)

			# Добавляем в очередь для генерации меша
			_curb_smoothed_queue.append({
				"points": smoothed_points,
				"width": item.width,
				"height_offset": item.height_offset,
				"curb_height": item.curb_height,
				"parent": item.parent,
				"elev_data": item.elev_data
			})
			smoothed_count += 1

	# Этап 2: Инкрементальная генерация меша — обрабатываем до 50 сегментов за кадр
	var t0 := Time.get_ticks_usec()
	_process_curb_mesh_incremental(50)
	_record_perf("curb_mesh", Time.get_ticks_usec() - t0)


## Инкрементальная генерация меша бордюра
func _process_curb_mesh_incremental(max_segments: int) -> void:
	var segments_processed := 0

	while segments_processed < max_segments:
		# Если нет активного состояния, берём следующий бордюр из очереди
		if _curb_mesh_state.is_empty():
			if _curb_smoothed_queue.is_empty():
				return
			var item: Dictionary = _curb_smoothed_queue.pop_front()
			if not is_instance_valid(item.parent):
				continue
			_init_curb_mesh_state(item)

		# Обрабатываем сегменты
		var remaining := max_segments - segments_processed
		var processed := _process_curb_segments(remaining)
		segments_processed += processed

		# Если бордюр завершён, финализируем меш
		if _curb_mesh_state.current_idx >= _curb_mesh_state.points.size() - 1:
			_finalize_curb_mesh()
			_curb_mesh_state.clear()


## Инициализирует состояние для генерации меша бордюра
func _init_curb_mesh_state(item: Dictionary) -> void:
	var points: PackedVector2Array = item.points
	var road_width: float = item.width
	var curb_height: float = item.curb_height

	var curb_width := 0.15
	var hash_val := int(abs(points[0].x * 1000 + points[0].y * 7919)) % 100
	var z_offset := hash_val * 0.0002
	var curb_ellipse_scale := 1.41

	# Предварительно вычисляем валидные сегменты
	var valid_segments: Array[int] = []
	for i in range(points.size() - 1):
		var p1 := points[i]
		var p2 := points[i + 1]
		var dir := (p2 - p1).normalized()
		var perp := Vector2(-dir.y, dir.x)
		var offset := perp * (road_width * 0.5)
		var left1 := p1 + offset
		var left2 := p2 + offset
		var right1 := p1 - offset
		var right2 := p2 - offset
		if _is_point_in_intersection_ellipse(left1, curb_ellipse_scale) < 0 and \
		   _is_point_in_intersection_ellipse(left2, curb_ellipse_scale) < 0 and \
		   _is_point_in_intersection_ellipse(right1, curb_ellipse_scale) < 0 and \
		   _is_point_in_intersection_ellipse(right2, curb_ellipse_scale) < 0:
			valid_segments.append(i)

	# Разбиваем на группы непрерывных сегментов
	var groups: Array[Array] = []
	var current_group: Array[int] = []
	for seg_idx in valid_segments:
		if current_group.is_empty() or current_group[current_group.size() - 1] == seg_idx - 1:
			current_group.append(seg_idx)
		else:
			if not current_group.is_empty():
				groups.append(current_group.duplicate())
			current_group = [seg_idx]
	if not current_group.is_empty():
		groups.append(current_group)

	_curb_mesh_state = {
		"points": points,
		"road_width": road_width,
		"road_height": item.height_offset,
		"curb_height": curb_height,
		"curb_width": curb_width,
		"z_offset": z_offset,
		"curb_ellipse_scale": curb_ellipse_scale,
		"elev_data": item.elev_data,
		"parent": item.parent,
		"groups": groups,
		"current_group_idx": 0,
		"current_idx_in_group": 0,
		"current_idx": 0,
		"vertices": PackedVector3Array(),
		"normals": PackedVector3Array(),
		"indices": PackedInt32Array()
	}


## Обрабатывает сегменты бордюра
func _process_curb_segments(max_count: int) -> int:
	var state := _curb_mesh_state
	var processed := 0
	var points: PackedVector2Array = state.points
	var groups: Array = state.groups
	var road_width: float = state.road_width
	var road_height: float = state.road_height
	var curb_height: float = state.curb_height
	var curb_width: float = state.curb_width
	var z_offset: float = state.z_offset
	var elev_data: Dictionary = state.elev_data
	var vertices: PackedVector3Array = state.vertices
	var normals: PackedVector3Array = state.normals
	var indices: PackedInt32Array = state.indices

	while processed < max_count and state.current_group_idx < groups.size():
		var group: Array = groups[state.current_group_idx]
		if state.current_idx_in_group >= group.size():
			state.current_group_idx += 1
			state.current_idx_in_group = 0
			continue

		var g_idx: int = state.current_idx_in_group
		var i: int = group[g_idx]
		var is_first := (g_idx == 0)
		var is_last := (g_idx == group.size() - 1)

		var p1 := points[i]
		var p2 := points[i + 1]
		var dir := (p2 - p1).normalized()
		var perp := Vector2(-dir.y, dir.x)

		var h1 := _get_elevation_at_point(p1, elev_data)
		var h2 := _get_elevation_at_point(p2, elev_data)

		var road_y1 := h1 + road_height + z_offset
		var road_y2 := h2 + road_height + z_offset
		var curb_y1 := h1 + road_height + curb_height + z_offset
		var curb_y2 := h2 + road_height + curb_height + z_offset

		var left_inner1 := p1 + perp * (road_width * 0.5)
		var left_outer1 := p1 + perp * (road_width * 0.5 + curb_width)
		var left_inner2 := p2 + perp * (road_width * 0.5)
		var left_outer2 := p2 + perp * (road_width * 0.5 + curb_width)
		var right_inner1 := p1 - perp * (road_width * 0.5)
		var right_outer1 := p1 - perp * (road_width * 0.5 + curb_width)
		var right_inner2 := p2 - perp * (road_width * 0.5)
		var right_outer2 := p2 - perp * (road_width * 0.5 + curb_width)

		var idx := vertices.size()

		# Левый бордюр - внутренняя стенка
		vertices.append(Vector3(left_inner1.x, road_y1, left_inner1.y))
		vertices.append(Vector3(left_inner2.x, road_y2, left_inner2.y))
		vertices.append(Vector3(left_inner2.x, curb_y2, left_inner2.y))
		vertices.append(Vector3(left_inner1.x, curb_y1, left_inner1.y))
		for _j in range(4):
			normals.append(Vector3(-perp.x, 0, -perp.y))
		indices.append(idx + 0); indices.append(idx + 1); indices.append(idx + 2)
		indices.append(idx + 0); indices.append(idx + 2); indices.append(idx + 3)
		idx = vertices.size()

		# Верхняя грань левого бордюра
		vertices.append(Vector3(left_inner1.x, curb_y1, left_inner1.y))
		vertices.append(Vector3(left_inner2.x, curb_y2, left_inner2.y))
		vertices.append(Vector3(left_outer2.x, curb_y2, left_outer2.y))
		vertices.append(Vector3(left_outer1.x, curb_y1, left_outer1.y))
		for _j in range(4):
			normals.append(Vector3.UP)
		indices.append(idx + 0); indices.append(idx + 1); indices.append(idx + 2)
		indices.append(idx + 0); indices.append(idx + 2); indices.append(idx + 3)

		# Торцы левого бордюра
		if is_first:
			idx = vertices.size()
			vertices.append(Vector3(left_inner1.x, road_y1, left_inner1.y))
			vertices.append(Vector3(left_outer1.x, road_y1, left_outer1.y))
			vertices.append(Vector3(left_outer1.x, curb_y1, left_outer1.y))
			vertices.append(Vector3(left_inner1.x, curb_y1, left_inner1.y))
			for _j in range(4):
				normals.append(-dir.x * Vector3(1, 0, 0) - dir.y * Vector3(0, 0, 1))
			indices.append(idx + 0); indices.append(idx + 1); indices.append(idx + 2)
			indices.append(idx + 0); indices.append(idx + 2); indices.append(idx + 3)
		if is_last:
			idx = vertices.size()
			vertices.append(Vector3(left_inner2.x, road_y2, left_inner2.y))
			vertices.append(Vector3(left_outer2.x, road_y2, left_outer2.y))
			vertices.append(Vector3(left_outer2.x, curb_y2, left_outer2.y))
			vertices.append(Vector3(left_inner2.x, curb_y2, left_inner2.y))
			for _j in range(4):
				normals.append(dir.x * Vector3(1, 0, 0) + dir.y * Vector3(0, 0, 1))
			indices.append(idx + 0); indices.append(idx + 2); indices.append(idx + 1)
			indices.append(idx + 0); indices.append(idx + 3); indices.append(idx + 2)

		idx = vertices.size()

		# Правый бордюр - внутренняя стенка
		vertices.append(Vector3(right_inner1.x, road_y1, right_inner1.y))
		vertices.append(Vector3(right_inner2.x, road_y2, right_inner2.y))
		vertices.append(Vector3(right_inner2.x, curb_y2, right_inner2.y))
		vertices.append(Vector3(right_inner1.x, curb_y1, right_inner1.y))
		for _j in range(4):
			normals.append(Vector3(perp.x, 0, perp.y))
		indices.append(idx + 0); indices.append(idx + 2); indices.append(idx + 1)
		indices.append(idx + 0); indices.append(idx + 3); indices.append(idx + 2)
		idx = vertices.size()

		# Верхняя грань правого бордюра
		vertices.append(Vector3(right_inner1.x, curb_y1, right_inner1.y))
		vertices.append(Vector3(right_inner2.x, curb_y2, right_inner2.y))
		vertices.append(Vector3(right_outer2.x, curb_y2, right_outer2.y))
		vertices.append(Vector3(right_outer1.x, curb_y1, right_outer1.y))
		for _j in range(4):
			normals.append(Vector3.UP)
		indices.append(idx + 0); indices.append(idx + 2); indices.append(idx + 1)
		indices.append(idx + 0); indices.append(idx + 3); indices.append(idx + 2)

		# Торцы правого бордюра
		if is_first:
			idx = vertices.size()
			vertices.append(Vector3(right_inner1.x, road_y1, right_inner1.y))
			vertices.append(Vector3(right_outer1.x, road_y1, right_outer1.y))
			vertices.append(Vector3(right_outer1.x, curb_y1, right_outer1.y))
			vertices.append(Vector3(right_inner1.x, curb_y1, right_inner1.y))
			for _j in range(4):
				normals.append(-dir.x * Vector3(1, 0, 0) - dir.y * Vector3(0, 0, 1))
			indices.append(idx + 0); indices.append(idx + 2); indices.append(idx + 1)
			indices.append(idx + 0); indices.append(idx + 3); indices.append(idx + 2)
		if is_last:
			idx = vertices.size()
			vertices.append(Vector3(right_inner2.x, road_y2, right_inner2.y))
			vertices.append(Vector3(right_outer2.x, road_y2, right_outer2.y))
			vertices.append(Vector3(right_outer2.x, curb_y2, right_outer2.y))
			vertices.append(Vector3(right_inner2.x, curb_y2, right_inner2.y))
			for _j in range(4):
				normals.append(dir.x * Vector3(1, 0, 0) + dir.y * Vector3(0, 0, 1))
			indices.append(idx + 0); indices.append(idx + 1); indices.append(idx + 2)
			indices.append(idx + 0); indices.append(idx + 2); indices.append(idx + 3)

		state.current_idx_in_group += 1
		state.current_idx = i + 1
		processed += 1

	# Если все группы обработаны, помечаем завершение
	if state.current_group_idx >= groups.size():
		state.current_idx = points.size()

	return processed


## Финализирует меш бордюра и добавляет в сцену
func _finalize_curb_mesh() -> void:
	var state := _curb_mesh_state
	if not state or not is_instance_valid(state.get("parent")):
		return

	var vertices: PackedVector3Array = state.vertices
	var normals: PackedVector3Array = state.normals
	var indices: PackedInt32Array = state.indices
	var parent: Node3D = state.parent

	if vertices.size() == 0:
		return

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices

	var arr_mesh := ArrayMesh.new()
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mesh := MeshInstance3D.new()
	mesh.mesh = arr_mesh
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.6, 0.6, 0.58)
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
	mesh.material_override = material

	parent.add_child(mesh)

	# Запускаем расчёт коллизий в worker thread
	# Передаём groups (уже вычисленные валидные сегменты) чтобы избежать race condition
	var collision_task := {
		"points": state.points,
		"groups": state.groups,
		"road_width": state.road_width,
		"road_height": state.road_height,
		"curb_height": state.curb_height,
		"curb_width": state.curb_width,
		"z_offset": state.z_offset,
		"elev_data": state.elev_data,
		"parent": parent
	}
	WorkerThreadPool.add_task(_compute_curb_collisions_thread.bind(collision_task))


## Сортирует очередь по расстоянию до игрока (ближайшие первые)
func _sort_queue_by_distance(queue: Array, player_pos: Vector3) -> void:
	var player_pos_2d := Vector2(player_pos.x, player_pos.z)

	# Вычисляем расстояние для каждого элемента
	for item in queue:
		var first_node = item.nodes[0] if item.nodes.size() > 0 else null
		if first_node:
			var pos_2d := _latlon_to_local(first_node.lat, first_node.lon)
			item["_dist"] = pos_2d.distance_squared_to(player_pos_2d)
		else:
			item["_dist"] = 999999.0

	# Сортируем по расстоянию
	queue.sort_custom(func(a, b): return a.get("_dist", 999999.0) < b.get("_dist", 999999.0))


## Сортирует очередь инфраструктуры по расстоянию до игрока
func _sort_infrastructure_by_distance(queue: Array, player_pos: Vector3) -> void:
	var player_pos_2d := Vector2(player_pos.x, player_pos.z)

	# Вычисляем расстояние для каждого элемента
	for item in queue:
		var pos = item.get("pos")
		if pos is Vector2:
			item["_dist"] = pos.distance_squared_to(player_pos_2d)
		else:
			item["_dist"] = 999999.0

	# Сортируем по расстоянию
	queue.sort_custom(func(a, b): return a.get("_dist", 999999.0) < b.get("_dist", 999999.0))


## Сортирует результаты зданий по расстоянию до игрока
func _sort_building_results_by_distance(results: Array, player_pos: Vector3) -> void:
	var player_pos_2d := Vector2(player_pos.x, player_pos.z)

	# Вычисляем расстояние для каждого здания
	for result in results:
		if not result.get("valid", false):
			result["_dist"] = 999999.0
			continue

		var points = result.get("points")
		if points is PackedVector2Array and points.size() > 0:
			# Вычисляем центр здания
			var center := Vector2.ZERO
			for p in points:
				center += p
			center /= points.size()
			result["_dist"] = center.distance_squared_to(player_pos_2d)
		else:
			result["_dist"] = 999999.0

	# Сортируем по расстоянию
	results.sort_custom(func(a, b): return a.get("_dist", 999999.0) < b.get("_dist", 999999.0))


## Обрабатывает очередь terrain объектов (фиксированное количество за кадр)
func _process_terrain_objects_queue() -> void:
	if _terrain_objects_queue.is_empty():
		return

	# Сортируем по расстоянию до игрока
	if _terrain_objects_queue.size() > 20 and _car:
		var t0 := Time.get_ticks_usec()
		_sort_queue_by_distance(_terrain_objects_queue, _car.global_position)
		_record_perf("terrain_sort", Time.get_ticks_usec() - t0)

	var max_per_frame := 2  # Terrain objects могут быть тяжёлыми (деревья)
	var processed := 0

	while not _terrain_objects_queue.is_empty() and processed < max_per_frame:
		var item: Dictionary = _terrain_objects_queue.pop_front()

		# Проверяем что parent ещё существует
		if not is_instance_valid(item.get("parent")):
			continue

		var obj_type: String = item.get("type", "")
		var t0 := Time.get_ticks_usec()

		match obj_type:
			"natural":
				_create_natural_immediate(item.nodes, item.tags, item.parent, item.elev_data)
				_record_perf("terrain_natural", Time.get_ticks_usec() - t0)
			"landuse":
				_create_landuse_immediate(item.nodes, item.tags, item.parent, item.elev_data)
				_record_perf("terrain_landuse", Time.get_ticks_usec() - t0)
			"leisure":
				_create_leisure_immediate(item.nodes, item.tags, item.parent, item.elev_data)
				_record_perf("terrain_leisure", Time.get_ticks_usec() - t0)

		processed += 1


## Обрабатывает очередь инфраструктуры (1 объект за кадр)
func _process_infrastructure_queue() -> void:
	if _infrastructure_queue.is_empty():
		return

	# Сортируем по расстоянию до игрока
	if _infrastructure_queue.size() > 20 and _car:
		var t0 := Time.get_ticks_usec()
		_sort_infrastructure_by_distance(_infrastructure_queue, _car.global_position)
		_record_perf("infra_sort", Time.get_ticks_usec() - t0)

	var item: Dictionary = _infrastructure_queue.pop_front()
	var item_type: String = item.get("type", "")

	# Проверяем что parent ещё существует (мог быть удалён при reset_terrain)
	var parent = item.get("parent")
	if parent == null or not is_instance_valid(parent):
		return

	var t0 := Time.get_ticks_usec()

	match item_type:
		"lamp":
			_create_street_lamp_immediate(item.pos, item.elevation, item.parent, item.get("direction", Vector2.ZERO))
			_record_perf("infra_lamp", Time.get_ticks_usec() - t0)
		"traffic_light":
			_create_traffic_light_immediate(item.pos, item.elevation, item.parent)
			_record_perf("infra_traffic_light", Time.get_ticks_usec() - t0)
		"yield_sign":
			_create_yield_sign_immediate(item.pos, item.elevation, item.parent)
			_record_perf("infra_yield_sign", Time.get_ticks_usec() - t0)
		"parking_sign":
			_create_parking_sign_immediate(item.pos, item.elevation, item.rotation, item.parent)
			_record_perf("infra_parking_sign", Time.get_ticks_usec() - t0)


## Обрабатывает очередь растительности (1 за кадр, низкий приоритет)
func _process_vegetation_queue() -> void:
	if _vegetation_queue.is_empty():
		return

	var item: Dictionary = _vegetation_queue.pop_front()
	var veg_type: String = item.get("type", "")
	var t0 := Time.get_ticks_usec()

	if not is_instance_valid(item.get("parent")):
		return

	match veg_type:
		"trees":
			_create_trees_immediate(item.points, item.elev_data, item.parent, item.dense)
			_record_perf("veg_trees", Time.get_ticks_usec() - t0)
		"vegetation":
			_create_vegetation_immediate(item.points, item.elev_data, item.parent, item.dense)
			_record_perf("veg_bushes_grass", Time.get_ticks_usec() - t0)
		"chunk_vegetation":
			_create_chunk_vegetation_immediate(item.chunk_key, item.points, item.elev_data, item.parent)
			_record_perf("veg_chunk", Time.get_ticks_usec() - t0)


func _create_3d_building_with_texture(points: PackedVector2Array, building_height: float, texture_type: String, parent: Node3D, base_elev: float = 0.0, _debug_name: String = "") -> void:
	# Минимум 4 точки для нормального здания (3 - треугольник, плохо)
	if points.size() < 4:
		return

	# Убираем дубликат последней точки если она совпадает с первой
	if points.size() > 1 and points[0].distance_to(points[points.size() - 1]) < 0.1:
		points.remove_at(points.size() - 1)

	if points.size() < 3:
		return

	# Проверка на слишком маленькие или вырожденные здания
	var min_x := points[0].x
	var max_x := points[0].x
	var min_z := points[0].y
	var max_z := points[0].y

	for p in points:
		min_x = min(min_x, p.x)
		max_x = max(max_x, p.x)
		min_z = min(min_z, p.y)
		max_z = max(max_z, p.y)

	var size_x := max_x - min_x
	var size_z := max_z - min_z

	# Пропускаем слишком маленькие здания (< 3м)
	if size_x < 3.0 or size_z < 3.0:
		return

	# Пропускаем слишком большие здания (возможно ошибка данных > 200м)
	if size_x > 200.0 or size_z > 200.0:
		return

	# Проверка на соотношение сторон (слишком вытянутые - вероятно ошибка)
	var min_size: float = min(size_x, size_z)
	if min_size < 0.1:
		return
	var aspect: float = max(size_x, size_z) / min_size
	if aspect > 20.0:
		return

	# Проверка на площадь (слишком маленькая площадь = плохие данные)
	var area: float = _calculate_polygon_area(points)
	if area < 10.0:  # Меньше 10 м²
		return

	# Высоты с учётом террейна
	var floor_y := base_elev + 0.1  # Чуть выше террейна
	var roof_y := base_elev + building_height

	# === СТЕНЫ с ArrayMesh для UV ===
	var wall_arrays := []
	wall_arrays.resize(Mesh.ARRAY_MAX)

	var wall_vertices := PackedVector3Array()
	var wall_uvs := PackedVector2Array()
	var wall_normals := PackedVector3Array()
	var wall_indices := PackedInt32Array()

	var uv_scale_x := 0.1  # Масштаб UV по горизонтали (10м = 1 повтор текстуры)
	var uv_scale_y := 0.1  # Масштаб UV по вертикали

	# Определяем направление полигона для корректных нормалей
	var is_ccw := _is_polygon_ccw(points)
	var normal_sign := 1.0 if is_ccw else -1.0

	var accumulated_width := 0.0
	for i in range(points.size()):
		var p1 := points[i]
		var p2 := points[(i + 1) % points.size()]

		var wall_width := p1.distance_to(p2)

		var v1 := Vector3(p1.x, floor_y, p1.y)
		var v2 := Vector3(p2.x, floor_y, p2.y)
		var v3 := Vector3(p2.x, roof_y, p2.y)
		var v4 := Vector3(p1.x, roof_y, p1.y)

		# Нормаль стены (наружу) - учитываем направление обхода полигона
		var dir := (p2 - p1).normalized()
		var normal := Vector3(-dir.y * normal_sign, 0, dir.x * normal_sign)

		# UV координаты
		var u1 := accumulated_width * uv_scale_x
		var u2 := (accumulated_width + wall_width) * uv_scale_x
		var v_bottom := 0.0
		var v_top := building_height * uv_scale_y

		var idx := wall_vertices.size()

		wall_vertices.append(v1)
		wall_vertices.append(v2)
		wall_vertices.append(v3)
		wall_vertices.append(v4)

		wall_uvs.append(Vector2(u1, v_bottom))
		wall_uvs.append(Vector2(u2, v_bottom))
		wall_uvs.append(Vector2(u2, v_top))
		wall_uvs.append(Vector2(u1, v_top))

		wall_normals.append(normal)
		wall_normals.append(normal)
		wall_normals.append(normal)
		wall_normals.append(normal)

		# Два треугольника для квадрата стены
		wall_indices.append(idx + 0)
		wall_indices.append(idx + 1)
		wall_indices.append(idx + 2)

		wall_indices.append(idx + 0)
		wall_indices.append(idx + 2)
		wall_indices.append(idx + 3)

		accumulated_width += wall_width

	wall_arrays[Mesh.ARRAY_VERTEX] = wall_vertices
	wall_arrays[Mesh.ARRAY_TEX_UV] = wall_uvs
	wall_arrays[Mesh.ARRAY_NORMAL] = wall_normals
	wall_arrays[Mesh.ARRAY_INDEX] = wall_indices

	var wall_mesh := ArrayMesh.new()
	wall_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, wall_arrays)

	var wall_mesh_instance := MeshInstance3D.new()
	wall_mesh_instance.mesh = wall_mesh
	wall_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	# Visibility range для автоматического скрытия далёких зданий
	wall_mesh_instance.visibility_range_end = 400.0
	wall_mesh_instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED

	# Материал стен с шейдером для правильного двустороннего освещения
	var wall_material := ShaderMaterial.new()
	wall_material.shader = BuildingWallShader
	if _building_textures.has(texture_type):
		wall_material.set_shader_parameter("albedo_texture", _building_textures[texture_type])
		wall_material.set_shader_parameter("use_texture", true)
	else:
		wall_material.set_shader_parameter("albedo_color", Color(0.7, 0.6, 0.5))
		wall_material.set_shader_parameter("use_texture", false)
	wall_mesh_instance.material_override = wall_material

	# === КРЫША с ArrayMesh для UV ===
	var roof_indices_2d := Geometry2D.triangulate_polygon(points)
	if roof_indices_2d.size() >= 3:
		var roof_arrays := []
		roof_arrays.resize(Mesh.ARRAY_MAX)

		var roof_vertices := PackedVector3Array()
		var roof_uvs := PackedVector2Array()
		var roof_normals := PackedVector3Array()
		var roof_indices := PackedInt32Array()

		# Добавляем все вершины крыши
		for p in points:
			roof_vertices.append(Vector3(p.x, roof_y, p.y))
			# UV для крыши - мировые координаты
			roof_uvs.append(Vector2(p.x * 0.1, p.y * 0.1))
			roof_normals.append(Vector3.UP)

		# Индексы из триангуляции
		for idx in roof_indices_2d:
			roof_indices.append(idx)

		roof_arrays[Mesh.ARRAY_VERTEX] = roof_vertices
		roof_arrays[Mesh.ARRAY_TEX_UV] = roof_uvs
		roof_arrays[Mesh.ARRAY_NORMAL] = roof_normals
		roof_arrays[Mesh.ARRAY_INDEX] = roof_indices

		var roof_mesh := ArrayMesh.new()
		roof_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, roof_arrays)

		var roof_mesh_instance := MeshInstance3D.new()
		roof_mesh_instance.mesh = roof_mesh
		roof_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

		# Материал крыши с текстурой
		var roof_material := StandardMaterial3D.new()
		roof_material.cull_mode = BaseMaterial3D.CULL_BACK  # Оптимизация: включить backface culling
		if _building_textures.has("roof"):
			roof_material.albedo_texture = _building_textures["roof"]
			roof_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		else:
			roof_material.albedo_color = Color(0.4, 0.35, 0.3)
		roof_mesh_instance.material_override = roof_material

		# Добавляем крышу к стенам
		wall_mesh_instance.add_child(roof_mesh_instance)

	# Создаём физическое тело
	var body := StaticBody3D.new()
	body.collision_layer = 2  # Слой 2 для зданий
	body.collision_mask = 0   # Статика не проверяет коллизии (машина проверяет со зданиями)
	body.add_child(wall_mesh_instance)

	# Добавляем тело в сцену сразу (визуал появится)
	parent.add_child(body)

	# Создаём коллизии и декорации отложенно (deferred) чтобы не блокировать кадр
	_create_building_collisions_deferred.call_deferred(body, points, base_elev, building_height)
	_add_building_night_decorations.call_deferred(wall_mesh_instance, points, building_height, parent)


# Отложенное создание коллизий зданий (вызывается через call_deferred)
func _create_building_collisions_deferred(body: StaticBody3D, points: PackedVector2Array, base_elev: float, building_height: float) -> void:
	if not is_instance_valid(body):
		return

	for i in range(points.size()):
		var p1 := points[i]
		var p2 := points[(i + 1) % points.size()]

		var wall_center := Vector3((p1.x + p2.x) / 2, base_elev + building_height / 2, (p1.y + p2.y) / 2)
		var wall_length := p1.distance_to(p2)

		if wall_length < 0.5:  # Пропускаем слишком короткие стены
			continue

		var wall_angle := atan2(p2.y - p1.y, p2.x - p1.x)

		var collision := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(wall_length, building_height, 0.3)  # Толщина стены 0.3м
		collision.shape = box
		collision.position = wall_center
		collision.rotation.y = -wall_angle

		body.add_child(collision)

func _create_polygon_mesh(points: PackedVector2Array, color: Color, height_offset: float, parent: Node3D, elev_data: Dictionary = {}) -> void:
	if points.size() < 3:
		return

	# Убираем дубликат последней точки если она совпадает с первой
	if points.size() > 1 and points[0].distance_to(points[points.size() - 1]) < 0.1:
		points.remove_at(points.size() - 1)

	if points.size() < 3:
		return

	var mesh := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	mesh.mesh = im

	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material_override = material

	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)

	# Используем триангуляцию для корректной работы с невыпуклыми полигонами
	var indices := Geometry2D.triangulate_polygon(points)
	if indices.size() >= 3:
		im.surface_set_normal(Vector3.UP)  # Нормаль вверх для плоских поверхностей
		for i in range(0, indices.size(), 3):
			var p1 := points[indices[i]]
			var p2 := points[indices[i + 1]]
			var p3 := points[indices[i + 2]]
			var h1 := _get_elevation_at_point(p1, elev_data) + height_offset
			var h2 := _get_elevation_at_point(p2, elev_data) + height_offset
			var h3 := _get_elevation_at_point(p3, elev_data) + height_offset
			im.surface_add_vertex(Vector3(p1.x, h1, p1.y))
			im.surface_add_vertex(Vector3(p2.x, h2, p2.y))
			im.surface_add_vertex(Vector3(p3.x, h3, p3.y))

	im.surface_end()

	parent.add_child(mesh)

func _create_polygon_mesh_with_texture(points: PackedVector2Array, texture_key: String, height_offset: float, parent: Node3D, elev_data: Dictionary = {}, is_water: bool = false) -> void:
	if points.size() < 3:
		return

	# Убираем дубликат последней точки если она совпадает с первой
	if points.size() > 1 and points[0].distance_to(points[points.size() - 1]) < 0.1:
		points.remove_at(points.size() - 1)

	if points.size() < 3:
		return

	# Триангуляция
	var indices := Geometry2D.triangulate_polygon(points)
	if indices.size() < 3:
		return

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)

	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	var tri_indices := PackedInt32Array()

	var uv_scale := 0.05  # Масштаб UV для земли (20м = 1 повтор текстуры)

	# Добавляем вершины
	for p in points:
		var h := _get_elevation_at_point(p, elev_data) + height_offset
		vertices.append(Vector3(p.x, h, p.y))
		uvs.append(Vector2(p.x * uv_scale, p.y * uv_scale))
		normals.append(Vector3.UP)

	# Добавляем индексы
	for idx in indices:
		tri_indices.append(idx)

	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = tri_indices

	var arr_mesh := ArrayMesh.new()
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mesh := MeshInstance3D.new()
	mesh.mesh = arr_mesh

	# Материал с текстурой
	var material := StandardMaterial3D.new()
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	if _ground_textures.has(texture_key):
		material.albedo_texture = _ground_textures[texture_key]
		material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	else:
		# Fallback цвета
		match texture_key:
			"grass":
				material.albedo_color = Color(0.3, 0.5, 0.2)
			"forest":
				material.albedo_color = Color(0.2, 0.4, 0.15)
			"water":
				material.albedo_color = Color(0.2, 0.4, 0.6)
			_:
				material.albedo_color = Color(0.4, 0.5, 0.3)

	# Для воды добавляем прозрачность
	if is_water:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.albedo_color.a = 0.8

	mesh.material_override = material
	parent.add_child(mesh)

## Создаёт коллизию для парка с группой "Park" (очень высокое сопротивление качению)
func _create_park_collision(points: PackedVector2Array, elev_data: Dictionary, parent: Node3D) -> void:
	if points.size() < 3:
		return

	# Триангуляция для создания коллизии
	var indices := Geometry2D.triangulate_polygon(points)
	if indices.size() < 3:
		return

	var vertices := PackedVector3Array()
	for p in points:
		var h := _get_elevation_at_point(p, elev_data) + 0.01  # Чуть выше террейна
		vertices.append(Vector3(p.x, h, p.y))

	# Создаём меш для коллизии
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array(indices)

	var arr_mesh := ArrayMesh.new()
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mesh := MeshInstance3D.new()
	mesh.mesh = arr_mesh
	mesh.visible = false  # Невидимый меш только для коллизии

	var body := StaticBody3D.new()
	body.name = "ParkCollision"
	body.collision_layer = 1
	body.collision_mask = 0  # Статика не проверяет коллизии
	body.add_to_group("Park")  # GEVP - парк (очень высокое сопротивление)
	body.add_child(mesh)

	# Создаём коллизию
	mesh.create_trimesh_collision()
	for child in mesh.get_children():
		if child is StaticBody3D:
			var col_shape := child.get_child(0)
			if col_shape is CollisionShape3D:
				child.remove_child(col_shape)
				body.add_child(col_shape)
			child.queue_free()

	parent.add_child(body)

# Конвертация lat/lon в локальные координаты относительно стартовой точки
# Примечание: Z инвертирован, т.к. в Godot +Z направлен "от экрана", а latitude растёт на север
func _latlon_to_local(lat: float, lon: float) -> Vector2:
	var dx := (lon - start_lon) * 111000.0 * cos(deg_to_rad(start_lat))
	var dz := (lat - start_lat) * 111000.0
	return Vector2(dx, -dz)  # Инвертируем Z для корректной ориентации карты


## Предзагрузка чанков вдоль маршрута гонки
## waypoints: Array[Vector2] - массив точек (lat, lon)
func preload_route_chunks(waypoints: Array) -> void:
	if waypoints.is_empty():
		return

	print("OSMTerrain: Preloading chunks for %d waypoints" % waypoints.size())

	var chunks_to_load: Array[String] = []

	for wp in waypoints:
		# wp - это Vector2(lat, lon)
		var local_pos := _latlon_to_local(wp.x, wp.y)
		var chunk_x := int(floor(local_pos.x / chunk_size))
		var chunk_z := int(floor(local_pos.y / chunk_size))

		# Загружаем также соседние чанки для плавности
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				var key := "%d,%d" % [chunk_x + dx, chunk_z + dz]
				if key not in chunks_to_load and key not in _loaded_chunks and key not in _loading_chunks:
					chunks_to_load.append(key)

	print("OSMTerrain: Will load %d chunks along route" % chunks_to_load.size())

	# Запускаем загрузку чанков
	for key in chunks_to_load:
		var parts := key.split(",")
		var cx := int(parts[0])
		var cz := int(parts[1])
		_load_chunk(cx, cz)


# Расчёт площади полигона (формула Шолейса)
func _calculate_polygon_area(points: PackedVector2Array) -> float:
	var area := 0.0
	var n := points.size()
	for i in range(n):
		var j := (i + 1) % n
		area += points[i].x * points[j].y
		area -= points[j].x * points[i].y
	return abs(area) / 2.0


# Проверка направления полигона (true = против часовой стрелки = нормали наружу)
func _is_polygon_ccw(points: PackedVector2Array) -> bool:
	var signed_area := 0.0
	var n := points.size()
	for i in range(n):
		var j := (i + 1) % n
		signed_area += points[i].x * points[j].y
		signed_area -= points[j].x * points[i].y
	return signed_area > 0.0  # Положительная = против часовой (CCW)

# Получение центра полигона
func _get_polygon_center(points: PackedVector2Array) -> Vector2:
	if points.size() == 0:
		return Vector2.ZERO
	var center := Vector2.ZERO
	for p in points:
		center += p
	return center / points.size()

# Получение центра way из массива узлов (в локальных координатах)
func _get_way_center(nodes: Array) -> Vector2:
	if nodes.size() == 0:
		return Vector2.ZERO
	var center := Vector2.ZERO
	for node in nodes:
		var local: Vector2 = _latlon_to_local(node.lat, node.lon)
		center += local
	return center / nodes.size()

# Получение высоты террейна в точке
func _get_elevation_at_point(point: Vector2, elev_data: Dictionary) -> float:
	if elev_data.is_empty():
		return 0.0

	var grid: Array = elev_data.get("grid", [])
	var grid_size: int = elev_data.get("grid_size", 0)
	var min_elev: float = elev_data.get("min_elevation", 0.0)

	if grid_size < 2 or grid.size() == 0:
		return 0.0

	# Определяем позицию в сетке
	# Точка в локальных координатах, нужно преобразовать в координаты сетки чанка
	# Сетка покрывает chunk_size x chunk_size метров

	# Нормализуем координаты относительно чанка
	# Примечание: elev_data содержит данные для конкретного чанка
	var center_lat: float = elev_data.get("center_lat", start_lat)
	var center_lon: float = elev_data.get("center_lon", start_lon)

	# Преобразуем точку обратно в lat/lon
	var lon := start_lon + point.x / (111000.0 * cos(deg_to_rad(start_lat)))
	var lat := start_lat - point.y / 111000.0  # Y инвертирован

	# Смещение от центра чанка
	var lat_delta := chunk_size / 111000.0
	var lon_delta := chunk_size / (111000.0 * cos(deg_to_rad(center_lat)))

	# Нормализуем к [0, 1]
	var x_norm := (lon - (center_lon - lon_delta / 2)) / lon_delta
	var z_norm := ((center_lat + lat_delta / 2) - lat) / lat_delta

	x_norm = clamp(x_norm, 0.0, 1.0)
	z_norm = clamp(z_norm, 0.0, 1.0)

	# Используем интерполяцию из ElevationLoader
	var elevation := ElevationLoaderScript.interpolate_elevation(grid, grid_size, x_norm, z_norm)

	# Возвращаем высоту относительно базовой
	return (elevation - _base_elevation) * elevation_scale


# Создание дерева из 3D модели берёзы
func _create_tree(pos: Vector2, elevation: float, parent: Node3D) -> void:
	# Контейнер без масштабирования (для коллизии)
	var tree_root := Node3D.new()
	tree_root.name = "Tree"
	tree_root.position = Vector3(pos.x, elevation, pos.y)

	# Визуальная модель дерева (масштабируется)
	var tree_model: Node3D = BIRCH_TREE_SCENE.instantiate()
	var scale_factor := randf_range(0.015, 0.022)
	tree_model.scale = Vector3(scale_factor, scale_factor, scale_factor)
	tree_root.add_child(tree_model)

	# Коллизия для ствола
	# Ствол в модели находится примерно на (200, 0, 200) в единицах модели
	# После масштабирования: позиция = координаты_модели * scale_factor
	# При scale 0.0185 (среднее): 200 * 0.0185 = 3.7
	var trunk_offset_x := 195.0  # X чуть к 9 часам
	var trunk_offset_z := 190.0  # Z чуть к 12 часам
	var trunk_x := trunk_offset_x * scale_factor
	var trunk_z := trunk_offset_z * scale_factor

	var body := StaticBody3D.new()
	body.collision_layer = 2  # Слой статических объектов
	body.collision_mask = 0   # Статика не проверяет коллизии
	body.name = "TreeCollision"

	var collision := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.4  # Радиус ствола
	shape.height = 8.0  # Высота коллизии 8м
	collision.shape = shape
	# Коллизия на позиции ствола (масштабируется вместе с моделью)
	collision.position = Vector3(trunk_x, 4.0, trunk_z)
	body.add_child(collision)
	tree_root.add_child(body)

	# DEBUG: Визуализация коллизии (зелёный цилиндр)
	# Раскомментировать для отладки позиции коллизии
	#var debug_mesh := MeshInstance3D.new()
	#var cylinder := CylinderMesh.new()
	#cylinder.top_radius = 0.4
	#cylinder.bottom_radius = 0.4
	#cylinder.height = 8.0
	#debug_mesh.mesh = cylinder
	#var debug_mat := StandardMaterial3D.new()
	#debug_mat.albedo_color = Color(0, 1, 0, 0.5)
	#debug_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	#debug_mesh.material_override = debug_mat
	#debug_mesh.position = Vector3(trunk_x, 4.0, trunk_z)
	#tree_root.add_child(debug_mesh)

	parent.add_child(tree_root)


# Создание дорожного знака - разрушаемый при столкновении
func _create_traffic_sign(pos: Vector2, elevation: float, tags: Dictionary, parent: Node3D) -> void:
	# Смещаем знак с дороги если нужно
	var safe_pos := _move_object_off_road(pos, 0.5, 5)
	if safe_pos == Vector2.ZERO:
		# Не нашли безопасное место, пропускаем
		return

	# Проверяем на дубликаты (с учётом новой позиции)
	var pos_key := "ts_%d_%d" % [int(safe_pos.x), int(safe_pos.y)]
	if _created_sign_positions.has(pos_key):
		return
	_created_sign_positions[pos_key] = true

	# RigidBody3D как корневой узел для физики
	var body := RigidBody3D.new()
	body.name = "TrafficSign"
	body.position = Vector3(safe_pos.x, elevation, safe_pos.y)
	body.collision_layer = 4  # Слой 4 - разрушаемые знаки
	body.collision_mask = 7  # Машины(1) + статика(2) + другие знаки(4)
	body.mass = 15.0
	body.freeze = true
	body.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	body.contact_monitor = true
	body.max_contacts_reported = 4
	body.body_entered.connect(_on_sign_hit.bind(body))

	# Коллизия для столба
	var collision := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.05
	shape.height = 2.5
	collision.shape = shape
	collision.position.y = 1.25
	body.add_child(collision)

	# Столб - серый тонкий цилиндр
	var pole := MeshInstance3D.new()
	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = 0.03
	pole_mesh.bottom_radius = 0.04
	pole_mesh.height = 2.5
	pole.mesh = pole_mesh

	var pole_mat := StandardMaterial3D.new()
	pole_mat.albedo_color = Color(0.5, 0.5, 0.5)  # Серый
	pole_mat.metallic = 0.8
	pole.material_override = pole_mat
	pole.position.y = 1.25
	pole.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	body.add_child(pole)

	# Знак - красный/белый диск
	var sign_plate := MeshInstance3D.new()
	var sign_mesh := CylinderMesh.new()
	sign_mesh.top_radius = 0.3
	sign_mesh.bottom_radius = 0.3
	sign_mesh.height = 0.02
	sign_plate.mesh = sign_mesh

	var sign_mat := StandardMaterial3D.new()
	# Определяем цвет по типу знака
	var sign_type: String = str(tags.get("traffic_sign", ""))
	if "stop" in sign_type.to_lower():
		sign_mat.albedo_color = Color(0.9, 0.1, 0.1)  # Красный
	elif "yield" in sign_type.to_lower() or "give_way" in sign_type.to_lower():
		sign_mat.albedo_color = Color(0.9, 0.9, 0.1)  # Жёлтый
	elif "speed" in sign_type.to_lower():
		sign_mat.albedo_color = Color(0.95, 0.95, 0.95)  # Белый с красной каймой
	else:
		sign_mat.albedo_color = Color(0.2, 0.4, 0.8)  # Синий (информационный)

	sign_plate.material_override = sign_mat
	sign_plate.position.y = 2.3
	sign_plate.rotation.x = PI / 2  # Повернуть горизонтально
	sign_plate.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	body.add_child(sign_plate)

	parent.add_child(body)


# Создание уличного фонаря - добавляет в очередь
func _create_street_lamp(pos: Vector2, elevation: float, parent: Node3D, direction_to_road: Vector2 = Vector2.ZERO) -> void:
	# Проверяем, не создан ли уже фонарь в этой позиции (округляем до метров)
	var pos_key := "%d_%d" % [int(pos.x), int(pos.y)]
	if _created_lamp_positions.has(pos_key):
		return
	_created_lamp_positions[pos_key] = true

	# Добавляем в очередь для отложенного создания
	_infrastructure_queue.append({
		"type": "lamp",
		"pos": pos,
		"elevation": elevation,
		"parent": parent,
		"direction": direction_to_road
	})


# Немедленное создание фонаря (вызывается из очереди)
func _create_street_lamp_immediate(pos: Vector2, elevation: float, parent: Node3D, direction_to_road: Vector2 = Vector2.ZERO) -> void:
	if not is_instance_valid(parent):
		return

	var lamp := Node3D.new()
	lamp.position = Vector3(pos.x, elevation, pos.y)

	# Поворачиваем весь фонарь в направлении дороги (+90° + 180° чтобы кронштейн смотрел К дороге)
	if direction_to_road.length() > 0.1:
		var angle_to_road := atan2(direction_to_road.x, direction_to_road.y) - PI / 2
		lamp.rotation.y = angle_to_road

	var pole_mat := StandardMaterial3D.new()
	pole_mat.albedo_color = Color(0.25, 0.25, 0.25)  # Тёмно-серый
	pole_mat.metallic = 0.9

	# Основной столб - тёмно-серый цилиндр
	var pole := MeshInstance3D.new()
	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = 0.05
	pole_mesh.bottom_radius = 0.08
	pole_mesh.height = 5.5
	pole.mesh = pole_mesh
	pole.material_override = pole_mat
	pole.position.y = 2.75
	pole.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	lamp.add_child(pole)

	# Кронштейн - наклонный цилиндр от верха столба к лампе (наклон ВВЕРХ)
	var arm_length := 2.0
	var arm_angle := PI / 6  # 30 градусов вверх от горизонтали
	var arm := MeshInstance3D.new()
	var arm_mesh := CylinderMesh.new()
	arm_mesh.top_radius = 0.03
	arm_mesh.bottom_radius = 0.04
	arm_mesh.height = arm_length
	arm.mesh = arm_mesh
	arm.material_override = pole_mat
	arm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

	# Кронштейн идёт от столба вверх и в сторону
	var arm_start_y := 5.0  # Точка крепления к столбу
	var arm_end_x := arm_length * cos(arm_angle)  # Горизонтальное смещение
	var arm_end_y := arm_start_y + arm_length * sin(arm_angle)  # Вертикальное смещение (вверх)

	# Позиция центра кронштейна
	arm.position.x = arm_end_x / 2.0
	arm.position.y = (arm_start_y + arm_end_y) / 2.0

	# Поворот кронштейна: наклон вверх
	arm.rotation.z = PI / 2 + arm_angle
	lamp.add_child(arm)

	# Плафон - светлая сфера на конце кронштейна
	var light_globe := MeshInstance3D.new()
	var globe_mesh := SphereMesh.new()
	globe_mesh.radius = 0.2
	globe_mesh.height = 0.35
	light_globe.mesh = globe_mesh

	# 5% шанс что фонарь сломан (определяем до создания плафона)
	var is_broken := randf() < 0.05

	# Проверяем, включён ли ночной режим
	var is_night := _is_night_mode
	if not is_night:
		var night_manager := get_tree().current_scene.find_child("NightModeManager", true, false)
		if night_manager:
			is_night = night_manager.is_night

	var globe_mat := StandardMaterial3D.new()
	# Настраиваем плафон в зависимости от состояния (ночь/день, сломан/работает)
	if is_night and not is_broken:
		globe_mat.albedo_color = Color(1.0, 0.75, 0.3)  # Натриевый оранжевый
		globe_mat.emission_enabled = true
		globe_mat.emission = Color(1.0, 0.65, 0.2)  # Тёплый натриевый
		globe_mat.emission_energy_multiplier = 5.0
	else:
		globe_mat.albedo_color = Color(0.3, 0.3, 0.3)  # Серый днём или сломан
		globe_mat.emission_enabled = false
	light_globe.material_override = globe_mat
	light_globe.name = "LampGlobe"
	# Сохраняем флаг "сломан" в метаданных плафона
	light_globe.set_meta("is_broken", is_broken)

	# Позиция плафона на конце кронштейна
	light_globe.position.x = arm_end_x
	light_globe.position.y = arm_end_y
	lamp.add_child(light_globe)

	# Добавляем источник света - OmniLight для освещения вокруг
	var lamp_light := OmniLight3D.new()
	lamp_light.name = "LampLight"
	lamp_light.position = light_globe.position
	lamp_light.omni_range = 12.0  # Радиус освещения
	lamp_light.omni_attenuation = 1.2
	lamp_light.light_energy = 1.5
	lamp_light.light_color = Color(1.0, 0.65, 0.2)  # Тёплый натриевый жёлто-оранжевый
	lamp_light.shadow_enabled = false
	lamp_light.light_bake_mode = Light3D.BAKE_DISABLED
	# Фонарь светит только ночью и если не сломан
	lamp_light.visible = is_night and not is_broken
	# Сохраняем флаг "сломан" в метаданных для переключения день/ночь
	lamp_light.set_meta("is_broken", is_broken)
	lamp.add_child(lamp_light)

	# Коллизия для столба
	var body := StaticBody3D.new()
	body.collision_layer = 2
	body.collision_mask = 0  # Статика не проверяет коллизии
	var collision := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.1
	shape.height = 5.5
	collision.shape = shape
	collision.position.y = 2.75
	body.add_child(collision)
	lamp.add_child(body)

	parent.add_child(lamp)


# Процедурная генерация деревьев в полигоне (парк, лес) - добавляет в очередь
func _generate_trees_in_polygon(points: PackedVector2Array, elev_data: Dictionary, parent: Node3D, dense: bool = false) -> void:
	if points.size() < 3:
		return

	# Добавляем в очередь растительности для обработки по кадрам
	_vegetation_queue.append({
		"type": "trees",
		"points": points,
		"elev_data": elev_data,
		"parent": parent,
		"dense": dense
	})

	# Также добавляем траву и кусты в парках и на газонах
	_vegetation_queue.append({
		"type": "vegetation",
		"points": points,
		"elev_data": elev_data,
		"parent": parent,
		"dense": dense
	})


# Немедленное создание деревьев (вызывается из очереди)
func _create_trees_immediate(points: PackedVector2Array, elev_data: Dictionary, parent: Node3D, dense: bool = false) -> void:
	if not is_instance_valid(parent):
		return

	# Вычисляем bounding box
	var min_x := points[0].x
	var max_x := points[0].x
	var min_y := points[0].y
	var max_y := points[0].y

	for p in points:
		min_x = min(min_x, p.x)
		max_x = max(max_x, p.x)
		min_y = min(min_y, p.y)
		max_y = max(max_y, p.y)

	var width := max_x - min_x
	var height := max_y - min_y

	# Ограничиваем максимальное количество деревьев на полигон
	var max_trees := 50 if dense else 30
	var tree_count := 0

	# Используем хаотичное размещение на основе хеша координат полигона
	var seed_value := int(abs(min_x * 1000 + min_y * 100 + width * 10 + height)) % 10000
	var avg_spacing := 12.0 if dense else 20.0
	var estimated_trees := int((width * height) / (avg_spacing * avg_spacing))
	estimated_trees = mini(estimated_trees, max_trees)

	for i in range(estimated_trees):
		var hash1 := fmod(float(seed_value + i * 7919) * 0.61803398875, 1.0)
		var hash2 := fmod(float(seed_value + i * 104729) * 0.41421356237, 1.0)

		var hash3 := fmod(hash1 * 17.0 + hash2 * 31.0, 1.0)
		var hash4 := fmod(hash2 * 23.0 + hash1 * 13.0, 1.0)

		var test_x := min_x + (hash1 * 0.7 + hash3 * 0.3) * width
		var test_y := min_y + (hash2 * 0.7 + hash4 * 0.3) * height
		var test_point := Vector2(test_x, test_y)

		if Geometry2D.is_point_in_polygon(test_point, points):
			if _is_point_near_road(test_point, 3.0):
				continue

			var elevation := _get_elevation_at_point(test_point, elev_data)
			_create_tree(test_point, elevation, parent)
			tree_count += 1

			if tree_count >= max_trees:
				break


# Немедленное создание травы и кустов (вызывается из очереди, без коллизий)
func _create_vegetation_immediate(points: PackedVector2Array, elev_data: Dictionary, parent: Node3D, dense: bool = false) -> void:
	if points.size() < 3:
		return

	# Вычисляем bounding box
	var min_x := points[0].x
	var max_x := points[0].x
	var min_y := points[0].y
	var max_y := points[0].y

	for p in points:
		min_x = min(min_x, p.x)
		max_x = max(max_x, p.x)
		min_y = min(min_y, p.y)
		max_y = max(max_y, p.y)

	var width := max_x - min_x
	var height := max_y - min_y
	var area := width * height

	# Пропускаем слишком маленькие или большие полигоны
	if area < 100.0 or area > 50000.0:
		return

	# Создаём контейнер для растительности
	var veg_container := Node3D.new()
	veg_container.name = "Vegetation"
	parent.add_child(veg_container)

	# Генерация кустов с использованием MultiMesh
	var bush_count := mini(int(area * 0.005), 30)  # ~5 кустов на 1000 кв.м
	if dense:
		bush_count = mini(int(area * 0.01), 50)

	# Временно отключено
	# if bush_count > 0:
	# 	_create_bush_multimesh(points, bush_count, elev_data, veg_container)

	# Генерация травяных пучков с использованием MultiMesh
	var grass_count := mini(int(area * 0.02), 100)  # ~20 пучков на 1000 кв.м
	if dense:
		grass_count = mini(int(area * 0.05), 200)

	# Временно отключено
	# if grass_count > 0:
	# 	_create_grass_multimesh(points, grass_count, elev_data, veg_container)


# Создаёт MultiMesh с кустами
func _create_bush_multimesh(points: PackedVector2Array, count: int, elev_data: Dictionary, parent: Node3D) -> void:
	var min_x := points[0].x
	var max_x := points[0].x
	var min_y := points[0].y
	var max_y := points[0].y

	for p in points:
		min_x = min(min_x, p.x)
		max_x = max(max_x, p.x)
		min_y = min(min_y, p.y)
		max_y = max(max_y, p.y)

	var width := max_x - min_x
	var height := max_y - min_y

	# Создаём меш куста
	var bush_mesh := _create_bush_mesh()

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = bush_mesh
	multimesh.instance_count = count

	var seed_value := int(abs(min_x * 1000 + min_y * 100)) % 10000
	var valid_count := 0

	for i in range(count * 3):  # Пробуем больше точек чтобы набрать нужное количество
		if valid_count >= count:
			break

		var hash1 := fmod(float(seed_value + i * 7919) * 0.61803398875, 1.0)
		var hash2 := fmod(float(seed_value + i * 104729) * 0.41421356237, 1.0)

		var test_x := min_x + hash1 * width
		var test_y := min_y + hash2 * height
		var test_point := Vector2(test_x, test_y)

		if Geometry2D.is_point_in_polygon(test_point, points):
			if _is_point_near_road(test_point, 2.0):
				continue

			var elevation := _get_elevation_at_point(test_point, elev_data)
			var transform := Transform3D()

			# Случайный поворот
			var rotation := fmod(float(seed_value + i * 31) * 2.718281828, TAU)
			transform = transform.rotated(Vector3.UP, rotation)

			# Случайный масштаб
			var scale_factor := 0.6 + fmod(float(seed_value + i * 17) * 1.414, 0.8)
			transform = transform.scaled(Vector3(scale_factor, scale_factor, scale_factor))

			# Позиция
			transform.origin = Vector3(test_x, elevation, test_y)

			multimesh.set_instance_transform(valid_count, transform)
			valid_count += 1

	if valid_count == 0:
		return

	multimesh.instance_count = valid_count

	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Bushes"
	mmi.multimesh = multimesh
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mmi)


# Извлекает меш куста из загруженной GLB модели (Kenney Nature Kit)
func _create_bush_mesh() -> Mesh:
	print("OSM: Loading bush model from ", BUSH_MODEL_PATH)
	if not _bush_model:
		_bush_model = load(BUSH_MODEL_PATH)
		if not _bush_model:
			print("ERROR: Failed to load bush model!")
			return null
		print("OSM: Bush model loaded successfully")
	return _extract_mesh_from_scene(_bush_model)


# Создаёт MultiMesh с травой
func _create_grass_multimesh(points: PackedVector2Array, count: int, elev_data: Dictionary, parent: Node3D) -> void:
	var min_x := points[0].x
	var max_x := points[0].x
	var min_y := points[0].y
	var max_y := points[0].y

	for p in points:
		min_x = min(min_x, p.x)
		max_x = max(max_x, p.x)
		min_y = min(min_y, p.y)
		max_y = max(max_y, p.y)

	var width := max_x - min_x
	var height := max_y - min_y

	# Создаём меш пучка травы
	var grass_mesh := _create_grass_clump_mesh()

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = grass_mesh
	multimesh.instance_count = count

	var seed_value := int(abs(min_x * 1234 + min_y * 567)) % 10000
	var valid_count := 0

	for i in range(count * 3):
		if valid_count >= count:
			break

		var hash1 := fmod(float(seed_value + i * 6271) * 0.61803398875, 1.0)
		var hash2 := fmod(float(seed_value + i * 89123) * 0.41421356237, 1.0)

		var test_x := min_x + hash1 * width
		var test_y := min_y + hash2 * height
		var test_point := Vector2(test_x, test_y)

		if Geometry2D.is_point_in_polygon(test_point, points):
			if _is_point_near_road(test_point, 1.5):
				continue

			var elevation := _get_elevation_at_point(test_point, elev_data)
			var transform := Transform3D()

			var rotation := fmod(float(seed_value + i * 41) * 2.718281828, TAU)
			transform = transform.rotated(Vector3.UP, rotation)

			var scale_factor := 0.7 + fmod(float(seed_value + i * 23) * 1.618, 0.6)
			transform = transform.scaled(Vector3(scale_factor, scale_factor, scale_factor))

			transform.origin = Vector3(test_x, elevation, test_y)

			multimesh.set_instance_transform(valid_count, transform)
			valid_count += 1

	if valid_count == 0:
		return

	multimesh.instance_count = valid_count

	var mmi := MultiMeshInstance3D.new()
	mmi.name = "GrassClumps"
	mmi.multimesh = multimesh
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mmi)


# Извлекает меш травы из загруженной GLB модели (Kenney Nature Kit)
func _create_grass_clump_mesh() -> Mesh:
	print("OSM: Loading grass model from ", GRASS_MODEL_PATH)
	if not _grass_model:
		_grass_model = load(GRASS_MODEL_PATH)
		if not _grass_model:
			print("ERROR: Failed to load grass model!")
			return null
		print("OSM: Grass model loaded successfully")
	return _extract_mesh_from_scene(_grass_model)


# Вспомогательная функция для извлечения меша из PackedScene (GLB модели)
func _extract_mesh_from_scene(scene: PackedScene) -> Mesh:
	if not scene:
		print("ERROR: Scene is null in _extract_mesh_from_scene")
		return null

	print("OSM: Instantiating scene...")
	var instance := scene.instantiate()
	if not instance:
		print("ERROR: Failed to instantiate scene!")
		return null

	print("OSM: Searching for mesh in node tree...")
	var mesh: Mesh = null

	# Ищем MeshInstance3D в дереве
	mesh = _find_mesh_in_node(instance)

	if not mesh:
		print("ERROR: No mesh found in scene!")
	else:
		print("OSM: Mesh found successfully")

	# Освобождаем ноду напрямую (она не в дереве сцены)
	instance.free()
	return mesh


# Рекурсивно ищет первый меш в дереве нод
func _find_mesh_in_node(node: Node) -> Mesh:
	if node is MeshInstance3D:
		return node.mesh

	for child in node.get_children():
		var found := _find_mesh_in_node(child)
		if found:
			return found

	return null


# Добавляет растительность на пустые участки чанка в очередь
func _queue_chunk_vegetation(chunk_key: String, parent: Node3D) -> void:
	var coords: Array = chunk_key.split(",")
	var chunk_x := int(coords[0])
	var chunk_z := int(coords[1])

	var chunk_min_x := chunk_x * chunk_size
	var chunk_min_z := chunk_z * chunk_size

	# Создаём прямоугольник чанка для генерации
	var chunk_points: PackedVector2Array = []
	chunk_points.append(Vector2(chunk_min_x, chunk_min_z))
	chunk_points.append(Vector2(chunk_min_x + chunk_size, chunk_min_z))
	chunk_points.append(Vector2(chunk_min_x + chunk_size, chunk_min_z + chunk_size))
	chunk_points.append(Vector2(chunk_min_x, chunk_min_z + chunk_size))

	# Получаем данные высот
	var elev_data: Dictionary = {}
	if _chunk_elevations.has(chunk_key):
		elev_data = _chunk_elevations[chunk_key]

	# Добавляем в очередь растительности для пустых участков
	_vegetation_queue.append({
		"type": "chunk_vegetation",
		"chunk_key": chunk_key,
		"points": chunk_points,
		"elev_data": elev_data,
		"parent": parent
	})


# Создаёт растительность на пустых участках чанка
func _create_chunk_vegetation_immediate(chunk_key: String, points: PackedVector2Array, elev_data: Dictionary, parent: Node3D) -> void:
	if not is_instance_valid(parent):
		return

	var min_x := points[0].x
	var max_x := points[2].x
	var min_z := points[0].y
	var max_z := points[2].y

	# Параметры генерации
	var grass_spacing := 8.0  # Расстояние между пучками травы
	var bush_spacing := 25.0  # Расстояние между кустами

	var seed_value := hash(chunk_key)
	var grass_count := 0
	var bush_count := 0
	var max_grass := 100
	var max_bushes := 15

	# Создаём контейнер для растительности чанка
	var veg_container := Node3D.new()
	veg_container.name = "ChunkVegetation"
	parent.add_child(veg_container)

	# Меши для MultiMesh
	var grass_mesh := _create_grass_clump_mesh()
	var bush_mesh := _create_bush_mesh()

	# Собираем позиции травы и кустов
	var grass_transforms: Array[Transform3D] = []
	var bush_transforms: Array[Transform3D] = []

	# Генерируем позиции на сетке с джиттером
	var x := min_x + grass_spacing / 2.0
	while x < max_x and grass_count < max_grass:
		var z := min_z + grass_spacing / 2.0
		while z < max_z and grass_count < max_grass:
			# Псевдослучайное смещение
			var hash1 := fmod(float(seed_value + int(x * 100) * 7 + int(z * 100) * 13) * 0.61803, 1.0)
			var hash2 := fmod(float(seed_value + int(x * 100) * 11 + int(z * 100) * 17) * 0.41421, 1.0)

			var jitter_x := (hash1 - 0.5) * grass_spacing * 0.8
			var jitter_z := (hash2 - 0.5) * grass_spacing * 0.8

			var pos := Vector2(x + jitter_x, z + jitter_z)

			# Проверяем что не на дороге
			if not _is_point_near_road(pos, 4.0):
				var elevation := _get_elevation_at_point(pos, elev_data)

				# ПРОВЕРКА: Пропускаем если высота невалидна
				if not is_finite(elevation):
					z += grass_spacing
					continue

				var transform := Transform3D()
				var rotation := fmod(float(seed_value + int(x * 10) + int(z * 10)) * 2.718, TAU)

				# ПРОВЕРКА: Пропускаем если rotation невалиден
				if not is_finite(rotation):
					z += grass_spacing
					continue

				transform = transform.rotated(Vector3.UP, rotation)

				var scale_factor := 0.8 + hash1 * 0.5
				transform = transform.scaled(Vector3(scale_factor, scale_factor, scale_factor))
				transform.origin = Vector3(pos.x, elevation + 0.01, pos.y)

				# Финальная проверка transform перед добавлением
				if transform.origin.is_finite() and transform.basis.x.is_finite() and transform.basis.y.is_finite() and transform.basis.z.is_finite():
					grass_transforms.append(transform)
					grass_count += 1

			z += grass_spacing
		x += grass_spacing

	# Генерируем кусты (реже)
	x = min_x + bush_spacing / 2.0
	while x < max_x and bush_count < max_bushes:
		var z := min_z + bush_spacing / 2.0
		while z < max_z and bush_count < max_bushes:
			var hash1 := fmod(float(seed_value + int(x * 50) * 23 + int(z * 50) * 31) * 0.61803, 1.0)
			var hash2 := fmod(float(seed_value + int(x * 50) * 29 + int(z * 50) * 37) * 0.41421, 1.0)

			# Только 40% позиций получают куст
			if hash1 < 0.4:
				var jitter_x := (hash2 - 0.5) * bush_spacing * 0.6
				var jitter_z := (fmod(hash1 * 3.14, 1.0) - 0.5) * bush_spacing * 0.6

				var pos := Vector2(x + jitter_x, z + jitter_z)

				if not _is_point_near_road(pos, 5.0):
					var elevation := _get_elevation_at_point(pos, elev_data)

					# ПРОВЕРКА: Пропускаем если высота невалидна
					if not is_finite(elevation):
						z += bush_spacing
						continue

					var transform := Transform3D()
					var rotation := fmod(float(seed_value + int(x * 20) + int(z * 20)) * 1.618, TAU)

					# ПРОВЕРКА: Пропускаем если rotation невалиден
					if not is_finite(rotation):
						z += bush_spacing
						continue

					transform = transform.rotated(Vector3.UP, rotation)

					var scale_factor := 0.7 + hash2 * 0.6
					transform = transform.scaled(Vector3(scale_factor, scale_factor, scale_factor))
					transform.origin = Vector3(pos.x, elevation, pos.y)

					# Финальная проверка transform перед добавлением
					if transform.origin.is_finite() and transform.basis.x.is_finite() and transform.basis.y.is_finite() and transform.basis.z.is_finite():
						bush_transforms.append(transform)
						bush_count += 1

			z += bush_spacing
		x += bush_spacing

	# Создаём MultiMesh для травы
	if grass_transforms.size() > 0:
		var grass_mm := MultiMesh.new()
		grass_mm.transform_format = MultiMesh.TRANSFORM_3D
		grass_mm.mesh = grass_mesh
		grass_mm.instance_count = grass_transforms.size()

		for i in range(grass_transforms.size()):
			grass_mm.set_instance_transform(i, grass_transforms[i])

		var grass_mmi := MultiMeshInstance3D.new()
		grass_mmi.name = "ChunkGrass"
		grass_mmi.multimesh = grass_mm
		grass_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		veg_container.add_child(grass_mmi)

	# Создаём MultiMesh для кустов
	if bush_transforms.size() > 0:
		var bush_mm := MultiMesh.new()
		bush_mm.transform_format = MultiMesh.TRANSFORM_3D
		bush_mm.mesh = bush_mesh
		bush_mm.instance_count = bush_transforms.size()

		for i in range(bush_transforms.size()):
			bush_mm.set_instance_transform(i, bush_transforms[i])

		var bush_mmi := MultiMeshInstance3D.new()
		bush_mmi.name = "ChunkBushes"
		bush_mmi.multimesh = bush_mm
		bush_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		veg_container.add_child(bush_mmi)


# Процедурная генерация промышленных зданий внутри территории
func _generate_industrial_buildings(points: PackedVector2Array, elev_data: Dictionary, parent: Node3D) -> void:
	if points.size() < 4:
		return

	# Вычисляем bounding box
	var min_x := points[0].x
	var max_x := points[0].x
	var min_y := points[0].y
	var max_y := points[0].y

	for p in points:
		min_x = min(min_x, p.x)
		max_x = max(max_x, p.x)
		min_y = min(min_y, p.y)
		max_y = max(max_y, p.y)

	var width := max_x - min_x
	var height := max_y - min_y

	# Пропускаем слишком маленькие территории
	if width < 20.0 or height < 20.0:
		return

	var area := width * height
	if area < 500.0:
		return

	# Генерируем 1-2 здания
	var seed_value := int(abs(min_x * 73 + min_y * 37)) % 10000
	var num_buildings := 1
	if area > 2000:
		num_buildings = 2

	var building_color := Color(0.75, 0.55, 0.4)  # Кирпичный/промышленный цвет

	for i in range(num_buildings):
		# Псевдослучайная позиция (простой хеш)
		var hash1 := fmod(float(seed_value + i * 127) * 0.618, 1.0)
		var hash2 := fmod(float(seed_value + i * 311) * 0.414, 1.0)
		var hash3 := fmod(float(seed_value + i * 541) * 0.314, 1.0)

		# Позиция в центральной части (20-80% от размера)
		var bld_x := min_x + width * (0.2 + hash1 * 0.6)
		var bld_y := min_y + height * (0.2 + hash2 * 0.6)
		var bld_center := Vector2(bld_x, bld_y)

		# Проверяем что центр внутри полигона
		if not Geometry2D.is_point_in_polygon(bld_center, points):
			continue

		# Размер здания (фиксированный, небольшой)
		var bld_width := 10.0 + hash1 * 10.0   # 10-20 м
		var bld_depth := 12.0 + hash2 * 12.0   # 12-24 м
		var bld_height := 6.0 + hash3 * 6.0    # 6-12 м

		# Создаём прямоугольный контур здания
		var half_w := bld_width / 2.0
		var half_d := bld_depth / 2.0
		var bld_points: PackedVector2Array = [
			Vector2(bld_x - half_w, bld_y - half_d),
			Vector2(bld_x + half_w, bld_y - half_d),
			Vector2(bld_x + half_w, bld_y + half_d),
			Vector2(bld_x - half_w, bld_y + half_d)
		]

		# Проверяем что все углы внутри полигона
		var all_inside := true
		for corner in bld_points:
			if not Geometry2D.is_point_in_polygon(corner, points):
				all_inside = false
				break

		if all_inside:
			var base_elev := _get_elevation_at_point(bld_center, elev_data)
			_create_3d_building(bld_points, building_color, bld_height, parent, base_elev)


# Процедурная генерация фонарей вдоль дороги
func _generate_street_lamps_along_road(nodes: Array, road_width: float, elev_data: Dictionary, parent: Node3D) -> void:
	if nodes.size() < 2:
		return

	var lamp_spacing := 25.0  # Расстояние между фонарями (метры)
	var lamp_offset := road_width / 2 + 1.5  # Смещение от края дороги

	var accumulated_distance := 0.0
	var last_lamp_distance := 0.0

	for i in range(nodes.size() - 1):
		var p1 := _latlon_to_local(nodes[i].lat, nodes[i].lon)
		var p2 := _latlon_to_local(nodes[i + 1].lat, nodes[i + 1].lon)

		var segment_length := p1.distance_to(p2)
		var dir := (p2 - p1).normalized()
		var perp := Vector2(-dir.y, dir.x)  # Перпендикуляр

		# Проходим по сегменту и ставим фонари
		var pos_along := 0.0
		while pos_along < segment_length:
			var distance_from_last := accumulated_distance + pos_along - last_lamp_distance

			if distance_from_last >= lamp_spacing:
				# Интерполируем позицию
				var t := pos_along / segment_length
				var road_pos := p1.lerp(p2, t)

				# Ставим фонари по обе стороны дороги
				var lamp_pos_left := road_pos + perp * lamp_offset
				var lamp_pos_right := road_pos - perp * lamp_offset

				# Проверяем, не попадают ли фонари на парковку
				var left_on_parking := _is_point_in_any_parking(lamp_pos_left)
				var right_on_parking := _is_point_in_any_parking(lamp_pos_right)

				var elev_left := _get_elevation_at_point(lamp_pos_left, elev_data)
				var elev_right := _get_elevation_at_point(lamp_pos_right, elev_data)

				# Направление к дороге (от фонаря к центру дороги)
				var dir_to_road_left := -perp  # Левый фонарь смотрит вправо (к дороге)
				var dir_to_road_right := perp   # Правый фонарь смотрит влево (к дороге)

				# Сохраняем позиции фонарей для отложенного создания
				# (после загрузки всех чанков когда все парковки известны)
				_pending_lamps.append({
					"pos": lamp_pos_left,
					"elev": elev_left,
					"parent": parent,
					"dir": dir_to_road_left
				})
				_pending_lamps.append({
					"pos": lamp_pos_right,
					"elev": elev_right,
					"parent": parent,
					"dir": dir_to_road_right
				})

				last_lamp_distance = accumulated_distance + pos_along

			pos_along += lamp_spacing / 4  # Проверяем чаще для точности

		accumulated_distance += segment_length


func _create_pending_lamps() -> void:
	"""Создаёт отложенные фонари, фильтруя те что на парковках"""
	print("OSM: _create_pending_lamps started, count=%d" % _pending_lamps.size())
	if _pending_lamps.is_empty():
		print("OSM: No pending lamps")
		return

	var created := 0
	var skipped := 0

	for lamp_data in _pending_lamps:
		var pos: Vector2 = lamp_data.pos
		var elev: float = lamp_data.elev
		var dir: Vector2 = lamp_data.dir

		# Находим ПРАВИЛЬНЫЙ чанк для этого фонаря по его позиции
		var chunk_x := int(floor(pos.x / chunk_size))
		var chunk_z := int(floor(pos.y / chunk_size))
		var chunk_key := "%d,%d" % [chunk_x, chunk_z]

		# Проверяем что чанк загружен
		if not _loaded_chunks.has(chunk_key):
			skipped += 1
			continue

		var parent: Node3D = _loaded_chunks[chunk_key]

		# Проверяем что фонарь не на парковке
		if _is_point_in_any_parking(pos):
			skipped += 1
			continue

		# Проверяем что фонарь не на дороге (с небольшим запасом)
		if _is_point_on_road(pos, 0.5):
			skipped += 1
			continue

		_create_street_lamp(pos, elev, parent, dir)
		created += 1

	if created > 0:
		print("OSM: Created %d lamps, skipped %d (on parking or chunk not loaded)" % [created, skipped])
	_pending_lamps.clear()
	_lamps_created = true  # Флаг только для начальной загрузки


func _create_pending_parking_signs() -> void:
	"""Создаёт отложенные знаки парковки (теперь все дороги известны)"""
	print("OSM: _create_pending_parking_signs started, count=%d, road_segments=%d" % [_pending_parking_signs.size(), _road_segments.size()])

	var created := 0
	for sign_data in _pending_parking_signs:
		var points: PackedVector2Array = sign_data.points
		var elev_data: Dictionary = sign_data.elev_data
		var parent: Node3D = sign_data.parent

		var sign_result = _find_parking_sign_position(points)
		if sign_result.is_empty():
			continue

		var sign_pos: Vector2 = sign_result.position
		var sign_rotation: float = sign_result.rotation
		var base_elev = _get_elevation_at_point(sign_pos, elev_data)

		_create_parking_sign(sign_pos, base_elev, sign_rotation, parent)
		created += 1

	print("OSM: Created %d parking signs" % created)
	_pending_parking_signs.clear()


func _is_point_in_any_parking(point: Vector2) -> bool:
	"""Проверяет, находится ли точка внутри или рядом с любой парковкой"""
	const PARKING_BUFFER := 10.0  # Буфер вокруг парковки (метры) - увеличен

	for parking in _parking_polygons:
		if parking.size() < 3:
			continue

		# Вычисляем центр и максимальный радиус парковки для быстрой отсечки
		var center := Vector2.ZERO
		for p in parking:
			center += p
		center /= parking.size()

		var max_radius := 0.0
		for p in parking:
			max_radius = max(max_radius, center.distance_to(p))

		# Быстрая отсечка - если точка слишком далеко от центра
		if point.distance_to(center) > max_radius + PARKING_BUFFER + 5.0:
			continue

		# 1. Проверка - внутри полигона
		if Geometry2D.is_point_in_polygon(point, parking):
			return true

		# 2. Проверяем расстояние до ближайшего ребра парковки
		for i in range(parking.size()):
			var p1: Vector2 = parking[i]
			var p2: Vector2 = parking[(i + 1) % parking.size()]

			# Ближайшая точка на отрезке к нашей точке
			var edge: Vector2 = p2 - p1
			var edge_len_sq: float = edge.length_squared()
			if edge_len_sq < 0.0001:
				continue

			var t: float = clamp((point - p1).dot(edge) / edge_len_sq, 0.0, 1.0)
			var closest: Vector2 = p1 + edge * t
			var dist: float = point.distance_to(closest)

			if dist < PARKING_BUFFER:
				return true

	return false


func _is_point_near_road(point: Vector2, min_distance: float) -> bool:
	"""Проверяет, находится ли точка слишком близко к любой дороге"""
	for seg in _road_segments:
		var p1: Vector2 = seg.p1
		var p2: Vector2 = seg.p2
		var road_width: float = seg.width

		# Вычисляем расстояние от точки до сегмента дороги
		var closest := Geometry2D.get_closest_point_to_segment(point, p1, p2)
		var dist := point.distance_to(closest)

		# Учитываем ширину дороги (расстояние от центра до края + буфер)
		if dist < (road_width / 2.0) + min_distance:
			return true

	return false


func _is_point_near_any_parking(point: Vector2, max_distance: float) -> bool:
	"""Проверяет, находится ли точка близко к любой парковке"""
	for parking in _parking_polygons:
		if parking.size() < 3:
			continue

		# Вычисляем центр парковки
		var center := Vector2.ZERO
		for p in parking:
			center += p
		center /= parking.size()

		# Максимальное расстояние от центра до угла
		var max_radius := 0.0
		for p in parking:
			max_radius = max(max_radius, center.distance_to(p))

		# Быстрая отсечка
		if point.distance_to(center) > max_radius + max_distance + 5.0:
			continue

		# Проверяем внутри
		if Geometry2D.is_point_in_polygon(point, parking):
			return true

		# Проверяем расстояние до каждого ребра
		for i in range(parking.size()):
			var p1: Vector2 = parking[i]
			var p2: Vector2 = parking[(i + 1) % parking.size()]

			var edge: Vector2 = p2 - p1
			var edge_len_sq: float = edge.length_squared()
			if edge_len_sq < 0.0001:
				continue

			var t: float = clamp((point - p1).dot(edge) / edge_len_sq, 0.0, 1.0)
			var closest: Vector2 = p1 + edge * t

			if point.distance_to(closest) < max_distance:
				return true

	return false


# Создание светофора на перекрёстке
func _create_traffic_light(pos: Vector2, elevation: float, parent: Node3D) -> void:
	# Смещаем светофор с дороги если нужно
	var safe_pos := _move_object_off_road(pos, 0.5, 5)
	if safe_pos == Vector2.ZERO:
		# Не нашли безопасное место, пропускаем
		return

	# Добавляем в очередь для отложенного создания
	_infrastructure_queue.append({
		"type": "traffic_light",
		"pos": safe_pos,
		"elevation": elevation,
		"parent": parent
	})


# Немедленное создание светофора (вызывается из очереди)
func _create_traffic_light_immediate(pos: Vector2, elevation: float, parent: Node3D) -> void:
	if not is_instance_valid(parent):
		return

	var traffic_light := Node3D.new()
	traffic_light.position = Vector3(pos.x, elevation, pos.y)

	# Столб - тёмно-серый
	var pole := MeshInstance3D.new()
	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = 0.08
	pole_mesh.bottom_radius = 0.1
	pole_mesh.height = 4.5
	pole.mesh = pole_mesh

	var pole_mat := StandardMaterial3D.new()
	pole_mat.albedo_color = Color(0.2, 0.2, 0.2)
	pole_mat.metallic = 0.8
	pole.material_override = pole_mat
	pole.position.y = 2.25
	pole.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	traffic_light.add_child(pole)

	# Корпус светофора - чёрный бокс
	var box := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = Vector3(0.35, 1.0, 0.25)
	box.mesh = box_mesh

	var box_mat := StandardMaterial3D.new()
	box_mat.albedo_color = Color(0.1, 0.1, 0.1)
	box.material_override = box_mat
	box.position.y = 4.2
	box.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	traffic_light.add_child(box)

	# Красный сигнал
	var red_light := MeshInstance3D.new()
	var light_mesh := SphereMesh.new()
	light_mesh.radius = 0.1
	light_mesh.height = 0.2
	red_light.mesh = light_mesh

	var red_mat := StandardMaterial3D.new()
	red_mat.albedo_color = Color(0.9, 0.1, 0.1)
	red_mat.emission_enabled = true
	red_mat.emission = Color(0.9, 0.1, 0.1)
	red_mat.emission_energy_multiplier = 0.3
	red_light.material_override = red_mat
	red_light.position = Vector3(0, 4.5, 0.13)
	traffic_light.add_child(red_light)

	# Жёлтый сигнал
	var yellow_light := MeshInstance3D.new()
	yellow_light.mesh = light_mesh

	var yellow_mat := StandardMaterial3D.new()
	yellow_mat.albedo_color = Color(0.9, 0.7, 0.1)
	yellow_light.material_override = yellow_mat
	yellow_light.position = Vector3(0, 4.2, 0.13)
	traffic_light.add_child(yellow_light)

	# Зелёный сигнал
	var green_light := MeshInstance3D.new()
	green_light.mesh = light_mesh

	var green_mat := StandardMaterial3D.new()
	green_mat.albedo_color = Color(0.1, 0.7, 0.1)
	green_mat.emission_enabled = true
	green_mat.emission = Color(0.1, 0.8, 0.1)
	green_mat.emission_energy_multiplier = 0.5
	green_light.material_override = green_mat
	green_light.position = Vector3(0, 3.9, 0.13)
	traffic_light.add_child(green_light)

	# Коллизия для столба
	var body := StaticBody3D.new()
	body.collision_layer = 2
	body.collision_mask = 0  # Статика не проверяет коллизии
	var collision := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.12
	shape.height = 4.5
	collision.shape = shape
	collision.position.y = 2.25
	body.add_child(collision)
	traffic_light.add_child(body)

	parent.add_child(traffic_light)


# Создание знаков на перекрёстке (уступи дорогу)
func _create_intersection_signs(pos: Vector2, elevation: float, parent: Node3D) -> void:
	# Ставим знак немного в стороне от центра перекрёстка
	var offset := 5.0

	# 4 знака по углам перекрёстка
	var offsets: Array[Vector2] = [
		Vector2(offset, offset),
		Vector2(-offset, offset),
		Vector2(offset, -offset),
		Vector2(-offset, -offset)
	]

	for off in offsets:
		var sign_pos: Vector2 = pos + off
		# Создаём знак "Уступи дорогу" (треугольный)
		_create_yield_sign(sign_pos, elevation, parent)


# Создание знака "Уступи дорогу" - разрушаемый при столкновении
func _create_yield_sign(pos: Vector2, elevation: float, parent: Node3D) -> void:
	# Смещаем знак с дороги если нужно
	var safe_pos := _move_object_off_road(pos, 0.5, 5)
	if safe_pos == Vector2.ZERO:
		# Не нашли безопасное место, пропускаем
		return

	# Проверяем на дубликаты (с учётом новой позиции)
	var pos_key := "ys_%d_%d" % [int(safe_pos.x), int(safe_pos.y)]
	if _created_sign_positions.has(pos_key):
		return
	_created_sign_positions[pos_key] = true

	# Добавляем в очередь для отложенного создания
	_infrastructure_queue.append({
		"type": "yield_sign",
		"pos": safe_pos,
		"elevation": elevation,
		"parent": parent
	})


# Немедленное создание знака (вызывается из очереди)
func _create_yield_sign_immediate(pos: Vector2, elevation: float, parent: Node3D) -> void:
	if not is_instance_valid(parent):
		return

	# RigidBody3D как корневой узел для физики
	var body := RigidBody3D.new()
	body.name = "YieldSign"
	body.position = Vector3(pos.x, elevation, pos.y)
	body.collision_layer = 4  # Слой 4 - разрушаемые знаки
	body.collision_mask = 7  # Машины(1) + статика(2) + другие знаки(4)
	body.mass = 12.0
	body.freeze = true
	body.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	body.contact_monitor = true
	body.max_contacts_reported = 4
	body.body_entered.connect(_on_sign_hit.bind(body))

	# Коллизия
	var collision := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.05
	shape.height = 2.2
	collision.shape = shape
	collision.position.y = 1.1
	body.add_child(collision)

	# Столб
	var pole := MeshInstance3D.new()
	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = 0.03
	pole_mesh.bottom_radius = 0.04
	pole_mesh.height = 2.2
	pole.mesh = pole_mesh

	var pole_mat := StandardMaterial3D.new()
	pole_mat.albedo_color = Color(0.5, 0.5, 0.5)
	pole_mat.metallic = 0.8
	pole.material_override = pole_mat
	pole.position.y = 1.1
	pole.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	body.add_child(pole)

	# Треугольный знак (используем призму/цилиндр с 3 гранями)
	var sign_plate := MeshInstance3D.new()
	var sign_mesh := PrismMesh.new()
	sign_mesh.size = Vector3(0.5, 0.5, 0.02)
	sign_plate.mesh = sign_mesh

	var sign_mat := StandardMaterial3D.new()
	sign_mat.albedo_color = Color(0.95, 0.95, 0.95)  # Белый с красной каймой (упрощённо - белый)
	sign_plate.material_override = sign_mat
	sign_plate.position.y = 2.3
	sign_plate.rotation.x = PI / 2  # Поворот чтобы был вертикально
	sign_plate.rotation.z = PI  # Вершина вниз (уступи дорогу)
	sign_plate.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	body.add_child(sign_plate)

	parent.add_child(body)

# Извлечение данных дороги для навигации NPC
func _extract_road_for_traffic(nodes: Array, tags: Dictionary, elev_data: Dictionary) -> void:
	"""Извлекает данные дороги в RoadNetwork для навигации NPC"""
	# Проверяем наличие TrafficManager
	if not get_parent().has_node("TrafficManager"):
		return

	var traffic_mgr = get_parent().get_node("TrafficManager")
	if not traffic_mgr.has_method("get_road_network"):
		return

	var road_network = traffic_mgr.get_road_network()
	if road_network == null:
		return

	# Конвертируем nodes в PackedVector2Array
	var local_points := PackedVector2Array()
	for node in nodes:
		var local: Vector2 = _latlon_to_local(node.lat, node.lon)
		local_points.append(local)

	# Определяем chunk_key по первой точке дороги
	var first_point := local_points[0]
	var chunk_x := int(floor(first_point.x / chunk_size))
	var chunk_z := int(floor(first_point.y / chunk_size))
	var chunk_key := "%d,%d" % [chunk_x, chunk_z]

	# Получаем тип дороги
	var highway_type: String = tags.get("highway", "residential")

	# Добавляем дорожный сегмент в RoadNetwork
	road_network.add_road_segment(local_points, highway_type, chunk_key, elev_data)


# === NIGHT MODE ===

var _is_wet_mode := false
var _night_mode_connected := false
var _night_mode_manager = null  # Кэш ссылки на NightModeManager (для избежания повторных поисков)
var _building_night_lights: Array[Node3D] = []  # Храним ссылки на созданные источники света

var _is_night_mode := false

func set_wet_mode(enabled: bool, is_night: bool = true) -> void:
	"""Включает/выключает мокрый асфальт для дорог"""
	_is_night_mode = is_night

	if _is_wet_mode == enabled:
		# Даже если состояние не изменилось, нужно обновить материалы если изменился день/ночь
		if enabled:
			for chunk_key in _loaded_chunks.keys():
				var chunk: Node3D = _loaded_chunks[chunk_key]
				_update_chunk_road_wetness(chunk, enabled, is_night)
		return

	_is_wet_mode = enabled
	print("OSM: Wet mode ", "enabled" if enabled else "disabled")

	# Обновляем материалы всех загруженных дорог
	for chunk_key in _loaded_chunks.keys():
		var chunk: Node3D = _loaded_chunks[chunk_key]
		_update_chunk_road_wetness(chunk, enabled, is_night)


func _update_chunk_road_wetness(chunk: Node3D, is_wet: bool, is_night: bool = true) -> void:
	"""Обновляет материалы дорог в чанке для мокрого/сухого состояния"""
	for child in chunk.get_children():
		# Дороги добавляются как MeshInstance3D прямо в чанк
		if child is MeshInstance3D:
			var mat := child.material_override as StandardMaterial3D
			if mat and _is_road_material(mat):
				_apply_wet_material(mat, is_wet, is_night)
		# Также проверяем внутри StaticBody3D (бордюры и коллизии)
		elif child is StaticBody3D:
			for mesh_child in child.get_children():
				if mesh_child is MeshInstance3D:
					var mat := mesh_child.material_override as StandardMaterial3D
					if mat and _is_road_material(mat):
						_apply_wet_material(mat, is_wet, is_night)


func _is_road_material(mat: StandardMaterial3D) -> bool:
	"""Проверяет, является ли материал дорожным (не бордюр, не здание)"""
	# Дороги имеют текстуру или тёмный цвет асфальта
	if mat.albedo_texture:
		return true
	# Проверяем цвет - дороги обычно тёмно-серые
	var color := mat.albedo_color
	if color.r < 0.5 and color.g < 0.5 and color.b < 0.5:
		return true
	return false


func _apply_wet_material(mat: StandardMaterial3D, is_wet: bool, is_night: bool = true) -> void:
	"""Применяет свойства мокрого/сухого асфальта к материалу"""
	WetRoadMaterial.apply_wet_properties(mat, is_wet, is_night)


func _connect_to_night_mode() -> void:
	"""Подключается к NightModeManager для получения сигналов"""
	if _night_mode_connected:
		return

	var night_manager := get_tree().current_scene.find_child("NightModeManager", true, false)
	if night_manager:
		_night_mode_manager = night_manager  # Кэшируем ссылку
		night_manager.night_mode_changed.connect(_on_night_mode_changed)
		_night_mode_connected = true
		# Если уже ночь - включаем фонари
		if night_manager.is_night:
			_on_night_mode_changed(true)


func _setup_render_distance() -> void:
	"""Настраивает дальность прорисовки камеры, туман и дистанции чанков"""
	# Настраиваем дистанции загрузки чанков
	load_distance = render_distance + 100.0  # Загружаем чуть дальше видимости
	unload_distance = render_distance + 300.0  # Выгружаем с запасом
	print("OSM: Chunk distances - load: %.0f, unload: %.0f" % [load_distance, unload_distance])

	# Настраиваем камеру
	if _camera:
		_camera.far = render_distance * 1.5  # Немного дальше тумана
		print("OSM: Camera far plane set to %.0f" % _camera.far)

	# Настраиваем туман (Godot 4 использует экспоненциальный туман)
	if fog_enabled:
		var world_env := get_tree().current_scene.find_child("WorldEnvironment", true, false) as WorldEnvironment
		if world_env and world_env.environment:
			var env := world_env.environment
			env.fog_enabled = true
			# Плотность тумана обратно пропорциональна дальности
			# При 400м density ~= 0.002, при 100м ~= 0.008, при 800м ~= 0.001
			env.fog_density = 0.8 / render_distance
			env.fog_light_color = Color(0.7, 0.75, 0.85)  # Светло-серо-голубой
			env.fog_light_energy = 1.0
			env.fog_aerial_perspective = 0.5  # Эффект дымки на расстоянии
			print("OSM: Fog enabled (density: %.4f for %.0fm)" % [env.fog_density, render_distance])


func _on_night_mode_changed(enabled: bool) -> void:
	"""Обрабатывает переключение ночного режима"""
	print("OSM: Night mode ", "enabled" if enabled else "disabled")
	_is_night_mode = enabled

	# Обновляем все фонари и неоновые вывески
	for chunk_key in _loaded_chunks.keys():
		var chunk: Node3D = _loaded_chunks[chunk_key]
		_update_chunk_night_lights(chunk, enabled)


func _apply_night_mode_to_chunk(chunk: Node3D) -> void:
	"""Применяет текущее состояние ночного режима к чанку"""
	# Проверяем состояние ночного режима из NightModeManager
	var night_manager := get_tree().current_scene.find_child("NightModeManager", true, false)
	var is_night := false
	if night_manager:
		is_night = night_manager.is_night
	elif _is_night_mode:
		is_night = true

	if is_night:
		_update_chunk_night_lights(chunk, true)


func _update_chunk_night_lights(chunk: Node3D, night_enabled: bool) -> void:
	"""Включает/выключает ночное освещение в чанке"""
	_recursive_update_lights(chunk, night_enabled)


func _recursive_update_lights(node: Node, night_enabled: bool) -> void:
	"""Рекурсивно обновляет все источники света"""
	# Проверяем лампы уличных фонарей (SpotLight3D или OmniLight3D для совместимости)
	if node.name == "LampLight" and (node is SpotLight3D or node is OmniLight3D):
		# Проверяем не сломана ли лампа
		var is_broken: bool = node.get_meta("is_broken", false)
		# Сломанные лампы не включаются
		node.visible = night_enabled and not is_broken

	# Проверяем плафоны фонарей (LampGlobe)
	if node.name == "LampGlobe" and node is MeshInstance3D:
		var is_broken: bool = node.get_meta("is_broken", false)
		if node.material_override:
			var mat := node.material_override as StandardMaterial3D
			if mat:
				if night_enabled and not is_broken:
					mat.emission_enabled = true
					mat.emission = Color(1.0, 0.65, 0.2)
					mat.emission_energy_multiplier = 5.0
					mat.albedo_color = Color(1.0, 0.85, 0.5)  # Тёплый жёлтый
				else:
					mat.emission_enabled = false
					mat.albedo_color = Color(0.3, 0.3, 0.3)  # Серый днём

	# Проверяем неоновые вывески
	if node.name.begins_with("NeonSign"):
		node.visible = night_enabled

	# Проверяем окна (MultiMeshInstance3D с шейдером)
	if node.name.begins_with("Windows_") and node is MultiMeshInstance3D:
		var mat := node.material_override as ShaderMaterial
		if mat:
			mat.set_shader_parameter("is_night", night_enabled)

	# Рекурсивно обходим дочерние ноды
	for child in node.get_children():
		_recursive_update_lights(child, night_enabled)


# Цвета для неоновых вывесок (NFS Underground style)
const NEON_COLORS := [
	Color(1.0, 0.0, 0.4),   # Hot pink
	Color(0.0, 1.0, 0.9),   # Cyan
	Color(1.0, 0.3, 0.0),   # Orange
	Color(0.0, 0.5, 1.0),   # Blue
	Color(1.0, 1.0, 0.0),   # Yellow
	Color(0.8, 0.0, 1.0),   # Purple
	Color(0.0, 1.0, 0.3),   # Green
]


var _neon_signs_created := 0

func _add_building_night_decorations(building_mesh: MeshInstance3D, points: PackedVector2Array, building_height: float, parent: Node3D) -> void:
	"""Добавляет неоновые вывески и освещённые окна к зданию"""
	# Проверка на дублирование - ищем уже существующие окна по позиции
	var center := _get_polygon_center(points)
	var window_name := "Windows_%d" % hash(Vector2(center.x, center.y))

	# Проверяем, есть ли уже окна с таким именем в parent
	for child in parent.get_children():
		if child.name.begins_with("Windows_") or child.name.begins_with("NeonSign_"):
			# Проверяем позицию - если совпадает, пропускаем
			if child is Node3D:
				var child_pos := Vector2(child.position.x, child.position.z)
				if child_pos.distance_to(center) < 1.0:
					return  # Уже есть декорации для этого здания

	# Случайный seed на основе позиции здания
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector2(center.x, center.y))

	# Размер здания
	var min_x := points[0].x
	var max_x := points[0].x
	var min_z := points[0].y
	var max_z := points[0].y
	for p in points:
		min_x = min(min_x, p.x)
		max_x = max(max_x, p.x)
		min_z = min(min_z, p.y)
		max_z = max(max_z, p.y)

	var building_width := max_x - min_x
	var building_depth := max_z - min_z

	# 35% шанс на неоновую вывеску
	if rng.randf() < 0.35 and building_width > 5.0:
		_add_neon_sign(center, building_height, building_width, rng, parent, building_depth)
		_neon_signs_created += 1

	# Добавляем светящиеся окна для зданий выше 1 этажа
	if building_height > 3.5:
		_add_building_windows(points, building_height, rng, parent)


func _add_neon_sign(center: Vector2, height: float, width: float, rng: RandomNumberGenerator, parent: Node3D, depth: float = 0.0) -> void:
	"""Добавляет неоновую вывеску на здание - видимую издалека"""
	var sign_container := Node3D.new()
	sign_container.name = "NeonSign_%d" % rng.randi()

	# Выбираем случайный цвет
	var color: Color = NEON_COLORS[rng.randi() % NEON_COLORS.size()]

	# Размер вывески - увеличен для видимости издалека
	var sign_width := minf(width * 0.6, 5.0)
	var sign_height := rng.randf_range(1.0, 1.5)

	# Позиция - на фасаде здания
	var sign_y := minf(height * 0.35, 5.0)

	# Создаём светящийся mesh
	var sign_mesh := MeshInstance3D.new()
	sign_mesh.name = "SignMesh"
	var box := BoxMesh.new()
	box.size = Vector3(sign_width, sign_height, 0.15)
	sign_mesh.mesh = box

	# Материал с emission - очень яркий для видимости издалека
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 20.0  # Очень яркий
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sign_mesh.material_override = mat

	# Выбираем случайную сторону для вывески
	var side := rng.randi() % 4
	var sign_offset: Vector3
	var sign_rotation := 0.0

	# Используем depth если передан, иначе берём width (квадратное здание)
	var actual_depth := depth if depth > 0 else width

	match side:
		0:  # Z+ (фасад)
			sign_offset = Vector3(0, sign_y, actual_depth / 2 + 0.15)
			sign_rotation = 0.0
		1:  # Z-
			sign_offset = Vector3(0, sign_y, -actual_depth / 2 - 0.15)
			sign_rotation = PI
		2:  # X+
			sign_offset = Vector3(width / 2 + 0.15, sign_y, 0)
			sign_rotation = PI / 2
		3:  # X-
			sign_offset = Vector3(-width / 2 - 0.15, sign_y, 0)
			sign_rotation = -PI / 2

	sign_mesh.position = sign_offset
	sign_mesh.rotation.y = sign_rotation
	sign_container.add_child(sign_mesh)

	# Источник света - увеличен для видимости издалека
	var light := OmniLight3D.new()
	light.name = "SignLight"
	# Свет чуть впереди вывески
	var light_offset := Vector3(0, 0, 2.0).rotated(Vector3.UP, sign_rotation)
	light.position = sign_offset + light_offset
	light.omni_range = 25.0  # Большой радиус
	light.light_energy = 3.0  # Яркий свет
	light.light_color = color
	light.shadow_enabled = false
	light.light_bake_mode = Light3D.BAKE_DISABLED
	sign_container.add_child(light)

	# Позиция контейнера
	sign_container.position = Vector3(center.x, 0, center.y)
	sign_container.visible = false  # Включается ночью

	parent.add_child(sign_container)


func _add_building_windows(points: PackedVector2Array, height: float, rng: RandomNumberGenerator, parent: Node3D) -> void:
	"""Добавляет светящиеся окна по периметру здания используя MultiMesh"""
	if points.size() < 3:
		return

	# Параметры окон
	var floor_height := 3.0
	var num_floors := int(height / floor_height)
	if num_floors < 1:
		return

	var window_size := 1.2  # Квадратные окна
	var window_spacing := 2.5  # Расстояние между окнами
	var wall_offset := 0.05  # Отступ окна от стены

	# Цвета окон: тёплые-холодные и фитолампы
	var warm_cold_colors := [
		Color(1.0, 0.85, 0.5),   # Тёплый жёлтый
		Color(1.0, 0.9, 0.6),    # Жёлтый
		Color(1.0, 0.95, 0.75),  # Светло-жёлтый
		Color(0.95, 0.92, 0.85), # Тёплый белый
		Color(0.9, 0.92, 0.95),  # Нейтральный белый
		Color(0.85, 0.9, 1.0),   # Холодный белый
		Color(0.75, 0.85, 1.0),  # Холодный голубоватый
	]
	var phyto_color := Color(0.9, 0.2, 0.9)  # Фиолетовый/маджента
	var off_color := Color(0.0, 0.0, 0.0)  # Чёрный для выключенных окон

	# Случайное распределение для этого здания:
	# Выключено: 30-80%, Включено: 17-65%, Фитолампы: 3-5%
	# NOTE: Цвета генерируются независимо от времени суток
	# Shader сам решит показывать их или нет на основе is_night uniform
	var off_percent := 0.30 + rng.randf() * 0.50  # 30% - 80%
	var phyto_percent := 0.03 + rng.randf() * 0.02  # 3% - 5%
	# Включённые = остаток (17% - 65%)

	# Собираем трансформы и цвета окон
	var window_transforms: Array[Transform3D] = []
	var window_colors: Array[Color] = []

	# Определяем направление полигона для корректных нормалей (как в генерации стен)
	# Инвертируем знак чтобы окна смотрели наружу (в ту же сторону что нормали стен)
	var is_ccw := _is_polygon_ccw(points)
	var normal_sign := -1.0 if is_ccw else 1.0

	# Итерируем по рёбрам полигона (стенам здания)
	var num_points := points.size()
	for i in range(num_points):
		var p1 := points[i]
		var p2 := points[(i + 1) % num_points]

		# Направление и длина стены
		var wall_dir := (p2 - p1)
		var wall_length := wall_dir.length()
		if wall_length < window_spacing:
			continue  # Стена слишком короткая для окон

		wall_dir = wall_dir.normalized()

		# Нормаль стены (наружу) - учитываем направление обхода полигона
		var wall_normal := Vector2(-wall_dir.y * normal_sign, wall_dir.x * normal_sign)

		# Угол поворота окна - окно должно быть параллельно стене и смотреть наружу
		# atan2(normal.x, normal.y) даёт угол нормали относительно +Z
		var rot := atan2(wall_normal.x, wall_normal.y)

		# Количество окон на этой стене
		var num_windows := int((wall_length - window_spacing * 0.5) / window_spacing)
		if num_windows < 1:
			num_windows = 1

		# Начальный отступ от края стены
		var start_offset := (wall_length - (num_windows - 1) * window_spacing) / 2.0

		for floor_idx in range(num_floors):
			for win_idx in range(num_windows):
				# Выбор цвета: off_percent выключены, остальные - тёплые-холодные или фитолампы
				var color: Color
				var chance := rng.randf()
				if chance < off_percent:
					# Выключенные окна (остаются тёмными ночью)
					color = off_color
				elif chance < (1.0 - phyto_percent):
					# Тёплые до холодных оттенков (жёлтый -> белый)
					color = warm_cold_colors[rng.randi() % warm_cold_colors.size()]
					# Случайная яркость от 0.15 до 0.5 (храним в альфа-канале)
					color.a = 0.15 + rng.randf() * 0.35
				else:
					# Фитолампы (маджента)
					color = phyto_color
					color.a = 0.25 + rng.randf() * 0.25  # Фитолампы ярче

				# Позиция вдоль стены
				var along_wall := start_offset + win_idx * window_spacing
				var wall_pos := p1 + wall_dir * along_wall

				# Смещение наружу от стены
				var final_pos := wall_pos + wall_normal * wall_offset

				# Высота окна
				var y_pos := floor_height * 0.5 + floor_idx * floor_height

				var pos := Vector3(final_pos.x, y_pos, final_pos.y)
				var transform := Transform3D(Basis.from_euler(Vector3(0, rot, 0)), pos)
				window_transforms.append(transform)
				window_colors.append(color)

	if window_transforms.is_empty():
		return

	# OPTIMIZATION: Window Batching - накапливаем трансформы вместо создания MultiMesh
	# Один MultiMesh per chunk вместо per building (620 buildings → 1 MultiMesh)

	# Определяем chunk_key из parent
	var chunk_key := ""
	if parent.name.begins_with("Chunk_"):
		chunk_key = parent.name.substr(6)
	else:
		chunk_key = "initial"

	# Инициализируем batch data для этого чанка если ещё нет
	if not _window_batch_data.has(chunk_key):
		_window_batch_data[chunk_key] = {
			"transforms": [],
			"colors": [],
			"parent": parent.get_parent()  # ChunkRoot, а не Building
		}

	# Добавляем трансформы и цвета этого здания в чанк
	var batch: Dictionary = _window_batch_data[chunk_key]
	batch.transforms.append_array(window_transforms)
	batch.colors.append_array(window_colors)

	# MultiMesh будет создан один раз после генерации всех зданий в чанке
	# См. _finalize_window_batches_for_chunk()


## ============================================================================
## BUSINESS SIGNS (вывески для заведений)
## ============================================================================

func _add_business_signs_simple(points: PackedVector2Array, tags: Dictionary, parent: Node3D, building_height: float, base_elev: float = 0.0, loader: Node = null) -> void:
	"""
	Добавление вывесок для заведений
	Приоритет: вход (entrance) > POI node > самая длинная стена

	Также ищет POI nodes (точечные заведения) внутри здания и создаёт для них вывески
	"""
	var BusinessSignGen = preload("res://osm/business_sign_generator.gd")

	# Список заведений для создания вывесок
	var businesses_to_process: Array = []

	# 1. Если само здание - заведение с названием
	if (tags.has("amenity") or tags.has("shop")) and (tags.has("name") or tags.has("brand")):
		businesses_to_process.append({"tags": tags, "poi_position": null})

	# 2. Ищем POI nodes внутри здания
	if loader != null:
		var pois_inside = _find_pois_inside_building(points, loader)
		for poi in pois_inside:
			businesses_to_process.append({"tags": poi.tags, "poi_position": poi.position})
	else:
		print("BusinessSign WARNING: loader is null, cannot search for POIs")

	if businesses_to_process.is_empty():
		return

	# Обрабатываем каждое заведение
	for business in businesses_to_process:
		var business_tags: Dictionary = business.tags
		var poi_pos = business.poi_position  # Vector2 или null

		var sign_text = BusinessSignGen.get_sign_text(business_tags)
		if sign_text == "":
			continue

		var sign_width = _calculate_sign_width(sign_text)

		var sign_position_2d: Vector2
		var wall_normal: Vector3
		var placement_method: String

		# Приоритет 1: Ищем вход для этого здания
		var entrance = {}
		if not _entrance_nodes.is_empty() and loader != null:
			entrance = _find_entrance_for_building(points, loader)

		if not entrance.is_empty():
			# Размещаем вывеску над входом
			sign_position_2d = entrance.position
			var wall_dir = (entrance.wall_p2 - entrance.wall_p1).normalized()
			wall_normal = Vector3(wall_dir.y, 0, -wall_dir.x)
			placement_method = "entrance"
		elif poi_pos != null:
			# Приоритет 2: POI node - ищем ближайшую стену к точке
			var closest_wall = _find_closest_wall_to_point(points, poi_pos, sign_width)
			if closest_wall.is_empty():
				continue
			sign_position_2d = closest_wall.closest_point
			wall_normal = closest_wall.normal
			placement_method = "poi_node"
		else:
			# Fallback: самая длинная стена
			var longest_wall = _find_longest_wall_simple(points, sign_width)
			if longest_wall.is_empty():
				continue
			sign_position_2d = (longest_wall.p1 + longest_wall.p2) / 2.0
			wall_normal = longest_wall.normal
			placement_method = "longest_wall"

		# Размещаем вывеску и входную группу
		# Для entrance и poi_node - добавляем входную группу (крыльцо с козырьком)
		var has_entrance_group = placement_method in ["entrance", "poi_node"]

		# Создаём вывеску (ограничиваем ширину для входных групп)
		var max_sign_width = EntranceGroupGenerator.get_canopy_width(2) / 3.0 if has_entrance_group else 4.0
		var sign = BusinessSignGen.create_sign(business_tags, max_sign_width)
		if sign.get_child_count() == 0:
			continue

		var sign_height: float
		if has_entrance_group:
			# Входная группа: вывеска над козырьком
			sign_height = base_elev + EntranceGroupGenerator.get_canopy_top_height() + 0.3
		elif placement_method == "poi_node":
			# Магазин на первом этаже жилого дома - вывеска на 4м
			sign_height = base_elev + min(4.0, building_height * 0.7)
		else:
			sign_height = base_elev + building_height * 0.7

		sign.position = Vector3(sign_position_2d.x, sign_height, sign_position_2d.y)
		sign.position += wall_normal * 1.5  # Отступ от стены (вывеска масштабирована 3x)

		# Поворачиваем вывеску перпендикулярно стене
		sign.rotation.y = atan2(wall_normal.x, wall_normal.z)

		# Добавляем входную группу (крыльцо + двери + козырёк)
		if has_entrance_group:
			var entrance_group = EntranceGroupGenerator.create_entrance_group(2)
			entrance_group.position = Vector3(sign_position_2d.x, base_elev, sign_position_2d.y)
			entrance_group.rotation.y = atan2(wall_normal.x, wall_normal.z)
			entrance_group.name = "EntranceGroup_%s" % sign_text.substr(0, 10)
			parent.add_child(entrance_group)

		parent.add_child(sign)


func _calculate_sign_width(text: String) -> float:
	"""Точно рассчитывает ширину вывески по тексту"""
	var char_count = text.length()
	var avg_char_width = 1.2  # Средняя ширина русского символа для font_size=256 (увеличено с 0.75)
	var text_width = char_count * avg_char_width
	var padding = 2.0  # Отступы (1м с каждой стороны, увеличено с 1.0)
	return text_width + padding


func _find_longest_wall_simple(points: PackedVector2Array, min_width: float) -> Dictionary:
	"""Находит самую длинную стену, достаточную для вывески"""
	if points.size() < 3:
		return {}

	var longest = null
	var max_length = 0.0

	for i in range(points.size()):
		var p1 = points[i]
		var p2 = points[(i + 1) % points.size()]

		var length = p1.distance_to(p2)

		# Проверяем, что стена достаточно длинная для вывески (+ отступы)
		if length < min_width + 1.0:  # 1.0м - запас с обеих сторон
			continue

		if length > max_length:
			max_length = length
			var wall_dir = (p2 - p1).normalized()
			# Нормаль наружу = поворот ВПРАВО (по часовой) от направления стены
			# В 2D: право от (x, y) = (y, -x)
			# В 3D с Y вверх: право от (x, z) = (z, -x)
			var wall_normal = Vector3(wall_dir.y, 0, -wall_dir.x)

			longest = {
				"p1": p1,
				"p2": p2,
				"center": (p1 + p2) / 2.0,
				"length": length,
				"normal": wall_normal
			}

	return longest if longest != null else {}


func _point_to_segment_distance(point: Vector2, seg_start: Vector2, seg_end: Vector2) -> float:
	"""Вычисляет расстояние от точки до отрезка"""
	var seg = seg_end - seg_start
	var seg_length_sq = seg.length_squared()

	if seg_length_sq < 0.0001:
		return point.distance_to(seg_start)

	# Проекция точки на линию отрезка
	var t = clamp((point - seg_start).dot(seg) / seg_length_sq, 0.0, 1.0)
	var projection = seg_start + t * seg

	return point.distance_to(projection)


func _find_entrance_for_building(building_points: PackedVector2Array, _loader: Node) -> Dictionary:
	"""
	Ищет вход, принадлежащий данному зданию.
	Вход считается принадлежащим, если он находится на контуре здания
	или в пределах небольшого расстояния от контура.

	ВАЖНО: Использует _latlon_to_local() (глобальная система координат),
	т.к. building_points уже конвертированы через неё в _create_building()

	Returns: {position: Vector2, wall_p1: Vector2, wall_p2: Vector2, tags: Dictionary} или пустой словарь
	"""
	const MAX_DISTANCE := 2.0  # Максимальное расстояние от контура (2 метра)

	for entrance in _entrance_nodes:
		# Используем _latlon_to_local(), т.к. building_points в той же системе координат
		var entrance_pos: Vector2 = _latlon_to_local(entrance.lat, entrance.lon)

		# Проверяем расстояние до каждой стены здания
		for i in range(building_points.size()):
			var p1 = building_points[i]
			var p2 = building_points[(i + 1) % building_points.size()]

			var distance = _point_to_segment_distance(entrance_pos, p1, p2)

			if distance <= MAX_DISTANCE:
				return {
					"position": entrance_pos,
					"wall_p1": p1,
					"wall_p2": p2,
					"tags": entrance.tags
				}

	return {}


func _find_pois_inside_building(building_points: PackedVector2Array, _loader: Node) -> Array:
	"""
	Ищет POI nodes (точечные заведения) внутри полигона здания.
	Использует алгоритм ray casting для проверки принадлежности точки полигону.

	ВАЖНО: Использует _latlon_to_local() (глобальная система координат),
	т.к. building_points уже конвертированы через неё в _create_building()

	Returns: Array of {position: Vector2, tags: Dictionary}
	"""
	var result: Array = []

	# Вычисляем bbox здания для быстрой фильтрации
	var min_x = INF
	var max_x = -INF
	var min_y = INF
	var max_y = -INF
	for p in building_points:
		min_x = min(min_x, p.x)
		max_x = max(max_x, p.x)
		min_y = min(min_y, p.y)
		max_y = max(max_y, p.y)

	for poi in _poi_nodes:
		# Используем _latlon_to_local(), т.к. building_points в той же системе координат
		var poi_pos: Vector2 = _latlon_to_local(poi.lat, poi.lon)

		# Быстрая проверка bbox
		if poi_pos.x < min_x or poi_pos.x > max_x or poi_pos.y < min_y or poi_pos.y > max_y:
			continue

		# Точная проверка point-in-polygon
		if _point_in_polygon(poi_pos, building_points):
			var name = poi.tags.get("name", "unknown")
			print("POI_DEBUG: Found '%s' inside building at local (%.1f, %.1f)" % [name, poi_pos.x, poi_pos.y])
			result.append({
				"position": poi_pos,
				"tags": poi.tags
			})

	return result


func _point_in_polygon(point: Vector2, polygon: PackedVector2Array) -> bool:
	"""Проверяет, находится ли точка внутри полигона (ray casting algorithm)"""
	var n = polygon.size()
	if n < 3:
		return false

	var inside = false
	var j = n - 1

	for i in range(n):
		var pi = polygon[i]
		var pj = polygon[j]

		if ((pi.y > point.y) != (pj.y > point.y)) and \
		   (point.x < (pj.x - pi.x) * (point.y - pi.y) / (pj.y - pi.y) + pi.x):
			inside = not inside

		j = i

	return inside


func _find_closest_wall_to_point(building_points: PackedVector2Array, target_point: Vector2, min_width: float) -> Dictionary:
	"""
	Находит стену здания, ближайшую к указанной точке.
	Возвращает точку на стене, ближайшую к target_point.
	Нормаль всегда направлена НАРУЖУ от центра здания.

	Returns: {closest_point: Vector2, normal: Vector3, p1: Vector2, p2: Vector2} или пустой словарь
	"""
	var closest_wall = {}
	var min_distance = INF

	# Вычисляем центр здания для проверки направления нормали
	var center = Vector2.ZERO
	for p in building_points:
		center += p
	center /= building_points.size()

	for i in range(building_points.size()):
		var p1 = building_points[i]
		var p2 = building_points[(i + 1) % building_points.size()]

		var wall_length = p1.distance_to(p2)

		# Пропускаем слишком короткие стены
		if wall_length < min_width + 1.0:
			continue

		# Находим ближайшую точку на отрезке
		var seg = p2 - p1
		var seg_length_sq = seg.length_squared()

		var t = 0.0
		if seg_length_sq > 0.0001:
			t = clamp((target_point - p1).dot(seg) / seg_length_sq, 0.0, 1.0)

		var closest_on_wall = p1 + t * seg
		var distance = target_point.distance_to(closest_on_wall)

		if distance < min_distance:
			min_distance = distance
			var wall_dir = seg.normalized()
			# Нормаль перпендикулярна стене
			var normal_2d = Vector2(wall_dir.y, -wall_dir.x)

			# Проверяем направление: нормаль должна быть НАРУЖУ от центра
			var wall_center = (p1 + p2) / 2.0
			var to_center = center - wall_center
			if normal_2d.dot(to_center) > 0:
				# Нормаль направлена к центру - инвертируем
				normal_2d = -normal_2d

			var wall_normal = Vector3(normal_2d.x, 0, normal_2d.y)

			closest_wall = {
				"closest_point": closest_on_wall,
				"normal": wall_normal,
				"p1": p1,
				"p2": p2,
				"distance": distance
			}

	return closest_wall


# ============ ROAD SMOOTHING ============

## Catmull-Rom spline interpolation
func _catmull_rom(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, t: float) -> Vector2:
	var t2: float = t * t
	var t3: float = t2 * t
	return (p1 * 2.0 + (-p0 + p2) * t + (p0 * 2.0 - p1 * 5.0 + p2 * 4.0 - p3) * t2 + (-p0 + p1 * 3.0 - p2 * 3.0 + p3) * t3) * 0.5


## Smooths road geometry using Catmull-Rom spline interpolation
## This creates smooth curves through all points
func _smooth_road_corners(raw_points: PackedVector2Array) -> PackedVector2Array:
	return _smooth_points(raw_points, 3.0, 12, 0.3)  # Полное сглаживание для дорог


## Упрощённое сглаживание для бордюров (меньше точек)
func _smooth_curb_corners(raw_points: PackedVector2Array) -> PackedVector2Array:
	return _smooth_points(raw_points, 8.0, 4, 1.5)  # Меньше точек для бордюров


## Общая функция сглаживания с настраиваемыми параметрами
func _smooth_points(raw_points: PackedVector2Array, meters_per_point: float, max_subdiv: int, min_dist: float) -> PackedVector2Array:
	if raw_points.size() < 3:
		return raw_points

	var result: PackedVector2Array = PackedVector2Array()

	# Always add first point
	result.append(raw_points[0])

	# Interpolate between each pair of points using Catmull-Rom
	for i in range(raw_points.size() - 1):
		# Get 4 control points for Catmull-Rom (p0, p1, p2, p3)
		var p0: Vector2 = raw_points[maxi(0, i - 1)]
		var p1: Vector2 = raw_points[i]
		var p2: Vector2 = raw_points[mini(raw_points.size() - 1, i + 1)]
		var p3: Vector2 = raw_points[mini(raw_points.size() - 1, i + 2)]

		# Calculate segment length to determine subdivision count
		var seg_length: float = p1.distance_to(p2)

		# Check angle at p1 (current point)
		var angle_sharpness: float = 1.0
		if i > 0:
			var d1: Vector2 = (p1 - p0).normalized()
			var d2: Vector2 = (p2 - p1).normalized()
			var dot: float = d1.dot(d2)
			# dot = 1 means straight, dot = -1 means 180° turn
			# Convert to sharpness: 0 = straight, 1 = very sharp
			angle_sharpness = (1.0 - dot) * 0.5

		# More subdivisions for sharp turns and longer segments
		var base_subdivisions: int = maxi(2, int(seg_length / meters_per_point))
		var subdivisions: int = base_subdivisions

		# Add extra subdivisions for sharp corners
		if angle_sharpness > 0.1:  # > ~25 degrees
			subdivisions = maxi(subdivisions, mini(4, max_subdiv))
		if angle_sharpness > 0.25:  # > ~60 degrees
			subdivisions = maxi(subdivisions, mini(6, max_subdiv))
		if angle_sharpness > 0.5:  # > ~90 degrees
			subdivisions = maxi(subdivisions, max_subdiv)

		# Cap at maximum
		subdivisions = mini(subdivisions, max_subdiv)

		# Interpolate from p1 to p2
		for j in range(1, subdivisions):
			var t: float = float(j) / float(subdivisions)
			var interp: Vector2 = _catmull_rom(p0, p1, p2, p3, t)

			# Only add if far enough from last point (avoid duplicates)
			if result[result.size() - 1].distance_to(interp) > min_dist:
				result.append(interp)

		# Add the endpoint of this segment (p2) unless it's the last point
		if i < raw_points.size() - 2:
			if result[result.size() - 1].distance_to(p2) > min_dist:
				result.append(p2)

	# Always add last point
	var last_point: Vector2 = raw_points[raw_points.size() - 1]
	if result[result.size() - 1].distance_to(last_point) > 0.1:
		result.append(last_point)

	return result


## Возвращает приоритет дороги (больше = важнее)
func _get_road_priority(highway_type: String) -> int:
	match highway_type:
		"motorway", "trunk":
			return 5
		"primary":
			return 4
		"secondary":
			return 3
		"tertiary":
			return 2
		"residential", "unclassified", "service":
			return 1
		_:
			return 0


## Переключает отображение границ чанков для отладки
func toggle_chunk_boundaries() -> void:
	_show_chunk_boundaries = not _show_chunk_boundaries

	if _show_chunk_boundaries:
		# Создаём визуализацию границ для всех загруженных чанков
		for chunk_key in _loaded_chunks.keys():
			_create_chunk_boundary_mesh(chunk_key)
	else:
		# Удаляем все визуализации
		for mesh_instance in _chunk_boundary_meshes.values():
			if mesh_instance:
				mesh_instance.queue_free()
		_chunk_boundary_meshes.clear()


## Создаёт mesh для визуализации границы чанка
func _create_chunk_boundary_mesh(chunk_key: String) -> void:
	if _chunk_boundary_meshes.has(chunk_key):
		return  # Уже создан

	var coords := chunk_key.split(",")
	var chunk_x := int(coords[0])
	var chunk_z := int(coords[1])

	var x := chunk_x * chunk_size
	var z := chunk_z * chunk_size

	# Создаём линии по периметру чанка
	var immediate_mesh := ImmediateMesh.new()
	immediate_mesh.surface_begin(Mesh.PRIMITIVE_LINES)

	var height := 50.0  # Высота линий
	var color := Color.YELLOW

	# Нижняя рамка
	immediate_mesh.surface_set_color(color)
	immediate_mesh.surface_add_vertex(Vector3(x, 0, z))
	immediate_mesh.surface_add_vertex(Vector3(x + chunk_size, 0, z))

	immediate_mesh.surface_add_vertex(Vector3(x + chunk_size, 0, z))
	immediate_mesh.surface_add_vertex(Vector3(x + chunk_size, 0, z + chunk_size))

	immediate_mesh.surface_add_vertex(Vector3(x + chunk_size, 0, z + chunk_size))
	immediate_mesh.surface_add_vertex(Vector3(x, 0, z + chunk_size))

	immediate_mesh.surface_add_vertex(Vector3(x, 0, z + chunk_size))
	immediate_mesh.surface_add_vertex(Vector3(x, 0, z))

	# Вертикальные линии по углам
	immediate_mesh.surface_add_vertex(Vector3(x, 0, z))
	immediate_mesh.surface_add_vertex(Vector3(x, height, z))

	immediate_mesh.surface_add_vertex(Vector3(x + chunk_size, 0, z))
	immediate_mesh.surface_add_vertex(Vector3(x + chunk_size, height, z))

	immediate_mesh.surface_add_vertex(Vector3(x + chunk_size, 0, z + chunk_size))
	immediate_mesh.surface_add_vertex(Vector3(x + chunk_size, height, z + chunk_size))

	immediate_mesh.surface_add_vertex(Vector3(x, 0, z + chunk_size))
	immediate_mesh.surface_add_vertex(Vector3(x, height, z + chunk_size))

	# Верхняя рамка
	immediate_mesh.surface_add_vertex(Vector3(x, height, z))
	immediate_mesh.surface_add_vertex(Vector3(x + chunk_size, height, z))

	immediate_mesh.surface_add_vertex(Vector3(x + chunk_size, height, z))
	immediate_mesh.surface_add_vertex(Vector3(x + chunk_size, height, z + chunk_size))

	immediate_mesh.surface_add_vertex(Vector3(x + chunk_size, height, z + chunk_size))
	immediate_mesh.surface_add_vertex(Vector3(x, height, z + chunk_size))

	immediate_mesh.surface_add_vertex(Vector3(x, height, z + chunk_size))
	immediate_mesh.surface_add_vertex(Vector3(x, height, z))

	immediate_mesh.surface_end()

	# Создаём MeshInstance3D
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = immediate_mesh

	# Создаём материал
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	material.no_depth_test = true  # Всегда видим
	mesh_instance.material_override = material

	# Добавляем в сцену
	add_child(mesh_instance)
	_chunk_boundary_meshes[chunk_key] = mesh_instance


## Проверяет, находится ли точка рядом с перекрёстком
## Возвращает индекс перекрёстка или -1
func _find_nearby_intersection(pos: Vector2, radius: float = 15.0) -> int:
	for i in range(_intersection_positions.size()):
		if pos.distance_to(_intersection_positions[i]) < radius:
			return i
	return -1


## Проверяет, является ли перекрёсток равнозначным
func _is_equal_intersection(intersection_idx: int) -> bool:
	if intersection_idx < 0 or intersection_idx >= _intersection_types.size():
		return false
	return _intersection_types[intersection_idx]


## Ищет ближайший перекрёсток в пределах радиуса
func _find_nearest_intersection(pos: Vector2, max_dist: float) -> int:
	var best_idx := -1
	var best_dist := max_dist
	for i in range(_intersection_positions.size()):
		var dist := pos.distance_to(_intersection_positions[i])
		if dist < best_dist:
			best_dist = dist
			best_idx = i
	return best_idx


## Проверяет, находится ли точка внутри эллипса перекрёстка (с масштабом)
## Добавляет перекрёсток в spatial hash
func _add_intersection_to_spatial_hash(pos: Vector2, radii: Vector2, idx: int) -> void:
	# Определяем bounding box перекрёстка с учётом максимального радиуса
	var max_radius := maxf(radii.x, radii.y) * 1.5  # С запасом для scale
	var min_cell_x := int(floor((pos.x - max_radius) / INTERSECTION_CELL_SIZE))
	var max_cell_x := int(floor((pos.x + max_radius) / INTERSECTION_CELL_SIZE))
	var min_cell_y := int(floor((pos.y - max_radius) / INTERSECTION_CELL_SIZE))
	var max_cell_y := int(floor((pos.y + max_radius) / INTERSECTION_CELL_SIZE))

	# Добавляем индекс во все затронутые ячейки
	for cx in range(min_cell_x, max_cell_x + 1):
		for cy in range(min_cell_y, max_cell_y + 1):
			var key := Vector2i(cx, cy)
			if not _intersection_spatial_hash.has(key):
				_intersection_spatial_hash[key] = []
			_intersection_spatial_hash[key].append(idx)


## Получает индексы перекрёстков рядом с точкой через spatial hash
func _get_nearby_intersections(pos: Vector2) -> Array:
	var cell_x := int(floor(pos.x / INTERSECTION_CELL_SIZE))
	var cell_y := int(floor(pos.y / INTERSECTION_CELL_SIZE))
	var key := Vector2i(cell_x, cell_y)
	if _intersection_spatial_hash.has(key):
		return _intersection_spatial_hash[key]
	return []


## Добавляет сегмент дороги в spatial hash для быстрого поиска
func _add_road_segment_to_spatial_hash(seg: Dictionary) -> void:
	var p1: Vector2 = seg.p1
	var p2: Vector2 = seg.p2
	var width: float = seg.width

	# Определяем bounding box сегмента дороги
	var min_x := minf(p1.x, p2.x) - width / 2.0
	var max_x := maxf(p1.x, p2.x) + width / 2.0
	var min_y := minf(p1.y, p2.y) - width / 2.0
	var max_y := maxf(p1.y, p2.y) + width / 2.0

	var min_cell_x := int(floor(min_x / ROAD_CELL_SIZE))
	var max_cell_x := int(floor(max_x / ROAD_CELL_SIZE))
	var min_cell_y := int(floor(min_y / ROAD_CELL_SIZE))
	var max_cell_y := int(floor(max_y / ROAD_CELL_SIZE))

	# Добавляем сегмент во все затронутые ячейки
	for cx in range(min_cell_x, max_cell_x + 1):
		for cy in range(min_cell_y, max_cell_y + 1):
			var key := Vector2i(cx, cy)
			if not _road_spatial_hash.has(key):
				_road_spatial_hash[key] = []
			_road_spatial_hash[key].append(seg)


## Получает сегменты дорог рядом с точкой через spatial hash
func _get_nearby_road_segments(pos: Vector2) -> Array:
	var cell_x := int(floor(pos.x / ROAD_CELL_SIZE))
	var cell_y := int(floor(pos.y / ROAD_CELL_SIZE))
	var key := Vector2i(cell_x, cell_y)
	if _road_spatial_hash.has(key):
		return _road_spatial_hash[key]
	return []


## Проверяет, находится ли точка на дороге
func _is_point_on_road(pos: Vector2, margin: float = 0.5) -> bool:
	# Используем spatial hash для быстрого поиска ближайших сегментов
	var nearby_segments := _get_nearby_road_segments(pos)

	for seg in nearby_segments:
		var p1: Vector2 = seg.p1
		var p2: Vector2 = seg.p2
		var width: float = seg.width

		# Вычисляем расстояние от точки до сегмента дороги
		var line_vec := p2 - p1
		var point_vec := pos - p1
		var line_len := line_vec.length()

		if line_len < 0.01:  # Вырожденный сегмент
			continue

		# Проекция точки на линию сегмента
		var t := point_vec.dot(line_vec) / (line_len * line_len)
		t = clampf(t, 0.0, 1.0)

		# Ближайшая точка на сегменте
		var closest := p1 + line_vec * t
		var dist := pos.distance_to(closest)

		# Проверяем, находится ли точка в пределах ширины дороги + margin
		if dist <= (width / 2.0 + margin):
			return true

	return false


## Пытается сместить позицию объекта с дороги к её краю
## Возвращает новую позицию или Vector2.ZERO если не удалось найти безопасное место
func _move_object_off_road(pos: Vector2, margin: float = 0.5, max_attempts: int = 5) -> Vector2:
	var current_pos := pos

	for attempt in range(max_attempts):
		# Проверяем текущую позицию
		if not _is_point_on_road(current_pos, margin):
			return current_pos  # Нашли безопасное место

		# Ищем ближайший сегмент дороги
		var nearby_segments := _get_nearby_road_segments(current_pos)
		if nearby_segments.is_empty():
			return current_pos  # Нет дорог рядом, позиция безопасна

		# Находим самый близкий сегмент
		var closest_seg: Dictionary = {}
		var min_dist := INF
		var closest_point := Vector2.ZERO

		for seg in nearby_segments:
			var p1: Vector2 = seg.p1
			var p2: Vector2 = seg.p2
			var line_vec := p2 - p1
			var point_vec := current_pos - p1
			var line_len := line_vec.length()

			if line_len < 0.01:
				continue

			var t := point_vec.dot(line_vec) / (line_len * line_len)
			t = clampf(t, 0.0, 1.0)
			var closest := p1 + line_vec * t
			var dist := current_pos.distance_to(closest)

			if dist < min_dist:
				min_dist = dist
				closest_seg = seg
				closest_point = closest

		if closest_seg.is_empty():
			return current_pos  # Не нашли близкий сегмент

		# Направление от ближайшей точки на дороге к текущей позиции
		var away_dir := (current_pos - closest_point).normalized()
		if away_dir.length() < 0.01:
			# Если находимся точно на линии дороги, используем перпендикуляр
			var p1: Vector2 = closest_seg.p1
			var p2: Vector2 = closest_seg.p2
			var road_dir := (p2 - p1).normalized()
			away_dir = Vector2(-road_dir.y, road_dir.x)  # Перпендикуляр

		# Смещаем к краю дороги + margin
		var width: float = closest_seg.width
		var target_dist := width / 2.0 + margin + 0.5  # Дополнительный запас 0.5м
		current_pos = closest_point + away_dir * target_dist

	# Не удалось найти безопасное место за max_attempts попыток
	return Vector2.ZERO


func _is_point_in_intersection_ellipse(pos: Vector2, scale: float = 1.0) -> int:
	# Используем spatial hash для быстрого поиска
	var nearby := _get_nearby_intersections(pos)

	for i in nearby:
		var center: Vector2 = _intersection_positions[i]
		var radii: Vector2 = _intersection_radii[i] * scale
		var angle: float = _intersection_angles[i]

		# Смещение точки относительно центра
		var dx := pos.x - center.x
		var dy := pos.y - center.y

		# Поворот в систему координат эллипса
		var cos_a := cos(-angle)
		var sin_a := sin(-angle)
		var rx := dx * cos_a - dy * sin_a
		var ry := dx * sin_a + dy * cos_a

		# Проверка: (rx/a)^2 + (ry/b)^2 <= 1
		var normalized := (rx * rx) / (radii.x * radii.x) + (ry * ry) / (radii.y * radii.y)
		if normalized <= 1.0:
			return i

	return -1


## Создаёт заплатку на перекрёстке (чистый асфальт без разметки)
## Эллипс с полуосями по ширинам пересекающихся дорог
func _create_intersection_patch(pos: Vector2, elevation: float, parent: Node3D, radius_a: float = 6.0, radius_b: float = 6.0, rotation_angle: float = 0.0) -> void:
	if not _road_textures.has("intersection"):
		return

	# Создаём эллиптический меш (многоугольник с 16 сторонами)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var segments := 16
	var center_y := elevation + 0.08  # Выше дороги

	# Центральная вершина
	st.set_uv(Vector2(0.5, 0.5))
	st.set_normal(Vector3.UP)
	st.add_vertex(Vector3(pos.x, center_y, pos.y))

	# Вершины по эллипсу с поворотом
	var cos_rot := cos(rotation_angle)
	var sin_rot := sin(rotation_angle)
	for i in range(segments):
		var angle := float(i) / segments * TAU
		# Точка на эллипсе (до поворота)
		var ex := cos(angle) * radius_a
		var ey := sin(angle) * radius_b
		# Поворот на угол дороги
		var rx := ex * cos_rot - ey * sin_rot
		var ry := ex * sin_rot + ey * cos_rot
		var x := pos.x + rx
		var z := pos.y + ry
		var u := 0.5 + cos(angle) * 0.5
		var v := 0.5 + sin(angle) * 0.5
		st.set_uv(Vector2(u, v))
		st.set_normal(Vector3.UP)
		st.add_vertex(Vector3(x, center_y, z))

	# Индексы (треугольники от центра к краям)
	for i in range(segments):
		var next_i := (i + 1) % segments
		st.add_index(0)  # Центр
		st.add_index(i + 1)
		st.add_index(next_i + 1)

	var mesh := st.commit()
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = mesh

	# Материал с текстурой перекрёстка
	var material := StandardMaterial3D.new()
	material.albedo_texture = _road_textures["intersection"]
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	# Добавляем карту нормалей как у дорог
	if _normal_textures.has("asphalt"):
		material.normal_enabled = true
		material.normal_texture = _normal_textures["asphalt"]
		material.normal_scale = 0.3  # Уменьшено для меньшего шума
	# Применяем мокрый эффект если дождь
	if _is_wet_mode:
		WetRoadMaterial.apply_wet_properties(material, true, _is_night_mode)
	mesh_instance.material_override = material
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	parent.add_child(mesh_instance)


## Записывает метрику времени
func _record_perf(name: String, time_usec: int) -> void:
	if not _perf_enabled:
		return
	if not _perf_metrics.has(name):
		_perf_metrics[name] = {"total": 0, "count": 0, "max": 0, "samples": []}
	var m: Dictionary = _perf_metrics[name]
	m.total += time_usec
	m.count += 1
	if time_usec > m.max:
		m.max = time_usec
	# Храним последние 100 сэмплов для расчёта медианы
	if m.samples.size() < 100:
		m.samples.append(time_usec)
	else:
		m.samples[m.count % 100] = time_usec


## Выводит метрики в консоль
func _print_perf_metrics() -> void:
	print("\n========== PERFORMANCE METRICS ==========")
	print("Frames: %d" % _perf_frame_count)

	var sorted_keys := _perf_metrics.keys()
	sorted_keys.sort_custom(func(a, b):
		return _perf_metrics[a].total > _perf_metrics[b].total
	)

	for name in sorted_keys:
		var m: Dictionary = _perf_metrics[name]
		if m.count == 0:
			continue
		var avg: float = float(m.total) / float(m.count)
		var samples: Array = m.samples.duplicate()
		samples.sort()
		var median: float = float(samples[samples.size() / 2]) if samples.size() > 0 else 0.0
		print("  %s: avg=%.2f ms, median=%.2f ms, max=%.2f ms, calls=%d, total=%.1f ms" % [
			name,
			avg / 1000.0,
			median / 1000.0,
			float(m.max) / 1000.0,
			m.count,
			float(m.total) / 1000.0
		])

	print("==========================================\n")
	# Сбрасываем метрики
	_perf_metrics.clear()
	_perf_frame_count = 0
