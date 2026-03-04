extends Node

# Automatic performance test for OSM Racing Game
# Test: Drive straight from Pionerskaya sprint start toward finish

@export var test_duration: float = 30.0  # 30 секунд после загрузки
@export var test_speed: float = 20.0  # m/s (~72 km/h)
@export var enable_night_mode: bool = false
@export var test_location: Vector2 = Vector2(59.149827, 37.948859)  # Pionerskaya sprint start
@export var finish_location: Vector2 = Vector2(59.142110, 37.943897)  # Pionerskaya sprint finish
@export var auto_quit_after_test: bool = true

var logger: PerformanceLogger
var car: Node3D
var vehicle_input: Node  # VehicleInput node
var osm_terrain: Node
var night_mode_manager: Node
var test_running: bool = false
var test_time: float = 0.0
var output_filename: String = ""
var _gpu_cpu_timer: float = 0.0
var _gpu_times: Array[float] = []
var _cpu_render_times: Array[float] = []

func _ready() -> void:
	# Fix random seed for reproducible tests
	seed(12345)
	print("\n========== Starting Performance Test ==========")
	print("Random seed: 12345 (fixed for reproducibility)")
	print("Location: Pionerskaya sprint start (%.4f, %.4f)" % [test_location.x, test_location.y])
	print("Duration: %.1f seconds" % test_duration)
	print("Night mode: %s" % ("ON" if enable_night_mode else "OFF"))
	print("==============================================\n")

	# Create logger (if available)
	var logger_script = load("res://tests/performance_logger.gd")
	if logger_script:
		logger = logger_script.new()
		add_child(logger)
		print("[PerformanceTest] Logger created")
	else:
		print("[PerformanceTest] WARNING: Could not load PerformanceLogger, test will run without CSV output")

	# Generate output filename with timestamp
	var datetime = Time.get_datetime_dict_from_system()
	output_filename = "user://performance_%04d%02d%02d_%02d%02d%02d.csv" % [
		datetime.year, datetime.month, datetime.day,
		datetime.hour, datetime.minute, datetime.second
	]

	# Wait a frame for scene to be ready
	await get_tree().process_frame

	# Find required nodes
	_find_nodes()

	if not car or not osm_terrain:
		push_error("[PerformanceTest] Failed to find required nodes!")
		return

	# Setup test (will start automatically when terrain loads)
	_setup_test()

func _find_nodes() -> void:
	# Find car (player vehicle)
	car = get_tree().get_first_node_in_group("player")
	if not car:
		# Try finding by type
		for node in get_tree().root.get_children():
			if node is VehicleBody3D:
				car = node
				break

	# Find VehicleInput
	if car:
		vehicle_input = car.get_node_or_null("VehicleInput")
		if not vehicle_input:
			# Try to find any VehicleInput node
			for child in car.get_children():
				if child.get_script() and "vehicle_input" in child.get_script().resource_path.to_lower():
					vehicle_input = child
					break

	# Find OSM terrain
	osm_terrain = get_node_or_null("/root/RaceScene/OSMTerrain")
	if not osm_terrain:
		osm_terrain = get_tree().get_first_node_in_group("osm_terrain")

	# Find night mode manager
	night_mode_manager = get_node_or_null("/root/RaceScene/NightModeManager")
	if not night_mode_manager:
		night_mode_manager = get_tree().get_first_node_in_group("night_mode_manager")

	print("[PerformanceTest] Found nodes:")
	print("  Car: %s" % ("YES" if car else "NO"))
	print("  VehicleInput: %s" % ("YES" if vehicle_input else "NO"))
	print("  OSMTerrain: %s" % ("YES" if osm_terrain else "NO"))
	print("  NightModeManager: %s" % ("YES" if night_mode_manager else "NO"))

func _apply_render_flags() -> void:
	var args := OS.get_cmdline_args()
	var env: Environment
	var we := get_node_or_null("WorldEnvironment") as WorldEnvironment
	if we:
		env = we.environment
	if not env:
		return
	var disabled: PackedStringArray = []
	for arg in args:
		if arg == "--no-sdfgi":
			env.sdfgi_enabled = false
			disabled.append("SDFGI")
		elif arg == "--no-ssr":
			env.ssr_enabled = false
			disabled.append("SSR")
		elif arg == "--no-ssao":
			env.ssao_enabled = false
			disabled.append("SSAO")
		elif arg == "--no-ssil":
			env.ssil_enabled = false
			disabled.append("SSIL")
		elif arg == "--no-volumetric-fog":
			env.volumetric_fog_enabled = false
			disabled.append("VolumetricFog")
		elif arg == "--no-glow":
			env.glow_enabled = false
			disabled.append("Glow")
	if disabled.is_empty():
		print("[PerfTest] Render: all effects enabled (matching main.tscn)")
	else:
		print("[PerfTest] Render: DISABLED %s" % " ".join(disabled))


