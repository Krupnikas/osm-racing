extends Control

## Экран выбора локации (ВЫБЕРИТЕ ЛОКАЦИЮ).
## По дизайну screens-1.jsx → ScreenWorldMap.
##
## Слева — список из 7 локаций с фокусом по стрелкам, справа — Locator
## панель с именем, координатами и top-down превью реального ОСМ-чанка
## (берётся из ui/assets/location_chunks/*.json — заранее скачано
## tools/fetch_location_chunks.py).

signal location_chosen(loc: Dictionary)
signal back_requested
signal map_requested

const BrandMarkScene      = preload("res://ui/components/brand_mark.tscn")
const CornerChromeScript  = preload("res://ui/components/corner_chrome.gd")
const NeonStyleBoxScript  = preload("res://ui/neon_style_box.gd")
const OSMPreviewScript    = preload("res://ui/components/osm_preview.gd")
const FiraBoldItalicFont  = preload("res://ui/fonts/FiraSansCondensed-BoldItalic.ttf")

const LOCATIONS := [
	{"ru": "Череповец",               "en": "CHEREPOVETS",   "lat": 59.150406, "lon": 37.948805, "dist_km":     0, "races": 3, "status": "unlocked", "chunk": "cherepovets"},
	{"ru": "Новый Век",               "en": "NEW CENTURY",   "lat": 59.123567, "lon": 37.982864, "dist_km":    12, "races": 4, "status": "unlocked", "chunk": "noviy_vek"},
	{"ru": "Ледовый дворец",          "en": "ICE PALACE",    "lat": 59.089216, "lon": 37.917488, "dist_km":    24, "races": 5, "status": "unlocked", "chunk": "ledoviy_dvorets"},
	{"ru": "Октябрьский мост",        "en": "OKT. BRIDGE",   "lat": 59.118453, "lon": 37.902972, "dist_km":    38, "races": 2, "status": "unlocked", "chunk": "oktyabrsky_most"},
	{"ru": "Москва (Отрадное)",       "en": "MOSCOW",        "lat": 55.860580, "lon": 37.599646, "dist_km":   492, "races": 6, "status": "unlocked", "chunk": "moscow"},
	{"ru": "Тбилиси (Важа-Пшавела)",  "en": "TBILISI",       "lat": 41.723972, "lon": 44.730502, "dist_km":  2140, "races": 4, "status": "unlocked", "chunk": "tbilisi"},
	{"ru": "Дубай (Крик)",            "en": "DUBAI / CREEK", "lat": 25.208591, "lon": 55.344100, "dist_km":  4220, "races": 3, "status": "unlocked", "chunk": "dubai"},
]

static var _fira_tight: FontVariation = null
static func _get_fira_tight() -> FontVariation:
	if _fira_tight == null:
		_fira_tight = FontVariation.new()
		_fira_tight.base_font = FiraBoldItalicFont
		_fira_tight.spacing_glyph = 0
	return _fira_tight

var _focused_idx: int = 0
var _rows: Array[Control] = []
var _map_row_idx: int = -1  # index of "choose on map" row in _rows
var _focused_sidebar: ColorRect = null
var _focused_sidebar_tween: Tween = null

# Locator side
var _loc_name: Label
var _loc_coords: Label
var _osm_preview: OSMPreview
var _readout_length: Label
var _readout_traffic: Label
var _readout_weather: Label


func _ready() -> void:
	_build_ui()
	_apply_focus()


func show_screen() -> void:
	visible = true
	_apply_focus()
	if _rows.size() > 0:
		_rows[_focused_idx].call_deferred("grab_focus")


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		# Up/Down are handled by Godot's built-in spatial focus navigation
		# (ui_up / ui_down) — adding manual handling here would step twice.
		match event.keycode:
			KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
				_activate_focused()
			KEY_ESCAPE:
				back_requested.emit()


# === UI build ===

