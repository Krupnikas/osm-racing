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
		"test_elevation":
			all_ways.append_array(_make_oval_road())
			all_ways.append_array(_make_elevation_buildings())

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
		# Для дорог: привязываем к чанку по первой точке (одна дорога → один чанк)
		# Для зданий: привязываем к чанку по центру
		var tags: Dictionary = way.get("tags", {})
		if tags.has("highway"):
			var first_node = nodes[0]
			if first_node.lat >= min_lat and first_node.lat < max_lat and first_node.lon >= min_lon and first_node.lon < max_lon:
				filtered_ways.append(way)
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


static func get_elevation(track_id: String, chunk_key: String, _chunk_lat: float, _chunk_lon: float) -> Dictionary:
	match track_id:
		"test_suspension":
			return _make_suspension_elevation(chunk_key, _chunk_lat, _chunk_lon)
		"test_elevation":
			return _make_terrain_elevation(chunk_key, _chunk_lat, _chunk_lon)
	return {}


static func get_height_at(track_id: String, x: float, z: float) -> float:
	## Высота terrain в локальных координатах (метры)
	match track_id:
		"test_elevation":
			return _terrain_height(x, z)
		"test_suspension":
			return _suspension_height(z)
	return 0.0


# --- Дороги ---

static func _make_oval_road() -> Array:
	## Овальный трек: 2 прямые (300m) + 2 полукруга (radius=80m)
	var nodes := []
	var straight_length := 300.0
	var turn_radius := 80.0
	var segments := 64
	var half_straight := straight_length / 2.0
	var straight_steps := 30

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


# --- Здания ---

static func _make_elevation_buildings() -> Array:
	## Здания вокруг овальной трассы
	## Овал: прямые X=±80, Z=-150..+150, повороты radius=80
	return [
		# Внутри овала — небольшие дома
		_bldg(20, -80, 15, 10, "house", 2),
		_bldg(-30, -60, 12, 12, "house", 1),
		_bldg(10, 0, 18, 12, "residential", 5),
		_bldg(-25, 40, 14, 10, "house", 2),
		_bldg(30, 80, 16, 11, "detached", 2),
		_bldg(-10, 120, 20, 14, "apartments", 9),
		# Снаружи овала — крупнее
		_bldg(120, -100, 25, 15, "apartments", 9),
		_bldg(130, -40, 30, 12, "residential", 5),
		_bldg(125, 50, 20, 20, "commercial", 3),
		_bldg(135, 120, 22, 14, "residential", 5),
		_bldg(-120, -80, 18, 12, "house", 2),
		_bldg(-130, 0, 28, 16, "apartments", 7),
		_bldg(-125, 90, 24, 14, "residential", 4),
	]


# --- Elevation ---

static func _make_suspension_elevation(chunk_key: String, _chunk_lat: float, _chunk_lon: float) -> Dictionary:
	var grid_size := 32
	var chunk_size := 300.0

	var parts := chunk_key.split(",")
	var chunk_origin_x := int(parts[0]) * chunk_size
	var chunk_origin_z := int(parts[1]) * chunk_size

	var grid := []
	var min_elev := 0.0
	var max_elev := 0.0

	for gz in range(grid_size):
		var row := []
		for gx in range(grid_size):
			var _world_x := chunk_origin_x + float(gx) / (grid_size - 1) * chunk_size
			var world_z := chunk_origin_z + float(gz) / (grid_size - 1) * chunk_size
			var h := _suspension_height(world_z)
			row.append(h)
			min_elev = min(min_elev, h)
			max_elev = max(max_elev, h)
		grid.append(row)

	return {
		"grid": grid,
		"grid_size": grid_size,
		"center_lat": _chunk_lat,
		"center_lon": _chunk_lon,
		"min_elevation": min_elev,
		"max_elevation": max_elev,
	}


static func _make_terrain_elevation(chunk_key: String, _chunk_lat: float, _chunk_lon: float) -> Dictionary:
	var grid_size := 32
	var chunk_size := 300.0

	var parts := chunk_key.split(",")
	var chunk_origin_x := int(parts[0]) * chunk_size
	var chunk_origin_z := int(parts[1]) * chunk_size

	var grid := []
	var min_elev := 0.0
	var max_elev := 0.0

	for gz in range(grid_size):
		var row := []
		for gx in range(grid_size):
			var world_x := chunk_origin_x + float(gx) / (grid_size - 1) * chunk_size
			var world_z := chunk_origin_z + float(gz) / (grid_size - 1) * chunk_size
			var h := _terrain_height(world_x, world_z)
			row.append(h)
			min_elev = min(min_elev, h)
			max_elev = max(max_elev, h)
		grid.append(row)

	return {
		"grid": grid,
		"grid_size": grid_size,
		"center_lat": _chunk_lat,
		"center_lon": _chunk_lon,
		"min_elevation": min_elev,
		"max_elevation": max_elev,
	}


static func _terrain_height(x: float, z: float) -> float:
	## Холмистый рельеф
	# Холмы из суммы синусов разных частот
	var h := sin(x * 0.02) * sin(z * 0.015) * 8.0
	h += sin(x * 0.04 + 1.0) * sin(z * 0.03 + 2.0) * 4.0
	h += sin(x * 0.01 + z * 0.008) * 12.0
	return h


static func _dist_to_oval(x: float, z: float, radius: float, half_straight: float) -> float:
	## Приблизительное расстояние от точки до овальной трассы
	if z >= -half_straight and z <= half_straight:
		# В зоне прямых — расстояние до ближайшей прямой
		return min(abs(x - radius), abs(x + radius))
	elif z > half_straight:
		# Верхний полукруг — расстояние до дуги
		var dx := x
		var dz := z - half_straight
		return abs(sqrt(dx * dx + dz * dz) - radius)
	else:
		# Нижний полукруг
		var dx := x
		var dz := z + half_straight
		return abs(sqrt(dx * dx + dz * dz) - radius)


static func _suspension_height(z: float) -> float:
	if z < 50.0:
		return 0.0
	if z < 150.0:
		var lz := z - 50.0
		return sin(lz * 0.5) * 0.15 + sin(lz * 1.2) * 0.08
	if z < 200.0:
		return 0.0
	if z < 300.0:
		var lz := z - 200.0
		return sin(lz * 0.08) * 0.8 + sin(lz * 0.15) * 0.3
	if z < 350.0:
		return 0.0
	if z < 450.0:
		var lz := z - 350.0
		var h := sin(lz * 0.3) * 0.5
		var pit := fmod(lz, 20.0)
		if pit < 3.0:
			h -= 0.3 * sin(pit / 3.0 * PI)
		return h
	var lz := z - 450.0
	var blend := clampf(lz / 50.0, 0.0, 1.0)
	var prev_h := sin((z - 450.0) * 0.3) * 0.5
	return prev_h * (1.0 - blend)


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
