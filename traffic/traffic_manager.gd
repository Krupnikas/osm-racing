extends Node
class_name TrafficManager

## Менеджер NPC-трафика
## Управляет spawning, despawning и жизненным циклом NPC машин

# Параметры spawning
const MAX_NPCS := 100  # Максимум машин одновременно (увеличено в 4 раза)
const SPAWN_DISTANCE := 200.0  # Радиус spawning от игрока
const DESPAWN_DISTANCE := 300.0  # Дистанция despawning
const MIN_SPAWN_SEPARATION := 35.0  # Мин. расстояние между NPC (было 20.0)
const NPCS_PER_CHUNK := 20  # Машин на чанк (увеличено в 4 раза)

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
const SPAWN_COOLDOWN_TIME := 1.0  # Spawn каждую секунду

# Debug визуализация
var debug_visualize := false  # Включить/выключить визуализацию waypoints
var waypoint_spheres: Array = []  # Визуальные маркеры waypoints
var npc_path_visuals: Dictionary = {}  # npc -> Array[MeshInstance3D] для визуализации путей
var npc_target_cubes: Dictionary = {}  # npc -> MeshInstance3D для визуализации целевой точки


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


func _input(event: InputEvent) -> void:
	# V key toggles waypoint visualization
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_V:
			toggle_waypoint_visualization()


func toggle_waypoint_visualization() -> void:
	"""Переключает визуализацию waypoints по нажатию V"""
	debug_visualize = not debug_visualize

	if debug_visualize:
		print("[TrafficManager] Waypoint visualization ON")
		# Визуализируем все загруженные чанки
		for chunk_key in spawned_positions.keys():
			visualize_waypoints_in_chunk(chunk_key)
	else:
		print("[TrafficManager] Waypoint visualization OFF")
		clear_waypoint_visualization()
		# Очищаем визуализацию путей NPC
		for npc in npc_path_visuals.keys().duplicate():
			_clear_npc_path_visual(npc)
		# Очищаем целевые кубики NPC
		for npc in npc_target_cubes.keys().duplicate():
			_clear_npc_target_cube(npc)


func _update_spawning() -> void:
	"""Обновляет spawning NPC машин"""
	if active_npcs.size() >= MAX_NPCS:
		return

	if not terrain_generator:
		return

	# Проверяем что terrain_generator это OSMTerrainGenerator
	if not terrain_generator is OSMTerrainGenerator:
		return

	var player_pos := _get_player_position()
	var loaded_chunks: Dictionary = terrain_generator._loaded_chunks

	if loaded_chunks.is_empty():
		return

	# Спавним несколько машин за раз для быстрого заполнения
	var spawns_this_frame := 0
	const MAX_SPAWNS_PER_FRAME := 3

	# Проходим по всем загруженным чанкам
	for chunk_key in loaded_chunks.keys():
		if active_npcs.size() >= MAX_NPCS:
			break
		if spawns_this_frame >= MAX_SPAWNS_PER_FRAME:
			break

		# Инициализируем tracking для чанка
		if not spawned_positions.has(chunk_key):
			spawned_positions[chunk_key] = []
			# Визуализируем waypoints в новом чанке
			if debug_visualize:
				visualize_waypoints_in_chunk(chunk_key)

		# Считаем реальное количество NPC в чанке (не по spawned_positions)
		var current_count := _count_npcs_in_chunk(chunk_key)
		if current_count < NPCS_PER_CHUNK:
			if _attempt_spawn_in_chunk(chunk_key, player_pos):
				spawns_this_frame += 1


