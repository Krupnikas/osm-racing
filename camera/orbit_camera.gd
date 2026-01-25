extends Camera3D

## Орбитальная камера - можно вращать мышкой и она остаётся в заданном положении

@export var target: NodePath
@export var distance := 8.0
@export var min_distance := 3.0
@export var max_distance := 30.0
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

	# Начальная позиция - сзади машины
	_yaw = 0.0
	_pitch = 0.3

func reset_camera() -> void:
	_yaw = 0.0
	_pitch = 0.3

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
	if not _target_node or not current:
		return

	# Целевая позиция - центр машины
	var target_pos := _target_node.global_position + Vector3(0, 1, 0)

	# Вычисляем позицию камеры относительно машины
	# Добавляем rotation.y машины к углу камеры для привязки к машине
	var car_yaw := _target_node.rotation.y
	var absolute_yaw := car_yaw + _yaw

	var offset := Vector3.ZERO
	offset.x = sin(absolute_yaw) * cos(_pitch) * distance
	offset.z = cos(absolute_yaw) * cos(_pitch) * distance
	offset.y = sin(_pitch) * distance

	var desired_pos := target_pos + offset

	# Плавное перемещение
	global_position = global_position.lerp(desired_pos, smooth_speed * delta)

	# Смотрим на машину
	look_at(target_pos)
