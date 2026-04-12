extends Node
class_name ElevationLoader

## Загружает elevation данные из OpenTopoData SRTM30m API.
## Кеширует результат на диск. Один инстанс на чанк.

signal elevation_loaded(chunk_key: String, grid_data: Dictionary)
signal elevation_failed(chunk_key: String, error: String)

const API_URL := "https://api.opentopodata.org/v1/srtm30m"
const CACHE_DIR := "user://osm_cache/"
const CACHE_VERSION := 2
const GRID_RES := 7  # 7x7 grid per chunk (~33m spacing, matches SRTM30m native resolution)

# Global rate limiting — 1 request per second (API returns 429 otherwise)
static var _request_queue: Array[ElevationLoader] = []
static var _active_requests: int = 0
static var _last_request_time: int = 0
static var _queue_processor: ElevationLoader = null
const MAX_ACTIVE_REQUESTS := 1
const REQUEST_INTERVAL_MS := 1100  # Slightly over 1s to stay safe

var http_request: HTTPRequest
var chunk_key: String
var chunk_x: int
var chunk_z: int
var chunk_size: float
var start_lat: float
var start_lon: float
var _lon_scale: float
var _waiting_in_queue := false

# Thread-based cache loading
var _cache_task_id: int = -1
var _cache_result: Dictionary = {}
var _cache_result_ready: bool = false
var _cache_mutex := Mutex.new()


func _ready() -> void:
	http_request = HTTPRequest.new()
	http_request.timeout = 15.0
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
				elevation_loaded.emit(chunk_key, result)
			else:
				# Cache load failed — fetch from network
				_start_network_request()

	# Process global queue (one instance processes it)
	if _queue_processor == null or not is_instance_valid(_queue_processor):
		if not _request_queue.is_empty():
			_queue_processor = self
	if _queue_processor == self:
		_process_global_queue()


func _exit_tree() -> void:
	_request_queue.erase(self)
	if _queue_processor == self:
		_queue_processor = null
		for loader in _request_queue:
			if is_instance_valid(loader) and loader.is_inside_tree():
				_queue_processor = loader
				break


func _process_global_queue() -> void:
	if _request_queue.is_empty():
		return
	if _active_requests >= MAX_ACTIVE_REQUESTS:
		return

	var now := Time.get_ticks_msec()
	if (now - _last_request_time) < REQUEST_INTERVAL_MS:
		return

	var loader: ElevationLoader = _request_queue.pop_front()
	if not is_instance_valid(loader):
		return
	loader._waiting_in_queue = false
	_last_request_time = now
	_active_requests += 1
	loader._send_request_immediate()


func _ensure_cache_dir() -> void:
	if not DirAccess.dir_exists_absolute(CACHE_DIR):
		DirAccess.make_dir_recursive_absolute(CACHE_DIR)


func _get_cache_key() -> String:
	return "elev_v%d_%.4f_%.4f_%s.json" % [CACHE_VERSION, start_lat, start_lon, chunk_key]


func _get_cache_path() -> String:
	return CACHE_DIR + _get_cache_key()


## Load elevation grid for a chunk. Checks cache first, then API.
func load_elevation(p_chunk_key: String, p_chunk_x: int, p_chunk_z: int,
		p_chunk_size: float, p_start_lat: float, p_start_lon: float) -> void:
	chunk_key = p_chunk_key
	chunk_x = p_chunk_x
	chunk_z = p_chunk_z
	chunk_size = p_chunk_size
	start_lat = p_start_lat
	start_lon = p_start_lon
	_lon_scale = cos(deg_to_rad(start_lat)) * 111000.0

	# Check cache
	var cache_path := _get_cache_path()
	if FileAccess.file_exists(cache_path):
		print("ELEV: CACHE HIT: %s" % _get_cache_key())
		_load_from_cache_threaded()
		return

	print("ELEV: CACHE MISS — queueing API request: %s" % chunk_key)
	_start_network_request()


func _load_from_cache_threaded() -> void:
	var cache_path := ProjectSettings.globalize_path(_get_cache_path())
	_cache_task_id = WorkerThreadPool.add_task(
		_cache_load_task.bind(cache_path),
		false,
		"ElevCacheLoad"
	)


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


func _save_to_cache(data: Dictionary) -> void:
	var cache_path := _get_cache_path()
	var file := FileAccess.open(cache_path, FileAccess.WRITE)
	if not file:
		push_warning("ELEV: Failed to write cache: " + cache_path)
		return
	file.store_string(JSON.stringify(data))
	file.close()
	print("ELEV: Cached %s" % _get_cache_key())


func _start_network_request() -> void:
	_waiting_in_queue = true
	if not _request_queue.has(self):
		_request_queue.append(self)
	if _queue_processor == null or not is_instance_valid(_queue_processor):
		_queue_processor = self


