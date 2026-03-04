extends Node
class_name GraphicsSettings

## Настройки графики с возможностью включения/отключения эффектов

signal settings_changed

# Настройки по умолчанию
var ssr_enabled := true
var fog_enabled := true
var glow_enabled := true
var ssao_enabled := true
var sdfgi_enabled := false  # SDFGI выключен по умолчанию (стоит ~12ms на M1 Pro)
var normal_maps_enabled := true
var clouds_enabled := true

# Antialiasing - MSAA 2X + TAA для баланса качества и чёткости
var msaa_mode := Viewport.MSAA_2X  # MSAA 2X
var taa_enabled := true  # TAA включен
var fxaa_enabled := false  # FXAA выключен
var taa_jitter_amount := 0.5  # Сила TAA (0.0-1.0): меньше = четче но больше шума, больше = размытие

# Дополнительные эффекты
var motion_blur_enabled := false
var dof_enabled := false  # Размытие от расстояния
var chromatic_aberration_enabled := false
var vignette_enabled := false  # Виньетка (по умолчанию выключена)

# Упрощённые деревья (процедурные вместо GLTF модели)
var simplified_trees := false

# Разрешение HDRI неба: 0=1K, 1=2K, 2=4K, 3=8K
var sky_resolution := 1  # Default 2K

# Дальность прорисовки
var render_distance := 400.0  # Метры

# Громкость (0-100)
var music_volume := 80.0
var sfx_volume := 80.0

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
	print("GraphicsSettings: Applying initial settings...")
	_apply_all()
	print("GraphicsSettings: Ready")
	# Автосохранение при изменении настроек
	settings_changed.connect(_on_settings_changed)
	# Подписываемся на смену камеры — нужно переприменить far/DOF к новой камере
	var cam_mgr := get_tree().current_scene.find_child("CameraManager", true, false)
	if cam_mgr and cam_mgr.has_signal("camera_changed"):
		cam_mgr.camera_changed.connect(_on_camera_changed)


func _on_camera_changed(_index: int, _name: String) -> void:
	# Камера сменилась — переприменяем настройки к новой камере
	_find_camera()
	if _camera:
		_apply_render_distance()
		_apply_dof()


func _on_settings_changed() -> void:
	save_settings()


func _find_environment() -> void:
	_world_env = get_tree().current_scene.find_child("WorldEnvironment", true, false) as WorldEnvironment
	if _world_env:
		_environment = _world_env.environment
		print("GraphicsSettings: Found WorldEnvironment")
	else:
		print("GraphicsSettings: ERROR - WorldEnvironment not found!")


func _find_camera() -> void:
	# Всегда получаем текущую активную камеру (может смениться через CameraManager)
	var viewport := get_viewport()
	if viewport:
		_camera = viewport.get_camera_3d()
	if not _camera:
		print("GraphicsSettings: WARNING - Camera3D not found")


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
			KEY_F10:
				toggle_fxaa()


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


func toggle_sdfgi() -> void:
	sdfgi_enabled = not sdfgi_enabled
	_apply_sdfgi()
	print("SDFGI: ", "ON" if sdfgi_enabled else "OFF")
	settings_changed.emit()


func toggle_normal_maps() -> void:
	normal_maps_enabled = not normal_maps_enabled
	print("Normal Maps: ", "ON" if normal_maps_enabled else "OFF")
	print("WARNING: Normal Maps change requires terrain reload to take effect")
	# Normal maps применяются при создании материалов - нужна перезагрузка чанков
	settings_changed.emit()


func set_sky_resolution(value: int) -> void:
	sky_resolution = clampi(value, 0, 3)
	print("Sky Resolution: ", ["1K", "2K", "4K", "8K"][sky_resolution])
	var night_mgr := get_tree().current_scene.find_child("NightModeManager", true, false)
	if night_mgr and night_mgr.has_method("reload_sky_textures"):
		night_mgr.reload_sky_textures()
	settings_changed.emit()


func set_render_distance(distance: float) -> void:
	render_distance = clampf(distance, 100.0, 1000.0)
	_apply_render_distance()
	print("Render distance: %.0f m" % render_distance)
	settings_changed.emit()


func _apply_render_distance() -> void:
	# Настраиваем камеру (обновляем ссылку — камера могла смениться)
	_find_camera()
	if _camera:
		_camera.far = render_distance * 1.5

	# Настраиваем туман (Godot 4 экспоненциальный)
	if _environment and fog_enabled:
		_environment.fog_density = 0.8 / render_distance
		_environment.fog_aerial_perspective = 0.5

	# Обновляем terrain generator (включая дистанции чанков)
	var terrain := get_tree().current_scene.find_child("OSMTerrainGenerator", true, false)
	if terrain:
		terrain.render_distance = render_distance
		if terrain.has_method("_setup_render_distance"):
			terrain._setup_render_distance()
		else:
			print("WARNING: Terrain does not have _setup_render_distance() method")


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


