extends Node3D

# Тест для проверки езды машины по сложному рельефу
# Машина должна ехать по холмам и впадинам без провалов
# Запуск: godot --path . tests/test_car_on_terrain.tscn

var _car: VehicleBody3D
var _camera: Camera3D
var _terrain_size := 80.0
var _terrain_resolution := 40
var _terrain_amplitude := 6.0

var _test_duration := 15.0
var _elapsed := 0.0
var _test_running := false

# Записываем путь машины
var _car_path: Array[Vector3] = []
var _min_car_y := 1000.0
var _max_car_y := -1000.0
var _fall_through_count := 0
var _last_valid_y := 0.0

func _ready() -> void:
	print("\n========================================")
	print("Car on Complex Terrain Test")
	print("========================================\n")

	# Создаём сложный террейн
	_create_complex_terrain()

	# Ждём физику - дольше чтобы коллизия успела инициализироваться
	await get_tree().create_timer(1.0).timeout

	# Проверяем raycast чтобы убедиться что коллизия работает
	var space_state := get_world_3d().direct_space_state
	var attempts := 0
	while attempts < 30:
		var query := PhysicsRayQueryParameters3D.create(
			Vector3(0, 100, 0),
			Vector3(0, -100, 0)
		)
		query.collision_mask = 1
		var result := space_state.intersect_ray(query)
		if result:
			print("[TEST] Terrain collision ready after %d attempts" % attempts)
			break
		await get_tree().physics_frame
		attempts += 1

	if attempts >= 30:
		print("[WARN] Terrain collision may not be ready!")

	# Создаём машину
	_car = _create_test_car()
	add_child(_car)

	# Создаём камеру, следящую за машиной
	_camera = Camera3D.new()
	_camera.current = true
	add_child(_camera)

	# Ждём чтобы машина приземлилась
	await get_tree().create_timer(2.0).timeout
	_start_test()

func _create_complex_terrain() -> void:
	print("[TEST] Creating complex terrain...")

	var body := StaticBody3D.new()
	body.name = "Terrain"
	body.collision_layer = 1

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

			var height := _get_terrain_height(world_x, world_z)

			vertices.append(Vector3(world_x, height, world_z))
			normals.append(Vector3.UP)
			uvs.append(Vector2(float(x) / (_terrain_resolution - 1), float(z) / (_terrain_resolution - 1)))

	# Генерируем треугольники
	for z in range(_terrain_resolution - 1):
		for x in range(_terrain_resolution - 1):
			var top_left := z * _terrain_resolution + x
			var top_right := top_left + 1
			var bottom_left := (z + 1) * _terrain_resolution + x
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
	material.albedo_color = Color(0.4, 0.5, 0.3)
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh_inst.material_override = material

	body.add_child(mesh_inst)

	# Коллизия - используем HeightMapShape3D для быстрой инициализации
	var collision := CollisionShape3D.new()
	var heightmap := HeightMapShape3D.new()
	heightmap.map_width = _terrain_resolution
	heightmap.map_depth = _terrain_resolution

	# Создаём данные высот
	var map_data := PackedFloat32Array()
	map_data.resize(_terrain_resolution * _terrain_resolution)

	for z in range(_terrain_resolution):
		for x in range(_terrain_resolution):
			var world_x := -_terrain_size / 2.0 + x * step
			var world_z := -_terrain_size / 2.0 + z * step
			map_data[z * _terrain_resolution + x] = _get_terrain_height(world_x, world_z)

	heightmap.map_data = map_data

	collision.shape = heightmap
	# Масштабируем чтобы соответствовать размеру террейна
	collision.scale = Vector3(step, 1.0, step)
	body.add_child(collision)

	add_child(body)

	print("[TEST] Terrain created: %dx%d vertices, amplitude=%.1fm" %
		[_terrain_resolution, _terrain_resolution, _terrain_amplitude])

func _get_terrain_height(x: float, z: float) -> float:
	var height := 0.0

	# Большой холм в центре
	var dist_center := sqrt(x * x + z * z)
	height += _terrain_amplitude * 0.6 * exp(-dist_center * dist_center / 500.0)

	# Волны
	height += _terrain_amplitude * 0.25 * sin(x * 0.12) * cos(z * 0.12)

	# Дополнительные холмы
	height += _terrain_amplitude * 0.4 * exp(-((x - 20) * (x - 20) + z * z) / 150.0)
	height += _terrain_amplitude * 0.3 * exp(-((x + 25) * (x + 25) + (z - 15) * (z - 15)) / 200.0)

	# Впадина
	height -= _terrain_amplitude * 0.35 * exp(-((x - 10) * (x - 10) + (z + 20) * (z + 20)) / 120.0)

	return height