func _setup_test() -> void:
	_apply_render_flags()
	# Set test location in Cherepovets
	if osm_terrain:
		# Connect to loading signals
		if osm_terrain.has_signal("initial_load_complete"):
			osm_terrain.initial_load_complete.connect(_on_terrain_loaded)
			print("[PerformanceTest] Connected to terrain loading signals")

		if osm_terrain.has_method("set_initial_position"):
			osm_terrain.set_initial_position(test_location)
			print("[PerformanceTest] Set initial position to Pionerskaya: %.4f, %.4f" % [test_location.x, test_location.y])

		# Start terrain loading
		if osm_terrain.has_method("start_loading"):
			print("[PerformanceTest] Starting terrain loading...")
			osm_terrain.start_loading()
		else:
			print("[PerformanceTest] WARNING: OSMTerrain doesn't have start_loading method!")
			# If auto-start, wait and then start test anyway
			await get_tree().create_timer(5.0).timeout
			_on_terrain_loaded()

	# Position car on nearest road (will be set after terrain loads)
	# Initial position at origin, will be adjusted in _on_terrain_loaded
	if car:
		car.global_position = Vector3(0, 1.0, 0)
		car.rotation = Vector3.ZERO

	# Enable night mode
	if enable_night_mode and night_mode_manager:
		if night_mode_manager.has_method("enable_night_mode"):
			night_mode_manager.enable_night_mode()
		elif night_mode_manager.has_method("set_night_mode"):
			night_mode_manager.set_night_mode(true)
		print("[PerformanceTest] Night mode enabled")

	# Disable UI if present
	var ui = get_node_or_null("/root/RaceScene/UI")
	if ui:
		ui.visible = false

func _on_terrain_loaded() -> void:
	print("\n[PerformanceTest] Terrain loaded! Positioning car on road...")

	# Position car like sprint race: on nearest road, facing finish direction
	_position_car_on_road()

	await get_tree().create_timer(2.0).timeout

	# Re-enable night mode before test (in case it got disabled)
	if enable_night_mode and night_mode_manager:
		if night_mode_manager.has_method("enable_night_mode"):
			night_mode_manager.enable_night_mode()
		night_mode_manager.set_process_input(false)
		print("[PerformanceTest] Night mode re-enabled and locked (input disabled)")

	_start_test()

# Position car like sprint race: at start location, facing toward finish
func _position_car_on_road() -> void:
	if not car or not osm_terrain:
		print("[PerformanceTest] Cannot position car: car or terrain missing")
		return

	# Convert start/finish lat/lon to local coordinates (same as RaceManager)
	var start_lat: float = osm_terrain.start_lat
	var start_lon: float = osm_terrain.start_lon
	var cos_lat := cos(deg_to_rad(start_lat))

	var start_local := Vector3(
		(test_location.y - start_lon) * cos_lat * 111000.0,
		1.0,
		-(test_location.x - start_lat) * 111000.0
	)
	var finish_local := Vector3(
		(finish_location.y - start_lon) * cos_lat * 111000.0,
		1.0,
		-(finish_location.x - start_lat) * 111000.0
	)

	# Find nearest road waypoint via TrafficManager (like sprint race)
	var traffic_manager = get_tree().current_scene.find_child("TrafficManager", true, false)
	if traffic_manager and traffic_manager.has_method("get_road_network"):
		var road_network = traffic_manager.get_road_network()
		if road_network and not road_network.all_waypoints.is_empty():
			var nearest_wp = road_network.get_nearest_waypoint(start_local)
			if nearest_wp:
				start_local = Vector3(nearest_wp.position.x, 1.0, nearest_wp.position.z)
				print("[PerformanceTest] Found road waypoint near start")

	# Face car toward finish (south along Pionerskaya)
	var dir := finish_local - start_local
	dir.y = 0
	var yaw := 0.0
	if dir.length_squared() > 0.01:
		yaw = atan2(dir.x, dir.z) + PI

	var new_transform := Transform3D()
	new_transform.origin = start_local
	new_transform.basis = Basis(Vector3.UP, yaw)
	car.global_transform = new_transform

	print("[PerformanceTest] Car positioned at (%.1f, %.1f, %.1f), facing %.1f deg (toward finish)" % [
		start_local.x, start_local.y, start_local.z, rad_to_deg(yaw)
	])

func _start_test() -> void:
	print("\n========== TEST STARTED ==========")
	print("Test will run for %.1f seconds" % test_duration)
	print("==================================\n")
	test_running = true
	test_time = 0.0
	# Отключаем ручной ввод чтобы тест контролировал машину
	if vehicle_input:
		vehicle_input.set_physics_process(false)
		vehicle_input.set_process_input(false)
	# Включаем 1-ю передачу и автомат
	if car and car.get("current_gear") != null:
		car.current_gear = 1
		car.automatic_transmission = true
		print("[PerformanceTest] Set gear 1, automatic transmission")
	if logger:
		logger.start_logging("pionerskaya_perftest")

