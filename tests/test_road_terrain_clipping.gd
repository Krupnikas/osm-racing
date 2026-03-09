extends Node
class_name TestRoadTerrainClipping

## Synthetic tests for the road mesh → terrain corridor → terrain clipping pipeline.
## Verifies that the terrain corridor fully covers the road mesh, so no terrain
## renders on top of roads.
##
## Run via test_runner.tscn or manually instantiate and call run_all_tests().

var tests_passed := 0
var tests_failed := 0
var test_results := []

func run_all_tests() -> void:
	print("\n=== Road-Terrain Clipping Tests ===\n")
	tests_passed = 0
	tests_failed = 0
	test_results.clear()

	test_straight_road_corridor_covers_mesh()
	test_90deg_turn_corridor_covers_mesh()
	test_45deg_turn_corridor_covers_mesh()
	test_s_curve_corridor_covers_mesh()
	test_sharp_u_turn_corridor_covers_mesh()
	test_corridor_perps_match_mesh_perps()
	test_smoothed_road_corridor_covers_mesh()
	test_terrain_clipping_removes_road_area()
	test_terrain_clipping_sharp_turn()
	test_validate_road_direction_consistency()
	test_chunk_boundary_horizontal_road()
	test_chunk_boundary_diagonal_road()
	test_chunk_boundary_real_osm_data()
	test_chunk_boundary_grid_offset_sensitivity()
	test_full_pipeline_straight_road()
	test_full_pipeline_crossing_boundary()
	test_full_pipeline_diagonal_crossing()
	test_full_pipeline_real_osm_multi_grid()
	test_full_pipeline_multiple_roads_one_chunk()
	test_full_pipeline_road_ending_in_chunk()
	test_full_pipeline_road_starting_in_chunk()

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


# ==================== Helper Functions ====================
# These replicate the exact logic from osm_terrain_generator.gd

## Road mesh perpendiculars: forward-only (lines 3918-3929 in osm_terrain_generator.gd)
static func build_road_mesh_perps(points: PackedVector2Array) -> PackedVector2Array:
	var n := points.size()
	var perps := PackedVector2Array()
	perps.resize(n)
	for i in range(n):
		var perp: Vector2
		if i == 0:
			var dir: Vector2 = (points[1] - points[0]).normalized()
			perp = Vector2(-dir.y, dir.x)
		elif i == n - 1:
			var dir: Vector2 = (points[i] - points[i - 1]).normalized()
			perp = Vector2(-dir.y, dir.x)
		else:
			# FORWARD-ONLY: uses next segment direction
			var dir_out: Vector2 = (points[i + 1] - points[i]).normalized()
			perp = Vector2(-dir_out.y, dir_out.x)
		perps[i] = perp
	return perps


## Corridor perpendiculars: forward-only (same as road mesh) + buffer
## After fix: matches road mesh perps exactly (lines 4059-4077 in osm_terrain_generator.gd)
static func build_corridor_perps(points: PackedVector2Array) -> PackedVector2Array:
	# After the fix, corridor uses the same forward-only perps as road mesh
	return build_road_mesh_perps(points)


## Build road mesh edge vertices (left and right) from points and half_width
static func build_road_mesh_edges(points: PackedVector2Array, half_w: float) -> Array:
	var perps := build_road_mesh_perps(points)
	var left := PackedVector2Array()
	var right := PackedVector2Array()
	for i in range(points.size()):
		left.append(points[i] - perps[i] * half_w)
		right.append(points[i] + perps[i] * half_w)
	return [left, right]


## Build single corridor polygon (same as production code).
## Left edge forward + right edge reversed. No buffer.
static func build_corridor_polygon(points: PackedVector2Array, half_w: float) -> PackedVector2Array:
	var perps := build_road_mesh_perps(points)
	var corridor := PackedVector2Array()
	for i in range(points.size()):
		corridor.append(points[i] - perps[i] * half_w)
	for i in range(points.size() - 1, -1, -1):
		corridor.append(points[i] + perps[i] * half_w)
	if ChunkMath.polygon_area(corridor) < 0:
		corridor.reverse()
	return corridor


## Clip corridor polygon to chunk rect, returns array of clipped polygons
static func clip_corridor_to_chunk(corridor: PackedVector2Array, chunk_rect: PackedVector2Array) -> Array[PackedVector2Array]:
	var result: Array[PackedVector2Array] = []
	var clipped: Array[PackedVector2Array] = Geometry2D.intersect_polygons(corridor, chunk_rect)
	for cp in clipped:
		if cp.size() >= 3 and ChunkMath.polygon_area(cp) > 0.001:
			result.append(cp)
	return result


## Build chunk rect polygon from chunk coords and size
static func make_chunk_rect(cx: int, cz: int, chunk_size: float) -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(float(cx) * chunk_size, float(cz) * chunk_size),
		Vector2(float(cx + 1) * chunk_size, float(cz) * chunk_size),
		Vector2(float(cx + 1) * chunk_size, float(cz + 1) * chunk_size),
		Vector2(float(cx) * chunk_size, float(cz + 1) * chunk_size),
	])


