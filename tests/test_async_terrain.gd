extends Node3D

# Тест для АСИНХРОННОЙ загрузки чанков террейна
# Симулирует поведение игры - чанки загружаются по одному
# и меши создаются сразу после загрузки elevation
# Проверяет что границы чанков совпадают
# Запуск: godot --path . tests/test_async_terrain.tscn

const CENTER_LAT := 41.723972
const CENTER_LON := 44.730502

const CHUNK_SIZE := 200.0
const GRID_RESOLUTION := 16

var _elevation_loader: Node
var _chunks_to_load: Array[Vector2i] = []
var _loaded_chunks: Dictionary = {}  # chunk_key -> elevation_data
var _terrain_meshes: Dictionary = {}
var _edge_heights: Dictionary = {}  # Согласованные границы между чанками

var _base_elevation := 0.0
var _car: VehicleBody3D
var _camera: Camera3D

var _test_duration := 15.0
var _elapsed := 0.0
var _test_running := false

var _car_min_y := 10000.0
var _car_max_y := -10000.0
var _fall_through_count := 0
var _total_samples := 0

var _chunks_created := 0
var _edge_mismatches := 0

func _ready() -> void:
	print("\n========================================")
	print("ASYNC Terrain Loading Test")
	print("Chunks load one by one, mesh created immediately")
	print("Location: Vazha-Pshavela, Tbilisi")
	print("========================================\n")

	_elevation_loader = preload("res://osm/elevation_loader.gd").new()
	add_child(_elevation_loader)
	_elevation_loader.elevation_loaded.connect(_on_elevation_loaded)
	_elevation_loader.elevation_failed.connect(_on_elevation_failed)

	# 3x3 сетка чанков
	for chunk_z in range(-1, 2):
		for chunk_x in range(-1, 2):
			_chunks_to_load.append(Vector2i(chunk_x, chunk_z))

	print("[TEST] Will load %d chunks ASYNCHRONOUSLY" % _chunks_to_load.size())

	# Загружаем первый чанк
	_load_next_chunk()

func _load_next_chunk() -> void:
	if _chunks_to_load.is_empty():
		print("\n[TEST] All chunks loaded and created!")
		_verify_all_edges()
		_spawn_car_and_start_test()
		return

	var chunk_pos: Vector2i = _chunks_to_load.pop_front()
	var chunk_key := "%d,%d" % [chunk_pos.x, chunk_pos.y]

	var chunk_lat: float = CENTER_LAT + (chunk_pos.y * CHUNK_SIZE) / 111000.0
	var chunk_lon: float = CENTER_LON + (chunk_pos.x * CHUNK_SIZE) / (111000.0 * cos(deg_to_rad(CENTER_LAT)))

	print("[TEST] Loading chunk %s..." % chunk_key)

	_elevation_loader.set_meta("current_chunk", chunk_pos)
	_elevation_loader.load_elevation_grid(chunk_lat, chunk_lon, CHUNK_SIZE / 2.0, GRID_RESOLUTION)

func _on_elevation_loaded(data: Dictionary) -> void:
	var chunk_pos: Vector2i = _elevation_loader.get_meta("current_chunk")
	var chunk_key := "%d,%d" % [chunk_pos.x, chunk_pos.y]

	_loaded_chunks[chunk_key] = {
		"chunk_pos": chunk_pos,
		"grid": data.grid,
		"grid_size": data.grid_size,
		"min_elevation": data.min_elevation,
		"max_elevation": data.max_elevation
	}

	if chunk_pos == Vector2i(0, 0):
		_base_elevation = data.min_elevation
		print("[TEST] Base elevation: %.0f m" % _base_elevation)

	print("[TEST] Chunk %s loaded (%.0f - %.0f m)" % [chunk_key, data.min_elevation, data.max_elevation])

	# СРАЗУ создаём меш - как в игре!
	_create_terrain_mesh_immediately(chunk_key)
	_chunks_created += 1

	# Ждём немного и загружаем следующий чанк
	await get_tree().create_timer(0.1).timeout
	_load_next_chunk()

