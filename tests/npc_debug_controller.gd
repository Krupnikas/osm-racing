extends Node3D

## Отладочная сцена для наблюдения за поведением одной NPC машины
## Визуализирует waypoints, путь, направление движения и состояние AI

var RoadNetworkScript = preload("res://traffic/road_network.gd")
var road_network: Node
var npc_car: Node3D
var debug_label: Label
var camera: Camera3D

var elapsed_time := 0.0
var waypoint_spheres: Array = []
var path_lines: Array = []

func _ready() -> void:
	print("\n=== NPC Debug Scene Started ===")

	# Создаём road network
	road_network = RoadNetworkScript.new()
	add_child(road_network)

	# Создаём тестовую дорогу с поворотами
	_create_test_road_network()

	# Получаем ссылки
	npc_car = get_node("NPCCar")
	debug_label = get_node("CanvasLayer/DebugLabel")
	camera = get_node("Camera3D")

	# Устанавливаем путь для NPC
	await get_tree().process_frame
	var waypoints = road_network.all_waypoints
	if waypoints.size() > 0:
		npc_car.set_path(waypoints)
		npc_car.global_position = waypoints[0].position + Vector3(0, 1, 0)
		# VehicleBody3D "вперёд" = -Z, поэтому direction(x,z) -> rotation_y
		var dir = waypoints[0].direction
		npc_car.global_rotation.y = atan2(dir.x, dir.z)
		npc_car.randomize_color()
		print("NPC spawned at: ", npc_car.global_position)
		print("NPC direction: ", dir, " rotation.y: ", rad_to_deg(npc_car.global_rotation.y))

	# Визуализируем waypoints
	_visualize_waypoints()


func _create_test_road_network() -> void:
	"""Создаём тестовую дорожную сеть с прямыми участками и поворотами"""

	# Прямая дорога 1 (0, 0) -> (100, 0)
	var road1 = PackedVector2Array([
		Vector2(0, 0),
		Vector2(50, 0),
		Vector2(100, 0)
	])
	road_network.add_road_segment(road1, "primary", "0,0", {})

	# Поворот направо: (100, 0) -> (100, -50) -> (150, -50)
	var road2 = PackedVector2Array([
		Vector2(100, 0),
		Vector2(100, -25),
		Vector2(100, -50),
		Vector2(125, -50),
		Vector2(150, -50)
	])
	road_network.add_road_segment(road2, "primary", "0,0", {})

	# Поворот налево: (150, -50) -> (150, -100) -> (100, -100)
	var road3 = PackedVector2Array([
		Vector2(150, -50),
		Vector2(150, -75),
		Vector2(150, -100),
		Vector2(125, -100),
		Vector2(100, -100)
	])
	road_network.add_road_segment(road3, "secondary", "0,0", {})

	# Возврат: (100, -100) -> (0, -100)
	var road4 = PackedVector2Array([
		Vector2(100, -100),
		Vector2(50, -100),
		Vector2(0, -100)
	])
	road_network.add_road_segment(road4, "secondary", "0,0", {})

	# Замыкаем круг: (0, -100) -> (0, 0)
	var road5 = PackedVector2Array([
		Vector2(0, -100),
		Vector2(0, -50),
		Vector2(0, 0)
	])
	road_network.add_road_segment(road5, "primary", "0,0", {})

	print("Test road network created with %d waypoints" % road_network.all_waypoints.size())


func _visualize_waypoints() -> void:
	"""Визуализирует waypoints как сферы в 3D пространстве"""
	for wp in road_network.all_waypoints:
		var sphere = MeshInstance3D.new()
		var mesh = SphereMesh.new()
		mesh.radius = 0.5
		mesh.height = 1.0
		sphere.mesh = mesh

		var material = StandardMaterial3D.new()
		material.albedo_color = Color(0, 1, 0, 0.5)  # Зелёный полупрозрачный
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		sphere.material_override = material

		sphere.global_position = wp.position
		add_child(sphere)
		waypoint_spheres.append(sphere)

		# Рисуем стрелку направления
		var arrow = _create_direction_arrow(wp.position, wp.direction)
		add_child(arrow)


func _create_direction_arrow(pos: Vector3, dir: Vector3) -> MeshInstance3D:
	"""Создаёт стрелку для визуализации направления"""
	var arrow = MeshInstance3D.new()
	var mesh = CylinderMesh.new()
	mesh.top_radius = 0.1
	mesh.bottom_radius = 0.1
	mesh.height = 3.0
	arrow.mesh = mesh

	var material = StandardMaterial3D.new()
	material.albedo_color = Color(1, 0, 0, 0.7)  # Красный
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	arrow.material_override = material

	# Позиционируем и поворачиваем
	arrow.global_position = pos + Vector3(0, 0.5, 0)
	var forward_flat = Vector3(dir.x, 0, dir.z).normalized()
	arrow.look_at(pos + forward_flat * 5.0, Vector3.UP)
	arrow.rotate_object_local(Vector3.RIGHT, PI / 2)

	return arrow


