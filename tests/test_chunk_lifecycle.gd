extends Node
class_name TestChunkLifecycle

const OSMTerrainGeneratorScript = preload("res://osm/osm_terrain_generator.gd")

var tests_passed := 0
var tests_failed := 0
var test_results := []


func run_all_tests() -> void:
	print("\n=== Chunk Lifecycle Tests ===\n")
	tests_passed = 0
	tests_failed = 0
	test_results.clear()

	await test_chunk_reaches_ready_state_with_fake_provider()
	await test_async_result_before_loaded_chunks_does_not_drop_chunk()
	await test_terrain_gen_result_uses_stored_chunk_node()
	await test_cancelled_chunk_ignores_stale_results_without_poisoning_retry()
	await test_activation_pending_reports_blocking_queue()
	await test_debug_only_backlog_does_not_block_activation()
	await test_chunk_with_queued_roads_does_not_finalize_empty()
	await test_pending_batch_chunk_road_queue_gets_priority()
	await test_road_dispatch_round_robin_reaches_second_pending_batch_chunk()
	await test_hidden_pending_batch_chunk_still_processes()
	await test_chunk_load_queue_deduplicates_and_sorts()
	await test_chunk_load_queue_respects_max_concurrent_loads()
	await test_incomplete_chunk_cannot_purge_on_cull()
	await test_ready_chunk_without_blockers_can_purge_on_cull()

	print("\n=== Results ===")
	print("Passed: %d" % tests_passed)
	print("Failed: %d" % tests_failed)
	print("Total: %d" % (tests_passed + tests_failed))
	if tests_failed > 0:
		print("\nFailed tests:")
		for result in test_results:
			if not result.passed:
				print("  - %s: %s" % [result.name, result.message])


func _assert(condition: bool, test_name: String, message: String = "") -> void:
	if condition:
		tests_passed += 1
		test_results.append({"name": test_name, "passed": true, "message": ""})
		print("[PASS] %s" % test_name)
	else:
		tests_failed += 1
		test_results.append({"name": test_name, "passed": false, "message": message})
		print("[FAIL] %s - %s" % [test_name, message])


func _configure_test_generator(gen: Node3D) -> void:
	gen.show_debug_stats = false
	gen.debug_print = false
	gen.debug_chunk_lifecycle = false
	gen.enable_buildings = false
	gen.enable_windows = false
	gen.enable_roads = false
	gen.enable_curbs = false
	gen.enable_vegetation = false
	gen.enable_street_lamps = false
	gen.enable_traffic_signs = false
	gen.enable_traffic_lights = false
	gen.enable_manholes = false
	gen.enable_crossing_signs = false
	gen.enable_fences = false
	gen.enable_frustum_culling = false
	gen.load_distance = 100.0
	gen.unload_distance = 200.0


func _empty_osm_data(_lat: float, _lon: float, _size: float) -> Dictionary:
	return {
		"nodes": {},
		"ways": [],
		"point_objects": [],
		"entrance_nodes": [],
		"poi_nodes": [],
		"bus_stops": [],
	}


func _make_generator() -> OSMTerrainGenerator:
	var gen: OSMTerrainGenerator = OSMTerrainGeneratorScript.new()
	_configure_test_generator(gen)
	add_child(gen)
	return gen


func _make_tgen_result(chunk_key: String, gen: int) -> Dictionary:
	return {
		"chunk_key": chunk_key,
		"gen": gen,
		"osm_data": _empty_osm_data(0.0, 0.0, 0.0),
		"parking_polygons": [],
		"parking_bounds": [],
		"parking_hash_entries": [],
		"road_hash_entries": [],
		"building_hash_entries": [],
		"building_poly_entries": [],
		"new_positions": [],
		"new_radii": [],
		"new_angles": [],
		"new_types": [],
		"new_roads": [],
		"new_contours": [],
		"new_curb_contours": [],
		"new_hash_entries": [],
		"node_road_count": {},
		"node_positions": {},
		"node_road_types": {},
		"thread_time_ms": 0.1,
	}


