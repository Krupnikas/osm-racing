extends Node

## Тест производительности загрузки чанков.
## Фаза 1: Начальная загрузка — камера стоит, профилируется отдельно.
## Фаза 2: Полёт — камера летит на юг на высоте 38м со скоростью 100 км/ч (60с).
## Всё остальное как в игре — NPC, профилирование, здания, деревья.

@export var test_duration: float = 60.0
@export var spike_threshold_ms: float = 16.0
@export var fly_speed: float = 27.78  # 100 km/h in m/s
@export var fly_height: float = 38.0
@export var test_location: Vector2 = Vector2(59.150406, 37.955805)  # Cherepovets east
@export var auto_quit_after_test: bool = true

var camera: Camera3D
var car: Node3D
var osm_terrain: Node
var logger: Node
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
var physics_spikes: Array[Dictionary] = []
var frame_times: PackedFloat64Array = PackedFloat64Array()

# Chunk tracking
var initial_chunk_count: int = 0
var peak_chunk_count: int = 0

# Settings panel
var settings_panel: PanelContainer
var settings_visible := false


func _ready() -> void:
	seed(12345)
	# CLI override: --test-lat=50.0614 --test-lon=19.9383
	var all_args := OS.get_cmdline_args()
	all_args.append_array(OS.get_cmdline_user_args())
	for arg in all_args:
		if arg.begins_with("--test-lat="):
			test_location.x = float(arg.substr(11))
		elif arg.begins_with("--test-lon="):
			test_location.y = float(arg.substr(11))
		elif arg.begins_with("--fly-height="):
			fly_height = float(arg.substr(13))
		elif arg.begins_with("--fly-speed="):
			fly_speed = float(arg.substr(12))
	print("\n========== CHUNK LOAD PERFORMANCE TEST ==========")
	print("Location: (%.4f, %.4f)" % [test_location.x, test_location.y])
	print("Phase 1: Initial load (camera stationary, profiled separately)")
	print("Phase 2: Flying south %.0f km/h at %.0fm for %.0fs" % [fly_speed * 3.6, fly_height, test_duration])
	print("Spike threshold: %.1f ms" % spike_threshold_ms)
	print("===================================================\n")

	# Create flying camera
	camera = Camera3D.new()
	camera.name = "FlyCamera"
	camera.rotation_degrees = Vector3(-15, 180, 0)  # facing south, slightly down
	add_child(camera)
	camera.global_position = Vector3(0, fly_height, 0)
	camera.current = true

	# Load logger
	var logger_script = load("res://tests/performance_logger.gd")
	if logger_script:
		logger = logger_script.new()
		add_child(logger)

	await get_tree().process_frame
	_find_nodes()

	if not osm_terrain:
		push_error("[ChunkLoadTest] Failed to find OSMTerrain!")
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

	print("[ChunkLoadTest] Found: Car=%s, OSMTerrain=%s" % [
		"YES" if car else "NO", "YES" if osm_terrain else "NO"])


func _apply_render_flags() -> void:
	var args := OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	var disabled: PackedStringArray = []

	# Render flags (Environment)
	var env: Environment
	var we := get_node_or_null("WorldEnvironment") as WorldEnvironment
	if we:
		env = we.environment
	if env:
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

	# Scene feature flags (OSM terrain generator)
	if osm_terrain:
		for arg in args:
			if arg == "--perf-verbose":
				osm_terrain._perf_verbose = true
				disabled.append("(perf-verbose: log every slow frame)")
			elif arg == "--no-bush-shadows":
				osm_terrain.enable_bush_shadows = false
				disabled.append("BushShadows")
			elif arg == "--no-buildings":
				osm_terrain.enable_buildings = false
				disabled.append("Buildings")
			elif arg == "--no-vegetation":
				osm_terrain.enable_vegetation = false
				disabled.append("Vegetation")
			elif arg == "--no-bushes":
				osm_terrain.enable_bushes = false
				disabled.append("Bushes")
			elif arg == "--no-lamps":
				osm_terrain.enable_street_lamps = false
				disabled.append("Lamps")
			elif arg == "--no-signs":
				osm_terrain.enable_traffic_signs = false
				osm_terrain.enable_crossing_signs = false
				disabled.append("Signs")
			elif arg == "--no-traffic-lights":
				osm_terrain.enable_traffic_lights = false
				disabled.append("TrafficLights")
			elif arg == "--no-curbs":
				osm_terrain.enable_curbs = false
				disabled.append("Curbs")
			elif arg == "--no-windows":
				osm_terrain.enable_windows = false
				disabled.append("Windows")
			elif arg == "--no-manholes":
				osm_terrain.enable_manholes = false
				disabled.append("Manholes")
			elif arg == "--no-roads":
				osm_terrain.enable_roads = false
				disabled.append("Roads")
			elif arg == "--no-fences":
				osm_terrain.enable_fences = false
				disabled.append("Fences")
			elif arg == "--no-road-smoothing":
				osm_terrain.enable_road_smoothing = false
				disabled.append("RoadSmoothing")

	# Traffic flags
	var traffic_mgr := get_node_or_null("TrafficManager")
	if traffic_mgr:
		for arg in args:
			if arg == "--no-npcs":
				traffic_mgr.max_npcs = 0
				disabled.append("NPCs")

	if disabled.is_empty():
		print("[ChunkLoadTest] All features enabled (baseline)")
	else:
		print("[ChunkLoadTest] DISABLED: %s" % " ".join(disabled))


