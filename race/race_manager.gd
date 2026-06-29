class_name RaceManager
extends Node

## Менеджер гонки: состояния, таймер, обратный отсчёт

const RaceTrackScript = preload("res://race/race_tracks.gd")
const RaceBarriersScript = preload("res://race/race_barriers.gd")
const RaceRouteScript = preload("res://race/race_route.gd")
const RaceGridScript = preload("res://race/race_grid.gd")

# Сцены AI соперников
const OPPONENT_SCENES := [
	"res://race/racer_nexia.tscn",
	"res://race/racer_vaz2107.tscn",
	"res://race/racer_logan.tscn",
]
const OPPONENT_COUNT := 3  # Количество AI соперников

signal race_loading_started
signal race_loading_progress(progress: float, status: String)
signal race_ready  # Чанки загружены, можно начинать отсчёт
signal countdown_tick(number: int)  # 3, 2, 1
signal countdown_go  # Старт!
signal race_started
signal race_finished(time: float, results: Array)  # results: [{name, time, position}]
signal race_cancelled
signal checkpoint_passed(index: int, time_bonus: float)  # Пройден чекпоинт
signal checkpoint_timeout  # Время истекло

enum State { IDLE, LOADING, COUNTDOWN, RACING, FINISHED }

var current_state := State.IDLE
var race_time := 0.0
var current_track  # RaceTrack

@export var terrain_generator_path: NodePath
@export var car_path: NodePath
@export var camera_path: NodePath

var _terrain_generator: Node3D
var _car: Node3D
var _car_rigidbody: RigidBody3D
var _camera: Camera3D
var _finish_line: Area3D
var _finish_pos_2d := Vector2.ZERO  # XZ позиция финиша для distance check
const FINISH_ARRIVE_DIST := 15.0  # 2D дистанция для срабатывания финиша (как pickup в work mode)
var _finish_elevation_fixed := false  # Починили ли высоту финиша
var _finish_check_timer := 0.0  # Таймер проверки финиша/высоты (раз в секунду)
var _countdown_timer: float = 0.0
var _countdown_current: int = 0

# Checkpoint mode
var _checkpoint_mode: bool = false
var _checkpoint_timer: float = 0.0
var _current_checkpoint_index: int = 0
var _checkpoint_areas: Array = []  # Array[Area3D]
var _checkpoint_local_positions: Array = []  # Array[Vector3] для minimap
var _minimap: Control  # Ссылка на мини-карту
var _barriers = null  # Визуальные барьеры вдоль маршрута
var _route_rebuild_timer := 0.0  # Таймер перестроения маршрута при загрузке новых чанков
const ROUTE_REBUILD_INTERVAL := 5.0  # Перестроение каждые 5 секунд

# AI соперники
var _race_route: RaceRoute  # Маршрут для AI
var _opponents: Array = []  # Array[RacerAI] - спавненные соперники
var _finish_order: Array = []  # [{name, time, is_player}] - порядок финиша

# Live HUD data (standings / progress / next-turn) — считается по запросу на такте HUD (5 Гц)
static var race_hud_debug := false
var _standings_state := {}   # { key: { last_pos: int } } — для стрелок тренда
var _player_seg_hint := 0    # кэш сегмента маршрута для проекции игрока (инкрементальный поиск)
const STANDINGS_MIN_SPEED := 8.0   # м/с — пол знаменателя для оценки гэпа
const NEXT_TURN_LOOKAHEAD := 250.0 # м — окно поиска ближайшего поворота
const NEXT_TURN_MIN_DEG := 18.0    # ° — порог «значимого» изгиба
const NEXT_TURN_FLIP := true       # XZ-базис зеркалит cross → left/right перевёрнуты, флипаем (подтверждено в игре)


func _ready() -> void:
	await get_tree().process_frame

	if terrain_generator_path:
		_terrain_generator = get_node_or_null(terrain_generator_path)
	if car_path:
		_car = get_node_or_null(car_path)
		_car_rigidbody = _car if _car is RigidBody3D else null
	if camera_path:
		_camera = get_node_or_null(camera_path)


func _process(delta: float) -> void:
	match current_state:
		State.COUNTDOWN:
			_process_countdown(delta)
		State.RACING:
			race_time += delta
			if _checkpoint_mode:
				_process_checkpoint_timer(delta)
			_finish_check_timer -= delta
			if _finish_check_timer <= 0.0:
				_finish_check_timer = 1.0
				_check_finish_distance()
				_fix_finish_elevation()
			_route_rebuild_timer -= delta
			if _route_rebuild_timer <= 0.0:
				_route_rebuild_timer = ROUTE_REBUILD_INTERVAL
				_update_minimap_route()


func _process_countdown(delta: float) -> void:
	_countdown_timer -= delta
	if _countdown_timer <= 0:
		if _countdown_current > 0:
			_countdown_current -= 1
			_countdown_timer = 1.0
			if _countdown_current > 0:
				countdown_tick.emit(_countdown_current)
			else:
				# GO!
				countdown_go.emit()
				_start_racing()
		else:
			_start_racing()


func start_race(track) -> void:
	"""Запустить гонку на указанной трассе"""
	print("RaceManager.start_race() called with track: ", track)
	print("RaceManager: current_state = ", State.keys()[current_state])
	if current_state != State.IDLE:
		print("RaceManager: Cannot start race - already in state ", State.keys()[current_state])
		return

	current_track = track
	race_time = 0.0
	current_state = State.LOADING
	print("RaceManager: State changed to LOADING")

	# Reset checkpoint state
	_checkpoint_mode = track.race_mode == "checkpoint"
	print("RaceManager: checkpoint_mode = ", _checkpoint_mode)
	_checkpoint_timer = 0.0
	_current_checkpoint_index = 0
	_checkpoint_local_positions.clear()
	_finish_order.clear()

	print("RaceManager: Emitting race_loading_started signal")
	race_loading_started.emit()

	print("RaceManager: Starting race on track '%s'" % track.track_name)

	# Update terrain_generator origin FIRST so subsequent lat/lon-to-local
	# conversions (start_pos here, waypoint positions in route building,
	# minimap track polyline) all reference the correct race origin.
	# Without this, a free-roam session at a different lat/lon (e.g.
	# Октябрьский мост) leaves start_lat/start_lon at the free-roam value
	# and the entire race route is offset by hundreds of meters.
	if _terrain_generator:
		_terrain_generator.start_lat = track.start_lat
		_terrain_generator.start_lon = track.start_lon

	# Перемещаем машину на старт ДО загрузки terrain
	# Это нужно чтобы terrain_generator загрузил чанки вокруг старта, а не финиша
	var start_pos := _latlon_to_local(track.start_lat, track.start_lon)
	start_pos.y = 1.0
	if _car:
		_car.global_position = start_pos
		_car.visible = false
	if _car_rigidbody:
		_car_rigidbody.freeze = true
		_car_rigidbody.linear_velocity = Vector3.ZERO
		_car_rigidbody.angular_velocity = Vector3.ZERO

	# Ждём загрузку чанков (используем сигнал от terrain_generator)
	if _terrain_generator:
		# Отключаем старые соединения и подключаем заново (для чистого состояния)
		if _terrain_generator.initial_load_progress.is_connected(_on_load_progress):
			_terrain_generator.initial_load_progress.disconnect(_on_load_progress)
		if _terrain_generator.initial_load_complete.is_connected(_on_load_complete):
			_terrain_generator.initial_load_complete.disconnect(_on_load_complete)

		_terrain_generator.initial_load_progress.connect(_on_load_progress)
		_terrain_generator.initial_load_complete.connect(_on_load_complete)

		_terrain_generator.spawn_lat = track.start_lat
		_terrain_generator.spawn_lon = track.start_lon
		_terrain_generator.reset_terrain()
		# Даём кадр на сброс состояния перед загрузкой
		await get_tree().process_frame
		_terrain_generator.start_loading()
	else:
		# Нет генератора - сразу готовы
		_on_race_ready()


