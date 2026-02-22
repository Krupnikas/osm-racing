extends Camera3D

## Низкая гоночная камера - близко к машине, динамичная

@export var target: NodePath
@export var distance := 4.0
@export var height := 1.5
@export var smooth_speed := 12.0  # Жёсткое следование, камера не отлетает
@export var rotation_smooth := 5.0  # Быстрое следование за поворотом
@export var fov_base := 65.0
@export var fov_speed_boost := 35.0  # Эффект скорости через FOV (65→100)
@export var max_speed_for_fov := 120.0

var _target_node: Node3D
var _car: RigidBody3D  # Может быть VehicleBody3D или GEVP Vehicle
var _yaw := 0.0
var _pitch := 0.25  # Небольшой наклон вниз

func _ready() -> void:
	if target:
		_target_node = get_node(target)
		if _target_node is VehicleBody3D or _target_node is RigidBody3D:
			_car = _target_node
	fov = fov_base

func reset_camera() -> void:
	_yaw = 0.0
	_pitch = 0.25


func teleport_to_target() -> void:
	"""Мгновенно телепортировать камеру за машину"""
	if not _target_node:
		return

	_yaw = _target_node.rotation.y

	var target_pos := _target_node.global_position + Vector3(0, height, 0)

	var offset := Vector3.ZERO
	offset.x = sin(_yaw) * cos(_pitch) * distance
	offset.z = cos(_yaw) * cos(_pitch) * distance
	offset.y = sin(_pitch) * distance

	global_position = target_pos + offset
	look_at(target_pos)
	print("ChaseCamera: Teleported behind car")


func _physics_process(delta: float) -> void:
	if not _target_node:
		return

	var target_pos := _target_node.global_position + Vector3(0, height, 0)

	# Следуем за поворотом машины
	var target_yaw := _target_node.rotation.y
	_yaw = lerp_angle(_yaw, target_yaw, rotation_smooth * delta)

	# Позиция камеры (сзади машины)
	var offset := Vector3.ZERO
	offset.x = sin(_yaw) * cos(_pitch) * distance
	offset.z = cos(_yaw) * cos(_pitch) * distance
	offset.y = sin(_pitch) * distance

	var desired_pos := target_pos + offset
	global_position = global_position.lerp(desired_pos, smooth_speed * delta)

	# Жёсткий лимит — камера не дальше 5м от машины
	var to_cam := global_position - _target_node.global_position
	if to_cam.length() > 5.0:
		global_position = _target_node.global_position + to_cam.normalized() * 5.0

	if not current:
		return

	# Смотрим на машину
	look_at(target_pos)

	# Динамический FOV
	if _car:
		var speed := _car.linear_velocity.length() * 3.6
		var speed_factor: float = clamp(speed / max_speed_for_fov, 0.0, 1.0)
		var target_fov: float = fov_base + fov_speed_boost * speed_factor
		fov = lerp(fov, target_fov, 5.0 * delta)
