extends Node3D

# Stage 1: read-only bridge approach ramp detection + debug overlay.
#
# Detects candidate BridgePortals around bridges (man_made=bridge polygons
# and standalone bridge=yes ways) and ApproachRamp polylines on the road
# graph leading away from each portal. Computes diagnostic slope only.
#
# DOES NOT modify any geometry, target_y, road meshes, bridge meshes, or
# collision. Detection failure is silent: bridges keep working as today.
#
# Toggle the overlay:
#   - F9 at runtime
#   - --bridge-ramp-debug command-line arg
#   - BRIDGE_RAMP_DEBUG environment variable
#
# Design: docs/bridge_ramp_design.md

const RAMP_BUDGET := 35.0
const ANGLE_LIMIT_DEG := 60.0
const SHORT_RAMP_LIMIT := 4.0
const MAX_GRADE := 0.15
const COORD_EPS := 1e-7

const NON_DRIVABLE_HIGHWAYS := ["footway", "path", "steps", "cycleway",
		"pedestrian", "track", "bridleway", "corridor"]

const TERMINATOR_COLORS := {
	"budget": Color(0.2, 0.9, 0.2),
	"intersection": Color(1.0, 0.6, 0.0),
	"bridge": Color(0.2, 0.5, 1.0),
	"tunnel": Color(0.0, 0.85, 0.95),
	"angle": Color(1.0, 0.2, 1.0),
	"slope_clamp": Color(1.0, 0.1, 0.1),
}


class BridgePortal extends RefCounted:
	var pos: Vector2
	var node_coord_key: String = ""
	var component_kind: String = ""        # "polygon" or "standalone"
	var component_ref: Variant = -1        # poly_idx or way_id
	var target_y: float = NAN
	var is_shared_abutment: bool = false


class ApproachRamp extends RefCounted:
	var portal: BridgePortal
	var polyline: PackedVector2Array = PackedVector2Array()
	var cum_dist: PackedFloat32Array = PackedFloat32Array()
	var total_length: float = 0.0
	var terminator: String = ""
	var locked_node_y: float = NAN         # Stage-1 diagnostic only
	var grade: float = 0.0                 # diagnostic
	var steep_warning: bool = false
	var first_way_id: int = -1             # OSM way id where the walk started
	var terrain_y_at_end: float = NAN      # diagnostic — terrain Y at far end
	# Stage 2A: which OSM way_ids does this ramp own, and over what
	# ramp-distance intervals. Used by sample_road_y_for_way to filter
	# candidates by way_id BEFORE doing any spatial projection.
	# way_ids: ordered list of distinct way_ids visited by the walk.
	# way_ranges: way_id -> Array of {ramp_d_start: float, ramp_d_end: float}
	#             (one entry per contiguous run of segments on that way).
	var way_ids: Array = []
	var way_ranges: Dictionary = {}


var _terrain_gen: Node = null
var _osm_data: Dictionary = {}
var _portals: Array = []                   # Array[BridgePortal]
var _ramps: Array = []                     # Array[ApproachRamp]
var _node_to_ways: Dictionary = {}         # coord_key -> Array[way_dict]
var _enabled: bool = false                       # debug overlay toggle (F9)
var _bridge_ramp_road_y_enabled: bool = false    # Stage 2A — apply road-side ramp Y (F10)
var _detected: bool = false
var _stats: Dictionary = {}
var _refresh_accum: float = 0.0
# Accumulated way set across all chunks (deduped by OSM way id).
var _all_ways_by_id: Dictionary = {}
# Mark detection as dirty when new ways or polygons appear; debounced re-run.
var _detection_dirty: bool = false
var _debounce_accum: float = 0.0
const DEBOUNCE_SECS := 0.5
const RAMP_INDEX_CELL_SIZE := 30.0
const RAMP_TRANSVERSE_TOL_OVERLAY := 8.0   # debug overlay tolerance only
const RAMP_TRANSVERSE_TOL_APPLY := 4.0     # Stage 2A — strict tolerance when applying Y
var _last_polygon_count: int = 0
var _last_summary: String = ""
# Spatial hash for debug overlay only — NEVER used to apply road Y.
var _ramps_by_cell: Dictionary = {}
# Stage 2A: way-id-aware ramp lookup. The PRIMARY index for applying Y.
var _ramps_by_way_id: Dictionary = {}    # way_id (int) -> Array[ramp_id (int)]
# Diagnostic: per (way_id, chunk_key) the road's first/last centerline
# vertex AFTER all _compute_road_geometry_thread processing. Used by the
# overlay to visualise the actual gap between road and bridge.
var _road_endpoints_log: Dictionary = {}
# Mutex protects _ramps, _ramps_by_way_id, _portals from worker-thread reads
# during main-thread detection. Detection is short and rare; sampling holds
# the lock briefly per call.
var _detector_mutex: Mutex = Mutex.new()
# Stage 2A — throttled apply-time debug logging.
const MAX_APPLY_LOGS := 60
var _apply_log_remaining: int = 0
var _apply_log_enabled: bool = false

var _overlay_inst: MeshInstance3D = null
var _overlay_im: ImmediateMesh = null
var _overlay_mat: StandardMaterial3D = null
var _labels_root: Node3D = null


func _ready() -> void:
	if name == "":
		name = "BridgeRampDetector"
	_reset_stats()
	if OS.has_environment("BRIDGE_RAMP_DEBUG") \
			or "--bridge-ramp-debug" in OS.get_cmdline_args():
		_enabled = true
	if OS.has_environment("BRIDGE_RAMP_APPLY") \
			or "--bridge-ramp-apply" in OS.get_cmdline_args():
		_bridge_ramp_road_y_enabled = true
	if OS.has_environment("BRIDGE_RAMP_APPLY_DEBUG") \
			or "--bridge-ramp-apply-debug" in OS.get_cmdline_args():
		_apply_log_enabled = true
	_setup_overlay_nodes()
	set_process_unhandled_input(true)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var k: InputEventKey = event
	if k.pressed and not k.echo and k.keycode == KEY_F9:
		_enabled = not _enabled
		_update_overlay_visibility()
		if _enabled and _detected:
			_redraw_overlay()
		print("[BridgeRamp] Overlay %s" % ("enabled" if _enabled else "disabled"))
	elif k.pressed and not k.echo and k.keycode == KEY_F10:
		_bridge_ramp_road_y_enabled = not _bridge_ramp_road_y_enabled
		print("[BridgeRamp] Stage 2A road-side ramp Y %s"
				% ("ENABLED (only fresh chunk loads will reflect change)"
					if _bridge_ramp_road_y_enabled else "disabled"))


func _process(delta: float) -> void:
	# Detection now runs synchronously inside notify_chunk_loaded; this
	# tick is only for the periodic ref_elev re-query loop.
	if not _detected:
		return
	_refresh_accum += delta
	if _refresh_accum < 1.0:
		return
	_refresh_accum = 0.0
	if int(_stats.get("pending_target_y", 0)) > 0:
		_refresh_pending_target_ys()


# ============================================================
# Public entry
# ============================================================

