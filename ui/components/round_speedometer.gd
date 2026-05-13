extends Control

## ЖАЖДА СКОРОСТИ HUD speedometer — 280x280 analog dial.
## Day:   cream paper background, dark ink scale, red needle + red zone.
## Night: graphite background, amber backlit text, amber/red needle.
## Renders entirely via `_draw()` (no child nodes for scale/needle).
## Set `current_speed_kmh`, `current_gear`, `nitro_pct` from the HUD;
## the dial smooths to those values inside `_process()`.

const MAX_KMH := 200.0
const RED_ZONE_KMH := 160.0
const DIAL_RADIUS := 110.0          # outer scale radius (out of 140 half-size)
const NITRO_RADIUS := 130.0
const TICK_LEN_MAJOR := 12.0
const TICK_LEN_MINOR := 6.0
const NEEDLE_LEN := 96.0
const NEEDLE_BACK := 18.0           # tail length behind centre
const NEEDLE_WIDTH := 3.0
const SWEEP_START_DEG := -225.0     # bottom-left
const SWEEP_END_DEG := 45.0         # bottom-right (sweeps 270° clockwise on top)

@export var current_speed_kmh: float = 0.0
@export var current_gear: int = 1
@export var nitro_pct: float = 70.0         # 0..100; default seeded for HUD preview
@export var smooth_speed_rate: float = 12.0 # higher = snappier
@export var smooth_nitro_rate: float = 8.0

var is_night: bool = false

var _displayed_speed: float = 0.0
var _displayed_nitro: float = 0.0

# Theme palette — overwritten in _refresh_palette() when is_night flips.
var _bg_inner: Color
var _bg_outer: Color
var _border_color: Color
var _scale_ink: Color
var _scale_ink_dim: Color
var _label_ink: Color
var _accent_red: Color
var _accent_cyan: Color
var _needle_color: Color

# Fonts preloaded at compile time — see lap_time_panel.gd diagnostics
# (which print path + class confirming the resources load correctly).
# ShareTechMono is latin-only (no Cyrillic glyphs), so we use it ONLY
# for the numeric scale; the Cyrillic captions ("ПЕР.", "КМ/Ч") fall
# back to JetBrainsMono via HudFonts.jbmono_regular() — that returns a
# FontVariation around the variable font which Godot can render.
const FONT_SHARETECH := preload("res://ui/fonts/ShareTechMono-Regular.ttf")
const FONT_RUSSO := preload("res://ui/fonts/RussoOne-Regular.ttf")
const FONT_JBMONO := preload("res://ui/fonts/jbmono_regular.tres")
const FONT_JBMONO_WIDE := preload("res://ui/fonts/jbmono_wide.tres")


func _ready() -> void:
	custom_minimum_size = Vector2(280, 280)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_refresh_palette()
	set_process(true)
	var probe := FONT_SHARETECH.get_string_size("100", HORIZONTAL_ALIGNMENT_LEFT, -1, 14)
	print("[Speedo] _ready size=%s scale_font_size('100',14)=%s" % [size, probe])
	queue_redraw()


func set_night(enabled: bool) -> void:
	if is_night == enabled:
		return
	is_night = enabled
	_refresh_palette()
	queue_redraw()


func _refresh_palette() -> void:
	if is_night:
		# Same translucency as the HUD cards (~0.58) so the dial reads
		# as a layered piece of the same pace-note set.
		_bg_inner = Color(0.141, 0.106, 0.078, 0.58)
		_bg_outer = Color(0.039, 0.031, 0.020, 0.58)
		_border_color = Color(1.0, 0.706, 0.314, 0.25)
		_scale_ink = Color("#ffd17a")
		_scale_ink_dim = Color(0.953, 0.847, 0.640, 0.55)
		_label_ink = Color("#ffd17a")
		_accent_red = Color("#ff6b5a")
		_accent_cyan = Color("#1fc8d8")
		_needle_color = Color("#ff6b5a")
	else:
		_bg_inner = Color(0.976, 0.953, 0.875, 0.58)
		_bg_outer = Color(0.859, 0.812, 0.651, 0.58)
		_border_color = Color(0.235, 0.157, 0.078, 0.35)
		_scale_ink = Color("#1c1612")
		_scale_ink_dim = Color(0.110, 0.086, 0.071, 0.55)
		_label_ink = Color("#1c1612")
		_accent_red = Color("#b3251e")
		_accent_cyan = Color("#1fc8d8")
		_needle_color = Color("#b3251e")