func _on_elevation_failed(error: String) -> void:
	var chunk_pos: Vector2i = _elevation_loader.get_meta("current_chunk")
	print("[ERROR] Chunk %d,%d failed: %s" % [chunk_pos.x, chunk_pos.y, error])
	_load_next_chunk()

func _create_terrain_mesh_immediately(chunk_key: String) -> void:
	var data: Dictionary = _loaded_chunks[chunk_key]
	var chunk_pos: Vector2i = data.chunk_pos
	var grid: Array = data.grid
	var grid_size: int = data.grid_size

	# Сглаживаем с использованием согласованных границ
	grid = _blend_with_shared_edges(grid, grid_size, chunk_pos.x, chunk_pos.y)

	var chunk_origin := Vector3(
		chunk_pos.x * CHUNK_SIZE - CHUNK_SIZE / 2.0,
		0,
		chunk_pos.y * CHUNK_SIZE - CHUNK_SIZE / 2.0
	)

	var body := StaticBody3D.new()
	body.name = "Terrain_" + chunk_key
	body.collision_layer = 1

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	var cell_size := CHUNK_SIZE / (grid_size - 1)

	for z in range(grid_size):
		for x in range(grid_size):
			var world_x := chunk_origin.x + x * cell_size
			var world_z := chunk_origin.z + z * cell_size
			var height: float = float(grid[z][x]) - _base_elevation

			vertices.append(Vector3(world_x, height, world_z))
			normals.append(Vector3.UP)
			uvs.append(Vector2(float(x) / (grid_size - 1), float(z) / (grid_size - 1)))

	for z in range(grid_size - 1):
		for x in range(grid_size - 1):
			var top_left := z * grid_size + x
			var top_right := top_left + 1
			var bottom_left := (z + 1) * grid_size + x
			var bottom_right := bottom_left + 1

			indices.append(top_left)
			indices.append(bottom_left)
			indices.append(top_right)

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
	material.albedo_color = Color(0.35, 0.45, 0.25)
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh_inst.material_override = material

	body.add_child(mesh_inst)

	# HeightMap коллизия
	var collision := CollisionShape3D.new()
	var heightmap := HeightMapShape3D.new()
	heightmap.map_width = grid_size
	heightmap.map_depth = grid_size

	var map_data := PackedFloat32Array()
	map_data.resize(grid_size * grid_size)
	for z in range(grid_size):
		for x in range(grid_size):
			var height: float = float(grid[z][x]) - _base_elevation
			map_data[z * grid_size + x] = height

	heightmap.map_data = map_data

	collision.shape = heightmap
	collision.position = Vector3(
		chunk_origin.x + CHUNK_SIZE / 2.0,
		0,
		chunk_origin.z + CHUNK_SIZE / 2.0
	)
	collision.scale = Vector3(
		CHUNK_SIZE / float(grid_size - 1),
		1.0,
		CHUNK_SIZE / float(grid_size - 1)
	)
	body.add_child(collision)

	add_child(body)
	_terrain_meshes[chunk_key] = body

	print("[TEST] Mesh %s created at (%.0f, %.0f)" % [chunk_key, chunk_origin.x, chunk_origin.z])

# Ключ для границы между двумя чанками (всегда одинаковый независимо от порядка)
func _get_edge_key(chunk1_x: int, chunk1_z: int, chunk2_x: int, chunk2_z: int) -> String:
	var key1 := "%d,%d" % [chunk1_x, chunk1_z]
	var key2 := "%d,%d" % [chunk2_x, chunk2_z]
	if key1 < key2:
		return key1 + "|" + key2
	else:
		return key2 + "|" + key1

