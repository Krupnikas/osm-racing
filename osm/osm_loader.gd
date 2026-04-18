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

# Глобальная ротация серверов и rate limit (shared между всеми инстансами)
static var _next_server_index := 0  # Round-robin: каждый новый запрос → следующий сервер
static var _server_cooldown_until: Array[int] = [0, 0, 0]  # msec timestamp до которого сервер заблокирован
static var _request_queue: Array[OSMLoader] = []  # Глобальная очередь запросов
static var _active_requests: int = 0  # Сколько HTTP запросов сейчас в полёте
const MAX_ACTIVE_REQUESTS := 6  # Макс одновременных HTTP запросов (2 на сервер)
const REQUEST_INTERVAL_MS := 500  # Минимальный интервал между запросами к одному серверу
const RATE_LIMIT_COOLDOWN_MS := 10000  # Cooldown сервера после 429/ошибки
static var _last_request_time: Array[int] = [0, 0, 0]  # Время последнего запроса к каждому серверу
static var _queue_processor: OSMLoader = null  # Один инстанс обрабатывает очередь

# Кеширование
const CACHE_DIR := "user://osm_cache/"
const CACHE_VERSION := 6  # v6: добавлен poi node id
var use_cache := true

var http_request: HTTPRequest
var center_lat: float
var center_lon: float
var radius_meters: float
var current_server_index := 0
var retry_count := 0
var max_retries := 6  # 2 полных прохода по 3 серверам
var pending_query: String = ""
var current_cache_key: String = ""
var _waiting_in_queue := false

# Thread-based cache loading
var _cache_task_id: int = -1
var _cache_result: Dictionary = {}
var _cache_result_ready: bool = false
var _cache_mutex := Mutex.new()

func _ready() -> void:
	http_request = HTTPRequest.new()
	http_request.timeout = 10.0  # 10s HTTP timeout per server attempt
	add_child(http_request)
	http_request.request_completed.connect(_on_request_completed)
	_ensure_cache_dir()


func _process(_delta: float) -> void:
	# Poll for thread-loaded cache results
	if _cache_task_id >= 0:
		_cache_mutex.lock()
		var ready := _cache_result_ready
		_cache_mutex.unlock()
		if ready:
			var result := _cache_result
			_cache_task_id = -1
			_cache_result = {}
			_cache_result_ready = false
			if not result.is_empty():
				result["center_lat"] = center_lat
				result["center_lon"] = center_lon
				data_loaded.emit(result)
			else:
				# Cache load failed — fall back to network
				_start_network_request()

	# Один инстанс обрабатывает глобальную очередь (dispatch multiple per frame)
	if _queue_processor == null or not is_instance_valid(_queue_processor):
		if not _request_queue.is_empty():
			_queue_processor = self
	if _queue_processor == self:
		for _qi in MAX_ACTIVE_REQUESTS:
			_process_global_queue()


func _exit_tree() -> void:
	# Убираем себя из очереди при удалении
	_request_queue.erase(self)
	if _queue_processor == self:
		# Hand off queue processing to another waiting loader
		_queue_processor = null
		for loader in _request_queue:
			if is_instance_valid(loader) and loader.is_inside_tree():
				_queue_processor = loader
				break


## Обработка глобальной очереди запросов
func _process_global_queue() -> void:
	if _request_queue.is_empty():
		return
	if _active_requests >= MAX_ACTIVE_REQUESTS:
		return

	var now := Time.get_ticks_msec()

	# Ищем свободный сервер для следующего в очереди
	var server_idx := _pick_available_server(now)
	if server_idx < 0:
		return  # Все серверы на cooldown или rate limited

	# Берём первого из очереди
	var loader: OSMLoader = _request_queue.pop_front()
	if not is_instance_valid(loader):
		return  # Loader был удалён пока ждал
	loader._waiting_in_queue = false
	loader.current_server_index = server_idx
	_last_request_time[server_idx] = now
	_active_requests += 1
	loader._send_request_immediate()


## Выбирает сервер с учётом cooldown и минимального интервала
static func _pick_available_server(now: int) -> int:
	var best_idx := -1
	var best_wait := 999999
	for i in OVERPASS_SERVERS.size():
		# Сервер на cooldown (rate limited)
		if now < _server_cooldown_until[i]:
			continue
		# Проверяем минимальный интервал
		var elapsed := now - _last_request_time[i]
		if elapsed >= REQUEST_INTERVAL_MS:
			# Сервер свободен — берём с наименьшим временем ожидания
			if elapsed > best_wait or best_idx < 0:
				best_idx = i
				best_wait = elapsed
	return best_idx


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


