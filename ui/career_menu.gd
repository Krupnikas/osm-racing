extends Control

## Меню карьеры в стиле NFS Underground
##
## Экраны:
## 1. Выбор/создание профиля
## 2. Хаб карьеры (баланс, гараж, магазин, выезд в город, вызовы)
## 3. Гараж (свои машины)
## 4. Магазин (покупка машин)
## 5. Выбор локации (свободная езда)
## 6. Вызовы (гонки с призовыми)

const RaceTrackScript = preload("res://race/race_tracks.gd")
const BrandMarkScene = preload("res://ui/components/brand_mark.tscn")
const MenuBackdropScene = preload("res://ui/MenuBackdrop.tscn")
const CornerChromeScript = preload("res://ui/components/corner_chrome.gd")
const NeonStyleBoxScript = preload("res://ui/neon_style_box.gd")
const DashedBorderScript = preload("res://ui/dashed_border.gd")
const FiraBoldItalicFont = preload("res://ui/fonts/FiraSansCondensed-BoldItalic.ttf")
const CarSelectionScene = preload("res://ui/car_selection.tscn")
const PROFILE_SAVE_PATH := "user://career_profiles.cfg"

# Profile-row name font without the wide title tracking.
static var _fira_tight: FontVariation = null
static func _get_fira_tight() -> FontVariation:
	if _fira_tight == null:
		_fira_tight = FontVariation.new()
		_fira_tight.base_font = FiraBoldItalicFont
		_fira_tight.spacing_glyph = 0
	return _fira_tight

# Локации для свободной езды (те же что в главном меню)
const LOCATIONS := {
	"Череповец": [59.150406, 37.948805],
	"Новый Век": [59.123567, 37.982864],
	"Ледовый дворец": [59.089216, 37.917488],
	"Москва (Отрадное)": [55.860580, 37.599646],
	"Тбилиси (Важа-Пшавела)": [41.723972, 44.730502],
	"Дубай (Крик)": [25.208591, 55.344100],
}

signal back_to_main_menu

var _profile_panel: Control
var _hub_panel: Control
var _garage_panel: Panel
var _garage_carsel: Control = null
var _shop_panel: Control
var _create_panel: Panel
var _delete_confirm_panel: Panel
var _location_panel: Panel
var _challenges_panel: Panel
var _tuning_panel: Panel
var _sell_confirm_panel: Panel
var _delete_profile_name: String = ""
var _sell_car_id: String = ""
var _tuning_car_id: String = ""

var _focused_sidebar: ColorRect = null
var _focused_sidebar_tween: Tween = null
var _shop_scroll: ScrollContainer = null

# Прямые ссылки на контейнеры
var _profiles_container: VBoxContainer
var _name_input: LineEdit
var _delete_title: Label
var _hub_profile_label: Label
var _hub_balance_label: Label
var _hub_stats_label: Label
var _hub_car_label: Label
var _hub_freeroam_btn: HBoxContainer
var _hub_challenges_btn: HBoxContainer
var _garage_cars_container: VBoxContainer
var _shop_balance_label: Label
var _shop_cars_container: VBoxContainer
var _challenges_container: VBoxContainer
var _tuning_container: VBoxContainer
var _tuning_title: Label
var _tuning_balance: Label
var _sell_title: Label
var _sell_price_label: Label


func _ready() -> void:
	visible = false
	_build_profile_panel()
	_build_create_panel()
	_build_delete_confirm_panel()
	_build_hub_panel()
	_build_garage_panel()
	_build_shop_panel()
	_build_location_panel()
	_build_challenges_panel()
	_build_tuning_panel()
	_build_sell_confirm_panel()


func show_menu() -> void:
	visible = true
	_show_profile_screen()


func hide_menu() -> void:
	visible = false
	_hide_all()


# === Построение UI ===

func _build_profile_panel() -> void:
	# Full-rect screen per design spec 02-career.
	_profile_panel = Control.new()
	_profile_panel.name = "ProfileScreen"
	_profile_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_profile_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_profile_panel)

	var bg := MenuBackdropScene.instantiate()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_profile_panel.add_child(bg)

	# Brand mark top-left — same as main menu, just smaller scale.
	var brand := BrandMarkScene.instantiate() as Control
	brand.scale = Vector2(0.85, 0.85)
	brand.position = Vector2(90, 80)
	brand.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_profile_panel.add_child(brand)

	# Title block — kicker first, then the two H2s overlapping by design.
	var title_box := VBoxContainer.new()
	title_box.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	title_box.offset_left = -1100.0
	title_box.offset_right = -90.0
	title_box.offset_top = 80.0
	title_box.offset_bottom = 360.0
	title_box.alignment = BoxContainer.ALIGNMENT_BEGIN
	title_box.add_theme_constant_override("separation", 8)
	title_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_profile_panel.add_child(title_box)

	var t_kicker := Label.new()
	t_kicker.text = "// 02 / CAREEER · КАРЬЕРА"
	t_kicker.theme_type_variation = "MonoLabel"
	t_kicker.add_theme_font_size_override("font_size", 12)
	t_kicker.modulate = UI.NEON_MAGENTA
	t_kicker.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	title_box.add_child(t_kicker)

	# Inner stack with the two H2s overlapping.
	var h2_stack := VBoxContainer.new()
	h2_stack.add_theme_constant_override("separation", -54)
	h2_stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_box.add_child(h2_stack)

	var t1 := Label.new()
	t1.text = "КАРЬЕРА"
	t1.theme_type_variation = "DisplayLabel"
	t1.add_theme_font_size_override("font_size", 96)
	t1.add_theme_color_override("font_color", UI.INK_900)
	t1.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	h2_stack.add_child(t1)

	var t2 := Label.new()
	t2.text = "ВЫБОР ПРОФИЛЯ"
	t2.theme_type_variation = "DisplayLabel"
	t2.add_theme_font_size_override("font_size", 96)
	t2.add_theme_color_override("font_color", Color(0, 0, 0, 0))
	t2.add_theme_color_override("font_outline_color", UI.NEON_MAGENTA)
	t2.add_theme_constant_override("outline_size", 2)
	t2.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	h2_stack.add_child(t2)

	# Profile list — centered horizontally below the title
	var list := VBoxContainer.new()
	list.set_anchors_preset(Control.PRESET_TOP_WIDE)
	list.offset_left = 200.0
	list.offset_right = -200.0
	list.offset_top = 320.0
	list.offset_bottom = 920.0
	list.add_theme_constant_override("separation", 18)
	list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_profile_panel.add_child(list)

	var sub_kicker := Label.new()
	sub_kicker.text = "// ВЫБЕРИТЕ ПРОФИЛЬ · SELECT PROFILE"
	sub_kicker.theme_type_variation = "MonoLabel"
	sub_kicker.add_theme_font_size_override("font_size", 12)
	sub_kicker.modulate = UI.INK_500
	list.add_child(sub_kicker)

	_profiles_container = VBoxContainer.new()
	_profiles_container.add_theme_constant_override("separation", 14)
	_profiles_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	list.add_child(_profiles_container)

	var new_row := _build_new_profile_row()
	list.add_child(new_row)

	# Back button bottom-left
	var back_btn := Button.new()
	back_btn.text = "← НАЗАД"
	back_btn.theme_type_variation = "MenuRow"
	back_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	back_btn.add_theme_font_size_override("font_size", 24)
	back_btn.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	back_btn.offset_left = 200.0
	back_btn.offset_top = -130.0
	back_btn.offset_right = 360.0
	back_btn.offset_bottom = -90.0
	back_btn.pressed.connect(_on_profile_back)
	_profile_panel.add_child(back_btn)

	# Corner chrome on top
	var chrome := Control.new()
	chrome.set_script(CornerChromeScript)
	chrome.set_anchors_preset(Control.PRESET_FULL_RECT)
	chrome.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_profile_panel.add_child(chrome)


func _get_profile_meta(profile_name: String) -> Dictionary:
	var config := ConfigFile.new()
	if config.load(PROFILE_SAVE_PATH) != OK or not config.has_section(profile_name):
		return {"balance": 0, "cars": 0, "races": 0, "level": 1}
	var balance: int = config.get_value(profile_name, "balance", 0)
	var cars_arr: Array = config.get_value(profile_name, "owned_cars", [])
	var total_races: int = config.get_value(profile_name, "total_races", 0)
	var level: int = max(1, total_races / 5 + 1)
	return {
		"balance": balance,
		"cars": cars_arr.size(),
		"races": total_races,
		"level": level,
	}


func _build_cell(label_text: String, value_text: String, value_color: Color = UI.NEON_LIME) -> Control:
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
	v.add_theme_constant_override("separation", 6)
	cell.add_child(v)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.theme_type_variation = "MonoLabel"
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.modulate = UI.INK_500
	v.add_child(lbl)

	var val := Label.new()
	val.text = value_text
	val.theme_type_variation = "MonoLabel"
	val.add_theme_font_size_override("font_size", 22)
	val.modulate = value_color
	v.add_child(val)

	return cell


