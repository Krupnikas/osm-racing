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
	"ford_focus_st_2006": "2006 · 2.5L · 225 HP · FWD · 1392 KG",
	"honda_civic_si_2006": "2006 · 2.0L · 197 HP · FWD · 1270 KG",
	"mazda_rx8_2006": "2006 · 1.3L Rotary · 232 HP · RWD · 1310 KG",
	"audi_tt_32_2003": "2003 · 3.2L VR6 · 250 HP · AWD · 1510 KG",
	"volga_gaz3110": "2000 · 2.3L · 150 HP · RWD · 1400 KG",
	"lancer_evo_x_2008": "2008 · 2.0L Turbo · 291 HP · AWD · 1560 KG",
	"subaru_sti_2011": "2011 · 2.5L Turbo · 305 HP · AWD · 1505 KG",
	"mercedes_clk55_2003": "2003 · 5.4L V8 · 367 HP · RWD · 1635 KG",
	"porsche_cayenne_turbo_s_2009": "2009 · 4.8L TT V8 · 550 HP · AWD · 2355 KG",
}

# — Tunnel car-select (NFS Underground style) feature flag —
const USE_TUNNEL_SELECT := true
const _TUNNEL_STRIP_N := 14
const _TUNNEL_SPACING := 4.0
const _TUNNEL_LEN: float = _TUNNEL_STRIP_N * _TUNNEL_SPACING
const _TUNNEL_SPEED := 10.0
const _TUNNEL_HW := 4.5
const _CAR_Y_ANGLE := 0.0

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

# Tunnel mode state
var _tunnel_pairs: Array[Node3D] = []
var _transition_tween: Tween = null
var _is_transitioning := false
var _orbit_yaw := 0.0
var _orbit_pitch := 0.35
var _dragging := false
var _wheel_nodes: Array[Node3D] = []


func _ready() -> void:
	_car_ids = CarSettings.get_car_ids()
	_initial_car_id = CarSettings.selected_car_id
	_current_index = max(0, _car_ids.find(CarSettings.selected_car_id))
	_build_ui()
	if USE_TUNNEL_SELECT:
		_build_tunnel()
	# Preview is loaded lazily on show_selection() — otherwise the default
	# car would briefly stack underneath whatever the host actually wants
	# to display (e.g. Garage focuses an owned car).


func _process(delta: float) -> void:
	if not visible:
		return
	if USE_TUNNEL_SELECT:
		_scroll_tunnel(delta)
	elif _preview_car:
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
		if _transition_tween and _transition_tween.is_valid():
			_transition_tween.kill()
		_is_transitioning = false
		_wheel_nodes.clear()
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
	if USE_TUNNEL_SELECT and _is_transitioning:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_LEFT, KEY_A:
				_on_prev_pressed()
			KEY_RIGHT, KEY_D:
				_on_next_pressed()
			KEY_ESCAPE:
				_on_back_pressed()


func _unhandled_input(event: InputEvent) -> void:
	if not visible or not USE_TUNNEL_SELECT:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
	if event is InputEventMouseMotion and _dragging:
		_orbit_yaw -= event.relative.x * 0.005
		_orbit_pitch = clampf(_orbit_pitch + event.relative.y * 0.003, -0.1, 0.6)
		_update_orbit_camera()


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


# === Tunnel (NFS Underground style) ===

