extends Node3D
class_name TestTrackGenerator

## Процедурный генератор тестовых трасс (без OSM)
## Создаёт дорогу, обочину, ограждения

signal generation_complete

const ROAD_WIDTH := 12.0  # Ширина дороги (метры)
const ROAD_COLOR := Color(0.18, 0.18, 0.20)  # Тёмный асфальт
const CURB_COLOR := Color(0.5, 0.5, 0.5)  # Серый бордюр
const GRASS_COLOR := Color(0.35, 0.50, 0.30)  # Трава
const LINE_COLOR := Color(1, 1, 1, 0.8)  # Белая разметка
const BARRIER_COLOR := Color(0.6, 0.1, 0.1)  # Красные отбойники
const BARRIER_WHITE := Color(0.9, 0.9, 0.9)  # Белые полоски отбойников

var _track_id: String = ""
var _road_material: StandardMaterial3D
var _curb_material: StandardMaterial3D
var _grass_material: StandardMaterial3D
var _barrier_material: StandardMaterial3D
var _line_material: StandardMaterial3D


func generate(track_id: String) -> void:
	_track_id = track_id
	_init_materials()

	match track_id:
		"test_flat":
			_generate_flat_track()
		"test_suspension":
			_generate_suspension_track()
		_:
			push_error("Unknown test track: " + track_id)
			_generate_flat_track()

	generation_complete.emit()


func get_spawn_position() -> Vector3:
	match _track_id:
		"test_flat":
			# Спавн на правой прямой овала (X = turn_radius, Z = 0)
			return Vector3(80, 1.0, 0)
		"test_suspension":
			# Спавн в начале трассы
			return Vector3(0, 1.0, 5)
		_:
			return Vector3(0, 1.0, 0)


func get_spawn_rotation() -> float:
	# Направление вдоль Z (вперёд)
	return 0.0


func _init_materials() -> void:
	_road_material = StandardMaterial3D.new()
	_road_material.albedo_color = ROAD_COLOR
	_road_material.roughness = 0.85
	_road_material.cull_mode = BaseMaterial3D.CULL_DISABLED

	_curb_material = StandardMaterial3D.new()
	_curb_material.albedo_color = CURB_COLOR
	_curb_material.roughness = 0.9
	_curb_material.cull_mode = BaseMaterial3D.CULL_DISABLED

	_grass_material = StandardMaterial3D.new()
	_grass_material.albedo_color = GRASS_COLOR
	_grass_material.roughness = 0.95

	_barrier_material = StandardMaterial3D.new()
	_barrier_material.albedo_color = BARRIER_COLOR
	_barrier_material.roughness = 0.7
	_barrier_material.cull_mode = BaseMaterial3D.CULL_DISABLED

	_line_material = StandardMaterial3D.new()
	_line_material.albedo_color = LINE_COLOR
	_line_material.roughness = 0.7
	_line_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA


# ==========================================
# ПЛОСКАЯ ТРАССА - овальный трек
# ==========================================

func _generate_flat_track() -> void:
	# Овальный трек: 2 прямые + 2 полукруга
	var straight_length := 300.0  # Длина прямого участка
	var turn_radius := 80.0  # Радиус поворота
	var segments := 64  # Сегментов на полукруг

	# Генерируем точки centerline
	var points := _generate_oval_points(straight_length, turn_radius, segments)

	# Создаём дорогу по точкам
	_create_road_from_points(points, ROAD_WIDTH, false)

	# Разметка (центральная линия)
	_create_center_line(points, 0.15)

	# Ограждения по бокам
	_create_barriers(points, ROAD_WIDTH)

	print("TestTrack: Flat oval track generated, length ~%.0f m" % _calc_track_length(points))


