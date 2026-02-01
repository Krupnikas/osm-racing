extends Control

## Круглая мини-карта в стиле NFS
## Отображает дороги, игрока и соперников
## Карта вращается под игрока (направление движения всегда вверх)

# Константы отрисовки
const MAP_RADIUS := 100.0        # Радиус карты в пикселях
const MAP_CENTER := Vector2(110, 110)  # Центр карты (с отступом от края)
const WORLD_RADIUS := 150.0      # Радиус видимости в мировых метрах
const CACHE_EXTRA_RADIUS := 100.0  # Дополнительный радиус кэширования (впереди и сзади)

# Цвета (как на референсе NFS)
const BG_COLOR := Color(0.12, 0.12, 0.15, 0.85)    # Тёмный фон
const ROAD_COLOR := Color(0.65, 0.65, 0.65, 0.9)   # Серые дороги
const BORDER_COLOR := Color(0.35, 0.4, 0.5, 1.0)   # Серая рамка
const BORDER_WIDTH := 3.0

# Цвета маркеров
const PLAYER_COLOR := Color(0.2, 0.9, 0.3, 1.0)    # Зелёная стрелка
const OPPONENT_COLOR := Color(1.0, 0.35, 0.2, 1.0) # Красные/оранжевые точки
const PLAYER_SIZE := 10.0        # Размер стрелки игрока
const OPPONENT_SIZE := 6.0       # Размер точек соперников
const ROAD_WIDTH := 2.5          # Ширина линий дорог

# Ссылки
var _car: Node3D
var _road_network  # RoadNetwork
var _traffic_manager: Node

# Кэш дорог (статичны, обновляем редко)
var _cached_road_segments: Array = []  # Array[PackedVector2Array] - линии дорог в мировых координатах
var _cache_center: Vector3 = Vector3.ZERO
var _cache_radius: float = 0.0
const CACHE_UPDATE_DISTANCE := 50.0  # Обновлять кэш каждые 50м движения

# Флаг видимости соперников (режим гонки)
var _show_opponents := false


func _ready() -> void:
	custom_minimum_size = Vector2(220, 220)

	# Ждём один кадр чтобы сцена полностью загрузилась
	await get_tree().process_frame

	# Ищем машину игрока
	_car = get_tree().get_first_node_in_group("car")
	if not _car:
		_car = get_tree().get_first_node_in_group("player")

	# Пробуем найти RoadNetwork (может быть не готов сразу)
	_try_find_road_network()

	print("MiniMap: Initialized (car=%s, roads=%s)" % [_car != null, _road_network != null])
	queue_redraw()


func _process(_delta: float) -> void:
	# Перерисовка каждый кадр (карта вращается)
	queue_redraw()


func _draw() -> void:
	if not _car:
		# Рисуем пустую карту если нет машины
		_draw_empty_map()
		return

	var player_pos := _car.global_position
	# Угол поворота машины в мировых координатах
	# В Godot: -Z = forward, rotation.y = yaw
	var forward := -_car.global_transform.basis.z
	forward.y = 0
	forward = forward.normalized()
	# Используем rotation.y напрямую - это yaw угол машины
	var player_rotation := _car.global_rotation.y

	# Обновляем кэш дорог если нужно
	_update_road_cache(player_pos)

	# 1. Рисуем фон (круг)
	draw_circle(MAP_CENTER, MAP_RADIUS + 2, BORDER_COLOR)
	draw_circle(MAP_CENTER, MAP_RADIUS, BG_COLOR)

	# 2. Рисуем дороги (с вращением и clipping)
	_draw_roads(player_pos, player_rotation)

	# 3. Рисуем соперников (если режим гонки)
	if _show_opponents:
		_draw_opponents(player_pos, player_rotation)

	# 4. Рисуем игрока (всегда в центре, стрелка вверх)
	_draw_player_marker()

	# 5. Рисуем рамку поверх всего
	draw_arc(MAP_CENTER, MAP_RADIUS, 0, TAU, 64, BORDER_COLOR, BORDER_WIDTH, true)


func _draw_empty_map() -> void:
	"""Рисует пустую карту (когда нет машины)"""
	draw_circle(MAP_CENTER, MAP_RADIUS + 2, BORDER_COLOR)
	draw_circle(MAP_CENTER, MAP_RADIUS, BG_COLOR)
	draw_arc(MAP_CENTER, MAP_RADIUS, 0, TAU, 64, BORDER_COLOR, BORDER_WIDTH, true)


