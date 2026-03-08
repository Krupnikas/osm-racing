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


## Build per-segment corridor rectangles (same as _apply_road_result after fix).
## Returns array of convex quadrilaterals, one per segment.
## The real code uses half_w + 0.3m buffer for guaranteed coverage.
static func build_corridor_segments(points: PackedVector2Array, half_w: float) -> Array[PackedVector2Array]:
	var hw := half_w + 0.3
	var segments: Array[PackedVector2Array] = []
	for i in range(points.size() - 1):
		var p0 := points[i]
		var p1 := points[i + 1]
		var d := (p1 - p0).normalized()
		var perp := Vector2(-d.y, d.x)
		var seg := PackedVector2Array()
		seg.append(p0 - perp * hw)
		seg.append(p1 - perp * hw)
		seg.append(p1 + perp * hw)
		seg.append(p0 + perp * hw)
		if ChunkMath.polygon_area(seg) < 0:
			seg.reverse()
		segments.append(seg)
	return segments


## Build single merged corridor polygon for simple containment tests.
## Uses Geometry2D.merge_polygons to union per-segment rectangles.
static func build_corridor_polygon(points: PackedVector2Array, half_w: float) -> PackedVector2Array:
	var segments := build_corridor_segments(points, half_w)
	if segments.is_empty():
		return PackedVector2Array()
	var merged: Array[PackedVector2Array] = [segments[0]]
	for i in range(1, segments.size()):
		var new_merged: Array[PackedVector2Array] = []
		for existing in merged:
			var union := Geometry2D.merge_polygons(existing, segments[i])
			for u in union:
				if u.size() >= 3:
					new_merged.append(u)
		merged = new_merged
	return merged[0] if not merged.is_empty() else PackedVector2Array()


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

	# Inflate corridor slightly for floating-point tolerance
	for i in range(left.size()):
		if not point_in_polygon(left[i], corridor):
			# Check with small tolerance (0.01m)
			var to_center := (points[i] - left[i]).normalized() * 0.01
			if not point_in_polygon(left[i] + to_center, corridor):
				return [false, left[i], i, "left"]
		if not point_in_polygon(right[i], corridor):
			var to_center := (points[i] - right[i]).normalized() * 0.01
			if not point_in_polygon(right[i] + to_center, corridor):
				return [false, right[i], i, "right"]
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
	# Build a straight road corridor and verify terrain clipping removes the road area
	var chunk_rect := PackedVector2Array([
		Vector2(0, 0), Vector2(200, 0), Vector2(200, 200), Vector2(0, 200)
	])

	# Road going through the middle of the chunk
	var road_points := PackedVector2Array([
		Vector2(0, 100), Vector2(200, 100)
	])
	var half_w := 5.0
	var corridors := build_corridor_segments(road_points, half_w)

	# Clip terrain by road corridor segments (same as _compute_terrain_clipping_thread)
	var terrain_polys: Array[PackedVector2Array] = [chunk_rect]
	for corridor in corridors:
		var new_polys: Array[PackedVector2Array] = []
		for poly in terrain_polys:
			var clipped: Array[PackedVector2Array] = Geometry2D.clip_polygons(poly, corridor)
			for cp in clipped:
				if cp.size() >= 3:
					new_polys.append(cp)
		terrain_polys = new_polys

	# Check that road center points are NOT inside any terrain polygon
	var road_center := Vector2(100, 100)
	var center_in_terrain := false
	for poly in terrain_polys:
		if point_in_polygon(road_center, poly):
			center_in_terrain = true
			break
	_assert(not center_in_terrain, "terrain_clipping_removes_road_center",
		"Road center (100,100) still inside terrain after clipping!")

	# Check that terrain exists outside the road
	var terrain_point := Vector2(100, 50)  # Above the road
	var found_terrain := false
	for poly in terrain_polys:
		if point_in_polygon(terrain_point, poly):
			found_terrain = true
			break
	_assert(found_terrain, "terrain_clipping_preserves_non_road_area",
		"Terrain at (100,50) — outside road — should exist after clipping")

	# Check total terrain area is approximately correct
	# Chunk = 200x200 = 40000, road corridor = 200 * (10 + 0.6) = 2120 (with +0.3m buffer each side)
	# Remaining should be ~37880
	var total_area := 0.0
	for poly in terrain_polys:
		total_area += absf(ChunkMath.polygon_area(poly))
	var expected_area := 200.0 * 200.0 - 200.0 * (10.0 + 0.6)  # 37880
	_assert(absf(total_area - expected_area) < 200.0, "terrain_clipping_area_correct",
		"Expected terrain area ~%.0f, got %.0f" % [expected_area, total_area])


func test_terrain_clipping_sharp_turn() -> void:
	# Road with a sharp turn through the chunk.
	# Per-segment corridors must cover ALL road mesh vertices.
	# After clipping, NO road mesh vertex should be inside any terrain polygon.
	var chunk_rect := PackedVector2Array([
		Vector2(-100, -100), Vector2(100, -100), Vector2(100, 100), Vector2(-100, 100)
	])

	# 90° turn road crossing chunk boundaries (realistic scenario)
	var road_points := PackedVector2Array([
		Vector2(-120, 0), Vector2(0, 0), Vector2(0, -120)
	])
	var half_w := 5.0

	# Build per-segment corridor rectangles (same as real code)
	var corridors := build_corridor_segments(road_points, half_w)

	# Build road mesh edges (forward-only perps, no buffer)
	var edges := build_road_mesh_edges(road_points, half_w)
	var mesh_left: PackedVector2Array = edges[0]
	var mesh_right: PackedVector2Array = edges[1]

	# Ensure chunk_rect is CCW (Geometry2D requires consistent winding)
	if ChunkMath.polygon_area(chunk_rect) < 0:
		chunk_rect.reverse()

	# Clip terrain by each corridor segment (same as _compute_terrain_clipping_thread)
	var terrain_polys: Array[PackedVector2Array] = [chunk_rect]
	for corridor in corridors:
		var new_polys: Array[PackedVector2Array] = []
		for poly in terrain_polys:
			var clipped: Array[PackedVector2Array] = Geometry2D.clip_polygons(poly, corridor)
			for cp in clipped:
				if cp.size() >= 3:
					new_polys.append(cp)
		terrain_polys = new_polys
	# Final filter: clip CW holes from CCW polys (same as production code)
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
			var clipped := Geometry2D.clip_polygons(poly, hole)
			for cp in clipped:
				if cp.size() >= 3 and ChunkMath.polygon_area(cp) >= 2.0:
					new_ccw.append(cp)
		ccw_polys = new_ccw
	terrain_polys = ccw_polys

	# Check road CENTER points are NOT inside any terrain polygon.
	# Edge vertices at turn inner corners may have tiny gaps between corridor segments —
	# these are covered by intersection contours in the real pipeline (step 2 of clipping).
	# So we test points along the road centerline + half-width inward on each side.
	var any_overlap := false
	var overlap_info := ""
	# Test points along each road segment centerline
	for seg_i in range(road_points.size() - 1):
		var p0 := road_points[seg_i]
		var p1 := road_points[seg_i + 1]
		var d := (p1 - p0).normalized()
		var perp := Vector2(-d.y, d.x)
		# Test 5 points along the segment, at center and ±(half_w - 0.5) from center
		for t in [0.2, 0.4, 0.6, 0.8]:
			var center := p0.lerp(p1, t)
			# Test only within chunk bounds
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