func _create_test_car() -> VehicleBody3D:
	var car := VehicleBody3D.new()
	car.name = "TestCar"
	car.mass = 1200.0

	# Коллизия
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2.0, 1.0, 4.0)
	collision.shape = box
	collision.position = Vector3(0, 0.5, 0)
	car.add_child(collision)

	# Визуал
	var mesh_inst := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = Vector3(2.0, 1.0, 4.0)
	mesh_inst.mesh = box_mesh
	mesh_inst.position = Vector3(0, 0.5, 0)

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.9, 0.2, 0.2)
	mesh_inst.material_override = material

	car.add_child(mesh_inst)

	# Колёса
	var wheel_positions := [
		Vector3(-0.9, 0.0, 1.5),   # Переднее левое
		Vector3(0.9, 0.0, 1.5),    # Переднее правое
		Vector3(-0.9, 0.0, -1.5),  # Заднее левое
		Vector3(0.9, 0.0, -1.5),   # Заднее правое
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

		# Визуал колеса
		var wheel_mesh := MeshInstance3D.new()
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = 0.4
		cylinder.bottom_radius = 0.4
		cylinder.height = 0.3
		wheel_mesh.mesh = cylinder
		wheel_mesh.rotation.z = deg_to_rad(90)

		var wheel_mat := StandardMaterial3D.new()
		wheel_mat.albedo_color = Color(0.2, 0.2, 0.2)
		wheel_mesh.material_override = wheel_mat

		wheel.add_child(wheel_mesh)
		car.add_child(wheel)

	# Начальная позиция - ближе к центру террейна
	var start_x := -20.0
	var start_z := 0.0
	var start_height := _get_terrain_height(start_x, start_z)
	car.position = Vector3(start_x, start_height + 3.0, start_z)

	_last_valid_y = start_height

	print("[TEST] Car created at (%.1f, %.1f, %.1f), terrain height=%.2f" %
		[car.position.x, car.position.y, car.position.z, start_height])

	return car

func _start_test() -> void:
	_test_running = true
	_elapsed = 0.0
	_car_path.clear()
	_min_car_y = 1000.0
	_max_car_y = -1000.0
	_fall_through_count = 0

	print("[TEST] Starting car driving test...")
	print("[TEST] Car will drive across terrain for %.0f seconds\n" % _test_duration)

func _physics_process(delta: float) -> void:
	if not _test_running:
		return

	_elapsed += delta

	# Камера следит за машиной
	if _camera and _car:
		var cam_offset := Vector3(-10, 8, 0)  # Сзади и сверху
		var target_pos := _car.position + cam_offset
		_camera.position = _camera.position.lerp(target_pos, 5.0 * delta)
		_camera.look_at(_car.position, Vector3.UP)

	# Управление машиной - едем вперёд
	_car.engine_force = 800.0

	# Лёгкое подруливание для интересной траектории
	var steer := sin(_elapsed * 0.5) * 0.3
	for child in _car.get_children():
		if child is VehicleWheel3D and child.use_as_steering:
			child.steering = steer

	# Записываем позицию
	_car_path.append(_car.position)

	# Проверяем высоту
	var terrain_height := _get_terrain_height(_car.position.x, _car.position.z)
	var car_bottom := _car.position.y - 0.5  # Нижняя часть машины

	_min_car_y = min(_min_car_y, _car.position.y)
	_max_car_y = max(_max_car_y, _car.position.y)

	# Проверяем провал сквозь землю
	if car_bottom < terrain_height - 1.0:
		_fall_through_count += 1
		print("[WARN] Car fell through terrain! car_y=%.2f, terrain=%.2f at (%.1f, %.1f)" %
			[_car.position.y, terrain_height, _car.position.x, _car.position.z])

	# Проверяем что машина не улетела
	if _car.position.y > 50.0 or _car.position.y < -20.0:
		print("[WARN] Car out of bounds! y=%.2f" % _car.position.y)

	_last_valid_y = _car.position.y

	# Завершаем тест
	if _elapsed >= _test_duration:
		_complete_test()

func _complete_test() -> void:
	_test_running = false

	print("\n========================================")
	print("CAR ON TERRAIN TEST RESULTS")
	print("========================================\n")

	var path_length := _car_path.size()
	var distance := 0.0
	for i in range(1, path_length):
		distance += _car_path[i].distance_to(_car_path[i - 1])

	print("Test duration: %.1f seconds" % _elapsed)
	print("Path points recorded: %d" % path_length)
	print("Distance traveled: %.1f meters" % distance)
	print("Car Y range: %.2f to %.2f meters" % [_min_car_y, _max_car_y])
	print("Fall-through incidents: %d" % _fall_through_count)
	print("")

	var passed := _fall_through_count == 0 and distance > 20.0

	print("========================================")

	if passed:
		print("[PASS] Car drove on terrain without falling through!")
		await get_tree().create_timer(3.0).timeout
		get_tree().quit(0)
	else:
		if _fall_through_count > 0:
			print("[FAIL] Car fell through terrain %d times!" % _fall_through_count)
		if distance <= 20.0:
			print("[FAIL] Car didn't travel enough distance (%.1fm < 20m)" % distance)
		await get_tree().create_timer(3.0).timeout
		get_tree().quit(1)
