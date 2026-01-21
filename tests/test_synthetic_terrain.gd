extends Node3D

# Синтетический тест для проверки высот земли
# Создаёт простую сцену с разными высотами без загрузки OSM данных
# Запуск: godot --path . tests/test_synthetic_terrain.tscn

var _car: VehicleBody3D
var _test_duration := 5.0
var _elapsed := 0.0
var _test_running := false
var _test_results: Array[Dictionary] = []

# Тестовые точки с разными высотами
var _test_points := [
	{"name": "Flat ground", "position": Vector3(0, 0, 0), "expected_height": 0.0},
	{"name": "Low hill", "position": Vector3(10, 5, 0), "expected_height": 5.0},
	{"name": "High hill", "position": Vector3(20, 10, 0), "expected_height": 10.0},
	{"name": "Valley", "position": Vector3(30, -3, 0), "expected_height": -3.0},
	{"name": "Plateau", "position": Vector3(40, 7, 0), "expected_height": 7.0},
]

func _ready() -> void:
	print("\n========================================")
	print("Synthetic Terrain Elevation Test")
	print("========================================\n")

	# Создаём синтетическую местность
	_create_synthetic_terrain()

	# Создаём машину
	_car = _create_test_car()
	add_child(_car)

	# Запускаем тест
	await get_tree().create_timer(1.0).timeout
	_start_test()

func _create_synthetic_terrain() -> void:
	print("[TEST] Creating synthetic terrain...")

	# Создаём базовую землю далеко внизу (чтобы не мешала raycast)
	var ground := _create_ground_mesh(Vector3(0, 0, 0), 100.0, -100.0)
	add_child(ground)

	# Создаём холмы на разных высотах
	for point in _test_points:
		var pos: Vector3 = point.position
		var height: float = point.expected_height

		# Создаём платформу на нужной высоте
		var platform := _create_platform(pos, 8.0, height)
		platform.name = point.name
		add_child(platform)

		# Создаём тестовую дорогу на платформе
		var road := _create_test_road(pos, height)
		road.name = "Road_" + point.name
		add_child(road)

		# Создаём тестовое здание на платформе
		var building := _create_test_building(pos + Vector3(3, 0, 0), height, 5.0)
		building.name = "Building_" + point.name
		add_child(building)

	print("[TEST] Synthetic terrain created with %d test points" % _test_points.size())

func _create_ground_mesh(center: Vector3, size: float, height: float) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "Ground"

	# Коллизия
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(size, 1.0, size)
	collision.shape = box
	collision.position = center + Vector3(0, height - 0.5, 0)
	body.add_child(collision)

	# Визуал
	var mesh_inst := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(size, size)
	mesh_inst.mesh = plane
	mesh_inst.position = center + Vector3(0, height, 0)

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.4, 0.5, 0.3)
	mesh_inst.material_override = material

	body.add_child(mesh_inst)

	return body

func _create_platform(center: Vector3, size: float, height: float) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = 1

	# Коллизия - плоская поверхность точно на height
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(size, 0.01, size)  # Очень тонкая платформа
	collision.shape = box
	collision.position = Vector3(center.x, height, center.z)
	body.add_child(collision)

	# Визуал
	var mesh_inst := MeshInstance3D.new()
	var plane_mesh := PlaneMesh.new()
	plane_mesh.size = Vector2(size, size)
	mesh_inst.mesh = plane_mesh
	mesh_inst.position = Vector3(center.x, height, center.z)

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.6, 0.5, 0.4)
	mesh_inst.material_override = material

	body.add_child(mesh_inst)

	return body

func _create_test_road(center: Vector3, height: float) -> MeshInstance3D:
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = "Road"

	# Простая плоская дорога 6м x 1м
	var plane := PlaneMesh.new()
	plane.size = Vector2(6.0, 1.0)
	mesh_inst.mesh = plane
	mesh_inst.position = Vector3(center.x, height, center.z)  # Точно на height

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.3, 0.3, 0.3)
	mesh_inst.material_override = material

	return mesh_inst

func _create_test_building(center: Vector3, base_height: float, building_height: float) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "Building"
	body.collision_layer = 2

	# Коллизия
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4.0, building_height, 4.0)
	collision.shape = box
	collision.position = Vector3(center.x, base_height + building_height / 2, center.z)
	body.add_child(collision)

	# Визуал
	var mesh_inst := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = Vector3(4.0, building_height, 4.0)
	mesh_inst.mesh = box_mesh
	mesh_inst.position = Vector3(center.x, base_height + building_height / 2, center.z)

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.7, 0.6, 0.5)
	mesh_inst.material_override = material

	body.add_child(mesh_inst)

	return body