func _build_ui() -> void:
	var brand := BrandMarkScene.instantiate() as Control
	brand.scale = Vector2(0.85, 0.85)
	brand.position = Vector2(90, 80)
	brand.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(brand)

	var title_box := VBoxContainer.new()
	title_box.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	title_box.offset_left = -1100.0
	title_box.offset_right = -90.0
	title_box.offset_top = 80.0
	title_box.offset_bottom = 360.0
	title_box.alignment = BoxContainer.ALIGNMENT_BEGIN
	title_box.add_theme_constant_override("separation", 8)
	title_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(title_box)

	var t_kicker := Label.new()
	t_kicker.text = "// 04 / WORLD MAP · КАРТА"
	t_kicker.theme_type_variation = "MonoLabel"
	t_kicker.add_theme_font_size_override("font_size", 12)
	t_kicker.add_theme_color_override("font_color", UI.NEON_CYAN)
	t_kicker.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	title_box.add_child(t_kicker)

	var h2_stack := VBoxContainer.new()
	h2_stack.add_theme_constant_override("separation", -50)
	h2_stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_box.add_child(h2_stack)

	var t1 := Label.new()
	t1.text = "ВЫБЕРИТЕ"
	t1.theme_type_variation = "DisplayLabel"
	t1.add_theme_font_size_override("font_size", 88)
	t1.add_theme_color_override("font_color", UI.INK_900)
	t1.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	h2_stack.add_child(t1)

	var t2 := Label.new()
	t2.text = "ЛОКАЦИЮ"
	t2.theme_type_variation = "DisplayLabel"
	t2.add_theme_font_size_override("font_size", 88)
	t2.add_theme_color_override("font_color", Color(0, 0, 0, 0))
	t2.add_theme_color_override("font_outline_color", UI.NEON_CYAN)
	t2.add_theme_constant_override("outline_size", 2)
	t2.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	h2_stack.add_child(t2)

	var split := HBoxContainer.new()
	split.set_anchors_preset(Control.PRESET_FULL_RECT)
	split.offset_left = 120.0
	split.offset_right = -120.0
	split.offset_top = 280.0
	split.offset_bottom = -160.0
	split.add_theme_constant_override("separation", 60)
	split.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(split)

	# --- LEFT: list ---
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 6)
	left.mouse_filter = Control.MOUSE_FILTER_IGNORE
	split.add_child(left)

	var sub_kicker := Label.new()
	sub_kicker.text = "// %d ЛОКАЦИЙ · СЕГОДНЯ" % LOCATIONS.size()
	sub_kicker.theme_type_variation = "MonoLabel"
	sub_kicker.add_theme_font_size_override("font_size", 12)
	sub_kicker.add_theme_color_override("font_color", UI.INK_500)
	left.add_child(sub_kicker)

	var rows_box := VBoxContainer.new()
	rows_box.add_theme_constant_override("separation", 4)
	rows_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	left.add_child(rows_box)

	for i in LOCATIONS.size():
		var row := _build_location_row(i)
		_rows.append(row)
		rows_box.add_child(row)

	# "Choose on map" row
	var map_row := _build_map_row(LOCATIONS.size())
	_map_row_idx = _rows.size()
	_rows.append(map_row)
	rows_box.add_child(map_row)

	left.add_child(_make_spacer(24))

	var back_btn := _make_p_button("← НАЗАД")
	back_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	back_btn.pressed.connect(func(): back_requested.emit())
	left.add_child(back_btn)

	# --- RIGHT: locator panel ---
	var locator := Panel.new()
	locator.custom_minimum_size = Vector2(720, 0)
	locator.size_flags_horizontal = Control.SIZE_FILL
	locator.size_flags_vertical = Control.SIZE_EXPAND_FILL
	locator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var lsb: NeonStyleBox = NeonStyleBoxScript.new()
	lsb.fill_color = Color(UI.INK_050.r, UI.INK_050.g, UI.INK_050.b, 0.85)
	lsb.outline_color = UI.INK_300
	lsb.outline_width = 1.0
	lsb.shear_deg = 0.0
	lsb.glow_size = 0
	lsb.slashed = true
	lsb.slash_size = 24.0
	locator.add_theme_stylebox_override("panel", lsb)
	split.add_child(locator)

	_build_locator_contents(locator)

	# Corner chrome on top.
	var chrome := Control.new()
	chrome.set_script(CornerChromeScript)
	chrome.set_anchors_preset(Control.PRESET_FULL_RECT)
	chrome.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(chrome)