func _on_load_progress(progress: float, status: String) -> void:
	if current_state == State.LOADING:
		race_loading_progress.emit(progress, status)


func _on_load_complete() -> void:
	if current_state == State.LOADING:
		_on_race_ready()


func _on_race_ready() -> void:
	"""Загрузка завершена, спавним машину и начинаем обратный отсчёт"""
	print("RaceManager: Race ready, spawning car")

	# Теперь дороги загружены - спавним машину на ближайшей дороге
	_spawn_car_at_start()

	# Ждём физический кадр чтобы позиция применилась
	await get_tree().physics_frame

	# Проверяем что машина на правильной высоте (защита от багов)
	if _car:
		var expected_y := _get_ground_y(_car.global_position.x, _car.global_position.z) + 1.0
		if absf(_car.global_position.y - expected_y) > 50.0:
			print("RaceManager: WARNING - Car at height %.1f, correcting to %.1f" % [_car.global_position.y, expected_y])
			var pos := _car.global_position
			pos.y = expected_y
			_car.global_position = pos

	# Создаём финишную линию
	_create_finish_line()

	# Создаём чекпоинты для checkpoint mode
	if _checkpoint_mode:
		_create_checkpoints()

	# Строим маршрут и спавним AI соперников (только в Sprint mode)
	if not is_checkpoint_mode():
		_build_race_route()
		_spawn_opponents()

	# Отправляем маршрут на мини-карту для визуализации (после _build_race_route)
	_update_minimap_route()

	# Создаём визуальные барьеры вдоль маршрута
	_create_barriers()

	# Показываем чекпоинты/финиш на миникарте (универсально для всех режимов)
	_update_minimap_markers()

	race_ready.emit()

	# Небольшая пауза перед отсчётом
	await get_tree().create_timer(0.5).timeout

	# Запускаем обратный отсчёт
	_start_countdown()


func _start_countdown() -> void:
	"""Начать обратный отсчёт 3-2-1"""
	current_state = State.COUNTDOWN
	_countdown_current = 3
	_countdown_timer = 1.0
	countdown_tick.emit(3)


func _start_racing() -> void:
	"""Начать гонку после отсчёта"""
	print("RaceManager: GO!")

	# ВАЖНО: Инициализируем таймер чекпоинтов ДО смены состояния на RACING
	# Иначе _process() увидит RACING + timer=0 и вызовет мгновенный таймаут
	if _checkpoint_mode and current_track and current_track.checkpoints.size() > 0:
		_checkpoint_timer = current_track.checkpoints[0].get("time_limit", current_track.default_checkpoint_time)
		_current_checkpoint_index = 0
		print("RaceManager: Checkpoint timer initialized: %.1f" % _checkpoint_timer)

	current_state = State.RACING
	race_time = 0.0

	# Сохраняем позицию и поворот перед размораживанием
	var saved_pos := _car.global_position if _car else Vector3.ZERO
	var saved_rot := _car.global_rotation if _car else Vector3.ZERO

	print("RaceManager: BEFORE unfreeze - Y=%.2f, vel=%.2f" % [_car.global_position.y, _car_rigidbody.linear_velocity.length() if _car_rigidbody else 0])

	# Сбрасываем состояние GEVP прямо перед unfreeze
	_reset_vehicle_physics_state()

	# Размораживаем машину
	if _car_rigidbody:
		_car_rigidbody.linear_velocity = Vector3.ZERO
		_car_rigidbody.angular_velocity = Vector3.ZERO
		_car_rigidbody.freeze = false

	print("RaceManager: AFTER unfreeze (same frame) - Y=%.2f" % _car.global_position.y)

	# Ждём физический кадр
	await get_tree().physics_frame
	print("RaceManager: AFTER 1 physics frame - Y=%.2f, vel_y=%.2f" % [_car.global_position.y, _car_rigidbody.linear_velocity.y if _car_rigidbody else 0])

	# Ещё один кадр
	await get_tree().physics_frame
	print("RaceManager: AFTER 2 physics frames - Y=%.2f, vel_y=%.2f" % [_car.global_position.y, _car_rigidbody.linear_velocity.y if _car_rigidbody else 0])

	# После разморозки снова устанавливаем позицию и обнуляем скорости
	if _car:
		_car.global_position = saved_pos
		_car.global_rotation = saved_rot
	if _car_rigidbody:
		_car_rigidbody.linear_velocity = Vector3.ZERO
		_car_rigidbody.angular_velocity = Vector3.ZERO

	print("RaceManager: AFTER reset - Y=%.2f" % _car.global_position.y)

	# Запускаем AI соперников
	_start_opponents_racing()

	race_started.emit()


func _spawn_car_at_start() -> void:
	"""Переместить машину на старт трассы (на ближайшую дорогу)"""
	if not _car or not current_track:
		return

	# Конвертируем lat/lon в локальные координаты
	var start_pos := _latlon_to_local(current_track.start_lat, current_track.start_lon)
	var finish_pos := _latlon_to_local(current_track.finish_lat, current_track.finish_lon)

	# Ищем ближайшую дорогу через TrafficManager
	var found_road := false
	var traffic_manager = get_tree().current_scene.find_child("TrafficManager", true, false)
	if traffic_manager and traffic_manager.has_method("get_road_network"):
		var road_network = traffic_manager.get_road_network()
		if road_network and not road_network.all_waypoints.is_empty():
			var nearest_wp = road_network.get_nearest_waypoint(start_pos)
			if nearest_wp:
				start_pos = nearest_wp.position
				start_pos.y += 1.0
				found_road = true
				print("RaceManager: Found road waypoint near start at Y=%.1f" % nearest_wp.position.y)

	# Если дороги нет — используем raycast/рельеф
	if not found_road:
		start_pos.y = _get_ground_y(start_pos.x, start_pos.z) + 1.0

	# Сбрасываем физику машины перед спавном
	if _car_rigidbody:
		_car_rigidbody.linear_velocity = Vector3.ZERO
		_car_rigidbody.angular_velocity = Vector3.ZERO
		_car_rigidbody.linear_damp = 0.0  # Сброс демпфирования после финиша
		_car_rigidbody.freeze = true
		# Сбрасываем тормоза
		if _car_rigidbody.get("handbrake") != null:
			_car_rigidbody.handbrake = 0.0
		if _car_rigidbody.get("brake") != null:
			_car_rigidbody.brake = 0.0

	# Поворачиваем машину к финишу (перед машины смотрит в -Z)
	var dir := finish_pos - start_pos
	dir.y = 0
	var yaw := 0.0
	if dir.length_squared() > 0.01:
		yaw = atan2(dir.x, dir.z) + PI

	# Устанавливаем позицию и поворот через transform (надёжнее для RigidBody3D)
	var new_transform := Transform3D()
	new_transform.origin = start_pos
	new_transform.basis = Basis(Vector3.UP, yaw)
	_car.global_transform = new_transform

	# Показываем машину
	_car.visible = true

	# КРИТИЧЕСКИ ВАЖНО: Сбрасываем внутреннее состояние GEVP после телепортации!
	# Иначе GEVP рассчитает "скорость" как разницу между старой и новой позицией
	# и получит безумные значения, что приведёт к взлёту машины
	_reset_vehicle_physics_state()

	# Телепортируем камеру к машине (иначе она будет медленно лететь от финиша)
	if _camera and _camera.has_method("teleport_to_target"):
		_camera.teleport_to_target()

	print("RaceManager: Car spawned at start (%.1f, %.1f, %.1f), target Y=0.5" % [
		_car.global_position.x, _car.global_position.y, _car.global_position.z
	])