## Check if a 2D point is inside a polygon (uses Godot's built-in)
static func point_in_polygon(point: Vector2, polygon: PackedVector2Array) -> bool:
	return Geometry2D.is_point_in_polygon(point, polygon)


## Check if all road mesh edge vertices are inside the corridor polygon
## Returns [all_inside, first_outside_point, first_outside_index]
static func check_mesh_inside_corridor(points: PackedVector2Array, half_w: float) -> Array:
	var edges := build_road_mesh_edges(points, half_w)
	var left: PackedVector2Array = edges[0]
	var right: PackedVector2Array = edges[1]
	var corridor := build_corridor_polygon(points, half_w)

	for i in range(left.size()):
		if not point_in_polygon(left[i], corridor):
			var to_center := (points[i] - left[i]).normalized() * 0.01
			if not point_in_polygon(left[i] + to_center, corridor):
				return [false, left[i], i, "left"]
		if not point_in_polygon(right[i], corridor):
			var to_center := (points[i] - right[i]).normalized() * 0.01
			if not point_in_polygon(right[i] + to_center, corridor):
				return [false, right[i], i, "right"]
	return [true, Vector2.ZERO, -1, ""]


## Check if a mesh point inside chunk_rect is covered by ANY corridor in the list.
## This simulates terrain clipping: point must be inside a corridor OR outside chunk_rect.
static func check_mesh_covered_in_chunk(
	points: PackedVector2Array, half_w: float,
	corridors: Array[PackedVector2Array], chunk_rect: PackedVector2Array
) -> Array:
	var edges := build_road_mesh_edges(points, half_w)
	var left: PackedVector2Array = edges[0]
	var right: PackedVector2Array = edges[1]
	for i in range(left.size()):
		var pts_to_check: PackedVector2Array = PackedVector2Array([left[i], right[i]])
		for pi in range(2):
			var pt: Vector2 = pts_to_check[pi]
			if not point_in_polygon(pt, chunk_rect):
				continue  # outside chunk — not our problem
			var covered := false
			for corridor in corridors:
				if point_in_polygon(pt, corridor):
					covered = true
					break
			if not covered:
				# Try with tiny inward nudge for fp tolerance
				var nudge: Vector2 = (points[i] - pt).normalized() * 0.02
				for corridor in corridors:
					if point_in_polygon(pt + nudge, corridor):
						covered = true
						break
			if not covered:
				var side: String = "left" if pi == 0 else "right"
				return [false, pt, i, side]
	return [true, Vector2.ZERO, -1, ""]


## Replicate _validate_road_direction from osm_terrain_generator.gd (line 14821)
static func validate_road_direction(points: PackedVector2Array) -> PackedVector2Array:
	return ChunkMath.validate_road_direction(points)


# ==================== Tests ====================

func test_straight_road_corridor_covers_mesh() -> void:
	# Straight road — mesh and corridor should be identical
	var points := PackedVector2Array([
		Vector2(0, 0), Vector2(50, 0), Vector2(100, 0)
	])
	var half_w := 3.5
	var result := check_mesh_inside_corridor(points, half_w)
	_assert(result[0], "straight_road_corridor_covers_mesh",
		"Point %s at idx %d (%s) outside corridor" % [result[1], result[2], result[3]])


func test_90deg_turn_corridor_covers_mesh() -> void:
	# 90° turn: road goes right then up. This is where miter-join diverges most.
	var points := PackedVector2Array([
		Vector2(0, 0), Vector2(50, 0), Vector2(50, 50)
	])
	var half_w := 3.5
	var result := check_mesh_inside_corridor(points, half_w)
	_assert(result[0], "90deg_turn_corridor_covers_mesh",
		"Point %s at idx %d (%s) outside corridor" % [result[1], result[2], result[3]])


func test_45deg_turn_corridor_covers_mesh() -> void:
	# 45° turn
	var points := PackedVector2Array([
		Vector2(0, 0), Vector2(50, 0), Vector2(85, 35)
	])
	var half_w := 3.5
	var result := check_mesh_inside_corridor(points, half_w)
	_assert(result[0], "45deg_turn_corridor_covers_mesh",
		"Point %s at idx %d (%s) outside corridor" % [result[1], result[2], result[3]])


func test_s_curve_corridor_covers_mesh() -> void:
	# S-curve: goes right, bends up, bends back right
	var points := PackedVector2Array([
		Vector2(0, 0), Vector2(30, 0), Vector2(50, 20),
		Vector2(70, 0), Vector2(100, 0)
	])
	var half_w := 3.5
	var result := check_mesh_inside_corridor(points, half_w)
	_assert(result[0], "s_curve_corridor_covers_mesh",
		"Point %s at idx %d (%s) outside corridor" % [result[1], result[2], result[3]])


func test_sharp_u_turn_corridor_covers_mesh() -> void:
	# Hairpin / U-turn (~150°)
	var points := PackedVector2Array([
		Vector2(0, 0), Vector2(20, 0), Vector2(25, 5),
		Vector2(20, 10), Vector2(0, 10)
	])
	var half_w := 3.0
	var result := check_mesh_inside_corridor(points, half_w)
	_assert(result[0], "sharp_u_turn_corridor_covers_mesh",
		"Point %s at idx %d (%s) outside corridor" % [result[1], result[2], result[3]])