func _build_profile_row(profile_name: String, focused: bool) -> Control:
	var meta := _get_profile_meta(profile_name)

	var row := Panel.new()
	row.custom_minimum_size = Vector2(0, 96)
	var sb: NeonStyleBox = NeonStyleBoxScript.new()
	sb.fill_color = UI.INK_100
	sb.outline_color = UI.NEON_CYAN if focused else UI.INK_300
	sb.outline_width = 1.0
	sb.shear_deg = 0.0
	sb.slashed = true
	sb.slash_size = 18.0
	sb.glow_size = 0
	row.add_theme_stylebox_override("panel", sb)
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	row.focus_mode = Control.FOCUS_ALL
	row.gui_input.connect(_on_row_gui_input.bind(profile_name))

	# Side bar
	var bar := ColorRect.new()
	bar.name = "SideBar"
	bar.color = UI.NEON_CYAN if focused else UI.INK_400
	bar.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	bar.offset_right = 6.0
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(bar)
	if focused:
		_focused_sidebar = bar

	# Content HBox
	var hbox := HBoxContainer.new()
	hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	hbox.offset_left = 6.0
	hbox.add_theme_constant_override("separation", 0)
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(hbox)

	var spacer_left := Control.new()
	spacer_left.custom_minimum_size = Vector2(28, 0)
	spacer_left.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(spacer_left)

	var name_box := VBoxContainer.new()
	name_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	name_box.add_theme_constant_override("separation", 4)
	hbox.add_child(name_box)

	var name_label := Label.new()
	name_label.name = "NameLabel"
	name_label.text = profile_name.to_upper()
	name_label.theme_type_variation = "DisplayLabel"
	name_label.add_theme_font_override("font", _get_fira_tight())
	name_label.add_theme_font_size_override("font_size", 44)
	name_label.add_theme_color_override("font_color", UI.NEON_CYAN if focused else UI.INK_900)
	name_box.add_child(name_label)

	var sub := Label.new()
	sub.text = "УРОВЕНЬ %d · ИГРОК" % int(meta["level"])
	sub.theme_type_variation = "MonoLabel"
	sub.add_theme_font_size_override("font_size", 11)
	sub.modulate = UI.INK_500
	name_box.add_child(sub)

	hbox.add_child(_build_cell("БАЛАНС", CareerState.format_money(int(meta["balance"]))))
	hbox.add_child(_build_cell("МАШИН", str(int(meta["cars"]))))
	hbox.add_child(_build_cell("ГОНОК", str(int(meta["races"]))))

	# Action column
	var action_cell := PanelContainer.new()
	action_cell.name = "ActionCell"
	action_cell.custom_minimum_size = Vector2(140, 0)
	var action_sb := StyleBoxFlat.new()
	action_sb.bg_color = Color(0, 0, 0, 0)
	action_sb.border_color = UI.INK_300
	action_sb.border_width_left = 1
	action_cell.add_theme_stylebox_override("panel", action_sb)
	hbox.add_child(action_cell)

	var enter := Label.new()
	enter.name = "EnterLabel"
	enter.text = "↵ ВОЙТИ"
	enter.theme_type_variation = "MonoLabel"
	enter.add_theme_font_size_override("font_size", 12)
	enter.modulate = UI.NEON_CYAN
	enter.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	enter.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	enter.visible = focused
	action_cell.add_child(enter)

	var x_btn := Button.new()
	x_btn.name = "DeleteBtn"
	x_btn.text = "✕"
	x_btn.flat = true
	x_btn.add_theme_color_override("font_color", UI.NEON_RED)
	x_btn.add_theme_font_size_override("font_size", 18)
	x_btn.pressed.connect(_on_delete_profile_pressed.bind(profile_name))
	x_btn.visible = not focused
	action_cell.add_child(x_btn)

	# Dynamic focus highlight
	row.focus_entered.connect(_on_profile_row_focus.bind(row, true))
	row.focus_exited.connect(_on_profile_row_focus.bind(row, false))
	row.mouse_entered.connect(func(): row.grab_focus())

	return row


func _on_profile_row_focus(row: Panel, is_focused: bool) -> void:
	# Outline
	var sb: NeonStyleBox = row.get_theme_stylebox("panel") as NeonStyleBox
	if sb:
		sb.outline_color = UI.NEON_CYAN if is_focused else UI.INK_300
		row.queue_redraw()
	# Sidebar
	var bar: ColorRect = row.get_node_or_null("SideBar")
	if bar:
		bar.color = UI.NEON_CYAN if is_focused else UI.INK_400
		if is_focused:
			_focused_sidebar = bar
			_start_sidebar_pulse(bar)
		elif _focused_sidebar == bar:
			if _focused_sidebar_tween and _focused_sidebar_tween.is_valid():
				_focused_sidebar_tween.kill()
			bar.modulate.a = 1.0
			_focused_sidebar = null
	# Name label color
	var name_lbl: Label = row.find_child("NameLabel", true, false) as Label
	if name_lbl:
		name_lbl.add_theme_color_override("font_color", UI.NEON_CYAN if is_focused else UI.INK_900)
	# Action cell: show enter / delete
	var enter_lbl: Label = row.find_child("EnterLabel", true, false) as Label
	var del_btn: Button = row.find_child("DeleteBtn", true, false) as Button
	if enter_lbl:
		enter_lbl.visible = is_focused
	if del_btn:
		del_btn.visible = not is_focused


func _build_new_profile_row() -> Control:
	# Faint lime bg + dashed lime border drawn at the panel edges. Same row
	# height as profile rows. Focusable so arrow keys / tab can land on it.
	var row := Panel.new()
	row.name = "NewProfileRow"
	row.custom_minimum_size = Vector2(0, 96)
	var sb_normal := StyleBoxFlat.new()
	sb_normal.bg_color = Color(UI.NEON_LIME.r, UI.NEON_LIME.g, UI.NEON_LIME.b, 0.04)
	var sb_hover := StyleBoxFlat.new()
	sb_hover.bg_color = Color(UI.NEON_LIME.r, UI.NEON_LIME.g, UI.NEON_LIME.b, 0.16)
	row.add_theme_stylebox_override("panel", sb_normal)
	row.set_meta("sb_normal", sb_normal)
	row.set_meta("sb_hover", sb_hover)
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	row.focus_mode = Control.FOCUS_ALL
	row.gui_input.connect(_on_new_profile_gui_input)
	row.mouse_entered.connect(_on_new_profile_hover.bind(row, true))
	row.mouse_exited.connect(_on_new_profile_hover.bind(row, false))
	row.focus_entered.connect(_on_new_profile_hover.bind(row, true))
	row.focus_exited.connect(_on_new_profile_hover.bind(row, false))

	var hbox := HBoxContainer.new()
	hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	hbox.offset_left = 28
	hbox.offset_right = -28
	hbox.offset_top = 0
	hbox.offset_bottom = 0
	hbox.add_theme_constant_override("separation", 22)
	hbox.alignment = BoxContainer.ALIGNMENT_BEGIN
	row.add_child(hbox)

	var dashed := Control.new()
	dashed.set_script(DashedBorderScript)
	dashed.set_anchors_preset(Control.PRESET_FULL_RECT)
	dashed.mouse_filter = Control.MOUSE_FILTER_IGNORE
	(dashed as DashedBorder).color = UI.NEON_LIME
	row.add_child(dashed)

	var plus := Label.new()
	plus.text = "+"
	plus.theme_type_variation = "DisplayLabel"
	plus.add_theme_font_override("font", _get_fira_tight())
	plus.add_theme_font_size_override("font_size", 44)
	plus.add_theme_color_override("font_color", UI.NEON_LIME)
	plus.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hbox.add_child(plus)

	var stack := VBoxContainer.new()
	stack.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	stack.add_theme_constant_override("separation", 4)
	hbox.add_child(stack)

	var t := Label.new()
	t.text = "НОВЫЙ ПРОФИЛЬ"
	t.theme_type_variation = "DisplayLabel"
	t.add_theme_font_override("font", _get_fira_tight())
	t.add_theme_font_size_override("font_size", 32)
	t.add_theme_color_override("font_color", UI.NEON_LIME)
	stack.add_child(t)

	var s := Label.new()
	s.text = "Создать новый профиль · NEW PROFILE"
	s.theme_type_variation = "MonoLabel"
	s.add_theme_font_size_override("font_size", 11)
	s.modulate = Color(UI.NEON_LIME.r, UI.NEON_LIME.g, UI.NEON_LIME.b, 0.65)
	stack.add_child(s)

	return row


func _on_row_gui_input(event: InputEvent, profile_name: String) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_on_profile_selected(profile_name)
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER or event.keycode == KEY_SPACE:
			_on_profile_selected(profile_name)


func _on_new_profile_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_on_create_profile_pressed()
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER or event.keycode == KEY_SPACE:
			_on_create_profile_pressed()


func _on_new_profile_hover(row: Panel, hovered: bool) -> void:
	var sb: StyleBox = row.get_meta("sb_hover" if hovered else "sb_normal")
	row.add_theme_stylebox_override("panel", sb)


