extends Node

# Интеграционный тест проверяющий физику спавна машины
# Запуск: godot --path . tests/test_physics_spawn.tscn

const TestCarSpawnScript = preload("res://tests/test_car_spawn.gd")

var _terrain_generator: Node3D
var _car: VehicleBody3D
var _test_runner: Node
var _spawn_timeout := 30.0  # Максимум 30 сек на спавн
var _spawn_timer := 0.0
var _spawn_ready := false
var _test_started := false

func _ready() -> void:
	print("\n========================================")
	print("OSM Racing Physics Spawn Test")
	print("========================================\n")

	# Находим OSMTerrain
	_terrain_generator = get_parent().get_node_or_null("OSMTerrain")
	if not _terrain_generator:
		_fail("OSMTerrain not found")
		return

	# Находим машину
	_car = get_parent().get_node_or_null("Car")
	if not _car:
		_fail("Car not found")
		return

	# Подписываемся на spawn_ready
	_terrain_generator.spawn_ready.connect(_on_spawn_ready)

	# Запускаем загрузку
	print("[TEST] Starting terrain loading...")
	_terrain_generator.start_loading()

func _process(delta: float) -> void:
	if _test_started:
		return

	if not _spawn_ready:
		_spawn_timer += delta
		if _spawn_timer >= _spawn_timeout:
			_fail("Spawn timeout after %.0f seconds" % _spawn_timeout)

func _on_spawn_ready(spawn_position: Vector3) -> void:
	_spawn_ready = true
	print("[TEST] Spawn ready at position: (%.1f, %.1f, %.1f)" % [spawn_position.x, spawn_position.y, spawn_position.z])

	# Ставим машину на позицию
	_car.global_position = spawn_position
	_car.linear_velocity = Vector3.ZERO
	_car.angular_velocity = Vector3.ZERO

	# Небольшая задержка перед запуском теста
	await get_tree().create_timer(0.5).timeout

	# Запускаем тест физики
	_start_physics_test()

func _start_physics_test() -> void:
	_test_started = true
	print("[TEST] Starting physics test...")

	_test_runner = TestCarSpawnScript.new()
	add_child(_test_runner)
	_test_runner.test_completed.connect(_on_test_completed)
	_test_runner.run_test(_car)

func _on_test_completed(passed: bool, message: String) -> void:
	print("\n========================================")
	if passed:
		print("[PASS] Physics Spawn Test: %s" % message)
		print("========================================\n")
		await get_tree().create_timer(0.5).timeout
		get_tree().quit(0)  # Exit code 0 = success
	else:
		print("[FAIL] Physics Spawn Test: %s" % message)
		print("========================================\n")
		await get_tree().create_timer(0.5).timeout
		get_tree().quit(1)  # Exit code 1 = failure

func _fail(message: String) -> void:
	print("\n========================================")
	print("[FAIL] %s" % message)
	print("========================================\n")
	await get_tree().create_timer(0.5).timeout
	get_tree().quit(1)