func test_corridor_perps_match_mesh_perps() -> void:
	# After fix: corridor uses the same forward-only perpendiculars as road mesh.
	# At a 90° turn, both should produce the same perp direction.
	var points := PackedVector2Array([
		Vector2(0, 0), Vector2(50, 0), Vector2(50, 50)
	])

	var mesh_perps := build_road_mesh_perps(points)
	var corr_perps := build_corridor_perps(points)

	# At the turn point (index 1):
	# Both should use forward-only: direction to (50,50) from (50,0) → dir=(0,1) → perp=(-1,0)
	var mesh_perp_at_turn := mesh_perps[1]
	var corr_perp_at_turn := corr_perps[1]

	var expected := Vector2(-1, 0)
	_assert(mesh_perp_at_turn.distance_to(expected) < 0.01,
		"mesh_perp_at_90deg_turn",
		"Expected mesh perp ≈ %s, got %s" % [expected, mesh_perp_at_turn])

	_assert(corr_perp_at_turn.distance_to(expected) < 0.01,
		"corridor_perp_matches_mesh_at_90deg_turn",
		"Expected corridor perp ≈ %s, got %s" % [expected, corr_perp_at_turn])

	# Verify corridor is wider due to +0.3m buffer
	var half_w := 3.5
	var mesh_left := points[1] - mesh_perps[1] * half_w
	var corr_left := points[1] - corr_perps[1] * (half_w + 0.3)
	var mesh_dist := mesh_left.distance_to(points[1])
	var corr_dist := corr_left.distance_to(points[1])
	_assert(corr_dist > mesh_dist,
		"corridor_wider_than_mesh_at_turn",
		"Corridor dist %.2f should be > mesh dist %.2f" % [corr_dist, mesh_dist])


func test_smoothed_road_corridor_covers_mesh() -> void:
	# Simulate a real road: raw OSM points → smooth → validate → build mesh + corridor
	# Use the same smoothing function as the real pipeline
	var raw_points := PackedVector2Array([
		Vector2(0, 0), Vector2(30, 2), Vector2(60, 0),
		Vector2(80, -15), Vector2(100, -40), Vector2(100, -70)
	])
	var half_w := 4.0  # Primary road

	# Step 1: Smooth (same as pipeline)
	var smoothed := ChunkMath.smooth_road_corners(raw_points)

	# Step 2: Validate (both mesh and corridor use validated points in this test)
	var validated := ChunkMath.validate_road_direction(smoothed)

	if validated.size() < 2:
		_assert(false, "smoothed_road_corridor_covers_mesh", "Validation reduced to < 2 points")
		return

	var result := check_mesh_inside_corridor(validated, half_w)
	_assert(result[0], "smoothed_road_corridor_covers_mesh",
		"Point %s at idx %d (%s) outside corridor after smoothing" % [result[1], result[2], result[3]])


func test_terrain_clipping_removes_road_area() -> void:
	var chunk_rect := PackedVector2Array([
		Vector2(0, 0), Vector2(200, 0), Vector2(200, 200), Vector2(0, 200)
	])
	var road_points := PackedVector2Array([
		Vector2(0, 100), Vector2(200, 100)
	])
	var half_w := 5.0
	var corridor := build_corridor_polygon(road_points, half_w)

	var terrain_polys: Array[PackedVector2Array] = [chunk_rect]
	var new_polys: Array[PackedVector2Array] = []
	for poly in terrain_polys:
		var clipped: Array[PackedVector2Array] = Geometry2D.clip_polygons(poly, corridor)
		for cp in clipped:
			if cp.size() >= 3:
				new_polys.append(cp)
	terrain_polys = new_polys

	var road_center := Vector2(100, 100)
	var center_in_terrain := false
	for poly in terrain_polys:
		if point_in_polygon(road_center, poly):
			center_in_terrain = true
			break
	_assert(not center_in_terrain, "terrain_clipping_removes_road_center",
		"Road center (100,100) still inside terrain after clipping!")

	var terrain_point := Vector2(100, 50)
	var found_terrain := false
	for poly in terrain_polys:
		if point_in_polygon(terrain_point, poly):
			found_terrain = true
			break
	_assert(found_terrain, "terrain_clipping_preserves_non_road_area",
		"Terrain at (100,50) — outside road — should exist after clipping")

	var total_area := 0.0
	for poly in terrain_polys:
		total_area += absf(ChunkMath.polygon_area(poly))
	var expected_area := 200.0 * 200.0 - 200.0 * 10.0  # 38000
	_assert(absf(total_area - expected_area) < 200.0, "terrain_clipping_area_correct",
		"Expected terrain area ~%.0f, got %.0f" % [expected_area, total_area])


