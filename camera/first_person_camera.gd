extends Camera3D

# Камера от первого лица (вид из машины)

@export var target: NodePath
@export var offset := Vector3(0, 0.8, 0.5)  # Позиция внутри машины
@export var look_ahead := 10.0  # Смотрим вперёд

var _target_node: Node3D

func _ready() -> void:
	if target:
		_target_node = get_node(target)

func _physics_process(_delta: float) -> void:
	if not _target_node or not current:
		return

	# Позиция относительно машины
	var car_transform := _target_node.global_transform
	global_position = car_transform * offset

	# Смотрим в направлении движения машины
	var forward := -car_transform.basis.z
	look_at(global_position + forward * look_ahead, Vector3.UP)