func _make_spacer(height: int) -> Control:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, height)
	s.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return s


func _build_location_row(idx: int) -> Control:
	var loc: Dictionary = LOCATIONS[idx]
	var row := Panel.new()
	row.name = "Row_%d" % idx
	row.custom_minimum_size = Vector2(0, 60)
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	row.focus_mode = Control.FOCUS_ALL

	var sb_normal: NeonStyleBox = NeonStyleBoxScript.new()
	sb_normal.fill_color = Color(0, 0, 0, 0)
	sb_normal.outline_color = Color(0, 0, 0, 0)
	sb_normal.outline_width = 0.0
	sb_normal.shear_deg = 0.0
	sb_normal.glow_size = 0
	sb_normal.right_slant = 14.0
	row.add_theme_stylebox_override("panel", sb_normal)

	var hbox := HBoxContainer.new()
	hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	hbox.offset_left = 22.0
	hbox.offset_right = -22.0
	hbox.add_theme_constant_override("separation", 18)
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(hbox)

	# Pulsing sidebar — 4px on the left, alpha=0 unless focused.
	var bar := ColorRect.new()
	bar.color = UI.NEON_CYAN
	bar.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	bar.offset_top = 6.0
	bar.offset_bottom = -6.0
	bar.offset_right = 4.0
	bar.modulate.a = 0.0
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(bar)

	var num_lbl := Label.new()
	num_lbl.text = "%02d" % (idx + 1)
	num_lbl.theme_type_variation = "MonoLabel"
	num_lbl.add_theme_font_size_override("font_size", 22)
	num_lbl.add_theme_color_override("font_color", UI.INK_500)
	num_lbl.custom_minimum_size = Vector2(48, 0)
	num_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hbox.add_child(num_lbl)

	var name_box := VBoxContainer.new()
	name_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	name_box.add_theme_constant_override("separation", 4)
	hbox.add_child(name_box)

	var name_lbl := Label.new()
	name_lbl.text = String(loc["ru"]).to_upper()
	name_lbl.theme_type_variation = "DisplayLabel"
	name_lbl.add_theme_font_override("font", _get_fira_tight())
	name_lbl.add_theme_font_size_override("font_size", 28)
	name_lbl.add_theme_color_override("font_color", UI.INK_900)
	name_box.add_child(name_lbl)

	var sub_lbl := Label.new()
	sub_lbl.text = "%s · %d ГОНКИ" % [loc["en"], int(loc["races"])]
	sub_lbl.theme_type_variation = "MonoLabel"
	sub_lbl.add_theme_font_size_override("font_size", 10)
	sub_lbl.add_theme_color_override("font_color", UI.INK_500)
	name_box.add_child(sub_lbl)

	var dist_lbl := Label.new()
	dist_lbl.text = _format_distance(int(loc["dist_km"]))
	dist_lbl.theme_type_variation = "MonoLabel"
	dist_lbl.add_theme_font_size_override("font_size", 14)
	dist_lbl.add_theme_color_override("font_color", UI.INK_500)
	dist_lbl.custom_minimum_size = Vector2(120, 0)
	dist_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dist_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hbox.add_child(dist_lbl)

	var status_lbl := Label.new()
	status_lbl.theme_type_variation = "MonoLabel"
	status_lbl.add_theme_font_size_override("font_size", 11)
	status_lbl.custom_minimum_size = Vector2(110, 0)
	status_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hbox.add_child(status_lbl)

	# Stash refs in metadata so _apply_focus can repaint without rebuilding.
	row.set_meta("name_lbl", name_lbl)
	row.set_meta("sub_lbl", sub_lbl)
	row.set_meta("num_lbl", num_lbl)
	row.set_meta("dist_lbl", dist_lbl)
	row.set_meta("status_lbl", status_lbl)
	row.set_meta("bar", bar)

	row.gui_input.connect(_on_row_gui_input.bind(idx))
	row.focus_entered.connect(_on_row_focus_entered.bind(idx))
	row.mouse_entered.connect(row.grab_focus)

	return row


