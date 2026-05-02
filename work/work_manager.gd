extends Node

## Менеджер режима работы (такси/доставка)
## Управляет заказами, бонусами, выплатами
##
## Несколько заказов видны одновременно на миникарте.
## Игрок подъезжает к любому — видит попап — принимает/отклоняет.

const WorkPersonScript = preload("res://work/work_person.gd")
const WorkDropoffMarkerScript = preload("res://work/work_dropoff_marker.gd")

enum State { SEARCHING, AT_PICKUP, DRIVING, AT_DROPOFF }

signal order_spawned(pickup_pos: Vector3)
signal order_accepted(fare: int, destination: String)
signal order_completed(result: Dictionary)
signal balance_changed(new_balance: int)
signal bonus_updated(speed_pct: float, safe_pct: float)

const PICKUP_RADIUS := 500.0       # Радиус появления заказа от машины
const DROPOFF_MIN_DIST := 300.0    # Мин. расстояние до dropoff
const DROPOFF_MAX_DIST := 4000.0   # Макс. расстояние до dropoff (4 км)
const PICKUP_ARRIVE_DIST := 15.0   # Расстояние до точки подбора для срабатывания
const DROPOFF_ARRIVE_DIST := 15.0
const MIN_FARE := 150
const MAX_FARE := 2000
const FARE_BASE := 100.0
const FARE_PER_KM := 450.0
const BONUS_SPEED_PCT := 0.2       # 20% чаевые за скорость
const BONUS_SAFE_PCT := 0.2        # 20% за безопасную езду
const TARGET_AVG_SPEED := 45.0     # км/ч — целевая скорость
const OFF_ROAD_PENALTY_RATE := 0.05  # Потеря бонуса в секунду при езде вне дороги
const NUM_AVAILABLE_ORDERS := 3    # Одновременно видимых заказов
const MAX_PICKUP_DISTANCE := 500.0 # Обновлять далёкие пикапы
const REFRESH_INTERVAL := 5.0     # Секунды между проверками далёких заказов
const ROUTE_UPDATE_INTERVAL := 1.0   # Перестроение маршрута (сек)
const PATHFIND_QUERY_RADIUS := 150.0 # Радиус запроса сегментов
const PATHFIND_QUERY_STEP := 120.0   # Шаг вдоль коридора
const PATHFIND_MAX_ITER := 3000      # Лимит итераций A*

const CLIENT_PHRASES_GOOD: Array[String] = [
	"Спасибо, отличная поездка!",
	"Вы лучший водитель!",
	"Как быстро доехали!",
	"Обязательно закажу ещё раз!",
	"Пять звёзд!",
]

const CLIENT_PHRASES_BAD: Array[String] = [
	"Ужасная поездка!",
	"Вы что, первый раз за рулём?!",
	"Я чуть не умер от страха!",
	"Больше никогда!",
	"Моя бабушка водит лучше!",
]

var _state: State = State.SEARCHING
var _car: Node3D
var _terrain_generator: Node
var _minimap: Control
var _hud: Node  # WorkHUD (CanvasLayer)

# Доступные заказы (pre-generated)
# Array of {pickup: Vector3, dropoff: Vector3, fare: int, dest_name: String, est_time: float, trip_dist: float}
var _available_orders: Array = []
var _current_order_idx: int = -1

# Текущий активный заказ (после accept)
var _pickup_pos := Vector3.ZERO
var _dropoff_pos := Vector3.ZERO
var _fare: int = 0
var _destination_name: String = ""

# Бонусы
var _safe_driving_pct: float = 1.0  # 0.0 - 1.0
var _trip_start_time: float = 0.0
var _trip_distance: float = 0.0  # Прямое расстояние pickup-dropoff в метрах
var _estimated_time: float = 0.0  # Ожидаемое время в секундах
var _had_collision: bool = false
var _prev_velocity := Vector3.ZERO  # Для детекции столкновений

var _initial_load_done: bool = false
var _refresh_timer: float = 0.0
var _route_update_timer: float = 0.0

# 3D маркеры
var _person_nodes: Array[Node3D] = []
var _dropoff_marker_node: Node3D = null

