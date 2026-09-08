class_name LocalOSMSource
extends RefCounted

# Offline OSM data source: reads a bundled .osm.pbf once into an in-memory spatial
# index and serves per-chunk queries locally — a full replacement for the Overpass
# network path. Held for the lifetime of a world session by osm_terrain_generator.
#
# build_elements() returns an Overpass-shaped `elements` array (the same shape the
# HTTP path receives) so OSMParse.parse_elements() produces byte-identical output —
# guaranteeing parity with the on-disk osm_v11 cache.
#
# Faithfulness to the Overpass query in osm_loader.gd:
#   - ways/relations are kept only if their tags match the queried set (below);
#   - a way/relation is included in a chunk iff it has >=1 node inside the chunk bbox
#     (exactly Overpass `way[...](bbox)` semantics), and its FULL geometry is emitted;
#   - queried tagged nodes are emitted with tags only when inside the bbox; way-vertex
#     nodes are emitted as skeletons (no tags), matching `>; out skel qt`.

const OSM_DIR := "res://data/osm/"

# --- Load state (thread-safe handshake) ---
var _mutex := Mutex.new()
var _ready := false
var _load_failed := false
var _task_id := -1
var _pbf_path := ""

# --- Built index (written on worker thread, read on main after _ready) ---
var _node_lat: Dictionary = {}          # id:int -> lat:float (pruned to referenced nodes)
var _node_lon: Dictionary = {}          # id:int -> lon:float
var _ways: Array = []                   # [{id, refs:PackedInt64Array, tags}] (tag-filtered)
var _way_refs_by_id: Dictionary = {}    # id -> refs (kept ways + relation member ways)
var _relations: Array = []              # [{id, members:[{type,ref,role}], tags}] (tag-filtered)
var _tagged_nodes: Array = []           # [{id, lat, lon, tags}] (queried node-tag set only)

# --- Spatial buckets (cell key "cy,cx" -> Array[int index]) ---
var _way_cells: Dictionary = {}
var _rel_cells: Dictionary = {}
var _node_cells: Dictionary = {}
var _step_lat := 210.0 / 111000.0
var _step_lon := 210.0 / 111000.0
var _coverage: Dictionary = {}          # {min_lat,min_lon,max_lat,max_lon} for the loaded file

const _MEMBER_TYPE_STR := ["node", "way", "relation"]


# --- File selection ---------------------------------------------------------

## Returns the res:// path of the bundled .pbf whose header bbox covers (lat, lon),
## or "" if none. Cheap: reads only each file's header.
static func select_file_for(lat: float, lon: float) -> String:
	var dir := DirAccess.open(OSM_DIR)
	if dir == null:
		return ""
	dir.list_dir_begin()
	var name := dir.get_next()
	var best := ""
	var best_area := INF
	while name != "":
		if not dir.current_is_dir() and name.ends_with(".osm.pbf"):
			var path := OSM_DIR + name
			var bbox := PbfReader.decode_header_bbox(path)
			if _bbox_contains(bbox, lat, lon):
				# Prefer the smallest-area (most specific) covering extract.
				var area: float = (bbox["max_lat"] - bbox["min_lat"]) * (bbox["max_lon"] - bbox["min_lon"])
				if area < best_area:
					best_area = area
					best = path
		name = dir.get_next()
	dir.list_dir_end()
	return best


static func _bbox_contains(bbox: Dictionary, lat: float, lon: float) -> bool:
	if bbox.is_empty():
		return false
	return lat >= bbox["min_lat"] and lat <= bbox["max_lat"] and lon >= bbox["min_lon"] and lon <= bbox["max_lon"]


# --- Loading ----------------------------------------------------------------

## Kicks off a worker-thread decode + index build of `path`. Poll is_ready().
func begin_load(path: String) -> void:
	_pbf_path = path
	_task_id = WorkerThreadPool.add_task(_load_task, false, "LocalOSMSource:" + path.get_file())


func is_ready() -> bool:
	_mutex.lock()
	var r := _ready
	_mutex.unlock()
	return r


func load_failed() -> bool:
	_mutex.lock()
	var f := _load_failed
	_mutex.unlock()
	return f


func _load_task() -> void:
	var t0 := Time.get_ticks_msec()
	var raw := PbfReader.decode(_pbf_path)
	if raw.is_empty():
		_mutex.lock()
		_load_failed = true
		_ready = true
		_mutex.unlock()
		return
	_build_index(raw)
	var dt := Time.get_ticks_msec() - t0
	print("LocalOSMSource: indexed %s in %d ms — %d ways, %d relations, %d tagged nodes, %d geom nodes" % [
		_pbf_path.get_file(), dt, _ways.size(), _relations.size(), _tagged_nodes.size(), _node_lat.size()])
	_mutex.lock()
	_ready = true
	_mutex.unlock()


