extends Node
class_name OSMLoader

signal data_loaded(osm_data: Dictionary)
signal load_failed(error: String)

# Список серверов Overpass API (fallback)
const OVERPASS_SERVERS := [
	"http://mc.skrup.ru:12346/api/interpreter",
	"https://overpass.kumi.systems/api/interpreter",
	"https://overpass-api.de/api/interpreter",
	"https://maps.mail.ru/osm/tools/overpass/api/interpreter",
]

# Глобальная ротация серверов и rate limit (shared между всеми инстансами)
static var _next_server_index := 0  # Round-robin: каждый новый запрос → следующий сервер
static var _server_cooldown_until: Array[int] = [0, 0, 0, 0]  # msec timestamp до которого сервер заблокирован
static var _request_queue: Array[OSMLoader] = []  # Глобальная очередь запросов
static var _active_requests: int = 0  # Сколько HTTP запросов сейчас в полёте
const MAX_ACTIVE_REQUESTS := 6  # Макс одновременных HTTP запросов (2 на сервер)
const REQUEST_INTERVAL_MS := 500  # Минимальный интервал между запросами к одному серверу
const RATE_LIMIT_COOLDOWN_MS := 10000  # Cooldown сервера после 429/ошибки
static var _last_request_time: Array[int] = [0, 0, 0, 0]  # Время последнего запроса к каждому серверу
static var _queue_processor: OSMLoader = null  # Один инстанс обрабатывает очередь

# Кеширование
const CACHE_DIR := "user://osm_cache/"
const CACHE_VERSION := 11  # v11: custom-landmark relations (OSMLandmarks) suppressed + footprint captured into "landmarks"
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


## Выбирает сервер: приоритет у первого (свой), остальные — fallback с round-robin
static func _pick_available_server(now: int) -> int:
	# Приоритет: свой сервер (index 0) — без интервала, если не на cooldown
	if now >= _server_cooldown_until[0]:
		return 0
	# Fallback: остальные серверы с интервалом
	var best_idx := -1
	var best_wait := 999999
	for i in range(1, OVERPASS_SERVERS.size()):
		if now < _server_cooldown_until[i]:
			continue
		var elapsed := now - _last_request_time[i]
		if elapsed >= REQUEST_INTERVAL_MS:
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
  way["man_made"="bridge"](%s);
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
  node["highway"="traffic_signals"](%s);
  node["entrance"](%s);
  node["shop"](%s);
  node["amenity"](%s);
  node["highway"="bus_stop"](%s);
  node["amenity"="bus_station"](%s);
  node["public_transport"="platform"](%s);
  node["public_transport"="station"](%s);
  node["railway"="tram_stop"](%s);
  node["highway"="give_way"](%s);
);
out body geom;
>;
out skel qt;
""" % [bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox, bbox]

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
		_try_next_server("HTTP %d from %s" % [response_code, OVERPASS_SERVERS[current_server_index].split("/")[2]])
		return

	var json_string := body.get_string_from_utf8()
	var json := JSON.new()
	var parse_result := json.parse(json_string)

	if parse_result != OK:
		var now := Time.get_ticks_msec()
		_server_cooldown_until[current_server_index] = now + RATE_LIMIT_COOLDOWN_MS
		_try_next_server("JSON parse error: " + json.get_error_message())
		return

	var data: Dictionary = json.data
	var parsed := _parse_osm_data(data)

	# Если сервер вернул 0 ways — возможно неполная БД, пробуем следующий
	if parsed.get("ways", []).size() == 0 and retry_count < max_retries - 1:
		var srv_name: String = OVERPASS_SERVERS[current_server_index].split("/")[2]
		print("OSM: Server %s returned 0 ways, cooldown + trying next" % srv_name)
		var now := Time.get_ticks_msec()
		_server_cooldown_until[current_server_index] = now + RATE_LIMIT_COOLDOWN_MS
		_try_next_server("0 ways returned (incomplete data)")
		return

	# Сохраняем в кеш (только если есть данные — не кешируем пустые ответы)
	if use_cache and current_cache_key != "" and parsed.get("ways", []).size() > 0:
		_save_to_cache(current_cache_key, parsed)

	data_loaded.emit(parsed)

func _parse_osm_data(data: Dictionary) -> Dictionary:
	# Delegates to the shared transform — single source of truth for both the
	# network/Overpass path and the offline .osm.pbf path. See osm/osm_parse.gd.
	return OSMParse.parse_elements(data.get("elements", []), center_lat, center_lon)


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
