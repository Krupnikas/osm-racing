extends Camera3D

## Низкая гоночная камера - близко к машине, динамичная

@export var target: NodePath
@export var distance := 6.0  # Близко к машине
@export var height := 2.0  # Низко
@export var smooth_speed := 8.0  # Быстрая реакция
@export var rotation_smooth := 5.0  # Быстрое следование за поворотом
@export var fov_base := 70.0
@export var fov_speed_boost := 15.0  # FOV увеличивается на скорости
@export var max_speed_for_fov := 120.0

var _target_node: Node3D
var _car: RigidBody3D  # Может быть VehicleBody3D или GEVP Vehicle
var _yaw := 0.0
var _pitch := 0.25  # Небольшой наклон вниз

func _ready() -> void:
	if target:
		_target_node = get_node(target)
		# Target теперь указывает прямо на Car (RigidBody3D)
		if _target_node is VehicleBody3D or _target_node is RigidBody3D:
			_car = _target_node
	fov = fov_base

func reset_camera() -> void:
	_yaw = 0.0
	_pitch = 0.25

func _physics_process(delta: float) -> void:
	if not _target_node or not current:
		return

	var target_pos := _target_node.global_position + Vector3(0, 0.8, 0)

	# Следуем за поворотом машины (убираем +PI чтобы камера была сзади)
	var target_yaw := _target_node.rotation.y
	_yaw = lerp_angle(_yaw, target_yaw, rotation_smooth * delta)

	# Позиция камеры
	var offset := Vector3.ZERO
	offset.x = sin(_yaw) * cos(_pitch) * distance
	offset.z = cos(_yaw) * cos(_pitch) * distance
	offset.y = sin(_pitch) * distance + height

	var desired_pos := target_pos + offset
	global_position = global_position.lerp(desired_pos, smooth_speed * delta)

	# Смотрим на точку чуть впереди машины
	var look_target := target_pos + _target_node.global_transform.basis.z * 5.0
	look_at(look_target)

	# Динамический FOV
	if _car:
		var speed := _car.linear_velocity.length() * 3.6
		var speed_factor: float = clamp(speed / max_speed_for_fov, 0.0, 1.0)
		var target_fov: float = fov_base + fov_speed_boost * speed_factor
		fov = lerp(fov, target_fov, 5.0 * delta)
