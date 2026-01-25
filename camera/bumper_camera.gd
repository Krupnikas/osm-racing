extends Camera3D

# Камера в стиле NFS Underground - низкая, на уровне бампера
# Создаёт ощущение скорости и близости к дороге

@export var target: NodePath
@export var offset := Vector3(0, 0.4, 2.5)  # Низко, на капоте
@export var look_ahead := 15.0  # Смотрим далеко вперёд
@export var fov_base := 75.0  # Базовый FOV
@export var fov_speed_boost := 20.0  # Добавка к FOV на скорости
@export var max_speed_for_fov := 150.0  # Скорость для максимального FOV

var _target_node: Node3D
var _car: RigidBody3D  # Может быть VehicleBody3D или GEVP Vehicle

func _ready() -> void:
	if target:
		_target_node = get_node(target)
		# Target теперь указывает прямо на Car (RigidBody3D)
		if _target_node is VehicleBody3D or _target_node is RigidBody3D:
			_car = _target_node
	fov = fov_base

func _physics_process(delta: float) -> void:
	if not _target_node or not current:
		return

	# Позиция относительно машины
	var car_transform := _target_node.global_transform
	global_position = car_transform * offset

	# Смотрим вперёд
	var forward := car_transform.basis.z
	look_at(global_position + forward * look_ahead, Vector3.UP)

	# Динамический FOV на основе скорости (эффект NFS)
	if _car:
		var speed := _car.linear_velocity.length() * 3.6  # м/с -> км/ч
		var speed_factor: float = clamp(speed / max_speed_for_fov, 0.0, 1.0)
		var target_fov: float = fov_base + fov_speed_boost * speed_factor
		fov = lerp(fov, target_fov, 5.0 * delta)