## Load from cache on a worker thread (file I/O + JSON parse)
func _load_from_cache_threaded(cache_key: String) -> void:
	var cache_path := ProjectSettings.globalize_path(_get_cache_path(cache_key))
	_cache_task_id = WorkerThreadPool.add_task(
		_cache_load_task.bind(cache_path),
		false,  # high_priority
		"OSMCacheLoad"
	)


## Worker thread task: read file + parse JSON (no scene tree access!)
func _cache_load_task(cache_path: String) -> void:
	var result := {}
	var file := FileAccess.open(cache_path, FileAccess.READ)
	if file:
		var json_string := file.get_as_text()
		file.close()
		var json := JSON.new()
		if json.parse(json_string) == OK:
			result = json.data
	_cache_mutex.lock()
	_cache_result = result
	_cache_result_ready = true
	_cache_mutex.unlock()


## Synchronous cache load (used during initial loading for simplicity)
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
		var cache_path := _get_cache_path(current_cache_key)
		if FileAccess.file_exists(cache_path):
			print("OSM: CACHE HIT: " + current_cache_key)
			_load_from_cache_threaded(current_cache_key)
			return

	print("OSM: CACHE MISS — fetching from Overpass: " + current_cache_key)
	_start_network_request()


func _start_network_request() -> void:
	# Конвертируем радиус в градусы (приблизительно)
	var lat_delta := radius_meters / 111000.0  # 111км на градус широты
	var lon_delta := radius_meters / (111000.0 * cos(deg_to_rad(center_lat)))

	var bbox := "%f,%f,%f,%f" % [
		center_lat - lat_delta,
		center_lon - lon_delta,
		center_lat + lat_delta,
		center_lon + lon_delta
	]

	# Overpass запрос для получения дорог, зданий, водоёмов, зелени, amenity, деревьев, знаков, входов
	# Включаем relation для крупных зданий (школы, больницы и т.д.)
	var query := """
[out:json][timeout:30];
(
  way["highway"](%s);
  way["railway"="tram"](%s);
  way["building"](%s);
  way["landuse"](%s);
  way["natural"](%s);
  way["leisure"](%s);
  way["waterway"](%s);
  way["amenity"](%s);
  relation["building"](%s);
  relation["amenity"](%s);
  relation["highway"="pedestrian"](%s);
  relation["leisure"](%s);
  relation["natural"="water"](%s);
  relation["waterway"="riverbank"](%s);
  relation["man_made"="bridge"](%s);
  node["man_made"="chimney"](%s);
  node["natural"="tree"](%s);
  node["traffic_sign"](%s);
  node["highway"="street_lamp"](%s);
  node["entrance"](%s);
  node["shop"](%s);
  node["amenity"](%s);
  node["highway"="bus_stop"](%s);
  node["amenity"="bus_station"](%s);
  node["public_transport"="platform"](%s);
  node["public_transport"="station"](%s);
  node["railway"="tram_stop"](%s);
);
out body geom;
>;
out skel qt;
""" % [bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox]

	pending_query = query
	retry_count = 0

	# Встаём в глобальную очередь вместо немедленного запроса
	_waiting_in_queue = true
	if not _request_queue.has(self):
		_request_queue.append(self)

	# Назначаем обработчик очереди если ещё нет
	if _queue_processor == null or not is_instance_valid(_queue_processor):
		_queue_processor = self


func _emit_cached_data(cached: Dictionary) -> void:
	data_loaded.emit(cached)


## Отправляет запрос немедленно (вызывается из очереди, сервер уже выбран)
func _send_request_immediate() -> void:
	var server_url: String = OVERPASS_SERVERS[current_server_index]
	var headers := ["Content-Type: application/x-www-form-urlencoded"]
	var body := "data=" + pending_query.uri_encode()

	var server_name := server_url.split("/")[2]  # "overpass.kumi.systems" etc
	print("OSM: [%s] attempt %d (active: %d, queued: %d)" % [
		server_name, retry_count + 1, _active_requests, _request_queue.size()])
	var error := http_request.request(server_url, headers, HTTPClient.METHOD_POST, body)

	if error != OK:
		_active_requests = maxi(0, _active_requests - 1)
		_try_next_server("HTTP request failed: " + str(error))


func _try_next_server(reason: String) -> void:
	print("OSM: Server failed - %s" % reason)
	retry_count += 1

	if retry_count < max_retries:
		# Возвращаемся в очередь — сервер выберется автоматически
		_waiting_in_queue = true
		if not _request_queue.has(self):
			_request_queue.append(self)
	else:
		load_failed.emit("All servers failed after %d attempts. Last error: %s" % [max_retries, reason])


