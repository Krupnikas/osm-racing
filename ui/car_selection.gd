extends Control

## Экран выбора машины (ВЫБОР МАШИНЫ).
## Реализован по дизайну screens-2.jsx → ScreenCarSelect.
##
## Two modes — "all cars" (главное меню → ВЫБОР МАШИНЫ) and "owned only"
## (КАРЬЕРА → ГАРАЖ). Selection / back are emitted as signals; the host
## screen wires the resulting action and the back path.

signal selection_done(car_id: String)
signal back_requested

const BrandMarkScene      = preload("res://ui/components/brand_mark.tscn")
const CornerChromeScript  = preload("res://ui/components/corner_chrome.gd")
const NeonStyleBoxScript  = preload("res://ui/neon_style_box.gd")
const FiraBoldItalicFont  = preload("res://ui/fonts/FiraSansCondensed-BoldItalic.ttf")

const CAR_SPEC_LINES := {
	"matiz":      "1998 · 0.8L · 51 HP · FWD · 720 KG",
	"logan":      "2004 · 1.4L · 75 HP · FWD · 975 KG",
	"nexia":      "1995 · 1.5L · 80 HP · FWD · 1080 KG",
	"polo":       "2009 · 1.6L · 105 HP · FWD · 1135 KG",
	"beetle":     "1968 · 1.5L · 53 HP · RWD · 880 KG",
	"bmw_m3_gtr": "2001 · 3.2L · 380 HP · RWD · 1350 KG",
}

static var _fira_tight: FontVariation = null
static func _get_fira_tight() -> FontVariation:
	if _fira_tight == null:
		_fira_tight = FontVariation.new()
		_fira_tight.base_font = FiraBoldItalicFont
		_fira_tight.spacing_glyph = 0
	return _fira_tight

var _car_ids: Array = []
var _current_index: int = 0
var _preview_car: Node3D = null
var _initial_car_id: String = ""
var _owned_only: bool = false

var _name_make: Label
var _name_model: Label
var _spec_label: Label
var _counter_label: Label
var _chevrons_left: Array[ColorRect] = []
var _chevrons_right: Array[ColorRect] = []
var _accel_segments: Array[ColorRect] = []
var _speed_segments: Array[ColorRect] = []
var _handle_segments: Array[ColorRect] = []
var _select_btn: Button


func _ready() -> void:
	_car_ids = CarSettings.get_car_ids()
	_initial_car_id = CarSettings.selected_car_id
	_current_index = max(0, _car_ids.find(CarSettings.selected_car_id))
	_build_ui()
	# Preview is loaded lazily on show_selection() — otherwise the default
	# car would briefly stack underneath whatever the host actually wants
	# to display (e.g. Garage focuses an owned car).


func _process(delta: float) -> void:
	if _preview_car and visible:
		_preview_car.rotate_y(delta * 0.5)


func _notification(what: int) -> void:
	if what != NOTIFICATION_VISIBILITY_CHANGED:
		return
	var vp := get_node_or_null("PreviewViewport/SubViewport") as SubViewport
	if vp == null:
		return
	if visible:
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	else:
		# Drop the car AND stop rendering so no stale frame can leak from
		# a hidden CarSelection's render target into a sibling instance.
		var container := get_node_or_null("PreviewViewport/SubViewport/CarPreviewContainer")
		if container:
			for child in container.get_children():
				child.free()
		_preview_car = null
		vp.render_target_update_mode = SubViewport.UPDATE_DISABLED


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_LEFT, KEY_A:
				_on_prev_pressed()
			KEY_RIGHT, KEY_D:
				_on_next_pressed()
			KEY_ESCAPE:
				_on_back_pressed()


# === UI build ===

