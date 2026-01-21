extends Node3D

## Скрипт для настройки модели ВАЗ-2107
## Рандомизирует цвет кузова для NPC

# Классические цвета ВАЗ-2107
const VAZ_COLORS := [
	Color(0.5, 0.1, 0.15),   # Вишнёвый
	Color(0.1, 0.2, 0.5),    # Синий "Балтика"
	Color(0.9, 0.9, 0.85),   # Белый
	Color(0.1, 0.1, 0.1),    # Чёрный
	Color(0.2, 0.4, 0.2),    # Зелёный "Липа"
	Color(0.6, 0.55, 0.45),  # Бежевый "Сафари"
	Color(0.4, 0.4, 0.45),   # Серый "Мокрый асфальт"
	Color(0.55, 0.25, 0.1),  # Коричневый "Корица"
	Color(0.7, 0.15, 0.1),   # Красный
	Color(0.15, 0.35, 0.45), # Морская волна
]

var body_color := Color(0.5, 0.1, 0.15, 1.0)

func _ready() -> void:
	# Выбираем случайный цвет
	body_color = VAZ_COLORS[randi() % VAZ_COLORS.size()]

	await get_tree().process_frame

	# Меняем цвет кузова
	_change_body_color()

	print("VAZ-2107 setup complete, color: ", body_color)


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

		# Пропускаем стёкла, фары и колёса
		var is_glass: bool = "glass" in mesh_name or "window" in mesh_name or "стекло" in mesh_name
		var is_light: bool = "light" in mesh_name or "lamp" in mesh_name or "фара" in mesh_name
		var is_wheel: bool = "wheel" in mesh_name or "tire" in mesh_name or "rim" in mesh_name or "колесо" in mesh_name
		var is_chrome: bool = "chrome" in mesh_name or "bumper" in mesh_name or "бампер" in mesh_name

		if is_glass or is_light or is_wheel or is_chrome:
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
				if material is StandardMaterial3D or material is BaseMaterial3D:
					material.albedo_color = body_color
