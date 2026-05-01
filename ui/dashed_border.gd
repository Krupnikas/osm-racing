# Draws a dashed rectangular border filling its rect.
# Place as a full-rect child of a Container (mouse_filter=IGNORE).
@tool
extends Control
class_name DashedBorder

@export var color: Color = Color(0.768, 1.0, 0.18, 1.0) :
	set(v):
		color = v
		queue_redraw()

@export var dash_length: float = 8.0 :
	set(v):
		dash_length = v
		queue_redraw()

@export var gap_length: float = 5.0 :
	set(v):
		gap_length = v
		queue_redraw()

@export var line_width: float = 1.0 :
	set(v):
		line_width = v
		queue_redraw()


func _draw() -> void:
	var w := size.x
	var h := size.y
	if w <= 0.0 or h <= 0.0:
		return
	_dashed(Vector2(0, 0),     Vector2(w, 0))
	_dashed(Vector2(w, 0),     Vector2(w, h))
	_dashed(Vector2(w, h),     Vector2(0, h))
	_dashed(Vector2(0, h),     Vector2(0, 0))


func _dashed(a: Vector2, b: Vector2) -> void:
	var total := a.distance_to(b)
	if total <= 0.0:
		return
	var dir := (b - a) / total
	var t := 0.0
	while t < total:
		var seg_end: float = min(t + dash_length, total)
		draw_line(a + dir * t, a + dir * seg_end, color, line_width, false)
		t = seg_end + gap_length