func _process(delta: float) -> void:
	var changed := false
	var new_speed: float = lerpf(_displayed_speed, current_speed_kmh, clampf(delta * smooth_speed_rate, 0.0, 1.0))
	if absf(new_speed - _displayed_speed) > 0.01:
		_displayed_speed = new_speed
		changed = true
	var new_nitro: float = lerpf(_displayed_nitro, nitro_pct, clampf(delta * smooth_nitro_rate, 0.0, 1.0))
	if absf(new_nitro - _displayed_nitro) > 0.01:
		_displayed_nitro = new_nitro
		changed = true
	if changed:
		queue_redraw()


# Maps km/h on the dial to absolute angle in radians (Godot screen-space:
# 0 rad = right, +Y down so +rad rotates clockwise). The dial sweeps the
# top 270° going clockwise from bottom-left (-225°) to bottom-right (+45°).
func _kmh_to_angle(kmh: float) -> float:
	var t: float = clampf(kmh / MAX_KMH, 0.0, 1.0)
	var deg: float = lerpf(SWEEP_START_DEG, SWEEP_END_DEG, t)
	return deg_to_rad(deg)


func _draw() -> void:
	var centre: Vector2 = size * 0.5
	# Background — radial gradient via two filled circles (fastest, no shader).
	draw_circle(centre, 140.0, _bg_outer)
	draw_circle(centre, 122.0, _bg_inner)
	# Outer border ring.
	draw_arc(centre, 138.0, 0.0, TAU, 64, _border_color, 1.5, true)

	_draw_nitro_arc(centre)
	_draw_red_zone(centre)
	_draw_scale(centre)
	# Needle first, then the centre labels so the big speed digit and
	# "ПЕР./gear" cluster cover the needle in the dial's middle (per
	# the design — the readout reads OVER the indicator, not behind it).
	_draw_needle(centre)
	# Pin in the centre — anchors the needle visually.
	draw_circle(centre, 6.0, _scale_ink)
	draw_arc(centre, 6.0, 0.0, TAU, 24, _bg_outer, 1.5, true)
	_draw_center_labels(centre)


func _draw_red_zone(centre: Vector2) -> void:
	var a0 := _kmh_to_angle(RED_ZONE_KMH)
	var a1 := _kmh_to_angle(MAX_KMH)
	draw_arc(centre, DIAL_RADIUS + 4.0, a0, a1, 32, _accent_red, 3.0, true)


func _draw_nitro_arc(centre: Vector2) -> void:
	# Nitro arc mirrors the 0..200 km/h dial sweep (270°, bottom-left to
	# bottom-right, clockwise across the top). Matches HUD HTML source:
	# 4px stroke, brighter cyan (#1fc8d8), 0.18 alpha background, plus
	# a soft outer glow drawn as a thicker semi-transparent arc beneath
	# the main one. Thumb is a small circle in lighter cyan with its
	# own glow halo at the fill's leading edge.
	var a_start := deg_to_rad(SWEEP_START_DEG)
	var a_end := deg_to_rad(SWEEP_END_DEG)

	# Background ring — neutral gray (NOT dimmed cyan) so the active
	# cyan portion reads as the filled state of an empty slider track.
	var bg_col: Color = _scale_ink_dim
	bg_col.a = 0.40
	draw_arc(centre, NITRO_RADIUS, a_start, a_end, 96, bg_col, 4.0, true)

	var t: float = clampf(_displayed_nitro / 100.0, 0.0, 1.0)
	if t > 0.001:
		var a_fill_end := lerpf(a_start, a_end, t)
		# Outer glow — 3 progressively wider, dimmer copies under the
		# bright stroke. Imitates the CSS drop-shadow halo.
		var glow_col := _accent_cyan
		glow_col.a = 0.18
		draw_arc(centre, NITRO_RADIUS, a_start, a_fill_end, 96, glow_col, 14.0, true)
		glow_col.a = 0.28
		draw_arc(centre, NITRO_RADIUS, a_start, a_fill_end, 96, glow_col, 9.0, true)
		# Main stroke.
		draw_arc(centre, NITRO_RADIUS, a_start, a_fill_end, 96, _accent_cyan, 4.0, true)

		# Thumb — small bright dot at the leading edge with a glow halo
		# so it reads as a slider handle.
		var thumb_pos := centre + Vector2(cos(a_fill_end), sin(a_fill_end)) * NITRO_RADIUS
		var halo_col := Color("#1fc8d8")
		halo_col.a = 0.45
		draw_circle(thumb_pos, 8.0, halo_col)
		draw_circle(thumb_pos, 3.5, Color("#7df0ff"))