func _build_race_route() -> void:
	"""Строит маршрут гонки для AI соперников"""
	if not current_track:
		return

	# Сброс live-HUD кэшей под новую гонку
	_standings_state.clear()
	_player_seg_hint = 0

	# Приоритет маршрутов:
	# 1. Dense route_points (>10 точек) — лучший вариант
	# 2. RoadNetwork pathfinding — автогенерация по дорожной сети
	# 3. Sparse waypoints — fallback

	if current_track.route_points and current_track.route_points.size() > 10:
		# Dense route_points — используем напрямую
		print("RaceManager: Building route from %d route_points" % current_track.route_points.size())
		var converter := func(lat: float, lon: float) -> Vector3:
			return _latlon_to_local(lat, lon)
		_race_route = RaceRouteScript.build_from_track_waypoints(current_track.route_points, converter)
	else:
		# Пробуем RoadNetwork pathfinding
		var road_network = null
		var traffic_manager = get_tree().current_scene.find_child("TrafficManager", true, false)
		if traffic_manager and traffic_manager.has_method("get_road_network"):
			road_network = traffic_manager.get_road_network()

		if road_network and not road_network.all_waypoints.is_empty():
			var start_pos := _latlon_to_local(current_track.start_lat, current_track.start_lon)
			var finish_pos := _latlon_to_local(current_track.finish_lat, current_track.finish_lon)
			# Sparse waypoints как промежуточные цели для предсказуемого пути
			var intermediate: Array = []
			if current_track.waypoints and current_track.waypoints.size() > 2:
				for i in range(1, current_track.waypoints.size() - 1):
					var wp = current_track.waypoints[i]
					intermediate.append(_latlon_to_local(wp.x, wp.y))
			print("RaceManager: Building route from RoadNetwork with %d intermediate targets" % intermediate.size())
			_race_route = RaceRouteScript.build_from_road_network(
				start_pos, finish_pos, road_network, intermediate)
		elif current_track.waypoints and current_track.waypoints.size() > 0:
			# Fallback: sparse waypoints
			print("RaceManager: Building route from %d sparse waypoints (fallback)" % current_track.waypoints.size())
			var converter := func(lat: float, lon: float) -> Vector3:
				return _latlon_to_local(lat, lon)
			_race_route = RaceRouteScript.build_from_track_waypoints(current_track.waypoints, converter)
		else:
			push_error("RaceManager: No route data available!")
			return

	if _race_route:
		print("RaceManager: Race route built with %d points, length: %.1fm" % [
			_race_route.points.size(), _race_route.total_length
		])
	else:
		push_error("RaceManager: Failed to build race route!")


func _spawn_opponents() -> void:
	"""Спавнит AI соперников на стартовой сетке"""
	if not _car or not current_track:
		return

	# Очищаем предыдущих соперников
	_clear_opponents()

	# Если нет маршрута - не спавним соперников
	if not _race_route:
		print("RaceManager: No race route, skipping opponent spawn")
		return

	# Рассчитываем позиции на стартовой сетке
	var player_pos := _car.global_position
	var forward_dir := -_car.global_transform.basis.z  # -Z это перед машины

	var grid_positions := RaceGridScript.calculate_positions(player_pos, forward_dir, OPPONENT_COUNT)
	print("RaceManager: Grid positions calculated:\n%s" % RaceGridScript.debug_grid_layout(OPPONENT_COUNT))

	# Спавним соперников
	for i in range(OPPONENT_COUNT):
		if i >= grid_positions.size():
			break

		# Выбираем случайную сцену соперника
		var scene_path: String = OPPONENT_SCENES[i % OPPONENT_SCENES.size()]
		var scene := load(scene_path) as PackedScene
		if not scene:
			push_error("RaceManager: Failed to load opponent scene: " + scene_path)
			continue

		var opponent := scene.instantiate()
		if not opponent:
			push_error("RaceManager: Failed to instantiate opponent")
			continue

		# Даём имя
		opponent.name = "Opponent_%d" % (i + 1)
		if opponent.get("racer_name") != null:
			opponent.racer_name = "AI %d" % (i + 1)

		# ВАЖНО: Сначала добавляем в сцену, потом устанавливаем global_position!
		# global_position работает только после добавления в дерево
		get_tree().current_scene.add_child(opponent)

		# Устанавливаем позицию и поворот из стартовой сетки
		# RaceGrid уже рассчитывает правильный basis с учётом направления -Z для VehicleBody3D
		var grid_transform: Transform3D = grid_positions[i]
		opponent.global_position = grid_transform.origin
		# Разворачиваем на 180° — grid basis смотрит назад для соперников
		opponent.global_transform.basis = grid_transform.basis * Basis(Vector3.UP, PI)

		# Устанавливаем маршрут
		if opponent.has_method("set_race_route"):
			opponent.set_race_route(_race_route)

		# Замораживаем до старта
		if opponent.has_method("freeze_for_countdown"):
			opponent.freeze_for_countdown()
		_opponents.append(opponent)

		print("RaceManager: Spawned opponent %d at (%.1f, %.1f, %.1f)" % [
			i + 1, opponent.global_position.x, opponent.global_position.y, opponent.global_position.z
		])

	print("RaceManager: Spawned %d opponents" % _opponents.size())

	# Включаем отображение соперников на миникарте
	if not _minimap:
		_minimap = get_tree().current_scene.find_child("MiniMap", true, false)
	if _minimap and _minimap.has_method("set_show_opponents"):
		_minimap.set_show_opponents(true)


func _start_opponents_racing() -> void:
	"""Запускает всех AI соперников после GO!"""
	for opponent in _opponents:
		if is_instance_valid(opponent) and opponent.has_method("start_racing"):
			opponent.start_racing()
	print("RaceManager: Started %d opponents racing" % _opponents.size())


func _clear_opponents() -> void:
	"""Удаляет всех AI соперников"""
	for opponent in _opponents:
		if is_instance_valid(opponent):
			opponent.queue_free()
	_opponents.clear()

	# Выключаем отображение соперников на миникарте
	if _minimap and _minimap.has_method("set_show_opponents"):
		_minimap.set_show_opponents(false)


func _generate_race_results() -> Array:
	"""Генерирует итоговые результаты гонки на основе реального порядка финиша.
	Те кто финишировал - с реальным временем.
	Те кто не финишировал - с оценочным временем в конце."""
	var results: Array = []

	# 1. Добавляем всех кто уже финишировал (в порядке финиша)
	var position := 1
	for finisher in _finish_order:
		results.append({
			"name": finisher.name,
			"time": finisher.time,
			"position": position,
			"is_player": finisher.is_player
		})
		position += 1

	# 2. Добавляем AI которые ещё не финишировали
	var finished_names: Array = []
	for finisher in _finish_order:
		finished_names.append(finisher.name)

	var unfinished: Array = []
	for opponent in _opponents:
		if is_instance_valid(opponent):
			var opp_name: String = opponent.racer_name if opponent.get("racer_name") else "AI"
			if opp_name not in finished_names:
				unfinished.append(opp_name)

	# Перемешиваем не финишировавших и добавляем с оценочным временем
	unfinished.shuffle()
	for i in range(unfinished.size()):
		var estimated_time: float = race_time + randf_range(3.0, 8.0) + i * randf_range(1.0, 3.0)
		results.append({
			"name": unfinished[i],
			"time": estimated_time,
			"position": position,
			"is_player": false
		})
		position += 1

	print("RaceManager: Generated results - %d racers (%d finished, %d estimated)" % [
		results.size(), _finish_order.size(), unfinished.size()
	])
	return results


