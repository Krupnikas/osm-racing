extends Node

# Детальный тест производительности - отслеживает КАЖДЫЙ спайк

@export var test_duration: float = 90.0
@export var spike_threshold_ms: float = 25.0  # Всё > 25ms = спайк
@export var test_speed: float = 20.0  # m/s (~72 km/h)
@export var test_location: Vector2 = Vector2(59.1167, 37.9000)  # Cherepovets coordinates
@export var auto_quit_after_test: bool = true

var logger: Node
var car: Node3D
var vehicle_input: Node
var osm_terrain: Node
var test_running: bool = false
var test_time: float = 0.0

# Массивы для анализа
var frame_spikes: Array[Dictionary] = []  # Все спайки > 25ms
var physics_spikes: Array[Dictionary] = []  # Все physics spikes > 10ms

func _ready() -> void:
	# Загрузить logger
	var logger_script = load("res://tests/performance_logger.gd")
	if logger_script:
		logger = logger_script.new()
		add_child(logger)

	# ФИКСИРУЕМ SEED ДЛЯ ВОСПРОИЗВОДИМОСТИ NPC
	seed(12345)
	print("\n========== DETAILED PERFORMANCE TEST ==========")
	print("Random seed: 12345 (fixed for reproducibility)")
	print("Location: Cherepovets (%.4f, %.4f)" % [test_location.x, test_location.y])
	print("Duration: %.0f seconds" % test_duration)
	print("Spike threshold: %.1f ms" % spike_threshold_ms)
	print("Tracking: Every spike > %.1f ms" % spike_threshold_ms)
	print("Night mode: ENABLED")
	print("==============================================\n")

	# Подождать загрузки сцены
	await get_tree().process_frame

	# Find required nodes
	_find_nodes()

	if not car or not osm_terrain:
		push_error("[PerformanceTestDetailed] Failed to find required nodes!")
		return

	# Setup test
	_setup_test()

func _find_nodes() -> void:
	# Find car
	car = get_tree().get_first_node_in_group("player")
	if not car:
		for node in get_tree().root.get_children():
			if node is VehicleBody3D:
				car = node
				break

	# Find VehicleInput
	if car:
		vehicle_input = car.get_node_or_null("VehicleInput")
		if not vehicle_input:
			for child in car.get_children():
				if child.get_script() and "vehicle_input" in child.get_script().resource_path.to_lower():
					vehicle_input = child
					break

	# Find OSM terrain
	osm_terrain = get_node_or_null("/root/PerformanceTestDetailed/OSMTerrain")
	if not osm_terrain:
		osm_terrain = get_tree().get_first_node_in_group("osm_terrain")

	print("[PerformanceTestDetailed] Found nodes:")
	print("  Car: %s" % ("YES" if car else "NO"))
	print("  VehicleInput: %s" % ("YES" if vehicle_input else "NO"))
	print("  OSMTerrain: %s" % ("YES" if osm_terrain else "NO"))

func _setup_test() -> void:
	# ВКЛЮЧИТЬ НОЧНОЙ РЕЖИМ С ОКНАМИ И СВЕТОМ
	var night_manager = get_tree().get_first_node_in_group("night_mode_manager")
	if night_manager and night_manager.has_method("enable_night_mode"):
		night_manager.enable_night_mode()
		print("[PerformanceTestDetailed] Night mode ENABLED (windows + lights + moon)")

	# Set test location in Cherepovets
	if osm_terrain:
		# Connect to loading signals
		if osm_terrain.has_signal("initial_load_complete"):
			osm_terrain.initial_load_complete.connect(_on_terrain_loaded)
			print("[PerformanceTestDetailed] Connected to terrain loading signals")

		if osm_terrain.has_method("set_initial_position"):
			osm_terrain.set_initial_position(test_location)
			print("[PerformanceTestDetailed] Set initial position to Cherepovets")

		# Start terrain loading
		if osm_terrain.has_method("start_loading"):
			print("[PerformanceTestDetailed] Starting terrain loading...")
			osm_terrain.start_loading()
		else:
			await get_tree().create_timer(5.0).timeout
			_on_terrain_loaded()

	# Position car
	if car:
		car.global_position = Vector3(0, 1.0, 0)
		car.rotation = Vector3.ZERO

func _on_terrain_loaded() -> void:
	print("\n[PerformanceTestDetailed] ✓ Terrain loaded! Starting test in 2 seconds...")
	await get_tree().create_timer(2.0).timeout
	_start_test()

func _start_test() -> void:
	test_running = true
	test_time = 0.0
	if logger:
		logger.start_logging("detailed_test_90s")
	print("🚀 Test started!")
	print()

func _process(delta: float) -> void:
	if not test_running:
		return

	var frame_time_ms = delta * 1000.0

	# Записать КАЖДЫЙ спайк
	if frame_time_ms > spike_threshold_ms:
		var spike_data = {
			"time": test_time,
			"frame_time": frame_time_ms,
			"fps": Engine.get_frames_per_second(),
			"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
			"vertices": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
			"physics_bodies": Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS),
			"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
			"vram_mb": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1024.0 / 1024.0,
		}
		frame_spikes.append(spike_data)

		print("⚡ FRAME SPIKE #%d: %.1f ms at %.1fs (Draw: %d, Bodies: %d)" % [
			frame_spikes.size(), frame_time_ms, test_time,
			spike_data.draw_calls, spike_data.physics_bodies
		])

	# Log frame metrics
	if logger:
		logger.log_frame()

	# Обновить время теста
	test_time += delta

	# Проверить завершение
	if test_time >= test_duration:
		_end_test()