func _build_create_panel() -> void:
	_create_panel = _create_centered_panel("CreatePanel", Vector2(450, 280))
	add_child(_create_panel)

	var vbox := _create_inner_vbox(_create_panel)

	var title := Label.new()
	title.text = "Новый профиль"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 36)
	vbox.add_child(title)

	_add_spacer(vbox, 15)

	var name_label := Label.new()
	name_label.text = "Имя игрока:"
	name_label.add_theme_font_size_override("font_size", 22)
	vbox.add_child(name_label)

	_name_input = LineEdit.new()
	_name_input.placeholder_text = "Введите имя..."
	_name_input.custom_minimum_size = Vector2(0, 50)
	_name_input.add_theme_font_size_override("font_size", 24)
	_name_input.max_length = 20
	_name_input.text_submitted.connect(_on_name_submitted)
	vbox.add_child(_name_input)

	_add_spacer(vbox, 10)

	var hbox := HBoxContainer.new()
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(hbox)

	var cancel_btn := Button.new()
	cancel_btn.text = "Отмена"
	cancel_btn.custom_minimum_size = Vector2(150, 50)
	cancel_btn.add_theme_font_size_override("font_size", 22)
	cancel_btn.pressed.connect(_on_create_cancel)
	hbox.add_child(cancel_btn)

	var spacer_h := Control.new()
	spacer_h.custom_minimum_size = Vector2(20, 0)
	hbox.add_child(spacer_h)

	var ok_btn := Button.new()
	ok_btn.text = "Создать"
	ok_btn.custom_minimum_size = Vector2(150, 50)
	ok_btn.add_theme_font_size_override("font_size", 22)
	ok_btn.add_theme_color_override("font_color", Color(0.5, 1, 0.5))
	ok_btn.pressed.connect(_on_create_confirm)
	hbox.add_child(ok_btn)


func _build_delete_confirm_panel() -> void:
	_delete_confirm_panel = _create_centered_panel("DeleteConfirmPanel", Vector2(420, 200))
	add_child(_delete_confirm_panel)

	var vbox := _create_inner_vbox(_delete_confirm_panel)

	_delete_title = Label.new()
	_delete_title.text = "Удалить профиль?"
	_delete_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_delete_title.add_theme_font_size_override("font_size", 28)
	vbox.add_child(_delete_title)

	_add_spacer(vbox, 10)

	var desc := Label.new()
	desc.text = "Весь прогресс будет потерян."
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc.add_theme_font_size_override("font_size", 20)
	desc.add_theme_color_override("font_color", Color(1, 0.6, 0.6))
	vbox.add_child(desc)

	_add_expand_spacer(vbox)

	var hbox := HBoxContainer.new()
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(hbox)

	var cancel_btn := Button.new()
	cancel_btn.text = "Отмена"
	cancel_btn.custom_minimum_size = Vector2(150, 50)
	cancel_btn.add_theme_font_size_override("font_size", 22)
	cancel_btn.pressed.connect(_on_delete_cancel)
	hbox.add_child(cancel_btn)

	var spacer_h := Control.new()
	spacer_h.custom_minimum_size = Vector2(20, 0)
	hbox.add_child(spacer_h)

	var delete_btn := Button.new()
	delete_btn.text = "Удалить"
	delete_btn.custom_minimum_size = Vector2(150, 50)
	delete_btn.add_theme_font_size_override("font_size", 22)
	delete_btn.add_theme_color_override("font_color", Color(1, 0.3, 0.3))
	delete_btn.pressed.connect(_on_delete_confirm)
	hbox.add_child(delete_btn)


func _build_hub_panel() -> void:
	_hub_panel = Control.new()
	_hub_panel.name = "HubScreen"
	_hub_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_hub_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hub_panel.visible = false
	add_child(_hub_panel)

	var bg := MenuBackdropScene.instantiate()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_hub_panel.add_child(bg)

	# Brand mark top-left
	var brand := BrandMarkScene.instantiate() as Control
	brand.scale = Vector2(0.85, 0.85)
	brand.position = Vector2(90, 80)
	brand.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hub_panel.add_child(brand)

	# Title block top-right
	var title_box := VBoxContainer.new()
	title_box.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	title_box.offset_left = -1100.0
	title_box.offset_right = -90.0
	title_box.offset_top = 80.0
	title_box.offset_bottom = 360.0
	title_box.alignment = BoxContainer.ALIGNMENT_BEGIN
	title_box.add_theme_constant_override("separation", 8)
	title_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hub_panel.add_child(title_box)

	var t_kicker := Label.new()
	t_kicker.text = "// 01 / CAREER · КАРЬЕРА"
	t_kicker.theme_type_variation = "MonoLabel"
	t_kicker.add_theme_font_size_override("font_size", 12)
	t_kicker.modulate = UI.NEON_MAGENTA
	t_kicker.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	title_box.add_child(t_kicker)

	var h2_stack := VBoxContainer.new()
	h2_stack.add_theme_constant_override("separation", -54)
	h2_stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_box.add_child(h2_stack)

	var t1 := Label.new()
	t1.text = "КАРЬЕРА"
	t1.theme_type_variation = "DisplayLabel"
	t1.add_theme_font_size_override("font_size", 96)
	t1.add_theme_color_override("font_color", UI.INK_900)
	t1.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	h2_stack.add_child(t1)

	# Profile name (dynamic, set in _update_hub)
	_hub_profile_label = Label.new()
	_hub_profile_label.text = ""
	_hub_profile_label.theme_type_variation = "DisplayLabel"
	_hub_profile_label.add_theme_font_size_override("font_size", 96)
	_hub_profile_label.add_theme_color_override("font_color", Color(0, 0, 0, 0))
	_hub_profile_label.add_theme_color_override("font_outline_color", UI.NEON_MAGENTA)
	_hub_profile_label.add_theme_constant_override("outline_size", 2)
	_hub_profile_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	h2_stack.add_child(_hub_profile_label)

	# Stats row below title
	var stats_row := HBoxContainer.new()
	stats_row.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	stats_row.offset_left = -900.0
	stats_row.offset_right = -90.0
	stats_row.offset_top = 300.0
	stats_row.offset_bottom = 380.0
	stats_row.add_theme_constant_override("separation", 0)
	stats_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hub_panel.add_child(stats_row)

	_hub_balance_label = Label.new()
	_hub_balance_label.theme_type_variation = "MonoLabel"
	_hub_balance_label.add_theme_font_size_override("font_size", 13)
	_hub_balance_label.modulate = UI.NEON_LIME
	stats_row.add_child(_hub_balance_label)

	var sep1 := Label.new()
	sep1.text = "  ·  "
	sep1.theme_type_variation = "MonoLabel"
	sep1.add_theme_font_size_override("font_size", 13)
	sep1.modulate = UI.INK_500
	stats_row.add_child(sep1)

	_hub_stats_label = Label.new()
	_hub_stats_label.theme_type_variation = "MonoLabel"
	_hub_stats_label.add_theme_font_size_override("font_size", 13)
	_hub_stats_label.modulate = UI.INK_500
	stats_row.add_child(_hub_stats_label)

	var sep2 := Label.new()
	sep2.text = "  ·  "
	sep2.theme_type_variation = "MonoLabel"
	sep2.add_theme_font_size_override("font_size", 13)
	sep2.modulate = UI.INK_500
	stats_row.add_child(sep2)

	_hub_car_label = Label.new()
	_hub_car_label.theme_type_variation = "MonoLabel"
	_hub_car_label.add_theme_font_size_override("font_size", 13)
	_hub_car_label.modulate = UI.INK_500
	stats_row.add_child(_hub_car_label)

	# Menu items — right-aligned, same style as main menu
	var menu_vbox := VBoxContainer.new()
	menu_vbox.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	menu_vbox.offset_left = -840.0
	menu_vbox.offset_right = -120.0
	menu_vbox.offset_top = 420.0
	menu_vbox.offset_bottom = -120.0
	menu_vbox.add_theme_constant_override("separation", 4)
	menu_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hub_panel.add_child(menu_vbox)

	# РАБОТАТЬ
	_hub_freeroam_btn = _build_hub_menu_row("РАБОТАТЬ", "01 / WORK", "Taxi & delivery")
	_hub_freeroam_btn.get_node("Btn").pressed.connect(_on_work_pressed)
	menu_vbox.add_child(_hub_freeroam_btn)

	# ГОНЯТЬСЯ
	_hub_challenges_btn = _build_hub_menu_row("ГОНЯТЬСЯ", "02 / RACES", "Underground challenges")
	_hub_challenges_btn.get_node("Btn").pressed.connect(_on_challenges_pressed)
	menu_vbox.add_child(_hub_challenges_btn)

	# ГАРАЖ
	var garage_row := _build_hub_menu_row("ГАРАЖ", "03 / GARAGE", "Your cars")
	garage_row.get_node("Btn").pressed.connect(_on_garage_pressed)
	menu_vbox.add_child(garage_row)

	# АВТОСАЛОН
	var shop_row := _build_hub_menu_row("АВТОСАЛОН", "04 / SHOP", "Buy new cars")
	shop_row.get_node("Btn").pressed.connect(_on_shop_pressed)
	menu_vbox.add_child(shop_row)

	# ГЛАВНОЕ МЕНЮ
	var back_row := _build_hub_menu_row("← ГЛАВНОЕ МЕНЮ", "05 / MAIN MENU", "Back to main menu")
	back_row.get_node("Btn").pressed.connect(_on_hub_back)
	menu_vbox.add_child(back_row)

	# Wire focus highlights
	_wire_hub_focus(menu_vbox)

	# Corner chrome
	var chrome := Control.new()
	chrome.set_script(CornerChromeScript)
	chrome.set_anchors_preset(Control.PRESET_FULL_RECT)
	chrome.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hub_panel.add_child(chrome)