func _create_finish_line() -> void:
	"""Создать финишную линию на конечной точке"""
	if not current_track:
		return

	# Удаляем старую финишную линию если есть
	if _finish_line:
		_finish_line.queue_free()
		_finish_line = null

	# Конвертируем координаты
	var finish_pos := _latlon_to_local(current_track.finish_lat, current_track.finish_lon)
	var start_pos := _latlon_to_local(current_track.start_lat, current_track.start_lon)

	# Создаём Area3D
	_finish_line = Area3D.new()
	_finish_line.name = "FinishLine"
	# Collision mask: слой 1 (игрок) + слой 8 (AI соперники, 128)
	_finish_line.collision_mask = 1 + 128

	# Создаём коллизию (широкая полоса поперёк дороги) - поднята для детекции машины
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(20.0, 4.0, 2.0)  # Широкая, высокая, тонкая
	collision.shape = shape
	collision.position = Vector3(0, 1.5, 0)  # Коллизия выше земли для детекции
	_finish_line.add_child(collision)

	# Создаём визуальную финишную линию - шахматка в два ряда
	var square_size := 1.0  # Размер одного квадрата
	var num_squares_x := 12  # Количество квадратов по ширине
	var num_squares_z := 2   # Два ряда

	for ix in range(num_squares_x):
		for iz in range(num_squares_z):
			var is_white := (ix + iz) % 2 == 0
			var square := MeshInstance3D.new()
			var square_mesh := BoxMesh.new()
			square_mesh.size = Vector3(square_size, 0.05, square_size)
			square.mesh = square_mesh

			var mat := StandardMaterial3D.new()
			if is_white:
				mat.albedo_color = Color.WHITE
				mat.emission_enabled = true
				mat.emission = Color(1, 1, 1, 1)
				mat.emission_energy_multiplier = 0.3
			else:
				mat.albedo_color = Color.BLACK
			square.material_override = mat

			# Позиция квадрата (центрируем по X и Z)
			var x_pos := (ix - num_squares_x / 2.0 + 0.5) * square_size
			var z_pos := (iz - num_squares_z / 2.0 + 0.5) * square_size
			square.position = Vector3(x_pos, 0.15, z_pos)
			_finish_line.add_child(square)

	# Добавляем вертикальные столбы по краям
	for side in [-1, 1]:
		var pole := MeshInstance3D.new()
		var pole_mesh := CylinderMesh.new()
		pole_mesh.top_radius = 0.15
		pole_mesh.bottom_radius = 0.15
		pole_mesh.height = 4.0
		pole.mesh = pole_mesh
		var pole_mat := StandardMaterial3D.new()
		pole_mat.albedo_color = Color(1, 0.2, 0.2)
		pole_mat.emission_enabled = true
		pole_mat.emission = Color(1, 0.2, 0.2)
		pole_mat.emission_energy_multiplier = 0.3
		pole.material_override = pole_mat
		pole.position = Vector3(side * 6.5, 2.0, 0)  # Столбы от земли вверх
		_finish_line.add_child(pole)

	# Сохраняем 2D позицию финиша для distance check
	_finish_pos_2d = Vector2(finish_pos.x, finish_pos.z)
	_finish_elevation_fixed = false

	# Высота финиша — при старте гонки чанк финиша может быть ещё не загружен
	var gy := _get_ground_y(finish_pos.x, finish_pos.z)
	if gy == 0.0:
		# Нет данных о высоте, поставим на 0 — починим позже в _fix_finish_elevation
		print("RaceManager: Finish elevation unknown, will fix later")
	else:
		_finish_elevation_fixed = true
	finish_pos.y = gy
	_finish_line.global_position = finish_pos
	add_child(_finish_line)

	# Поворачиваем перпендикулярно направлению движения
	var dir := finish_pos - start_pos
	dir.y = 0
	if dir.length_squared() > 0.01:
		var yaw := atan2(dir.x, dir.z)
		_finish_line.rotation = Vector3(0, yaw, 0)

	# Подключаем сигнал
	_finish_line.body_entered.connect(_on_finish_line_entered)

	print("RaceManager: Finish line created at (%.1f, %.1f, %.1f)" % [
		finish_pos.x, finish_pos.y, finish_pos.z
	])


func _on_finish_line_entered(body: Node3D) -> void:
	"""Машина пересекла финишную линию"""
	if current_state != State.RACING:
		return

	# Проверяем что это игрок
	if body == _car or body == _car_rigidbody:
		# Записываем финиш игрока
		_finish_order.append({
			"name": "Игрок",
			"time": race_time,
			"is_player": true
		})
		print("RaceManager: Player finished at position %d, time %.2f" % [_finish_order.size(), race_time])
		_finish_race()
		return

	# Проверяем что это AI соперник
	for opponent in _opponents:
		if is_instance_valid(opponent) and body == opponent:
			# Проверяем, не финишировал ли уже этот соперник
			for finished in _finish_order:
				if finished.name == opponent.racer_name:
					return  # Уже финишировал

			# Записываем финиш AI
			_finish_order.append({
				"name": opponent.racer_name,
				"time": race_time,
				"is_player": false
			})
			print("RaceManager: %s finished at position %d, time %.2f" % [opponent.racer_name, _finish_order.size(), race_time])

			# Останавливаем AI
			if opponent.has_method("finish_race"):
				opponent.finish_race()
			return


func _check_finish_distance() -> void:
	"""Проверка финиша по 2D дистанции (как pickup в work mode) — не зависит от высоты"""
	if not _car or _finish_pos_2d == Vector2.ZERO:
		return
	var car_2d := Vector2(_car.global_position.x, _car.global_position.z)
	if car_2d.distance_to(_finish_pos_2d) <= FINISH_ARRIVE_DIST:
		# Имитируем body_entered для игрока
		_on_finish_line_entered(_car)


func _fix_finish_elevation() -> void:
	"""Чинит высоту финиша когда чанк загрузится"""
	if _finish_elevation_fixed or not _finish_line:
		return
	var gy := _get_ground_y(_finish_pos_2d.x, _finish_pos_2d.y)
	if gy != 0.0:
		var pos := _finish_line.global_position
		pos.y = gy
		_finish_line.global_position = pos
		_finish_elevation_fixed = true
		print("RaceManager: Fixed finish elevation to %.2f" % gy)


func _finish_race() -> void:
	"""Завершить гонку"""
	print("RaceManager: FINISH! Time: %.2f seconds" % race_time)
	current_state = State.FINISHED

	# Останавливаем всех AI соперников (но не удаляем!)
	for opponent in _opponents:
		if is_instance_valid(opponent) and opponent.has_method("finish_race"):
			opponent.finish_race()

	# Генерируем результаты гонки
	var results := _generate_race_results()

	# Удаляем барьеры
	_clear_barriers()

	# НЕ удаляем AI соперников сразу - они останутся видны
	# Они будут удалены при reset() или cancel_race()

	# Автоматическое торможение (ручной тормоз)
	if _car_rigidbody:
		# Для GEVP Vehicle - устанавливаем ручной тормоз
		if _car_rigidbody.has_method("set"):
			if _car_rigidbody.get("handbrake") != null:
				_car_rigidbody.handbrake = 1.0
			elif _car_rigidbody.get("brake") != null:
				_car_rigidbody.brake = 1.0
		# Замедляем машину
		_car_rigidbody.linear_damp = 3.0

	race_finished.emit(race_time, results)


