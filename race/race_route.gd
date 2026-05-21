extends RefCounted
class_name RaceRoute

## Маршрут гонки от старта до финиша
## Содержит последовательность waypoints и методы для отслеживания прогресса

# Точка маршрута
class RoutePoint:
	var position: Vector3
	var direction: Vector3
	var distance_from_start: float  # Накопленная дистанция от старта

	func _init(pos: Vector3, dir: Vector3, dist: float):
		position = pos
		direction = dir.normalized() if dir.length() > 0 else Vector3.FORWARD
		distance_from_start = dist

# Данные маршрута
var points: Array = []  # Array of RoutePoint
var total_length: float = 0.0

# Константы
const MAX_SEARCH_ITERATIONS := 5000  # Защита от бесконечного цикла
const FINISH_THRESHOLD := 50.0  # Расстояние до финиша для завершения поиска


## Строит маршрут из waypoints трека (lat/lon координаты)
## Это основной метод для построения маршрута - надёжнее чем RoadNetwork pathfinding
static func build_from_track_waypoints(waypoints: Array, latlon_converter: Callable) -> RaceRoute:
	var route := RaceRoute.new()

	if waypoints.is_empty():
		push_error("RaceRoute: waypoints array is empty")
		return route

	print("RaceRoute: Building route from %d track waypoints" % waypoints.size())

	var accumulated_distance := 0.0
	var prev_pos: Vector3 = Vector3.ZERO

	for i in range(waypoints.size()):
		var wp = waypoints[i]  # Vector2(lat, lon)
		if not wp is Vector2:
			push_error("RaceRoute: waypoint %d is not Vector2: %s" % [i, typeof(wp)])
			continue
		var pos3d: Vector3 = latlon_converter.call(wp.x, wp.y)
		if i == 0:
			print("RaceRoute: First waypoint (%.6f, %.6f) -> pos3d %s" % [wp.x, wp.y, pos3d])

		# Вычисляем направление к следующей точке
		var direction := Vector3.FORWARD
		if i < waypoints.size() - 1:
			var next_wp = waypoints[i + 1]
			var next_pos: Vector3 = latlon_converter.call(next_wp.x, next_wp.y)
			direction = (next_pos - pos3d).normalized()
			if direction.length_squared() < 0.01:
				direction = Vector3.FORWARD
		elif route.points.size() > 0:
			# Для последней точки используем направление предыдущего сегмента
			direction = route.points[-1].direction

		# Накапливаем дистанцию
		if i > 0:
			accumulated_distance += prev_pos.distance_to(pos3d)

		var point := RoutePoint.new(pos3d, direction, accumulated_distance)
		route.points.append(point)
		prev_pos = pos3d

	if route.points.size() > 0:
		route.total_length = route.points[-1].distance_from_start

	print("RaceRoute: Built route with %d points, length: %.1fm" % [route.points.size(), route.total_length])

	return route