func _build_index(raw: Dictionary) -> void:
	var node_lat: Dictionary = raw["node_lat"]
	var node_lon: Dictionary = raw["node_lon"]
	var node_tags: Dictionary = raw["node_tags"]
	var all_ways: Array = raw["ways"]
	var all_relations: Array = raw["relations"]
	_coverage = raw.get("bbox", {})

	# Cell steps from the coverage mid-latitude (bucketing only; queries precise-test).
	var mid_lat := 0.5 * (float(_coverage.get("min_lat", 59.0)) + float(_coverage.get("max_lat", 59.0)))
	_step_lat = 210.0 / 111000.0
	_step_lon = 210.0 / (111000.0 * cos(deg_to_rad(mid_lat)))

	# 1) Filter relations; collect member way/node ids needed for geometry.
	var rel_member_way_ids := {}
	for rel in all_relations:
		if not _relation_wanted(rel["tags"]):
			continue
		_relations.append(rel)
		for m in rel["members"]:
			if m["type"] == 1:
				rel_member_way_ids[m["ref"]] = true

	# 2) Filter ways; keep refs for kept ways + relation member ways.
	for w in all_ways:
		var wid: int = w["id"]
		var wanted := _way_wanted(w["tags"])
		if wanted:
			_ways.append(w)
			_way_refs_by_id[wid] = w["refs"]
		elif rel_member_way_ids.has(wid):
			_way_refs_by_id[wid] = w["refs"]

	# 3) Queried tagged nodes (with coords).
	for nid in node_tags:
		var tags: Dictionary = node_tags[nid]
		if _node_wanted(tags) and node_lat.has(nid):
			_tagged_nodes.append({"id": nid, "lat": node_lat[nid], "lon": node_lon[nid], "tags": tags})

	# 4) Determine referenced nodes and prune coords to just those (memory).
	var needed := {}
	for w in _ways:
		for r in w["refs"]:
			needed[r] = true
	for rid in rel_member_way_ids:
		if _way_refs_by_id.has(rid):
			for r in _way_refs_by_id[rid]:
				needed[r] = true
	for rel in _relations:
		for m in rel["members"]:
			if m["type"] == 0:
				needed[m["ref"]] = true
	for tn in _tagged_nodes:
		needed[tn["id"]] = true
	for nid in needed:
		if node_lat.has(nid):
			_node_lat[nid] = node_lat[nid]
			_node_lon[nid] = node_lon[nid]

	# 5) Spatial buckets.
	for i in _ways.size():
		var seen := {}
		for r in _ways[i]["refs"]:
			if _node_lat.has(r):
				var key := _cell_key(_node_lat[r], _node_lon[r])
				if not seen.has(key):
					seen[key] = true
					_bucket_add(_way_cells, key, i)
	for j in _relations.size():
		var seen2 := {}
		for m in _relations[j]["members"]:
			var coords := _member_node_coords(m)
			for c in coords:
				var key := _cell_key(c.x, c.y)
				if not seen2.has(key):
					seen2[key] = true
					_bucket_add(_rel_cells, key, j)
	for k in _tagged_nodes.size():
		var tn: Dictionary = _tagged_nodes[k]
		_bucket_add(_node_cells, _cell_key(tn["lat"], tn["lon"]), k)


# Returns Array[Vector2] of (lat, lon) for a relation member's nodes (for bucketing).
func _member_node_coords(m: Dictionary) -> Array:
	var out: Array = []
	if m["type"] == 1 and _way_refs_by_id.has(m["ref"]):
		for r in _way_refs_by_id[m["ref"]]:
			if _node_lat.has(r):
				out.append(Vector2(_node_lat[r], _node_lon[r]))
	elif m["type"] == 0 and _node_lat.has(m["ref"]):
		out.append(Vector2(_node_lat[m["ref"]], _node_lon[m["ref"]]))
	return out


func _cell_key(lat: float, lon: float) -> String:
	return "%d,%d" % [int(floor(lat / _step_lat)), int(floor(lon / _step_lon))]


static func _bucket_add(bucket: Dictionary, key: String, idx: int) -> void:
	if bucket.has(key):
		bucket[key].append(idx)
	else:
		bucket[key] = [idx]


# --- Per-chunk query --------------------------------------------------------

