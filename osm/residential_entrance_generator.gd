class_name ResidentialEntranceGenerator
extends RefCounted

## Генератор входных групп для жилых домов (серия 111-125 и др.)
## Возвращает сырую геометрию для per-chunk batch merge.

# === Размеры (метры) ===
const STEP_HEIGHT := 0.15
const STEP_DEPTH := 0.3
const STEP_COUNT := 5
const STEP_WIDTH := 3.5

const PLATFORM_DEPTH := 1.2      # Глубина площадки перед дверями
const PLATFORM_HEIGHT := 0.75    # = STEP_COUNT * STEP_HEIGHT

const RED_DOOR_WIDTH := 0.9
const RED_DOOR_HEIGHT := 2.1

const GRAY_DOOR_WIDTH := 0.9
const GRAY_DOOR_HEIGHT := 2.2
const GRAY_DOOR_GAP := 0.15      # Зазор между серыми дверями

const TURQUOISE_WALL_WIDTH := 2.5
const TURQUOISE_WALL_HEIGHT := 2.8
const TURQUOISE_WALL_DEPTH := 0.1

const CANOPY_WIDTH := 4.5
const CANOPY_HEIGHT := 0.2
const CANOPY_DEPTH := 1.5

const RAILING_THICKNESS := 0.04
const RAILING_HEIGHT := 0.9

const LAMP_WIDTH := 0.4
const LAMP_HEIGHT := 0.12
const LAMP_DEPTH := 0.15

# === Цвета материалов ===
const CONCRETE_COLOR := Color(0.55, 0.53, 0.50)
const RED_METAL_COLOR := Color(0.7, 0.15, 0.1)
const GRAY_METAL_COLOR := Color(0.35, 0.35, 0.38)
const TURQUOISE_COLOR := Color(0.2, 0.75, 0.65)
const DARK_METAL_COLOR := Color(0.25, 0.25, 0.28)
const LAMP_COLOR := Color(1.0, 0.9, 0.7)

# Ключи материалов (для батчинга)
const MATERIAL_KEYS := ["concrete", "red_metal", "gray_metal", "turquoise", "dark_metal", "lamp_emissive"]

# Кэш shared материалов
static var _materials: Dictionary = {}


static func get_materials() -> Dictionary:
	"""Возвращает shared материалы для финализации батча"""
	_ensure_materials()
	return _materials


static func _ensure_materials() -> void:
	if not _materials.is_empty():
		return

	# Общий шейдер для всех материалов входной группы
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

	var concrete := ShaderMaterial.new()
	concrete.shader = base_shader
	concrete.set_shader_parameter("albedo_color", CONCRETE_COLOR)
	concrete.set_shader_parameter("roughness_value", 0.9)
	concrete.set_shader_parameter("metallic_value", 0.0)
	_materials["concrete"] = concrete

	var red := ShaderMaterial.new()
	red.shader = base_shader
	red.set_shader_parameter("albedo_color", RED_METAL_COLOR)
	red.set_shader_parameter("roughness_value", 0.5)
	red.set_shader_parameter("metallic_value", 0.4)
	_materials["red_metal"] = red

	var gray := ShaderMaterial.new()
	gray.shader = base_shader
	gray.set_shader_parameter("albedo_color", GRAY_METAL_COLOR)
	gray.set_shader_parameter("roughness_value", 0.4)
	gray.set_shader_parameter("metallic_value", 0.5)
	_materials["gray_metal"] = gray

	var turquoise := ShaderMaterial.new()
	turquoise.shader = base_shader
	turquoise.set_shader_parameter("albedo_color", TURQUOISE_COLOR)
	turquoise.set_shader_parameter("roughness_value", 0.8)
	turquoise.set_shader_parameter("metallic_value", 0.0)
	_materials["turquoise"] = turquoise

	var dark := ShaderMaterial.new()
	dark.shader = base_shader
	dark.set_shader_parameter("albedo_color", DARK_METAL_COLOR)
	dark.set_shader_parameter("roughness_value", 0.4)
	dark.set_shader_parameter("metallic_value", 0.7)
	_materials["dark_metal"] = dark

	# Светильник с эмиссией по ночному режиму
	var lamp_shader := Shader.new()
	lamp_shader.code = """
shader_type spatial;
render_mode cull_disabled;
uniform vec4 albedo_color : source_color = vec4(1.0, 0.9, 0.7, 1.0);
global uniform bool is_night_global;
void fragment() {
	ALBEDO = albedo_color.rgb;
	if (is_night_global) {
		EMISSION = albedo_color.rgb * 4.0;
	}
}
"""
	var lamp_mat := ShaderMaterial.new()
	lamp_mat.shader = lamp_shader
	lamp_mat.set_shader_parameter("albedo_color", LAMP_COLOR)
	_materials["lamp_emissive"] = lamp_mat