func _process(delta: float) -> void:
	elapsed_time += delta

	# Обновляем позицию камеры, чтобы следовать за машиной
	if npc_car:
		var target_pos = npc_car.global_position + Vector3(0, 30, 40)
		camera.global_position = camera.global_position.lerp(target_pos, delta * 2.0)
		camera.look_at(npc_car.global_position, Vector3.UP)

	# Обновляем debug информацию
	_update_debug_label()

	# Визуализируем текущий путь
	_draw_current_path()

	# Логи каждую секунду
	if int(elapsed_time) != int(elapsed_time - delta):
		_log_npc_state()


func _update_debug_label() -> void:
	"""Обновляет отладочную информацию на экране"""
	if not npc_car or not debug_label:
		return

	var info := ""
	info += "=== NPC DEBUG INFO ===\n"
	info += "Time: %.1f sec\n\n" % elapsed_time

	info += "Position: (%.1f, %.1f, %.1f)\n" % [
		npc_car.global_position.x,
		npc_car.global_position.y,
		npc_car.global_position.z
	]

	info += "Speed: %.1f km/h\n" % npc_car.current_speed_kmh
	info += "Target Speed: %.1f km/h\n" % npc_car.target_speed

	var state_name := ""
	match npc_car.ai_state:
		0: state_name = "DRIVING"
		1: state_name = "STOPPED"
		2: state_name = "YIELDING"
	info += "AI State: %s\n\n" % state_name

	info += "Throttle: %.2f\n" % npc_car.throttle_input
	info += "Brake: %.2f\n" % npc_car.brake_input
	info += "Steering: %.2f\n\n" % npc_car.steering_input

	info += "Current Waypoint: %d / %d\n" % [
		npc_car.current_waypoint_index,
		npc_car.waypoint_path.size()
	]

	if npc_car.current_waypoint_index < npc_car.waypoint_path.size():
		var current_wp = npc_car.waypoint_path[npc_car.current_waypoint_index]
		var dist_to_wp = npc_car.global_position.distance_to(current_wp.position)
		info += "Distance to WP: %.1f m\n" % dist_to_wp

	# Проверяем препятствия
	var has_obstacle = npc_car._check_obstacle_ahead()
	info += "Obstacle Ahead: %s\n" % ("YES" if has_obstacle else "NO")

	info += "\nGrace Timer: %.2f\n" % npc_car.spawn_grace_timer

	# Turn sharpness
	var turn_sharpness = npc_car._get_turn_sharpness_ahead()
	info += "Turn Sharpness: %.2f\n" % turn_sharpness

	debug_label.text = info


func _draw_current_path() -> void:
	"""Рисует линию текущего пути NPC"""
	# Очищаем старые линии
	for line in path_lines:
		line.queue_free()
	path_lines.clear()

	if not npc_car or npc_car.waypoint_path.is_empty():
		return

	# Рисуем путь от текущего waypoint
	for i in range(npc_car.current_waypoint_index, min(npc_car.current_waypoint_index + 10, npc_car.waypoint_path.size() - 1)):
		var wp1 = npc_car.waypoint_path[i]
		var wp2 = npc_car.waypoint_path[i + 1]

		var line = _create_line(wp1.position, wp2.position, Color(0, 0, 1, 0.8))
		add_child(line)
		path_lines.append(line)


func _create_line(from: Vector3, to: Vector3, color: Color) -> MeshInstance3D:
	"""Создаёт цилиндр в качестве линии между двумя точками"""
	var line = MeshInstance3D.new()
	var mesh = CylinderMesh.new()

	var length = from.distance_to(to)
	mesh.top_radius = 0.3
	mesh.bottom_radius = 0.3
	mesh.height = length

	line.mesh = mesh

	var material = StandardMaterial3D.new()
	material.albedo_color = color
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	line.material_override = material

	# Позиционируем и поворачиваем
	var midpoint = (from + to) / 2.0
	line.global_position = midpoint
	line.look_at(to, Vector3.UP)
	line.rotate_object_local(Vector3.RIGHT, PI / 2)

	return line


func _log_npc_state() -> void:
	"""Выводит состояние NPC в консоль каждую секунду"""
	if not npc_car:
		return

	var state_name := ""
	match npc_car.ai_state:
		0: state_name = "DRIVING"
		1: state_name = "STOPPED"
		2: state_name = "YIELDING"

	print("[%.1fs] Pos:(%.1f,%.1f,%.1f) Speed:%.1f State:%s WP:%d/%d Throttle:%.2f Steering:%.2f" % [
		elapsed_time,
		npc_car.global_position.x,
		npc_car.global_position.y,
		npc_car.global_position.z,
		npc_car.current_speed_kmh,
		state_name,
		npc_car.current_waypoint_index,
		npc_car.waypoint_path.size(),
		npc_car.throttle_input,
		npc_car.steering_input
	])


func _input(event: InputEvent) -> void:
	"""Обработка ввода для управления отладкой"""
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_ESCAPE:
			print("\n=== Debug Session Ended at %.1f sec ===" % elapsed_time)
			get_tree().quit()
		elif event.keycode == KEY_R:
			# Перезапуск
			get_tree().reload_current_scene()
		elif event.keycode == KEY_SPACE:
			# Пауза/возобновление
			get_tree().paused = not get_tree().paused
			print("Paused" if get_tree().paused else "Resumed")