func _build_hub_menu_row(label_text: String, kicker_text: String, hint_text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, 70)
	row.add_theme_constant_override("separation", 24)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var btn := Button.new()
	btn.name = "Btn"
	btn.text = label_text
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.theme_type_variation = "MenuRow"
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	row.add_child(btn)

	var stack := VBoxContainer.new()
	stack.name = "KickerStack"
	stack.custom_minimum_size = Vector2(180, 0)
	stack.size_flags_vertical = Control.SIZE_SHRINK_END
	stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.add_theme_constant_override("separation", 4)
	row.add_child(stack)

	var kicker := Label.new()
	kicker.name = "Kicker"
	kicker.text = kicker_text
	kicker.theme_type_variation = "MonoLabel"
	kicker.add_theme_font_size_override("font_size", 11)
	kicker.modulate = UI.INK_500
	kicker.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	stack.add_child(kicker)

	var hint := Label.new()
	hint.text = hint_text
	hint.theme_type_variation = "MonoLabel"
	hint.add_theme_font_size_override("font_size", 10)
	hint.modulate = Color(UI.INK_500.r, UI.INK_500.g, UI.INK_500.b, 0.75)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	stack.add_child(hint)

	return row


func _wire_hub_focus(vbox: VBoxContainer) -> void:
	for row in vbox.get_children():
		if not (row is HBoxContainer):
			continue
		var btn: Button = row.get_node_or_null("Btn")
		var kicker: Label = row.get_node_or_null("KickerStack/Kicker")
		if btn and kicker:
			btn.focus_entered.connect(func(): kicker.modulate = UI.NEON_MAGENTA)
			btn.focus_exited.connect(func(): kicker.modulate = UI.INK_500)
			btn.mouse_entered.connect(func(): btn.grab_focus())


func _build_location_panel() -> void:
	_location_panel = _create_centered_panel("LocationPanel", Vector2(500, 450))
	add_child(_location_panel)

	var vbox := _create_inner_vbox(_location_panel)

	var title := Label.new()
	title.text = "Выберите город"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 36)
	vbox.add_child(title)

	_add_spacer(vbox, 15)

	for location_name in LOCATIONS.keys():
		var btn := Button.new()
		btn.text = location_name
		btn.custom_minimum_size = Vector2(0, 55)
		btn.add_theme_font_size_override("font_size", 26)
		btn.pressed.connect(_on_location_selected.bind(location_name))
		vbox.add_child(btn)

	_add_expand_spacer(vbox)

	var back_btn := _create_back_button()
	back_btn.pressed.connect(_on_location_back)
	vbox.add_child(back_btn)


func _build_challenges_panel() -> void:
	_challenges_panel = _create_centered_panel("ChallengesPanel", Vector2(600, 500))
	add_child(_challenges_panel)

	var vbox := _create_inner_vbox(_challenges_panel)

	var title := Label.new()
	title.text = "ВЫЗОВЫ"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 36)
	title.add_theme_color_override("font_color", Color(1, 0.5, 0.5))
	vbox.add_child(title)

	_add_spacer(vbox, 10)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 300)
	vbox.add_child(scroll)

	_challenges_container = VBoxContainer.new()
	_challenges_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_challenges_container)

	_add_spacer(vbox, 10)

	var back_btn := _create_back_button()
	back_btn.pressed.connect(_on_challenges_back)
	vbox.add_child(back_btn)


func _build_garage_panel() -> void:
	_garage_panel = _create_centered_panel("GaragePanel", Vector2(550, 500))
	add_child(_garage_panel)

	var vbox := _create_inner_vbox(_garage_panel)

	var title := Label.new()
	title.text = "ГАРАЖ"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 36)
	title.add_theme_color_override("font_color", Color(0.5, 0.8, 1))
	vbox.add_child(title)

	_add_spacer(vbox, 15)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 280)
	vbox.add_child(scroll)

	_garage_cars_container = VBoxContainer.new()
	_garage_cars_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_garage_cars_container)

	_add_spacer(vbox, 10)

	var back_btn := _create_back_button()
	back_btn.pressed.connect(_on_garage_back)
	vbox.add_child(back_btn)


func _build_shop_panel() -> void:
	# Full-rect АВТО САЛОН screen per design spec 03-garage.
	_shop_panel = Control.new()
	_shop_panel.name = "ShopScreen"
	_shop_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_shop_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shop_panel.visible = false
	add_child(_shop_panel)

	# (No backdrop here — the standalone main menu's own MenuBackdrop is
	# already drawn behind us; adding another one stacks two copies and
	# brightens the screen.)

	# Brand mark top-left
	var brand := BrandMarkScene.instantiate() as Control
	brand.scale = Vector2(0.85, 0.85)
	brand.position = Vector2(90, 80)
	brand.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shop_panel.add_child(brand)

	# Title block (kicker + АВТО / САЛОН)
	var title_box := VBoxContainer.new()
	title_box.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	title_box.offset_left = -1100.0
	title_box.offset_right = -90.0
	title_box.offset_top = 80.0
	title_box.offset_bottom = 360.0
	title_box.alignment = BoxContainer.ALIGNMENT_BEGIN
	title_box.add_theme_constant_override("separation", 8)
	title_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shop_panel.add_child(title_box)

	var t_kicker := Label.new()
	t_kicker.text = "// 03 / DEALERSHIP · АВТОСАЛОН"
	t_kicker.theme_type_variation = "MonoLabel"
	t_kicker.add_theme_font_size_override("font_size", 12)
	t_kicker.add_theme_color_override("font_color", UI.NEON_CYAN)
	t_kicker.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	title_box.add_child(t_kicker)

	var h2_stack := VBoxContainer.new()
	h2_stack.add_theme_constant_override("separation", -54)
	h2_stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_box.add_child(h2_stack)

	var t1 := Label.new()
	t1.text = "АВТО"
	t1.theme_type_variation = "DisplayLabel"
	t1.add_theme_font_size_override("font_size", 96)
	t1.add_theme_color_override("font_color", UI.INK_900)
	t1.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	h2_stack.add_child(t1)

	var t2 := Label.new()
	t2.text = "САЛОН"
	t2.theme_type_variation = "DisplayLabel"
	t2.add_theme_font_size_override("font_size", 96)
	t2.add_theme_color_override("font_color", Color(0, 0, 0, 0))
	t2.add_theme_color_override("font_outline_color", UI.NEON_MAGENTA)
	t2.add_theme_constant_override("outline_size", 2)
	t2.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	h2_stack.add_child(t2)

	# Balance pill (parallelogram-cut, lime border)
	_build_balance_pill()

	# Scrollable car list. Top edge clips clean; bottom edge fades into the
	# background via a gradient overlay so the back button doesn't fight the
	# list visually.
	const LIST_BOTTOM_FADE := 96.0
	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.offset_left = 120.0
	scroll.offset_right = -120.0
	scroll.offset_top = 360.0
	scroll.offset_bottom = -120.0
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.follow_focus = true
	scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	_shop_panel.add_child(scroll)
	_shop_scroll = scroll

	_shop_cars_container = VBoxContainer.new()
	_shop_cars_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_shop_cars_container.add_theme_constant_override("separation", 10)
	_shop_cars_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	scroll.add_child(_shop_cars_container)

	# Bottom fade overlay: simple vertical gradient from transparent (top)
	# to bg-black (bottom). A TextureRect with a GradientTexture2D — no
	# shader, no risk of rendering as a flat opaque rectangle.
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 1.0])
	grad.colors = PackedColorArray([Color(0.024, 0.031, 0.047, 0.0),
									 Color(0.024, 0.031, 0.047, 1.0)])
	var grad_tex := GradientTexture2D.new()
	grad_tex.gradient = grad
	grad_tex.width = 4
	grad_tex.height = 256
	grad_tex.fill_from = Vector2(0, 0)
	grad_tex.fill_to = Vector2(0, 1)
	var fade := TextureRect.new()
	fade.name = "ListBottomFade"
	fade.texture = grad_tex
	fade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	fade.stretch_mode = TextureRect.STRETCH_SCALE
	fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	fade.offset_left = 120.0
	fade.offset_right = -120.0
	fade.offset_top = -120.0 - LIST_BOTTOM_FADE
	fade.offset_bottom = -120.0
	fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shop_panel.add_child(fade)

	# Back button bottom-left
	var back_btn := Button.new()
	back_btn.text = "← НАЗАД"
	back_btn.theme_type_variation = "MenuRow"
	back_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	back_btn.add_theme_font_size_override("font_size", 24)
	back_btn.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	back_btn.offset_left = 120.0
	back_btn.offset_top = -110.0
	back_btn.offset_right = 280.0
	back_btn.offset_bottom = -70.0
	back_btn.pressed.connect(_on_shop_back)
	_shop_panel.add_child(back_btn)

	# Corner chrome on top
	var chrome := Control.new()
	chrome.set_script(CornerChromeScript)
	chrome.set_anchors_preset(Control.PRESET_FULL_RECT)
	chrome.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shop_panel.add_child(chrome)


func _format_ruble(amount: int) -> String:
	# 65250 -> "65 250 ₽"
	var s := str(int(abs(amount)))
	var grouped := ""
	var i := s.length()
	while i > 0:
		var start: int = max(0, i - 3)
		var chunk := s.substr(start, i - start)
		grouped = chunk + ((" " + grouped) if grouped != "" else "")
		i = start
	if amount < 0:
		grouped = "-" + grouped
	return grouped + " ₽"


