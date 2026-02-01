extends Node3D

## Скрипт для настройки модели Volkswagen Polo Sedan 2017
## Скрывает колёса из модели, так как используются VehicleWheel3D
## Изменяет цвет кузова
## Переключает материал стёкол день/ночь
## Управляет габаритами (emission + OmniLight)

# Цвет кузова (серебристый)
var body_color := Color(0.75, 0.75, 0.8, 1.0)  # Серебристый

# Цвета стёкол для дня и ночи
var glass_color_day := Color(0.12, 0.14, 0.2, 0.5)  # Полупрозрачная тонировка днём
var glass_color_night := Color(0.05, 0.07, 0.12, 1.0)  # Глухая тонировка ночью

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
var _vehicle: Node  # Ссылка на Vehicle для проверки торможения

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

	# Находим Vehicle (родитель)
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

	print("Polo Sedan model setup complete")

func _process(_delta: float) -> void:
	# Проверяем режим дня/ночи (ищем NightModeManager)
	var night_manager = get_node_or_null("/root/Main/NightModeManager")
	if night_manager and "is_night" in night_manager:
		var current_night: bool = night_manager.is_night
		if current_night != _is_night:
			_is_night = current_night
			_update_glass_materials()
			_update_headlights()

	# Обновляем emission габаритов при торможении
	_update_taillight_brightness()

func _update_glass_materials() -> void:
	"""Обновляет материалы стёкол в зависимости от времени суток"""
	for material in _glass_materials:
		if not is_instance_valid(material):
			continue

		if _is_night:
			# Ночью - непрозрачные с бликами
			material.albedo_color = glass_color_night
			material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
			material.metallic = 0.2
			material.metallic_specular = 0.8
			material.roughness = 0.1
			material.clearcoat = 0.9
			material.clearcoat_roughness = 0.05
		else:
			# Днём - полупрозрачные
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
		# Скрываем объекты с названиями содержащими "wheel", "tire"
		if "wheel" in mesh_name or "tire" in mesh_name:
			mesh.visible = false
			print("Polo: Hidden wheel mesh: ", mesh.name)

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

		# Проверяем тип детали по имени меша
		var is_glass: bool = "glass" in mesh_name and not "lightglass" in mesh_name
		var is_light: bool = "light" in mesh_name or "stop" in mesh_name or "gabarit" in mesh_name or "fog" in mesh_name or "head" in mesh_name or "run" in mesh_name or "long" in mesh_name or "_red" in mesh_name or "reve" in mesh_name
		var is_wheel: bool = "wheel" in mesh_name or "tire" in mesh_name
		var is_chrome: bool = "chrome" in mesh_name or "mirror" in mesh_name
		var is_interior: bool = "salon" in mesh_name or "seats" in mesh_name or "dash" in mesh_name or "pribor" in mesh_name or "gauges" in mesh_name or "clock" in mesh_name or "kover" in mesh_name
		var is_body: bool = "body" in mesh_name or "roof" in mesh_name

		# Пропускаем фары, хром, колёса и салон
		if is_light or is_wheel or is_chrome or is_interior:
			continue

		# Проходим по всем surface материалам
		var surface_count: int = mesh.get_surface_override_material_count()
		if surface_count == 0 and mesh.mesh:
			surface_count = mesh.mesh.get_surface_count()

		for i in range(surface_count):
			var material: Material = mesh.get_surface_override_material(i)
			if not material and mesh.mesh:
				# Создаём копию оригинального материала
				var original_mat: Material = mesh.mesh.surface_get_material(i)
				if original_mat:
					material = original_mat.duplicate()
					mesh.set_surface_override_material(i, material)

			if material:
				var mat_name := ""
				if material.resource_name:
					mat_name = material.resource_name.to_lower()

				# Проверяем материал на предмет фар/стёкол
				var is_light_material: bool = "light" in mat_name or "stop" in mat_name or "gabarit" in mat_name or "head" in mat_name or "fog" in mat_name

				if is_light_material:
					continue

				if material is StandardMaterial3D:
					if is_glass:
						# Для стёкол - настраиваем и сохраняем для переключения день/ночь
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
					elif is_body:
						# Для кузова - глянцевая краска с лаком
						material.albedo_color = body_color
						material.metallic = 0.3
						material.metallic_specular = 0.8
						material.roughness = 0.15
						material.clearcoat = 0.9
						material.clearcoat_roughness = 0.1


func _setup_taillights() -> void:
	"""Находит материалы задних габаритов и создаёт стоп-сигналы"""
	var meshes := _find_all_meshes(self)

	for mesh in meshes:
		if not (mesh is MeshInstance3D):
			continue

		var mesh_name: String = mesh.name.to_lower()

		# Ищем стоп-сигналы и красные элементы
		if "stop" in mesh_name or "_red" in mesh_name:
			print("Polo: Found taillight mesh: ", mesh.name)
			_setup_taillight_material(mesh)

	# Создаём SpotLight3D для стоп-сигналов (направлены назад)
	# Polo примерно 4.4м длиной, центр координат примерно в центре
	# При scale 2.3: Z задней части ~-1.0 (в мировых координатах после масштабирования ~-2.3)
	var brake_positions := [
		Vector3(-0.6, 0.7, -2.1),  # Левый
		Vector3(0.6, 0.7, -2.1),   # Правый
	]

	for i in range(brake_positions.size()):
		var light := SpotLight3D.new()
		light.name = "BrakeLight_%d" % i
		light.position = brake_positions[i]
		light.rotation_degrees = Vector3(0, 180, 0)  # Направлен назад
		light.spot_range = 1.5
		light.spot_angle = 90.0
		light.light_energy = 0.3  # Тусклый свет для габаритов
		light.light_color = Color(1.0, 0.0, 0.0)
		light.shadow_enabled = false
		light.visible = true

		get_parent().add_child(light)
		_brake_lights.append(light)


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
			# Габариты всегда светятся, но тускло
			material.emission_enabled = true
			material.emission = Color(1.0, 0.1, 0.1)  # Красный
			material.emission_energy_multiplier = 0.5  # Тусклые габариты
			_taillight_materials.append(material)


