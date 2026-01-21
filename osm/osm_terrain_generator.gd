extends Node3D
class_name OSMTerrainGenerator

signal initial_load_started
signal initial_load_progress(loaded: int, total: int)
signal initial_load_complete

const OSMLoaderScript = preload("res://osm/osm_loader.gd")
const ElevationLoaderScript = preload("res://osm/elevation_loader.gd")
const TextureGeneratorScript = preload("res://textures/texture_generator.gd")
const BuildingWallShader = preload("res://osm/building_wall.gdshader")
const WetRoadMaterial = preload("res://night_mode/wet_road_material.gd")
const EntranceGroupGenerator = preload("res://osm/entrance_group_generator.gd")

# Кэш текстур (создаются один раз)
var _road_textures: Dictionary = {}
var _building_textures: Dictionary = {}
var _ground_textures: Dictionary = {}
var _textures_initialized := false

@export var start_lat := 59.149886
@export var start_lon := 37.949370
@export var chunk_size := 300.0  # Размер чанка в метрах
@export var load_distance := 500.0  # Дистанция подгрузки
@export var unload_distance := 800.0  # Дистанция выгрузки
@export var car_path: NodePath
@export var camera_path: NodePath
@export var enable_elevation := false  # Включить загрузку высот (экспериментально)
@export var elevation_scale := 1.0  # Масштаб высоты (1.0 = реальный)
@export var elevation_grid_resolution := 16  # Разрешение сетки высот на чанк

var osm_loader: Node
var _car: Node3D
var _camera: Camera3D
var _loaded_chunks: Dictionary = {}  # key: "x,z" -> value: Node3D (chunk node)
var _loading_chunks: Dictionary = {}  # Чанки в процессе загрузки
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
var _loading_paused := true  # Загрузка на паузе до команды
var _entrance_nodes: Array = []  # Входы в здания/заведения из OSM
var _poi_nodes: Array = []  # Точечные заведения (shop/amenity как node)
var _parking_polygons: Array[PackedVector2Array] = []  # Полигоны парковок для исключения фонарей
var _road_segments: Array = []  # Сегменты дорог для позиционирования знаков парковки
var _created_lamp_positions: Dictionary = {}  # Позиции созданных фонарей для избежания дубликатов
var _pending_lamps: Array = []  # Отложенные фонари (создаются после загрузки всех парковок)
var _lamps_created := false  # Флаг что фонари уже созданы
var _pending_parking_signs: Array = []  # Отложенные знаки парковки

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
	osm_loader = OSMLoaderScript.new()
	add_child(osm_loader)
	osm_loader.data_loaded.connect(_on_osm_data_loaded)
	osm_loader.load_failed.connect(_on_osm_load_failed)

	# Инициализируем текстуры
	_init_textures()

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

	print("OSM: Ready for loading (waiting for start_loading call)...")

func _init_textures() -> void:
	if _textures_initialized:
		return

	print("OSM: Initializing textures...")
	var start_time := Time.get_ticks_msec()

	# Текстуры дорог
	_road_textures["highway"] = TextureGeneratorScript.create_highway_texture(512, 4)
	_road_textures["primary"] = TextureGeneratorScript.create_highway_texture(512, 4)  # 4 полосы как магистраль
	_road_textures["residential"] = TextureGeneratorScript.create_road_texture(256, 2, true, false)
	_road_textures["path"] = TextureGeneratorScript.create_sidewalk_texture(256)

	# Текстуры зданий
	_building_textures["panel"] = TextureGeneratorScript.create_panel_building_texture(512, 5, 4)
	_building_textures["brick"] = TextureGeneratorScript.create_brick_building_texture(512, 4, 3)
	_building_textures["wall"] = TextureGeneratorScript.create_wall_texture(256)
	_building_textures["roof"] = TextureGeneratorScript.create_roof_texture(256)

	# Текстуры земли
	_ground_textures["grass"] = TextureGeneratorScript.create_grass_texture(256)
	_ground_textures["forest"] = TextureGeneratorScript.create_forest_texture(256)
	_ground_textures["water"] = TextureGeneratorScript.create_water_texture(256)

	_textures_initialized = true
	var elapsed := Time.get_ticks_msec() - start_time
	print("OSM: Textures initialized in %d ms" % elapsed)