func _build_map_row(idx: int) -> Control:
	var row := Panel.new()
	row.name = "Row_map"
	row.custom_minimum_size = Vector2(0, 60)
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	row.focus_mode = Control.FOCUS_ALL

	var sb_normal: NeonStyleBox = NeonStyleBoxScript.new()
	sb_normal.fill_color = Color(0, 0, 0, 0)
	sb_normal.outline_color = Color(0, 0, 0, 0)
	sb_normal.outline_width = 0.0
	sb_normal.shear_deg = 0.0
	sb_normal.glow_size = 0
	sb_normal.right_slant = 14.0
	row.add_theme_stylebox_override("panel", sb_normal)

	var hbox := HBoxContainer.new()
	hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	hbox.offset_left = 22.0
	hbox.offset_right = -22.0
	hbox.add_theme_constant_override("separation", 18)
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(hbox)

	var bar := ColorRect.new()
	bar.color = UI.NEON_MAGENTA
	bar.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	bar.offset_top = 6.0
	bar.offset_bottom = -6.0
	bar.offset_right = 4.0
	bar.modulate.a = 0.0
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(bar)

	var num_lbl := Label.new()
	num_lbl.text = "%02d" % (idx + 1)
	num_lbl.theme_type_variation = "MonoLabel"
	num_lbl.add_theme_font_size_override("font_size", 22)
	num_lbl.add_theme_color_override("font_color", UI.INK_500)
	num_lbl.custom_minimum_size = Vector2(48, 0)
	num_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hbox.add_child(num_lbl)

	var name_box := VBoxContainer.new()
	name_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	name_box.add_theme_constant_override("separation", 4)
	hbox.add_child(name_box)

	var name_lbl := Label.new()
	name_lbl.text = "ВЫБРАТЬ НА КАРТЕ"
	name_lbl.theme_type_variation = "DisplayLabel"
	name_lbl.add_theme_font_override("font", _get_fira_tight())
	name_lbl.add_theme_font_size_override("font_size", 28)
	name_lbl.add_theme_color_override("font_color", UI.INK_900)
	name_box.add_child(name_lbl)

	var sub_lbl := Label.new()
	sub_lbl.text = "WORLD MAP · ANY PLACE ON EARTH"
	sub_lbl.theme_type_variation = "MonoLabel"
	sub_lbl.add_theme_font_size_override("font_size", 10)
	sub_lbl.add_theme_color_override("font_color", UI.INK_500)
	name_box.add_child(sub_lbl)

	var dist_lbl := Label.new()
	dist_lbl.text = "🌍"
	dist_lbl.theme_type_variation = "MonoLabel"
	dist_lbl.add_theme_font_size_override("font_size", 14)
	dist_lbl.add_theme_color_override("font_color", UI.INK_500)
	dist_lbl.custom_minimum_size = Vector2(120, 0)
	dist_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dist_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hbox.add_child(dist_lbl)

	var status_lbl := Label.new()
	status_lbl.theme_type_variation = "MonoLabel"
	status_lbl.add_theme_font_size_override("font_size", 11)
	status_lbl.custom_minimum_size = Vector2(110, 0)
	status_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hbox.add_child(status_lbl)

	row.set_meta("name_lbl", name_lbl)
	row.set_meta("sub_lbl", sub_lbl)
	row.set_meta("num_lbl", num_lbl)
	row.set_meta("dist_lbl", dist_lbl)
	row.set_meta("status_lbl", status_lbl)
	row.set_meta("bar", bar)

	row.gui_input.connect(_on_row_gui_input.bind(idx))
	row.focus_entered.connect(_on_row_focus_entered.bind(idx))
	row.mouse_entered.connect(row.grab_focus)

	return row


