## ChunkRoads — road geometry computation for chunk building.
## All static functions, fully thread-safe.
class_name ChunkRoads

const _ChunkMath = preload("res://osm/chunk_math.gd")

const ROAD_WIDTHS := {
	"motorway": 16.0, "trunk": 14.0, "primary": 12.0, "secondary": 10.0,
	"tertiary": 8.0, "residential": 6.0, "unclassified": 5.0, "service": 4.0,
	"footway": 2.0, "path": 1.5, "cycleway": 2.5, "track": 3.5
}


## Computes road mesh geometry + terrain corridor for a single road way.
## Returns dict with valid=false if road is outside chunk or too short.
static func compute_road_geometry(nodes: Array, tags: Dictionary, chunk_key: String,
		chunk_size: float, start_lat: float, start_lon: float, lon_scale: float) -> Dictionary:

	var highway_type: String = tags.get("highway", "residential")
	var width: float = ROAD_WIDTHS.get(highway_type, 5.0)

	# Convert lat/lon to local coords
	var raw_points := PackedVector2Array()
	raw_points.resize(nodes.size())
	for i in range(nodes.size()):
		var dx: float = (nodes[i].lon - start_lon) * lon_scale
		var dz: float = (nodes[i].lat - start_lat) * 111000.0
		raw_points[i] = Vector2(dx, -dz)

	# Bridge detection
	var is_bridge: bool = tags.get("bridge", "") == "yes" or tags.get("man_made", "") == "bridge"

	# Texture and height assignment
	var texture_key: String
	var height_offset: float
	var curb_height: float = 0.0
	match highway_type:
		"motorway", "trunk":
			texture_key = "highway"
			height_offset = 0.012
		"primary":
			texture_key = "primary"
			height_offset = 0.010
		"secondary":
			texture_key = "secondary"
			height_offset = 0.008
		"tertiary":
			texture_key = "tertiary"
			height_offset = 0.007
		"residential", "unclassified":
			texture_key = "residential"
			height_offset = 0.006
		"service":
			texture_key = "service"
			height_offset = 0.004
		"footway", "path", "pedestrian":
			texture_key = "path"
			height_offset = 0.115
		"cycleway":
			texture_key = "cycleway"
			height_offset = 0.006
		"track":
			texture_key = "track"
			height_offset = 0.004
		_:
			texture_key = "residential"
			height_offset = 0.006

	# Smooth
	var smoothed_points := _ChunkMath.smooth_road_corners(raw_points)

	# Clip to chunk bbox
	var ck_parts: PackedStringArray = chunk_key.split(",")
	var ck_x := int(ck_parts[0])
	var ck_z := int(ck_parts[1])
	var margin := width * 0.5 + 1.0
	var clipped := _ChunkMath.clip_polyline_to_rect(smoothed_points,
		float(ck_x) * chunk_size - margin,
		float(ck_x + 1) * chunk_size + margin,
		float(ck_z) * chunk_size - margin,
		float(ck_z + 1) * chunk_size + margin)

	if clipped.size() < 2:
		return {"valid": false}

	var result := {
		"valid": true,
		"smoothed_points": smoothed_points,
		"clipped_points": clipped,
		"highway_type": highway_type,
		"texture_key": texture_key,
		"width": width,
		"height_offset": height_offset,
		"curb_height": curb_height,
		"is_bridge": is_bridge,
		"tags": tags,
	}

	# Skip vertex gen for bridges and footways (handled separately)
	if is_bridge or highway_type in ["footway", "path"]:
		result["vertices"] = PackedVector3Array()
		result["uvs"] = PackedVector2Array()
		result["normals"] = PackedVector3Array()
		result["indices"] = PackedInt32Array()
		result["terrain_corridor"] = PackedVector2Array()
		return result

	# Validate direction (skip sharp reversals from clipping artifacts)
	var points: PackedVector2Array = _ChunkMath.validate_road_direction(clipped)

	if points.size() < 2:
		result["vertices"] = PackedVector3Array()
		result["uvs"] = PackedVector2Array()
		result["normals"] = PackedVector3Array()
		result["indices"] = PackedInt32Array()
		result["terrain_corridor"] = PackedVector2Array()
		return result

	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	var terrain_corridor := PackedVector2Array()

	var hash_val: int = int(abs(points[0].x * 1000 + points[0].y * 7919)) % 100
	var z_offset: float = hash_val * 0.00003
	var half_w: float = width * 0.5
	var h: float = height_offset + z_offset
	var n_points: int = points.size()

	# Perpendiculars
	var perpendiculars := PackedVector2Array()
	perpendiculars.resize(n_points)
	for i in range(n_points):
		var perp: Vector2
		if i == 0:
			var dir: Vector2 = (points[1] - points[0]).normalized()
			perp = Vector2(-dir.y, dir.x)
		elif i == n_points - 1:
			var dir: Vector2 = (points[i] - points[i - 1]).normalized()
			perp = Vector2(-dir.y, dir.x)
		else:
			var dir_out: Vector2 = (points[i + 1] - points[i]).normalized()
			perp = Vector2(-dir_out.y, dir_out.x)
		perpendiculars[i] = perp

	# Vertices
	var accumulated_length: float = 0.0
	var uv_scale: float = 0.1
	for i in range(n_points):
		var p: Vector2 = points[i]
		var perp: Vector2 = perpendiculars[i]
		if i > 0:
			accumulated_length += points[i - 1].distance_to(p)
		var uv_y: float = accumulated_length * uv_scale
		var left_pos := Vector2(p.x - perp.x * half_w, p.y - perp.y * half_w)
		var right_pos := Vector2(p.x + perp.x * half_w, p.y + perp.y * half_w)
		vertices.append(Vector3(left_pos.x, h, left_pos.y))
		uvs.append(Vector2(0.0, uv_y))
		normals.append(Vector3.UP)
		vertices.append(Vector3(right_pos.x, h, right_pos.y))
		uvs.append(Vector2(1.0, uv_y))
		normals.append(Vector3.UP)

	# Indices
	for i in range(n_points - 1):
		var idx: int = i * 2
		indices.append(idx)
		indices.append(idx + 3)
		indices.append(idx + 1)
		indices.append(idx)
		indices.append(idx + 2)
		indices.append(idx + 3)

	# Terrain corridor — use offset_polyline for proper non-self-intersecting polygon.
	# Manual perp-based construction self-intersects at sharp turns.
	if highway_type not in ["cycleway", "track", "steps"]:
		var corridor_delta: float = half_w + 0.1  # 10cm buffer over mesh width
		var corridor_polys: Array[PackedVector2Array] = Geometry2D.offset_polyline(
			points, corridor_delta,
			Geometry2D.JOIN_MITER, Geometry2D.END_SQUARE)
		if corridor_polys.size() > 0:
			terrain_corridor = corridor_polys[0]
			if terrain_corridor.size() >= 3 and _ChunkMath.polygon_area(terrain_corridor) < 0:
				terrain_corridor.reverse()

	result["vertices"] = vertices
	result["uvs"] = uvs
	result["normals"] = normals
	result["indices"] = indices
	result["terrain_corridor"] = terrain_corridor

	return result
