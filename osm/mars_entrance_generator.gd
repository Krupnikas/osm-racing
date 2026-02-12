class_name MarsEntranceGenerator
extends RefCounted

## Генератор входной группы мини-рынка МАРС
## Возвращает сырую геометрию по паттерну ResidentialEntranceGenerator.

# === Размеры (метры) ===
const WALL_WIDTH := 6.0
const WALL_HEIGHT := 6.2       # ~40% от 15м здания (2 этажа) +0.2
const WALL_DEPTH := 0.1

const STEP_HEIGHT := 0.15
const STEP_DEPTH := 0.35
const STEP_COUNT := 5
const STEP_WIDTH := 6.0
const PLATFORM_DEPTH := 1.5
const PLATFORM_HEIGHT := 0.75  # = STEP_COUNT * STEP_HEIGHT

const SIDE_RAILING_WIDTH := 0.3
const SIDE_RAILING_HEIGHT := 0.9
const SIDE_RAILING_DEPTH := 0.3

const CENTER_RAILING_THICKNESS := 0.04
const CENTER_RAILING_HEIGHT := 0.9

const DOOR_WIDTH := 0.9
const DOOR_HEIGHT := 2.2
const DOOR_GAP := 0.15         # Зазор между дверями в паре
const DOOR_SET_GAP := 1.5      # Расстояние между двумя парами дверей

const CANOPY_WIDTH := 6.5
const CANOPY_HEIGHT := 0.15
const CANOPY_DEPTH := 1.5

const SIGN_WIDTH := 5.0
const SIGN_HEIGHT := 1.0
const SIGN_DEPTH := 0.1
const SIGN_Y := 4.2            # Высота центра вывески

# === Цвета ===
const YELLOW_WALL_COLOR := Color(0.85, 0.75, 0.35)
const CONCRETE_COLOR := Color(0.55, 0.53, 0.50)
const GRAY_DOOR_COLOR := Color(0.3, 0.3, 0.33)
const DARK_METAL_COLOR := Color(0.15, 0.15, 0.17)
const RED_SIGN_COLOR := Color(0.8, 0.15, 0.1)

const MATERIAL_KEYS := ["yellow_wall", "concrete", "gray_door", "dark_metal", "red_sign"]

static var _materials: Dictionary = {}


static func get_materials() -> Dictionary:
	_ensure_materials()
	return _materials


static func _ensure_materials() -> void:
	if not _materials.is_empty():
		return

	var base_shader := Shader.new()
	base_shader.code = """
shader_type spatial;
render_mode cull_disabled;
uniform vec4 albedo_color : source_color = vec4(0.5, 0.5, 0.5, 1.0);
uniform float roughness_value : hint_range(0.0, 1.0) = 0.5;
uniform float metallic_value : hint_range(0.0, 1.0) = 0.0;
void fragment() {
	ALBEDO = albedo_color.rgb;
	ROUGHNESS = roughness_value;
	METALLIC = metallic_value;
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
}
"""

	var yellow := ShaderMaterial.new()
	yellow.shader = base_shader
	yellow.set_shader_parameter("albedo_color", YELLOW_WALL_COLOR)
	yellow.set_shader_parameter("roughness_value", 0.8)
	yellow.set_shader_parameter("metallic_value", 0.0)
	_materials["yellow_wall"] = yellow

	var concrete := ShaderMaterial.new()
	concrete.shader = base_shader
	concrete.set_shader_parameter("albedo_color", CONCRETE_COLOR)
	concrete.set_shader_parameter("roughness_value", 0.9)
	concrete.set_shader_parameter("metallic_value", 0.0)
	_materials["concrete"] = concrete

	var gray_door := ShaderMaterial.new()
	gray_door.shader = base_shader
	gray_door.set_shader_parameter("albedo_color", GRAY_DOOR_COLOR)
	gray_door.set_shader_parameter("roughness_value", 0.4)
	gray_door.set_shader_parameter("metallic_value", 0.5)
	_materials["gray_door"] = gray_door

	var dark := ShaderMaterial.new()
	dark.shader = base_shader
	dark.set_shader_parameter("albedo_color", DARK_METAL_COLOR)
	dark.set_shader_parameter("roughness_value", 0.4)
	dark.set_shader_parameter("metallic_value", 0.7)
	_materials["dark_metal"] = dark

	var red := ShaderMaterial.new()
	red.shader = base_shader
	red.set_shader_parameter("albedo_color", RED_SIGN_COLOR)
	red.set_shader_parameter("roughness_value", 0.5)
	red.set_shader_parameter("metallic_value", 0.1)
	_materials["red_sign"] = red