func _cleanup_generator(gen: OSMTerrainGenerator) -> void:
	if is_instance_valid(gen):
		gen.queue_free()


func _await_ready(gen: OSMTerrainGenerator) -> void:
	while not gen.is_node_ready():
		await get_tree().process_frame
	await get_tree().process_frame


func _wait_for_chunk_ready(gen: OSMTerrainGenerator, chunk_key: String, max_frames: int = 240) -> bool:
	for _i in range(max_frames):
		if gen.is_chunk_fully_ready(chunk_key):
			return true
		await get_tree().process_frame
	return false


func test_chunk_reaches_ready_state_with_fake_provider() -> void:
	var gen: OSMTerrainGenerator = _make_generator()
	await _await_ready(gen)
	gen.test_data_provider = Callable(self, "_empty_osm_data")
	gen._load_chunk(0, 0)
	var ready: bool = await _wait_for_chunk_ready(gen, "0,0")
	var debug_state: Dictionary = gen.get_chunk_debug_state("0,0")
	_assert(ready, "chunk_reaches_ready_state_with_fake_provider", "Chunk 0,0 did not reach ready")
	_assert(debug_state.get("stage", "") == "ready", "chunk_ready_stage_is_ready", "Expected ready stage, got %s" % str(debug_state.get("stage", "")))
	_assert(not gen._loading_chunks.has("0,0"), "chunk_ready_no_loading_entry", "Chunk 0,0 still in _loading_chunks")
	_assert(not gen._chunk_activation_pending.has("0,0"), "chunk_ready_no_activation_entry", "Chunk 0,0 still activation-pending")
	_cleanup_generator(gen)
	await get_tree().process_frame


func test_async_result_before_loaded_chunks_does_not_drop_chunk() -> void:
	var gen: OSMTerrainGenerator = _make_generator()
	await _await_ready(gen)
	var chunk_key := "0,0"
	var chunk_node := Node3D.new()
	chunk_node.name = "Chunk_" + chunk_key
	gen.add_child(chunk_node)
	gen._ensure_chunk_state(chunk_key, chunk_node)
	gen._set_chunk_stage(chunk_key, "http_loaded", {"generation": gen._load_generation, "node": chunk_node})
	gen._loading_chunks[chunk_key] = Time.get_ticks_msec()
	gen._chunk_activation_pending[chunk_key] = -1
	gen._apply_single_terrain_gen_result(_make_tgen_result(chunk_key, gen._load_generation))
	var queued: bool = gen._phase3_queue.size() == 1
	var ready: bool = await _wait_for_chunk_ready(gen, chunk_key)
	_assert(queued, "async_result_queued_phase3", "Terrain gen result was not queued for phase 3")
	_assert(ready, "async_result_before_loaded_chunks_does_not_drop_chunk", "Chunk 0,0 did not reach ready after async result")
	_cleanup_generator(gen)
	await get_tree().process_frame


func test_terrain_gen_result_uses_stored_chunk_node() -> void:
	var gen: OSMTerrainGenerator = _make_generator()
	await _await_ready(gen)
	var chunk_key := "1,0"
	var chunk_node := Node3D.new()
	chunk_node.name = "DetachedChunkNode"
	gen.add_child(chunk_node)
	gen._ensure_chunk_state(chunk_key, chunk_node)
	gen._set_chunk_stage(chunk_key, "http_loaded", {"generation": gen._load_generation, "node": chunk_node})
	gen._loading_chunks[chunk_key] = Time.get_ticks_msec()
	gen._chunk_activation_pending[chunk_key] = -1
	gen._apply_single_terrain_gen_result(_make_tgen_result(chunk_key, gen._load_generation))
	var debug_state: Dictionary = gen.get_chunk_debug_state(chunk_key)
	_assert(gen._phase3_queue.size() == 1, "terrain_gen_result_uses_stored_chunk_node", "Terrain gen result was dropped for stored node")
	_assert(debug_state.get("stage", "") == "terrain_gen_ready", "terrain_gen_result_stage_ready", "Expected terrain_gen_ready, got %s" % str(debug_state.get("stage", "")))
	_cleanup_generator(gen)
	await get_tree().process_frame