func _process(delta: float) -> void:
	if not test_running:
		return

	# Log frame metrics (if logger exists)
	if logger:
		logger.log_frame()

	# Measure GPU vs CPU render time
	var vp_rid: RID = get_viewport().get_viewport_rid()
	var gpu_ms: float = RenderingServer.viewport_get_measured_render_time_gpu(vp_rid)
	var cpu_ms: float = RenderingServer.viewport_get_measured_render_time_cpu(vp_rid)
	_gpu_times.append(gpu_ms)
	_cpu_render_times.append(cpu_ms)

	_gpu_cpu_timer += delta
	if _gpu_cpu_timer >= 5.0:
		_gpu_cpu_timer = 0.0
		_print_gpu_cpu_stats(delta)

	# Update test time
	test_time += delta

	# Check if test is complete
	if test_time >= test_duration:
		_end_test()

func _physics_process(_delta: float) -> void:
	if not test_running:
		return

	# Apply constant throttle to maintain speed
	if car:
		car.throttle_input = 1.0
		car.brake_input = 0.0
		car.steering_input = 0.0
		car.handbrake_input = 0.0

func _end_test() -> void:
	if not test_running:
		return
	test_running = false
	print("\n[PerformanceTest] Test complete! Duration: %.1f s" % test_time)

	# Stop the car
	if car:
		car.throttle_input = 0.0
		car.brake_input = 1.0

	# Re-enable normal vehicle input
	if vehicle_input:
		vehicle_input.set_physics_process(true)

	if logger:
		# Stop logging and get summary
		var summary = logger.stop_logging()

		# Export to CSV
		logger.export_to_csv(output_filename)

		# Print summary
		logger.print_summary(summary)

		# Print file location
		print("\nResults saved to: %s" % output_filename)
		print("Absolute path: %s" % ProjectSettings.globalize_path(output_filename))
	else:
		print("\n[PerformanceTest] No logger available, skipping CSV export")

	# Final GPU/CPU stats
	_print_gpu_cpu_stats()

	# Quit if requested
	if auto_quit_after_test:
		print("\nQuitting application...")
		await get_tree().create_timer(1.0).timeout
		get_tree().quit()
	else:
		print("\nTest finished. You can continue playing or close the game.")

func _print_gpu_cpu_stats(_delta: float = 0.0) -> void:
	# GPU/CPU render times (may be 0 on macOS Metal)
	var gpu_avg := 0.0
	var gpu_max := 0.0
	var gpu_valid := 0
	for v in _gpu_times:
		if v > 0.0:
			gpu_avg += v
			gpu_max = maxf(gpu_max, v)
			gpu_valid += 1
	if gpu_valid > 0:
		gpu_avg /= gpu_valid

	var cpu_render_avg := 0.0
	var cpu_render_max := 0.0
	var cpu_valid := 0
	for v in _cpu_render_times:
		if v > 0.0:
			cpu_render_avg += v
			cpu_render_max = maxf(cpu_render_max, v)
			cpu_valid += 1
	if cpu_valid > 0:
		cpu_render_avg /= cpu_valid

	var fps: float = Engine.get_frames_per_second()
	var frame_ms: float = 1000.0 / maxf(fps, 1.0)

	# Infer bottleneck from GPU/CPU render times
	var bottleneck: String
	if gpu_valid > 0:
		if gpu_avg > cpu_render_avg * 1.2:
			bottleneck = "GPU-BOUND"
		elif cpu_render_avg > gpu_avg * 1.2:
			bottleneck = "CPU-BOUND"
		else:
			bottleneck = "BALANCED"
	else:
		bottleneck = "GPU timing N/A"

	var draw_calls: int = int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var objects: int = int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
	var vram_mb: float = Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0

	print("[BOTTLENECK] %s | FPS: %.0f | Frame: %.1f ms" % [bottleneck, fps, frame_ms])
	if gpu_valid > 0:
		print("  GPU render: %.2f ms avg (%.2f max) | CPU render: %.2f ms avg (%.2f max)" % [
			gpu_avg, gpu_max, cpu_render_avg, cpu_render_max])
	print("  Draw calls: %d | Objects: %d | VRAM: %.0f MB" % [draw_calls, objects, vram_mb])

	_gpu_times.clear()
	_cpu_render_times.clear()


func _input(event: InputEvent) -> void:
	# Allow manual test abort with Escape
	if event.is_action_pressed("ui_cancel") and test_running:
		print("\n[PerformanceTest] Test aborted by user")
		_end_test()
