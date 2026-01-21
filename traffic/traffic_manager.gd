extends Node
class_name TrafficManager

## Менеджер NPC-трафика
## Управляет spawning, despawning и жизненным циклом NPC машин

# Параметры spawning
const MAX_NPCS := 50  # Максимум машин одновременно (было 40)
const SPAWN_DISTANCE := 200.0  # Радиус spawning от игрока
const DESPAWN_DISTANCE := 300.0  # Дистанция despawning
const MIN_SPAWN_SEPARATION := 35.0  # Мин. расстояние между NPC (было 20.0)
const NPCS_PER_CHUNK := 4  # Машин на чанк (увеличено для большей загруженности)

# Ссылки
var npc_car_scene: PackedScene
var npc_paz_scene: PackedScene
var npc_lada_scene: PackedScene
var npc_taxi_scene: PackedScene
var npc_vaz2107_scene: PackedScene
var road_network: Node  # RoadNetwork
var terrain_generator: Node  # OSMTerrainGenerator
var player_car: Node3D

# Object pooling
var active_npcs: Array = []  # Array[NPCCar]
var inactive_npcs: Array = []  # Array[NPCCar]

# Spawn tracking
var spawned_positions: Dictionary = {}  # chunk_key -> Array[Vector3]
var spawn_cooldown := 0.0  # Задержка между spawns
const SPAWN_COOLDOWN_TIME := 1.0  # Spawn каждую секунду максимум

# Debug визуализация
var debug_visualize := false  # Включить/выключить визуализацию waypoints (отключено для производительности)
var waypoint_spheres: Array = []  # Визуальные маркеры waypoints
var npc_path_visuals: Dictionary = {}  # npc -> Array[MeshInstance3D] для визуализации путей


func _ready() -> void:
	# Загружаем сцены NPC машин
	npc_car_scene = preload("res://traffic/npc_car.tscn")
	npc_paz_scene = preload("res://traffic/npc_paz.tscn")
	npc_lada_scene = preload("res://traffic/npc_lada_2109.tscn")
	npc_taxi_scene = preload("res://traffic/npc_taxi.tscn")
	npc_vaz2107_scene = preload("res://traffic/npc_vaz_2107.tscn")

	# Создаём RoadNetwork
	var RoadNetworkScript = preload("res://traffic/road_network.gd")
	road_network = RoadNetworkScript.new()
	add_child(road_network)

	# Ищем terrain generator
	await get_tree().process_frame
	terrain_generator = get_node_or_null("../OSMTerrain")
	if not terrain_generator:
		push_error("TrafficManager: OSMTerrain not found!")
		return

	# Ищем player car
	player_car = get_tree().get_first_node_in_group("car")
	if not player_car:
		push_warning("TrafficManager: Player car not found in group 'car'")

	print("TrafficManager: Initialized (max %d NPCs)" % MAX_NPCS)


func _process(delta: float) -> void:
	spawn_cooldown -= delta

	if spawn_cooldown <= 0.0:
		_update_spawning()
		spawn_cooldown = SPAWN_COOLDOWN_TIME

	_update_despawning()

	# Обновляем визуализацию путей NPC
	if debug_visualize:
		_update_npc_path_visualization()


func _update_spawning() -> void:
	"""Обновляет spawning NPC машин"""
	if active_npcs.size() >= MAX_NPCS:
		return

	if not terrain_generator:
		return

	var player_pos := _get_player_position()
	var loaded_chunks: Dictionary = terrain_generator._loaded_chunks

	if loaded_chunks.is_empty():
		return

	# Проходим по всем загруженным чанкам
	for chunk_key in loaded_chunks.keys():
		if active_npcs.size() >= MAX_NPCS:
			break

		# Инициализируем tracking для чанка
		if not spawned_positions.has(chunk_key):
			spawned_positions[chunk_key] = []
			# Визуализируем waypoints в новом чанке
			if debug_visualize:
				visualize_waypoints_in_chunk(chunk_key)

		# Проверяем сколько уже заспавнено в этом чанке
		var current_count: int = spawned_positions[chunk_key].size()
		if current_count < NPCS_PER_CHUNK:
			_attempt_spawn_in_chunk(chunk_key, player_pos)


