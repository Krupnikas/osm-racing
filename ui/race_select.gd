extends Control

## Экран выбора гонки (ВЫЗОВЫ).
## По дизайну screens-2.jsx → ScreenRaceMenu.

signal race_chosen(track)
signal back_requested

const RaceTrackScript     = preload("res://race/race_tracks.gd")
const BrandMarkScene      = preload("res://ui/components/brand_mark.tscn")
const CornerChromeScript  = preload("res://ui/components/corner_chrome.gd")
const NeonStyleBoxScript  = preload("res://ui/neon_style_box.gd")
const FiraBoldItalicFont  = preload("res://ui/fonts/FiraSansCondensed-BoldItalic.ttf")

# Per-track metadata. Tracks come from race_tracks.gd; the locked
# placeholder at the end matches the JSX render.
const TRACK_META := {
	"pionerskaya":   {"type": "СПРИНТ", "laps": "1 LAP / 2.4 КМ",  "diff": 2},
	"fanera":        {"type": "ЧЕКПОИНТ","laps": "5 CHECKS / 3.1 КМ","diff": 3},
	"fanera_sprint": {"type": "СПРИНТ", "laps": "1 LAP / 3.8 КМ",  "diff": 4},
}

const LOCKED_RACE := {
	"name": "Заводская",
	"type": "ДРЭГ",
	"laps": "1/4 МИЛИ",
	"prize": 40000,
	"entry": 10000,
	"diff": 5,
	"unlock_level": 5,
}

static var _fira_tight: FontVariation = null
static func _get_fira_tight() -> FontVariation:
	if _fira_tight == null:
		_fira_tight = FontVariation.new()
		_fira_tight.base_font = FiraBoldItalicFont
		_fira_tight.spacing_glyph = 0
	return _fira_tight

var _focused_idx: int = 0
var _rows: Array[Control] = []
var _entries: Array = []  # per-row entry dict (track or locked)
var _focused_sidebar: ColorRect = null
var _focused_sidebar_tween: Tween = null


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
	t_kicker.text = "// 05 / CHALLENGES · ВЫЗОВЫ"
	t_kicker.theme_type_variation = "MonoLabel"
	t_kicker.add_theme_font_size_override("font_size", 12)
	t_kicker.add_theme_color_override("font_color", UI.NEON_MAGENTA)
	t_kicker.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	title_box.add_child(t_kicker)

	var t1 := Label.new()
	t1.text = "ВЫЗОВЫ"
	t1.theme_type_variation = "DisplayLabel"
	t1.add_theme_font_size_override("font_size", 96)
	t1.add_theme_color_override("font_color", UI.INK_900)
	t1.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	title_box.add_child(t1)

	var t_sub := Label.new()
	t_sub.text = "ЛОКАЦИЯ: НОВЫЙ ВЕК · 4 ГОНКИ"
	t_sub.theme_type_variation = "MonoLabel"
	t_sub.add_theme_font_size_override("font_size", 13)
	t_sub.add_theme_color_override("font_color", UI.INK_500)
	t_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	title_box.add_child(t_sub)

	# Race list
	_entries = _build_entries()
	var list := VBoxContainer.new()
	list.set_anchors_preset(Control.PRESET_FULL_RECT)
	list.offset_left = 120.0
	list.offset_right = -120.0
	list.offset_top = 320.0
	list.offset_bottom = -140.0
	list.add_theme_constant_override("separation", 18)
	list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(list)

	for i in _entries.size():
		var row := _build_race_row(i, _entries[i])
		_rows.append(row)
		list.add_child(row)

	# Back button bottom-left
	var back_btn := _make_p_button("← НАЗАД")
	back_btn.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	back_btn.offset_left = 120.0
	back_btn.offset_top = -110.0
	back_btn.offset_right = 280.0
	back_btn.offset_bottom = -60.0
	back_btn.pressed.connect(func(): back_requested.emit())
	add_child(back_btn)

	# Corner chrome
	var chrome := Control.new()
	chrome.set_script(CornerChromeScript)
	chrome.set_anchors_preset(Control.PRESET_FULL_RECT)
	chrome.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(chrome)


