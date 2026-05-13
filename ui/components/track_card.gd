extends PanelContainer

## "ТРАССА · ПРОМЗОНА · ЮЖНАЯ" card under the lap-time panel. Compact:
## label + name on the left, distance ("2.4 КМ") on the right.

const RUSSO := preload("res://ui/fonts/RussoOne-Regular.ttf")
const SHARETECH := preload("res://ui/fonts/ShareTechMono-Regular.ttf")
const JBMONO := preload("res://ui/fonts/jbmono_regular.tres")
const JBMONO_WIDE := preload("res://ui/fonts/jbmono_wide.tres")

var is_night: bool = false

@onready var _caption: Label = $HBox/Left/Caption
@onready var _name_label: Label = $HBox/Left/NameLabel
@onready var _distance: Label = $HBox/Distance


func _ready() -> void:
	_apply_theme()


func set_night(enabled: bool) -> void:
	if is_night == enabled:
		return
	is_night = enabled
	_apply_theme()


func set_track(name_text: String, distance_km: float) -> void:
	_name_label.text = name_text.to_upper()
	_distance.text = "%.1f КМ" % distance_km


func _color_bg() -> Color:
	# Matches HUD source — day rgba(232,222,194,.58); night rgba(26,22,18,.58).
	return Color(0.102, 0.086, 0.071, 0.58) if is_night else Color(0.910, 0.871, 0.761, 0.58)
func _color_border() -> Color:
	return Color(1.0, 0.706, 0.314, 0.18) if is_night else Color(0.235, 0.157, 0.078, 0.30)
func _color_ink() -> Color:
	return Color("#ffd17a") if is_night else Color("#1c1612")
func _color_ink_dim() -> Color:
	return Color(0.953, 0.847, 0.640, 0.55) if is_night else Color(0.110, 0.086, 0.071, 0.55)


func _apply_theme() -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = _color_bg()
	sb.border_color = _color_border()
	sb.set_border_width_all(1)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	add_theme_stylebox_override("panel", sb)
	if _caption == null:
		return
	_caption.add_theme_font_override("font", JBMONO_WIDE)
	_caption.add_theme_font_size_override("font_size", 10)
	_caption.add_theme_color_override("font_color", _color_ink_dim())
	_name_label.add_theme_font_override("font", RUSSO)
	_name_label.add_theme_font_size_override("font_size", 18)
	_name_label.add_theme_color_override("font_color", _color_ink())
	# Distance is the same ink as the name (BLACK / amber) per spec —
	# matches the pace-note design's "2.4 КМ" treatment.
	_distance.add_theme_font_override("font", SHARETECH)
	_distance.add_theme_font_size_override("font_size", 18)
	_distance.add_theme_color_override("font_color", _color_ink())