func _setup_test() -> void:
	_apply_render_flags()
	# Hide and freeze car — only used as NPC spawn anchor
	if car:
		car.visible = false
		if car is RigidBody3D:
			car.freeze = true
		car.global_position = Vector3(0, 0.5, 0)
		var vehicle_input = car.get_node_or_null("VehicleInput")
		if vehicle_input:
			vehicle_input.set_physics_process(false)
			vehicle_input.set_process(false)

	# Start loading phase
	current_phase = Phase.LOADING
	loading_start_time = Time.get_ticks_msec() / 1000.0
	print("\n--- PHASE 1: INITIAL LOAD ---")
	print("[ChunkLoadTest] Camera stationary, profiling initial chunk load...")

	# Apply CLI lat/lon — spawn position (origin is fixed globally)
	osm_terrain.spawn_lat = test_location.x
	osm_terrain.spawn_lon = test_location.y

	var signal_connected := false
	if osm_terrain.has_signal("initial_load_complete"):
		osm_terrain.initial_load_complete.connect(_on_terrain_loaded)
		signal_connected = true

	if osm_terrain.has_method("set_initial_position"):
		osm_terrain.set_initial_position(test_location)

	if osm_terrain.has_method("start_loading"):
		osm_terrain.start_loading()

	# Fallback timeout (60s for dense areas like Krakow center)
	if signal_connected:
		await get_tree().create_timer(60.0).timeout
		if current_phase == Phase.LOADING:
			print("[ChunkLoadTest] Fallback: 60s timeout, starting flight phase")
			_on_terrain_loaded()
	else:
		await get_tree().create_timer(60.0).timeout
		_on_terrain_loaded()


func _on_terrain_loaded() -> void:
	if current_phase != Phase.LOADING:
		return
	loading_duration = Time.get_ticks_msec() / 1000.0 - loading_start_time

	# Print loading phase results immediately
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
		var p95_l: float = sorted_loading[int(sorted_loading.size() * 0.95)]
		print("  Frame times: Avg=%.1f P95=%.1f Worst=%.1f ms" % [avg_l, p95_l, worst_l])
	print("  Spikes (>%.0fms): %d" % [spike_threshold_ms, loading_spikes.size()])
	if loading_spikes.size() > 0:
		var worst_ls: Dictionary = loading_spikes[0]
		for s in loading_spikes:
			if s.frame_time > worst_ls.frame_time:
				worst_ls = s
		print("  Worst spike: %.1f ms" % worst_ls.frame_time)
	var chunks_after_load: int = osm_terrain._loaded_chunks.size() if osm_terrain and "_loaded_chunks" in osm_terrain else -1
	print("  Chunks loaded: %d" % chunks_after_load)
	print("-----------------------------------\n")

	print("[ChunkLoadTest] Starting flight in 2 seconds...")
	await get_tree().create_timer(2.0).timeout
	_start_flight()


func _start_flight() -> void:
	current_phase = Phase.FLYING
	test_running = true
	test_time = 0.0
	# Force _initial_loading = false so gameplay budgets apply during flying
	if osm_terrain and "_initial_loading" in osm_terrain and osm_terrain._initial_loading:
		print("[ChunkLoadTest] Forcing _initial_loading = false for gameplay budgets")
		osm_terrain._initial_loading = false

	if osm_terrain and "_loaded_chunks" in osm_terrain:
		initial_chunk_count = osm_terrain._loaded_chunks.size()
		peak_chunk_count = initial_chunk_count

	if logger:
		logger.start_logging("chunk_load_test")

	print("--- PHASE 2: FLYING ---")
	print("[ChunkLoadTest] Flying south at %.0f km/h, height %.0fm, duration %.0fs" % [
		fly_speed * 3.6, fly_height, test_duration])


