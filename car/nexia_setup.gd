extends Node3D

## Скрипт для настройки модели Daewoo Nexia
## Скрывает колёса из модели, так как используются VehicleWheel3D
## Изменяет цвет кузова

# Цвет кузова (спелая вишня - код 74U "Красный шпинель")
# RGB: 89, 0, 6 -> нормализованные значения для Godot (делим на 255)
var body_color := Color(0.349, 0.0, 0.024, 1.0)  # #590006

# Цвет тонировки стёкол (слегка затемнённое, прозрачное, блестящее)
var glass_color := Color(0.15, 0.15, 0.17, 0.3)  # Лёгкая тонировка (полупрозрачная)

func _ready() -> void:
	await get_tree().process_frame

	# Не скрываем колёса модели - они нужны для визуала
	# VehicleWheel3D используются только для физики
	# _hide_model_wheels()

	# Меняем цвет кузова
	_change_body_color()

	print("Nexia model setup complete")

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

				# Выбираем цвет в зависимости от типа детали
				var target_color: Color = glass_color if is_glass else body_color

				if material is StandardMaterial3D:
					material.albedo_color = target_color
					if is_glass:
						# Для стёкол делаем прозрачными с сильным блеском
						material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
						material.metallic = 0.8  # Высокая металличность для блеска
						material.roughness = 0.05  # Минимальная шероховатость для зеркального эффекта
						material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
						material.cull_mode = BaseMaterial3D.CULL_DISABLED  # Рендерим с обеих сторон
						print("  -> Changed glass to tinted (transparent, shiny)")
					else:
						print("  -> Changed body color to cherry")
				elif material is BaseMaterial3D:
					material.albedo_color = target_color
					if is_glass:
						material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
						print("  -> Changed glass to tinted (transparent)")
					else:
						print("  -> Changed body color to cherry")
