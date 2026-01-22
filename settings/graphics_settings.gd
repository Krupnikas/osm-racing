extends Node
class_name GraphicsSettings

## Настройки графики с возможностью включения/отключения эффектов

signal settings_changed

# Настройки по умолчанию
var ssr_enabled := true
var fog_enabled := true
var glow_enabled := true
var ssao_enabled := true
var normal_maps_enabled := true
var clouds_enabled := true

# Antialiasing - по умолчанию только TAA (легче чем MSAA)
var msaa_mode := Viewport.MSAA_DISABLED  # MSAA тяжёлый, по умолчанию выкл
var taa_enabled := true  # TAA легче и лучше сглаживает

# Дополнительные эффекты - по умолчанию выкл для производительности
var motion_blur_enabled := false
var dof_enabled := false  # DOF тяжёлый
var chromatic_aberration_enabled := false
var vignette_enabled := false  # Виньетка легкая но не критична

# Ссылки на сцену
var _environment: Environment
var _world_env: WorldEnvironment
var _camera: Camera3D
var _compositor: Compositor
var _compositor_effect_motion_blur: CompositorEffect
var _compositor_effect_dof: CompositorEffect

# Сохранённые значения
var _saved_ssr_max_steps := 64
var _saved_fog_density := 0.0003
var _saved_glow_intensity := 0.15


func _ready() -> void:
	await get_tree().process_frame
	_find_environment()
	_find_camera()
	_load_settings()
	_apply_all()


func _find_environment() -> void:
	_world_env = get_tree().current_scene.find_child("WorldEnvironment", true, false) as WorldEnvironment
	if _world_env:
		_environment = _world_env.environment


func _find_camera() -> void:
	# Ищем камеру в сцене
	_camera = get_tree().current_scene.find_child("Camera3D", true, false) as Camera3D
	if not _camera:
		# Пробуем найти любую Camera3D
		var cameras := get_tree().get_nodes_in_group("camera")
		if cameras.size() > 0:
			_camera = cameras[0] as Camera3D


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_F1:
				toggle_ssr()
			KEY_F2:
				toggle_fog()
			KEY_F3:
				toggle_glow()
			KEY_F4:
				toggle_ssao()
			KEY_F5:
				toggle_normal_maps()
			KEY_F6:
				toggle_clouds()
			KEY_F7:
				set_quality_low()
			KEY_F8:
				set_quality_medium()
			KEY_F9:
				set_quality_high()


func toggle_ssr() -> void:
	ssr_enabled = not ssr_enabled
	_apply_ssr()
	print("SSR: ", "ON" if ssr_enabled else "OFF")
	settings_changed.emit()


func toggle_fog() -> void:
	fog_enabled = not fog_enabled
	_apply_fog()
	print("Fog: ", "ON" if fog_enabled else "OFF")
	settings_changed.emit()


func toggle_glow() -> void:
	glow_enabled = not glow_enabled
	_apply_glow()
	print("Glow: ", "ON" if glow_enabled else "OFF")
	settings_changed.emit()


func toggle_ssao() -> void:
	ssao_enabled = not ssao_enabled
	_apply_ssao()
	print("SSAO: ", "ON" if ssao_enabled else "OFF")
	settings_changed.emit()


func toggle_normal_maps() -> void:
	normal_maps_enabled = not normal_maps_enabled
	print("Normal Maps: ", "ON" if normal_maps_enabled else "OFF")
	# Normal maps применяются при создании материалов
	settings_changed.emit()


func toggle_clouds() -> void:
	clouds_enabled = not clouds_enabled
	print("Clouds: ", "ON" if clouds_enabled else "OFF")
	settings_changed.emit()


func toggle_taa() -> void:
	taa_enabled = not taa_enabled
	_apply_taa()
	print("TAA: ", "ON" if taa_enabled else "OFF")
	settings_changed.emit()


