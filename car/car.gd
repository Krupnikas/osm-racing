extends VehicleBody3D

## Сила двигателя
@export var engine_power := 800.0
## Максимальный угол поворота колёс (радианы)
@export var steering_limit := 0.5
## Скорость поворота руля
@export var steering_speed := 5.0
## Сила торможения
@export var brake_power := 50.0

func _physics_process(delta: float) -> void:
	# Руление (стрелки влево/вправо)
	var steer_input := Input.get_axis("ui_right", "ui_left")
	steering = lerp(steering, steer_input * steering_limit, steering_speed * delta)

	# Газ/задний ход (стрелки вверх/вниз)
	var throttle := Input.get_axis("ui_down", "ui_up")
	engine_force = throttle * engine_power

	# Ручной тормоз (пробел)
	if Input.is_action_pressed("ui_accept"):
		brake = brake_power
	else:
		brake = 0.0
