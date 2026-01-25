extends Node

## Simple input handler for GEVP Vehicle
## Converts keyboard input to vehicle control signals

@export var vehicle: Vehicle

func _physics_process(_delta: float) -> void:
	if not vehicle:
		return

	# Throttle (W / Up)
	vehicle.throttle_input = Input.get_action_strength("Throttle")

	# Brake (S / Down)
	vehicle.brake_input = Input.get_action_strength("Brake")

	# Steering (A/D or Left/Right)
	var steer_left = Input.get_action_strength("SteerLeft")
	var steer_right = Input.get_action_strength("SteerRight")
	vehicle.steering_input = steer_right - steer_left

	# Handbrake (Space)
	vehicle.handbrake_input = 1.0 if Input.is_action_pressed("Handbrake") else 0.0