func _process(delta: float) -> void:
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
	print("OSM: Starting initial loading...")
	_loading_paused = false
	_initial_loading = true
	_initial_chunks_loaded = 0
	_parking_polygons.clear()  # Очищаем парковки при новой загрузке
	_created_lamp_positions.clear()  # Очищаем позиции фонарей
	_pending_lamps.clear()  # Очищаем отложенные фонари
	_pending_parking_signs.clear()  # Очищаем отложенные знаки парковки
	_lamps_created = false  # Сбрасываем флаг

	# Определяем какие чанки нужны для старта (вокруг точки спавна)
	_initial_chunks_needed = _get_needed_chunks(Vector3.ZERO)
	print("OSM: Need to load %d chunks for initial area" % _initial_chunks_needed.size())

	initial_load_started.emit()

	# Загружаем начальные чанки
	for chunk_key in _initial_chunks_needed:
		if not _loaded_chunks.has(chunk_key) and not _loading_chunks.has(chunk_key):
			var coords: Array = chunk_key.split(",")
			var chunk_x := int(coords[0])
			var chunk_z := int(coords[1])
			_load_chunk(chunk_x, chunk_z)

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
	initial_load_progress.emit(loaded_count, _initial_chunks_needed.size())

	# Все начальные чанки загружены?
	if loaded_count >= _initial_chunks_needed.size():
		_initial_loading = false
		print("OSM: Initial loading complete! %d chunks loaded" % loaded_count)

		# Создаём отложенные фонари (теперь все парковки известны)
		_create_pending_lamps()

		# Создаём отложенные знаки парковки (теперь все дороги известны)
		_create_pending_parking_signs()

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

func _load_chunk(chunk_x: int, chunk_z: int) -> void:
	var chunk_key := "%d,%d" % [chunk_x, chunk_z]
	_loading_chunks[chunk_key] = true

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
	loader.data_loaded.connect(_on_chunk_data_loaded.bind(chunk_key, loader))
	loader.load_failed.connect(_on_chunk_load_failed.bind(chunk_key, loader))
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
		print("OSM: Unloaded chunk %s" % chunk_key)

# Сбрасывает все загруженные чанки (для смены локации)
func reset_terrain() -> void:
	print("OSM: Resetting terrain...")
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
	print("OSM: Terrain reset complete")

func _on_osm_load_failed(error: String) -> void:
	push_error("OSM load failed: " + error)

func _on_chunk_load_failed(error: String, chunk_key: String, loader: Node) -> void:
	push_error("OSM chunk %s load failed: %s" % [chunk_key, error])
	_loading_chunks.erase(chunk_key)
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
	_generate_terrain(osm_data, null)

func _on_chunk_data_loaded(osm_data: Dictionary, chunk_key: String, loader: Node) -> void:
	print("OSM: Chunk %s data loaded" % chunk_key)
	_loading_chunks.erase(chunk_key)

	# Создаём контейнер для чанка
	var chunk_node := Node3D.new()
	chunk_node.name = "Chunk_" + chunk_key
	add_child(chunk_node)
	_loaded_chunks[chunk_key] = chunk_node

	# Если высоты уже загружены, создаём террейн
	if _chunk_elevations.has(chunk_key):
		_create_terrain_mesh(chunk_key, chunk_node)

	_generate_terrain(osm_data, chunk_node, chunk_key)
	loader.queue_free()

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

		if tags.has("highway"):
			_create_road(nodes, tags, target, loader, elev_data)
			road_count += 1
		elif tags.has("building"):
			_create_building(nodes, tags, target, loader, elev_data)
			building_count += 1
		elif tags.has("amenity") and not tags.has("building"):
			# Amenity без building тега - создаём как здание
			_create_amenity_building(nodes, tags, target, loader, elev_data)
			building_count += 1
		elif tags.has("natural"):
			_create_natural(nodes, tags, target, loader, elev_data)
		elif tags.has("landuse"):
			_create_landuse(nodes, tags, target, loader, elev_data)
		elif tags.has("leisure"):
			_create_leisure(nodes, tags, target, loader, elev_data)
		elif tags.has("waterway"):
			_create_waterway(nodes, tags, target, loader, elev_data)

	if skipped_buildings > 0:
		print("OSM: Skipped %d buildings (outside chunk bounds)" % skipped_buildings)

	# Ищем перекрёстки (узлы, которые используются несколькими дорогами)
	# Оптимизация: проверяем только концы дорог (первый и последний узел)
	var node_road_count: Dictionary = {}  # node_key -> count
	var node_positions: Dictionary = {}  # node_key -> Vector2
	var node_road_types: Dictionary = {}  # node_key -> Array of highway types

	for way in ways:
		var way_tags: Dictionary = way.get("tags", {})
		var way_nodes: Array = way.get("nodes", [])

		if not way_tags.has("highway"):
			continue

		var highway_type: String = way_tags.get("highway", "")
		# Только primary дороги для перекрёстков
		if highway_type not in ["primary", "secondary"]:
			continue

		if way_nodes.size() < 2:
			continue

		# Проверяем только первый и последний узел дороги (концы)
		var endpoints := [way_nodes[0], way_nodes[way_nodes.size() - 1]]
		for node in endpoints:
			var node_key := "%.5f,%.5f" % [node.lat, node.lon]  # Уменьшил точность для группировки близких точек
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

	# Создаём светофоры и знаки на перекрёстках
	var intersection_count := 0
	for node_key in node_road_count:
		if node_road_count[node_key] >= 2:  # Перекрёсток - 2+ дороги сходятся концами
			var pos: Vector2 = node_positions[node_key]
			var road_types: Array = node_road_types[node_key]
			var elevation := _get_elevation_at_point(pos, elev_data)

			# На крупных перекрёстках - светофор, на мелких - знаки
			var has_primary := "primary" in road_types or "secondary" in road_types
			if has_primary and node_road_count[node_key] >= 3:
				_create_traffic_light(pos, elevation, target)
			else:
				# На обычных перекрёстках - один знак, не 4
				_create_yield_sign(pos + Vector2(5, 5), elevation, target)

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

