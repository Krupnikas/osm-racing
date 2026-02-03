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
const ROAD_COLOR_BASE := Color(0.65, 0.65, 0.65)   # Базовый серый для дорог
const BORDER_COLOR := Color(0.35, 0.4, 0.5, 1.0)   # Серая рамка
const BORDER_WIDTH := 3.0

# Цвета маркеров
const PLAYER_COLOR := Color(0.2, 0.9, 0.3, 1.0)    # Зелёная стрелка
const OPPONENT_COLOR := Color(1.0, 0.35, 0.2, 1.0) # Красные/оранжевые точки
const CHECKPOINT_COLOR := Color(1.0, 0.85, 0.0, 1.0)  # Жёлтые чекпоинты
const PLAYER_SIZE := 10.0        # Размер стрелки игрока
const OPPONENT_SIZE := 6.0       # Размер точек соперников
const CHECKPOINT_SIZE := 8.0     # Размер чекпоинтов
const FINISH_SIZE := 10.0        # Размер финиша

# Ширина линий дорог в пикселях (зависит от ширины дороги в метрах)
# motorway=16, trunk=14, primary=12, secondary=10, tertiary=8, residential=6, service=4
const ROAD_LINE_WIDTH_MAJOR := 3.5    # ширина >= 12м (motorway, trunk, primary)
const ROAD_LINE_WIDTH_MEDIUM := 2.5   # ширина 8-11м (secondary, tertiary)
const ROAD_LINE_WIDTH_MINOR := 1.5    # ширина < 8м (residential, service)

# Прозрачность дорог (чем меньше дорога, тем прозрачнее)
const ROAD_ALPHA_MAJOR := 0.95
const ROAD_ALPHA_MEDIUM := 0.8
const ROAD_ALPHA_MINOR := 0.55

# Ссылки
var _car: Node3D
var _terrain_generator: Node  # OSMTerrainGenerator для получения всех дорог

# Кэш дорог (статичны, обновляем редко)
# Array[{p1: Vector2, p2: Vector2, width: float}] - сегменты дорог
var _cached_road_segments: Array = []
var _cache_center: Vector3 = Vector3.ZERO
var _cache_radius: float = 0.0
const CACHE_UPDATE_DISTANCE := 50.0  # Обновлять кэш каждые 50м движения

# Флаг видимости соперников (режим гонки)
var _show_opponents := false

# Чекпоинты (для checkpoint mode)
var _checkpoint_positions: Array = []  # Array[Vector3]
var _finish_position: Vector3 = Vector3.ZERO
var _current_checkpoint_index: int = 0
var _show_checkpoints := false

# Маршрут гонки (визуализация)
var _route_points_local: Array = []  # Array[Vector2] - точки маршрута в локальных координатах (x, z)
var _route_segments: Dictionary = {}  # {segment_key: true} - сегменты на маршруте
const ROUTE_COLOR := Color(0.3, 0.7, 1.0, 0.95)  # Голубой
const ROUTE_MATCH_DISTANCE := 10.0  # Метры - максимальное расстояние от отрезка маршрута


func _ready() -> void:
	custom_minimum_size = Vector2(220, 220)

	# Ждём один кадр чтобы сцена полностью загрузилась
	await get_tree().process_frame

	# Ищем машину игрока
	_car = get_tree().get_first_node_in_group("car")
	if not _car:
		_car = get_tree().get_first_node_in_group("player")

	# Пробуем найти terrain generator
	_try_find_terrain_generator()

	print("MiniMap: Initialized (car=%s, terrain=%s)" % [_car != null, _terrain_generator != null])
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

	# 3. Рисуем чекпоинты и финиш (если checkpoint mode)
	if _show_checkpoints:
		_draw_checkpoints(player_pos, player_rotation)
		_draw_finish_marker(player_pos, player_rotation)

	# 4. Рисуем соперников (если режим гонки)
	if _show_opponents:
		_draw_opponents(player_pos, player_rotation)

	# 5. Рисуем игрока (всегда в центре, стрелка вверх)
	_draw_player_marker()

	# 6. Рисуем рамку поверх всего
	draw_arc(MAP_CENTER, MAP_RADIUS, 0, TAU, 64, BORDER_COLOR, BORDER_WIDTH, true)


func _draw_empty_map() -> void:
	"""Рисует пустую карту (когда нет машины)"""
	draw_circle(MAP_CENTER, MAP_RADIUS + 2, BORDER_COLOR)
	draw_circle(MAP_CENTER, MAP_RADIUS, BG_COLOR)
	draw_arc(MAP_CENTER, MAP_RADIUS, 0, TAU, 64, BORDER_COLOR, BORDER_WIDTH, true)


