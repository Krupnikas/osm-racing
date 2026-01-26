extends Node3D

## Тестовая сцена для проверки светящихся окон зданий

var _camera: Camera3D
var _orbit_angle := 0.0
var _orbit_radius := 80.0
var _orbit_height := 40.0
var _orbit_speed := 0.1  # Радианы в секунду

# Этажность зданий для теста
var _floor_counts := [1, 2, 3, 4, 5, 9, 12, 16]
var _floor_height := 3.0  # Высота этажа в метрах

func _ready() -> void:
	_setup_environment()
	_create_ground()
	_create_buildings()
	_setup_camera()

	# Сразу включаем ночной режим
	_enable_night_mode()

	print("Test scene ready. Press N to toggle night mode.")


func _setup_environment() -> void:
	var world_env := $WorldEnvironment as WorldEnvironment
	var env := Environment.new()

	# Базовые настройки
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.1, 0.1, 0.15)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.2, 0.2, 0.3)
	env.ambient_light_energy = 0.3

	# Fog для атмосферы
	env.fog_enabled = true
	env.fog_light_color = Color(0.05, 0.05, 0.1)
	env.fog_density = 0.002

	# Glow/Bloom
	env.glow_enabled = true
	env.glow_intensity = 1.0
	env.glow_bloom = 0.3
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE

	world_env.environment = env


func _create_ground() -> void:
	var ground := MeshInstance3D.new()
	ground.name = "Ground"

	var plane := PlaneMesh.new()
	plane.size = Vector2(200, 200)
	ground.mesh = plane

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.15, 0.15, 0.15)
	ground.material_override = mat

	add_child(ground)


func _create_buildings() -> void:
	var buildings_parent := Node3D.new()
	buildings_parent.name = "Buildings"
	add_child(buildings_parent)

	# Размещаем здания по кругу
	var num_buildings := _floor_counts.size()
	var circle_radius := 40.0

	for i in range(num_buildings):
		var floors: int = _floor_counts[i]
		var height: float = floors * _floor_height
		var angle := (float(i) / num_buildings) * TAU

		var pos := Vector3(
			cos(angle) * circle_radius,
			0,
			sin(angle) * circle_radius
		)

		_create_building(pos, height, floors, buildings_parent)

	print("Created %d test buildings" % num_buildings)


func _create_building(pos: Vector3, height: float, floors: int, parent: Node3D) -> void:
	var building := Node3D.new()
	building.name = "Building_%d_floors" % floors
	building.position = pos

	# Размеры здания
	var width := 8.0 + floors * 0.5  # Больше этажей - шире здание
	var depth := 6.0 + floors * 0.3

	# Основной меш здания
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "BuildingMesh"

	var box := BoxMesh.new()
	box.size = Vector3(width, height, depth)
	mesh_instance.mesh = box
	mesh_instance.position.y = height / 2

	# Материал здания
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.3, 0.3, 0.35)
	mesh_instance.material_override = mat

	building.add_child(mesh_instance)

	# Добавляем светящиеся окна
	_add_windows_to_building(building, width, height, depth, floors)

	# Добавляем метку с количеством этажей
	_add_floor_label(building, height, floors)

	parent.add_child(building)


