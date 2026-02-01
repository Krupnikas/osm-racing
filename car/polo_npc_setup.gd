extends Node3D

## Скрипт для настройки модели VW Polo Sedan (NPC версия)
## Рандомизирует цвет кузова, НЕ скрывает колёса
## Фары настраиваются через npc_car_lights.gd

# Официальные цвета VW Polo Sedan 2020 (Россия)
const POLO_COLORS := [
	Color(0.96, 0.96, 0.96),  # Белый «Pure» (Pure White)
	Color(0.74, 0.76, 0.76),  # Серебристый «Reflex» (Reflex Silver)
	Color(0.48, 0.48, 0.48),  # Серый «Tungsten» (Tungsten Silver)
	Color(0.31, 0.32, 0.33),  # Серый «Indium» (Indium Grey)
	Color(0.055, 0.055, 0.063), # Черный «Deep» (Deep Black)
	Color(0.0, 0.28, 0.49),   # Синий «Reef» (Reef Blue)
	Color(0.11, 0.16, 0.25),  # Тёмно-синий «Starlight» (Starlight Blue)
	Color(0.58, 0.54, 0.48),  # Бежевый «Cappuccino» (Cappuccino Beige)
	Color(0.64, 0.29, 0.15),  # Оранжевый «Copper» (Copper Orange)
]

var body_color := Color(0.75, 0.75, 0.8, 1.0)


func _ready() -> void:
	# Выбираем случайный цвет
	body_color = POLO_COLORS[randi() % POLO_COLORS.size()]

	await get_tree().process_frame

	# Меняем цвет кузова
	_change_body_color()


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

		# Пропускаем стёкла, фары, колёса, хром, салон
		var is_glass: bool = "glass" in mesh_name and not "lightglass" in mesh_name
		var is_light: bool = "light" in mesh_name or "stop" in mesh_name or "gabarit" in mesh_name or "fog" in mesh_name or "head" in mesh_name or "run" in mesh_name or "long" in mesh_name or "_red" in mesh_name or "reve" in mesh_name
		var is_wheel: bool = "wheel" in mesh_name or "tire" in mesh_name
		var is_chrome: bool = "chrome" in mesh_name or "mirror" in mesh_name
		var is_interior: bool = "salon" in mesh_name or "seats" in mesh_name or "dash" in mesh_name or "pribor" in mesh_name or "gauges" in mesh_name or "clock" in mesh_name or "kover" in mesh_name
		var is_body: bool = "body" in mesh_name or "roof" in mesh_name

		if is_glass or is_light or is_wheel or is_chrome or is_interior:
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

			# Применяем цвет только к кузовным деталям (body/roof)
			if material and (material is StandardMaterial3D or material is BaseMaterial3D) and is_body:
				material.albedo_texture = null
				material.albedo_color = body_color
				material.metallic = 0.3
				material.metallic_specular = 0.8
				material.roughness = 0.15
