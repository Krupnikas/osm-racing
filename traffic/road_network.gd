extends Node
class_name RoadNetwork

## Система навигации по дорогам для NPC-машин
## Хранит waypoints и связи между ними для pathfinding

class Waypoint:
	var position: Vector3
	var direction: Vector3  # Направление движения (нормализованный вектор)
	var speed_limit: float  # Лимит скорости в км/ч
	var width: float  # Ширина проезжей части этого направления в метрах
	var lanes_count: int  # Количество полос на этом way
	var is_oneway: bool  # true = OSM oneway way (center = center of carriageway)
	var is_bridge: bool  # waypoint на мосту (рейкаст для высоты не нужен)
	var next_waypoints: Array[Waypoint] = []
	var prev_waypoints: Array[Waypoint] = []
	var chunk_key: String
	var road_id: int

	func _init(pos: Vector3, dir: Vector3, speed: float, w: float, lanes: int, chunk: String, rid: int = 0):
		position = pos
		direction = dir.normalized()
		speed_limit = speed
		width = w
		lanes_count = lanes
		chunk_key = chunk
		road_id = rid
		is_oneway = false
		is_bridge = false

# Хранение waypoints по чанкам
var waypoints_by_chunk: Dictionary = {}  # "x,z" -> Array[Waypoint]
var all_waypoints: Array[Waypoint] = []

# Tram waypoints — separate network, never connects to roads
var tram_waypoints_by_chunk: Dictionary = {}  # "x,z" -> Array[Waypoint]
var all_tram_waypoints: Array[Waypoint] = []

# Ссылка на terrain generator для получения высот
var terrain_generator: Node = null

# Пространственный индекс для быстрого поиска пересечений
var _spatial_grid: Dictionary = {}  # "gx,gz" -> Array[Waypoint]
const GRID_CELL_SIZE := 20.0  # Размер ячейки сетки в метрах

# Счётчик для уникальных ID дорог
var _next_road_id: int = 0

# Отложенное соединение перекрёстков (порционно по кадрам)
var _pending_connections: Array = []  # Массивы вейпоинтов, ожидающих соединения
var _current_connect_batch: Array = []  # Текущий батч для обработки
var _current_connect_index: int = 0  # Индекс в текущем батче (фаза 2)

# Tram connections (separate from road connections)
var _pending_tram_connections: Array = []
var _tram_spatial_grid: Dictionary = {}  # Separate spatial grid for tram waypoints

# Tram stop positions (world coordinates) for tram stopping behavior
var tram_stop_positions: Array[Vector3] = []

# Константы
const WAYPOINT_SPACING := 8.0  # Расстояние между waypoints в метрах
const INTERSECTION_THRESHOLD := 8.0  # Расстояние для определения пересечений
const RIGHT_SIDE_OFFSET := 0.75  # Смещение вправо (75% от половины ширины дороги для встречного движения)
const CHUNK_SIZE := 300.0  # Размер чанка в метрах (должен совпадать с osm_terrain_generator)
const LANE_WIDTH := 3.5  # Стандартная ширина полосы (метры)

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


