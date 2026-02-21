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


static func _make_building(cx: float, cz: float, w: float, d: float, tags: Dictionary) -> Dictionary:
	## Создаёт прямоугольное здание с центром (cx, cz) размером w x d
	var hw := w / 2.0
	var hd := d / 2.0
	return {
		"nodes": [
			_local_to_latlon(cx - hw, cz - hd),
			_local_to_latlon(cx + hw, cz - hd),
			_local_to_latlon(cx + hw, cz + hd),
			_local_to_latlon(cx - hw, cz + hd),
			_local_to_latlon(cx - hw, cz - hd),  # Замыкаем
		],
		"tags": tags,
	}


static func _local_to_latlon(x: float, z: float) -> Dictionary:
	## Конвертирует локальные метры в lat/lon (start_lat=0, start_lon=0)
	## _latlon_to_local делает: dx = (lon - start_lon) * 111000 * cos(lat), dz = -(lat - start_lat) * 111000
	## Обратно: lon = x / 111000, lat = -z / 111000
	return {"lat": -z / 111000.0, "lon": x / 111000.0}
