extends Node3D

## Скрипт для настройки модели Daewoo Nexia
## Скрывает колёса из модели, так как используются VehicleWheel3D
## Изменяет цвет кузова
## Переключает материал стёкол день/ночь
## Управляет габаритами (emission + OmniLight)
##
## ВАЖНО: Модель Nexia имеет transform с инвертированной осью Z (scale -10)
## Поэтому в координатах Vehicle:
## - Передняя часть (капот, фары) находится в ОТРИЦАТЕЛЬНОМ Z
## - Задняя часть (багажник, габариты) находится в ПОЛОЖИТЕЛЬНОМ Z

# Цвет кузова (бордовый - тёмно-вишнёвый)
var body_color := Color(0.5, 0.05, 0.1, 1.0)  # Бордовый

# Цвета стёкол для дня и ночи
var glass_color_day := Color(0.12, 0.14, 0.2, 0.5)  # Полупрозрачная тонировка днём
var glass_color_night := Color(0.05, 0.07, 0.12, 1.0)  # Глухая тонировка ночью

var _glass_materials: Array[StandardMaterial3D] = []
var _taillight_materials: Array[StandardMaterial3D] = []
var _frontlight_materials: Array[StandardMaterial3D] = []
var _brake_lights: Array[SpotLight3D] = []
var _headlights: Array[SpotLight3D] = []
var _is_night := false
var _vehicle: Node  # Ссылка на Vehicle для проверки торможения

func _ready() -> void:
	await get_tree().process_frame

	# Находим Vehicle (родитель)
	_vehicle = get_parent()

	# Меняем цвет кузова
	_change_body_color()

	# Настраиваем габариты
	_setup_taillights()
	_setup_frontlights()
	_setup_headlights()

	print("Nexia model setup complete")

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
	# Ищем все MeshInstance3D которые могут быть колёсами
	var meshes := _find_all_meshes(self)

	for mesh in meshes:
		var mesh_name: String = mesh.name.to_lower()
		# Скрываем объекты с названиями содержащими "wheel", "tire", "rim"
		if "wheel" in mesh_name or "tire" in mesh_name or "rim" in mesh_name or "колесо" in mesh_name:
			mesh.visible = false
			print("Nexia: Hidden wheel mesh: ", mesh.name)

func _find_all_meshes(node: Node) -> Array:
	"""Рекурсивно находит все MeshInstance3D"""
	var meshes: Array = []

	if node is MeshInstance3D:
		meshes.append(node)

	for child in node.get_children():
		meshes.append_array(_find_all_meshes(child))

	return meshes

func _change_body_color() -> void:
	"""Меняет цвет кузова на вишнёвый"""
	var meshes := _find_all_meshes(self)

	for mesh in meshes:
		if not (mesh is MeshInstance3D):
			continue

		var mesh_name: String = mesh.name.to_lower()
		print("Nexia: Found mesh: ", mesh.name)

		# Проверяем тип детали
		# Стёкла - только opaque glass (не цветное стекло фар)
		var is_glass: bool = ("glass" in mesh_name and "opaque" in mesh_name) or "window" in mesh_name or "стекло" in mesh_name
		# Фары и габариты - цветное стекло (orangeglass, redglass)
		var is_light: bool = "light" in mesh_name or "lamp" in mesh_name or "фара" in mesh_name or "orangeglass" in mesh_name or "redglass" in mesh_name
		var is_wheel: bool = "wheel" in mesh_name or "tire" in mesh_name or "rim" in mesh_name or "колесо" in mesh_name or "brakedisk" in mesh_name
		var is_chrome: bool = "chrome" in mesh_name or "mattemetal" in mesh_name or "хром" in mesh_name or "mirror" in mesh_name
		var is_interior: bool = "leather" in mesh_name or "кожа" in mesh_name

		# Пропускаем фары, габариты, хромированные детали, колёса и салон (они остаются как есть)
		if is_light or is_wheel or is_chrome or is_interior:
			print("  -> Skipping (light/wheel/chrome/interior)")
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
					print("  -> Created override material for surface ", i)

			if material:
				var mat_name := ""
				if material.resource_name:
					mat_name = material.resource_name.to_lower()
				print("  -> Material: ", material.resource_name, " (", material.get_class(), ")")

				# Проверяем материал на предмет фар/стёкол/белых элементов
				var is_light_material: bool = "light" in mat_name or "lamp" in mat_name or "фара" in mat_name or "white" in mat_name or "yellow" in mat_name or "orange" in mat_name or "red" in mat_name
				# Для стёкол - проверяем что это именно opaque glass
				if "glass" in mat_name and not "opaque" in mat_name:
					is_light_material = true

				if is_light_material:
					print("  -> Skipping light/glass material")
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
						print("  -> Changed glass to tinted (day mode)")
					else:
						# Для кузова - глянцевая краска с лаком
						material.albedo_color = body_color
						material.metallic = 0.3
						material.metallic_specular = 0.8
						material.roughness = 0.15
						material.clearcoat = 0.9
						material.clearcoat_roughness = 0.1
						print("  -> Changed body color to cherry (glossy)")
				elif material is BaseMaterial3D:
					material.albedo_color = body_color if not is_glass else glass_color_day
					if is_glass:
						material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
						print("  -> Changed glass to tinted (transparent)")
					else:
						print("  -> Changed body color to cherry")