func _create_test_car() -> VehicleBody3D:
	var car := VehicleBody3D.new()
	car.name = "TestCar"
	car.mass = 1000.0

	# Коллизия
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2.0, 1.0, 4.0)
	collision.shape = box
	car.add_child(collision)

	# Визуал
	var mesh_inst := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = Vector3(2.0, 1.0, 4.0)
	mesh_inst.mesh = box_mesh

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.8, 0.2, 0.2)
	mesh_inst.material_override = material

	car.add_child(mesh_inst)

	# Колёса (упрощённые)
	var wheel_positions := [
		Vector3(-0.8, -0.5, 1.2),   # Переднее левое
		Vector3(0.8, -0.5, 1.2),    # Переднее правое
		Vector3(-0.8, -0.5, -1.2),  # Заднее левое
		Vector3(0.8, -0.5, -1.2),   # Заднее правое
	]

	for i in range(4):
		var wheel := VehicleWheel3D.new()
		wheel.use_as_steering = i < 2  # Передние колёса управляемые
		wheel.use_as_traction = i >= 2  # Задние колёса ведущие
		wheel.wheel_radius = 0.3
		wheel.wheel_rest_length = 0.1
		wheel.position = wheel_positions[i]
		car.add_child(wheel)

	# Ставим машину на первую тестовую точку
	car.position = Vector3(0, 5, 0)

	return car

func _start_test() -> void:
	_test_running = true
	_elapsed = 0.0
	_test_results.clear()

	print("[TEST] Starting synthetic terrain test...")
	print("[TEST] Testing %d points with different elevations\n" % _test_points.size())

	# Тестируем каждую точку
	for point in _test_points:
		await _test_point(point)

	# Завершаем тест
	_complete_test()

func _test_point(point: Dictionary) -> void:
	var pos: Vector3 = point.position
	var expected_height: float = point.expected_height
	var name: String = point.name

	print("[TEST] Testing: %s (expected height: %.2fm)" % [name, expected_height])

	# Перемещаем машину на точку
	_car.position = Vector3(pos.x, expected_height + 3, pos.z)
	_car.linear_velocity = Vector3.ZERO
	_car.angular_velocity = Vector3.ZERO

	# Ждём физику
	await get_tree().create_timer(1.0).timeout

	# Проверяем высоту
	var final_y := _car.position.y
	var terrain_height := _get_terrain_height_at(Vector2(pos.x, pos.z))
	var error: float = abs(terrain_height - expected_height)

	var result := {
		"name": name,
		"position": pos,
		"expected_height": expected_height,
		"measured_height": terrain_height,
		"car_final_y": final_y,
		"height_error": error,
		"passed": error < 0.1  # Допуск 10см
	}

	_test_results.append(result)

	if result.passed:
		print("  ✓ PASS: measured=%.2fm, error=%.3fm, car_y=%.2fm" %
			[terrain_height, error, final_y])
	else:
		print("  ✗ FAIL: measured=%.2fm, error=%.3fm, car_y=%.2fm" %
			[terrain_height, error, final_y])

	# Проверяем что дорога и здание на правильной высоте
	var road := get_node_or_null("Road_" + name)
	var building := get_node_or_null("Building_" + name)

	if road:
		var road_height: float = road.position.y
		var road_error: float = abs(road_height - expected_height)
		print("  Road height: %.2fm (expected: %.2fm, error: %.3fm)" %
			[road_height, expected_height, road_error])

	if building:
		# Building - это StaticBody3D, нужно получить позицию его mesh child
		var mesh_child := building.get_child(1) if building.get_child_count() > 1 else null
		var building_y: float = mesh_child.position.y - 2.5 if mesh_child else 0.0  # Вычитаем половину высоты
		var building_error: float = abs(building_y - expected_height)
		print("  Building base: %.2fm (expected: %.2fm, error: %.3fm)" %
			[building_y, expected_height, building_error])

	print("")

func _get_terrain_height_at(xz_pos: Vector2) -> float:
	# Raycast вниз
	var space_state := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		Vector3(xz_pos.x, 100.0, xz_pos.y),
		Vector3(xz_pos.x, -100.0, xz_pos.y)
	)
	query.collision_mask = 1

	var result := space_state.intersect_ray(query)
	if result:
		return result.position.y

	return 0.0

func _complete_test() -> void:
	_test_running = false

	print("========================================")
	print("SYNTHETIC TERRAIN TEST RESULTS")
	print("========================================\n")

	var total := _test_results.size()
	var passed := 0
	var failed := 0

	for result in _test_results:
		if result.passed:
			passed += 1
		else:
			failed += 1

	print("Total points tested: %d" % total)
	print("Passed: %d" % passed)
	print("Failed: %d" % failed)
	print("")

	if failed > 0:
		print("Failed points:")
		for result in _test_results:
			if not result.passed:
				print("  - %s: expected=%.2fm, measured=%.2fm, error=%.3fm" %
					[result.name, result.expected_height, result.measured_height, result.height_error])
		print("")

	print("========================================")

	if failed == 0:
		print("[PASS] All terrain height tests passed!")
		await get_tree().create_timer(0.5).timeout
		get_tree().quit(0)
	else:
		print("[FAIL] %d terrain height tests failed" % failed)
		await get_tree().create_timer(0.5).timeout
		get_tree().quit(1)
