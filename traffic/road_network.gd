extends Node
class_name RoadNetwork

## Система навигации по дорогам для NPC-машин
## Хранит waypoints и связи между ними для pathfinding

class Waypoint:
	var position: Vector3
	var direction: Vector3  # Направление движения (нормализованный вектор)
	var speed_limit: float  # Лимит скорости в км/ч
	var width: float  # Ширина дороги в метрах
	var lanes_count: int  # Количество полос В ОДНОМ направлении (1 или 2)
	var next_waypoints: Array[Waypoint] = []  # Связи с следующими точками
	var chunk_key: String  # Ключ чанка для cleanup

	func _init(pos: Vector3, dir: Vector3, speed: float, w: float, lanes: int, chunk: String):
		position = pos
		direction = dir.normalized()
		speed_limit = speed
		width = w
		lanes_count = lanes
		chunk_key = chunk

# Хранение waypoints по чанкам
var waypoints_by_chunk: Dictionary = {}  # "x,z" -> Array[Waypoint]
var all_waypoints: Array[Waypoint] = []

# Пространственный индекс для быстрого поиска пересечений
var _spatial_grid: Dictionary = {}  # "gx,gz" -> Array[Waypoint]
const GRID_CELL_SIZE := 20.0  # Размер ячейки сетки в метрах

# Константы
const WAYPOINT_SPACING := 8.0  # Расстояние между waypoints в метрах
const INTERSECTION_THRESHOLD := 8.0  # Расстояние для определения пересечений
const RIGHT_SIDE_OFFSET := 0.75  # Смещение вправо (75% от половины ширины дороги для встречного движения)
const CHUNK_SIZE := 300.0  # Размер чанка в метрах (должен совпадать с osm_terrain_generator)

# Speed limits по типам дорог (км/ч)
const SPEED_LIMITS := {
	"motorway": 50.0,
	"trunk": 50.0,
	"primary": 40.0,
	"secondary": 30.0,
	"tertiary": 25.0,
	"residential": 25.0,
	"unclassified": 20.0,
	"service": 15.0,
	"footway": 10.0,
	"path": 10.0,
	"cycleway": 15.0,
	"track": 20.0,
}


func add_road_segment(points: PackedVector2Array, highway_type: String, _chunk_key: String, elev_data: Dictionary) -> void:
	"""Добавляет дорожный сегмент в навигационную сеть
	Примечание: _chunk_key не используется, каждый waypoint определяет свой чанк по позиции
	Создаёт waypoints в ОБОИХ направлениях для двустороннего движения"""
	if points.size() < 2:
		return

	# Только крупные дороги - не дворы и сервисные проезды
	const VEHICLE_ROADS := ["motorway", "trunk", "primary", "secondary", "tertiary"]
	if not highway_type in VEHICLE_ROADS:
		return  # Пропускаем residential, service, footway и т.д.

	# Получаем параметры дороги
	var speed_limit: float = SPEED_LIMITS.get(highway_type, 25.0)
	var width: float = _get_road_width(highway_type)
	var lanes: int = _get_lanes_per_direction(highway_type)

	# Создаём waypoints в прямом направлении
	var forward_waypoints := _create_directional_waypoints(points, elev_data, speed_limit, width, lanes, false)

	# Создаём waypoints в обратном направлении
	var reverse_waypoints := _create_directional_waypoints(points, elev_data, speed_limit, width, lanes, true)

	# Проверяем пересечения с другими дорогами для создания связей
	# Важно: проверяем каждое направление отдельно, чтобы не связывать forward и reverse между собой
	_connect_intersections_fast(forward_waypoints)
	_connect_intersections_fast(reverse_waypoints)


