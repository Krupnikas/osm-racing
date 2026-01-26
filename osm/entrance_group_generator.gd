class_name EntranceGroupGenerator
extends RefCounted

# Размеры входной группы (в метрах)
const DOOR_WIDTH := 0.9          # ширина одной двери
const DOOR_HEIGHT := 2.2         # высота двери
const DOOR_GAP := 0.1            # зазор между дверьми
const FRAME_THICKNESS := 0.05    # толщина рамы двери
const FRAME_WIDTH := 0.08        # ширина профиля рамы

const CANOPY_DEPTH := 1.2        # глубина козырька (выступ от стены)
const CANOPY_HEIGHT := 0.08      # толщина козырька
const CANOPY_OVERHANG := 0.3     # выступ козырька по бокам от дверей

const STEP_HEIGHT := 0.15        # высота одной ступени
const STEP_DEPTH := 0.3          # глубина ступени
const STEP_COUNT := 3            # количество ступеней
const PLATFORM_DEPTH := 1.0      # глубина площадки перед дверью

# Материалы (цвета)
const METAL_COLOR := Color(0.25, 0.25, 0.28)       # тёмно-серый металл
const GLASS_COLOR := Color(0.3, 0.4, 0.5, 0.6)    # полупрозрачное стекло
const CONCRETE_COLOR := Color(0.55, 0.53, 0.50)   # бетон/камень
const FRAME_COLOR := Color(0.12, 0.12, 0.15)      # тёмная рама

# Кэш материалов
static var _metal_material: StandardMaterial3D
static var _glass_material: StandardMaterial3D
static var _concrete_material: StandardMaterial3D
static var _frame_material: StandardMaterial3D


static func create_entrance_group(door_count: int = 2) -> Node3D:
	var root = Node3D.new()
	root.name = "EntranceGroup"

	_ensure_materials()

	# Рассчитываем общую ширину
	var total_door_width = door_count * DOOR_WIDTH + (door_count - 1) * DOOR_GAP

	# 1. Ступени и площадка
	_add_steps(root, total_door_width)

	# 2. Двери с рамами
	_add_doors(root, door_count, total_door_width)

	# 3. Козырёк
	_add_canopy(root, total_door_width)

	return root


static func _ensure_materials() -> void:
	if _metal_material == null:
		_metal_material = StandardMaterial3D.new()
		_metal_material.albedo_color = METAL_COLOR
		_metal_material.metallic = 0.7
		_metal_material.roughness = 0.4
		_metal_material.cull_mode = BaseMaterial3D.CULL_BACK  # Оптимизация: металл не прозрачный

	if _glass_material == null:
		_glass_material = StandardMaterial3D.new()
		_glass_material.albedo_color = GLASS_COLOR
		_glass_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_glass_material.metallic = 0.1
		_glass_material.roughness = 0.1
		_glass_material.cull_mode = BaseMaterial3D.CULL_DISABLED

	if _concrete_material == null:
		_concrete_material = StandardMaterial3D.new()
		_concrete_material.albedo_color = CONCRETE_COLOR
		_concrete_material.roughness = 0.9
		_concrete_material.cull_mode = BaseMaterial3D.CULL_BACK  # Оптимизация: бетон не прозрачный

	if _frame_material == null:
		_frame_material = StandardMaterial3D.new()
		_frame_material.albedo_color = FRAME_COLOR
		_frame_material.metallic = 0.6
		_frame_material.roughness = 0.3
		_frame_material.cull_mode = BaseMaterial3D.CULL_BACK  # Оптимизация: рама не прозрачная


static func _add_steps(root: Node3D, total_door_width: float) -> void:
	# Ширина ступеней = ширина дверей + отступы
	var step_width = total_door_width + 0.6

	# Высота площадки = количество ступеней * высота ступени
	var platform_height = STEP_COUNT * STEP_HEIGHT

	# Площадка перед дверью
	var platform_mesh = BoxMesh.new()
	platform_mesh.size = Vector3(step_width, platform_height, PLATFORM_DEPTH)

	var platform = MeshInstance3D.new()
	platform.mesh = platform_mesh
	platform.material_override = _concrete_material
	platform.name = "Platform"
	# Позиция: центр площадки
	platform.position = Vector3(0, platform_height / 2.0, PLATFORM_DEPTH / 2.0)
	root.add_child(platform)

	# Ступени (выступающие части)
	for i in range(STEP_COUNT):
		var step_y = (STEP_COUNT - 1 - i) * STEP_HEIGHT  # от верхней к нижней
		var step_z = PLATFORM_DEPTH + i * STEP_DEPTH      # каждая следующая дальше

		var step_mesh = BoxMesh.new()
		step_mesh.size = Vector3(step_width, STEP_HEIGHT, STEP_DEPTH)

		var step = MeshInstance3D.new()
		step.mesh = step_mesh
		step.material_override = _concrete_material
		step.name = "Step_%d" % i
		step.position = Vector3(0, step_y + STEP_HEIGHT / 2.0, step_z + STEP_DEPTH / 2.0)
		root.add_child(step)


