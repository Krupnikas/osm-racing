extends SceneTree

# Анализ JSON логов - находит паттерны и корреляции

func _init():
	analyze()
	quit()

func analyze():
	var file_path = OS.get_user_data_dir() + "/detailed_performance.json"

	if not FileAccess.file_exists(file_path):
		print("❌ No log file found at: %s" % file_path)
		print("Run the detailed performance test first:")
		print("  godot --path . res://tests/performance_test_detailed.tscn")
		return

	var file = FileAccess.open(file_path, FileAccess.READ)
	var json_text = file.get_as_text()
	file.close()

	var data = JSON.parse_string(json_text)
	if data == null:
		print("❌ Failed to parse JSON file")
		return

	var frame_spikes = data.get("frame_spikes", [])
	var physics_spikes = data.get("physics_spikes", [])
	var summary = data.get("summary", {})

	print("\n========== PERFORMANCE LOG ANALYSIS ==========")
	print("Test duration: %.1f seconds" % data.get("test_duration", 0))
	print("Spike threshold: %.1f ms" % data.get("spike_threshold_ms", 25.0))
	print()

	print("📊 SUMMARY:")
	print("  Total frame spikes: %d" % frame_spikes.size())
	print("  Total physics spikes: %d" % physics_spikes.size())
	print()

	if frame_spikes.is_empty():
		print("✅ No frame spikes detected!")
		print("==============================================\n")
		return

	# === КОРРЕЛЯЦИЯ 1: Спайки vs Draw Calls ===
	var high_drawcall_spikes = 0
	var very_high_drawcall_spikes = 0
	for spike in frame_spikes:
		if spike.draw_calls > 8000:
			very_high_drawcall_spikes += 1
		elif spike.draw_calls > 7000:
			high_drawcall_spikes += 1

	print("📈 CORRELATION 1: Spikes vs Draw Calls")
	print("  Spikes with >7000 draw calls: %d / %d (%.1f%%)" % [
		high_drawcall_spikes,
		frame_spikes.size(),
		100.0 * high_drawcall_spikes / frame_spikes.size()
	])
	print("  Spikes with >8000 draw calls: %d / %d (%.1f%%)" % [
		very_high_drawcall_spikes,
		frame_spikes.size(),
		100.0 * very_high_drawcall_spikes / frame_spikes.size()
	])

	# === КОРРЕЛЯЦИЯ 2: Спайки vs Physics Bodies ===
	var high_physics_spikes = 0
	var very_high_physics_spikes = 0
	for spike in frame_spikes:
		if spike.physics_bodies > 450:
			very_high_physics_spikes += 1
		elif spike.physics_bodies > 400:
			high_physics_spikes += 1

	print("\n📈 CORRELATION 2: Spikes vs Physics Bodies")
	print("  Spikes with >400 bodies: %d / %d (%.1f%%)" % [
		high_physics_spikes,
		frame_spikes.size(),
		100.0 * high_physics_spikes / frame_spikes.size()
	])
	print("  Spikes with >450 bodies: %d / %d (%.1f%%)" % [
		very_high_physics_spikes,
		frame_spikes.size(),
		100.0 * very_high_physics_spikes / frame_spikes.size()
	])

	# === ПАТТЕРН: Когда происходят спайки? ===
	print("\n📈 PATTERN: When do spikes occur?")

	var early = 0  # 0-30s
	var mid = 0    # 30-60s
	var late = 0   # 60-90s

	for spike in frame_spikes:
		if spike.time < 30.0:
			early += 1
		elif spike.time < 60.0:
			mid += 1
		else:
			late += 1

	print("  Early game (0-30s): %d spikes (%.1f%%)" % [early, 100.0 * early / frame_spikes.size()])
	print("  Mid game (30-60s): %d spikes (%.1f%%)" % [mid, 100.0 * mid / frame_spikes.size()])
	print("  Late game (60-90s): %d spikes (%.1f%%)" % [late, 100.0 * late / frame_spikes.size()])

	# === SEVERITY DISTRIBUTION ===
	print("\n📈 SPIKE SEVERITY:")
	var mild_spikes = 0    # 25-35ms
	var medium_spikes = 0  # 35-50ms
	var severe_spikes = 0  # >50ms

	for spike in frame_spikes:
		if spike.frame_time > 50.0:
			severe_spikes += 1
		elif spike.frame_time > 35.0:
			medium_spikes += 1
		else:
			mild_spikes += 1

	print("  Mild (25-35ms): %d (%.1f%%)" % [mild_spikes, 100.0 * mild_spikes / frame_spikes.size()])
	print("  Medium (35-50ms): %d (%.1f%%)" % [medium_spikes, 100.0 * medium_spikes / frame_spikes.size()])
	print("  Severe (>50ms): %d (%.1f%%)" % [severe_spikes, 100.0 * severe_spikes / frame_spikes.size()])

	# === ТОП-5 WORST SPIKES ===
	print("\n🔴 TOP 5 WORST FRAME SPIKES:")

	# Сортировка по frame_time (descending)
	var sorted_spikes = frame_spikes.duplicate()
	sorted_spikes.sort_custom(func(a, b): return a.frame_time > b.frame_time)

	for i in range(min(5, sorted_spikes.size())):
		var s = sorted_spikes[i]
		print("  #%d: %.1f ms at %.1fs" % [i + 1, s.frame_time, s.time])
		print("      Draw: %d | Bodies: %d | Vertices: %d | Nodes: %d" % [
			s.draw_calls, s.physics_bodies, s.vertices, s.nodes
		])

	# === PHYSICS SPIKES ANALYSIS ===
	if physics_spikes.size() > 0:
		print("\n🔴 PHYSICS SPIKES ANALYSIS:")
		print("  Total physics spikes: %d" % physics_spikes.size())

		# Worst physics spike
		var sorted_physics = physics_spikes.duplicate()
		sorted_physics.sort_custom(func(a, b): return a.physics_time > b.physics_time)

		print("\n  Top 3 worst physics spikes:")
		for i in range(min(3, sorted_physics.size())):
			var s = sorted_physics[i]
			print("    #%d: %.1f ms at %.1fs (Bodies: %d)" % [
				i + 1, s.physics_time, s.time, s.bodies
			])

	# === RECOMMENDATIONS ===
	print("\n💡 RECOMMENDATIONS:")

	if very_high_drawcall_spikes > frame_spikes.size() * 0.5:
		print("  🔴 CRITICAL: >50%% of spikes have >8000 draw calls")
		print("     → Optimize rendering FIRST (batching, LOD, frustum culling)")

	if early > frame_spikes.size() * 0.6:
		print("  ⚠️  Most spikes occur in early game (0-30s)")
		print("     → Optimize chunk loading and initial mesh generation")

	if severe_spikes > 10:
		print("  🔴 %d severe spikes (>50ms) detected" % severe_spikes)
		print("     → Check console logs for FREEZE/SLOW messages")

	if physics_spikes.size() > 100:
		print("  ⚠️  High number of physics spikes (%d)" % physics_spikes.size())
		print("     → Reduce physics bodies or implement physics LOD")

	print("\n==============================================\n")

	# Save analysis to file
	var analysis_file = OS.get_user_data_dir() + "/performance_analysis.txt"
	var out_file = FileAccess.open(analysis_file, FileAccess.WRITE)
	if out_file:
		out_file.store_string("Performance Analysis Report\n")
		out_file.store_string("===========================\n\n")
		out_file.store_string("Frame spikes: %d\n" % frame_spikes.size())
		out_file.store_string("Physics spikes: %d\n" % physics_spikes.size())
		out_file.store_string("\nSee console output for detailed analysis.\n")
		out_file.close()
		print("Analysis saved to: %s" % analysis_file)
