extends Node
class_name ElevationLoader

signal elevation_loaded(elevation_data: Dictionary)
signal elevation_failed(error: String)

const OPEN_ELEVATION_API := "https://api.open-elevation.com/api/v1/lookup"
const CACHE_DIR := "user://elevation_cache/"

var http_request: HTTPRequest
var _pending_locations: Array = []
var _grid_size: int = 0
var _center_lat: float = 0.0
var _center_lon: float = 0.0
var _radius: float = 0.0

func _ready() -> void:
	http_request = HTTPRequest.new()
	add_child(http_request)
	http_request.request_completed.connect(_on_request_completed)
	# Создаём папку кеша если не существует
	DirAccess.make_dir_recursive_absolute(CACHE_DIR)

# Генерирует ключ кеша для заданных параметров
func _get_cache_key(lat: float, lon: float, radius: float, grid_resolution: int) -> String:
	# Округляем координаты для стабильного ключа
	var lat_key := "%.5f" % lat
	var lon_key := "%.5f" % lon
	var rad_key := "%.0f" % radius
	return "elev_%s_%s_%s_%d.json" % [lat_key, lon_key, rad_key, grid_resolution]

# Загружает данные из кеша если есть
func _load_from_cache(cache_key: String) -> Dictionary:
	var cache_path := CACHE_DIR + cache_key
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

# Сохраняет данные в кеш
func _save_to_cache(cache_key: String, data: Dictionary) -> void:
	var cache_path := CACHE_DIR + cache_key
	var file := FileAccess.open(cache_path, FileAccess.WRITE)
	if not file:
		print("Elevation: Failed to save cache to %s" % cache_path)
		return

	file.store_string(JSON.stringify(data))
	file.close()
	print("Elevation: Cached to %s" % cache_key)

# Загружает высоты для сетки точек вокруг центра
func load_elevation_grid(lat: float, lon: float, radius: float, grid_resolution: int = 10) -> void:
	_center_lat = lat
	_center_lon = lon
	_grid_size = grid_resolution
	_radius = radius
	_pending_locations.clear()

	# Проверяем кеш
	var cache_key := _get_cache_key(lat, lon, radius, grid_resolution)
	var cached_data := _load_from_cache(cache_key)
	if not cached_data.is_empty():
		print("Elevation: Loaded from cache %s" % cache_key)
		elevation_loaded.emit(cached_data)
		return

	# Конвертируем радиус в градусы
	var lat_delta := radius / 111000.0
	var lon_delta := radius / (111000.0 * cos(deg_to_rad(lat)))

	# Создаём сетку точек
	var locations: Array = []
	for y in range(grid_resolution):
		for x in range(grid_resolution):
			var point_lat := lat - lat_delta + (2.0 * lat_delta * y / (grid_resolution - 1))
			var point_lon := lon - lon_delta + (2.0 * lon_delta * x / (grid_resolution - 1))
			locations.append({"latitude": point_lat, "longitude": point_lon})
			_pending_locations.append({"lat": point_lat, "lon": point_lon})

	# Формируем JSON запрос
	var request_body := JSON.stringify({"locations": locations})
	var headers := ["Content-Type: application/json", "Accept: application/json"]

	print("Elevation: Requesting %d points from API..." % locations.size())
	var error := http_request.request(OPEN_ELEVATION_API, headers, HTTPClient.METHOD_POST, request_body)

	if error != OK:
		elevation_failed.emit("HTTP request failed: " + str(error))

