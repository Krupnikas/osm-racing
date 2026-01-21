extends Node3D

# Тест для мультичанкового сглаженного террейна
# Загружает РЕАЛЬНЫЕ данные высот из API/кеша через ElevationLoader
# Использует координаты Важа-Пшавела (41.723972, 44.730502)
# Запуск: godot --path . tests/test_multi_chunk_smoothed.tscn

# Координаты Важа-Пшавела, Тбилиси
const CENTER_LAT := 41.723972
const CENTER_LON := 44.730502

const CHUNK_SIZE := 200.0  # Размер чанка в метрах (как в основной игре)
const GRID_RESOLUTION := 16  # Разрешение сетки для каждого чанка

var _elevation_loader: Node
var _chunks_to_load: Array[Vector2i] = []
var _loaded_chunks: Dictionary = {}  # chunk_key -> elevation_data
var _terrain_meshes: Dictionary = {}

var _base_elevation := 0.0
var _car: VehicleBody3D
var _camera: Camera3D

var _test_duration := 20.0
var _elapsed := 0.0
var _test_running := false

# Статистика машины
var _car_min_y := 10000.0
var _car_max_y := -10000.0
var _fall_through_count := 0
var _total_samples := 0

# Статистика сглаживания
var _smoothing_stats: Dictionary = {}

func _ready() -> void:
	print("\n========================================")
	print("Multi-Chunk Smoothed Terrain Test")
	print("Using REAL elevation data from API/cache")
	print("Location: Vazha-Pshavela, Tbilisi")
	print("Coords: %.6f, %.6f" % [CENTER_LAT, CENTER_LON])
	print("========================================\n")

	# Создаём загрузчик высот
	_elevation_loader = preload("res://osm/elevation_loader.gd").new()
	add_child(_elevation_loader)
	_elevation_loader.elevation_loaded.connect(_on_elevation_loaded)
	_elevation_loader.elevation_failed.connect(_on_elevation_failed)

	# Определяем чанки для загрузки (3x3 сетка)
	for chunk_z in range(-1, 2):
		for chunk_x in range(-1, 2):
			_chunks_to_load.append(Vector2i(chunk_x, chunk_z))

	print("[TEST] Will load %d chunks" % _chunks_to_load.size())

	# Начинаем загрузку первого чанка
	_load_next_chunk()

func _load_next_chunk() -> void:
	if _chunks_to_load.is_empty():
		print("\n[TEST] All chunks loaded! Creating terrain...")
		_create_all_terrain()
		return

	var chunk_pos: Vector2i = _chunks_to_load.pop_front()
	var chunk_key := "%d,%d" % [chunk_pos.x, chunk_pos.y]

	# Вычисляем координаты центра чанка
	var chunk_lat: float = CENTER_LAT + (chunk_pos.y * CHUNK_SIZE) / 111000.0
	var chunk_lon: float = CENTER_LON + (chunk_pos.x * CHUNK_SIZE) / (111000.0 * cos(deg_to_rad(CENTER_LAT)))

	print("[TEST] Loading chunk %s (lat=%.5f, lon=%.5f)..." % [chunk_key, chunk_lat, chunk_lon])

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
		"max_elevation": data.max_elevation,
		"center_lat": data.center_lat,
		"center_lon": data.center_lon
	}

	# Устанавливаем базовую высоту от центрального чанка
	if chunk_pos == Vector2i(0, 0):
		_base_elevation = data.min_elevation
		print("[TEST] Base elevation set to %.0f m" % _base_elevation)

	print("[TEST] Chunk %s loaded: elevation range %.0f - %.0f m" %
		[chunk_key, data.min_elevation, data.max_elevation])

	# Сохраняем статистику для проверки сглаживания
	_smoothing_stats[chunk_key] = {
		"min": data.min_elevation,
		"max": data.max_elevation,
		"range": data.max_elevation - data.min_elevation
	}

	# Загружаем следующий чанк
	_load_next_chunk()