func _create_road(nodes: Array, tags: Dictionary, parent: Node3D, loader: Node, elev_data: Dictionary = {}) -> void:
	var highway_type: String = tags.get("highway", "residential")
	var width: float = ROAD_WIDTHS.get(highway_type, 5.0)

	var texture_key: String
	var height_offset: float  # Высота дороги
	var curb_height: float    # Высота бордюра над дорогой
	match highway_type:
		"motorway", "trunk":
			texture_key = "highway"
			height_offset = 0.02
			curb_height = 0.12  # Высокие бордюры для магистралей
		"primary":
			texture_key = "primary"
			height_offset = 0.02
			curb_height = 0.10  # 10 см бордюр
		"secondary", "tertiary":
			texture_key = "primary"
			height_offset = 0.02
			curb_height = 0.08
		"residential", "unclassified":
			texture_key = "residential"
			height_offset = 0.02
			curb_height = 0.06
		"service":
			texture_key = "residential"
			height_offset = 0.02
			curb_height = 0.04
		"footway", "path", "cycleway", "track":
			texture_key = "path"
			height_offset = 0.08  # Пешеходные на уровне тротуара
			curb_height = 0.0    # Без бордюра
		_:
			texture_key = "residential"
			height_offset = 0.02
			curb_height = 0.05

	_create_road_mesh_with_texture(nodes, width, texture_key, height_offset, parent, elev_data)

	# Сохраняем сегменты дорог для позиционирования знаков парковки
	for i in range(nodes.size() - 1):
		var p1 = _latlon_to_local(nodes[i].lat, nodes[i].lon)
		var p2 = _latlon_to_local(nodes[i + 1].lat, nodes[i + 1].lon)
		_road_segments.append({"p1": p1, "p2": p2, "width": width})

	# Создаём бордюры если нужно
	if curb_height > 0.0:
		_create_curbs(nodes, width, height_offset, curb_height, parent, elev_data)

	# Процедурная генерация фонарей вдоль дорог (позиции сохраняются для отложенного создания)
	if highway_type in ["motorway", "trunk", "primary", "secondary", "tertiary"]:
		_generate_street_lamps_along_road(nodes, width, elev_data, parent)

	# Извлекаем данные для RoadNetwork (для навигации NPC)
	_extract_road_for_traffic(nodes, tags, elev_data)

func _create_road_mesh_with_texture(nodes: Array, width: float, texture_key: String, height_offset: float, parent: Node3D, elev_data: Dictionary = {}) -> void:
	if nodes.size() < 2:
		return

	var points: PackedVector2Array = []
	for node in nodes:
		var local: Vector2 = _latlon_to_local(node.lat, node.lon)
		points.append(local)

	# Добавляем небольшое случайное смещение по высоте для предотвращения z-fighting
	# на пересечениях (используем хэш от первой точки дороги)
	var hash_val := int(abs(points[0].x * 1000 + points[0].y * 7919)) % 100
	var z_offset := hash_val * 0.0003  # 0-3 см случайное смещение

	# Используем ArrayMesh для UV координат
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)

	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()

	var accumulated_length := 0.0
	var uv_scale := 0.1  # Масштаб UV вдоль дороги (чтобы разметка повторялась)

	for i in range(points.size() - 1):
		var p1 := points[i]
		var p2 := points[i + 1]

		var segment_length := p1.distance_to(p2)
		var dir := (p2 - p1).normalized()
		var perp := Vector2(-dir.y, dir.x) * width * 0.5

		# Получаем высоты для каждой точки с z_offset
		var h1 := _get_elevation_at_point(p1, elev_data) + height_offset + z_offset
		var h2 := _get_elevation_at_point(p2, elev_data) + height_offset + z_offset

		var v1 := Vector3(p1.x - perp.x, h1, p1.y - perp.y)
		var v2 := Vector3(p1.x + perp.x, h1, p1.y + perp.y)
		var v3 := Vector3(p2.x + perp.x, h2, p2.y + perp.y)
		var v4 := Vector3(p2.x - perp.x, h2, p2.y - perp.y)

		# UV координаты: x = поперёк дороги (0-1), y = вдоль дороги (повторяется)
		var uv_y1 := accumulated_length * uv_scale
		var uv_y2 := (accumulated_length + segment_length) * uv_scale

		var idx := vertices.size()
		vertices.append(v1)
		vertices.append(v2)
		vertices.append(v3)
		vertices.append(v4)

		uvs.append(Vector2(0.0, uv_y1))  # v1 - левый край, начало
		uvs.append(Vector2(1.0, uv_y1))  # v2 - правый край, начало
		uvs.append(Vector2(1.0, uv_y2))  # v3 - правый край, конец
		uvs.append(Vector2(0.0, uv_y2))  # v4 - левый край, конец

		normals.append(Vector3.UP)
		normals.append(Vector3.UP)
		normals.append(Vector3.UP)
		normals.append(Vector3.UP)

		# Два треугольника
		indices.append(idx + 0)
		indices.append(idx + 2)
		indices.append(idx + 1)

		indices.append(idx + 0)
		indices.append(idx + 3)
		indices.append(idx + 2)

		accumulated_length += segment_length

	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices

	var arr_mesh := ArrayMesh.new()
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mesh := MeshInstance3D.new()
	mesh.mesh = arr_mesh

	# Материал с текстурой
	var material := StandardMaterial3D.new()
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	if _road_textures.has(texture_key):
		material.albedo_texture = _road_textures[texture_key]
		material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	else:
		# Fallback цвет
		material.albedo_color = COLORS.get("road_residential", Color(0.4, 0.4, 0.4))

	# Применяем мокрый асфальт если дождь уже идёт
	if _is_wet_mode:
		WetRoadMaterial.apply_wet_properties(material, true)

	mesh.material_override = material

	parent.add_child(mesh)