func _build_ui() -> void:
	# (No backdrop here — the standalone main menu's MenuBackdrop already
	# fills the screen behind us.)

	var brand := BrandMarkScene.instantiate() as Control
	brand.scale = Vector2(0.85, 0.85)
	brand.position = Vector2(90, 80)
	brand.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(brand)

	# Title block top-right.
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
	t_kicker.text = "// 04 / CAR SELECT · ВЫБОР"
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
	t1.text = "ВЫБОР"
	t1.theme_type_variation = "DisplayLabel"
	t1.add_theme_font_size_override("font_size", 88)
	t1.add_theme_color_override("font_color", UI.INK_900)
	t1.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	h2_stack.add_child(t1)

	var t2 := Label.new()
	t2.text = "МАШИНЫ"
	t2.theme_type_variation = "DisplayLabel"
	t2.add_theme_font_size_override("font_size", 88)
	t2.add_theme_color_override("font_color", Color(0, 0, 0, 0))
	t2.add_theme_color_override("font_outline_color", UI.NEON_CYAN)
	t2.add_theme_constant_override("outline_size", 2)
	t2.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	h2_stack.add_child(t2)

	# Top-center counter: chevrons on/off · "NN / TOTAL" · chevrons.
	_build_counter_strip()

	# Big car name + spec line — centered above the 3D preview.
	var name_box := VBoxContainer.new()
	name_box.set_anchors_preset(Control.PRESET_TOP_WIDE)
	name_box.offset_top = 220.0
	name_box.offset_bottom = 380.0
	name_box.alignment = BoxContainer.ALIGNMENT_BEGIN
	name_box.add_theme_constant_override("separation", 6)
	name_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(name_box)

	var name_row := HBoxContainer.new()
	name_row.alignment = BoxContainer.ALIGNMENT_CENTER
	name_row.add_theme_constant_override("separation", 18)
	name_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_box.add_child(name_row)

	_name_make = Label.new()
	_name_make.theme_type_variation = "DisplayLabel"
	_name_make.add_theme_font_override("font", _get_fira_tight())
	_name_make.add_theme_font_size_override("font_size", 88)
	_name_make.add_theme_color_override("font_color", UI.INK_900)
	name_row.add_child(_name_make)

	_name_model = Label.new()
	_name_model.theme_type_variation = "DisplayLabel"
	_name_model.add_theme_font_override("font", _get_fira_tight())
	_name_model.add_theme_font_size_override("font_size", 88)
	_name_model.add_theme_color_override("font_color", UI.NEON_CYAN)
	name_row.add_child(_name_model)

	_spec_label = Label.new()
	_spec_label.theme_type_variation = "MonoLabel"
	_spec_label.add_theme_font_size_override("font_size", 13)
	_spec_label.add_theme_color_override("font_color", UI.INK_500)
	_spec_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_box.add_child(_spec_label)

	# 3D preview lives in a SubViewportContainer that already exists in
	# the scene — reposition it to the central hero area.
	var preview: SubViewportContainer = $PreviewViewport
	preview.set_anchors_preset(Control.PRESET_FULL_RECT)
	preview.offset_left = 200.0
	preview.offset_right = -200.0
	preview.offset_top = 380.0
	preview.offset_bottom = -260.0
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Left + right chevron-arrow buttons flanking the preview.
	_build_arrow_button("Prev", true, _on_prev_pressed)
	_build_arrow_button("Next", false, _on_next_pressed)

	# Stats panel (bottom).
	_build_stats_panel()

	# Action buttons (ВЫБРАТЬ + ВЫЙТИ).
	_build_action_bar()

	# Corner chrome on top of everything.
	var chrome := Control.new()
	chrome.set_script(CornerChromeScript)
	chrome.set_anchors_preset(Control.PRESET_FULL_RECT)
	chrome.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(chrome)


func _build_counter_strip() -> void:
	var strip := HBoxContainer.new()
	strip.set_anchors_preset(Control.PRESET_CENTER_TOP)
	strip.offset_left = -160.0
	strip.offset_right = 160.0
	strip.offset_top = 130.0
	strip.offset_bottom = 160.0
	strip.alignment = BoxContainer.ALIGNMENT_CENTER
	strip.add_theme_constant_override("separation", 24)
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(strip)

	_chevrons_left = _build_chevron_group(strip, 5)

	_counter_label = Label.new()
	_counter_label.theme_type_variation = "MonoLabel"
	_counter_label.add_theme_font_size_override("font_size", 13)
	_counter_label.add_theme_color_override("font_color", UI.INK_500)
	_counter_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	strip.add_child(_counter_label)

	_chevrons_right = _build_chevron_group(strip, 3)


func _build_chevron_group(parent: Container, count: int) -> Array[ColorRect]:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(box)
	var out: Array[ColorRect] = []
	for i in count:
		var c := ColorRect.new()
		c.custom_minimum_size = Vector2(12, 4)
		c.color = UI.INK_400
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(c)
		out.append(c)
	return out