func _generate_oval_points(straight_len: float, radius: float, segments: int) -> PackedVector3Array:
	var points := PackedVector3Array()
	var half_straight := straight_len / 2.0
	var straight_steps := 30

	# Правая прямая: X = +radius, Z от -half_straight до +half_straight
	for i in range(straight_steps + 1):
		var t := float(i) / straight_steps
		var z := -half_straight + t * straight_len
		points.append(Vector3(radius, 0, z))

	# Верхний полукруг: центр (0, 0, +half_straight), от правой прямой к левой
	for i in range(1, segments + 1):
		var angle := float(i) / segments * PI
		var x := radius * cos(angle)
		var z := half_straight + radius * sin(angle)
		points.append(Vector3(x, 0, z))

	# Левая прямая: X = -radius, Z от +half_straight до -half_straight
	for i in range(1, straight_steps + 1):
		var t := float(i) / straight_steps
		var z := half_straight - t * straight_len
		points.append(Vector3(-radius, 0, z))

	# Нижний полукруг: центр (0, 0, -half_straight), от левой прямой к правой
	# range до segments (не segments-1), чтобы замкнуть петлю до первой точки
	for i in range(1, segments):
		var angle := PI + float(i) / segments * PI
		var x := radius * cos(angle)
		var z := -half_straight + radius * sin(angle)
		points.append(Vector3(x, 0, z))

	# Замыкаем овал — добавляем первую точку для бесшовного стыка
	points.append(points[0])

	return points


# ==========================================
# ТЕСТ ПОДВЕСКИ - прямая дорога с бугорками
# ==========================================

func _generate_suspension_track() -> void:
	var track_length := 500.0  # Длина трассы
	var segments := 200  # Количество сегментов

	# Генерируем точки с бугорками
	var points := PackedVector3Array()
	for i in range(segments + 1):
		var t := float(i) / segments
		var z := t * track_length
		var y := _suspension_height(z)
		points.append(Vector3(0, y, z))

	# Создаём дорогу
	_create_road_from_points(points, ROAD_WIDTH, true)

	# Разметка
	_create_center_line(points, 0.15)

	# Ограждения
	_create_barriers(points, ROAD_WIDTH)

	# Разворотная петля в конце
	_create_turnaround(Vector3(0, 0, track_length), 30.0)

	print("TestTrack: Suspension test track generated, length %.0f m" % track_length)


func _suspension_height(z: float) -> float:
	# Первые 50м - ровная дорога (разгон)
	if z < 50.0:
		return 0.0

	# 50-150м: мелкие бугорки (speed bumps)
	if z < 150.0:
		var local_z := z - 50.0
		return sin(local_z * 0.5) * 0.15 + sin(local_z * 1.2) * 0.08

	# 150-200м: ровный участок
	if z < 200.0:
		return 0.0

	# 200-300м: крупные волны
	if z < 300.0:
		var local_z := z - 200.0
		return sin(local_z * 0.08) * 0.8 + sin(local_z * 0.15) * 0.3

	# 300-350м: ровный
	if z < 350.0:
		return 0.0

	# 350-450м: ямы и бугры (жёсткий тест)
	if z < 450.0:
		var local_z := z - 350.0
		var h := sin(local_z * 0.3) * 0.5
		# Добавляем резкие ямы каждые 20м
		var pit := fmod(local_z, 20.0)
		if pit < 3.0:
			h -= 0.3 * sin(pit / 3.0 * PI)
		return h

	# Последние 50м - выравнивание
	var local_z := z - 450.0
	var blend := clampf(local_z / 50.0, 0.0, 1.0)
	var prev_h := sin((z - 350.0 - 100.0) * 0.3) * 0.5
	return prev_h * (1.0 - blend)


func _create_turnaround(center: Vector3, radius: float) -> void:
	## Создаёт разворотную площадку в конце трассы
	var segments := 32
	var points := PackedVector3Array()
	for i in range(segments + 1):
		var angle := float(i) / segments * PI * 2
		var x := center.x + cos(angle) * radius
		var z := center.z + sin(angle) * radius
		points.append(Vector3(x, center.y, z))

	# Плоская площадка
	var mesh := ArrayMesh.new()
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var idx := PackedInt32Array()

	# Круг из треугольников (fan)
	verts.append(center + Vector3(0, 0.05, 0))
	norms.append(Vector3.UP)
	for i in range(segments + 1):
		verts.append(points[i] + Vector3(0, 0.05, 0))
		norms.append(Vector3.UP)
	for i in range(segments):
		idx.append(0)
		idx.append(i + 1)
		idx.append(i + 2)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_INDEX] = idx
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _road_material)

	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = mesh
	mesh_inst.name = "Turnaround"
	add_child(mesh_inst)

	# Коллизия для площадки
	var body := StaticBody3D.new()
	body.name = "TurnaroundCollision"
	var col := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = radius
	shape.height = 0.2
	col.shape = shape
	body.add_child(col)
	body.global_position = center
	add_child(body)