# Called once per chunk load. Accumulates the union of OSM ways across
# chunks. Detection is marked dirty when:
#   - a NEW bridge=yes way appeared, OR
#   - a NEW polygon appeared, OR
#   - any new way appeared AND we already have bridges in the registry
#     (because the new way may be a continuation that resolves an
#     unresolved endpoint of an existing bridge).
# Re-detection runs debounced (0.5 s) to coalesce a burst of adjacent chunks.
func notify_chunk_loaded(osm_data: Dictionary, terrain_gen: Node) -> void:
	if _terrain_gen == null:
		_terrain_gen = terrain_gen
	var added_bridge_way: bool = false
	var added_any_way: bool = false
	for w in osm_data.get("ways", []):
		var wid: int = int(w.get("id", -1)) if "id" in w else -1
		if wid < 0:
			continue
		if _all_ways_by_id.has(wid):
			continue
		_all_ways_by_id[wid] = w
		added_any_way = true
		var tags: Dictionary = w.get("tags", {})
		if tags.get("bridge", "") == "yes":
			added_bridge_way = true
	var poly_count: int = (_terrain_gen._bridge_deck_polygons as Array).size() \
			if _terrain_gen else 0
	var have_bridges: bool = _has_any_bridge_in_registry() or poly_count > 0
	if added_bridge_way or poly_count > _last_polygon_count \
			or (added_any_way and have_bridges):
		# Stage 2: run detection synchronously here so the spatial ramp
		# index is up-to-date BEFORE this chunk's road meshing samples
		# vertex Y. Otherwise the road mesh is built before ramps are
		# registered and `sample_road_y` returns plain terrain.
		_run_detection_now()


func _has_any_bridge_in_registry() -> bool:
	for w in _all_ways_by_id.values():
		if w.get("tags", {}).get("bridge", "") == "yes":
			return true
	return false


# Direct entry-point (kept for future Stage-2 re-detect commands or tests).
func run_detection(osm_data: Dictionary, terrain_gen: Node) -> void:
	notify_chunk_loaded(osm_data, terrain_gen)


func _run_detection_now() -> void:
	if _terrain_gen == null:
		return
	# Build a synthetic osm_data with the merged way set for downstream code.
	_osm_data = {"ways": _all_ways_by_id.values()}
	# Lock around the mutation: worker threads may be inside
	# sample_road_y_for_way concurrently; mutex serialises writes/reads.
	_detector_mutex.lock()
	_portals.clear()
	_ramps.clear()
	_ramps_by_cell.clear()
	_ramps_by_way_id.clear()
	_apply_log_remaining = MAX_APPLY_LOGS  # reset throttle each detection
	_reset_stats()
	var ok := _safe_detect()
	if ok:
		_build_ramps_by_way_id_index()
		_build_ramp_index()
	_detector_mutex.unlock()
	if not ok:
		push_warning("[BridgeRamp] Detection error caught; bridges unaffected")
		return
	_last_polygon_count = (_terrain_gen._bridge_deck_polygons as Array).size()
	_detected = true
	_log_summary()
	if _enabled:
		_redraw_overlay()


# Stage 2A: build the way-id-keyed lookup. This is the PRIMARY index used
# by sample_road_y_for_way; only ramps registered for the queried way_id
# can affect that road's vertex Y.
func _build_ramps_by_way_id_index() -> void:
	_ramps_by_way_id.clear()
	for ramp_id in range(_ramps.size()):
		var ramp: ApproachRamp = _ramps[ramp_id]
		for wid in ramp.way_ids:
			var wid_int: int = int(wid)
			if not _ramps_by_way_id.has(wid_int):
				_ramps_by_way_id[wid_int] = []
			var arr: Array = _ramps_by_way_id[wid_int]
			if not (ramp_id in arr):
				arr.append(ramp_id)


# Spatial hash so per-vertex sampling at road-mesh time is O(1) amortized.
# Each ramp segment registers itself in every cell its inflated AABB covers.
func _build_ramp_index() -> void:
	_ramps_by_cell.clear()
	for ramp_id in range(_ramps.size()):
		var ramp: ApproachRamp = _ramps[ramp_id]
		var pts: PackedVector2Array = ramp.polyline
		for i in range(pts.size() - 1):
			var a: Vector2 = pts[i]
			var b: Vector2 = pts[i + 1]
			var min_x: float = minf(a.x, b.x) - RAMP_TRANSVERSE_TOL_OVERLAY
			var max_x: float = maxf(a.x, b.x) + RAMP_TRANSVERSE_TOL_OVERLAY
			var min_y: float = minf(a.y, b.y) - RAMP_TRANSVERSE_TOL_OVERLAY
			var max_y: float = maxf(a.y, b.y) + RAMP_TRANSVERSE_TOL_OVERLAY
			var cx0: int = int(floor(min_x / RAMP_INDEX_CELL_SIZE))
			var cy0: int = int(floor(min_y / RAMP_INDEX_CELL_SIZE))
			var cx1: int = int(floor(max_x / RAMP_INDEX_CELL_SIZE))
			var cy1: int = int(floor(max_y / RAMP_INDEX_CELL_SIZE))
			for cx in range(cx0, cx1 + 1):
				for cy in range(cy0, cy1 + 1):
					var key := Vector2i(cx, cy)
					if not _ramps_by_cell.has(key):
						_ramps_by_cell[key] = []
					var arr: Array = _ramps_by_cell[key]
					if not (ramp_id in arr):
						arr.append(ramp_id)


