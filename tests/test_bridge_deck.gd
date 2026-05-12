extends Node
class_name TestBridgeDeck

## Tests for bridge elevation redesign and man_made=bridge deck platform.
## Covers: bridge node registry, shared endpoint detection, height function,
## deck polygon detection, and on-deck road rendering path.

const OSMTerrainGeneratorScript = preload("res://osm/osm_terrain_generator.gd")

var tests_passed := 0
var tests_failed := 0
var test_results := []


func run_all_tests() -> void:
	print("\n=== Bridge Deck Tests ===\n")
	tests_passed = 0
	tests_failed = 0
	test_results.clear()

	test_bridge_coord_key_quantization()
	test_register_bridge_node()
	test_bridge_endpoint_is_shared()
	test_bridge_endpoint_touches_any()
	test_bridge_prescan_ways()
	test_bridge_height_at_free_both_ends()
	test_bridge_height_at_shared_start()
	test_bridge_height_at_shared_both()
	test_bridge_height_at_short_way()
	test_is_point_on_bridge_deck()
	test_is_way_on_bridge_deck()
	test_bridge_deck_not_found_when_empty()
	test_prescan_skips_blacklisted_ways()
	test_polygon_axis_ends_finds_long_axis_extremes()
	test_compute_ref_elev_returns_max_axis_end_elev()
	test_compute_ref_elev_returns_nan_when_axis_chunks_missing()
	test_compute_ref_elev_caches_result()
	test_deck_surface_y_constant_in_middle()
	test_deck_surface_y_lerps_at_axis_ends()
	test_deck_surface_y_handles_unloaded_local_via_ref_fallback()
	test_deck_surface_y_at_cached_returns_terrain_outside_deck()
	test_deck_surface_y_at_cached_uses_polygon_ref_elev()

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


func _make_gen() -> Node3D:
	var gen := OSMTerrainGeneratorScript.new()
	gen.start_lat = 0.0
	gen.start_lon = 0.0
	gen.chunk_size = 200.0
	return gen


# === Coordinate key ===

func test_bridge_coord_key_quantization() -> void:
	var gen := _make_gen()
	var k1: String = gen._bridge_coord_key(59.1137542, 37.9035627)
	var k2: String = gen._bridge_coord_key(59.1137542, 37.9035627)
	_assert(k1 == k2, "coord_key_same_input_same_output")
	# Different coords → different keys
	var k3: String = gen._bridge_coord_key(59.1137543, 37.9035627)
	_assert(k1 != k3, "coord_key_different_lat_different_key")
	gen.free()


# === Registry ===

func test_register_bridge_node() -> void:
	var gen := _make_gen()
	gen._register_bridge_node(59.0, 37.0, 100)
	gen._register_bridge_node(59.0, 37.0, 200)
	var k: String = gen._bridge_coord_key(59.0, 37.0)
	var entries: Dictionary = gen._bridge_node_ways.get(k, {})
	_assert(entries.size() == 2, "register_two_ways_at_same_node",
		"expected 2, got %d" % entries.size())
	_assert(entries.has(100) and entries.has(200), "register_correct_way_ids")
	gen.free()


func test_bridge_endpoint_is_shared() -> void:
	var gen := _make_gen()
	gen._register_bridge_node(59.0, 37.0, 100)
	_assert(not gen._bridge_endpoint_is_shared(59.0, 37.0),
		"shared_false_with_one_way")
	gen._register_bridge_node(59.0, 37.0, 200)
	_assert(gen._bridge_endpoint_is_shared(59.0, 37.0),
		"shared_true_with_two_ways")
	_assert(not gen._bridge_endpoint_is_shared(59.1, 37.1),
		"shared_false_at_unregistered_coord")
	gen.free()


func test_bridge_endpoint_touches_any() -> void:
	var gen := _make_gen()
	_assert(not gen._bridge_endpoint_touches_any(59.0, 37.0),
		"touches_false_when_empty")
	gen._register_bridge_node(59.0, 37.0, 100)
	_assert(gen._bridge_endpoint_touches_any(59.0, 37.0),
		"touches_true_with_one_way")
	gen.free()


# === Prescan ===