func cancel_race() -> void:
	"""Отменить гонку и вернуться в IDLE"""
	if current_state == State.IDLE:
		return

	print("RaceManager: Race cancelled")

	# Удаляем барьеры
	_clear_barriers()

	# Удаляем AI соперников
	_clear_opponents()

	# Удаляем финишную линию
	if _finish_line:
		_finish_line.queue_free()
		_finish_line = null

	# Удаляем чекпоинты
	for area in _checkpoint_areas:
		if is_instance_valid(area):
			area.queue_free()
	_checkpoint_areas.clear()
	_checkpoint_local_positions.clear()

	# Очищаем мини-карту
	if _minimap and _minimap.has_method("clear_checkpoints"):
		_minimap.clear_checkpoints()
	if _minimap and _minimap.has_method("clear_route_points"):
		_minimap.clear_route_points()

	current_state = State.IDLE
	race_cancelled.emit()


func reset() -> void:
	"""Сбросить состояние для новой гонки"""
	cancel_race()
	current_track = null
	race_time = 0.0


func get_formatted_time() -> String:
	"""Получить время в формате MM:SS.ms"""
	var minutes := int(race_time) / 60
	var seconds := int(race_time) % 60
	var ms := int((race_time - int(race_time)) * 100)
	return "%02d:%02d.%02d" % [minutes, seconds, ms]


func _reset_vehicle_physics_state() -> void:
	"""Сбросить внутреннее состояние GEVP Vehicle после телепортации.
	Это критически важно! GEVP рассчитывает скорость как разницу позиций между кадрами.
	После телепортации previous_global_position указывает на старую позицию,
	и GEVP думает что машина пролетела сотни метров за один кадр."""

	if not _car_rigidbody:
		return

	var current_pos := _car.global_position

	# Сбрасываем состояние Vehicle (GEVP)
	if _car_rigidbody.get("previous_global_position") != null:
		_car_rigidbody.previous_global_position = current_pos
		print("RaceManager: Reset vehicle previous_global_position")

	if _car_rigidbody.get("local_velocity") != null:
		_car_rigidbody.local_velocity = Vector3.ZERO

	if _car_rigidbody.get("motor_rpm") != null and _car_rigidbody.get("idle_rpm") != null:
		_car_rigidbody.motor_rpm = _car_rigidbody.idle_rpm

	if _car_rigidbody.get("current_gear") != null:
		_car_rigidbody.current_gear = 0

	if _car_rigidbody.get("throttle_amount") != null:
		_car_rigidbody.throttle_amount = 0.0
	if _car_rigidbody.get("brake_amount") != null:
		_car_rigidbody.brake_amount = 0.0
	if _car_rigidbody.get("steering_amount") != null:
		_car_rigidbody.steering_amount = 0.0
	if _car_rigidbody.get("clutch_amount") != null:
		_car_rigidbody.clutch_amount = 0.0

	# Сбрасываем состояние всех колёс
	var wheels: Array = []
	if _car_rigidbody.get("wheel_array") != null:
		wheels = _car_rigidbody.wheel_array
	elif _car_rigidbody.get("front_left_wheel") != null:
		# Собираем колёса вручную
		if _car_rigidbody.front_left_wheel:
			wheels.append(_car_rigidbody.front_left_wheel)
		if _car_rigidbody.front_right_wheel:
			wheels.append(_car_rigidbody.front_right_wheel)
		if _car_rigidbody.rear_left_wheel:
			wheels.append(_car_rigidbody.rear_left_wheel)
		if _car_rigidbody.rear_right_wheel:
			wheels.append(_car_rigidbody.rear_right_wheel)

	for wheel in wheels:
		if wheel == null:
			continue

		# Сбрасываем previous_global_position колеса
		if wheel.get("previous_global_position") != null:
			wheel.previous_global_position = wheel.global_position

		# Сбрасываем скорости колеса
		if wheel.get("local_velocity") != null:
			wheel.local_velocity = Vector3.ZERO
		if wheel.get("previous_velocity") != null:
			wheel.previous_velocity = Vector3.ZERO

		# Сбрасываем вращение колеса
		if wheel.get("spin") != null:
			wheel.spin = 0.0

		# Сбрасываем сжатие подвески
		if wheel.get("previous_compression") != null:
			wheel.previous_compression = 0.0

		# Сбрасываем силы
		if wheel.get("force_vector") != null:
			wheel.force_vector = Vector2.ZERO
		if wheel.get("slip_vector") != null:
			wheel.slip_vector = Vector2.ZERO

	print("RaceManager: Reset GEVP physics state for %d wheels" % wheels.size())


func _get_ground_y(x: float, z: float) -> float:
	"""Найти высоту земли через physics raycast (точнее чем elevation grid)"""
	# Raycast сверху вниз - находит реальную поверхность дороги/terrain
	var world_3d := get_viewport().find_world_3d()
	if world_3d:
		var space_state := world_3d.direct_space_state
		if space_state:
			var from := Vector3(x, 1000.0, z)
			var to := Vector3(x, -100.0, z)
			var query := PhysicsRayQueryParameters3D.create(from, to)
			var result := space_state.intersect_ray(query)
			if not result.is_empty():
				return result.position.y
	# Fallback: elevation grid
	if _terrain_generator and _terrain_generator.has_method("_sample_elevation"):
		var elev: float = _terrain_generator._sample_elevation(x, z)
		if elev != 0.0:
			return elev
	# Fallback: car level
	if _car and is_instance_valid(_car):
		return _car.global_position.y - 1.0
	return 0.0


func _latlon_to_local(lat: float, lon: float) -> Vector3:
	"""Конвертировать GPS координаты в локальные (используем terrain_generator)"""
	if _terrain_generator and _terrain_generator.has_method("_latlon_to_local"):
		var pos2d = _terrain_generator._latlon_to_local(lat, lon)
		return Vector3(pos2d.x, 0, pos2d.y)  # Vector2 -> Vector3

	# Fallback: простая конвертация
	# 1 градус широты ≈ 111 км
	# 1 градус долготы ≈ 111 км * cos(lat)
	var ref_lat := 59.15  # Череповец
	var ref_lon := 37.95

	var lat_diff := lat - ref_lat
	var lon_diff := lon - ref_lon

	var z := -lat_diff * 111000.0
	var x := lon_diff * 111000.0 * cos(deg_to_rad(lat))

	return Vector3(x, 0, z)


func _get_road_network():
	"""Получить RoadNetwork из TrafficManager"""
	var traffic_manager = get_tree().current_scene.find_child("TrafficManager", true, false)
	if traffic_manager and traffic_manager.has_method("get_road_network"):
		return traffic_manager.get_road_network()
	return null


func _build_minimap_route_via_roads(road_network) -> Array:
	"""Строит маршрут по дорогам между sparse waypoints для миникарты.
	Использует A* по RoadNetwork (как work mode). Возвращает Array[Vector2]."""
	if not current_track or current_track.route_points.size() < 2:
		return []

	# Конвертируем waypoints в 3D позиции
	var targets: Array[Vector3] = []
	for latlon in current_track.route_points:
		targets.append(_latlon_to_local(latlon.x, latlon.y))

	# Для каждого сегмента строим A* путь
	var result: Array = []
	for i in range(targets.size() - 1):
		var seg_path := _astar_between(road_network, targets[i], targets[i + 1])
		# Добавляем без дубликатов
		for pt in seg_path:
			if result.is_empty() or result[-1].distance_to(pt) > 3.0:
				result.append(pt)

	# Добавляем конечную точку
	var last_2d := Vector2(targets[-1].x, targets[-1].z)
	if result.is_empty() or result[-1].distance_to(last_2d) > 3.0:
		result.append(last_2d)

	return result


const _ASTAR_MAX_ITER := 3000

