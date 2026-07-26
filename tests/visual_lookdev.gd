extends Node3D

## Визуальный look-dev: загружает реальную (кэшированную) локацию, ставит уличную
## 3/4 камеру, ждёт прогрузку чанков и делает скриншоты ДЕНЬ / НОЧЬ / НОЧЬ+ДОЖДЬ.
## Скриншоты пишутся в res://screenshots/visual/ для сравнения с референсами
## (день ~ GTA V, ночь ~ NFS Underground).
##
## Запуск (GUI, не headless):
##   Godot --path . tests/visual_lookdev.tscn
## Флаги:
##   --shot-lat= / --shot-lon=     локация (по умолч. Пионерская, Череповец)
##   --load-wait=SECONDS           сколько ждать прогрузку чанков (по умолч. 16)
##   --cam-pos=x,y,z               позиция камеры
##   --cam-look=x,y,z              точка, на которую смотрит камера
##   --only=day|night|rain         снять только одну фазу (по умолч. все)
##   --free                        свободная камера (WASD+мышь), без автосъёмки — для подбора ракурса
##   --no-quit                     не выходить после съёмки

@export var shot_lat: float = 59.149827
@export var shot_lon: float = 37.948859
@export var load_wait: float = 16.0

var camera: Camera3D
var osm_terrain: Node
var night_mgr: Node

var cam_pos := Vector3(7.0, 2.1, 9.0)
var cam_look := Vector3(-2.0, 1.2, -18.0)
var only_phase := ""
var free_cam := false
var do_quit := true
var _cam_override := false

const OUT_DIR := "res://screenshots/visual/"


func _parse_vec3(s: String) -> Vector3:
	var p := s.split(",")
	if p.size() != 3:
		return Vector3.ZERO
	return Vector3(float(p[0]), float(p[1]), float(p[2]))


func _ready() -> void:
	var args := OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	for a in args:
		if a.begins_with("--shot-lat="): shot_lat = float(a.substr(11))
		elif a.begins_with("--shot-lon="): shot_lon = float(a.substr(11))
		elif a.begins_with("--load-wait="): load_wait = float(a.substr(12))
		elif a.begins_with("--cam-pos="): cam_pos = _parse_vec3(a.substr(10)); _cam_override = true
		elif a.begins_with("--cam-look="): cam_look = _parse_vec3(a.substr(11)); _cam_override = true
		elif a.begins_with("--only="): only_phase = a.substr(7)
		elif a == "--free": free_cam = true
		elif a == "--no-quit": do_quit = false

	# Гарантируем каталог вывода
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	# Настроим локацию генератора ДО _ready OSMTerrain? он уже в дереве,
	# поэтому проставим start_lat/lon и дадим ему стартовать.
	osm_terrain = get_node_or_null("OSMTerrain")
	if osm_terrain:
		osm_terrain.spawn_lat = shot_lat
		osm_terrain.spawn_lon = shot_lon

	camera = Camera3D.new()
	camera.name = "LookDevCamera"
	camera.fov = 55.0
	camera.far = 2000.0
	add_child(camera)
	# временная позиция, реальную выставим после прогрузки относительно машины
	camera.global_position = Vector3(0, 200, 0)
	camera.current = true

	night_mgr = get_node_or_null("NightModeManager")

	print("\n===== VISUAL LOOK-DEV =====")
	print("Location: (%.6f, %.6f)" % [shot_lat, shot_lon])
	print("Cam pos=%s look=%s" % [cam_pos, cam_look])
	print("Load wait: %.0fs  free=%s only=%s" % [load_wait, free_cam, only_phase])
	print("===========================\n")

	if free_cam:
		set_process(true)  # свободная камера в _process
		return

	_run_capture_sequence.call_deferred()


var _car: Node3D = null

func _spawn_on_road() -> Vector3:
	# Спавн-точка → ближайший waypoint дорожной сети → рейкаст до поверхности.
	var off: Vector2 = osm_terrain.get_spawn_world_position()
	var elev: float = osm_terrain.get_spawn_elevation()
	var base := Vector3(off.x, (elev if elev > 0.1 else 2.0), off.y)

	var tm := get_node_or_null("TrafficManager")
	if tm and tm.has_method("get_road_network"):
		var rn = tm.get_road_network()
		if rn and not rn.all_waypoints.is_empty():
			var wp = rn.get_nearest_waypoint(base)
			if wp != null and wp.position.is_finite():
				base = wp.position
				print("[lookdev] snapped to road waypoint %s" % base)

	# Точный рейкаст вниз до коллизии дороги/террейна
	var space := get_viewport().world_3d.direct_space_state
	var q := PhysicsRayQueryParameters3D.create(base + Vector3(0, 120, 0), base - Vector3(0, 120, 0))
	q.collision_mask = 1
	var hit := space.intersect_ray(q)
	if not hit.is_empty():
		base.y = hit.position.y
	return base


const CAR_GROUND_OFFSET := 0.4  # origin машины над поверхностью коллизии (колёса)

