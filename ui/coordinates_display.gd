extends Label

@export var car_path: NodePath
@export var start_lat := 59.149886
@export var start_lon := 37.949370

var _car: Node3D

func _ready() -> void:
	if car_path:
		_car = get_node(car_path)

func _process(_delta: float) -> void:
	if not _car:
		return

	var pos := _car.global_position
	var coords := local_to_latlon(pos.x, pos.z)

	text = "Lat: %.6f\nLon: %.6f\nAlt: %.1fm" % [coords.x, coords.y, pos.y]

func local_to_latlon(x: float, z: float) -> Vector2:
	# Обратная конвертация из локальных метров в lat/lon
	var lat := start_lat + z / 111000.0
	var lon := start_lon + x / (111000.0 * cos(deg_to_rad(start_lat)))
	return Vector2(lat, lon)