func _attempt_spawn_in_chunk(chunk_key: String, player_pos: Vector3) -> void:
	"""Пытается spawить NPC машину в чанке"""
	# Получаем waypoints из road network
	var waypoints: Array = road_network.get_waypoints_in_chunk(chunk_key)
	if waypoints.is_empty():
		print("TrafficManager: No waypoints in chunk %s" % chunk_key)
		return

	print("TrafficManager: Attempting spawn in chunk %s (has %d waypoints)" % [chunk_key, waypoints.size()])

	# Фильтруем waypoints по дистанции от игрока
	var nearby_waypoints: Array = []
	for wp in waypoints:
		var dist: float = wp.position.distance_to(player_pos)
		if dist < SPAWN_DISTANCE and dist > 30.0:  # Не слишком близко
			nearby_waypoints.append(wp)

	if nearby_waypoints.is_empty():
		return

	# Случайный waypoint для spawning
	var spawn_waypoint = nearby_waypoints[randi() % nearby_waypoints.size()]

	# Проверяем separation от других NPC
	if not _check_spawn_separation(spawn_waypoint.position):
		return

	# Spawим NPC
	var npc: Node = _get_npc_from_pool()
	if not npc:
		return

	# Позиция и ориентация
	npc.global_position = spawn_waypoint.position
	# VehicleBody3D "вперёд" = -Z axis, direction(x,z) -> rotation_y
	npc.global_rotation.y = atan2(spawn_waypoint.direction.x, spawn_waypoint.direction.z)

	# Случайный цвет
	npc.randomize_color()

	# Создаём путь
	var path: Array = _build_path_from_waypoint(spawn_waypoint, 20)
	npc.set_path(path)

	# Добавляем в списки
	active_npcs.append(npc)
	spawned_positions[chunk_key].append(spawn_waypoint.position)

	print("TrafficManager: Spawned NPC at %s in chunk %s (total active: %d)" % [npc.global_position, chunk_key, active_npcs.size()])


func _update_despawning() -> void:
	"""Удаляет далёкие NPC машины"""
	var player_pos := _get_player_position()

	for npc in active_npcs.duplicate():
		var distance: float = npc.global_position.distance_to(player_pos)
		if distance > DESPAWN_DISTANCE:
			_return_npc_to_pool(npc)


func _check_spawn_separation(position: Vector3) -> bool:
	"""Проверяет минимальную дистанцию до других NPC"""
	for npc in active_npcs:
		if npc.global_position.distance_to(position) < MIN_SPAWN_SEPARATION:
			return false
	return true


func _build_path_from_waypoint(start, count: int) -> Array:
	"""Строит путь из waypoints начиная с заданного"""
	var path := [start]
	var current = start

	for i in range(count - 1):
		if current.next_waypoints.is_empty():
			break

		# Выбираем следующий waypoint
		# 60% шанс продолжить прямо, 40% повернуть
		var next
		if current.next_waypoints.size() == 1:
			next = current.next_waypoints[0]
		else:
			var rand := randf()
			if rand < 0.6:
				# Прямо - берём первый (обычно продолжение дороги)
				next = current.next_waypoints[0]
			else:
				# Поворот - случайный из доступных
				next = current.next_waypoints[randi() % current.next_waypoints.size()]

		path.append(next)
		current = next

	return path


func _get_npc_from_pool():
	"""Получает NPC из pool или создаёт новый"""
	if inactive_npcs.size() > 0:
		var npc = inactive_npcs.pop_back()
		npc.visible = true
		npc.process_mode = Node.PROCESS_MODE_INHERIT
		return npc

	if active_npcs.size() < MAX_NPCS:
		# Распределение: 5% Lada 2109 DPS, 15% Такси, 15% ПАЗ, 25% ВАЗ-2107, 40% блочные
		var rand := randf()
		var scene_to_use: PackedScene
		var car_type: String

		if rand < 0.05:
			# 5% - Lada 2109 DPS
			scene_to_use = npc_lada_scene
			car_type = "Lada 2109 DPS"
		elif rand < 0.20:
			# 15% - Такси
			scene_to_use = npc_taxi_scene
			car_type = "Taxi"
		elif rand < 0.35:
			# 15% - ПАЗ
			scene_to_use = npc_paz_scene
			car_type = "PAZ bus"
		elif rand < 0.60:
			# 25% - ВАЗ-2107
			scene_to_use = npc_vaz2107_scene
			car_type = "VAZ-2107"
		else:
			# 40% - блочные машинки
			scene_to_use = npc_car_scene
			car_type = "box car"

		print("TrafficManager: Spawning %s" % car_type)

		var npc = scene_to_use.instantiate()
		get_parent().add_child(npc)
		return npc

	return null


func _return_npc_to_pool(npc) -> void:
	"""Возвращает NPC в pool"""
	# Убираем из активных
	active_npcs.erase(npc)

	# Убираем из spawn tracking
	for chunk_key in spawned_positions.keys():
		var positions: Array = spawned_positions[chunk_key]
		# Находим и удаляем позицию этой машины
		for i in range(positions.size() - 1, -1, -1):
			if npc.global_position.distance_to(positions[i]) < 5.0:
				positions.remove_at(i)

	# Сбрасываем состояние
	npc.visible = false
	npc.process_mode = Node.PROCESS_MODE_DISABLED
	npc.linear_velocity = Vector3.ZERO
	npc.angular_velocity = Vector3.ZERO

	# Добавляем в pool
	inactive_npcs.append(npc)

	#print("TrafficManager: Despawned NPC (%d active)" % active_npcs.size())


func _get_player_position() -> Vector3:
	"""Получает позицию игрока для spawning"""
	if player_car:
		return player_car.global_position

	# Fallback - используем камеру
	var viewport := get_viewport()
	if viewport:
		var camera := viewport.get_camera_3d()
		if camera:
			return camera.global_position

	return Vector3.ZERO


func get_road_network():
	"""Возвращает RoadNetwork для OSMTerrainGenerator"""
	return road_network


