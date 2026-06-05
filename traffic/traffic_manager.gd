extends Node
class_name TrafficManager

## Менеджер NPC-трафика
## Управляет spawning, despawning и жизненным циклом NPC машин

# Параметры spawning
var max_npcs := 30  # Максимум машин одновременно
var spawn_distance := 200.0  # Радиус spawning от игрока
var despawn_distance := 300.0  # Дистанция despawning
var min_spawn_separation := 15.0  # Мин. расстояние между NPC
var npcs_per_chunk := 4  # Машин на чанк

# Ссылки
var npc_car_scene: PackedScene
var npc_paz_scene: PackedScene
var npc_lada_scene: PackedScene
var npc_taxi_scene: PackedScene
var npc_vaz2107_scene: PackedScene
var npc_polo_scene: PackedScene
var npc_matiz_scene: PackedScene
var npc_logan_scene: PackedScene
var npc_focus_scene: PackedScene
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

# Диагностика и профилирование
var _profiler: Node = null
var _log_timer: float = 0.0
const LOG_INTERVAL := 2.0  # Логировать каждые 2 секунды


func _ready() -> void:
	# Загружаем сцены NPC машин
	npc_car_scene = preload("res://traffic/npc_car.tscn")
	npc_paz_scene = preload("res://traffic/npc_paz.tscn")
	npc_lada_scene = preload("res://traffic/npc_lada_2109.tscn")
	npc_taxi_scene = preload("res://traffic/npc_taxi.tscn")
	npc_vaz2107_scene = preload("res://traffic/npc_vaz_2107.tscn")
	npc_polo_scene = preload("res://traffic/npc_polo.tscn")
	npc_matiz_scene = preload("res://traffic/npc_matiz.tscn")
	npc_logan_scene = preload("res://traffic/npc_logan.tscn")
	npc_focus_scene = preload("res://traffic/npc_ford_focus_st.tscn")

	# Создаём RoadNetwork
	var RoadNetworkScript = preload("res://traffic/road_network.gd")
	road_network = RoadNetworkScript.new()
	add_child(road_network)

	# Создаём TramManager
	var TramManagerScript = preload("res://traffic/tram_manager.gd")
	var tram_mgr = TramManagerScript.new()
	tram_mgr.name = "TramManager"
	add_child(tram_mgr)

	# Ищем terrain generator
	await get_tree().process_frame
	terrain_generator = get_node_or_null("../OSMTerrain")
	if not terrain_generator:
		push_error("TrafficManager: OSMTerrain not found!")
		return

	# Передаём terrain generator в road_network для корректных высот waypoints
	road_network.terrain_generator = terrain_generator

	# Ищем player car
	player_car = get_tree().get_first_node_in_group("car")
	if not player_car:
		push_warning("TrafficManager: Player car not found in group 'car'")

	# Загрузить профайлер для диагностики
	var profiler_script = load("res://debug/performance_profiler.gd")
	if profiler_script:
		_profiler = profiler_script.new()
		_profiler.print_interval = 5.0
		add_child(_profiler)
		print("[TrafficManager] Profiler created for diagnostics")

	# Прогреваем кэш mesh merge — инстанцируем по 1 NPC каждого типа,
	# чтобы _merge_meshes() отработал до начала езды (иначе фриз при первом спавне)
	_warmup_mesh_cache()

	print("TrafficManager: Initialized (max %d NPCs)" % max_npcs)