func _setup_frontlights() -> void:
	"""Находит материалы передних габаритов и включает emission"""
	var meshes := _find_all_meshes(self)

	for mesh in meshes:
		if not (mesh is MeshInstance3D):
			continue

		var mesh_name: String = mesh.name.to_lower()

		# Ищем передние габариты/поворотники
		if "gabarit" in mesh_name or "pov" in mesh_name:
			print("Polo: Found front marker mesh: ", mesh.name)
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
			# Передние габариты - жёлто-оранжевые, всегда тускло светятся
			material.emission_enabled = true
			material.emission = Color(1.0, 0.6, 0.1)  # Жёлто-оранжевый
			material.emission_energy_multiplier = 0.5
			_frontlight_materials.append(material)


func _setup_headlights() -> void:
	"""Создаёт SpotLight3D для передних фар"""
	# Polo ~4.4м длиной, передняя часть на Z ~+2.2
	var headlight_positions := [
		Vector3(-0.55, 0.65, 2.1),  # Левая фара
		Vector3(0.55, 0.65, 2.1),   # Правая фара
	]

	for i in range(headlight_positions.size()):
		var light := SpotLight3D.new()
		light.name = "Headlight_%d" % i
		light.position = headlight_positions[i]
		light.rotation_degrees = Vector3(0, 0, 0)  # Направлен вперёд (по +Z)
		light.spot_range = 30.0
		light.spot_angle = 45.0
		light.light_energy = 2.0
		light.light_color = Color(1.0, 0.95, 0.8)  # Тёплый белый
		light.shadow_enabled = true
		light.visible = _is_night  # Включаются только ночью

		get_parent().add_child(light)
		_headlights.append(light)


func _update_taillight_brightness() -> void:
	"""Обновляет яркость габаритов и включает стоп-сигналы при торможении"""
	var braking := false
	if _vehicle and "brake_input" in _vehicle:
		braking = _vehicle.brake_input > 0.1

	# Emission: тусклый для габаритов, яркий при торможении
	for material in _taillight_materials:
		if is_instance_valid(material):
			material.emission_energy_multiplier = 2.0 if braking else 0.5

	# SpotLight: тусклый для габаритов, яркий при торможении
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

	# Материал для светящихся полосок
	_underglow_material = StandardMaterial3D.new()
	_underglow_material.albedo_color = color
	_underglow_material.emission_enabled = true
	_underglow_material.emission = color
	_underglow_material.emission_energy_multiplier = 3.0

	# Polo: колёсная база ~2.55м, ширина ~1.7м
	# 5 SpotLight3D с каждой стороны
	var left_positions: Array[Vector3] = []
	var right_positions: Array[Vector3] = []
	for i in range(5):
		var z: float = 1.0 - (i * 0.5)  # От 1.0 до -1.0
		left_positions.append(Vector3(-0.75, 0.25, z))
		right_positions.append(Vector3(0.75, 0.25, z))

	# 3 под задним бампером
	var rear_positions: Array[Vector3] = []
	for i in range(3):
		var x: float = -0.5 + (i * 0.5)
		rear_positions.append(Vector3(x, 0.25, -2.0))

	# 3 под передним бампером
	var front_positions: Array[Vector3] = []
	for i in range(3):
		var x: float = -0.5 + (i * 0.5)
		front_positions.append(Vector3(x, 0.25, 2.0))

	# Боковые источники
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
		light.rotation_degrees = Vector3(-90, 0, 0)  # Светит вниз (-Y)
		light.spot_range = 1.0
		light.spot_angle = 60.0
		light.light_energy = 0.8
		light.light_color = color
		light.shadow_enabled = true
		light.visible = _underglow_enabled
		get_parent().add_child(light)
		_underglow_lights.append(light)

	# Задние источники
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

	# Передние источники
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
	"""Переключает неон вкл/выкл, при включении меняет цвет"""
	_underglow_enabled = not _underglow_enabled

	# При включении - следующий цвет
	if _underglow_enabled:
		_underglow_color_index = (_underglow_color_index + 1) % UNDERGLOW_COLORS.size()
		var new_color: Color = UNDERGLOW_COLORS[_underglow_color_index]

		for light in _underglow_lights:
			if is_instance_valid(light):
				light.light_color = new_color

		if _underglow_material:
			_underglow_material.albedo_color = new_color
			_underglow_material.emission = new_color

	# Включаем/выключаем
	for light in _underglow_lights:
		if is_instance_valid(light):
			light.visible = _underglow_enabled

	print("Underglow: ", "ON (color %d)" % _underglow_color_index if _underglow_enabled else "OFF")
