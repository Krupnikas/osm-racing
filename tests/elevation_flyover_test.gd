extends Node

## Flyover test for elevation system with chess-pattern chunk loading.
## Only loads every other chunk (checkerboard), testing neighbor fallback
## and how roads/terrain handle missing adjacent chunks.
## Default location: Tbilisi (hilly terrain, ~500m ASL).

@export var test_duration: float = 60.0
@export var spike_threshold_ms: float = 25.0
@export var fly_speed: float = 27.78  # 100 km/h in m/s
@export var fly_height_above_ground: float = 38.0
@export var test_location: Vector2 = Vector2(41.723972, 44.730502)  # Tbilisi, Vazha-Pshavela
@export var auto_quit_after_test: bool = true
@export var chess_pattern: bool = true  # Only load every other chunk

var camera: Camera3D
var car: Node3D
var osm_terrain: Node
var logger: Node
var fixed_camera_y: float = 0.0
var mouse_dragging: bool = false
var camera_pitch: float = -55.0  # degrees, negative = looking down
var camera_yaw: float = 180.0    # degrees, 180 = facing south
var test_running: bool = false
var test_time: float = 0.0

# Phase tracking
enum Phase { LOADING, FLYING }
var current_phase: int = Phase.LOADING
var loading_start_time: float = 0.0

# Loading phase metrics
var loading_frame_times: PackedFloat64Array = PackedFloat64Array()
var loading_spikes: Array[Dictionary] = []
var loading_duration: float = 0.0

# Flying phase metrics
var frame_spikes: Array[Dictionary] = []
var frame_times: PackedFloat64Array = PackedFloat64Array()

# Chunk tracking
var initial_chunk_count: int = 0
var peak_chunk_count: int = 0
var chunks_skipped: int = 0


func _ready() -> void:
	seed(12345)
	# CLI overrides
	var all_args := OS.get_cmdline_args()
	all_args.append_array(OS.get_cmdline_user_args())
	for arg in all_args:
		if arg.begins_with("--test-lat="):
			test_location.x = float(arg.substr(11))
		elif arg.begins_with("--test-lon="):
			test_location.y = float(arg.substr(11))
		elif arg == "--no-chess":
			chess_pattern = false

	print("\n========== ELEVATION FLYOVER TEST ==========")
	print("Location: (%.4f, %.4f)" % [test_location.x, test_location.y])
	print("Chess pattern: %s" % ("ON — only every other chunk loads" if chess_pattern else "OFF — all chunks"))
	print("Flying south %.0f km/h at %.0fm above ground for %.0fs" % [fly_speed * 3.6, fly_height_above_ground, test_duration])
	print("Spike threshold: %.1f ms" % spike_threshold_ms)
	print("=============================================\n")

	# Create flying camera
	camera = Camera3D.new()
	camera.name = "FlyCamera"
	camera.rotation_degrees = Vector3(camera_pitch, camera_yaw, 0)
	add_child(camera)
	camera.global_position = Vector3(0, fly_height_above_ground, 0)
	camera.current = true
	camera.far = 2000.0

	# Load logger
	var logger_script = load("res://tests/performance_logger.gd")
	if logger_script:
		logger = logger_script.new()
		add_child(logger)

	await get_tree().process_frame
	_find_nodes()

	if not osm_terrain:
		push_error("[ElevationFlyover] Failed to find OSMTerrain!")
		return

	_setup_test()


func _find_nodes() -> void:
	car = get_tree().get_first_node_in_group("player")
	if not car:
		for node in get_tree().root.get_children():
			if node is VehicleBody3D:
				car = node
				break

	osm_terrain = get_tree().get_first_node_in_group("osm_terrain")
	if not osm_terrain:
		osm_terrain = get_node_or_null("OSMTerrain")

	print("[ElevationFlyover] Found: Car=%s, OSMTerrain=%s" % [
		"YES" if car else "NO", "YES" if osm_terrain else "NO"])