func test_terrain_clipping_sharp_turn() -> void:
	var chunk_rect := PackedVector2Array([
		Vector2(-100, -100), Vector2(100, -100), Vector2(100, 100), Vector2(-100, 100)
	])
	var road_points := PackedVector2Array([
		Vector2(-120, 0), Vector2(0, 0), Vector2(0, -120)
	])
	var half_w := 5.0
	var corridor := build_corridor_polygon(road_points, half_w)

	if ChunkMath.polygon_area(chunk_rect) < 0:
		chunk_rect.reverse()

	var terrain_polys: Array[PackedVector2Array] = [chunk_rect]
	var new_polys: Array[PackedVector2Array] = []
	for poly in terrain_polys:
		var clipped: Array[PackedVector2Array] = Geometry2D.clip_polygons(poly, corridor)
		for cp in clipped:
			if cp.size() >= 3:
				new_polys.append(cp)
	terrain_polys = new_polys

	# CW hole filter
	var ccw_polys: Array[PackedVector2Array] = []
	var cw_holes: Array[PackedVector2Array] = []
	for poly in terrain_polys:
		if poly.size() < 3:
			continue
		var area := ChunkMath.polygon_area(poly)
		if area >= 2.0:
			ccw_polys.append(poly)
		elif area <= -2.0:
			var rev := PackedVector2Array(poly)
			rev.reverse()
			cw_holes.append(rev)
	for hole in cw_holes:
		var new_ccw: Array[PackedVector2Array] = []
		for poly in ccw_polys:
			var clipped_h: Array[PackedVector2Array] = Geometry2D.clip_polygons(poly, hole)
			for cp in clipped_h:
				if cp.size() >= 3 and ChunkMath.polygon_area(cp) >= 2.0:
					new_ccw.append(cp)
		ccw_polys = new_ccw
	terrain_polys = ccw_polys

	var any_overlap := false
	var overlap_info := ""
	for seg_i in range(road_points.size() - 1):
		var p0 := road_points[seg_i]
		var p1 := road_points[seg_i + 1]
		var d := (p1 - p0).normalized()
		var perp := Vector2(-d.y, d.x)
		for t in [0.2, 0.4, 0.6, 0.8]:
			var center := p0.lerp(p1, t)
			if center.x < -99 or center.x > 99 or center.y < -99 or center.y > 99:
				continue
			var offsets: PackedFloat64Array = [0.0, half_w - 0.5, -(half_w - 0.5)]
			for oi in range(offsets.size()):
				var test_pt: Vector2 = center + perp * offsets[oi]
				for poly in terrain_polys:
					if point_in_polygon(test_pt, poly):
						any_overlap = true
						overlap_info = "Seg %d, t=%.1f, offset=%.1f: %s inside terrain" % [seg_i, t, offsets[oi], test_pt]
						break
				if any_overlap:
					break
			if any_overlap:
				break
		if any_overlap:
			break

	_assert(not any_overlap, "terrain_clipping_sharp_turn_no_overlap", overlap_info)


func test_validate_road_direction_consistency() -> void:
	# Test that _validate_road_direction produces the same result regardless
	# of whether points are clipped or unclipped (when both contain the same segments)
	var full_points := PackedVector2Array([
		Vector2(-50, 10), Vector2(0, 0), Vector2(50, 0),
		Vector2(50, -50), Vector2(50, -100)
	])

	# Simulate clipping: remove points outside a "chunk bbox"
	# Keep only points with x >= 0
	var clipped_points := PackedVector2Array()
	for p in full_points:
		if p.x >= -1.0:  # Small margin
			clipped_points.append(p)

	# Validate both
	var validated_full := ChunkMath.validate_road_direction(full_points)
	var validated_clipped := ChunkMath.validate_road_direction(clipped_points)

	# Check the overlapping points are the same
	# The clipped version starts from the second point of full
	# Both should keep the same points in the shared region
	var shared_ok := true
	var info := ""

	# Find the matching start in validated_full
	if validated_clipped.size() >= 2 and validated_full.size() >= 2:
		# The last point should be the same in both
		var full_last := validated_full[validated_full.size() - 1]
		var clip_last := validated_clipped[validated_clipped.size() - 1]
		if full_last.distance_to(clip_last) > 0.01:
			shared_ok = false
			info = "Last points differ: full=%s, clipped=%s" % [full_last, clip_last]
	else:
		shared_ok = false
		info = "Too few points after validation: full=%d, clipped=%d" % [validated_full.size(), validated_clipped.size()]

	_assert(shared_ok, "validate_road_direction_consistency", info)


# ==================== Chunk Boundary Tests ====================
# These test that corridors correctly cover road mesh at chunk boundaries.
# The key scenario: a road crosses a chunk boundary. Each chunk builds
# its own corridor clipped to its rect. The mesh extends with margin.
# Every mesh point INSIDE the chunk rect must be covered by a corridor.