func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		elevation_failed.emit("Request failed with result: " + str(result))
		return

	if response_code != 200:
		elevation_failed.emit("HTTP error: " + str(response_code))
		return

	var json_string := body.get_string_from_utf8()
	var json := JSON.new()
	var parse_result := json.parse(json_string)

	if parse_result != OK:
		elevation_failed.emit("JSON parse error: " + json.get_error_message())
		return

	var data: Dictionary = json.data
	var results: Array = data.get("results", [])

	if results.size() != _pending_locations.size():
		elevation_failed.emit("Unexpected results count: %d vs %d" % [results.size(), _pending_locations.size()])
		return

	# Создаём карту высот
	var elevation_grid: Array = []
	elevation_grid.resize(_grid_size)

	for y in range(_grid_size):
		var row: Array = []
		row.resize(_grid_size)
		for x in range(_grid_size):
			var idx := y * _grid_size + x
			var elevation: float = results[idx].get("elevation", 0.0)
			row[x] = elevation
		elevation_grid[y] = row

	# Применяем гауссово сглаживание для плавного рельефа
	elevation_grid = _apply_gaussian_blur(elevation_grid, _grid_size, 1.5)

	# Находим мин/макс после сглаживания
	var min_elev := 99999.0
	var max_elev := -99999.0
	for row in elevation_grid:
		for elev in row:
			min_elev = min(min_elev, elev)
			max_elev = max(max_elev, elev)

	print("Elevation: Loaded grid %dx%d, range %.1f - %.1f m (smoothed)" % [_grid_size, _grid_size, min_elev, max_elev])

	var elev_data := {
		"grid": elevation_grid,
		"grid_size": _grid_size,
		"center_lat": _center_lat,
		"center_lon": _center_lon,
		"min_elevation": min_elev,
		"max_elevation": max_elev
	}

	# Сохраняем в кеш
	var cache_key := _get_cache_key(_center_lat, _center_lon, _radius, _grid_size)
	_save_to_cache(cache_key, elev_data)

	elevation_loaded.emit(elev_data)

# Применяет гауссово размытие к сетке высот
static func _apply_gaussian_blur(grid: Array, grid_size: int, sigma: float) -> Array:
	# Создаём гауссово ядро 5x5
	var kernel_size := 5
	var kernel: Array = []
	var kernel_sum := 0.0
	var half := kernel_size / 2

	for y in range(kernel_size):
		var row: Array = []
		for x in range(kernel_size):
			var dx := x - half
			var dy := y - half
			var value := exp(-(dx * dx + dy * dy) / (2.0 * sigma * sigma))
			row.append(value)
			kernel_sum += value
		kernel.append(row)

	# Нормализуем ядро
	for y in range(kernel_size):
		for x in range(kernel_size):
			kernel[y][x] /= kernel_sum

	# Применяем свёртку
	var result: Array = []
	result.resize(grid_size)

	for z in range(grid_size):
		var row: Array = []
		row.resize(grid_size)
		for x in range(grid_size):
			var sum := 0.0
			for ky in range(kernel_size):
				for kx in range(kernel_size):
					var sx := clampi(x + kx - half, 0, grid_size - 1)
					var sz := clampi(z + ky - half, 0, grid_size - 1)
					sum += float(grid[sz][sx]) * kernel[ky][kx]
			row[x] = sum
		result[z] = row

	return result

# Интерполирует высоту для произвольной точки на основе сетки
static func interpolate_elevation(grid: Array, grid_size: int, x_norm: float, z_norm: float) -> float:
	# x_norm и z_norm от 0 до 1
	var fx: float = clamp(x_norm * (grid_size - 1), 0.0, float(grid_size - 1))
	var fz: float = clamp(z_norm * (grid_size - 1), 0.0, float(grid_size - 1))

	var x0: int = int(floor(fx))
	var z0: int = int(floor(fz))
	var x1: int = mini(x0 + 1, grid_size - 1)
	var z1: int = mini(z0 + 1, grid_size - 1)

	var tx: float = fx - x0
	var tz: float = fz - z0

	# Билинейная интерполяция
	var h00: float = float(grid[z0][x0])
	var h10: float = float(grid[z0][x1])
	var h01: float = float(grid[z1][x0])
	var h11: float = float(grid[z1][x1])

	var h0: float = lerpf(h00, h10, tx)
	var h1: float = lerpf(h01, h11, tx)

	return lerpf(h0, h1, tz)
