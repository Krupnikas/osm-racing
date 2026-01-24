extends Vehicle

## Тест Nexia с GEVP физикой
## Автоматически едет по кругу вправо на полном газу

var test_time := 0.0
var frame_count := 0

func _ready() -> void:
	print("=== Nexia GEVP Test - _ready() called ===")
	super._ready()
	print("=== Nexia GEVP Test - Initialized ===")
	print("Full throttle + Right turn")
	print("Mass: ", mass)
	print("Max torque: ", max_torque)

	# Включаем автомат
	automatic_transmission = true
	print("Automatic transmission enabled")

func _physics_process(delta: float) -> void:
	test_time += delta
	frame_count += 1

	# Устанавливаем инпуты напрямую
	throttle_input = 1.0  # Полный газ
	steering_input = -1.0  # Максимум вправо
	brake_input = 0.0  # Без тормоза
	handbrake_input = 0.0
	clutch_input = 0.0

	# Вызов базовой физики
	super._physics_process(delta)

	# Вывод в логи каждые 120 кадров (~2 секунды при 60fps)
	if frame_count % 120 == 0:
		var speed := linear_velocity.length() * 3.6
		var roll := rad_to_deg(rotation.z)
		var roll_direction := ""
		if roll < -0.5:
			roll_direction = "← LEANING LEFT (away from turn center) ✓ CORRECT!"
		elif roll > 0.5:
			roll_direction = "→ LEANING RIGHT (INTO turn center) ✗ WRONG!"
		else:
			roll_direction = "| NEUTRAL"

		# Отладка колес
		var fl_contact = front_left_wheel.is_colliding() if front_left_wheel else false
		var fr_contact = front_right_wheel.is_colliding() if front_right_wheel else false

		print("Time: %.1fs | Speed: %.1f km/h | Roll: %.2f° %s | Gear: %d | RPM: %.0f | Wheels: FL=%s FR=%s" % [
			test_time,
			speed,
			roll,
			roll_direction,
			current_gear,
			motor_rpm,
			fl_contact,
			fr_contact
		])
