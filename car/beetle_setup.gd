extends Node3D

## Скрипт для настройки модели VW New Beetle 1998
## Скрывает колёса модели (используются VehicleWheel3D)
## Настраивает цвет кузова и стёкла
## Создаёт габариты и фары

# Цвет кузова (жёлтый - классический для Beetle)
var body_color := Color(0.95, 0.85, 0.2, 1.0)

# Цвета стёкол
var glass_color_day := Color(0.12, 0.14, 0.2, 0.5)
var glass_color_night := Color(0.05, 0.07, 0.12, 1.0)

var _glass_materials: Array[StandardMaterial3D] = []
var _taillight_materials: Array[StandardMaterial3D] = []
var _frontlight_materials: Array[StandardMaterial3D] = []
var _brake_lights: Array[SpotLight3D] = []
var _headlights: Array[SpotLight3D] = []
var _underglow_lights: Array[SpotLight3D] = []
var _underglow_material: StandardMaterial3D
var _underglow_enabled := true
var _underglow_color_index := 0
var _is_night := false
var _vehicle: Node
var _night_manager: Node

# Цвета неона
const UNDERGLOW_COLORS := [
	Color(0.0, 1.0, 0.9),   # Cyan
	Color(0.8, 0.0, 1.0),   # Purple
	Color(1.0, 0.0, 0.5),   # Pink
	Color(0.0, 1.0, 0.3),   # Green
	Color(1.0, 0.5, 0.0),   # Orange
]


func _ready() -> void:
	await get_tree().process_frame

	_vehicle = get_parent()

	# Скрываем колёса модели
	_hide_model_wheels()

	# Меняем цвет кузова
	_change_body_color()

	# Настраиваем габариты
	_setup_taillights()
	_setup_frontlights()
	_setup_headlights()
	_setup_underglow()

	print("Beetle model setup complete")


func _process(_delta: float) -> void:
	# Проверяем режим дня/ночи
	if not is_instance_valid(_night_manager):
		_night_manager = get_tree().current_scene.find_child("NightModeManager", true, false)
	if _night_manager and "is_night" in _night_manager:
		var current_night: bool = _night_manager.is_night
		if current_night != _is_night:
			_is_night = current_night
			_update_glass_materials()
			_update_headlights()

	_update_taillight_brightness()


func _update_glass_materials() -> void:
	"""Обновляет материалы стёкол в зависимости от времени суток"""
	for material in _glass_materials:
		if not is_instance_valid(material):
			continue

		if _is_night:
			material.albedo_color = glass_color_night
			material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
			material.metallic = 0.2
			material.metallic_specular = 0.8
			material.roughness = 0.1
			material.clearcoat = 0.9
			material.clearcoat_roughness = 0.05
		else:
			material.albedo_color = glass_color_day
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			material.metallic = 0.0
			material.metallic_specular = 0.5
			material.roughness = 0.05
			material.clearcoat = 0.0
			material.clearcoat_roughness = 0.0


func _hide_model_wheels() -> void:
	"""Скрывает колёса из импортированной модели"""
	var meshes := _find_all_meshes(self)

	for mesh in meshes:
		var mesh_name: String = mesh.name.to_lower()
		# Скрываем объекты с названиями содержащими "disk", "rim", "wheel", "tire"
		if "disk" in mesh_name or "rim" in mesh_name or "wheel" in mesh_name or "tire" in mesh_name:
			mesh.visible = false
			print("Beetle: Hidden wheel mesh: ", mesh.name)


func _find_all_meshes(node: Node) -> Array:
	"""Рекурсивно находит все MeshInstance3D"""
	var meshes: Array = []

	if node is MeshInstance3D:
		meshes.append(node)

	for child in node.get_children():
		meshes.append_array(_find_all_meshes(child))

	return meshes


