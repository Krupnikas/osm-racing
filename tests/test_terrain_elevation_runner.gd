extends Node

# Раннер для теста высот земли
# Запуск: godot --path . tests/test_terrain_elevation_runner.tscn

const TestTerrainElevationScript = preload("res://tests/test_terrain_elevation.gd")

var _terrain_generator: Node3D
var _car: VehicleBody3D
var _test_runner: Node
var _load_wait_time := 15.0  # Ждём загрузки местности
var _test_started := false

func _ready() -> void:
	print("\n========================================")
	print("OSM Racing Terrain Elevation Test")
	print("========================================\n")

	# Находим OSMTerrain
	_terrain_generator = get_parent().get_node_or_null("OSMTerrain")
	if not _terrain_generator:
		_fail("OSMTerrain not found")
		return

	# Проверяем что elevation включен
	if not _terrain_generator.enable_elevation:
		print("[WARN] Elevation is disabled. Enabling for test...")
		_terrain_generator.enable_elevation = true

	print("[INFO] Elevation settings:")
	print("  - enabled: %s" % _terrain_generator.enable_elevation)
	print("  - scale: %.2f" % _terrain_generator.elevation_scale)
	print("  - grid resolution: %d" % _terrain_generator.elevation_grid_resolution)

	# Находим машину
	_car = get_parent().get_node_or_null("Car")
	if not _car:
		_fail("Car not found")
		return

	# Запускаем загрузку
	print("[TEST] Starting terrain loading...")
	_terrain_generator.start_loading()

	# Ждём загрузки и запускаем тест
	_wait_and_start_test()

func _wait_and_start_test() -> void:
	print("[TEST] Waiting %.1f seconds for terrain to load..." % _load_wait_time)
	await get_tree().create_timer(_load_wait_time).timeout

	if not _test_started:
		print("[TEST] Terrain loaded, positioning car...")
		# Ставим машину немного выше земли
		_car.global_position = Vector3(_car.global_position.x, 10, _car.global_position.z)
		_car.linear_velocity = Vector3.ZERO
		_car.angular_velocity = Vector3.ZERO

		# Ждём стабилизации физики
		await get_tree().create_timer(2.0).timeout

		# Запускаем тест
		_start_elevation_test()

func _start_elevation_test() -> void:
	_test_started = true
	print("[TEST] Starting terrain elevation test...")

	_test_runner = TestTerrainElevationScript.new()
	add_child(_test_runner)
	_test_runner.test_completed.connect(_on_test_completed)
	_test_runner.run_test(_car, _terrain_generator)

func _on_test_completed(passed: bool, message: String) -> void:
	print("\n========================================")
	if passed:
		print("[PASS] Terrain Elevation Test")
		print("%s" % message)
		print("========================================\n")
		await get_tree().create_timer(0.5).timeout
		get_tree().quit(0)  # Exit code 0 = success
	else:
		print("[FAIL] Terrain Elevation Test")
		print("%s" % message)
		print("========================================\n")
		await get_tree().create_timer(0.5).timeout
		get_tree().quit(1)  # Exit code 1 = failure

func _fail(message: String) -> void:
	print("\n========================================")
	print("[FAIL] %s" % message)
	print("========================================\n")
	await get_tree().create_timer(0.5).timeout
	get_tree().quit(1)
