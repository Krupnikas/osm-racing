extends Node3D

## Главная сцена свободной езды.
## Загружает террейн, показывает LoadingScreen, спавнит машину на дороге.

const WorkManagerScript = preload("res://work/work_manager.gd")
const WorkHudScript = preload("res://work/work_hud.gd")
const PassengerVoiceScript = preload("res://work/passenger_voice.gd")

var _terrain: Node3D
var _car: Node3D
var _car_rb: RigidBody3D
var _hud: Control
var _loading_screen: Control
var _pending_race_track = null


func _ready() -> void:
	# TEST-ONLY (env RACE_WORKTEST=<сек>): headless-запуск режима работы (= карьера «Выезд в город»).
	if OS.get_environment("RACE_WORKTEST") != "":
		RaceState.is_work_mode = true
		RaceState.free_roam_location = "Череповец"
		RaceState.free_roam_lat = 59.150406
		RaceState.free_roam_lon = 37.948805
		get_tree().create_timer(maxf(20.0, float(OS.get_environment("RACE_WORKTEST")))).timeout.connect(
			func() -> void: get_tree().quit())

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

	# HEADLESS AUTOTEST (env RACE_AUTOTEST=<сек>): автостарт гонки fanera_sprint + дамп
	# телеметрии соперников и выход. Ноль эффекта без переменной. ТЕСТ-ONLY, не коммитить.
	# RACE_LINEDUMP=1 — Phase-1 верификация: печатает геометрию K1999-линии соперника и выходит.
	var _linedump: bool = OS.get_environment("RACE_LINEDUMP") != ""
	if OS.get_environment("RACE_AUTOTEST") != "" or _linedump:
		_pending_race_track = load("res://race/race_tracks.gd").get_track_by_id("fanera_sprint")
		if _terrain and _pending_race_track.get("start_lat"):
			_terrain.spawn_lat = _pending_race_track.start_lat
			_terrain.spawn_lon = _pending_race_track.start_lon
		# Диагностика: RACE_LINEDUMP_SPAWN="lat,lon" смещает точку загрузки чанков (проверить,
		# не «под-картой»/off-road ли дальние точки просто из-за незагруженных чанков).
		var _sp: String = OS.get_environment("RACE_LINEDUMP_SPAWN")
		if _sp != "" and _terrain and _sp.split(",").size() == 2:
			_terrain.spawn_lat = float(_sp.split(",")[0])
			_terrain.spawn_lon = float(_sp.split(",")[1])
			print("LINEDUMP spawn override -> ", _terrain.spawn_lat, ",", _terrain.spawn_lon)
		if _linedump:
			_race_linedump_arm()
		else:
			_race_autotest_arm()

	await get_tree().process_frame
	_start_loading()

	if RaceState.is_work_mode:
		_setup_work_mode()


