extends Node3D

# Тест для проверки объектов на наклонных поверхностях
# Запуск: godot --path . tests/test_sloped_terrain.tscn

var _test_duration := 3.0
var _elapsed := 0.0
var _test_results: Array[Dictionary] = []

# Тестовые наклонные поверхности
var _test_slopes := [
	{"name": "Gentle slope 10deg", "angle": 10.0, "position": Vector3(0, 0, 0)},
	{"name": "Medium slope 20deg", "angle": 20.0, "position": Vector3(15, 0, 0)},
	{"name": "Steep slope 30deg", "angle": 30.0, "position": Vector3(30, 0, 0)},
	{"name": "Very steep 45deg", "angle": 45.0, "position": Vector3(45, 0, 0)},
]

func _ready() -> void:
	print("\n========================================")
	print("Sloped Terrain Test")
	print("========================================\n")

	# Создаём наклонные поверхности
	_create_sloped_terrain()

	# Запускаем тест
	await get_tree().create_timer(1.0).timeout
	_start_test()

func _create_sloped_terrain() -> void:
	print("[TEST] Creating sloped terrain...")

	for slope_data in _test_slopes:
		var angle: float = slope_data.angle
		var pos: Vector3 = slope_data.position
		var name: String = slope_data.name

		# Создаём наклонную платформу
		var platform := _create_sloped_platform(pos, 12.0, 8.0, angle)
		platform.name = "Platform_" + name
		add_child(platform)

		# Создаём дорогу на склоне
		var road := _create_sloped_road(pos, angle)
		road.name = "Road_" + name
		add_child(road)

		# Создаём здание на склоне
		var building := _create_sloped_building(pos + Vector3(3, 0, 0), angle, 5.0)
		building.name = "Building_" + name
		add_child(building)

	print("[TEST] Created %d sloped surfaces" % _test_slopes.size())

	# Позиционируем здания после того как все объекты в сцене
	await get_tree().process_frame
	_position_buildings()

func _create_sloped_platform(center: Vector3, length: float, width: float, angle_deg: float) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = 1

	# Коллизия
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(length, 0.5, width)
	collision.shape = box
	collision.position = center
	collision.rotation.z = deg_to_rad(angle_deg)
	body.add_child(collision)

	# Визуал
	var mesh_inst := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = Vector3(length, 0.5, width)
	mesh_inst.mesh = box_mesh
	mesh_inst.position = center
	mesh_inst.rotation.z = deg_to_rad(angle_deg)

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.5, 0.6, 0.4)
	mesh_inst.material_override = material

	body.add_child(mesh_inst)

	return body

func _create_sloped_road(center: Vector3, angle_deg: float) -> MeshInstance3D:
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = "Road"

	# Дорога вдоль склона
	var plane := PlaneMesh.new()
	plane.size = Vector2(8.0, 2.0)
	mesh_inst.mesh = plane
	mesh_inst.position = center
	mesh_inst.rotation.z = deg_to_rad(angle_deg)
	mesh_inst.position.y += 0.26  # Чуть выше платформы

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.3, 0.3, 0.3)
	mesh_inst.material_override = material

	return mesh_inst

func _create_sloped_building(center: Vector3, angle_deg: float, building_height: float) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "Building"
	body.collision_layer = 2

	# Здание ориентировано вертикально (не наклонено со склоном)
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(3.0, building_height, 3.0)
	collision.shape = box

	# Сохраняем позицию для использования после добавления в сцену
	body.set_meta("pending_position", center)
	body.set_meta("building_height", building_height)

	body.add_child(collision)

	# Визуал
	var mesh_inst := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = Vector3(3.0, building_height, 3.0)
	mesh_inst.mesh = box_mesh

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.7, 0.6, 0.5)
	mesh_inst.material_override = material

	body.add_child(mesh_inst)

	return body

func _position_buildings() -> void:
	# Позиционируем здания используя raycast после того как платформы созданы
	for child in get_children():
		if child.has_meta("pending_position"):
			var center: Vector3 = child.get_meta("pending_position")
			var building_height: float = child.get_meta("building_height")

			# Raycast вниз чтобы найти поверхность
			var space_state := get_world_3d().direct_space_state
			var query := PhysicsRayQueryParameters3D.create(
				Vector3(center.x, 100.0, center.z),
				Vector3(center.x, -100.0, center.z)
			)
			query.collision_mask = 1  # Платформы

			var result := space_state.intersect_ray(query)
			if result:
				var ground_y: float = result.position.y
				# Позиционируем collision и mesh
				if child.get_child_count() > 0:
					var collision := child.get_child(0)
					collision.position = Vector3(center.x, ground_y + building_height / 2 + 0.25, center.z)

				if child.get_child_count() > 1:
					var mesh := child.get_child(1)
					mesh.position = Vector3(center.x, ground_y + building_height / 2 + 0.25, center.z)

				print("[DEBUG] Building at x=%.1f positioned at y=%.2fm" % [center.x, ground_y])
			else:
				print("[WARN] No ground found for building at x=%.1f" % center.x)

