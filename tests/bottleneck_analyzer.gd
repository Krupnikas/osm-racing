extends Node

## Анализатор узких мест производительности
## Запускается в реальном времени и выводит детальную статистику

@export var update_interval: float = 1.0
@export var detailed_logging: bool = true

var _timer: float = 0.0
var _frame_count: int = 0
var _samples: Dictionary = {
	"fps": [],
	"frame_time": [],
	"physics_time": [],
	"render_time": [],
	"draw_calls": [],
	"vertices": [],
	"physics_bodies": [],
	"nodes": [],
}

# Специфичные метрики для игры
var _osm_terrain: Node
var _traffic_manager: Node
var _night_mode: Node
var _car: Node3D

func _ready() -> void:
	print("\n========== Bottleneck Analyzer Started ==========")
	print("Collecting performance data...")
	print("=================================================\n")

	# Найти ключевые системы
	await get_tree().process_frame
	_find_systems()

func _find_systems() -> void:
	_osm_terrain = get_node_or_null("/root/RaceScene/OSMTerrain")
	if not _osm_terrain:
		_osm_terrain = get_node_or_null("/root/PerformanceTest/OSMTerrain")

	_traffic_manager = get_node_or_null("/root/RaceScene/TrafficManager")
	if not _traffic_manager:
		_traffic_manager = get_node_or_null("/root/PerformanceTest/TrafficManager")

	_night_mode = get_node_or_null("/root/RaceScene/NightModeManager")
	if not _night_mode:
		_night_mode = get_node_or_null("/root/PerformanceTest/NightModeManager")

	_car = get_tree().get_first_node_in_group("player")

	print("[Systems Found]")
	print("  OSMTerrain: %s" % ("YES" if _osm_terrain else "NO"))
	print("  TrafficManager: %s" % ("YES" if _traffic_manager else "NO"))
	print("  NightModeManager: %s" % ("YES" if _night_mode else "NO"))
	print("  Player Car: %s" % ("YES" if _car else "NO"))
	print()

func _process(delta: float) -> void:
	_frame_count += 1
	_timer += delta

	# Собираем данные каждый фрейм
	_samples["fps"].append(Engine.get_frames_per_second())
	_samples["frame_time"].append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	_samples["physics_time"].append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	_samples["draw_calls"].append(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	_samples["vertices"].append(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	_samples["physics_bodies"].append(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS))
	_samples["nodes"].append(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))

	# Ограничим размер массивов
	for key in _samples:
		if _samples[key].size() > 120:  # 2 секунды при 60fps
			_samples[key].pop_front()

	# Выводим отчет с интервалом
	if _timer >= update_interval:
		_timer = 0.0
		_print_bottleneck_report()