func test_bridge_prescan_ways() -> void:
	var gen := _make_gen()
	var ways := [
		{"id": 1, "tags": {"highway": "primary", "bridge": "yes"},
		 "nodes": [{"lat": 0.001, "lon": 0.0}, {"lat": 0.002, "lon": 0.0}]},
		{"id": 2, "tags": {"highway": "primary", "bridge": "yes"},
		 "nodes": [{"lat": 0.002, "lon": 0.0}, {"lat": 0.003, "lon": 0.0}]},
		{"id": 3, "tags": {"highway": "primary"},
		 "nodes": [{"lat": 0.003, "lon": 0.0}, {"lat": 0.004, "lon": 0.0}]},
	]
	gen._bridge_prescan_ways(ways)
	# Way 1 and 2 are bridges. Way 3 is not (no bridge=yes).
	# Node at (0.002, 0.0) is shared by way 1 (end) and way 2 (start).
	_assert(gen._bridge_endpoint_is_shared(0.002, 0.0),
		"prescan_shared_node_detected")
	_assert(not gen._bridge_endpoint_is_shared(0.001, 0.0),
		"prescan_free_end_not_shared")
	# Way 3 (no bridge tag) should NOT be in registry
	_assert(not gen._bridge_endpoint_touches_any(0.004, 0.0),
		"prescan_non_bridge_not_registered")
	gen.free()


func test_prescan_skips_blacklisted_ways() -> void:
	var gen := _make_gen()
	var ways := [
		{"id": 587234728, "tags": {"highway": "steps", "bridge": "yes"},
		 "nodes": [{"lat": 0.005, "lon": 0.0}, {"lat": 0.006, "lon": 0.0}]},
	]
	gen._bridge_prescan_ways(ways)
	_assert(not gen._bridge_endpoint_touches_any(0.005, 0.0),
		"blacklisted_stair_not_registered")
	gen.free()


# === Height function ===

func test_bridge_height_at_free_both_ends() -> void:
	var gen := _make_gen()
	var deck: float = gen.BRIDGE_DECK_HEIGHT
	var ramp: float = gen.BRIDGE_RAMP_LENGTH
	var total := 200.0
	var h_offset := 0.01
	# At start (accumulated=0): ramp from 0, smooth_step(0)=0 → h=0+h_offset
	var h0: float = gen._bridge_height_at(0.0, ramp, ramp, total, h_offset)
	_assert(absf(h0 - h_offset) < 0.01, "height_at_free_start_is_zero",
		"expected ~%.3f, got %.3f" % [h_offset, h0])
	# At middle (accumulated=100): flat deck → h=deck+h_offset
	var hm: float = gen._bridge_height_at(100.0, ramp, ramp, total, h_offset)
	_assert(absf(hm - (deck + h_offset)) < 0.01, "height_at_middle_is_deck",
		"expected ~%.3f, got %.3f" % [deck + h_offset, hm])
	# At end (accumulated=200): ramp to 0 → h=0+h_offset
	var he: float = gen._bridge_height_at(200.0, ramp, ramp, total, h_offset)
	_assert(absf(he - h_offset) < 0.01, "height_at_free_end_is_zero",
		"expected ~%.3f, got %.3f" % [h_offset, he])
	gen.free()


func test_bridge_height_at_shared_start() -> void:
	var gen := _make_gen()
	var deck: float = gen.BRIDGE_DECK_HEIGHT
	var ramp: float = gen.BRIDGE_RAMP_LENGTH
	var total := 200.0
	var h_offset := 0.01
	# ramp_from_start=0 (shared), ramp_from_end=35 (free)
	# At start: should be at full deck (shared = no ramp)
	var h0: float = gen._bridge_height_at(0.0, 0.0, ramp, total, h_offset)
	_assert(absf(h0 - (deck + h_offset)) < 0.01, "height_shared_start_is_deck",
		"expected ~%.3f, got %.3f" % [deck + h_offset, h0])
	# At end: should ramp to 0
	var he: float = gen._bridge_height_at(total, 0.0, ramp, total, h_offset)
	_assert(absf(he - h_offset) < 0.01, "height_free_end_is_zero",
		"expected ~%.3f, got %.3f" % [h_offset, he])
	gen.free()


func test_bridge_height_at_shared_both() -> void:
	var gen := _make_gen()
	var deck: float = gen.BRIDGE_DECK_HEIGHT
	var total := 50.0
	var h_offset := 0.01
	# Both ends shared → flat deck everywhere
	var h0: float = gen._bridge_height_at(0.0, 0.0, 0.0, total, h_offset)
	var hm: float = gen._bridge_height_at(25.0, 0.0, 0.0, total, h_offset)
	var he: float = gen._bridge_height_at(50.0, 0.0, 0.0, total, h_offset)
	_assert(absf(h0 - (deck + h_offset)) < 0.01, "shared_both_start_is_deck")
	_assert(absf(hm - (deck + h_offset)) < 0.01, "shared_both_mid_is_deck")
	_assert(absf(he - (deck + h_offset)) < 0.01, "shared_both_end_is_deck")
	gen.free()