func _build_entries() -> Array:
	var out: Array = []
	for track in RaceTrackScript.get_all_tracks():
		if track == null:
			continue
		var meta: Dictionary = TRACK_META.get(track.track_id, {
			"type": track.race_mode.to_upper(),
			"laps": "—",
			"diff": 2,
		})
		out.append({
			"locked": false,
			"track": track,
			"name": String(track.track_name),
			"type": String(meta.get("type", "")),
			"laps": String(meta.get("laps", "")),
			"diff": int(meta.get("diff", 2)),
			"prize": CareerState.get_challenge_prize(track.track_id),
			"entry": CareerState.get_entry_fee(track.track_id),
		})
	out.append({
		"locked": true,
		"track": null,
		"name": String(LOCKED_RACE["name"]),
		"type": String(LOCKED_RACE["type"]),
		"laps": String(LOCKED_RACE["laps"]),
		"diff": int(LOCKED_RACE["diff"]),
		"prize": int(LOCKED_RACE["prize"]),
		"entry": int(LOCKED_RACE["entry"]),
		"unlock_level": int(LOCKED_RACE["unlock_level"]),
	})
	return out


func _build_race_row(idx: int, entry: Dictionary) -> Control:
	var row := Panel.new()
	row.name = "Row_%d" % idx
	row.custom_minimum_size = Vector2(0, 124)
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	row.focus_mode = Control.FOCUS_ALL

	var sb: NeonStyleBox = NeonStyleBoxScript.new()
	sb.fill_color = Color(UI.INK_050.r, UI.INK_050.g, UI.INK_050.b, 0.6)
	sb.outline_color = UI.INK_300
	sb.outline_width = 1.0
	sb.shear_deg = 0.0
	sb.glow_size = 0
	sb.right_slant = 22.0
	row.add_theme_stylebox_override("panel", sb)

	# Magenta sidebar (8px), pulses on focus.
	var bar := ColorRect.new()
	bar.color = UI.NEON_MAGENTA
	bar.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	bar.offset_right = 8.0
	bar.modulate.a = 0.0
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(bar)

	# Content split: name block | prize | entry | difficulty | action.
	var hbox := HBoxContainer.new()
	hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	hbox.offset_left = 28.0
	hbox.offset_right = -36.0
	hbox.add_theme_constant_override("separation", 0)
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(hbox)

	# 1) Name block
	var name_box := VBoxContainer.new()
	name_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	name_box.add_theme_constant_override("separation", 4)
	hbox.add_child(name_box)

	var type_kicker := Label.new()
	type_kicker.text = "%02d · %s" % [idx + 1, entry["type"]]
	type_kicker.theme_type_variation = "MonoLabel"
	type_kicker.add_theme_font_size_override("font_size", 11)
	type_kicker.add_theme_color_override("font_color", UI.INK_500)
	name_box.add_child(type_kicker)

	var name_lbl := Label.new()
	name_lbl.text = String(entry["name"]).to_upper()
	name_lbl.theme_type_variation = "DisplayLabel"
	name_lbl.add_theme_font_override("font", _get_fira_tight())
	name_lbl.add_theme_font_size_override("font_size", 44)
	name_lbl.add_theme_color_override("font_color", UI.INK_700)
	name_box.add_child(name_lbl)

	var laps_lbl := Label.new()
	laps_lbl.text = String(entry["laps"])
	laps_lbl.theme_type_variation = "MonoLabel"
	laps_lbl.add_theme_font_size_override("font_size", 11)
	laps_lbl.add_theme_color_override("font_color", UI.INK_500)
	name_box.add_child(laps_lbl)

	# 2) Prize cell
	hbox.add_child(_build_value_cell("ПРИЗ", _format_money(int(entry["prize"])), UI.NEON_LIME))

	# 3) Entry cell
	hbox.add_child(_build_value_cell("ВЗНОС", _format_money(int(entry["entry"])), UI.NEON_MAGENTA))

	# 4) Difficulty bars
	var diff_cell := _build_difficulty_cell(int(entry["diff"]))
	hbox.add_child(diff_cell)

	# 5) Action — fixed-width Control with absolutely-positioned child so
	# the button doesn't get stretched to the full row height by the HBox
	# Container layout.
	var action := Control.new()
	action.custom_minimum_size = Vector2(180, 0)
	action.size_flags_vertical = Control.SIZE_FILL
	action.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(action)

	var action_inner: Control
	if entry.get("locked", false):
		var lock_lbl := Label.new()
		lock_lbl.text = "◢ LVL %d" % int(entry.get("unlock_level", 5))
		lock_lbl.theme_type_variation = "MonoLabel"
		lock_lbl.add_theme_font_size_override("font_size", 12)
		lock_lbl.add_theme_color_override("font_color", UI.NEON_RED)
		lock_lbl.set_anchors_preset(Control.PRESET_FULL_RECT)
		lock_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lock_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		action_inner = lock_lbl
	else:
		var go_btn := _make_race_button(idx)
		action_inner = go_btn
	action.add_child(action_inner)

	# Stash refs.
	row.set_meta("bar", bar)
	row.set_meta("type_kicker", type_kicker)
	row.set_meta("name_lbl", name_lbl)
	row.set_meta("action_inner", action_inner)

	row.gui_input.connect(_on_row_gui_input.bind(idx))
	row.focus_entered.connect(_on_row_focus_entered.bind(idx))
	row.mouse_entered.connect(row.grab_focus)

	return row