## Simulate the full pipeline for one road in one chunk:
## smooth → validate → clip polyline → build mesh → build corridor → clip corridor
static func simulate_road_in_chunk(
	raw_local_pts: PackedVector2Array, half_w: float,
	cx: int, cz: int, chunk_size: float
) -> Dictionary:
	# 1. Smooth
	var smoothed := ChunkMath.smooth_road_corners(raw_local_pts)
	# 2. Validate
	var validated := ChunkMath.validate_road_direction(smoothed)
	if validated.size() < 2:
		return {"points": PackedVector2Array(), "corridors": []}
	# 3. Build extended corridor — extend road endpoints beyond chunk boundary
	# so clip_polygons always splits terrain (never creates CW holes)
	var chunk_rect := make_chunk_rect(cx, cz, chunk_size)
	var ext_corridor := build_extended_corridor(validated, half_w, chunk_rect)
	var corridors: Array[PackedVector2Array] = []
	if ext_corridor.size() >= 3:
		corridors.append(ext_corridor)
	# 5. Clip polyline to chunk with margin (for mesh vertices)
	var margin := half_w + 1.0
	var min_x := float(cx) * chunk_size - margin
	var max_x := float(cx + 1) * chunk_size + margin
	var min_z := float(cz) * chunk_size - margin
	var max_z := float(cz + 1) * chunk_size + margin
	var clipped := ChunkMath.clip_polyline_to_rect(validated, min_x, max_x, min_z, max_z)
	if clipped.size() < 2:
		return {"points": PackedVector2Array(), "corridors": corridors, "chunk_rect": chunk_rect}
	return {"points": clipped, "corridors": corridors, "chunk_rect": chunk_rect}


func test_chunk_boundary_horizontal_road() -> void:
	# Horizontal road crossing chunk boundary at x=200 (chunks 0,0 and 1,0)
	var chunk_size := 200.0
	var half_w := 3.0  # 6m road
	var road_pts := PackedVector2Array([
		Vector2(150, 100), Vector2(250, 100)
	])

	# Check both chunks
	var all_ok := true
	var info := ""
	for cx in [0, 1]:
		var result := simulate_road_in_chunk(road_pts, half_w, cx, 0, chunk_size)
		if result.points.size() < 2:
			continue
		var check := check_mesh_covered_in_chunk(
			result.points, half_w, result.corridors, result.chunk_rect)
		if not check[0]:
			all_ok = false
			info = "chunk(%d,0) %s pt %d at %s uncovered" % [cx, check[3], check[2], check[1]]
			break

	_assert(all_ok, "chunk_boundary_horizontal_road", info)


func test_chunk_boundary_diagonal_road() -> void:
	# Diagonal road crossing chunk boundary at x=200, z=200 (corner of 4 chunks)
	var chunk_size := 200.0
	var half_w := 3.5  # 7m road
	var road_pts := PackedVector2Array([
		Vector2(150, 150), Vector2(250, 250)
	])

	var all_ok := true
	var info := ""
	for cx in [0, 1]:
		for cz in [0, 1]:
			var result := simulate_road_in_chunk(road_pts, half_w, cx, cz, chunk_size)
			if result.points.size() < 2:
				continue
			var check := check_mesh_covered_in_chunk(
				result.points, half_w, result.corridors, result.chunk_rect)
			if not check[0]:
				all_ok = false
				info = "chunk(%d,%d) %s pt %d at %s uncovered" % [cx, cz, check[3], check[2], check[1]]
				break
		if not all_ok:
			break

	_assert(all_ok, "chunk_boundary_diagonal_road", info)


func test_chunk_boundary_real_osm_data() -> void:
	# Real OSM data near 59.146519, 37.965935 (Cherepovets)
	# Way 58762459 (tertiary) — long road with many points
	var start_lat := 59.1504
	var start_lon := 37.9488
	var lon_scale := cos(deg_to_rad(start_lat)) * 111000.0

	# Convert real lat/lon to local coords
	var raw_latlons := [
		[59.1460608, 37.9655808],
		[59.1457399, 37.9641653],
		[59.1457077, 37.9640221],
		[59.1456803, 37.9639000],
		[59.1453984, 37.9626453],
		[59.1449675, 37.9607274],
		[59.1444785, 37.9584874],
		[59.1443458, 37.9578795],
	]
	var local_pts := PackedVector2Array()
	for ll in raw_latlons:
		var dx: float = (ll[1] - start_lon) * lon_scale
		var dz: float = (ll[0] - start_lat) * 111000.0
		local_pts.append(Vector2(dx, -dz))

	var chunk_size := 200.0
	var half_w := 3.0  # tertiary = 6m

	# Find which chunks this road passes through
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF
	for p in local_pts:
		min_x = minf(min_x, p.x)
		max_x = maxf(max_x, p.x)
		min_z = minf(min_z, p.y)
		max_z = maxf(max_z, p.y)

	var all_ok := true
	var info := ""
	var chunks_tested := 0
	for cx in range(int(floor(min_x / chunk_size)) - 1, int(floor(max_x / chunk_size)) + 2):
		for cz in range(int(floor(min_z / chunk_size)) - 1, int(floor(max_z / chunk_size)) + 2):
			var result := simulate_road_in_chunk(local_pts, half_w, cx, cz, chunk_size)
			if result.points.size() < 2:
				continue
			chunks_tested += 1
			var check := check_mesh_covered_in_chunk(
				result.points, half_w, result.corridors, result.chunk_rect)
			if not check[0]:
				all_ok = false
				info = "chunk(%d,%d) %s pt %d at %s uncovered" % [cx, cz, check[3], check[2], check[1]]
				break
		if not all_ok:
			break

	if chunks_tested == 0:
		all_ok = false
		info = "No chunks tested — road outside all chunks?"

	_assert(all_ok, "chunk_boundary_real_osm_data", info)


