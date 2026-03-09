extends Vehicle

## BMW-only arcade handling profile kept separate from shared car selection data.

# Theoretical no-load road speeds at 8500 RPM with the current 0.33 m tire radius:
# 89 / 135 / 182 / 229 / 264 / 293 / 386 km/h.
# With the current automatic shift logic, normal upshifts happen closer to:
# 67 / 101 / 136 / 172 / 198 / 220 km/h.
# Actual top speed can still be lower if the car runs out of pull before redline in top gear.
const BMW_GEAR_RATIOS: Array[float] = [3.55, 2.35, 1.74, 1.38, 1.20, 1.08, 0.82]
const BMW_ANGULAR_VELOCITY_TO_RPM := 60.0 / TAU
const BMW_TIRE_STIFFNESSES := {
	"Road": 12.0,
	"Dirt": 0.55,
	"Grass": 0.35,
	"Park": 0.25,
}
const BMW_COEFFICIENT_OF_FRICTION := {
	"Road": 3.6,
	"Dirt": 2.2,
	"Grass": 1.7,
	"Park": 1.3,
}
const BMW_ROLLING_RESISTANCE := {
	"Road": 0.08,
	"Dirt": 3.2,
	"Grass": 6.5,
	"Park": 11.0,
}
const BMW_LATERAL_GRIP_ASSIST := {
	"Road": 0.12,
	"Dirt": 0.02,
	"Grass": 0.0,
	"Park": 0.0,
}
const BMW_LONGITUDINAL_GRIP_RATIO := {
	"Road": 0.62,
	"Dirt": 0.52,
	"Grass": 0.4,
	"Park": 0.3,
}


func _ready() -> void:
	_apply_bmw_arcade_profile()
	initialize()


func _apply_bmw_arcade_profile() -> void:
	steering_speed = 4.6
	countersteer_speed = 12.5
	steering_speed_decay = 0.13
	steering_slip_assist = 0.4
	countersteer_assist = 0.8
	max_steering_angle = deg_to_rad(38.0)

	throttle_speed = 24.0
	throttle_steering_adjust = 0.18
	braking_speed = 14.0
	brake_force_multiplier = 1.15
	traction_control_max_slip = 3.2

	stability_yaw_engage_angle = 0.04
	stability_yaw_strength = 10.0
	stability_yaw_ground_multiplier = 9.0

	max_torque = 760.0
	max_rpm = 8500.0
	idle_rpm = 900.0
	motor_moment = 1.15
	clutch_out_rpm = 1800.0
	gear_ratios = _duplicate_ratios(BMW_GEAR_RATIOS)
	final_drive = 3.35
	shift_time = 0.11
	automatic_time_between_shifts = 320.0

	front_torque_split = 0.32
	variable_torque_split = true
	front_variable_split = 0.42
	rear_locking_differential_engage_torque = 280.0
	rear_torque_vectoring = 0.05

	vehicle_mass = 1460.0
	front_weight_distribution = 0.52
	center_of_gravity_height_offset = -0.28
	front_damping_ratio = 0.6
	front_arb_ratio = 0.4
	front_toe = 0.008
	rear_damping_ratio = 0.58
	rear_arb_ratio = 0.22
	rear_toe = 0.015

	braking_grip_multiplier = 2.2
	tire_stiffnesses = BMW_TIRE_STIFFNESSES.duplicate(true)
	coefficient_of_friction = BMW_COEFFICIENT_OF_FRICTION.duplicate(true)
	rolling_resistance = BMW_ROLLING_RESISTANCE.duplicate(true)
	lateral_grip_assist = BMW_LATERAL_GRIP_ASSIST.duplicate(true)
	longitudinal_grip_ratio = BMW_LONGITUDINAL_GRIP_RATIO.duplicate(true)

	coefficient_of_friction["Road"] = 3.8
	lateral_grip_assist["Road"] = 0.18
	longitudinal_grip_ratio["Road"] = 0.68

	coefficient_of_drag = 0.27
	frontal_area = 1.95


func process_transmission() -> void:
	if is_shifting:
		if delta_time > complete_shift_delta_time:
			complete_shift()
		return

	if not automatic_transmission:
		return

	var auto_shift_delay := _get_bmw_auto_shift_delay()
	if burnout_active:
		if current_gear != 1 and delta_time - last_shift_delta_time > auto_shift_delay:
			requested_gear = 1
			complete_shift()
		return

	var reversing := current_gear == -1
	var ideal_wheel_spin := speed / average_drive_wheel_radius
	var drivetrain_spin := get_drivetrain_spin()
	var real_wheel_spin := drivetrain_spin * get_gear_ratio(current_gear)
	var current_ideal_gear_rpm := 0.0
	var current_real_gear_rpm := real_wheel_spin * BMW_ANGULAR_VELOCITY_TO_RPM

	if current_gear > 0 and current_gear <= gear_ratios.size():
		current_ideal_gear_rpm = gear_ratios[current_gear - 1] * final_drive * ideal_wheel_spin * BMW_ANGULAR_VELOCITY_TO_RPM

	if not reversing:
		var previous_gear_rpm := 0.0
		if current_gear > 1:
			previous_gear_rpm = get_gear_ratio(current_gear - 1) * maxf(drivetrain_spin, ideal_wheel_spin) * BMW_ANGULAR_VELOCITY_TO_RPM

		if current_gear < gear_ratios.size():
			if current_gear > 0:
				if current_ideal_gear_rpm > max_rpm * 0.75:
					if delta_time - last_shift_delta_time > auto_shift_delay:
						shift(1)
						return
				if current_ideal_gear_rpm > max_rpm * 0.6 and current_real_gear_rpm > max_rpm * 0.75:
					if delta_time - last_shift_delta_time > auto_shift_delay:
						shift(1)
						return
			elif motor_rpm > maxf(clutch_out_rpm, idle_rpm):
				shift(1)
				return

		if current_gear > 1 and previous_gear_rpm < 0.5 * max_rpm:
			if delta_time - last_shift_delta_time > auto_shift_delay:
				shift(-1)
				return

	if absf(current_gear) <= 1 and brake_input > 0.75:
		if not reversing:
			if speed < 1.0 or local_velocity.z > 0.0:
				if delta_time - last_shift_delta_time > auto_shift_delay:
					shift(-1)
		else:
			if speed < 1.0 or local_velocity.z < 0.0:
				if delta_time - last_shift_delta_time > auto_shift_delay:
					shift(1)


func _get_bmw_auto_shift_delay() -> float:
	return maxf(shift_time, automatic_time_between_shifts * 0.001)


func _duplicate_ratios(source: Array[float]) -> Array[float]:
	var copy: Array[float] = []
	for value in source:
		copy.append(value)
	return copy