func _create_directional_waypoints(points: PackedVector2Array, elev_data: Dictionary, speed_limit: float, width: float, lanes: int, reverse: bool) -> Array[Waypoint]:
	"""Создаёт waypoints вдоль дороги в одном направлении"""
	var all_road_waypoints: Array[Waypoint] = []
	var prev_segment_last: Waypoint = null

	# Определяем порядок обхода точек
	var start_idx: int
	var end_idx: int
	var step: int
	if reverse:
		start_idx = points.size() - 1
		end_idx = 0
		step = -1
	else:
		start_idx = 0
		end_idx = points.size() - 1
		step = 1

	# Генерируем waypoints вдоль дороги
	var i := start_idx
	while (step > 0 and i < end_idx) or (step < 0 and i > end_idx):
		var start_2d := points[i]
		var end_2d := points[i + step]

		# Получаем высоты
		var start_height := _get_elevation_at_point(start_2d, elev_data)
		var end_height := _get_elevation_at_point(end_2d, elev_data)

		var start_pos := Vector3(start_2d.x, start_height, start_2d.y)
		var end_pos := Vector3(end_2d.x, end_height, end_2d.y)

		var segment_length := start_pos.distance_to(end_pos)
		var direction := (end_pos - start_pos).normalized()

		# Создаём waypoints ПО ЦЕНТРУ дороги
		# Машины сами будут смещаться вправо при следовании по пути
		# Минимум 2 waypoints чтобы избежать деления на 0 в интерполяции
		var num_waypoints: int = max(2, int(ceil(segment_length / WAYPOINT_SPACING)))

		var segment_waypoints: Array[Waypoint] = []

		for j in range(num_waypoints):
			var t := float(j) / float(num_waypoints - 1)
			var pos := start_pos.lerp(end_pos, t)

			# Определяем chunk_key для этого waypoint на основе его позиции
			var wp_chunk_key := _get_chunk_key_for_position(pos)

			var waypoint := Waypoint.new(pos, direction, speed_limit, width, lanes, wp_chunk_key)
			segment_waypoints.append(waypoint)
			all_road_waypoints.append(waypoint)
			all_waypoints.append(waypoint)

			# Добавляем в правильный чанк по позиции waypoint
			if not waypoints_by_chunk.has(wp_chunk_key):
				waypoints_by_chunk[wp_chunk_key] = []
			waypoints_by_chunk[wp_chunk_key].append(waypoint)

			# Добавляем в пространственный индекс
			_add_to_spatial_grid(waypoint)

		# Связываем waypoints внутри сегмента
		for j in range(segment_waypoints.size() - 1):
			segment_waypoints[j].next_waypoints.append(segment_waypoints[j + 1])

		# Связываем с предыдущим сегментом
		if prev_segment_last != null and segment_waypoints.size() > 0:
			prev_segment_last.next_waypoints.append(segment_waypoints[0])

		# Запоминаем последний waypoint для связи со следующим сегментом
		if segment_waypoints.size() > 0:
			prev_segment_last = segment_waypoints[segment_waypoints.size() - 1]

		i += step

	return all_road_waypoints


## Получает ключ чанка по позиции waypoint
func _get_chunk_key_for_position(pos: Vector3) -> String:
	var cx := int(floor(pos.x / CHUNK_SIZE))
	var cz := int(floor(pos.z / CHUNK_SIZE))
	return "%d,%d" % [cx, cz]


## Получает ключ ячейки пространственной сетки
func _get_grid_key(pos: Vector3) -> String:
	var gx := int(floor(pos.x / GRID_CELL_SIZE))
	var gz := int(floor(pos.z / GRID_CELL_SIZE))
	return "%d,%d" % [gx, gz]


## Добавляет waypoint в пространственный индекс
func _add_to_spatial_grid(waypoint: Waypoint) -> void:
	var key := _get_grid_key(waypoint.position)
	if not _spatial_grid.has(key):
		_spatial_grid[key] = []
	_spatial_grid[key].append(waypoint)


