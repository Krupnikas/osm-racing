extends RefCounted
class_name BuildingLights

## Создание неоновых вывесок и освещённых окон для зданий ночью

# Цвета неоновых вывесок (NFS Underground style)
const NEON_COLORS := [
	Color(1.0, 0.0, 0.4),   # Hot pink
	Color(0.0, 1.0, 0.9),   # Cyan
	Color(1.0, 0.3, 0.0),   # Orange
	Color(0.0, 0.5, 1.0),   # Blue
	Color(1.0, 1.0, 0.0),   # Yellow
	Color(0.8, 0.0, 1.0),   # Purple
	Color(0.0, 1.0, 0.3),   # Green
	Color(1.0, 0.0, 0.0),   # Red
]

# Тексты для вывесок (имитация)
const SIGN_PATTERNS := [
	"BAR", "SHOP", "24/7", "CAFE", "CLUB", "GYM", "OPEN", "PIZZA"
]


static func add_building_night_lights(building_mesh: MeshInstance3D, building_height: float, building_width: float, building_depth: float) -> Array[Node3D]:
	"""Добавляет ночное освещение к зданию: окна и неоновые вывески"""
	var lights: Array[Node3D] = []

	# Случайно решаем какие эффекты добавить
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(building_mesh.global_position)

	# 40% шанс на неоновую вывеску
	if rng.randf() < 0.4:
		var sign_node := _create_neon_sign(building_mesh, building_height, building_width, rng)
		if sign_node:
			lights.append(sign_node)

	# 60% шанс на освещённые окна
	if rng.randf() < 0.6 and building_height > 4.0:
		var windows := _create_lit_windows(building_mesh, building_height, building_width, building_depth, rng)
		lights.append_array(windows)

	return lights


static func _create_neon_sign(building: MeshInstance3D, height: float, width: float, rng: RandomNumberGenerator) -> Node3D:
	"""Создаёт неоновую вывеску на фасаде здания"""
	var container := Node3D.new()
	container.name = "NeonSign"

	# Выбираем случайный цвет
	var color: Color = NEON_COLORS[rng.randi() % NEON_COLORS.size()]

	# Размер вывески
	var sign_width := minf(width * 0.6, 4.0)
	var sign_height := 0.8

	# Позиция - на фасаде, на высоте 3-5 метров
	var sign_y := minf(height * 0.4, 5.0)
	var sign_z := 0.0  # Будет определено позже

	# Создаём светящийся mesh
	var sign_mesh := MeshInstance3D.new()
	sign_mesh.name = "SignMesh"
	var box := BoxMesh.new()
	box.size = Vector3(sign_width, sign_height, 0.15)
	sign_mesh.mesh = box

	# Материал с emission
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 6.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sign_mesh.material_override = mat

	# Позиция относительно здания
	sign_mesh.position = Vector3(0, sign_y, building.scale.z / 2 + 0.1)
	container.add_child(sign_mesh)

	# Добавляем источник света
	var light := OmniLight3D.new()
	light.name = "SignLight"
	light.position = sign_mesh.position + Vector3(0, 0, 0.5)
	light.omni_range = 8.0
	light.light_energy = 1.5
	light.light_color = color
	light.shadow_enabled = false
	container.add_child(light)

	# Позиционируем контейнер
	container.position = building.global_position

	return container


static func _create_lit_windows(building: MeshInstance3D, height: float, width: float, depth: float, rng: RandomNumberGenerator) -> Array[Node3D]:
	"""Создаёт освещённые окна на здании"""
	var windows: Array[Node3D] = []

	# Параметры окон
	var window_width := 0.8
	var window_height := 1.2
	var floor_height := 3.0
	var window_spacing := 2.5

	# Количество этажей
	var num_floors := int(height / floor_height)
	if num_floors < 1:
		return windows

	# Количество окон по ширине
	var num_windows_width := int(width / window_spacing)
	if num_windows_width < 1:
		num_windows_width = 1

	# Цвета света в окнах
	var window_colors := [
		Color(1.0, 0.9, 0.7),   # Тёплый белый
		Color(1.0, 0.95, 0.8),  # Тёплый жёлтый
		Color(0.8, 0.9, 1.0),   # Холодный белый (TV)
		Color(0.6, 0.7, 1.0),   # Синеватый (TV)
	]

	# Создаём окна на каждом этаже
	for floor_idx in range(num_floors):
		for window_idx in range(num_windows_width):
			# 50% шанс что окно горит
			if rng.randf() > 0.5:
				continue

			var window_container := Node3D.new()
			window_container.name = "Window_%d_%d" % [floor_idx, window_idx]

			# Позиция окна
			var wx := -width / 2 + window_spacing / 2 + window_idx * window_spacing
			var wy := floor_height / 2 + floor_idx * floor_height
			var wz := depth / 2 + 0.05

			# Mesh окна
			var window_mesh := MeshInstance3D.new()
			var box := BoxMesh.new()
			box.size = Vector3(window_width, window_height, 0.05)
			window_mesh.mesh = box

			# Случайный цвет
			var color: Color = window_colors[rng.randi() % window_colors.size()]

			var mat := StandardMaterial3D.new()
			mat.albedo_color = color
			mat.emission_enabled = true
			mat.emission = color
			mat.emission_energy_multiplier = 2.5
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			window_mesh.material_override = mat

			window_mesh.position = Vector3(wx, wy, wz)
			window_container.add_child(window_mesh)

			# Маленький источник света для отражения
			if rng.randf() < 0.3:  # Только 30% окон дают свет наружу
				var light := OmniLight3D.new()
				light.position = Vector3(wx, wy, wz + 0.5)
				light.omni_range = 4.0
				light.light_energy = 0.5
				light.light_color = color
				light.shadow_enabled = false
				window_container.add_child(light)

			window_container.position = building.global_position
			windows.append(window_container)

	return windows


static func create_street_neon_light(position: Vector3, color: Color = Color.CYAN) -> Node3D:
	"""Создаёт отдельную неоновую лампу/трубку на столбе или стене"""
	var container := Node3D.new()
	container.name = "StreetNeon"
	container.position = position

	# Неоновая трубка (горизонтальная)
	var tube_mesh := MeshInstance3D.new()
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 0.04
	cylinder.bottom_radius = 0.04
	cylinder.height = 1.5
	tube_mesh.mesh = cylinder
	tube_mesh.rotation_degrees = Vector3(0, 0, 90)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 8.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	tube_mesh.material_override = mat
	container.add_child(tube_mesh)

	# Свет
	var light := OmniLight3D.new()
	light.omni_range = 6.0
	light.light_energy = 1.8
	light.light_color = color
	light.shadow_enabled = false
	container.add_child(light)

	return container
