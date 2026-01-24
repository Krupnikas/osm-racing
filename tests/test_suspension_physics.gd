extends Node

## Тест физики подвески автомобиля
## Проверяет направление крена в поворотах

var tests_passed := 0
var tests_failed := 0

func _ready():
	print("\n=== Testing Suspension Physics ===\n")
	run_all_tests()

	# Выводим результаты
	print("\n--- Suspension Test Results ---")
	print("Passed: %d" % tests_passed)
	print("Failed: %d" % tests_failed)
	print("-------------------------------\n")

	# Закрываем после 2 секунд
	await get_tree().create_timer(2.0).timeout
	get_tree().quit()


func run_all_tests():
	test_wheel_positions()
	test_suspension_direction()
	test_body_roll_direction()


func test_wheel_positions():
	print("Test: Wheel positions are symmetric")

	var car_scene = preload("res://car/car_nexia.tscn")
	var car = car_scene.instantiate()
	add_child(car)

	await get_tree().process_frame

	# Получаем колёса
	var wheel_fl = car.get_node("WheelFL")
	var wheel_fr = car.get_node("WheelFR")
	var wheel_rl = car.get_node("WheelRL")
	var wheel_rr = car.get_node("WheelRR")

	# Проверяем симметрию по X
	var fl_x = wheel_fl.position.x
	var fr_x = wheel_fr.position.x
	var rl_x = wheel_rl.position.x
	var rr_x = wheel_rr.position.x

	print("  Front Left X:  %.2f" % fl_x)
	print("  Front Right X: %.2f" % fr_x)
	print("  Rear Left X:   %.2f" % rl_x)
	print("  Rear Right X:  %.2f" % rr_x)

	if abs(fl_x + fr_x) < 0.01 and abs(rl_x + rr_x) < 0.01:
		print("  ✓ PASS: Wheels are symmetric")
		tests_passed += 1
	else:
		print("  ✗ FAIL: Wheels are NOT symmetric")
		tests_failed += 1

	car.queue_free()


func test_suspension_direction():
	print("\nTest: Suspension compression/relaxation values")

	var car_scene = preload("res://car/car_nexia.tscn")
	var car = car_scene.instantiate()
	add_child(car)

	await get_tree().process_frame

	var wheel_fl = car.get_node("WheelFL")
	var wheel_rr = car.get_node("WheelRR")

	var comp_fl = wheel_fl.damping_compression
	var relax_fl = wheel_fl.damping_relaxation
	var comp_rr = wheel_rr.damping_compression
	var relax_rr = wheel_rr.damping_relaxation

	print("  Front: compression=%.1f, relaxation=%.1f" % [comp_fl, relax_fl])
	print("  Rear:  compression=%.1f, relaxation=%.1f" % [comp_rr, relax_rr])

	# Compression должен быть больше relaxation для правильного крена
	if comp_fl > relax_fl and comp_rr > relax_rr:
		print("  ✓ PASS: Damping values are correct (compression > relaxation)")
		tests_passed += 1
	else:
		print("  ✗ FAIL: Damping values are WRONG (should be compression > relaxation)")
		tests_failed += 1

	car.queue_free()


func test_body_roll_direction():
	print("\nTest: Body roll direction in turn")
	print("  Setting up car with lateral force...")

	var car_scene = preload("res://car/car_nexia.tscn")
	var car = car_scene.instantiate()
	add_child(car)

	# Позиционируем машину над землёй
	car.global_position = Vector3(0, 2, 0)

	await get_tree().process_frame
	await get_tree().process_frame

	# Даём машине упасть на землю
	var initial_rotation = car.rotation.z
	print("  Initial Z rotation: %.3f rad (%.1f°)" % [initial_rotation, rad_to_deg(initial_rotation)])

	# Применяем боковую силу (симулируем поворот направо)
	# В реальности это центробежная сила
	var lateral_force = Vector3(5000, 0, 0)  # Сила вправо

	# Симулируем физику на несколько кадров
	for i in range(30):
		car.apply_central_force(lateral_force)
		await get_tree().physics_frame

	var final_rotation = car.rotation.z
	var roll_change = final_rotation - initial_rotation

	print("  Final Z rotation:   %.3f rad (%.1f°)" % [final_rotation, rad_to_deg(final_rotation)])
	print("  Roll change:        %.3f rad (%.1f°)" % [roll_change, rad_to_deg(roll_change)])

	# При силе вправо (+X), машина должна крениться влево (-Z rotation)
	# Это физически правильно (крен ОТ центра поворота)
	if roll_change < -0.01:
		print("  ✓ PASS: Body rolls AWAY from lateral force (correct physics)")
		tests_passed += 1
	elif roll_change > 0.01:
		print("  ✗ FAIL: Body rolls TOWARDS lateral force (INVERTED - BUG!)")
		print("  → This is the Godot VehicleBody3D suspension bug")
		tests_failed += 1
	else:
		print("  ? INCONCLUSIVE: No significant roll detected")
		print("  → May need stronger force or more simulation time")
		tests_failed += 1

	car.queue_free()