func test_bridge_height_at_short_way() -> void:
	var gen := _make_gen()
	var deck: float = gen.BRIDGE_DECK_HEIGHT
	var total := 20.0  # Shorter than BRIDGE_RAMP_LENGTH
	var h_offset := 0.01
	# Both free, total < 2*ramp → ramps split in half (10m each)
	# ramp_from_start = ramp_from_end = 10 (total/2 since total < 2*RAMP)
	var ramp_half := total * 0.5
	# At middle (10m): both ramps reach full deck
	var hm: float = gen._bridge_height_at(10.0, ramp_half, ramp_half, total, h_offset)
	_assert(absf(hm - (deck + h_offset)) < 0.01, "short_way_mid_reaches_deck",
		"expected ~%.3f, got %.3f" % [deck + h_offset, hm])
	gen.free()


# === Deck polygon ===

func test_is_point_on_bridge_deck() -> void:
	var gen := _make_gen()
	# Add a square deck polygon: (0,0), (100,0), (100,100), (0,100)
	var poly := PackedVector2Array([
		Vector2(0, 0), Vector2(100, 0), Vector2(100, 100), Vector2(0, 100)
	])
	gen._bridge_deck_polygons.append(poly)
	_assert(gen._is_point_on_bridge_deck(Vector2(50, 50)),
		"point_inside_deck_polygon")
	_assert(not gen._is_point_on_bridge_deck(Vector2(150, 50)),
		"point_outside_deck_polygon")
	gen.free()


func test_is_way_on_bridge_deck() -> void:
	var gen := _make_gen()
	# Deck polygon covers a region
	var poly := PackedVector2Array([
		Vector2(-50, -500), Vector2(50, -500), Vector2(50, 500), Vector2(-50, 500)
	])
	gen._bridge_deck_polygons.append(poly)
	# Way whose midpoint is inside the deck
	var nodes_inside := [
		{"lat": -0.001, "lon": 0.0},  # game z ≈ 111
		{"lat": 0.0, "lon": 0.0},     # game z = 0
		{"lat": 0.001, "lon": 0.0},   # game z ≈ -111
	]
	_assert(gen._is_way_on_bridge_deck(nodes_inside),
		"way_inside_deck")
	# Way whose midpoint is outside
	var nodes_outside := [
		{"lat": -0.01, "lon": 0.01},
		{"lat": -0.02, "lon": 0.01},
	]
	_assert(not gen._is_way_on_bridge_deck(nodes_outside),
		"way_outside_deck")
	gen.free()


func test_bridge_deck_not_found_when_empty() -> void:
	var gen := _make_gen()
	_assert(not gen._is_point_on_bridge_deck(Vector2(0, 0)),
		"no_deck_returns_false")
	var nodes := [{"lat": 0.0, "lon": 0.0}, {"lat": 0.001, "lon": 0.0}]
	_assert(not gen._is_way_on_bridge_deck(nodes),
		"no_deck_way_returns_false")
	gen.free()


# === Polygon axis ends + ref_elev (post-merge restoration) ===

# Build a uniform 5×5 elevation grid covering one chunk and stash it under
# `chunk_key`. `chunk_size` matches the gen's chunk_size; the grid origin
# is at the chunk's local bottom-left corner.
func _stash_uniform_elev(gen: Node3D, chunk_x: int, chunk_z: int, elev: float) -> void:
	var step: float = gen.chunk_size / 4.0  # 5 samples → 4 intervals
	var grid := []
	for _r in 5:
		var row := []
		for _c in 5:
			row.append(elev)
		grid.append(row)
	var ck := "%d,%d" % [chunk_x, chunk_z]
	gen._chunk_elevation_data[ck] = {
		"grid": grid,
		"grid_res": 5,
		"base_x": float(chunk_x) * gen.chunk_size,
		"base_z": float(chunk_z) * gen.chunk_size,
		"grid_step": step,
	}


func test_polygon_axis_ends_finds_long_axis_extremes() -> void:
	var gen := _make_gen()
	# Wide rectangle 600×30, long axis runs along x.
	var poly := PackedVector2Array([
		Vector2(-300, -15), Vector2(300, -15),
		Vector2(300, 15), Vector2(-300, 15),
	])
	gen._bridge_deck_polygons.append(poly)
	var ends: Array = gen._polygon_axis_ends(poly)
	# The two axis ends should be on opposite long sides (x ≈ ±300, |x|≈300).
	var xs := [absf(ends[0].x), absf(ends[1].x)]
	xs.sort()
	_assert(xs[0] >= 290.0 and xs[1] >= 290.0,
		"axis_ends_at_long_axis_extremes",
		"got %s" % str(ends))
	gen.free()