# Названия улиц (генерируемые)
const STREET_NAMES: Array[String] = [
	"ул. Ленина", "ул. Мира", "ул. Советская", "ул. Пушкина",
	"пр. Победы", "ул. Гагарина", "ул. Кирова", "ул. Строителей",
	"ул. Молодёжная", "ул. Садовая", "пр. Ломоносова", "ул. Чехова",
	"ул. Горького", "ул. Лермонтова", "ул. Комсомольская", "ул. Парковая",
	"ул. Заводская", "ул. Набережная", "пр. Революции", "ул. Октябрьская",
]


func setup(car: Node3D, terrain_generator: Node, hud: Node) -> void:
	_car = car
	_terrain_generator = terrain_generator
	_hud = hud
	print("WorkManager: Setup complete (car=%s, terrain=%s)" % [_car != null, _terrain_generator != null])


func _process(delta: float) -> void:
	if not _car or not is_instance_valid(_car):
		return
	if not _minimap:
		_minimap = _find_minimap()

	match _state:
		State.SEARCHING:
			_process_searching(delta)
		State.DRIVING:
			_process_driving(delta)


func _process_searching(delta: float) -> void:
	if not _initial_load_done:
		# Ждём пока загрузятся чанки
		if _terrain_generator and _terrain_generator.has_method("get_road_segments_in_radius"):
			var segs: Array = _terrain_generator.get_road_segments_in_radius(_car.global_position, 100.0)
			if segs.size() > 5:
				_initial_load_done = true
				print("WorkManager: Initial load done, spawning orders...")
				_spawn_orders()
		return

	# Проверяем прибытие к любому из доступных пикапов
	for i in range(_available_orders.size()):
		var order: Dictionary = _available_orders[i]
		var dist := _dist_2d(_car.global_position, order.pickup)
		if dist <= PICKUP_ARRIVE_DIST:
			_current_order_idx = i
			_state = State.AT_PICKUP
			_show_order_popup(i)
			return

	# Периодически обновляем далёкие заказы
	_refresh_timer -= delta
	if _refresh_timer <= 0.0:
		_refresh_timer = REFRESH_INTERVAL
		_refresh_stale_orders()


func _process_driving(delta: float) -> void:
	# Детекция столкновений по резкому изменению скорости
	_check_collision()

	# Проверяем безопасное вождение
	_update_safe_driving(delta)

	# Перестраиваем маршрут по дорогам
	_route_update_timer -= delta
	if _route_update_timer <= 0.0:
		_route_update_timer = ROUTE_UPDATE_INTERVAL
		_update_route_to(_dropoff_pos)

	# Проверяем прибытие (2D — не зависит от высоты)
	var dist := _dist_2d(_car.global_position, _dropoff_pos)
	if dist <= DROPOFF_ARRIVE_DIST:
		_complete_order()


func _update_safe_driving(delta: float) -> void:
	if _safe_driving_pct <= 0.0:
		return

	# Проверяем, на дороге ли машина
	if _terrain_generator and _terrain_generator.has_method("is_point_on_road"):
		var pos_2d := Vector2(_car.global_position.x, _car.global_position.z)
		var on_road: bool = _terrain_generator.is_point_on_road(pos_2d, 2.0)
		if not on_road:
			_safe_driving_pct = maxf(0.0, _safe_driving_pct - OFF_ROAD_PENALTY_RATE * delta)
			bonus_updated.emit(_get_speed_bonus_pct(), _safe_driving_pct)


# === ГЕНЕРАЦИЯ ЗАКАЗОВ ===

func _spawn_orders() -> void:
	"""Создаём NUM_AVAILABLE_ORDERS заказов с pre-generated данными"""
	_available_orders.clear()
	for _i in range(NUM_AVAILABLE_ORDERS):
		var order := _generate_order()
		if not order.is_empty():
			_available_orders.append(order)
	_update_minimap_pickups()
	_rebuild_persons()
	if not _available_orders.is_empty():
		print("WorkManager: Spawned %d orders" % _available_orders.size())
		order_spawned.emit(_available_orders[0].pickup)