func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_active_requests = maxi(0, _active_requests - 1)

	if result != HTTPRequest.RESULT_SUCCESS:
		_try_next_server("Request failed with result: " + str(result))
		return

	if response_code == 429 or response_code == 503:
		# Rate limited — ставим cooldown на этот сервер
		var now := Time.get_ticks_msec()
		_server_cooldown_until[current_server_index] = now + RATE_LIMIT_COOLDOWN_MS
		print("OSM: Server %s rate limited (HTTP %d), cooldown %ds" % [
			OVERPASS_SERVERS[current_server_index].split("/")[2],
			response_code, RATE_LIMIT_COOLDOWN_MS / 1000])
		_try_next_server("HTTP %d (rate limited)" % response_code)
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
	var bus_stops := []  # Автобусные остановки
	var tram_stops := []  # Трамвайные остановки
	var pedestrian_areas := []  # Пешеходные площади (relation highway=pedestrian area=yes)
	var bridge_decks := []  # Bridge deck outlines (relation man_made=bridge type=multipolygon)

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
						"id": element.id,
						"lat": element.lat,
						"lon": element.lon,
						"tags": tags
					})

				# Автобусные остановки (highway=bus_stop, amenity=bus_station, public_transport=platform/station)
				var is_bus_stop: bool = tags.get("highway", "") == "bus_stop"
				var is_bus_station: bool = tags.get("amenity", "") == "bus_station"
				var pt_value: String = tags.get("public_transport", "")
				var is_platform: bool = pt_value == "platform" or pt_value == "station"
				if is_bus_stop or is_bus_station or is_platform:
					bus_stops.append({
						"lat": element.lat,
						"lon": element.lon,
						"tags": tags
					})

				# Трамвайные остановки
				if tags.get("railway", "") == "tram_stop":
					tram_stops.append({
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
				var tags_d: Dictionary = element.get("tags", {})
				var way_data := {
					"id": element.id,
					"nodes": way_nodes,
					"tags": tags_d
				}
				if tags_d.get("railway", "") == "tram":
					print("[TRAM] Loaded tram way %d with %d nodes, tags=%s" % [element.id, way_nodes.size(), str(tags_d)])
				ways.append(way_data)
				way_by_id[element.id] = way_nodes

	# Обрабатываем relation (multipolygon для крупных зданий)
	# С out geom геометрия включена напрямую в members
	var relations_found := 0
	var relations_with_nodes := 0
	var relation_member_way_ids: Dictionary = {}  # way_id → true (member ways of building relations)
	for element in data.get("elements", []):
		if element.get("type") == "relation":
			relations_found += 1
			var tags: Dictionary = element.get("tags", {})
			# Multipolygon: outer members are individual ways (often open lines) that need to
			# be JOINED head-to-tail into closed rings. Concatenating them naively or treating
			# each as a polygon both produce broken geometry for relations like the Rybinsk
			# Reservoir water (637 members forming many separate rings).
			var is_building_relation: bool = tags.has("building") or tags.has("amenity")
			var outer_member_ways: Array = []  # Array[ {nodes: Array, way_ref: int} ]
			for member in element.get("members", []):
				if member.get("type") == "way" and member.get("role", "outer") == "outer":
					var ref_id: int = member.get("ref", 0)
					# Запоминаем member way IDs чтобы не дублировать building из relation
					if is_building_relation and ref_id > 0:
						relation_member_way_ids[ref_id] = true
					var member_nodes: Array = []
					var geometry: Array = member.get("geometry", [])
					if geometry.size() > 0:
						for point in geometry:
							member_nodes.append({
								"lat": point.get("lat", 0.0),
								"lon": point.get("lon", 0.0)
							})
					elif way_by_id.has(ref_id):
						for node in way_by_id[ref_id]:
							member_nodes.append(node)
					if member_nodes.size() >= 2:
						outer_member_ways.append({"nodes": member_nodes, "way_ref": ref_id})

			# Join member ways into closed rings (each ring is a separate polygon)
			var outer_rings: Array = _join_relation_rings(outer_member_ways)

			if not outer_rings.is_empty():
				relations_with_nodes += 1
				if tags.get("man_made", "") == "bridge":
					# Bridge deck outlines go to a separate array.
					# Each ring is a closed polygon of the bridge platform area.
					for ring in outer_rings:
						if ring.nodes.size() > 2:
							bridge_decks.append({
								"nodes": ring.nodes,
								"tags": tags,
								"relation_id": element.get("id", 0)
							})
				elif tags.get("highway", "") == "pedestrian" and tags.get("area", "") == "yes":
					# Pedestrian areas go to separate array (not mixed with roads).
					for ring in outer_rings:
						if ring.nodes.size() > 2:
							pedestrian_areas.append(ring.nodes)
				else:
					for ring in outer_rings:
						if ring.nodes.size() > 2:
							ways.append({
								"id": ring.way_ref,
								"nodes": ring.nodes,
								"tags": tags
							})

	# Убираем building/amenity теги у ways которые являются members building-relations
	# (relation уже добавлен как целый building, individual way не нужен)
	if not relation_member_way_ids.is_empty():
		var deduped := 0
		for way_data in ways:
			var wid: int = int(way_data.get("id", 0))
			if wid > 0 and relation_member_way_ids.has(wid):
				var wtags: Dictionary = way_data.get("tags", {})
				if wtags.has("building") or wtags.has("amenity"):
					wtags.erase("building")
					wtags.erase("amenity")
					deduped += 1
		if deduped > 0:
			print("OSM: Deduped %d ways that are members of building/amenity relations" % deduped)

	if relations_found > 0:
		print("OSM: Found %d relations, %d with valid geometry" % [relations_found, relations_with_nodes])

	print("OSM: Parsed %d nodes, %d ways, %d point objects, %d entrances, %d POI nodes, %d bus stops, %d tram stops, %d pedestrian areas, %d bridge decks" % [nodes.size(), ways.size(), point_objects.size(), entrance_nodes.size(), poi_nodes.size(), bus_stops.size(), tram_stops.size(), pedestrian_areas.size(), bridge_decks.size()])

	return {
		"center_lat": center_lat,
		"center_lon": center_lon,
		"nodes": nodes,
		"ways": ways,
		"point_objects": point_objects,
		"entrance_nodes": entrance_nodes,
		"poi_nodes": poi_nodes,
		"bus_stops": bus_stops,
		"tram_stops": tram_stops,
		"pedestrian_areas": pedestrian_areas,
		"bridge_decks": bridge_decks,
	}

## Joins relation outer member ways head-to-tail into closed rings.
## Each member is an open polyline; consecutive members chain via shared endpoints.
## Returns Array of {nodes: Array, way_ref: int}, each entry being one closed (or auto-closed) ring.
func _join_relation_rings(member_ways: Array) -> Array:
	var rings: Array = []
	var pending: Array = member_ways.duplicate()
	while not pending.is_empty():
		var current: Dictionary = pending.pop_front()
		var ring_nodes: Array = (current["nodes"] as Array).duplicate()
		var ring_way_ref: int = int(current.get("way_ref", 0))
		while true:
			if ring_nodes.size() < 2:
				break
			var first: Dictionary = ring_nodes[0]
			var last: Dictionary = ring_nodes[ring_nodes.size() - 1]
			if _nodes_equal(first, last):
				break  # closed
			var found_idx: int = -1
			var found_reverse: bool = false
			for i in range(pending.size()):
				var w_dict: Dictionary = pending[i]
				var w_nodes: Array = w_dict["nodes"]
				if w_nodes.is_empty():
					continue
				var w_first: Dictionary = w_nodes[0]
				var w_last: Dictionary = w_nodes[w_nodes.size() - 1]
				if _nodes_equal(w_first, last):
					found_idx = i
					found_reverse = false
					break
				if _nodes_equal(w_last, last):
					found_idx = i
					found_reverse = true
					break
			if found_idx < 0:
				break  # no more chainable members
			var next_member: Dictionary = pending[found_idx]
			pending.remove_at(found_idx)
			var next_nodes: Array = (next_member["nodes"] as Array).duplicate()
			if found_reverse:
				next_nodes.reverse()
			# skip first node (duplicate of our last)
			for j in range(1, next_nodes.size()):
				ring_nodes.append(next_nodes[j])
		# Auto-close ring if not naturally closed (data clipped at bbox)
		if ring_nodes.size() >= 3:
			var first2: Dictionary = ring_nodes[0]
			var last2: Dictionary = ring_nodes[ring_nodes.size() - 1]
			if not _nodes_equal(first2, last2):
				ring_nodes.append(first2)
		rings.append({"nodes": ring_nodes, "way_ref": ring_way_ref})
	return rings


static func _nodes_equal(a: Dictionary, b: Dictionary) -> bool:
	# Tolerance ~0.01m at this latitude
	return absf(float(a["lat"]) - float(b["lat"])) < 1e-7 and absf(float(a["lon"]) - float(b["lon"])) < 1e-7


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
