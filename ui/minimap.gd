extends Control

## Круглая мини-карта в стиле NFS
## Отображает дороги, игрока и соперников
## Карта вращается под игрока (направление движения всегда вверх)

# Константы отрисовки
const MAP_RADIUS := 130.0        # Радиус карты в пикселях
const MAP_CENTER := Vector2(140, 140)  # Центр карты (с отступом от края)
const WORLD_RADIUS := 150.0      # Радиус видимости в мировых метрах
const CACHE_EXTRA_RADIUS := 100.0  # Дополнительный радиус кэширования (впереди и сзади)

# Цвета берутся из палитры день/ночь (_palette(), ниже). Рамка:
const BORDER_WIDTH := 4.0

# Размеры маркеров
const OPPONENT_SIZE := 8.0       # Размер точек соперников
const CHECKPOINT_SIZE := 11.0    # Размер чекпоинтов
const FINISH_SIZE := 14.0        # Размер финиша

# Дороги по КЛАССУ (highway), а не по физической ширине: иначе service с lanes=2
# (≈7м) и tertiary (8м) попадают в один тир. Тиры: 0 крупные / 1 средние / 2 мелкие / 3 service.
const ROAD_TIER_WIDTH := [5.0, 3.5, 2.5, 1.6]   # px
# «Прозрачность» задаётся как доля подмешивания цвета дороги к фону диска — но рисуем
# НЕПРОЗРАЧНО (см. _get_road_style), чтобы пересечения не складывались в яркие точки.
# День: тёмные дороги на кремовом — хватает малой доли. Ночь: светлый янтарь на графите —
# нужна бОльшая доля, иначе мелкие дорожки (service) тонут в фоне.
const ROAD_TIER_BLEND_DAY := [0.46, 0.30, 0.17, 0.13]
const ROAD_TIER_BLEND_NIGHT := [0.90, 0.70, 0.52, 0.42]
const ROAD_TIER := {
	"motorway": 0, "trunk": 0, "primary": 0,
	"motorway_link": 0, "trunk_link": 0, "primary_link": 0,
	"secondary": 1, "tertiary": 1, "secondary_link": 1, "tertiary_link": 1,
	"residential": 2, "unclassified": 2, "living_street": 2, "road": 2, "busway": 2,
	"service": 3, "track": 3, "alley": 3, "driveway": 3, "parking_aisle": 3,
}

# Безель (кольцо делений) перекрывает сетку: контент клиппится по внутреннему радиусу
const BEZEL_INSET := 20.0
var _content_radius: float:
	get:
		return MAP_RADIUS - BEZEL_INSET

# Палитра день/ночь (парная спидометру). Переключается по сигналу night_mode_manager.
var _is_night := false
const DAY := {
	"bg":         Color("#f4eccc", 0.90),   # кремовый диск, почти непрозрачный
	"border":     Color("#3c2814", 0.55),   # тёмная оправа
	"road":       Color("#1c1612"),         # тёмные дороги (альфа из _get_road_style)
	"route":      Color("#1fc8d8", 0.72),   # циановый маршрут
	"player":     Color("#3f8a1e"),         # зелёная стрелка
	"opponent":   Color("#b3251e"),         # красные соперники
	"checkpoint": Color("#c0871e"),         # янтарный чекпоинт
	"tick":       Color("#1c1612", 0.45),   # деления безеля
	"halo":       Color("#f8f1de", 0.82),   # подложка под стрелкой
}
const NIGHT := {
	"bg":         Color("#14110e", 0.92),
	"border":     Color("#ffb450", 0.30),
	"road":       Color("#ffd17a"),
	"route":      Color("#5fd8e8", 0.72),
	"player":     Color("#9ddc7a"),
	"opponent":   Color("#ff6b5a"),
	"checkpoint": Color("#ffc24d"),
	"tick":       Color("#ffd17a", 0.50),
	"halo":       Color("#080706", 0.78),
}

func _palette() -> Dictionary:
	return NIGHT if _is_night else DAY

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
const ROUTE_LINE_WIDTH := 5.5  # Ширина линии маршрута (цвет — из палитры)
const ROUTE_MATCH_DISTANCE := 6.0  # Метры - максимальное расстояние от отрезка маршрута