func _race_linedump_arm() -> void:
	# FULLLOAD: подгружаем чанки ВДОЛЬ ВСЕГО маршрута (dense route_points) и держим их (unload_distance
	# большой), чтобы проверить дальние точки при загруженных дорогах — не «одним прямоугольником».
	var track = _pending_race_track
	var full: bool = OS.get_environment("RACE_LINEDUMP_FULLLOAD") != ""
	var delay: float = 22.0
	if full:
		delay = 62.0
		if _terrain:
			_terrain.unload_distance = 3500.0
		get_tree().create_timer(8.0).timeout.connect(func() -> void:
			if _terrain and track and track.get("route_points") and _terrain.has_method("preload_route_chunks"):
				_terrain.preload_route_chunks(track.route_points)
				print("LINEDUMP FULLLOAD: preloaded %d route chunks; unload_distance=%.0f" % [
					track.route_points.size(), _terrain.unload_distance]))
	# Ждём построения линии (set_race_route в start_race после загрузки террейна), печатаем, выходим.
	get_tree().create_timer(delay).timeout.connect(func() -> void:
		print("LINEDUMP_VERIFY (Phase 1 — K1999 line geometry):")
		var printed := false
		for o in get_tree().get_nodes_in_group("race_opponent"):
			if is_instance_valid(o) and o.has_method("get_racing_line_debug"):
				if full and o.has_method("_build_racing_line"):
					o._build_racing_line()  # пересобрать линию теперь, когда все чанки маршрута загружены
					print("     REBUILT racing line with full route chunks loaded")
				var dbg: Dictionary = o.get_racing_line_debug()
				print("  => n=%d arc=%.0fm route_len=%.0fm max_curv=%.4f min_R=%.1fm v=[%.0f..%.0f]kmh off=[%.1f..%.1f]m fallback=%.0f%% onroad=%.0f%% fb_tail=%.0f%% first_fb_arc=%.0fm" % [
					int(dbg.get("n", 0)), float(dbg.get("arc_total", 0.0)), float(dbg.get("route_len", 0.0)),
					float(dbg.get("max_curv", 0.0)), float(dbg.get("min_radius", 0.0)),
					float(dbg.get("vmin_kmh", 0.0)), float(dbg.get("vmax_kmh", 0.0)),
					float(dbg.get("off_min", 0.0)), float(dbg.get("off_max", 0.0)),
					100.0 * float(dbg.get("fallback_frac", 0.0)), 100.0 * float(dbg.get("onroad_frac", 0.0)),
					100.0 * float(dbg.get("fb_tail_frac", 0.0)), float(dbg.get("first_fb_arc", -1.0))])
				print("     WHY-FALLBACK: loaded_segs=%d  fb_inf(chunk-not-loaded)=%d  fb_far(25-80m off centerline)=%d  fb_close(<=25m,bug)=%d  fb_maxdist_from_start=%.0fm" % [
					int(dbg.get("loaded_segs", 0)), int(dbg.get("fb_inf", 0)),
					int(dbg.get("fb_far", 0)), int(dbg.get("fb_close", 0)), float(dbg.get("fb_maxdist", 0.0))])
				for line in dbg.get("samples", []):
					print("     ", line)
				var jpath: String = OS.get_environment("RACE_LINEDUMP_JSON")
				if jpath != "" and o.has_method("export_racing_line_json"):
					var ok: bool = o.export_racing_line_json(jpath)
					print("     JSON export -> %s : %s" % [jpath, str(ok)])
				printed = true
				break
		if not printed:
			print("  => NO opponent with get_racing_line_debug (race not started / line empty)")
		get_tree().quit())


var _autotest_stats: Dictionary = {}  # name -> ground-truth accumulators
var _drivetest := false          # RACE_DRIVETEST: тащим игрока (и камеру) по маршруту → террейн стримится
var _drivetest_route = null
var _drivetest_dist := 0.0
const _DRIVETEST_SPEED := 6.0     # м/с — «игрок» ползёт медленно, чтобы соперники уехали в дальние чанки


func _process(delta: float) -> void:
	if _drivetest and _drivetest_route:
		_drivetest_dist += _DRIVETEST_SPEED * delta
		var pd: Dictionary = _drivetest_route.get_point_at_distance(_drivetest_dist)
		var p: Vector3 = pd.position
		var player := get_tree().get_first_node_in_group("player") as Node3D
		if player:
			player.global_position = Vector3(p.x, p.y + 1.0, p.z)


func _log_stream_state() -> void:
	var cam := get_viewport().get_camera_3d()
	var campos: Vector3 = cam.global_position if cam else Vector3.ZERO
	var nchunks := 0
	if _terrain:
		var lc = _terrain.get("_loaded_chunks")
		if lc is Dictionary:
			nchunks = (lc as Dictionary).size()
	var space := get_world_3d().direct_space_state
	var parts: Array = ["STREAM cam=(%.0f,%.0f) chunks=%d" % [campos.x, campos.z, nchunks]]
	for o in get_tree().get_nodes_in_group("race_opponent"):
		if not is_instance_valid(o):
			continue
		var pp: Vector3 = o.global_position
		var dg := "NONE"
		if space:
			var q := PhysicsRayQueryParameters3D.create(pp + Vector3(0, 25, 0), pp + Vector3(0, -300, 0))
			q.collision_mask = 1
			var hit := space.intersect_ray(q)
			if not hit.is_empty():
				dg = "%.1f" % (pp.y - float(hit.position.y))
		parts.append("%s pr%.0f y%.1f grnd=%s kin=%s" % [o.racer_name, o.race_progress, pp.y, dg, str(o._kinematic)])
	print(" | ".join(parts))

