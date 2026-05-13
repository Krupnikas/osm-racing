extends PanelContainer

## Top-left "Время круга" card — header label + CHRONO stamp, current lap
## NN/NN, big chronometer text with the milliseconds picked out in the
## accent colour, and a small delta line under it. Public API:
##   set_lap(current: int, total: int)
##   set_time(text: String)        # "01:08.347"
##   set_delta(seconds: float, label: String = "лучший круг")

const RUSSO := preload("res://ui/fonts/RussoOne-Regular.ttf")
const SHARETECH := preload("res://ui/fonts/ShareTechMono-Regular.ttf")
const JBMONO := preload("res://ui/fonts/jbmono_regular.tres")
const JBMONO_WIDE := preload("res://ui/fonts/jbmono_wide.tres")

var is_night: bool = false

@onready var _hdr_label: Label = $VBox/Header/Label
@onready var _chrono_holder: PanelContainer = $VBox/Header/ChronoHolder
@onready var _chrono_label: Label = $VBox/Header/ChronoHolder/ChronoLabel
@onready var _separator: Control = $VBox/Separator
@onready var _lap_caption: Label = $VBox/Caption
@onready var _lap_current: Label = $VBox/LapRow/Current
@onready var _lap_total: Label = $VBox/LapRow/Total
@onready var _time_main: Label = $VBox/Time/Main
@onready var _time_ms: Label = $VBox/Time/Ms
@onready var _delta_label: Label = $VBox/Delta


func _ready() -> void:
	print("[LapTimePanel] _ready hdr=%s russo=%s sharetech=%s jbmono=%s" % [
		str(_hdr_label != null), str(RUSSO != null), str(SHARETECH != null), str(JBMONO != null)])
	_apply_theme()
	set_time("00:00.000")
	set_lap(1, 1)
	set_delta(NAN, "")
	# Diagnostic: was the font actually attached to the label?
	var f = _hdr_label.get_theme_font("font") if _hdr_label else null
	print("[LapTimePanel] hdr_label.theme_font=%s class=%s" % [str(f), f.get_class() if f else "null"])


func set_night(enabled: bool) -> void:
	if is_night == enabled:
		return
	is_night = enabled
	_apply_theme()


func set_lap(current: int, total: int) -> void:
	_lap_current.text = "%02d" % current
	_lap_total.text = "/%02d" % total


# Splits "MM:SS.mmm" so the milliseconds are tinted with the accent color.
func set_time(text: String) -> void:
	var dot := text.find(".")
	if dot < 0:
		_time_main.text = text
		_time_ms.text = ""
		return
	_time_main.text = text.substr(0, dot + 1)
	_time_ms.text = text.substr(dot + 1)


# `seconds` < 0 = ahead of best (green), > 0 = behind (red).
# Pass NAN to hide the row.
func set_delta(seconds: float, label: String = "лучший круг") -> void:
	if is_nan(seconds):
		_delta_label.visible = false
		return
	_delta_label.visible = true
	var arrow := "▼" if seconds <= 0.0 else "▲"
	var sign := "−" if seconds <= 0.0 else "+"
	var abs_s := absf(seconds)
	_delta_label.text = "%s %s%05.3f · %s" % [arrow, sign, abs_s, label]
	var col := _color_green() if seconds <= 0.0 else _color_red()
	_delta_label.add_theme_color_override("font_color", col)


func _color_bg() -> Color:
	# Matches HUD HTML source: day rgba(244,236,212,.58); night rgba(20,17,14,.58).
	return Color(0.078, 0.067, 0.055, 0.58) if is_night else Color(0.957, 0.925, 0.831, 0.58)
func _color_border() -> Color:
	return Color(1.0, 0.706, 0.314, 0.18) if is_night else Color(0.235, 0.157, 0.078, 0.30)
func _color_ink() -> Color:
	return Color("#ffd17a") if is_night else Color("#1c1612")
func _color_ink_dim() -> Color:
	return Color(0.953, 0.847, 0.640, 0.55) if is_night else Color(0.110, 0.086, 0.071, 0.55)
func _color_red() -> Color:
	return Color("#ff6b5a") if is_night else Color("#b3251e")
func _color_green() -> Color:
	return Color("#9ddc7a") if is_night else Color("#3f8a1e")


