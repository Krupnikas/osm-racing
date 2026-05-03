extends Control

## Меню паузы (ПАУЗА).
## По дизайну screens-3.jsx → ScreenPause.

signal resumed
signal restarted
signal exited_to_menu

const BrandMarkScene      = preload("res://ui/components/brand_mark.tscn")
const NeonStyleBoxScript  = preload("res://ui/neon_style_box.gd")
const FiraBoldItalicFont  = preload("res://ui/fonts/FiraSansCondensed-BoldItalic.ttf")

const MENU_ITEMS := [
	{"id": "resume",    "ru": "Продолжить",     "en": "RESUME",    "hint": "Назад в гонку"},
	{"id": "restart",   "ru": "Рестарт",        "en": "RESTART",   "hint": "Заново с начала"},
	{"id": "settings",  "ru": "Настройки",      "en": "SETTINGS",  "hint": "Audio · video · controls"},
	{"id": "main_menu", "ru": "В главное меню", "en": "MAIN MENU", "hint": "Завершить гонку"},
]

static var _fira_tight: FontVariation = null
static func _get_fira_tight() -> FontVariation:
	if _fira_tight == null:
		_fira_tight = FontVariation.new()
		_fira_tight.base_font = FiraBoldItalicFont
		_fira_tight.spacing_glyph = 0
	return _fira_tight

var _is_paused := false
var _is_race_mode := false
var _focused_idx: int = 0
var _rows: Array[Control] = []
var _focused_sidebar_tween: Tween = null
var _focused_sidebar: ColorRect = null
var _restart_label: Label = null   # to swap text in free roam vs race


func _ready() -> void:
	visible = false
	process_mode = Node.PROCESS_MODE_ALWAYS

	_build_ui()

	# Detect race vs free roam to relabel "Restart" appropriately.
	await get_tree().process_frame
	var race_manager = get_tree().current_scene.find_child("RaceManager", true, false)
	if race_manager and race_manager.get("current_track") != null:
		_is_race_mode = true
	elif RaceState.selected_track != null:
		_is_race_mode = true
	else:
		_is_race_mode = false
	_update_restart_label()


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		if _is_paused:
			_resume()
		else:
			_pause()
		get_viewport().set_input_as_handled()
		return
	if not _is_paused or not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
				_activate_focused()


# === UI build ===

func _build_ui() -> void:
	# Dim wash so the frozen race scene shows behind, like the JSX.
	var dim := ColorRect.new()
	dim.color = Color(0.024, 0.031, 0.047, 0.78)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)

	var brand := BrandMarkScene.instantiate() as Control
	brand.position = Vector2(90, 90)
	brand.modulate.a = 0.55
	brand.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(brand)

	# Big "ПАУЗА" outlined magenta on the left half.
	var title_box := VBoxContainer.new()
	title_box.set_anchors_preset(Control.PRESET_TOP_LEFT)
	title_box.offset_left = 120.0
	title_box.offset_top = 220.0
	title_box.offset_right = 1100.0
	title_box.offset_bottom = 700.0
	title_box.add_theme_constant_override("separation", 12)
	title_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(title_box)

	var t_kicker := Label.new()
	t_kicker.text = "// 07 / PAUSED · ПАУЗА"
	t_kicker.theme_type_variation = "MonoLabel"
	t_kicker.add_theme_font_size_override("font_size", 12)
	t_kicker.add_theme_color_override("font_color", UI.NEON_MAGENTA)
	title_box.add_child(t_kicker)

	var title := Label.new()
	title.text = "ПАУЗА"
	title.theme_type_variation = "DisplayLabel"
	title.add_theme_font_override("font", _get_fira_tight())
	title.add_theme_font_size_override("font_size", 220)
	title.add_theme_color_override("font_color", Color(0, 0, 0, 0))
	title.add_theme_color_override("font_outline_color", UI.NEON_MAGENTA)
	title.add_theme_constant_override("outline_size", 3)
	title_box.add_child(title)

	var sub := Label.new()
	sub.text = "ГОНКА ОСТАНОВЛЕНА · ПЕРЕВЕДИ ДЫХАНИЕ"
	sub.theme_type_variation = "MonoLabel"
	sub.add_theme_font_size_override("font_size", 13)
	sub.add_theme_color_override("font_color", UI.INK_500)
	title_box.add_child(sub)

	# Menu list on the right.
	var menu_box := VBoxContainer.new()
	menu_box.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	menu_box.offset_left = -760.0
	menu_box.offset_right = -120.0
	menu_box.offset_top = 220.0
	menu_box.offset_bottom = 720.0
	menu_box.add_theme_constant_override("separation", 14)
	menu_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(menu_box)

	var k := Label.new()
	k.text = "// ОПЦИИ"
	k.theme_type_variation = "MonoLabel"
	k.add_theme_font_size_override("font_size", 12)
	k.add_theme_color_override("font_color", UI.INK_500)
	menu_box.add_child(k)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 12)
	menu_box.add_child(spacer)

	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 10)
	rows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	menu_box.add_child(rows)

	for i in MENU_ITEMS.size():
		var row := _build_menu_row(i, MENU_ITEMS[i])
		_rows.append(row)
		rows.add_child(row)

	# Footer hints.
	var footer := HBoxContainer.new()
	footer.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	footer.offset_left = 120.0
	footer.offset_top = -90.0
	footer.offset_right = 800.0
	footer.offset_bottom = -50.0
	footer.add_theme_constant_override("separation", 36)
	footer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(footer)
	footer.add_child(_make_hint("↑↓", "НАВИГАЦИЯ", UI.NEON_CYAN))
	footer.add_child(_make_hint("↵", "ВЫБОР", UI.NEON_CYAN))
	footer.add_child(_make_hint("ESC", "ПРОДОЛЖИТЬ", UI.NEON_MAGENTA))