func _blend_with_shared_edges(grid: Array, grid_size: int, chunk_x: int, chunk_z: int) -> Array:
	var blended: Array = []
	for row in grid:
		blended.append(row.duplicate())

	var blend_width := 3

	# Соседи
	var left_key := "%d,%d" % [chunk_x - 1, chunk_z]
	var right_key := "%d,%d" % [chunk_x + 1, chunk_z]
	var top_key := "%d,%d" % [chunk_x, chunk_z - 1]
	var bottom_key := "%d,%d" % [chunk_x, chunk_z + 1]

	# Левая граница
	var left_edge_key := _get_edge_key(chunk_x, chunk_z, chunk_x - 1, chunk_z)
	if _edge_heights.has(left_edge_key):
		# Граница уже согласована - используем её
		var edge_data: Array = _edge_heights[left_edge_key]
		print("[BLEND] Chunk %d,%d LEFT uses existing edge %s (first val=%.2f)" % [chunk_x, chunk_z, left_edge_key, edge_data[0]])
		for z in range(grid_size):
			blended[z][0] = edge_data[z]
			for bx in range(1, blend_width):
				var t: float = float(bx) / float(blend_width)
				blended[z][bx] = lerpf(edge_data[z], float(grid[z][bx]), t)
	else:
		# Границы ещё нет - вычисляем среднее с соседом (если есть) или используем свои данные
		var edge_data: Array = []
		if _loaded_chunks.has(left_key):
			var neighbor_grid: Array = _loaded_chunks[left_key].get("grid", [])
			if neighbor_grid.size() == grid_size:
				for z in range(grid_size):
					var avg: float = (float(neighbor_grid[z][grid_size - 1]) + float(grid[z][0])) / 2.0
					edge_data.append(avg)
			else:
				for z in range(grid_size):
					edge_data.append(float(grid[z][0]))
		else:
			for z in range(grid_size):
				edge_data.append(float(grid[z][0]))
		_edge_heights[left_edge_key] = edge_data
		for z in range(grid_size):
			blended[z][0] = edge_data[z]
			for bx in range(1, blend_width):
				var t: float = float(bx) / float(blend_width)
				blended[z][bx] = lerpf(edge_data[z], float(grid[z][bx]), t)

	# Правая граница
	var right_edge_key := _get_edge_key(chunk_x, chunk_z, chunk_x + 1, chunk_z)
	if _edge_heights.has(right_edge_key):
		var edge_data: Array = _edge_heights[right_edge_key]
		print("[BLEND] Chunk %d,%d RIGHT uses existing edge %s (first val=%.2f)" % [chunk_x, chunk_z, right_edge_key, edge_data[0]])
		for z in range(grid_size):
			blended[z][grid_size - 1] = edge_data[z]
			for bx in range(1, blend_width):
				var x := grid_size - 1 - bx
				var t: float = float(bx) / float(blend_width)
				blended[z][x] = lerpf(edge_data[z], float(grid[z][x]), t)
	else:
		var edge_data: Array = []
		if _loaded_chunks.has(right_key):
			var neighbor_grid: Array = _loaded_chunks[right_key].get("grid", [])
			if neighbor_grid.size() == grid_size:
				for z in range(grid_size):
					var avg: float = (float(neighbor_grid[z][0]) + float(grid[z][grid_size - 1])) / 2.0
					edge_data.append(avg)
				print("[BLEND] Chunk %d,%d RIGHT creates AVERAGE edge %s with neighbor (first val=%.2f)" % [chunk_x, chunk_z, right_edge_key, edge_data[0]])
			else:
				for z in range(grid_size):
					edge_data.append(float(grid[z][grid_size - 1]))
				print("[BLEND] Chunk %d,%d RIGHT creates edge %s from OWN data (first val=%.2f)" % [chunk_x, chunk_z, right_edge_key, edge_data[0]])
		else:
			for z in range(grid_size):
				edge_data.append(float(grid[z][grid_size - 1]))
			print("[BLEND] Chunk %d,%d RIGHT creates edge %s from OWN data (no neighbor) (first val=%.2f)" % [chunk_x, chunk_z, right_edge_key, edge_data[0]])
		_edge_heights[right_edge_key] = edge_data
		for z in range(grid_size):
			blended[z][grid_size - 1] = edge_data[z]
			for bx in range(1, blend_width):
				var x := grid_size - 1 - bx
				var t: float = float(bx) / float(blend_width)
				blended[z][x] = lerpf(edge_data[z], float(grid[z][x]), t)

	# Верхняя граница
	var top_edge_key := _get_edge_key(chunk_x, chunk_z, chunk_x, chunk_z - 1)
	if _edge_heights.has(top_edge_key):
		var edge_data: Array = _edge_heights[top_edge_key]
		for x in range(grid_size):
			blended[0][x] = edge_data[x]
			for bz in range(1, blend_width):
				var t: float = float(bz) / float(blend_width)
				blended[bz][x] = lerpf(edge_data[x], float(blended[bz][x]), t)
	else:
		var edge_data: Array = []
		if _loaded_chunks.has(top_key):
			var neighbor_grid: Array = _loaded_chunks[top_key].get("grid", [])
			if neighbor_grid.size() == grid_size:
				for x in range(grid_size):
					var avg: float = (float(neighbor_grid[grid_size - 1][x]) + float(grid[0][x])) / 2.0
					edge_data.append(avg)
			else:
				for x in range(grid_size):
					edge_data.append(float(grid[0][x]))
		else:
			for x in range(grid_size):
				edge_data.append(float(grid[0][x]))
		_edge_heights[top_edge_key] = edge_data
		for x in range(grid_size):
			blended[0][x] = edge_data[x]
			for bz in range(1, blend_width):
				var t: float = float(bz) / float(blend_width)
				blended[bz][x] = lerpf(edge_data[x], float(blended[bz][x]), t)

	# Нижняя граница
	var bottom_edge_key := _get_edge_key(chunk_x, chunk_z, chunk_x, chunk_z + 1)
	if _edge_heights.has(bottom_edge_key):
		var edge_data: Array = _edge_heights[bottom_edge_key]
		for x in range(grid_size):
			blended[grid_size - 1][x] = edge_data[x]
			for bz in range(1, blend_width):
				var z := grid_size - 1 - bz
				var t: float = float(bz) / float(blend_width)
				blended[z][x] = lerpf(edge_data[x], float(blended[z][x]), t)
	else:
		var edge_data: Array = []
		if _loaded_chunks.has(bottom_key):
			var neighbor_grid: Array = _loaded_chunks[bottom_key].get("grid", [])
			if neighbor_grid.size() == grid_size:
				for x in range(grid_size):
					var avg: float = (float(neighbor_grid[0][x]) + float(grid[grid_size - 1][x])) / 2.0
					edge_data.append(avg)
			else:
				for x in range(grid_size):
					edge_data.append(float(grid[grid_size - 1][x]))
		else:
			for x in range(grid_size):
				edge_data.append(float(grid[grid_size - 1][x]))
		_edge_heights[bottom_edge_key] = edge_data
		for x in range(grid_size):
			blended[grid_size - 1][x] = edge_data[x]
			for bz in range(1, blend_width):
				var z := grid_size - 1 - bz
				var t: float = float(bz) / float(blend_width)
				blended[z][x] = lerpf(edge_data[x], float(blended[z][x]), t)

	return blended

