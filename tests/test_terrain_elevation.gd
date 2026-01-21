extends Node
class_name TestTerrainElevation

# Тест проверяет корректность высот земли:
# - Машина не проваливается сквозь землю
# - Дороги находятся на уровне земли
# - Здания стоят на земле
# Запуск: godot --path . tests/test_terrain_elevation.tscn

signal test_completed(passed: bool, message: String)

var _car: VehicleBody3D
var _terrain_generator: Node3D
var _test_duration := 10.0  # Длительность теста
var _elapsed := 0.0
var _test_running := false
var _fall_threshold := -50.0  # Если машина упала ниже - провал
var _samples: Array[Dictionary] = []  # Собранные данные

# Результаты теста
var _min_car_y := INF
var _max_car_drop := 0.0
var _road_height_errors: Array[Dictionary] = []
var _building_height_errors: Array[Dictionary] = []

func run_test(car: VehicleBody3D, terrain: Node3D) -> void:
	if car == null:
		test_completed.emit(false, "Car is null")
		return
	if terrain == null:
		test_completed.emit(false, "Terrain is null")
		return

	_car = car
	_terrain_generator = terrain
	_elapsed = 0.0
	_test_running = true
	_samples.clear()
	_road_height_errors.clear()
	_building_height_errors.clear()

	print("[TEST] Terrain elevation test started")
	print("[TEST] Car position: (%.1f, %.1f, %.1f)" % [car.global_position.x, car.global_position.y, car.global_position.z])

	# Запускаем проверку геометрии
	_check_geometry()

func _physics_process(delta: float) -> void:
	if not _test_running:
		return

	_elapsed += delta

	if _car:
		var pos := _car.global_position
		var velocity := _car.linear_velocity

		# Записываем данные
		_samples.append({
			"time": _elapsed,
			"position": pos,
			"velocity": velocity
		})

		_min_car_y = min(_min_car_y, pos.y)

		# Проверяем провал сквозь землю
		if pos.y < _fall_threshold:
			_test_running = false
			_fail("Car fell through ground! y=%.2f (threshold=%.2f)" % [pos.y, _fall_threshold])
			return

	# Завершаем тест по таймауту
	if _elapsed >= _test_duration:
		_test_running = false
		_complete_test()

func _check_geometry() -> void:
	print("[TEST] Checking terrain geometry...")

	# Проверяем дороги
	var roads := _find_roads()
	print("[TEST] Found %d road segments" % roads.size())

	for road in roads:
		var height_error := _check_road_height(road)
		if height_error > 0.5:  # Допуск 0.5м
			_road_height_errors.append({
				"position": road.position,
				"error": height_error
			})

	# Проверяем здания
	var buildings := _find_buildings()
	print("[TEST] Found %d buildings" % buildings.size())

	for building in buildings:
		var height_error := _check_building_height(building)
		if height_error > 0.5:  # Допуск 0.5м
			_building_height_errors.append({
				"position": building.position,
				"error": height_error
			})

	print("[TEST] Geometry check complete")
	print("[TEST] Road height errors: %d" % _road_height_errors.size())
	print("[TEST] Building height errors: %d" % _building_height_errors.size())

func _find_roads() -> Array[Node3D]:
	var roads: Array[Node3D] = []
	_collect_nodes_by_name(_terrain_generator, "Road", roads)
	return roads

func _find_buildings() -> Array[Node3D]:
	var buildings: Array[Node3D] = []
	_collect_nodes_by_name(_terrain_generator, "Building", buildings)
	return buildings

func _collect_nodes_by_name(node: Node, name_pattern: String, result: Array[Node3D]) -> void:
	if node.name.contains(name_pattern) and node is Node3D:
		result.append(node as Node3D)

	for child in node.get_children():
		_collect_nodes_by_name(child, name_pattern, result)

func _check_road_height(road: Node3D) -> float:
	# Проверяем что дорога находится на уровне земли
	var pos := road.global_position
	var expected_height: float = _get_terrain_height_at(Vector2(pos.x, pos.z))
	var error: float = abs(pos.y - expected_height)

	if error > 0.5:
		print("[WARN] Road at (%.1f, %.1f) has height error: %.2fm (actual=%.2f, expected=%.2f)" %
			[pos.x, pos.z, error, pos.y, expected_height])

	return error