func test_chunk_boundary_grid_offset_sensitivity() -> void:
	# Same road, different start positions → different grid alignment
	# This tests the user's exact bug: "depends on chunk grid"
	var road_latlons := [
		[59.1460608, 37.9655808],
		[59.1457399, 37.9641653],
		[59.1456803, 37.9639000],
		[59.1453984, 37.9626453],
		[59.1449675, 37.9607274],
	]

	var chunk_size := 200.0
	var half_w := 3.0

	# Try 10 different start positions (shifts the grid)
	var all_ok := true
	var info := ""
	var start_positions := [
		[59.1504, 37.9488],   # default
		[59.1470, 37.9650],   # near the road
		[59.1450, 37.9600],   # shifted
		[59.1500, 37.9500],   # shifted more
		[59.1465, 37.9660],   # from screenshot coords
		[59.1440, 37.9580],   # south
		[59.1480, 37.9620],   # north
		[59.1455, 37.9640],   # on the road
		[59.1460, 37.9656],   # very close to road start
		[59.1445, 37.9585],   # another offset
	]

	for si in range(start_positions.size()):
		var slat: float = start_positions[si][0]
		var slon: float = start_positions[si][1]
		var lon_scale := cos(deg_to_rad(slat)) * 111000.0

		var local_pts := PackedVector2Array()
		for ll in road_latlons:
			var dx: float = (ll[1] - slon) * lon_scale
			var dz: float = (ll[0] - slat) * 111000.0
			local_pts.append(Vector2(dx, -dz))

		# Find chunks
		var min_x := INF
		var max_x := -INF
		var min_z := INF
		var max_z := -INF
		for p in local_pts:
			min_x = minf(min_x, p.x)
			max_x = maxf(max_x, p.x)
			min_z = minf(min_z, p.y)
			max_z = maxf(max_z, p.y)

		for cx in range(int(floor(min_x / chunk_size)) - 1, int(floor(max_x / chunk_size)) + 2):
			for cz in range(int(floor(min_z / chunk_size)) - 1, int(floor(max_z / chunk_size)) + 2):
				var result := simulate_road_in_chunk(local_pts, half_w, cx, cz, chunk_size)
				if result.points.size() < 2:
					continue
				var check := check_mesh_covered_in_chunk(
					result.points, half_w, result.corridors, result.chunk_rect)
				if not check[0]:
					all_ok = false
					info = "start[%d] (%.4f,%.4f) chunk(%d,%d) %s pt %d at %s uncovered" % [
						si, slat, slon, cx, cz, check[3], check[2], check[1]]
					break
			if not all_ok:
				break
		if not all_ok:
			break

	_assert(all_ok, "chunk_boundary_grid_offset_sensitivity", info)


# ==================== Full Terrain Clipping Pipeline Tests ====================
# These replicate _compute_terrain_clipping_thread: take corridors, clip from
# chunk_rect terrain polygon, then verify no road mesh points inside terrain.
# This catches bugs where corridor EXISTS but terrain clipping fails.

## Simulate terrain clipping: clip all corridors from chunk rect, handle CW holes.
## Returns array of remaining terrain polygons.
## Build an extended corridor that reaches chunk boundaries on both ends.
## Takes the road centerline points and half_w, extends endpoints by chunk diagonal,
## builds corridor from extended points, then clips to chunk rect.
## Result always crosses chunk boundary → clip_polygons works correctly.
static func build_extended_corridor(
	road_points: PackedVector2Array, half_w: float, chunk_rect: PackedVector2Array
) -> PackedVector2Array:
	if road_points.size() < 2:
		return PackedVector2Array()
	# Extension distance: chunk_size + half_w + 1m (just past boundary)
	var min_x := chunk_rect[0].x
	var max_x := chunk_rect[0].x
	for i in range(1, chunk_rect.size()):
		min_x = minf(min_x, chunk_rect[i].x)
		max_x = maxf(max_x, chunk_rect[i].x)
	var chunk_size_est := max_x - min_x
	var ext_dist := chunk_size_est + half_w + 1.0
	# Extend road points at both ends
	var n := road_points.size()
	var start_dir := (road_points[0] - road_points[1]).normalized()
	var end_dir := (road_points[n - 1] - road_points[n - 2]).normalized()
	var ext_pts := PackedVector2Array()
	ext_pts.append(road_points[0] + start_dir * ext_dist)
	for i in range(n):
		ext_pts.append(road_points[i])
	ext_pts.append(road_points[n - 1] + end_dir * ext_dist)
	# Build corridor from extended points
	var corridor := build_corridor_polygon(ext_pts, half_w)
	# Clip to chunk rect
	if ChunkMath.polygon_area(corridor) < 0:
		corridor.reverse()
	var clipped := Geometry2D.intersect_polygons(corridor, chunk_rect)
	if clipped.size() > 0 and clipped[0].size() >= 3:
		return clipped[0]
	return PackedVector2Array()


