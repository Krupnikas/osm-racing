extends Camera3D

@export var target: NodePath
@export var distance := 10.0
@export var min_distance := 3.0
@export var max_distance := 30.0
@export var height := 5.0
@export var smooth_speed := 5.0
@export var mouse_sensitivity := 0.003
@export var zoom_speed := 1.0
@export var fly_speed := 20.0
@export var fly_speed_fast := 60.0
@export var follow_rotation := true  # Камера следует за поворотом машины
@export var rotation_smooth := 3.0   # Скорость следования за поворотом

var _target_node: Node3D
var _yaw := 0.0      # Горизонтальный угол (вокруг Y)
var _pitch := 0.3    # Вертикальный угол (наклон вниз)
var _fly_mode := false  # Режим свободного полёта
var _target_yaw := 0.0  # Целевой угол от машины
var _yaw_offset := 0.0  # Смещение от мыши
var _mouse_return_speed := 2.0  # Скорость возврата смещения мыши

func _ready() -> void:
	if target:
		_target_node = get_node(target)
	# Мышь управляется через MainMenu, не захватываем здесь

# Сброс камеры в начальное положение
func reset_camera() -> void:
	_yaw = 0.0
	_pitch = 0.3
	_yaw_offset = 0.0
	_fly_mode = false
	_target_yaw = 0.0

func _input(event: InputEvent) -> void:
	# Игнорируем мышь когда меню открыто
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return

	# Управление мышью
	if event is InputEventMouseMotion:
		if follow_rotation and not _fly_mode:
			# В режиме следования мышь создаёт временное смещение
			_yaw_offset -= event.relative.x * mouse_sensitivity
			_yaw_offset = clamp(_yaw_offset, -PI, PI)
		else:
			_yaw -= event.relative.x * mouse_sensitivity
		_pitch += event.relative.y * mouse_sensitivity
		_pitch = clamp(_pitch, -0.2, 1.2)

	# Зум колёсиком
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			distance = max(min_distance, distance - zoom_speed)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			distance = min(max_distance, distance + zoom_speed)

	# Клавиши
	if event is InputEventKey and event.pressed:
		# Escape для освобождения мыши
		if event.keycode == KEY_ESCAPE:
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			else:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		# F - переключение режима полёта
		elif event.keycode == KEY_F:
			_fly_mode = not _fly_mode
			if _fly_mode:
				print("Camera: Fly mode ON (WASD + QE to move, Shift for fast)")
			else:
				print("Camera: Follow mode ON")

func _physics_process(delta: float) -> void:
	if _fly_mode:
		_process_fly_mode(delta)
	else:
		_process_follow_mode(delta)

func _process_fly_mode(delta: float) -> void:
	# Определяем скорость (Shift для быстрого движения)
	var speed := fly_speed_fast if Input.is_key_pressed(KEY_SHIFT) else fly_speed

	# Направление движения на основе углов камеры
	var forward := Vector3(-sin(_yaw), 0, -cos(_yaw)).normalized()
	var right := Vector3(cos(_yaw), 0, -sin(_yaw)).normalized()
	var up := Vector3.UP

	var velocity := Vector3.ZERO

	# WASD для горизонтального движения
	if Input.is_key_pressed(KEY_W):
		velocity += forward
	if Input.is_key_pressed(KEY_S):
		velocity -= forward
	if Input.is_key_pressed(KEY_A):
		velocity -= right
	if Input.is_key_pressed(KEY_D):
		velocity += right
	# Q/E для вертикального движения
	if Input.is_key_pressed(KEY_Q):
		velocity -= up
	if Input.is_key_pressed(KEY_E):
		velocity += up

	if velocity.length() > 0:
		velocity = velocity.normalized() * speed

	global_position += velocity * delta

	# Обновляем направление взгляда
	var look_dir := Vector3(-sin(_yaw) * cos(_pitch), -sin(_pitch), -cos(_yaw) * cos(_pitch))
	look_at(global_position + look_dir)

func _process_follow_mode(delta: float) -> void:
	if not _target_node:
		return

	var target_pos := _target_node.global_position + Vector3(0, 1, 0)

	# Если включено следование за поворотом машины
	if follow_rotation:
		# Получаем угол поворота машины (убираем +PI чтобы камера была сзади)
		_target_yaw = _target_node.rotation.y
		# Плавно интерполируем угол камеры к углу машины + смещение от мыши
		_yaw = lerp_angle(_yaw, _target_yaw + _yaw_offset, rotation_smooth * delta)
		# Плавно возвращаем смещение мыши к нулю
		_yaw_offset = lerp(_yaw_offset, 0.0, _mouse_return_speed * delta)

	# Вычисляем позицию камеры на основе углов (камера сзади машины)
	var offset := Vector3.ZERO
	offset.x = sin(_yaw) * cos(_pitch) * distance
	offset.z = cos(_yaw) * cos(_pitch) * distance
	offset.y = sin(_pitch) * distance

	var desired_pos := target_pos + offset

	# Плавное перемещение
	global_position = global_position.lerp(desired_pos, smooth_speed * delta)

	# Смотрим на цель
	look_at(target_pos)
