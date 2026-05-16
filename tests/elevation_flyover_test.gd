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

# Path mode: camera follows a polyline of lat,lon waypoints
var path_waypoints: Array[Vector2] = []  # lat,lon pairs from --path CLI
var path_local: PackedVector2Array = PackedVector2Array()  # local XZ after conversion
var path_segment: int = 0
var path_t: float = 0.0
var path_from_deck: bool = false  # --path=deck: auto-build path from deck polygon
var path_reverse: bool = false    # --reverse: fly polygon in reverse order

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

# Debug HUD
var debug_label: Label

# Settings panel
var settings_panel: PanelContainer
var settings_visible := false


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
		elif arg.begins_with("--cam-height="):
			fly_height_above_ground = float(arg.substr(13))
		elif arg == "--path=deck":
			path_from_deck = true
		elif arg == "--reverse":
			path_reverse = true
		elif arg.begins_with("--path="):
			# Format: --path=lat1,lon1:lat2,lon2:lat3,lon3
			var pairs: PackedStringArray = arg.substr(7).split(":")
			for pair in pairs:
				var coords: PackedStringArray = pair.split(",")
				if coords.size() == 2:
					path_waypoints.append(Vector2(float(coords[0]), float(coords[1])))
			if path_waypoints.size() >= 2:
				test_location = path_waypoints[0]

	print("\n========== ELEVATION FLYOVER TEST ==========")
	print("Location: (%.4f, %.4f)" % [test_location.x, test_location.y])
	print("Chess pattern: %s" % ("ON — only every other chunk loads" if chess_pattern else "OFF — all chunks"))
	if path_from_deck:
		print("Path mode: DECK (will build from bridge deck polygon after load)")
	elif path_waypoints.size() >= 2:
		print("Path mode: %d waypoints" % path_waypoints.size())
		for wi in path_waypoints.size():
			print("  [%d] (%.6f, %.6f)" % [wi, path_waypoints[wi].x, path_waypoints[wi].y])
	print("Flying %.0f km/h at %.0fm above ground for %.0fs" % [fly_speed * 3.6, fly_height_above_ground, test_duration])
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

	# Debug HUD overlay
	var hud_canvas := CanvasLayer.new()
	hud_canvas.layer = 100
	add_child(hud_canvas)
	debug_label = Label.new()
	debug_label.position = Vector2(10, 10)
	debug_label.add_theme_font_size_override("font_size", 18)
	debug_label.add_theme_color_override("font_color", Color.WHITE)
	debug_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	debug_label.add_theme_constant_override("shadow_offset_x", 1)
	debug_label.add_theme_constant_override("shadow_offset_y", 1)
	hud_canvas.add_child(debug_label)

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
			osm_terrain.enable_behind_camera_cull = false
			enabled.append("-BehindCameraCull")
		elif arg == "--with-culling":
			osm_terrain.enable_behind_camera_cull = true
			enabled.append("BehindCameraCull")

	if enabled.is_empty():
		print("[ElevationFlyover] Features: terrain + roads only (use --with-buildings etc to enable)")
	else:
		print("[ElevationFlyover] Extra features enabled: %s" % ", ".join(enabled))
	print("[ElevationFlyover] Behind-camera culling: %s" % ("ON" if osm_terrain.enable_behind_camera_cull else "OFF"))


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

	# Apply CLI lat/lon — set spawn position (origin is fixed globally)
	if "spawn_lat" in osm_terrain:
		osm_terrain.spawn_lat = test_location.x
		osm_terrain.spawn_lon = test_location.y

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

	# Build path from deck polygon: straight line north→south
	if path_from_deck and osm_terrain and "_bridge_deck_polygons" in osm_terrain:
		var polys: Array = osm_terrain._bridge_deck_polygons
		print("  Deck polygons found: %d" % polys.size())
		# Find northernmost (min local.y) and southernmost (max local.y) vertex
		var north_pt := Vector2.ZERO
		var south_pt := Vector2.ZERO
		var min_z: float = INF
		var max_z: float = -INF
		for poly in polys:
			for v in poly:
				if v.y < min_z:
					min_z = v.y
					north_pt = v
				if v.y > max_z:
					max_z = v.y
					south_pt = v
		if min_z < INF and max_z > -INF:
			path_local.clear()
			if path_reverse:
				path_local.append(south_pt)
				path_local.append(north_pt)
				print("  Deck path: south→north (reversed)")
			else:
				path_local.append(north_pt)
				path_local.append(south_pt)
				print("  Deck path: north→south")
			var total_len: float = north_pt.distance_to(south_pt)
			test_duration = total_len / fly_speed + 5.0
			var s_lat: float = osm_terrain.start_lat if "start_lat" in osm_terrain else test_location.x
			var s_lon: float = osm_terrain.start_lon if "start_lon" in osm_terrain else test_location.y
			var lon_scale: float = cos(deg_to_rad(s_lat)) * 111000.0
			var n_lat: float = s_lat - north_pt.y / 111000.0
			var n_lon: float = s_lon + north_pt.x / lon_scale
			var s_lat2: float = s_lat - south_pt.y / 111000.0
			var s_lon2: float = s_lon + south_pt.x / lon_scale
			print("  North: local=(%.1f, %.1f) latlon=(%.6f, %.6f)" % [north_pt.x, north_pt.y, n_lat, n_lon])
			print("  South: local=(%.1f, %.1f) latlon=(%.6f, %.6f)" % [south_pt.x, south_pt.y, s_lat2, s_lon2])
			print("  Straight line: %.0fm, duration %.0fs" % [total_len, test_duration])
			camera.global_position.x = path_local[0].x
			camera.global_position.z = path_local[0].y
			var init_dir: Vector2 = path_local[1] - path_local[0]
			camera_yaw = rad_to_deg(atan2(-init_dir.x, -init_dir.y))
			camera.rotation_degrees = Vector3(camera_pitch, camera_yaw, 0)
		else:
			print("  WARNING: No deck polygon vertices found, falling back to south flight")

	# Convert path waypoints to local coordinates
	elif path_waypoints.size() >= 2 and osm_terrain and osm_terrain.has_method("_latlon_to_local"):
		path_local.clear()
		for wp in path_waypoints:
			var local: Vector2 = osm_terrain._latlon_to_local(wp.x, wp.y)
			path_local.append(local)
		# Compute total path length and set duration
		var total_len: float = 0.0
		for si in range(path_local.size() - 1):
			total_len += path_local[si].distance_to(path_local[si + 1])
		test_duration = total_len / fly_speed + 5.0  # +5s buffer
		print("  Path: %d local points, total %.0fm, duration %.0fs" % [
			path_local.size(), total_len, test_duration])
		# Start camera at first waypoint
		camera.global_position.x = path_local[0].x
		camera.global_position.z = path_local[0].y
		# Initial yaw toward second waypoint
		var init_dir: Vector2 = path_local[1] - path_local[0]
		camera_yaw = rad_to_deg(atan2(-init_dir.x, -init_dir.y))
		camera.rotation_degrees = Vector3(camera_pitch, camera_yaw, 0)

	# Position camera at spawn world offset
	if osm_terrain and osm_terrain.has_method("get_spawn_world_position"):
		var spawn_pos: Vector2 = osm_terrain.get_spawn_world_position()
		camera.global_position.x = spawn_pos.x
		camera.global_position.z = spawn_pos.y

	# Set fixed camera height = spawn elevation + fly_height_above_ground
	if osm_terrain and osm_terrain.has_method("get_spawn_elevation"):
		var elev: float = osm_terrain.get_spawn_elevation()
		if elev > 0.0:
			fixed_camera_y = elev + fly_height_above_ground
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

	# Move camera along path or south
	if path_local.size() >= 2:
		var advance: float = fly_speed * delta
		while advance > 0.0 and path_segment < path_local.size() - 1:
			var seg_start: Vector2 = path_local[path_segment]
			var seg_end: Vector2 = path_local[path_segment + 1]
			var seg_len: float = seg_start.distance_to(seg_end)
			if seg_len < 0.001:
				path_segment += 1
				path_t = 0.0
				continue
			var remaining: float = seg_len * (1.0 - path_t)
			if advance < remaining:
				path_t += advance / seg_len
				advance = 0.0
			else:
				advance -= remaining
				path_segment += 1
				path_t = 0.0
		if path_segment >= path_local.size() - 1:
			_end_test()
			return
		var a: Vector2 = path_local[path_segment]
		var b: Vector2 = path_local[path_segment + 1]
		var pos: Vector2 = a.lerp(b, path_t)
		camera.global_position.x = pos.x
		camera.global_position.z = pos.y
		# Camera Y from terrain + height
		if osm_terrain and osm_terrain.has_method("_sample_elevation"):
			var ground: float = osm_terrain._sample_elevation(pos.x, pos.y)
			if ground > 0.0:
				camera.global_position.y = ground + fly_height_above_ground
		# Smooth yaw rotation toward movement direction
		var seg_dir: Vector2 = b - a
		var target_yaw: float = rad_to_deg(atan2(-seg_dir.x, -seg_dir.y))
		var yaw_rad: float = lerp_angle(deg_to_rad(camera_yaw), deg_to_rad(target_yaw), minf(delta * 3.0, 1.0))
		camera_yaw = rad_to_deg(yaw_rad)
		camera.rotation_degrees = Vector3(camera_pitch, camera_yaw, 0)
	else:
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

	# Update debug HUD
	if debug_label and camera:
		var pos := camera.global_position
		var chunk_x := int(floor(pos.x / 210.0))
		var chunk_z := int(floor(pos.z / 210.0))
		var lat := 0.0
		var lon := 0.0
		if osm_terrain and "start_lat" in osm_terrain and "start_lon" in osm_terrain:
			lat = osm_terrain.start_lat - pos.z / 111000.0
			var lon_scale: float = cos(deg_to_rad(osm_terrain.start_lat)) * 111000.0
			lon = osm_terrain.start_lon + pos.x / lon_scale
		var elev := 0.0
		if osm_terrain and osm_terrain.has_method("_sample_elevation"):
			elev = osm_terrain._sample_elevation(pos.x, pos.z)
		debug_label.text = "Chunk: %d, %d | World: %.0f, %.0f | Elev: %.1f\nLat: %.6f  Lon: %.6f | FPS: %d" % [
			chunk_x, chunk_z, pos.x, pos.z, elev, lat, lon, Engine.get_frames_per_second()]

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

	if event is InputEventKey and event.pressed and event.keycode == KEY_P:
		_toggle_settings_panel()

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			mouse_dragging = event.pressed
	elif event is InputEventMouseMotion and mouse_dragging and camera:
		camera_yaw -= event.relative.x * 0.3
		camera_pitch -= event.relative.y * 0.3
		camera_pitch = clampf(camera_pitch, -89.0, 10.0)
		camera.rotation_degrees = Vector3(camera_pitch, camera_yaw, 0)