static func generate_entrance_geometry(world_pos: Vector3, rotation_y: float) -> Dictionary:
	"""
	Генерирует геометрию подъезда серии 111-125.
	Все вершины в мировых координатах.

	world_pos: позиция у стены (основание подъезда)
	rotation_y: поворот (рад), +Z = наружу от стены

	Returns: {
	  "concrete": {vertices, normals, indices},
	  "red_metal": ...,
	  "gray_metal": ...,
	  "turquoise": ...,
	  "dark_metal": ...,
	  "collisions": [{center, size, rotation_y}]
	}
	"""
	# Создаём буферы для каждого материала
	var geo := {}
	for key in MATERIAL_KEYS:
		geo[key] = {
			"vertices": PackedVector3Array(),
			"normals": PackedVector3Array(),
			"indices": PackedInt32Array()
		}

	# Базис поворота
	var cos_r := cos(rotation_y)
	var sin_r := sin(rotation_y)

	# Локальные координаты: X = вдоль стены, Z = от стены наружу, Y = вверх
	# Центр — точка на стене

	# === CONCRETE: площадка + ступени ===
	var g: Dictionary = geo["concrete"]

	# Площадка (приподнята на PLATFORM_HEIGHT)
	_add_box_rotated(g, world_pos, rotation_y,
		Vector3(0, PLATFORM_HEIGHT / 2.0, PLATFORM_DEPTH / 2.0),
		Vector3(STEP_WIDTH, PLATFORM_HEIGHT, PLATFORM_DEPTH))

	# 5 ступеней (от площадки наружу, каждая ниже)
	for i in range(STEP_COUNT):
		var step_y := (STEP_COUNT - 1 - i) * STEP_HEIGHT
		var step_z := PLATFORM_DEPTH + i * STEP_DEPTH
		_add_box_rotated(g, world_pos, rotation_y,
			Vector3(0, step_y + STEP_HEIGHT / 2.0, step_z + STEP_DEPTH / 2.0),
			Vector3(STEP_WIDTH, STEP_HEIGHT, STEP_DEPTH))

	# === RED_METAL: красная дверь (слева, на уровне земли) + перила ===
	g = geo["red_metal"]

	# Красная дверь — слева от бирюзовой стенки, на уровне земли (не на площадке)
	var red_door_x := -(TURQUOISE_WALL_WIDTH / 2.0 + RED_DOOR_WIDTH * 1.5 + 0.1)
	_add_quad_rotated(g, world_pos, rotation_y,
		Vector3(red_door_x, RED_DOOR_HEIGHT / 2.0, TURQUOISE_WALL_DEPTH + 0.04),
		Vector2(RED_DOOR_WIDTH, RED_DOOR_HEIGHT))

	# Перила (2 штуки по бокам ступеней)
	var stair_total_depth := STEP_COUNT * STEP_DEPTH
	var railing_z := PLATFORM_DEPTH + stair_total_depth / 2.0
	var railing_y := PLATFORM_HEIGHT / 2.0 + RAILING_HEIGHT / 2.0

	for side in [-1, 1]:
		var railing_x: float = side * (STEP_WIDTH / 2.0 - RAILING_THICKNESS)
		# Горизонтальная перекладина
		_add_box_rotated(g, world_pos, rotation_y,
			Vector3(railing_x, PLATFORM_HEIGHT + RAILING_HEIGHT, railing_z),
			Vector3(RAILING_THICKNESS, RAILING_THICKNESS, stair_total_depth + PLATFORM_DEPTH))
		# Вертикальные стойки (3 штуки)
		for j in range(3):
			var t := float(j) / 2.0
			var post_z := PLATFORM_DEPTH * (1.0 - t) + (PLATFORM_DEPTH + stair_total_depth) * t
			var post_y_bottom := PLATFORM_HEIGHT * (1.0 - t)
			var post_height := RAILING_HEIGHT + PLATFORM_HEIGHT * t
			_add_box_rotated(g, world_pos, rotation_y,
				Vector3(railing_x, post_y_bottom + post_height / 2.0, post_z),
				Vector3(RAILING_THICKNESS, post_height, RAILING_THICKNESS))

	# === GRAY_METAL: серые двери (2 шт на площадке) ===
	g = geo["gray_metal"]
	var gray_start_x := -GRAY_DOOR_GAP / 2.0 - GRAY_DOOR_WIDTH
	for i in range(2):
		var door_x := gray_start_x + i * (GRAY_DOOR_WIDTH + GRAY_DOOR_GAP) + GRAY_DOOR_WIDTH / 2.0
		_add_quad_rotated(g, world_pos, rotation_y,
			Vector3(door_x, PLATFORM_HEIGHT + GRAY_DOOR_HEIGHT / 2.0, TURQUOISE_WALL_DEPTH + 0.04),
			Vector2(GRAY_DOOR_WIDTH, GRAY_DOOR_HEIGHT))

	# Вычисляем общие границы: от левого края красной двери до правого перила
	var left_edge := red_door_x - RED_DOOR_WIDTH / 2.0 - RED_DOOR_WIDTH * 0.25
	var right_edge := STEP_WIDTH / 2.0
	var full_width := right_edge - left_edge
	var center_x := (left_edge + right_edge) / 2.0

	# === DARK_METAL: козырёк (от красной двери до правого перила) ===
	g = geo["dark_metal"]
	var canopy_y := PLATFORM_HEIGHT + GRAY_DOOR_HEIGHT + CANOPY_HEIGHT / 2.0 + 0.05
	_add_box_rotated(g, world_pos, rotation_y,
		Vector3(center_x, canopy_y, CANOPY_DEPTH / 2.0 - 0.1),
		Vector3(full_width, CANOPY_HEIGHT, CANOPY_DEPTH))

	# === TURQUOISE: стенка от красной двери до правого перила, от пола до козырька ===
	g = geo["turquoise"]
	var wall_height := canopy_y + CANOPY_HEIGHT / 2.0
	_add_box_rotated(g, world_pos, rotation_y,
		Vector3(center_x, wall_height / 2.0, TURQUOISE_WALL_DEPTH / 2.0 + 0.02),
		Vector3(full_width, wall_height, TURQUOISE_WALL_DEPTH))

	# === LAMP: светильник под козырьком между дверьми ===
	# Корпус (dark_metal)
	var lamp_y := canopy_y - CANOPY_HEIGHT / 2.0 - LAMP_HEIGHT / 2.0
	var lamp_z := TURQUOISE_WALL_DEPTH + LAMP_DEPTH / 2.0 + 0.02
	_add_box_rotated(geo["dark_metal"], world_pos, rotation_y,
		Vector3(0, lamp_y, lamp_z),
		Vector3(LAMP_WIDTH, LAMP_HEIGHT, LAMP_DEPTH))

	# Светящаяся поверхность (нижняя грань)
	g = geo["lamp_emissive"]
	var lamp_glow_y := lamp_y - LAMP_HEIGHT / 2.0
	_add_quad_rotated_down(g, world_pos, rotation_y,
		Vector3(0, lamp_glow_y, lamp_z),
		Vector2(LAMP_WIDTH - 0.04, LAMP_DEPTH - 0.04))

	# Позиция для OmniLight3D (вперёд от стены, на середине площадки)
	var light_pos := _rotate_point(world_pos, rotation_y,
		Vector3(0, lamp_y - LAMP_HEIGHT, PLATFORM_DEPTH * 0.5))
	geo["lights"] = [{"position": light_pos}]

	# === КОЛЛИЗИИ ===
	var collisions := []

	# Стенка + площадка (основной блок)
	var wall_coll_height := TURQUOISE_WALL_HEIGHT
	collisions.append({
		"center": _rotate_point(world_pos, rotation_y, Vector3(0, wall_coll_height / 2.0, 0)),
		"size": Vector3(CANOPY_WIDTH, wall_coll_height, PLATFORM_DEPTH + 0.3),
		"rotation_y": rotation_y
	})

	# Ступеньки (упрощённый box)
	var stairs_center_z := PLATFORM_DEPTH + stair_total_depth / 2.0
	collisions.append({
		"center": _rotate_point(world_pos, rotation_y, Vector3(0, PLATFORM_HEIGHT / 2.0, stairs_center_z)),
		"size": Vector3(STEP_WIDTH, PLATFORM_HEIGHT, stair_total_depth),
		"rotation_y": rotation_y
	})

	geo["collisions"] = collisions
	return geo