func _make_hint(key_text: String, label_text: String, key_color: Color) -> Control:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var key := Label.new()
	key.text = key_text
	key.theme_type_variation = "MonoLabel"
	key.add_theme_font_size_override("font_size", 12)
	key.add_theme_color_override("font_color", key_color)
	box.add_child(key)
	var lbl := Label.new()
	lbl.text = label_text
	lbl.theme_type_variation = "MonoLabel"
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.add_theme_color_override("font_color", UI.INK_500)
	box.add_child(lbl)
	return box


func _build_menu_row(idx: int, item: Dictionary) -> Control:
	var row := Panel.new()
	row.name = "Row_%d" % idx
	row.custom_minimum_size = Vector2(0, 92)
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	row.focus_mode = Control.FOCUS_ALL

	var sb: NeonStyleBox = NeonStyleBoxScript.new()
	sb.fill_color = Color(0.031, 0.039, 0.071, 0.5)
	sb.outline_color = Color(0, 0, 0, 0)
	sb.outline_width = 1.0
	sb.shear_deg = 0.0
	sb.glow_size = 0
	sb.right_slant = 22.0
	row.add_theme_stylebox_override("panel", sb)

	# Cyan sidebar (4px), pulses on focus.
	var bar := ColorRect.new()
	bar.color = UI.NEON_CYAN
	bar.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	bar.offset_right = 4.0
	bar.modulate.a = 0.0
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(bar)

	var hbox := HBoxContainer.new()
	hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	hbox.offset_left = 28.0
	hbox.offset_right = -36.0
	hbox.alignment = BoxContainer.ALIGNMENT_BEGIN
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(hbox)

	var name_box := VBoxContainer.new()
	name_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	name_box.add_theme_constant_override("separation", 4)
	hbox.add_child(name_box)

	var name_lbl := Label.new()
	name_lbl.text = String(item["ru"]).to_upper()
	name_lbl.theme_type_variation = "DisplayLabel"
	name_lbl.add_theme_font_override("font", _get_fira_tight())
	name_lbl.add_theme_font_size_override("font_size", 40)
	name_lbl.add_theme_color_override("font_color", UI.INK_900)
	name_box.add_child(name_lbl)

	var hint_lbl := Label.new()
	hint_lbl.text = String(item["hint"]).to_upper()
	hint_lbl.theme_type_variation = "MonoLabel"
	hint_lbl.add_theme_font_size_override("font_size", 10)
	hint_lbl.add_theme_color_override("font_color", UI.INK_500)
	name_box.add_child(hint_lbl)

	var en_lbl := Label.new()
	en_lbl.text = "%02d · %s" % [idx + 1, item["en"]]
	en_lbl.theme_type_variation = "MonoLabel"
	en_lbl.add_theme_font_size_override("font_size", 11)
	en_lbl.add_theme_color_override("font_color", UI.INK_500)
	en_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hbox.add_child(en_lbl)

	row.set_meta("name_lbl", name_lbl)
	row.set_meta("en_lbl", en_lbl)
	row.set_meta("bar", bar)

	if String(item["id"]) == "restart":
		_restart_label = name_lbl

	row.gui_input.connect(_on_row_gui_input.bind(idx))
	row.focus_entered.connect(_on_row_focus_entered.bind(idx))
	row.mouse_entered.connect(row.grab_focus)

	return row