func _draw_scale(centre: Vector2) -> void:
	# 0..200 step 10. Major every 20, minor otherwise.
	var v := 0
	while v <= int(MAX_KMH):
		var ang := _kmh_to_angle(float(v))
		var dir := Vector2(cos(ang), sin(ang))
		var is_major := (v % 20) == 0
		var len: float = TICK_LEN_MAJOR if is_major else TICK_LEN_MINOR
		var width: float = 2.5 if is_major else 1.0
		var outer := centre + dir * DIAL_RADIUS
		var inner := centre + dir * (DIAL_RADIUS - len)
		var col := _accent_red if v >= int(RED_ZONE_KMH) else _scale_ink
		draw_line(outer, inner, col, width, true)
		if is_major and FONT_SHARETECH:
			var label_pos := centre + dir * (DIAL_RADIUS - len - 18.0)
			var text := str(v)
			var fs := 11
			var ts: Vector2 = FONT_SHARETECH.get_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, -1, fs)
			label_pos.x -= ts.x * 0.5
			label_pos.y += ts.y * 0.32
			var label_col := _accent_red if v >= int(RED_ZONE_KMH) else _scale_ink
			draw_string(FONT_SHARETECH, label_pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, label_col)
		v += 10


func _draw_needle(centre: Vector2) -> void:
	var ang := _kmh_to_angle(_displayed_speed)
	var dir := Vector2(cos(ang), sin(ang))
	var tail := centre - dir * NEEDLE_BACK
	var tip := centre + dir * NEEDLE_LEN
	# Main shaft.
	draw_line(tail, tip, _needle_color, NEEDLE_WIDTH, true)
	# Arrowhead triangle.
	var perp := Vector2(-dir.y, dir.x)
	var base := tip - dir * 14.0
	var p1 := base + perp * 6.0
	var p2 := base - perp * 6.0
	var pts := PackedVector2Array([tip, p1, p2])
	draw_colored_polygon(pts, _needle_color)


func _draw_center_labels(centre: Vector2) -> void:
	var jbmono: Font = FONT_JBMONO

	# Gear cluster: "ПЕР." caption + big gear digit, baseline-aligned.
	# `draw_string`'s `pos` is the BASELINE-left of the glyph row, so to
	# share a baseline we simply pass the same y to both calls.
	# Use the wide-tracked JBMono for the caption so the small-caps
	# letters read with the same airy spacing as ВРЕМЯ КРУГА et al.
	# Cluster is pushed up a bit so it sits above (not over) the big
	# speed digit cluster below.
	var gear_baseline_y: float = centre.y - 40.0
	var gear_lbl := "ПЕР."
	var gear_lbl_size_px := 11
	# Map internal gear int → display label. -1 = Reverse, 0 = Neutral,
	# 1..N = numeric forward gear.
	var gear_digit := "N"
	if current_gear == -1:
		gear_digit = "R"
	elif current_gear == 0:
		gear_digit = "N"
	else:
		gear_digit = str(current_gear)
	var gear_digit_size_px := 22
	var lbl_w: float = FONT_JBMONO_WIDE.get_string_size(gear_lbl, HORIZONTAL_ALIGNMENT_LEFT, -1, gear_lbl_size_px).x
	var digit_w: float = FONT_RUSSO.get_string_size(gear_digit, HORIZONTAL_ALIGNMENT_LEFT, -1, gear_digit_size_px).x
	# Centre the cluster horizontally on the dial.
	var cluster_w: float = lbl_w + 4.0 + digit_w
	var cluster_x: float = centre.x - cluster_w * 0.5
	draw_string(FONT_JBMONO_WIDE, Vector2(cluster_x, gear_baseline_y), gear_lbl,
			HORIZONTAL_ALIGNMENT_LEFT, -1, gear_lbl_size_px, _scale_ink_dim)
	draw_string(FONT_RUSSO, Vector2(cluster_x + lbl_w + 4.0, gear_baseline_y), gear_digit,
			HORIZONTAL_ALIGNMENT_LEFT, -1, gear_digit_size_px, _accent_red)

	# Big speed number — RussoOne, centred horizontally on the dial.
	var sp := str(int(roundf(_displayed_speed)))
	var sp_size_px := 72
	var sp_w: float = FONT_RUSSO.get_string_size(sp, HORIZONTAL_ALIGNMENT_LEFT, -1, sp_size_px).x
	draw_string(FONT_RUSSO, Vector2(centre.x - sp_w * 0.5, centre.y + 28.0), sp,
			HORIZONTAL_ALIGNMENT_LEFT, -1, sp_size_px, _label_ink)

	# "КМ/Ч" units below the speed digit — Cyrillic, must use JBMono.
	var unit := "КМ/Ч"
	var unit_size_px := 11
	var unit_w: float = jbmono.get_string_size(unit, HORIZONTAL_ALIGNMENT_LEFT, -1, unit_size_px).x
	draw_string(jbmono, Vector2(centre.x - unit_w * 0.5, centre.y + 58.0), unit,
			HORIZONTAL_ALIGNMENT_LEFT, -1, unit_size_px, _scale_ink_dim)
