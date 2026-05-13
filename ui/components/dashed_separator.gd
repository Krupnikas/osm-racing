extends Control

## Simple dashed horizontal separator. Renders one row of fixed-length
## dashes with gaps via `_draw()`. Used inside HUD cards where a
## divider strip is part of the visual design (pace-note paper style).

@export var dash_color: Color = Color(0.235, 0.157, 0.078, 0.35)
@export var dash_length: float = 4.0
@export var gap_length: float = 4.0
@export var thickness: float = 1.0


func _ready() -> void:
	custom_minimum_size = Vector2(0, max(2.0, thickness + 1.0))
	queue_redraw()


func set_color(c: Color) -> void:
	dash_color = c
	queue_redraw()


func _draw() -> void:
	var y: float = thickness * 0.5
	var x: float = 0.0
	var stride: float = dash_length + gap_length
	while x < size.x:
		var end_x: float = min(x + dash_length, size.x)
		draw_line(Vector2(x, y), Vector2(end_x, y), dash_color, thickness, false)
		x += stride