## Строит маршрут из RoadNetwork с промежуточными waypoints для предсказуемого пути
## intermediate_targets — 3D позиции промежуточных точек (sparse waypoints без старта/финиша)
static func build_from_road_network(start_pos: Vector3, finish_pos: Vector3,
		road_network, intermediate_targets: Array = []) -> RaceRoute:
	var route := RaceRoute.new()

	if not road_network or road_network.all_waypoints.is_empty():
		push_error("RaceRoute: road_network is null or empty")
		return route

	# Строим список целей: start → intermediate1 → ... → finish
	var targets: Array[Vector3] = [start_pos]
	for t in intermediate_targets:
		targets.append(t)
	targets.append(finish_pos)

	print("RaceRoute: Building from RoadNetwork with %d targets" % targets.size())

	var all_positions: Array[Vector3] = []
	var visited_global: Dictionary = {}

	# Для каждого сегмента (target[i] → target[i+1]) строим путь по дорожной сети
	for seg_idx in range(targets.size() - 1):
		var seg_start: Vector3 = targets[seg_idx]
		var seg_finish: Vector3 = targets[seg_idx + 1]

		var start_wp = road_network.get_nearest_waypoint(seg_start)
		var finish_wp = road_network.get_nearest_waypoint(seg_finish)

		if not start_wp or not finish_wp:
			print("RaceRoute: Segment %d — no waypoints found, adding direct line" % seg_idx)
			if all_positions.is_empty() or all_positions[-1].distance_to(seg_start) > 1.0:
				all_positions.append(seg_start)
			all_positions.append(seg_finish)
			continue

		# Greedy pathfinding по next_waypoints к finish
		var path: Array = []
		var current = start_wp
		var visited: Dictionary = {}

		for _iter in range(MAX_SEARCH_ITERATIONS):
			if visited.has(current):
				break
			visited[current] = true

			path.append(current.position)

			# Достигли финиша?
			if current == finish_wp or current.position.distance_to(seg_finish) < 15.0:
				break

			# Выбираем следующий waypoint ближайший к цели сегмента
			var best_next = null
			var best_dist := INF
			for next_wp in current.next_waypoints:
				if visited.has(next_wp):
					continue
				# Не идём назад по глобальному маршруту
				if visited_global.has(next_wp):
					continue
				var d: float = next_wp.position.distance_to(seg_finish)
				if d < best_dist:
					best_dist = d
					best_next = next_wp

			if not best_next:
				# Fallback: попробуем любой не visited
				for next_wp in current.next_waypoints:
					if not visited.has(next_wp):
						best_next = next_wp
						break

			if not best_next:
				break  # Dead end

			current = best_next

		# Помечаем все waypoints сегмента как посещённые глобально
		for wp_key in visited:
			visited_global[wp_key] = true

		# Добавляем позиции сегмента (без дубликатов)
		for pos in path:
			if all_positions.is_empty() or all_positions[-1].distance_to(pos) > 1.0:
				all_positions.append(pos)

		print("RaceRoute: Segment %d: %d waypoints" % [seg_idx, path.size()])

	# Конвертируем в RoutePoints
	var accumulated_distance := 0.0
	for i in range(all_positions.size()):
		if i > 0:
			accumulated_distance += all_positions[i - 1].distance_to(all_positions[i])

		var direction := Vector3.FORWARD
		if i < all_positions.size() - 1:
			direction = (all_positions[i + 1] - all_positions[i]).normalized()
		elif route.points.size() > 0:
			direction = route.points[-1].direction

		var point := RoutePoint.new(all_positions[i], direction, accumulated_distance)
		route.points.append(point)

	if route.points.size() > 0:
		route.total_length = route.points[-1].distance_from_start

	print("RaceRoute: Built from RoadNetwork: %d points, length: %.1fm" % [
		route.points.size(), route.total_length])

	return route


## Строит маршрут от старта до финиша используя RoadNetwork (fallback, менее надёжен)
static func build_from_positions(start_pos: Vector3, finish_pos: Vector3, road_network) -> RaceRoute:
	var route := RaceRoute.new()

	if not road_network:
		push_error("RaceRoute: road_network is null")
		return route

	# Находим ближайшие waypoints к старту и финишу
	var start_wp = road_network.get_nearest_waypoint(start_pos)
	var finish_wp = road_network.get_nearest_waypoint(finish_pos)

	if not start_wp or not finish_wp:
		push_error("RaceRoute: Could not find waypoints for start/finish")
		return route

	print("RaceRoute: Building route from ", start_pos, " to ", finish_pos)
	print("RaceRoute: Start waypoint at ", start_wp.position)
	print("RaceRoute: Finish waypoint at ", finish_wp.position)

	# Строим путь используя greedy pathfinding
	var path := _build_path_greedy(start_wp, finish_wp, finish_pos)

	if path.is_empty():
		push_error("RaceRoute: Failed to build path")
		return route

	# Конвертируем waypoints в RoutePoints с накопленной дистанцией
	var accumulated_distance := 0.0
	for i in range(path.size()):
		var wp = path[i]

		if i > 0:
			accumulated_distance += path[i - 1].position.distance_to(wp.position)

		var point := RoutePoint.new(wp.position, wp.direction, accumulated_distance)
		route.points.append(point)

	if route.points.size() > 0:
		route.total_length = route.points[-1].distance_from_start

	print("RaceRoute: Built route with ", route.points.size(), " points, length: ", route.total_length, "m")

	return route


## Greedy pathfinding - идём к финишу выбирая ближайший waypoint
static func _build_path_greedy(start_wp, finish_wp, finish_pos: Vector3) -> Array:
	var path := [start_wp]
	var current = start_wp
	var visited := {}  # Защита от циклов
	visited[current] = true

	for _iteration in range(MAX_SEARCH_ITERATIONS):
		# Проверяем достижение финиша
		if current == finish_wp or current.position.distance_to(finish_pos) < FINISH_THRESHOLD:
			print("RaceRoute: Reached finish after ", path.size(), " waypoints")
			break

		# Ищем следующий waypoint
		var next_wp = _get_best_next_waypoint(current, finish_pos, visited)

		if not next_wp:
			# Нет доступных waypoints - пробуем найти любой невизитированный
			next_wp = _find_any_unvisited_nearby(current, visited, finish_pos)
			if not next_wp:
				print("RaceRoute: Dead end at ", current.position, ", path length: ", path.size())
				break

		visited[next_wp] = true
		path.append(next_wp)
		current = next_wp

	return path