func _setup_taillights() -> void:
	"""Находит материалы задних габаритов (redglass) и создаёт стоп-сигналы"""
	var meshes := _find_all_meshes(self)

	for mesh in meshes:
		if not (mesh is MeshInstance3D):
			continue

		var mesh_name: String = mesh.name.to_lower()

		# Ищем красное стекло задних габаритов (body_redglass_0)
		if "redglass" in mesh_name:
			print("Nexia: Found taillight mesh: ", mesh.name)
			_setup_taillight_material(mesh)

	# Создаём SpotLight3D для стоп-сигналов (направлены назад)
	# Z положительный - сзади машины (ось инвертирована)
	var brake_positions := [
		Vector3(-0.5, 0.9, 1.95),  # Левый
		Vector3(0.5, 0.9, 1.95),   # Правый
	]

	for i in range(brake_positions.size()):
		var light := SpotLight3D.new()
		light.name = "BrakeLight_%d" % i
		light.position = brake_positions[i]
		light.rotation_degrees = Vector3(0, 180, 0)  # Направлен назад (учитывая инверсию модели)
		light.spot_range = 1.5
		light.spot_angle = 150.0
		light.light_energy = 0.3  # Тусклый свет для габаритов
		light.light_color = Color(1.0, 0.0, 0.0)
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
			# Габариты всегда светятся, но тускло
			material.emission_enabled = true
			material.emission = Color(1.0, 0.1, 0.1)  # Красный
			material.emission_energy_multiplier = 0.5  # Тусклые габариты
			_taillight_materials.append(material)
			print("  -> Added taillight material")


func _setup_frontlights() -> void:
	"""Находит материалы передних габаритов (orangeglass) и включает emission"""
	var meshes := _find_all_meshes(self)

	for mesh in meshes:
		if not (mesh is MeshInstance3D):
			continue

		var mesh_name: String = mesh.name.to_lower()

		# Ищем оранжевое стекло передних габаритов (body_orangeglass_0)
		if "orangeglass" in mesh_name:
			print("Nexia: Found front marker mesh: ", mesh.name)
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
			print("  -> Added front marker material")


func _setup_headlights() -> void:
	"""Создаёт SpotLight3D для передних фар"""
	# Z отрицательный - спереди машины (ось инвертирована)
	var headlight_positions := [
		Vector3(-0.55, 0.75, -1.9),  # Левая фара
		Vector3(0.55, 0.75, -1.9),   # Правая фара
	]

	for i in range(headlight_positions.size()):
		var light := SpotLight3D.new()
		light.name = "Headlight_%d" % i
		light.position = headlight_positions[i]
		light.rotation_degrees = Vector3(0, 0, 0)  # Направлен вперёд (по -Z)
		light.spot_range = 30.0
		light.spot_angle = 45.0
		light.light_energy = 2.0
		light.light_color = Color(1.0, 0.95, 0.8)  # Тёплый белый
		light.shadow_enabled = true
		light.visible = _is_night  # Включаются только ночью

		get_parent().add_child(light)
		_headlights.append(light)
		print("  -> Created headlight SpotLight at ", headlight_positions[i])


func _update_taillight_brightness() -> void:
	"""Обновляет яркость габаритов и включает стоп-сигналы при торможении"""
	var braking := false
	if _vehicle and "brake_input" in _vehicle:
		braking = _vehicle.brake_input > 0.1

	# Emission: тусклый для габаритов, яркий при торможении
	for material in _taillight_materials:
		if is_instance_valid(material):
			material.emission_energy_multiplier = 3.0 if braking else 0.5

	# SpotLight: тусклый для габаритов, яркий при торможении
	for light in _brake_lights:
		if is_instance_valid(light):
			light.light_energy = 2.0 if braking else 0.3


func _update_headlights() -> void:
	"""Включает/выключает фары в зависимости от времени суток"""
	for light in _headlights:
		if is_instance_valid(light):
			light.visible = _is_night