# === Вспомогательные функции ===

static func _rotate_point(origin: Vector3, rot: float, local: Vector3) -> Vector3:
	"""Поворачивает локальную точку вокруг Y и смещает на origin"""
	var cos_r := cos(rot)
	var sin_r := sin(rot)
	return Vector3(
		origin.x + local.x * cos_r + local.z * sin_r,
		origin.y + local.y,
		origin.z - local.x * sin_r + local.z * cos_r
	)


static func _rotate_normal(rot: float, normal: Vector3) -> Vector3:
	"""Поворачивает нормаль вокруг Y"""
	var cos_r := cos(rot)
	var sin_r := sin(rot)
	return Vector3(
		normal.x * cos_r + normal.z * sin_r,
		normal.y,
		-normal.x * sin_r + normal.z * cos_r
	)


static func _add_box_rotated(geo: Dictionary, origin: Vector3, rot: float,
		local_center: Vector3, size: Vector3) -> void:
	"""Добавляет box уже повёрнутый в мировые координаты"""
	var verts: PackedVector3Array = geo["vertices"]
	var norms: PackedVector3Array = geo["normals"]
	var idx: PackedInt32Array = geo["indices"]

	var hx := size.x * 0.5
	var hy := size.y * 0.5
	var hz := size.z * 0.5

	# 6 граней
	var faces := [
		# normal_local, 4 corners (local offsets from center)
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


static func _add_quad_rotated_down(geo: Dictionary, origin: Vector3, rot: float,
		local_center: Vector3, size: Vector2) -> void:
	"""Добавляет quad лицом вниз (-Y) уже повёрнутый"""
	var verts: PackedVector3Array = geo["vertices"]
	var norms: PackedVector3Array = geo["normals"]
	var idx: PackedInt32Array = geo["indices"]

	var hx := size.x * 0.5
	var hz := size.y * 0.5
	var base := verts.size()

	var n := _rotate_normal(rot, Vector3(0, -1, 0))

	verts.append(_rotate_point(origin, rot, local_center + Vector3(-hx, 0, -hz)))
	verts.append(_rotate_point(origin, rot, local_center + Vector3(hx, 0, -hz)))
	verts.append(_rotate_point(origin, rot, local_center + Vector3(hx, 0, hz)))
	verts.append(_rotate_point(origin, rot, local_center + Vector3(-hx, 0, hz)))
	for _i in range(4):
		norms.append(n)
	idx.append_array([base, base + 1, base + 2, base, base + 2, base + 3])


static func _add_quad_rotated(geo: Dictionary, origin: Vector3, rot: float,
		local_center: Vector3, size: Vector2) -> void:
	"""Добавляет quad (лицом наружу, +Z) уже повёрнутый"""
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