func toggle_fxaa() -> void:
	fxaa_enabled = not fxaa_enabled
	_apply_fxaa()
	print("FXAA: ", "ON" if fxaa_enabled else "OFF")
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


func set_simplified_trees(value: bool) -> void:
	simplified_trees = value
	print("Simplified trees: ", "ON" if simplified_trees else "OFF")
	print("NOTE: Tree style change requires terrain reload to take effect")
	settings_changed.emit()


func _apply_ssr() -> void:
	if _environment:
		_environment.ssr_enabled = ssr_enabled
		print("SSR: ", "ON" if ssr_enabled else "OFF")
	else:
		print("ERROR: Cannot apply SSR - no environment!")


func _apply_fog() -> void:
	if _environment:
		_environment.fog_enabled = fog_enabled
		print("Fog: ", "ON" if fog_enabled else "OFF")
	else:
		print("ERROR: Cannot apply Fog - no environment!")


func _apply_glow() -> void:
	if _environment:
		_environment.glow_enabled = glow_enabled
		print("Glow: ", "ON" if glow_enabled else "OFF")
	else:
		print("ERROR: Cannot apply Glow - no environment!")


func _apply_ssao() -> void:
	if _environment:
		_environment.ssao_enabled = ssao_enabled
		print("SSAO: ", "ON" if ssao_enabled else "OFF")
	else:
		print("ERROR: Cannot apply SSAO - no environment!")


func _apply_sdfgi() -> void:
	if _environment:
		_environment.sdfgi_enabled = sdfgi_enabled
		print("SDFGI: ", "ON" if sdfgi_enabled else "OFF")
	else:
		print("ERROR: Cannot apply SDFGI - no environment!")


func _apply_taa() -> void:
	var viewport := get_tree().root
	if viewport:
		viewport.use_taa = taa_enabled
		print("TAA: ", "ON" if taa_enabled else "OFF")
		# Рекомендация: TAA + MSAA 2X = хорошее сглаживание без сильного размытия


func _apply_msaa() -> void:
	var viewport := get_tree().root
	if viewport:
		viewport.msaa_3d = msaa_mode
		print("MSAA: ", _get_msaa_name())


func _apply_fxaa() -> void:
	var viewport := get_tree().root
	if viewport:
		if fxaa_enabled:
			viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
			print("FXAA enabled on root viewport")
		else:
			viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
			print("FXAA disabled on root viewport")


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
	# DOF через CameraAttributes (обновляем ссылку — камера могла смениться)
	_find_camera()

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
				print("DOF: ON (far distance: 100m)")
			else:
				attrs.dof_blur_far_enabled = false
				print("DOF: OFF")
	else:
		print("ERROR: Cannot apply DOF - no camera!")


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
	sdfgi_enabled = false
	normal_maps_enabled = false
	clouds_enabled = false
	msaa_mode = Viewport.MSAA_DISABLED
	taa_enabled = false
	motion_blur_enabled = false
	dof_enabled = false
	vignette_enabled = false
	simplified_trees = true
	sky_resolution = 0  # 1K
	_apply_all()
	print("Graphics: LOW")
	settings_changed.emit()


func set_quality_medium() -> void:
	ssr_enabled = false
	fog_enabled = true
	glow_enabled = true
	ssao_enabled = true
	sdfgi_enabled = false
	normal_maps_enabled = true
	clouds_enabled = true
	msaa_mode = Viewport.MSAA_DISABLED
	taa_enabled = true
	motion_blur_enabled = false
	dof_enabled = false
	vignette_enabled = false
	simplified_trees = false
	sky_resolution = 1  # 2K
	_apply_all()
	print("Graphics: MEDIUM")
	settings_changed.emit()


func set_quality_high() -> void:
	ssr_enabled = true
	fog_enabled = true
	glow_enabled = true
	ssao_enabled = true
	sdfgi_enabled = true
	normal_maps_enabled = true
	clouds_enabled = true
	msaa_mode = Viewport.MSAA_2X
	taa_enabled = true
	motion_blur_enabled = false
	dof_enabled = false
	vignette_enabled = false
	simplified_trees = false
	sky_resolution = 2  # 4K
	_apply_all()
	print("Graphics: HIGH")
	settings_changed.emit()


