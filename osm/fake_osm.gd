extends RefCounted

## Генератор фейковых OSM-данных для тестовых трасс
## Формат выхода идентичен osm_loader.gd: {ways, point_objects, entrance_nodes, poi_nodes, bus_stops}

## Координатная система: start_lat=0, start_lon=0, cos(0)=1
## _latlon_to_local: dx = lon * 111000, dz = -lat * 111000
## Обратно: lat = -z / 111000, lon = x / 111000


static func get_data(track_id: String, _chunk_lat: float, _chunk_lon: float, _chunk_size: float) -> Dictionary:
	var all_ways := []

	match track_id:
		"test_flat", "test_npc":
			all_ways.append_array(_make_oval_road())
		"test_suspension":
			all_ways.append_array(_make_suspension_road())
		"test_bridge":
			all_ways.append_array(_make_bridge_track())

	# Фильтруем ways по bbox чанка (как реальный Overpass API)
	# Каждый way отдаём только чанку, содержащему его первую точку — избегаем дублирования
	var half := _chunk_size / 2.0
	var lat_delta := half / 111000.0
	var lon_delta := half / 111000.0  # cos(0)=1
	var min_lat := _chunk_lat - lat_delta
	var max_lat := _chunk_lat + lat_delta
	var min_lon := _chunk_lon - lon_delta
	var max_lon := _chunk_lon + lon_delta

	var filtered_ways := []
	for way in all_ways:
		var nodes: Array = way.get("nodes", [])
		if nodes.is_empty():
			continue
		var tags: Dictionary = way.get("tags", {})
		var way_id: int = int(way.get("id", 0))
		if tags.has("highway"):
			# Дороги: находим непрерывные группы точек внутри bbox
			# Way может проходить через чанк несколько раз (напр. правая и левая прямые овала)
			var segments := _clip_way_to_bbox(nodes, min_lat, max_lat, min_lon, max_lon)
			for seg in segments:
				filtered_ways.append({
					"id": way_id,
					"nodes": seg,
					"tags": tags,
				})
		else:
			# Здания и прочее — по центру
			var cx := 0.0
			var cz := 0.0
			for node in nodes:
				cx += node.lon
				cz += node.lat
			cx /= nodes.size()
			cz /= nodes.size()
			if cz >= min_lat and cz < max_lat and cx >= min_lon and cx < max_lon:
				filtered_ways.append(way)

	return {
		"ways": filtered_ways,
		"point_objects": [],
		"entrance_nodes": [],
		"poi_nodes": [],
		"bus_stops": [],
	}




# --- Дороги ---

static func _make_oval_road() -> Array:
	## Овальный трек: 2 прямые (1400m) + 2 полукруга (radius=100m) — ~10 чанков в длину
	## Один замкнутый way — get_data() обрезает по bbox каждого чанка
	var nodes := []
	var straight_length := 1400.0
	var turn_radius := 100.0
	var segments := 64
	var half_straight := straight_length / 2.0
	var straight_steps := 140

	# Правая прямая
	for i in range(straight_steps + 1):
		var t := float(i) / straight_steps
		var z := -half_straight + t * straight_length
		nodes.append(_ll(turn_radius, z))
	# Верхний полукруг
	for i in range(1, segments + 1):
		var angle := float(i) / segments * PI
		nodes.append(_ll(turn_radius * cos(angle), half_straight + turn_radius * sin(angle)))
	# Левая прямая
	for i in range(1, straight_steps + 1):
		var t := float(i) / straight_steps
		nodes.append(_ll(-turn_radius, half_straight - t * straight_length))
	# Нижний полукруг
	for i in range(1, segments):
		var angle := PI + float(i) / segments * PI
		nodes.append(_ll(turn_radius * cos(angle), -half_straight + turn_radius * sin(angle)))
	nodes.append(nodes[0])

	return [{
		"nodes": nodes,
		"tags": {"highway": "primary", "name": "Test Oval"},
	}]


