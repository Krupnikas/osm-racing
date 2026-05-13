extends PanelContainer

## NEAR MISS ephemeral card. Slight -1.2° tilt. Tween: scale 0.9→1 +
## opacity 0→1 over 150ms, hold ~1.4s, fade out over ~350ms.
## Call `trigger(count: int, points: int)` to (re)play the animation —
## if called again while still on-screen the count is updated and the
## fade-out timer restarts.

const RUSSO := preload("res://ui/fonts/RussoOne-Regular.ttf")
const GOLOS := preload("res://ui/fonts/GolosText-Regular.ttf")
const JBMONO := preload("res://ui/fonts/jbmono_regular.tres")

const POINTS_PER_HIT := 100

@onready var _icon: Label = $HBox/Icon
@onready var _title: Label = $HBox/Mid/Title
@onready var _sub: Label = $HBox/Mid/Sub
@onready var _count: Label = $HBox/Count
@onready var _plus: Label = $HBox/Plus
@onready var _into_nitro: Label = $HBox/IntoNitro

var is_night: bool = false
var _active_tween: Tween


func _ready() -> void:
	modulate.a = 0.0
	scale = Vector2(0.9, 0.9)
	rotation = deg_to_rad(-1.2)
	pivot_offset = size * 0.5
	visible = false
	_apply_theme()


func set_night(enabled: bool) -> void:
	if is_night == enabled:
		return
	is_night = enabled
	_apply_theme()


func trigger(count: int, points: int = 0) -> void:
	if points <= 0:
		points = count * POINTS_PER_HIT
	_count.text = "×%d" % count
	_plus.text = "+%d" % points
	visible = true
	# Restart animation regardless of previous state.
	if _active_tween:
		_active_tween.kill()
	scale = Vector2(0.9, 0.9)
	modulate.a = 0.0
	_active_tween = create_tween()
	_active_tween.set_parallel(true)
	_active_tween.tween_property(self, "scale", Vector2(1.0, 1.0), 0.15).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_active_tween.tween_property(self, "modulate:a", 1.0, 0.15)
	_active_tween.chain().tween_interval(1.4)
	_active_tween.chain().tween_property(self, "modulate:a", 0.0, 0.35)
	_active_tween.chain().tween_callback(func() -> void: visible = false)


func _color_bg() -> Color:
	# NEAR MISS is the only opaque card per HUD source — pops in & out so
	# it must stay readable: day = solid cream #f4eccc, night = ~0.85
	# alpha graphite. Reverted from the 0.58 cards' transparency.
	return Color(0.157, 0.086, 0.063, 0.85) if is_night else Color("#f4eccc")
func _color_border() -> Color:
	return Color(1.0, 0.706, 0.314, 0.18) if is_night else Color(0.235, 0.157, 0.078, 0.30)
func _color_ink() -> Color:
	return Color("#ffd17a") if is_night else Color("#1c1612")
func _color_ink_dim() -> Color:
	return Color(0.953, 0.847, 0.640, 0.55) if is_night else Color(0.110, 0.086, 0.071, 0.55)
func _color_red() -> Color:
	return Color("#ff6b5a") if is_night else Color("#b3251e")
func _color_cyan() -> Color:
	return Color("#5fd8e8") if is_night else Color("#1a8a8a")


func _apply_theme() -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = _color_bg()
	sb.border_color = _color_border()
	sb.set_border_width_all(1)
	sb.border_width_left = 4
	# Override left border with red accent.
	# StyleBoxFlat doesn't support per-side colors, so we render the
	# accent by adjusting border_color globally + using a translucent
	# overlay. Compromise: tint border_color toward red.
	sb.border_color = _color_red()
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	add_theme_stylebox_override("panel", sb)
	if _icon == null:
		return
	_icon.add_theme_font_override("font", RUSSO)
	_icon.add_theme_font_size_override("font_size", 18)
	_icon.add_theme_color_override("font_color", _color_red())
	_title.add_theme_font_override("font", RUSSO)
	_title.add_theme_font_size_override("font_size", 14)
	_title.add_theme_color_override("font_color", _color_red())
	_sub.add_theme_font_override("font", JBMONO)
	_sub.add_theme_font_size_override("font_size", 9)
	_sub.add_theme_color_override("font_color", _color_ink_dim())
	_count.add_theme_font_override("font", RUSSO)
	_count.add_theme_font_size_override("font_size", 26)
	_count.add_theme_color_override("font_color", _color_red())
	_plus.add_theme_font_override("font", RUSSO)
	_plus.add_theme_font_size_override("font_size", 18)
	_plus.add_theme_color_override("font_color", _color_ink())
	_into_nitro.add_theme_font_override("font", JBMONO)
	_into_nitro.add_theme_font_size_override("font_size", 8)
	_into_nitro.add_theme_color_override("font_color", _color_cyan())