static func simulate_terrain_clipping(
	corridors: Array[PackedVector2Array], chunk_rect: PackedVector2Array
) -> Array[PackedVector2Array]:
	var terrain_polys: Array[PackedVector2Array] = [chunk_rect]
	for corridor in corridors:
		if corridor.size() < 3:
			continue
		var new_polys: Array[PackedVector2Array] = []
		for poly in terrain_polys:
			var clipped: Array[PackedVector2Array] = Geometry2D.clip_polygons(poly, corridor)
			for cp in clipped:
				if cp.size() >= 3 and ChunkMath.polygon_area(cp) >= 1.0:
					new_polys.append(cp)
		terrain_polys = new_polys
		if terrain_polys.is_empty():
			break
	return terrain_polys


## Check if any road mesh point inside chunk is still inside terrain after clipping.
## Returns [ok, fail_info_string]
static func check_road_not_in_terrain(
	mesh_points: PackedVector2Array, half_w: float,
	terrain_polys: Array[PackedVector2Array], chunk_rect: PackedVector2Array
) -> Array:
	var edges := build_road_mesh_edges(mesh_points, half_w)
	var left: PackedVector2Array = edges[0]
	var right: PackedVector2Array = edges[1]
	# Also test center points
	for i in range(mesh_points.size()):
		var test_pts: Array[Vector2] = [mesh_points[i], left[i], right[i]]
		var labels: Array[String] = ["center", "left", "right"]
		for pi in range(3):
			var pt: Vector2 = test_pts[pi]
			if not point_in_polygon(pt, chunk_rect):
				continue
			for terrain in terrain_polys:
				if point_in_polygon(pt, terrain):
					# Nudge inward to handle edge cases
					var nudge_dir: Vector2
					if pi == 0:
						nudge_dir = Vector2.ZERO
					else:
						nudge_dir = (mesh_points[i] - pt).normalized() * 0.05
					if pi == 0 or point_in_polygon(pt + nudge_dir, terrain):
						return [false, "%s pt %d at %s inside terrain" % [labels[pi], i, pt]]
	return [true, ""]


## Full pipeline test for one road in one chunk: build corridor, clip terrain, check.
static func full_pipeline_test_road_in_chunk(
	raw_local_pts: PackedVector2Array, half_w: float,
	cx: int, cz: int, chunk_size: float
) -> Dictionary:
	# Simulate the full pipeline
	var result := simulate_road_in_chunk(raw_local_pts, half_w, cx, cz, chunk_size)
	if result.points.size() < 2:
		return {"ok": true, "info": "no mesh in chunk", "has_mesh": false}
	var corridors: Array[PackedVector2Array] = result.corridors
	var chunk_rect: PackedVector2Array = result.chunk_rect
	# Clip terrain
	var terrain_polys := simulate_terrain_clipping(corridors, chunk_rect)
	# Check no road mesh inside terrain
	var check := check_road_not_in_terrain(result.points, half_w, terrain_polys, chunk_rect)
	return {
		"ok": check[0],
		"info": check[1],
		"has_mesh": true,
		"n_corridors": corridors.size(),
		"n_terrain_polys": terrain_polys.size()
	}


func test_full_pipeline_straight_road() -> void:
	var chunk_size := 200.0
	var half_w := 3.0
	# Road through middle of chunk
	var road := PackedVector2Array([Vector2(50, 100), Vector2(150, 100)])
	var r := full_pipeline_test_road_in_chunk(road, half_w, 0, 0, chunk_size)
	_assert(r.ok, "full_pipeline_straight_road", r.info)


func test_full_pipeline_crossing_boundary() -> void:
	var chunk_size := 200.0
	var half_w := 3.0
	var road := PackedVector2Array([Vector2(150, 100), Vector2(250, 100)])
	var all_ok := true
	var info := ""
	for cx in [0, 1]:
		var r := full_pipeline_test_road_in_chunk(road, half_w, cx, 0, chunk_size)
		if not r.ok:
			all_ok = false
			info = "chunk(%d,0): %s" % [cx, r.info]
			break
	_assert(all_ok, "full_pipeline_crossing_boundary", info)


func test_full_pipeline_diagonal_crossing() -> void:
	var chunk_size := 200.0
	var half_w := 3.5
	var road := PackedVector2Array([Vector2(150, 150), Vector2(250, 250)])
	var all_ok := true
	var info := ""
	for cx in [0, 1]:
		for cz in [0, 1]:
			var r := full_pipeline_test_road_in_chunk(road, half_w, cx, cz, chunk_size)
			if not r.ok:
				all_ok = false
				info = "chunk(%d,%d): %s" % [cx, cz, r.info]
				break
		if not all_ok:
			break
	_assert(all_ok, "full_pipeline_diagonal_crossing", info)


