extends Node3D

## Скрипт для настройки модели ПАЗ-32053
## Настраивает цвета и параметры автобуса

# Цвет кузова автобуса (жёлто-оранжевый, типичный для ПАЗ)
var body_color := Color(0.95, 0.7, 0.1, 1.0)  # Жёлто-оранжевый

func _ready() -> void:
	await get_tree().process_frame

	# Выводим все mesh'и в модели для отладки
	_debug_print_meshes()

	# ВРЕМЕННО ОТКЛЮЧЕНО: процедурные колёса не нужны, в модели они есть
	# _create_visual_wheels()

	print("PAZ-32053 model setup complete")

func _create_visual_wheels() -> void:
	"""Создаёт визуальные mesh'и колёс для ПАЗа"""
	# Получаем родительскую VehicleBody3D
	var vehicle := get_parent() as VehicleBody3D
	if not vehicle:
		push_error("PAZ setup: Parent is not VehicleBody3D")
		return

	# Находим все VehicleWheel3D
	var wheels := []
	for child in vehicle.get_children():
		if child is VehicleWheel3D:
			wheels.append(child)

	print("PAZ setup: Found ", wheels.size(), " wheel nodes")

	# Создаём визуальные mesh'и для каждого колеса
	for wheel in wheels:
		var wheel_visual := MeshInstance3D.new()
		var cylinder := CylinderMesh.new()

		# Размеры колеса автобуса (радиус 0.55)
		cylinder.top_radius = 0.55
		cylinder.bottom_radius = 0.55
		cylinder.height = 0.25  # Ширина колеса
		cylinder.radial_segments = 16

		wheel_visual.mesh = cylinder

		# Материал колеса (чёрная резина)
		var tire_mat := StandardMaterial3D.new()
		tire_mat.albedo_color = Color(0.1, 0.1, 0.1, 1.0)
		tire_mat.roughness = 0.9
		tire_mat.metallic = 0.0
		wheel_visual.material_override = tire_mat

		# Поворачиваем цилиндр на 90° чтобы он был как колесо (по оси Z)
		wheel_visual.rotation_degrees = Vector3(0, 0, 90)

		# Добавляем как дочерний узел к VehicleWheel3D
		wheel.add_child(wheel_visual)

		print("PAZ setup: Added visual wheel to ", wheel.name)

func _debug_print_meshes() -> void:
	"""Выводит все mesh'и в модели для отладки"""
	print("=== PAZ Model Meshes Debug ===")
	var meshes := _find_all_meshes(self)
	print("Total meshes found: ", meshes.size())
	for mesh in meshes:
		print("  - Mesh: ", mesh.name, " (", mesh.get_class(), ")")

func _find_all_meshes(node: Node) -> Array:
	"""Рекурсивно находит все MeshInstance3D"""
	var meshes: Array = []

	if node is MeshInstance3D:
		meshes.append(node)

	for child in node.get_children():
		meshes.append_array(_find_all_meshes(child))

	return meshes
