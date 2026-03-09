extends Node
class_name TestRoadTerrainClipping

const ChunkTerrainScript = preload("res://osm/chunk_terrain.gd")

## Synthetic tests for the road mesh → terrain corridor → terrain clipping pipeline.
## Verifies that the terrain corridor fully covers the road mesh, so no terrain
## renders on top of roads.
##
## Run via test_runner.tscn or manually instantiate and call run_all_tests().

var tests_passed := 0
var tests_failed := 0
var test_results := []

class ChunkMath:
	static func polygon_area(poly: PackedVector2Array) -> float:
		var area := 0.0
		var n := poly.size()
		for i in range(n):
			var j := (i + 1) % n
			area += poly[i].x * poly[j].y
			area -= poly[j].x * poly[i].y
		return area * 0.5

	static func validate_road_direction(points: PackedVector2Array) -> PackedVector2Array:
		if points.size() < 3:
			return points
		var result := PackedVector2Array()
		result.append(points[0])
		var prev_dir: Vector2 = (points[1] - points[0]).normalized()
		for i in range(1, points.size() - 1):
			var current_dir: Vector2 = (points[i + 1] - points[i]).normalized()
			if prev_dir.dot(current_dir) < 0.26:
				continue
			result.append(points[i])
			prev_dir = current_dir
		result.append(points[points.size() - 1])
		return result

	static func smooth_road_corners(raw_points: PackedVector2Array) -> PackedVector2Array:
		return _remove_polyline_loops(_smooth_points_adaptive(raw_points, 1.0))

	static func clip_polyline_to_rect(points: PackedVector2Array, min_x: float, max_x: float, min_z: float, max_z: float) -> PackedVector2Array:
		if points.size() < 2:
			return points
		var result := PackedVector2Array()
		for i in range(points.size() - 1):
			var segment := _clip_segment_to_rect_segment(points[i], points[i + 1], min_x, max_x, min_z, max_z)
			if segment.size() < 2:
				continue
			for pt in segment:
				if result.is_empty() or result[result.size() - 1].distance_to(pt) > 0.01:
					result.append(pt)
		return result

	static func _clip_segment_to_rect_segment(a: Vector2, b: Vector2, min_x: float, max_x: float, min_z: float, max_z: float) -> PackedVector2Array:
		var dx := b.x - a.x
		var dy := b.y - a.y
		var t0 := 0.0
		var t1 := 1.0

		var clip_test := func(p: float, q: float) -> bool:
			if absf(p) < 0.000001:
				return q >= 0.0
			var r := q / p
			if p < 0.0:
				if r > t1:
					return false
				if r > t0:
					t0 = r
			else:
				if r < t0:
					return false
				if r < t1:
					t1 = r
			return true

		if not clip_test.call(-dx, a.x - min_x):
			return PackedVector2Array()
		if not clip_test.call(dx, max_x - a.x):
			return PackedVector2Array()
		if not clip_test.call(-dy, a.y - min_z):
			return PackedVector2Array()
		if not clip_test.call(dy, max_z - a.y):
			return PackedVector2Array()
		if t1 < t0:
			return PackedVector2Array()

		return PackedVector2Array([
			Vector2(a.x + dx * t0, a.y + dy * t0),
			Vector2(a.x + dx * t1, a.y + dy * t1),
		])

	static func _catmull_rom(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, t: float) -> Vector2:
		var t2 := t * t
		var t3 := t2 * t
		return (p1 * 2.0 + (-p0 + p2) * t + (p0 * 2.0 - p1 * 5.0 + p2 * 4.0 - p3) * t2 + (-p0 + p1 * 3.0 - p2 * 3.0 + p3) * t3) * 0.5

	static func _smooth_points_adaptive(raw_points: PackedVector2Array, min_dist: float) -> PackedVector2Array:
		if raw_points.size() < 3:
			return raw_points
		var result := PackedVector2Array()
		result.append(raw_points[0])
		for i in range(raw_points.size() - 1):
			var p0: Vector2 = raw_points[maxi(0, i - 1)]
			var p1: Vector2 = raw_points[i]
			var p2: Vector2 = raw_points[mini(raw_points.size() - 1, i + 1)]
			var p3: Vector2 = raw_points[mini(raw_points.size() - 1, i + 2)]
			var seg_length: float = p1.distance_to(p2)
			if seg_length < 0.01:
				continue
			var sharpness_at_p1 := 0.0
			if i > 0:
				var d1: Vector2 = (p1 - p0).normalized()
				var d2: Vector2 = (p2 - p1).normalized()
				sharpness_at_p1 = (1.0 - d1.dot(d2)) * 0.5
			var sharpness_at_p2 := 0.0
			if i + 2 < raw_points.size():
				var d1: Vector2 = (p2 - p1).normalized()
				var d2: Vector2 = (p3 - p2).normalized()
				sharpness_at_p2 = (1.0 - d1.dot(d2)) * 0.5
			var sharpness := maxf(sharpness_at_p1, sharpness_at_p2)
			var mid_interp: Vector2 = _catmull_rom(p0, p1, p2, p3, 0.5)
			var mid_straight: Vector2 = (p1 + p2) * 0.5
			var rel_curvature := mid_interp.distance_to(mid_straight) / maxf(seg_length, 0.1)
			if rel_curvature > 0.005:
				sharpness = maxf(sharpness, rel_curvature * 8.0)
			var subdivisions: int
			if sharpness < 0.05:
				subdivisions = 1
			elif sharpness < 0.15:
				subdivisions = 2
			elif sharpness < 0.3:
				subdivisions = maxi(3, mini(4, int(seg_length / 8.0)))
			elif sharpness < 0.5:
				subdivisions = maxi(4, mini(6, int(seg_length / 5.0)))
			else:
				subdivisions = maxi(6, mini(8, int(seg_length / 3.0)))
			for j in range(1, subdivisions):
				var t := float(j) / float(subdivisions)
				var interp: Vector2 = _catmull_rom(p0, p1, p2, p3, t)
				if result[result.size() - 1].distance_to(interp) > min_dist:
					result.append(interp)
			if i < raw_points.size() - 2 and result[result.size() - 1].distance_to(p2) > min_dist:
				result.append(p2)
		var last_point: Vector2 = raw_points[raw_points.size() - 1]
		if result[result.size() - 1].distance_to(last_point) > 0.1:
			result.append(last_point)
		return result

	static func _remove_polyline_loops(points: PackedVector2Array) -> PackedVector2Array:
		if points.size() < 4:
			return points
		var result := PackedVector2Array()
		result.append(points[0])
		var i := 1
		while i < points.size():
			var a: Vector2 = result[result.size() - 1]
			var b: Vector2 = points[i]
			var loop_found := false
			if result.size() >= 3:
				var j := 0
				while j < result.size() - 2:
					var ix := _segment_intersect(a, b, result[j], result[j + 1])
					if ix != Vector2.INF:
						var new_result := PackedVector2Array()
						for k in range(j + 1):
							new_result.append(result[k])
						new_result.append(ix)
						result = new_result
						loop_found = true
						break
					j += 1
			if not loop_found:
				result.append(b)
			i += 1
		return result

	static func _segment_intersect(a: Vector2, b: Vector2, c: Vector2, d: Vector2) -> Vector2:
		var ab: Vector2 = b - a
		var cd: Vector2 = d - c
		var denom: float = ab.x * cd.y - ab.y * cd.x
		if absf(denom) < 1e-10:
			return Vector2.INF
		var ac: Vector2 = c - a
		var t: float = (ac.x * cd.y - ac.y * cd.x) / denom
		var u: float = (ac.x * ab.y - ac.y * ab.x) / denom
		if t > 0.01 and t < 0.99 and u > 0.01 and u < 0.99:
			return a + ab * t
		return Vector2.INF

	static func _clip_segment_to_rect(a: Vector2, b: Vector2, min_x: float, max_x: float, min_z: float, max_z: float) -> Vector2:
		var best_t := 1.0
		var dx := b.x - a.x
		var dy := b.y - a.y
		if absf(dx) > 0.001:
			var t1: float = (min_x - a.x) / dx
			if t1 > 0.0 and t1 < best_t:
				var hz1: float = a.y + dy * t1
				if hz1 >= min_z and hz1 <= max_z:
					best_t = t1
			var t2: float = (max_x - a.x) / dx
			if t2 > 0.0 and t2 < best_t:
				var hz2: float = a.y + dy * t2
				if hz2 >= min_z and hz2 <= max_z:
					best_t = t2
		if absf(dy) > 0.001:
			var t3: float = (min_z - a.y) / dy
			if t3 > 0.0 and t3 < best_t:
				var hx3: float = a.x + dx * t3
				if hx3 >= min_x and hx3 <= max_x:
					best_t = t3
			var t4: float = (max_z - a.y) / dy
			if t4 > 0.0 and t4 < best_t:
				var hx4: float = a.x + dx * t4
				if hx4 >= min_x and hx4 <= max_x:
					best_t = t4
		return Vector2(a.x + dx * best_t, a.y + dy * best_t)

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
	test_corridor_covers_mesh_at_turn()
	test_sharp_turn_no_self_intersection()
	test_smoothed_road_corridor_covers_mesh()
	test_terrain_clipping_removes_road_area()
	test_terrain_clipping_sharp_turn()
	test_validate_road_direction_consistency()
	test_chunk_boundary_horizontal_road()
	test_chunk_boundary_crossing_with_both_endpoints_outside()
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