func _update_road_cache(player_pos: Vector3) -> void:
	"""Обновляет кэш дорог если игрок уехал далеко от точки кэширования"""
	# Ленивая инициализация terrain generator
	if not _terrain_generator:
		_try_find_terrain_generator()
		if not _terrain_generator:
			return

	var distance_from_cache := player_pos.distance_to(_cache_center)
	# Первый раз всегда загружаем (когда кэш пустой), потом - каждые 50м
	var is_first_load := _cached_road_segments.is_empty()
	var needs_update := is_first_load or distance_from_cache >= CACHE_UPDATE_DISTANCE

	if not needs_update:
		return  # Кэш актуален

	_cached_road_segments.clear()
	_cache_center = player_pos
	# Большой радиус кэширования: видимость + запас впереди/сзади + запас на обновление
	_cache_radius = WORLD_RADIUS + CACHE_EXTRA_RADIUS + CACHE_UPDATE_DISTANCE

	# Получаем сегменты дорог из terrain generator
	if not _terrain_generator.has_method("get_road_segments_in_radius"):
		return

	_cached_road_segments = _terrain_generator.get_road_segments_in_radius(player_pos, _cache_radius)

	if not _cached_road_segments.is_empty():
		print("MiniMap: Cached %d road segments" % _cached_road_segments.size())

	# Пересчитываем какие сегменты на маршруте
	_update_route_segments_cache()


func _get_road_style(width: float) -> Dictionary:
	"""Возвращает толщину линии и цвет в зависимости от ширины дороги"""
	var line_width: float
	var alpha: float

	if width >= 12.0:
		# Крупные дороги: motorway, trunk, primary
		line_width = ROAD_LINE_WIDTH_MAJOR
		alpha = ROAD_ALPHA_MAJOR
	elif width >= 8.0:
		# Средние дороги: secondary, tertiary
		line_width = ROAD_LINE_WIDTH_MEDIUM
		alpha = ROAD_ALPHA_MEDIUM
	else:
		# Мелкие дороги: residential, service
		line_width = ROAD_LINE_WIDTH_MINOR
		alpha = ROAD_ALPHA_MINOR

	var color := Color(ROAD_COLOR_BASE.r, ROAD_COLOR_BASE.g, ROAD_COLOR_BASE.b, alpha)
	return {"width": line_width, "color": color}


func _draw_roads(player_pos: Vector3, player_rotation: float) -> void:
	"""Рисует дороги с трансформацией в экранные координаты"""
	var scale := MAP_RADIUS / WORLD_RADIUS  # Пиксели на метр
	var player_pos_2d := Vector2(player_pos.x, player_pos.z)

	# Угол вращения: +player_rotation чтобы карта вращалась в правильную сторону
	var angle := player_rotation

	# Сначала рисуем мелкие дороги, потом крупные (чтобы крупные были сверху)
	# Сортируем сегменты по ширине
	var sorted_segments := _cached_road_segments.duplicate()
	sorted_segments.sort_custom(func(a, b): return a.width < b.width)

	for seg in sorted_segments:
		var p1: Vector2 = seg.p1
		var p2: Vector2 = seg.p2
		var road_width: float = seg.width

		# Получаем стиль для этой дороги
		var style := _get_road_style(road_width)

		# Проверяем, на маршруте ли сегмент
		var seg_key := _segment_key(p1, p2)
		if _route_segments.has(seg_key):
			style.color = ROUTE_COLOR

		# Трансформируем точки
		var rel1 := p1 - player_pos_2d
		var rel2 := p2 - player_pos_2d

		# Грубый clip по дистанции
		var dist1 := rel1.length()
		var dist2 := rel2.length()
		if dist1 > WORLD_RADIUS * 1.5 and dist2 > WORLD_RADIUS * 1.5:
			continue

		# Вращаем
		var rot1 := rel1.rotated(angle)
		var rot2 := rel2.rotated(angle)

		# Экранные координаты
		var screen1 := MAP_CENTER + rot1 * scale
		var screen2 := MAP_CENTER + rot2 * scale

		# Clip по кругу
		var from_center1 := screen1 - MAP_CENTER
		var from_center2 := screen2 - MAP_CENTER
		var inside1 := from_center1.length() <= MAP_RADIUS
		var inside2 := from_center2.length() <= MAP_RADIUS

		if inside1 and inside2:
			# Обе точки внутри - рисуем линию
			draw_line(screen1, screen2, style.color, style.width, true)
		elif inside1 or inside2:
			# Одна точка внутри - clip до границы
			var inside_pt := screen1 if inside1 else screen2
			var outside_pt := screen2 if inside1 else screen1
			var edge_pt := _clip_to_circle(inside_pt, outside_pt)
			draw_line(inside_pt, edge_pt, style.color, style.width, true)
		else:
			# Обе точки снаружи - проверяем пересечение с кругом
			# Упрощённая проверка: если линия близка к центру, рисуем
			var mid := (screen1 + screen2) / 2.0
			if (mid - MAP_CENTER).length() <= MAP_RADIUS:
				# Находим точки пересечения
				var clip1 := _clip_to_circle(MAP_CENTER, screen1)
				var clip2 := _clip_to_circle(MAP_CENTER, screen2)
				draw_line(clip1, clip2, style.color, style.width, true)


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