func _update_restart_label() -> void:
	if _restart_label == null:
		return
	_restart_label.text = "РЕСТАРТ" if _is_race_mode else "ПЕРЕЗАГРУЗИТЬ ЛОКАЦИЮ"


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
	var item: Dictionary = MENU_ITEMS[_focused_idx]
	match String(item["id"]):
		"resume":    _resume()
		"restart":   _on_restart_pressed()
		"settings":  _on_settings_pressed()
		"main_menu": _on_main_menu_pressed()


func _apply_focus() -> void:
	if _focused_sidebar_tween and _focused_sidebar_tween.is_valid():
		_focused_sidebar_tween.kill()
	_focused_sidebar = null

	for i in _rows.size():
		var row: Panel = _rows[i] as Panel
		var focused := i == _focused_idx
		var sb := row.get_theme_stylebox("panel") as NeonStyleBox
		if sb:
			if focused:
				sb.fill_color = Color(UI.NEON_CYAN.r, UI.NEON_CYAN.g, UI.NEON_CYAN.b, 0.10)
				sb.outline_color = UI.NEON_CYAN
			else:
				sb.fill_color = Color(0.031, 0.039, 0.071, 0.5)
				sb.outline_color = Color(0, 0, 0, 0)

		var name_lbl: Label = row.get_meta("name_lbl") as Label
		name_lbl.add_theme_color_override("font_color",
			UI.NEON_CYAN if focused else UI.INK_900)

		var en_lbl: Label = row.get_meta("en_lbl") as Label
		en_lbl.add_theme_color_override("font_color",
			UI.NEON_MAGENTA if focused else UI.INK_500)

		var bar: ColorRect = row.get_meta("bar") as ColorRect
		bar.modulate.a = 1.0 if focused else 0.0
		if focused:
			_focused_sidebar = bar

	if _focused_sidebar:
		_focused_sidebar.modulate.a = 1.0
		_focused_sidebar_tween = create_tween().set_loops()
		_focused_sidebar_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		_focused_sidebar_tween.tween_property(_focused_sidebar, "modulate:a", 0.35, 0.55)
		_focused_sidebar_tween.tween_property(_focused_sidebar, "modulate:a", 1.0, 0.55)


# === Pause control ===

func _pause() -> void:
	_is_paused = true
	visible = true
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if _rows.size() > 0:
		_rows[0].call_deferred("grab_focus")


func _resume() -> void:
	_is_paused = false
	visible = false
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	resumed.emit()


func _on_resume_pressed() -> void:
	_resume()


func _on_restart_pressed() -> void:
	_is_paused = false
	get_tree().paused = false
	restarted.emit()
	get_tree().reload_current_scene()


func _on_settings_pressed() -> void:
	# TODO: surface an in-race settings dialog.
	push_warning("Pause: settings panel not yet wired in-race")


func _on_main_menu_pressed() -> void:
	_is_paused = false
	get_tree().paused = false
	if MusicManager:
		MusicManager.play_next_track()
	exited_to_menu.emit()
	get_tree().change_scene_to_file("res://ui/standalone_main_menu.tscn")