func _print_bottleneck_report() -> void:
	print("\n========== Bottleneck Analysis Report ==========")
	print("Time: %.1fs | Frames: %d" % [Time.get_ticks_msec() / 1000.0, _frame_count])
	print()

	# === ОСНОВНЫЕ МЕТРИКИ ===
	var avg_fps = _calculate_average(_samples["fps"])
	var min_fps = _samples["fps"].min() if not _samples["fps"].is_empty() else 0
	var avg_frame_time = _calculate_average(_samples["frame_time"])
	var max_frame_time = _samples["frame_time"].max() if not _samples["frame_time"].is_empty() else 0
	var avg_physics_time = _calculate_average(_samples["physics_time"])

	print("📊 PERFORMANCE OVERVIEW:")
	print("  FPS: %.1f avg | %.1f min" % [avg_fps, min_fps])
	print("  Frame Time: %.2f ms avg | %.2f ms max" % [avg_frame_time, max_frame_time])
	print("  Physics Time: %.2f ms avg" % avg_physics_time)
	print()

	# === АНАЛИЗ УЗКИХ МЕСТ ===
	print("🔍 BOTTLENECK IDENTIFICATION:")

	var bottlenecks: Array[Dictionary] = []

	# Проверка 1: Высокое frame time
	if avg_frame_time > 16.67:
		var severity = "CRITICAL" if avg_frame_time > 33.33 else "HIGH"
		bottlenecks.append({
			"name": "Frame Time",
			"severity": severity,
			"value": "%.2f ms (target: 16.67 ms)" % avg_frame_time,
			"impact": "Overall performance bottleneck",
			"suggestions": [
				"Reduce draw calls",
				"Optimize scripts in _process()",
				"Check for expensive operations per frame"
			]
		})

	# Проверка 2: Высокое physics time
	if avg_physics_time > 5.0:
		var severity = "CRITICAL" if avg_physics_time > 10.0 else "MEDIUM"
		bottlenecks.append({
			"name": "Physics Time",
			"severity": severity,
			"value": "%.2f ms" % avg_physics_time,
			"impact": "Physics simulation overhead",
			"suggestions": [
				"Reduce number of active physics bodies",
				"Simplify collision shapes",
				"Disable physics for distant objects"
			]
		})

	# Проверка 3: Много draw calls
	var avg_draw_calls = _calculate_average_int(_samples["draw_calls"])
	if avg_draw_calls > 2000:
		var severity = "HIGH" if avg_draw_calls > 3000 else "MEDIUM"
		bottlenecks.append({
			"name": "Draw Calls",
			"severity": severity,
			"value": "%d calls/frame" % avg_draw_calls,
			"impact": "GPU rendering overhead",
			"suggestions": [
				"Batch meshes by material",
				"Use MultiMeshInstance3D",
				"Implement LOD system",
				"Enable frustum culling"
			]
		})

	# Проверка 4: Много вершин
	var avg_vertices = _calculate_average_int(_samples["vertices"])
	if avg_vertices > 500000:
		var severity = "MEDIUM" if avg_vertices > 1000000 else "LOW"
		bottlenecks.append({
			"name": "Vertex Count",
			"severity": severity,
			"value": "%d vertices/frame" % avg_vertices,
			"impact": "GPU vertex processing",
			"suggestions": [
				"Implement LOD for distant objects",
				"Simplify building meshes",
				"Use lower poly models"
			]
		})

	# Проверка 5: Много physics bodies
	var avg_bodies = _calculate_average_int(_samples["physics_bodies"])
	if avg_bodies > 150:
		var severity = "HIGH" if avg_bodies > 200 else "MEDIUM"
		bottlenecks.append({
			"name": "Physics Bodies",
			"severity": severity,
			"value": "%d active bodies" % avg_bodies,
			"impact": "Physics engine load",
			"suggestions": [
				"Reduce NPC count",
				"Convert distant NPCs to kinematic",
				"Disable physics for far objects"
			]
		})

	# Проверка 6: Много нод
	var node_count = _samples["nodes"][-1] if not _samples["nodes"].is_empty() else 0
	if node_count > 5000:
		var severity = "MEDIUM" if node_count > 10000 else "LOW"
		bottlenecks.append({
			"name": "Node Count",
			"severity": severity,
			"value": "%d nodes" % node_count,
			"impact": "Scene tree traversal overhead",
			"suggestions": [
				"Unload distant chunks",
				"Pool and reuse nodes",
				"Flatten hierarchy where possible"
			]
		})

	# Специфичные проверки для систем игры
	_check_osm_terrain_bottlenecks(bottlenecks)
	_check_traffic_bottlenecks(bottlenecks)
	_check_rendering_bottlenecks(bottlenecks)

	# Сортируем по важности
	bottlenecks.sort_custom(func(a, b):
		var severity_order = {"CRITICAL": 0, "HIGH": 1, "MEDIUM": 2, "LOW": 3}
		return severity_order.get(a["severity"], 999) < severity_order.get(b["severity"], 999)
	)

	# Выводим результаты
	if bottlenecks.is_empty():
		print("  ✅ No major bottlenecks detected!")
	else:
		for i in bottlenecks.size():
			var bn = bottlenecks[i]
			var icon = "🔴" if bn["severity"] == "CRITICAL" else "🟠" if bn["severity"] == "HIGH" else "🟡" if bn["severity"] == "MEDIUM" else "🟢"
			print("  %s [%s] %s" % [icon, bn["severity"], bn["name"]])
			print("      Value: %s" % bn["value"])
			print("      Impact: %s" % bn["impact"])
			if detailed_logging:
				print("      Suggestions:")
				for suggestion in bn["suggestions"]:
					print("        • %s" % suggestion)
			print()

	# === ДЕТАЛЬНАЯ СТАТИСТИКА ===
	if detailed_logging:
		print("📈 DETAILED STATS:")
		print("  Draw Calls: %d avg | %d max" % [avg_draw_calls, _samples["draw_calls"].max()])
		print("  Vertices: %d avg | %d max" % [avg_vertices, _samples["vertices"].max()])
		print("  Physics Bodies: %d" % avg_bodies)
		print("  Nodes: %d" % node_count)
		print("  VRAM: %.1f MB" % (Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1024.0 / 1024.0))
		print()

	print("=================================================\n")