func _race_autotest_arm() -> void:
	# Начинаем ЧЕСТНУЮ выборку, когда соперники поехали (после загрузки + отсчёта)
	get_tree().create_timer(17.0).timeout.connect(func() -> void:
		for o in get_tree().get_nodes_in_group("race_opponent"):
			if is_instance_valid(o) and o.has_method("clear_debug_samples"):
				o.ai_debug = true
				o.clear_debug_samples()
			if is_instance_valid(o) and o.has_method("enable_collision_metric"):
				o.enable_collision_metric()   # Phase 0: реальный счётчик столкновений на реальной трассе
		print("HONEST_SAMPLER armed: opp=", get_tree().get_nodes_in_group("race_opponent").size())
		# RACE_BLOCKTEST: ставим узкую стену ПРЯМО НА ЛИНИИ впереди — проверяем, объезжают ли (context
		# steering) и реверсит ли реально упёршийся. width=2.2м на дороге ~7м → есть чистая сторона.
		if OS.get_environment("RACE_BLOCKTEST") != "":
			var opp: Array = get_tree().get_nodes_in_group("race_opponent")
			if opp.size() > 0 and opp[0].race_route:
				var d: float = float(opp[0].race_progress) + 50.0
				var wp: Vector3 = opp[0].race_route.get_point_at_distance(d).position
				var wall := StaticBody3D.new()
				wall.collision_layer = 2  # статическая помеха (как здание)
				var cs := CollisionShape3D.new()
				var box := BoxShape3D.new()
				box.size = Vector3(2.2, 3.0, 1.0)
				cs.shape = box
				wall.add_child(cs)
				add_child(wall)
				wall.global_position = Vector3(wp.x, wp.y + 1.5, wp.z)
				print("[BLOCKTEST] narrow wall at prog %.0f pos (%.0f,%.0f)" % [d, wp.x, wp.z])
		var t := Timer.new()
		t.wait_time = 0.2
		t.autostart = true
		add_child(t)
		t.timeout.connect(_autotest_sample)
		# STREAM state logger (камера, число загруженных чанков, земля-под-каждым-соперником, kinematic)
		var st := Timer.new()
		st.wait_time = 2.0
		st.autostart = true
		add_child(st)
		st.timeout.connect(_log_stream_state)
		# RACE_DRIVETEST: двигаем КАМЕРУ по маршруту (террейн стримится вокруг неё) — воспроизводим
		# реальную езду игрока, чтобы дальние чанки НЕ были загружены и соперники уезжали в них.
		if OS.get_environment("RACE_DRIVETEST") != "":
			_drivetest = true
			var opp0: Array = get_tree().get_nodes_in_group("race_opponent")
			if opp0.size() > 0:
				_drivetest_route = opp0[0].race_route
			print("[DRIVETEST] camera will crawl the route at %.0f m/s" % _DRIVETEST_SPEED))
	get_tree().create_timer(float(OS.get_environment("RACE_AUTOTEST"))).timeout.connect(func() -> void:
		_autotest_report()
		get_tree().quit())


func _autotest_sample() -> void:
	# Ground truth: луч ВНИЗ от точки над машиной на слой дорог/террейна (1). Если Y машины
	# ниже поверхности → едет ПОД картой (провал, а не прогресс). Виляние/скорость считаем
	# ТОЛЬКО пока машина реально на дороге и движется — под картой руль ровный, это не успех.
	var space := get_world_3d().direct_space_state
	for o in get_tree().get_nodes_in_group("race_opponent"):
		if not is_instance_valid(o):
			continue
		var nm: String = o.racer_name
		if not _autotest_stats.has(nm):
			_autotest_stats[nm] = {"n": 0, "under": 0, "onmove": 0, "flip": 0, "lastsign": 0,
				"world_d": 0.0, "lastpos": o.global_position, "maxbelow": 0.0, "vmax": 0.0, "vsum": 0.0,
				"trace": []}
		var s: Dictionary = _autotest_stats[nm]
		var pos: Vector3 = o.global_position
		var q := PhysicsRayQueryParameters3D.create(pos + Vector3(0, 25, 0), pos + Vector3(0, -50, 0))
		q.collision_mask = 1
		var hit: Dictionary = space.intersect_ray(q)
		var on_ground: bool = not hit.is_empty()
		var above: float = 999.0
		if on_ground:
			above = pos.y - float(hit.position.y)
		var under: bool = on_ground and above < -0.8
		var v: float = o.current_speed_kmh
		s.n += 1
		if under:
			s.under += 1
		s.maxbelow = minf(s.maxbelow, above if on_ground else 0.0)
		s.world_d += Vector2(pos.x - s.lastpos.x, pos.z - s.lastpos.z).length()
		s.lastpos = pos
		s.vmax = maxf(s.vmax, v)
		if on_ground and not under and v > 8.0:
			s.onmove += 1
			s.vsum += v
			var st: float = o.steering_input
			if absf(st) > 0.15:
				var sg := 1 if st > 0.0 else -1
				if s.lastsign != 0 and sg != s.lastsign:
					s.flip += 1
				s.lastsign = sg
		# Трейс только МЕДЛЕННЫХ моментов на дороге (v<12) — чтобы видеть ПРИЧИНУ краула
		if v < 12.0 and on_ground and not under and (s.trace as Array).size() < 60:
			(s.trace as Array).append("t%.1f v%.0f st%d thr%.1f urg%.2f safe%.0f blk%d p(%.0f,%.0f)" % [
				float(s.n) * 0.2, v, int(o.ai_state), float(o.throttle_input), float(o.dbg_urgency),
				float(o.dbg_safe), (1 if o.dbg_blocked else 0), pos.x, pos.z])
		_autotest_stats[nm] = s


