extends Vehicle

## Тест разгона 0-100 км/ч
## Проверяет работу коробки передач

var test_time := 0.0
var frame_count := 0
var last_gear := 0
var reached_100 := false
var gear_changes: Array[Dictionary] = []
var max_speed_reached := 0.0

func _ready() -> void:
	print("=== Acceleration Test 0-100 km/h ===")
	super._ready()
	print("Gear ratios: ", gear_ratios)
	print("Final drive: ", final_drive)
	print("Max RPM: ", max_rpm)
	print("Max torque: ", max_torque)
	print("Automatic: ", automatic_transmission)
	print("Front torque split: ", front_torque_split)
	print("")
	print("Starting acceleration test...")

func _physics_process(delta: float) -> void:
	test_time += delta
	frame_count += 1

	# Полный газ, без руления
	throttle_input = 1.0
	steering_input = 0.0
	brake_input = 0.0
	handbrake_input = 0.0
	clutch_input = 0.0

	super._physics_process(delta)

	var speed := linear_velocity.length() * 3.6  # км/ч
	max_speed_reached = max(max_speed_reached, speed)

	# Логируем переключение передачи
	if current_gear != last_gear:
		var info := {
			"time": test_time,
			"speed": speed,
			"from_gear": last_gear,
			"to_gear": current_gear,
			"rpm": motor_rpm
		}
		gear_changes.append(info)
		print("SHIFT: %.2fs | %d -> %d | Speed: %.1f km/h | RPM: %.0f" % [
			test_time, last_gear, current_gear, speed, motor_rpm
		])
		last_gear = current_gear

	# Логируем каждые 60 кадров (~1 секунда)
	if frame_count % 60 == 0:
		var wheel_spin := get_drivetrain_spin() * 60 / TAU  # в об/мин
		print("T: %.1fs | Speed: %.1f km/h | Gear: %d | RPM: %.0f | WheelRPM: %.0f | Throttle: %.1f | Shifting: %s" % [
			test_time, speed, current_gear, motor_rpm, wheel_spin, throttle_amount, is_shifting
		])

	# Достигли 100 км/ч
	if speed >= 100.0 and not reached_100:
		reached_100 = true
		print("")
		print("=== REACHED 100 km/h in %.2f seconds ===" % test_time)
		print("Gear changes:")
		for gc in gear_changes:
			print("  %.2fs: %d -> %d at %.1f km/h (RPM: %.0f)" % [
				gc.time, gc.from_gear, gc.to_gear, gc.speed, gc.rpm
			])
		print("")

	# Останавливаем после 30 секунд или 160 км/ч
	if test_time > 30.0 or speed > 160.0:
		print("")
		print("=== Test finished ===")
		print("Max speed reached: %.1f km/h" % max_speed_reached)
		print("Final speed: %.1f km/h" % speed)
		print("Final gear: %d" % current_gear)
		print("Total gear changes: %d" % gear_changes.size())
		for gc in gear_changes:
			print("  %.2fs: %d -> %d at %.1f km/h" % [gc.time, gc.from_gear, gc.to_gear, gc.speed])
		get_tree().quit()