func _change_body_color() -> void:
	"""Меняет цвет кузова"""
	var meshes := _find_all_meshes(self)

	for mesh in meshes:
		if not (mesh is MeshInstance3D):
			continue

		var mesh_name: String = mesh.name.to_lower()
		print("Beetle: Found mesh: ", mesh.name)

		# Проверяем тип детали
		var is_glass: bool = "glass" in mesh_name or "wind" in mesh_name
		var is_light: bool = "light" in mesh_name or "lamp" in mesh_name
		var is_wheel: bool = "disk" in mesh_name or "rim" in mesh_name or "wheel" in mesh_name or "tire" in mesh_name
		var is_chrome: bool = "chrome" in mesh_name or "metal" in mesh_name or "mirror" in mesh_name
		var is_interior: bool = "salon" in mesh_name or "seat" in mesh_name or "carpet" in mesh_name or "dash" in mesh_name
		var is_body: bool = "body" in mesh_name

		# Пропускаем фары, колёса, хром, салон
		if is_light or is_wheel or is_chrome or is_interior:
			print("  -> Skipping (light/wheel/chrome/interior)")
			continue

		var surface_count: int = mesh.get_surface_override_material_count()
		if surface_count == 0 and mesh.mesh:
			surface_count = mesh.mesh.get_surface_count()

		for i in range(surface_count):
			var material: Material = mesh.get_surface_override_material(i)
			if not material and mesh.mesh:
				var original_mat: Material = mesh.mesh.surface_get_material(i)
				if original_mat:
					material = original_mat.duplicate()
					mesh.set_surface_override_material(i, material)
					print("  -> Created override material for surface ", i)

			if material:
				var mat_name := ""
				if material.resource_name:
					mat_name = material.resource_name.to_lower()
				print("  -> Material: ", material.resource_name, " (", material.get_class(), ")")

				# Пропускаем материалы фар
				var is_light_material: bool = "light" in mat_name or "lamp" in mat_name or "white" in mat_name or "yellow" in mat_name or "orange" in mat_name or "red" in mat_name
				if "glass" in mat_name and not "wind" in mat_name:
					is_light_material = true

				if is_light_material:
					print("  -> Skipping light material")
					continue

				if material is StandardMaterial3D:
					if is_glass:
						# Стёкла
						material.albedo_texture = null
						material.normal_texture = null
						material.albedo_color = glass_color_day
						material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
						material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
						material.cull_mode = BaseMaterial3D.CULL_DISABLED
						material.metallic = 0.0
						material.metallic_specular = 0.5
						material.roughness = 0.05
						_glass_materials.append(material)
						print("  -> Changed glass to tinted")
					elif is_body:
						# Кузов - глянцевая краска
						material.albedo_texture = null
						material.albedo_color = body_color
						material.metallic = 0.3
						material.metallic_specular = 0.8
						material.roughness = 0.15
						material.clearcoat = 0.9
						material.clearcoat_roughness = 0.1
						print("  -> Changed body color to yellow")
				elif material is BaseMaterial3D:
					if is_glass:
						material.albedo_color = glass_color_day
						material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
						print("  -> Changed glass")
					elif is_body:
						material.albedo_color = body_color
						print("  -> Changed body color")


func _setup_taillights() -> void:
	"""Находит материалы задних габаритов и создаёт стоп-сигналы"""
	var meshes := _find_all_meshes(self)

	for mesh in meshes:
		if not (mesh is MeshInstance3D):
			continue

		var mesh_name: String = mesh.name.to_lower()

		# Ищем красное стекло задних габаритов
		if "red" in mesh_name and "glass" in mesh_name:
			print("Beetle: Found taillight mesh: ", mesh.name)
			_setup_taillight_material(mesh)

	# SpotLight3D для стоп-сигналов (Beetle - задние фары выше и по краям)
	var brake_positions := [
		Vector3(-0.5, 0.6, -1.7),  # Левый
		Vector3(0.5, 0.6, -1.7),   # Правый
	]

	for i in range(brake_positions.size()):
		var light := SpotLight3D.new()
		light.name = "BrakeLight_%d" % i
		light.position = brake_positions[i]
		light.rotation_degrees = Vector3(0, 0, 0)  # Назад (по -Z)
		light.spot_range = 1.5
		light.spot_angle = 90.0
		light.light_energy = 0.3
		light.light_color = Color(1.0, 0.0, 0.0)
		light.shadow_enabled = false
		light.visible = true

		get_parent().add_child(light)
		_brake_lights.append(light)
		print("  -> Created brake SpotLight at ", brake_positions[i])


