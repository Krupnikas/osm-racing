extends CanvasLayer

## Overlay панель настроек постпроцессинга
## Открывается по P, показывается слева под метриками
## Все изменения применяются в реалтайме к Environment

var _panel: PanelContainer
var _scroll: ScrollContainer
var _vbox: VBoxContainer
var _visible := false

var _environment: Environment
var _sliders := {}  # name -> HSlider
var _labels := {}   # name -> Label (value display)

const PANEL_WIDTH := 280
const FONT_SIZE := 13
const SLIDER_HEIGHT := 20

# Цвета для групп
const GROUP_COLOR := Color(0.9, 0.8, 0.3)
const LABEL_COLOR := Color(0.85, 0.85, 0.85)
const VALUE_COLOR := Color(0.5, 0.9, 0.5)
const BG_COLOR := Color(0.05, 0.05, 0.08, 0.85)


func _ready() -> void:
	layer = 110  # Выше ColorGrading (100)
	await get_tree().process_frame
	_find_environment()
	_build_ui()
	_panel.visible = false
	print("PostProcessOverlay: Ready (press P to toggle)")


func _find_environment() -> void:
	var world_env := get_tree().current_scene.find_child("WorldEnvironment", true, false) as WorldEnvironment
	if world_env:
		_environment = world_env.environment


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_P:
			_visible = not _visible
			_panel.visible = _visible
			if _visible:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
				_sync_all_from_environment()
			else:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _build_ui() -> void:
	# Фон панели
	_panel = PanelContainer.new()
	_panel.name = "PostProcessPanel"

	var style := StyleBoxFlat.new()
	style.bg_color = BG_COLOR
	style.corner_radius_top_left = 0
	style.corner_radius_top_right = 8
	style.corner_radius_bottom_left = 0
	style.corner_radius_bottom_right = 8
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	_panel.add_theme_stylebox_override("panel", style)

	_panel.position = Vector2(0, 90)  # Под CoordsLabel
	_panel.size = Vector2(PANEL_WIDTH, 0)

	# ScrollContainer для прокрутки
	_scroll = ScrollContainer.new()
	_scroll.custom_minimum_size = Vector2(PANEL_WIDTH - 16, 600)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_panel.add_child(_scroll)

	_vbox = VBoxContainer.new()
	_vbox.custom_minimum_size.x = PANEL_WIDTH - 32
	_scroll.add_child(_vbox)

	# === TITLE ===
	_add_title("POST-PROCESSING  [P]")

	# === TONEMAPPING ===
	_add_group("TONEMAPPING")
	_add_option("tonemap_mode", "Tonemap", ["Linear", "Reinhard", "Filmic", "ACES"], _get_tonemap_mode())
	_add_slider("tonemap_exposure", "Exposure", 0.1, 3.0, 0.05)
	_add_slider("tonemap_white", "White", 1.0, 16.0, 0.1)

	# === GLOW / BLOOM ===
	_add_group("GLOW / BLOOM")
	_add_toggle("glow_enabled", "Glow")
	_add_slider("glow_intensity", "Intensity", 0.0, 5.0, 0.05)
	_add_slider("glow_bloom", "Bloom", 0.0, 1.0, 0.01)
	_add_slider("glow_hdr_threshold", "HDR Threshold", 0.0, 4.0, 0.05)
	_add_slider("glow_hdr_scale", "HDR Scale", 0.0, 4.0, 0.05)
	_add_slider("glow_hdr_luminance_cap", "Luminance Cap", 0.0, 64.0, 0.5)
	_add_slider("glow_mix", "Mix", 0.0, 1.0, 0.01)
	_add_option("glow_blend_mode", "Blend", ["Additive", "Screen", "Softlight", "Replace", "Mix"], _get_glow_blend())

	# === SSAO ===
	_add_group("SSAO")
	_add_toggle("ssao_enabled", "SSAO")
	_add_slider("ssao_radius", "Radius", 0.01, 16.0, 0.1)
	_add_slider("ssao_intensity", "Intensity", 0.0, 16.0, 0.1)
	_add_slider("ssao_power", "Power", 0.01, 16.0, 0.1)
	_add_slider("ssao_detail", "Detail", 0.0, 5.0, 0.05)
	_add_slider("ssao_light_affect", "Light Affect", 0.0, 1.0, 0.01)

	# === SSIL ===
	_add_group("SSIL")
	_add_toggle("ssil_enabled", "SSIL")
	_add_slider("ssil_radius", "Radius", 0.01, 16.0, 0.1)
	_add_slider("ssil_intensity", "Intensity", 0.0, 16.0, 0.1)
	_add_slider("ssil_sharpness", "Sharpness", 0.0, 1.0, 0.01)
	_add_slider("ssil_normal_rejection", "Normal Reject", 0.0, 1.5, 0.01)

	# === SSR ===
	_add_group("SSR")
	_add_toggle("ssr_enabled", "SSR")
	_add_slider("ssr_max_steps", "Max Steps", 1, 512, 1)
	_add_slider("ssr_fade_in", "Fade In", 0.0, 2.0, 0.01)
	_add_slider("ssr_fade_out", "Fade Out", 0.1, 8.0, 0.1)
	_add_slider("ssr_depth_tolerance", "Depth Tol.", 0.01, 128.0, 0.5)

	# === SDFGI ===
	_add_group("SDFGI")
	_add_toggle("sdfgi_enabled", "SDFGI")
	_add_slider("sdfgi_energy", "Energy", 0.0, 16.0, 0.1)
	_add_slider("sdfgi_bounce_feedback", "Bounce", 0.0, 1.0, 0.01)
	_add_slider("sdfgi_normal_bias", "Normal Bias", 0.0, 16.0, 0.1)
	_add_slider("sdfgi_probe_bias", "Probe Bias", 0.0, 16.0, 0.1)

	# === FOG ===
	_add_group("FOG")
	_add_toggle("fog_enabled", "Fog")
	_add_slider("fog_density", "Density", 0.0, 0.05, 0.0001)
	_add_slider("fog_aerial_perspective", "Aerial Persp.", 0.0, 1.0, 0.01)
	_add_slider("fog_sky_affect", "Sky Affect", 0.0, 1.0, 0.01)
	_add_slider("fog_sun_scatter", "Sun Scatter", 0.0, 1.0, 0.01)

	# === VOLUMETRIC FOG ===
	_add_group("VOLUMETRIC FOG")
	_add_toggle("volumetric_fog_enabled", "Vol. Fog")
	_add_slider("volumetric_fog_density", "Density", 0.0, 0.1, 0.001)
	_add_slider("volumetric_fog_anisotropy", "Anisotropy", -1.0, 1.0, 0.01)
	_add_slider("volumetric_fog_length", "Length", 10.0, 500.0, 5.0)
	_add_slider("volumetric_fog_detail_spread", "Detail Spread", 0.5, 6.0, 0.1)
	_add_slider("volumetric_fog_ambient_inject", "Ambient Inj.", 0.0, 16.0, 0.1)
	_add_slider("volumetric_fog_gi_inject", "GI Inject", 0.0, 16.0, 0.1)
	_add_slider("volumetric_fog_sky_affect", "Sky Affect", 0.0, 1.0, 0.01)
	_add_slider("volumetric_fog_emission_energy", "Emission E.", 0.0, 16.0, 0.1)

	# === ADJUSTMENTS ===
	_add_group("ADJUSTMENTS")
	_add_toggle("adjustment_enabled", "Adjustments")
	_add_slider("adjustment_brightness", "Brightness", 0.01, 3.0, 0.01)
	_add_slider("adjustment_contrast", "Contrast", 0.01, 3.0, 0.01)
	_add_slider("adjustment_saturation", "Saturation", 0.0, 3.0, 0.01)

	add_child(_panel)

	# Синхронизируем значения из Environment
	_sync_all_from_environment()


