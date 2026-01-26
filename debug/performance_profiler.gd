extends Node
class_name PerformanceProfiler

## Профилировщик производительности
## Выводит метрики каждые N секунд

@export var print_interval: float = 5.0  # Интервал вывода в секундах
@export var enabled: bool = true

var _timer: float = 0.0
var _frame_times: Array[float] = []
var _physics_times: Array[float] = []
var _last_physics_time: int = 0

# Счётчики для отдельных систем
var _system_times: Dictionary = {}

func _ready() -> void:
	if enabled:
		print("=== Performance Profiler Started ===")

func _process(delta: float) -> void:
	if not enabled:
		return

	_frame_times.append(delta * 1000.0)  # мс
	if _frame_times.size() > 300:  # Храним последние 5 сек при 60fps
		_frame_times.pop_front()

	_timer += delta
	if _timer >= print_interval:
		_timer = 0.0
		_print_metrics()

func _physics_process(_delta: float) -> void:
	if not enabled:
		return

	var now := Time.get_ticks_usec()
	if _last_physics_time > 0:
		var physics_delta := (now - _last_physics_time) / 1000.0  # мс
		_physics_times.append(physics_delta)
		if _physics_times.size() > 300:
			_physics_times.pop_front()
	_last_physics_time = now

func start_measure(system_name: String) -> int:
	return Time.get_ticks_usec()

func end_measure(system_name: String, start_time: int) -> void:
	var elapsed := (Time.get_ticks_usec() - start_time) / 1000.0  # мс
	if not _system_times.has(system_name):
		_system_times[system_name] = []
	_system_times[system_name].append(elapsed)
	if _system_times[system_name].size() > 300:
		_system_times[system_name].pop_front()

func _print_metrics() -> void:
	var fps := Engine.get_frames_per_second()
	var avg_frame := _calculate_avg(_frame_times)
	var max_frame := _calculate_max(_frame_times)
	var avg_physics := _calculate_avg(_physics_times)
	var max_physics := _calculate_max(_physics_times)

	# Встроенные метрики Godot
	var render_time := Performance.get_monitor(Performance.TIME_PROCESS)
	var physics_time := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
	var objects := Performance.get_monitor(Performance.OBJECT_COUNT)
	var nodes := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	var resources := Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)
	var draw_calls := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var vertices := Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	var video_mem := Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1024.0 / 1024.0
	var physics_bodies := Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)
	var collision_pairs := Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS)

	print("")
	print("=== PERFORMANCE METRICS ===")
	print("FPS: %d | Frame: %.1f ms (max %.1f) | Physics: %.1f ms (max %.1f)" % [
		fps, avg_frame, max_frame, avg_physics, max_physics
	])
	print("Godot Process: %.2f ms | Physics: %.2f ms" % [render_time * 1000, physics_time * 1000])
	print("Objects: %d | Nodes: %d | Resources: %d" % [objects, nodes, resources])
	print("Draw calls: %d | Vertices: %d | VRAM: %.1f MB" % [draw_calls, vertices, video_mem])
	print("Physics bodies: %d | Collision pairs: %d" % [physics_bodies, collision_pairs])

	# Выводим системные метрики если есть
	if _system_times.size() > 0:
		print("--- System Times ---")
		var sorted_systems := _system_times.keys()
		sorted_systems.sort()
		for system_name in sorted_systems:
			var times: Array = _system_times[system_name]
			var avg := _calculate_avg_arr(times)
			var max_t := _calculate_max_arr(times)
			if avg > 0.1:  # Только если > 0.1 мс
				print("  %s: %.2f ms (max %.2f)" % [system_name, avg, max_t])

	print("===========================")

func _calculate_avg(arr: Array[float]) -> float:
	if arr.is_empty():
		return 0.0
	var sum := 0.0
	for v in arr:
		sum += v
	return sum / arr.size()

func _calculate_max(arr: Array[float]) -> float:
	if arr.is_empty():
		return 0.0
	var m := 0.0
	for v in arr:
		if v > m:
			m = v
	return m

func _calculate_avg_arr(arr: Array) -> float:
	if arr.is_empty():
		return 0.0
	var sum := 0.0
	for v in arr:
		sum += v
	return sum / arr.size()

func _calculate_max_arr(arr: Array) -> float:
	if arr.is_empty():
		return 0.0
	var m := 0.0
	for v in arr:
		if v > m:
			m = v
	return m
