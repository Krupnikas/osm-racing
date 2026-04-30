# Custom StyleBox: sheared parallelogram + neon outline + soft halo.
# Use on Buttons/Panels for the "underground" look without HDR glow.
@tool
extends StyleBox
class_name NeonStyleBox

@export var fill_color      : Color = Color("#11151D")
@export var outline_color   : Color = Color("#00E7FF")
@export var outline_width   : float = 1.0
@export var shear_deg       : float = -12.0
@export var glow_color      : Color = Color(0.0, 0.91, 1.0, 0.55)
@export var glow_size       : int   = 18
@export var slashed         : bool  = false
@export var slash_size      : float = 18.0

func _draw(to_canvas_item: RID, rect: Rect2) -> void:
	var ci := to_canvas_item
	var x := rect.position.x
	var y := rect.position.y
	var w := rect.size.x
	var h := rect.size.y
	var dx := h * tan(deg_to_rad(shear_deg))

	var pts : PackedVector2Array
	if slashed:
		pts = PackedVector2Array([
			Vector2(x - dx,                  y),
			Vector2(x + w - dx - slash_size, y),
			Vector2(x + w - dx,              y + slash_size),
			Vector2(x + w,                   y + h - slash_size),
			Vector2(x + w - slash_size,      y + h),
			Vector2(x + slash_size,          y + h),
			Vector2(x,                       y + h),
		])
	else:
		pts = PackedVector2Array([
			Vector2(x - dx,     y),
			Vector2(x + w - dx, y),
			Vector2(x + w,      y + h),
			Vector2(x,          y + h),
		])

	if glow_size > 0:
		for i in range(glow_size, 0, -2):
			var a := glow_color.a * (1.0 - float(i) / float(glow_size))
			var c := Color(glow_color.r, glow_color.g, glow_color.b, a * 0.18)
			RenderingServer.canvas_item_add_polygon(ci, _inflate(pts, float(i)), [c])

	RenderingServer.canvas_item_add_polygon(ci, pts, [fill_color])

	var loop := pts.duplicate()
	loop.append(pts[0])
	for i in range(loop.size() - 1):
		RenderingServer.canvas_item_add_line(ci, loop[i], loop[i+1], outline_color, outline_width, true)


func _inflate(poly: PackedVector2Array, by: float) -> PackedVector2Array:
	var c := Vector2.ZERO
	for p in poly: c += p
	c /= poly.size()
	var out := PackedVector2Array()
	for p in poly:
		var n := (p - c).normalized()
		out.append(p + n * by)
	return out


func _get_minimum_size() -> Vector2:
	return Vector2(8, 8)