func add_road_segment(points: PackedVector2Array, highway_type: String, _chunk_key: String, bridge_info: Dictionary = {}, oneway: String = "", tags: Dictionary = {}) -> void:
	"""Добавляет дорожный сегмент в навигационную сеть
	Примечание: _chunk_key не используется, каждый waypoint определяет свой чанк по позиции
	oneway: "" или "no" = оба направления, "yes" = по порядку нод, "-1" = против порядка нод
	bridge_info содержит информацию о мосте: is_bridge, bridge_height, ramp_length"""
	if points.size() < 2:
		return

	# Только крупные дороги - не дворы и сервисные проезды
	const VEHICLE_ROADS := ["motorway", "trunk", "primary", "secondary", "tertiary"]
	if not highway_type in VEHICLE_ROADS:
		return  # Пропускаем residential, service, footway и т.д.

	var is_oneway_forward: bool = oneway == "yes" or oneway == "true" or oneway == "1"
	var is_oneway_reverse: bool = oneway == "-1" or oneway == "reverse"
	var is_bidirectional: bool = not is_oneway_forward and not is_oneway_reverse
	var is_oneway: bool = not is_bidirectional

	# Получаем параметры дороги
	var speed_limit: float = SPEED_LIMITS.get(highway_type, 25.0)

	# Количество полос из OSM тегов
	var osm_lanes: int = 0
	var lanes_str: String = str(tags.get("lanes", ""))
	if lanes_str.is_valid_int():
		osm_lanes = int(lanes_str)

	var lanes: int  # полосы на этом way (для NPC lane offset)
	var width: float  # ширина проезжей части этого направления

	if is_oneway:
		# Oneway: OSM way = одна проезжая часть. Все полосы принадлежат этому направлению.
		if osm_lanes > 0:
			lanes = max(1, osm_lanes)
			width = float(lanes) * LANE_WIDTH
		else:
			lanes = _get_lanes_per_direction(highway_type)
			width = float(lanes) * LANE_WIDTH
	else:
		# Bidirectional: OSM way = центр всей дороги. NPC смещается на правую половину.
		if osm_lanes > 0:
			lanes = max(1, osm_lanes / 2)
		else:
			lanes = _get_lanes_per_direction(highway_type)
		width = _get_road_width(highway_type)

	# Уникальный ID для этой дороги
	var road_id := _next_road_id
	_next_road_id += 1

	# Создаём waypoints
	var forward_waypoints: Array[Waypoint] = []
	if is_bidirectional or is_oneway_forward:
		forward_waypoints = _create_directional_waypoints(points, speed_limit, width, lanes, false, road_id, bridge_info)
		if is_oneway:
			for wp in forward_waypoints:
				wp.is_oneway = true

	var reverse_waypoints: Array[Waypoint] = []
	if is_bidirectional or is_oneway_reverse:
		reverse_waypoints = _create_directional_waypoints(points, speed_limit, width, lanes, true, road_id, bridge_info)
		if is_oneway:
			for wp in reverse_waypoints:
				wp.is_oneway = true

	# Замыкаем кольцевые дороги (последняя точка совпадает с первой)
	if points.size() >= 3:
		var first_2d := points[0]
		var last_2d := points[points.size() - 1]
		if first_2d.distance_to(last_2d) < 1.0:
			if not forward_waypoints.is_empty():
				_close_loop(forward_waypoints)
			if not reverse_waypoints.is_empty():
				_close_loop(reverse_waypoints)

	# Откладываем соединение перекрёстков — порционно по кадрам через process_pending_connections()
	if not forward_waypoints.is_empty():
		_pending_connections.append(forward_waypoints)
	if not reverse_waypoints.is_empty():
		_pending_connections.append(reverse_waypoints)


func add_tram_segment(points: PackedVector2Array, chunk_key: String) -> void:
	"""Добавляет трамвайный сегмент в отдельную сеть (только прямое направление по OSM node order)"""
	if points.size() < 2:
		return
	var speed_limit := 40.0  # км/ч
	var width := 3.0
	var road_id := _next_road_id
	_next_road_id += 1
	# Tram tracks are always one-way (OSM node order = travel direction)
	var waypoints: Array[Waypoint] = _create_directional_waypoints(points, speed_limit, width, 1, false, road_id, {}, true)
	if waypoints.is_empty():
		return
	# Store in tram-specific collections
	for wp in waypoints:
		var cx := int(floor(wp.position.x / CHUNK_SIZE))
		var cz := int(floor(wp.position.z / CHUNK_SIZE))
		var ck := "%d,%d" % [cx, cz]
		wp.chunk_key = ck
		if not tram_waypoints_by_chunk.has(ck):
			tram_waypoints_by_chunk[ck] = []
		tram_waypoints_by_chunk[ck].append(wp)
		all_tram_waypoints.append(wp)
		# Add to tram spatial grid (separate from road grid)
		var gx := int(floor(wp.position.x / GRID_CELL_SIZE))
		var gz := int(floor(wp.position.z / GRID_CELL_SIZE))
		var grid_key := "%d,%d" % [gx, gz]
		if not _tram_spatial_grid.has(grid_key):
			_tram_spatial_grid[grid_key] = []
		_tram_spatial_grid[grid_key].append(wp)
	# Close loop if circular track
	if points.size() >= 3 and points[0].distance_to(points[points.size() - 1]) < 1.0:
		_close_loop(waypoints)
	_pending_tram_connections.append(waypoints)


