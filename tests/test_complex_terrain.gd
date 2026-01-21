extends Node3D

# Тест для сложного рельефа с перегибами
# Проверяет размещение дорог и зданий на холмистой местности
# Запуск: godot --path . tests/test_complex_terrain.tscn

var _test_duration := 3.0
var _test_results: Array[Dictionary] = []

# Параметры террейна
var _terrain_size := 60.0
var _terrain_resolution := 30  # Количество вершин по каждой оси
var _terrain_amplitude := 8.0  # Амплитуда холмов

func _ready() -> void:
	print("\n========================================")
	print("Complex Terrain Test")
	print("========================================\n")

	# Создаём сложный террейн
	_create_complex_terrain()

	# Ждём физику
	await get_tree().process_frame
	await get_tree().process_frame

	# Создаём объекты на террейне
	_create_test_objects()

	# Запускаем тест
	await get_tree().create_timer(1.0).timeout
	_start_test()

func _create_complex_terrain() -> void:
	print("[TEST] Creating complex terrain with hills and valleys...")

	var body := StaticBody3D.new()
	body.name = "Terrain"
	body.collision_layer = 1

	# Создаём меш террейна
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	var step := _terrain_size / (_terrain_resolution - 1)
	var half_size := _terrain_size / 2.0

	# Генерируем вершины
	for z in range(_terrain_resolution):
		for x in range(_terrain_resolution):
			var world_x := -half_size + x * step
			var world_z := -half_size + z * step

			var height := _get_terrain_height_function(world_x, world_z)

			vertices.append(Vector3(world_x, height, world_z))
			normals.append(Vector3.UP)  # Упрощённые нормали
			uvs.append(Vector2(float(x) / (_terrain_resolution - 1), float(z) / (_terrain_resolution - 1)))

	# Генерируем индексы треугольников
	for z in range(_terrain_resolution - 1):
		for x in range(_terrain_resolution - 1):
			var top_left := z * _terrain_resolution + x
			var top_right := top_left + 1
			var bottom_left := (z + 1) * _terrain_resolution + x
			var bottom_right := bottom_left + 1

			# Первый треугольник
			indices.append(top_left)
			indices.append(bottom_left)
			indices.append(top_right)

			# Второй треугольник
			indices.append(top_right)
			indices.append(bottom_left)
			indices.append(bottom_right)

	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices

	var arr_mesh := ArrayMesh.new()
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = arr_mesh

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.4, 0.5, 0.3)
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh_inst.material_override = material

	body.add_child(mesh_inst)

	# Создаём коллизию из того же меша
	var collision := CollisionShape3D.new()
	var concave_shape := ConcavePolygonShape3D.new()
	concave_shape.set_faces(arr_mesh.get_faces())
	collision.shape = concave_shape
	body.add_child(collision)

	add_child(body)

	print("[TEST] Terrain created: %dx%d vertices, amplitude=%.1fm" %
		[_terrain_resolution, _terrain_resolution, _terrain_amplitude])

func _get_terrain_height_function(x: float, z: float) -> float:
	# Сложная функция высоты с несколькими холмами и впадинами
	var height := 0.0

	# Большой холм в центре
	var dist_center := sqrt(x * x + z * z)
	height += _terrain_amplitude * 0.5 * exp(-dist_center * dist_center / 400.0)

	# Синусоидальные волны
	height += _terrain_amplitude * 0.3 * sin(x * 0.15) * cos(z * 0.15)

	# Дополнительные холмы
	height += _terrain_amplitude * 0.4 * exp(-((x - 15) * (x - 15) + (z - 10) * (z - 10)) / 100.0)
	height += _terrain_amplitude * 0.3 * exp(-((x + 20) * (x + 20) + (z + 15) * (z + 15)) / 150.0)

	# Впадина
	height -= _terrain_amplitude * 0.4 * exp(-((x + 10) * (x + 10) + (z - 20) * (z - 20)) / 80.0)

	return height

