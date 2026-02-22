extends Camera3D

@export var target: NodePath
@export var distance := 3.0
@export var height := 1.7
@export var smooth_speed := 10.0  # Жёсткое следование как у Chase (было 5)
@export var follow_rotation := true  # Камера следует за поворотом машины
@export var rotation_smooth := 4.0   # Быстрое следование за поворотом (было 3)

var _target_node: Node3D
var _yaw := 0.0
var _pitch := 0.35  # Наклон вниз
var _target_yaw := 0.0

func _ready() -> void:
	if target:
		_target_node = get_node(target)

# Сброс камеры в начальное положение
func reset_camera() -> void:
	_yaw = 0.0
	_pitch = 0.35
	_target_yaw = 0.0


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
	print("FollowCamera: Teleported behind car")


func _physics_process(delta: float) -> void:
	if not _target_node:
		return

	var target_pos := _target_node.global_position + Vector3(0, height, 0)

	# Следуем за поворотом машины
	if follow_rotation:
		_target_yaw = _target_node.rotation.y
		_yaw = lerp_angle(_yaw, _target_yaw, rotation_smooth * delta)

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

	# Смотрим на машину
	look_at(target_pos)
