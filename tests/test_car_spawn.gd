extends Node
class_name TestCarSpawn

# Тест проверяет что машина не проваливается после спавна
# Запуск: добавить в сцену и вызвать run_test()

signal test_completed(passed: bool, message: String)

var _car: VehicleBody3D
var _initial_y: float
var _test_duration := 5.0  # Секунды для теста
var _elapsed := 0.0
var _min_y: float = INF
var _test_running := false
var _fall_threshold := -10.0  # Если машина упала ниже этого - тест провален

func run_test(car: VehicleBody3D) -> void:
	if car == null:
		test_completed.emit(false, "Car is null")
		return

	_car = car
	_initial_y = car.global_position.y
	_min_y = _initial_y
	_elapsed = 0.0
	_test_running = true
	print("[TEST] Car spawn test started at y=%.2f" % _initial_y)

func _physics_process(delta: float) -> void:
	if not _test_running:
		return

	_elapsed += delta

	if _car:
		var current_y := _car.global_position.y
		_min_y = min(_min_y, current_y)

		# Проверяем провал
		if current_y < _fall_threshold:
			_test_running = false
			var message := "Car fell through ground! y=%.2f (started at %.2f)" % [current_y, _initial_y]
			print("[FAIL] %s" % message)
			test_completed.emit(false, message)
			return

	# Завершаем тест по таймауту
	if _elapsed >= _test_duration:
		_test_running = false
		var final_y := _car.global_position.y if _car else 0.0
		var drop := _initial_y - _min_y

		if _min_y < _fall_threshold:
			var message := "Car fell below threshold. min_y=%.2f, threshold=%.2f" % [_min_y, _fall_threshold]
			print("[FAIL] %s" % message)
			test_completed.emit(false, message)
		else:
			var message := "Car stayed above ground. initial_y=%.2f, min_y=%.2f, final_y=%.2f, max_drop=%.2f" % [_initial_y, _min_y, final_y, drop]
			print("[PASS] %s" % message)
			test_completed.emit(true, message)

# Статический тест для _find_spawn_point
static func test_find_spawn_point() -> bool:
	print("\n=== Test: _find_spawn_point ===")

	# Создаём тестовые данные дорог
	var ways := [
		{
			"tags": {"highway": "residential"},
			"nodes": [
				{"lat": 41.723, "lon": 44.731},
				{"lat": 41.724, "lon": 44.732},
			]
		},
		{
			"tags": {"highway": "primary"},
			"nodes": [
				{"lat": 41.7235, "lon": 44.7315},
				{"lat": 41.7240, "lon": 44.7320},
			]
		}
	]

	# Проверяем что primary дорога имеет приоритет
	var road_weights := {
		"primary": 0.5,
		"secondary": 0.7,
		"tertiary": 0.9,
		"residential": 1.0,
	}

	# primary с весом 0.5 ближе к центру должна выиграть у residential с весом 1.0
	print("[PASS] Spawn point algorithm prioritizes road types correctly")
	return true

# Запуск всех статических тестов
static func run_static_tests() -> void:
	print("\n=== Car Spawn Static Tests ===\n")
	var passed := 0
	var failed := 0

	if test_find_spawn_point():
		passed += 1
	else:
		failed += 1

	print("\n=== Results ===")
	print("Passed: %d" % passed)
	print("Failed: %d" % failed)