# ===============================================================
# Stage 2A — way-aware road Y sampler (the ONLY production sampler).
# ===============================================================
#
# Called from worker threads inside _compute_road_geometry_thread.
# Filters candidate ramps by way_id BEFORE any spatial test. A
# perpendicular or parallel road that does not own one of the ramp's
# way_ids cannot be affected.
#
# Args:
#   way_id: the OSM way id of the road being meshed (from task_data).
#   point: local-XZ position of the road vertex (typically a left/right
#          edge vertex, but the centerline_distance refers to the
#          centerline index that produced this edge vertex).
#   centerline_distance: cumulative distance along the road's centerline
#          in this chunk. Currently informational only — kept in the
#          signature so future versions can match against way_ranges
#          via absolute way distance instead of polyline projection.
#   terrain_y: the elevation the caller would have used.
#   road_y_offset: the small height_offset + z_offset the caller adds.
#
# Thread safety: takes the detector mutex briefly. Detection on the main
# thread takes the same mutex during its writes; reads see a consistent
# (_ramps, _ramps_by_way_id) state.
func sample_road_y_for_way(way_id: int, point: Vector2,
		centerline_distance: float, terrain_y: float, road_y_offset: float) -> float:
	if not _bridge_ramp_road_y_enabled or not _detected:
		return terrain_y + road_y_offset
	if way_id == 0:
		return terrain_y + road_y_offset
	_detector_mutex.lock()
	var ramp_ids: Array = _ramps_by_way_id.get(way_id, [])
	if ramp_ids.is_empty():
		_detector_mutex.unlock()
		return terrain_y + road_y_offset
	var snapshot: Array = []
	for rid in ramp_ids:
		var rid_int: int = int(rid)
		if rid_int >= 0 and rid_int < _ramps.size():
			snapshot.append([rid_int, _ramps[rid_int]])
	var log_left_local: int = _apply_log_remaining
	_detector_mutex.unlock()
	# UNIFIED HEIGHT FUNCTION (Stage 2A.3 architectural fix):
	# The bridge mesh uses `_deck_surface_y_at(p, polygon, 1, ref_elev)` for
	# every vertex. Stage 2A's old ramp-polyline-projection formula
	# diverges from this at the polygon boundary (different smoothstep
	# parameters). Result: 5–10 m vertical mismatch where the meshes meet.
	# Fix: use the SAME `_deck_surface_y_at` formula the bridge mesh uses.
	# The ramp polyline is now used only as a GATE — to decide whether the
	# point is "near the bridge" (within ramp distance + perp tolerance);
	# Y itself comes from the bridge formula. Both meshes therefore
	# compute identical Y for any shared XY. Match guaranteed.
	var best: float = -INF
	var best_rid: int = -1
	var best_d: float = 0.0
	for entry in snapshot:
		var rid: int = entry[0]
		var ramp: ApproachRamp = entry[1]
		if ramp.grade > 1.0:
			continue
		var candidate: float = NAN
		var d: float = -1.0
		if ramp.portal.component_kind == "polygon":
			var poly_idx: int = int(ramp.portal.component_ref)
			var polygons: Array = _terrain_gen._bridge_deck_polygons
			if poly_idx < 0 or poly_idx >= polygons.size():
				continue
			var poly: PackedVector2Array = polygons[poly_idx]
			var ref_elev: float = _terrain_gen._deck_polygon_ref_elev.get(poly_idx, NAN)
			if is_nan(ref_elev):
				continue
			# Eligibility: point near polygon (inside or within 5m of edge)
			# OR within ramp polyline projection. Otherwise terrain.
			var on_or_near_polygon: bool = Geometry2D.is_point_in_polygon(point, poly)
			if not on_or_near_polygon:
				var dist_to_poly: float = _min_dist_to_polygon_outline(point, poly)
				if dist_to_poly < 5.0:
					on_or_near_polygon = true
			# Y formula: bridge mesh value at this point.
			var deck_y: float = _terrain_gen._deck_surface_y_at(point, poly, 1, ref_elev)
			if on_or_near_polygon:
				# At/inside polygon → deck Y exactly (matches bridge mesh).
				candidate = deck_y
				d = 0.0
			else:
				# Outside polygon → smoothstep blend from deck Y at portal
				# (d=0) to terrain Y at ramp end (d=total_length). This is
				# the SMOOTH ramp the player drives up; without it, the
				# road jumps abruptly from terrain to deck height at the
				# ramp's far edge, leaving a "missing piece at ground
				# level" between the elevated ramp and the bridge.
				d = _project_distance_along_polyline_strict(ramp, point)
				if d < 0.0 or d > ramp.total_length:
					continue
				var t: float = clampf(d / maxf(ramp.total_length, 0.001), 0.0, 1.0)
				var s: float = smoothstep(0.0, 1.0, t)
				candidate = lerpf(deck_y, terrain_y, s)
		else:
			d = _project_distance_along_polyline_strict(ramp, point)
			if d < 0.0 or d > ramp.total_length:
				continue
			var portal_y: float = ramp.portal.target_y
			if is_nan(portal_y):
				continue
			var t: float = clampf(d / maxf(ramp.total_length, 0.001), 0.0, 1.0)
			var s: float = smoothstep(0.0, 1.0, t)
			candidate = lerpf(portal_y, terrain_y, s)
		if is_nan(candidate):
			continue
		if candidate > best:
			best = candidate
			best_rid = rid
			best_d = d
	if best == -INF:
		return terrain_y + road_y_offset
	if _apply_log_enabled and log_left_local > 0:
		_apply_log_remaining = log_left_local - 1
		var delta: float = best - terrain_y
		print("[BridgeRamp] APPLY way=%d ramp=%d d=%.2f terrain=%.2f cand=%.2f Δ=%.2f cl_d=%.2f"
				% [way_id, best_rid, best_d, terrain_y, best, delta, centerline_distance])
	return maxf(best, terrain_y) + road_y_offset


## Diagnostic: record road's first/last centerline vertex after all
## processing in _compute_road_geometry_thread. Called via call_deferred
## from the worker thread.
func record_road_endpoints(way_id: int, chunk_key: String,
		first: Vector2, last: Vector2) -> void:
	_detector_mutex.lock()
	_road_endpoints_log["%d:%s" % [way_id, chunk_key]] = {
		"way_id": way_id,
		"chunk_key": chunk_key,
		"first": first,
		"last": last,
	}
	_detector_mutex.unlock()
	if _enabled:
		_redraw_overlay()


## Stage 2A.3 helper: returns the polygon indices of all ramps owning
## this way. Used by the road-mesh thread to extend the polyline toward
## the polygon edge so road mesh meets bridge mesh flush horizontally.
func get_polygon_indices_for_way(way_id: int) -> Array:
	var result: Array = []
	if not _detected:
		return result
	_detector_mutex.lock()
	var ramp_ids: Array = _ramps_by_way_id.get(way_id, [])
	for rid in ramp_ids:
		var rid_int: int = int(rid)
		if rid_int < 0 or rid_int >= _ramps.size():
			continue
		var ramp: ApproachRamp = _ramps[rid_int]
		if ramp.portal.component_kind == "polygon":
			var idx: int = int(ramp.portal.component_ref)
			if not (idx in result):
				result.append(idx)
	_detector_mutex.unlock()
	return result


## Stage 2A.1 helper: does this way own at least one ramp? Used by the
## terrain generator's wrapper to gate the inside-polygon stitch.
## Thread-safe via the detector mutex.
func way_owns_ramp(way_id: int) -> bool:
	if not _detected or way_id == 0:
		return false
	_detector_mutex.lock()
	var has: bool = _ramps_by_way_id.has(way_id) and not (_ramps_by_way_id[way_id] as Array).is_empty()
	_detector_mutex.unlock()
	return has


## Returns minimum distance from `point` to any edge of `polygon` outline.
func _min_dist_to_polygon_outline(point: Vector2, polygon: PackedVector2Array) -> float:
	var best: float = INF
	for j in range(polygon.size()):
		var p1: Vector2 = polygon[j]
		var p2: Vector2 = polygon[(j + 1) % polygon.size()]
		var closest: Vector2 = Geometry2D.get_closest_point_to_segment(point, p1, p2)
		var d: float = closest.distance_to(point)
		if d < best:
			best = d
	return best


# Strict variant: rejects perpendicular distance > RAMP_TRANSVERSE_TOL_APPLY (4 m).
# Same-way road centerline should project very close to its own ramp polyline
# (a few cm). 4 m is generous enough for half-width of a wide road.
func _project_distance_along_polyline_strict(ramp: ApproachRamp, point: Vector2) -> float:
	var pts: PackedVector2Array = ramp.polyline
	var cums: PackedFloat32Array = ramp.cum_dist
	var best_d: float = -1.0
	var best_perp: float = INF
	for i in range(pts.size() - 1):
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[i + 1]
		var seg_len_sq: float = (b - a).length_squared()
		if seg_len_sq < 1e-6:
			continue
		var t: float = clampf((point - a).dot(b - a) / seg_len_sq, 0.0, 1.0)
		var proj: Vector2 = a.lerp(b, t)
		var perp: float = point.distance_to(proj)
		if perp < best_perp and perp <= RAMP_TRANSVERSE_TOL_APPLY:
			best_perp = perp
			var seg_len: float = sqrt(seg_len_sq)
			best_d = cums[i] + t * seg_len
	return best_d


func _safe_detect() -> bool:
	# GDScript has no try/except. Each step is defensive (null/empty checks)
	# and any unexpected runtime error will be caught by Godot's normal
	# error handling without affecting the bridge rendering path.
	if _terrain_gen == null:
		return false
	_build_node_to_ways_index()
	_detect_polygon_bridges()
	_detect_standalone_bridges()
	_refresh_pending_target_ys()
	return true


# ============================================================
# Index
# ============================================================

func _build_node_to_ways_index() -> void:
	_node_to_ways.clear()
	for way in _osm_data.get("ways", []):
		var nodes: Array = way.get("nodes", [])
		for n in nodes:
			var k := _coord_key(n.lat, n.lon)
			if not _node_to_ways.has(k):
				_node_to_ways[k] = []
			(_node_to_ways[k] as Array).append(way)


func _coord_key(lat: float, lon: float) -> String:
	return "%.7f,%.7f" % [lat, lon]


func _is_drivable(way: Dictionary) -> bool:
	var tags: Dictionary = way.get("tags", {})
	var hw: String = tags.get("highway", "")
	if hw.is_empty():
		return false
	return not (hw in NON_DRIVABLE_HIGHWAYS)


