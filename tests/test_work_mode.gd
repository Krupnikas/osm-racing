extends Node3D

## Тест режима работы (такси).
## Загружает мир, создаёт WorkManager, автоматически рулит к точкам.
##
## Запуск:
##   /Applications/Godot.app/Contents/MacOS/Godot --path . tests/test_work_mode.tscn
##   -- --test-lat=59.1504 --test-lon=37.9488
##
## Флаги:
##   --test-lat=XX --test-lon=YY  — координаты (дефолт: Череповец)
##   --auto-drive                 — автопилот к pickup/dropoff (дефолт: вкл)
##   --test-orders=N              — завершить после N заказов (дефолт: 3)

const WorkManagerScript = preload("res://work/work_manager.gd")
const WorkHudScript = preload("res://work/work_hud.gd")

@export var test_location: Vector2 = Vector2(59.150406, 37.948805)
@export var max_orders: int = 3
@export var auto_drive: bool = true

var _car: Node3D
var _osm_terrain: Node
var _work_manager: Node
var _work_hud: Node
var _camera: Camera3D

var _orders_done: int = 0
var _test_start_time: float = 0.0
var _phase: String = "loading"
var _steer_target := Vector3.ZERO
var _hud_node: Control


func _ready() -> void:
	_parse_args()
	print("\n========== WORK MODE TEST ==========")
	print("Location: (%.4f, %.4f)" % [test_location.x, test_location.y])
	print("Auto-drive: %s" % auto_drive)
	print("Max orders: %d" % max_orders)
	print("=====================================\n")

	await get_tree().process_frame
	_find_nodes()

	if not _osm_terrain:
		push_error("[WorkTest] No OSMTerrain found!")
		return

	# Задаём координаты — spawn position (origin is fixed globally)
	if "spawn_lat" in _osm_terrain:
		_osm_terrain.spawn_lat = test_location.x
		_osm_terrain.spawn_lon = test_location.y

	# Запускаем камеру
	_setup_camera()

	# Ждём загрузки terrain
	_test_start_time = Time.get_ticks_msec() / 1000.0
	print("[WorkTest] Waiting for terrain to load...")

	if _osm_terrain.has_signal("initial_load_complete"):
		_osm_terrain.initial_load_complete.connect(_on_terrain_loaded)

	if _osm_terrain.has_method("set_initial_position"):
		_osm_terrain.set_initial_position(test_location)
	if _osm_terrain.has_method("start_loading"):
		_osm_terrain.start_loading()

	# Fallback timeout
	await get_tree().create_timer(30.0).timeout
	if _phase == "loading":
		print("[WorkTest] Timeout, starting anyway...")
		_on_terrain_loaded()


func _parse_args() -> void:
	var all_args := OS.get_cmdline_args()
	all_args.append_array(OS.get_cmdline_user_args())
	for arg in all_args:
		if arg.begins_with("--test-lat="):
			test_location.x = float(arg.substr(11))
		elif arg.begins_with("--test-lon="):
			test_location.y = float(arg.substr(11))
		elif arg.begins_with("--test-orders="):
			max_orders = int(arg.substr(14))
		elif arg == "--no-auto-drive":
			auto_drive = false


func _find_nodes() -> void:
	_car = get_tree().get_first_node_in_group("car")
	if not _car:
		_car = get_tree().get_first_node_in_group("player")
	_osm_terrain = get_node_or_null("OSMTerrain")
	if not _osm_terrain:
		_osm_terrain = find_child("OSMTerrain", true, false)

	_hud_node = find_child("HUD", true, false)

	print("[WorkTest] Found: Car=%s, OSMTerrain=%s, HUD=%s" % [
		"YES" if _car else "NO",
		"YES" if _osm_terrain else "NO",
		"YES" if _hud_node else "NO"])


func _setup_camera() -> void:
	# Ищем существующую камеру или создаём chase-камеру
	_camera = get_viewport().get_camera_3d()
	if not _camera and _car:
		_camera = Camera3D.new()
		_camera.name = "TestCamera"
		add_child(_camera)
		_camera.current = true


func _on_terrain_loaded() -> void:
	if _phase != "loading":
		return
	var elapsed := Time.get_ticks_msec() / 1000.0 - _test_start_time
	print("[WorkTest] Terrain loaded in %.1fs" % elapsed)
	_phase = "working"

	# Показываем HUD
	if _hud_node and _hud_node.has_method("show_hud"):
		_hud_node.show_hud()

	# Отключаем ручное управление при автопилоте
	if auto_drive and _car:
		for child_name in ["VehicleInput", "VehicleController"]:
			var ctrl := _car.get_node_or_null(child_name)
			if ctrl:
				ctrl.set_physics_process(false)
				ctrl.set_process(false)
				print("[WorkTest] Disabled %s for auto-drive" % child_name)

	# Создаём WorkManager
	_work_manager = Node.new()
	_work_manager.name = "WorkManager"
	_work_manager.set_script(WorkManagerScript)
	add_child(_work_manager)

	# Создаём WorkHUD
	_work_hud = CanvasLayer.new()
	_work_hud.name = "WorkHUD"
	_work_hud.layer = 10
	_work_hud.set_script(WorkHudScript)
	add_child(_work_hud)

	_work_manager.setup(_car, _osm_terrain, _work_hud)
	_work_hud.setup(_work_manager)

	# Слушаем события
	_work_manager.order_spawned.connect(_on_order_spawned)
	_work_manager.order_completed.connect(_on_order_completed)

	print("[WorkTest] WorkManager initialized, waiting for first order...")


