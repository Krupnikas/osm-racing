## ChunkMath - pure geometry helpers shared by chunk generation code.
class_name ChunkMath

## Fixed global origin — chunk (0,0) center is here.
## Must be on the 210m snap grid so chunk boundaries match legacy sessions.
## Computed: snap(59.150066) with lat_step=210/111000, snapped to 0.0001.
const ORIGIN_LAT := 59.1509
const ORIGIN_LON := 37.9483
const CHUNK_SIZE := 210.0

## Lon scale at origin latitude: cos(59.1509°) * 111000
const LON_SCALE := 56918.44  # Precomputed: cos(deg_to_rad(59.1509)) * 111000.0


## Convert absolute lat/lon to world coordinates (meters from global origin).
static func latlon_to_world(lat: float, lon: float) -> Vector2:
	var x := (lon - ORIGIN_LON) * LON_SCALE
	var z := -(lat - ORIGIN_LAT) * 111000.0
	return Vector2(x, z)


## Convert world coordinates back to absolute lat/lon.
static func world_to_latlon(world_x: float, world_z: float) -> Vector2:
	var lat := ORIGIN_LAT - world_z / 111000.0
	var lon := ORIGIN_LON + world_x / LON_SCALE
	return Vector2(lat, lon)


## Get chunk indices for a world position.
static func world_to_chunk(world_x: float, world_z: float) -> Vector2i:
	return Vector2i(int(floor(world_x / CHUNK_SIZE)), int(floor(world_z / CHUNK_SIZE)))


## Get chunk indices directly from absolute lat/lon.
static func latlon_to_chunk(lat: float, lon: float) -> Vector2i:
	var w := latlon_to_world(lat, lon)
	return world_to_chunk(w.x, w.y)


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
			var d3: Vector2 = (p2 - p1).normalized()
			var d4: Vector2 = (p3 - p2).normalized()
			sharpness_at_p2 = (1.0 - d3.dot(d4)) * 0.5
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