func _verify_all_edges() -> void:
	print("\n[TEST] Verifying edge matching...")

	var space_state := get_world_3d().direct_space_state

	# Ждём физику
	for i in range(10):
		await get_tree().physics_frame

	# Проверяем границы между чанками
	var edges_to_check := [
		# Горизонтальные границы (между чанками по X)
		[Vector2i(-1, -1), Vector2i(0, -1)],
		[Vector2i(0, -1), Vector2i(1, -1)],
		[Vector2i(-1, 0), Vector2i(0, 0)],
		[Vector2i(0, 0), Vector2i(1, 0)],
		[Vector2i(-1, 1), Vector2i(0, 1)],
		[Vector2i(0, 1), Vector2i(1, 1)],
		# Вертикальные границы (между чанками по Z)
		[Vector2i(-1, -1), Vector2i(-1, 0)],
		[Vector2i(-1, 0), Vector2i(-1, 1)],
		[Vector2i(0, -1), Vector2i(0, 0)],
		[Vector2i(0, 0), Vector2i(0, 1)],
		[Vector2i(1, -1), Vector2i(1, 0)],
		[Vector2i(1, 0), Vector2i(1, 1)],
	]

	for edge in edges_to_check:
		var chunk1: Vector2i = edge[0]
		var chunk2: Vector2i = edge[1]

		# Определяем где граница
		var is_horizontal := chunk1.y == chunk2.y  # Граница по X

		if is_horizontal:
			# Граница между chunk1 (слева) и chunk2 (справа)
			var edge_x: float = chunk2.x * CHUNK_SIZE - CHUNK_SIZE / 2.0
			var edge_z_center: float = chunk1.y * CHUNK_SIZE  # Центр по Z

			# Проверяем несколько точек вдоль границы
			# Используем большее смещение чтобы попасть во внутреннюю интерполяцию
			var offsets: Array[float] = [-80.0, -40.0, 0.0, 40.0, 80.0]
			for offset in offsets:
				var test_z: float = edge_z_center + offset

				# Точки на расстоянии ~1 ячейки от границы для проверки плавности
				var cell_size: float = CHUNK_SIZE / (GRID_RESOLUTION - 1)
				var h_left: float = _raycast_height(space_state, Vector2(edge_x - cell_size * 0.5, test_z))
				var h_right: float = _raycast_height(space_state, Vector2(edge_x + cell_size * 0.5, test_z))

				if h_left > -9000 and h_right > -9000:
					var diff: float = abs(h_left - h_right)
					# Допуск 3м - реальный terrain имеет уклоны до 10-15%, что при cell_size ~13м даёт ~2м разницы
					if diff > 3.0:
						print("[EDGE MISMATCH] Between %d,%d and %d,%d at z=%.0f: left=%.2f right=%.2f diff=%.2f" %
							[chunk1.x, chunk1.y, chunk2.x, chunk2.y, test_z, h_left, h_right, diff])
						_edge_mismatches += 1
		else:
			# Вертикальная граница между chunk1 (сверху) и chunk2 (снизу)
			var edge_z: float = chunk2.y * CHUNK_SIZE - CHUNK_SIZE / 2.0
			var edge_x_center: float = chunk1.x * CHUNK_SIZE  # Центр по X

			var offsets: Array[float] = [-80.0, -40.0, 0.0, 40.0, 80.0]
			var cell_size: float = CHUNK_SIZE / (GRID_RESOLUTION - 1)
			for offset in offsets:
				var test_x: float = edge_x_center + offset

				var h_top: float = _raycast_height(space_state, Vector2(test_x, edge_z - cell_size * 0.5))
				var h_bottom: float = _raycast_height(space_state, Vector2(test_x, edge_z + cell_size * 0.5))

				if h_top > -9000 and h_bottom > -9000:
					var diff: float = abs(h_top - h_bottom)
					if diff > 3.0:
						print("[EDGE MISMATCH] Between %d,%d and %d,%d at x=%.0f: top=%.2f bottom=%.2f diff=%.2f" %
							[chunk1.x, chunk1.y, chunk2.x, chunk2.y, test_x, h_top, h_bottom, diff])
						_edge_mismatches += 1

	if _edge_mismatches == 0:
		print("[TEST] All edges match perfectly!")
	else:
		print("[TEST] Found %d edge mismatches" % _edge_mismatches)