func _attempt_spawn_in_chunk(chunk_key: String, player_pos: Vector3) -> bool:
	"""Пытается spawить NPC машину в чанке. Возвращает true если успешно."""
	# Получаем waypoints из road network
	var waypoints: Array = road_network.get_waypoints_in_chunk(chunk_key)
	if waypoints.is_empty():
		return false  # Нет waypoints в этом чанке

	# Фильтруем waypoints по дистанции от игрока
	var nearby_waypoints: Array = []
	for wp in waypoints:
		var dist: float = wp.position.distance_to(player_pos)
		if dist < SPAWN_DISTANCE and dist > 30.0:  # Не слишком близко
			nearby_waypoints.append(wp)

	if nearby_waypoints.is_empty():
		return false

	# Случайный waypoint для spawning
	var spawn_waypoint = nearby_waypoints[randi() % nearby_waypoints.size()]

	# Spawим NPC
	var npc: Node = _get_npc_from_pool()
	if not npc:
		return false

	# Случайный цвет
	npc.randomize_color()

	# Создаём путь - машина сама выберет полосу в set_path
	var path: Array = _build_path_from_waypoint(spawn_waypoint, 20)
	npc.set_path(path)

	# Вычисляем позицию спавна на выбранной машиной полосе
	var spawn_pos := _calculate_spawn_position_on_lane(spawn_waypoint, npc.chosen_lane)

	# Проверяем separation от других NPC
	if not _check_spawn_separation(spawn_pos):
		_return_npc_to_pool(npc)
		return false

	# Позиция на полосе и ориентация
	npc.global_position = spawn_pos
	# VehicleBody3D "вперёд" = -Z axis, direction(x,z) -> rotation_y
	npc.global_rotation.y = atan2(spawn_waypoint.direction.x, spawn_waypoint.direction.z)

	# Добавляем в списки
	active_npcs.append(npc)

	return true


func _count_npcs_in_chunk(chunk_key: String) -> int:
	"""Считает реальное количество NPC в чанке по их позициям"""
	# Используем тот же метод что и road_network для вычисления chunk_key
	var count := 0
	var parts := chunk_key.split(",")
	if parts.size() != 2:
		return 0

	var chunk_x := int(parts[0])
	var chunk_z := int(parts[1])
	const CHUNK_SIZE := 300.0

	for npc in active_npcs:
		var pos: Vector3 = npc.global_position
		var npc_chunk_x := int(floor(pos.x / CHUNK_SIZE))
		var npc_chunk_z := int(floor(pos.z / CHUNK_SIZE))
		if npc_chunk_x == chunk_x and npc_chunk_z == chunk_z:
			count += 1

	return count


func _calculate_spawn_position_on_lane(wp: Variant, lane: int) -> Vector3:
	"""Вычисляет позицию спавна на конкретной полосе"""
	# Логика как в NPCCar._calculate_lane_offset
	var lanes: int = wp.lanes_count if wp.lanes_count > 0 else 1
	var half_road: float = wp.width / 2.0
	var lane_width: float = half_road / lanes

	var effective_lane: int = min(lane, lanes - 1)
	var offset: float = half_road - lane_width * (0.5 + effective_lane)

	# Вычисляем вектор вправо (защита от нулевого direction)
	var dir_flat := Vector3(wp.direction.x, 0, wp.direction.z)
	if dir_flat.length_squared() < 0.0001:
		return wp.position
	var right_vector := Vector3(-dir_flat.z, 0, dir_flat.x).normalized()
	return wp.position + right_vector * offset


func _update_despawning() -> void:
	"""Удаляет далёкие NPC машины"""
	var player_pos := _get_player_position()

	# Итерируем в обратном порядке чтобы безопасно удалять элементы
	for i in range(active_npcs.size() - 1, -1, -1):
		var npc = active_npcs[i]
		var distance: float = npc.global_position.distance_to(player_pos)
		if distance > DESPAWN_DISTANCE:
			_return_npc_to_pool(npc)


func _check_spawn_separation(position: Vector3) -> bool:
	"""Проверяет минимальную дистанцию до других NPC"""
	# Используем distance_squared для оптимизации (избегаем sqrt)
	var min_dist_sq := MIN_SPAWN_SEPARATION * MIN_SPAWN_SEPARATION
	for npc in active_npcs:
		if npc.global_position.distance_squared_to(position) < min_dist_sq:
			return false
	return true


func _build_path_from_waypoint(start: Variant, count: int) -> Array:
	"""Строит путь из waypoints начиная с заданного"""
	var path := [start]
	var current = start

	for i in range(count - 1):
		if current.next_waypoints.is_empty():
			break

		# Выбираем следующий waypoint с приоритетом прямого направления
		var next = _choose_next_waypoint(current)
		if next == null:
			break

		# Защита от циклов - не добавляем waypoint если он уже в пути
		if next in path:
			break

		path.append(next)
		current = next

	return path