func cycle_msaa() -> void:
	# Цикл: OFF -> 2X -> 4X -> OFF
	match msaa_mode:
		Viewport.MSAA_DISABLED:
			msaa_mode = Viewport.MSAA_2X
		Viewport.MSAA_2X:
			msaa_mode = Viewport.MSAA_4X
		Viewport.MSAA_4X:
			msaa_mode = Viewport.MSAA_DISABLED
		_:
			msaa_mode = Viewport.MSAA_DISABLED
	_apply_msaa()
	print("MSAA: ", _get_msaa_name())
	settings_changed.emit()


func set_msaa(mode: Viewport.MSAA) -> void:
	msaa_mode = mode
	_apply_msaa()
	settings_changed.emit()


func toggle_motion_blur() -> void:
	motion_blur_enabled = not motion_blur_enabled
	_apply_motion_blur()
	print("Motion Blur: ", "ON" if motion_blur_enabled else "OFF")
	settings_changed.emit()


func toggle_dof() -> void:
	dof_enabled = not dof_enabled
	_apply_dof()
	print("DOF: ", "ON" if dof_enabled else "OFF")
	settings_changed.emit()


func toggle_chromatic_aberration() -> void:
	chromatic_aberration_enabled = not chromatic_aberration_enabled
	_apply_chromatic_aberration()
	print("Chromatic Aberration: ", "ON" if chromatic_aberration_enabled else "OFF")
	settings_changed.emit()


func toggle_vignette() -> void:
	vignette_enabled = not vignette_enabled
	_apply_vignette()
	print("Vignette: ", "ON" if vignette_enabled else "OFF")
	settings_changed.emit()


func _apply_ssr() -> void:
	if _environment:
		_environment.ssr_enabled = ssr_enabled


func _apply_fog() -> void:
	if _environment:
		_environment.fog_enabled = fog_enabled


func _apply_glow() -> void:
	if _environment:
		_environment.glow_enabled = glow_enabled


func _apply_ssao() -> void:
	if _environment:
		_environment.ssao_enabled = ssao_enabled


func _apply_taa() -> void:
	var viewport := get_viewport()
	if viewport:
		viewport.use_taa = taa_enabled


func _apply_msaa() -> void:
	var viewport := get_viewport()
	if viewport:
		viewport.msaa_3d = msaa_mode


func _apply_motion_blur() -> void:
	# Motion blur через CameraAttributes
	if _camera and _camera.attributes:
		var attrs := _camera.attributes as CameraAttributesPractical
		if attrs:
			# Godot 4 не имеет встроенного motion blur в CameraAttributes
			# Используем custom compositor effect или оставляем как placeholder
			pass
	# Альтернативно можно использовать шейдер постобработки


func _apply_dof() -> void:
	# DOF через CameraAttributes
	if _camera:
		if not _camera.attributes:
			_camera.attributes = CameraAttributesPractical.new()
		var attrs := _camera.attributes as CameraAttributesPractical
		if attrs:
			if dof_enabled:
				attrs.dof_blur_far_enabled = true
				attrs.dof_blur_far_distance = 100.0
				attrs.dof_blur_far_transition = 50.0
				attrs.dof_blur_amount = 0.05
			else:
				attrs.dof_blur_far_enabled = false


func _apply_chromatic_aberration() -> void:
	# Chromatic aberration требует кастомного шейдера постобработки
	# Это placeholder для будущей реализации
	pass


func _apply_vignette() -> void:
	# Виньетка - placeholder, не влияет на производительность
	# В будущем можно добавить через кастомный шейдер
	pass


func _get_msaa_name() -> String:
	match msaa_mode:
		Viewport.MSAA_DISABLED:
			return "OFF"
		Viewport.MSAA_2X:
			return "2X"
		Viewport.MSAA_4X:
			return "4X"
		Viewport.MSAA_8X:
			return "8X"
		_:
			return "OFF"


func set_quality_low() -> void:
	ssr_enabled = false
	fog_enabled = false
	glow_enabled = false
	ssao_enabled = false
	normal_maps_enabled = false
	clouds_enabled = false
	msaa_mode = Viewport.MSAA_DISABLED
	taa_enabled = false
	motion_blur_enabled = false
	dof_enabled = false
	vignette_enabled = false
	_apply_all()
	print("Graphics: LOW")
	settings_changed.emit()