func _on_elevation_failed(error: String) -> void:
	var chunk_pos: Vector2i = _elevation_loader.get_meta("current_chunk")
	var chunk_key := "%d,%d" % [chunk_pos.x, chunk_pos.y]
	print("[ERROR] Failed to load chunk %s: %s" % [chunk_key, error])
	# Продолжаем загрузку остальных чанков
	_load_next_chunk()

func _create_all_terrain() -> void:
	print("\n[TEST] Creating terrain meshes with edge blending...")

	for chunk_key in _loaded_chunks.keys():
		var data: Dictionary = _loaded_chunks[chunk_key]
		_create_terrain_mesh(data, chunk_key)

	# Ждём готовности физики - активная проверка вместо простого ожидания
	print("[TEST] Waiting for physics initialization...")
	var space_state := get_world_3d().direct_space_state
	var collision_ready := false
	var max_attempts := 300  # До 5 секунд (300 * physics_frame ~= 5 сек при 60fps)
	var attempts := 0

	# Проверяем несколько точек чтобы убедиться что все чанки готовы
	var test_points := [
		Vector2(0, 0),      # Центр
		Vector2(-150, 0),   # Левый чанк
		Vector2(150, 0),    # Правый чанк
		Vector2(0, -150),   # Верхний чанк
		Vector2(0, 150),    # Нижний чанк
	]

	while attempts < max_attempts:
		var all_ready := true
		for test_point in test_points:
			var query := PhysicsRayQueryParameters3D.create(
				Vector3(test_point.x, 200, test_point.y),
				Vector3(test_point.x, -200, test_point.y)
			)
			query.collision_mask = 1
			var result := space_state.intersect_ray(query)
			if not result:
				all_ready = false
				break

		if all_ready:
			collision_ready = true
			print("[TEST] Terrain collision ready after %d physics frames" % attempts)
			break

		await get_tree().physics_frame
		attempts += 1

		if attempts % 60 == 0:
			print("[TEST] Still waiting for collision... (%d frames)" % attempts)

	if not collision_ready:
		print("[WARN] Terrain collision not fully ready after %d attempts!" % max_attempts)

	# Дополнительные кадры для стабилизации
	for i in range(10):
		await get_tree().physics_frame

	# Создаём дороги
	_create_roads()

	# Создаём машину и камеру - с проверкой готовности
	print("[TEST] Verifying collision before spawning car...")
	var spawn_height := -10000.0
	var spawn_attempts := 0
	while spawn_height < -9000 and spawn_attempts < 60:
		var spawn_query := PhysicsRayQueryParameters3D.create(
			Vector3(0, 200, 0),
			Vector3(0, -200, 0)
		)
		spawn_query.collision_mask = 1
		var spawn_result := space_state.intersect_ray(spawn_query)
		if spawn_result:
			spawn_height = spawn_result.position.y
			print("[TEST] Spawn point collision confirmed at y=%.2f" % spawn_height)
			break
		await get_tree().physics_frame
		spawn_attempts += 1

	if spawn_height < -9000:
		print("[WARN] Spawn point collision not ready, using fallback!")
		spawn_height = 10.0

	# Тест raycast в нескольких точках
	print("[DEBUG] Final raycast tests:")
	for test_pos in [Vector2(0, 0), Vector2(50, 0), Vector2(-50, 0), Vector2(0, 50), Vector2(0, -50)]:
		var h := _raycast_height(space_state, test_pos)
		print("  pos(%.0f, %.0f) -> height=%.2f" % [test_pos.x, test_pos.y, h])

	_create_car(spawn_height)

	_camera = Camera3D.new()
	_camera.current = true
	add_child(_camera)

	# Ждём приземления машины
	await get_tree().create_timer(2.0).timeout
	_start_test()