func _add_title(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 15)
	label.add_theme_color_override("font_color", Color(1, 1, 1))
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_vbox.add_child(label)
	var sep := HSeparator.new()
	sep.add_theme_constant_override("separation", 4)
	_vbox.add_child(sep)


func _add_group(text: String) -> void:
	var spacer := Control.new()
	spacer.custom_minimum_size.y = 6
	_vbox.add_child(spacer)
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", FONT_SIZE)
	label.add_theme_color_override("font_color", GROUP_COLOR)
	_vbox.add_child(label)


func _add_slider(prop: String, display_name: String, min_val: float, max_val: float, step: float) -> void:
	var hbox := HBoxContainer.new()
	hbox.custom_minimum_size.y = SLIDER_HEIGHT

	var name_label := Label.new()
	name_label.text = display_name
	name_label.custom_minimum_size.x = 90
	name_label.add_theme_font_size_override("font_size", FONT_SIZE)
	name_label.add_theme_color_override("font_color", LABEL_COLOR)
	hbox.add_child(name_label)

	var slider := HSlider.new()
	slider.min_value = min_val
	slider.max_value = max_val
	slider.step = step
	slider.custom_minimum_size.x = 100
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value_changed.connect(_on_slider_changed.bind(prop))
	hbox.add_child(slider)
	_sliders[prop] = slider

	var val_label := Label.new()
	val_label.custom_minimum_size.x = 50
	val_label.add_theme_font_size_override("font_size", FONT_SIZE)
	val_label.add_theme_color_override("font_color", VALUE_COLOR)
	val_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hbox.add_child(val_label)
	_labels[prop] = val_label

	_vbox.add_child(hbox)


