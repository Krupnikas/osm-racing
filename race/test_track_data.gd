extends Node
class_name TestTrackData

## Захардкоженные OSM-данные для тестовых трасс
## Формат идентичен тому что возвращает osm_loader.gd

## Координатная система: start_lat=0, start_lon=0, cos(0)=1
## _latlon_to_local: dx = lon * 111000, dz = -lat * 111000
## Обратно: lat = -z / 111000, lon = x / 111000


static func get_flat_track_data(_chunk_lat: float, _chunk_lon: float, _chunk_size: float) -> Dictionary:
	## Овальный трек: 2 прямые (300m) + 2 полукруга (radius=80m)
	## Ширина дороги определяется тегом highway (primary = 12m)
	var nodes := []
	var straight_length := 300.0
	var turn_radius := 80.0
	var segments := 64
	var half_straight := straight_length / 2.0
	var straight_steps := 30

	# Правая прямая: X = +radius, Z от -half_straight до +half_straight
	for i in range(straight_steps + 1):
		var t := float(i) / straight_steps
		var z := -half_straight + t * straight_length
		nodes.append(_local_to_latlon(turn_radius, z))

	# Верхний полукруг: от правой прямой к левой
	for i in range(1, segments + 1):
		var angle := float(i) / segments * PI
		var x := turn_radius * cos(angle)
		var z := half_straight + turn_radius * sin(angle)
		nodes.append(_local_to_latlon(x, z))

	# Левая прямая: X = -radius, Z от +half_straight до -half_straight
	for i in range(1, straight_steps + 1):
		var t := float(i) / straight_steps
		var z := half_straight - t * straight_length
		nodes.append(_local_to_latlon(-turn_radius, z))

	# Нижний полукруг: от левой прямой к правой
	for i in range(1, segments):
		var angle := PI + float(i) / segments * PI
		var x := turn_radius * cos(angle)
		var z := -half_straight + turn_radius * sin(angle)
		nodes.append(_local_to_latlon(x, z))

	# Замыкаем овал
	nodes.append(nodes[0])

	return {
		"ways": [
			{
				"nodes": nodes,
				"tags": {"highway": "primary", "name": "Test Oval"},
			}
		],
		"point_objects": [],
		"entrance_nodes": [],
		"poi_nodes": [],
	}


static func get_suspension_track_data(_chunk_lat: float, _chunk_lon: float, _chunk_size: float) -> Dictionary:
	## Прямая дорога 500m с разворотной петлёй в конце
	var nodes := []
	var track_length := 500.0
	var segments := 100

	# Прямая Z=0..500
	for i in range(segments + 1):
		var t := float(i) / segments
		var z := t * track_length
		nodes.append(_local_to_latlon(0, z))

	# Разворотная петля (полукруг radius=30m в конце)
	var loop_nodes := []
	var loop_radius := 30.0
	var loop_segments := 32
	var loop_center_z := track_length

	for i in range(loop_segments + 1):
		var angle := -PI / 2.0 + float(i) / loop_segments * PI
		var x := loop_radius * cos(angle)
		var z := loop_center_z + loop_radius * sin(angle)
		loop_nodes.append(_local_to_latlon(x, z))

	return {
		"ways": [
			{
				"nodes": nodes,
				"tags": {"highway": "primary", "name": "Suspension Test"},
			},
			{
				"nodes": loop_nodes,
				"tags": {"highway": "primary", "name": "Turnaround"},
			}
		],
		"point_objects": [],
		"entrance_nodes": [],
		"poi_nodes": [],
	}


static func get_suspension_elevation(chunk_key: String, _chunk_lat: float, _chunk_lon: float) -> Dictionary:
	## Elevation grid с бугорками для теста подвески
	## Grid покрывает чанк 300x300m, разрешение 32x32
	var grid_size := 32
	var chunk_size := 300.0

	# Парсим chunk_key для определения позиции чанка
	var parts := chunk_key.split(",")
	var chunk_x := int(parts[0])
	var chunk_z := int(parts[1])
	var chunk_origin_x := chunk_x * chunk_size
	var chunk_origin_z := chunk_z * chunk_size

	var grid := []
	var min_elev := 0.0
	var max_elev := 0.0

	for gz in range(grid_size):
		var row := []
		for gx in range(grid_size):
			# Мировые координаты точки
			var _world_x := chunk_origin_x + float(gx) / (grid_size - 1) * chunk_size
			var world_z := chunk_origin_z + float(gz) / (grid_size - 1) * chunk_size

			# Бугорки только вдоль Z (дорога идёт по X=0, Z=0..500)
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


static func _suspension_height(z: float) -> float:
	## Профиль бугорков (перенесено из test_track_generator.gd)
	# Первые 50м — ровная дорога (разгон)
	if z < 50.0:
		return 0.0

	# 50-150м: мелкие бугорки (speed bumps)
	if z < 150.0:
		var local_z := z - 50.0
		return sin(local_z * 0.5) * 0.15 + sin(local_z * 1.2) * 0.08

	# 150-200м: ровный участок
	if z < 200.0:
		return 0.0

	# 200-300м: крупные волны
	if z < 300.0:
		var local_z := z - 200.0
		return sin(local_z * 0.08) * 0.8 + sin(local_z * 0.15) * 0.3

	# 300-350м: ровный
	if z < 350.0:
		return 0.0

	# 350-450м: ямы и бугры (жёсткий тест)
	if z < 450.0:
		var local_z := z - 350.0
		var h := sin(local_z * 0.3) * 0.5
		# Резкие ямы каждые 20м
		var pit := fmod(local_z, 20.0)
		if pit < 3.0:
			h -= 0.3 * sin(pit / 3.0 * PI)
		return h

	# Последние 50м — выравнивание
	var local_z := z - 450.0
	var blend := clampf(local_z / 50.0, 0.0, 1.0)
	var prev_h := sin((z - 350.0 - 100.0) * 0.3) * 0.5
	return prev_h * (1.0 - blend)


static func _local_to_latlon(x: float, z: float) -> Dictionary:
	## Конвертирует локальные метры в lat/lon (start_lat=0, start_lon=0)
	## _latlon_to_local делает: dx = (lon - start_lon) * 111000 * cos(lat), dz = -(lat - start_lat) * 111000
	## Обратно: lon = x / 111000, lat = -z / 111000
	return {"lat": -z / 111000.0, "lon": x / 111000.0}