func _build_value_cell(label_text: String, value_text: String, value_color: Color) -> Control:
	var cell := PanelContainer.new()
	cell.custom_minimum_size = Vector2(220, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.border_color = UI.INK_300
	sb.border_width_left = 1
	sb.content_margin_left = 22
	sb.content_margin_right = 18
	sb.content_margin_top = 18
	sb.content_margin_bottom = 18
	cell.add_theme_stylebox_override("panel", sb)

	var v := VBoxContainer.new()
	v.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	v.add_theme_constant_override("separation", 6)
	cell.add_child(v)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.theme_type_variation = "MonoLabel"
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.add_theme_color_override("font_color", UI.INK_500)
	v.add_child(lbl)

	var val := Label.new()
	val.text = value_text
	val.theme_type_variation = "MonoLabel"
	val.add_theme_font_size_override("font_size", 22)
	val.add_theme_color_override("font_color", value_color)
	v.add_child(val)
	return cell


func _build_difficulty_cell(diff: int) -> Control:
	var cell := PanelContainer.new()
	cell.custom_minimum_size = Vector2(180, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.border_color = UI.INK_300
	sb.border_width_left = 1
	sb.content_margin_left = 22
	sb.content_margin_right = 18
	sb.content_margin_top = 18
	sb.content_margin_bottom = 18
	cell.add_theme_stylebox_override("panel", sb)

	var v := VBoxContainer.new()
	v.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	v.add_theme_constant_override("separation", 8)
	cell.add_child(v)

	var lbl := Label.new()
	lbl.text = "СЛОЖНОСТЬ"
	lbl.theme_type_variation = "MonoLabel"
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.add_theme_color_override("font_color", UI.INK_500)
	v.add_child(lbl)

	var bars := HBoxContainer.new()
	bars.add_theme_constant_override("separation", 4)
	v.add_child(bars)
	for i in range(5):
		var seg := ColorRect.new()
		seg.custom_minimum_size = Vector2(18, 8)
		seg.color = UI.NEON_MAGENTA if i < diff else UI.INK_300
		seg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		bars.add_child(seg)
	return cell


func _make_race_button(idx: int) -> Button:
	# Small parallelogram button per JSX size="sm": transparent fill, faint
	# outline by default, cyan tint on hover, sized to the cell — not the
	# full row height.
	var btn := Button.new()
	btn.text = "ГОНКА !"
	btn.add_theme_font_size_override("font_size", 14)
	btn.custom_minimum_size = Vector2(120, 36)
	btn.focus_mode = Control.FOCUS_NONE
	btn.set_anchors_preset(Control.PRESET_CENTER)
	btn.offset_left = -60.0
	btn.offset_right = 60.0
	btn.offset_top = -18.0
	btn.offset_bottom = 18.0

	var sb_normal: NeonStyleBox = NeonStyleBoxScript.new()
	sb_normal.fill_color = Color(0, 0, 0, 0)
	sb_normal.outline_color = UI.INK_400
	sb_normal.outline_width = 1.0
	sb_normal.shear_deg = -14.0
	sb_normal.glow_size = 0

	var sb_hover: NeonStyleBox = NeonStyleBoxScript.new()
	sb_hover.fill_color = Color(UI.NEON_CYAN.r, UI.NEON_CYAN.g, UI.NEON_CYAN.b, 0.10)
	sb_hover.outline_color = UI.NEON_CYAN
	sb_hover.outline_width = 1.0
	sb_hover.shear_deg = -14.0
	sb_hover.glow_color = Color(UI.NEON_CYAN.r, UI.NEON_CYAN.g, UI.NEON_CYAN.b, 0.45)
	sb_hover.glow_size = 12

	btn.add_theme_stylebox_override("normal", sb_normal)
	btn.add_theme_stylebox_override("focus", sb_normal)
	btn.add_theme_stylebox_override("hover", sb_hover)
	btn.add_theme_stylebox_override("pressed", sb_hover)
	btn.add_theme_color_override("font_color", UI.INK_700)
	btn.add_theme_color_override("font_hover_color", UI.NEON_CYAN)
	btn.add_theme_color_override("font_pressed_color", UI.NEON_CYAN)
	btn.add_theme_color_override("font_focus_color", UI.INK_700)
	btn.pressed.connect(_activate_idx.bind(idx))
	return btn


func _make_p_button(text_value: String) -> Button:
	var btn := Button.new()
	btn.text = text_value
	btn.add_theme_font_size_override("font_size", 18)
	btn.custom_minimum_size = Vector2(180, 50)
	btn.focus_mode = Control.FOCUS_ALL
	for state in ["normal", "hover", "pressed", "focus"]:
		var sb: NeonStyleBox = NeonStyleBoxScript.new()
		sb.fill_color = Color(0, 0, 0, 0)
		sb.outline_color = UI.NEON_MAGENTA
		sb.outline_width = 1.0
		sb.shear_deg = -14.0
		sb.glow_color = Color(UI.NEON_MAGENTA.r, UI.NEON_MAGENTA.g, UI.NEON_MAGENTA.b, 0.45)
		sb.glow_size = 14 if state in ["hover", "focus"] else 0
		btn.add_theme_stylebox_override(state, sb)
	btn.add_theme_color_override("font_color", UI.NEON_MAGENTA)
	btn.add_theme_color_override("font_hover_color", UI.NEON_MAGENTA)
	btn.add_theme_color_override("font_pressed_color", UI.NEON_MAGENTA)
	btn.add_theme_color_override("font_focus_color", UI.NEON_MAGENTA)
	return btn


# === Focus / activation ===

func _on_row_gui_input(event: InputEvent, idx: int) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_focused_idx = idx
		_rows[idx].grab_focus()
		_activate_focused()


func _on_row_focus_entered(idx: int) -> void:
	_focused_idx = idx
	_apply_focus()


func _activate_focused() -> void:
	_activate_idx(_focused_idx)


func _activate_idx(idx: int) -> void:
	var entry: Dictionary = _entries[idx]
	if entry.get("locked", false):
		return
	var track = entry.get("track")
	if track:
		race_chosen.emit(track)


func _apply_focus() -> void:
	if _focused_sidebar_tween and _focused_sidebar_tween.is_valid():
		_focused_sidebar_tween.kill()
	_focused_sidebar = null

	for i in _rows.size():
		var row: Panel = _rows[i] as Panel
		var entry: Dictionary = _entries[i]
		var locked: bool = entry.get("locked", false)
		var focused := i == _focused_idx

		row.modulate.a = 0.45 if locked else 1.0

		var sb := row.get_theme_stylebox("panel") as NeonStyleBox
		if sb:
			if focused:
				sb.fill_color = Color(UI.NEON_MAGENTA.r, UI.NEON_MAGENTA.g, UI.NEON_MAGENTA.b, 0.08)
				sb.outline_color = UI.NEON_MAGENTA
			else:
				sb.fill_color = Color(UI.INK_050.r, UI.INK_050.g, UI.INK_050.b, 0.6)
				sb.outline_color = UI.INK_300

		var type_kicker: Label = row.get_meta("type_kicker") as Label
		type_kicker.add_theme_color_override("font_color",
			UI.NEON_MAGENTA if focused else UI.INK_500)

		var name_lbl: Label = row.get_meta("name_lbl") as Label
		name_lbl.add_theme_color_override("font_color",
			UI.INK_900 if focused else UI.INK_700)

		var bar: ColorRect = row.get_meta("bar") as ColorRect
		bar.modulate.a = 1.0 if focused else 0.0
		if focused and not locked:
			_focused_sidebar = bar

	_start_sidebar_pulse()


func _start_sidebar_pulse() -> void:
	if _focused_sidebar == null:
		return
	_focused_sidebar.modulate.a = 1.0
	_focused_sidebar_tween = create_tween().set_loops()
	_focused_sidebar_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_focused_sidebar_tween.tween_property(_focused_sidebar, "modulate:a", 0.35, 0.55)
	_focused_sidebar_tween.tween_property(_focused_sidebar, "modulate:a", 1.0, 0.55)


func _format_money(amount: int) -> String:
	var s := "%d" % int(abs(amount))
	var grouped := ""
	var i := s.length()
	while i > 0:
		var start: int = max(0, i - 3)
		var chunk := s.substr(start, i - start)
		grouped = chunk + ((" " + grouped) if grouped != "" else "")
		i = start
	return grouped + " ₽"