static func generate_entrance_geometry(world_pos: Vector3, rotation_y: float) -> Dictionary:
	var geo := {}
	for key in MATERIAL_KEYS:
		geo[key] = {
			"vertices": PackedVector3Array(),
			"normals": PackedVector3Array(),
			"indices": PackedInt32Array()
		}

	# === YELLOW_WALL: большая жёлтая стена (от земли до 6м) ===
	var g: Dictionary = geo["yellow_wall"]
	_add_box_rotated(g, world_pos, rotation_y,
		Vector3(0, WALL_HEIGHT / 2.0, WALL_DEPTH / 2.0 + 0.02),
		Vector3(WALL_WIDTH, WALL_HEIGHT, WALL_DEPTH))

	# Боковые перила — сплошные жёлтые бетонные стенки вдоль лестницы
	var stair_total_depth := STEP_COUNT * STEP_DEPTH
	var railing_total_depth := PLATFORM_DEPTH + stair_total_depth
	var h_near := PLATFORM_HEIGHT + SIDE_RAILING_HEIGHT  # высота у площадки
	var h_far := SIDE_RAILING_HEIGHT                     # высота у нижней ступени
	for side in [-1, 1]:
		var rx: float = side * (STEP_WIDTH / 2.0 - SIDE_RAILING_WIDTH / 2.0 + 0.05)
		_add_railing_wall_rotated(g, world_pos, rotation_y,
			Vector3(rx, 0, 0), SIDE_RAILING_WIDTH, railing_total_depth, h_near, h_far)

	# === CONCRETE: ступеньки + площадка ===
	g = geo["concrete"]

	# Площадка
	_add_box_rotated(g, world_pos, rotation_y,
		Vector3(0, PLATFORM_HEIGHT / 2.0, PLATFORM_DEPTH / 2.0),
		Vector3(STEP_WIDTH, PLATFORM_HEIGHT, PLATFORM_DEPTH))

	# 5 ступеней
	for i in range(STEP_COUNT):
		var step_y := (STEP_COUNT - 1 - i) * STEP_HEIGHT
		var step_z := PLATFORM_DEPTH + i * STEP_DEPTH
		_add_box_rotated(g, world_pos, rotation_y,
			Vector3(0, step_y + STEP_HEIGHT / 2.0, step_z + STEP_DEPTH / 2.0),
			Vector3(STEP_WIDTH, STEP_HEIGHT, STEP_DEPTH))

	# === DARK_METAL: козырёк + центральные перила ===
	g = geo["dark_metal"]

	# Козырёк
	var canopy_y := PLATFORM_HEIGHT + DOOR_HEIGHT + CANOPY_HEIGHT / 2.0 + 0.05
	_add_box_rotated(g, world_pos, rotation_y,
		Vector3(0, canopy_y, CANOPY_DEPTH / 2.0 - 0.1),
		Vector3(CANOPY_WIDTH, CANOPY_HEIGHT, CANOPY_DEPTH))

	# Центральные чёрные перила (по центру ступеней)
	var railing_z_start := PLATFORM_DEPTH
	var railing_z_end := PLATFORM_DEPTH + stair_total_depth
	# Горизонтальная перекладина
	_add_box_rotated(g, world_pos, rotation_y,
		Vector3(0, PLATFORM_HEIGHT + CENTER_RAILING_HEIGHT, (railing_z_start + railing_z_end) / 2.0),
		Vector3(CENTER_RAILING_THICKNESS, CENTER_RAILING_THICKNESS, stair_total_depth))
	# Вертикальные стойки (4 штуки)
	for j in range(4):
		var t := float(j) / 3.0
		var post_z := railing_z_start + t * stair_total_depth
		var post_y_bottom := PLATFORM_HEIGHT * (1.0 - t)
		var post_height := CENTER_RAILING_HEIGHT + PLATFORM_HEIGHT * t
		_add_box_rotated(g, world_pos, rotation_y,
			Vector3(0, post_y_bottom + post_height / 2.0, post_z),
			Vector3(CENTER_RAILING_THICKNESS, post_height, CENTER_RAILING_THICKNESS))

	# === GRAY_DOOR: 2 пары дверей ===
	g = geo["gray_door"]
	for set_side in [-1, 1]:
		var set_center_x: float = set_side * (DOOR_SET_GAP / 2.0 + DOOR_WIDTH + DOOR_GAP / 2.0)
		for door_i in range(2):
			var door_x := set_center_x + (door_i - 0.5) * (DOOR_WIDTH + DOOR_GAP)
			_add_quad_rotated(g, world_pos, rotation_y,
				Vector3(door_x, PLATFORM_HEIGHT + DOOR_HEIGHT / 2.0, WALL_DEPTH + 0.04),
				Vector2(DOOR_WIDTH, DOOR_HEIGHT))

	# === RED_SIGN: красная вывеска ===
	g = geo["red_sign"]
	_add_box_rotated(g, world_pos, rotation_y,
		Vector3(0, SIGN_Y, SIGN_DEPTH / 2.0 + 0.05),
		Vector3(SIGN_WIDTH, SIGN_HEIGHT, SIGN_DEPTH))

	# Данные для размещения Label3D текста
	var sign_face_z := SIGN_DEPTH + 0.07
	geo["sign_data"] = {
		"position": _rotate_point(world_pos, rotation_y, Vector3(0, SIGN_Y, sign_face_z)),
		"rotation_y": rotation_y
	}

	# === КОЛЛИЗИИ ===
	var collisions := []
	# Стена + площадка
	collisions.append({
		"center": _rotate_point(world_pos, rotation_y, Vector3(0, WALL_HEIGHT / 2.0, 0)),
		"size": Vector3(WALL_WIDTH, WALL_HEIGHT, PLATFORM_DEPTH + 0.3),
		"rotation_y": rotation_y
	})
	# Ступеньки
	var stairs_center_z := PLATFORM_DEPTH + stair_total_depth / 2.0
	collisions.append({
		"center": _rotate_point(world_pos, rotation_y, Vector3(0, PLATFORM_HEIGHT / 2.0, stairs_center_z)),
		"size": Vector3(STEP_WIDTH, PLATFORM_HEIGHT, stair_total_depth),
		"rotation_y": rotation_y
	})

	geo["collisions"] = collisions
	return geo