func _apply_feature_flags() -> void:
	if not osm_terrain:
		return
	var all_args := OS.get_cmdline_args()
	all_args.append_array(OS.get_cmdline_user_args())
	var enabled: PackedStringArray = []
	for arg in all_args:
		# Enable features one by one: --with-buildings, --with-lamps, etc.
		if arg == "--with-buildings":
			osm_terrain.enable_buildings = true
			enabled.append("Buildings")
		elif arg == "--with-vegetation":
			osm_terrain.enable_vegetation = true
			enabled.append("Vegetation")
		elif arg == "--with-lamps":
			osm_terrain.enable_street_lamps = true
			enabled.append("Lamps")
		elif arg == "--with-curbs":
			osm_terrain.enable_curbs = true
			enabled.append("Curbs")
		elif arg == "--with-signs":
			osm_terrain.enable_traffic_signs = true
			osm_terrain.enable_crossing_signs = true
			enabled.append("Signs")
		elif arg == "--with-traffic-lights":
			osm_terrain.enable_traffic_lights = true
			enabled.append("TrafficLights")
		elif arg == "--with-windows":
			osm_terrain.enable_windows = true
			enabled.append("Windows")
		elif arg == "--with-manholes":
			osm_terrain.enable_manholes = true
			enabled.append("Manholes")
		elif arg == "--with-fences":
			osm_terrain.enable_fences = true
			enabled.append("Fences")
		elif arg == "--no-roads":
			osm_terrain.enable_roads = false
			enabled.append("-Roads")
		elif arg == "--with-roads":
			osm_terrain.enable_roads = true
			enabled.append("Roads")
		elif arg == "--with-water":
			osm_terrain.enable_water = true
			enabled.append("Water")
		elif arg == "--with-all":
			osm_terrain.enable_buildings = true
			osm_terrain.enable_vegetation = true
			osm_terrain.enable_street_lamps = true
			osm_terrain.enable_curbs = true
			osm_terrain.enable_traffic_signs = true
			osm_terrain.enable_crossing_signs = true
			osm_terrain.enable_traffic_lights = true
			osm_terrain.enable_windows = true
			osm_terrain.enable_manholes = true
			osm_terrain.enable_fences = true
			osm_terrain.enable_water = true
			enabled.append("ALL")
		elif arg == "--no-culling":
			osm_terrain.enable_frustum_culling = false
			enabled.append("-FrustumCulling")
		elif arg == "--with-culling":
			osm_terrain.enable_frustum_culling = true
			enabled.append("FrustumCulling")

	if enabled.is_empty():
		print("[ElevationFlyover] Features: terrain + roads only (use --with-buildings etc to enable)")
	else:
		print("[ElevationFlyover] Extra features enabled: %s" % ", ".join(enabled))
	print("[ElevationFlyover] Frustum culling: %s" % ("ON" if osm_terrain.enable_frustum_culling else "OFF"))


func _setup_test() -> void:
	# Hide and freeze car
	if car:
		car.visible = false
		if car is RigidBody3D:
			car.freeze = true
		car.global_position = Vector3(0, 0.5, 0)
		var vehicle_input = car.get_node_or_null("VehicleInput")
		if vehicle_input:
			vehicle_input.set_physics_process(false)
			vehicle_input.set_process(false)

	# Apply feature flags
	_apply_feature_flags()

	# Apply chess pattern filter
	if chess_pattern and osm_terrain:
		osm_terrain.chunk_filter = Callable(self, "_chess_filter")
		print("[ElevationFlyover] Chess chunk filter: ON (every other chunk skipped)")
	else:
		print("[ElevationFlyover] Chess chunk filter: OFF (all chunks loaded)")

	# Apply CLI lat/lon
	if "start_lat" in osm_terrain:
		osm_terrain.start_lat = test_location.x
	if "start_lon" in osm_terrain:
		osm_terrain.start_lon = test_location.y

	# Enable elevation
	if "enable_elevation" in osm_terrain:
		osm_terrain.enable_elevation = true
		print("[ElevationFlyover] Elevation enabled")

	# Start loading phase
	current_phase = Phase.LOADING
	loading_start_time = Time.get_ticks_msec() / 1000.0
	print("\n--- PHASE 1: INITIAL LOAD ---")

	var signal_connected := false
	if osm_terrain.has_signal("initial_load_complete"):
		osm_terrain.initial_load_complete.connect(_on_terrain_loaded)
		signal_connected = true

	if osm_terrain.has_method("set_initial_position"):
		osm_terrain.set_initial_position(test_location)
	if osm_terrain.has_method("start_loading"):
		osm_terrain.start_loading()

	# Fallback timeout
	if signal_connected:
		await get_tree().create_timer(90.0).timeout
		if current_phase == Phase.LOADING:
			print("[ElevationFlyover] Fallback: 90s timeout, starting flight")
			_on_terrain_loaded()
	else:
		await get_tree().create_timer(90.0).timeout
		_on_terrain_loaded()


## Chess filter: only load chunks where (cx + cz) is even
func _chess_filter(cx: int, cz: int) -> bool:
	return (cx + cz) % 2 == 0


