extends Camera3D

## Орбитальная камера - можно вращать мышкой и она остаётся в заданном положении

@export var target: NodePath
@export var distance := 5.0
@export var min_distance := 2.0
@export var max_distance := 5.0
@export var smooth_speed := 8.0
@export var mouse_sensitivity := 0.005
@export var zoom_speed := 1.0

var _target_node: Node3D
var _car: RigidBody3D  # Для GEVP Vehicle
var _yaw := 0.0      # Горизонтальный угол относительно машины
var _pitch := 0.3    # Вертикальный угол (наклон)
var _mouse_captured := false

func _ready() -> void:
	if target:
		_target_node = get_node(target)
		if _target_node is VehicleBody3D or _target_node is RigidBody3D:
			_car = _target_node

	# Начальная позиция - сзади машины (yaw=0 = сзади относительно машины)
	_yaw = 0.0
	_pitch = 0.3

func reset_camera() -> void:
	# Сброс только pitch, yaw не трогаем - он изменяется только мышкой
	_pitch = 0.3
	# _yaw остаётся как есть


func teleport_to_target() -> void:
	"""Мгновенно телепортировать камеру к цели (без интерполяции).
	Вызывать после телепортации машины!"""
	if not _target_node:
		return

	# ВАЖНО: Устанавливаем _yaw равным углу поворота машины + PI (сзади машины)
	# Это гарантирует что камера будет сзади машины после телепортации
	_yaw = _target_node.global_rotation.y + PI

	var target_pos := _target_node.global_position + Vector3(0, 1, 0)

	# Вычисляем позицию камеры
	var offset := Vector3.ZERO
	offset.x = sin(_yaw) * cos(_pitch) * distance
	offset.z = cos(_yaw) * cos(_pitch) * distance
	offset.y = sin(_pitch) * distance

	# Мгновенно устанавливаем позицию
	global_position = target_pos + offset
	look_at(target_pos)
	print("OrbitCamera: Teleported behind car (yaw=%.2f)" % _yaw)

func _input(event: InputEvent) -> void:
	if not current:
		return

	# Захват/освобождение мыши правой кнопкой
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed:
				_mouse_captured = true
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			else:
				_mouse_captured = false
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

		# Зум колёсиком
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			distance = max(min_distance, distance - zoom_speed)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			distance = min(max_distance, distance + zoom_speed)

	# Вращение мышкой (только если захвачена)
	if event is InputEventMouseMotion and _mouse_captured:
		_yaw -= event.relative.x * mouse_sensitivity
		_pitch += event.relative.y * mouse_sensitivity
		_pitch = clamp(_pitch, -1.0, 1.4)  # Ограничиваем наклон

func _physics_process(delta: float) -> void:
	if not _target_node:
		return

	# Целевая позиция - центр машины
	var target_pos := _target_node.global_position + Vector3(0, 1, 0)

	# Вычисляем позицию камеры в мировых координатах
	# _yaw - абсолютный угол в мире, изменяется только мышкой
	var offset := Vector3.ZERO
	offset.x = sin(_yaw) * cos(_pitch) * distance
	offset.z = cos(_yaw) * cos(_pitch) * distance
	offset.y = sin(_pitch) * distance

	var desired_pos := target_pos + offset

	# Плавное перемещение
	global_position = global_position.lerp(desired_pos, smooth_speed * delta)

	# Жёсткий лимит — камера не дальше 5м от машины
	var to_cam := global_position - _target_node.global_position
	if to_cam.length() > 5.0:
		global_position = _target_node.global_position + to_cam.normalized() * 5.0

	if not current:
		return

	# Смотрим на машину
	look_at(target_pos)
