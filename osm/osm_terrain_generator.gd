extends Node3D
class_name OSMTerrainGenerator

signal initial_load_started
signal initial_load_progress(loaded: int, total: int)
signal initial_load_complete

const OSMLoaderScript = preload("res://osm/osm_loader.gd")
const ElevationLoaderScript = preload("res://osm/elevation_loader.gd")

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

	print("OSM: Ready for loading (waiting for start_loading call)...")

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
			_create_street_lamp(local, elevation, target)
			lamp_count += 1

	print("OSM: Generated %d roads, %d buildings, %d trees, %d signs, %d lamps, %d intersections" % [road_count, building_count, tree_count, sign_count, lamp_count, intersection_count])

func _create_road(nodes: Array, tags: Dictionary, parent: Node3D, loader: Node, elev_data: Dictionary = {}) -> void:
	var highway_type: String = tags.get("highway", "residential")
	var width: float = ROAD_WIDTHS.get(highway_type, 5.0)

	var color: Color
	var height_offset: float  # Смещение над террейном
	match highway_type:
		"motorway", "trunk":
			color = COLORS["road_primary"]
			height_offset = 0.15  # Самые высокие - магистрали
		"primary":
			color = COLORS["road_primary"]
			height_offset = 0.13
		"secondary":
			color = COLORS["road_secondary"]
			height_offset = 0.11
		"tertiary":
			color = COLORS["road_secondary"]
			height_offset = 0.09
		"residential", "unclassified":
			color = COLORS["road_residential"]
			height_offset = 0.07
		"service":
			color = COLORS["road_residential"]
			height_offset = 0.05
		"footway", "path", "cycleway", "track":
			color = COLORS["road_path"]
			height_offset = 0.03  # Самые низкие - пешеходные
		_:
			color = COLORS["road_residential"]
			height_offset = 0.06

	_create_path_mesh(nodes, width, color, height_offset, parent, loader, elev_data)

	# Процедурная генерация фонарей вдоль крупных дорог
	if highway_type in ["motorway", "trunk", "primary", "secondary"]:
		_generate_street_lamps_along_road(nodes, width, elev_data, parent)

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

	_create_3d_building(points, color, building_height, parent, base_elev, debug_name)

func _create_natural(nodes: Array, tags: Dictionary, parent: Node3D, loader: Node, elev_data: Dictionary = {}) -> void:
	if nodes.size() < 3:
		return

	var natural_type: String = tags.get("natural", "")
	var color: Color

	match natural_type:
		"water":
			color = COLORS["water"]
		"wood", "tree_row":
			color = COLORS["forest"]
		"grassland", "scrub":
			color = COLORS["grass"]
		_:
			color = COLORS["grass"]

	var points: PackedVector2Array = []
	for node in nodes:
		var local: Vector2 = _latlon_to_local(node.lat, node.lon)
		points.append(local)

	_create_polygon_mesh(points, color, 0.04, parent, elev_data)

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

	var color: Color
	match landuse_type:
		"residential":
			color = COLORS["default"]
		"farmland", "farm":
			color = COLORS["farmland"]
		"forest":
			color = COLORS["forest"]
		"grass", "meadow", "recreation_ground":
			color = COLORS["grass"]
		"reservoir", "basin":
			color = COLORS["water"]
		_:
			color = COLORS["default"]

	_create_polygon_mesh(points, color, 0.02, parent, elev_data)

	# Процедурная генерация деревьев в лесах
	if landuse_type == "forest":
		_generate_trees_in_polygon(points, elev_data, parent, true)  # dense=true для леса

func _create_leisure(nodes: Array, tags: Dictionary, parent: Node3D, loader: Node, elev_data: Dictionary = {}) -> void:
	if nodes.size() < 3:
		return

	var leisure_type: String = tags.get("leisure", "")
	var color: Color

	match leisure_type:
		"park", "garden":
			color = COLORS["grass"]
		"pitch", "stadium":
			color = Color(0.3, 0.5, 0.3)
		"swimming_pool":
			color = COLORS["water"]
		_:
			color = COLORS["grass"]

	var points: PackedVector2Array = []
	for node in nodes:
		var local: Vector2 = _latlon_to_local(node.lat, node.lon)
		points.append(local)

	_create_polygon_mesh(points, color, 0.04, parent, elev_data)

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

	# Парковки не создаём как здания
	if amenity_type == "parking":
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

	var mesh := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	mesh.mesh = im
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

	var material := StandardMaterial3D.new()
	material.albedo_color = fence_color
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material_override = material

	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)

	# Рисуем забор как стены по периметру
	for i in range(points.size()):
		var p1 := points[i]
		var p2 := points[(i + 1) % points.size()]

		var h1 := _get_elevation_at_point(p1, elev_data) + 0.1
		var h2 := _get_elevation_at_point(p2, elev_data) + 0.1

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

		var wall_length := p1.distance_to(p2)
		if wall_length < 0.5:
			continue

		var h1 := _get_elevation_at_point(p1, elev_data) + 0.1
		var h2 := _get_elevation_at_point(p2, elev_data) + 0.1
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

	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
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
	globe_mat.albedo_color = Color(1.0, 0.95, 0.8)  # Тёплый белый
	globe_mat.emission_enabled = true
	globe_mat.emission = Color(1.0, 0.9, 0.7)
	globe_mat.emission_energy_multiplier = 0.5
	light_globe.material_override = globe_mat

	# Позиция плафона на конце кронштейна
	light_globe.position.x = arm_end_x
	light_globe.position.y = arm_end_y
	lamp.add_child(light_globe)

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

	var lamp_spacing := 40.0  # Расстояние между фонарями (метры)
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

				var elev_left := _get_elevation_at_point(lamp_pos_left, elev_data)
				var elev_right := _get_elevation_at_point(lamp_pos_right, elev_data)

				# Направление к дороге (от фонаря к центру дороги)
				var dir_to_road_left := -perp  # Левый фонарь смотрит вправо (к дороге)
				var dir_to_road_right := perp   # Правый фонарь смотрит влево (к дороге)

				_create_street_lamp(lamp_pos_left, elev_left, parent, dir_to_road_left)
				_create_street_lamp(lamp_pos_right, elev_right, parent, dir_to_road_right)

				last_lamp_distance = accumulated_distance + pos_along

			pos_along += lamp_spacing / 4  # Проверяем чаще для точности

		accumulated_distance += segment_length


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