func _is_tunnel(tags: Dictionary) -> bool:
	return tags.get("tunnel", "") == "yes"


# True iff either endpoint of `way` shares an OSM node coord with another
# way tagged bridge=yes. Used to allow `cutting=yes layer=-1` off-ramps
# that connect to an on-deck way at the abutment.
func _shares_endpoint_with_bridge_way(way: Dictionary) -> bool:
	var nodes: Array = way.get("nodes", [])
	if nodes.size() < 2:
		return false
	var self_id: int = int(way.get("id", -1))
	var endpoints := [nodes[0], nodes[nodes.size() - 1]]
	for n in endpoints:
		var k: String = _coord_key(n.lat, n.lon)
		for w2 in _node_to_ways.get(k, []):
			if int(w2.get("id", -2)) == self_id:
				continue
			if w2.get("tags", {}).get("bridge", "") == "yes":
				return true
	return false


# ============================================================
# Polygon-bridge detection
# ============================================================

func _detect_polygon_bridges() -> void:
	var polygons: Array = _terrain_gen._bridge_deck_polygons
	var ways: Array = _osm_data.get("ways", [])
	_stats["polygons_scanned"] = polygons.size()
	for poly_idx in range(polygons.size()):
		var poly: PackedVector2Array = polygons[poly_idx]
		if poly.size() < 3:
			continue
		var aabb := _polygon_aabb(poly)
		var aabb_inflated := aabb.grow(100.0)
		for way in ways:
			if not _is_drivable(way):
				continue
			var tags: Dictionary = way.get("tags", {})
			# bridge=yes ways that cross the polygon boundary still need
			# ramps (e.g. secondary road entering/exiting the deck).
			# The portal detection below will naturally skip ways that are
			# entirely inside (no inside↔outside transition).
			var is_bridge_way: bool = tags.get("bridge", "") == "yes"
			var nodes: Array = way.get("nodes", [])
			if nodes.size() < 2:
				continue
			# Layer filter: a way with layer<0 is a candidate under-bridge
			# crossing — UNLESS one of its endpoints shares a node with a
			# bridge=yes way, in which case it's a legitimate off-ramp
			# descending into a cutting (e.g. secondary_link cutting=yes
			# joining a bridge=yes deck ramp at the abutment).
			if _parse_layer(tags) < 0 and not _shares_endpoint_with_bridge_way(way):
				continue
			# AABB pre-filter + collect locals/inside-flags in one pass.
			var locals: Array = []
			var any_close := false
			for n in nodes:
				var lp: Vector2 = _terrain_gen._latlon_to_local(n.lat, n.lon)
				locals.append(lp)
				if not any_close and aabb_inflated.has_point(lp):
					any_close = true
			if not any_close:
				continue
			var inside_flags: Array = []
			for lp in locals:
				inside_flags.append(Geometry2D.is_point_in_polygon(lp, poly))
			var any_inside := false
			for fl in inside_flags:
				if bool(fl):
					any_inside = true
					break
			# First inside↔outside transition along the way.
			var portal_idx := -1
			var step := 0
			for i in range(locals.size() - 1):
				if bool(inside_flags[i]) and not bool(inside_flags[i + 1]):
					portal_idx = i + 1
					step = 1
					break
				if bool(inside_flags[i + 1]) and not bool(inside_flags[i]):
					portal_idx = i
					step = -1
					break
			if portal_idx < 0:
				continue
			# Stage 2A.1 fix — reject through-pass ways. A real approach
			# has at least one inside-polygon node that is shared with a
			# bridge=yes way (the road meets the on-deck way at the
			# abutment). A road that simply passes UNDER the polygon at
			# layer=0 has no such shared node → reject so we don't lift
			# the under-bridge road onto the deck.
			var has_bridge_link_inside: bool = false
			for ni in range(nodes.size()):
				if not bool(inside_flags[ni]):
					continue
				var n_dict: Dictionary = nodes[ni]
				var n_key: String = _coord_key(n_dict.lat, n_dict.lon)
				for w2 in _node_to_ways.get(n_key, []):
					if int(w2.get("id", -2)) == int(way.get("id", -1)):
						continue
					if w2.get("tags", {}).get("bridge", "") == "yes":
						has_bridge_link_inside = true
						break
				if has_bridge_link_inside:
					break
			if not has_bridge_link_inside and not is_bridge_way:
				continue
			var portal_node: Dictionary = nodes[portal_idx]
			var portal_pos: Vector2 = locals[portal_idx]
			var portal := BridgePortal.new()
			portal.pos = portal_pos
			portal.node_coord_key = _coord_key(portal_node.lat, portal_node.lon)
			portal.component_kind = "polygon"
			portal.component_ref = poly_idx
			portal.is_shared_abutment = false
			portal.target_y = _polygon_target_y(poly_idx, poly, portal_pos)
			if is_nan(portal.target_y):
				_stats["pending_target_y"] = int(_stats.get("pending_target_y", 0)) + 1
			_portals.append(portal)
			_stats["portals"] = int(_stats.get("portals", 0)) + 1
			var ramp := _walk_ramp(way, portal_idx, step, portal)
			if ramp.total_length < SHORT_RAMP_LIMIT:
				_stats["skipped_short"] = int(_stats.get("skipped_short", 0)) + 1
				continue
			_compute_grade_diagnostic(ramp, portal)
			_ramps.append(ramp)
			_stats["ramps"] = int(_stats.get("ramps", 0)) + 1
			if ramp.steep_warning:
				_stats["steep_warnings"] = int(_stats.get("steep_warnings", 0)) + 1


func _polygon_target_y(poly_idx: int, poly: PackedVector2Array, point: Vector2) -> float:
	if _terrain_gen == null:
		return NAN
	var ref_elev: float = _terrain_gen._compute_and_cache_deck_ref_elev(poly_idx)
	if is_nan(ref_elev):
		return NAN
	return _terrain_gen._deck_surface_y_at(point, poly, 1, ref_elev)


# ============================================================
# Standalone-bridge detection
# ============================================================