func _add_toggle(prop: String, display_name: String) -> void:
	var hbox := HBoxContainer.new()
	hbox.custom_minimum_size.y = SLIDER_HEIGHT

	var check := CheckBox.new()
	check.text = display_name
	check.add_theme_font_size_override("font_size", FONT_SIZE)
	check.add_theme_color_override("font_color", LABEL_COLOR)
	check.toggled.connect(_on_toggle_changed.bind(prop))
	hbox.add_child(check)
	_sliders[prop] = check  # Reuse dict for toggles

	_vbox.add_child(hbox)


func _add_option(prop: String, display_name: String, options: Array, current: int) -> void:
	var hbox := HBoxContainer.new()
	hbox.custom_minimum_size.y = SLIDER_HEIGHT

	var name_label := Label.new()
	name_label.text = display_name
	name_label.custom_minimum_size.x = 90
	name_label.add_theme_font_size_override("font_size", FONT_SIZE)
	name_label.add_theme_color_override("font_color", LABEL_COLOR)
	hbox.add_child(name_label)

	var option_btn := OptionButton.new()
	for opt in options:
		option_btn.add_item(opt)
	option_btn.selected = current
	option_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	option_btn.add_theme_font_size_override("font_size", FONT_SIZE)
	option_btn.item_selected.connect(_on_option_changed.bind(prop))
	hbox.add_child(option_btn)
	_sliders[prop] = option_btn

	_vbox.add_child(hbox)


func _get_tonemap_mode() -> int:
	if not _environment:
		return 2
	return _environment.tonemap_mode


func _get_glow_blend() -> int:
	if not _environment:
		return 0
	return _environment.glow_blend_mode


# === Sync from Environment ===

