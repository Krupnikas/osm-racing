extends Node
class_name PerformanceLogger

## Performance metrics logger with CSV export
## Logs frame-by-frame metrics and exports to CSV

var metrics: Array[Dictionary] = []
var start_time: float = 0.0
var test_name: String = "performance_test"

# Current frame metrics
var _frame_times: Array[float] = []
var _fps_samples: Array[float] = []
var _draw_calls: Array[int] = []
var _vertices: Array[int] = []

func start_logging(test_name_param: String = "performance_test") -> void:
	test_name = test_name_param
	start_time = Time.get_ticks_msec() / 1000.0
	metrics.clear()
	_frame_times.clear()
	_fps_samples.clear()
	_draw_calls.clear()
	_vertices.clear()
	print("[PerformanceLogger] Started logging: %s" % test_name)

func log_frame() -> void:
	var current_time = Time.get_ticks_msec() / 1000.0 - start_time

	# Collect metrics
	var fps = Engine.get_frames_per_second()
	var frame_time = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var physics_time = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	var draw_calls = Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var vertices = Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	var vram_usage = Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1024.0 / 1024.0  # MB
	var physics_bodies = Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)
	var node_count = Performance.get_monitor(Performance.OBJECT_NODE_COUNT)

	# Store samples
	_fps_samples.append(fps)
	_frame_times.append(frame_time)
	_draw_calls.append(int(draw_calls))
	_vertices.append(int(vertices))

	# Create metric entry
	var metric = {
		"time": current_time,
		"fps": fps,
		"frame_time": frame_time,
		"physics_time": physics_time,
		"draw_calls": draw_calls,
		"vertices": vertices,
		"vram_mb": vram_usage,
		"physics_bodies": physics_bodies,
		"node_count": node_count
	}

	metrics.append(metric)

func stop_logging() -> Dictionary:
	print("[PerformanceLogger] Stopped logging: %s" % test_name)
	return get_summary()

func get_summary() -> Dictionary:
	if _fps_samples.is_empty():
		return {}

	var summary = {
		"test_name": test_name,
		"duration": Time.get_ticks_msec() / 1000.0 - start_time,
		"frame_count": metrics.size(),
		"avg_fps": _calculate_average(_fps_samples),
		"min_fps": _fps_samples.min(),
		"max_fps": _fps_samples.max(),
		"avg_frame_time": _calculate_average(_frame_times),
		"min_frame_time": _frame_times.min(),
		"max_frame_time": _frame_times.max(),
		"avg_draw_calls": _calculate_average_int(_draw_calls),
		"max_draw_calls": _draw_calls.max(),
		"avg_vertices": _calculate_average_int(_vertices),
		"max_vertices": _vertices.max(),
	}

	if not metrics.is_empty():
		summary["avg_vram_mb"] = metrics[metrics.size() - 1]["vram_mb"]
		summary["avg_physics_bodies"] = metrics[metrics.size() - 1]["physics_bodies"]
		summary["avg_node_count"] = metrics[metrics.size() - 1]["node_count"]

	return summary

func export_to_csv(filepath: String) -> void:
	var file = FileAccess.open(filepath, FileAccess.WRITE)
	if not file:
		push_error("[PerformanceLogger] Failed to open file: %s" % filepath)
		return

	# Write header
	file.store_line("time,fps,frame_time,physics_time,draw_calls,vertices,vram_mb,physics_bodies,node_count")

	# Write data
	for metric in metrics:
		var line = "%f,%f,%f,%f,%d,%d,%f,%d,%d" % [
			metric["time"],
			metric["fps"],
			metric["frame_time"],
			metric["physics_time"],
			metric["draw_calls"],
			metric["vertices"],
			metric["vram_mb"],
			metric["physics_bodies"],
			metric["node_count"]
		]
		file.store_line(line)

	file.close()
	print("[PerformanceLogger] Exported metrics to: %s" % filepath)

func print_summary(summary: Dictionary = {}) -> void:
	if summary.is_empty():
		summary = get_summary()

	print("\n========== Performance Test Summary ==========")
	print("Test: %s" % summary.get("test_name", "unknown"))
	print("Duration: %.2f seconds" % summary.get("duration", 0.0))
	print("Frames: %d" % summary.get("frame_count", 0))
	print("")
	print("FPS:")
	print("  Average: %.1f" % summary.get("avg_fps", 0.0))
	print("  Min: %.1f" % summary.get("min_fps", 0.0))
	print("  Max: %.1f" % summary.get("max_fps", 0.0))
	print("")
	print("Frame Time (ms):")
	print("  Average: %.2f" % summary.get("avg_frame_time", 0.0))
	print("  Min: %.2f" % summary.get("min_frame_time", 0.0))
	print("  Max: %.2f" % summary.get("max_frame_time", 0.0))
	print("")
	print("Rendering:")
	print("  Avg Draw Calls: %d" % summary.get("avg_draw_calls", 0))
	print("  Max Draw Calls: %d" % summary.get("max_draw_calls", 0))
	print("  Avg Vertices: %d" % summary.get("avg_vertices", 0))
	print("  Max Vertices: %d" % summary.get("max_vertices", 0))
	print("  VRAM: %.1f MB" % summary.get("avg_vram_mb", 0.0))
	print("")
	print("Physics:")
	print("  Active Bodies: %d" % summary.get("avg_physics_bodies", 0))
	print("")
	print("Scene:")
	print("  Node Count: %d" % summary.get("avg_node_count", 0))
	print("==============================================\n")

func _calculate_average(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var sum = 0.0
	for v in values:
		sum += v
	return sum / float(values.size())

func _calculate_average_int(values: Array[int]) -> int:
	if values.is_empty():
		return 0
	var sum = 0
	for v in values:
		sum += v
	return sum / values.size()
