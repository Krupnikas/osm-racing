extends PanelContainer

## Standings card — top-right of the HUD. Renders a header
## (position N / total + "8 ПИЛОТОВ" stamp), a divider, up to 5 rows of
## racers and a dashed footer summarising the rest of the field.
##
## Driven by `set_standings(rows: Array, player_pos: int, total: int)` where
## each row is { name: String, gap_seconds: float, trend: int (-1/0/1),
## is_player: bool }. Trend: 1=▲ moved up, -1=▼ moved down, 0=◆ same.

const RUSSO := preload("res://ui/fonts/RussoOne-Regular.ttf")
const SHARETECH := preload("res://ui/fonts/ShareTechMono-Regular.ttf")
const JBMONO := preload("res://ui/fonts/jbmono_regular.tres")
const GOLOS := preload("res://ui/fonts/GolosText-Regular.ttf")
const GOLOS_BOLD := preload("res://ui/fonts/GolosText-Bold.ttf")

var is_night: bool = false
var _rows: Array = []
var _player_pos: int = 1
var _total: int = 1

@onready var _vbox: VBoxContainer = $VBox
@onready var _pos_value: Label = $VBox/Header/PosBox/PosValue
@onready var _pos_total: Label = $VBox/Header/PosBox/PosTotal
@onready var _drivers_stamp: Label = $VBox/Header/StampHolder/DriversStamp
@onready var _rows_box: VBoxContainer = $VBox/RowsBox
@onready var _footer: Label = $VBox/Footer


func _ready() -> void:
	_apply_theme()


func set_night(enabled: bool) -> void:
	if is_night == enabled:
		return
	is_night = enabled
	_apply_theme()
	_rebuild_rows()


# Updates standings data and rebuilds the row list. Caller passes the
# full standings; the panel shows up to 5 rows centred on the player.
func set_standings(rows: Array, player_pos: int, total: int) -> void:
	_rows = rows
	_player_pos = player_pos
	_total = total
	_pos_value.text = "%02d" % player_pos
	_pos_total.text = "/%02d" % total
	_drivers_stamp.text = "%d ПИЛОТОВ" % total
	_rebuild_rows()


func _color_bg_primary() -> Color:
	return Color(0.078, 0.067, 0.055, 0.58) if is_night else Color(0.957, 0.925, 0.831, 0.58)
func _color_bg_secondary() -> Color:
	return Color(0.102, 0.086, 0.071, 0.58) if is_night else Color(0.910, 0.871, 0.761, 0.58)
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
func _color_player_bg() -> Color:
	return Color(1.0, 0.42, 0.353, 0.14) if is_night else Color(0.702, 0.145, 0.118, 0.10)


func _apply_theme() -> void:
	# Top-level panel style.
	var sb := StyleBoxFlat.new()
	sb.bg_color = _color_bg_primary()
	sb.border_color = _color_border()
	sb.set_border_width_all(1)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 12
	sb.content_margin_bottom = 12
	sb.corner_radius_top_left = 2
	sb.corner_radius_top_right = 2
	sb.corner_radius_bottom_left = 2
	sb.corner_radius_bottom_right = 2
	add_theme_stylebox_override("panel", sb)

	if _pos_value == null:
		return

	# Header labels — position 02 big, /08 small with manual baseline
	# alignment (parent is a Control, not a Container) so the smaller
	# total sits on the same baseline as the big position number.
	_pos_value.add_theme_color_override("font_color", _color_red())
	_pos_value.add_theme_font_override("font", RUSSO)
	_pos_value.add_theme_font_size_override("font_size", 30)

	_pos_total.add_theme_color_override("font_color", _color_ink_dim())
	_pos_total.add_theme_font_override("font", RUSSO)
	_pos_total.add_theme_font_size_override("font_size", 14)

	_align_pos_baseline()

	_drivers_stamp.add_theme_color_override("font_color", _color_red())
	_drivers_stamp.add_theme_font_override("font", RUSSO)
	_drivers_stamp.add_theme_font_size_override("font_size", 11)
	# Slight tilt — handled by setting rotation on the parent control in tscn.

	$VBox/Header/Label.add_theme_color_override("font_color", _color_ink_dim())
	$VBox/Header/Label.add_theme_font_override("font", JBMONO)
	$VBox/Header/Label.add_theme_font_size_override("font_size", 10)

	# Stamp border via StyleBoxFlat on a margin container.
	var stamp_sb := StyleBoxFlat.new()
	stamp_sb.bg_color = Color(0, 0, 0, 0)
	stamp_sb.border_color = _color_red()
	stamp_sb.set_border_width_all(1)
	stamp_sb.content_margin_left = 8
	stamp_sb.content_margin_right = 8
	stamp_sb.content_margin_top = 2
	stamp_sb.content_margin_bottom = 2
	var stamp_holder: PanelContainer = $VBox/Header/StampHolder
	if stamp_holder:
		stamp_holder.add_theme_stylebox_override("panel", stamp_sb)
		stamp_holder.rotation = deg_to_rad(2.0)

	# Footer.
	_footer.add_theme_color_override("font_color", _color_ink_dim())
	_footer.add_theme_font_override("font", JBMONO)
	_footer.add_theme_font_size_override("font_size", 10)