## Builds the Overpass-shaped `elements` array for a chunk centred at (center_lat,
## center_lon) with the given radius (metres). Fast slice from the in-memory index.
func build_elements(center_lat: float, center_lon: float, radius: float) -> Array:
	var lat_d := radius / 111000.0
	var lon_d := radius / (111000.0 * cos(deg_to_rad(center_lat)))
	var min_lat := center_lat - lat_d
	var max_lat := center_lat + lat_d
	var min_lon := center_lon - lon_d
	var max_lon := center_lon + lon_d

	var cy0 := int(floor(min_lat / _step_lat))
	var cy1 := int(floor(max_lat / _step_lat))
	var cx0 := int(floor(min_lon / _step_lon))
	var cx1 := int(floor(max_lon / _step_lon))

	var elements: Array = []
	var node_out: Dictionary = {}  # id -> node element (tagged overrides skeleton)

	# Ways with >=1 node in bbox.
	var way_seen := {}
	for cy in range(cy0, cy1 + 1):
		for cx in range(cx0, cx1 + 1):
			var key := "%d,%d" % [cy, cx]
			if not _way_cells.has(key):
				continue
			for idx in _way_cells[key]:
				if way_seen.has(idx):
					continue
				way_seen[idx] = true
				var w: Dictionary = _ways[idx]
				if _way_hits_bbox(w["refs"], min_lat, max_lat, min_lon, max_lon):
					elements.append({"type": "way", "id": w["id"], "nodes": _refs_to_array(w["refs"]), "tags": w["tags"]})
					for r in w["refs"]:
						if _node_lat.has(r) and not node_out.has(r):
							node_out[r] = {"type": "node", "id": r, "lat": _node_lat[r], "lon": _node_lon[r]}

	# Relations with >=1 member node in bbox — emit with inline member geometry.
	var rel_seen := {}
	for cy in range(cy0, cy1 + 1):
		for cx in range(cx0, cx1 + 1):
			var key := "%d,%d" % [cy, cx]
			if not _rel_cells.has(key):
				continue
			for idx in _rel_cells[key]:
				if rel_seen.has(idx):
					continue
				rel_seen[idx] = true
				var rel: Dictionary = _relations[idx]
				if _relation_hits_bbox(rel, min_lat, max_lat, min_lon, max_lon):
					elements.append(_build_relation_element(rel))

	# Queried tagged nodes inside bbox (override skeletons).
	for cy in range(cy0, cy1 + 1):
		for cx in range(cx0, cx1 + 1):
			var key := "%d,%d" % [cy, cx]
			if not _node_cells.has(key):
				continue
			for idx in _node_cells[key]:
				var tn: Dictionary = _tagged_nodes[idx]
				var lat: float = tn["lat"]
				var lon: float = tn["lon"]
				if lat >= min_lat and lat <= max_lat and lon >= min_lon and lon <= max_lon:
					node_out[tn["id"]] = {"type": "node", "id": tn["id"], "lat": lat, "lon": lon, "tags": tn["tags"]}

	for nid in node_out:
		elements.append(node_out[nid])
	return elements


func _way_hits_bbox(refs: PackedInt64Array, min_lat: float, max_lat: float, min_lon: float, max_lon: float) -> bool:
	for r in refs:
		if _node_lat.has(r):
			var lat: float = _node_lat[r]
			var lon: float = _node_lon[r]
			if lat >= min_lat and lat <= max_lat and lon >= min_lon and lon <= max_lon:
				return true
	return false


func _relation_hits_bbox(rel: Dictionary, min_lat: float, max_lat: float, min_lon: float, max_lon: float) -> bool:
	for m in rel["members"]:
		for c in _member_node_coords(m):
			if c.x >= min_lat and c.x <= max_lat and c.y >= min_lon and c.y <= max_lon:
				return true
	return false


func _build_relation_element(rel: Dictionary) -> Dictionary:
	var members_out: Array = []
	for m in rel["members"]:
		var geom: Array = []
		if m["type"] == 1 and _way_refs_by_id.has(m["ref"]):
			for r in _way_refs_by_id[m["ref"]]:
				if _node_lat.has(r):
					geom.append({"lat": _node_lat[r], "lon": _node_lon[r]})
		elif m["type"] == 0 and _node_lat.has(m["ref"]):
			geom.append({"lat": _node_lat[m["ref"]], "lon": _node_lon[m["ref"]]})
		members_out.append({
			"type": _MEMBER_TYPE_STR[m["type"]] if m["type"] < 3 else "node",
			"ref": m["ref"],
			"role": m["role"],
			"geometry": geom,
		})
	return {"type": "relation", "id": rel["id"], "members": members_out, "tags": rel["tags"]}


static func _refs_to_array(refs: PackedInt64Array) -> Array:
	var out: Array = []
	for r in refs:
		out.append(r)
	return out


# --- Tag filters (mirror the Overpass query in osm_loader.gd) ----------------

static func _way_wanted(tags: Dictionary) -> bool:
	return tags.has("highway") or tags.has("building") or tags.has("landuse") \
		or tags.has("natural") or tags.has("leisure") or tags.has("waterway") \
		or tags.has("amenity") or tags.get("railway", "") == "tram" \
		or tags.get("man_made", "") == "bridge"


static func _relation_wanted(tags: Dictionary) -> bool:
	return tags.has("building") or tags.has("amenity") or tags.has("leisure") \
		or tags.get("highway", "") == "pedestrian" \
		or tags.get("natural", "") == "water" \
		or tags.get("waterway", "") == "riverbank" \
		or tags.get("man_made", "") == "bridge"


static func _node_wanted(tags: Dictionary) -> bool:
	if tags.get("man_made", "") == "chimney":
		return true
	if tags.get("natural", "") == "tree":
		return true
	if tags.has("traffic_sign"):
		return true
	var hw: String = tags.get("highway", "")
	if hw == "street_lamp" or hw == "traffic_signals" or hw == "bus_stop" or hw == "give_way":
		return true
	if tags.has("entrance") or tags.has("shop") or tags.has("amenity"):
		return true
	var pt: String = tags.get("public_transport", "")
	if pt == "platform" or pt == "station":
		return true
	if tags.get("railway", "") == "tram_stop":
		return true
	return false
