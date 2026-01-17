extends Camera3D

# Камера сверху (вид сверху вниз)

@export var target: NodePath
@export var height := 50.0
@export var smooth_speed := 3.0

var _target_node: Node3D

func _ready() -> void:
	if target:
		_target_node = get_node(target)

func _physics_process(delta: float) -> void:
	if not _target_node or not current:
		return

	var target_pos := _target_node.global_position
	var desired_pos := Vector3(target_pos.x, height, target_pos.z)

	global_position = global_position.lerp(desired_pos, smooth_speed * delta)
	rotation_degrees = Vector3(-90, 0, 0)  # Смотрим вниз