func _astar_between(road_network, from_pos: Vector3, to_pos: Vector3) -> Array:
	"""A* между двумя 3D точками по RoadNetwork. Возвращает Array[Vector2].
	Ограничен коридором вдоль прямой линии чтобы избежать зигзагов по боковым улицам."""
	var start_wp = road_network.get_nearest_waypoint(from_pos)
	if not start_wp or start_wp.position.distance_to(from_pos) > 150.0:
		return [Vector2(from_pos.x, from_pos.z), Vector2(to_pos.x, to_pos.z)]

	var end_wp = road_network.get_nearest_waypoint(to_pos)

	# Коридор: отсекаем waypoints далеко от прямой линии start→end
	var from_2d := Vector2(from_pos.x, from_pos.z)
	var to_2d := Vector2(to_pos.x, to_pos.z)
	var seg_dir := to_2d - from_2d
	var seg_len := seg_dir.length()
	var seg_norm := seg_dir / seg_len if seg_len > 1.0 else Vector2.ZERO
	var corridor_half := 60.0  # Макс отклонение от прямой линии (метры)

	var open: Array = [[start_wp.position.distance_to(to_pos), 0.0, start_wp]]
	var g_score := {start_wp: 0.0}
	var came_from := {}
	var closed := {}
	var best_wp = start_wp
	var best_dist: float = start_wp.position.distance_to(to_pos)

	for _iter in range(_ASTAR_MAX_ITER):
		if open.is_empty():
			break
		var best_idx := 0
		for j in range(1, open.size()):
			if open[j][0] < open[best_idx][0]:
				best_idx = j
		var entry: Array = open[best_idx]
		open.remove_at(best_idx)
		var current = entry[2]
		var g: float = entry[1]

		if closed.has(current):
			continue
		closed[current] = true

		var dist_to_target: float = current.position.distance_to(to_pos)
		if dist_to_target < best_dist:
			best_dist = dist_to_target
			best_wp = current

		if current == end_wp or dist_to_target < 30.0:
			best_wp = current
			break

		# Раскрываем соседей (оба направления)
		for next_wp in current.next_waypoints:
			if closed.has(next_wp):
				continue
			# Проверка коридора
			var wp_2d := Vector2(next_wp.position.x, next_wp.position.z)
			var offset := wp_2d - from_2d
			var cross := absf(offset.x * seg_norm.y - offset.y * seg_norm.x)
			if cross > corridor_half:
				continue
			var edge_cost: float = current.position.distance_to(next_wp.position)
			var new_g: float = g + edge_cost
			if new_g < g_score.get(next_wp, INF):
				g_score[next_wp] = new_g
				came_from[next_wp] = current
				open.append([new_g + next_wp.position.distance_to(to_pos), new_g, next_wp])

		for prev_wp in current.prev_waypoints:
			if closed.has(prev_wp):
				continue
			var wp_2d := Vector2(prev_wp.position.x, prev_wp.position.z)
			var offset := wp_2d - from_2d
			var cross := absf(offset.x * seg_norm.y - offset.y * seg_norm.x)
			if cross > corridor_half:
				continue
			var edge_cost: float = current.position.distance_to(prev_wp.position)
			var new_g: float = g + edge_cost
			if new_g < g_score.get(prev_wp, INF):
				g_score[prev_wp] = new_g
				came_from[prev_wp] = current
				open.append([new_g + prev_wp.position.distance_to(to_pos), new_g, prev_wp])

	# Реконструируем путь
	if best_wp == start_wp and best_dist > 50.0:
		return [Vector2(from_pos.x, from_pos.z)]

	var wp_path: Array = []
	var n = best_wp
	while came_from.has(n):
		wp_path.insert(0, Vector2(n.position.x, n.position.z))
		n = came_from[n]
	wp_path.insert(0, Vector2(n.position.x, n.position.z))

	# Начинаем от from_pos
	var path: Array = [Vector2(from_pos.x, from_pos.z)]
	for pt in wp_path:
		if path[-1].distance_to(pt) > 3.0:
			path.append(pt)
	print("RaceManager: A* segment %.0fm -> %d waypoints" % [seg_len, path.size()])
	return path


# ============= Checkpoint Mode =============

func _create_checkpoints() -> void:
	"""Создать Area3D для каждого чекпоинта"""
	if not current_track or current_track.checkpoints.is_empty():
		return

	# Очищаем старые чекпоинты
	for area in _checkpoint_areas:
		if is_instance_valid(area):
			area.queue_free()
	_checkpoint_areas.clear()
	_checkpoint_local_positions.clear()

	var start_pos := _latlon_to_local(current_track.start_lat, current_track.start_lon)

	for i in range(current_track.checkpoints.size()):
		var cp: Dictionary = current_track.checkpoints[i]
		var cp_pos := _latlon_to_local(cp.lat, cp.lon)
		_checkpoint_local_positions.append(cp_pos)

		# Создаём Area3D
		var area := Area3D.new()
		area.name = "Checkpoint_%d" % i

		# Создаём коллизию
		var collision := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3(20.0, 4.0, 2.0)
		collision.shape = shape
		collision.position = Vector3(0, 1.5, 0)
		area.add_child(collision)

		# Визуализация - жёлтая разметка
		_create_checkpoint_visuals(area)

		cp_pos.y = _get_ground_y(cp_pos.x, cp_pos.z)
		area.global_position = cp_pos

		# Ориентация - к следующему чекпоинту или финишу
		var next_pos: Vector3
		if i < current_track.checkpoints.size() - 1:
			var next_cp: Dictionary = current_track.checkpoints[i + 1]
			next_pos = _latlon_to_local(next_cp.lat, next_cp.lon)
		else:
			next_pos = _latlon_to_local(current_track.finish_lat, current_track.finish_lon)

		var dir := next_pos - cp_pos
		dir.y = 0
		if dir.length_squared() > 0.01:
			var yaw := atan2(dir.x, dir.z)
			area.rotation = Vector3(0, yaw, 0)

		# Подключаем сигнал с индексом
		area.body_entered.connect(_on_checkpoint_entered.bind(i))

		# Скрываем все кроме первого
		area.visible = (i == 0)

		add_child(area)
		_checkpoint_areas.append(area)

	print("RaceManager: Created %d checkpoints" % _checkpoint_areas.size())


func _update_minimap_markers() -> void:
	"""Универсально обновляем маркеры на миникарте:
	- Если есть чекпоинты → показываем их + финиш
	- Если нет чекпоинтов но есть финиш → показываем только финиш
	- Если ничего нет (свободная езда) → ничего не показываем"""
	if not _minimap:
		_minimap = get_tree().current_scene.find_child("MiniMap", true, false)

	if not _minimap or not _minimap.has_method("set_checkpoints"):
		return

	if not current_track:
		return

	# Получаем позицию финиша (если есть координаты)
	var finish_pos: Vector3 = Vector3.ZERO
	var has_finish: bool = current_track.finish_lat != 0.0 or current_track.finish_lon != 0.0
	if has_finish:
		finish_pos = _latlon_to_local(current_track.finish_lat, current_track.finish_lon)

	# Передаём чекпоинты (может быть пустой массив) и финиш
	_minimap.set_checkpoints(_checkpoint_local_positions, finish_pos if has_finish else Vector3.ZERO)