# Создаёт бордюры вдоль дороги
func _create_curbs(nodes: Array, road_width: float, road_height: float, curb_height: float, parent: Node3D, elev_data: Dictionary = {}) -> void:
	if nodes.size() < 2:
		return

	var points: PackedVector2Array = []
	for node in nodes:
		var local: Vector2 = _latlon_to_local(node.lat, node.lon)
		points.append(local)

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

	# Пропускаем первый и последний сегменты (перекрёстки)
	var start_idx := 1 if points.size() > 3 else 0
	var end_idx := points.size() - 2 if points.size() > 3 else points.size() - 1

	for i in range(start_idx, end_idx):
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
			normals.append(Vector3(-perp.x, 0, -perp.y))  # Внутрь к дороге

		indices.append(idx + 0)
		indices.append(idx + 1)
		indices.append(idx + 2)
		indices.append(idx + 0)
		indices.append(idx + 2)
		indices.append(idx + 3)

		idx = vertices.size()

		# Верхняя грань
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

		idx = vertices.size()

		# === Правый бордюр ===
		# Внутренняя стенка (со стороны дороги)
		vertices.append(Vector3(right_inner1.x, road_y1, right_inner1.y))
		vertices.append(Vector3(right_inner2.x, road_y2, right_inner2.y))
		vertices.append(Vector3(right_inner2.x, curb_y2, right_inner2.y))
		vertices.append(Vector3(right_inner1.x, curb_y1, right_inner1.y))
		for _j in range(4):
			normals.append(Vector3(perp.x, 0, perp.y))  # Внутрь к дороге

		indices.append(idx + 0)
		indices.append(idx + 2)
		indices.append(idx + 1)
		indices.append(idx + 0)
		indices.append(idx + 3)
		indices.append(idx + 2)

		idx = vertices.size()

		# Верхняя грань
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

	# Создаём StaticBody3D с коллизией для бордюров
	var body := StaticBody3D.new()
	body.collision_layer = 1  # Слой 1 - земля/дороги
	body.collision_mask = 0   # Не реагируем ни на что
	body.add_child(mesh)

	# Создаём коллизии для каждого сегмента бордюра (тоже пропускаем перекрёстки)
	for i in range(start_idx, end_idx):
		var p1 := points[i]
		var p2 := points[i + 1]

		var dir := (p2 - p1).normalized()
		var perp := Vector2(-dir.y, dir.x)
		var segment_length := p1.distance_to(p2)

		if segment_length < 0.5:
			continue

		var h1 := _get_elevation_at_point(p1, elev_data)
		var h2 := _get_elevation_at_point(p2, elev_data)
		var avg_h := (h1 + h2) / 2.0 + road_height + curb_height * 0.5 + z_offset

		var wall_angle := atan2(p2.y - p1.y, p2.x - p1.x)

		# Левый бордюр
		var left_center := (p1 + p2) / 2 + perp * (road_width * 0.5 + curb_width * 0.5)
		var left_collision := CollisionShape3D.new()
		var left_box := BoxShape3D.new()
		left_box.size = Vector3(segment_length, curb_height, curb_width)
		left_collision.shape = left_box
		left_collision.position = Vector3(left_center.x, avg_h, left_center.y)
		left_collision.rotation.y = -wall_angle
		body.add_child(left_collision)

		# Правый бордюр
		var right_center := (p1 + p2) / 2 - perp * (road_width * 0.5 + curb_width * 0.5)
		var right_collision := CollisionShape3D.new()
		var right_box := BoxShape3D.new()
		right_box.size = Vector3(segment_length, curb_height, curb_width)
		right_collision.shape = right_box
		right_collision.position = Vector3(right_center.x, avg_h, right_center.y)
		right_collision.rotation.y = -wall_angle
		body.add_child(right_collision)

	parent.add_child(body)

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

	_create_3d_building_with_texture(points, building_height, texture_type, parent, base_elev, debug_name)

	# Добавляем вывески для заведений (amenity/shop с названием)
	_add_business_signs_simple(points, tags, parent, building_height, base_elev, loader)