# ==========================================
# ОБЩИЕ ФУНКЦИИ СОЗДАНИЯ ГЕОМЕТРИИ
# ==========================================

func _create_road_from_points(points: PackedVector3Array, width: float, use_heightmap_collision: bool) -> void:
	## Создаёт дорожное полотно по точкам centerline
	var half_w := width / 2.0
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var idx := PackedInt32Array()

	for i in range(points.size()):
		# Направление дороги
		var dir := Vector3.FORWARD
		if i < points.size() - 1:
			dir = (points[i + 1] - points[i]).normalized()
		elif i > 0:
			dir = (points[i] - points[i - 1]).normalized()

		# Перпендикуляр (вправо)
		var right := dir.cross(Vector3.UP).normalized()
		if right.length_squared() < 0.01:
			right = Vector3.RIGHT

		var p := points[i]
		var base := verts.size()

		# Левая и правая точки дороги (выше земли чтобы не z-fighting)
		verts.append(p - right * half_w + Vector3(0, 0.05, 0))
		verts.append(p + right * half_w + Vector3(0, 0.05, 0))
		norms.append(Vector3.UP)
		norms.append(Vector3.UP)

		# Треугольники (кроме первой точки)
		if i > 0:
			var prev_base := base - 2
			idx.append(prev_base)
			idx.append(prev_base + 1)
			idx.append(base + 1)
			idx.append(prev_base)
			idx.append(base + 1)
			idx.append(base)

	# Создаём меш дороги
	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_INDEX] = idx
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _road_material)

	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = mesh
	mesh_inst.name = "RoadSurface"
	add_child(mesh_inst)

	print("TestTrack: Road mesh - %d verts, %d indices, %d triangles" % [verts.size(), idx.size(), idx.size() / 3])

	# Коллизия дороги
	if use_heightmap_collision:
		# Для трассы с бугорками - используем trimesh collision
		_create_trimesh_collision(verts, idx, "RoadCollision")
	else:
		# Для плоской - trimesh тоже подходит
		_create_trimesh_collision(verts, idx, "RoadCollision")

	# Обочины (curbs) по бокам
	_create_curbs(points, width)


func _create_trimesh_collision(verts: PackedVector3Array, indices: PackedInt32Array, col_name: String) -> void:
	## Создаёт trimesh коллизию из вершин и индексов
	var body := StaticBody3D.new()
	body.name = col_name

	# Создаём массив граней для ConcavePolygonShape3D
	var faces := PackedVector3Array()
	for i in range(0, indices.size(), 3):
		faces.append(verts[indices[i]])
		faces.append(verts[indices[i + 1]])
		faces.append(verts[indices[i + 2]])

	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)

	var col := CollisionShape3D.new()
	col.shape = shape
	body.add_child(col)
	add_child(body)


func _create_curbs(points: PackedVector3Array, road_width: float) -> void:
	## Создаёт бордюры по бокам дороги
	var curb_width := 0.5
	var curb_height := 0.12
	var half_road := road_width / 2.0

	for side in [-1, 1]:
		var verts := PackedVector3Array()
		var norms := PackedVector3Array()
		var idx := PackedInt32Array()

		for i in range(points.size()):
			var dir := Vector3.FORWARD
			if i < points.size() - 1:
				dir = (points[i + 1] - points[i]).normalized()
			elif i > 0:
				dir = (points[i] - points[i - 1]).normalized()

			var right := dir.cross(Vector3.UP).normalized()
			if right.length_squared() < 0.01:
				right = Vector3.RIGHT

			var p := points[i]
			var offset: Vector3 = right * (half_road + curb_width * 0.5) * side
			var base := verts.size()

			# Верхняя грань бордюра (2 точки)
			verts.append(p + right * half_road * side + Vector3(0, curb_height, 0))
			verts.append(p + right * (half_road + curb_width) * side + Vector3(0, curb_height, 0))
			norms.append(Vector3.UP)
			norms.append(Vector3.UP)

			if i > 0:
				var prev := base - 2
				idx.append(prev)
				idx.append(prev + 1)
				idx.append(base + 1)
				idx.append(prev)
				idx.append(base + 1)
				idx.append(base)

		var mesh := ArrayMesh.new()
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = norms
		arrays[Mesh.ARRAY_INDEX] = idx
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(0, _curb_material)

		var mesh_inst := MeshInstance3D.new()
		mesh_inst.mesh = mesh
		mesh_inst.name = "Curb_" + ("L" if side < 0 else "R")
		add_child(mesh_inst)