## Получает waypoints в соседних ячейках
func _get_nearby_waypoints(pos: Vector3) -> Array:
	var result := []
	var gx := int(floor(pos.x / GRID_CELL_SIZE))
	var gz := int(floor(pos.z / GRID_CELL_SIZE))

	# Проверяем 9 ячеек (текущая + 8 соседних)
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var key := "%d,%d" % [gx + dx, gz + dz]
			if _spatial_grid.has(key):
				result.append_array(_spatial_grid[key])
	return result


## Быстрый поиск пересечений с использованием пространственного индекса
func _connect_intersections_fast(new_waypoints: Array) -> void:
	"""Находит пересечения используя пространственный индекс O(1) вместо O(n)
	Связывает только waypoints с близким направлением (не встречные)"""
	# Проверяем только концы сегмента
	var endpoints := []
	if new_waypoints.size() > 0:
		endpoints.append(new_waypoints[0])
	if new_waypoints.size() > 1:
		endpoints.append(new_waypoints[new_waypoints.size() - 1])

	for new_wp in endpoints:
		# Ищем только в соседних ячейках
		var nearby := _get_nearby_waypoints(new_wp.position)

		for existing_wp in nearby:
			if existing_wp == new_wp:
				continue
			if existing_wp in new_waypoints:
				continue

			var distance: float = new_wp.position.distance_to(existing_wp.position)

			if distance < INTERSECTION_THRESHOLD:
				# Проверяем что направления не противоположные (dot > 0 = схожее направление)
				# Это предотвращает связывание встречных полос
				var dir_dot: float = new_wp.direction.dot(existing_wp.direction)
				if dir_dot < -0.3:  # Почти противоположные направления - не связываем
					continue

				if not new_wp.next_waypoints.has(existing_wp):
					new_wp.next_waypoints.append(existing_wp)
				if not existing_wp.next_waypoints.has(new_wp):
					existing_wp.next_waypoints.append(new_wp)


func get_nearest_waypoint(position: Vector3) -> Waypoint:
	"""Находит ближайший waypoint к заданной позиции используя пространственный индекс"""
	if all_waypoints.is_empty():
		return null

	# Сначала ищем в соседних ячейках (быстрый путь)
	var nearby := _get_nearby_waypoints(position)
	if not nearby.is_empty():
		var nearest: Waypoint = null
		var min_distance_sq := INF

		for wp in nearby:
			var dist_sq := position.distance_squared_to(wp.position)
			if dist_sq < min_distance_sq:
				min_distance_sq = dist_sq
				nearest = wp

		if nearest:
			return nearest

	# Fallback - полный поиск (редко должен срабатывать)
	var nearest: Waypoint = null
	var min_distance_sq := INF

	for wp in all_waypoints:
		var dist_sq := position.distance_squared_to(wp.position)
		if dist_sq < min_distance_sq:
			min_distance_sq = dist_sq
			nearest = wp

	return nearest


func get_waypoints_in_radius(position: Vector3, radius: float) -> Array:
	"""Возвращает все waypoints в заданном радиусе от позиции"""
	var result: Array = []
	var radius_sq := radius * radius

	# Используем пространственный индекс для ускорения поиска
	# Определяем сколько ячеек нужно проверить
	var cells_to_check := int(ceil(radius / GRID_CELL_SIZE)) + 1
	var gx := int(floor(position.x / GRID_CELL_SIZE))
	var gz := int(floor(position.z / GRID_CELL_SIZE))

	for dx in range(-cells_to_check, cells_to_check + 1):
		for dz in range(-cells_to_check, cells_to_check + 1):
			var key := "%d,%d" % [gx + dx, gz + dz]
			if _spatial_grid.has(key):
				for wp in _spatial_grid[key]:
					if position.distance_squared_to(wp.position) <= radius_sq:
						result.append(wp)

	return result


func get_waypoints_in_chunk(chunk_key: String) -> Array:
	"""Возвращает все waypoints в указанном чанке"""
	return waypoints_by_chunk.get(chunk_key, [])