# Маркеры режима работы (такси)
var _work_pickup_positions: Array = []  # Array[Vector3] — несколько пикапов одновременно
var _work_dropoff_pos := Vector3.ZERO
var _show_work_dropoff := false
const WORK_PICKUP_COLOR := Color(0.2, 0.8, 1.0, 1.0)   # Голубой (клиент)
const WORK_DROPOFF_COLOR := Color(1.0, 0.5, 0.1, 1.0)   # Оранжевый (назначение)
const WORK_MARKER_SIZE := 12.0
const WORK_EDGE_MARKER_SIZE := 10.0  # Размер маркера на краю


func _ready() -> void:
	custom_minimum_size = Vector2(280, 280)

	# Ждём один кадр чтобы сцена полностью загрузилась
	await get_tree().process_frame

	# Ищем машину игрока
	_car = get_tree().get_first_node_in_group("car")
	if not _car:
		_car = get_tree().get_first_node_in_group("player")

	# Пробуем найти terrain generator
	_try_find_terrain_generator()

	# Подписка на день/ночь (палитра парная спидометру)
	var nm := get_tree().current_scene.find_child("NightModeManager", true, false)
	if nm and nm.has_signal("night_mode_changed"):
		if not nm.night_mode_changed.is_connected(_on_night_mode_changed):
			nm.night_mode_changed.connect(_on_night_mode_changed)
		if "is_night" in nm:
			_is_night = nm.is_night   # начальное состояние

	print("MiniMap: Initialized (car=%s, terrain=%s)" % [_car != null, _terrain_generator != null])
	queue_redraw()


func _on_night_mode_changed(is_night: bool) -> void:
	_is_night = is_night
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
	var pal := _palette()
	draw_circle(MAP_CENTER, MAP_RADIUS + 2, pal["border"])
	draw_circle(MAP_CENTER, MAP_RADIUS, pal["bg"])

	# 2. Рисуем дороги (с вращением и clipping)
	_draw_roads(player_pos, player_rotation)

	# 2.5. Рисуем маршрут поверх дорог (полилиния)
	if not _route_points_local.is_empty():
		_draw_route_line(player_pos, player_rotation)

	# 3. Рисуем чекпоинты и финиш (если checkpoint mode)
	if _show_checkpoints:
		_draw_checkpoints(player_pos, player_rotation)
		_draw_finish_marker(player_pos, player_rotation)

	# 3.5. Рисуем маркеры работы (такси) с edge clamping
	for pickup_pos in _work_pickup_positions:
		_draw_work_marker(pickup_pos, player_pos, player_rotation, WORK_PICKUP_COLOR)
	if _show_work_dropoff:
		_draw_work_marker(_work_dropoff_pos, player_pos, player_rotation, WORK_DROPOFF_COLOR)

	# 4. Рисуем соперников (если режим гонки)
	if _show_opponents:
		_draw_opponents(player_pos, player_rotation)

	# 5. Рисуем игрока (всегда в центре, стрелка вверх)
	_draw_player_marker()

	# 6. Безель (кольцо делений + рамка) поверх всего — визуально обрезает сетку
	_draw_bezel()


func _draw_bezel() -> void:
	"""Кольцо делений по краю (как у спидометра) + тонкое внутреннее кольцо + рамка."""
	var pal := _palette()
	var tick: Color = pal["tick"]
	for i in 60:
		var a := deg_to_rad(i * 6.0 - 90.0)
		var major := i % 5 == 0
		var r1 := MAP_RADIUS - (13.0 if major else 7.0)
		var r2 := MAP_RADIUS - 2.0
		var col := tick
		col.a = tick.a * (1.0 if major else 0.56)
		var dir := Vector2(cos(a), sin(a))
		draw_line(MAP_CENTER + dir * r1, MAP_CENTER + dir * r2, col, 2.0 if major else 1.0, true)
	# тонкое внутреннее кольцо (граница контента)
	draw_arc(MAP_CENTER, MAP_RADIUS - 17.0, 0, TAU, 64, Color(pal["border"], 0.5), 1.0, true)
	# внешняя рамка
	draw_arc(MAP_CENTER, MAP_RADIUS, 0, TAU, 64, pal["border"], BORDER_WIDTH, true)


