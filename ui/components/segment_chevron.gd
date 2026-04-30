# Skewed parallelogram (chevron) segment. No halo — soft glow is provided
# externally (e.g. via a radial-glow ColorRect placed behind the chevron).
@tool
extends Control
class_name SegmentChevron

@export var fill_color: Color = Color(0, 0.906, 1, 1) :
	set(v):
		fill_color = v
		queue_redraw()

@export var skew_px: float = 8.0 :
	set(v):
		skew_px = v
		queue_redraw()


func _draw() -> void:
	var w := size.x
	var h := size.y
	if w <= 0.0 or h <= 0.0:
		return
	var s := skew_px
	var pts := PackedVector2Array([
		Vector2(s, 0),
		Vector2(w, 0),
		Vector2(w - s, h),
		Vector2(0, h),
	])
	draw_colored_polygon(pts, fill_color)