func _generate_order() -> Dictionary:
	"""Генерирует один полный заказ: pickup + dropoff + fare"""
	var pickup := _generate_pickup_position()
	if pickup == Vector3.ZERO:
		return {}

	var dropoff := _generate_dropoff_position(pickup)
	var trip_dist := Vector2(pickup.x, pickup.z).distance_to(Vector2(dropoff.x, dropoff.z))
	var dist_km := trip_dist / 1000.0
	var fare := clampi(int(FARE_BASE + dist_km * FARE_PER_KM), MIN_FARE, MAX_FARE)
	var dest_name := STREET_NAMES[randi() % STREET_NAMES.size()] + ", д. " + str(randi_range(1, 120))
	var est_time := trip_dist / (TARGET_AVG_SPEED / 3.6)

	return {
		"pickup": pickup,
		"dropoff": dropoff,
		"fare": fare,
		"dest_name": dest_name,
		"est_time": est_time,
		"trip_dist": trip_dist,
	}


func _refresh_stale_orders() -> void:
	"""Заменяем заказы, которые слишком далеко от машины"""
	var changed := false
	for i in range(_available_orders.size() - 1, -1, -1):
		var order: Dictionary = _available_orders[i]
		var dist := _dist_2d(_car.global_position, order.pickup)
		if dist > MAX_PICKUP_DISTANCE:
			var new_order := _generate_order()
			if not new_order.is_empty():
				_available_orders[i] = new_order
				changed = true

	# Добавляем недостающие заказы
	while _available_orders.size() < NUM_AVAILABLE_ORDERS:
		var new_order := _generate_order()
		if not new_order.is_empty():
			_available_orders.append(new_order)
			changed = true
		else:
			break

	if changed:
		_update_minimap_pickups()
		_rebuild_persons()


func _generate_pickup_position() -> Vector3:
	if not _terrain_generator:
		return Vector3.ZERO

	var car_pos := _car.global_position
	var car_2d := Vector2(car_pos.x, car_pos.z)

	# Пробуем несколько раз найти точку рядом с дорогой
	for _attempt in range(20):
		var angle := randf() * TAU
		var dist := randf_range(100.0, PICKUP_RADIUS)
		var offset := Vector2(cos(angle) * dist, sin(angle) * dist)
		var candidate := car_2d + offset

		var road_pos := _snap_to_road_edge(candidate)
		if road_pos != Vector2.ZERO:
			var y := _get_ground_y(road_pos.x, road_pos.y)
			return Vector3(road_pos.x, y, road_pos.y)

	return Vector3.ZERO


func _generate_dropoff_position(from_pos: Vector3) -> Vector3:
	if not _terrain_generator:
		return Vector3.ZERO

	var from_2d := Vector2(from_pos.x, from_pos.z)

	for _attempt in range(30):
		var angle := randf() * TAU
		var dist := randf_range(DROPOFF_MIN_DIST, DROPOFF_MAX_DIST)
		var offset := Vector2(cos(angle) * dist, sin(angle) * dist)
		var candidate := from_2d + offset

		var road_pos := _snap_to_road_edge(candidate)
		if road_pos != Vector2.ZERO:
			if road_pos.distance_to(from_2d) > 200.0:
				var y := _get_ground_y(road_pos.x, road_pos.y)
				return Vector3(road_pos.x, y, road_pos.y)

	# Fallback: случайная точка без привязки к дороге
	var angle := randf() * TAU
	var dist := randf_range(DROPOFF_MIN_DIST, DROPOFF_MAX_DIST * 0.5)
	var offset := Vector2(cos(angle) * dist, sin(angle) * dist)
	var pos := from_2d + offset
	return Vector3(pos.x, 0.0, pos.y)