func _build_balance_pill() -> void:
	# Parallelogram pill at the right side under the title (screen 03 spec).
	# JSX: bg=ink-100, border=lime, clip-path with right-slant. The slanted
	# edge has no outline (clipped away), per CSS clip-path semantics.
	var pill := Panel.new()
	pill.name = "BalancePill"
	pill.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	pill.offset_left = -380.0
	pill.offset_right = -110.0
	pill.offset_top = 270.0
	pill.offset_bottom = 322.0
	pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var psb: NeonStyleBox = NeonStyleBoxScript.new()
	psb.fill_color = UI.INK_100
	psb.outline_color = UI.NEON_LIME
	psb.outline_width = 1.0
	psb.shear_deg = 0.0
	psb.glow_size = 0
	psb.right_slant = 16.0
	pill.add_theme_stylebox_override("panel", psb)
	_shop_panel.add_child(pill)

	var hbox := HBoxContainer.new()
	hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	hbox.offset_left = 22.0
	hbox.offset_right = -32.0
	hbox.offset_top = 0.0
	hbox.offset_bottom = 0.0
	hbox.add_theme_constant_override("separation", 16)
	hbox.alignment = BoxContainer.ALIGNMENT_BEGIN
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pill.add_child(hbox)

	var lbl := Label.new()
	lbl.text = "БАЛАНС"
	lbl.theme_type_variation = "MonoLabel"
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", UI.INK_500)
	lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hbox.add_child(lbl)

	_shop_balance_label = Label.new()
	_shop_balance_label.theme_type_variation = "MonoLabel"
	_shop_balance_label.add_theme_font_size_override("font_size", 22)
	_shop_balance_label.add_theme_color_override("font_color", UI.NEON_LIME)
	_shop_balance_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hbox.add_child(_shop_balance_label)


func _build_tuning_panel() -> void:
	_tuning_panel = _create_centered_panel("TuningPanel", Vector2(550, 480))
	add_child(_tuning_panel)

	var vbox := _create_inner_vbox(_tuning_panel)

	var title_row := HBoxContainer.new()
	vbox.add_child(title_row)

	_tuning_title = Label.new()
	_tuning_title.text = "ТЮНИНГ"
	_tuning_title.add_theme_font_size_override("font_size", 32)
	_tuning_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(_tuning_title)

	_tuning_balance = Label.new()
	_tuning_balance.add_theme_font_size_override("font_size", 20)
	_tuning_balance.add_theme_color_override("font_color", Color(0.2, 1, 0.2))
	title_row.add_child(_tuning_balance)

	_add_spacer(vbox, 15)

	_tuning_container = VBoxContainer.new()
	_tuning_container.add_theme_constant_override("separation", 8)
	vbox.add_child(_tuning_container)

	_add_expand_spacer(vbox)

	var back_btn := _create_back_button()
	back_btn.pressed.connect(_on_tuning_back)
	vbox.add_child(back_btn)


func _build_sell_confirm_panel() -> void:
	_sell_confirm_panel = _create_centered_panel("SellConfirmPanel", Vector2(420, 230))
	add_child(_sell_confirm_panel)

	var vbox := _create_inner_vbox(_sell_confirm_panel)

	_sell_title = Label.new()
	_sell_title.text = "Продать машину?"
	_sell_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_sell_title.add_theme_font_size_override("font_size", 28)
	vbox.add_child(_sell_title)

	_add_spacer(vbox, 8)

	_sell_price_label = Label.new()
	_sell_price_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_sell_price_label.add_theme_font_size_override("font_size", 22)
	_sell_price_label.add_theme_color_override("font_color", Color(0.2, 1, 0.2))
	vbox.add_child(_sell_price_label)

	var warn := Label.new()
	warn.text = "Тюнинг будет потерян!"
	warn.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	warn.add_theme_font_size_override("font_size", 18)
	warn.add_theme_color_override("font_color", Color(1, 0.6, 0.6))
	vbox.add_child(warn)

	_add_expand_spacer(vbox)

	var hbox := HBoxContainer.new()
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(hbox)

	var cancel_btn := Button.new()
	cancel_btn.text = "Отмена"
	cancel_btn.custom_minimum_size = Vector2(150, 50)
	cancel_btn.add_theme_font_size_override("font_size", 22)
	cancel_btn.pressed.connect(_on_sell_cancel)
	hbox.add_child(cancel_btn)

	var spacer_h := Control.new()
	spacer_h.custom_minimum_size = Vector2(20, 0)
	hbox.add_child(spacer_h)

	var sell_btn := Button.new()
	sell_btn.text = "Продать"
	sell_btn.custom_minimum_size = Vector2(150, 50)
	sell_btn.add_theme_font_size_override("font_size", 22)
	sell_btn.add_theme_color_override("font_color", Color(1, 0.3, 0.3))
	sell_btn.pressed.connect(_on_sell_confirm)
	hbox.add_child(sell_btn)


# === Навигация ===

func _hide_all() -> void:
	_profile_panel.visible = false
	_hub_panel.visible = false
	_garage_panel.visible = false
	_shop_panel.visible = false
	_create_panel.visible = false
	_delete_confirm_panel.visible = false
	_location_panel.visible = false
	_challenges_panel.visible = false
	_tuning_panel.visible = false
	_sell_confirm_panel.visible = false
	if _garage_carsel:
		_garage_carsel.visible = false


func _show_profile_screen() -> void:
	_hide_all()
	_profile_panel.visible = true
	_populate_profiles()


func _show_hub() -> void:
	_hide_all()
	_hub_panel.visible = true
	_update_hub()
	var first_btn: Button = _hub_freeroam_btn.get_node_or_null("Btn")
	if first_btn:
		first_btn.call_deferred("grab_focus")


func _show_garage() -> void:
	_hide_all()
	# Lazy: instantiate the CarSelection screen once, parented under us so
	# it sits above any career hub panels.
	if _garage_carsel == null:
		_garage_carsel = CarSelectionScene.instantiate()
		add_child(_garage_carsel)
		_garage_carsel.selection_done.connect(_on_garage_carsel_chosen)
		_garage_carsel.back_requested.connect(_on_garage_carsel_back)
	_garage_carsel.show_selection(true, CareerState.selected_car)


func _on_garage_carsel_chosen(car_id: String) -> void:
	CareerState.select_car(car_id)
	_show_hub()


func _on_garage_carsel_back() -> void:
	_show_hub()


func _show_shop() -> void:
	_hide_all()
	_shop_panel.visible = true
	_populate_shop()


func _has_car() -> bool:
	return CareerState.selected_car != "" and CareerState.selected_car in CareerState.owned_cars


# === Профили ===

func _populate_profiles() -> void:
	# Stop any previous pulse before rebuilding (the bar will be freed).
	if _focused_sidebar_tween and _focused_sidebar_tween.is_valid():
		_focused_sidebar_tween.kill()
	_focused_sidebar = null

	for child in _profiles_container.get_children():
		child.queue_free()

	var profiles := CareerState.get_profile_names()
	var rows: Array[Control] = []
	for i in range(profiles.size()):
		var row := _build_profile_row(profiles[i], i == 0)
		_profiles_container.add_child(row)
		rows.append(row)

	# The "new profile" row sits in the parent list VBox, right after _profiles_container.
	var new_row: Control = _profile_panel.get_node_or_null("ProfileScreen") if false else null
	# Find NewProfileRow — it's a sibling of _profiles_container in the list VBox.
	var list_vbox := _profiles_container.get_parent()
	for child in list_vbox.get_children():
		if child.name == "NewProfileRow":
			new_row = child
			break

	# Back button is a direct child of _profile_panel.
	var back_btn: Control = null
	for child in _profile_panel.get_children():
		if child is Button and child.text == "← НАЗАД":
			back_btn = child
			break

	# Build the full focusable list: profile rows + new profile + back.
	var focusables: Array[Control] = []
	focusables.append_array(rows)
	if new_row:
		focusables.append(new_row)
	if back_btn:
		focusables.append(back_btn)

	# Wire up/down focus neighbors so arrow keys navigate between them.
	for i in range(focusables.size()):
		var node := focusables[i]
		var prev := focusables[i - 1] if i > 0 else focusables[focusables.size() - 1]
		var next := focusables[i + 1] if i < focusables.size() - 1 else focusables[0]
		node.focus_neighbor_top = prev.get_path()
		node.focus_neighbor_bottom = next.get_path()
		node.focus_previous = prev.get_path()
		node.focus_next = next.get_path()

	if _focused_sidebar:
		_start_sidebar_pulse(_focused_sidebar)

	if not rows.is_empty():
		rows[0].call_deferred("grab_focus")


func _start_sidebar_pulse(bar: ColorRect) -> void:
	bar.modulate.a = 1.0
	_focused_sidebar_tween = create_tween().set_loops()
	_focused_sidebar_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_focused_sidebar_tween.tween_property(bar, "modulate:a", 0.35, 0.55)
	_focused_sidebar_tween.tween_property(bar, "modulate:a", 1.0, 0.55)


func _on_profile_selected(profile_name: String) -> void:
	if CareerState.load_profile(profile_name):
		_show_hub()


func _on_create_profile_pressed() -> void:
	_profile_panel.visible = false
	_create_panel.visible = true
	_name_input.text = ""
	_name_input.grab_focus()