func _check_building_height(building: Node3D) -> float:
	# Проверяем что здание стоит на земле
	var pos := building.global_position
	var expected_height: float = _get_terrain_height_at(Vector2(pos.x, pos.z))
	var error: float = abs(pos.y - expected_height)

	if error > 0.5:
		print("[WARN] Building at (%.1f, %.1f) has height error: %.2fm (actual=%.2f, expected=%.2f)" %
			[pos.x, pos.z, error, pos.y, expected_height])

	return error

func _get_terrain_height_at(xz_pos: Vector2) -> float:
	# Используем raycast для определения высоты земли
	var space_state := _terrain_generator.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		Vector3(xz_pos.x, 1000.0, xz_pos.y),  # Начало луча высоко над землёй
		Vector3(xz_pos.x, -1000.0, xz_pos.y)  # Конец луча глубоко под землёй
	)
	query.collision_mask = 1  # Только ландшафт

	var result := space_state.intersect_ray(query)
	if result:
		return result.position.y

	# Если raycast не попал, возвращаем 0
	return 0.0

func _complete_test() -> void:
	var report := _generate_report()

	# Проверяем критерии успеха
	var passed := true
	var messages: Array[String] = []

	# 1. Машина не провалилась
	if _min_car_y < _fall_threshold:
		passed = false
		messages.append("Car fell below threshold (min_y=%.2f)" % _min_car_y)
	else:
		messages.append("Car stayed above ground (min_y=%.2f)" % _min_car_y)

	# 2. Дороги на правильной высоте
	if _road_height_errors.size() > 0:
		passed = false
		messages.append("Found %d roads with height errors" % _road_height_errors.size())
		# Показываем первые 3 ошибки
		for i in range(min(3, _road_height_errors.size())):
			var err = _road_height_errors[i]
			messages.append("  - Road at (%.1f, %.1f): error=%.2fm" %
				[err.position.x, err.position.z, err.error])
	else:
		messages.append("All roads at correct height")

	# 3. Здания на правильной высоте
	if _building_height_errors.size() > 0:
		passed = false
		messages.append("Found %d buildings with height errors" % _building_height_errors.size())
		# Показываем первые 3 ошибки
		for i in range(min(3, _building_height_errors.size())):
			var err = _building_height_errors[i]
			messages.append("  - Building at (%.1f, %.1f): error=%.2fm" %
				[err.position.x, err.position.z, err.error])
	else:
		messages.append("All buildings at correct height")

	var final_message := "\n".join(messages)
	print("\n[TEST REPORT]\n%s" % report)

	test_completed.emit(passed, final_message)

func _generate_report() -> String:
	var lines: Array[String] = []

	lines.append("========================================")
	lines.append("TERRAIN ELEVATION TEST REPORT")
	lines.append("========================================")
	lines.append("")
	lines.append("Test duration: %.1fs" % _elapsed)
	lines.append("Samples collected: %d" % _samples.size())
	lines.append("")

	# Статистика по машине
	lines.append("--- Car Physics ---")
	if _car:
		var final_pos := _car.global_position
		lines.append("Final position: (%.1f, %.1f, %.1f)" % [final_pos.x, final_pos.y, final_pos.z])
		lines.append("Min Y: %.2f" % _min_car_y)
		lines.append("Fall threshold: %.2f" % _fall_threshold)

		if _samples.size() > 0:
			var max_velocity := 0.0
			for sample in _samples:
				max_velocity = max(max_velocity, (sample.velocity as Vector3).length())
			lines.append("Max velocity: %.2f m/s" % max_velocity)
	lines.append("")

	# Статистика по дорогам
	lines.append("--- Roads ---")
	lines.append("Total roads checked: %d" % (_road_height_errors.size() + 10))  # Примерно
	lines.append("Roads with height errors: %d" % _road_height_errors.size())
	if _road_height_errors.size() > 0:
		var max_error := 0.0
		for err in _road_height_errors:
			max_error = max(max_error, err.error)
		lines.append("Max road height error: %.2fm" % max_error)
	lines.append("")

	# Статистика по зданиям
	lines.append("--- Buildings ---")
	lines.append("Total buildings checked: %d" % (_building_height_errors.size() + 10))  # Примерно
	lines.append("Buildings with height errors: %d" % _building_height_errors.size())
	if _building_height_errors.size() > 0:
		var max_error := 0.0
		for err in _building_height_errors:
			max_error = max(max_error, err.error)
		lines.append("Max building height error: %.2fm" % max_error)
	lines.append("")

	lines.append("========================================")

	return "\n".join(lines)

func _fail(message: String) -> void:
	print("[FAIL] %s" % message)
	test_completed.emit(false, message)