func set_route_points(points_local: Array) -> void:
	"""Установить точки маршрута для подсветки на карте.
	points_local - Array[Vector2] в локальных координатах (x, z)"""
	_route_points_local = points_local
	_route_segments.clear()
	# Принудительно обновим кэш при следующей отрисовке
	_cache_center = Vector3(INF, 0, INF)
	print("MiniMap: Set %d route points for visualization" % points_local.size())
	queue_redraw()


func clear_route_points() -> void:
	"""Очистить маршрут"""
	_route_points_local.clear()
	_route_segments.clear()
	queue_redraw()


func _try_find_terrain_generator() -> void:
	"""Пытается найти OSMTerrainGenerator"""
	# Способ 1: через группу
	var generators = get_tree().get_nodes_in_group("terrain_generator")
	if not generators.is_empty():
		_terrain_generator = generators[0]
		return

	# Способ 2: по имени в корне сцены
	_terrain_generator = get_tree().current_scene.find_child("OSMTerrainGenerator", true, false)
	if _terrain_generator:
		return

	# Способ 3: по имени TerrainGenerator
	_terrain_generator = get_tree().current_scene.find_child("TerrainGenerator", true, false)


# ===== ROUTE MATCHING =====

func _is_segment_on_route(p1: Vector2, p2: Vector2) -> bool:
	"""Проверяет, принадлежит ли сегмент дороги маршруту.
	Условия: близко к ОТРЕЗКУ маршрута (не точке) И направление совпадает."""
	if _route_points_local.size() < 2:
		return false

	var mid: Vector2 = (p1 + p2) / 2.0
	var seg_dir: Vector2 = (p2 - p1).normalized()

	# Ищем ближайший ОТРЕЗОК маршрута (не точку!)
	for i in range(_route_points_local.size() - 1):
		var route_a: Vector2 = _route_points_local[i]
		var route_b: Vector2 = _route_points_local[i + 1]

		# Расстояние от середины сегмента до отрезка маршрута
		var dist: float = _point_to_segment_distance(mid, route_a, route_b)
		if dist > ROUTE_MATCH_DISTANCE:
			continue

		# Направление отрезка маршрута
		var route_dir: Vector2 = (route_b - route_a).normalized()

		# Проверяем совпадение направлений (abs т.к. дорога двусторонняя)
		var dot: float = abs(seg_dir.dot(route_dir))
		if dot > 0.7:  # ~45 градусов допуск
			return true

	return false


func _point_to_segment_distance(point: Vector2, seg_a: Vector2, seg_b: Vector2) -> float:
	"""Расстояние от точки до отрезка (не прямой!)"""
	var ab: Vector2 = seg_b - seg_a
	var ap: Vector2 = point - seg_a
	var ab_len_sq: float = ab.length_squared()

	if ab_len_sq < 0.001:
		return point.distance_to(seg_a)

	# Проекция точки на отрезок [0, 1]
	var t: float = clamp(ap.dot(ab) / ab_len_sq, 0.0, 1.0)
	var closest: Vector2 = seg_a + ab * t

	return point.distance_to(closest)


func _segment_key(p1: Vector2, p2: Vector2) -> String:
	"""Уникальный ключ для сегмента"""
	return "%d_%d_%d_%d" % [int(p1.x), int(p1.y), int(p2.x), int(p2.y)]