func test_cancelled_chunk_ignores_stale_results_without_poisoning_retry() -> void:
	var gen: OSMTerrainGenerator = _make_generator()
	await _await_ready(gen)
	var chunk_key := "0,0"
	var stale_node := Node3D.new()
	stale_node.name = "StaleChunkNode"
	gen.add_child(stale_node)
	gen._ensure_chunk_state(chunk_key, stale_node)
	gen._set_chunk_stage(chunk_key, "cancelled", {"generation": 0, "node": stale_node, "cancelled": true})
	gen._load_generation = 1
	gen._apply_single_terrain_gen_result(_make_tgen_result(chunk_key, 0))
	var ignored_stale: bool = gen._phase3_queue.is_empty()
	gen.test_data_provider = Callable(self, "_empty_osm_data")
	gen._load_chunk(0, 0)
	var ready: bool = await _wait_for_chunk_ready(gen, chunk_key)
	_assert(ignored_stale, "cancelled_chunk_ignores_stale_results", "Stale terrain result should have been ignored")
	_assert(ready, "cancelled_chunk_retry_reaches_ready", "Chunk retry did not reach ready")
	_cleanup_generator(gen)
	await get_tree().process_frame


func test_activation_pending_reports_blocking_queue() -> void:
	var gen: OSMTerrainGenerator = _make_generator()
	await _await_ready(gen)
	var chunk_key := "2,0"
	var chunk_node := Node3D.new()
	chunk_node.name = "Chunk_" + chunk_key
	gen.add_child(chunk_node)
	gen._ensure_chunk_state(chunk_key, chunk_node)
	gen._set_chunk_stage(chunk_key, "finalizing", {"generation": gen._load_generation, "node": chunk_node})
	gen._chunk_activation_pending[chunk_key] = -1
	gen._deferred_append(gen._deferred_lamp_queue, chunk_key, {
		"points": PackedVector2Array(),
		"width": 0.0,
		"parent": chunk_node,
	})
	var debug_state: Dictionary = gen.get_chunk_debug_state(chunk_key)
	var blockers: Array = debug_state.get("blockers", [])
	_assert("deferred_lamps" in blockers, "activation_pending_reports_blocking_queue", "Expected deferred_lamps blocker, got %s" % str(blockers))
	_cleanup_generator(gen)
	await get_tree().process_frame


func test_debug_only_backlog_does_not_block_activation() -> void:
	var gen: OSMTerrainGenerator = _make_generator()
	await _await_ready(gen)
	var chunk_key := "3,0"
	var chunk_node := Node3D.new()
	chunk_node.name = "Chunk_" + chunk_key
	gen.add_child(chunk_node)
	gen._ensure_chunk_state(chunk_key, chunk_node)
	gen._set_chunk_stage(chunk_key, "finalizing", {"generation": gen._load_generation, "node": chunk_node})
	gen._chunk_activation_pending[chunk_key] = -1
	var fake_terrain_polys: Array[PackedVector2Array] = []
	gen._terrain_thread_results.append({
		"chunk_key": chunk_key,
		"terrain_polys": fake_terrain_polys,
	})
	gen._process_chunk_activation()
	var debug_state: Dictionary = gen.get_chunk_debug_state(chunk_key)
	var blockers: Array = debug_state.get("blockers", [])
	var activation_blockers: Array = debug_state.get("activation_blockers", [])
	_assert("terrain_thread_results" in blockers, "debug_only_backlog_reported", "Expected terrain_thread_results in debug blockers, got %s" % str(blockers))
	_assert(not ("terrain_thread_results" in activation_blockers), "debug_only_backlog_not_activation_blocker", "terrain_thread_results should not block activation")
	_assert(gen._chunk_activation_pending.get(chunk_key, -1) == 0, "debug_only_backlog_does_not_block_activation", "Chunk should move from waiting to activation when only debug backlog remains")
	gen._terrain_thread_results.clear()
	_cleanup_generator(gen)
	await get_tree().process_frame