func _warmup_mesh_cache() -> void:
	var t0 := Time.get_ticks_msec()
	var scenes: Array[PackedScene] = []
	if npc_car_scene: scenes.append(npc_car_scene)
	if npc_paz_scene: scenes.append(npc_paz_scene)
	if npc_lada_scene: scenes.append(npc_lada_scene)
	if npc_taxi_scene: scenes.append(npc_taxi_scene)
	if npc_vaz2107_scene: scenes.append(npc_vaz2107_scene)
	if npc_polo_scene: scenes.append(npc_polo_scene)
	if npc_matiz_scene: scenes.append(npc_matiz_scene)
	if npc_logan_scene: scenes.append(npc_logan_scene)
	if npc_focus_scene: scenes.append(npc_focus_scene)
	for scene in scenes:
		var instance := scene.instantiate() as Node3D
		instance.visible = false
		add_child(instance)  # triggers _ready() → _merge_meshes() → кэш заполнится
		instance.queue_free()
	print("TrafficManager: Mesh cache warmed up (%d types, %d ms)" % [scenes.size(), Time.get_ticks_msec() - t0])


func _process(delta: float) -> void:
	spawn_cooldown -= delta

	if spawn_cooldown <= 0.0:
		_update_spawning()
		spawn_cooldown = SPAWN_COOLDOWN_TIME

	_update_despawning()

	# Порционное соединение перекрёстков — 2ms бюджет на кадр
	if road_network and road_network.has_method("process_pending_connections"):
		road_network.process_pending_connections(2000)

	# Обновляем визуализацию путей NPC
	if debug_visualize:
		_update_npc_path_visualization()

	# Логировать статистику NPC каждые 2 секунды
	_log_timer += delta
	if _log_timer >= LOG_INTERVAL:
		_log_timer = 0.0
		_log_npc_statistics()


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
	if active_npcs.size() >= max_npcs:
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

	# Проходим по всем полностью загруженным чанкам
	for chunk_key in loaded_chunks.keys():
		if active_npcs.size() >= max_npcs:
			break
		if spawns_this_frame >= MAX_SPAWNS_PER_FRAME:
			break
		# Спавним только в полностью финализированных чанках
		if not terrain_generator.is_chunk_fully_ready(chunk_key):
			continue

		# Инициализируем tracking для чанка
		if not spawned_positions.has(chunk_key):
			spawned_positions[chunk_key] = []
			# Визуализируем waypoints в новом чанке
			if debug_visualize:
				visualize_waypoints_in_chunk(chunk_key)

		# Считаем реальное количество NPC в чанке (не по spawned_positions)
		var current_count := _count_npcs_in_chunk(chunk_key)
		if current_count < npcs_per_chunk:
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
		if dist < spawn_distance and dist > 30.0:  # Не слишком близко
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

	# Рейкаст для реальной высоты поверхности (попадёт в мост или землю)
	spawn_pos.y = _raycast_ground_y(spawn_pos)

	# Позиция на полосе и ориентация
	npc.global_position = spawn_pos
	# VehicleBody3D "вперёд" = -Z axis, direction(x,z) -> rotation_y
	npc.global_rotation.y = atan2(spawn_waypoint.direction.x, spawn_waypoint.direction.z)

	# Добавляем в списки
	active_npcs.append(npc)

	print("[NPC Spawn] chunk=%s bridge=%s pos=(%.1f, %.1f, %.1f) wp_y=%.1f" % [
		chunk_key, spawn_waypoint.is_bridge, spawn_pos.x, spawn_pos.y, spawn_pos.z,
		spawn_waypoint.position.y])

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
	var lanes: int = wp.lanes_count if wp.lanes_count > 0 else 1
	var effective_lane: int = min(lane, lanes - 1)

	var offset: float
	if wp.is_oneway:
		var lane_w: float = wp.width / float(lanes)
		offset = wp.width / 2.0 - lane_w * (0.5 + effective_lane)
	else:
		var half_road: float = wp.width / 2.0
		var lane_w: float = half_road / float(lanes)
		offset = half_road - lane_w * (0.5 + effective_lane)

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
		if distance > despawn_distance:
			print("[NPC Despawn] reason=distance dist=%.0f pos=(%.1f, %.1f, %.1f)" % [
				distance, npc.global_position.x, npc.global_position.y, npc.global_position.z])
			_return_npc_to_pool(npc)