func _draw_empty_map() -> void:
	"""Рисует пустую карту (когда нет машины)"""
	var pal := _palette()
	draw_circle(MAP_CENTER, MAP_RADIUS + 2, pal["border"])
	draw_circle(MAP_CENTER, MAP_RADIUS, pal["bg"])
	_draw_bezel()


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

	var raw_segments: Array = _terrain_generator.get_road_segments_in_radius(player_pos, _cache_radius)
	# Фильтруем пешеходные дороги — не показываем на миникарте
	const PEDESTRIAN_ROADS := ["footway", "path", "cycleway", "steps", "pedestrian"]
	for seg in raw_segments:
		var hw: String = seg.get("highway", "")
		if hw in PEDESTRIAN_ROADS:
			continue
		_cached_road_segments.append(seg)

	if not _cached_road_segments.is_empty():
		print("MiniMap: Cached %d road segments" % _cached_road_segments.size())

	# Пересчитываем какие сегменты на маршруте
	_update_route_segments_cache()


func _road_tier(hw: String, width: float) -> int:
	"""Тир дороги по классу (highway). Фолбэк по физической ширине, если класс неизвестен."""
	if ROAD_TIER.has(hw):
		return ROAD_TIER[hw]
	if width >= 12.0:
		return 0
	elif width >= 8.0:
		return 1
	return 2


func _get_road_style(hw: String, width: float) -> Dictionary:
	"""Толщина и цвет линии по классу дороги. Цвет — НЕПРОЗРАЧНЫЙ результат подмешивания
	дороги к фону диска: одиночная линия выглядит как полупрозрачная, но пересечения двух
	линий не складываются в яркую точку (рисуем opaque поверх opaque)."""
	var tier := _road_tier(hw, width)
	var pal := _palette()
	var bg: Color = pal["bg"]
	var road: Color = pal["road"]
	var blend: Array = ROAD_TIER_BLEND_NIGHT if _is_night else ROAD_TIER_BLEND_DAY
	var color := Color(bg.r, bg.g, bg.b).lerp(Color(road.r, road.g, road.b), blend[tier])
	return {"width": ROAD_TIER_WIDTH[tier], "color": color, "tier": tier}


func _draw_roads(player_pos: Vector3, player_rotation: float) -> void:
	"""Рисует дороги с трансформацией в экранные координаты"""
	var scale := MAP_RADIUS / WORLD_RADIUS  # Пиксели на метр
	var player_pos_2d := Vector2(player_pos.x, player_pos.z)

	# Угол вращения: +player_rotation чтобы карта вращалась в правильную сторону
	var angle := player_rotation

	# Рисуем мелкие дороги первыми, крупные сверху — сортируем по ТИРУ (3→0)
	var sorted_segments := _cached_road_segments.duplicate()
	sorted_segments.sort_custom(func(a, b):
		return _road_tier(str(a.get("highway", "")), a.get("width", 5.0)) \
			> _road_tier(str(b.get("highway", "")), b.get("width", 5.0)))

	for seg in sorted_segments:
		var p1: Vector2 = seg.p1
		var p2: Vector2 = seg.p2
		var road_width: float = seg.width
		var hw: String = str(seg.get("highway", ""))

		# Получаем стиль для этой дороги (по классу)
		var style := _get_road_style(hw, road_width)

		# Проверяем, на маршруте ли сегмент
		var seg_key := _segment_key(p1, p2)
		if _route_segments.has(seg_key):
			style.color = _palette()["route"]

		# Трансформируем точки
		var rel1 := p1 - player_pos_2d
		var rel2 := p2 - player_pos_2d

		# Грубый clip: проверяем расстояние от ОТРЕЗКА до игрока, а не от
		# концов. Иначе длинные segments (как 720m primary мостов с 2-node
		# way'ями) выпадают, когда игрок между их концами.
		var seg_to_player := Geometry2D.get_closest_point_to_segment(
			Vector2.ZERO, rel1, rel2)
		if seg_to_player.length() > WORLD_RADIUS * 1.5:
			continue

		# Вращаем
		var rot1 := rel1.rotated(angle)
		var rot2 := rel2.rotated(angle)

		# Экранные координаты
		var screen1 := MAP_CENTER + rot1 * scale
		var screen2 := MAP_CENTER + rot2 * scale

		# Clip по внутреннему радиусу (безель остаётся снаружи)
		var cr := _content_radius
		var from_center1 := screen1 - MAP_CENTER
		var from_center2 := screen2 - MAP_CENTER
		var inside1 := from_center1.length() <= cr
		var inside2 := from_center2.length() <= cr

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
			# Обе точки снаружи. Сегмент всё ещё может пересекать круг —
			# например 720m мостовой way с двумя нодами и игроком где-то
			# посередине. Проверяем кратчайшее расстояние от MAP_CENTER до
			# отрезка screen1→screen2; если ≤ MAP_RADIUS, считаем точки
			# пересечения и рисуем хорду.
			var closest := Geometry2D.get_closest_point_to_segment(
				MAP_CENTER, screen1, screen2)
			if closest.distance_to(MAP_CENTER) <= cr:
				var clip1 := _clip_to_circle(closest, screen1)
				var clip2 := _clip_to_circle(closest, screen2)
				draw_line(clip1, clip2, style.color, style.width, true)