func test_compute_ref_elev_returns_max_axis_end_elev() -> void:
	var gen := _make_gen()
	gen.enable_elevation = true
	# Long polygon spanning chunks 0..2 (chunk_size=200 → x ∈ [-100, 500]).
	var poly := PackedVector2Array([
		Vector2(-100, -10), Vector2(500, -10),
		Vector2(500, 10), Vector2(-100, 10),
	])
	gen._bridge_deck_polygons.append(poly)
	# axis_a (-100, ?) → chunk -1 (since floor(-100/200) = -1)
	# axis_b (500, ?)  → chunk 2  (since floor(500/200)  = 2)
	_stash_uniform_elev(gen, -1, 0, 110.0)  # bank_a
	_stash_uniform_elev(gen, 2, 0, 115.0)   # bank_b (higher)
	var ref_elev: float = gen._compute_and_cache_deck_ref_elev(0)
	_assert(absf(ref_elev - 115.0) < 0.5,
		"ref_elev_is_max_of_axis_end_elevs",
		"expected ~115, got %.2f" % ref_elev)
	gen.free()


func test_compute_ref_elev_returns_nan_when_axis_chunks_missing() -> void:
	var gen := _make_gen()
	gen.enable_elevation = true
	var poly := PackedVector2Array([
		Vector2(-100, -10), Vector2(500, -10),
		Vector2(500, 10), Vector2(-100, 10),
	])
	gen._bridge_deck_polygons.append(poly)
	_stash_uniform_elev(gen, -1, 0, 110.0)  # only one abutment loaded
	var ref_elev: float = gen._compute_and_cache_deck_ref_elev(0)
	_assert(is_nan(ref_elev),
		"ref_elev_nan_when_one_abutment_chunk_missing",
		"expected NAN, got %s" % str(ref_elev))
	gen.free()


func test_compute_ref_elev_caches_result() -> void:
	var gen := _make_gen()
	gen.enable_elevation = true
	var poly := PackedVector2Array([
		Vector2(-100, -10), Vector2(500, -10),
		Vector2(500, 10), Vector2(-100, 10),
	])
	gen._bridge_deck_polygons.append(poly)
	_stash_uniform_elev(gen, -1, 0, 110.0)
	_stash_uniform_elev(gen, 2, 0, 115.0)
	var first: float = gen._compute_and_cache_deck_ref_elev(0)
	# Now wipe the elevation grid — cached value should still come back.
	gen._chunk_elevation_data.clear()
	var second: float = gen._compute_and_cache_deck_ref_elev(0)
	_assert(absf(first - second) < 0.001,
		"ref_elev_cached_after_first_compute",
		"first=%.2f second=%.2f" % [first, second])
	gen.free()


func test_deck_surface_y_constant_in_middle() -> void:
	var gen := _make_gen()
	gen.enable_elevation = true
	# 600m long polygon → flat middle is far from BRIDGE_RAMP_LENGTH (35m)
	# from either axis end.
	var poly := PackedVector2Array([
		Vector2(-300, -15), Vector2(300, -15),
		Vector2(300, 15), Vector2(-300, 15),
	])
	gen._bridge_deck_polygons.append(poly)
	_stash_uniform_elev(gen, -2, 0, 100.0)  # axis_a chunk
	_stash_uniform_elev(gen, 1, 0, 110.0)   # axis_b chunk
	var ref_elev: float = gen._compute_and_cache_deck_ref_elev(0)
	# A point at x=0 (middle): t == 1, Y must be ref_elev + BRIDGE_DECK_HEIGHT.
	var y_mid: float = gen._deck_surface_y_at(Vector2(0, 0), poly, 1, ref_elev)
	var expected: float = ref_elev + gen.BRIDGE_DECK_HEIGHT
	_assert(absf(y_mid - expected) < 0.01,
		"deck_y_constant_in_flat_middle",
		"expected %.2f, got %.2f (ref=%.2f)" % [expected, y_mid, ref_elev])
	gen.free()