func _process(delta: float) -> void:
	var frame_time_ms: float = delta * 1000.0

	# Phase 1: Loading — record metrics but don't move camera
	if current_phase == Phase.LOADING:
		loading_frame_times.append(frame_time_ms)
		if frame_time_ms > spike_threshold_ms:
			loading_spikes.append({
				"time": Time.get_ticks_msec() / 1000.0 - loading_start_time,
				"frame_time": frame_time_ms,
				"fps": Engine.get_frames_per_second(),
				"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
				"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
			})
		return

	# Phase 2: Flying
	if not test_running:
		return

	# Move camera south
	camera.global_position.z += fly_speed * delta
	var ground_y := 0.0
	if osm_terrain and osm_terrain.has_method("_sample_elevation"):
		ground_y = osm_terrain._sample_elevation(camera.global_position.x, camera.global_position.z)
	camera.global_position.y = ground_y + fly_height

	# Sync car position for NPC spawning
	if car:
		car.global_position = Vector3(camera.global_position.x, ground_y + 0.5, camera.global_position.z)

	# Track chunk count
	if osm_terrain and "_loaded_chunks" in osm_terrain:
		var current_chunks: int = osm_terrain._loaded_chunks.size()
		if current_chunks > peak_chunk_count:
			peak_chunk_count = current_chunks

	# Record frame time
	frame_times.append(frame_time_ms)

	# Track frame spikes
	if frame_time_ms > spike_threshold_ms:
		var viewport_rid: RID = get_viewport().get_viewport_rid()
		var render_cpu := RenderingServer.viewport_get_measured_render_time_cpu(viewport_rid)
		var render_gpu := RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid)
		var process_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		var physics_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		var spike_data: Dictionary = {
			"time": test_time,
			"frame_time": frame_time_ms,
			"fps": Engine.get_frames_per_second(),
			"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
			"vertices": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
			"physics_bodies": Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS),
			"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
			"vram_mb": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
			"camera_z": camera.global_position.z,
			"chunks": osm_terrain._loaded_chunks.size() if osm_terrain and "_loaded_chunks" in osm_terrain else -1,
			"render_cpu_ms": render_cpu,
			"render_gpu_ms": render_gpu,
			"process_ms": process_ms,
			"physics_ms": physics_ms,
		}
		# Grab per-subsystem breakdown from terrain generator
		if osm_terrain and "_current_frame_perf" in osm_terrain:
			var perf: Dictionary = osm_terrain._current_frame_perf
			if not perf.is_empty():
				spike_data["perf_breakdown"] = perf.duplicate()
		frame_spikes.append(spike_data)
		# Print breakdown for spikes >25ms
		if frame_time_ms > 25.0:
			var breakdown_str := ""
			if spike_data.has("perf_breakdown"):
				var parts: PackedStringArray = []
				for key in spike_data.perf_breakdown:
					var val: float = spike_data.perf_breakdown[key]
					if val > 0.1:
						parts.append("%s=%.1fms" % [key, val])
				breakdown_str = " [%s]" % ", ".join(parts)
			print("SPIKE #%d: %.1f ms at %.1fs (z=%.0f, chunks=%d) process=%.1f render_cpu=%.1f render_gpu=%.1f physics=%.1f%s" % [
				frame_spikes.size(), frame_time_ms, test_time,
				spike_data.camera_z, spike_data.chunks,
				process_ms, render_cpu, render_gpu, physics_ms,
				breakdown_str
			])
		else:
			print("spike #%d: %.1f ms at %.1fs (z=%.0f) process=%.1f render_cpu=%.1f" % [
				frame_spikes.size(), frame_time_ms, test_time,
				spike_data.camera_z, process_ms, render_cpu
			])

	# Log frame metrics
	if logger:
		logger.log_frame()

	# Progress report every 10 seconds
	if int(test_time / 10.0) != int((test_time + delta) / 10.0) or test_time < delta:
		var chunks: int = osm_terrain._loaded_chunks.size() if osm_terrain and "_loaded_chunks" in osm_terrain else -1
		var distance: float = fly_speed * test_time
		print("[%.0fs] z=%.0f dist=%.0fm chunks=%d fps=%d spikes=%d" % [
			test_time, camera.global_position.z, distance, chunks,
			Engine.get_frames_per_second(), frame_spikes.size()
		])

	test_time += delta
	if test_time >= test_duration:
		_end_test()


func _physics_process(_delta: float) -> void:
	if not test_running:
		return

	var physics_time_ms: float = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	if physics_time_ms > 10.0:
		physics_spikes.append({
			"time": test_time,
			"physics_time": physics_time_ms,
			"bodies": Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS),
		})