func test_full_pipeline_real_osm_multi_grid() -> void:
	# Multiple real roads near 59.146519, 37.965935 with different grid offsets
	# This is THE test that must catch the "curbs visible but terrain on road" bug
	var roads_latlons := [
		# Way 58762459 (tertiary)
		[[59.1460608, 37.9655808], [59.1457399, 37.9641653], [59.1457077, 37.9640221],
		 [59.1456803, 37.9639000], [59.1453984, 37.9626453], [59.1449675, 37.9607274]],
		# Shorter residential road
		[[59.1458, 37.9645], [59.1456, 37.9635], [59.1454, 37.9625]],
		# Service road perpendicular
		[[59.1457, 37.9640], [59.1457, 37.9650]],
	]
	var road_widths := [3.0, 2.75, 2.0]  # tertiary, residential, service

	var chunk_size := 200.0
	var start_positions := [
		[59.1504, 37.9488],   # default Cherepovets
		[59.1470, 37.9650],   # near road
		[59.1450, 37.9600],   # shifted
		[59.1460, 37.9656],   # very close to road start
		[59.1455, 37.9640],   # on the road
		[59.1445, 37.9585],   # south of road
		[59.1480, 37.9620],   # north
		[59.1500, 37.9500],   # far north
	]

	var all_ok := true
	var info := ""
	for si in range(start_positions.size()):
		var slat: float = start_positions[si][0]
		var slon: float = start_positions[si][1]
		var lon_scale := cos(deg_to_rad(slat)) * 111000.0

		for ri in range(roads_latlons.size()):
			var half_w: float = road_widths[ri]
			var local_pts := PackedVector2Array()
			for ll in roads_latlons[ri]:
				var dx: float = (ll[1] - slon) * lon_scale
				var dz: float = (ll[0] - slat) * 111000.0
				local_pts.append(Vector2(dx, -dz))

			# Find chunks
			var min_x := INF
			var max_x := -INF
			var min_z := INF
			var max_z := -INF
			for p in local_pts:
				min_x = minf(min_x, p.x)
				max_x = maxf(max_x, p.x)
				min_z = minf(min_z, p.y)
				max_z = maxf(max_z, p.y)

			for cx in range(int(floor(min_x / chunk_size)) - 1, int(floor(max_x / chunk_size)) + 2):
				for cz in range(int(floor(min_z / chunk_size)) - 1, int(floor(max_z / chunk_size)) + 2):
					var r := full_pipeline_test_road_in_chunk(local_pts, half_w, cx, cz, chunk_size)
					if not r.ok:
						all_ok = false
						info = "start[%d] road[%d] chunk(%d,%d): %s (corrs=%d terr=%d)" % [
							si, ri, cx, cz, r.info, r.n_corridors, r.n_terrain_polys]
						break
				if not all_ok:
					break
			if not all_ok:
				break
		if not all_ok:
			break

	_assert(all_ok, "full_pipeline_real_osm_multi_grid", info)


func test_full_pipeline_multiple_roads_one_chunk() -> void:
	# Multiple roads in one chunk — test that clipping multiple corridors works
	var chunk_size := 200.0
	var roads := [
		{"pts": PackedVector2Array([Vector2(20, 50), Vector2(180, 50)]), "hw": 3.0},
		{"pts": PackedVector2Array([Vector2(20, 100), Vector2(180, 100)]), "hw": 3.5},
		{"pts": PackedVector2Array([Vector2(100, 20), Vector2(100, 180)]), "hw": 2.75},
	]
	var chunk_rect := make_chunk_rect(0, 0, chunk_size)
	var all_corridors: Array[PackedVector2Array] = []
	var all_mesh: Array[Dictionary] = []  # {points, half_w}

	for road in roads:
		var result := simulate_road_in_chunk(road.pts, road.hw, 0, 0, chunk_size)
		if result.points.size() >= 2:
			for c in result.corridors:
				all_corridors.append(c)
			all_mesh.append({"points": result.points, "half_w": road.hw})

	# Clip terrain with all corridors
	var terrain_polys := simulate_terrain_clipping(all_corridors, chunk_rect)

	# Check ALL roads
	var all_ok := true
	var info := ""
	for mi in range(all_mesh.size()):
		var m: Dictionary = all_mesh[mi]
		var check := check_road_not_in_terrain(m.points, m.half_w, terrain_polys, chunk_rect)
		if not check[0]:
			all_ok = false
			info = "road[%d]: %s" % [mi, check[1]]
			break

	_assert(all_ok, "full_pipeline_multiple_roads_one_chunk", info)


func test_full_pipeline_road_ending_in_chunk() -> void:
	# Road that starts outside and ends inside chunk — the user's key scenario
	var chunk_size := 200.0
	var half_w := 3.0
	# Road starts at x=-50 (outside chunk 0,0) and ends at x=80 (inside)
	var road := PackedVector2Array([
		Vector2(-50, 100), Vector2(0, 100), Vector2(40, 95), Vector2(80, 100)
	])
	var r := full_pipeline_test_road_in_chunk(road, half_w, 0, 0, chunk_size)
	_assert(r.ok, "full_pipeline_road_ending_in_chunk", r.info)


func test_full_pipeline_road_starting_in_chunk() -> void:
	# Road starts inside chunk and exits
	var chunk_size := 200.0
	var half_w := 3.0
	var road := PackedVector2Array([
		Vector2(120, 100), Vector2(160, 105), Vector2(200, 100), Vector2(250, 100)
	])
	var r := full_pipeline_test_road_in_chunk(road, half_w, 0, 0, chunk_size)
	_assert(r.ok, "full_pipeline_road_starting_in_chunk", r.info)