func _on_terrain_loaded() -> void:
	if current_phase != Phase.LOADING:
		return
	loading_duration = Time.get_ticks_msec() / 1000.0 - loading_start_time

	print("\n--- PHASE 1 RESULTS: INITIAL LOAD ---")
	print("  Duration: %.1f seconds" % loading_duration)
	print("  Frames: %d" % loading_frame_times.size())
	if loading_frame_times.size() > 0:
		var sorted_loading: Array = Array(loading_frame_times)
		sorted_loading.sort()
		var avg_l: float = 0.0
		for t in sorted_loading:
			avg_l += t
		avg_l /= sorted_loading.size()
		var worst_l: float = sorted_loading[sorted_loading.size() - 1]
		print("  Frame times: Avg=%.1f Worst=%.1f ms" % [avg_l, worst_l])
	print("  Spikes (>%.0fms): %d" % [spike_threshold_ms, loading_spikes.size()])
	var chunks_after_load: int = osm_terrain._loaded_chunks.size() if osm_terrain and "_loaded_chunks" in osm_terrain else -1
	print("  Chunks loaded: %d" % chunks_after_load)

	# Set fixed camera height = spawn elevation + 200m
	if osm_terrain and osm_terrain.has_method("get_spawn_elevation"):
		var elev: float = osm_terrain.get_spawn_elevation()
		if elev > 0.0:
			fixed_camera_y = elev + 200.0
			camera.global_position.y = fixed_camera_y
			print("  Spawn elevation: %.1fm ASL, camera fixed at %.1fm" % [elev, fixed_camera_y])

	print("-----------------------------------\n")
	print("[ElevationFlyover] Starting flight in 2 seconds...")
	await get_tree().create_timer(2.0).timeout
	_start_flight()


func _start_flight() -> void:
	current_phase = Phase.FLYING
	test_running = true
	test_time = 0.0

	if osm_terrain and "_initial_loading" in osm_terrain and osm_terrain._initial_loading:
		osm_terrain._initial_loading = false

	if osm_terrain and "_loaded_chunks" in osm_terrain:
		initial_chunk_count = osm_terrain._loaded_chunks.size()
		peak_chunk_count = initial_chunk_count

	if logger:
		logger.start_logging("elevation_flyover_test")

	print("--- PHASE 2: FLYING ---")
	print("[ElevationFlyover] Flying south at %.0f km/h, %.0fm above ground, %.0fs" % [
		fly_speed * 3.6, fly_height_above_ground, test_duration])


func _process(delta: float) -> void:
	var frame_time_ms: float = delta * 1000.0

	# Phase 1: Loading
	if current_phase == Phase.LOADING:
		loading_frame_times.append(frame_time_ms)
		if frame_time_ms > spike_threshold_ms:
			loading_spikes.append({
				"time": Time.get_ticks_msec() / 1000.0 - loading_start_time,
				"frame_time": frame_time_ms,
			})
		return

	if not test_running:
		return

	# Move camera south, maintain height above terrain
	camera.global_position.z += fly_speed * delta

	# Fixed camera height
	if fixed_camera_y > 0.0:
		camera.global_position.y = fixed_camera_y

	# Sync car position for chunk loading — drive at terrain height
	if car:
		var car_y := 0.5
		if osm_terrain and osm_terrain.has_method("_sample_elevation"):
			var ground: float = osm_terrain._sample_elevation(camera.global_position.x, camera.global_position.z)
			if ground > 0.0:
				car_y = ground + 0.5
		car.global_position = Vector3(camera.global_position.x, car_y, camera.global_position.z)

	# Track chunks
	if osm_terrain and "_loaded_chunks" in osm_terrain:
		var current_chunks: int = osm_terrain._loaded_chunks.size()
		if current_chunks > peak_chunk_count:
			peak_chunk_count = current_chunks

	frame_times.append(frame_time_ms)

	# Track spikes
	if frame_time_ms > spike_threshold_ms:
		var spike_data: Dictionary = {
			"time": test_time,
			"frame_time": frame_time_ms,
			"fps": Engine.get_frames_per_second(),
			"camera_y": camera.global_position.y,
			"camera_z": camera.global_position.z,
			"chunks": osm_terrain._loaded_chunks.size() if osm_terrain and "_loaded_chunks" in osm_terrain else -1,
		}
		frame_spikes.append(spike_data)
		if frame_time_ms > 40.0:
			print("SPIKE #%d: %.1f ms at %.1fs (y=%.0f z=%.0f chunks=%d)" % [
				frame_spikes.size(), frame_time_ms, test_time,
				spike_data.camera_y, spike_data.camera_z, spike_data.chunks])

	if logger:
		logger.log_frame()

	# Progress every 10s
	if int(test_time / 10.0) != int((test_time + delta) / 10.0) or test_time < delta:
		var chunks: int = osm_terrain._loaded_chunks.size() if osm_terrain and "_loaded_chunks" in osm_terrain else -1
		var vis: int = osm_terrain._culling_visible_count if osm_terrain and "_culling_visible_count" in osm_terrain else -1
		var cul: int = osm_terrain._culling_culled_count if osm_terrain and "_culling_culled_count" in osm_terrain else -1
		print("[%.0fs] y=%.0f z=%.0f chunks=%d (vis=%d cul=%d) fps=%d spikes=%d" % [
			test_time, camera.global_position.y, camera.global_position.z,
			chunks, vis, cul, Engine.get_frames_per_second(), frame_spikes.size()])

	test_time += delta
	if test_time >= test_duration:
		_end_test()