func _snap_to_road_edge(pos: Vector2) -> Vector2:
	"""Находит ближайшую точку на краю дороги"""
	if not _terrain_generator or not _terrain_generator.has_method("get_road_segments_in_radius"):
		return Vector2.ZERO

	var center := Vector3(pos.x, 0, pos.y)
	var segments: Array = _terrain_generator.get_road_segments_in_radius(center, 30.0)
	if segments.is_empty():
		return Vector2.ZERO

	# Находим ближайший сегмент
	var best_dist := INF
	var best_point := Vector2.ZERO
	for seg in segments:
		var p1: Vector2 = seg.p1
		var p2: Vector2 = seg.p2
		var width: float = seg.width

		# Ближайшая точка на сегменте
		var closest := _closest_point_on_segment(pos, p1, p2)
		var dist := pos.distance_to(closest)

		if dist < best_dist:
			best_dist = dist
			# Смещаемся к краю дороги (не в центр)
			var road_dir := (p2 - p1).normalized()
			var perpendicular := Vector2(-road_dir.y, road_dir.x)
			# Выбираем сторону ближе к исходной точке
			var side := perpendicular if (pos - closest).dot(perpendicular) > 0 else -perpendicular
			best_point = closest + side * (width / 2.0 + 2.0)

	if best_dist < 50.0:
		return best_point
	return Vector2.ZERO


func _closest_point_on_segment(point: Vector2, seg_a: Vector2, seg_b: Vector2) -> Vector2:
	var ab := seg_b - seg_a
	var ab_len_sq := ab.length_squared()
	if ab_len_sq < 0.001:
		return seg_a
	var t := clampf((point - seg_a).dot(ab) / ab_len_sq, 0.0, 1.0)
	return seg_a + ab * t


# === УПРАВЛЕНИЕ ЗАКАЗОМ ===

func _show_order_popup(order_idx: int) -> void:
	"""Показывает попап с данными pre-generated заказа"""
	var order: Dictionary = _available_orders[order_idx]
	_pickup_pos = order.pickup
	_dropoff_pos = order.dropoff
	_fare = order.fare
	_destination_name = order.dest_name
	_estimated_time = order.est_time
	_trip_distance = order.trip_dist

	_freeze_car()

	# Показываем popup через HUD
	if _hud and _hud.has_method("show_order_popup"):
		_hud.show_order_popup(_destination_name, _fare, _estimated_time, _trip_distance)
	print("WorkManager: Showing order: %s, %d руб" % [_destination_name, _fare])


func accept_order() -> void:
	"""Вызывается из HUD когда игрок принимает заказ"""
	_unfreeze_car()
	_state = State.DRIVING
	_trip_start_time = Time.get_ticks_msec() / 1000.0
	_safe_driving_pct = 1.0
	_had_collision = false

	# Убираем людей на пикапах
	_clear_persons()

	# Убираем все маркеры пикапов
	_available_orders.clear()
	_current_order_idx = -1

	# Показываем маркер dropoff и маршрут (только во время DRIVING)
	if _minimap:
		if _minimap.has_method("clear_work_pickups"):
			_minimap.clear_work_pickups()
		if _minimap.has_method("set_work_dropoff"):
			_minimap.set_work_dropoff(_dropoff_pos)

	_route_update_timer = ROUTE_UPDATE_INTERVAL
	_update_route_to(_dropoff_pos)
	_spawn_dropoff_marker(_dropoff_pos)

	order_accepted.emit(_fare, _destination_name)
	print("WorkManager: Order accepted, fare=%d, dest=%s" % [_fare, _destination_name])


func decline_order() -> void:
	"""Вызывается из HUD когда игрок отклоняет заказ"""
	_unfreeze_car()
	# Удаляем отклонённый заказ
	if _current_order_idx >= 0 and _current_order_idx < _available_orders.size():
		_available_orders.remove_at(_current_order_idx)
	_current_order_idx = -1
	_state = State.SEARCHING

	# Генерируем замену
	var new_order := _generate_order()
	if not new_order.is_empty():
		_available_orders.append(new_order)
	_update_minimap_pickups()
	_rebuild_persons()
	print("WorkManager: Order declined, %d orders available" % _available_orders.size())