func set_quality_medium() -> void:
	ssr_enabled = false
	fog_enabled = true
	glow_enabled = true
	ssao_enabled = true
	normal_maps_enabled = true
	clouds_enabled = true
	msaa_mode = Viewport.MSAA_DISABLED  # MSAA тяжёлый
	taa_enabled = true  # TAA легче
	motion_blur_enabled = false
	dof_enabled = false
	vignette_enabled = false
	_apply_all()
	print("Graphics: MEDIUM")
	settings_changed.emit()


func set_quality_high() -> void:
	ssr_enabled = true
	fog_enabled = true
	glow_enabled = true
	ssao_enabled = true
	normal_maps_enabled = true
	clouds_enabled = true
	msaa_mode = Viewport.MSAA_2X  # 2X вместо 4X
	taa_enabled = true
	motion_blur_enabled = false
	dof_enabled = false  # DOF тяжёлый
	vignette_enabled = false
	_apply_all()
	print("Graphics: HIGH")
	settings_changed.emit()


func _apply_all() -> void:
	_apply_ssr()
	_apply_fog()
	_apply_glow()
	_apply_ssao()
	_apply_taa()
	_apply_msaa()
	_apply_dof()
	_apply_vignette()


func _load_settings() -> void:
	var config := ConfigFile.new()
	var err := config.load("user://graphics.cfg")
	if err == OK:
		ssr_enabled = config.get_value("graphics", "ssr", true)
		fog_enabled = config.get_value("graphics", "fog", true)
		glow_enabled = config.get_value("graphics", "glow", true)
		ssao_enabled = config.get_value("graphics", "ssao", true)
		normal_maps_enabled = config.get_value("graphics", "normal_maps", true)
		clouds_enabled = config.get_value("graphics", "clouds", true)
		msaa_mode = config.get_value("graphics", "msaa", Viewport.MSAA_2X)
		taa_enabled = config.get_value("graphics", "taa", true)
		motion_blur_enabled = config.get_value("graphics", "motion_blur", false)
		dof_enabled = config.get_value("graphics", "dof", false)
		vignette_enabled = config.get_value("graphics", "vignette", true)


func save_settings() -> void:
	var config := ConfigFile.new()
	config.set_value("graphics", "ssr", ssr_enabled)
	config.set_value("graphics", "fog", fog_enabled)
	config.set_value("graphics", "glow", glow_enabled)
	config.set_value("graphics", "ssao", ssao_enabled)
	config.set_value("graphics", "normal_maps", normal_maps_enabled)
	config.set_value("graphics", "clouds", clouds_enabled)
	config.set_value("graphics", "msaa", msaa_mode)
	config.set_value("graphics", "taa", taa_enabled)
	config.set_value("graphics", "motion_blur", motion_blur_enabled)
	config.set_value("graphics", "dof", dof_enabled)
	config.set_value("graphics", "vignette", vignette_enabled)
	config.save("user://graphics.cfg")


func get_settings_text() -> String:
	return """Graphics Settings:
  F1 - SSR: %s
  F2 - Fog: %s
  F3 - Glow: %s
  F4 - SSAO: %s
  F5 - Normal Maps: %s
  F6 - Clouds: %s
  F7 - Quality: LOW
  F8 - Quality: MEDIUM
  F9 - Quality: HIGH

  TAA: %s | MSAA: %s
  DOF: %s | Vignette: %s""" % [
		"ON" if ssr_enabled else "OFF",
		"ON" if fog_enabled else "OFF",
		"ON" if glow_enabled else "OFF",
		"ON" if ssao_enabled else "OFF",
		"ON" if normal_maps_enabled else "OFF",
		"ON" if clouds_enabled else "OFF",
		"ON" if taa_enabled else "OFF",
		_get_msaa_name(),
		"ON" if dof_enabled else "OFF",
		"ON" if vignette_enabled else "OFF"
	]