# Сглаживает границы чанка с соседними чанками для плавных переходов
func _blend_chunk_edges(grid: Array, grid_size: int, chunk_x: int, chunk_z: int) -> Array:
	# Создаём копию сетки
	var blended: Array = []
	for row in grid:
		blended.append(row.duplicate())

	var blend_width := 2  # Количество точек для сглаживания

	# Ключи соседних чанков
	var neighbors := {
		"left": "%d,%d" % [chunk_x - 1, chunk_z],
		"right": "%d,%d" % [chunk_x + 1, chunk_z],
		"top": "%d,%d" % [chunk_x, chunk_z - 1],
		"bottom": "%d,%d" % [chunk_x, chunk_z + 1]
	}

	# Левая граница (x = 0)
	if _loaded_chunks.has(neighbors.left):
		var neighbor_grid: Array = _loaded_chunks[neighbors.left].get("grid", [])
		if neighbor_grid.size() == grid_size:
			for z in range(grid_size):
				var neighbor_edge: float = neighbor_grid[z][grid_size - 1]
				for bx in range(blend_width):
					var t: float = float(bx) / float(blend_width)
					var blended_val: float = lerpf(neighbor_edge, float(grid[z][bx]), t)
					blended[z][bx] = lerpf(blended_val, float(grid[z][bx]), t)

	# Правая граница (x = grid_size - 1)
	if _loaded_chunks.has(neighbors.right):
		var neighbor_grid: Array = _loaded_chunks[neighbors.right].get("grid", [])
		if neighbor_grid.size() == grid_size:
			for z in range(grid_size):
				var neighbor_edge: float = neighbor_grid[z][0]
				for bx in range(blend_width):
					var x := grid_size - 1 - bx
					var t: float = float(bx) / float(blend_width)
					var blended_val: float = lerpf(neighbor_edge, float(grid[z][x]), t)
					blended[z][x] = lerpf(blended_val, float(grid[z][x]), t)

	# Верхняя граница (z = 0)
	if _loaded_chunks.has(neighbors.top):
		var neighbor_grid: Array = _loaded_chunks[neighbors.top].get("grid", [])
		if neighbor_grid.size() == grid_size:
			for x in range(grid_size):
				var neighbor_edge: float = neighbor_grid[grid_size - 1][x]
				for bz in range(blend_width):
					var t: float = float(bz) / float(blend_width)
					var blended_val: float = lerpf(neighbor_edge, float(grid[bz][x]), t)
					blended[bz][x] = lerpf(blended_val, float(blended[bz][x]), t)

	# Нижняя граница (z = grid_size - 1)
	if _loaded_chunks.has(neighbors.bottom):
		var neighbor_grid: Array = _loaded_chunks[neighbors.bottom].get("grid", [])
		if neighbor_grid.size() == grid_size:
			for x in range(grid_size):
				var neighbor_edge: float = neighbor_grid[0][x]
				for bz in range(blend_width):
					var z := grid_size - 1 - bz
					var t: float = float(bz) / float(blend_width)
					var blended_val: float = lerpf(neighbor_edge, float(grid[z][x]), t)
					blended[z][x] = lerpf(blended_val, float(blended[z][x]), t)

	return blended