func _update_route_segments_cache() -> void:
	"""Пересчитывает какие сегменты на маршруте"""
	_route_segments.clear()

	if _route_points_local.is_empty():
		return

	for seg in _cached_road_segments:
		if _is_segment_on_route(seg.p1, seg.p2):
			var key := _segment_key(seg.p1, seg.p2)
			_route_segments[key] = true

	print("MiniMap: Found %d road segments on route (of %d total, %d route points)" % [
		_route_segments.size(), _cached_road_segments.size(), _route_points_local.size()
	])


# ===== CHECKPOINT MODE =====

func set_checkpoints(checkpoints: Array, finish_pos: Vector3) -> void:
	"""Установить чекпоинты и финиш для отображения на карте"""
	_checkpoint_positions = checkpoints
	_finish_position = finish_pos
	_current_checkpoint_index = 0
	_show_checkpoints = true
	print("MiniMap: Set %d checkpoints, finish at (%.1f, %.1f)" % [checkpoints.size(), finish_pos.x, finish_pos.z])


func mark_checkpoint_passed(index: int) -> void:
	"""Отметить чекпоинт как пройденный"""
	_current_checkpoint_index = index + 1
	print("MiniMap: Checkpoint %d passed, next is %d" % [index, _current_checkpoint_index])


func clear_checkpoints() -> void:
	"""Очистить чекпоинты"""
	_checkpoint_positions.clear()
	_finish_position = Vector3.ZERO
	_current_checkpoint_index = 0
	_show_checkpoints = false


func _draw_checkpoints(player_pos: Vector3, player_rotation: float) -> void:
	"""Рисует жёлтые чекпоинты"""
	var scale := MAP_RADIUS / WORLD_RADIUS
	var angle := player_rotation

	for i in range(_checkpoint_positions.size()):
		# Пропускаем уже пройденные чекпоинты
		if i < _current_checkpoint_index:
			continue

		var cp_pos: Vector3 = _checkpoint_positions[i]

		# Относительная позиция
		var relative := Vector2(cp_pos.x - player_pos.x, cp_pos.z - player_pos.z)

		# Проверяем что в радиусе видимости
		if relative.length() > WORLD_RADIUS:
			continue

		# Вращаем
		var rotated := relative.rotated(angle)

		# Экранные координаты
		var screen_pos := MAP_CENTER + rotated * scale

		# Проверяем что внутри круга
		if (screen_pos - MAP_CENTER).length() <= MAP_RADIUS - CHECKPOINT_SIZE:
			# Текущий чекпоинт - ярче, следующие - бледнее
			var color := CHECKPOINT_COLOR
			if i > _current_checkpoint_index:
				color.a = 0.5

			# Рисуем жёлтый кружок
			draw_circle(screen_pos, CHECKPOINT_SIZE, color)
			# Белая обводка
			draw_arc(screen_pos, CHECKPOINT_SIZE, 0, TAU, 16, Color.WHITE, 1.5)


func _draw_finish_marker(player_pos: Vector3, player_rotation: float) -> void:
	"""Рисует шахматный финиш"""
	if _finish_position == Vector3.ZERO:
		return

	var scale := MAP_RADIUS / WORLD_RADIUS
	var angle := player_rotation

	# Относительная позиция
	var relative := Vector2(_finish_position.x - player_pos.x, _finish_position.z - player_pos.z)

	# Проверяем что в радиусе видимости
	if relative.length() > WORLD_RADIUS:
		return

	# Вращаем
	var rotated := relative.rotated(angle)

	# Экранные координаты
	var screen_pos := MAP_CENTER + rotated * scale

	# Проверяем что внутри круга
	if (screen_pos - MAP_CENTER).length() > MAP_RADIUS - FINISH_SIZE:
		return

	# Рисуем шахматный кружок (8 сегментов)
	var num_segments := 8
	var segment_angle := TAU / num_segments

	for i in range(num_segments):
		var start_angle := i * segment_angle
		var end_angle := (i + 1) * segment_angle
		var color := Color.WHITE if i % 2 == 0 else Color.BLACK

		# Рисуем сегмент как треугольник
		var points := PackedVector2Array()
		points.append(screen_pos)  # Центр
		# Точки по дуге
		for j in range(5):
			var a := start_angle + (end_angle - start_angle) * j / 4.0
			points.append(screen_pos + Vector2(cos(a), sin(a)) * FINISH_SIZE)

		if points.size() >= 3:
			draw_colored_polygon(points, color)

	# Белая обводка
	draw_arc(screen_pos, FINISH_SIZE, 0, TAU, 24, Color.WHITE, 2.0)