func _send_request_immediate() -> void:
	var locations := _build_locations_string()
	var url := "%s?locations=%s" % [API_URL, locations]
	print("ELEV: Requesting %s (%d points)" % [chunk_key, GRID_RES * GRID_RES])

	var error := http_request.request(url)
	if error != OK:
		_active_requests = maxi(0, _active_requests - 1)
		elevation_failed.emit(chunk_key, "HTTP request error: %d" % error)


## Build pipe-separated lat,lon pairs for the 5x5 grid
func _build_locations_string() -> String:
	var grid_step := chunk_size / (GRID_RES - 1)
	var parts := PackedStringArray()

	for iz in GRID_RES:
		for ix in GRID_RES:
			var world_x: float = chunk_x * chunk_size + ix * grid_step
			var world_z: float = chunk_z * chunk_size + iz * grid_step
			# Inverse of _latlon_to_local: world → lat/lon
			var lat: float = start_lat - world_z / 111000.0
			var lon: float = start_lon + world_x / _lon_scale
			parts.append("%.6f,%.6f" % [lat, lon])

	return "|".join(parts)


func _on_request_completed(result: int, response_code: int,
		_headers: PackedStringArray, body: PackedByteArray) -> void:
	_active_requests = maxi(0, _active_requests - 1)

	if result != HTTPRequest.RESULT_SUCCESS:
		elevation_failed.emit(chunk_key, "Request failed: %d" % result)
		return

	if response_code == 429:
		# Rate limited — re-queue with delay
		print("ELEV: Rate limited (429), re-queueing %s" % chunk_key)
		_start_network_request()
		return

	if response_code != 200:
		elevation_failed.emit(chunk_key, "HTTP %d" % response_code)
		return

	var json_string := body.get_string_from_utf8()
	var json := JSON.new()
	if json.parse(json_string) != OK:
		elevation_failed.emit(chunk_key, "JSON parse error")
		return

	var data: Dictionary = json.data
	if data.get("status") != "OK":
		elevation_failed.emit(chunk_key, "API error: %s" % data.get("error", "unknown"))
		return

	var results: Array = data.get("results", [])
	if results.size() != GRID_RES * GRID_RES:
		elevation_failed.emit(chunk_key, "Expected %d results, got %d" % [
			GRID_RES * GRID_RES, results.size()])
		return

	# Parse into 2D grid
	var grid_step := chunk_size / (GRID_RES - 1)
	var grid: Array = []
	for iz in GRID_RES:
		var row: Array = []
		for ix in GRID_RES:
			var idx := iz * GRID_RES + ix
			var elev = results[idx].get("elevation")
			if elev == null:
				elev = 0.0
			row.append(float(elev))
		grid.append(row)

	# Filter bad data
	_filter_bad_data(grid)

	var grid_data := {
		"version": CACHE_VERSION,
		"grid_res": GRID_RES,
		"grid": grid,
		"base_x": float(chunk_x) * chunk_size,
		"base_z": float(chunk_z) * chunk_size,
		"grid_step": grid_step,
	}

	# Log elevation range
	var min_e: float = float(grid[0][0])
	var max_e: float = float(grid[0][0])
	for row in grid:
		for val in row:
			min_e = minf(min_e, val)
			max_e = maxf(max_e, val)
	print("ELEV: %s loaded, range %.0f-%.0fm ASL" % [chunk_key, min_e, max_e])

	_save_to_cache(grid_data)
	elevation_loaded.emit(chunk_key, grid_data)


## Filter out bad elevation values (zeros in areas where they shouldn't be, outliers)
func _filter_bad_data(grid: Array) -> void:
	# Pass 1: detect zeros that are likely errors (surrounded by high values)
	for iz in GRID_RES:
		for ix in GRID_RES:
			if absf(grid[iz][ix]) < 0.1:
				# Check if neighbors have significantly higher values
				var neighbor_sum := 0.0
				var neighbor_count := 0
				for dz in range(-1, 2):
					for dx in range(-1, 2):
						if dz == 0 and dx == 0:
							continue
						var nz := iz + dz
						var nx := ix + dx
						if nz >= 0 and nz < GRID_RES and nx >= 0 and nx < GRID_RES:
							var nv: float = grid[nz][nx]
							if absf(nv) > 0.1:
								neighbor_sum += nv
								neighbor_count += 1
				if neighbor_count > 0:
					var avg := neighbor_sum / neighbor_count
					if absf(avg) > 50.0:
						# Zero surrounded by high values — likely data error
						print("ELEV: Filtered zero at [%d][%d], replaced with %.1f" % [iz, ix, avg])
						grid[iz][ix] = avg