func _update_road_cache(player_pos: Vector3) -> void:
	"""Обновляет кэш дорог если игрок уехал далеко от точки кэширования"""
	# Ленивая инициализация road_network (может быть не готов при старте)
	if not _road_network:
		_try_find_road_network()
		if not _road_network:
			return

	var distance_from_cache := player_pos.distance_to(_cache_center)
	# Первый раз всегда загружаем (когда кэш пустой), потом - каждые 50м
	var is_first_load := _cached_road_segments.is_empty()
	var needs_update := is_first_load or distance_from_cache >= CACHE_UPDATE_DISTANCE

	if not needs_update:
		return  # Кэш актуален

	print("MiniMap: Updating cache (first=%s, dist=%.1f)" % [is_first_load, distance_from_cache])

	_cached_road_segments.clear()
	_cache_center = player_pos
	# Большой радиус кэширования: видимость + запас впереди/сзади + запас на обновление
	_cache_radius = WORLD_RADIUS + CACHE_EXTRA_RADIUS + CACHE_UPDATE_DISTANCE

	# Получаем waypoints в расширенном радиусе
	if not _road_network.has_method("get_waypoints_in_radius"):
		return

	var waypoints: Array = _road_network.get_waypoints_in_radius(player_pos, _cache_radius)

	if waypoints.is_empty():
		print("MiniMap: No waypoints found in radius %.0f at pos %s" % [_cache_radius, player_pos])
		return

	print("MiniMap: Found %d waypoints, building segments..." % waypoints.size())

	# Группируем waypoints в линии дорог (следуем по next_waypoints)
	var processed: Dictionary = {}  # waypoint -> true

	for wp in waypoints:
		if processed.has(wp):
			continue

		# Строим линию от этого waypoint
		var line := PackedVector2Array()
		var current = wp
		var iteration := 0
		const MAX_ITERATIONS := 200  # Защита от бесконечного цикла

		while current != null and not processed.has(current) and iteration < MAX_ITERATIONS:
			processed[current] = true
			line.append(Vector2(current.position.x, current.position.z))
			iteration += 1

			# Переходим к следующему waypoint
			if current.next_waypoints.is_empty():
				break

			# Берём первый next_waypoint (основное направление)
			var next = current.next_waypoints[0]

			# Проверяем что next в радиусе кэша
			if next.position.distance_to(player_pos) > _cache_radius * 1.2:
				break

			current = next

		if line.size() >= 2:
			_cached_road_segments.append(line)

	if not _cached_road_segments.is_empty():
		print("MiniMap: Built %d road segments" % _cached_road_segments.size())


func _draw_roads(player_pos: Vector3, player_rotation: float) -> void:
	"""Рисует дороги с трансформацией в экранные координаты"""
	var scale := MAP_RADIUS / WORLD_RADIUS  # Пиксели на метр
	var player_pos_2d := Vector2(player_pos.x, player_pos.z)

	# Угол вращения: +player_rotation чтобы карта вращалась в правильную сторону
	var angle := player_rotation

	for road_line in _cached_road_segments:
		var screen_points := PackedVector2Array()
		var prev_inside := false

		for i in range(road_line.size()):
			var world_point: Vector2 = road_line[i]

			# Мировые координаты -> относительно игрока
			var relative := world_point - player_pos_2d

			# Грубый clip по дистанции
			var dist := relative.length()
			if dist > WORLD_RADIUS * 1.3:
				# Точка слишком далеко - если были точки внутри, рисуем сегмент
				if screen_points.size() >= 2:
					draw_polyline(screen_points, ROAD_COLOR, ROAD_WIDTH, true)
				screen_points.clear()
				prev_inside = false
				continue

			# Вращаем относительно игрока (карта вращается)
			var rotated := relative.rotated(angle)

			# Масштабируем и переводим в экранные координаты
			var screen_pos := MAP_CENTER + rotated * scale

			# Точный clip по кругу
			var from_center := screen_pos - MAP_CENTER
			var inside := from_center.length() <= MAP_RADIUS

			if inside:
				screen_points.append(screen_pos)
				prev_inside = true
			else:
				# Точка за пределами круга
				if prev_inside and screen_points.size() >= 1:
					# Интерполируем до границы круга
					var last_inside: Vector2 = screen_points[-1]
					var edge_point := _clip_to_circle(last_inside, screen_pos)
					screen_points.append(edge_point)

				# Рисуем накопленный сегмент
				if screen_points.size() >= 2:
					draw_polyline(screen_points, ROAD_COLOR, ROAD_WIDTH, true)
				screen_points.clear()
				prev_inside = false

		# Рисуем оставшиеся точки
		if screen_points.size() >= 2:
			draw_polyline(screen_points, ROAD_COLOR, ROAD_WIDTH, true)