func _autotest_report() -> void:
	print("HONEST_VERIFY (ground-truth; under-map/off-road/stuck = FAIL):")
	print("  DEBUG opponents_now=%d stats_keys=%s" % [get_tree().get_nodes_in_group("race_opponent").size(), str(_autotest_stats.keys())])
	for o in get_tree().get_nodes_in_group("race_opponent"):
		if not is_instance_valid(o):
			continue
		var nm: String = o.racer_name
		if not _autotest_stats.has(nm):
			continue
		var s: Dictionary = _autotest_stats[nm]
		var n: int = maxi(1, s.n)
		var under_pct: float = 100.0 * float(s.under) / float(n)
		var onmove_pct: float = 100.0 * float(s.onmove) / float(n)
		var avg_on: float = s.vsum / maxf(1.0, float(s.onmove))
		var verdict := "OK"
		if under_pct > 2.0:
			verdict = "FAIL:under-map"
		elif onmove_pct < 60.0:
			verdict = "FAIL:stuck/slow"
		elif s.flip > 12:
			verdict = "FAIL:weaving"
		var rec := 0
		var obs_frac := 0.0
		if o.has_method("get_debug_summary"):
			var gsum: Dictionary = o.get_debug_summary()
			rec = int(gsum.get("recovery_count", 0))
			obs_frac = float((gsum.get("global", {}) as Dictionary).get("obstacle_active_frac", 0.0))
		print("  %s: under_map=%.0f%% onroad_moving=%.0f%% world_dist=%.0fm vmax=%.0f avg_on=%.0f weave_flips=%d rec=%d avoid=%.0f%% max_below=%.1fm prog=%.0f state=%s => %s" % [
			nm, under_pct, onmove_pct, float(s.world_d), float(s.vmax), avg_on, int(s.flip),
			rec, 100.0 * obs_frac, float(s.maxbelow), o.get_race_progress(), str(o.ai_state), verdict])
		if o.has_method("get_collision_metric"):
			var cm: Dictionary = o.get_collision_metric()
			print("    %s COLLISIONS: static=%d corner_static=%d | dynamic=%d (npc=%d racer=%d)" % [
				nm, cm.static, cm.corner_static, cm.dynamic, cm.get("npc", 0), cm.get("racer", 0)])
			print("      %s EVENTS [prog_m,kmh,kind]: %s" % [nm, str(cm.get("events", []))])
		if verdict != "OK" or nm == "AI 1":
			var tr: Array = s.trace
			for k in range(0, tr.size(), 2):
				print("      [%s] %s" % [nm, tr[k]])


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

	# Start terrain loading first — this computes the world offset for float precision.
	# Car positioning must happen AFTER so coordinates are in the shifted system.
	if _terrain:
		_terrain.start_loading()
	else:
		_start_game()
		return

	if _car_rb:
		var spawn_offset: Vector2 = _terrain.get_spawn_world_position()
		var spawn_y: float = 2.0
		if _terrain.get("enable_elevation"):
			var elev: float = _terrain.get_spawn_elevation()
			if elev > 0.0:
				spawn_y = elev + 2.0
		_car.global_position = Vector3(spawn_offset.x, spawn_y, spawn_offset.y)
		_car.rotation = Vector3.ZERO


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
			# --shot: держим машину замороженной для стабильных скриншотов (без отката).
			if OS.get_cmdline_user_args().has("--shot"):
				_car_rb.freeze = true


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

	var passenger_voice := Node.new()
	passenger_voice.name = "PassengerVoice"
	passenger_voice.set_script(PassengerVoiceScript)
	add_child(passenger_voice)
	passenger_voice.setup(work_manager, car, terrain)