func test_chunk_with_queued_roads_does_not_finalize_empty() -> void:
	var gen: OSMTerrainGenerator = _make_generator()
	await _await_ready(gen)
	var chunk_key := "6,0"
	var chunk_node := Node3D.new()
	chunk_node.name = "Chunk_" + chunk_key
	chunk_node.visible = false
	gen.add_child(chunk_node)
	gen._loaded_chunks[chunk_key] = chunk_node
	gen._ensure_chunk_state(chunk_key, chunk_node)
	gen._set_chunk_stage(chunk_key, "finalizing", {"generation": gen._load_generation, "node": chunk_node})
	gen._pending_batch_chunks.append(chunk_key)
	gen._road_queue[chunk_key] = [{
		"nodes": [],
		"tags": {"highway": "service"},
		"parent": chunk_node,
		"way_id": 1,
	}]
	gen._finalize_phase = 0
	gen._process_road_queue()
	var debug_state: Dictionary = gen.get_chunk_debug_state(chunk_key)
	var activation_blockers: Array = debug_state.get("activation_blockers", [])
	_assert(gen._pending_batch_chunks.has(chunk_key), "queued_roads_block_empty_finalize", "Chunk should stay pending while its road queue is not drained")
	_assert("pending_batch" in activation_blockers, "queued_roads_report_activation_blocker", "Expected pending_batch activation blocker, got %s" % str(activation_blockers))
	_assert(not ("road_queue" in activation_blockers), "queued_roads_not_direct_activation_blocker", "road_queue should not directly block activation once batch finalization is holding the chunk")
	_cleanup_generator(gen)
	await get_tree().process_frame


func test_pending_batch_chunk_road_queue_gets_priority() -> void:
	var gen: OSMTerrainGenerator = _make_generator()
	await _await_ready(gen)
	gen._loaded_chunks["9,0"] = Node3D.new()
	gen._loaded_chunks["0,0"] = Node3D.new()
	gen._chunk_activation_pending["9,0"] = -1
	gen._road_queue["9,0"] = [{"parent": Node3D.new()}]
	gen._road_queue["0,0"] = [{"parent": Node3D.new()}]
	gen._pending_batch_chunks.append("9,0")
	var ordered: Array = gen._get_prioritized_road_queue_keys()
	_assert(ordered.size() >= 2 and ordered[0] == "9,0", "pending_batch_chunk_road_queue_gets_priority", "Expected pending_batch chunk first, got %s" % str(ordered))
	gen._loaded_chunks.clear()
	gen._chunk_activation_pending.clear()
	gen._road_queue.clear()
	gen._pending_batch_chunks.clear()
	_cleanup_generator(gen)
	await get_tree().process_frame


func test_road_dispatch_round_robin_reaches_second_pending_batch_chunk() -> void:
	var gen: OSMTerrainGenerator = _make_generator()
	await _await_ready(gen)
	gen._road_queue["9,0"] = [{}, {}, {}, {}, {}, {}, {}, {}]
	gen._road_queue["8,0"] = [{}]
	gen._pending_batch_chunks.append("9,0")
	gen._pending_batch_chunks.append("8,0")
	var dispatch_order: Array = gen._get_road_dispatch_order(8)
	_assert(dispatch_order.size() >= 2 and dispatch_order[0] == "8,0" and dispatch_order[1] == "9,0", "road_dispatch_round_robin_reaches_second_pending_batch_chunk", "Expected closest pending batch chunks to round-robin, got %s" % str(dispatch_order))
	_cleanup_generator(gen)
	await get_tree().process_frame