func _create_parking(points: PackedVector2Array, elev_data: Dictionary, parent: Node3D) -> void:
	"""Создаёт парковку: асфальтовую поверхность + знак P (знак отложен)"""
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

	if _is_wet_mode:
		WetRoadMaterial.apply_wet_properties(material, true)

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


func _create_parking_sign(pos: Vector2, elevation: float, rotation_y: float, parent: Node3D) -> void:
	"""Создаёт дорожный знак парковки (P)"""
	var sign_node := Node3D.new()
	sign_node.name = "ParkingSign"
	sign_node.position = Vector3(pos.x, elevation, pos.y)
	sign_node.rotation.y = rotation_y

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
	sign_node.add_child(pole)

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
	sign_node.add_child(sign_plate)

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
	sign_node.add_child(label)

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
	sign_node.add_child(label_back)

	# Коллизия для столба
	var body := StaticBody3D.new()
	body.collision_layer = 2
	body.collision_mask = 1
	var collision := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.05
	shape.height = 2.5
	collision.shape = shape
	collision.position.y = 1.25
	body.add_child(collision)
	sign_node.add_child(body)

	parent.add_child(sign_node)


func _create_natural(nodes: Array, tags: Dictionary, parent: Node3D, loader: Node, elev_data: Dictionary = {}) -> void:
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

	_create_polygon_mesh_with_texture(points, texture_key, 0.04, parent, elev_data, is_water)

	# Процедурная генерация деревьев в лесах
	if natural_type in ["wood"]:
		_generate_trees_in_polygon(points, elev_data, parent, true)  # dense=true для леса

func _create_landuse(nodes: Array, tags: Dictionary, parent: Node3D, loader: Node, elev_data: Dictionary = {}) -> void:
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

	_create_polygon_mesh_with_texture(points, texture_key, 0.02, parent, elev_data, is_water)

	# Процедурная генерация деревьев в лесах
	if landuse_type == "forest":
		_generate_trees_in_polygon(points, elev_data, parent, true)  # dense=true для леса

func _create_leisure(nodes: Array, tags: Dictionary, parent: Node3D, loader: Node, elev_data: Dictionary = {}) -> void:
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

	_create_polygon_mesh_with_texture(points, texture_key, 0.04, parent, elev_data, is_water)

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
	body.collision_mask = 1
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
	body.collision_mask = 1   # Реагирует на слой 1 (машина)
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

	var accumulated_width := 0.0
	for i in range(points.size()):
		var p1 := points[i]
		var p2 := points[(i + 1) % points.size()]

		var wall_width := p1.distance_to(p2)

		var v1 := Vector3(p1.x, floor_y, p1.y)
		var v2 := Vector3(p2.x, floor_y, p2.y)
		var v3 := Vector3(p2.x, roof_y, p2.y)
		var v4 := Vector3(p1.x, roof_y, p1.y)

		# Нормаль стены (наружу)
		var dir := (p2 - p1).normalized()
		var normal := Vector3(-dir.y, 0, dir.x)

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
		roof_material.cull_mode = BaseMaterial3D.CULL_DISABLED
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
	body.collision_mask = 1   # Реагирует на слой 1 (машина)
	body.add_child(wall_mesh_instance)

	# Создаём коллизию для каждой стены отдельно
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

	# Добавляем ночные декорации (неоновые вывески и окна)
	_add_building_night_decorations(wall_mesh_instance, points, building_height, parent)

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

# Конвертация lat/lon в локальные координаты относительно стартовой точки
# Примечание: Z инвертирован, т.к. в Godot +Z направлен "от экрана", а latitude растёт на север
func _latlon_to_local(lat: float, lon: float) -> Vector2:
	var dx := (lon - start_lon) * 111000.0 * cos(deg_to_rad(start_lat))
	var dz := (lat - start_lat) * 111000.0
	return Vector2(dx, -dz)  # Инвертируем Z для корректной ориентации карты

# Расчёт площади полигона (формула Шолейса)
func _calculate_polygon_area(points: PackedVector2Array) -> float:
	var area := 0.0
	var n := points.size()
	for i in range(n):
		var j := (i + 1) % n
		area += points[i].x * points[j].y
		area -= points[j].x * points[i].y
	return abs(area) / 2.0

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