func _add_windows_to_building(building: Node3D, width: float, height: float, depth: float, floors: int) -> void:
	var windows_container := Node3D.new()
	windows_container.name = "Windows"

	# Параметры окон (квадратные)
	var window_size := 1.2
	var window_spacing_h := 2.5  # Горизонтальный интервал
	var floor_height := _floor_height

	# Цвета окон: 65% тёплые-холодные, 5% фитолампы (маджента)
	var warm_cold_colors := [
		Color(1.0, 0.85, 0.5),   # Тёплый жёлтый
		Color(1.0, 0.9, 0.6),    # Жёлтый
		Color(1.0, 0.95, 0.75),  # Светло-жёлтый
		Color(0.95, 0.92, 0.85), # Тёплый белый
		Color(0.9, 0.92, 0.95),  # Нейтральный белый
		Color(0.85, 0.9, 1.0),   # Холодный белый
		Color(0.75, 0.85, 1.0),  # Холодный голубоватый
	]
	var phyto_color := Color(0.9, 0.2, 0.9)  # Фиолетовый/маджента фитолампы

	var rng := RandomNumberGenerator.new()
	rng.seed = hash(building.position)

	# Стороны здания: передняя и задняя (по Z), левая и правая (по X)
	var sides := [
		{"normal": Vector3(0, 0, 1), "offset": depth / 2 + 0.05, "size": width, "axis": "x"},
		{"normal": Vector3(0, 0, -1), "offset": depth / 2 + 0.05, "size": width, "axis": "x"},
		{"normal": Vector3(1, 0, 0), "offset": width / 2 + 0.05, "size": depth, "axis": "z"},
		{"normal": Vector3(-1, 0, 0), "offset": width / 2 + 0.05, "size": depth, "axis": "z"},
	]

	for side in sides:
		var side_width: float = side["size"]
		var num_windows_h := int(side_width / window_spacing_h)
		if num_windows_h < 1:
			num_windows_h = 1

		for floor_idx in range(floors):
			for win_idx in range(num_windows_h):
				# 30% окон выключено
				if rng.randf() < 0.30:
					continue

				var window_mesh := MeshInstance3D.new()
				var box := BoxMesh.new()
				box.size = Vector3(window_size, window_size, 0.05)  # Квадратные окна
				window_mesh.mesh = box

				# Выбор цвета: ~93% тёплые-холодные, ~7% фитолампы (5% от всех окон)
				var color: Color
				var color_chance := rng.randf()
				if color_chance < 0.07:
					color = phyto_color
				else:
					color = warm_cold_colors[rng.randi() % warm_cold_colors.size()]

				var mat := StandardMaterial3D.new()
				mat.albedo_color = color
				mat.emission_enabled = true
				mat.emission = color
				mat.emission_energy_multiplier = 5.0
				mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				window_mesh.material_override = mat

				# Позиция окна
				var y_pos := floor_height * 0.5 + floor_idx * floor_height
				var h_offset := -side_width / 2 + window_spacing_h / 2 + win_idx * window_spacing_h

				var normal: Vector3 = side["normal"]
				var offset: float = side["offset"]

				if side["axis"] == "x":
					window_mesh.position = Vector3(h_offset, y_pos, normal.z * offset)
					if normal.z < 0:
						window_mesh.rotation.y = PI
				else:
					window_mesh.position = Vector3(normal.x * offset, y_pos, h_offset)
					window_mesh.rotation.y = PI / 2 if normal.x > 0 else -PI / 2

				windows_container.add_child(window_mesh)

	building.add_child(windows_container)


func _add_floor_label(building: Node3D, height: float, floors: int) -> void:
	# 3D текст с количеством этажей
	var label := Label3D.new()
	label.name = "FloorLabel"
	label.text = "%d" % floors
	label.font_size = 128
	label.position = Vector3(0, height + 2, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.modulate = Color(1, 1, 1)
	label.outline_size = 8
	building.add_child(label)


func _setup_camera() -> void:
	_camera = $Camera3D
	_camera.position = Vector3(_orbit_radius, _orbit_height, 0)
	_camera.look_at(Vector3.ZERO)


func _process(delta: float) -> void:
	# Вращаем камеру по орбите
	_orbit_angle += _orbit_speed * delta

	var cam_x := cos(_orbit_angle) * _orbit_radius
	var cam_z := sin(_orbit_angle) * _orbit_radius

	_camera.position = Vector3(cam_x, _orbit_height, cam_z)
	_camera.look_at(Vector3(0, 15, 0))


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_N:
			_toggle_night_mode()
		elif event.keycode == KEY_ESCAPE:
			get_tree().quit()


var _is_night := true

func _toggle_night_mode() -> void:
	_is_night = not _is_night

	var env := ($WorldEnvironment as WorldEnvironment).environment

	if _is_night:
		_enable_night_mode()
	else:
		# День
		env.background_color = Color(0.5, 0.6, 0.8)
		env.ambient_light_color = Color(0.6, 0.6, 0.6)
		env.ambient_light_energy = 1.0
		env.fog_light_color = Color(0.7, 0.75, 0.85)
		env.glow_intensity = 0.3
		$DirectionalLight3D.light_energy = 1.0

	print("Night mode: ", "ON" if _is_night else "OFF")


func _enable_night_mode() -> void:
	var env := ($WorldEnvironment as WorldEnvironment).environment
	env.background_color = Color(0.02, 0.02, 0.05)
	env.ambient_light_color = Color(0.1, 0.1, 0.2)
	env.ambient_light_energy = 0.2
	env.fog_light_color = Color(0.05, 0.03, 0.08)
	env.glow_intensity = 1.5
	$DirectionalLight3D.light_energy = 0.1