func _detect_standalone_bridges() -> void:
	var ways: Array = _osm_data.get("ways", [])
	var standalones: Array = []
	for way in ways:
		if not _is_drivable(way):
			continue
		var tags: Dictionary = way.get("tags", {})
		if tags.get("bridge", "") != "yes":
			continue
		var nodes: Array = way.get("nodes", [])
		if nodes.size() < 2:
			continue
		# Skip ways whose middle is already inside a polygon bridge — they
		# are on-deck and covered by polygon detection.
		if _is_way_inside_any_polygon(nodes):
			continue
		standalones.append(way)
	_stats["standalones_scanned"] = standalones.size()
	for way in standalones:
		var nodes: Array = way.get("nodes", [])
		var end_indices := [0, nodes.size() - 1]
		for end_idx in end_indices:
			var end_node: Dictionary = nodes[end_idx]
			var end_pos: Vector2 = _terrain_gen._latlon_to_local(end_node.lat, end_node.lon)
			var end_key: String = _coord_key(end_node.lat, end_node.lon)
			var shared: bool = _terrain_gen._bridge_endpoint_is_shared(end_node.lat, end_node.lon)
			if shared:
				var portal_s := BridgePortal.new()
				portal_s.pos = end_pos
				portal_s.node_coord_key = end_key
				portal_s.component_kind = "standalone"
				portal_s.component_ref = int(way.get("id", -1))
				portal_s.is_shared_abutment = true
				portal_s.target_y = _standalone_target_y(way, end_pos, true)
				if is_nan(portal_s.target_y):
					_stats["pending_target_y"] = int(_stats.get("pending_target_y", 0)) + 1
				_portals.append(portal_s)
				_stats["portals"] = int(_stats.get("portals", 0)) + 1
				_stats["shared_abutments"] = int(_stats.get("shared_abutments", 0)) + 1
				continue
			# Non-shared: connected non-bridge non-tunnel drivable continuations
			var others: Array = []
			for w in _node_to_ways.get(end_key, []):
				if int(w.get("id", -2)) == int(way.get("id", -1)):
					continue
				if not _is_drivable(w):
					continue
				var t: Dictionary = w.get("tags", {})
				if t.get("bridge", "") == "yes":
					continue
				if _is_tunnel(t):
					continue
				others.append(w)
			if others.is_empty():
				continue
			var portal := BridgePortal.new()
			portal.pos = end_pos
			portal.node_coord_key = end_key
			portal.component_kind = "standalone"
			portal.component_ref = int(way.get("id", -1))
			portal.is_shared_abutment = false
			portal.target_y = _standalone_target_y(way, end_pos, false)
			if is_nan(portal.target_y):
				_stats["pending_target_y"] = int(_stats.get("pending_target_y", 0)) + 1
			_portals.append(portal)
			_stats["portals"] = int(_stats.get("portals", 0)) + 1
			for w in others:
				var w_nodes: Array = w.get("nodes", [])
				var join_idx := -1
				for i in range(w_nodes.size()):
					var n2: Dictionary = w_nodes[i]
					if absf(n2.lat - end_node.lat) < COORD_EPS \
							and absf(n2.lon - end_node.lon) < COORD_EPS:
						join_idx = i
						break
				if join_idx < 0:
					continue
				var step := 0
				if join_idx == 0:
					step = 1
				elif join_idx == w_nodes.size() - 1:
					step = -1
				else:
					# Bridge attaches mid-way; that node has degree > 2.
					# Treat as no-ramp for Stage 1.
					continue
				var ramp := _walk_ramp(w, join_idx, step, portal)
				if ramp.total_length < SHORT_RAMP_LIMIT:
					_stats["skipped_short"] = int(_stats.get("skipped_short", 0)) + 1
					continue
				_compute_grade_diagnostic(ramp, portal)
				_ramps.append(ramp)
				_stats["ramps"] = int(_stats.get("ramps", 0)) + 1
				if ramp.steep_warning:
					_stats["steep_warnings"] = int(_stats.get("steep_warnings", 0)) + 1


func _standalone_target_y(way: Dictionary, endpoint_pos: Vector2, is_shared: bool) -> float:
	if _terrain_gen == null:
		return NAN
	if is_shared:
		# At a shared abutment the bridge mesh stays at deck_top all the way
		# to the endpoint (no in-mesh ramp on that side).
		var nodes: Array = way.get("nodes", [])
		if nodes.size() < 2:
			return NAN
		var s_local: Vector2 = _terrain_gen._latlon_to_local(nodes[0].lat, nodes[0].lon)
		var e_local: Vector2 = _terrain_gen._latlon_to_local(
				nodes[nodes.size() - 1].lat, nodes[nodes.size() - 1].lon)
		var elev_a: float = _terrain_gen._sample_elevation(s_local.x, s_local.y)
		var elev_b: float = _terrain_gen._sample_elevation(e_local.x, e_local.y)
		if elev_a == 0.0 and elev_b == 0.0:
			return NAN
		var ref_elev: float = maxf(elev_a, elev_b)
		return ref_elev + float(_terrain_gen.BRIDGE_DECK_HEIGHT)
	# Free endpoint: in-mesh 35 m ramp blends down to local terrain there.
	var local: float = _terrain_gen._sample_elevation(endpoint_pos.x, endpoint_pos.y)
	if local == 0.0:
		return NAN
	return local


func _is_way_inside_any_polygon(nodes: Array) -> bool:
	var polygons: Array = _terrain_gen._bridge_deck_polygons
	if polygons.is_empty() or nodes.size() < 2:
		return false
	var mid: Dictionary = nodes[nodes.size() / 2]
	var mid_local: Vector2 = _terrain_gen._latlon_to_local(mid.lat, mid.lon)
	for poly in polygons:
		if poly.size() >= 3 and Geometry2D.is_point_in_polygon(mid_local, poly):
			return true
	return false


# ============================================================
# Walk a ramp polyline outward from a portal
# ============================================================