func _apply_theme() -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = _color_bg()
	sb.border_color = _color_border()
	sb.set_border_width_all(1)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	add_theme_stylebox_override("panel", sb)

	if _hdr_label == null:
		return

	# Header caption uses the wide-spaced JBMono variant — the design
	# wants visibly tracked-out small caps (CSS letter-spacing 0.22em).
	_hdr_label.add_theme_font_override("font", JBMONO_WIDE)
	_hdr_label.add_theme_font_size_override("font_size", 11)
	_hdr_label.add_theme_color_override("font_color", _color_ink_dim())

	# CHRONO stamp panel — slightly tracked, rotated CCW, red 1.5px border.
	var stamp_sb := StyleBoxFlat.new()
	stamp_sb.bg_color = Color(0, 0, 0, 0)
	stamp_sb.border_color = _color_red()
	stamp_sb.border_width_left = 2
	stamp_sb.border_width_right = 2
	stamp_sb.border_width_top = 2
	stamp_sb.border_width_bottom = 2
	stamp_sb.content_margin_left = 8
	stamp_sb.content_margin_right = 8
	stamp_sb.content_margin_top = 1
	stamp_sb.content_margin_bottom = 1
	_chrono_holder.add_theme_stylebox_override("panel", stamp_sb)
	# CCW rotation per design (against clock when viewed top-down).
	_chrono_holder.rotation = deg_to_rad(-2.0)
	_chrono_holder.pivot_offset = _chrono_holder.size * 0.5

	# Sync the dashed separator colour with the theme.
	if _separator and _separator.has_method("set_color"):
		_separator.set_color(_color_border())
	_chrono_label.add_theme_font_override("font", RUSSO)
	_chrono_label.add_theme_font_size_override("font_size", 11)
	_chrono_label.add_theme_color_override("font_color", _color_red())

	_lap_caption.add_theme_font_override("font", JBMONO_WIDE)
	_lap_caption.add_theme_font_size_override("font_size", 10)
	_lap_caption.add_theme_color_override("font_color", _color_ink_dim())

	_lap_current.add_theme_font_override("font", RUSSO)
	_lap_current.add_theme_font_size_override("font_size", 32)
	_lap_current.add_theme_color_override("font_color", _color_ink())

	# Exactly half the current-lap size, dimmer ink — design wants the
	# total to read as a quiet annotation next to the bold lap number.
	_lap_total.add_theme_font_override("font", RUSSO)
	_lap_total.add_theme_font_size_override("font_size", 16)
	_lap_total.add_theme_color_override("font_color", _color_ink_dim())

	# Precise baseline alignment of the lap numbers: parent is a Control
	# (no auto-layout). We position both labels so their text baselines
	# coincide — the small "/01" sits at the same y as the bottom of the
	# big "01" digits. Container layout via HBoxContainer would only
	# align rect bottoms, not baselines (different font sizes have
	# different descent).
	_align_lap_row_baseline()


func _align_lap_row_baseline() -> void:
	# Wait one frame so Label.get_size_min() reflects the final font/size
	# overrides we just applied; otherwise we get pre-override metrics.
	await get_tree().process_frame
	if not is_inside_tree() or _lap_current == null:
		return
	var big_font: Font = _lap_current.get_theme_font("font")
	var small_font: Font = _lap_total.get_theme_font("font")
	var big_ascent: float = big_font.get_ascent(32)
	var small_ascent: float = small_font.get_ascent(16)
	# Big label sits at y=0. Small label is shifted down by the ascent
	# difference so its baseline lands on the big baseline.
	_lap_current.position = Vector2(0, 0)
	_lap_current.size = _lap_current.get_minimum_size()
	_lap_total.position = Vector2(_lap_current.size.x + 4.0, big_ascent - small_ascent)
	_lap_total.size = _lap_total.get_minimum_size()

	_time_main.add_theme_font_override("font", SHARETECH)
	_time_main.add_theme_font_size_override("font_size", 30)
	_time_main.add_theme_color_override("font_color", _color_ink())

	_time_ms.add_theme_font_override("font", SHARETECH)
	_time_ms.add_theme_font_size_override("font_size", 30)
	_time_ms.add_theme_color_override("font_color", _color_red())

	_delta_label.add_theme_font_override("font", SHARETECH)
	_delta_label.add_theme_font_size_override("font_size", 12)