func get_tram_waypoints_in_chunk(chunk_key: String) -> Array:
	return tram_waypoints_by_chunk.get(chunk_key, [])


func _close_loop(waypoints: Array) -> void:
	"""Замыкает кольцевую дорогу: последний waypoint <-> первый"""
	if waypoints.size() < 3:
		return
	var last_wp: Waypoint = waypoints[waypoints.size() - 1]
	var first_wp: Waypoint = waypoints[0]
	if not last_wp.next_waypoints.has(first_wp):
		last_wp.next_waypoints.append(first_wp)
		first_wp.prev_waypoints.append(last_wp)


func _create_directional_waypoints(points: PackedVector2Array, speed_limit: float, width: float, lanes: int, reverse: bool, road_id: int = 0, bridge_info: Dictionary = {}, tram_only: bool = false) -> Array[Waypoint]:
	"""Создаёт waypoints вдоль дороги в одном направлении
	bridge_info содержит: is_bridge, bridge_height, ramp_length для расчёта высоты на мостах
	tram_only: если true, НЕ добавляет waypoints в road-коллекции (only returns array)"""
	var all_road_waypoints: Array[Waypoint] = []
	var prev_segment_last: Waypoint = null

	# Параметры моста
	var is_bridge: bool = bridge_info.get("is_bridge", false)
	var bridge_height: float = bridge_info.get("bridge_height", 0.0)
	var ramp_length: float = bridge_info.get("ramp_length", 0.0)

	# Вычисляем общую длину дороги для правильного расчёта рамп
	var total_road_length := 0.0
	if is_bridge:
		for k in range(points.size() - 1):
			var p1 := points[k]
			var p2 := points[k + 1]
			total_road_length += p1.distance_to(p2)

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

	# Отслеживаем пройденное расстояние для рамп моста
	var accumulated_distance := 0.0

	# Генерируем waypoints вдоль дороги
	var i := start_idx
	while (step > 0 and i < end_idx) or (step < 0 and i > end_idx):
		var start_2d := points[i]
		var end_2d := points[i + step]

		var start_height := 0.0
		var end_height := 0.0
		# For bridge roads, use get_surface_y which returns deck height when on a bridge polygon
		if is_bridge and terrain_generator and terrain_generator.has_method("get_surface_y"):
			start_height = terrain_generator.get_surface_y(start_2d.x, start_2d.y)
			end_height = terrain_generator.get_surface_y(end_2d.x, end_2d.y)
		elif terrain_generator and terrain_generator.has_method("_sample_elevation"):
			start_height = terrain_generator._sample_elevation(start_2d.x, start_2d.y)
			end_height = terrain_generator._sample_elevation(end_2d.x, end_2d.y)

		var start_pos := Vector3(start_2d.x, start_height, start_2d.y)
		var end_pos := Vector3(end_2d.x, end_height, end_2d.y)

		var segment_length := start_pos.distance_to(end_pos)
		# Защита от нулевого вектора при совпадающих точках
		if segment_length < 0.01:
			i += step
			continue
		var direction := (end_pos - start_pos).normalized()

		# Создаём waypoints ПО ЦЕНТРУ дороги
		# Машины сами будут смещаться вправо при следовании по пути
		# Минимум 2 waypoints чтобы избежать деления на 0 в интерполяции
		var num_waypoints: int = max(2, int(ceil(segment_length / WAYPOINT_SPACING)))

		var segment_waypoints: Array[Waypoint] = []

		# For bridge roads using get_surface_y, sample deck height per-waypoint
		var has_surface_y: bool = is_bridge and terrain_generator and terrain_generator.has_method("get_surface_y")
		var use_bridge_formula: bool = is_bridge and bridge_height > 0.0 and not has_surface_y

		for j in range(num_waypoints):
			var t := float(j) / float(num_waypoints - 1)
			var pos := start_pos.lerp(end_pos, t)

			if has_surface_y:
				# Sample actual deck/terrain height at this exact point
				pos.y = terrain_generator.get_surface_y(pos.x, pos.z)
			elif use_bridge_formula:
				# Fallback: generic bridge ramp formula
				var current_distance := accumulated_distance + t * segment_length
				var bridge_y := _calculate_bridge_height_at_distance(current_distance, total_road_length, bridge_height, ramp_length)
				pos.y += bridge_y

			# Определяем chunk_key для этого waypoint на основе его позиции
			var wp_chunk_key := _get_chunk_key_for_position(pos)

			var waypoint := Waypoint.new(pos, direction, speed_limit, width, lanes, wp_chunk_key, road_id)
			if is_bridge:
				waypoint.is_bridge = true
			segment_waypoints.append(waypoint)
			all_road_waypoints.append(waypoint)

			# Tram waypoints НЕ добавляются в road-коллекции —
			# их добавляет add_tram_segment в tram-коллекции
			if not tram_only:
				all_waypoints.append(waypoint)
				if not waypoints_by_chunk.has(wp_chunk_key):
					waypoints_by_chunk[wp_chunk_key] = []
				waypoints_by_chunk[wp_chunk_key].append(waypoint)
				_add_to_spatial_grid(waypoint)

		# Связываем waypoints внутри сегмента
		for j in range(segment_waypoints.size() - 1):
			segment_waypoints[j].next_waypoints.append(segment_waypoints[j + 1])
			segment_waypoints[j + 1].prev_waypoints.append(segment_waypoints[j])

		# Связываем с предыдущим сегментом
		if prev_segment_last != null and segment_waypoints.size() > 0:
			prev_segment_last.next_waypoints.append(segment_waypoints[0])
			segment_waypoints[0].prev_waypoints.append(prev_segment_last)

		# Запоминаем последний waypoint для связи со следующим сегментом
		if segment_waypoints.size() > 0:
			prev_segment_last = segment_waypoints[segment_waypoints.size() - 1]

		# Обновляем накопленное расстояние для рамп моста
		accumulated_distance += segment_length

		i += step

	return all_road_waypoints