func _build_arrow_button(name_id: String, is_left: bool, callback: Callable) -> void:
	# Arrow button drawn as a parallelogram via NeonStyleBox shear, with a
	# big italic glyph centered inside.
	var btn := Button.new()
	btn.name = name_id + "Arrow"
	btn.flat = true
	btn.focus_mode = Control.FOCUS_NONE
	btn.set_anchors_preset(Control.PRESET_CENTER_LEFT if is_left else Control.PRESET_CENTER_RIGHT)
	if is_left:
		btn.offset_left = 60.0
		btn.offset_right = 140.0
	else:
		btn.offset_left = -140.0
		btn.offset_right = -60.0
	btn.offset_top = -50.0
	btn.offset_bottom = 50.0

	var sb: NeonStyleBox = NeonStyleBoxScript.new()
	sb.fill_color = UI.INK_100
	sb.outline_color = UI.NEON_CYAN
	sb.outline_width = 1.0
	sb.shear_deg = -18.0 if is_left else 18.0
	sb.glow_color = Color(UI.NEON_CYAN.r, UI.NEON_CYAN.g, UI.NEON_CYAN.b, 0.4)
	sb.glow_size = 14
	btn.add_theme_stylebox_override("normal", sb)
	btn.add_theme_stylebox_override("hover", sb)
	btn.add_theme_stylebox_override("pressed", sb)
	btn.add_theme_stylebox_override("focus", sb)

	# Glyph — Label child centered.
	var lbl := Label.new()
	lbl.text = "◀" if is_left else "▶"
	lbl.theme_type_variation = "DisplayLabel"
	lbl.add_theme_font_override("font", _get_fira_tight())
	lbl.add_theme_font_size_override("font_size", 36)
	lbl.add_theme_color_override("font_color", UI.NEON_CYAN)
	lbl.set_anchors_preset(Control.PRESET_FULL_RECT)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(lbl)

	btn.pressed.connect(callback)
	add_child(btn)


func _build_stats_panel() -> void:
	var panel := Panel.new()
	panel.name = "StatsPanel"
	panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	panel.offset_left = 200.0
	panel.offset_right = -200.0
	panel.offset_top = -260.0
	panel.offset_bottom = -180.0
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var sb: NeonStyleBox = NeonStyleBoxScript.new()
	sb.fill_color = Color(UI.INK_050.r, UI.INK_050.g, UI.INK_050.b, 0.85)
	sb.outline_color = UI.INK_300
	sb.outline_width = 1.0
	sb.shear_deg = 0.0
	sb.glow_size = 0
	sb.right_slant = 28.0
	panel.add_theme_stylebox_override("panel", sb)
	add_child(panel)

	var hbox := HBoxContainer.new()
	hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	hbox.offset_left = 32.0
	hbox.offset_right = -64.0
	hbox.offset_top = 0.0
	hbox.offset_bottom = 0.0
	hbox.add_theme_constant_override("separation", 32)
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(hbox)

	var accel := _build_stat_bar("УСКОРЕНИЕ")
	hbox.add_child(accel[0])
	_accel_segments = accel[1]

	var speed := _build_stat_bar("СКОРОСТЬ")
	hbox.add_child(speed[0])
	_speed_segments = speed[1]

	var handle := _build_stat_bar("УПРАВЛЕНИЕ")
	hbox.add_child(handle[0])
	_handle_segments = handle[1]


func _build_stat_bar(label_text: String) -> Array:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	box.add_theme_constant_override("separation", 6)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var lbl := Label.new()
	lbl.text = label_text
	lbl.theme_type_variation = "MonoLabel"
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", UI.INK_700)
	box.add_child(lbl)

	var seg_row := HBoxContainer.new()
	seg_row.add_theme_constant_override("separation", 3)
	seg_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(seg_row)

	var segments: Array[ColorRect] = []
	for _i in range(10):
		var seg := ColorRect.new()
		seg.custom_minimum_size = Vector2(20, 12)
		seg.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		seg.color = UI.INK_300
		seg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		seg_row.add_child(seg)
		segments.append(seg)

	return [box, segments]


func _build_action_bar() -> void:
	var bar := HBoxContainer.new()
	bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	bar.offset_left = 0.0
	bar.offset_right = 0.0
	bar.offset_top = -130.0
	bar.offset_bottom = -50.0
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	bar.add_theme_constant_override("separation", 24)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bar)

	_select_btn = _make_p_button("ВЫБРАТЬ", true)
	_select_btn.pressed.connect(_on_select_pressed)
	bar.add_child(_select_btn)

	var back_btn := _make_p_button("ВЫЙТИ", false)
	back_btn.pressed.connect(_on_back_pressed)
	bar.add_child(back_btn)


