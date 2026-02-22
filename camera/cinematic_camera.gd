extends Camera3D

## Кинематографическая камера - выше, плавнее, эпичный вид

@export var target: NodePath
@export var distance := 3.0
@export var height := 1.3
@export var smooth_speed := 10.0  # Жёсткое следование как у Chase (было 8)
@export var rotation_smooth := 4.0  # Быстрое следование за поворотом
@export var look_ahead := 3.0  # Смотрим чуть вперёд по движению (было 8 — слишком далеко)

var _target_node: Node3D
var _car: RigidBody3D
var _yaw := 0.0
var _pitch := 0.4  # Наклон вниз

func _ready() -> void:
	if target:
		_target_node = get_node(target)
		if _target_node is VehicleBody3D or _target_node is RigidBody3D:
			_car = _target_node
	fov = 60.0

func reset_camera() -> void:
	_yaw = 0.0
	_pitch = 0.4


func teleport_to_target() -> void:
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
	print("CinematicCamera: Teleported behind car")


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
	if to_cam.length() > 7.0:
		global_position = _target_node.global_position + to_cam.normalized() * 7.0

	if not current:
		return

	# Смотрим чуть вперёд по направлению машины
	var forward := -_target_node.global_transform.basis.z
	var look_target := target_pos + forward * look_ahead
	look_at(look_target)
