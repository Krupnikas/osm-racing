extends PanelContainer

## "СЛЕДУЮЩИЙ ПОВОРОТ" card. Left side: chevron + caption + bold turn
## label ("ПРАВО · СРЕДНИЙ"). Right side: distance to the upcoming
## corner as two labels — big red value + small dim unit, baseline aligned
## (RussoOne block + smaller "М").

const RUSSO := preload("res://ui/fonts/RussoOne-Regular.ttf")
const JBMONO := preload("res://ui/fonts/jbmono_regular.tres")
const JBMONO_WIDE := preload("res://ui/fonts/jbmono_wide.tres")

var is_night: bool = false

@onready var _caption: Label = $HBox/Left/Caption
@onready var _turn_label: Label = $HBox/Left/TurnLabel
@onready var _chevron: Label = $HBox/Chevron
@onready var _dist_value: Label = $HBox/Distance/Value
@onready var _dist_unit: Label = $HBox/Distance/Unit


func _ready() -> void:
	_apply_theme()


func set_night(enabled: bool) -> void:
	if is_night == enabled:
		return
	is_night = enabled
	_apply_theme()


# direction: "left" | "right" | "straight"
# severity: "sharp" | "medium" | "easy"
# distance_m: integer meters to the turn (rounded)
func set_turn(direction: String, severity: String, distance_m: int) -> void:
	var arrow := "▶"
	if direction == "left":
		arrow = "◀"
	elif direction == "straight":
		arrow = "▲"
	_chevron.text = arrow
	var dir_text := "ПРЯМО"
	if direction == "left":
		dir_text = "ЛЕВО"
	elif direction == "right":
		dir_text = "ПРАВО"
	var sev_text := "СРЕДНИЙ"
	if severity == "sharp":
		sev_text = "ОСТРЫЙ"
	elif severity == "easy":
		sev_text = "ПОЛОГИЙ"
	_turn_label.text = "%s · %s" % [dir_text, sev_text]
	_dist_value.text = "%d" % distance_m


func _color_bg() -> Color:
	return Color(0.078, 0.067, 0.055, 0.58) if is_night else Color(0.957, 0.925, 0.831, 0.58)
func _color_border() -> Color:
	return Color(1.0, 0.706, 0.314, 0.18) if is_night else Color(0.235, 0.157, 0.078, 0.30)
func _color_ink() -> Color:
	return Color("#ffd17a") if is_night else Color("#1c1612")
func _color_ink_dim() -> Color:
	return Color(0.953, 0.847, 0.640, 0.55) if is_night else Color(0.110, 0.086, 0.071, 0.55)
func _color_red() -> Color:
	return Color("#ff6b5a") if is_night else Color("#b3251e")


func _apply_theme() -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = _color_bg()
	sb.border_color = _color_border()
	sb.set_border_width_all(1)
	sb.border_width_left = 3
	sb.border_color = _color_red()
	sb.content_margin_left = 11
	sb.content_margin_right = 14
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	add_theme_stylebox_override("panel", sb)
	if _chevron == null:
		return
	_chevron.add_theme_font_override("font", RUSSO)
	_chevron.add_theme_font_size_override("font_size", 22)
	_chevron.add_theme_color_override("font_color", _color_red())
	_caption.add_theme_font_override("font", JBMONO_WIDE)
	_caption.add_theme_font_size_override("font_size", 10)
	_caption.add_theme_color_override("font_color", _color_ink_dim())
	# "ПРАВО · СРЕДНИЙ" wants RussoOne block letters per the design — the
	# old GolosText-Bold here read too rounded / casual.
	_turn_label.add_theme_font_override("font", RUSSO)
	_turn_label.add_theme_font_size_override("font_size", 14)
	_turn_label.add_theme_color_override("font_color", _color_ink())
	# Distance is split into value + unit. Value is the same RussoOne
	# block family as ПРОМЗОНА ЮЖНАЯ above (red). Unit "М" uses the same
	# wide-tracked JBMono small caps as the СЛЕДУЮЩИЙ ПОВОРОТ caption,
	# at exactly half the value's font size, dimmer ink, baseline-aligned.
	_dist_value.add_theme_font_override("font", RUSSO)
	_dist_value.add_theme_font_size_override("font_size", 26)
	_dist_value.add_theme_color_override("font_color", _color_red())
	_dist_unit.add_theme_font_override("font", JBMONO_WIDE)
	_dist_unit.add_theme_font_size_override("font_size", 13)
	_dist_unit.add_theme_color_override("font_color", _color_ink_dim())
	_align_distance_baseline()


func _align_distance_baseline() -> void:
	# Wait one frame so the font/size overrides set above are reflected
	# in `get_minimum_size()`, then position the labels manually so the
	# small "М" sits on the same baseline as the bottom of "240".
	await get_tree().process_frame
	if not is_inside_tree() or _dist_value == null:
		return
	var v_font: Font = _dist_value.get_theme_font("font")
	var u_font: Font = _dist_unit.get_theme_font("font")
	var v_ascent: float = v_font.get_ascent(26)
	var u_ascent: float = u_font.get_ascent(13)
	_dist_value.position = Vector2(0, 0)
	_dist_value.size = _dist_value.get_minimum_size()
	_dist_unit.position = Vector2(_dist_value.size.x + 2.0, v_ascent - u_ascent)
	_dist_unit.size = _dist_unit.get_minimum_size()
	# Resize the parent Control to fit value + unit so HBoxContainer
	# layout knows how wide the distance group is.
	var parent_ctrl: Control = _dist_value.get_parent()
	if parent_ctrl:
		parent_ctrl.custom_minimum_size = Vector2(
			_dist_unit.position.x + _dist_unit.size.x,
			max(_dist_value.size.y, _dist_unit.position.y + _dist_unit.size.y))