# === Вспомогательные функции (идентичны ResidentialEntranceGenerator) ===

static func _rotate_point(origin: Vector3, rot: float, local: Vector3) -> Vector3:
	var cos_r := cos(rot)
	var sin_r := sin(rot)
	return Vector3(
		origin.x + local.x * cos_r + local.z * sin_r,
		origin.y + local.y,
		origin.z - local.x * sin_r + local.z * cos_r
	)


static func _rotate_normal(rot: float, normal: Vector3) -> Vector3:
	var cos_r := cos(rot)
	var sin_r := sin(rot)
	return Vector3(
		normal.x * cos_r + normal.z * sin_r,
		normal.y,
		-normal.x * sin_r + normal.z * cos_r
	)


static func _add_box_rotated(geo: Dictionary, origin: Vector3, rot: float,
		local_center: Vector3, size: Vector3) -> void:
	var verts: PackedVector3Array = geo["vertices"]
	var norms: PackedVector3Array = geo["normals"]
	var idx: PackedInt32Array = geo["indices"]

	var hx := size.x * 0.5
	var hy := size.y * 0.5
	var hz := size.z * 0.5

	var faces := [
		[Vector3(0, 0, 1), [Vector3(-hx, -hy, hz), Vector3(hx, -hy, hz), Vector3(hx, hy, hz), Vector3(-hx, hy, hz)]],
		[Vector3(0, 0, -1), [Vector3(hx, -hy, -hz), Vector3(-hx, -hy, -hz), Vector3(-hx, hy, -hz), Vector3(hx, hy, -hz)]],
		[Vector3(0, 1, 0), [Vector3(-hx, hy, -hz), Vector3(-hx, hy, hz), Vector3(hx, hy, hz), Vector3(hx, hy, -hz)]],
		[Vector3(0, -1, 0), [Vector3(-hx, -hy, hz), Vector3(-hx, -hy, -hz), Vector3(hx, -hy, -hz), Vector3(hx, -hy, hz)]],
		[Vector3(1, 0, 0), [Vector3(hx, -hy, hz), Vector3(hx, -hy, -hz), Vector3(hx, hy, -hz), Vector3(hx, hy, hz)]],
		[Vector3(-1, 0, 0), [Vector3(-hx, -hy, -hz), Vector3(-hx, -hy, hz), Vector3(-hx, hy, hz), Vector3(-hx, hy, -hz)]],
	]

	for face in faces:
		var base := verts.size()
		var n: Vector3 = _rotate_normal(rot, face[0])
		var corners: Array = face[1]
		for c in corners:
			verts.append(_rotate_point(origin, rot, local_center + c))
			norms.append(n)
		idx.append_array([base, base + 1, base + 2, base, base + 2, base + 3])