func _physics_process(_delta: float) -> void:
	if not test_running:
		return

	# Apply constant throttle
	if car and "throttle_input" in car:
		car.throttle_input = 1.0
		car.brake_input = 0.0
		car.steering_input = 0.0
		car.handbrake_input = 0.0
	elif vehicle_input:
		vehicle_input.set_physics_process(false)
		if car and "throttle_input" in car:
			car.throttle_input = 1.0
			car.brake_input = 0.0
			car.steering_input = 0.0
			car.handbrake_input = 0.0

	# Track physics spikes
	var physics_time_ms = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0

	if physics_time_ms > 10.0:
		var spike_data = {
			"time": test_time,
			"physics_time": physics_time_ms,
			"bodies": Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS),
		}
		physics_spikes.append(spike_data)

		print("⚡ PHYSICS SPIKE #%d: %.1f ms at %.1fs (Bodies: %d)" % [
			physics_spikes.size(), physics_time_ms, test_time, spike_data.bodies
		])

func _end_test() -> void:
	test_running = false

	# Re-enable normal vehicle input
	if vehicle_input:
		vehicle_input.set_physics_process(true)

	# Stop the car
	if car and "throttle_input" in car:
		car.throttle_input = 0.0
		car.brake_input = 1.0

	print("\n========== DETAILED TEST RESULTS ==========")
	print("Test duration: %.1f seconds" % test_time)
	print()

	# === FRAME SPIKES ===
	print("📊 FRAME SPIKES (> %.1f ms): %d total" % [spike_threshold_ms, frame_spikes.size()])

	var worst = null
	if frame_spikes.size() > 0:
		worst = frame_spikes[0]
		# Группировка по времени
		var early_spikes = []  # 0-30s
		var mid_spikes = []    # 30-60s
		var late_spikes = []   # 60-90s

		for spike in frame_spikes:
			if spike.time < 30.0:
				early_spikes.append(spike)
			elif spike.time < 60.0:
				mid_spikes.append(spike)
			else:
				late_spikes.append(spike)

		print("  Early (0-30s): %d spikes" % early_spikes.size())
		print("  Mid (30-60s): %d spikes" % mid_spikes.size())
		print("  Late (60-90s): %d spikes" % late_spikes.size())

		# Найти worst spike
		for spike in frame_spikes:
			if spike.frame_time > worst.frame_time:
				worst = spike

		print("\n  🔴 WORST SPIKE:")
		print("    Time: %.1fs" % worst.time)
		print("    Frame time: %.1f ms" % worst.frame_time)
		print("    FPS: %.0f" % worst.fps)
		print("    Draw calls: %d" % worst.draw_calls)
		print("    Vertices: %d" % worst.vertices)
		print("    Physics bodies: %d" % worst.physics_bodies)
		print("    Nodes: %d" % worst.nodes)

		# Показать первые 5 спайков
		print("\n  First 5 spikes:")
		for i in range(min(5, frame_spikes.size())):
			var s = frame_spikes[i]
			print("    %.1fs: %.1f ms (Draw: %d, Bodies: %d)" % [s.time, s.frame_time, s.draw_calls, s.physics_bodies])

	# === PHYSICS SPIKES ===
	print("\n📊 PHYSICS SPIKES (> 10ms): %d total" % physics_spikes.size())

	var worst_physics = null
	if physics_spikes.size() > 0:
		worst_physics = physics_spikes[0]
		for spike in physics_spikes:
			if spike.physics_time > worst_physics.physics_time:
				worst_physics = spike

		print("  🔴 WORST PHYSICS SPIKE:")
		print("    Time: %.1fs" % worst_physics.time)
		print("    Physics time: %.1f ms" % worst_physics.physics_time)
		print("    Bodies: %d" % worst_physics.bodies)

	# === ЭКСПОРТ В JSON ===
	var export_data = {
		"test_duration": test_time,
		"spike_threshold_ms": spike_threshold_ms,
		"frame_spikes": frame_spikes,
		"physics_spikes": physics_spikes,
		"summary": {
			"total_frame_spikes": frame_spikes.size(),
			"total_physics_spikes": physics_spikes.size(),
			"worst_frame_time_ms": worst.frame_time if worst else 0,
			"worst_physics_time_ms": worst_physics.physics_time if worst_physics else 0,
		}
	}

	var file = FileAccess.open("user://detailed_performance.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(export_data, "\t"))
	file.close()

	var file_path = ProjectSettings.globalize_path("user://detailed_performance.json")
	print("\n✅ Detailed spike data saved to:")
	print("   %s" % file_path)

	# CSV от logger
	if logger:
		var summary = logger.stop_logging()
		logger.export_to_csv("user://detailed_test_90s.csv")
		logger.print_summary(summary)

	print("\n===========================================\n")

	# Quit
	if auto_quit_after_test:
		print("Quitting application...")
		await get_tree().create_timer(1.0).timeout
		get_tree().quit()
	else:
		print("Test finished. You can continue playing or close the game.")

func _input(event: InputEvent) -> void:
	# Allow manual test abort with Escape
	if event.is_action_pressed("ui_cancel") and test_running:
		print("\n[PerformanceTestDetailed] Test aborted by user")
		_end_test()