func _on_order_spawned(pickup_pos: Vector3) -> void:
	print("[WorkTest] Order spawned at (%.1f, %.1f, %.1f)" % [pickup_pos.x, pickup_pos.y, pickup_pos.z])
	_steer_target = pickup_pos


func _on_order_completed(result: Dictionary) -> void:
	_orders_done += 1
	print("[WorkTest] === Order %d/%d completed ===" % [_orders_done, max_orders])
	print("  Fare: %d rub" % result.fare)
	print("  Speed bonus: %d rub (%.0f%%)" % [result.speed_bonus, result.speed_pct * 100])
	print("  Safe bonus: %d rub (%.0f%%)" % [result.safe_bonus, result.safe_pct * 100])
	print("  Total: %d rub" % result.total)
	print("  Time: %.1fs (estimated %.1fs)" % [result.elapsed, result.estimated])
	print("  Client: \"%s\"" % result.phrase)

	if _orders_done >= max_orders:
		_finish_test()


func _physics_process(delta: float) -> void:
	if not auto_drive or _phase != "working":
		return
	if not _car or not is_instance_valid(_car):
		return
	if not _work_manager:
		return

	# Обновляем камеру (chase)
	_update_chase_camera(delta)

	var state: int = _work_manager.get_state()

	# Auto-accept order
	if state == 1:  # AT_PICKUP
		print("[WorkTest] At pickup, auto-accepting...")
		_work_manager.accept_order()
		_steer_target = _work_manager.get_dropoff_pos()
		return

	# Auto-close result
	if state == 3:  # AT_DROPOFF
		print("[WorkTest] At dropoff, auto-closing result...")
		_work_manager.finish_result_screen()
		return

	# Auto-steer toward target
	if state == 0:  # SEARCHING — drive to nearest pickup
		var pickups: Array = _work_manager.get_available_pickups()
		if not pickups.is_empty():
			_steer_target = _find_nearest(pickups)
		_auto_steer_toward(_steer_target, delta)
	elif state == 2:  # DRIVING
		_auto_steer_toward(_steer_target, delta)


func _find_nearest(positions: Array) -> Vector3:
	var car_pos := _car.global_position
	var best_dist := INF
	var best_pos := Vector3.ZERO
	for pos in positions:
		var p: Vector3 = pos
		var dist := car_pos.distance_to(p)
		if dist < best_dist:
			best_dist = dist
			best_pos = p
	return best_pos


func _auto_steer_toward(target: Vector3, _delta: float) -> void:
	"""Простой автопилот — GEVP Vehicle API (throttle_input, steering_input, brake_input)"""
	if not _car is RigidBody3D:
		return

	var car_pos := _car.global_position
	var to_target := target - car_pos
	to_target.y = 0
	var dist := to_target.length()

	if dist < 5.0:
		return

	var forward := -_car.global_transform.basis.z
	forward.y = 0
	forward = forward.normalized()
	var to_dir := to_target.normalized()

	var cross := forward.cross(to_dir).y
	var dot := forward.dot(to_dir)

	# GEVP: steering_input (-1..1), throttle_input (0..1), brake_input (0..1)
	_car.steering_input = clampf(cross * 2.5, -1.0, 1.0)

	var speed := (_car as RigidBody3D).linear_velocity.length() * 3.6
	if dot < 0:
		_car.throttle_input = 0.0
		_car.brake_input = 0.8
		_car.steering_input = clampf(cross * 4.0, -1.0, 1.0)
	elif speed > 50.0:
		_car.throttle_input = 0.0
		_car.brake_input = 0.3
	else:
		_car.throttle_input = 0.7
		_car.brake_input = 0.0


func _update_chase_camera(_delta: float) -> void:
	if not _camera or not _car or not is_instance_valid(_car):
		return
	# Простая chase-камера
	var target_pos := _car.global_position
	var forward := -_car.global_transform.basis.z
	var cam_pos := target_pos + Vector3(0, 8, 0) - forward * 12.0
	_camera.global_position = _camera.global_position.lerp(cam_pos, 0.05)
	_camera.look_at(target_pos + Vector3(0, 1, 0))


func _finish_test() -> void:
	var elapsed := Time.get_ticks_msec() / 1000.0 - _test_start_time
	print("\n========== WORK MODE TEST RESULTS ==========")
	print("Total time: %.1fs" % elapsed)
	print("Orders completed: %d/%d" % [_orders_done, max_orders])
	if CareerState:
		print("Balance: %s" % CareerState.format_money(CareerState.balance))
	print("=============================================\n")
	_phase = "done"

	# Не выходим — даём пользователю осмотреть
	print("[WorkTest] Test complete. Close window to exit.")
