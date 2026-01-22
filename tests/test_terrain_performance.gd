extends Node3D

# Тест производительности генерации террейна
# Машина едет, чанки загружаются с реального OSM API
# Проверяет время кадров и фризы
# Запуск: godot --path . tests/test_terrain_performance.tscn

const OSMTerrainGeneratorScript = preload("res://osm/osm_terrain_generator.gd")
const TrafficManagerScript = preload("res://traffic/traffic_manager.gd")
const NightModeManagerScript = preload("res://night_mode/night_mode_manager.gd")

var _terrain_generator: Node
var _traffic_manager: Node
var _night_mode_manager: Node
var _car: VehicleBody3D
var _camera: Camera3D
var _test_started := false
var _frame_times: Array[float] = []
var _max_frame_time := 0.0
var _frames_over_16ms := 0
var _frames_over_33ms := 0
var _frames_over_50ms := 0
var _total_frames := 0
var _test_duration := 20.0
var _elapsed := 0.0

# Движение машины
var _drive_speed := 30.0  # м/с (~108 км/ч)
var _drive_direction := Vector3(1, 0, 1).normalized()

func _ready() -> void:
	print("\n========================================")
	print("TERRAIN PERFORMANCE TEST")
	print("Car drives, chunks load from OSM API")
	print("Night mode + Rain enabled")
	print("Measures frame times and stutters")
	print("========================================\n")

	# Создаём машину
	_car = VehicleBody3D.new()
	_car.name = "TestCar"
	_car.position = Vector3(0, 2, 0)
	_car.add_to_group("car")
	add_child(_car)

	# Добавляем простую коллизию для машины
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2, 1, 4)
	collision.shape = box
	_car.add_child(collision)

	# Создаём камеру следящую за машиной
	_camera = Camera3D.new()
	_camera.current = true
	add_child(_camera)

	# Создаём землю (как в main.tscn)
	var ground := StaticBody3D.new()
	ground.name = "StaticGround"
	add_child(ground)

	var ground_collision := CollisionShape3D.new()
	var ground_box := BoxShape3D.new()
	ground_box.size = Vector3(10000, 1, 10000)
	ground_collision.shape = ground_box
	ground_collision.position = Vector3(0, -0.5, 0)
	ground.add_child(ground_collision)

	var ground_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(10000, 10000)
	ground_mesh.mesh = plane
	var ground_mat := StandardMaterial3D.new()
	ground_mat.albedo_color = Color(0.4, 0.5, 0.4)
	ground_mesh.set_surface_override_material(0, ground_mat)
	ground.add_child(ground_mesh)

	# Создаём генератор террейна
	_terrain_generator = OSMTerrainGeneratorScript.new()
	_terrain_generator.name = "OSMTerrain"
	_terrain_generator.start_lat = 59.149886
	_terrain_generator.start_lon = 37.94937
	_terrain_generator.chunk_size = 300.0
	_terrain_generator.load_distance = 500.0
	_terrain_generator.unload_distance = 800.0
	_terrain_generator.car_path = NodePath("../TestCar")
	add_child(_terrain_generator)

	# Создаём TrafficManager для NPC машин
	# Он сам найдёт OSMTerrain по имени ../OSMTerrain
	_traffic_manager = TrafficManagerScript.new()
	_traffic_manager.name = "TrafficManager"
	add_child(_traffic_manager)

	# Создаём NightModeManager (ночь + дождь)
	_night_mode_manager = NightModeManagerScript.new()
	_night_mode_manager.name = "NightModeManager"
	add_child(_night_mode_manager)

	# Подключаемся к сигналам
	if _terrain_generator.has_signal("initial_load_complete"):
		_terrain_generator.initial_load_complete.connect(_on_initial_load_complete)

	# Ждём кадр и запускаем загрузку
	await get_tree().process_frame
	print("Starting terrain loading...")
	_terrain_generator.start_loading()

	# Таймаут на случай если initial_load не сработает
	await get_tree().create_timer(30.0).timeout
	if not _test_started:
		print("Timeout waiting for initial load, starting anyway...")
		_test_started = true


func _on_initial_load_complete() -> void:
	print("Initial load complete, starting drive test...")
	_test_started = true


func _physics_process(delta: float) -> void:
	if not _test_started:
		return

	# Двигаем машину по горизонтали, держим на фиксированной высоте
	var move := _drive_direction * _drive_speed * delta
	_car.global_position.x += move.x
	_car.global_position.z += move.z
	_car.global_position.y = 2.0  # Фиксированная высота над землёй

	# Обновляем камеру - выше и дальше
	var cam_pos := _car.global_position + Vector3(-20, 15, -20)
	_camera.global_position = cam_pos
	_camera.look_at(_car.global_position)


