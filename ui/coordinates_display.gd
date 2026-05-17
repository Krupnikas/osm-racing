extends Label

@export var car_path: NodePath
@export var start_lat := 59.149886
@export var start_lon := 37.949370

var _car: Node3D
var _terrain_gen: Node3D
var _chunk_size := 300.0

func _ready() -> void:
	if car_path:
		_car = get_node(car_path)
	# Находим terrain generator для синхронизации координат
	_terrain_gen = get_tree().current_scene.find_child("OSMTerrain", true, false)
	if _terrain_gen and _terrain_gen.get_script():
		start_lat = _terrain_gen.start_lat
		start_lon = _terrain_gen.start_lon
		_chunk_size = _terrain_gen.chunk_size

func _process(_delta: float) -> void:
	if not is_instance_valid(_car):
		if car_path:
			_car = get_node_or_null(car_path)
		if not _car:
			return

	# Синхронизируем координаты с terrain generator (могут обновиться после загрузки)
	if _terrain_gen and _terrain_gen.get_script():
		start_lat = _terrain_gen.start_lat
		start_lon = _terrain_gen.start_lon

	var pos := _car.global_position
	var coords := local_to_latlon(pos.x, pos.z)

	# Вычисляем индекс чанка
	var chunk_x := int(floor(pos.x / _chunk_size))
	var chunk_z := int(floor(pos.z / _chunk_size))

	text = "Lat: %.6f  Lon: %.6f\nChunk: %d,%d  Alt: %.1fm" % [coords.x, coords.y, chunk_x, chunk_z, pos.y]

func local_to_latlon(x: float, z: float) -> Vector2:
	# Add world offset to get absolute coords before converting to lat/lon
	var abs_x := x
	var abs_z := z
	if _terrain_gen and _terrain_gen.has_method("get_world_offset"):
		var wo: Vector2 = _terrain_gen.get_world_offset()
		abs_x += wo.x
		abs_z += wo.y
	var lat := start_lat - abs_z / 111000.0
	var lon := start_lon + abs_x / (111000.0 * cos(deg_to_rad(start_lat)))
	return Vector2(lat, lon)