func _spawn_car_and_start_test() -> void:
	print("\n[TEST] Spawning car...")

	var space_state := get_world_3d().direct_space_state

	# Ждём физику
	for i in range(30):
		await get_tree().physics_frame

	var spawn_height := _raycast_height(space_state, Vector2(0, 0))
	if spawn_height < -9000:
		spawn_height = 10.0

	_car = VehicleBody3D.new()
	_car.name = "TestCar"
	_car.mass = 1200.0

	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2.0, 1.0, 4.0)
	collision.shape = box
	collision.position = Vector3(0, 0.5, 0)
	_car.add_child(collision)

	var mesh := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = Vector3(2.0, 1.0, 4.0)
	mesh.mesh = box_mesh
	mesh.position = Vector3(0, 0.5, 0)
	_car.add_child(mesh)

	# Колёса
	for wheel_data in [
		{"pos": Vector3(-0.8, 0.3, 1.2), "steer": true},
		{"pos": Vector3(0.8, 0.3, 1.2), "steer": true},
		{"pos": Vector3(-0.8, 0.3, -1.2), "steer": false},
		{"pos": Vector3(0.8, 0.3, -1.2), "steer": false},
	]:
		var wheel := VehicleWheel3D.new()
		wheel.position = wheel_data.pos
		wheel.use_as_steering = wheel_data.steer
		wheel.use_as_traction = not wheel_data.steer
		wheel.wheel_radius = 0.35
		_car.add_child(wheel)

	_car.position = Vector3(0, spawn_height + 2.0, 0)
	add_child(_car)

	_camera = Camera3D.new()
	_camera.current = true
	add_child(_camera)

	await get_tree().create_timer(2.0).timeout
	_start_test()