func _complete_order() -> void:
	_freeze_car()

	var elapsed := Time.get_ticks_msec() / 1000.0 - _trip_start_time
	var speed_bonus_pct := _get_speed_bonus_pct()
	var safe_bonus_pct := _safe_driving_pct

	var speed_bonus := int(_fare * BONUS_SPEED_PCT * speed_bonus_pct)
	var safe_bonus := int(_fare * BONUS_SAFE_PCT * safe_bonus_pct)
	var total := _fare + speed_bonus + safe_bonus

	# Выбираем фразу клиента
	var overall_quality := (speed_bonus_pct + safe_bonus_pct) / 2.0
	var phrase: String
	if overall_quality >= 0.5:
		phrase = CLIENT_PHRASES_GOOD[randi() % CLIENT_PHRASES_GOOD.size()]
	else:
		phrase = CLIENT_PHRASES_BAD[randi() % CLIENT_PHRASES_BAD.size()]

	# Оценка в звёздах (1-5)
	var stars := clampi(int(overall_quality * 4.0) + 1, 1, 5)

	# Начисляем деньги
	if CareerState:
		CareerState.complete_order(total)
		balance_changed.emit(CareerState.balance)

	var result := {
		"fare": _fare,
		"speed_bonus": speed_bonus,
		"safe_bonus": safe_bonus,
		"total": total,
		"phrase": phrase,
		"elapsed": elapsed,
		"estimated": _estimated_time,
		"speed_pct": speed_bonus_pct,
		"safe_pct": safe_bonus_pct,
		"stars": stars,
	}

	_state = State.AT_DROPOFF

	# Показываем результаты
	if _hud and _hud.has_method("show_order_result"):
		_hud.show_order_result(result)

	order_completed.emit(result)
	_clear_markers()

	print("WorkManager: Order completed! fare=%d +speed=%d +safe=%d = %d | %s" % [
		_fare, speed_bonus, safe_bonus, total, phrase])


func finish_result_screen() -> void:
	"""Вызывается из HUD когда игрок закрывает экран результата"""
	_unfreeze_car()
	_state = State.SEARCHING
	_refresh_timer = 0.0
	_spawn_orders()


func _get_speed_bonus_pct() -> float:
	if _state != State.DRIVING:
		return 1.0
	var elapsed := Time.get_ticks_msec() / 1000.0 - _trip_start_time
	if elapsed < 1.0:
		return 1.0
	# Средняя скорость = прямая дистанция / прошедшее время
	var avg_speed_ms := _trip_distance / elapsed
	var avg_speed_kmh := avg_speed_ms * 3.6
	if avg_speed_kmh >= TARGET_AVG_SPEED:
		return 1.0
	# Плавное снижение
	return clampf(avg_speed_kmh / TARGET_AVG_SPEED, 0.0, 1.0)


# === СТОЛКНОВЕНИЯ И БЕЗОПАСНОСТЬ ===

func _check_collision() -> void:
	"""Детекция столкновений по резкому изменению скорости"""
	if _had_collision or _safe_driving_pct <= 0.0:
		return
	if not _car is RigidBody3D:
		return
	var cur_vel: Vector3 = (_car as RigidBody3D).linear_velocity
	var decel := (_prev_velocity - cur_vel).length()
	_prev_velocity = cur_vel
	var speed_kmh := cur_vel.length() * 3.6
	if decel > 8.0 and speed_kmh > 5.0:
		_safe_driving_pct = 0.0
		_had_collision = true
		bonus_updated.emit(_get_speed_bonus_pct(), 0.0)
		print("WorkManager: Collision detected (decel=%.1f)! Safe driving bonus lost" % decel)


# === ВСПОМОГАТЕЛЬНЫЕ ===

func _dist_2d(a: Vector3, b: Vector3) -> float:
	"""Расстояние по X/Z (игнорирует высоту)"""
	return Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))


func _find_minimap() -> Control:
	var node := get_tree().current_scene.find_child("MiniMap", true, false)
	return node


func _update_route_to(target: Vector3) -> void:
	if not _minimap or not _minimap.has_method("set_route_points"):
		return
	var path := _find_road_path(_car.global_position, target)
	_minimap.set_route_points(path)


# === PATHFINDING ПО ДОРОГАМ (A*) ===