## Build corridor polygon using Geometry2D.offset_polyline (same as production code).
## Produces proper non-self-intersecting polygon with miter joins at turns.
static func build_corridor_polygon(points: PackedVector2Array, half_w: float) -> PackedVector2Array:
	var corridor_delta: float = half_w + 0.1  # 10cm buffer over mesh width
	var corridor_polys: Array[PackedVector2Array] = Geometry2D.offset_polyline(
		points, corridor_delta,
		Geometry2D.JOIN_MITER, Geometry2D.END_SQUARE)
	if corridor_polys.is_empty():
		return PackedVector2Array()
	var best: PackedVector2Array = corridor_polys[0]
	if best.size() >= 3 and ChunkMath.polygon_area(best) < 0:
		best.reverse()
	return best


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


func test_corridor_covers_mesh_at_turn() -> void:
	# Corridor (from offset_polyline) must cover all mesh vertices at turns.
	# 90° turn — most challenging case for coverage.
	var points := PackedVector2Array([
		Vector2(0, 0), Vector2(50, 0), Vector2(50, 50)
	])
	var half_w := 3.5
	var result := check_mesh_inside_corridor(points, half_w)
	_assert(result[0], "corridor_covers_mesh_at_90deg_turn",
		"Point %s at idx %d (%s) outside corridor" % [result[1], result[2], result[3]])

	# Corridor polygon should be strictly wider than mesh
	var corridor := build_corridor_polygon(points, half_w)
	var corridor_area := absf(ChunkMath.polygon_area(corridor))
	# Mesh area ≈ 2 * half_w * total_length = 7 * 100 = 700
	_assert(corridor_area > 700.0, "corridor_larger_than_mesh",
		"Corridor area %.1f should be > 700" % corridor_area)