func _setup_taillight_material(mesh: MeshInstance3D) -> void:
	"""Настраивает материал для габаритов"""
	var surface_count: int = mesh.get_surface_override_material_count()
	if surface_count == 0 and mesh.mesh:
		surface_count = mesh.mesh.get_surface_count()

	for i in range(surface_count):
		var material: Material = mesh.get_surface_override_material(i)
		if not material and mesh.mesh:
			var original_mat: Material = mesh.mesh.surface_get_material(i)
			if original_mat:
				material = original_mat.duplicate()
				mesh.set_surface_override_material(i, material)

		if material is StandardMaterial3D:
			material.emission_enabled = true
			material.emission = Color(1.0, 0.1, 0.1)
			material.emission_energy_multiplier = 0.5
			_taillight_materials.append(material)
			print("  -> Added taillight material")


func _setup_frontlights() -> void:
	"""Находит материалы передних габаритов (оранжевые)"""
	var meshes := _find_all_meshes(self)

	for mesh in meshes:
		if not (mesh is MeshInstance3D):
			continue

		var mesh_name: String = mesh.name.to_lower()

		if "orange" in mesh_name and "glass" in mesh_name:
			print("Beetle: Found front marker mesh: ", mesh.name)
			_setup_frontlight_material(mesh)


func _setup_frontlight_material(mesh: MeshInstance3D) -> void:
	"""Настраивает материал для передних габаритов"""
	var surface_count: int = mesh.get_surface_override_material_count()
	if surface_count == 0 and mesh.mesh:
		surface_count = mesh.mesh.get_surface_count()

	for i in range(surface_count):
		var material: Material = mesh.get_surface_override_material(i)
		if not material and mesh.mesh:
			var original_mat: Material = mesh.mesh.surface_get_material(i)
			if original_mat:
				material = original_mat.duplicate()
				mesh.set_surface_override_material(i, material)

		if material is StandardMaterial3D:
			material.emission_enabled = true
			material.emission = Color(1.0, 0.6, 0.1)
			material.emission_energy_multiplier = 0.5
			_frontlight_materials.append(material)
			print("  -> Added front marker material")


func _setup_headlights() -> void:
	"""Создаёт SpotLight3D для передних фар"""
	# Beetle - круглые фары по краям капота
	var headlight_positions := [
		Vector3(-0.55, 0.55, 1.6),  # Левая фара
		Vector3(0.55, 0.55, 1.6),   # Правая фара
	]

	for i in range(headlight_positions.size()):
		var light := SpotLight3D.new()
		light.name = "Headlight_%d" % i
		light.position = headlight_positions[i]
		light.rotation_degrees = Vector3(0, 180, 0)  # Вперёд
		light.spot_range = 30.0
		light.spot_angle = 45.0
		light.light_energy = 2.0
		light.light_color = Color(1.0, 0.95, 0.8)
		light.shadow_enabled = true
		light.visible = _is_night

		get_parent().add_child(light)
		_headlights.append(light)
		print("  -> Created headlight SpotLight at ", headlight_positions[i])


func _update_taillight_brightness() -> void:
	"""Обновляет яркость габаритов при торможении"""
	var braking := false
	if _vehicle and "brake_input" in _vehicle:
		braking = _vehicle.brake_input > 0.1

	for material in _taillight_materials:
		if is_instance_valid(material):
			material.emission_energy_multiplier = 2.0 if braking else 0.5

	for light in _brake_lights:
		if is_instance_valid(light):
			light.light_energy = 2.0 if braking else 0.3


