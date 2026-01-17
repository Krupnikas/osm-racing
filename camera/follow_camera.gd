extends Camera3D

@export var target: NodePath
@export var distance := 10.0
@export var min_distance := 3.0
@export var max_distance := 30.0
@export var height := 5.0
@export var smooth_speed := 5.0
@export var mouse_sensitivity := 0.003
@export var zoom_speed := 1.0

var _target_node: Node3D
var _yaw := 0.0      # Горизонтальный угол (вокруг Y)
var _pitch := 0.3    # Вертикальный угол (наклон вниз)

func _ready() -> void:
	if target:
		_target_node = get_node(target)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _input(event: InputEvent) -> void:
	# Управление мышью
	if event is InputEventMouseMotion:
		_yaw -= event.relative.x * mouse_sensitivity
		_pitch -= event.relative.y * mouse_sensitivity
		_pitch = clamp(_pitch, -0.2, 1.2)  # Ограничиваем наклон

	# Зум колёсиком
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			distance = max(min_distance, distance - zoom_speed)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			distance = min(max_distance, distance + zoom_speed)

	# Escape для освобождения мыши
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_ESCAPE:
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			else:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _physics_process(delta: float) -> void:
	if not _target_node:
		return

	var target_pos := _target_node.global_position + Vector3(0, 1, 0)

	# Вычисляем позицию камеры на основе углов
	var offset := Vector3.ZERO
	offset.x = sin(_yaw) * cos(_pitch) * distance
	offset.z = cos(_yaw) * cos(_pitch) * distance
	offset.y = sin(_pitch) * distance

	var desired_pos := target_pos + offset

	# Плавное перемещение
	global_position = global_position.lerp(desired_pos, smooth_speed * delta)

	# Смотрим на цель
	look_at(target_pos)