func _build_tunnel() -> void:
	var vp: SubViewport = $PreviewViewport/SubViewport
	vp.transparent_bg = false

	# Camera: rear-right 3/4 view
	var cam: Camera3D = vp.get_node("Camera3D")
	cam.transform = Transform3D.IDENTITY
	cam.position = Vector3(3.0, 1.8, 3.0)
	cam.look_at(Vector3(0, 0.3, -6.0), Vector3.UP)
	cam.fov = 50.0

	# Dim existing lights — neon does the work
	vp.get_node("DirectionalLight3D").light_energy = 0.3
	vp.get_node("AmbientLight").light_energy = 0.15

	# Environment: dark bg + glow bloom on emissive neon + depth fog
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.01, 0.01, 0.02)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.02, 0.02, 0.04)
	env.glow_enabled = true
	env.glow_intensity = 0.8
	env.glow_bloom = 0.15
	env.fog_enabled = true
	env.fog_light_color = Color(0.01, 0.01, 0.02)
	env.fog_density = 0.015
	env.ssr_enabled = true
	env.ssr_max_steps = 64
	env.ssr_fade_in = 0.15
	env.ssr_fade_out = 2.0
	env.ssr_depth_tolerance = 0.2
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)

	# ---- materials ----
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.02, 0.02, 0.04)
	floor_mat.metallic = 0.95
	floor_mat.roughness = 0.1

	var cyan_mat := StandardMaterial3D.new()
	cyan_mat.albedo_color = Color.BLACK
	cyan_mat.emission_enabled = true
	cyan_mat.emission = Color(0.0, 0.85, 1.0)
	cyan_mat.emission_energy_multiplier = 4.0

	var magenta_mat := StandardMaterial3D.new()
	magenta_mat.albedo_color = Color.BLACK
	magenta_mat.emission_enabled = true
	magenta_mat.emission = Color(1.0, 0.05, 0.55)
	magenta_mat.emission_energy_multiplier = 4.0

	var dim_mat := StandardMaterial3D.new()
	dim_mat.albedo_color = Color.BLACK
	dim_mat.emission_enabled = true
	dim_mat.emission = Color(0.35, 0.35, 0.45)
	dim_mat.emission_energy_multiplier = 1.5

	# ---- geometry ----
	# Floor: dark, wet-look reflective
	var floor_mi := MeshInstance3D.new()
	var floor_pm := PlaneMesh.new()
	floor_pm.size = Vector2(_TUNNEL_HW * 3, _TUNNEL_LEN * 4)
	floor_mi.mesh = floor_pm
	floor_mi.position = Vector3(0, -0.01, 0)
	floor_mi.material_override = floor_mat
	vp.add_child(floor_mi)

	# Continuous neon base-strips (static, define corridor edges)
	var base_mesh := BoxMesh.new()
	base_mesh.size = Vector3(0.04, 0.06, _TUNNEL_LEN * 3)
	for side in [-1.0, 1.0]:
		var strip := MeshInstance3D.new()
		strip.mesh = base_mesh
		strip.material_override = cyan_mat if side < 0 else magenta_mat
		strip.position = Vector3(side * _TUNNEL_HW, 0.03, -_TUNNEL_LEN * 0.5)
		vp.add_child(strip)

	# Scrolling strip pairs (vertical posts + floor markers)
	var post_mesh := BoxMesh.new()
	post_mesh.size = Vector3(0.06, 1.8, 0.06)
	var marker_mesh := BoxMesh.new()
	marker_mesh.size = Vector3(0.12, 0.02, 1.6)

	for i in _TUNNEL_STRIP_N:
		var pair := Node3D.new()
		pair.position.z = -float(i) * _TUNNEL_SPACING + _TUNNEL_LEN * 0.3

		var left := MeshInstance3D.new()
		left.mesh = post_mesh
		left.material_override = cyan_mat
		left.position = Vector3(-_TUNNEL_HW, 0.9, 0)
		pair.add_child(left)

		var right := MeshInstance3D.new()
		right.mesh = post_mesh
		right.material_override = magenta_mat
		right.position = Vector3(_TUNNEL_HW, 0.9, 0)
		pair.add_child(right)

		var fm := MeshInstance3D.new()
		fm.mesh = marker_mesh
		fm.material_override = dim_mat
		fm.position = Vector3(0, 0.01, 0)
		pair.add_child(fm)

		# Small omni lights on each pair — move with the posts
		var ol_l := OmniLight3D.new()
		ol_l.light_color = Color(0.0, 0.85, 1.0)
		ol_l.light_energy = 0.6
		ol_l.omni_range = 4.0
		ol_l.omni_attenuation = 1.5
		ol_l.position = Vector3(-_TUNNEL_HW, 0.5, 0)
		pair.add_child(ol_l)

		var ol_r := OmniLight3D.new()
		ol_r.light_color = Color(1.0, 0.05, 0.55)
		ol_r.light_energy = 0.6
		ol_r.omni_range = 4.0
		ol_r.omni_attenuation = 1.5
		ol_r.position = Vector3(_TUNNEL_HW, 0.5, 0)
		pair.add_child(ol_r)

		vp.add_child(pair)
		_tunnel_pairs.append(pair)


