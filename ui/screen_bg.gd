# Full-rect screen background per design system: ink gradient + neon
# radial glows. Use as a backdrop for non-menu screens (Garage, World Map,
# Race Menu, Pause overlay).
@tool
extends ColorRect
class_name ScreenBg

const SHADER = preload("res://ui/screen_bg.gdshader")


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	color = Color(0, 0, 0, 1)
	if material == null:
		var mat := ShaderMaterial.new()
		mat.shader = SHADER
		material = mat