func _apply_all() -> void:
	_apply_ssr()
	_apply_fog()
	_apply_glow()
	_apply_ssao()
	_apply_sdfgi()
	_apply_taa()
	_apply_msaa()
	_apply_fxaa()
	_apply_dof()
	_apply_vignette()
	_apply_render_distance()
	_apply_audio()


func _apply_audio() -> void:
	var music_idx := AudioServer.get_bus_index("Music")
	if music_idx >= 0:
		AudioServer.set_bus_volume_db(music_idx, linear_to_db(music_volume / 100.0))
	var sfx_idx := AudioServer.get_bus_index("SFX")
	if sfx_idx >= 0:
		AudioServer.set_bus_volume_db(sfx_idx, linear_to_db(sfx_volume / 100.0))


func _load_settings() -> void:
	var config := ConfigFile.new()
	var err := config.load("user://graphics.cfg")
	if err == OK:
		print("GraphicsSettings: Loading settings from file...")
		ssr_enabled = config.get_value("graphics", "ssr", true)
		fog_enabled = config.get_value("graphics", "fog", true)
		glow_enabled = config.get_value("graphics", "glow", true)
		ssao_enabled = config.get_value("graphics", "ssao", true)
		sdfgi_enabled = config.get_value("graphics", "sdfgi", false)
		normal_maps_enabled = config.get_value("graphics", "normal_maps", true)
		clouds_enabled = config.get_value("graphics", "clouds", true)
		msaa_mode = config.get_value("graphics", "msaa", Viewport.MSAA_4X)
		taa_enabled = config.get_value("graphics", "taa", false)
		fxaa_enabled = config.get_value("graphics", "fxaa", true)
		motion_blur_enabled = config.get_value("graphics", "motion_blur", false)
		dof_enabled = config.get_value("graphics", "dof", false)
		vignette_enabled = config.get_value("graphics", "vignette", false)  # Дефолт false как при инициализации
		simplified_trees = config.get_value("graphics", "simplified_trees", false)
		sky_resolution = config.get_value("graphics", "sky_resolution", 1)
		render_distance = config.get_value("graphics", "render_distance", 400.0)
		music_volume = config.get_value("audio", "music_volume", 80.0)
		sfx_volume = config.get_value("audio", "sfx_volume", 80.0)
		print("GraphicsSettings: Settings loaded - FXAA: ", fxaa_enabled, ", TAA: ", taa_enabled, ", MSAA: ", msaa_mode)
	else:
		print("GraphicsSettings: No saved settings found (err: ", err, "), using defaults")
		# Сохраняем дефолтные настройки в файл
		save_settings()


func save_settings() -> void:
	var config := ConfigFile.new()
	config.set_value("graphics", "ssr", ssr_enabled)
	config.set_value("graphics", "fog", fog_enabled)
	config.set_value("graphics", "glow", glow_enabled)
	config.set_value("graphics", "ssao", ssao_enabled)
	config.set_value("graphics", "sdfgi", sdfgi_enabled)
	config.set_value("graphics", "normal_maps", normal_maps_enabled)
	config.set_value("graphics", "clouds", clouds_enabled)
	config.set_value("graphics", "msaa", msaa_mode)
	config.set_value("graphics", "taa", taa_enabled)
	config.set_value("graphics", "fxaa", fxaa_enabled)
	config.set_value("graphics", "motion_blur", motion_blur_enabled)
	config.set_value("graphics", "dof", dof_enabled)
	config.set_value("graphics", "vignette", vignette_enabled)
	config.set_value("graphics", "simplified_trees", simplified_trees)
	config.set_value("graphics", "sky_resolution", sky_resolution)
	config.set_value("graphics", "render_distance", render_distance)
	config.set_value("audio", "music_volume", music_volume)
	config.set_value("audio", "sfx_volume", sfx_volume)
	var err := config.save("user://graphics.cfg")
	if err == OK:
		print("GraphicsSettings: Settings saved successfully")
	else:
		print("GraphicsSettings: ERROR - Failed to save settings: ", err)


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
  F10 - FXAA: %s

  TAA: %s | MSAA: %s
  DOF: %s | Vignette: %s""" % [
		"ON" if ssr_enabled else "OFF",
		"ON" if fog_enabled else "OFF",
		"ON" if glow_enabled else "OFF",
		"ON" if ssao_enabled else "OFF",
		"ON" if normal_maps_enabled else "OFF",
		"ON" if clouds_enabled else "OFF",
		"ON" if fxaa_enabled else "OFF",
		"ON" if taa_enabled else "OFF",
		_get_msaa_name(),
		"ON" if dof_enabled else "OFF",
		"ON" if vignette_enabled else "OFF"
	]