func _align_pos_baseline() -> void:
	# Same trick as lap_time_panel — parent is a Control so we can
	# position both labels manually and align their text baselines.
	await get_tree().process_frame
	if not is_inside_tree() or _pos_value == null:
		return
	var big_font: Font = _pos_value.get_theme_font("font")
	var small_font: Font = _pos_total.get_theme_font("font")
	var big_ascent: float = big_font.get_ascent(30)
	var small_ascent: float = small_font.get_ascent(14)
	_pos_value.position = Vector2(0, 0)
	_pos_value.size = _pos_value.get_minimum_size()
	_pos_total.position = Vector2(_pos_value.size.x + 2.0, big_ascent - small_ascent)
	_pos_total.size = _pos_total.get_minimum_size()
	var parent_ctrl: Control = _pos_value.get_parent()
	if parent_ctrl:
		parent_ctrl.custom_minimum_size = Vector2(
			_pos_total.position.x + _pos_total.size.x,
			max(_pos_value.size.y, _pos_total.position.y + _pos_total.size.y))


func _rebuild_rows() -> void:
	if not _rows_box:
		return
	for child in _rows_box.get_children():
		child.queue_free()

	# Build a window of up to 5 rows centred on the player.
	var n: int = _rows.size()
	if n == 0:
		_footer.text = ""
		return
	var start: int = max(0, _player_pos - 3)
	var end: int = min(n, start + 5)
	if end - start < 5:
		start = max(0, end - 5)
	for i in range(start, end):
		_rows_box.add_child(_make_row(_rows[i], i + 1))

	# Footer enumerates the trailing positions if any.
	var behind_count: int = max(0, n - end)
	if behind_count <= 0:
		_footer.text = ""
	else:
		var tail: PackedStringArray = []
		for pos in range(end + 1, n + 1):
			tail.append("%02d" % pos)
		_footer.text = "+%d ПОЗАДИ · %s" % [behind_count, " / ".join(tail)]


func _make_row(data: Dictionary, position: int) -> Control:
	var row := PanelContainer.new()
	row.custom_minimum_size = Vector2(0, 28)
	var sb := StyleBoxFlat.new()
	var is_player: bool = bool(data.get("is_player", false))
	if is_player:
		sb.bg_color = _color_player_bg()
		sb.set_border_width_all(0)
		sb.border_width_left = 3
		sb.border_color = _color_red()
	else:
		sb.bg_color = Color(0, 0, 0, 0)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	row.add_theme_stylebox_override("panel", sb)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	row.add_child(hbox)

	# Position number.
	var pos_lbl := Label.new()
	pos_lbl.text = "%02d" % position
	pos_lbl.add_theme_font_override("font", RUSSO)
	pos_lbl.add_theme_font_size_override("font_size", 16)
	pos_lbl.add_theme_color_override("font_color", _color_ink())
	pos_lbl.custom_minimum_size = Vector2(34, 0)
	hbox.add_child(pos_lbl)

	# Trend arrow.
	var trend_lbl := Label.new()
	var trend: int = int(data.get("trend", 0))
	var trend_text := "◆"
	var trend_col := _color_ink_dim()
	if trend > 0:
		trend_text = "▲"
		trend_col = _color_green()
	elif trend < 0:
		trend_text = "▼"
		trend_col = _color_red()
	trend_lbl.text = trend_text
	trend_lbl.add_theme_font_override("font", GOLOS_BOLD)
	trend_lbl.add_theme_font_size_override("font_size", 13)
	trend_lbl.add_theme_color_override("font_color", trend_col)
	trend_lbl.custom_minimum_size = Vector2(18, 0)
	hbox.add_child(trend_lbl)

	# Name (expands).
	var name_lbl := Label.new()
	name_lbl.text = str(data.get("name", "")).to_upper()
	name_lbl.add_theme_font_override("font", GOLOS_BOLD)
	name_lbl.add_theme_font_size_override("font_size", 14)
	name_lbl.add_theme_color_override("font_color", _color_ink() if not is_player else _color_red())
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(name_lbl)

	# Gap (right aligned).
	var gap_lbl := Label.new()
	gap_lbl.text = _format_gap(float(data.get("gap_seconds", 0.0)), is_player)
	gap_lbl.add_theme_font_override("font", SHARETECH)
	gap_lbl.add_theme_font_size_override("font_size", 13)
	var gap: float = float(data.get("gap_seconds", 0.0))
	var gap_col: Color = _color_ink_dim()
	if is_player:
		gap_col = _color_red()
	elif gap < 0:
		gap_col = _color_green()
	elif gap > 0:
		gap_col = _color_red()
	gap_lbl.add_theme_color_override("font_color", gap_col)
	gap_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	gap_lbl.custom_minimum_size = Vector2(70, 0)
	hbox.add_child(gap_lbl)

	return row


static func _format_gap(seconds: float, is_player: bool) -> String:
	if is_player:
		return "0:00.00"
	var sign_str: String = "+" if seconds >= 0 else "−"
	var abs_s: float = absf(seconds)
	return "%s%05.2f" % [sign_str, abs_s]
