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

# Кэш shared материалов (создаются один раз)
static var _concrete_material: StandardMaterial3D
static var _glass_material: StandardMaterial3D
static var _frame_material: StandardMaterial3D
static var _metal_material: StandardMaterial3D


## Создаёт входную группу как один MeshInstance3D с 4 surfaces (4 draw calls вместо ~15)
static func create_entrance_group(door_count: int = 2) -> MeshInstance3D:
	_ensure_materials()

	var total_door_width := door_count * DOOR_WIDTH + (door_count - 1) * DOOR_GAP
	var platform_height := STEP_COUNT * STEP_HEIGHT

	# 4 набора геометрии по типу материала
	var concrete_verts := PackedVector3Array()
	var concrete_norms := PackedVector3Array()
	var concrete_idx := PackedInt32Array()

	var glass_verts := PackedVector3Array()
	var glass_norms := PackedVector3Array()
	var glass_idx := PackedInt32Array()

	var frame_verts := PackedVector3Array()
	var frame_norms := PackedVector3Array()
	var frame_idx := PackedInt32Array()

	var metal_verts := PackedVector3Array()
	var metal_norms := PackedVector3Array()
	var metal_idx := PackedInt32Array()

	# === CONCRETE: площадка + ступени ===
	var step_width := total_door_width + 0.6

	# Площадка
	_add_box(concrete_verts, concrete_norms, concrete_idx,
		Vector3(0, platform_height / 2.0, PLATFORM_DEPTH / 2.0),
		Vector3(step_width, platform_height, PLATFORM_DEPTH))

	# Ступени
	for i in range(STEP_COUNT):
		var step_y := (STEP_COUNT - 1 - i) * STEP_HEIGHT
		var step_z := PLATFORM_DEPTH + i * STEP_DEPTH
		_add_box(concrete_verts, concrete_norms, concrete_idx,
			Vector3(0, step_y + STEP_HEIGHT / 2.0, step_z + STEP_DEPTH / 2.0),
			Vector3(step_width, STEP_HEIGHT, STEP_DEPTH))

	# === GLASS: стёкла дверей ===
	var start_x := -total_door_width / 2.0 + DOOR_WIDTH / 2.0
	for i in range(door_count):
		var door_x := start_x + i * (DOOR_WIDTH + DOOR_GAP)
		_add_quad(glass_verts, glass_norms, glass_idx,
			Vector3(door_x, platform_height + DOOR_HEIGHT / 2.0, FRAME_THICKNESS / 2.0),
			Vector2(DOOR_WIDTH - FRAME_WIDTH * 2, DOOR_HEIGHT - FRAME_WIDTH * 2))

	# === FRAME: рамы дверей ===
	for i in range(door_count):
		var door_x := start_x + i * (DOOR_WIDTH + DOOR_GAP)
		# Вертикальные планки
		for side in [-1, 1]:
			_add_box(frame_verts, frame_norms, frame_idx,
				Vector3(door_x + side * (DOOR_WIDTH / 2.0 - FRAME_WIDTH / 2.0),
					platform_height + DOOR_HEIGHT / 2.0, FRAME_THICKNESS / 2.0),
				Vector3(FRAME_WIDTH, DOOR_HEIGHT, FRAME_THICKNESS))
		# Горизонтальные планки
		_add_box(frame_verts, frame_norms, frame_idx,
			Vector3(door_x, platform_height + FRAME_WIDTH / 2.0, FRAME_THICKNESS / 2.0),
			Vector3(DOOR_WIDTH, FRAME_WIDTH, FRAME_THICKNESS))
		_add_box(frame_verts, frame_norms, frame_idx,
			Vector3(door_x, platform_height + DOOR_HEIGHT - FRAME_WIDTH / 2.0, FRAME_THICKNESS / 2.0),
			Vector3(DOOR_WIDTH, FRAME_WIDTH, FRAME_THICKNESS))

	# === METAL: козырёк ===
	var canopy_width := total_door_width + CANOPY_OVERHANG * 2
	_add_box(metal_verts, metal_norms, metal_idx,
		Vector3(0, platform_height + DOOR_HEIGHT + CANOPY_HEIGHT / 2.0, CANOPY_DEPTH / 2.0 - 0.1),
		Vector3(canopy_width, CANOPY_HEIGHT, CANOPY_DEPTH))

	# Собираем ArrayMesh с 4 surfaces
	var arr_mesh := ArrayMesh.new()

	if concrete_verts.size() > 0:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = concrete_verts
		arrays[Mesh.ARRAY_NORMAL] = concrete_norms
		arrays[Mesh.ARRAY_INDEX] = concrete_idx
		arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		arr_mesh.surface_set_material(arr_mesh.get_surface_count() - 1, _concrete_material)

	if glass_verts.size() > 0:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = glass_verts
		arrays[Mesh.ARRAY_NORMAL] = glass_norms
		arrays[Mesh.ARRAY_INDEX] = glass_idx
		arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		arr_mesh.surface_set_material(arr_mesh.get_surface_count() - 1, _glass_material)

	if frame_verts.size() > 0:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = frame_verts
		arrays[Mesh.ARRAY_NORMAL] = frame_norms
		arrays[Mesh.ARRAY_INDEX] = frame_idx
		arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		arr_mesh.surface_set_material(arr_mesh.get_surface_count() - 1, _frame_material)

	if metal_verts.size() > 0:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = metal_verts
		arrays[Mesh.ARRAY_NORMAL] = metal_norms
		arrays[Mesh.ARRAY_INDEX] = metal_idx
		arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		arr_mesh.surface_set_material(arr_mesh.get_surface_count() - 1, _metal_material)

	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = arr_mesh
	mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh_inst.name = "EntranceGroup"
	return mesh_inst