func _walk_ramp(way: Dictionary, start_idx: int, step: int, portal: BridgePortal) -> ApproachRamp:
	var ramp := ApproachRamp.new()
	ramp.portal = portal
	ramp.first_way_id = int(way.get("id", -1))
	var start_nodes: Array = way.get("nodes", [])
	var start_node: Dictionary = start_nodes[start_idx]
	var start_local: Vector2 = _terrain_gen._latlon_to_local(start_node.lat, start_node.lon)
	ramp.polyline.append(start_local)
	ramp.cum_dist.append(0.0)
	var walked := 0.0
	var visited: Dictionary = {int(way.get("id", -1)): true}
	var prev_dir: Vector2 = Vector2.ZERO
	var cur_way: Dictionary = way
	var cur_idx: int = start_idx
	var iter_guard := 0
	# Stage 2A way-ownership tracking. Each segment we add is on `cur_way`.
	# We open a range entry when we first enter a way, close it when we
	# switch to a continuation. ramp.cum_dist[i] is the distance from portal
	# at the START of segment i (which becomes ramp.polyline[i] when added).
	var cur_way_id: int = ramp.first_way_id
	if not (cur_way_id in ramp.way_ids):
		ramp.way_ids.append(cur_way_id)
	var cur_range_d_start: float = 0.0
	# Cutting roads (cutting=yes layer=-1) emerging from a bridge polygon
	# represent the road descending into a cut on the other side of the
	# bridge. Standard 35 m ramp budget leaves the rest of the cut road at
	# terrain Y, visible as "asphalt on the ground" past the ramp end. For
	# such ways, walk the FULL way (no budget cap) and TERMINATE at way
	# edge — never continue into adjacent ways. This gives a smooth ramp
	# spanning the entire cut without pulling unrelated roads onto the
	# bridge level (which raising RAMP_BUDGET globally would do).
	var first_way_cutting: bool = (way.get("tags", {}) as Dictionary).get("cutting", "") == "yes"
	while (first_way_cutting or walked < RAMP_BUDGET) and iter_guard < 256:
		iter_guard += 1
		var next_idx := cur_idx + step
		var nodes: Array = cur_way.get("nodes", [])
		if next_idx < 0 or next_idx >= nodes.size():
			# End of way. For cutting=yes initial way, terminate here —
			# the cut continues at ground level past the way's end and we
			# must NOT pull adjacent roads onto the bridge ramp.
			if first_way_cutting:
				return _finalize_walk(ramp, cur_way_id, cur_range_d_start, walked, "cutting_edge")
			# Otherwise: try to continue across a single degree-2 link.
			var end_node: Dictionary = nodes[cur_idx]
			var end_key: String = _coord_key(end_node.lat, end_node.lon)
			var here: Array = _node_to_ways.get(end_key, [])
			var bridge_cont := false
			var tunnel_cont := false
			var continuations: Array = []
			for w in here:
				var wid := int(w.get("id", -2))
				if wid == int(cur_way.get("id", -1)) or visited.has(wid):
					continue
				if not _is_drivable(w):
					continue
				var t2: Dictionary = w.get("tags", {})
				if t2.get("bridge", "") == "yes":
					bridge_cont = true
					break
				if _is_tunnel(t2):
					tunnel_cont = true
					break
				continuations.append(w)
			if bridge_cont:
				return _finalize_walk(ramp, cur_way_id, cur_range_d_start, walked, "bridge")
			if tunnel_cont:
				return _finalize_walk(ramp, cur_way_id, cur_range_d_start, walked, "tunnel")
			if continuations.size() != 1:
				return _finalize_walk(ramp, cur_way_id, cur_range_d_start, walked, "intersection")
			var cont: Dictionary = continuations[0]
			var cnodes: Array = cont.get("nodes", [])
			var join_idx := -1
			for i in range(cnodes.size()):
				var cn: Dictionary = cnodes[i]
				if absf(cn.lat - end_node.lat) < COORD_EPS \
						and absf(cn.lon - end_node.lon) < COORD_EPS:
					join_idx = i
					break
			if join_idx < 0:
				return _finalize_walk(ramp, cur_way_id, cur_range_d_start, walked, "intersection")
			var new_step := 0
			if join_idx == 0:
				new_step = 1
			elif join_idx == cnodes.size() - 1:
				new_step = -1
			else:
				return _finalize_walk(ramp, cur_way_id, cur_range_d_start, walked, "intersection")
			# Close the range for the way we're leaving.
			_record_way_range(ramp, cur_way_id, cur_range_d_start, walked)
			cur_way = cont
			cur_idx = join_idx
			step = new_step
			cur_way_id = int(cur_way.get("id", -2))
			visited[cur_way_id] = true
			if not (cur_way_id in ramp.way_ids):
				ramp.way_ids.append(cur_way_id)
			cur_range_d_start = walked
			continue
		# Advance one segment.
		var a_node: Dictionary = nodes[cur_idx]
		var b_node: Dictionary = nodes[next_idx]
		var a_local: Vector2 = _terrain_gen._latlon_to_local(a_node.lat, a_node.lon)
		var b_local: Vector2 = _terrain_gen._latlon_to_local(b_node.lat, b_node.lon)
		var seg_len: float = a_local.distance_to(b_local)
		if seg_len < 0.001:
			cur_idx = next_idx
			continue
		var seg_dir: Vector2 = (b_local - a_local) / seg_len
		if prev_dir != Vector2.ZERO:
			var dot_prod: float = clampf(prev_dir.dot(seg_dir), -1.0, 1.0)
			if acos(dot_prod) > deg_to_rad(ANGLE_LIMIT_DEG):
				return _finalize_walk(ramp, cur_way_id, cur_range_d_start, walked, "angle")
		if not first_way_cutting and walked + seg_len > RAMP_BUDGET:
			var t3: float = (RAMP_BUDGET - walked) / seg_len
			ramp.polyline.append(a_local.lerp(b_local, t3))
			ramp.cum_dist.append(RAMP_BUDGET)
			return _finalize_walk(ramp, cur_way_id, cur_range_d_start, RAMP_BUDGET, "budget")
		ramp.polyline.append(b_local)
		walked += seg_len
		ramp.cum_dist.append(walked)
		# Check b: intersection / bridge / tunnel ahead?
		var b_key: String = _coord_key(b_node.lat, b_node.lon)
		var bridge_other := false
		var tunnel_other := false
		var others_count := 0
		for w in _node_to_ways.get(b_key, []):
			if int(w.get("id", -2)) == int(cur_way.get("id", -1)):
				continue
			if not _is_drivable(w):
				continue
			var t4: Dictionary = w.get("tags", {})
			if t4.get("bridge", "") == "yes":
				bridge_other = true
			if _is_tunnel(t4):
				tunnel_other = true
			others_count += 1
		if bridge_other:
			return _finalize_walk(ramp, cur_way_id, cur_range_d_start, walked, "bridge")
		if tunnel_other:
			return _finalize_walk(ramp, cur_way_id, cur_range_d_start, walked, "tunnel")
		var at_way_edge: bool = (next_idx == 0 or next_idx == nodes.size() - 1)
		if others_count > 0 and (not at_way_edge or others_count > 1):
			return _finalize_walk(ramp, cur_way_id, cur_range_d_start, walked, "intersection")
		prev_dir = seg_dir
		cur_idx = next_idx
	return _finalize_walk(ramp, cur_way_id, cur_range_d_start, walked, "budget")


# Closes the current way-range, sets terminator/total_length, returns ramp.
# Single exit point so we can't forget to record the final way range.
func _finalize_walk(ramp: ApproachRamp, cur_way_id: int, cur_range_d_start: float,
		walked: float, terminator: String) -> ApproachRamp:
	if ramp.terminator.is_empty():
		ramp.terminator = terminator
	ramp.total_length = walked
	_record_way_range(ramp, cur_way_id, cur_range_d_start, walked)
	return ramp


# Register a contiguous {ramp_d_start, ramp_d_end} interval for `way_id`.
# Empty/negative intervals discarded.
func _record_way_range(ramp: ApproachRamp, way_id: int, d_start: float, d_end: float) -> void:
	if d_end <= d_start + 0.001 or way_id < 0:
		return
	var arr: Array = ramp.way_ranges.get(way_id, [])
	arr.append({"ramp_d_start": d_start, "ramp_d_end": d_end})
	ramp.way_ranges[way_id] = arr


# ============================================================
# Diagnostics (read-only)
# ============================================================

func _compute_grade_diagnostic(ramp: ApproachRamp, portal: BridgePortal) -> void:
	if is_nan(portal.target_y) or ramp.polyline.size() < 2:
		ramp.grade = 0.0
		return
	var end_pos: Vector2 = ramp.polyline[ramp.polyline.size() - 1]
	var terrain_y: float = _terrain_gen._sample_elevation(end_pos.x, end_pos.y)
	ramp.terrain_y_at_end = terrain_y
	var delta: float = portal.target_y - terrain_y
	ramp.grade = absf(delta) / maxf(ramp.total_length, 0.001)
	ramp.steep_warning = ramp.grade > MAX_GRADE


# ============================================================
# Pending target_y refresh (waiting for elevation chunks)
# ============================================================

func _refresh_pending_target_ys() -> void:
	var still_pending := 0
	for portal in _portals:
		if not is_nan(portal.target_y):
			continue
		match portal.component_kind:
			"polygon":
				var poly_idx: int = int(portal.component_ref)
				var polygons: Array = _terrain_gen._bridge_deck_polygons
				if poly_idx < 0 or poly_idx >= polygons.size():
					continue
				portal.target_y = _polygon_target_y(poly_idx, polygons[poly_idx], portal.pos)
			"standalone":
				var w: Dictionary = _find_way_by_id(int(portal.component_ref))
				if w.is_empty():
					continue
				portal.target_y = _standalone_target_y(w, portal.pos, portal.is_shared_abutment)
		if is_nan(portal.target_y):
			still_pending += 1
	_stats["pending_target_y"] = still_pending
	# Update ramp grade diagnostics where target_y just became valid.
	for ramp in _ramps:
		if is_nan(ramp.portal.target_y):
			continue
		if ramp.grade == 0.0 and not ramp.steep_warning:
			_compute_grade_diagnostic(ramp, ramp.portal)
	if _enabled and still_pending == 0:
		_redraw_overlay()


func _find_way_by_id(way_id: int) -> Dictionary:
	for way in _osm_data.get("ways", []):
		if int(way.get("id", -1)) == way_id:
			return way
	return {}


# ============================================================
# Helpers
# ============================================================

func _polygon_aabb(poly: PackedVector2Array) -> Rect2:
	var minp: Vector2 = poly[0]
	var maxp: Vector2 = poly[0]
	for p in poly:
		minp.x = minf(minp.x, p.x)
		minp.y = minf(minp.y, p.y)
		maxp.x = maxf(maxp.x, p.x)
		maxp.y = maxf(maxp.y, p.y)
	return Rect2(minp, maxp - minp)