func _create_center_line(points: PackedVector3Array, line_width: float) -> void:
	## Создаёт центральную разметку (пунктир)
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var idx := PackedInt32Array()
	var dash_len := 3.0
	var gap_len := 5.0
	var accumulated := 0.0
	var in_dash := true

	for i in range(points.size()):
		if i > 0:
			accumulated += points[i].distance_to(points[i - 1])
		var cycle := fmod(accumulated, dash_len + gap_len)
		in_dash = cycle < dash_len

		if not in_dash:
			continue

		var dir := Vector3.FORWARD
		if i < points.size() - 1:
			dir = (points[i + 1] - points[i]).normalized()
		elif i > 0:
			dir = (points[i] - points[i - 1]).normalized()

		var right := dir.cross(Vector3.UP).normalized()
		if right.length_squared() < 0.01:
			right = Vector3.RIGHT

		var p := points[i]
		var base := verts.size()
		verts.append(p - right * line_width + Vector3(0, 0.06, 0))
		verts.append(p + right * line_width + Vector3(0, 0.06, 0))
		norms.append(Vector3.UP)
		norms.append(Vector3.UP)

		if base >= 2:
			var prev := base - 2
			# Проверяем что предыдущие точки тоже были в dash
			if verts[prev].distance_to(verts[base]) < 10.0:
				idx.append(prev)
				idx.append(prev + 1)
				idx.append(base + 1)
				idx.append(prev)
				idx.append(base + 1)
				idx.append(base)

	if verts.size() < 4:
		return

	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_INDEX] = idx
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _line_material)

	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = mesh
	mesh_inst.name = "CenterLine"
	add_child(mesh_inst)


func _create_barriers(points: PackedVector3Array, road_width: float) -> void:
	## Создаёт ограждения (отбойники) по бокам дороги
	var barrier_height := 0.8
	var barrier_thickness := 0.15
	var half_road := road_width / 2.0
	var offset_from_road := 1.5  # Расстояние от края дороги

	for side in [-1, 1]:
		var verts := PackedVector3Array()
		var norms := PackedVector3Array()
		var idx := PackedInt32Array()

		for i in range(points.size()):
			var dir := Vector3.FORWARD
			if i < points.size() - 1:
				dir = (points[i + 1] - points[i]).normalized()
			elif i > 0:
				dir = (points[i] - points[i - 1]).normalized()

			var right := dir.cross(Vector3.UP).normalized()
			if right.length_squared() < 0.01:
				right = Vector3.RIGHT

			var p := points[i]
			var barrier_pos: Vector3 = p + right * (half_road + offset_from_road) * side
			var base := verts.size()

			# Внешняя грань отбойника
			var inner_normal: Vector3 = -right * side
			verts.append(barrier_pos + Vector3(0, 0, 0))
			verts.append(barrier_pos + Vector3(0, barrier_height, 0))
			norms.append(inner_normal)
			norms.append(inner_normal)

			if i > 0:
				var prev := base - 2
				idx.append(prev)
				idx.append(base)
				idx.append(base + 1)
				idx.append(prev)
				idx.append(base + 1)
				idx.append(prev + 1)

		var mesh := ArrayMesh.new()
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = norms
		arrays[Mesh.ARRAY_INDEX] = idx
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(0, _barrier_material)

		var mesh_inst := MeshInstance3D.new()
		mesh_inst.mesh = mesh
		mesh_inst.name = "Barrier_" + ("L" if side < 0 else "R")
		add_child(mesh_inst)

		# Коллизия для отбойника
		_create_trimesh_collision(verts, idx, "BarrierCol_" + ("L" if side < 0 else "R"))


func _calc_track_length(points: PackedVector3Array) -> float:
	var length := 0.0
	for i in range(1, points.size()):
		length += points[i].distance_to(points[i - 1])
	return length