func _update_minimap_route() -> void:
	"""Отправляем точки маршрута на мини-карту для визуализации"""
	if not _minimap:
		_minimap = get_tree().current_scene.find_child("MiniMap", true, false)

	if not _minimap or not _minimap.has_method("set_route_points"):
		return

	# Используем _race_route только если он построен из dense waypoints (не из RoadNetwork,
	# который неполон при старте гонки — загружены только начальные чанки)
	var use_race_route := false
	if _race_route and _race_route.points.size() > 2:
		if current_track and current_track.route_points.size() > 10:
			# Dense route_points → _race_route построен из build_from_track_waypoints → надёжен
			use_race_route = true

	if use_race_route:
		var local_points: Array = []
		for rp in _race_route.points:
			local_points.append(Vector2(rp.position.x, rp.position.z))
		_minimap.set_route_points(local_points)
		print("RaceManager: Sent %d route points to minimap (from race_route)" % local_points.size())
		return

	if not current_track or current_track.route_points.is_empty():
		return

	# Sparse route_points — строим маршрут по дорогам через RoadNetwork A*
	var road_network = _get_road_network()
	if road_network and not road_network.all_waypoints.is_empty():
		var road_path := _build_minimap_route_via_roads(road_network)
		if road_path.size() >= 2:
			_minimap.set_route_points(road_path)
			print("RaceManager: Sent %d route points to minimap (A* road path)" % road_path.size())
			return

	# Нет дорожных данных — не показываем маршрут (прямые линии подсвечивают не те дороги)
	print("RaceManager: No road network available, skipping minimap route")


func _create_barriers() -> void:
	"""Создать визуальные барьеры вдоль маршрута"""
	if _barriers:
		_barriers.queue_free()
		_barriers = null

	if not current_track or current_track.route_points.is_empty():
		return

	_barriers = Node3D.new()
	_barriers.set_script(RaceBarriersScript)
	_barriers.name = "RaceBarriers"
	add_child(_barriers)

	# Конвертируем route_points в локальные 3D координаты
	var local_points: Array = []
	for latlon in current_track.route_points:
		var pos := _latlon_to_local(latlon.x, latlon.y)
		pos.y = _get_ground_y(pos.x, pos.z) + 0.5
		local_points.append(pos)

	_barriers.build_barriers(local_points)
	print("RaceManager: Created barriers with %d route points" % local_points.size())


func _clear_barriers() -> void:
	"""Удалить визуальные барьеры"""
	if _barriers:
		_barriers.queue_free()
		_barriers = null


func _create_checkpoint_visuals(area: Area3D) -> void:
	"""Создать жёлтую визуализацию чекпоинта"""
	var square_size := 1.0
	var num_squares_x := 12
	var num_squares_z := 2
	var yellow := Color(1.0, 0.85, 0.0)

	# Жёлтые квадраты
	for ix in range(num_squares_x):
		for iz in range(num_squares_z):
			var square := MeshInstance3D.new()
			var square_mesh := BoxMesh.new()
			square_mesh.size = Vector3(square_size, 0.05, square_size)
			square.mesh = square_mesh

			var mat := StandardMaterial3D.new()
			mat.albedo_color = yellow
			mat.emission_enabled = true
			mat.emission = yellow
			mat.emission_energy_multiplier = 0.5
			square.material_override = mat

			var x_pos := (ix - num_squares_x / 2.0 + 0.5) * square_size
			var z_pos := (iz - num_squares_z / 2.0 + 0.5) * square_size
			square.position = Vector3(x_pos, 0.15, z_pos)
			area.add_child(square)

	# Жёлтые столбы
	for side in [-1, 1]:
		var pole := MeshInstance3D.new()
		var pole_mesh := CylinderMesh.new()
		pole_mesh.top_radius = 0.15
		pole_mesh.bottom_radius = 0.15
		pole_mesh.height = 4.0
		pole.mesh = pole_mesh
		var pole_mat := StandardMaterial3D.new()
		pole_mat.albedo_color = yellow
		pole_mat.emission_enabled = true
		pole_mat.emission = yellow
		pole_mat.emission_energy_multiplier = 0.5
		pole.material_override = pole_mat
		pole.position = Vector3(side * 6.5, 2.0, 0)
		area.add_child(pole)


func _on_checkpoint_entered(body: Node3D, index: int) -> void:
	"""Обработка проезда чекпоинта"""
	if current_state != State.RACING:
		return

	# Проверяем что это наша машина
	if body != _car and body != _car_rigidbody:
		return

	# Проверяем что это текущий чекпоинт
	if index != _current_checkpoint_index:
		return

	# Рассчитываем бонус времени (остаток)
	var time_bonus := _checkpoint_timer
	print("RaceManager: Checkpoint %d passed! Time bonus: +%.1f" % [index, time_bonus])

	# Скрываем пройденный чекпоинт
	if index < _checkpoint_areas.size():
		_checkpoint_areas[index].visible = false

	# Переходим к следующему чекпоинту
	_current_checkpoint_index += 1

	# Проверяем есть ли ещё чекпоинты
	if _current_checkpoint_index < current_track.checkpoints.size():
		# Показываем следующий чекпоинт
		_checkpoint_areas[_current_checkpoint_index].visible = true

		# Устанавливаем время для следующего чекпоинта (с бонусом)
		var next_cp: Dictionary = current_track.checkpoints[_current_checkpoint_index]
		var next_time: float = next_cp.get("time_limit", current_track.default_checkpoint_time)
		_checkpoint_timer = next_time + time_bonus  # Переносим избыток
		print("RaceManager: Next checkpoint time: %.1f (base %.1f + bonus %.1f)" % [_checkpoint_timer, next_time, time_bonus])
	else:
		# Все чекпоинты пройдены, таймер до финиша
		_checkpoint_timer = current_track.default_checkpoint_time + time_bonus
		print("RaceManager: All checkpoints passed! Time to finish: %.1f" % _checkpoint_timer)

	# Обновляем мини-карту
	if _minimap and _minimap.has_method("mark_checkpoint_passed"):
		_minimap.mark_checkpoint_passed(index)

	checkpoint_passed.emit(index, time_bonus)


func _process_checkpoint_timer(delta: float) -> void:
	"""Обработка таймера чекпоинтов"""
	_checkpoint_timer -= delta

	if _checkpoint_timer <= 0:
		_on_checkpoint_timeout()


func _on_checkpoint_timeout() -> void:
	"""Время истекло - поражение"""
	print("RaceManager: TIMEOUT! Race failed")
	current_state = State.FINISHED

	# Тормозим машину
	if _car_rigidbody:
		if _car_rigidbody.get("handbrake") != null:
			_car_rigidbody.handbrake = 1.0
		elif _car_rigidbody.get("brake") != null:
			_car_rigidbody.brake = 1.0
		_car_rigidbody.linear_damp = 3.0

	checkpoint_timeout.emit()


func get_checkpoint_timer() -> float:
	"""Получить текущее время таймера чекпоинтов"""
	return _checkpoint_timer


func get_checkpoint_positions() -> Array:
	"""Получить локальные позиции чекпоинтов для minimap"""
	return _checkpoint_local_positions


func get_current_checkpoint_index() -> int:
	"""Получить индекс текущего чекпоинта"""
	return _current_checkpoint_index


func is_checkpoint_mode() -> bool:
	"""Проверить активен ли режим чекпоинтов"""
	return _checkpoint_mode


# ===== LIVE HUD DATA (standings / progress / next-turn) =====
# Считается по запросу из race_hud.gd на такте 0.2с. Геометрия — переиспользуем RaceRoute.

func _xz(v: Vector3) -> Vector2:
	return Vector2(v.x, v.z)


## Проекция игрока на маршрут (инкрементально от кэш-хинта). Возвращает дистанцию от старта (м).
func _project_player_distance() -> float:
	if _car == null or not is_instance_valid(_car) or _race_route == null or _race_route.points.size() < 2:
		return 0.0
	var proj: Dictionary = _race_route.project_position(_car.global_position, maxi(0, _player_seg_hint - 1))
	_player_seg_hint = int(proj.get("segment_idx", _player_seg_hint))
	return float(proj.get("distance", 0.0))


