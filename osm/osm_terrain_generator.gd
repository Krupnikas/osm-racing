extends Node3D
class_name OSMTerrainGenerator

const OSMLoaderScript = preload("res://osm/osm_loader.gd")

@export var start_lat := 59.149886
@export var start_lon := 37.949370
@export var chunk_size := 300.0  # Размер чанка в метрах
@export var load_distance := 500.0  # Дистанция подгрузки
@export var unload_distance := 800.0  # Дистанция выгрузки
@export var car_path: NodePath
@export var camera_path: NodePath

var osm_loader: Node
var _car: Node3D
var _camera: Camera3D
var _loaded_chunks: Dictionary = {}  # key: "x,z" -> value: Node3D (chunk node)
var _loading_chunks: Dictionary = {}  # Чанки в процессе загрузки
var _last_check_pos := Vector3.ZERO
var _check_interval := 0.5  # Проверка каждые 0.5 сек
var _check_timer := 0.0

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

	print("OSM: Starting with dynamic chunk loading...")
	# Загружаем начальный чанк
	_load_chunk_at_position(Vector3.ZERO)

func _process(delta: float) -> void:
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

	# Создаём отдельный загрузчик для этого чанка
	var loader := OSMLoaderScript.new()
	add_child(loader)
	loader.data_loaded.connect(_on_chunk_data_loaded.bind(chunk_key, loader))
	loader.load_failed.connect(_on_chunk_load_failed.bind(chunk_key, loader))
	loader.load_area(chunk_lat, chunk_lon, chunk_size / 2 + 50)  # +50м overlap

func _load_chunk_at_position(pos: Vector3) -> void:
	var chunk_x := int(floor(pos.x / chunk_size))
	var chunk_z := int(floor(pos.z / chunk_size))
	_load_chunk(chunk_x, chunk_z)

func _unload_chunk(chunk_key: String) -> void:
	if _loaded_chunks.has(chunk_key):
		var chunk_node: Node3D = _loaded_chunks[chunk_key]
		chunk_node.queue_free()
		_loaded_chunks.erase(chunk_key)
		print("OSM: Unloaded chunk %s" % chunk_key)

func _on_osm_load_failed(error: String) -> void:
	push_error("OSM load failed: " + error)

func _on_chunk_load_failed(error: String, chunk_key: String, loader: Node) -> void:
	push_error("OSM chunk %s load failed: %s" % [chunk_key, error])
	_loading_chunks.erase(chunk_key)
	loader.queue_free()

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

	_generate_terrain(osm_data, chunk_node)
	loader.queue_free()

func _generate_terrain(osm_data: Dictionary, parent: Node3D) -> void:
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

	for way in ways:
		var tags: Dictionary = way.get("tags", {})
		var nodes: Array = way.get("nodes", [])

		if nodes.size() < 2:
			continue

		if tags.has("highway"):
			_create_road(nodes, tags, target, loader)
			road_count += 1
		elif tags.has("building"):
			_create_building(nodes, tags, target, loader)
			building_count += 1
		elif tags.has("amenity") and not tags.has("building"):
			# Amenity без building тега - создаём как здание
			_create_amenity_building(nodes, tags, target, loader)
			building_count += 1
		elif tags.has("natural"):
			_create_natural(nodes, tags, target, loader)
		elif tags.has("landuse"):
			_create_landuse(nodes, tags, target, loader)
		elif tags.has("leisure"):
			_create_leisure(nodes, tags, target, loader)
		elif tags.has("waterway"):
			_create_waterway(nodes, tags, target, loader)

	print("OSM: Generated %d roads, %d buildings" % [road_count, building_count])

