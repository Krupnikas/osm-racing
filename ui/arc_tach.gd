# Custom-drawn arc tachometer. Drop on a Control sized ~360×360. Call set_rpm() per frame.
@tool
extends Control
class_name ArcTach

@export_range(0.0, 12000.0) var rpm     : float = 5400.0 : set = _set_rpm
@export var max_rpm     : float = 9000.0
@export var redline_rpm : float = 7500.0
@export var tick_count  : int   = 60
@export var arc_color_active   : Color = Color("#00E7FF")
@export var arc_color_redline  : Color = Color("#FF3050")
@export var arc_color_inactive : Color = Color("#3A4456")
@export var label_color        : Color = Color("#A4ADBE")
@export var label_redline      : Color = Color("#FF3050")

const START_DEG : float = 135.0
const END_DEG   : float = 405.0

func _set_rpm(v: float) -> void:
	rpm = clamp(v, 0.0, max_rpm)
	queue_redraw()

func set_rpm(r: float, mx: float = -1.0, red: float = -1.0) -> void:
	if mx > 0: max_rpm = mx
	if red > 0: redline_rpm = red
	_set_rpm(r)

func _draw() -> void:
	var sz := size.x
	var center := Vector2(sz * 0.5, sz * 0.5)
	var radius := sz * 0.5 - 22.0
	var range_deg := END_DEG - START_DEG
	var val_deg   := START_DEG + (rpm / max_rpm) * range_deg
	var red_deg   := START_DEG + (redline_rpm / max_rpm) * range_deg

	for i in range(tick_count + 1):
		var t := float(i) / float(tick_count)
		var deg := START_DEG + t * range_deg
		var rad := deg_to_rad(deg)
		var is_major := i % 6 == 0
		var inner_off := 28.0 if is_major else 14.0
		var p1 := center + Vector2(cos(rad), sin(rad)) * (radius - inner_off)
		var p2 := center + Vector2(cos(rad), sin(rad)) * radius
		var on_arc := deg <= val_deg
		var in_red := deg >= red_deg
		var c : Color
		if in_red: c = arc_color_redline
		elif on_arc: c = arc_color_active
		else: c = arc_color_inactive
		var w : float = 3.0 if is_major else 1.5
		draw_line(p1, p2, c, w, true)

	var f := get_theme_default_font()
	if f:
		for i in range(10):
			var t := float(i) / 9.0
			var deg := START_DEG + t * range_deg
			var rad := deg_to_rad(deg)
			var p := center + Vector2(cos(rad), sin(rad)) * (radius - 50.0)
			var col := label_redline if i >= 7 else label_color
			var s := str(i)
			var ts := f.get_string_size(s, HORIZONTAL_ALIGNMENT_CENTER, -1, 14)
			draw_string(f, p - ts * 0.5 + Vector2(0, ts.y * 0.35), s,
				HORIZONTAL_ALIGNMENT_CENTER, -1, 14, col)