func _check_osm_terrain_bottlenecks(bottlenecks: Array[Dictionary]) -> void:
	if not _osm_terrain:
		return

	# Проверяем количество чанков
	if _osm_terrain.has_method("get_loaded_chunk_count"):
		var chunk_count = _osm_terrain.get_loaded_chunk_count()
		if chunk_count > 20:
			bottlenecks.append({
				"name": "OSM Terrain Chunks",
				"severity": "MEDIUM",
				"value": "%d chunks loaded" % chunk_count,
				"impact": "Too many chunks in memory",
				"suggestions": [
					"Reduce load_distance",
					"Implement frustum culling",
					"Unload chunks faster"
				]
			})

	# Проверяем очереди обработки
	if _osm_terrain.has_method("get_building_queue_size"):
		var queue_size = _osm_terrain.get_building_queue_size()
		if queue_size > 50:
			bottlenecks.append({
				"name": "Building Queue",
				"severity": "MEDIUM",
				"value": "%d buildings waiting" % queue_size,
				"impact": "Mesh generation backlog",
				"suggestions": [
					"Increase buildings per frame",
					"Reduce chunk load rate",
					"Optimize building mesh generation"
				]
			})

func _check_traffic_bottlenecks(bottlenecks: Array[Dictionary]) -> void:
	if not _traffic_manager:
		return

	if _traffic_manager.has_method("get_active_npc_count"):
		var npc_count = _traffic_manager.get_active_npc_count()
		if npc_count > 40:
			bottlenecks.append({
				"name": "Traffic NPCs",
				"severity": "HIGH",
				"value": "%d active NPCs" % npc_count,
				"impact": "Each NPC = 5 physics bodies (vehicle + 4 wheels)",
				"suggestions": [
					"Implement distance-based LOD",
					"Use simplified physics for far NPCs",
					"Reduce MAX_NPCS constant"
				]
			})

func _check_rendering_bottlenecks(bottlenecks: Array[Dictionary]) -> void:
	# Проверяем environment settings
	var env: Environment = get_viewport().world_3d.environment
	if env:
		var expensive_features = []
		if env.ssr_enabled and env.ssr_max_steps > 32:
			expensive_features.append("SSR with %d steps" % env.ssr_max_steps)
		if env.ssao_enabled:
			expensive_features.append("SSAO")
		if env.glow_enabled:
			expensive_features.append("Glow/Bloom")
		if env.fog_enabled:
			expensive_features.append("Volumetric Fog")

		if expensive_features.size() > 2:
			bottlenecks.append({
				"name": "Post-Processing Effects",
				"severity": "MEDIUM",
				"value": "%s" % ", ".join(expensive_features),
				"impact": "GPU shader overhead",
				"suggestions": [
					"Reduce SSR quality",
					"Disable SSAO on low-end hardware",
					"Use simpler fog"
				]
			})

func _calculate_average(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var sum = 0.0
	for v in values:
		sum += v
	return sum / float(values.size())

func _calculate_average_int(values: Array) -> int:
	if values.is_empty():
		return 0
	var sum = 0
	for v in values:
		sum += v
	return sum / values.size()