static func _add_railing_wall_rotated(geo: Dictionary, origin: Vector3, rot: float,
		local_pos: Vector3, width: float, depth: float, h_near: float, h_far: float) -> void:
	## Сплошная стенка-перила: высота h_near у ближнего края, h_far у дальнего.
	## local_pos — нижний передний центр (по X).
	var verts: PackedVector3Array = geo["vertices"]
	var norms: PackedVector3Array = geo["normals"]
	var idx: PackedInt32Array = geo["indices"]

	var hx := width * 0.5
	# 8 вершин клина
	var v0 := local_pos + Vector3(-hx, 0, 0)         # bottom-left-near
	var v1 := local_pos + Vector3(hx, 0, 0)          # bottom-right-near
	var v2 := local_pos + Vector3(hx, h_near, 0)     # top-right-near
	var v3 := local_pos + Vector3(-hx, h_near, 0)    # top-left-near
	var v4 := local_pos + Vector3(-hx, 0, depth)     # bottom-left-far
	var v5 := local_pos + Vector3(hx, 0, depth)      # bottom-right-far
	var v6 := local_pos + Vector3(hx, h_far, depth)  # top-right-far
	var v7 := local_pos + Vector3(-hx, h_far, depth) # top-left-far

	# Нормаль верхней наклонной грани
	var top_n := Vector3(0, depth, h_near - h_far).normalized()

	# 6 граней: [normal, [4 corners CCW]]
	var faces := [
		[Vector3(0, 0, -1), [v0, v1, v2, v3]],   # front (near)
		[Vector3(0, 0, 1), [v5, v4, v7, v6]],     # back (far)
		[Vector3(0, -1, 0), [v4, v5, v1, v0]],    # bottom
		[top_n, [v3, v2, v6, v7]],                 # top (sloped)
		[Vector3(1, 0, 0), [v1, v5, v6, v2]],     # right
		[Vector3(-1, 0, 0), [v4, v0, v3, v7]],    # left
	]

	for face in faces:
		var base := verts.size()
		var n: Vector3 = _rotate_normal(rot, face[0])
		var corners: Array = face[1]
		for c in corners:
			verts.append(_rotate_point(origin, rot, c))
			norms.append(n)
		idx.append_array([base, base + 1, base + 2, base, base + 2, base + 3])


static func _add_quad_rotated(geo: Dictionary, origin: Vector3, rot: float,
		local_center: Vector3, size: Vector2) -> void:
	var verts: PackedVector3Array = geo["vertices"]
	var norms: PackedVector3Array = geo["normals"]
	var idx: PackedInt32Array = geo["indices"]

	var hx := size.x * 0.5
	var hy := size.y * 0.5
	var base := verts.size()

	var n := _rotate_normal(rot, Vector3(0, 0, 1))

	verts.append(_rotate_point(origin, rot, local_center + Vector3(-hx, -hy, 0)))
	verts.append(_rotate_point(origin, rot, local_center + Vector3(hx, -hy, 0)))
	verts.append(_rotate_point(origin, rot, local_center + Vector3(hx, hy, 0)))
	verts.append(_rotate_point(origin, rot, local_center + Vector3(-hx, hy, 0)))
	for _i in range(4):
		norms.append(n)
	idx.append_array([base, base + 1, base + 2, base, base + 2, base + 3])