func _draw_route_line(player_pos: Vector3, player_rotation: float) -> void:
	"""Рисует маршрут как полилинию поверх дорог"""
	if _route_points_local.size() < 2:
		return

	var scale := MAP_RADIUS / WORLD_RADIUS
	var angle := player_rotation
	var player_pos_2d := Vector2(player_pos.x, player_pos.z)

	# Трансформируем все точки маршрута в экранные
	var screen_pts: Array[Vector2] = []
	for pt in _route_points_local:
		var rel: Vector2 = pt - player_pos_2d
		var rot: Vector2 = rel.rotated(angle)
		screen_pts.append(MAP_CENTER + rot * scale)

	# Рисуем сегменты с клиппингом по внутреннему радиусу
	var route_col: Color = _palette()["route"]
	var cr := _content_radius
	for i in range(screen_pts.size() - 1):
		var s1: Vector2 = screen_pts[i]
		var s2: Vector2 = screen_pts[i + 1]

		var d1: float = (s1 - MAP_CENTER).length()
		var d2: float = (s2 - MAP_CENTER).length()
		var in1: bool = d1 <= cr
		var in2: bool = d2 <= cr

		if in1 and in2:
			draw_line(s1, s2, route_col, ROUTE_LINE_WIDTH, true)
		elif in1:
			draw_line(s1, _clip_to_circle(s1, s2), route_col, ROUTE_LINE_WIDTH, true)
		elif in2:
			draw_line(_clip_to_circle(s2, s1), s2, route_col, ROUTE_LINE_WIDTH, true)
		else:
			# Обе снаружи — проверяем пересечение через центр
			var mid := (s1 + s2) / 2.0
			if (mid - MAP_CENTER).length() <= cr:
				var c1 := _clip_to_circle(MAP_CENTER, s1)
				var c2 := _clip_to_circle(MAP_CENTER, s2)
				draw_line(c1, c2, route_col, ROUTE_LINE_WIDTH, true)


func _clip_to_circle(inside_point: Vector2, outside_point: Vector2) -> Vector2:
	"""Находит точку пересечения линии с окружностью"""
	var dir := outside_point - inside_point
	var to_center := inside_point - MAP_CENTER

	# Решаем квадратное уравнение для пересечения с окружностью
	var a := dir.dot(dir)
	var b := 2.0 * to_center.dot(dir)
	var c := to_center.dot(to_center) - _content_radius * _content_radius

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
		if (screen_pos - MAP_CENTER).length() <= _content_radius - OPPONENT_SIZE:
			# Рисуем точку соперника
			draw_circle(screen_pos, OPPONENT_SIZE, _palette()["opponent"])

			# Маленькая белая точка в центре для лучшей видимости
			draw_circle(screen_pos, 2.0, Color.WHITE)


