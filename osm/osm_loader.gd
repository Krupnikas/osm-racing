extends Node
class_name OSMLoader

signal data_loaded(osm_data: Dictionary)
signal load_failed(error: String)

# Список серверов Overpass API (fallback)
const OVERPASS_SERVERS := [
	"https://overpass.kumi.systems/api/interpreter",
	"https://overpass-api.de/api/interpreter",
	"https://maps.mail.ru/osm/tools/overpass/api/interpreter",
]

# Кеширование
const CACHE_DIR := "user://osm_cache/"
const CACHE_VERSION := 2  # Увеличить при изменении формата запроса (v2: добавлены деревья, знаки, фонари)
var use_cache := true

var http_request: HTTPRequest
var center_lat: float
var center_lon: float
var radius_meters: float
var current_server_index := 0
var retry_count := 0
var max_retries := 3
var pending_query: String = ""
var current_cache_key: String = ""

func _ready() -> void:
	http_request = HTTPRequest.new()
	add_child(http_request)
	http_request.request_completed.connect(_on_request_completed)
	_ensure_cache_dir()


func _ensure_cache_dir() -> void:
	if not DirAccess.dir_exists_absolute(CACHE_DIR):
		DirAccess.make_dir_recursive_absolute(CACHE_DIR)


func _get_cache_key(lat: float, lon: float, radius: float) -> String:
	# Округляем координаты для стабильного ключа (до 4 знаков ~ 11м точность)
	var lat_key := "%.4f" % lat
	var lon_key := "%.4f" % lon
	var radius_key := "%d" % int(radius)
	return "osm_v%d_%s_%s_%s.json" % [CACHE_VERSION, lat_key, lon_key, radius_key]


func _get_cache_path(cache_key: String) -> String:
	return CACHE_DIR + cache_key


func _load_from_cache(cache_key: String) -> Dictionary:
	var cache_path := _get_cache_path(cache_key)
	if not FileAccess.file_exists(cache_path):
		return {}

	var file := FileAccess.open(cache_path, FileAccess.READ)
	if not file:
		return {}

	var json_string := file.get_as_text()
	file.close()

	var json := JSON.new()
	if json.parse(json_string) != OK:
		return {}

	return json.data


func _save_to_cache(cache_key: String, data: Dictionary) -> void:
	var cache_path := _get_cache_path(cache_key)
	var file := FileAccess.open(cache_path, FileAccess.WRITE)
	if not file:
		push_warning("OSM: Failed to write cache: " + cache_path)
		return

	file.store_string(JSON.stringify(data))
	file.close()
	print("OSM: Cached data to " + cache_key)


func load_area(lat: float, lon: float, radius: float = 500.0) -> void:
	center_lat = lat
	center_lon = lon
	radius_meters = radius

	# Проверяем кеш
	current_cache_key = _get_cache_key(lat, lon, radius)
	if use_cache:
		var cached := _load_from_cache(current_cache_key)
		if not cached.is_empty():
			print("OSM: Loaded from cache: " + current_cache_key)
			# Обновляем центр из кеша
			cached["center_lat"] = center_lat
			cached["center_lon"] = center_lon
			# Эмитим с небольшой задержкой чтобы вызывающий код успел подписаться
			call_deferred("_emit_cached_data", cached)
			return

	# Конвертируем радиус в градусы (приблизительно)
	var lat_delta := radius / 111000.0  # 111км на градус широты
	var lon_delta := radius / (111000.0 * cos(deg_to_rad(lat)))

	var bbox := "%f,%f,%f,%f" % [
		lat - lat_delta,
		lon - lon_delta,
		lat + lat_delta,
		lon + lon_delta
	]

	# Overpass запрос для получения дорог, зданий, водоёмов, зелени, amenity, деревьев, знаков, входов
	# Включаем relation для крупных зданий (школы, больницы и т.д.)
	var query := """
[out:json][timeout:30];
(
  way["highway"](%s);
  way["building"](%s);
  way["landuse"](%s);
  way["natural"](%s);
  way["leisure"](%s);
  way["waterway"](%s);
  way["amenity"](%s);
  relation["building"](%s);
  relation["amenity"](%s);
  node["natural"="tree"](%s);
  node["traffic_sign"](%s);
  node["highway"="street_lamp"](%s);
  node["entrance"](%s);
  node["shop"](%s);
  node["amenity"](%s);
);
out body geom;
>;
out skel qt;
""" % [bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox]

	pending_query = query
	current_server_index = 0
	retry_count = 0
	_send_request()


func _emit_cached_data(cached: Dictionary) -> void:
	data_loaded.emit(cached)

func _send_request() -> void:
	var server_url: String = OVERPASS_SERVERS[current_server_index]
	var headers := ["Content-Type: application/x-www-form-urlencoded"]
	var body := "data=" + pending_query.uri_encode()

	print("OSM: Trying server %s (attempt %d)" % [server_url, retry_count + 1])
	var error := http_request.request(server_url, headers, HTTPClient.METHOD_POST, body)

	if error != OK:
		_try_next_server("HTTP request failed: " + str(error))

func _try_next_server(reason: String) -> void:
	print("OSM: Server failed - %s" % reason)
	retry_count += 1

	if retry_count < max_retries:
		current_server_index = (current_server_index + 1) % OVERPASS_SERVERS.size()
		print("OSM: Retrying with next server...")
		_send_request()
	else:
		load_failed.emit("All servers failed after %d attempts. Last error: %s" % [max_retries, reason])