func _choose_next_waypoint(current: Variant) -> Variant:
	"""Выбирает следующий waypoint с приоритетом прямого направления.
	60% шанс ехать прямо, 40% шанс повернуть."""
	if current.next_waypoints.is_empty():
		return null

	if current.next_waypoints.size() == 1:
		return current.next_waypoints[0]

	# Находим waypoint с наиболее близким направлением (прямо)
	var straight_wp = null
	var best_dot := -INF
	var turn_candidates := []

	for wp in current.next_waypoints:
		var dir_dot: float = current.direction.dot(wp.direction)
		if dir_dot > best_dot:
			best_dot = dir_dot
			straight_wp = wp
		if dir_dot < 0.7:  # Это поворот
			turn_candidates.append(wp)

	# 60% шанс ехать прямо
	if randf() < 0.6 and straight_wp != null:
		return straight_wp

	# 40% шанс повернуть (если есть куда)
	if not turn_candidates.is_empty():
		return turn_candidates[randi() % turn_candidates.size()]

	# Fallback - едем прямо
	return straight_wp


func _get_npc_from_pool():
	"""Получает NPC из pool или создаёт новый"""
	if inactive_npcs.size() > 0:
		var npc = inactive_npcs.pop_back()
		npc.visible = true
		npc.process_mode = Node.PROCESS_MODE_INHERIT
		# Сигнал уже подключён при первом создании, не переподключаем
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

		var npc = scene_to_use.instantiate()
		get_parent().add_child(npc)
		# Подключаем сигнал despawn
		npc.request_despawn.connect(_on_npc_request_despawn.bind(npc))
		return npc

	return null


func _on_npc_request_despawn(npc) -> void:
	"""Обработчик запроса на despawn от NPC"""
	if npc in active_npcs:
		_return_npc_to_pool(npc)


func _return_npc_to_pool(npc) -> void:
	"""Возвращает NPC в pool"""
	# Убираем из активных
	active_npcs.erase(npc)

	# Очищаем визуализацию пути и целевого кубика сразу при возврате в pool
	_clear_npc_path_visual(npc)
	_clear_npc_target_cube(npc)

	# Убираем из spawn tracking
	# Примечание: машина могла уехать далеко от spawn точки,
	# поэтому удаляем одну позицию из чанка где машина была заспавнена
	# Это приблизительный подход - чанк с меньшим количеством NPC получит новый spawn
	for chunk_key in spawned_positions.keys():
		var positions: Array = spawned_positions[chunk_key]
		if positions.size() > 0:
			# Удаляем последнюю позицию (FIFO-подобное поведение)
			# Не идеально, но предотвращает утечку памяти
			var found := false
			for i in range(positions.size() - 1, -1, -1):
				if npc.global_position.distance_to(positions[i]) < 50.0:
					positions.remove_at(i)
					found = true
					break
			if found:
				break

	# Сбрасываем состояние
	npc.visible = false
	npc.process_mode = Node.PROCESS_MODE_DISABLED
	npc.linear_velocity = Vector3.ZERO
	npc.angular_velocity = Vector3.ZERO

	# Сбрасываем AI состояние
	npc.waypoint_path = []
	npc.current_waypoint_index = 0
	npc.chosen_lane = 0
	npc.target_speed = 30.0
	npc.ai_state = NPCCar.AIState.DRIVING
	npc.spawn_grace_timer = 0.0
	npc.update_timer = 0.0
	npc.stuck_timer = 0.0
	npc.off_road_timer = 0.0
	npc.steering_input = 0.0
	npc.throttle_input = 0.0
	npc.brake_input = 0.0
	# Выключаем освещение через метод (не просто флаг)
	if npc._lights_enabled:
		npc.disable_lights()

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
	"""Визуализирует waypoints в чанке
	Цвета:
	- Зелёный: нормальный waypoint с продолжением
	- Красный: ТУПИК (нет next_waypoints) - машины тут застрянут!
	- Жёлтый: waypoint с несколькими вариантами (перекрёсток)
	"""
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

		# Выбираем цвет в зависимости от количества связей
		if wp.next_waypoints.is_empty():
			# ТУПИК - красный, машины тут застрянут!
			material.albedo_color = Color(1, 0, 0, 0.8)
			mesh.radius = 1.2  # Увеличенный размер для видимости
			mesh.height = 2.4
		elif wp.next_waypoints.size() > 1:
			# Перекрёсток - жёлтый
			material.albedo_color = Color(1, 1, 0, 0.6)
		else:
			# Нормальный waypoint - зелёный
			material.albedo_color = Color(0, 1, 0, 0.6)

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
	# Очищаем старые визуализации для неактивных NPC
	# Копируем ключи чтобы избежать изменения словаря во время итерации
	var npcs_to_clear: Array = []
	for npc in npc_path_visuals.keys():
		if npc not in active_npcs:
			npcs_to_clear.append(npc)

	for npc in npcs_to_clear:
		_clear_npc_path_visual(npc)

	# Очищаем целевые кубики для неактивных NPC
	var cubes_to_clear: Array = []
	for npc in npc_target_cubes.keys():
		if npc not in active_npcs:
			cubes_to_clear.append(npc)

	for npc in cubes_to_clear:
		_clear_npc_target_cube(npc)

	# Создаём/обновляем визуализацию для активных NPC
	for npc in active_npcs:
		_visualize_npc_path(npc)
		_visualize_npc_target(npc)


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
	# Защита от нулевой длины
	if length < 0.01:
		length = 0.01

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

	# Защита от look_at с одинаковыми точками
	var target := to + Vector3(0, 3, 0)
	if midpoint.distance_to(target) > 0.01:
		arrow.look_at(target, Vector3.UP)
		arrow.rotate_object_local(Vector3.RIGHT, PI / 2)

	return arrow