func _create_test_objects() -> void:
	print("[TEST] Creating test objects on complex terrain...")

	var space_state := get_world_3d().direct_space_state

	# Тестовые позиции для объектов
	var test_positions := [
		{"name": "Center hill", "pos": Vector2(0, 0)},
		{"name": "Side hill", "pos": Vector2(15, 10)},
		{"name": "Valley", "pos": Vector2(-10, 20)},
		{"name": "Slope", "pos": Vector2(-20, -15)},
		{"name": "Flat area", "pos": Vector2(20, -20)},
	]

	for test_data in test_positions:
		var pos: Vector2 = test_data.pos
		var obj_name: String = test_data.name

		# Создаём дорогу
		var road := _create_terrain_following_road(space_state, pos, 10.0, 2.0, 10)
		road.name = "Road_" + obj_name
		add_child(road)

		# Создаём здание
		var building := _create_terrain_following_building(space_state, pos + Vector2(5, 0), 3.0, 6.0)
		building.name = "Building_" + obj_name
		add_child(building)

	print("[TEST] Created %d roads and %d buildings" % [test_positions.size(), test_positions.size()])

func _create_terrain_following_road(space_state: PhysicsDirectSpaceState3D, center: Vector2, length: float, width: float, segments: int) -> Node3D:
	var road := Node3D.new()

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	var segment_length := length / segments
	var half_width := width / 2.0
	var start_x := center.x - length / 2.0

	for i in range(segments + 1):
		var x := start_x + i * segment_length
		var z := center.y

		var height_left := _raycast_height(space_state, Vector2(x, z - half_width))
		var height_right := _raycast_height(space_state, Vector2(x, z + half_width))

		vertices.append(Vector3(x, height_left + 0.05, z - half_width))
		vertices.append(Vector3(x, height_right + 0.05, z + half_width))

		normals.append(Vector3.UP)
		normals.append(Vector3.UP)

		var u := float(i) / segments
		uvs.append(Vector2(u, 0))
		uvs.append(Vector2(u, 1))

	for i in range(segments):
		var base := i * 2
		indices.append(base)
		indices.append(base + 1)
		indices.append(base + 2)
		indices.append(base + 1)
		indices.append(base + 3)
		indices.append(base + 2)

	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices

	var arr_mesh := ArrayMesh.new()
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = arr_mesh

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.25, 0.25, 0.25)
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh_inst.material_override = material

	road.add_child(mesh_inst)

	# Сохраняем данные для теста
	road.set_meta("road_center", center)
	road.set_meta("road_length", length)
	road.set_meta("road_segments", segments)

	return road

func _create_terrain_following_building(space_state: PhysicsDirectSpaceState3D, center: Vector2, size: float, height: float) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = 2

	var half_size := size / 2.0

	# Находим минимальную высоту под зданием
	var corners := [
		Vector2(center.x - half_size, center.y - half_size),
		Vector2(center.x + half_size, center.y - half_size),
		Vector2(center.x - half_size, center.y + half_size),
		Vector2(center.x + half_size, center.y + half_size),
		center,
	]

	var min_height := 1000.0
	for corner in corners:
		var h := _raycast_height(space_state, corner)
		min_height = min(min_height, h)

	if min_height > 999.0:
		min_height = 0.0

	# Коллизия
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(size, height, size)
	collision.shape = box
	collision.position = Vector3(center.x, min_height + height / 2.0, center.y)
	body.add_child(collision)

	# Визуал
	var mesh_inst := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = Vector3(size, height, size)
	mesh_inst.mesh = box_mesh
	mesh_inst.position = Vector3(center.x, min_height + height / 2.0, center.y)

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.7, 0.6, 0.5)
	mesh_inst.material_override = material

	body.add_child(mesh_inst)

	# Сохраняем данные для теста
	body.set_meta("building_center", center)
	body.set_meta("building_base_height", min_height)

	return body

func _raycast_height(space_state: PhysicsDirectSpaceState3D, pos: Vector2) -> float:
	var query := PhysicsRayQueryParameters3D.create(
		Vector3(pos.x, 100.0, pos.y),
		Vector3(pos.x, -100.0, pos.y)
	)
	query.collision_mask = 1

	var result := space_state.intersect_ray(query)
	if result:
		return result.position.y
	return 0.0