func _create_terrain_mesh(data: Dictionary, chunk_key: String) -> void:
	var chunk_pos: Vector2i = data.chunk_pos
	var grid: Array = data.grid
	var grid_size: int = data.grid_size

	# Сглаживаем границы с соседними чанками
	grid = _blend_chunk_edges(grid, grid_size, chunk_pos.x, chunk_pos.y)

	# Вычисляем позицию чанка в мировых координатах (относительно центра)
	# Чанк 0,0 должен быть от -100 до 100 (с центром в 0)
	var chunk_origin := Vector3(
		chunk_pos.x * CHUNK_SIZE - CHUNK_SIZE / 2.0,
		0,
		chunk_pos.y * CHUNK_SIZE - CHUNK_SIZE / 2.0
	)

	print("[DEBUG] Chunk %s: origin=(%.0f, %.0f), grid_size=%d" %
		[chunk_key, chunk_origin.x, chunk_origin.z, grid_size])

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

	# Генерируем вершины
	for z in range(grid_size):
		for x in range(grid_size):
			var world_x := chunk_origin.x + x * cell_size
			var world_z := chunk_origin.z + z * cell_size
			var height: float = float(grid[z][x]) - _base_elevation

			vertices.append(Vector3(world_x, height, world_z))
			normals.append(Vector3.UP)
			uvs.append(Vector2(float(x) / (grid_size - 1), float(z) / (grid_size - 1)))

	# Генерируем треугольники
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

	# Коллизия через HeightMapShape3D - используем те же сглаженные данные
	var collision := CollisionShape3D.new()
	var heightmap := HeightMapShape3D.new()
	heightmap.map_width = grid_size
	heightmap.map_depth = grid_size

	# Конвертируем сглаженную сетку в PackedFloat32Array для HeightMapShape3D
	var map_data := PackedFloat32Array()
	map_data.resize(grid_size * grid_size)
	for z in range(grid_size):
		for x in range(grid_size):
			var height: float = float(grid[z][x]) - _base_elevation
			map_data[z * grid_size + x] = height

	heightmap.map_data = map_data

	collision.shape = heightmap
	# Позиционируем коллизию в центре чанка
	collision.position = Vector3(
		chunk_origin.x + CHUNK_SIZE / 2.0,
		0,
		chunk_origin.z + CHUNK_SIZE / 2.0
	)
	# Масштабируем до размера чанка
	collision.scale = Vector3(
		CHUNK_SIZE / float(grid_size - 1),
		1.0,
		CHUNK_SIZE / float(grid_size - 1)
	)
	body.add_child(collision)

	add_child(body)
	_terrain_meshes[chunk_key] = body

	print("[TEST] Terrain mesh %s created at origin (%.0f, 0, %.0f)" %
		[chunk_key, chunk_origin.x, chunk_origin.z])

func _create_roads() -> void:
	print("\n[TEST] Creating roads across chunks...")

	var space_state := get_world_3d().direct_space_state

	# Дороги разных типов - пересекают несколько чанков
	# Увеличено количество сегментов для точного следования рельефу
	var road_specs := [
		# Главные дороги через весь мир
		{"start": Vector2(-280, 0), "end": Vector2(280, 0), "width": 10.0, "segments": 100, "name": "Main_EW"},
		{"start": Vector2(0, -280), "end": Vector2(0, 280), "width": 10.0, "segments": 100, "name": "Main_NS"},

		# Второстепенные дороги
		{"start": Vector2(-200, -100), "end": Vector2(200, -80), "width": 7.0, "segments": 80, "name": "Secondary_1"},
		{"start": Vector2(-180, 120), "end": Vector2(180, 100), "width": 7.0, "segments": 80, "name": "Secondary_2"},

		# Диагональные улицы
		{"start": Vector2(-150, -150), "end": Vector2(150, 150), "width": 6.0, "segments": 80, "name": "Diagonal_1"},
		{"start": Vector2(-140, 140), "end": Vector2(140, -140), "width": 6.0, "segments": 80, "name": "Diagonal_2"},

		# Локальные улицы
		{"start": Vector2(50, -50), "end": Vector2(150, -40), "width": 5.0, "segments": 30, "name": "Street_1"},
		{"start": Vector2(-60, 30), "end": Vector2(-60, 130), "width": 5.0, "segments": 30, "name": "Street_2"},
		{"start": Vector2(-120, -60), "end": Vector2(-40, -70), "width": 5.0, "segments": 25, "name": "Street_3"},
		{"start": Vector2(80, 60), "end": Vector2(160, 90), "width": 5.0, "segments": 25, "name": "Street_4"},
	]

	for spec in road_specs:
		var road := _create_terrain_following_road(
			space_state,
			spec.start,
			spec.end,
			spec.width,
			spec.segments,
			spec.name
		)
		if road:
			add_child(road)

	print("[TEST] Created %d roads" % road_specs.size())