func _format_distance(km: int) -> String:
	if km <= 0:
		return "0 КМ"
	if km < 1000:
		return "%d КМ" % km
	var s := "%d" % km
	var grouped := ""
	var i := s.length()
	while i > 0:
		var start: int = max(0, i - 3)
		var chunk := s.substr(start, i - start)
		grouped = chunk + ((" " + grouped) if grouped != "" else "")
		i = start
	return grouped + " КМ"


func _build_locator_contents(panel: Panel) -> void:
	var pad := MarginContainer.new()
	pad.set_anchors_preset(Control.PRESET_FULL_RECT)
	pad.add_theme_constant_override("margin_left", 28)
	pad.add_theme_constant_override("margin_right", 28)
	pad.add_theme_constant_override("margin_top", 24)
	pad.add_theme_constant_override("margin_bottom", 24)
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(pad)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad.add_child(v)

	var k := Label.new()
	k.text = "// LOCATOR · GPS"
	k.theme_type_variation = "MonoLabel"
	k.add_theme_font_size_override("font_size", 11)
	k.add_theme_color_override("font_color", UI.NEON_MAGENTA)
	v.add_child(k)

	_loc_name = Label.new()
	_loc_name.theme_type_variation = "DisplayLabel"
	_loc_name.add_theme_font_override("font", _get_fira_tight())
	_loc_name.add_theme_font_size_override("font_size", 44)
	_loc_name.add_theme_color_override("font_color", UI.INK_900)
	v.add_child(_loc_name)

	_loc_coords = Label.new()
	_loc_coords.theme_type_variation = "MonoLabel"
	_loc_coords.add_theme_font_size_override("font_size", 11)
	_loc_coords.add_theme_color_override("font_color", UI.INK_500)
	v.add_child(_loc_coords)

	v.add_child(_make_spacer(14))

	var frame := Panel.new()
	frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	frame.custom_minimum_size = Vector2(0, 360)
	var fsb := StyleBoxFlat.new()
	fsb.bg_color = Color(0, 0, 0, 0)
	fsb.border_color = UI.INK_300
	fsb.border_width_left = 1
	fsb.border_width_right = 1
	fsb.border_width_top = 1
	fsb.border_width_bottom = 1
	frame.add_theme_stylebox_override("panel", fsb)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(frame)

	_osm_preview = OSMPreviewScript.new()
	_osm_preview.set_anchors_preset(Control.PRESET_FULL_RECT)
	_osm_preview.offset_left = 1.0
	_osm_preview.offset_right = -1.0
	_osm_preview.offset_top = 1.0
	_osm_preview.offset_bottom = -1.0
	_osm_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_osm_preview.clip_contents = true
	frame.add_child(_osm_preview)

	v.add_child(_make_spacer(14))

	var grid := HBoxContainer.new()
	grid.add_theme_constant_override("separation", 14)
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(grid)

	_readout_length = _build_readout("ДЛИНА")
	grid.add_child(_readout_length.get_parent().get_parent())  # the wrap HBox holding bar+col
	_readout_traffic = _build_readout("ТРАФИК")
	grid.add_child(_readout_traffic.get_parent().get_parent())
	_readout_weather = _build_readout("ПОГОДА")
	grid.add_child(_readout_weather.get_parent().get_parent())


