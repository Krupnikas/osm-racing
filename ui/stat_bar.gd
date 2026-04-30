# Segmented horizontal stat bar (10 cells by default).
# Use: var bar := StatBar.new(); add_child(bar); bar.label_text = "СКОРОСТЬ"; bar.value = 7
@tool
extends HBoxContainer
class_name StatBar

@export var label_text : String = "УСКОРЕНИЕ" :
	set(v):
		label_text = v
		if _label: _label.text = v
@export_range(0, 10) var value : int = 6 :
	set(v):
		value = clamp(v, 0, max_value)
		_repaint()
@export var max_value : int = 10
@export var fill_color   : Color = Color("#C4FF2E")
@export var track_color  : Color = Color("#232A39")
@export var bg_color     : Color = Color("#11151D")
@export var label_color  : Color = Color("#A4ADBE")

var _label : Label
var _segs  : Array[ColorRect] = []
var _num   : Label

func _ready() -> void:
	add_theme_constant_override("separation", 14)

	_label = Label.new()
	_label.text = label_text
	_label.modulate = label_color
	_label.custom_minimum_size = Vector2(130, 0)
	_label.theme_type_variation = "MonoLabel"
	add_child(_label)

	var track := HBoxContainer.new()
	track.add_theme_constant_override("separation", 2)
	track.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg_color
	sb.border_width_left = 1; sb.border_width_right = 1
	sb.border_width_top = 1; sb.border_width_bottom = 1
	sb.border_color = track_color
	sb.content_margin_left = 2; sb.content_margin_right = 2
	sb.content_margin_top = 2;  sb.content_margin_bottom = 2
	panel.add_theme_stylebox_override("panel", sb)
	panel.add_child(track)
	add_child(panel)

	_segs.clear()
	for i in range(max_value):
		var s := ColorRect.new()
		s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		s.custom_minimum_size = Vector2(0, 14)
		track.add_child(s)
		_segs.append(s)

	_num = Label.new()
	_num.custom_minimum_size = Vector2(40, 0)
	_num.theme_type_variation = "MonoLabel"
	_num.modulate = fill_color
	_num.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(_num)

	_repaint()

func _repaint() -> void:
	if _segs.is_empty(): return
	for i in range(_segs.size()):
		_segs[i].color = fill_color if i < value else track_color
	if _num: _num.text = "%02d" % value

func set_value(v: int) -> void:
	value = v