func clear_chunk(chunk_key: String) -> void:
	"""Очищает NPC из выгруженного чанка"""
	# Удаляем waypoints
	if road_network:
		road_network.clear_chunk(chunk_key)

	# Удаляем spawn tracking
	spawned_positions.erase(chunk_key)

	# Очищаем визуализацию (для всех чанков, упрощённо)
	# В будущем можно трекать spheres по чанкам отдельно
	if debug_visualize and waypoint_spheres.size() > 1000:  # Ограничиваем количество
		clear_waypoint_visualization()

	# Despawn NPCs в этом чанке (они будут удалены distance check'ом)


func get_debug_info() -> String:
	"""Возвращает отладочную информацию"""
	var info := "Traffic: %d/%d NPCs active, %d in pool" % [active_npcs.size(), MAX_NPCS, inactive_npcs.size()]
	if road_network:
		info += "\n" + road_network.get_debug_info()
	return info


func visualize_waypoints_in_chunk(chunk_key: String) -> void:
	"""Визуализирует waypoints в чанке"""
	if not debug_visualize:
		return

	var waypoints: Array = road_network.get_waypoints_in_chunk(chunk_key)
	if waypoints.is_empty():
		return

	for wp in waypoints:
		var sphere := MeshInstance3D.new()
		var mesh := SphereMesh.new()
		mesh.radius = 0.8
		mesh.height = 1.6
		sphere.mesh = mesh

		var material := StandardMaterial3D.new()
		material.albedo_color = Color(0, 1, 0, 0.6)  # Зелёный полупрозрачный
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		sphere.material_override = material

		sphere.global_position = wp.position + Vector3(0, 2, 0)  # Поднимаем над дорогой
		get_parent().add_child(sphere)
		waypoint_spheres.append(sphere)


func clear_waypoint_visualization() -> void:
	"""Очищает визуализацию waypoints"""
	for sphere in waypoint_spheres:
		sphere.queue_free()
	waypoint_spheres.clear()


func _update_npc_path_visualization() -> void:
	"""Обновляет визуализацию путей всех активных NPC"""
	# Очищаем старые визуализации
	for npc in npc_path_visuals.keys():
		if npc not in active_npcs:
			_clear_npc_path_visual(npc)

	# Создаём/обновляем визуализацию для активных NPC
	for npc in active_npcs:
		_visualize_npc_path(npc)


func _visualize_npc_path(npc) -> void:
	"""Визуализирует путь конкретной NPC машины"""
	# Очищаем старую визуализацию
	_clear_npc_path_visual(npc)

	if npc.waypoint_path.is_empty():
		return

	# Получаем цвет машины
	var npc_color := _get_npc_color(npc)
	var visuals := []

	# Рисуем следующие 10 waypoints от текущей позиции
	var start_idx: int = npc.current_waypoint_index
	var end_idx: int = min(start_idx + 10, npc.waypoint_path.size())

	for i in range(start_idx, end_idx):
		var wp = npc.waypoint_path[i]

		# Создаём сферу для waypoint
		var sphere := MeshInstance3D.new()
		var mesh := SphereMesh.new()
		mesh.radius = 1.2
		mesh.height = 2.4
		sphere.mesh = mesh

		var material := StandardMaterial3D.new()
		material.albedo_color = npc_color
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		sphere.material_override = material

		sphere.global_position = wp.position + Vector3(0, 3, 0)
		get_parent().add_child(sphere)
		visuals.append(sphere)

		# Создаём стрелку направления
		if i < end_idx - 1:
			var next_wp = npc.waypoint_path[i + 1]
			var arrow := _create_arrow(wp.position, next_wp.position, npc_color)
			get_parent().add_child(arrow)
			visuals.append(arrow)

	npc_path_visuals[npc] = visuals


func _create_arrow(from: Vector3, to: Vector3, color: Color) -> MeshInstance3D:
	"""Создаёт стрелку между двумя точками"""
	var arrow := MeshInstance3D.new()
	var mesh := CylinderMesh.new()

	var length := from.distance_to(to)
	mesh.top_radius = 0.3
	mesh.bottom_radius = 0.3
	mesh.height = length

	arrow.mesh = mesh

	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	arrow.material_override = material

	# Позиционируем и поворачиваем
	var midpoint := (from + to) / 2.0 + Vector3(0, 3, 0)
	arrow.global_position = midpoint
	arrow.look_at(to + Vector3(0, 3, 0), Vector3.UP)
	arrow.rotate_object_local(Vector3.RIGHT, PI / 2)

	return arrow


func _get_npc_color(npc) -> Color:
	"""Получает цвет NPC машины"""
	# Пытаемся получить цвет из Chassis
	if npc.has_node("Chassis"):
		var chassis = npc.get_node("Chassis")
		if chassis.material_override:
			return chassis.material_override.albedo_color
	return Color(1, 1, 0, 0.7)  # Fallback - жёлтый


func _clear_npc_path_visual(npc) -> void:
	"""Очищает визуализацию пути одной NPC"""
	if npc_path_visuals.has(npc):
		for visual in npc_path_visuals[npc]:
			visual.queue_free()
		npc_path_visuals.erase(npc)