func _process(delta: float) -> void:
	if not _test_started:
		return

	_elapsed += delta
	_total_frames += 1

	var frame_ms := delta * 1000.0
	_frame_times.append(frame_ms)

	if frame_ms > _max_frame_time:
		_max_frame_time = frame_ms
		if frame_ms > 50:
			print("SPIKE: %.0fms at %.1fs (pos: %.0f, %.0f)" % [frame_ms, _elapsed, _car.global_position.x, _car.global_position.z])

	if frame_ms > 16.67:
		_frames_over_16ms += 1
	if frame_ms > 33.33:
		_frames_over_33ms += 1
	if frame_ms > 50.0:
		_frames_over_50ms += 1

	# Завершаем тест
	if _elapsed >= _test_duration:
		_finish_test()


func _finish_test() -> void:
	_test_started = false

	print("\n========================================")
	print("TEST RESULTS")
	print("========================================")

	# Средний FPS
	var avg_frame_time := 0.0
	for t in _frame_times:
		avg_frame_time += t
	if _frame_times.size() > 0:
		avg_frame_time /= _frame_times.size()

	var avg_fps: float = 1000.0 / avg_frame_time if avg_frame_time > 0 else 0.0

	# Медиана
	var sorted_times := _frame_times.duplicate()
	sorted_times.sort()
	var median_frame_time: float = sorted_times[sorted_times.size() / 2] if sorted_times.size() > 0 else 0.0

	# 99 перцентиль
	var p99_idx := int(sorted_times.size() * 0.99)
	var p99_frame_time: float = sorted_times[p99_idx] if p99_idx < sorted_times.size() else 0.0

	# 1 перцентиль (worst)
	var p1_idx := int(sorted_times.size() * 0.01)
	var worst_1pct: float = sorted_times[sorted_times.size() - 1 - p1_idx] if sorted_times.size() > p1_idx else 0.0

	print("Duration: %.1f seconds" % _elapsed)
	print("Total frames: %d" % _total_frames)
	print("Distance traveled: %.0f meters" % (_drive_speed * _elapsed))

	# NPC статистика
	if _traffic_manager:
		print("NPC Traffic: %d active, %d in pool" % [_traffic_manager.active_npcs.size(), _traffic_manager.inactive_npcs.size()])
		if _traffic_manager.road_network:
			print("Road Network: %s" % _traffic_manager.road_network.get_debug_info())
	print("")
	print("Frame times:")
	print("  Average: %.2f ms (%.0f FPS)" % [avg_frame_time, avg_fps])
	print("  Median:  %.2f ms" % median_frame_time)
	print("  Max:     %.2f ms" % _max_frame_time)
	print("  99%%:     %.2f ms" % p99_frame_time)
	print("  Worst 1%%: %.2f ms" % worst_1pct)
	print("")
	print("Frame drops:")
	print("  >16.67ms (below 60fps): %d (%.1f%%)" % [_frames_over_16ms, 100.0 * _frames_over_16ms / max(1, _total_frames)])
	print("  >33.33ms (below 30fps): %d (%.1f%%)" % [_frames_over_33ms, 100.0 * _frames_over_33ms / max(1, _total_frames)])
	print("  >50ms (major stutter):  %d (%.1f%%)" % [_frames_over_50ms, 100.0 * _frames_over_50ms / max(1, _total_frames)])
	print("")

	# Оценка
	var passed := true
	var warnings: Array[String] = []

	if _max_frame_time > 200:
		warnings.append("FAIL: Max frame time > 200ms (was %.0fms)" % _max_frame_time)
		passed = false
	elif _max_frame_time > 100:
		warnings.append("WARN: Max frame time > 100ms (was %.0fms)" % _max_frame_time)

	if float(_frames_over_50ms) / max(1, _total_frames) > 0.02:
		warnings.append("FAIL: More than 2%% frames with major stutter (>50ms)")
		passed = false

	if float(_frames_over_33ms) / max(1, _total_frames) > 0.10:
		warnings.append("WARN: More than 10%% frames below 30fps")

	for w in warnings:
		print(w)

	if passed and warnings.is_empty():
		print("PASS: Performance is good!")
	elif passed:
		print("PASS: Performance acceptable with warnings")
	else:
		print("FAIL: Performance needs improvement")

	print("========================================\n")

	# Выход
	await get_tree().create_timer(1.0).timeout
	get_tree().quit(0 if passed else 1)
