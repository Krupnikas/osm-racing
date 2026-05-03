# Renders an OSM-chunk JSON file (produced by tools/fetch_location_chunks.py)
# as a flat top-down map: cyan grid + roads + buildings + water + center pin.
@tool
extends Control
class_name OSMPreview

@export_file("*.json") var chunk_path: String = "" :
	set(v):
		chunk_path = v
		_data = {}
		queue_redraw()

@export var grid_color: Color = Color(0.0, 0.91, 1.0, 0.08)
@export var grid_step_m: float = 50.0
@export var road_color: Color = Color(0.0, 0.91, 1.0, 0.85)
@export var building_fill: Color = Color(0.0, 0.91, 1.0, 0.10)
@export var building_stroke: Color = Color(0.0, 0.91, 1.0, 0.45)
@export var water_color: Color = Color(0.0, 0.55, 1.0, 0.30)
@export var center_pin_color: Color = Color(1.0, 0.168, 0.815, 1.0)

var _data: Dictionary = {}


func _ready() -> void:
	if chunk_path != "":
		_load()


func set_chunk(path: String) -> void:
	chunk_path = path
	_data = {}
	_load()
	queue_redraw()


func _load() -> void:
	if chunk_path == "":
		_data = {}
		return
	if not FileAccess.file_exists(chunk_path):
		push_warning("OSMPreview: chunk file not found: " + chunk_path)
		print("[OSMPreview] file not found: ", chunk_path)
		_data = {}
		return
	var f := FileAccess.open(chunk_path, FileAccess.READ)
	if f == null:
		_data = {}
		return
	var txt := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(txt)
	if parsed is Dictionary:
		_data = parsed
		print("[OSMPreview] loaded ", chunk_path, " ways=", _data.get("ways", []).size())
	else:
		_data = {}


func _draw() -> void:
	if _data.is_empty():
		_load()
	var w := size.x
	var h := size.y
	if w <= 0.0 or h <= 0.0:
		return

	# Background — slightly different from card bg so the map reads.
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.024, 0.031, 0.047, 1.0))

	if _data.is_empty():
		return

	var center: Array = _data.get("center", [0, 0])
	var clat: float = float(center[0]) if center.size() > 0 else 0.0
	var clon: float = float(center[1]) if center.size() > 1 else 0.0
	var radius_m: float = float(_data.get("radius_m", 315.0))

	# Pixels per meter — preserve aspect ratio of the drawing area.
	var ppm: float = min(w, h) / (radius_m * 2.0)
	var lat_m_per_deg := 111000.0
	var lon_m_per_deg := 111000.0 * cos(deg_to_rad(clat))

	# Grid (every grid_step_m metres).
	var grid_px := grid_step_m * ppm
	if grid_px > 4.0:
		var x_off := fmod(w * 0.5, grid_px)
		var y_off := fmod(h * 0.5, grid_px)
		var x := x_off
		while x <= w:
			draw_line(Vector2(x, 0), Vector2(x, h), grid_color, 1.0, false)
			x += grid_px
		var y := y_off
		while y <= h:
			draw_line(Vector2(0, y), Vector2(w, y), grid_color, 1.0, false)
			y += grid_px

	var ways: Array = _data.get("ways", [])

	# Three passes so roads stay on top and buildings under them.
	# Water → buildings → roads.
	for way in ways:
		if way.get("kind") != "water":
			continue
		var poly := _project_points(way.get("pts", []), clat, clon,
			lat_m_per_deg, lon_m_per_deg, ppm, w, h)
		if poly.size() >= 3:
			draw_colored_polygon(poly, water_color)

	for way in ways:
		if way.get("kind") != "building":
			continue
		var poly := _project_points(way.get("pts", []), clat, clon,
			lat_m_per_deg, lon_m_per_deg, ppm, w, h)
		if poly.size() >= 3:
			draw_colored_polygon(poly, building_fill)
			draw_polyline(poly, building_stroke, 1.0, false)

	for way in ways:
		if way.get("kind") != "road":
			continue
		var line := _project_points(way.get("pts", []), clat, clon,
			lat_m_per_deg, lon_m_per_deg, ppm, w, h)
		if line.size() >= 2:
			var width := _road_width(way)
			draw_polyline(line, road_color, width, true)

	# Center pin — diamond.
	var c := Vector2(w * 0.5, h * 0.5)
	var r := 7.0
	var diamond := PackedVector2Array([
		c + Vector2(0, -r),
		c + Vector2(r, 0),
		c + Vector2(0, r),
		c + Vector2(-r, 0),
	])
	draw_colored_polygon(diamond, center_pin_color)
	draw_circle(c, r * 1.6, Color(center_pin_color.r, center_pin_color.g, center_pin_color.b, 0.18))


func _project_points(pts: Array, clat: float, clon: float,
		lat_m: float, lon_m: float, ppm: float,
		w: float, h: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(pts.size())
	var cx := w * 0.5
	var cy := h * 0.5
	for i in pts.size():
		var p = pts[i]
		var dy := (float(p[0]) - clat) * lat_m   # north positive
		var dx := (float(p[1]) - clon) * lon_m   # east positive
		out[i] = Vector2(cx + dx * ppm, cy - dy * ppm)
	return out


func _road_width(way: Dictionary) -> float:
	var hw: String = (way.get("tags", {}) as Dictionary).get("highway", "")
	match hw:
		"motorway", "trunk", "primary":
			return 2.5
		"secondary", "tertiary":
			return 1.8
		"residential", "unclassified", "living_street":
			return 1.2
		_:
			return 0.8