func _check_spawn_separation(position: Vector3) -> bool:
	"""Проверяет минимальную дистанцию до других NPC"""
	# Используем distance_squared для оптимизации (избегаем sqrt)
	var min_dist_sq := min_spawn_separation * min_spawn_separation
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

	if active_npcs.size() < max_npcs:
		# Распределение: 5% DPS, 10% Такси, 10% ПАЗ, 25% ВАЗ-2107, 10% Polo, 10% Matiz, 2% Logan, 3% Focus ST, 25% блочные
		var rand := randf()
		var scene_to_use: PackedScene
		var car_type: String

		if rand < 0.05:
			# 5% - Lada 2109 DPS
			scene_to_use = npc_lada_scene
			car_type = "Lada 2109 DPS"
		elif rand < 0.15:
			# 10% - Такси
			scene_to_use = npc_taxi_scene
			car_type = "Taxi"
		elif rand < 0.25:
			# 10% - ПАЗ
			scene_to_use = npc_paz_scene
			car_type = "PAZ bus"
		elif rand < 0.50:
			# 25% - ВАЗ-2107
			scene_to_use = npc_vaz2107_scene
			car_type = "VAZ-2107"
		elif rand < 0.60:
			# 10% - VW Polo
			scene_to_use = npc_polo_scene
			car_type = "VW Polo"
		elif rand < 0.70:
			# 10% - Daewoo Matiz
			scene_to_use = npc_matiz_scene
			car_type = "Daewoo Matiz"
		elif rand < 0.72:
			# 2% - Renault Logan
			scene_to_use = npc_logan_scene
			car_type = "Renault Logan"
		elif rand < 0.75:
			# 3% - Ford Focus ST (rare hot-hatch)
			scene_to_use = npc_focus_scene
			car_type = "Ford Focus ST"
		else:
			# 25% - блочные машинки
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
		print("[NPC Despawn] reason=request pos=(%.1f, %.1f, %.1f)" % [
			npc.global_position.x, npc.global_position.y, npc.global_position.z])
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


func _raycast_ground_y(pos: Vector3) -> float:
	var space_state := get_viewport().find_world_3d().direct_space_state
	if not space_state:
		return pos.y + 0.1
	var ray_from := Vector3(pos.x, maxf(pos.y + 200.0, 2000.0), pos.z)
	var ray_to := Vector3(pos.x, minf(pos.y - 200.0, -10.0), pos.z)
	var query := PhysicsRayQueryParameters3D.create(ray_from, ray_to)
	query.collision_mask = 1
	var result := space_state.intersect_ray(query)
	if not result.is_empty():
		return result.position.y + 0.1
	return pos.y + 0.1


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
	var info := "Traffic: %d/%d NPCs active, %d in pool" % [active_npcs.size(), max_npcs, inactive_npcs.size()]
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


func _log_npc_statistics() -> void:
	"""Логировать детальную статистику NPC для диагностики"""
	if not player_car:
		return

	# Детальная статистика по дистанциям
	var near_count = 0  # < 100m
	var mid_count = 0   # 100-200m
	var far_count = 0   # > 200m

	for npc in active_npcs:
		var dist = npc.global_position.distance_to(player_car.global_position)
		if dist < 100.0:
			near_count += 1
		elif dist < 200.0:
			mid_count += 1
		else:
			far_count += 1

	print("🚗 Traffic: %d active NPCs (Near: %d, Mid: %d, Far: %d), %d pooled" % [
		active_npcs.size(), near_count, mid_count, far_count, inactive_npcs.size()
	])

	# Physics bodies: ВСЕ NPC без колес = 1 body each
	# (было: 5 bodies per NPC с колесами)
	var total_npc_bodies = active_npcs.size() * 1

	print("  → Physics bodies from NPCs: %d (All: %d×1, было бы %d×5=%d)" % [
		total_npc_bodies, active_npcs.size(),
		active_npcs.size(), active_npcs.size() * 5
	])