## Densifies a 2-point polyline into a chain of nodes every `step` metres.
## Needed because `_clip_way_to_bbox` below filters by node inclusion — a way
## with only 2 far-apart nodes gets dropped from every chunk that doesn't
## contain at least one of those nodes, even if the line passes through it.
static func _densify(p1: Dictionary, p2: Dictionary, step: float) -> Array:
	var x1: float = p1.lon * 111000.0
	var z1: float = -p1.lat * 111000.0
	var x2: float = p2.lon * 111000.0
	var z2: float = -p2.lat * 111000.0
	var dist: float = sqrt((x2 - x1) * (x2 - x1) + (z2 - z1) * (z2 - z1))
	if dist <= step:
		return [p1, p2]
	var n: int = int(ceil(dist / step))
	var out: Array = []
	for i in range(n + 1):
		var t: float = float(i) / float(n)
		out.append(_ll(x1 + (x2 - x1) * t, z1 + (z2 - z1) * t))
	return out


static func _make_bridge_track() -> Array:
	## Синтетическая трасса, повторяющая топологию Октябрьского моста в Череповце:
	##   - главная прямая ось Z из 5 way'ев: ground_S, bridge_B, bridge_C, bridge_D, ground_N
	##     где 3 средних — bridge=yes и делят общие OSM-узлы на стыках
	##   - восточный съезд (T-развязка): ground_E + bridge_F, F врезается в СРЕДНЮЮ
	##     ноду bridge_C, что моделирует развязку
	##   - два параллельных тротуара footway+bridge=yes на всю длину моста
	##   - наземная дорога (residential, НЕ bridge), проходящая поперёк под мостом
	##
	## Используется для отладки редизайна bridge pipeline
	## (docs/BRIDGE_ELEVATION_REDESIGN.md). Покрывает:
	##   - линейный стык двух bridge way'ев (должен быть бесшовным)
	##   - T-развязка: bridge_F втыкается в середину bridge_C
	##   - рампы на свободных концах (ground↔bridge)
	##   - тротуары на мосту
	##   - наземная дорога ПОД мостом не должна ломать барьеры/геометрию

	# Смещение всех нод: chunk_snap в терragen'е создаёт "мёртвую зону" ±chunk_size/2
	# вокруг (0,0), поэтому ставим мост в chunk-центре (300, 300).
	var OX := 300.0
	var OZ := 300.0

	# Общие узлы (одинаковые lat/lon → union-find объединит их в одну Y)
	var n_S_gnd := _ll(OX, OZ - 300)       # свободный южный конец ground_S
	var n_S_join := _ll(OX, OZ - 200)      # ground_S.end = bridge_B.start (ground↔bridge, рампа B)
	var n_BC := _ll(OX, OZ - 100)          # bridge_B.end = bridge_C.start (shared, бесшовно)
	var n_C_mid := _ll(OX, OZ)             # bridge_C середина = bridge_F.end (T-развязка)
	var n_CD := _ll(OX, OZ + 100)          # bridge_C.end = bridge_D.start (shared, бесшовно)
	var n_N_join := _ll(OX, OZ + 200)      # bridge_D.end = ground_N.start (ground↔bridge, рампа D)
	var n_N_gnd := _ll(OX, OZ + 300)       # свободный северный конец ground_N

	var n_E_gnd := _ll(OX + 200, OZ)       # свободный восточный конец ground_E
	var n_E_join := _ll(OX + 100, OZ)      # ground_E.end = bridge_F.start (рампа F)

	# Тротуары — отдельная нода-система, смещённая на ±3м от оси дороги.
	# Их концы НЕ совпадают с endpoint'ами главной дороги (разные lat/lon), поэтому
	# оба конца footway — "свободные" и получат собственные рампы.
	var n_SW := _ll(OX - 3, OZ - 220)
	var n_SW_end := _ll(OX - 3, OZ + 220)
	var n_SE := _ll(OX + 3, OZ - 220)
	var n_SE_end := _ll(OX + 3, OZ + 220)

	var n_under_W := _ll(OX - 200, OZ - 50)
	var n_under_E := _ll(OX + 200, OZ - 50)

	var primary_tags := {"highway": "primary", "lanes": "2", "oneway": "yes"}
	var bridge_primary_tags := {"highway": "primary", "lanes": "2", "oneway": "yes", "bridge": "yes", "layer": "1"}
	var bridge_link_tags := {"highway": "secondary_link", "lanes": "1", "oneway": "yes", "bridge": "yes", "layer": "1"}
	var bridge_footway_tags := {"highway": "footway", "bridge": "yes", "layer": "1"}
	var under_road_tags := {"highway": "residential"}

	# Densify every polyline to ~10m node spacing. This ensures each chunk
	# intersecting the polyline gets at least one node in `_clip_way_to_bbox`.
	# Real OSM data is usually sparser, but real `osm_loader` returns ways by
	# geometry intersection via Overpass — fake_osm's clipper is node-based.
	var D := 10.0
	return [
		# --- Главная ось ---
		{"id": 900001, "nodes": _densify(n_S_gnd, n_S_join, D), "tags": primary_tags},
		{"id": 900002, "nodes": _densify(n_S_join, n_BC, D), "tags": bridge_primary_tags},
		{"id": 900003, "nodes": _densify(n_BC, n_C_mid, D) + _densify(n_C_mid, n_CD, D).slice(1), "tags": bridge_primary_tags},
		{"id": 900004, "nodes": _densify(n_CD, n_N_join, D), "tags": bridge_primary_tags},
		{"id": 900005, "nodes": _densify(n_N_join, n_N_gnd, D), "tags": primary_tags},
		# --- Восточный съезд (T-развязка) ---
		{"id": 900010, "nodes": _densify(n_E_gnd, n_E_join, D), "tags": primary_tags},
		{"id": 900011, "nodes": _densify(n_E_join, n_C_mid, D), "tags": bridge_link_tags},
		# --- Тротуары на мосту ---
		{"id": 900020, "nodes": _densify(n_SW, n_SW_end, D), "tags": bridge_footway_tags},
		{"id": 900021, "nodes": _densify(n_SE, n_SE_end, D), "tags": bridge_footway_tags},
		# --- Наземная дорога под мостом (проверка, что мост её не ломает) ---
		{"id": 900030, "nodes": _densify(n_under_W, n_under_E, D), "tags": under_road_tags},
	]