func _end_test() -> void:
	test_running = false
	var distance_traveled: float = fly_speed * test_time
	var final_chunks: int = osm_terrain._loaded_chunks.size() if osm_terrain and "_loaded_chunks" in osm_terrain else -1

	print("\n========== CHUNK LOAD TEST RESULTS ==========")

	# Phase 1 summary
	print("\n--- PHASE 1: INITIAL LOAD ---")
	print("  Duration: %.1f s, Frames: %d, Spikes: %d" % [
		loading_duration, loading_frame_times.size(), loading_spikes.size()])

	# Phase 2 summary
	print("\n--- PHASE 2: FLYING ---")
	print("  Duration: %.1f s" % test_time)
	print("  Distance: %.0f m (%.1f km)" % [distance_traveled, distance_traveled / 1000.0])
	print("  Chunks: initial=%d, peak=%d, final=%d" % [initial_chunk_count, peak_chunk_count, final_chunks])

	if frame_times.size() > 0:
		var sorted_times: Array = Array(frame_times)
		sorted_times.sort()
		var p50: float = sorted_times[int(sorted_times.size() * 0.5)]
		var p95: float = sorted_times[int(sorted_times.size() * 0.95)]
		var p99: float = sorted_times[int(sorted_times.size() * 0.99)]
		var avg: float = 0.0
		for t in sorted_times:
			avg += t
		avg /= sorted_times.size()
		var worst: float = sorted_times[sorted_times.size() - 1]

		print("\n  Frame times (ms):")
		print("    Avg: %.1f  P50: %.1f  P95: %.1f  P99: %.1f  Worst: %.1f" % [avg, p50, p95, p99, worst])
		print("    Total frames: %d  Avg FPS: %.0f" % [frame_times.size(), 1000.0 / avg])

	print("\n  Frame spikes (> %.1f ms): %d" % [spike_threshold_ms, frame_spikes.size()])
	if frame_spikes.size() > 0:
		var worst_spike: Dictionary = frame_spikes[0]
		for spike in frame_spikes:
			if spike.frame_time > worst_spike.frame_time:
				worst_spike = spike
		print("    Worst: %.1f ms at %.1fs (z=%.0f, chunks=%d)" % [
			worst_spike.frame_time, worst_spike.time, worst_spike.camera_z, worst_spike.chunks])

		var early: int = 0
		var mid: int = 0
		var late: int = 0
		for spike in frame_spikes:
			if spike.time < 20.0:
				early += 1
			elif spike.time < 40.0:
				mid += 1
			else:
				late += 1
		print("    Early (0-20s): %d  Mid (20-40s): %d  Late (40-60s): %d" % [early, mid, late])

	print("\n  Physics spikes (> 10ms): %d" % physics_spikes.size())

	# Export JSON
	var export_data: Dictionary = {
		"test_type": "chunk_load_flyover",
		"location": {"lat": test_location.x, "lon": test_location.y},
		"loading_phase": {
			"duration_s": loading_duration,
			"total_frames": loading_frame_times.size(),
			"spikes": loading_spikes,
		},
		"flying_phase": {
			"duration_s": test_time,
			"fly_speed_ms": fly_speed,
			"fly_height": fly_height,
			"distance_m": distance_traveled,
			"chunks": {"initial": initial_chunk_count, "peak": peak_chunk_count, "final": final_chunks},
			"total_frames": frame_times.size(),
			"frame_spikes": frame_spikes,
			"physics_spikes": physics_spikes,
		},
		"spike_threshold_ms": spike_threshold_ms,
	}

	var file: FileAccess = FileAccess.open("user://chunk_load_test.json", FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(export_data, "\t"))
		file.close()
		print("\nResults saved to: %s" % ProjectSettings.globalize_path("user://chunk_load_test.json"))

	if logger:
		var summary = logger.stop_logging()
		logger.export_to_csv("user://chunk_load_test.csv")
		logger.print_summary(summary)

	print("\n================================================\n")

	if auto_quit_after_test:
		print("Quitting...")
		await get_tree().create_timer(1.0).timeout
		get_tree().quit()


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and test_running:
		print("\n[ChunkLoadTest] Test aborted by user")
		_end_test()

	if event is InputEventKey and event.pressed and event.keycode == KEY_P:
		_toggle_settings_panel()


func _toggle_settings_panel() -> void:
	if not settings_panel:
		_create_settings_panel()
	settings_visible = not settings_visible
	settings_panel.visible = settings_visible


func _create_settings_panel() -> void:
	settings_panel = PanelContainer.new()
	settings_panel.name = "LODSettingsPanel"
	settings_panel.visible = false

	# Style: semi-transparent dark background
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

	# Add sliders and checkboxes
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

	# Need CanvasLayer so it renders on top
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
