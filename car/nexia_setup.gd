extends Node3D

## Скрипт для настройки модели Daewoo Nexia
## Скрывает колёса из модели, так как используются VehicleWheel3D
## Изменяет цвет кузова

# Цвет кузова (спелая вишня - код 74U "Красный шпинель")
# RGB: 89, 0, 6 -> нормализованные значения для Godot (делим на 255)
var body_color := Color(0.349, 0.0, 0.024, 1.0)  # #590006

# Цвет тонировки стёкол (тёмно-серый, почти непрозрачный)
var glass_color := Color(0.1, 0.1, 0.12, 1.0)  # Тёмная тонировка (непрозрачная)

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
		var is_glass: bool = "glass" in mesh_name or "window" in mesh_name or "стекло" in mesh_name
		var is_light: bool = "light" in mesh_name or "lamp" in mesh_name or "фара" in mesh_name
		var is_wheel: bool = "wheel" in mesh_name or "tire" in mesh_name or "rim" in mesh_name

		# Пропускаем фары и колёса (они остаются как есть)
		if is_light or is_wheel:
			print("  -> Skipping (light/wheel)")
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
				print("  -> Material type: ", material.get_class())

				# Выбираем цвет в зависимости от типа детали
				var target_color: Color = glass_color if is_glass else body_color

				if material is StandardMaterial3D:
					material.albedo_color = target_color
					if is_glass:
						# Для стёкол делаем тёмными но непрозрачными
						material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
						material.metallic = 0.3
						material.roughness = 0.2
						print("  -> Changed glass to tinted (dark)")
					else:
						print("  -> Changed body color to cherry")
				elif material is BaseMaterial3D:
					material.albedo_color = target_color
					if is_glass:
						material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
						print("  -> Changed glass to tinted (dark)")
					else:
						print("  -> Changed body color to cherry")