func _scroll_tunnel(delta: float) -> void:
	# Scroll neon strip pairs toward camera, wrap when past
	var move := _TUNNEL_SPEED * delta
	var wrap_z: float = _TUNNEL_SPACING * 3
	for pair in _tunnel_pairs:
		pair.position.z += move
		if pair.position.z > wrap_z:
			pair.position.z -= _TUNNEL_LEN
	# Spin wheel meshes to simulate driving
	for w in _wheel_nodes:
		if is_instance_valid(w):
			w.rotate_x(-delta * 12.0)


func _update_orbit_camera() -> void:
	var cam: Camera3D = $PreviewViewport/SubViewport/Camera3D
	var radius := 7.0
	var cx := sin(_orbit_yaw) * radius * cos(_orbit_pitch)
	var cy := 1.2 + sin(_orbit_pitch) * radius * 0.6
	var cz := cos(_orbit_yaw) * radius * cos(_orbit_pitch)
	cam.position = Vector3(cx, cy, cz)
	cam.look_at(Vector3(0, 0.5, 0), Vector3.UP)


func _collect_wheel_nodes(root: Node) -> void:
	_wheel_nodes.clear()
	for child in root.get_children():
		if child is Wheel:
			var w: Wheel = child as Wheel
			if w.wheel_node:
				_wheel_nodes.append(w.wheel_node)


func _update_3d_tunnel(car_id: String, direction: int) -> void:
	var container: Node3D = $PreviewViewport/SubViewport/CarPreviewContainer

	if _transition_tween and _transition_tween.is_valid():
		_transition_tween.kill()

	var old_car := _preview_car

	# Instantiate new car
	var scene_path: String = CarSettings.CARS[car_id]["scene"]
	var new_car := (load(scene_path) as PackedScene).instantiate()
	new_car.scale = Vector3(1.5, 1.5, 1.5)
	new_car.rotation.y = _CAR_Y_ANGLE
	if new_car is RigidBody3D:
		new_car.freeze = true
	elif new_car is VehicleBody3D:
		new_car.set_physics_process(false)

	if direction == 0:
		# Initial load — no animation
		new_car.position = Vector3.ZERO
		container.add_child(new_car)
		if old_car:
			old_car.queue_free()
		_preview_car = new_car
		_collect_wheel_nodes(new_car)
		# Reset orbit camera to default angle
		_orbit_yaw = 0.0
		_orbit_pitch = 0.35
		_update_orbit_camera()
		return

	# Animated swap: old car exits, new car enters
	_is_transitioning = true
	var exit_z: float = -20.0 if direction > 0 else 16.0
	var enter_z: float = 16.0 if direction > 0 else -20.0

	new_car.position = Vector3(0, 0, enter_z)
	container.add_child(new_car)

	_transition_tween = create_tween().set_parallel()
	if old_car:
		_transition_tween.tween_property(old_car, "position:z", exit_z, 0.4) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_transition_tween.tween_property(new_car, "position:z", 0.0, 0.5) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT).set_delay(0.08)

	var ref := old_car
	_transition_tween.chain().tween_callback(func() -> void:
		if ref != null and is_instance_valid(ref):
			ref.queue_free()
		_is_transitioning = false
	)
	_preview_car = new_car
	_collect_wheel_nodes(new_car)
	# Camera stays at current orbit — no reset on car change


# === Updates ===

func _update_preview(direction: int = 0) -> void:
	var car_id: String = _car_ids[_current_index]
	var full_name: String = CarSettings.get_car_name(car_id).to_upper()
	var split := full_name.split(" ", false, 1)
	_name_make.text = split[0]
	_name_model.text = split[1] if split.size() > 1 else ""
	_spec_label.text = CAR_SPEC_LINES.get(car_id, "")
	_counter_label.text = "%02d / %02d" % [_current_index + 1, _car_ids.size()]
	_update_chevrons()
	_update_stat_segments(car_id)
	if USE_TUNNEL_SELECT:
		_update_3d_tunnel(car_id, direction)
	else:
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
	if USE_TUNNEL_SELECT and _is_transitioning:
		return
	_current_index = (_current_index - 1 + _car_ids.size()) % _car_ids.size()
	_update_preview(-1)


func _on_next_pressed() -> void:
	if USE_TUNNEL_SELECT and _is_transitioning:
		return
	_current_index = (_current_index + 1) % _car_ids.size()
	_update_preview(1)


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