func _sync_all_from_environment() -> void:
	if not _environment:
		return

	_sync_slider("tonemap_exposure", _environment.tonemap_exposure)
	_sync_slider("tonemap_white", _environment.tonemap_white)

	_sync_toggle("glow_enabled", _environment.glow_enabled)
	_sync_slider("glow_intensity", _environment.glow_intensity)
	_sync_slider("glow_bloom", _environment.glow_bloom)
	_sync_slider("glow_hdr_threshold", _environment.glow_hdr_threshold)
	_sync_slider("glow_hdr_scale", _environment.glow_hdr_scale)
	_sync_slider("glow_hdr_luminance_cap", _environment.glow_hdr_luminance_cap)
	_sync_slider("glow_mix", _environment.glow_mix)

	_sync_toggle("ssao_enabled", _environment.ssao_enabled)
	_sync_slider("ssao_radius", _environment.ssao_radius)
	_sync_slider("ssao_intensity", _environment.ssao_intensity)
	_sync_slider("ssao_power", _environment.ssao_power)
	_sync_slider("ssao_detail", _environment.ssao_detail)
	_sync_slider("ssao_light_affect", _environment.ssao_light_affect)

	_sync_toggle("ssil_enabled", _environment.ssil_enabled)
	_sync_slider("ssil_radius", _environment.ssil_radius)
	_sync_slider("ssil_intensity", _environment.ssil_intensity)
	_sync_slider("ssil_sharpness", _environment.ssil_sharpness)
	_sync_slider("ssil_normal_rejection", _environment.ssil_normal_rejection)

	_sync_toggle("ssr_enabled", _environment.ssr_enabled)
	_sync_slider("ssr_max_steps", _environment.ssr_max_steps)
	_sync_slider("ssr_fade_in", _environment.ssr_fade_in)
	_sync_slider("ssr_fade_out", _environment.ssr_fade_out)
	_sync_slider("ssr_depth_tolerance", _environment.ssr_depth_tolerance)

	_sync_toggle("sdfgi_enabled", _environment.sdfgi_enabled)
	_sync_slider("sdfgi_energy", _environment.sdfgi_energy)
	_sync_slider("sdfgi_bounce_feedback", _environment.sdfgi_bounce_feedback)
	_sync_slider("sdfgi_normal_bias", _environment.sdfgi_normal_bias)
	_sync_slider("sdfgi_probe_bias", _environment.sdfgi_probe_bias)

	_sync_toggle("fog_enabled", _environment.fog_enabled)
	_sync_slider("fog_density", _environment.fog_density)
	_sync_slider("fog_aerial_perspective", _environment.fog_aerial_perspective)
	_sync_slider("fog_sky_affect", _environment.fog_sky_affect)
	_sync_slider("fog_sun_scatter", _environment.fog_sun_scatter)

	_sync_toggle("volumetric_fog_enabled", _environment.volumetric_fog_enabled)
	_sync_slider("volumetric_fog_density", _environment.volumetric_fog_density)
	_sync_slider("volumetric_fog_anisotropy", _environment.volumetric_fog_anisotropy)
	_sync_slider("volumetric_fog_length", _environment.volumetric_fog_length)
	_sync_slider("volumetric_fog_detail_spread", _environment.volumetric_fog_detail_spread)
	_sync_slider("volumetric_fog_ambient_inject", _environment.volumetric_fog_ambient_inject)
	_sync_slider("volumetric_fog_gi_inject", _environment.volumetric_fog_gi_inject)
	_sync_slider("volumetric_fog_sky_affect", _environment.volumetric_fog_sky_affect)
	_sync_slider("volumetric_fog_emission_energy", _environment.volumetric_fog_emission_energy)

	_sync_toggle("adjustment_enabled", _environment.adjustment_enabled)
	_sync_slider("adjustment_brightness", _environment.adjustment_brightness)
	_sync_slider("adjustment_contrast", _environment.adjustment_contrast)
	_sync_slider("adjustment_saturation", _environment.adjustment_saturation)

	_sync_option("tonemap_mode", _environment.tonemap_mode)
	_sync_option("glow_blend_mode", _environment.glow_blend_mode)


func _sync_slider(prop: String, value: float) -> void:
	var slider: HSlider = _sliders.get(prop)
	if slider:
		slider.set_value_no_signal(value)
	_update_value_label(prop, value)


func _sync_toggle(prop: String, value: bool) -> void:
	var check: CheckBox = _sliders.get(prop)
	if check:
		check.set_pressed_no_signal(value)


func _sync_option(prop: String, value: int) -> void:
	var btn: OptionButton = _sliders.get(prop)
	if btn:
		btn.selected = value


func _update_value_label(prop: String, value: float) -> void:
	var label: Label = _labels.get(prop)
	if label:
		if prop == "ssr_max_steps":
			label.text = "%d" % int(value)
		elif prop.ends_with("density") and value < 0.01:
			label.text = "%.4f" % value
		elif absf(value) < 0.1:
			label.text = "%.3f" % value
		elif absf(value) < 10.0:
			label.text = "%.2f" % value
		else:
			label.text = "%.1f" % value


# === Apply to Environment ===

func _on_slider_changed(value: float, prop: String) -> void:
	if not _environment:
		return
	_environment.set(prop, value)
	_update_value_label(prop, value)


func _on_toggle_changed(value: bool, prop: String) -> void:
	if not _environment:
		return
	_environment.set(prop, value)


func _on_option_changed(index: int, prop: String) -> void:
	if not _environment:
		return
	_environment.set(prop, index)