func _toggle_settings_panel() -> void:
	if not settings_panel:
		_create_settings_panel()
	settings_visible = not settings_visible
	settings_panel.visible = settings_visible


func _create_settings_panel() -> void:
	settings_panel = PanelContainer.new()
	settings_panel.name = "LODSettingsPanel"
	settings_panel.visible = false

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.1, 0.85)
	style.corner_radius_top_left = 8
	style.corner_radius_top_right = 8
	style.corner_radius_bottom_left = 8
	style.corner_radius_bottom_right = 8
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	settings_panel.add_theme_stylebox_override("panel", style)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_top", 4)
	settings_panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "LOD Settings (P to close)"
	title.add_theme_font_size_override("font_size", 16)
	vbox.add_child(title)

	if osm_terrain:
		_add_slider(vbox, "lod0_distance", 100.0, 1500.0, 50.0, "Full detail: roads, curbs, lamps, everything")
		_add_slider(vbox, "lod1_distance", 200.0, 3000.0, 50.0, "Medium: flat grass, textured buildings, billboard trees")
		_add_slider(vbox, "lod2_distance", 500.0, 5000.0, 100.0, "Minimal: flat grass, solid-color building boxes")
		_add_slider(vbox, "lod_hysteresis", 0.0, 200.0, 10.0, "Extra distance before downgrading LOD (prevents oscillation)")
		_add_separator(vbox)
		_add_checkbox(vbox, "enable_lod", "Enable LOD1/2 chunks. Off = only full-detail LOD0")
		_add_checkbox(vbox, "enable_behind_camera_cull", "Hide chunks behind camera (dot product test)")
		_add_slider(vbox, "behind_cull_dot", -1.0, 0.5, 0.05, "Dot threshold for LOD0 behind-camera cull. Lower = less aggressive")
		_add_slider(vbox, "lod_cull_dot", -1.0, 0.5, 0.05, "Dot threshold for LOD1/2 behind-camera cull. Lower = less aggressive")
		_add_separator(vbox)
		_add_slider(vbox, "render_distance", 100.0, 2000.0, 50.0, "Shadow/fog distance for LOD0 chunks")
		_add_slider(vbox, "load_distance", 100.0, 3000.0, 50.0, "Max distance to start loading new chunks")
		_add_slider(vbox, "unload_distance", 100.0, 4000.0, 100.0, "Distance at which loaded chunks get unloaded")

	# Position top-left
	settings_panel.position = Vector2(10, 10)

	var canvas := CanvasLayer.new()
	canvas.layer = 100
	add_child(canvas)
	canvas.add_child(settings_panel)