## Вычисляет высоту на мосту с учётом плавных рамп подъёма/спуска
func _calculate_bridge_height_at_distance(distance: float, total_length: float, bridge_height: float, ramp_length: float) -> float:
	"""Возвращает Y-координату для точки на мосту.
	Рампы: smooth_step интерполяция от 0 до bridge_height на длине ramp_length.
	Плоская часть: bridge_height между рампами."""
	if total_length <= 0.0 or bridge_height <= 0.0:
		return 0.0

	# Безопасная длина рампы (не более 1/3 длины моста)
	var safe_ramp: float = minf(ramp_length, total_length / 3.0)

	if distance < safe_ramp:
		# Начальная рампа (подъём)
		var t: float = distance / safe_ramp
		return _smooth_step(t) * bridge_height
	elif distance > total_length - safe_ramp:
		# Конечная рампа (спуск)
		var t: float = (total_length - distance) / safe_ramp
		return _smooth_step(t) * bridge_height
	else:
		# Плоская часть моста
		return bridge_height


## Smooth step функция для плавных переходов (ease in-out)
func _smooth_step(t: float) -> float:
	t = clampf(t, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


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
	Связывает только waypoints с совместимым направлением для правостороннего движения.

	Ключевая проверка: машина поворачивающая с дороги A на дорогу B должна
	оказаться на ПРАВОЙ стороне дороги B (не на встречке).
	Для этого проверяем что existing_wp находится СПРАВА от направления new_wp."""

	if new_waypoints.is_empty():
		return

	var new_endpoints := [new_waypoints[0]]
	if new_waypoints.size() > 1:
		new_endpoints.append(new_waypoints[new_waypoints.size() - 1])

	# 1. Проверяем endpoints новой дороги против всех существующих waypoints
	for new_wp in new_endpoints:
		var nearby := _get_nearby_waypoints(new_wp.position)

		for existing_wp in nearby:
			if existing_wp == new_wp or existing_wp in new_waypoints:
				continue

			var distance: float = new_wp.position.distance_to(existing_wp.position)
			if distance >= INTERSECTION_THRESHOLD:
				continue

			# Пропускаем дубликаты (один OSM way загружен несколькими чанками)
			if _is_duplicate_waypoint(new_wp, existing_wp):
				continue

			# Проверяем совместимость направлений для правостороннего движения
			if _can_connect_waypoints(new_wp, existing_wp):
				if not new_wp.next_waypoints.has(existing_wp):
					new_wp.next_waypoints.append(existing_wp)
					existing_wp.prev_waypoints.append(new_wp)
			if _can_connect_waypoints(existing_wp, new_wp):
				if not existing_wp.next_waypoints.has(new_wp):
					existing_wp.next_waypoints.append(new_wp)
					new_wp.prev_waypoints.append(existing_wp)

	# 2. Проверяем ВСЕ waypoints новой дороги против "тупиков" (waypoints без next)
	#    Это нужно для T-образных перекрёстков где старая дорога заканчивается
	#    рядом с серединой новой дороги
	for new_wp in new_waypoints:
		var nearby := _get_nearby_waypoints(new_wp.position)

		for existing_wp in nearby:
			if existing_wp == new_wp or existing_wp in new_waypoints:
				continue

			# Проверяем только если existing_wp - тупик (нет следующих waypoints)
			if not existing_wp.next_waypoints.is_empty():
				continue

			var distance: float = new_wp.position.distance_to(existing_wp.position)
			if distance >= INTERSECTION_THRESHOLD:
				continue

			# Пропускаем дубликаты
			if _is_duplicate_waypoint(existing_wp, new_wp):
				continue

			# Связываем тупик с новой дорогой если направления совместимы
			if _can_connect_waypoints(existing_wp, new_wp):
				if not existing_wp.next_waypoints.has(new_wp):
					existing_wp.next_waypoints.append(new_wp)


## Проверяет являются ли два wp дубликатами (одна дорога загружена несколькими чанками)
## Дубликаты: близкое расстояние + почти одинаковое направление
func _is_duplicate_waypoint(wp_a: Waypoint, wp_b: Waypoint) -> bool:
	if wp_a.position.distance_to(wp_b.position) > 2.0:
		return false
	# Направления почти совпадают или почти противоположны = дубликат
	var dir_dot: float = abs(wp_a.direction.dot(wp_b.direction))
	return dir_dot > 0.9


## Проверяет можно ли создать связь from_wp -> to_wp для правостороннего движения
func _can_connect_waypoints(from_wp: Waypoint, to_wp: Waypoint) -> bool:
	"""Проверяет что переход from_wp -> to_wp валиден для правостороннего движения.

	Правила:
	1. НЕЛЬЗЯ связывать waypoints ОДНОЙ дороги (forward с reverse) - это встречка!
	2. Противоположные направления (разворот) - запрещено
	3. Одинаковые направления - разрешено (продолжение/слияние)
	4. Повороты - разрешены
	"""
	# КРИТИЧНО: waypoints одной дороги с противоположными направлениями = встречка!
	if from_wp.road_id == to_wp.road_id:
		return false

	var dir_dot: float = from_wp.direction.dot(to_wp.direction)

	# Противоположные направления - запрещено (разворот на 180°)
	if dir_dot < -0.3:
		return false

	# Всё остальное разрешено (прямо, слияние, повороты)
	return true


## Порционное соединение перекрёстков — вызывается каждый кадр из TrafficManager
func process_pending_connections(time_budget_usec: int) -> bool:
	"""Обрабатывает отложенные соединения перекрёстков порционно.
	Возвращает true если есть ещё работа, false если всё обработано."""
	if _pending_connections.is_empty() and _current_connect_batch.is_empty():
		return false

	var start := Time.get_ticks_usec()

	while true:
		# Нужен новый батч?
		if _current_connect_batch.is_empty():
			if _pending_connections.is_empty():
				return false
			_current_connect_batch = _pending_connections.pop_front()
			_current_connect_index = 0
			# Фаза 1: endpoints (быстро, делаем сразу)
			_connect_endpoints(_current_connect_batch)

		# Фаза 2: порционно проверяем все wp батча против тупиков
		while _current_connect_index < _current_connect_batch.size():
			var wp: Waypoint = _current_connect_batch[_current_connect_index]
			_connect_deadends_for(wp, _current_connect_batch)
			_current_connect_index += 1

			if Time.get_ticks_usec() - start > time_budget_usec:
				return true  # Есть ещё работа

		# Батч завершён
		_current_connect_batch = []
		_current_connect_index = 0

	# Process tram connections (tram↔tram only, using separate spatial grid)
	while not _pending_tram_connections.is_empty():
		if Time.get_ticks_usec() - start > time_budget_usec:
			return true
		var tram_batch: Array = _pending_tram_connections.pop_front()
		_connect_tram_endpoints(tram_batch)

	return false


func _connect_tram_endpoints(batch: Array) -> void:
	"""Connects tram track endpoints to nearby tram waypoints only"""
	if batch.is_empty():
		return
	var endpoints := [batch[0]]
	if batch.size() > 1:
		endpoints.append(batch[batch.size() - 1])
	for new_wp in endpoints:
		var gx := int(floor(new_wp.position.x / GRID_CELL_SIZE))
		var gz := int(floor(new_wp.position.z / GRID_CELL_SIZE))
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				var grid_key := "%d,%d" % [gx + dx, gz + dz]
				if not _tram_spatial_grid.has(grid_key):
					continue
				for existing_wp in _tram_spatial_grid[grid_key]:
					if existing_wp == new_wp or existing_wp in batch:
						continue
					var distance: float = new_wp.position.distance_to(existing_wp.position)
					if distance >= INTERSECTION_THRESHOLD:
						continue
					if _can_connect_waypoints(new_wp, existing_wp):
						if not new_wp.next_waypoints.has(existing_wp):
							new_wp.next_waypoints.append(existing_wp)
							existing_wp.prev_waypoints.append(new_wp)


## Фаза 1: соединяет endpoints (первый и последний wp) батча с соседними дорогами
func _connect_endpoints(batch: Array) -> void:
	if batch.is_empty():
		return

	var endpoints := [batch[0]]
	if batch.size() > 1:
		endpoints.append(batch[batch.size() - 1])

	for new_wp in endpoints:
		var nearby := _get_nearby_waypoints(new_wp.position)
		for existing_wp in nearby:
			if existing_wp == new_wp or existing_wp in batch:
				continue
			var distance: float = new_wp.position.distance_to(existing_wp.position)
			if distance >= INTERSECTION_THRESHOLD:
				continue
			# Пропускаем дубликаты: два wp в одной точке с тем же направлением —
			# это дублированная дорога (один OSM way загружен несколькими чанками)
			if _is_duplicate_waypoint(new_wp, existing_wp):
				continue
			if _can_connect_waypoints(new_wp, existing_wp):
				if not new_wp.next_waypoints.has(existing_wp):
					new_wp.next_waypoints.append(existing_wp)
					existing_wp.prev_waypoints.append(new_wp)
			if _can_connect_waypoints(existing_wp, new_wp):
				if not existing_wp.next_waypoints.has(new_wp):
					existing_wp.next_waypoints.append(new_wp)
					new_wp.prev_waypoints.append(existing_wp)


## Фаза 2: проверяет один wp против тупиков (dead-ends) соседних дорог
func _connect_deadends_for(wp: Waypoint, batch: Array) -> void:
	var nearby := _get_nearby_waypoints(wp.position)
	for existing_wp in nearby:
		if existing_wp == wp or existing_wp in batch:
			continue
		# Только тупики — вейпоинты без следующих
		if not existing_wp.next_waypoints.is_empty():
			continue
		var distance: float = wp.position.distance_to(existing_wp.position)
		if distance >= INTERSECTION_THRESHOLD:
			continue
		# Пропускаем дубликаты
		if _is_duplicate_waypoint(existing_wp, wp):
			continue
		if _can_connect_waypoints(existing_wp, wp):
			if not existing_wp.next_waypoints.has(wp):
				existing_wp.next_waypoints.append(wp)
				wp.prev_waypoints.append(existing_wp)


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
			other_wp.prev_waypoints.erase(wp)

	# Очищаем отложенные соединения: убираем батчи, содержащие удалённые wp
	var chunk_wps_set := {}
	for wp in chunk_waypoints:
		chunk_wps_set[wp] = true
	_pending_connections = _pending_connections.filter(func(batch: Array) -> bool:
		for bwp in batch:
			if bwp in chunk_wps_set:
				return false
		return true
	)
	if not _current_connect_batch.is_empty():
		for bwp in _current_connect_batch:
			if bwp in chunk_wps_set:
				_current_connect_batch = []
				_current_connect_index = 0
				break

	waypoints_by_chunk.erase(chunk_key)

	# Also clean up tram waypoints for this chunk
	if tram_waypoints_by_chunk.has(chunk_key):
		var tram_wps: Array = tram_waypoints_by_chunk[chunk_key]
		for wp in tram_wps:
			all_tram_waypoints.erase(wp)
			var grid_key := _get_grid_key(wp.position)
			if _tram_spatial_grid.has(grid_key):
				_tram_spatial_grid[grid_key].erase(wp)
				if _tram_spatial_grid[grid_key].is_empty():
					_tram_spatial_grid.erase(grid_key)
			for other_wp in all_tram_waypoints:
				other_wp.next_waypoints.erase(wp)
				other_wp.prev_waypoints.erase(wp)
		_pending_tram_connections = _pending_tram_connections.filter(func(batch: Array) -> bool:
			for bwp in batch:
				if bwp in tram_wps:
					return false
			return true
		)
		tram_waypoints_by_chunk.erase(chunk_key)


## Returns the nearest tram waypoint to a given world position (x, z), or null
func get_nearest_tram_waypoint(world_pos: Vector2, max_dist: float = 50.0) -> Waypoint:
	var gx := int(floor(world_pos.x / GRID_CELL_SIZE))
	var gz := int(floor(world_pos.y / GRID_CELL_SIZE))
	var best_wp: Waypoint = null
	var best_dist_sq: float = max_dist * max_dist
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var key := "%d,%d" % [gx + dx, gz + dz]
			if _tram_spatial_grid.has(key):
				for wp in _tram_spatial_grid[key]:
					var d_sq: float = (wp.position.x - world_pos.x) ** 2 + (wp.position.z - world_pos.y) ** 2
					if d_sq < best_dist_sq:
						best_dist_sq = d_sq
						best_wp = wp
	return best_wp


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


func get_debug_info() -> String:
	"""Возвращает отладочную информацию о сети"""
	var chunk_count := waypoints_by_chunk.size()
	var waypoint_count := all_waypoints.size()
	var connection_count := 0

	for wp in all_waypoints:
		connection_count += wp.next_waypoints.size()

	return "RoadNetwork: %d chunks, %d waypoints, %d connections" % [chunk_count, waypoint_count, connection_count]