func _build_readout(label_text: String) -> Label:
	# Returns the value Label; its grandparent HBox holds bar + col.
	var wrap := HBoxContainer.new()
	wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrap.add_theme_constant_override("separation", 10)
	wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var bar := ColorRect.new()
	bar.color = UI.NEON_CYAN
	bar.custom_minimum_size = Vector2(2, 0)
	bar.size_flags_vertical = Control.SIZE_FILL
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrap.add_child(bar)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrap.add_child(col)

	var lab := Label.new()
	lab.text = label_text
	lab.theme_type_variation = "MonoLabel"
	lab.add_theme_font_size_override("font_size", 9)
	lab.add_theme_color_override("font_color", UI.INK_500)
	col.add_child(lab)

	var val := Label.new()
	val.text = "—"
	val.theme_type_variation = "MonoLabel"
	val.add_theme_font_size_override("font_size", 16)
	val.add_theme_color_override("font_color", UI.NEON_LIME)
	col.add_child(val)
	return val


func _make_p_button(text_value: String) -> Button:
	var btn := Button.new()
	btn.text = text_value
	btn.add_theme_font_size_override("font_size", 18)
	btn.custom_minimum_size = Vector2(180, 50)
	btn.focus_mode = Control.FOCUS_ALL

	var border := UI.NEON_MAGENTA
	var text_color := UI.NEON_MAGENTA
	for state in ["normal", "hover", "pressed", "focus"]:
		var sb: NeonStyleBox = NeonStyleBoxScript.new()
		sb.fill_color = Color(0, 0, 0, 0)
		sb.outline_color = border
		sb.outline_width = 1.0
		sb.shear_deg = -14.0
		sb.glow_color = Color(border.r, border.g, border.b, 0.45)
		sb.glow_size = 14 if state in ["hover", "focus"] else 0
		btn.add_theme_stylebox_override(state, sb)
	btn.add_theme_color_override("font_color", text_color)
	btn.add_theme_color_override("font_hover_color", text_color)
	btn.add_theme_color_override("font_pressed_color", text_color)
	btn.add_theme_color_override("font_focus_color", text_color)
	return btn


# === Focus / interaction ===

func _move_focus(delta: int) -> void:
	if _rows.is_empty():
		return
	_focused_idx = clamp(_focused_idx + delta, 0, _rows.size() - 1)
	_rows[_focused_idx].grab_focus()


func _on_row_gui_input(event: InputEvent, idx: int) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_focused_idx = idx
		_rows[idx].grab_focus()
		_activate_focused()


func _on_row_focus_entered(idx: int) -> void:
	_focused_idx = idx
	_apply_focus()


func _activate_focused() -> void:
	if _focused_idx == _map_row_idx:
		map_requested.emit()
		return
	var loc: Dictionary = LOCATIONS[_focused_idx]
	if String(loc.get("status", "")) == "locked":
		return
	location_chosen.emit(loc)


func _apply_focus() -> void:
	if _focused_sidebar_tween and _focused_sidebar_tween.is_valid():
		_focused_sidebar_tween.kill()
	_focused_sidebar = null

	for i in _rows.size():
		var row: Panel = _rows[i] as Panel
		var is_map := i == _map_row_idx
		var loc: Dictionary = LOCATIONS[i] if not is_map else {}
		var locked: bool = loc.get("status", "") == "locked" if not is_map else false
		var focused := i == _focused_idx
		var accent: Color = UI.NEON_MAGENTA if is_map else UI.NEON_CYAN

		row.modulate.a = 0.55 if locked else 1.0

		var sb := row.get_theme_stylebox("panel") as NeonStyleBox
		if sb:
			if focused:
				sb.fill_color = Color(accent.r, accent.g, accent.b, 0.10)
				sb.outline_color = accent
				sb.outline_width = 1.0
			else:
				sb.fill_color = Color(0.043, 0.055, 0.078, 0.6)
				sb.outline_color = UI.INK_300
				sb.outline_width = 1.0

		var num: Label = row.get_meta("num_lbl") as Label
		num.add_theme_color_override("font_color",
			accent if focused else UI.INK_500)

		var name_lbl: Label = row.get_meta("name_lbl") as Label
		name_lbl.add_theme_color_override("font_color",
			accent if focused else UI.INK_900)

		var dist: Label = row.get_meta("dist_lbl") as Label
		dist.add_theme_color_override("font_color",
			UI.NEON_MAGENTA if focused else UI.INK_500)

		var status: Label = row.get_meta("status_lbl") as Label
		var status_text: String
		var status_color: Color
		if is_map:
			status_text = "↵ MAP" if focused else "MAP"
			status_color = accent if focused else UI.INK_500
		elif locked:
			status_text = "◢ LOCKED"
			status_color = UI.NEON_RED
		elif focused:
			status_text = "↵ GO"
			status_color = UI.NEON_CYAN
		else:
			status_text = "OPEN"
			status_color = UI.INK_500
		status.text = status_text
		status.add_theme_color_override("font_color", status_color)

		var bar: ColorRect = row.get_meta("bar") as ColorRect
		bar.modulate.a = 1.0 if focused else 0.0
		if focused:
			_focused_sidebar = bar

	if _focused_idx != _map_row_idx:
		_apply_locator()
	_start_sidebar_pulse()


