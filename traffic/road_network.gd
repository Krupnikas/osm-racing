extends Node
class_name RoadNetwork

## Система навигации по дорогам для NPC-машин
## Хранит waypoints и связи между ними для pathfinding

class Waypoint:
	var position: Vector3
	var direction: Vector3  # Направление движения (нормализованный вектор)
	var speed_limit: float  # Лимит скорости в км/ч
	var width: float  # Ширина дороги в метрах
	var next_waypoints: Array[Waypoint] = []  # Связи с следующими точками
	var chunk_key: String  # Ключ чанка для cleanup

	func _init(pos: Vector3, dir: Vector3, speed: float, w: float, chunk: String):
		position = pos
		direction = dir.normalized()
		speed_limit = speed
		width = w
		chunk_key = chunk

# Хранение waypoints по чанкам
var waypoints_by_chunk: Dictionary = {}  # "x,z" -> Array[Waypoint]
var all_waypoints: Array[Waypoint] = []

# Константы
const WAYPOINT_SPACING := 4.0  # Расстояние между waypoints в метрах (было 8.0, изначально 15.0)
const INTERSECTION_THRESHOLD := 8.0  # Расстояние для определения пересечений
const RIGHT_SIDE_OFFSET := 0.75  # Смещение вправо (75% от половины ширины дороги для встречного движения)

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


func add_road_segment(points: PackedVector2Array, highway_type: String, chunk_key: String, elev_data: Dictionary) -> void:
	"""Добавляет дорожный сегмент в навигационную сеть"""
	if points.size() < 2:
		return

	# Только крупные дороги - не дворы и сервисные проезды
	const VEHICLE_ROADS := ["motorway", "trunk", "primary", "secondary", "tertiary"]
	if not highway_type in VEHICLE_ROADS:
		return  # Пропускаем residential, service, footway и т.д.

	print("RoadNetwork: Adding %s road in chunk %s (%d points)" % [highway_type, chunk_key, points.size()])

	# Получаем параметры дороги
	var speed_limit: float = SPEED_LIMITS.get(highway_type, 25.0)
	var width: float = _get_road_width(highway_type)

	# Создаём массив waypoints для этого чанка
	if not waypoints_by_chunk.has(chunk_key):
		waypoints_by_chunk[chunk_key] = []

	var segment_waypoints: Array[Waypoint] = []

	# Генерируем waypoints вдоль дороги
	var i := 0
	while i < points.size() - 1:
		var start_2d := points[i]
		var end_2d := points[i + 1]

		# Получаем высоты
		var start_height := _get_elevation_at_point(start_2d, elev_data)
		var end_height := _get_elevation_at_point(end_2d, elev_data)

		var start_pos := Vector3(start_2d.x, start_height, start_2d.y)
		var end_pos := Vector3(end_2d.x, end_height, end_2d.y)

		var segment_length := start_pos.distance_to(end_pos)
		var direction := (end_pos - start_pos).normalized()

		# Создаём waypoints ПО ЦЕНТРУ дороги
		# Машины сами будут смещаться вправо при следовании по пути
		var num_waypoints: int = max(2, int(segment_length / WAYPOINT_SPACING))

		for j in range(num_waypoints):
			var t := float(j) / float(num_waypoints - 1)
			var pos := start_pos.lerp(end_pos, t)

			var waypoint := Waypoint.new(pos, direction, speed_limit, width, chunk_key)
			segment_waypoints.append(waypoint)
			all_waypoints.append(waypoint)
			waypoints_by_chunk[chunk_key].append(waypoint)

		# Связываем waypoints последовательно
		for j in range(segment_waypoints.size() - 1):
			segment_waypoints[j].next_waypoints.append(segment_waypoints[j + 1])

		i += 1

	# Проверяем пересечения с другими дорогами для создания связей
	_connect_intersections(segment_waypoints)


func _connect_intersections(new_waypoints: Array) -> void:
	"""Находит пересечения дорог и создаёт связи между waypoints"""
	for new_wp in new_waypoints:
		for existing_wp in all_waypoints:
			if existing_wp == new_wp:
				continue

			var distance: float = new_wp.position.distance_to(existing_wp.position)

			# Если waypoints близко друг к другу - это пересечение
			if distance < INTERSECTION_THRESHOLD:
				# Создаём двусторонние связи
				if not new_wp.next_waypoints.has(existing_wp):
					new_wp.next_waypoints.append(existing_wp)
				if not existing_wp.next_waypoints.has(new_wp):
					existing_wp.next_waypoints.append(new_wp)


func get_nearest_waypoint(position: Vector3) -> Waypoint:
	"""Находит ближайший waypoint к заданной позиции"""
	if all_waypoints.is_empty():
		return null

	var nearest: Waypoint = null
	var min_distance := INF

	for wp in all_waypoints:
		var distance := position.distance_to(wp.position)
		if distance < min_distance:
			min_distance = distance
			nearest = wp

	return nearest


func get_waypoints_in_radius(position: Vector3, radius: float) -> Array:
	"""Возвращает все waypoints в заданном радиусе от позиции"""
	var result: Array = []

	for wp in all_waypoints:
		if position.distance_to(wp.position) <= radius:
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

	var h00: float = elevations[y0 * grid_size + x0]
	var h10: float = elevations[y0 * grid_size + x1]
	var h01: float = elevations[y1 * grid_size + x0]
	var h11: float = elevations[y1 * grid_size + x1]

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