func test_hidden_pending_batch_chunk_still_processes() -> void:
	var gen: OSMTerrainGenerator = _make_generator()
	await _await_ready(gen)
	var chunk_key := "7,0"
	var chunk_node := Node3D.new()
	chunk_node.visible = false
	gen._loaded_chunks[chunk_key] = chunk_node
	gen._pending_batch_chunks.append(chunk_key)
	_assert(gen._should_process_chunk(chunk_key), "hidden_pending_batch_chunk_still_processes", "Hidden pending_batch chunk should still be processable")
	gen._loaded_chunks.clear()
	gen._pending_batch_chunks.clear()
	_cleanup_generator(gen)
	await get_tree().process_frame


func test_chunk_load_queue_deduplicates_and_sorts() -> void:
	var gen: OSMTerrainGenerator = _make_generator()
	await _await_ready(gen)
	gen._enqueue_chunk_load_request("2,0", 1.0)
	gen._enqueue_chunk_load_request("1,0", 2.0)
	gen._enqueue_chunk_load_request("2,0", 3.0)
	_assert(gen._chunk_load_queue.size() == 2, "chunk_load_queue_deduplicates", "Expected 2 queued chunks, got %d" % gen._chunk_load_queue.size())
	_assert(gen._chunk_load_queue[0]["key"] == "2,0", "chunk_load_queue_sorts_by_priority", "Expected highest priority chunk first, got %s" % str(gen._chunk_load_queue))
	gen._chunk_load_queue.clear()
	_cleanup_generator(gen)
	await get_tree().process_frame


func test_chunk_load_queue_respects_max_concurrent_loads() -> void:
	var gen: OSMTerrainGenerator = _make_generator()
	await _await_ready(gen)
	gen._current_load_count = gen.MAX_CONCURRENT_LOADS
	gen._enqueue_chunk_load_request("3,0", 1.0)
	gen._process_chunk_load_queue()
	_assert(gen._chunk_load_queue.size() == 1, "chunk_load_queue_respects_max_concurrent_loads", "Expected queue to remain blocked at max concurrency")
	gen._chunk_load_queue.clear()
	gen._current_load_count = 0
	_cleanup_generator(gen)
	await get_tree().process_frame


func test_incomplete_chunk_cannot_purge_on_cull() -> void:
	var gen: OSMTerrainGenerator = _make_generator()
	await _await_ready(gen)
	var chunk_key := "4,0"
	var chunk_node := Node3D.new()
	chunk_node.name = "Chunk_" + chunk_key
	gen.add_child(chunk_node)
	gen._loaded_chunks[chunk_key] = chunk_node
	gen._ensure_chunk_state(chunk_key, chunk_node)
	gen._set_chunk_stage(chunk_key, "ready", {"generation": gen._load_generation, "node": chunk_node})
	gen._deferred_append(gen._deferred_billboard_queue, chunk_key, {
		"billboard": {},
		"elevation": 0.0,
		"parent": chunk_node,
	})
	var debug_state: Dictionary = gen.get_chunk_debug_state(chunk_key)
	_assert(not debug_state.get("can_purge_on_cull", true), "incomplete_chunk_cannot_purge_on_cull", "Chunk with remaining blockers should not be purgeable")
	gen._deferred_billboard_queue.erase(chunk_key)
	_cleanup_generator(gen)
	await get_tree().process_frame


func test_ready_chunk_without_blockers_can_purge_on_cull() -> void:
	var gen: OSMTerrainGenerator = _make_generator()
	await _await_ready(gen)
	var chunk_key := "5,0"
	var chunk_node := Node3D.new()
	chunk_node.name = "Chunk_" + chunk_key
	gen.add_child(chunk_node)
	gen._loaded_chunks[chunk_key] = chunk_node
	gen._ensure_chunk_state(chunk_key, chunk_node)
	gen._set_chunk_stage(chunk_key, "ready", {"generation": gen._load_generation, "node": chunk_node})
	var debug_state: Dictionary = gen.get_chunk_debug_state(chunk_key)
	_assert(debug_state.get("can_purge_on_cull", false), "ready_chunk_without_blockers_can_purge_on_cull", "Fully ready chunk without blockers should be purgeable")
	_cleanup_generator(gen)
	await get_tree().process_frame
