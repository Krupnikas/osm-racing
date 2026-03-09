## ChunkTerrain - pure terrain clipping helpers for chunk generation/tests.
class_name ChunkTerrain

const ChunkMath = preload("res://osm/chunk_math.gd")


static func compute_terrain_clipping(
	chunk_rect: PackedVector2Array,
	roads: Array,
	contours: Array,
	parking: Array,
	water_shore: Array
) -> Array[PackedVector2Array]:
	var terrain_polys: Array[PackedVector2Array] = [chunk_rect]

	for corridor in roads:
		if corridor.size() < 4:
			continue
		var new_polys: Array[PackedVector2Array] = []
		for poly in terrain_polys:
			var clipped: Array[PackedVector2Array] = Geometry2D.clip_polygons(poly, corridor)
			var has_cw_hole := false
			for cp in clipped:
				if cp.size() >= 3 and ChunkMath.polygon_area(cp) < -1.0:
					has_cw_hole = true
					break
			if not has_cw_hole:
				for cp in clipped:
					if cp.size() >= 3 and ChunkMath.polygon_area(cp) >= 1.0:
						new_polys.append(cp)
			else:
				var halves := _split_polygon_around_corridor(poly, corridor)
				for half in halves:
					var half_clipped: Array[PackedVector2Array] = Geometry2D.clip_polygons(half, corridor)
					for hc in half_clipped:
						if hc.size() >= 3 and ChunkMath.polygon_area(hc) >= 1.0:
							new_polys.append(hc)
		terrain_polys = new_polys
		if terrain_polys.is_empty():
			break

	terrain_polys = _clip_many(terrain_polys, contours)
	terrain_polys = _clip_many(terrain_polys, parking)
	terrain_polys = _clip_many(terrain_polys, water_shore)

	var ccw_polys: Array[PackedVector2Array] = []
	var cw_holes: Array[PackedVector2Array] = []
	for poly in terrain_polys:
		if poly.size() < 3:
			continue
		var area := ChunkMath.polygon_area(poly)
		if area >= 2.0:
			ccw_polys.append(poly)
		elif area <= -2.0:
			var reversed_poly := PackedVector2Array(poly)
			reversed_poly.reverse()
			cw_holes.append(reversed_poly)

	for hole in cw_holes:
		var new_ccw: Array[PackedVector2Array] = []
		for poly in ccw_polys:
			var clipped: Array[PackedVector2Array] = Geometry2D.clip_polygons(poly, hole)
			for cp in clipped:
				if cp.size() >= 3 and ChunkMath.polygon_area(cp) >= 2.0:
					new_ccw.append(cp)
		ccw_polys = new_ccw

	return ccw_polys


static func _clip_many(terrain_polys: Array[PackedVector2Array], cutters: Array) -> Array[PackedVector2Array]:
	if terrain_polys.is_empty():
		return terrain_polys
	var current := terrain_polys
	for cutter in cutters:
		if cutter.size() < 3:
			continue
		var new_polys: Array[PackedVector2Array] = []
		for poly in current:
			var clipped: Array[PackedVector2Array] = Geometry2D.clip_polygons(poly, cutter)
			for cp in clipped:
				if cp.size() >= 3:
					new_polys.append(cp)
		current = new_polys
		if current.is_empty():
			break
	return current


static func _split_polygon_around_corridor(poly: PackedVector2Array, corridor: PackedVector2Array) -> Array[PackedVector2Array]:
	var c0: Vector2 = corridor[0]
	var c_min_x: float = c0.x
	var c_max_x: float = c0.x
	var c_min_y: float = c0.y
	var c_max_y: float = c0.y
	for i in range(1, corridor.size()):
		var cv: Vector2 = corridor[i]
		c_min_x = minf(c_min_x, cv.x)
		c_max_x = maxf(c_max_x, cv.x)
		c_min_y = minf(c_min_y, cv.y)
		c_max_y = maxf(c_max_y, cv.y)
	var c_center_x: float = (c_min_x + c_max_x) * 0.5
	var c_center_y: float = (c_min_y + c_max_y) * 0.5

	var pv0: Vector2 = poly[0]
	var p_min_x: float = pv0.x
	var p_max_x: float = pv0.x
	var p_min_y: float = pv0.y
	var p_max_y: float = pv0.y
	for i in range(1, poly.size()):
		var pv: Vector2 = poly[i]
		p_min_x = minf(p_min_x, pv.x)
		p_max_x = maxf(p_max_x, pv.x)
		p_min_y = minf(p_min_y, pv.y)
		p_max_y = maxf(p_max_y, pv.y)

	var halves: Array[PackedVector2Array] = []
	if (c_max_x - c_min_x) >= (c_max_y - c_min_y):
		var left_half := PackedVector2Array([
			Vector2(p_min_x - 1.0, p_min_y - 1.0),
			Vector2(c_center_x, p_min_y - 1.0),
			Vector2(c_center_x, p_max_y + 1.0),
			Vector2(p_min_x - 1.0, p_max_y + 1.0),
		])
		var right_half := PackedVector2Array([
			Vector2(c_center_x, p_min_y - 1.0),
			Vector2(p_max_x + 1.0, p_min_y - 1.0),
			Vector2(p_max_x + 1.0, p_max_y + 1.0),
			Vector2(c_center_x, p_max_y + 1.0),
		])
		for lp in Geometry2D.intersect_polygons(poly, left_half):
			if lp.size() >= 3 and ChunkMath.polygon_area(lp) >= 1.0:
				halves.append(lp)
		for rp in Geometry2D.intersect_polygons(poly, right_half):
			if rp.size() >= 3 and ChunkMath.polygon_area(rp) >= 1.0:
				halves.append(rp)
	else:
		var top_half := PackedVector2Array([
			Vector2(p_min_x - 1.0, p_min_y - 1.0),
			Vector2(p_max_x + 1.0, p_min_y - 1.0),
			Vector2(p_max_x + 1.0, c_center_y),
			Vector2(p_min_x - 1.0, c_center_y),
		])
		var bot_half := PackedVector2Array([
			Vector2(p_min_x - 1.0, c_center_y),
			Vector2(p_max_x + 1.0, c_center_y),
			Vector2(p_max_x + 1.0, p_max_y + 1.0),
			Vector2(p_min_x - 1.0, p_max_y + 1.0),
		])
		for tp in Geometry2D.intersect_polygons(poly, top_half):
			if tp.size() >= 3 and ChunkMath.polygon_area(tp) >= 1.0:
				halves.append(tp)
		for bp in Geometry2D.intersect_polygons(poly, bot_half):
			if bp.size() >= 3 and ChunkMath.polygon_area(bp) >= 1.0:
				halves.append(bp)
	return halves