func _make_p_button(text_value: String, primary: bool) -> Button:
	# Cyan-fill primary button vs ghost button. Both use NeonStyleBox shear.
	var btn := Button.new()
	btn.text = text_value
	btn.add_theme_font_size_override("font_size", 24)
	btn.custom_minimum_size = Vector2(220, 64)
	btn.focus_mode = Control.FOCUS_ALL

	var fill := UI.NEON_CYAN if primary else Color(0, 0, 0, 0)
	var border := UI.NEON_CYAN if primary else UI.NEON_MAGENTA
	var text_color := UI.INK_000 if primary else UI.NEON_MAGENTA

	for state in ["normal", "hover", "pressed", "focus"]:
		var sb: NeonStyleBox = NeonStyleBoxScript.new()
		sb.fill_color = fill
		sb.outline_color = border
		sb.outline_width = 1.0
		sb.shear_deg = -14.0
		sb.glow_color = Color(border.r, border.g, border.b, 0.45)
		sb.glow_size = 16 if state in ["hover", "focus"] else (12 if primary else 0)
		btn.add_theme_stylebox_override(state, sb)

	btn.add_theme_color_override("font_color", text_color)
	btn.add_theme_color_override("font_hover_color", text_color)
	btn.add_theme_color_override("font_pressed_color", text_color)
	btn.add_theme_color_override("font_focus_color", text_color)
	return btn


# === Updates ===

func _update_preview() -> void:
	var car_id: String = _car_ids[_current_index]
	var full_name: String = CarSettings.get_car_name(car_id).to_upper()
	var split := full_name.split(" ", false, 1)
	_name_make.text = split[0]
	_name_model.text = split[1] if split.size() > 1 else ""
	_spec_label.text = CAR_SPEC_LINES.get(car_id, "")
	_counter_label.text = "%02d / %02d" % [_current_index + 1, _car_ids.size()]
	_update_chevrons()
	_update_stat_segments(car_id)
	_update_3d_preview(car_id)


func _update_chevrons() -> void:
	# Left chevrons fill from left as the index increases; right chevrons
	# fill from right as fewer items remain.
	var total := _car_ids.size()
	var pos := _current_index + 1
	for i in _chevrons_left.size():
		_chevrons_left[i].color = UI.NEON_CYAN if i < pos else UI.INK_400
	for i in _chevrons_right.size():
		var remaining := total - pos
		_chevrons_right[i].color = UI.NEON_CYAN if i < remaining else UI.INK_400


func _update_stat_segments(car_id: String) -> void:
	var stats: Dictionary = CarSettings.DISPLAY_STATS.get(car_id,
		{"accel": 0.5, "speed": 0.5, "handling": 0.5})
	_paint_segments(_accel_segments, int(round(float(stats["accel"]) * 10.0)))
	_paint_segments(_speed_segments, int(round(float(stats["speed"]) * 10.0)))
	_paint_segments(_handle_segments, int(round(float(stats["handling"]) * 10.0)))


func _paint_segments(segs: Array[ColorRect], value: int) -> void:
	for i in segs.size():
		segs[i].color = UI.NEON_LIME if i < value else UI.INK_300


func _update_3d_preview(car_id: String) -> void:
	var container: Node3D = $PreviewViewport/SubViewport/CarPreviewContainer
	for child in container.get_children():
		child.free()
	_preview_car = null

	var scene_path: String = CarSettings.CARS[car_id]["scene"]
	var car_scene := load(scene_path) as PackedScene
	_preview_car = car_scene.instantiate()
	_preview_car.position = Vector3.ZERO
	_preview_car.scale = Vector3(1.5, 1.5, 1.5)
	if _preview_car is RigidBody3D:
		_preview_car.freeze = true
	elif _preview_car is VehicleBody3D:
		_preview_car.set_physics_process(false)
	container.add_child(_preview_car)


# === Actions ===

func _on_prev_pressed() -> void:
	_current_index = (_current_index - 1 + _car_ids.size()) % _car_ids.size()
	_update_preview()


func _on_next_pressed() -> void:
	_current_index = (_current_index + 1) % _car_ids.size()
	_update_preview()


func _on_select_pressed() -> void:
	if _car_ids.is_empty():
		return
	visible = false
	selection_done.emit(_car_ids[_current_index])


func _on_back_pressed() -> void:
	visible = false
	back_requested.emit()


func show_selection(owned_only: bool = false, initial_car_id: String = "") -> void:
	_owned_only = owned_only
	if owned_only:
		_car_ids = []
		for cid in CareerState.owned_cars:
			_car_ids.append(cid)
	else:
		_car_ids = CarSettings.get_car_ids()

	if initial_car_id == "":
		initial_car_id = (CareerState.selected_car if owned_only
			else CarSettings.selected_car_id)
	_initial_car_id = initial_car_id
	_current_index = max(0, _car_ids.find(initial_car_id))

	visible = true
	if _car_ids.size() > 0:
		_update_preview()
	if _select_btn:
		_select_btn.call_deferred("grab_focus")
