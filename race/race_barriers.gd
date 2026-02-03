extends Node3D
class_name RaceBarriers

const BARRIER_OFFSET := 7.0
const BARRIER_HEIGHT := 2.5
const BARRIER_THICKNESS := 0.1
const ARROW_SPACING := 30.0
const ARROW_SIZE := 1.5

# Цвета барьеров для дня/ночи
const DAY_BARRIER_COLOR := Color(0.0, 0.0, 0.0, 0.15)  # 15% чёрный
const NIGHT_BARRIER_COLOR := Color(1.0, 1.0, 1.0, 0.01)  # 1% белый

var _barrier_material: StandardMaterial3D
var _night_mode_manager: Node
var _arrow_material: StandardMaterial3D
var _left_container: Node3D
var _right_container: Node3D
var _arrows_container: Node3D


var _barriers_visible := true


func _ready() -> void:
	_setup_materials()
	_setup_containers()
	_connect_night_mode()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_G:
			toggle_visibility()


func toggle_visibility() -> void:
	_barriers_visible = not _barriers_visible
	if _left_container:
		_left_container.visible = _barriers_visible
	if _right_container:
		_right_container.visible = _barriers_visible
	if _arrows_container:
		_arrows_container.visible = _barriers_visible
	print("Race barriers: ", "visible" if _barriers_visible else "hidden")


func _connect_night_mode() -> void:
	# Ищем NightModeManager
	_night_mode_manager = get_tree().current_scene.find_child("NightModeManager", true, false)
	if _night_mode_manager:
		_night_mode_manager.night_mode_changed.connect(_on_night_mode_changed)
		# Устанавливаем начальный цвет
		_on_night_mode_changed(_night_mode_manager.is_night)


func _on_night_mode_changed(is_night: bool) -> void:
	if _barrier_material:
		_barrier_material.albedo_color = NIGHT_BARRIER_COLOR if is_night else DAY_BARRIER_COLOR


func _setup_materials() -> void:
	_barrier_material = StandardMaterial3D.new()
	_barrier_material.albedo_color = NIGHT_BARRIER_COLOR  # По умолчанию ночной (игра стартует ночью)
	_barrier_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_barrier_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_barrier_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	_arrow_material = StandardMaterial3D.new()
	_arrow_material.albedo_color = Color(1.0, 0.2, 0.2, 0.5)
	_arrow_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_arrow_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_arrow_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED


func _setup_containers() -> void:
	_left_container = Node3D.new()
	_left_container.name = "LeftBarriers"
	add_child(_left_container)

	_right_container = Node3D.new()
	_right_container.name = "RightBarriers"
	add_child(_right_container)

	_arrows_container = Node3D.new()
	_arrows_container.name = "Arrows"
	add_child(_arrows_container)


func build_barriers(route_points: Array) -> void:
	# Убедимся что контейнеры созданы (на случай если вызвано до _ready)
	if _left_container == null:
		_setup_materials()
		_setup_containers()

	clear_barriers()
	if route_points.size() < 2:
		return

	# Вычисляем смещённые точки для левой и правой стены
	var left_points: Array[Vector3] = []
	var right_points: Array[Vector3] = []

	for i in range(route_points.size()):
		var point: Vector3 = route_points[i]

		# Вычисляем усреднённое направление "вперёд" в этой точке
		var forward := Vector3.ZERO

		if i > 0:
			var dir_from_prev: Vector3 = point - route_points[i - 1]
			dir_from_prev.y = 0
			forward += dir_from_prev.normalized()

		if i < route_points.size() - 1:
			var dir_to_next: Vector3 = route_points[i + 1] - point
			dir_to_next.y = 0
			forward += dir_to_next.normalized()

		forward = forward.normalized()

		# Вектор "вправо" (перпендикуляр)
		var right := forward.cross(Vector3.UP).normalized()

		# Смещённые точки
		var left_pt := point + (-right * BARRIER_OFFSET)
		var right_pt := point + (right * BARRIER_OFFSET)

		left_points.append(left_pt)
		right_points.append(right_pt)

	# Создаём сегменты стен
	for i in range(left_points.size() - 1):
		_create_wall_segment(left_points[i], left_points[i + 1], _left_container)
		_create_wall_segment(right_points[i], right_points[i + 1], _right_container)

	# Создаём стрелки вдоль маршрута
	var accumulated_distance := 0.0
	for i in range(route_points.size() - 1):
		var point_a: Vector3 = route_points[i]
		var point_b: Vector3 = route_points[i + 1]
		var seg_length := point_a.distance_to(point_b)
		var forward := (point_b - point_a)
		forward.y = 0
		forward = forward.normalized()

		while accumulated_distance < seg_length:
			var t := accumulated_distance / seg_length
			var arrow_pos := point_a.lerp(point_b, t)
			_create_arrow(arrow_pos, forward)
			accumulated_distance += ARROW_SPACING
		accumulated_distance -= seg_length


func _create_wall_segment(start: Vector3, end_pt: Vector3, container: Node3D) -> void:
	var dir := end_pt - start
	dir.y = 0
	if dir.length_squared() < 0.01:
		return

	var forward := dir.normalized()
	var length := start.distance_to(end_pt)

	var mesh_instance := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(BARRIER_THICKNESS, BARRIER_HEIGHT, length)
	mesh_instance.mesh = box
	mesh_instance.material_override = _barrier_material

	var center := (start + end_pt) / 2.0
	center.y += BARRIER_HEIGHT / 2.0

	# Создаём трансформ напрямую
	var transform := Transform3D()
	transform.origin = center

	# Базис: Z вдоль сегмента, Y вверх
	var z_axis := forward
	var y_axis := Vector3.UP
	var x_axis := y_axis.cross(z_axis).normalized()

	transform.basis = Basis(x_axis, y_axis, z_axis)
	mesh_instance.transform = transform

	container.add_child(mesh_instance)


func _create_arrow(pos: Vector3, forward: Vector3) -> void:
	var right := forward.cross(Vector3.UP).normalized()

	for is_left in [true, false]:
		var offset := right * BARRIER_OFFSET * (-1.0 if is_left else 1.0)
		var arrow_pos := pos + offset
		arrow_pos.y += BARRIER_HEIGHT / 2.0

		var mesh_instance := MeshInstance3D.new()
		var prism := PrismMesh.new()
		prism.size = Vector3(ARROW_SIZE * 0.6, ARROW_SIZE, 0.05)
		mesh_instance.mesh = prism
		mesh_instance.material_override = _arrow_material

		# Строим базис так, чтобы стрелка была в плоскости стены:
		# - Y (кончик призмы) указывает вперёд по маршруту
		# - Z (нормаль плоской грани) указывает внутрь коридора
		var inward := right if is_left else -right
		var y_axis := forward
		var z_axis := inward
		var x_axis := y_axis.cross(z_axis).normalized()

		var arrow_transform := Transform3D()
		arrow_transform.origin = arrow_pos
		arrow_transform.basis = Basis(x_axis, y_axis, z_axis)
		mesh_instance.transform = arrow_transform

		_arrows_container.add_child(mesh_instance)


func clear_barriers() -> void:
	if _left_container == null:
		return
	for child in _left_container.get_children():
		child.queue_free()
	for child in _right_container.get_children():
		child.queue_free()
	for child in _arrows_container.get_children():
		child.queue_free()