func _place_hero() -> void:
	# Ставим машину ЗАМОРОЖЕННОЙ на дорогу (GEVP-физика взрывается при спавне в геометрии),
	# лицом на юг (+Z); камера сзади (север) видит корму — геймплейный chase-ракурс.
	_car = get_node_or_null("Car")
	var road_pos := _spawn_on_road()
	var cp := road_pos + Vector3(0, CAR_GROUND_OFFSET, 0)
	if _car:
		if _car is RigidBody3D:
			_car.freeze = true
			_car.linear_velocity = Vector3.ZERO
			_car.angular_velocity = Vector3.ZERO
		_car.global_position = cp
		_car.rotation = Vector3(0, PI, 0)  # перёд на юг (+Z)
	if _cam_override:
		# смещения ОТНОСИТЕЛЬНО машины (для разглядывания LOD-границ и т.п.)
		camera.global_position = cp + cam_pos
		camera.look_at(cp + cam_look, Vector3.UP)
	else:
		camera.global_position = cp + Vector3(0.0, 2.5, -6.8)     # сзади (север), сверху
		camera.look_at(cp + Vector3(0.0, 0.7, 14.0), Vector3.UP)  # взгляд на юг (+Z)
	print("[lookdev] car frozen at %s, cam=%s facing south" % [cp, camera.global_position])


func _run_capture_sequence() -> void:
	# Ждём прогрузку чанков
	print("[lookdev] waiting %.0fs for chunks to stream..." % load_wait)
	await get_tree().create_timer(load_wait).timeout
	await _settle(6)
	_place_hero()
	await _settle(8)

	if only_phase == "" or only_phase == "day":
		print("[lookdev] capturing DAY...")
		await _settle(4)
		await _shoot("day")

	# DUSK = «половина перехода день→ночь»: ловим сцену в середине tween-а
	# (фонари загораются, солнце наполовину погашено, небо/glow уже вечерние).
	if only_phase == "" or only_phase == "dusk":
		if night_mgr and night_mgr.has_method("enable_night_mode"):
			print("[lookdev] DUSK: half transition day->night...")
			night_mgr.enable_night_mode()
			await get_tree().create_timer(0.9).timeout  # ~середина 1.5с tween
			await _shoot("dusk")
			if only_phase == "dusk":
				# завершим переход, чтобы не оставлять полусостояние
				await get_tree().create_timer(2.0).timeout

	if only_phase == "" or only_phase == "night":
		if night_mgr and night_mgr.has_method("enable_night_mode"):
			# при полной последовательности переход уже запущен в DUSK — просто ждём финала
			if only_phase != "":
				night_mgr.enable_night_mode()
			print("[lookdev] settling to full NIGHT...")
			await get_tree().create_timer(2.5).timeout  # добираем остаток tween
			await _settle(6)
			await _shoot("night")

	if only_phase == "" or only_phase == "rain":
		if night_mgr and night_mgr.has_method("toggle_rain"):
			# гарантируем ночь
			if only_phase == "rain" and night_mgr.has_method("enable_night_mode"):
				night_mgr.enable_night_mode()
				await get_tree().create_timer(3.0).timeout
			print("[lookdev] enabling RAIN...")
			night_mgr.toggle_rain()
			await get_tree().create_timer(6.0).timeout  # wetness tween 5s
			await _settle(6)
			await _shoot("night_rain")

	print("[lookdev] DONE. Screenshots in %s" % OUT_DIR)
	if do_quit:
		await _safe_quit()


func _safe_quit() -> void:
	# Скриншоты уже синхронно записаны на диск (save_png вернул OK).
	# Обычный get_tree().quit() у движка падает на teardown: WorkerThreadPool::finish()
	# уничтожает висящие bound-Callable уже полу-снесённого GDScript → SIGSEGV + окно ошибки.
	# Для тестовой утилиты жёстко завершаем процесс SIGKILL — мгновенно, без crash-handler.
	print("[lookdev] hard-exit (SIGKILL) to skip crashy engine teardown")
	await _settle(2)
	OS.kill(OS.get_process_id())


func _settle(frames: int) -> void:
	for i in frames:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw


func _shoot(tag: String) -> void:
	var img := get_viewport().get_texture().get_image()
	var path := OUT_DIR + tag + ".png"
	var err := img.save_png(ProjectSettings.globalize_path(path))
	if err == OK:
		print("[lookdev] saved %s (%dx%d)" % [path, img.get_width(), img.get_height()])
	else:
		push_error("[lookdev] save failed %s err=%d" % [path, err])


# --- free camera ---
var _yaw := 0.0
var _pitch := 0.0
func _process(delta: float) -> void:
	if not free_cam:
		return
	var spd := 20.0 if Input.is_key_pressed(KEY_SHIFT) else 7.0
	var dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): dir -= camera.global_transform.basis.z
	if Input.is_key_pressed(KEY_S): dir += camera.global_transform.basis.z
	if Input.is_key_pressed(KEY_A): dir -= camera.global_transform.basis.x
	if Input.is_key_pressed(KEY_D): dir += camera.global_transform.basis.x
	if Input.is_key_pressed(KEY_E): dir += Vector3.UP
	if Input.is_key_pressed(KEY_Q): dir -= Vector3.UP
	camera.global_position += dir.normalized() * spd * delta
	if Input.is_key_pressed(KEY_P):
		print("cam-pos=%.1f,%.1f,%.1f" % [camera.global_position.x, camera.global_position.y, camera.global_position.z])


func _unhandled_input(event: InputEvent) -> void:
	if not free_cam:
		return
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		_yaw -= event.relative.x * 0.005
		_pitch = clamp(_pitch - event.relative.y * 0.005, -1.4, 1.4)
		camera.rotation = Vector3(_pitch, _yaw, 0)
