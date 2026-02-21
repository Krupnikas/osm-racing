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
		if tags.has("highway"):
			# Дороги: находим непрерывные группы точек внутри bbox
			# Way может проходить через чанк несколько раз (напр. правая и левая прямые овала)
			var segments := _clip_way_to_bbox(nodes, min_lat, max_lat, min_lon, max_lon)
			for seg in segments:
				filtered_ways.append({
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