func test_deck_surface_y_lerps_at_axis_ends() -> void:
	var gen := _make_gen()
	gen.enable_elevation = true
	var poly := PackedVector2Array([
		Vector2(-300, -15), Vector2(300, -15),
		Vector2(300, 15), Vector2(-300, 15),
	])
	gen._bridge_deck_polygons.append(poly)
	# Left abutment chunk at 100m, right at 110m → ref_elev = 110m
	_stash_uniform_elev(gen, -2, 0, 100.0)
	_stash_uniform_elev(gen, 1, 0, 110.0)
	var ref_elev: float = gen._compute_and_cache_deck_ref_elev(0)
	# Point on axis_a (x=-300): t=0, Y == local elev (= 100) + 0
	var y_at_axis_a: float = gen._deck_surface_y_at(Vector2(-300, 0), poly, 1, ref_elev)
	_assert(absf(y_at_axis_a - 100.0) < 1.0,
		"deck_y_lerps_to_local_at_axis_a",
		"expected ~100, got %.2f" % y_at_axis_a)
	# Point at axis_b (x=300): t=0, Y == local elev (= 110)
	var y_at_axis_b: float = gen._deck_surface_y_at(Vector2(300, 0), poly, 1, ref_elev)
	_assert(absf(y_at_axis_b - 110.0) < 1.0,
		"deck_y_lerps_to_local_at_axis_b",
		"expected ~110, got %.2f" % y_at_axis_b)
	# Point 35m+ inside: Y == ref_elev + BRIDGE_DECK_HEIGHT
	var y_inside: float = gen._deck_surface_y_at(Vector2(-260, 0), poly, 1, ref_elev)
	var expected_inside: float = ref_elev + gen.BRIDGE_DECK_HEIGHT
	_assert(absf(y_inside - expected_inside) < 0.5,
		"deck_y_at_full_deck_after_ramp_zone",
		"expected ~%.2f, got %.2f" % [expected_inside, y_inside])
	gen.free()


func test_deck_surface_y_handles_unloaded_local_via_ref_fallback() -> void:
	var gen := _make_gen()
	gen.enable_elevation = true
	var poly := PackedVector2Array([
		Vector2(-300, -15), Vector2(300, -15),
		Vector2(300, 15), Vector2(-300, 15),
	])
	gen._bridge_deck_polygons.append(poly)
	# Both axis-end chunks loaded so we get ref_elev.
	_stash_uniform_elev(gen, -2, 0, 100.0)
	_stash_uniform_elev(gen, 1, 0, 100.0)
	var ref_elev: float = gen._compute_and_cache_deck_ref_elev(0)
	# Now query a point in the ramp zone whose chunk is NOT loaded
	# (chunk -1 between the two axis chunks).
	var y: float = gen._deck_surface_y_at(Vector2(-280, 0), poly, 1, ref_elev)
	# Local would be 0 → fallback to ref_elev (=100). At edge t≈0,
	# Y ≈ ref_elev + small. Anything between [ref_elev, ref_elev + 5].
	_assert(y >= ref_elev - 0.5 and y <= ref_elev + gen.BRIDGE_DECK_HEIGHT + 0.5,
		"deck_y_falls_back_to_ref_when_local_chunk_unloaded",
		"got %.2f, ref=%.2f, deck_top=%.2f" % [y, ref_elev, ref_elev + gen.BRIDGE_DECK_HEIGHT])
	gen.free()


func test_deck_surface_y_at_cached_returns_terrain_outside_deck() -> void:
	var gen := _make_gen()
	gen.enable_elevation = true
	# No deck polygons at all → cached lookup must return _sample_elevation
	# (== 0 in absence of grids), NOT some bridge-derived value.
	var y: float = gen._deck_surface_y_at_cached(Vector2(50, 50))
	_assert(absf(y) < 0.001,
		"cached_returns_zero_when_no_deck_and_no_elev_data",
		"expected 0, got %.2f" % y)
	gen.free()


func test_deck_surface_y_at_cached_uses_polygon_ref_elev() -> void:
	var gen := _make_gen()
	gen.enable_elevation = true
	var poly := PackedVector2Array([
		Vector2(-300, -15), Vector2(300, -15),
		Vector2(300, 15), Vector2(-300, 15),
	])
	gen._bridge_deck_polygons.append(poly)
	_stash_uniform_elev(gen, -2, 0, 100.0)
	_stash_uniform_elev(gen, 1, 0, 110.0)
	# Pre-warm cache.
	gen._compute_and_cache_deck_ref_elev(0)
	# Query a flat-middle point via the cached wrapper.
	var y: float = gen._deck_surface_y_at_cached(Vector2(0, 0))
	var expected: float = 110.0 + gen.BRIDGE_DECK_HEIGHT
	_assert(absf(y - expected) < 0.5,
		"cached_uses_polygon_ref_elev",
		"expected %.2f, got %.2f" % [expected, y])
	gen.free()