func _on_create_confirm() -> void:
	var profile_name := _name_input.text.strip_edges()
	if profile_name == "":
		return
	if profile_name in CareerState.get_profile_names():
		return
	CareerState.create_profile(profile_name)
	_create_panel.visible = false
	_show_hub()


func _on_name_submitted(_text: String) -> void:
	_on_create_confirm()


func _on_create_cancel() -> void:
	_create_panel.visible = false
	_profile_panel.visible = true


func _on_delete_profile_pressed(profile_name: String) -> void:
	_delete_profile_name = profile_name
	_profile_panel.visible = false
	_delete_confirm_panel.visible = true
	_delete_title.text = "Удалить \"%s\"?" % profile_name


func _on_delete_confirm() -> void:
	CareerState.delete_profile(_delete_profile_name)
	_delete_profile_name = ""
	_delete_confirm_panel.visible = false
	_show_profile_screen()


func _on_delete_cancel() -> void:
	_delete_profile_name = ""
	_delete_confirm_panel.visible = false
	_profile_panel.visible = true


func _on_profile_back() -> void:
	hide_menu()
	back_to_main_menu.emit()


# === Хаб карьеры ===

func _update_hub() -> void:
	_hub_profile_label.text = CareerState.active_profile.to_upper()
	_hub_balance_label.text = CareerState.format_money(CareerState.balance)
	_hub_stats_label.text = "ПОБЕД: %d / ГОНОК: %d / ЗАКАЗОВ: %d" % [
		CareerState.races_won, CareerState.total_races, CareerState.orders_completed]

	var has_car := _has_car()
	if has_car:
		var car_name := CarSettings.get_car_name(CareerState.selected_car)
		_hub_car_label.text = "МАШИНА: %s" % car_name.to_upper()
		_hub_car_label.modulate = UI.INK_500
	else:
		_hub_car_label.text = "СНАЧАЛА КУПИТЕ МАШИНУ!"
		_hub_car_label.modulate = UI.NEON_RED

	var work_btn: Button = _hub_freeroam_btn.get_node("Btn")
	var race_btn: Button = _hub_challenges_btn.get_node("Btn")
	work_btn.disabled = not has_car
	race_btn.disabled = not has_car


func _on_work_pressed() -> void:
	if not _has_car():
		return
	_hide_all()
	_location_panel.visible = true


func _on_challenges_pressed() -> void:
	if not _has_car():
		return
	_hide_all()
	_challenges_panel.visible = true
	_populate_challenges()


func _on_garage_pressed() -> void:
	_show_garage()


func _on_shop_pressed() -> void:
	_show_shop()


func _on_hub_back() -> void:
	hide_menu()
	back_to_main_menu.emit()


# === Выезд в город ===

func _on_location_selected(location_name: String) -> void:
	var coords: Array = LOCATIONS[location_name]
	RaceState.free_roam_location = location_name
	RaceState.free_roam_lat = coords[0]
	RaceState.free_roam_lon = coords[1]
	RaceState.selected_track = null
	RaceState.is_career_race = false
	RaceState.is_work_mode = true
	if MusicManager:
		MusicManager.play_next_track()
	get_tree().change_scene_to_file("res://main.tscn")


func _on_location_back() -> void:
	_show_hub()


# === Вызовы ===

func _populate_challenges() -> void:
	for child in _challenges_container.get_children():
		child.queue_free()

	var tracks: Array = RaceTrackScript.get_all_tracks()
	for track in tracks:
		if not track:
			continue
		var track_id: String = track.track_id
		var prize := CareerState.get_challenge_prize(track_id)
		var entry_fee := CareerState.get_entry_fee(track_id)
		var can_enter := CareerState.can_afford_entry(track_id)

		var panel := PanelContainer.new()
		panel.custom_minimum_size = Vector2(0, 95)
		_challenges_container.add_child(panel)

		var hbox := HBoxContainer.new()
		hbox.add_theme_constant_override("separation", 15)
		panel.add_child(hbox)

		var info_vbox := VBoxContainer.new()
		info_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hbox.add_child(info_vbox)

		var name_label := Label.new()
		name_label.text = track.track_name
		name_label.add_theme_font_size_override("font_size", 26)
		info_vbox.add_child(name_label)

		var mode_text := "Спринт" if track.race_mode == "sprint" else "Чекпоинт"
		var desc_label := Label.new()
		desc_label.text = "%s  |  Приз: %s" % [mode_text, CareerState.format_money(prize)]
		desc_label.add_theme_font_size_override("font_size", 17)
		desc_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
		info_vbox.add_child(desc_label)

		var fee_label := Label.new()
		fee_label.text = "Взнос: %s" % CareerState.format_money(entry_fee)
		fee_label.add_theme_font_size_override("font_size", 16)
		if can_enter:
			fee_label.add_theme_color_override("font_color", Color(1, 0.8, 0.4))
		else:
			fee_label.add_theme_color_override("font_color", Color(1, 0.3, 0.3))
		info_vbox.add_child(fee_label)

		var race_btn := Button.new()
		race_btn.text = "Гонка!"
		race_btn.custom_minimum_size = Vector2(120, 50)
		race_btn.add_theme_font_size_override("font_size", 22)
		race_btn.add_theme_color_override("font_color", Color(1, 0.5, 0.5))
		if not can_enter:
			race_btn.disabled = true
			# Показываем помощь от администрации
			var help_btn := Button.new()
			help_btn.text = "Получить 5 000 руб."
			help_btn.custom_minimum_size = Vector2(180, 40)
			help_btn.add_theme_font_size_override("font_size", 16)
			help_btn.tooltip_text = "Помощь от администрации"
			help_btn.pressed.connect(_on_admin_help.bind(help_btn, race_btn))
			hbox.add_child(help_btn)
		else:
			race_btn.pressed.connect(_on_challenge_selected.bind(track))
		hbox.add_child(race_btn)


func _on_admin_help(_help_btn: Button, _race_btn: Button) -> void:
	CareerState.balance += 5000
	CareerState.save_profile()
	_hub_balance_label.text = CareerState.format_money(CareerState.balance)
	# Перестраиваем вызовы чтобы обновить кнопки
	_populate_challenges()


func _on_challenge_selected(track) -> void:
	# Списываем взнос
	CareerState.pay_entry_fee(track.track_id)
	RaceState.selected_track = track
	RaceState.free_roam_location = ""
	RaceState.is_career_race = true
	RaceState.is_work_mode = false
	if MusicManager:
		MusicManager.play_next_track()
	get_tree().change_scene_to_file("res://race/race_scene.tscn")


func _on_challenges_back() -> void:
	_show_hub()


# === Гараж ===

func _populate_garage() -> void:
	for child in _garage_cars_container.get_children():
		child.queue_free()

	if CareerState.owned_cars.is_empty():
		var empty_label := Label.new()
		empty_label.text = "Гараж пуст. Купите машину в автосалоне!"
		empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty_label.add_theme_font_size_override("font_size", 22)
		empty_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
		_garage_cars_container.add_child(empty_label)
		return

	for car_id in CareerState.sort_car_ids_by_price(CareerState.owned_cars):
		var is_selected := car_id == CareerState.selected_car
		var car_name := CarSettings.get_car_name(car_id)

		var row_panel := PanelContainer.new()
		row_panel.custom_minimum_size = Vector2(0, 70)
		_garage_cars_container.add_child(row_panel)

		var hbox := HBoxContainer.new()
		hbox.add_theme_constant_override("separation", 10)
		row_panel.add_child(hbox)

		var info_vbox := VBoxContainer.new()
		info_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hbox.add_child(info_vbox)

		var name_label := Label.new()
		name_label.text = car_name
		name_label.add_theme_font_size_override("font_size", 22)
		if is_selected:
			name_label.add_theme_color_override("font_color", Color(0.2, 1, 0.2))
		info_vbox.add_child(name_label)

		# Показываем уровни тюнинга
		var tuning_parts: Array[String] = []
		for cat in CareerState.TUNING_CATEGORIES:
			var lvl := CareerState.get_tuning_level(car_id, cat)
			if lvl > 0:
				tuning_parts.append("%s %d" % [CareerState.TUNING_NAMES[cat], lvl])
		if not tuning_parts.is_empty():
			var tuning_label := Label.new()
			tuning_label.text = ", ".join(tuning_parts)
			tuning_label.add_theme_font_size_override("font_size", 14)
			tuning_label.add_theme_color_override("font_color", Color(0.5, 0.7, 1))
			info_vbox.add_child(tuning_label)

		# Кнопки
		if is_selected:
			var badge := Label.new()
			badge.text = "V"
			badge.add_theme_font_size_override("font_size", 20)
			badge.add_theme_color_override("font_color", Color(0.2, 1, 0.2))
			hbox.add_child(badge)
		else:
			var select_btn := Button.new()
			select_btn.text = "Выбрать"
			select_btn.custom_minimum_size = Vector2(90, 0)
			select_btn.add_theme_font_size_override("font_size", 16)
			select_btn.pressed.connect(_on_garage_select.bind(car_id))
			hbox.add_child(select_btn)

		var tuning_btn := Button.new()
		tuning_btn.text = "Тюнинг"
		tuning_btn.custom_minimum_size = Vector2(90, 0)
		tuning_btn.add_theme_font_size_override("font_size", 16)
		tuning_btn.add_theme_color_override("font_color", Color(0.5, 0.8, 1))
		tuning_btn.pressed.connect(_on_tuning_pressed.bind(car_id))
		hbox.add_child(tuning_btn)

		var sell_btn := Button.new()
		sell_btn.text = "Продать"
		sell_btn.custom_minimum_size = Vector2(90, 0)
		sell_btn.add_theme_font_size_override("font_size", 16)
		sell_btn.add_theme_color_override("font_color", Color(1, 0.4, 0.4))
		sell_btn.pressed.connect(_on_sell_pressed.bind(car_id))
		hbox.add_child(sell_btn)