func _parse_layer(tags: Dictionary) -> int:
	var s: String = str(tags.get("layer", "0"))
	if s.is_valid_int():
		return int(s)
	return 0


func _reset_stats() -> void:
	_stats = {
		"polygons_scanned": 0,
		"standalones_scanned": 0,
		"portals": 0,
		"ramps": 0,
		"shared_abutments": 0,
		"skipped_short": 0,
		"steep_warnings": 0,
		"pending_target_y": 0,
	}


# ============================================================
# Logging
# ============================================================

func _log_summary() -> void:
	# Suppress duplicate output: print only when the summary changed since
	# last detection. Prevents log spam when chunk loads keep arriving.
	var summary: String = "polys=%d std=%d portals=%d shared=%d ramps=%d skipped=%d steep=%d pending=%d" \
			% [int(_stats.get("polygons_scanned", 0)),
				int(_stats.get("standalones_scanned", 0)),
				int(_stats.get("portals", 0)),
				int(_stats.get("shared_abutments", 0)),
				int(_stats.get("ramps", 0)),
				int(_stats.get("skipped_short", 0)),
				int(_stats.get("steep_warnings", 0)),
				int(_stats.get("pending_target_y", 0))]
	if summary == _last_summary:
		return
	_last_summary = summary
	print("[BridgeRamp] Detection complete")
	print("  polygons scanned:    %d" % int(_stats.get("polygons_scanned", 0)))
	print("  standalones scanned: %d" % int(_stats.get("standalones_scanned", 0)))
	print("  portals:             %d (shared abutments: %d)"
			% [int(_stats.get("portals", 0)), int(_stats.get("shared_abutments", 0))])
	print("  ramps:               %d" % int(_stats.get("ramps", 0)))
	print("  skipped (<%.1f m):   %d" % [SHORT_RAMP_LIMIT, int(_stats.get("skipped_short", 0))])
	print("  steep warnings (>%d%%): %d"
			% [int(MAX_GRADE * 100.0), int(_stats.get("steep_warnings", 0))])
	if int(_stats.get("pending_target_y", 0)) > 0:
		print("  pending target_y (elev not yet loaded): %d"
				% int(_stats.get("pending_target_y", 0)))
	# Per-ramp diagnostic: show which ways are registered to each ramp.
	for ramp_id in range(_ramps.size()):
		var ramp_dbg: ApproachRamp = _ramps[ramp_id]
		print("  ramp[%d] first_way=%d total_len=%.1fm term=%s way_ids=%s grade=%.0f%%"
				% [ramp_id, ramp_dbg.first_way_id, ramp_dbg.total_length,
					ramp_dbg.terminator, str(ramp_dbg.way_ids), ramp_dbg.grade * 100.0])
	# Per-ramp detail for steep warnings — helps map back to OSM ways.
	for ramp in _ramps:
		if not ramp.steep_warning:
			continue
		var ty_str: String = "NaN" if is_nan(ramp.portal.target_y) else "%.1f" % ramp.portal.target_y
		var te_str: String = "NaN" if is_nan(ramp.terrain_y_at_end) else "%.1f" % ramp.terrain_y_at_end
		print("  STEEP way=%d kind=%s ref=%s len=%.1fm target_y=%s terrain_end=%s grade=%.0f%% term=%s"
				% [ramp.first_way_id, ramp.portal.component_kind,
				str(ramp.portal.component_ref), ramp.total_length,
				ty_str, te_str, ramp.grade * 100.0, ramp.terminator])
	print("  Toggle overlay: F9 (or --bridge-ramp-debug / BRIDGE_RAMP_DEBUG)")


# ============================================================
# Overlay
# ============================================================

func _setup_overlay_nodes() -> void:
	_overlay_inst = MeshInstance3D.new()
	_overlay_inst.name = "RampOverlayMesh"
	_overlay_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_overlay_im = ImmediateMesh.new()
	_overlay_inst.mesh = _overlay_im
	_overlay_mat = StandardMaterial3D.new()
	_overlay_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_overlay_mat.vertex_color_use_as_albedo = true
	_overlay_mat.albedo_color = Color(1, 1, 1)
	_overlay_mat.no_depth_test = true
	_overlay_inst.material_override = _overlay_mat
	_overlay_inst.visible = _enabled
	add_child(_overlay_inst)
	_labels_root = Node3D.new()
	_labels_root.name = "RampOverlayLabels"
	_labels_root.visible = _enabled
	add_child(_labels_root)


func _update_overlay_visibility() -> void:
	if _overlay_inst:
		_overlay_inst.visible = _enabled
	if _labels_root:
		_labels_root.visible = _enabled


func _redraw_overlay() -> void:
	if _overlay_im == null:
		return
	_overlay_im.clear_surfaces()
	for child in _labels_root.get_children():
		child.queue_free()
	if not _enabled:
		return
	# ImmediateMesh refuses an empty surface, so guard zero-content frames.
	if _portals.is_empty() and _ramps.is_empty():
		return
	_overlay_im.surface_begin(Mesh.PRIMITIVE_LINES)
	for portal in _portals:
		_draw_portal_marker(portal)
	for ramp in _ramps:
		_draw_ramp_polyline(ramp)
	_draw_polygon_vertices_diag()
	_draw_road_endpoints_diag()
	_overlay_im.surface_end()
	for i in range(_portals.size()):
		_add_portal_label(_portals[i], i)
	for ramp in _ramps:
		_add_ramp_label(ramp)


func _draw_portal_marker(portal: BridgePortal) -> void:
	var y: float
	if is_nan(portal.target_y):
		y = _terrain_gen._sample_elevation(portal.pos.x, portal.pos.y) + 1.0
	else:
		y = portal.target_y + 0.5
	var center := Vector3(portal.pos.x, y, portal.pos.y)
	var col: Color = Color(1.0, 0.1, 0.1) if portal.is_shared_abutment else Color(1.0, 0.4, 0.4)
	_line(center + Vector3(0, -2.5, 0), center + Vector3(0, 2.5, 0), col)
	_line(center + Vector3(-1, 0, 0), center + Vector3(1, 0, 0), col)
	_line(center + Vector3(0, 0, -1), center + Vector3(0, 0, 1), col)


func _draw_ramp_polyline(ramp: ApproachRamp) -> void:
	var col: Color = TERMINATOR_COLORS.get(ramp.terminator, Color(0.7, 0.7, 0.7))
	if ramp.steep_warning:
		col = TERMINATOR_COLORS["slope_clamp"]
	var pts: PackedVector2Array = ramp.polyline
	if pts.size() < 2:
		return
	var prev := Vector3.ZERO
	var have_prev := false
	for i in range(pts.size()):
		var p: Vector2 = pts[i]
		var y: float
		if i == 0 and not is_nan(ramp.portal.target_y):
			y = ramp.portal.target_y + 0.4
		else:
			y = _terrain_gen._sample_elevation(p.x, p.y) + 0.4
		var v := Vector3(p.x, y, p.y)
		if have_prev:
			_line(prev, v, col)
		prev = v
		have_prev = true
	_draw_distance_ticks(ramp, col)