func _clip_to_circle(inside_point: Vector2, outside_point: Vector2) -> Vector2:
	"""Находит точку пересечения линии с окружностью"""
	var dir := outside_point - inside_point
	var to_center := inside_point - MAP_CENTER

	# Решаем квадратное уравнение для пересечения с окружностью
	var a := dir.dot(dir)
	var b := 2.0 * to_center.dot(dir)
	var c := to_center.dot(to_center) - MAP_RADIUS * MAP_RADIUS

	var discriminant := b * b - 4.0 * a * c
	if discriminant < 0:
		return outside_point

	var t := (-b + sqrt(discriminant)) / (2.0 * a)
	t = clamp(t, 0.0, 1.0)

	return inside_point + dir * t


func _draw_opponents(player_pos: Vector3, player_rotation: float) -> void:
	"""Рисует соперников как красные/оранжевые точки"""
	var opponents := get_tree().get_nodes_in_group("race_opponent")
	var scale := MAP_RADIUS / WORLD_RADIUS
	var angle := player_rotation

	for opponent in opponents:
		if not is_instance_valid(opponent):
			continue

		var opp_pos: Vector3 = opponent.global_position

		# Относительная позиция
		var relative := Vector2(opp_pos.x - player_pos.x, opp_pos.z - player_pos.z)

		# Проверяем что в радиусе видимости
		if relative.length() > WORLD_RADIUS:
			continue

		# Вращаем
		var rotated := relative.rotated(angle)

		# Экранные координаты
		var screen_pos := MAP_CENTER + rotated * scale

		# Проверяем что внутри круга
		if (screen_pos - MAP_CENTER).length() <= MAP_RADIUS - OPPONENT_SIZE:
			# Рисуем точку соперника
			draw_circle(screen_pos, OPPONENT_SIZE, OPPONENT_COLOR)

			# Маленькая белая точка в центре для лучшей видимости
			draw_circle(screen_pos, 2.0, Color.WHITE)


func _draw_player_marker() -> void:
	"""Рисует стрелку игрока в центре (направлена вверх)"""
	# Треугольная стрелка вверх (как на референсе)
	var tip := MAP_CENTER + Vector2(0, -PLAYER_SIZE)
	var left := MAP_CENTER + Vector2(-PLAYER_SIZE * 0.6, PLAYER_SIZE * 0.5)
	var right := MAP_CENTER + Vector2(PLAYER_SIZE * 0.6, PLAYER_SIZE * 0.5)

	var points := PackedVector2Array([tip, left, right])
	draw_colored_polygon(points, PLAYER_COLOR)

	# Белая обводка для лучшей видимости
	draw_polyline(PackedVector2Array([tip, left, right, tip]), Color.WHITE, 1.5, true)


# ===== ПУБЛИЧНЫЕ МЕТОДЫ =====

func set_show_opponents(show: bool) -> void:
	"""Включает/выключает отображение соперников (для режима гонки)"""
	_show_opponents = show
	print("MiniMap: show_opponents = %s" % show)


func set_world_radius(radius: float) -> void:
	"""Устанавливает радиус видимости карты в метрах"""
	# Обновляем константу (в GDScript const нельзя менять, используем переменную)
	pass  # TODO: сделать WORLD_RADIUS переменной если нужен zoom


func _try_find_road_network() -> void:
	"""Пытается найти RoadNetwork разными способами"""
	# Способ 1: через TrafficManager
	if not _traffic_manager:
		_traffic_manager = get_tree().current_scene.find_child("TrafficManager", true, false)
		if not _traffic_manager:
			# Способ 2: через группу
			var managers = get_tree().get_nodes_in_group("traffic_manager")
			if not managers.is_empty():
				_traffic_manager = managers[0]

	if _traffic_manager and _traffic_manager.has_method("get_road_network"):
		_road_network = _traffic_manager.get_road_network()
		if _road_network:
			print("MiniMap: RoadNetwork found (lazy init)")
