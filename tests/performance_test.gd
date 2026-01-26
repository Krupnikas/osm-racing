extends Node

# Automatic performance test for OSM Racing Game
# Test: Drive straight in Cherepovets at night for 30 seconds

@export var test_duration: float = 30.0
@export var test_speed: float = 20.0  # m/s (~72 km/h)
@export var enable_night_mode: bool = true
@export var test_location: Vector2 = Vector2(59.1167, 37.9000)  # Cherepovets coordinates
@export var auto_quit_after_test: bool = false

var logger: PerformanceLogger
var car: Node3D
var vehicle_input: Node  # VehicleInput node
var osm_terrain: Node
var night_mode_manager: Node
var test_running: bool = false
var test_time: float = 0.0
var output_filename: String = ""

func _ready() -> void:
	print("\n========== Starting Performance Test ==========")
	print("Location: Cherepovets (%.4f, %.4f)" % [test_location.x, test_location.y])
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

func _setup_test() -> void:
	# Set test location in Cherepovets
	if osm_terrain:
		# Connect to loading signals
		if osm_terrain.has_signal("initial_load_complete"):
			osm_terrain.initial_load_complete.connect(_on_terrain_loaded)
			print("[PerformanceTest] Connected to terrain loading signals")

		if osm_terrain.has_method("set_initial_position"):
			osm_terrain.set_initial_position(test_location)
			print("[PerformanceTest] Set initial position to Cherepovets: %.4f, %.4f" % [test_location.x, test_location.y])

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
	print("\n[PerformanceTest] ✓ Terrain loaded! Positioning car on road...")

	# Position car on nearest road
	_position_car_on_road()

	await get_tree().create_timer(2.0).timeout
	_start_test()

# Позиционирует машину на ближайшей дороге, в центре полосы, по направлению дороги
func _position_car_on_road() -> void:
	if not car or not osm_terrain:
		print("[PerformanceTest] Cannot position car: car or terrain missing")
		return

	# Получаем road segments из OSMTerrain
	var road_segments: Array = []
	if osm_terrain.has("_road_segments"):
		road_segments = osm_terrain._road_segments

	if road_segments.is_empty():
		print("[PerformanceTest] No road segments found, using default position")
		return

	# Найти ближайший road segment к origin
	var closest_segment = null
	var closest_distance := INF
	var closest_point := Vector3.ZERO
	var road_direction := Vector3.FORWARD

	for segment in road_segments:
		if not segment.has("start") or not segment.has("end"):
			continue

		var start: Vector2 = segment.start
		var end: Vector2 = segment.end

		# Найти ближайшую точку на сегменте к origin (0, 0)
		var segment_vec: Vector2 = end - start
		var to_origin: Vector2 = Vector2.ZERO - start
		var t: float = clamp(to_origin.dot(segment_vec) / segment_vec.length_squared(), 0.0, 1.0)
		var closest_2d: Vector2 = start + segment_vec * t
		var distance: float = closest_2d.length()

		if distance < closest_distance:
			closest_distance = distance
			closest_segment = segment
			closest_point = Vector3(closest_2d.x, 1.0, closest_2d.y)  # Y=1.0 для высоты машины

			# Направление дороги (от start к end)
			var dir_2d := (end - start).normalized()
			road_direction = Vector3(dir_2d.x, 0, dir_2d.y)

	if closest_segment:
		# Позиционируем машину
		car.global_position = closest_point

		# Поворачиваем машину по направлению дороги
		var target_rotation := Vector3.ZERO
		target_rotation.y = atan2(road_direction.x, road_direction.z)
		car.rotation = target_rotation

		print("[PerformanceTest] Car positioned on road at %s, direction: %.2f°" % [
			closest_point, rad_to_deg(target_rotation.y)
		])
	else:
		print("[PerformanceTest] Could not find suitable road segment")

func _start_test() -> void:
	print("\n========== TEST STARTED ==========")
	print("Test will run for %.1f seconds" % test_duration)
	print("==================================\n")
	test_running = true
	test_time = 0.0
	if logger:
		logger.start_logging("cherepovets_night_30s")

func _process(delta: float) -> void:
	if not test_running:
		return

	# Log frame metrics (if logger exists)
	if logger:
		logger.log_frame()

	# Update test time
	test_time += delta

	# Check if test is complete
	if test_time >= test_duration:
		_end_test()

func _physics_process(_delta: float) -> void:
	if not test_running:
		return

	# Apply constant throttle to maintain speed
	if car and "throttle_input" in car:
		# Set full throttle to maintain test_speed (~72 km/h = 20 m/s)
		car.throttle_input = 1.0
		car.brake_input = 0.0
		car.steering_input = 0.0  # Go straight
		car.handbrake_input = 0.0
	elif vehicle_input:
		# Disable normal input and control directly
		vehicle_input.set_physics_process(false)
		if car and "throttle_input" in car:
			car.throttle_input = 1.0
			car.brake_input = 0.0
			car.steering_input = 0.0
			car.handbrake_input = 0.0

func _end_test() -> void:
	test_running = false

	# Re-enable normal vehicle input
	if vehicle_input:
		vehicle_input.set_physics_process(true)

	# Stop the car
	if car and car.has("throttle_input"):
		car.throttle_input = 0.0
		car.brake_input = 1.0

	print("\n[PerformanceTest] Test complete!")

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

	# Quit if requested
	if auto_quit_after_test:
		print("\nQuitting application...")
		await get_tree().create_timer(1.0).timeout
		get_tree().quit()
	else:
		print("\nTest finished. You can continue playing or close the game.")

func _input(event: InputEvent) -> void:
	# Allow manual test abort with Escape
	if event.is_action_pressed("ui_cancel") and test_running:
		print("\n[PerformanceTest] Test aborted by user")
		_end_test()
