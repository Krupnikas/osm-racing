extends Car

## Тест крена машины Nexia при повороте
## Автоматически едет по кругу вправо на полном газу

var test_time := 0.0

func _ready() -> void:
	super._ready()
	print("=== Nexia Body Roll Test ===")
	print("Full throttle + Right turn")
	print("Watching for body roll direction...")

func _get_steering_input() -> float:
	return -1.0  # Максимум вправо

func _get_throttle_input() -> float:
	return 1.0  # Полный газ

func _get_brake_input() -> float:
	return 0.0  # Без тормоза

func _physics_process(delta: float) -> void:
	test_time += delta

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

		print("Time: %.1fs | Speed: %.1f km/h | Roll: %.2f° %s" % [
			test_time,
			speed,
			roll,
			roll_direction
		])
