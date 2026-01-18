extends Node
class_name CameraManager

# Управляет переключением между камерами
# C - переключение камеры
# F - режим полёта (для свободной камеры)

signal camera_changed(camera_index: int, camera_name: String)

@export var car_path: NodePath

var cameras: Array[Camera3D] = []
var camera_names: Array[String] = []
var current_camera_index := 0
var _car: Node3D

func _ready() -> void:
	if car_path:
		_car = get_node(car_path)

	# Собираем все камеры
	for child in get_children():
		if child is Camera3D:
			cameras.append(child)
			camera_names.append(child.name)

	if cameras.size() > 0:
		# Найти камеру которая уже current (установлена в сцене)
		for i in range(cameras.size()):
			if cameras[i].current:
				current_camera_index = i
				break
		print("CameraManager: %d cameras available, press C to switch" % cameras.size())

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_C:
			_next_camera()

func _next_camera() -> void:
	if cameras.size() == 0:
		return

	current_camera_index = (current_camera_index + 1) % cameras.size()
	_activate_camera(current_camera_index)

func _activate_camera(index: int) -> void:
	for i in range(cameras.size()):
		cameras[i].current = (i == index)

	var cam_name := camera_names[index]
	print("Camera: %s" % cam_name)
	camera_changed.emit(index, cam_name)