func test_sharp_turn_no_self_intersection() -> void:
	# Regression: road (0,0)→(50,0)→(20,10) caused self-intersecting corridor
	# with the old manual perp approach. offset_polyline should handle it.
	var points := PackedVector2Array([
		Vector2(0, 0), Vector2(50, 0), Vector2(20, 10)
	])
	var half_w := 3.05
	var corridor := build_corridor_polygon(points, half_w)
	_assert(corridor.size() >= 3, "sharp_turn_corridor_valid",
		"Corridor should have >= 3 vertices, got %d" % corridor.size())
	# Verify corridor covers all mesh vertices
	var result := check_mesh_inside_corridor(points, half_w)
	_assert(result[0], "sharp_turn_mesh_covered",
		"Point %s at idx %d (%s) outside corridor" % [result[1], result[2], result[3]])


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

	# Use production terrain clipping
	var corridors: Array = [corridor]
	var terrain_polys := ChunkTerrainScript.compute_terrain_clipping(chunk_rect, corridors, [], [], [])

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

## Add a thin slit from corridor to nearest chunk boundary (mirrors production _add_boundary_slit).
## If corridor already touches any boundary, returns unchanged.
static func add_boundary_slit(corridor: PackedVector2Array, ch_x0: float, ch_x1: float, ch_z0: float, ch_z1: float) -> PackedVector2Array:
	var eps := 0.1
	var touches_boundary := false
	for i in range(corridor.size()):
		var p := corridor[i]
		if p.x <= ch_x0 + eps or p.x >= ch_x1 - eps or p.y <= ch_z0 + eps or p.y >= ch_z1 - eps:
			touches_boundary = true
			break
	if touches_boundary:
		return corridor
	var best_idx := 0
	var best_dist := INF
	for i in range(corridor.size()):
		var p := corridor[i]
		var d := minf(minf(p.x - ch_x0, ch_x1 - p.x), minf(p.y - ch_z0, ch_z1 - p.y))
		if d < best_dist:
			best_dist = d
			best_idx = i
	var pt := corridor[best_idx]
	var d_left := pt.x - ch_x0
	var d_right := ch_x1 - pt.x
	var d_bottom := pt.y - ch_z0
	var d_top := ch_z1 - pt.y
	var min_d := minf(minf(d_left, d_right), minf(d_bottom, d_top))
	var boundary_pt: Vector2
	if min_d == d_left:
		boundary_pt = Vector2(ch_x0, pt.y)
	elif min_d == d_right:
		boundary_pt = Vector2(ch_x1, pt.y)
	elif min_d == d_bottom:
		boundary_pt = Vector2(pt.x, ch_z0)
	else:
		boundary_pt = Vector2(pt.x, ch_z1)
	var slit_dir := (boundary_pt - pt).normalized()
	var slit_start := pt - slit_dir * 0.5  # extend 0.5m past corridor vertex into corridor
	var slit_perp := Vector2(-slit_dir.y, slit_dir.x) * 0.01
	var slit := PackedVector2Array([
		slit_start + slit_perp, boundary_pt + slit_perp,
		boundary_pt - slit_perp, slit_start - slit_perp
	])
	var merged := Geometry2D.merge_polygons(corridor, slit)
	if merged.size() > 0 and merged[0].size() >= 3:
		if ChunkMath.polygon_area(merged[0]) < 0:
			merged[0].reverse()
		return merged[0]
	return corridor