func _find_road_path(from_pos: Vector3, to_pos: Vector3) -> Array:
	"""A* по дорожному графу. Возвращает Array[Vector2] точек маршрута."""
	if not _terrain_generator or not _terrain_generator.has_method("get_road_segments_in_radius"):
		return _straight_line_fallback(from_pos, to_pos)

	var start := Vector2(from_pos.x, from_pos.z)
	var end := Vector2(to_pos.x, to_pos.z)

	# 1. Собираем сегменты вдоль коридора
	var segments := _collect_corridor_segments(start, end)
	if segments.is_empty():
		return _straight_line_fallback(from_pos, to_pos)

	# 2. Строим граф
	# graph: Dictionary[Vector2i] → Array of {to: Vector2i, cost: float}
	var graph := {}
	for seg in segments:
		var k1 := Vector2i(roundi(seg.p1.x), roundi(seg.p1.y))
		var k2 := Vector2i(roundi(seg.p2.x), roundi(seg.p2.y))
		if k1 == k2:
			continue
		var cost: float = seg.p1.distance_to(seg.p2)
		if not graph.has(k1):
			graph[k1] = []
		if not graph.has(k2):
			graph[k2] = []
		graph[k1].append({"to": k2, "cost": cost})
		graph[k2].append({"to": k1, "cost": cost})

	if graph.is_empty():
		return _straight_line_fallback(from_pos, to_pos)

	# 3. Ближайшие ноды к старту и финишу
	var start_node := _nearest_graph_node(graph, start)
	var end_node := _nearest_graph_node(graph, end)
	if start_node == end_node:
		return [start, end]

	# 4. A*
	var path := _astar(graph, start_node, end_node)
	if path.is_empty():
		return _straight_line_fallback(from_pos, to_pos)

	# 5. Конвертируем Vector2i → Vector2, добавляем start/end
	var result: Array = [start]
	for node in path:
		result.append(Vector2(node.x, node.y))
	result.append(end)
	return result


func _collect_corridor_segments(start: Vector2, end: Vector2) -> Array:
	var segments: Array = []
	var seen := {}
	var dist := start.distance_to(end)
	var steps := maxi(int(dist / PATHFIND_QUERY_STEP), 1)
	for i in range(steps + 1):
		var t := float(i) / float(steps)
		var center := start.lerp(end, t)
		var center_3d := Vector3(center.x, 0, center.y)
		var segs: Array = _terrain_generator.get_road_segments_in_radius(center_3d, PATHFIND_QUERY_RADIUS)
		for seg in segs:
			var key := "%d_%d_%d_%d" % [roundi(seg.p1.x), roundi(seg.p1.y), roundi(seg.p2.x), roundi(seg.p2.y)]
			if not seen.has(key):
				seen[key] = true
				segments.append(seg)
	return segments


func _nearest_graph_node(graph: Dictionary, pos: Vector2) -> Vector2i:
	var best := Vector2i.ZERO
	var best_dist := INF
	for key: Vector2i in graph:
		var d := pos.distance_squared_to(Vector2(key.x, key.y))
		if d < best_dist:
			best_dist = d
			best = key
	return best


func _astar(graph: Dictionary, start: Vector2i, end: Vector2i) -> Array:
	if not graph.has(start) or not graph.has(end):
		return []
	var end_f := Vector2(end.x, end.y)
	# open: Array of [f_score, g_score, node]
	var open: Array = [[start.distance_to(end), 0.0, start]]
	var g_score := {start: 0.0}
	var came_from := {}
	var closed := {}
	var iterations := 0

	while not open.is_empty() and iterations < PATHFIND_MAX_ITER:
		iterations += 1
		# Находим минимум f
		var best_idx := 0
		for i in range(1, open.size()):
			if open[i][0] < open[best_idx][0]:
				best_idx = i
		var current: Array = open[best_idx]
		open.remove_at(best_idx)
		var node: Vector2i = current[2]
		var g: float = current[1]

		if node == end:
			# Реконструируем путь
			var path: Array = [end]
			var n := end
			while came_from.has(n):
				n = came_from[n]
				path.insert(0, n)
			return path

		if closed.has(node):
			continue
		closed[node] = true

		if not graph.has(node):
			continue

		for edge in graph[node]:
			var to: Vector2i = edge.to
			if closed.has(to):
				continue
			var new_g: float = g + edge.cost
			if new_g < g_score.get(to, INF):
				g_score[to] = new_g
				came_from[to] = node
				var h := Vector2(to.x, to.y).distance_to(end_f)
				open.append([new_g + h, new_g, to])

	return []