func _draw_player_marker() -> void:
	"""Крупная стрелка игрока в центре с подложкой-гало (читается поверх дорог)."""
	var pal := _palette()
	# Подложка-гало (пропорции от прототипа R150 → наш R130)
	draw_circle(MAP_CENTER, 17.0, pal["halo"])
	draw_arc(MAP_CENTER, 17.0, 0, TAU, 24, Color(pal["player"], 0.55), 1.5, true)
	# Стрелка с выемкой сзади
	var tip := MAP_CENTER + Vector2(0, -16)
	var left := MAP_CENTER + Vector2(-10, 11)
	var notch := MAP_CENTER + Vector2(0, 5)
	var right := MAP_CENTER + Vector2(10, 11)
	draw_colored_polygon(PackedVector2Array([tip, left, notch, right]), pal["player"])
	draw_polyline(PackedVector2Array([tip, left, notch, right, tip]), Color.WHITE, 1.5, true)


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
	Условия: ОБА конца близки к маршруту И направление совпадает."""
	if _route_points_local.size() < 2:
		return false

	var seg_dir: Vector2 = (p2 - p1).normalized()

	# Оба конца сегмента должны быть близко к маршруту
	var best_dist_p1 := INF
	var best_dist_p2 := INF
	var best_dot := 0.0

	for i in range(_route_points_local.size() - 1):
		var route_a: Vector2 = _route_points_local[i]
		var route_b: Vector2 = _route_points_local[i + 1]

		var d1: float = _point_to_segment_distance(p1, route_a, route_b)
		var d2: float = _point_to_segment_distance(p2, route_a, route_b)

		if d1 < best_dist_p1:
			best_dist_p1 = d1
		if d2 < best_dist_p2:
			best_dist_p2 = d2

		# Направление проверяем только для сегментов, к которым оба конца близки
		if d1 < ROUTE_MATCH_DISTANCE and d2 < ROUTE_MATCH_DISTANCE:
			var route_dir: Vector2 = (route_b - route_a).normalized()
			var dot: float = abs(seg_dir.dot(route_dir))
			if dot > best_dot:
				best_dot = dot

	# Оба конца должны быть близко И направление совпадает
	if best_dist_p1 < ROUTE_MATCH_DISTANCE and best_dist_p2 < ROUTE_MATCH_DISTANCE and best_dot > 0.85:
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
		if (screen_pos - MAP_CENTER).length() <= _content_radius - CHECKPOINT_SIZE:
			# Текущий чекпоинт - ярче, следующие - бледнее
			var color: Color = _palette()["checkpoint"]
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
	if (screen_pos - MAP_CENTER).length() > _content_radius - FINISH_SIZE:
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


# ===== WORK MODE MARKERS (с edge clamping — цветные кружки) =====

func _draw_work_marker(marker_pos: Vector3, player_pos: Vector3, player_rotation: float,
		color: Color) -> void:
	"""Рисует маркер работы. Если за пределами миникарты — цветной кружок на краю."""
	var scale := MAP_RADIUS / WORLD_RADIUS
	var angle := player_rotation

	var relative := Vector2(marker_pos.x - player_pos.x, marker_pos.z - player_pos.z)
	var rotated := relative.rotated(angle)
	var screen_pos := MAP_CENTER + rotated * scale
	var from_center := screen_pos - MAP_CENTER
	var dist_from_center := from_center.length()

	if dist_from_center <= MAP_RADIUS - WORK_MARKER_SIZE:
		# Внутри карты — цветной кружок с белой обводкой
		draw_circle(screen_pos, WORK_MARKER_SIZE, color)
		draw_arc(screen_pos, WORK_MARKER_SIZE, 0, TAU, 16, Color.WHITE, 2.0)
	else:
		# Edge clamping — цветной кружок на краю
		var edge_pos := MAP_CENTER + from_center.normalized() * (MAP_RADIUS - WORK_EDGE_MARKER_SIZE - 3)
		draw_circle(edge_pos, WORK_EDGE_MARKER_SIZE, color)
		draw_arc(edge_pos, WORK_EDGE_MARKER_SIZE, 0, TAU, 12, Color.WHITE, 1.5)


# ===== WORK MODE PUBLIC API =====

func set_work_pickups(positions: Array) -> void:
	_work_pickup_positions = positions
	queue_redraw()


func clear_work_pickups() -> void:
	_work_pickup_positions.clear()
	queue_redraw()


func set_work_dropoff(pos: Vector3) -> void:
	_work_dropoff_pos = pos
	_show_work_dropoff = true
	queue_redraw()


func clear_work_dropoff() -> void:
	_show_work_dropoff = false
	queue_redraw()


func clear_work_markers() -> void:
	_work_pickup_positions.clear()
	_show_work_dropoff = false
	queue_redraw()
