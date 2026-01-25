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

	# HACK: Инвертируем body roll применяя counter-torque
	# Используем угловую скорость поворота (yaw) для расчёта центробежной силы
	var forward_speed := linear_velocity.dot(-global_transform.basis.z)
	var yaw_rate := angular_velocity.y  # Скорость поворота вокруг вертикальной оси

	# Центробежное ускорение = V * omega
	var centrifugal_accel := forward_speed * yaw_rate

	# Желаемый крен ПРОТИВОПОЛОЖЕН центробежной силе
	# При повороте вправо (yaw < 0) машина должна крениться влево (roll < 0)
	var target_roll := -centrifugal_accel * 0.15  # Уменьшен коэффициент
	var current_roll := rotation.z
	var roll_error := target_roll - current_roll

	# PD controller с балансом между коррекцией и стабильностью
	var angular_vel_z := angular_velocity.dot(global_transform.basis.z)
	var correction_torque := roll_error * 120000.0 - angular_vel_z * 4000.0

	apply_torque_impulse(global_transform.basis.z * correction_torque * delta)

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