# Создание дерева из простых примитивов
func _create_tree(pos: Vector2, elevation: float, parent: Node3D) -> void:
	var tree := Node3D.new()
	tree.position = Vector3(pos.x, elevation, pos.y)

	# Ствол - коричневый цилиндр
	var trunk := MeshInstance3D.new()
	var trunk_mesh := CylinderMesh.new()
	trunk_mesh.top_radius = 0.15
	trunk_mesh.bottom_radius = 0.2
	trunk_mesh.height = 3.0
	trunk.mesh = trunk_mesh

	var trunk_mat := StandardMaterial3D.new()
	trunk_mat.albedo_color = Color(0.4, 0.25, 0.15)  # Коричневый
	trunk.material_override = trunk_mat
	trunk.position.y = 1.5  # Половина высоты ствола
	trunk.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	tree.add_child(trunk)

	# Крона - зелёная сфера
	var crown := MeshInstance3D.new()
	var crown_mesh := SphereMesh.new()
	crown_mesh.radius = 2.0
	crown_mesh.height = 3.5
	crown.mesh = crown_mesh

	var crown_mat := StandardMaterial3D.new()
	crown_mat.albedo_color = Color(0.2, 0.5, 0.2)  # Зелёный
	crown.material_override = crown_mat
	crown.position.y = 4.5  # Над стволом
	crown.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	tree.add_child(crown)

	# Коллизия для ствола
	var body := StaticBody3D.new()
	body.collision_layer = 2
	body.collision_mask = 1
	var collision := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.2
	shape.height = 3.0
	collision.shape = shape
	collision.position.y = 1.5
	body.add_child(collision)
	tree.add_child(body)

	parent.add_child(tree)


# Создание дорожного знака
func _create_traffic_sign(pos: Vector2, elevation: float, tags: Dictionary, parent: Node3D) -> void:
	var sign_node := Node3D.new()
	sign_node.position = Vector3(pos.x, elevation, pos.y)

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
	sign_node.add_child(pole)

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
	sign_node.add_child(sign_plate)

	# Коллизия для столба
	var body := StaticBody3D.new()
	body.collision_layer = 2
	body.collision_mask = 1
	var collision := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.05
	shape.height = 2.5
	collision.shape = shape
	collision.position.y = 1.25
	body.add_child(collision)
	sign_node.add_child(body)

	parent.add_child(sign_node)


# Создание уличного фонаря с кронштейном в сторону дороги
func _create_street_lamp(pos: Vector2, elevation: float, parent: Node3D, direction_to_road: Vector2 = Vector2.ZERO) -> void:
	# Проверяем, не создан ли уже фонарь в этой позиции (округляем до метров)
	var pos_key := "%d_%d" % [int(pos.x), int(pos.y)]
	if _created_lamp_positions.has(pos_key):
		return  # Фонарь уже есть
	_created_lamp_positions[pos_key] = true

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

	var globe_mat := StandardMaterial3D.new()
	globe_mat.albedo_color = Color(1.0, 0.75, 0.3)  # Натриевый оранжевый
	globe_mat.emission_enabled = true
	globe_mat.emission = Color(1.0, 0.65, 0.2)  # Тёплый натриевый
	globe_mat.emission_energy_multiplier = 0.8
	light_globe.material_override = globe_mat
	light_globe.name = "LampGlobe"

	# Позиция плафона на конце кронштейна
	light_globe.position.x = arm_end_x
	light_globe.position.y = arm_end_y
	lamp.add_child(light_globe)

	# Добавляем источник света - OmniLight для освещения вокруг
	# 5% шанс что фонарь сломан
	var is_broken := randf() < 0.05

	var lamp_light := OmniLight3D.new()
	lamp_light.name = "LampLight"
	lamp_light.position = light_globe.position
	lamp_light.omni_range = 12.0  # Радиус освещения
	lamp_light.omni_attenuation = 1.2
	lamp_light.light_energy = 1.5
	lamp_light.light_color = Color(1.0, 0.65, 0.2)  # Тёплый натриевый жёлто-оранжевый
	lamp_light.shadow_enabled = false
	lamp_light.light_bake_mode = Light3D.BAKE_DISABLED
	lamp_light.visible = not is_broken  # Сломанные фонари не горят
	lamp.add_child(lamp_light)

	# Если фонарь сломан, выключаем эмиссию плафона
	if is_broken:
		globe_mat.emission_enabled = false
		globe_mat.albedo_color = Color(0.3, 0.3, 0.3)  # Тусклый серый

	# Коллизия для столба
	var body := StaticBody3D.new()
	body.collision_layer = 2
	body.collision_mask = 1
	var collision := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.1
	shape.height = 5.5
	collision.shape = shape
	collision.position.y = 2.75
	body.add_child(collision)
	lamp.add_child(body)

	parent.add_child(lamp)


