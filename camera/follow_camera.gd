extends Camera3D

@export var target: NodePath
@export var offset := Vector3(0, 5, -10)
@export var smooth_speed := 5.0

var _target_node: Node3D

func _ready() -> void:
	if target:
		_target_node = get_node(target)

func _physics_process(delta: float) -> void:
	if not _target_node:
		return

	var target_pos := _target_node.global_position
	var desired_pos := target_pos + offset

	global_position = global_position.lerp(desired_pos, smooth_speed * delta)
	look_at(target_pos + Vector3(0, 1, 0))