func _add_separator(parent: VBoxContainer) -> void:
	var sep := HSeparator.new()
	sep.add_theme_constant_override("separation", 4)
	parent.add_child(sep)


func _add_slider(parent: VBoxContainer, prop: String, min_val: float, max_val: float, step: float, hint: String = "") -> void:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	if hint:
		hbox.tooltip_text = hint

	var label := Label.new()
	label.text = prop
	label.custom_minimum_size.x = 200
	label.add_theme_font_size_override("font_size", 13)
	if hint:
		label.tooltip_text = hint
	hbox.add_child(label)

	var slider := HSlider.new()
	slider.min_value = min_val
	slider.max_value = max_val
	slider.step = step
	slider.value = osm_terrain.get(prop)
	slider.custom_minimum_size.x = 200
	if hint:
		slider.tooltip_text = hint
	hbox.add_child(slider)

	var value_label := Label.new()
	value_label.text = _format_val(slider.value)
	value_label.custom_minimum_size.x = 60
	value_label.add_theme_font_size_override("font_size", 13)
	if hint:
		value_label.tooltip_text = hint
	hbox.add_child(value_label)

	slider.value_changed.connect(func(val: float):
		osm_terrain.set(prop, val)
		value_label.text = _format_val(val)
	)

	parent.add_child(hbox)


func _add_checkbox(parent: VBoxContainer, prop: String, hint: String = "") -> void:
	var check := CheckBox.new()
	check.text = prop
	check.button_pressed = osm_terrain.get(prop)
	check.add_theme_font_size_override("font_size", 13)
	if hint:
		check.tooltip_text = hint
	check.toggled.connect(func(pressed: bool):
		osm_terrain.set(prop, pressed)
	)
	parent.add_child(check)


func _format_val(val: float) -> String:
	if absf(val) >= 10.0:
		return "%.0f" % val
	return "%.2f" % val