# Процедурная генерация деревьев в полигоне (парк, лес)
func _generate_trees_in_polygon(points: PackedVector2Array, elev_data: Dictionary, parent: Node3D, dense: bool = false) -> void:
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

	# Ограничиваем максимальное количество деревьев на полигон
	var max_trees := 50 if dense else 30
	var tree_count := 0

	# Используем хаотичное размещение на основе хеша координат полигона
	# Генерируем псевдослучайные точки внутри bounding box
	var seed_value := int(abs(min_x * 1000 + min_y * 100 + width * 10 + height)) % 10000
	var avg_spacing := 12.0 if dense else 20.0  # Среднее расстояние между деревьями
	var estimated_trees := int((width * height) / (avg_spacing * avg_spacing))
	estimated_trees = mini(estimated_trees, max_trees)

	for i in range(estimated_trees):
		# Генерируем псевдослучайные координаты используя разные множители
		var hash1 := fmod(float(seed_value + i * 7919) * 0.61803398875, 1.0)  # Золотое сечение
		var hash2 := fmod(float(seed_value + i * 104729) * 0.41421356237, 1.0)  # sqrt(2) - 1

		# Добавляем вторичное смещение для большей хаотичности
		var hash3 := fmod(hash1 * 17.0 + hash2 * 31.0, 1.0)
		var hash4 := fmod(hash2 * 23.0 + hash1 * 13.0, 1.0)

		var test_x := min_x + (hash1 * 0.7 + hash3 * 0.3) * width
		var test_y := min_y + (hash2 * 0.7 + hash4 * 0.3) * height
		var test_point := Vector2(test_x, test_y)

		# Проверяем что точка внутри полигона
		if Geometry2D.is_point_in_polygon(test_point, points):
			var elevation := _get_elevation_at_point(test_point, elev_data)
			_create_tree(test_point, elevation, parent)
			tree_count += 1

			if tree_count >= max_trees:
				break


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
	if _lamps_created:
		return
	_lamps_created = true

	var created := 0
	var skipped := 0

	for lamp_data in _pending_lamps:
		var pos: Vector2 = lamp_data.pos
		var elev: float = lamp_data.elev
		var parent: Node3D = lamp_data.parent
		var dir: Vector2 = lamp_data.dir

		# Теперь проверяем с полным списком парковок
		if _is_point_in_any_parking(pos):
			skipped += 1
			continue

		_create_street_lamp(pos, elev, parent, dir)
		created += 1

	print("OSM: Created %d lamps, skipped %d (on parking)" % [created, skipped])
	_pending_lamps.clear()


func _create_pending_parking_signs() -> void:
	"""Создаёт отложенные знаки парковки (теперь все дороги известны)"""
	print("OSM: Creating parking signs, have %d road segments" % _road_segments.size())

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
	body.collision_mask = 1
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


# Создание знака "Уступи дорогу"
func _create_yield_sign(pos: Vector2, elevation: float, parent: Node3D) -> void:
	var sign_node := Node3D.new()
	sign_node.position = Vector3(pos.x, elevation, pos.y)

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
	sign_node.add_child(pole)

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
	sign_node.add_child(sign_plate)

	# Коллизия
	var body := StaticBody3D.new()
	body.collision_layer = 2
	body.collision_mask = 1
	var collision := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.05
	shape.height = 2.2
	collision.shape = shape
	collision.position.y = 1.1
	body.add_child(collision)
	sign_node.add_child(body)

	parent.add_child(sign_node)

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
var _building_night_lights: Array[Node3D] = []  # Храним ссылки на созданные источники света

func set_wet_mode(enabled: bool) -> void:
	"""Включает/выключает мокрый асфальт для дорог"""
	if _is_wet_mode == enabled:
		return

	_is_wet_mode = enabled
	print("OSM: Wet mode ", "enabled" if enabled else "disabled")

	# Обновляем материалы всех загруженных дорог
	for chunk_key in _loaded_chunks.keys():
		var chunk: Node3D = _loaded_chunks[chunk_key]
		_update_chunk_road_wetness(chunk, enabled)


func _update_chunk_road_wetness(chunk: Node3D, is_wet: bool) -> void:
	"""Обновляет материалы дорог в чанке для мокрого/сухого состояния"""
	for child in chunk.get_children():
		# Дороги добавляются как MeshInstance3D прямо в чанк
		if child is MeshInstance3D:
			var mat := child.material_override as StandardMaterial3D
			if mat and _is_road_material(mat):
				_apply_wet_material(mat, is_wet)
		# Также проверяем внутри StaticBody3D (бордюры и коллизии)
		elif child is StaticBody3D:
			for mesh_child in child.get_children():
				if mesh_child is MeshInstance3D:
					var mat := mesh_child.material_override as StandardMaterial3D
					if mat and _is_road_material(mat):
						_apply_wet_material(mat, is_wet)


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


func _apply_wet_material(mat: StandardMaterial3D, is_wet: bool) -> void:
	"""Применяет свойства мокрого/сухого асфальта к материалу"""
	WetRoadMaterial.apply_wet_properties(mat, is_wet)


func _connect_to_night_mode() -> void:
	"""Подключается к NightModeManager для получения сигналов"""
	if _night_mode_connected:
		return

	var night_manager := get_tree().current_scene.find_child("NightModeManager", true, false)
	if night_manager:
		night_manager.night_mode_changed.connect(_on_night_mode_changed)
		_night_mode_connected = true
		# Если уже ночь - включаем фонари
		if night_manager.is_night:
			_on_night_mode_changed(true)


var _is_night_mode := false

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
		node.visible = night_enabled
		# Усиливаем emission на плафоне
		var lamp_parent := node.get_parent()
		if lamp_parent:
			var globe := lamp_parent.find_child("LampGlobe", false)
			if globe and globe.material_override:
				var mat := globe.material_override as StandardMaterial3D
				if mat:
					mat.emission_energy_multiplier = 5.0 if night_enabled else 0.5

	# Проверяем неоновые вывески и окна
	if node.name.begins_with("NeonSign") or node.name.begins_with("WindowLights"):
		node.visible = night_enabled

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
var _window_lights_created := 0