func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		_try_next_server("Request failed with result: " + str(result))
		return

	if response_code != 200:
		_try_next_server("HTTP error: " + str(response_code))
		return

	var json_string := body.get_string_from_utf8()
	var json := JSON.new()
	var parse_result := json.parse(json_string)

	if parse_result != OK:
		load_failed.emit("JSON parse error: " + json.get_error_message())
		return

	var data: Dictionary = json.data
	var parsed := _parse_osm_data(data)

	# Сохраняем в кеш
	if use_cache and current_cache_key != "":
		_save_to_cache(current_cache_key, parsed)

	data_loaded.emit(parsed)

func _parse_osm_data(data: Dictionary) -> Dictionary:
	var nodes := {}
	var ways := []
	var way_by_id := {}  # Для связи relation -> way
	var point_objects := []  # Точечные объекты (деревья, знаки, фонари)
	var entrance_nodes := []  # Входы в здания
	var poi_nodes := []  # Точечные заведения (shop, amenity как node)

	# Собираем все узлы
	for element in data.get("elements", []):
		if element.get("type") == "node":
			nodes[element.id] = {
				"lat": element.lat,
				"lon": element.lon
			}
			# Проверяем есть ли теги - это точечный объект
			var tags: Dictionary = element.get("tags", {})
			if not tags.is_empty():
				# Отдельно сохраняем entrance nodes
				if tags.has("entrance"):
					entrance_nodes.append({
						"lat": element.lat,
						"lon": element.lon,
						"tags": tags
					})

				# Точечные заведения (shop или amenity с названием)
				if (tags.has("shop") or tags.has("amenity")) and (tags.has("name") or tags.has("brand")):
					poi_nodes.append({
						"lat": element.lat,
						"lon": element.lon,
						"tags": tags
					})

				point_objects.append({
					"lat": element.lat,
					"lon": element.lon,
					"tags": tags
				})

	# Собираем все пути (и сохраняем по id для relation)
	for element in data.get("elements", []):
		if element.get("type") == "way":
			var way_nodes := []
			for node_id in element.get("nodes", []):
				if nodes.has(node_id):
					way_nodes.append(nodes[node_id])

			if way_nodes.size() > 1:
				var way_data := {
					"nodes": way_nodes,
					"tags": element.get("tags", {})
				}
				ways.append(way_data)
				way_by_id[element.id] = way_nodes

	# Обрабатываем relation (multipolygon для крупных зданий)
	# С out geom геометрия включена напрямую в members
	var relations_found := 0
	var relations_with_nodes := 0
	for element in data.get("elements", []):
		if element.get("type") == "relation":
			relations_found += 1
			var tags: Dictionary = element.get("tags", {})
			# Берём только outer members для построения контура
			var outer_nodes := []
			for member in element.get("members", []):
				if member.get("type") == "way" and member.get("role", "outer") == "outer":
					# С out geom геометрия включена в member.geometry
					var geometry: Array = member.get("geometry", [])
					if geometry.size() > 0:
						for point in geometry:
							outer_nodes.append({
								"lat": point.get("lat", 0.0),
								"lon": point.get("lon", 0.0)
							})
					else:
						# Fallback на старый метод через way_by_id
						var way_id: int = member.get("ref", 0)
						if way_by_id.has(way_id):
							for node in way_by_id[way_id]:
								outer_nodes.append(node)

			if outer_nodes.size() > 2:
				relations_with_nodes += 1
				ways.append({
					"nodes": outer_nodes,
					"tags": tags
				})

	if relations_found > 0:
		print("OSM: Found %d relations, %d with valid geometry" % [relations_found, relations_with_nodes])

	print("OSM: Parsed %d nodes, %d ways, %d point objects, %d entrances, %d POI nodes" % [nodes.size(), ways.size(), point_objects.size(), entrance_nodes.size(), poi_nodes.size()])

	return {
		"center_lat": center_lat,
		"center_lon": center_lon,
		"nodes": nodes,
		"ways": ways,
		"point_objects": point_objects,
		"entrance_nodes": entrance_nodes,
		"poi_nodes": poi_nodes
	}

# Конвертация координат в локальные метры относительно центра
func latlon_to_local(lat: float, lon: float) -> Vector2:
	var dx := (lon - center_lon) * 111000.0 * cos(deg_to_rad(center_lat))
	var dz := (lat - center_lat) * 111000.0
	return Vector2(dx, dz)


# Очистка всего кеша
func clear_cache() -> void:
	var dir := DirAccess.open(CACHE_DIR)
	if not dir:
		return

	dir.list_dir_begin()
	var file_name := dir.get_next()
	var count := 0
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".json"):
			dir.remove(file_name)
			count += 1
		file_name = dir.get_next()
	dir.list_dir_end()
	print("OSM: Cleared %d cached files" % count)


# Получить размер кеша
func get_cache_size() -> int:
	var dir := DirAccess.open(CACHE_DIR)
	if not dir:
		return 0

	var total_size := 0
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".json"):
			var file := FileAccess.open(CACHE_DIR + file_name, FileAccess.READ)
			if file:
				total_size += file.get_length()
				file.close()
		file_name = dir.get_next()
	dir.list_dir_end()
	return total_size


# Проверить есть ли данные в кеше для области
func is_cached(lat: float, lon: float, radius: float) -> bool:
	var cache_key := _get_cache_key(lat, lon, radius)
	return FileAccess.file_exists(_get_cache_path(cache_key))