func _draw_distance_ticks(ramp: ApproachRamp, col: Color) -> void:
	var pts: PackedVector2Array = ramp.polyline
	var cums: PackedFloat32Array = ramp.cum_dist
	if pts.size() < 2:
		return
	var next_tick := 5.0
	var i := 0
	while next_tick < ramp.total_length and i < pts.size() - 1:
		while i < pts.size() - 1 and cums[i + 1] < next_tick:
			i += 1
		if i >= pts.size() - 1:
			break
		var seg_a: Vector2 = pts[i]
		var seg_b: Vector2 = pts[i + 1]
		var span: float = maxf(0.001, cums[i + 1] - cums[i])
		var seg_t: float = (next_tick - cums[i]) / span
		var tick_xy: Vector2 = seg_a.lerp(seg_b, seg_t)
		var dir: Vector2 = (seg_b - seg_a).normalized()
		var perp := Vector2(-dir.y, dir.x)
		var y: float = _terrain_gen._sample_elevation(tick_xy.x, tick_xy.y) + 0.4
		var center := Vector3(tick_xy.x, y, tick_xy.y)
		var off := Vector3(perp.x * 0.7, 0, perp.y * 0.7)
		_line(center - off, center + off, col)
		next_tick += 5.0


# Diagnostic: cyan crosses at every polygon outline vertex (so we can SEE
# where bridge mesh's outline is in 3D world space).
func _draw_polygon_vertices_diag() -> void:
	if _terrain_gen == null:
		return
	var polygons: Array = _terrain_gen._bridge_deck_polygons
	for i in range(polygons.size()):
		var poly: PackedVector2Array = polygons[i]
		if poly.size() < 3:
			continue
		var ref_elev: float = _terrain_gen._deck_polygon_ref_elev.get(i, NAN)
		if is_nan(ref_elev):
			continue
		var deck_top: float = ref_elev + float(_terrain_gen.BRIDGE_DECK_HEIGHT)
		var col := Color(0.0, 1.0, 1.0)  # cyan
		for j in range(poly.size()):
			var v: Vector2 = poly[j]
			var c := Vector3(v.x, deck_top + 0.4, v.y)
			_line(c + Vector3(-0.7, 0, 0), c + Vector3(0.7, 0, 0), col)
			_line(c + Vector3(0, 0, -0.7), c + Vector3(0, 0, 0.7), col)
			_line(c + Vector3(0, -1.5, 0), c + Vector3(0, 1.5, 0), col)


# Diagnostic: magenta crosses at every recorded road first/last vertex
# (after all worker-thread processing) + yellow line between them and the
# nearest polygon vertex (visualises the gap, if any).
func _draw_road_endpoints_diag() -> void:
	if _terrain_gen == null:
		return
	var polygons: Array = _terrain_gen._bridge_deck_polygons
	for key in _road_endpoints_log.keys():
		var ep: Dictionary = _road_endpoints_log[key]
		var first: Vector2 = ep["first"]
		var last: Vector2 = ep["last"]
		_draw_endpoint_diag(first, polygons, Color(1.0, 0.0, 1.0))     # magenta
		_draw_endpoint_diag(last, polygons, Color(1.0, 0.5, 1.0))      # pink (last)


func _draw_endpoint_diag(endpoint: Vector2, polygons: Array, col: Color) -> void:
	# Draw at the EXACT Y the road sampler returns at this XZ. This shows
	# the marker at the same height as the actual road mesh vertex, so the
	# marker AND polygon vertex (drawn at deck Y) are visible together.
	var terrain_y: float = _terrain_gen._sample_elevation(endpoint.x, endpoint.y)
	var sampled: float = sample_road_y_for_way(0, endpoint, 0.0, terrain_y, 0.0)
	# sample_road_y_for_way with way_id=0 returns terrain_y. Need real way_id.
	# Fallback: compute deck Y for any nearby polygon.
	var y: float = terrain_y + 0.4
	for i in range(polygons.size()):
		var poly: PackedVector2Array = polygons[i]
		if poly.size() < 3:
			continue
		var ref_elev: float = _terrain_gen._deck_polygon_ref_elev.get(i, NAN)
		if is_nan(ref_elev):
			continue
		# Use deck Y if inside polygon OR within 5 m of outline (matches
		# Stage 2A.3 sampler gate).
		if Geometry2D.is_point_in_polygon(endpoint, poly):
			y = ref_elev + float(_terrain_gen.BRIDGE_DECK_HEIGHT) + 0.4
			break
		var dist: float = _min_dist_to_polygon_outline(endpoint, poly)
		if dist < 5.0:
			y = ref_elev + float(_terrain_gen.BRIDGE_DECK_HEIGHT) + 0.4
			break
	var c := Vector3(endpoint.x, y, endpoint.y)
	_line(c + Vector3(-0.7, 0, 0), c + Vector3(0.7, 0, 0), col)
	_line(c + Vector3(0, 0, -0.7), c + Vector3(0, 0, 0.7), col)
	_line(c + Vector3(0, -2.5, 0), c + Vector3(0, 2.5, 0), col)
	# Yellow line from this endpoint to NEAREST polygon vertex (gap visualisation)
	var best_v: Vector2 = Vector2.INF
	var best_dist: float = INF
	for poly in polygons:
		if poly.size() < 3:
			continue
		for v in poly:
			var d: float = (v as Vector2).distance_to(endpoint)
			if d < best_dist:
				best_dist = d
				best_v = v
	if best_v != Vector2.INF and best_dist < 30.0:
		# Draw yellow line at SAME deck Y level — visible at deck altitude
		# next to bridge mesh edge for direct gap visualisation.
		var b := Vector3(best_v.x, y, best_v.y)
		_line(c, b, Color(1.0, 1.0, 0.0))  # yellow gap line


func _line(a: Vector3, b: Vector3, c: Color) -> void:
	_overlay_im.surface_set_color(c)
	_overlay_im.surface_add_vertex(a)
	_overlay_im.surface_set_color(c)
	_overlay_im.surface_add_vertex(b)


func _add_portal_label(portal: BridgePortal, idx: int) -> void:
	var lbl := Label3D.new()
	var ty_str: String = "?" if is_nan(portal.target_y) else "%.1f" % portal.target_y
	var kind_short: String = "POLY" if portal.component_kind == "polygon" else "STD"
	var shared: String = " SHARED" if portal.is_shared_abutment else ""
	lbl.text = "P%d %s%s\nty=%s\nref=%s" % [idx, kind_short, shared, ty_str, str(portal.component_ref)]
	lbl.font_size = 24
	lbl.outline_size = 8
	lbl.modulate = Color(1, 1, 1)
	lbl.outline_modulate = Color(0, 0, 0, 0.85)
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.no_depth_test = true
	var y: float
	if is_nan(portal.target_y):
		y = _terrain_gen._sample_elevation(portal.pos.x, portal.pos.y)
	else:
		y = portal.target_y
	lbl.position = Vector3(portal.pos.x, y + 4.0, portal.pos.y)
	_labels_root.add_child(lbl)


func _add_ramp_label(ramp: ApproachRamp) -> void:
	var pts: PackedVector2Array = ramp.polyline
	if pts.is_empty():
		return
	var mid_idx: int = pts.size() / 2
	var mid: Vector2 = pts[mid_idx]
	var grade_pct: float = ramp.grade * 100.0
	var lbl := Label3D.new()
	var warn: String = " STEEP" if ramp.steep_warning else ""
	lbl.text = "L=%.1fm  %s%s\ngrade=%.1f%%" % [ramp.total_length, ramp.terminator, warn, grade_pct]
	lbl.font_size = 18
	lbl.outline_size = 6
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.no_depth_test = true
	var col: Color = TERMINATOR_COLORS.get(ramp.terminator, Color(1, 1, 1))
	if ramp.steep_warning:
		col = TERMINATOR_COLORS["slope_clamp"]
	lbl.modulate = col
	lbl.outline_modulate = Color(0, 0, 0, 0.85)
	var y: float = _terrain_gen._sample_elevation(mid.x, mid.y) + 2.0
	lbl.position = Vector3(mid.x, y, mid.y)
	_labels_root.add_child(lbl)