func _create_road(nodes: Array, tags: Dictionary, parent: Node3D, loader: Node) -> void:
	var highway_type: String = tags.get("highway", "residential")
	var width: float = ROAD_WIDTHS.get(highway_type, 5.0)

	var color: Color
	var height: float
	match highway_type:
		"motorway", "trunk":
			color = COLORS["road_primary"]
			height = 0.15  # Самые высокие - магистрали
		"primary":
			color = COLORS["road_primary"]
			height = 0.13
		"secondary":
			color = COLORS["road_secondary"]
			height = 0.11
		"tertiary":
			color = COLORS["road_secondary"]
			height = 0.09
		"residential", "unclassified":
			color = COLORS["road_residential"]
			height = 0.07
		"service":
			color = COLORS["road_residential"]
			height = 0.05
		"footway", "path", "cycleway", "track":
			color = COLORS["road_path"]
			height = 0.03  # Самые низкие - пешеходные
		_:
			color = COLORS["road_residential"]
			height = 0.06

	_create_path_mesh(nodes, width, color, height, parent, loader)

func _create_path_mesh(nodes: Array, width: float, color: Color, height: float, parent: Node3D, loader: Node) -> void:
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

		var v1 := Vector3(p1.x - perp.x, height, p1.y - perp.y)
		var v2 := Vector3(p1.x + perp.x, height, p1.y + perp.y)
		var v3 := Vector3(p2.x + perp.x, height, p2.y + perp.y)
		var v4 := Vector3(p2.x - perp.x, height, p2.y - perp.y)

		im.surface_add_vertex(v1)
		im.surface_add_vertex(v3)
		im.surface_add_vertex(v2)

		im.surface_add_vertex(v1)
		im.surface_add_vertex(v4)
		im.surface_add_vertex(v3)

	im.surface_end()
	parent.add_child(mesh)

func _create_building(nodes: Array, tags: Dictionary, parent: Node3D, loader: Node) -> void:
	if nodes.size() < 3:
		return

	var points: PackedVector2Array = []
	for node in nodes:
		var local: Vector2 = _latlon_to_local(node.lat, node.lon)
		points.append(local)

	# Определяем высоту здания из OSM данных
	var height := 0.0

	# Приоритет 1: точная высота в метрах
	if tags.has("height"):
		var h_str: String = str(tags.get("height", ""))
		# Убираем "m" если есть
		h_str = h_str.replace(" m", "").replace("m", "").strip_edges()
		if h_str.is_valid_float():
			height = float(h_str)

	# Приоритет 2: количество этажей
	if height <= 0.0 and tags.has("building:levels"):
		var levels_str: String = str(tags.get("building:levels", ""))
		if levels_str.is_valid_int():
			var levels := int(levels_str)
			height = levels * 3.2  # ~3.2м на этаж

	# Приоритет 3: тип здания
	if height <= 0.0:
		var building_type: String = str(tags.get("building", "yes"))
		match building_type:
			"house", "detached", "semidetached_house":
				height = 7.0  # 2 этажа
			"residential", "apartments":
				height = 15.0  # 5 этажей
			"commercial", "office":
				height = 12.0  # 4 этажа
			"industrial", "warehouse":
				height = 8.0
			"garage", "garages":
				height = 3.0
			"shed", "hut":
				height = 2.5
			"church", "cathedral":
				height = 20.0
			"school", "university":
				height = 12.0
			"hospital":
				height = 18.0
			_:
				height = 8.0  # По умолчанию ~3 этажа

	# Ограничиваем высоту разумными пределами
	height = clamp(height, 2.5, 100.0)

	_create_3d_building(points, COLORS["building"], height, parent)

func _create_natural(nodes: Array, tags: Dictionary, parent: Node3D, loader: Node) -> void:
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

	_create_polygon_mesh(points, color, 0.04, parent)

func _create_landuse(nodes: Array, tags: Dictionary, parent: Node3D, loader: Node) -> void:
	if nodes.size() < 3:
		return

	var landuse_type: String = tags.get("landuse", "")
	var color: Color

	match landuse_type:
		"residential":
			color = COLORS["default"]
		"commercial", "industrial":
			color = COLORS["building"]
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

	var points: PackedVector2Array = []
	for node in nodes:
		var local: Vector2 = _latlon_to_local(node.lat, node.lon)
		points.append(local)

	_create_polygon_mesh(points, color, 0.02, parent)