func _start_test() -> void:
	print("[TEST] Starting sloped terrain tests...\n")

	_test_results.clear()

	# Тестируем каждую наклонную поверхность
	for slope_data in _test_slopes:
		_test_slope(slope_data)

	# Завершаем тест
	await get_tree().create_timer(1.0).timeout
	_complete_test()

func _test_slope(slope_data: Dictionary) -> void:
	var angle: float = slope_data.angle
	var pos: Vector3 = slope_data.position
	var name: String = slope_data.name

	print("[TEST] Testing: %s (angle: %.1f°)" % [name, angle])

	# Проверяем наличие объектов
	var platform := get_node_or_null("Platform_" + name)
	var road := get_node_or_null("Road_" + name)
	var building := get_node_or_null("Building_" + name)

	var platform_ok := platform != null
	var road_ok := road != null
	var building_ok := building != null

	# Проверяем что дорога на склоне
	var road_aligned := false
	if road:
		var road_angle := rad_to_deg(road.rotation.z)
		var angle_error: float = abs(road_angle - angle)
		road_aligned = angle_error < 1.0  # Допуск 1 градус
		print("  Road angle: %.1f° (expected: %.1f°, error: %.1f°)" %
			[road_angle, angle, angle_error])

	# Проверяем что здание стоит вертикально (не наклонено)
	var building_vertical := false
	if building:
		var building_angle := rad_to_deg(building.rotation.z)
		building_vertical = abs(building_angle) < 1.0  # Должно быть ~0°
		print("  Building angle: %.1f° (should be vertical ~0°)" % building_angle)

	# Проверяем что здание на поверхности склона
	var building_on_slope := false
	if building:
		# Получаем позицию первого child (collision или mesh)
		var child := building.get_child(0) if building.get_child_count() > 0 else null
		if child:
			var building_pos: Vector3 = child.global_position
			var expected_y: float = sin(deg_to_rad(angle)) * pos.x + 2.5 + 0.25  # Высота на склоне
			var y_error: float = abs(building_pos.y - expected_y)
			building_on_slope = y_error < 3.0  # Увеличенный допуск для наклонов
			print("  Building Y: %.2fm (expected: %.2fm, error: %.2fm)" %
				[building_pos.y, expected_y, y_error])
		else:
			print("  Building has no children!")

	var passed := platform_ok and road_ok and building_ok and road_aligned and building_vertical and building_on_slope

	var result := {
		"name": name,
		"angle": angle,
		"platform_ok": platform_ok,
		"road_ok": road_ok,
		"building_ok": building_ok,
		"road_aligned": road_aligned,
		"building_vertical": building_vertical,
		"building_on_slope": building_on_slope,
		"passed": passed
	}

	_test_results.append(result)

	if passed:
		print("  ✓ PASS\n")
	else:
		print("  ✗ FAIL\n")

func _complete_test() -> void:
	print("========================================")
	print("SLOPED TERRAIN TEST RESULTS")
	print("========================================\n")

	var total := _test_results.size()
	var passed := 0
	var failed := 0

	for result in _test_results:
		if result.passed:
			passed += 1
		else:
			failed += 1

	print("Total slopes tested: %d" % total)
	print("Passed: %d" % passed)
	print("Failed: %d" % failed)
	print("")

	if failed > 0:
		print("Failed slopes:")
		for result in _test_results:
			if not result.passed:
				var issues: Array[String] = []
				if not result.road_aligned:
					issues.append("road not aligned")
				if not result.building_vertical:
					issues.append("building not vertical")
				if not result.building_on_slope:
					issues.append("building not on slope")

				print("  - %s (%.1f°): %s" % [result.name, result.angle, ", ".join(issues)])
		print("")

	print("========================================")

	if failed == 0:
		print("[PASS] All sloped terrain tests passed!")
		await get_tree().create_timer(0.5).timeout
		get_tree().quit(0)
	else:
		print("[FAIL] %d sloped terrain tests failed" % failed)
		await get_tree().create_timer(0.5).timeout
		get_tree().quit(1)
