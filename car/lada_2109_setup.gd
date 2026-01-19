extends Node3D

## Скрипт для настройки модели Lada 2109 DPS
## Настраивает цвета и параметры полицейского автомобиля

# Цвет кузова (белый с синим для ДПС)
var body_color := Color(0.9, 0.9, 0.9, 1.0)  # Белый
var stripe_color := Color(0.1, 0.3, 0.8, 1.0)  # Синий для полосы

func _ready() -> void:
	await get_tree().process_frame

	# Выводим все mesh'и в модели для отладки
	_debug_print_meshes()

	# Применяем цветовую схему ДПС
	_apply_dps_colors()

	print("Lada 2109 DPS model setup complete")


func _apply_dps_colors() -> void:
	"""Применяет цветовую схему ДПС к модели"""
	var meshes := _find_all_meshes(self)

	for mesh_instance in meshes:
		var mesh_name: String = mesh_instance.name.to_lower()

		# Кузов - белый цвет
		if "carbody" in mesh_name or "body" in mesh_name:
			_apply_color_to_mesh(mesh_instance, body_color)
			print("  Applied DPS white to: ", mesh_instance.name)

		# Мигалка/фонарь уже должна быть в модели
		elif "flashlight" in mesh_name or "light" in mesh_name:
			print("  Found flashlight: ", mesh_instance.name, " (keeping original)")

		# Зеркала - оставляем как есть
		elif "mirror" in mesh_name:
			print("  Found mirror: ", mesh_instance.name, " (keeping original)")

		# Колёса - оставляем как есть
		elif "wheel" in mesh_name or "whell" in mesh_name:
			print("  Found wheel: ", mesh_instance.name, " (keeping original)")


func _apply_color_to_mesh(mesh_instance: MeshInstance3D, color: Color) -> void:
	"""Применяет цвет к mesh instance"""
	var mesh := mesh_instance.mesh
	if not mesh:
		return

	# Проходим по всем поверхностям mesh'а
	for i in range(mesh.get_surface_count()):
		var mat := mesh.surface_get_material(i)
		if mat:
			# Создаём копию материала чтобы не затронуть другие mesh'и
			var new_mat: StandardMaterial3D
			if mat is StandardMaterial3D:
				new_mat = mat.duplicate()
			else:
				new_mat = StandardMaterial3D.new()

			# Применяем цвет
			new_mat.albedo_color = color

			# Сохраняем металличность и шероховатость если были
			if mat is StandardMaterial3D:
				new_mat.metallic = mat.metallic
				new_mat.roughness = mat.roughness

			# Устанавливаем новый материал
			mesh_instance.set_surface_override_material(i, new_mat)


func _debug_print_meshes() -> void:
	"""Выводит все mesh'и в модели для отладки"""
	print("=== Lada 2109 DPS Model Meshes Debug ===")
	var meshes := _find_all_meshes(self)
	print("Total meshes found: ", meshes.size())
	for mesh in meshes:
		print("  - Mesh: ", mesh.name, " (", mesh.get_class(), ")")
		if mesh is MeshInstance3D and mesh.mesh:
			print("    Surfaces: ", mesh.mesh.get_surface_count())


func _find_all_meshes(node: Node) -> Array:
	"""Рекурсивно находит все MeshInstance3D"""
	var meshes: Array = []

	if node is MeshInstance3D:
		meshes.append(node)

	for child in node.get_children():
		meshes.append_array(_find_all_meshes(child))

	return meshes
