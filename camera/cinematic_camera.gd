extends Camera3D

## Кинематографическая камера - выше, плавнее, эпичный вид

@export var target: NodePath
@export var distance := 4.0  # Ближе к машине (было 12)
@export var height := 1.5  # Ниже (было 4)
@export var smooth_speed := 6.0  # Быстрее следует за машиной
@export var rotation_smooth := 4.0  # Быстрее следует за поворотом
@export var look_ahead := 8.0  # Смотрим вперёд по движению

var _target_node: Node3D
var _car: RigidBody3D  # Может быть VehicleBody3D или GEVP Vehicle
var _yaw := 0.0
var _pitch := 0.15  # Более горизонтальный угол (было 0.35)

func _ready() -> void:
	if target:
		_target_node = get_node(target)
		# Для GEVP - target это VehicleController, машина внутри
		if _target_node is VehicleBody3D or _target_node is RigidBody3D:
			_car = _target_node
		elif _target_node.has_node("Car"):
			_car = _target_node.get_node("Car")
	fov = 60.0  # Широкий угол для эпичности

func reset_camera() -> void:
	_yaw = 0.0
	_pitch = 0.15

func _physics_process(delta: float) -> void:
	if not _target_node or not current:
		return

	var target_pos := _target_node.global_position + Vector3(0, 1.0, 0)

	# Медленно следуем за поворотом - камера "отстаёт" от машины
	var target_yaw := _target_node.rotation.y + PI
	_yaw = lerp_angle(_yaw, target_yaw, rotation_smooth * delta)

	# Позиция камеры
	var offset := Vector3.ZERO
	offset.x = sin(_yaw) * cos(_pitch) * distance
	offset.z = cos(_yaw) * cos(_pitch) * distance
	offset.y = sin(_pitch) * distance + height

	var desired_pos := target_pos + offset
	global_position = global_position.lerp(desired_pos, smooth_speed * delta)

	# Смотрим вперёд по направлению движения машины
	var forward := _target_node.global_transform.basis.z
	var look_target := target_pos + forward * look_ahead
	look_at(look_target)