## Simulate the full pipeline for one road in one chunk:
## smooth → validate → build corridor → clip to chunk → add slit → clip mesh polyline
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
	# 3. Build corridor polygon, clip to chunk rect
	var chunk_rect := make_chunk_rect(cx, cz, chunk_size)
	var corridor := build_corridor_polygon(validated, half_w)
	var clipped_corridors := clip_corridor_to_chunk(corridor, chunk_rect)
	var ch_x0 := float(cx) * chunk_size
	var ch_x1 := float(cx + 1) * chunk_size
	var ch_z0 := float(cz) * chunk_size
	var ch_z1 := float(cz + 1) * chunk_size
	var corridors: Array[PackedVector2Array] = []
	for cp in clipped_corridors:
		if cp.size() >= 3:
			corridors.append(cp)
	# 4. Clip polyline to chunk with margin (for mesh vertices)
	var margin := half_w + 1.0
	var min_x := ch_x0 - margin
	var max_x := ch_x1 + margin
	var min_z := ch_z0 - margin
	var max_z := ch_z1 + margin
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


func test_chunk_boundary_crossing_with_both_endpoints_outside() -> void:
	var points := PackedVector2Array([
		Vector2(-70, 0),
		Vector2(130, 0),
	])
	var clipped := ChunkMath.clip_polyline_to_rect(points, -4.0, 104.0, -4.0, 104.0)
	_assert(clipped.size() >= 2, "chunk_boundary_crossing_with_both_endpoints_outside", "Expected clipped crossing segment, got %d points" % clipped.size())


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

static func simulate_terrain_clipping(
	corridors: Array[PackedVector2Array], chunk_rect: PackedVector2Array
) -> Array[PackedVector2Array]:
	# Use the production terrain clipping code (with CW hole handling)
	var corridor_array: Array = []
	for c in corridors:
		corridor_array.append(c)
	return ChunkTerrainScript.compute_terrain_clipping(chunk_rect, corridor_array, [], [], [])


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