func _create_terrain_following_road(space_state: PhysicsDirectSpaceState3D, start: Vector2, end: Vector2, width: float, segments: int, road_name: String) -> Node3D:
	var road := Node3D.new()
	road.name = "Road_" + road_name

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	var direction := (end - start).normalized()
	var perpendicular := Vector2(-direction.y, direction.x)
	var half_width := width / 2.0

	for i in range(segments + 1):
		var t := float(i) / segments
		var center := start.lerp(end, t)

		var left := center + perpendicular * half_width
		var right := center - perpendicular * half_width

		# Сэмплируем несколько точек поперёк дороги для точного определения высоты
		var height_left := _raycast_height(space_state, left)
		var height_center := _raycast_height(space_state, center)
		var height_right := _raycast_height(space_state, right)

		if height_left < -9000 or height_right < -9000 or height_center < -9000:
			continue  # Пропускаем точки без террейна

		# Берём максимальную высоту из всех точек + offset
		var max_height := maxf(maxf(height_left, height_right), height_center)
		vertices.append(Vector3(left.x, max_height + 0.15, left.y))
		vertices.append(Vector3(right.x, max_height + 0.15, right.y))

		normals.append(Vector3.UP)
		normals.append(Vector3.UP)

		uvs.append(Vector2(t, 0))
		uvs.append(Vector2(t, 1))

	if vertices.size() < 4:
		print("[WARN] Road %s has too few vertices" % road_name)
		return null

	var vertex_pairs := vertices.size() / 2
	for i in range(vertex_pairs - 1):
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
	material.albedo_color = Color(0.2, 0.2, 0.22)
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh_inst.material_override = material

	road.add_child(mesh_inst)

	# Сохраняем данные для анализа дороги
	road.set_meta("vertex_count", vertices.size())

	return road

func _raycast_height(space_state: PhysicsDirectSpaceState3D, pos: Vector2) -> float:
	var query := PhysicsRayQueryParameters3D.create(
		Vector3(pos.x, 200, pos.y),
		Vector3(pos.x, -200, pos.y)
	)
	query.collision_mask = 1

	var result := space_state.intersect_ray(query)
	if result:
		return result.position.y

	return -10000.0  # Нет террейна

func _create_car(spawn_height: float) -> void:
	_car = VehicleBody3D.new()
	_car.name = "TestCar"
	_car.mass = 1200.0

	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2.0, 1.0, 4.0)
	collision.shape = box
	collision.position = Vector3(0, 0.5, 0)
	_car.add_child(collision)

	var mesh_inst := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = Vector3(2.0, 1.0, 4.0)
	mesh_inst.mesh = box_mesh
	mesh_inst.position = Vector3(0, 0.5, 0)

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.9, 0.15, 0.1)
	mesh_inst.material_override = material
	_car.add_child(mesh_inst)

	var wheel_positions := [
		Vector3(-0.9, 0.0, 1.5),
		Vector3(0.9, 0.0, 1.5),
		Vector3(-0.9, 0.0, -1.5),
		Vector3(0.9, 0.0, -1.5),
	]

	for i in range(4):
		var wheel := VehicleWheel3D.new()
		wheel.use_as_steering = i < 2
		wheel.use_as_traction = i >= 2
		wheel.wheel_radius = 0.4
		wheel.wheel_rest_length = 0.2
		wheel.wheel_friction_slip = 3.0
		wheel.suspension_stiffness = 50.0
		wheel.suspension_travel = 0.3
		wheel.damping_compression = 2.0
		wheel.damping_relaxation = 2.5
		wheel.position = wheel_positions[i]

		var wheel_mesh := MeshInstance3D.new()
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = 0.4
		cylinder.bottom_radius = 0.4
		cylinder.height = 0.3
		wheel_mesh.mesh = cylinder
		wheel_mesh.rotation.z = deg_to_rad(90)

		var wheel_mat := StandardMaterial3D.new()
		wheel_mat.albedo_color = Color(0.15, 0.15, 0.15)
		wheel_mesh.material_override = wheel_mat

		wheel.add_child(wheel_mesh)
		_car.add_child(wheel)

	# Позиция машины - высота передаётся как параметр (уже проверена)
	_car.position = Vector3(0, spawn_height + 2.0, 0)

	add_child(_car)

	print("[TEST] Car spawned at (0, %.1f, 0), ground=%.1f" % [_car.position.y, spawn_height])

func _start_test() -> void:
	_test_running = true
	_elapsed = 0.0
	_car_min_y = 10000.0
	_car_max_y = -10000.0
	_fall_through_count = 0
	_total_samples = 0

	print("\n[TEST] Starting driving test...")
	print("[TEST] Car will drive across multiple chunks for %.0f seconds\n" % _test_duration)