## Живая таблица мест для StandingsPanel. Форма, которую уже потребляет race_hud._update_standings():
## { rows: [{name, is_player, trend, gap_seconds}], player_pos, total }.
func get_live_standings() -> Dictionary:
	if _race_route == null or _race_route.points.size() < 2:
		return {}
	# Allow during COUNTDOWN too (opponents + route already exist) so the panel
	# is correct the moment the cards appear, not only once RACING begins.
	if current_state != State.RACING and current_state != State.FINISHED and current_state != State.COUNTDOWN:
		return {}

	var total_len: float = _race_route.total_length

	# Финиш: ключ -> {rank, time}. Игрок матчится по is_player, соперники по имени.
	var finish_rank := {}
	for i in range(_finish_order.size()):
		var f: Dictionary = _finish_order[i]
		var fkey: String = "player" if bool(f.get("is_player", false)) else "name:%s" % str(f.get("name", ""))
		finish_rank[fkey] = {"rank": i, "time": float(f.get("time", 0.0))}

	# Сущности
	var entries := []
	var p_fin: Dictionary = finish_rank.get("player", {})
	entries.append({
		"key": "player", "name": "ВЫ", "is_player": true,
		"distance": (total_len if not p_fin.is_empty() else _project_player_distance()),
		"finished": not p_fin.is_empty(),
		"finish_rank": int(p_fin.get("rank", 1 << 20)),
		"finish_time": float(p_fin.get("time", 0.0)),
	})
	for opp in _opponents:
		if not is_instance_valid(opp):
			continue
		var nm: String = str(opp.racer_name) if opp.get("racer_name") != null else "AI"
		var o_fin: Dictionary = finish_rank.get("name:%s" % nm, {})
		var od: float = float(opp.get_race_progress()) if opp.has_method("get_race_progress") else 0.0
		entries.append({
			"key": "opp_%d" % opp.get_instance_id(), "name": nm, "is_player": false,
			"distance": (total_len if not o_fin.is_empty() else od),
			"finished": not o_fin.is_empty(),
			"finish_rank": int(o_fin.get("rank", 1 << 20)),
			"finish_time": float(o_fin.get("time", 0.0)),
		})

	# Сортировка: финишировавшие первыми (по порядку финиша), затем активные по дистанции (убыв.)
	entries.sort_custom(func(a, b):
		if a["finished"] != b["finished"]:
			return a["finished"]
		if a["finished"] and b["finished"]:
			return a["finish_rank"] < b["finish_rank"]
		return a["distance"] > b["distance"])

	# Позиция игрока + опорные значения
	var player_pos := 1
	var player_entry: Dictionary = entries[0]
	for i in range(entries.size()):
		if entries[i]["is_player"]:
			player_pos = i + 1
			player_entry = entries[i]
			break

	var p_speed := STANDINGS_MIN_SPEED
	if _car_rigidbody and is_instance_valid(_car_rigidbody):
		p_speed = maxf(STANDINGS_MIN_SPEED, _car_rigidbody.linear_velocity.length())

	# Строки + тренд (vs прошлый опрос) + гэп относительно игрока
	var rows := []
	var new_state := {}
	for i in range(entries.size()):
		var e: Dictionary = entries[i]
		var place := i + 1
		var trend := 0
		if _standings_state.has(e["key"]):
			var last_pos: int = int(_standings_state[e["key"]].get("last_pos", place))
			trend = 1 if last_pos > place else (-1 if last_pos < place else 0)
		new_state[e["key"]] = {"last_pos": place}

		var gap := 0.0
		if not e["is_player"]:
			if e["finished"] and player_entry["finished"]:
				gap = e["finish_time"] - player_entry["finish_time"]   # раньше финишировал → < 0 (зелёный)
			else:
				gap = (player_entry["distance"] - e["distance"]) / p_speed  # впереди → < 0 (зелёный)
			if is_nan(gap) or is_inf(gap):
				gap = 0.0
			gap = clampf(gap, -3599.0, 3599.0)
		rows.append({"name": e["name"], "is_player": e["is_player"], "trend": trend, "gap_seconds": gap})
	_standings_state = new_state

	if race_hud_debug:
		var dbg := []
		for i in range(entries.size()):
			dbg.append("%d.%s d=%.0f%s" % [i + 1, entries[i]["name"], entries[i]["distance"], " FIN" if entries[i]["finished"] else ""])
		print("[RaceHUD] standings pos=%d/%d spd=%.1f | %s" % [player_pos, entries.size(), p_speed, ", ".join(dbg)])

	return {"rows": rows, "player_pos": player_pos, "total": entries.size()}


## Прогресс гонки для панели игрока (sprint % или чекпоинт X/Y). Только данные игрока.
func get_race_progress() -> Dictionary:
	var out := {
		"is_checkpoint": is_checkpoint_mode(),
		"progress_percent": 0,
		"checkpoint_index": 0,
		"checkpoint_total": 0,
		"checkpoint_timer": 0.0,
		"distance_to_finish": 0.0,
	}
	if is_checkpoint_mode():
		out["checkpoint_index"] = _current_checkpoint_index + 1
		if current_track and current_track.get("checkpoints") != null:
			out["checkpoint_total"] = (current_track.checkpoints as Array).size()
		out["checkpoint_timer"] = _checkpoint_timer
	if _race_route and _race_route.total_length > 1.0:
		var d := _project_player_distance()
		out["progress_percent"] = int(round(_race_route.get_progress_percent(d)))
		out["distance_to_finish"] = maxf(0.0, _race_route.total_length - d)
	return out


## Ближайший значимый поворот впереди по маршруту. Форма под NextTurnCard.set_turn().
## { valid, direction(left|right|straight), severity(easy|medium|sharp), distance_m }.
func get_next_turn() -> Dictionary:
	if (current_state != State.RACING and current_state != State.COUNTDOWN) or _race_route == null:
		return {"valid": false}
	var pts: Array = _race_route.points
	if pts.size() < 3 or _car == null or not is_instance_valid(_car):
		return {"valid": false}
	var proj: Dictionary = _race_route.project_position(_car.global_position, maxi(0, _player_seg_hint - 1))
	var cur_dist: float = float(proj.get("distance", 0.0))
	var start_idx: int = int(proj.get("segment_idx", 0))
	for i in range(start_idx, pts.size() - 2):
		var pv = pts[i + 1]   # вершина потенциального изгиба
		var vdist: float = pv.distance_from_start
		if vdist < cur_dist:
			continue
		if vdist - cur_dist > NEXT_TURN_LOOKAHEAD:
			break
		var d_in := _xz(pts[i + 1].position - pts[i].position)
		var d_out := _xz(pts[i + 2].position - pts[i + 1].position)
		if d_in.length() < 0.05 or d_out.length() < 0.05:
			continue
		d_in = d_in.normalized()
		d_out = d_out.normalized()
		var ang := rad_to_deg(acos(clampf(d_in.dot(d_out), -1.0, 1.0)))
		if ang < NEXT_TURN_MIN_DEG:
			continue
		var cross := d_in.x * d_out.y - d_in.y * d_out.x
		var is_left := (cross > 0.0) != NEXT_TURN_FLIP
		var direction := "left" if is_left else "right"
		var severity := "sharp" if ang >= 60.0 else ("medium" if ang >= 30.0 else "easy")
		var dist_m := int(round(vdist - cur_dist))
		if race_hud_debug:
			print("[RaceHUD] next_turn dir=%s sev=%s ang=%.0f dist=%d cross=%.2f" % [direction, severity, ang, dist_m, cross])
		return {"valid": true, "direction": direction, "severity": severity, "distance_m": dist_m}
	return {"valid": false}