static func _make_suspension_road() -> Array:
	## Прямая дорога 500m с разворотной петлёй
	var nodes := []
	var track_length := 500.0
	var segments := 100

	for i in range(segments + 1):
		var t := float(i) / segments
		nodes.append(_ll(0, t * track_length))

	# Разворотная петля
	var loop_nodes := []
	var loop_radius := 30.0
	var loop_segments := 32

	for i in range(loop_segments + 1):
		var angle := -PI / 2.0 + float(i) / loop_segments * PI
		loop_nodes.append(_ll(loop_radius * cos(angle), track_length + loop_radius * sin(angle)))

	return [
		{"nodes": nodes, "tags": {"highway": "primary", "name": "Suspension Test"}},
		{"nodes": loop_nodes, "tags": {"highway": "primary", "name": "Turnaround"}},
	]


static func _clip_way_to_bbox(nodes: Array, min_lat: float, max_lat: float, min_lon: float, max_lon: float) -> Array:
	## Разбивает way на непрерывные сегменты, где точки попадают в bbox.
	## Каждый сегмент получает +1 точку до и после для плавного продолжения.
	## Way может проходить через bbox несколько раз (напр. овал — правая и левая стороны).
	var result := []
	var current_start := -1

	for i in range(nodes.size()):
		var n = nodes[i]
		var inside: bool = n.lat >= min_lat and n.lat < max_lat and n.lon >= min_lon and n.lon < max_lon
		if inside:
			if current_start < 0:
				current_start = i
		else:
			if current_start >= 0:
				# Закончилась непрерывная группа — вырезаем сегмент с +1 запасом на конце
				var seg_start := maxi(current_start - 1, 0)
				var seg_end := mini(i, nodes.size() - 1)  # i — первая точка ВНЕ bbox
				result.append(nodes.slice(seg_start, seg_end + 1))
				current_start = -1

	# Последняя группа (если way заканчивается внутри bbox)
	if current_start >= 0:
		var seg_start := maxi(current_start - 1, 0)
		result.append(nodes.slice(seg_start, nodes.size()))

	return result


# --- Хелперы ---

static func _bldg(cx: float, cz: float, w: float, d: float, type: String, levels: int) -> Dictionary:
	## Прямоугольное здание с центром (cx, cz) размером w x d
	var hw := w / 2.0
	var hd := d / 2.0
	return {
		"nodes": [
			_ll(cx - hw, cz - hd),
			_ll(cx + hw, cz - hd),
			_ll(cx + hw, cz + hd),
			_ll(cx - hw, cz + hd),
			_ll(cx - hw, cz - hd),
		],
		"tags": {"building": type, "building:levels": str(levels)},
	}


static func _ll(x: float, z: float) -> Dictionary:
	## Локальные метры -> lat/lon (start_lat=0, start_lon=0)
	return {"lat": -z / 111000.0, "lon": x / 111000.0}