func _physics_process(delta: float) -> void:
	if not _test_running or not _car:
		return

	_elapsed += delta
	_total_samples += 1

	# Камера
	if _camera:
		var cam_offset := Vector3(-12, 10, 0)
		var target_pos := _car.position + cam_offset
		_camera.position = _camera.position.lerp(target_pos, 5.0 * delta)
		_camera.look_at(_car.position, Vector3.UP)

	# Управление
	_car.engine_force = 1000.0
	var steer := sin(_elapsed * 0.3) * 0.4 + sin(_elapsed * 0.7) * 0.2
	for child in _car.get_children():
		if child is VehicleWheel3D and child.use_as_steering:
			child.steering = steer

	# Статистика
	var car_y := _car.position.y
	_car_min_y = min(_car_min_y, car_y)
	_car_max_y = max(_car_max_y, car_y)

	# Проверяем провал (машина значительно ниже террейна)
	var space_state := get_world_3d().direct_space_state
	var terrain_height := _raycast_height(space_state, Vector2(_car.position.x, _car.position.z))
	var car_bottom := car_y - 0.5

	# Провал считается если машина на 2+ метра ниже террейна
	if terrain_height > -9000 and car_bottom < terrain_height - 2.0:
		_fall_through_count += 1
		if _fall_through_count <= 5:
			print("[WARN] Car fell through! y=%.1f, terrain=%.1f at (%.1f, %.1f)" %
				[car_y, terrain_height, _car.position.x, _car.position.z])

	if _elapsed >= _test_duration:
		_complete_test()

func _complete_test() -> void:
	_test_running = false

	print("\n========================================")
	print("MULTI-CHUNK SMOOTHED TERRAIN TEST RESULTS")
	print("(Real elevation data from API/cache)")
	print("========================================\n")

	print("Test parameters:")
	print("  Location: Vazha-Pshavela, Tbilisi")
	print("  Coordinates: %.6f, %.6f" % [CENTER_LAT, CENTER_LON])
	print("  Chunks loaded: %d" % _loaded_chunks.size())
	print("  Chunk size: %.0fm" % CHUNK_SIZE)
	print("  Grid resolution: %d per chunk" % GRID_RESOLUTION)
	print("  Base elevation: %.0fm" % _base_elevation)
	print("")

	print("Elevation data per chunk:")
	for chunk_key in _smoothing_stats.keys():
		var stats: Dictionary = _smoothing_stats[chunk_key]
		print("  %s: %.0f - %.0f m (range: %.0fm)" %
			[chunk_key, stats.min, stats.max, stats.range])
	print("")

	print("Car statistics:")
	print("  Test duration: %.1f seconds" % _elapsed)
	print("  Total samples: %d" % _total_samples)
	print("  Y range: %.1f - %.1f m (%.1fm variation)" %
		[_car_min_y, _car_max_y, _car_max_y - _car_min_y])
	print("  Fall-through incidents: %d" % _fall_through_count)
	print("")

	# Итоговые результаты
	var chunks_ok := _loaded_chunks.size() >= 9
	var terrain_ok := _fall_through_count < 5
	var driving_ok := _car_max_y - _car_min_y < 100.0

	print("Test results:")
	print("  Chunks loaded: %s (%d/9)" % ["PASS" if chunks_ok else "FAIL", _loaded_chunks.size()])
	print("  Terrain collision: %s (fall-throughs: %d)" % ["PASS" if terrain_ok else "FAIL", _fall_through_count])
	print("  Driving stability: %s (Y range: %.1fm)" % ["PASS" if driving_ok else "FAIL", _car_max_y - _car_min_y])
	print("")

	var all_passed := chunks_ok and terrain_ok and driving_ok

	print("========================================")
	if all_passed:
		print("[PASS] Multi-chunk smoothed terrain test PASSED!")
		await get_tree().create_timer(3.0).timeout
		get_tree().quit(0)
	else:
		print("[FAIL] Multi-chunk smoothed terrain test FAILED")
		await get_tree().create_timer(3.0).timeout
		get_tree().quit(1)
