extends Vehicle

## Тест крена машины GEVP при повороте
## Автоматически едет по кругу вправо на полном газу

var test_time := 0.0
var controller_enabled := false

func _ready() -> void:
	print("=== GEVP Body Roll Test - _ready() called ===")
	super._ready()
	print("=== GEVP Body Roll Test - Initialized ===")
	print("Full throttle + Right turn")
	print("Watching for body roll direction...")
	print("Front left wheel: ", front_left_wheel)
	print("Mass: ", mass)
	print("Max torque: ", max_torque)

	# Включаем автомат
	automatic_transmission = true
	print("Automatic transmission enabled")

func _physics_process(delta: float) -> void:
	test_time += delta

	# Устанавливаем инпуты напрямую
	throttle_input = 1.0  # Полный газ
	steering_input = -1.0  # Максимум вправо
	brake_input = 0.0  # Без тормоза
	handbrake_input = 0.0
	clutch_input = 0.0

	# Вызов базовой физики
	super._physics_process(delta)

	# Вывод в логи каждые 2 секунды
	if int(test_time) % 2 == 0 and test_time - delta < int(test_time):
		var speed := linear_velocity.length() * 3.6
		var roll := rad_to_deg(rotation.z)
		var roll_direction := ""
		if roll < -0.5:
			roll_direction = "← LEANING LEFT (away from turn center) ✓"
		elif roll > 0.5:
			roll_direction = "→ LEANING RIGHT (INTO turn center) ✗ WRONG!"
		else:
			roll_direction = "| NEUTRAL"

		print("Time: %.1fs | Speed: %.1f km/h | Roll: %.2f° %s | Gear: %d | RPM: %.0f" % [
			test_time,
			speed,
			roll,
			roll_direction,
			current_gear,
			motor_rpm
		])