func _on_garage_select(car_id: String) -> void:
	CareerState.select_car(car_id)
	_populate_garage()


func _on_garage_back() -> void:
	_show_hub()


# === Продажа ===

func _on_sell_pressed(car_id: String) -> void:
	_sell_car_id = car_id
	var car_name := CarSettings.get_car_name(car_id)
	var sell_price := CareerState.get_sell_price(car_id)
	_sell_title.text = "Продать %s?" % car_name
	_sell_price_label.text = "+ %s" % CareerState.format_money(sell_price)
	_garage_panel.visible = false
	_sell_confirm_panel.visible = true


func _on_sell_confirm() -> void:
	CareerState.sell_car(_sell_car_id)
	_sell_car_id = ""
	_sell_confirm_panel.visible = false
	_show_garage()


func _on_sell_cancel() -> void:
	_sell_car_id = ""
	_sell_confirm_panel.visible = false
	_garage_panel.visible = true


# === Тюнинг ===

func _on_tuning_pressed(car_id: String) -> void:
	_tuning_car_id = car_id
	_hide_all()
	_tuning_panel.visible = true
	_populate_tuning()


func _populate_tuning() -> void:
	var car_name := CarSettings.get_car_name(_tuning_car_id)
	_tuning_title.text = "Тюнинг: %s" % car_name
	_tuning_balance.text = CareerState.format_money(CareerState.balance)

	for child in _tuning_container.get_children():
		child.queue_free()

	for category in CareerState.TUNING_CATEGORIES:
		var cat_name: String = CareerState.TUNING_NAMES[category]
		var level := CareerState.get_tuning_level(_tuning_car_id, category)
		var max_level: int = CareerState.TUNING_MAX_LEVEL

		var panel := PanelContainer.new()
		panel.custom_minimum_size = Vector2(0, 75)
		_tuning_container.add_child(panel)

		var hbox := HBoxContainer.new()
		hbox.add_theme_constant_override("separation", 15)
		panel.add_child(hbox)

		var info_vbox := VBoxContainer.new()
		info_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hbox.add_child(info_vbox)

		var name_label := Label.new()
		name_label.text = cat_name
		name_label.add_theme_font_size_override("font_size", 24)
		info_vbox.add_child(name_label)

		# Уровень: шкала из блоков
		var level_hbox := HBoxContainer.new()
		level_hbox.add_theme_constant_override("separation", 4)
		info_vbox.add_child(level_hbox)

		var lvl_label := Label.new()
		lvl_label.text = "Ур. "
		lvl_label.add_theme_font_size_override("font_size", 16)
		lvl_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		level_hbox.add_child(lvl_label)

		for i in range(max_level):
			var block := Label.new()
			block.text = "■" if i < level else "□"
			block.add_theme_font_size_override("font_size", 18)
			if i < level:
				block.add_theme_color_override("font_color", Color(0.3, 0.9, 0.3))
			else:
				block.add_theme_color_override("font_color", Color(0.4, 0.4, 0.4))
			level_hbox.add_child(block)

		if level < max_level:
			var price := CareerState.get_tuning_upgrade_price(_tuning_car_id, category)
			var can_afford := CareerState.balance >= price

			var right_vbox := VBoxContainer.new()
			right_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
			hbox.add_child(right_vbox)

			var price_label := Label.new()
			price_label.text = CareerState.format_money(price)
			price_label.add_theme_font_size_override("font_size", 16)
			if can_afford:
				price_label.add_theme_color_override("font_color", Color(1, 1, 1))
			else:
				price_label.add_theme_color_override("font_color", Color(1, 0.3, 0.3))
			right_vbox.add_child(price_label)

			var upgrade_btn := Button.new()
			upgrade_btn.text = "Улучшить"
			upgrade_btn.custom_minimum_size = Vector2(110, 35)
			upgrade_btn.add_theme_font_size_override("font_size", 18)
			upgrade_btn.disabled = not can_afford
			upgrade_btn.pressed.connect(_on_upgrade_pressed.bind(category))
			right_vbox.add_child(upgrade_btn)
		else:
			var max_label := Label.new()
			max_label.text = "МАКС"
			max_label.add_theme_font_size_override("font_size", 20)
			max_label.add_theme_color_override("font_color", Color(1, 0.85, 0))
			hbox.add_child(max_label)


func _on_upgrade_pressed(category: String) -> void:
	CareerState.upgrade_tuning(_tuning_car_id, category)
	_populate_tuning()


func _on_tuning_back() -> void:
	_tuning_car_id = ""
	_show_garage()


# === Магазин ===

const CAR_SPEC_LINES := {
	"matiz":      "1998 · 0.8L · 51 HP · FWD",
	"logan":      "2004 · 1.4L · 75 HP · FWD",
	"nexia":      "1995 · 1.5L · 80 HP · FWD",
	"polo":       "2009 · 1.6L · 105 HP · FWD",
	"beetle":     "1968 · 1.5L · 53 HP · RWD",
	"bmw_m3_gtr": "2001 · 3.2L · 380 HP · RWD",
}


func _populate_shop() -> void:
	# Stop the previous focus pulse before tearing rows down.
	if _focused_sidebar_tween and _focused_sidebar_tween.is_valid():
		_focused_sidebar_tween.kill()
	_focused_sidebar = null

	_shop_balance_label.text = _format_ruble(CareerState.balance)

	# Snap scroll to the top before tearing down rows so a stale focus on
	# a soon-to-be-freed row can't trigger a follow-focus mid-rebuild.
	if _shop_scroll:
		_shop_scroll.scroll_vertical = 0

	for child in _shop_cars_container.get_children():
		child.queue_free()

	var sorted_ids: Array[String] = []
	for cid in CarSettings.get_car_ids():
		sorted_ids.append(cid)
	sorted_ids.sort_custom(func(a: String, b: String) -> bool:
		return CareerState.get_car_price(a) < CareerState.get_car_price(b)
	)

	# Always focus the first (cheapest) car on open so the list shows at
	# the top. Arrow keys then walk down through the list.
	var first_row: Control = null
	for i in range(sorted_ids.size()):
		var cid := sorted_ids[i]
		var focused := i == 0
		var row := _build_shop_row(cid, i + 1, focused)
		_shop_cars_container.add_child(row)
		if focused:
			first_row = row

	# Bottom spacer so the last car row can scroll past under the fade
	# overlay without being clipped before reaching it.
	var tail := Control.new()
	tail.custom_minimum_size = Vector2(0, 96)
	tail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shop_cars_container.add_child(tail)

	if _focused_sidebar:
		_start_sidebar_pulse(_focused_sidebar)
	if first_row:
		first_row.call_deferred("grab_focus")
	# Re-snap scroll to top after the deferred focus grab settles, in case
	# follow_focus moved it.
	if _shop_scroll:
		_shop_scroll.set_deferred("scroll_vertical", 0)