func _add_building_night_decorations(building_mesh: MeshInstance3D, points: PackedVector2Array, building_height: float, parent: Node3D) -> void:
	"""Добавляет неоновые вывески и освещённые окна к зданию"""
	# Случайный seed на основе позиции здания
	var center := _get_polygon_center(points)
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
		if _neon_signs_created % 10 == 0:
			print("OSM: Created %d neon signs" % _neon_signs_created)

	# Светящиеся окна для высоких зданий (проверка внутри функции)
	if building_height > 6.0:
		var prev_count := _window_lights_created
		_add_window_lights(center, building_height, building_width, building_depth, rng, parent)
		if _window_lights_created > prev_count and _window_lights_created % 5 == 0:
			print("OSM: Created %d window lights" % _window_lights_created)


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


func _add_window_lights(center: Vector2, height: float, width: float, depth: float, rng: RandomNumberGenerator, parent: Node3D) -> void:
	"""Добавляет светящиеся окна: 5% жёлтые, 0.5% фиолетовые - видимые издалека"""
	# 5% жёлтые + 0.5% фиолетовые = 5.5% зданий
	var chance := rng.randf()
	var is_purple := chance < 0.005  # 0.5% фиолетовые
	var is_yellow := chance >= 0.005 and chance < 0.055  # 5% жёлтые

	if not is_purple and not is_yellow:
		return

	_window_lights_created += 1

	var container := Node3D.new()
	container.name = "WindowLights_%d" % rng.randi()
	container.position = Vector3(center.x, 0, center.y)

	# Параметры - увеличенные для видимости издалека
	var floor_height := 3.0
	var num_floors := mini(int(height / floor_height), 3)
	if num_floors < 1:
		num_floors = 1

	# Цвет окна - более яркий для видимости
	var color: Color
	var emission_energy: float
	if is_purple:
		color = Color(0.8, 0.3, 1.0)  # Яркий фиолетовый
		emission_energy = 15.0  # Очень яркий для видимости издалека
	else:
		color = Color(1.0, 0.95, 0.7)  # Яркий тёплый жёлтый
		emission_energy = 10.0  # Яркий для видимости издалека

	# Выбираем одну случайную сторону
	var all_sides := [
		{"offset": Vector3(0, 0, depth / 2 + 0.08), "rot": 0.0, "length": width},
		{"offset": Vector3(0, 0, -depth / 2 - 0.08), "rot": PI, "length": width},
		{"offset": Vector3(width / 2 + 0.08, 0, 0), "rot": PI / 2, "length": depth},
		{"offset": Vector3(-width / 2 - 0.08, 0, 0), "rot": -PI / 2, "length": depth},
	]
	var side: Dictionary = all_sides[rng.randi() % 4]
	var side_length: float = side["length"]

	# Создаём 1-3 окна на случайных этажах
	var num_windows := rng.randi_range(1, mini(3, num_floors))

	for _i in range(num_windows):
		var floor_idx := rng.randi() % num_floors
		var along := rng.randf_range(-side_length / 2 + 1.0, side_length / 2 - 1.0)
		var wy := floor_height * 0.6 + floor_idx * floor_height

		var window_mesh := MeshInstance3D.new()
		var box := BoxMesh.new()
		# Увеличенный размер для видимости издалека
		box.size = Vector3(1.5, 2.0, 0.08)
		window_mesh.mesh = box

		var mat := StandardMaterial3D.new()
		mat.albedo_color = color
		mat.emission_enabled = true
		mat.emission = color
		mat.emission_energy_multiplier = emission_energy
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED  # Всегда яркий, без затенения
		window_mesh.material_override = mat

		var base_offset: Vector3 = side["offset"]
		var rotation_y: float = side["rot"]
		window_mesh.position = base_offset + Vector3(along, wy, 0).rotated(Vector3.UP, rotation_y)
		window_mesh.position.y = wy
		window_mesh.rotation.y = rotation_y

		container.add_child(window_mesh)

	# Добавляем OmniLight для видимости издалека (один на все окна здания)
	var window_light := OmniLight3D.new()
	window_light.name = "WindowOmniLight"
	window_light.position = Vector3(0, height * 0.5, 0)  # В центре здания по высоте
	window_light.omni_range = 25.0 if is_purple else 20.0  # Большой радиус для видимости
	window_light.light_energy = 2.5 if is_purple else 1.5
	window_light.light_color = color
	window_light.shadow_enabled = false
	window_light.light_bake_mode = Light3D.BAKE_DISABLED
	container.add_child(window_light)

	container.visible = false  # Включается ночью
	parent.add_child(container)


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

		print("BusinessSign: '%s' placed via %s at (%.1f, %.1f, %.1f)%s" % [sign_text, placement_method, sign.position.x, sign.position.y, sign.position.z, " + entrance" if has_entrance_group else ""])

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