func _get_npc_color(npc) -> Color:
	"""Получает цвет NPC машины"""
	# Пытаемся получить цвет из Chassis
	if npc.has_node("Chassis"):
		var chassis = npc.get_node("Chassis")
		if chassis.material_override and chassis.material_override is StandardMaterial3D:
			var mat: StandardMaterial3D = chassis.material_override
			var color: Color = mat.albedo_color
			color.a = 0.7  # Делаем полупрозрачным для визуализации
			return color
	return Color(1, 1, 0, 0.7)  # Fallback - жёлтый


func _clear_npc_path_visual(npc) -> void:
	"""Очищает визуализацию пути одной NPC"""
	if npc_path_visuals.has(npc):
		for visual in npc_path_visuals[npc]:
			visual.queue_free()
		npc_path_visuals.erase(npc)


func _visualize_npc_target(npc) -> void:
	"""Визуализирует целевую точку (lookahead point) NPC маленьким кубиком цвета машины"""
	# Получаем lookahead point из NPC (используем тот же метод что и AI)
	if not npc.has_method("_get_lookahead_point"):
		return

	# Адаптивный lookahead как в AI
	var speed_factor: float = clamp(npc.current_speed_kmh / 40.0, 0.0, 1.0)
	var lookahead_dist: float = lerp(8.0, 20.0, speed_factor)  # LOOKAHEAD_MIN, LOOKAHEAD_MAX
	var target_point: Vector3 = npc._get_lookahead_point(lookahead_dist)

	if target_point == Vector3.ZERO:
		_clear_npc_target_cube(npc)
		return

	var npc_color := _get_npc_color(npc)

	# Создаём или обновляем кубик
	var cube: MeshInstance3D
	if npc_target_cubes.has(npc):
		cube = npc_target_cubes[npc]
	else:
		cube = MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3(0.8, 0.8, 0.8)  # Маленький кубик
		cube.mesh = mesh

		var material := StandardMaterial3D.new()
		material.albedo_color = npc_color
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		cube.material_override = material

		get_parent().add_child(cube)
		npc_target_cubes[npc] = cube

	# Обновляем позицию кубика
	cube.global_position = target_point + Vector3(0, 1.5, 0)  # Немного над землёй


func _clear_npc_target_cube(npc) -> void:
	"""Очищает кубик целевой точки одной NPC"""
	if npc_target_cubes.has(npc):
		npc_target_cubes[npc].queue_free()
		npc_target_cubes.erase(npc)