func _build_shop_row(car_id: String, number: int, focused: bool) -> Control:
	var price := CareerState.get_car_price(car_id)
	var owned: bool = car_id in CareerState.owned_cars
	var can_afford: bool = CareerState.can_afford(car_id)
	var car_name: String = CarSettings.get_car_name(car_id)
	var stats: Dictionary = CarSettings.DISPLAY_STATS.get(car_id, {})
	var spec_line: String = CAR_SPEC_LINES.get(car_id, "")

	var row := Panel.new()
	row.name = "Row_" + car_id
	row.custom_minimum_size = Vector2(0, 110)
	var sb: NeonStyleBox = NeonStyleBoxScript.new()
	sb.fill_color = UI.INK_100
	sb.outline_color = UI.NEON_CYAN if focused else UI.INK_300
	sb.outline_width = 1.0
	sb.shear_deg = 0.0
	sb.right_slant = 18.0
	sb.glow_size = 0
	row.add_theme_stylebox_override("panel", sb)
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	row.focus_mode = Control.FOCUS_ALL
	row.gui_input.connect(_on_shop_row_gui_input.bind(car_id))

	# Side bar — full height.
	var bar := ColorRect.new()
	bar.color = UI.NEON_CYAN if focused else UI.INK_400
	bar.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	bar.offset_left = 0.0
	bar.offset_top = 0.0
	bar.offset_right = 5.0
	bar.offset_bottom = 0.0
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(bar)
	if focused:
		_focused_sidebar = bar

	# Content
	var hbox := HBoxContainer.new()
	hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	hbox.offset_left = 28.0
	hbox.offset_right = -36.0  # leave room for the right slant
	hbox.add_theme_constant_override("separation", 24)
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(hbox)

	# Number column
	var num_lbl := Label.new()
	num_lbl.text = "%02d" % number
	num_lbl.theme_type_variation = "MonoLabel"
	num_lbl.add_theme_font_size_override("font_size", 22)
	num_lbl.add_theme_color_override("font_color",
		UI.NEON_CYAN if focused else UI.INK_500)
	num_lbl.custom_minimum_size = Vector2(56, 0)
	num_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hbox.add_child(num_lbl)

	# Car thumbnail with bordered frame + corner ticks.
	hbox.add_child(_build_car_thumb(car_id, focused))

	# Name + spec
	var name_box := VBoxContainer.new()
	name_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	name_box.custom_minimum_size = Vector2(280, 0)
	name_box.add_theme_constant_override("separation", 6)
	hbox.add_child(name_box)

	var name_label := Label.new()
	name_label.text = car_name.to_upper()
	name_label.theme_type_variation = "DisplayLabel"
	name_label.add_theme_font_override("font", _get_fira_tight())
	name_label.add_theme_font_size_override("font_size", 32)
	name_label.add_theme_color_override("font_color", UI.NEON_CYAN if focused else UI.INK_900)
	name_box.add_child(name_label)

	var spec_lbl := Label.new()
	spec_lbl.text = spec_line.to_upper()
	spec_lbl.theme_type_variation = "MonoLabel"
	spec_lbl.add_theme_font_size_override("font_size", 12)
	spec_lbl.add_theme_color_override("font_color", UI.INK_700)
	name_box.add_child(spec_lbl)

	# Stat bars
	var stats_row := HBoxContainer.new()
	stats_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stats_row.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	stats_row.add_theme_constant_override("separation", 28)
	hbox.add_child(stats_row)
	stats_row.add_child(_build_micro_stat("РАЗГОН", int(round(float(stats.get("accel", 0.5)) * 10.0))))
	stats_row.add_child(_build_micro_stat("СКОРОСТЬ", int(round(float(stats.get("speed", 0.5)) * 10.0))))
	stats_row.add_child(_build_micro_stat("УПРАВЛЕНИЕ", int(round(float(stats.get("handling", 0.5)) * 10.0))))

	# Price column
	var price_box := VBoxContainer.new()
	price_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	price_box.custom_minimum_size = Vector2(180, 0)
	price_box.add_theme_constant_override("separation", 4)
	hbox.add_child(price_box)

	var price_kicker := Label.new()
	price_kicker.text = "ЦЕНА"
	price_kicker.theme_type_variation = "MonoLabel"
	price_kicker.add_theme_font_size_override("font_size", 11)
	price_kicker.add_theme_color_override("font_color", UI.INK_700)
	price_kicker.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	price_box.add_child(price_kicker)

	var price_lbl := Label.new()
	price_lbl.text = _format_ruble(price)
	price_lbl.theme_type_variation = "MonoLabel"
	price_lbl.add_theme_font_size_override("font_size", 22)
	price_lbl.add_theme_color_override("font_color",
		UI.NEON_LIME if (owned or can_afford) else UI.INK_500)
	price_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	price_box.add_child(price_lbl)

	# Action column
	var action_box := Control.new()
	action_box.custom_minimum_size = Vector2(180, 0)
	action_box.size_flags_vertical = Control.SIZE_FILL
	action_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(action_box)

	if owned:
		var owned_lbl := Label.new()
		owned_lbl.text = "В ГАРАЖЕ"
		owned_lbl.theme_type_variation = "DisplayLabel"
		owned_lbl.add_theme_font_override("font", _get_fira_tight())
		owned_lbl.add_theme_font_size_override("font_size", 22)
		owned_lbl.add_theme_color_override("font_color", UI.NEON_LIME)
		owned_lbl.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
		owned_lbl.offset_left = -180.0
		owned_lbl.offset_right = 0.0
		owned_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		owned_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		action_box.add_child(owned_lbl)
	else:
		var buy_btn := Button.new()
		buy_btn.text = "КУПИТЬ"
		buy_btn.add_theme_font_size_override("font_size", 14)
		buy_btn.disabled = not can_afford
		buy_btn.pressed.connect(_on_shop_buy.bind(car_id))
		buy_btn.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
		buy_btn.offset_left = -130.0
		buy_btn.offset_right = -10.0
		buy_btn.offset_top = -22.0
		buy_btn.offset_bottom = 22.0
		# Highlight magenta when this row is focused.
		if focused:
			var hl := StyleBoxFlat.new()
			hl.bg_color = UI.NEON_MAGENTA
			hl.border_color = UI.NEON_MAGENTA
			hl.border_width_left = 1
			hl.border_width_right = 1
			hl.border_width_top = 1
			hl.border_width_bottom = 1
			hl.skew = Vector2(-0.21, 0.0)
			hl.content_margin_left = 18
			hl.content_margin_right = 18
			hl.content_margin_top = 8
			hl.content_margin_bottom = 8
			buy_btn.add_theme_stylebox_override("normal", hl)
			buy_btn.add_theme_stylebox_override("hover", hl)
			buy_btn.add_theme_stylebox_override("pressed", hl)
			buy_btn.add_theme_color_override("font_color", UI.INK_000)
		action_box.add_child(buy_btn)

	return row


func _build_car_thumb(car_id: String, focused: bool) -> Control:
	# 180x88 framed thumbnail. Vertical hairline borders left+right, four
	# 8px corner ticks. Texture loaded lazily so a missing thumb file
	# silently shows the empty frame.
	var frame := Control.new()
	frame.custom_minimum_size = Vector2(180, 88)
	frame.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var line_color := UI.NEON_CYAN if focused else UI.INK_300
	var tick_color := UI.NEON_CYAN if focused else UI.INK_400

	var left := ColorRect.new()
	left.color = line_color
	left.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	left.offset_right = 1.0
	left.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(left)

	var right := ColorRect.new()
	right.color = line_color
	right.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	right.offset_left = -1.0
	right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(right)

	var ticks := [
		[Control.PRESET_TOP_LEFT,    Vector2(-1, 0),  Vector2(8, 1)],
		[Control.PRESET_TOP_RIGHT,   Vector2(-7, 0),  Vector2(8, 1)],
		[Control.PRESET_BOTTOM_LEFT, Vector2(-1, -1), Vector2(8, 1)],
		[Control.PRESET_BOTTOM_RIGHT,Vector2(-7, -1), Vector2(8, 1)],
	]
	for t in ticks:
		var r := ColorRect.new()
		r.color = tick_color
		r.set_anchors_preset(t[0])
		r.position = t[1]
		r.size = t[2]
		r.mouse_filter = Control.MOUSE_FILTER_IGNORE
		frame.add_child(r)

	var tex_path := "res://ui/assets/car_thumbs/%s-thumb.png" % car_id
	if ResourceLoader.exists(tex_path):
		var thumb := TextureRect.new()
		thumb.texture = load(tex_path)
		thumb.set_anchors_preset(Control.PRESET_FULL_RECT)
		thumb.offset_left = 8.0
		thumb.offset_right = -8.0
		thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if not focused:
			thumb.modulate.a = 0.85
		frame.add_child(thumb)

	return frame


func _build_micro_stat(label_text: String, value: int) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var lbl := Label.new()
	lbl.text = label_text
	lbl.theme_type_variation = "MonoLabel"
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", UI.INK_700)
	box.add_child(lbl)

	var seg_row := HBoxContainer.new()
	seg_row.add_theme_constant_override("separation", 2)
	seg_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(seg_row)

	for i in range(10):
		var seg := ColorRect.new()
		seg.custom_minimum_size = Vector2(10, 10)
		seg.color = UI.NEON_LIME if i < value else UI.INK_300
		seg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		seg_row.add_child(seg)

	return box


func _on_shop_row_gui_input(event: InputEvent, car_id: String) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_select_shop_row(car_id)
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER or event.keycode == KEY_SPACE:
			_select_shop_row(car_id)


func _select_shop_row(car_id: String) -> void:
	# Enter on a row: buy if not owned and affordable; equip if owned.
	if car_id in CareerState.owned_cars:
		CareerState.select_car(car_id)
		_on_shop_back()
	elif CareerState.can_afford(car_id):
		_on_shop_buy(car_id)


func _on_shop_buy(car_id: String) -> void:
	if CareerState.buy_car(car_id):
		if CareerState.owned_cars.size() == 1:
			CareerState.select_car(car_id)
		_populate_shop()


func _on_shop_back() -> void:
	_show_hub()


# === Хелперы для построения UI ===

func _create_centered_panel(panel_name: String, size: Vector2) -> Panel:
	var panel := Panel.new()
	panel.name = panel_name
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.offset_left = -size.x / 2
	panel.offset_right = size.x / 2
	panel.offset_top = -size.y / 2
	panel.offset_bottom = size.y / 2
	panel.visible = false
	return panel


func _create_inner_vbox(panel: Panel) -> VBoxContainer:
	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 30
	vbox.offset_top = 25
	vbox.offset_right = -30
	vbox.offset_bottom = -25
	panel.add_child(vbox)
	return vbox


func _create_back_button() -> Button:
	var btn := Button.new()
	btn.text = "Назад"
	btn.custom_minimum_size = Vector2(0, 50)
	btn.add_theme_font_size_override("font_size", 24)
	return btn


func _add_spacer(parent: Control, height: float) -> void:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, height)
	parent.add_child(spacer)


func _add_expand_spacer(parent: Control) -> void:
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(spacer)