func _create_leisure(nodes: Array, tags: Dictionary, parent: Node3D, loader: Node) -> void:
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

	_create_polygon_mesh(points, color, 0.04, parent)

func _create_amenity_building(nodes: Array, tags: Dictionary, parent: Node3D, loader: Node) -> void:
	if nodes.size() < 3:
		return

	var points: PackedVector2Array = []
	for node in nodes:
		var local: Vector2 = _latlon_to_local(node.lat, node.lon)
		points.append(local)

	# Определяем высоту по типу amenity
	var amenity_type: String = str(tags.get("amenity", ""))
	var height: float
	var color: Color

	match amenity_type:
		"school", "kindergarten", "college":
			height = 12.0
			color = Color(0.7, 0.5, 0.4)  # Светло-коричневый
		"university":
			height = 18.0
			color = Color(0.6, 0.4, 0.3)
		"hospital", "clinic":
			height = 18.0
			color = Color(0.9, 0.9, 0.9)  # Белый
		"pharmacy":
			height = 5.0
			color = Color(0.4, 0.8, 0.4)  # Зелёный
		"police", "fire_station":
			height = 10.0
			color = Color(0.5, 0.5, 0.7)  # Синеватый
		"place_of_worship", "church":
			height = 20.0
			color = Color(0.8, 0.7, 0.5)
		"bank":
			height = 12.0
			color = Color(0.5, 0.5, 0.5)
		"restaurant", "cafe", "fast_food":
			height = 5.0
			color = Color(0.7, 0.6, 0.5)
		"fuel":
			height = 4.0
			color = Color(0.6, 0.6, 0.6)
		"parking":
			# Парковки не создаём как здания
			return
		_:
			height = 8.0
			color = Color(0.6, 0.5, 0.5)

	_create_3d_building(points, color, height, parent)

func _create_waterway(nodes: Array, tags: Dictionary, parent: Node3D, loader: Node) -> void:
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

	_create_path_mesh(nodes, width, COLORS["water"], 0.03, parent, null)

func _create_3d_building(points: PackedVector2Array, color: Color, building_height: float, parent: Node3D) -> void:
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

	# Пропускаем слишком большие здания (возможно ошибка данных > 150м)
	if size_x > 150.0 or size_z > 150.0:
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

	# Крыша - используем триангуляцию для корректной работы с невыпуклыми полигонами
	var roof_indices := Geometry2D.triangulate_polygon(points)
	if roof_indices.size() >= 3:
		for i in range(0, roof_indices.size(), 3):
			var p1 := points[roof_indices[i]]
			var p2 := points[roof_indices[i + 1]]
			var p3 := points[roof_indices[i + 2]]
			im.surface_add_vertex(Vector3(p1.x, building_height, p1.y))
			im.surface_add_vertex(Vector3(p2.x, building_height, p2.y))
			im.surface_add_vertex(Vector3(p3.x, building_height, p3.y))

	# Стены
	for i in range(points.size()):
		var p1 := points[i]
		var p2 := points[(i + 1) % points.size()]

		var v1 := Vector3(p1.x, 0.1, p1.y)  # Чуть выше земли
		var v2 := Vector3(p2.x, 0.1, p2.y)
		var v3 := Vector3(p2.x, building_height, p2.y)
		var v4 := Vector3(p1.x, building_height, p1.y)

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

		var wall_center := Vector3((p1.x + p2.x) / 2, building_height / 2, (p1.y + p2.y) / 2)
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

func _create_polygon_mesh(points: PackedVector2Array, color: Color, height: float, parent: Node3D) -> void:
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
			im.surface_add_vertex(Vector3(p1.x, height, p1.y))
			im.surface_add_vertex(Vector3(p2.x, height, p2.y))
			im.surface_add_vertex(Vector3(p3.x, height, p3.y))

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