static func _ensure_materials() -> void:
	if _concrete_material == null:
		_concrete_material = StandardMaterial3D.new()
		_concrete_material.albedo_color = CONCRETE_COLOR
		_concrete_material.roughness = 0.9
		_concrete_material.cull_mode = BaseMaterial3D.CULL_DISABLED

	if _glass_material == null:
		_glass_material = StandardMaterial3D.new()
		_glass_material.albedo_color = GLASS_COLOR
		_glass_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_glass_material.metallic = 0.1
		_glass_material.roughness = 0.1
		_glass_material.cull_mode = BaseMaterial3D.CULL_DISABLED

	if _frame_material == null:
		_frame_material = StandardMaterial3D.new()
		_frame_material.albedo_color = FRAME_COLOR
		_frame_material.metallic = 0.6
		_frame_material.roughness = 0.3
		_frame_material.cull_mode = BaseMaterial3D.CULL_DISABLED

	if _metal_material == null:
		_metal_material = StandardMaterial3D.new()
		_metal_material.albedo_color = METAL_COLOR
		_metal_material.metallic = 0.7
		_metal_material.roughness = 0.4
		_metal_material.cull_mode = BaseMaterial3D.CULL_DISABLED


## Добавляет Box геометрию (6 граней) в буферы
static func _add_box(verts: PackedVector3Array, norms: PackedVector3Array, idx: PackedInt32Array,
		center: Vector3, size: Vector3) -> void:
	var hx := size.x * 0.5
	var hy := size.y * 0.5
	var hz := size.z * 0.5
	var base := verts.size()

	# 6 граней × 4 вершины = 24 вершины, 6 × 2 = 12 треугольников
	# Front (+Z)
	verts.append(center + Vector3(-hx, -hy, hz))
	verts.append(center + Vector3(hx, -hy, hz))
	verts.append(center + Vector3(hx, hy, hz))
	verts.append(center + Vector3(-hx, hy, hz))
	for _i in range(4): norms.append(Vector3(0, 0, 1))
	idx.append_array([base, base+1, base+2, base, base+2, base+3])

	# Back (-Z)
	var b := base + 4
	verts.append(center + Vector3(hx, -hy, -hz))
	verts.append(center + Vector3(-hx, -hy, -hz))
	verts.append(center + Vector3(-hx, hy, -hz))
	verts.append(center + Vector3(hx, hy, -hz))
	for _i in range(4): norms.append(Vector3(0, 0, -1))
	idx.append_array([b, b+1, b+2, b, b+2, b+3])

	# Top (+Y)
	b = base + 8
	verts.append(center + Vector3(-hx, hy, -hz))
	verts.append(center + Vector3(-hx, hy, hz))
	verts.append(center + Vector3(hx, hy, hz))
	verts.append(center + Vector3(hx, hy, -hz))
	for _i in range(4): norms.append(Vector3(0, 1, 0))
	idx.append_array([b, b+1, b+2, b, b+2, b+3])

	# Bottom (-Y)
	b = base + 12
	verts.append(center + Vector3(-hx, -hy, hz))
	verts.append(center + Vector3(-hx, -hy, -hz))
	verts.append(center + Vector3(hx, -hy, -hz))
	verts.append(center + Vector3(hx, -hy, hz))
	for _i in range(4): norms.append(Vector3(0, -1, 0))
	idx.append_array([b, b+1, b+2, b, b+2, b+3])

	# Right (+X)
	b = base + 16
	verts.append(center + Vector3(hx, -hy, hz))
	verts.append(center + Vector3(hx, -hy, -hz))
	verts.append(center + Vector3(hx, hy, -hz))
	verts.append(center + Vector3(hx, hy, hz))
	for _i in range(4): norms.append(Vector3(1, 0, 0))
	idx.append_array([b, b+1, b+2, b, b+2, b+3])

	# Left (-X)
	b = base + 20
	verts.append(center + Vector3(-hx, -hy, -hz))
	verts.append(center + Vector3(-hx, -hy, hz))
	verts.append(center + Vector3(-hx, hy, hz))
	verts.append(center + Vector3(-hx, hy, -hz))
	for _i in range(4): norms.append(Vector3(-1, 0, 0))
	idx.append_array([b, b+1, b+2, b, b+2, b+3])


## Добавляет Quad геометрию (2 треугольника) в буферы
static func _add_quad(verts: PackedVector3Array, norms: PackedVector3Array, idx: PackedInt32Array,
		center: Vector3, size: Vector2) -> void:
	var hx := size.x * 0.5
	var hy := size.y * 0.5
	var base := verts.size()

	verts.append(center + Vector3(-hx, -hy, 0))
	verts.append(center + Vector3(hx, -hy, 0))
	verts.append(center + Vector3(hx, hy, 0))
	verts.append(center + Vector3(-hx, hy, 0))
	for _i in range(4): norms.append(Vector3(0, 0, 1))
	idx.append_array([base, base+1, base+2, base, base+2, base+3])


# Вспомогательные функции для интеграции
static func get_total_height() -> float:
	return STEP_COUNT * STEP_HEIGHT + DOOR_HEIGHT + CANOPY_HEIGHT


static func get_canopy_top_height() -> float:
	return STEP_COUNT * STEP_HEIGHT + DOOR_HEIGHT + CANOPY_HEIGHT


static func get_canopy_width(door_count: int = 2) -> float:
	var total_door_width = door_count * DOOR_WIDTH + (door_count - 1) * DOOR_GAP
	return total_door_width + CANOPY_OVERHANG * 2