func _raycast_height(space_state: PhysicsDirectSpaceState3D, pos: Vector2) -> float:
	var query := PhysicsRayQueryParameters3D.create(
		Vector3(pos.x, 200, pos.y),
		Vector3(pos.x, -200, pos.y)
	)
	query.collision_mask = 1

	var result := space_state.intersect_ray(query)
	if result:
		return result.position.y

	return -10000.0

func _start_test() -> void:
	_test_running = true
	print("\n[TEST] Car driving test started for %.0f seconds" % _test_duration)

func _physics_process(delta: float) -> void:
	if not _test_running:
		return

	_elapsed += delta

	if _camera and _car:
		var cam_offset := Vector3(-10, 8, 0)
		var target_pos := _car.position + cam_offset
		_camera.position = _camera.position.lerp(target_pos, 5.0 * delta)
		_camera.look_at(_car.position, Vector3.UP)

	_car.engine_force = 600.0
	var steer := sin(_elapsed * 0.3) * 0.4
	for child in _car.get_children():
		if child is VehicleWheel3D and child.use_as_steering:
			child.steering = steer

	# Статистика
	_total_samples += 1
	_car_min_y = min(_car_min_y, _car.position.y)
	_car_max_y = max(_car_max_y, _car.position.y)

	if _car.position.y < -50:
		_fall_through_count += 1
		_car.position.y = 50

	if _elapsed >= _test_duration:
		_complete_test()

func _complete_test() -> void:
	_test_running = false

	print("\n========================================")
	print("ASYNC TERRAIN TEST RESULTS")
	print("========================================\n")

	print("Chunks created: %d" % _chunks_created)
	print("Edge mismatches: %d" % _edge_mismatches)
	print("Car Y range: %.2f to %.2f" % [_car_min_y, _car_max_y])
	print("Fall through count: %d" % _fall_through_count)

	var passed := _edge_mismatches == 0 and _fall_through_count == 0

	print("\n========================================")
	if passed:
		print("[PASS] Async terrain test passed!")
		await get_tree().create_timer(3.0).timeout
		get_tree().quit(0)
	else:
		if _edge_mismatches > 0:
			print("[FAIL] Edge mismatches detected!")
		if _fall_through_count > 0:
			print("[FAIL] Car fell through terrain!")
		await get_tree().create_timer(3.0).timeout
		get_tree().quit(1)