## Выбирает лучший следующий waypoint (ближайший к финишу)
static func _get_best_next_waypoint(current, finish_pos: Vector3, visited: Dictionary):
	if current.next_waypoints.is_empty():
		return null

	var best = null
	var best_distance := INF

	for next in current.next_waypoints:
		if visited.has(next):
			continue

		var dist: float = next.position.distance_to(finish_pos)
		if dist < best_distance:
			best_distance = dist
			best = next

	return best


## Ищет любой невизитированный waypoint поблизости (fallback)
static func _find_any_unvisited_nearby(current, visited: Dictionary, finish_pos: Vector3):
	# Если next_waypoints пуст или все визитированы,
	# это может быть тупик - возвращаем null
	# В будущем можно добавить A* для более умного поиска
	return null


## Возвращает точку и направление на заданной дистанции от старта
func get_point_at_distance(distance: float) -> Dictionary:
	if points.is_empty():
		return {"position": Vector3.ZERO, "direction": Vector3.FORWARD, "segment_idx": 0}

	distance = clamp(distance, 0.0, total_length)

	# Бинарный поиск сегмента
	var idx := 0
	for i in range(points.size() - 1):
		if points[i + 1].distance_from_start >= distance:
			idx = i
			break
		idx = i

	# Интерполяция внутри сегмента
	if idx < points.size() - 1:
		var p1: RoutePoint = points[idx]
		var p2: RoutePoint = points[idx + 1]
		var segment_length: float = p2.distance_from_start - p1.distance_from_start

		if segment_length > 0:
			var t: float = (distance - p1.distance_from_start) / segment_length
			return {
				"position": p1.position.lerp(p2.position, t),
				"direction": p1.direction.lerp(p2.direction, t).normalized(),
				"segment_idx": idx
			}

	# Возвращаем последнюю точку
	var last: RoutePoint = points[-1]
	return {"position": last.position, "direction": last.direction, "segment_idx": points.size() - 1}


## Проецирует позицию на маршрут и возвращает прогресс (дистанцию от старта)
## min_segment_idx - минимальный индекс сегмента для поиска (только вперёд)
func project_position(pos: Vector3, min_segment_idx: int = 0) -> Dictionary:
	if points.size() < 2:
		return {"distance": 0.0, "segment_idx": 0, "lateral_offset": 0.0}

	var best_segment := min_segment_idx
	var best_t := 0.0
	var best_dist := INF

	# Ищем ближайший сегмент (только вперёд от min_segment_idx)
	for i in range(min_segment_idx, points.size() - 1):
		var pt_a: RoutePoint = points[i]
		var pt_b: RoutePoint = points[i + 1]
		var a: Vector3 = pt_a.position
		var b: Vector3 = pt_b.position

		# Проекция точки на отрезок
		var ab: Vector3 = b - a
		var ap: Vector3 = pos - a
		var ab_len_sq: float = ab.length_squared()

		if ab_len_sq < 0.001:
			continue

		var t: float = clamp(ap.dot(ab) / ab_len_sq, 0.0, 1.0)
		var closest: Vector3 = a + ab * t
		var dist: float = pos.distance_to(closest)

		if dist < best_dist:
			best_dist = dist
			best_segment = i
			best_t = t

	# Вычисляем дистанцию от старта
	var pt_best: RoutePoint = points[best_segment]
	var distance: float = pt_best.distance_from_start
	if best_segment < points.size() - 1:
		var pt_next: RoutePoint = points[best_segment + 1]
		var segment_length: float = pt_next.distance_from_start - pt_best.distance_from_start
		distance += segment_length * best_t

	return {
		"distance": distance,
		"segment_idx": best_segment,
		"lateral_offset": best_dist
	}


## Возвращает точку впереди на заданной дистанции от текущего прогресса
func get_lookahead_point(current_distance: float, lookahead: float) -> Vector3:
	var target_distance: float = current_distance + lookahead
	var result: Dictionary = get_point_at_distance(target_distance)
	return result.position


## Проверяет, достиг ли гонщик финиша
func is_finished(distance: float) -> bool:
	return distance >= total_length - 10.0  # 10м до конца


## Возвращает процент прохождения маршрута
func get_progress_percent(distance: float) -> float:
	if total_length <= 0:
		return 0.0
	return clamp(distance / total_length * 100.0, 0.0, 100.0)
