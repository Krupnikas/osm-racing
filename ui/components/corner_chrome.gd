# Four L-shaped neon corner brackets. Drop as a full-rect Control with
# mouse_filter=IGNORE on top of menu content.
@tool
extends Control
class_name CornerChrome

@export var color: Color = Color(0, 0.906, 1, 1) :
	set(v):
		color = v
		queue_redraw()

@export var inset: float = 24.0 :
	set(v):
		inset = v
		queue_redraw()

@export var leg_length: float = 32.0 :
	set(v):
		leg_length = v
		queue_redraw()

@export var thickness: float = 2.0 :
	set(v):
		thickness = v
		queue_redraw()


func _draw() -> void:
	var w := size.x
	var h := size.y
	if w <= 0.0 or h <= 0.0:
		return
	var t := thickness
	var l := leg_length
	var i := inset

	# top-left
	draw_rect(Rect2(Vector2(i, i), Vector2(l, t)), color)
	draw_rect(Rect2(Vector2(i, i), Vector2(t, l)), color)

	# top-right
	draw_rect(Rect2(Vector2(w - i - l, i), Vector2(l, t)), color)
	draw_rect(Rect2(Vector2(w - i - t, i), Vector2(t, l)), color)

	# bottom-left
	draw_rect(Rect2(Vector2(i, h - i - t), Vector2(l, t)), color)
	draw_rect(Rect2(Vector2(i, h - i - l), Vector2(t, l)), color)

	# bottom-right
	draw_rect(Rect2(Vector2(w - i - l, h - i - t), Vector2(l, t)), color)
	draw_rect(Rect2(Vector2(w - i - t, h - i - l), Vector2(t, l)), color)