static func _add_doors(root: Node3D, door_count: int, total_door_width: float) -> void:
	var platform_height = STEP_COUNT * STEP_HEIGHT

	# Стартовая позиция X для первой двери (центрирование)
	var start_x = -total_door_width / 2.0 + DOOR_WIDTH / 2.0

	for i in range(door_count):
		var door_x = start_x + i * (DOOR_WIDTH + DOOR_GAP)

		# Стекло двери
		var glass_mesh = QuadMesh.new()
		glass_mesh.size = Vector2(DOOR_WIDTH - FRAME_WIDTH * 2, DOOR_HEIGHT - FRAME_WIDTH * 2)

		var glass = MeshInstance3D.new()
		glass.mesh = glass_mesh
		glass.material_override = _glass_material
		glass.name = "DoorGlass_%d" % i
		glass.position = Vector3(door_x, platform_height + DOOR_HEIGHT / 2.0, FRAME_THICKNESS / 2.0)
		root.add_child(glass)

		# Рама двери (4 планки)
		_add_door_frame(root, door_x, platform_height, i)


static func _add_door_frame(root: Node3D, door_x: float, base_y: float, door_index: int) -> void:
	# Вертикальные планки (левая и правая)
	for side in [-1, 1]:
		var frame_mesh = BoxMesh.new()
		frame_mesh.size = Vector3(FRAME_WIDTH, DOOR_HEIGHT, FRAME_THICKNESS)

		var frame = MeshInstance3D.new()
		frame.mesh = frame_mesh
		frame.material_override = _frame_material
		frame.name = "DoorFrameV_%d_%d" % [door_index, side]
		frame.position = Vector3(
			door_x + side * (DOOR_WIDTH / 2.0 - FRAME_WIDTH / 2.0),
			base_y + DOOR_HEIGHT / 2.0,
			FRAME_THICKNESS / 2.0
		)
		root.add_child(frame)

	# Горизонтальные планки (верхняя и нижняя)
	for is_top in [false, true]:
		var frame_mesh = BoxMesh.new()
		frame_mesh.size = Vector3(DOOR_WIDTH, FRAME_WIDTH, FRAME_THICKNESS)

		var frame = MeshInstance3D.new()
		frame.mesh = frame_mesh
		frame.material_override = _frame_material
		frame.name = "DoorFrameH_%d_%s" % [door_index, "top" if is_top else "bottom"]

		var y_pos = base_y + FRAME_WIDTH / 2.0
		if is_top:
			y_pos = base_y + DOOR_HEIGHT - FRAME_WIDTH / 2.0

		frame.position = Vector3(door_x, y_pos, FRAME_THICKNESS / 2.0)
		root.add_child(frame)


static func _add_canopy(root: Node3D, total_door_width: float) -> void:
	var platform_height = STEP_COUNT * STEP_HEIGHT
	var canopy_width = total_door_width + CANOPY_OVERHANG * 2

	# Основная плита козырька
	var canopy_mesh = BoxMesh.new()
	canopy_mesh.size = Vector3(canopy_width, CANOPY_HEIGHT, CANOPY_DEPTH)

	var canopy = MeshInstance3D.new()
	canopy.mesh = canopy_mesh
	canopy.material_override = _metal_material
	canopy.name = "Canopy"

	# Позиция: над дверью, с выступом вперёд
	canopy.position = Vector3(
		0,
		platform_height + DOOR_HEIGHT + CANOPY_HEIGHT / 2.0,
		CANOPY_DEPTH / 2.0 - 0.1  # немного ближе к стене
	)

	# Небольшой наклон вперёд (3 градуса) для стока воды
	canopy.rotation.x = deg_to_rad(3)

	root.add_child(canopy)


# Вспомогательные функции для интеграции
static func get_total_height() -> float:
	return STEP_COUNT * STEP_HEIGHT + DOOR_HEIGHT + CANOPY_HEIGHT


static func get_canopy_top_height() -> float:
	return STEP_COUNT * STEP_HEIGHT + DOOR_HEIGHT + CANOPY_HEIGHT


static func get_canopy_width(door_count: int = 2) -> float:
	var total_door_width = door_count * DOOR_WIDTH + (door_count - 1) * DOOR_GAP
	return total_door_width + CANOPY_OVERHANG * 2
