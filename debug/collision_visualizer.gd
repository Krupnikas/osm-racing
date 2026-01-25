extends Node

## Визуализация хитбоксов - включается/выключается клавишей H

var _enabled := false
var _debug_meshes: Array[MeshInstance3D] = []

func _ready() -> void:
	print("CollisionVisualizer: ready")

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_H:
		_enabled = not _enabled
		if _enabled:
			print("Collision visualization: ON")
			_create_debug_meshes()
		else:
			print("Collision visualization: OFF")
			_clear_debug_meshes()

func _create_debug_meshes() -> void:
	_clear_debug_meshes()

	# Ищем машину игрока (в группе "player" или "car")
	var player_car := get_tree().get_first_node_in_group("player")
	if not player_car:
		player_car = get_tree().get_first_node_in_group("car")

	if not player_car:
		print("CollisionVisualizer: Player car not found!")
		return

	print("CollisionVisualizer: Found player car: ", player_car.name)

	# Сканируем только машину игрока и её потомков
	_scan_node_for_collisions(player_car)

	print("CollisionVisualizer: Created %d debug meshes for player car" % _debug_meshes.size())

func _scan_node_for_collisions(node: Node) -> void:
	if node is CollisionShape3D:
		_create_debug_mesh_for_shape(node)

	for child in node.get_children():
		_scan_node_for_collisions(child)

func _create_debug_mesh_for_shape(collision_shape: CollisionShape3D) -> void:
	var shape := collision_shape.shape
	if not shape:
		print("CollisionVisualizer: CollisionShape3D '", collision_shape.name, "' has no shape!")
		return

	print("CollisionVisualizer: Creating debug mesh for ", collision_shape.name, " (", shape.get_class(), ")")

	var mesh_instance := MeshInstance3D.new()
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0, 1, 0, 0.5)  # Зелёный полупрозрачный (увеличил прозрачность)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED  # Видно с обеих сторон
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.disable_depth_test = true  # Видно сквозь объекты

	var debug_mesh: Mesh

	# Создаём mesh в зависимости от типа shape
	if shape is BoxShape3D:
		var box := BoxMesh.new()
		box.size = shape.size
		debug_mesh = box
		print("  -> BoxShape3D: size = ", shape.size)
	elif shape is SphereShape3D:
		var sphere := SphereMesh.new()
		sphere.radius = shape.radius
		sphere.height = shape.radius * 2
		debug_mesh = sphere
		print("  -> SphereShape3D: radius = ", shape.radius)
	elif shape is CapsuleShape3D:
		var capsule := CapsuleMesh.new()
		capsule.radius = shape.radius
		capsule.height = shape.height
		debug_mesh = capsule
		print("  -> CapsuleShape3D: radius = ", shape.radius, ", height = ", shape.height)
	elif shape is CylinderShape3D:
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = shape.radius
		cylinder.bottom_radius = shape.radius
		cylinder.height = shape.height
		debug_mesh = cylinder
		print("  -> CylinderShape3D: radius = ", shape.radius, ", height = ", shape.height)
	elif shape is ConvexPolygonShape3D:
		# Создаём mesh из точек ConvexPolygonShape3D
		var convex_shape := shape as ConvexPolygonShape3D
		var points := convex_shape.points
		if points.size() >= 4:
			# Создаём convex hull mesh из точек
			var array_mesh := ArrayMesh.new()
			var surface_tool := SurfaceTool.new()
			surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)

			# Генерируем треугольники для convex hull используя QuickHull подход
			# Для простоты используем встроенный метод - создаём mesh через ConvexPolygonShape3D
			var hull_mesh := _create_convex_hull_mesh(points)
			if hull_mesh:
				debug_mesh = hull_mesh
				print("  -> ConvexPolygonShape3D: created hull mesh from %d points" % points.size())
			else:
				# Fallback: вычисляем bounding box из точек
				var min_pt := points[0]
				var max_pt := points[0]
				for pt in points:
					min_pt.x = min(min_pt.x, pt.x)
					min_pt.y = min(min_pt.y, pt.y)
					min_pt.z = min(min_pt.z, pt.z)
					max_pt.x = max(max_pt.x, pt.x)
					max_pt.y = max(max_pt.y, pt.y)
					max_pt.z = max(max_pt.z, pt.z)
				var box := BoxMesh.new()
				box.size = max_pt - min_pt
				debug_mesh = box
				# Центрируем mesh
				mesh_instance.position = (min_pt + max_pt) / 2.0
				print("  -> ConvexPolygonShape3D: fallback to bounding box ", box.size)
		else:
			print("  -> ConvexPolygonShape3D: not enough points (%d)" % points.size())
			return
	else:
		# Неизвестный тип shape
		print("  -> Unknown shape type: ", shape.get_class())
		return

	mesh_instance.mesh = debug_mesh
	mesh_instance.material_override = material
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	# Добавляем mesh как потомка CollisionShape3D чтобы следовал за ним
	collision_shape.add_child(mesh_instance)
	_debug_meshes.append(mesh_instance)

	print("  -> Debug mesh added to ", collision_shape.name)

func _create_convex_hull_mesh(points: PackedVector3Array) -> Mesh:
	# Используем SurfaceTool для создания mesh из convex hull
	# Метод: создаём треугольники для каждой грани convex hull

	if points.size() < 4:
		return null

	# Вычисляем центр
	var center := Vector3.ZERO
	for pt in points:
		center += pt
	center /= points.size()

	# Используем ImmediateMesh для простоты визуализации
	var immediate_mesh := ImmediateMesh.new()
	immediate_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)

	# Строим треугольники соединяя каждую пару соседних точек с центром
	# Это упрощённый подход - создаём "звезду" из центра
	# Для более точного отображения нужен полноценный convex hull алгоритм

	# Сортируем точки и строим грани
	# Упрощённый подход: создаём треугольники для визуализации
	for i in range(points.size()):
		for j in range(i + 1, points.size()):
			for k in range(j + 1, points.size()):
				# Проверяем, является ли эта тройка точек внешней гранью
				var p1 := points[i]
				var p2 := points[j]
				var p3 := points[k]

				# Вычисляем нормаль
				var normal := (p2 - p1).cross(p3 - p1).normalized()
				if normal.length() < 0.001:
					continue

				# Проверяем, все ли остальные точки с одной стороны плоскости
				var plane := Plane(p1, p2, p3)
				var all_behind := true
				var all_front := true

				for l in range(points.size()):
					if l == i or l == j or l == k:
						continue
					var dist := plane.distance_to(points[l])
					if dist > 0.001:
						all_behind = false
					if dist < -0.001:
						all_front = false

				if all_behind or all_front:
					# Это внешняя грань
					if all_front:
						# Инвертируем порядок вершин
						immediate_mesh.surface_add_vertex(p1)
						immediate_mesh.surface_add_vertex(p3)
						immediate_mesh.surface_add_vertex(p2)
					else:
						immediate_mesh.surface_add_vertex(p1)
						immediate_mesh.surface_add_vertex(p2)
						immediate_mesh.surface_add_vertex(p3)

	immediate_mesh.surface_end()
	return immediate_mesh

func _clear_debug_meshes() -> void:
	for mesh in _debug_meshes:
		if is_instance_valid(mesh):
			mesh.queue_free()
	_debug_meshes.clear()

func _exit_tree() -> void:
	_clear_debug_meshes()