func _straight_line_fallback(from_pos: Vector3, to_pos: Vector3) -> Array:
	var start := Vector2(from_pos.x, from_pos.z)
	var end := Vector2(to_pos.x, to_pos.z)
	var points: Array = []
	var steps := clampi(int(start.distance_to(end) / 20.0), 5, 200)
	for i in range(steps + 1):
		points.append(start.lerp(end, float(i) / float(steps)))
	return points


func _update_minimap_pickups() -> void:
	if not _minimap:
		return
	var positions: Array = []
	for order in _available_orders:
		positions.append(order.pickup)
	if _minimap.has_method("set_work_pickups"):
		_minimap.set_work_pickups(positions)


func _clear_markers() -> void:
	_clear_persons()
	_remove_dropoff_marker()
	if _minimap:
		if _minimap.has_method("clear_work_markers"):
			_minimap.clear_work_markers()
		if _minimap.has_method("clear_route_points"):
			_minimap.clear_route_points()


func _get_ground_y(x: float, z: float) -> float:
	"""Высота земли через physics raycast"""
	var world_3d := get_viewport().find_world_3d()
	if world_3d:
		var space_state := world_3d.direct_space_state
		if space_state:
			var from := Vector3(x, 1000.0, z)
			var to := Vector3(x, -100.0, z)
			var query := PhysicsRayQueryParameters3D.create(from, to)
			var result := space_state.intersect_ray(query)
			if not result.is_empty():
				return result.position.y
	# Fallback к elevation grid
	if _terrain_generator and _terrain_generator.has_method("_sample_elevation"):
		var elev: float = _terrain_generator._sample_elevation(x, z)
		if elev != 0.0:
			return elev
	return 0.0


func get_state() -> int:
	return _state


func get_pickup_pos() -> Vector3:
	return _pickup_pos


func get_dropoff_pos() -> Vector3:
	return _dropoff_pos


func get_car() -> Node3D:
	return _car


func get_destination_name() -> String:
	return _destination_name


func get_available_pickups() -> Array:
	var positions: Array = []
	for order in _available_orders:
		positions.append(order.pickup)
	return positions


# === 3D МАРКЕРЫ ===

func _rebuild_persons() -> void:
	_clear_persons()
	var scene_root := get_tree().current_scene
	for i in range(_available_orders.size()):
		var order: Dictionary = _available_orders[i]
		var person := Node3D.new()
		person.set_script(WorkPersonScript)
		person.global_position = order.pickup
		scene_root.add_child(person)
		_person_nodes.append(person)
		print("WorkManager: Person %d spawned at %s (Y=%.1f)" % [i, order.pickup, order.pickup.y])


func _clear_persons() -> void:
	for p in _person_nodes:
		if is_instance_valid(p):
			p.queue_free()
	_person_nodes.clear()


func _spawn_dropoff_marker(pos: Vector3) -> void:
	_remove_dropoff_marker()
	var marker := Node3D.new()
	marker.set_script(WorkDropoffMarkerScript)
	marker.global_position = pos
	get_tree().current_scene.add_child(marker)
	_dropoff_marker_node = marker


func _remove_dropoff_marker() -> void:
	if _dropoff_marker_node and is_instance_valid(_dropoff_marker_node):
		_dropoff_marker_node.queue_free()
		_dropoff_marker_node = null


func _freeze_car() -> void:
	if _car and _car is RigidBody3D:
		(_car as RigidBody3D).linear_velocity = Vector3.ZERO
		(_car as RigidBody3D).angular_velocity = Vector3.ZERO
		_car.freeze = true


func _unfreeze_car() -> void:
	if _car and _car is RigidBody3D:
		_car.freeze = false