func _end_test() -> void:
	test_running = false
	var distance_traveled: float = fly_speed * test_time
	var final_chunks: int = osm_terrain._loaded_chunks.size() if osm_terrain and "_loaded_chunks" in osm_terrain else -1

	print("\n========== ELEVATION FLYOVER RESULTS ==========")
	print("Chess pattern: %s" % ("ON" if chess_pattern else "OFF"))

	print("\n--- PHASE 1: INITIAL LOAD ---")
	print("  Duration: %.1f s, Frames: %d, Spikes: %d" % [
		loading_duration, loading_frame_times.size(), loading_spikes.size()])

	print("\n--- PHASE 2: FLYING ---")
	print("  Duration: %.1f s" % test_time)
	print("  Distance: %.0f m (%.1f km)" % [distance_traveled, distance_traveled / 1000.0])
	print("  Chunks: initial=%d, peak=%d, final=%d" % [initial_chunk_count, peak_chunk_count, final_chunks])

	if frame_times.size() > 0:
		var sorted_times: Array = Array(frame_times)
		sorted_times.sort()
		var avg: float = 0.0
		for t in sorted_times:
			avg += t
		avg /= sorted_times.size()
		var p95: float = sorted_times[int(sorted_times.size() * 0.95)]
		var worst: float = sorted_times[sorted_times.size() - 1]
		print("\n  Frame times (ms):")
		print("    Avg: %.1f  P95: %.1f  Worst: %.1f" % [avg, p95, worst])
		print("    Total frames: %d  Avg FPS: %.0f" % [frame_times.size(), 1000.0 / avg])

	print("\n  Frame spikes (> %.1f ms): %d" % [spike_threshold_ms, frame_spikes.size()])
	if frame_spikes.size() > 0:
		var worst_spike: Dictionary = frame_spikes[0]
		for spike in frame_spikes:
			if spike.frame_time > worst_spike.frame_time:
				worst_spike = spike
		print("    Worst: %.1f ms at %.1fs (y=%.0f z=%.0f chunks=%d)" % [
			worst_spike.frame_time, worst_spike.time, worst_spike.camera_y,
			worst_spike.camera_z, worst_spike.chunks])

	# Export JSON
	var export_data: Dictionary = {
		"test_type": "elevation_flyover",
		"chess_pattern": chess_pattern,
		"location": {"lat": test_location.x, "lon": test_location.y},
		"loading_phase": {
			"duration_s": loading_duration,
			"total_frames": loading_frame_times.size(),
			"spikes": loading_spikes.size(),
		},
		"flying_phase": {
			"duration_s": test_time,
			"fly_speed_ms": fly_speed,
			"fly_height_above_ground": fly_height_above_ground,
			"distance_m": distance_traveled,
			"chunks": {"initial": initial_chunk_count, "peak": peak_chunk_count, "final": final_chunks},
			"total_frames": frame_times.size(),
			"frame_spikes": frame_spikes.size(),
		},
	}

	var file: FileAccess = FileAccess.open("user://elevation_flyover_test.json", FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(export_data, "\t"))
		file.close()
		print("\nResults saved to: %s" % ProjectSettings.globalize_path("user://elevation_flyover_test.json"))

	if logger:
		var summary = logger.stop_logging()
		logger.export_to_csv("user://elevation_flyover_test.csv")
		logger.print_summary(summary)

	print("\n================================================\n")

	if auto_quit_after_test:
		print("Quitting...")
		await get_tree().create_timer(1.0).timeout
		get_tree().quit()


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and test_running:
		print("\n[ElevationFlyover] Test aborted by user")
		_end_test()

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			mouse_dragging = event.pressed
	elif event is InputEventMouseMotion and mouse_dragging and camera:
		camera_yaw -= event.relative.x * 0.3
		camera_pitch -= event.relative.y * 0.3
		camera_pitch = clampf(camera_pitch, -89.0, 10.0)
		camera.rotation_degrees = Vector3(camera_pitch, camera_yaw, 0)