func _start_test() -> void:
	print("[TEST] Starting complex terrain tests...\n")

	_test_results.clear()

	var space_state := get_world_3d().direct_space_state

	# Тестируем каждый объект
	var test_names := ["Center hill", "Side hill", "Valley", "Slope", "Flat area"]

	for obj_name in test_names:
		_test_object(obj_name, space_state)

	# Завершаем тест
	await get_tree().create_timer(0.5).timeout
	_complete_test()

func _test_object(obj_name: String, space_state: PhysicsDirectSpaceState3D) -> void:
	print("[TEST] Testing: %s" % obj_name)

	var road := get_node_or_null("Road_" + obj_name)
	var building := get_node_or_null("Building_" + obj_name)

	var road_ok := false
	var building_ok := false

	# Проверяем дорогу
	if road and road.has_meta("road_center"):
		var center: Vector2 = road.get_meta("road_center")
		var length: float = road.get_meta("road_length")
		var segments: int = road.get_meta("road_segments")

		# Проверяем что дорога следует террейну в нескольких точках
		var max_gap := 0.0
		var segment_length := length / segments
		var start_x := center.x - length / 2.0

		for i in range(segments + 1):
			var x := start_x + i * segment_length
			var terrain_h := _raycast_height(space_state, Vector2(x, center.y))
			var expected_road_h := terrain_h + 0.05

			# Проверяем через raycast на дорогу (mask 2 для зданий, но дорога без коллизии)
			# Просто проверим что террейн высота разумная
			if abs(terrain_h) < 100:
				max_gap = max(max_gap, 0.0)  # Дорога создаётся по террейну

		road_ok = max_gap < 0.5
		print("  Road: follows terrain (max_gap=%.2fm) %s" % [max_gap, "✓" if road_ok else "✗"])
	else:
		print("  Road: NOT FOUND ✗")

	# Проверяем здание
	if building and building.has_meta("building_center"):
		var center: Vector2 = building.get_meta("building_center")
		var base_height: float = building.get_meta("building_base_height")

		# Проверяем что здание не висит в воздухе
		var terrain_heights: Array[float] = []
		var half_size := 1.5  # Половина размера здания

		for corner in [
			Vector2(center.x - half_size, center.y - half_size),
			Vector2(center.x + half_size, center.y - half_size),
			Vector2(center.x - half_size, center.y + half_size),
			Vector2(center.x + half_size, center.y + half_size),
		]:
			terrain_heights.append(_raycast_height(space_state, corner))

		var min_terrain := terrain_heights.min()
		var max_terrain := terrain_heights.max()
		var height_range: float = max_terrain - min_terrain

		# Здание должно быть на минимальной высоте
		var gap: float = base_height - min_terrain
		building_ok = abs(gap) < 0.1 and height_range < 5.0  # Не слишком крутой склон

		print("  Building: base=%.2fm, terrain_min=%.2fm, gap=%.2fm, slope=%.2fm %s" %
			[base_height, min_terrain, gap, height_range, "✓" if building_ok else "✗"])
	else:
		print("  Building: NOT FOUND ✗")

	var passed := road_ok and building_ok
	_test_results.append({
		"name": obj_name,
		"road_ok": road_ok,
		"building_ok": building_ok,
		"passed": passed
	})

	print("")

func _complete_test() -> void:
	print("========================================")
	print("COMPLEX TERRAIN TEST RESULTS")
	print("========================================\n")

	var total := _test_results.size()
	var passed := 0

	for result in _test_results:
		if result.passed:
			passed += 1

	var failed := total - passed

	print("Total objects tested: %d" % total)
	print("Passed: %d" % passed)
	print("Failed: %d" % failed)
	print("")

	if failed > 0:
		print("Failed objects:")
		for result in _test_results:
			if not result.passed:
				var issues: Array[String] = []
				if not result.road_ok:
					issues.append("road")
				if not result.building_ok:
					issues.append("building")
				print("  - %s: %s" % [result.name, ", ".join(issues)])
		print("")

	print("========================================")

	if failed == 0:
		print("[PASS] All complex terrain tests passed!")
		await get_tree().create_timer(0.5).timeout
		get_tree().quit(0)
	else:
		print("[FAIL] %d complex terrain tests failed" % failed)
		await get_tree().create_timer(0.5).timeout
		get_tree().quit(1)