func _update_headlights() -> void:
	"""Включает/выключает фары в зависимости от времени суток"""
	for light in _headlights:
		if is_instance_valid(light):
			light.visible = _is_night


func _setup_underglow() -> void:
	"""Создаёт неоновую подсветку под машиной"""
	var color := UNDERGLOW_COLORS[0]

	_underglow_material = StandardMaterial3D.new()
	_underglow_material.albedo_color = color
	_underglow_material.emission_enabled = true
	_underglow_material.emission = color
	_underglow_material.emission_energy_multiplier = 3.0

	# Beetle короче Nexia - 5 источников с каждой стороны
	var left_positions: Array[Vector3] = []
	var right_positions: Array[Vector3] = []
	for i in range(5):
		var z: float = 0.6 - (i * 0.3)
		left_positions.append(Vector3(-0.6, 0.35, z))
		right_positions.append(Vector3(0.6, 0.35, z))

	var rear_positions: Array[Vector3] = []
	for i in range(3):
		var x: float = -0.35 + (i * 0.35)
		rear_positions.append(Vector3(x, 0.35, -1.4))

	var front_positions: Array[Vector3] = []
	for i in range(3):
		var x: float = -0.35 + (i * 0.35)
		front_positions.append(Vector3(x, 0.3, 1.3))

	var side_count: int = left_positions.size() + right_positions.size()
	for i in range(side_count):
		var pos: Vector3
		if i < left_positions.size():
			pos = left_positions[i]
		else:
			pos = right_positions[i - left_positions.size()]
		var light := SpotLight3D.new()
		light.name = "Underglow_%d" % i
		light.position = pos
		light.rotation_degrees = Vector3(-90, 0, 0)
		light.spot_range = 1.0
		light.spot_angle = 60.0
		light.light_energy = 0.8
		light.light_color = color
		light.shadow_enabled = true
		light.visible = _underglow_enabled
		get_parent().add_child(light)
		_underglow_lights.append(light)

	for i in range(rear_positions.size()):
		var light := SpotLight3D.new()
		light.name = "UnderglowRear_%d" % i
		light.position = rear_positions[i]
		light.rotation_degrees = Vector3(-90, 0, 0)
		light.spot_range = 1.0
		light.spot_angle = 70.0
		light.light_energy = 0.8
		light.light_color = color
		light.shadow_enabled = true
		light.visible = _underglow_enabled
		get_parent().add_child(light)
		_underglow_lights.append(light)

	for i in range(front_positions.size()):
		var light := SpotLight3D.new()
		light.name = "UnderglowFront_%d" % i
		light.position = front_positions[i]
		light.rotation_degrees = Vector3(-90, 0, 0)
		light.spot_range = 1.0
		light.spot_angle = 90.0
		light.light_energy = 0.8
		light.light_color = color
		light.shadow_enabled = true
		light.visible = _underglow_enabled
		get_parent().add_child(light)
		_underglow_lights.append(light)

	print("  -> Created underglow with %d lights" % _underglow_lights.size())


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_G:
			_toggle_underglow()


func _toggle_underglow() -> void:
	"""Переключает неон вкл/выкл"""
	_underglow_enabled = not _underglow_enabled

	if _underglow_enabled:
		_underglow_color_index = (_underglow_color_index + 1) % UNDERGLOW_COLORS.size()
		var new_color: Color = UNDERGLOW_COLORS[_underglow_color_index]

		for light in _underglow_lights:
			if is_instance_valid(light):
				light.light_color = new_color

		if _underglow_material:
			_underglow_material.albedo_color = new_color
			_underglow_material.emission = new_color

	for light in _underglow_lights:
		if is_instance_valid(light):
			light.visible = _underglow_enabled

	print("Underglow: ", "ON (color %d)" % _underglow_color_index if _underglow_enabled else "OFF")
