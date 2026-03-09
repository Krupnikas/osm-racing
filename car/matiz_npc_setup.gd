extends Node3D

## Скрипт для настройки модели Daewoo Matiz (NPC версия)
## Рандомизирует цвет кузова, НЕ скрывает колёса
## Фары настраиваются через npc_car_lights.gd

# Типичные цвета Daewoo Matiz
const MATIZ_COLORS := [
	Color(0.95, 0.85, 0.15),  # Жёлтый (такси-классика)
	Color(0.95, 0.85, 0.15),  # Жёлтый (дублируем — самый популярный)
	Color(0.10, 0.55, 0.25),  # Зелёный «Lime»
	Color(0.0, 0.35, 0.65),   # Синий «Ocean Blue»
	Color(0.55, 0.0, 0.15),   # Вишнёвый «Wine Red»
	Color(0.96, 0.96, 0.96),  # Белый
	Color(0.72, 0.74, 0.74),  # Серебристый
	Color(0.75, 0.30, 0.0),   # Оранжевый
	Color(0.60, 0.75, 0.85),  # Голубой «Light Blue»
	Color(0.45, 0.15, 0.40),  # Фиолетовый «Plum»
]

var body_color := Color(0.95, 0.85, 0.15, 1.0)


func _ready() -> void:
	body_color = MATIZ_COLORS[randi() % MATIZ_COLORS.size()]

	await get_tree().process_frame

	_change_body_color()


func _find_all_meshes(node: Node) -> Array:
	var meshes: Array = []
	if node is MeshInstance3D:
		meshes.append(node)
	for child in node.get_children():
		meshes.append_array(_find_all_meshes(child))
	return meshes


func _change_body_color() -> void:
	var meshes := _find_all_meshes(self)

	for mesh in meshes:
		if not (mesh is MeshInstance3D):
			continue

		var mesh_name: String = mesh.name.to_lower()

		var is_wheel: bool = "wheel" in mesh_name or "tire" in mesh_name or "rim" in mesh_name or "brakedisk" in mesh_name or "brake" in mesh_name
		var is_chrome: bool = "chrome" in mesh_name
		var is_interior: bool = "leather" in mesh_name or "interior" in mesh_name or "carbon" in mesh_name or "plastic_dark" in mesh_name
		var is_light: bool = "light" in mesh_name or "lamp" in mesh_name or "turn" in mesh_name or "signal" in mesh_name

		if is_wheel or is_chrome or is_interior or is_light:
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

			if not material:
				continue

			var mat_name := ""
			if material.resource_name:
				mat_name = material.resource_name.to_lower()

			var is_light_mat: bool = "light" in mat_name or "lamp" in mat_name or "turn" in mat_name or "signal" in mat_name or "brake" in mat_name or "rear" in mat_name
			var is_glass_mat: bool = "windshield" in mat_name or "glass" in mat_name
			var is_paint: bool = "car_paint" in mat_name or "paint" in mat_name

			if is_light_mat or is_glass_mat:
				continue

			if material is StandardMaterial3D and is_paint:
				material.albedo_color = body_color
				material.metallic = 0.3
				material.metallic_specular = 0.8
				material.roughness = 0.15
				material.clearcoat = 0.9
				material.clearcoat_roughness = 0.1
