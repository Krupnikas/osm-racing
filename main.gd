extends Node3D

## Главная сцена свободной езды.
## Загружает террейн, показывает LoadingScreen, спавнит машину на дороге.

const WorkManagerScript = preload("res://work/work_manager.gd")
const WorkHudScript = preload("res://work/work_hud.gd")

var _terrain: Node3D
var _car: Node3D
var _car_rb: RigidBody3D
var _hud: Control
var _loading_screen: Control
var _pending_race_track = null


func _ready() -> void:
	var new_car := CarSpawner.replace_player_car(self)
	_terrain = $OSMTerrain
	_car = new_car if new_car else $Car
	_car_rb = _car if _car is RigidBody3D else null
	_hud = find_child("HUD", true, false)
	_loading_screen = find_child("LoadingScreen", true, false)

	if RaceState.is_work_mode:
		MusicManager.set_category(MusicManager.Category.WORK)
	else:
		MusicManager.set_category(MusicManager.ALL_CATEGORIES)

	# Подключаем сигналы террейна
	if _terrain and _terrain.get_script():
		_terrain.initial_load_started.connect(_on_load_started)
		_terrain.initial_load_progress.connect(_on_load_progress)
		_terrain.initial_load_complete.connect(_on_load_complete)

	_hide_world()

	# CLI аргументы (--terrain-only)
	var args := OS.get_cmdline_user_args()
	for i in range(args.size()):
		if args[i] == "--terrain-only" and _terrain:
			_terrain.enable_buildings = false
			_terrain.enable_vegetation = false
			_terrain.enable_street_lamps = false

	# Координаты из RaceState — spawn position (origin is always fixed)
	if _terrain:
		if RaceState.free_roam_lat != 0.0:
			_terrain.spawn_lat = RaceState.free_roam_lat
			_terrain.spawn_lon = RaceState.free_roam_lon

	# Отложенный трек для гонки (перезагрузка через "Заново")
	if RaceState.pending_track != null:
		_pending_race_track = RaceState.pending_track
		RaceState.pending_track = null
		if _terrain and _pending_race_track.get("start_lat"):
			_terrain.spawn_lat = _pending_race_track.start_lat
			_terrain.spawn_lon = _pending_race_track.start_lon

	# Очищаем состояние
	RaceState.free_roam_location = ""
	RaceState.free_roam_lat = 0.0
	RaceState.free_roam_lon = 0.0

	await get_tree().process_frame
	_start_loading()

	if RaceState.is_work_mode:
		_setup_work_mode()


func _start_loading() -> void:
	if _loading_screen:
		_loading_screen.visible = true
		_loading_screen.set_progress(0.0)
		_loading_screen.set_status("Подготовка...")

	# Замораживаем машину
	if _car_rb:
		_car_rb.linear_velocity = Vector3.ZERO
		_car_rb.angular_velocity = Vector3.ZERO
		_car_rb.freeze = true
		var spawn_offset := Vector2.ZERO
		if _terrain:
			spawn_offset = _terrain.get_spawn_world_position()
		var spawn_y: float = 2.0
		if _terrain and _terrain.get("enable_elevation"):
			var elev: float = _terrain.get_spawn_elevation()
			if elev > 0.0:
				spawn_y = elev + 2.0
		_car.global_position = Vector3(spawn_offset.x, spawn_y, spawn_offset.y)
		_car.rotation = Vector3.ZERO

	if _terrain:
		_terrain.start_loading()
	else:
		_start_game()


func _on_load_started() -> void:
	if _loading_screen:
		_loading_screen.set_progress(0.0)
		_loading_screen.set_status("Загрузка карты...")


func _on_load_progress(progress: float, status: String) -> void:
	if _loading_screen:
		_loading_screen.set_progress(progress)
		_loading_screen.set_status(status)


func _on_load_complete() -> void:
	if _loading_screen:
		_loading_screen.set_progress(1.0)
		_loading_screen.set_status("Готово!")
	await get_tree().create_timer(0.3).timeout
	_start_game()


func _start_game() -> void:
	_spawn_car_on_road()
	await get_tree().physics_frame
	if not is_instance_valid(_car):
		return
	_show_world()

	if _hud:
		_hud.show_hud()

	if _loading_screen:
		_loading_screen.visible = false

	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	# Автозапуск гонки если есть отложенный трек
	if _pending_race_track:
		var race_manager = find_child("RaceManager", true, false)
		if race_manager:
			await get_tree().process_frame
			race_manager.start_race(_pending_race_track)
		_pending_race_track = null