func clear_chunk(chunk_key: String) -> void:
	"""Удаляет все waypoints из чанка"""
	if not waypoints_by_chunk.has(chunk_key):
		return

	var chunk_waypoints: Array = waypoints_by_chunk[chunk_key]

	# Удаляем связи с этими waypoints
	for wp in chunk_waypoints:
		all_waypoints.erase(wp)

		# Удаляем из пространственного индекса
		var grid_key := _get_grid_key(wp.position)
		if _spatial_grid.has(grid_key):
			_spatial_grid[grid_key].erase(wp)
			# Удаляем пустые ячейки
			if _spatial_grid[grid_key].is_empty():
				_spatial_grid.erase(grid_key)

		# Удаляем связи от других waypoints к удаляемым
		for other_wp in all_waypoints:
			other_wp.next_waypoints.erase(wp)

	waypoints_by_chunk.erase(chunk_key)


func _get_road_width(highway_type: String) -> float:
	"""Получает ширину дороги по типу"""
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
	return ROAD_WIDTHS.get(highway_type, 6.0)


func _get_lanes_per_direction(highway_type: String) -> int:
	"""Получает количество полос в одном направлении (должно совпадать с текстурой)"""
	# Синхронизировано с osm_terrain_generator.gd:
	# motorway, trunk, primary, secondary - используют текстуру с 4 полосами (highway/primary)
	# tertiary, residential и меньше - используют текстуру с 2 полосами (residential)
	match highway_type:
		"motorway", "trunk", "primary", "secondary":
			return 2  # 2 полосы в каждом направлении (4 всего)
		_:
			return 1  # 1 полоса в каждом направлении (2 всего)


func _get_elevation_at_point(point: Vector2, elev_data: Dictionary) -> float:
	"""Получает высоту в точке (из elevation data или 0)"""
	if elev_data.is_empty():
		return 0.0

	# Интерполяция из сетки высот
	var grid_size: int = elev_data.get("grid_size", 16)
	var chunk_size: float = elev_data.get("chunk_size", 300.0)
	var elevations: Array = elev_data.get("elevations", [])

	if elevations.is_empty():
		return 0.0

	# Нормализуем координаты к сетке [0..grid_size-1]
	var normalized_x := (point.x / chunk_size + 0.5) * float(grid_size - 1)
	var normalized_y := (point.y / chunk_size + 0.5) * float(grid_size - 1)

	normalized_x = clamp(normalized_x, 0, grid_size - 1)
	normalized_y = clamp(normalized_y, 0, grid_size - 1)

	var x0: int = int(normalized_x)
	var y0: int = int(normalized_y)
	var x1: int = min(x0 + 1, grid_size - 1)
	var y1: int = min(y0 + 1, grid_size - 1)

	# Билинейная интерполяция
	var fx: float = normalized_x - x0
	var fy: float = normalized_y - y0

	# Проверяем что индексы в пределах массива
	var idx00: int = y0 * grid_size + x0
	var idx10: int = y0 * grid_size + x1
	var idx01: int = y1 * grid_size + x0
	var idx11: int = y1 * grid_size + x1
	var max_idx: int = elevations.size() - 1

	if idx00 > max_idx or idx10 > max_idx or idx01 > max_idx or idx11 > max_idx:
		return 0.0  # Fallback если данные некорректны

	var h00: float = elevations[idx00]
	var h10: float = elevations[idx10]
	var h01: float = elevations[idx01]
	var h11: float = elevations[idx11]

	var h0: float = lerp(h00, h10, fx)
	var h1: float = lerp(h01, h11, fx)

	return lerp(h0, h1, fy)


func get_debug_info() -> String:
	"""Возвращает отладочную информацию о сети"""
	var chunk_count := waypoints_by_chunk.size()
	var waypoint_count := all_waypoints.size()
	var connection_count := 0

	for wp in all_waypoints:
		connection_count += wp.next_waypoints.size()

	return "RoadNetwork: %d chunks, %d waypoints, %d connections" % [chunk_count, waypoint_count, connection_count]
