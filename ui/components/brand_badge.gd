# BrandBadge — slashed-pentagon ЖС badge.
# Outer pentagon: clipPath(0 0, 100% 0, 100% 70%, 70% 100%, 0 100%) — bottom-right cut.
# Inner pentagon: 3px inset, hosts the "ЖС" letters.
@tool
extends Control
class_name BrandBadge

@export var outer_color: Color = Color(0, 0.906, 1, 1)
@export var inner_color: Color = Color(0.024, 0.031, 0.047, 1)
@export var inset: float = 3.0


func _draw() -> void:
	var w := size.x
	var h := size.y
	if w <= 0.0 or h <= 0.0:
		return

	var outer := PackedVector2Array([
		Vector2(0, 0),
		Vector2(w, 0),
		Vector2(w, h * 0.7),
		Vector2(w * 0.7, h),
		Vector2(0, h),
	])
	draw_colored_polygon(outer, outer_color)

	var i := inset
	var sw := w - 2.0 * i
	var sh := h - 2.0 * i
	var inner := PackedVector2Array([
		Vector2(i, i),
		Vector2(i + sw, i),
		Vector2(i + sw, i + sh * 0.7),
		Vector2(i + sw * 0.7, i + sh),
		Vector2(i, i + sh),
	])
	draw_colored_polygon(inner, inner_color)