func _spawn_car_on_road() -> void:
	if not _car:
		return

	# Get elevation from loaded data (available after initial_load_complete)
	var spawn_elev := 0.0
	if _terrain and _terrain.get("enable_elevation"):
		spawn_elev = _terrain.get_spawn_elevation()

	var traffic_manager = find_child("TrafficManager", true, false)
	if not traffic_manager or not traffic_manager.has_method("get_road_network"):
		_set_car_spawn_y(spawn_elev)
		return
	var road_network = traffic_manager.get_road_network()
	if road_network == null or road_network.all_waypoints.is_empty():
		_set_car_spawn_y(spawn_elev)
		return

	var nearest_wp = road_network.get_nearest_waypoint(_car.global_position)
	if nearest_wp == null:
		_set_car_spawn_y(spawn_elev)
		return

	var road_pos: Vector3 = nearest_wp.position
	var road_dir: Vector3 = nearest_wp.direction
	if not road_pos.is_finite():
		road_pos = Vector3(_car.global_position.x, spawn_elev + 0.5, _car.global_position.z)
	if not road_dir.is_finite():
		road_dir = Vector3(0, 0, 1)

	# Рейкаст для высоты поверхности (на мостах используем wp.position.y)
	if not nearest_wp.is_bridge:
		var space_state := _car.get_world_3d().direct_space_state
		var ray_from := Vector3(road_pos.x, maxf(road_pos.y + 200.0, 2000.0), road_pos.z)
		var ray_to := Vector3(road_pos.x, minf(road_pos.y - 200.0, -10.0), road_pos.z)
		var ray_query := PhysicsRayQueryParameters3D.create(ray_from, ray_to)
		ray_query.collision_mask = 1
		var ray_result := space_state.intersect_ray(ray_query)
		if not ray_result.is_empty():
			road_pos.y = ray_result.position.y + 0.1
		elif spawn_elev > 0.1:
			road_pos.y = spawn_elev + 0.5
		else:
			road_pos.y += 0.1
	else:
		road_pos.y += 0.1

	if not (_car_rb is RigidBody3D):
		return
	_car_rb.linear_velocity = Vector3.ZERO
	_car_rb.angular_velocity = Vector3.ZERO
	_car_rb.freeze = true
	_car.global_position = road_pos
	if not _car.global_position.is_finite():
		_car.global_position = Vector3(0, 2, 0)

	var final_yaw := 0.0
	if road_dir.length_squared() > 0.01:
		final_yaw = atan2(road_dir.x, road_dir.z)
		_car.rotation = Vector3(0, final_yaw, 0)

	if not is_nan(RaceState.spawn_heading_yaw):
		final_yaw = RaceState.spawn_heading_yaw
		_car.rotation = Vector3(0, final_yaw, 0)
		RaceState.spawn_heading_yaw = NAN

	if not _car.rotation.is_finite():
		_car.rotation = Vector3.ZERO

	# GEVP: 1-я передача, автомат
	if _car_rb.get("current_gear") != null:
		_car_rb.current_gear = 1
		if _car_rb.get("automatic_transmission") != null:
			_car_rb.automatic_transmission = true


func _set_car_spawn_y(elev: float) -> void:
	if not _car or not (_car_rb is RigidBody3D):
		return
	var y: float = elev + 0.5 if elev > 0.1 else 2.0
	_car.global_position.y = y
	_car_rb.linear_velocity = Vector3.ZERO
	_car_rb.angular_velocity = Vector3.ZERO


func _hide_world() -> void:
	if _car:
		_car.visible = false
		if _car_rb is RigidBody3D:
			_car_rb.freeze = true


func _show_world() -> void:
	if _car:
		_car.visible = true
		if _car_rb is RigidBody3D:
			_car_rb.linear_velocity = Vector3.ZERO
			_car_rb.angular_velocity = Vector3.ZERO
			if not _car.global_position.is_finite():
				_car.global_position = Vector3(0, 2, 0)
			if not _car.rotation.is_finite():
				_car.rotation = Vector3.ZERO
			_car_rb.freeze = false
			# Dampen velocities for a few frames to prevent bounce on unfreeze
			for i in 3:
				await get_tree().physics_frame
				if not is_instance_valid(_car_rb):
					return
				_car_rb.linear_velocity = Vector3.ZERO
				_car_rb.angular_velocity = Vector3.ZERO


func _setup_work_mode() -> void:
	await get_tree().process_frame
	var car := get_tree().get_first_node_in_group("car")
	var terrain := find_child("OSMTerrain", true, false)
	var hud := find_child("HUD", true, false)

	var work_manager := Node.new()
	work_manager.name = "WorkManager"
	work_manager.set_script(WorkManagerScript)
	add_child(work_manager)

	var work_hud := CanvasLayer.new()
	work_hud.name = "WorkHUD"
	work_hud.layer = 10
	work_hud.set_script(WorkHudScript)
	add_child(work_hud)

	work_manager.setup(car, terrain, work_hud)
	work_hud.setup(work_manager)