func _apply_locator() -> void:
	var loc: Dictionary = LOCATIONS[_focused_idx]
	_loc_name.text = String(loc["ru"]).to_upper()
	_loc_coords.text = _format_coords(float(loc["lat"]), float(loc["lon"]))

	if _osm_preview:
		var path: String = "res://ui/assets/location_chunks/%s.json" % loc["chunk"]
		_osm_preview.set_chunk(path)

	_readout_length.text = _length_for(loc)
	_readout_traffic.text = _traffic_for(loc)
	_readout_weather.text = _weather_for(loc)


func _format_coords(lat: float, lon: float) -> String:
	var lat_d := int(abs(lat))
	var lat_m := int((abs(lat) - lat_d) * 60.0)
	var lon_d := int(abs(lon))
	var lon_m := int((abs(lon) - lon_d) * 60.0)
	var lat_h := "N" if lat >= 0.0 else "S"
	var lon_h := "E" if lon >= 0.0 else "W"
	return "%d°%02d′ %s  %d°%02d′ %s" % [lat_d, lat_m, lat_h, lon_d, lon_m, lon_h]


func _length_for(loc: Dictionary) -> String:
	# Static placeholders keyed by location id so each panel has something.
	var t = {
		"cherepovets": "3.4 КМ", "noviy_vek": "2.8 КМ",
		"ledoviy_dvorets": "4.2 КМ", "oktyabrsky_most": "2.1 КМ",
		"moscow": "5.0 КМ", "tbilisi": "3.6 КМ", "dubai": "6.2 КМ",
	}
	return t.get(loc["chunk"], "—")


func _traffic_for(loc: Dictionary) -> String:
	var t = {
		"cherepovets": "СРЕДНИЙ", "noviy_vek": "СРЕДНИЙ",
		"ledoviy_dvorets": "СЛАБЫЙ", "oktyabrsky_most": "СРЕДНИЙ",
		"moscow": "ВЫСОКИЙ", "tbilisi": "ВЫСОКИЙ", "dubai": "ВЫСОКИЙ",
	}
	return t.get(loc["chunk"], "—")


func _weather_for(loc: Dictionary) -> String:
	var t = {
		"cherepovets": "ЯСНО", "noviy_vek": "ЯСНО",
		"ledoviy_dvorets": "ОБЛАЧНО", "oktyabrsky_most": "ЯСНО",
		"moscow": "ОБЛАЧНО", "tbilisi": "ЯСНО", "dubai": "ЖАРКО",
	}
	return t.get(loc["chunk"], "—")


func _start_sidebar_pulse() -> void:
	if _focused_sidebar == null:
		return
	_focused_sidebar.modulate.a = 1.0
	_focused_sidebar_tween = create_tween().set_loops()
	_focused_sidebar_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_focused_sidebar_tween.tween_property(_focused_sidebar, "modulate:a", 0.35, 0.55)
	_focused_sidebar_tween.tween_property(_focused_sidebar, "modulate:a", 1.0, 0.55)
