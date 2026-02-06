extends CanvasLayer

## Color Grading система для NFS Underground стиля
## Добавляет post-processing эффект поверх всей сцены
## Использует hint_screen_texture для чтения экрана

var _color_rect: ColorRect
var _material: ShaderMaterial
var _shader: Shader

# Настройки
var enabled := true
var intensity := 0.0  # 0 = выключено, 1 = полный эффект
var nfs_style_intensity := 0.7  # NFS Underground стиль
var contrast := 1.05
var saturation := 1.1
var brightness := 0.0

# Для плавного перехода
var _target_intensity := 0.0
var _transition_speed := 2.0

signal color_grading_changed(enabled: bool)


func _ready() -> void:
	# Этот слой должен рендериться поверх всего
	layer = 100

	# Загружаем шейдер
	if ResourceLoader.exists("res://shaders/color_grading.gdshader"):
		_shader = load("res://shaders/color_grading.gdshader")
	else:
		push_error("ColorGrading: Shader not found!")
		return

	# Создаём ColorRect на весь экран
	_color_rect = ColorRect.new()
	_color_rect.name = "ColorGradingRect"
	_color_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_color_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Создаём материал
	_material = ShaderMaterial.new()
	_material.shader = _shader
	_color_rect.material = _material

	# Устанавливаем начальные параметры
	_update_shader_params()

	add_child(_color_rect)

	# Подключаемся к NightModeManager для автоматического включения ночью
	await get_tree().process_frame
	_connect_to_night_mode()

	print("ColorGrading: Initialized (NFS Underground style ready, press L to toggle)")


func _process(delta: float) -> void:
	# Плавный переход интенсивности
	if abs(intensity - _target_intensity) > 0.01:
		intensity = lerp(intensity, _target_intensity, delta * _transition_speed)
		_material.set_shader_parameter("intensity", intensity)
		_material.set_shader_parameter("nfs_style_intensity", nfs_style_intensity * intensity)


func _connect_to_night_mode() -> void:
	var night_manager := get_tree().current_scene.find_child("NightModeManager", true, false)
	if night_manager:
		night_manager.night_mode_changed.connect(_on_night_mode_changed)
		# Если уже ночь - включаем
		if night_manager.is_night:
			_on_night_mode_changed(true)


func _on_night_mode_changed(is_night: bool) -> void:
	# Автоматически включаем/выключаем color grading с ночным режимом
	if is_night:
		enable_color_grading(0.8)  # 80% интенсивность ночью
	else:
		disable_color_grading()


func enable_color_grading(target_intensity: float = 1.0) -> void:
	"""Включает color grading с плавным переходом"""
	enabled = true
	_target_intensity = clamp(target_intensity, 0.0, 1.0)
	_material.set_shader_parameter("enabled", true)
	color_grading_changed.emit(true)
	print("ColorGrading: Enabled (target intensity: %.1f)" % _target_intensity)


func disable_color_grading() -> void:
	"""Выключает color grading с плавным переходом"""
	_target_intensity = 0.0
	# enabled остаётся true пока intensity > 0
	color_grading_changed.emit(false)
	print("ColorGrading: Disabled")


func toggle_color_grading() -> void:
	"""Переключает color grading"""
	if _target_intensity > 0.1:
		disable_color_grading()
	else:
		enable_color_grading(0.8)


func set_nfs_style(value: float) -> void:
	"""Устанавливает интенсивность NFS Underground стиля (0-1)"""
	nfs_style_intensity = clamp(value, 0.0, 1.0)
	_material.set_shader_parameter("nfs_style_intensity", nfs_style_intensity * intensity)


func set_contrast(value: float) -> void:
	"""Устанавливает контраст (0.5-2.0)"""
	contrast = clamp(value, 0.5, 2.0)
	_material.set_shader_parameter("contrast", contrast)


func set_saturation(value: float) -> void:
	"""Устанавливает насыщенность (0-2)"""
	saturation = clamp(value, 0.0, 2.0)
	_material.set_shader_parameter("saturation", saturation)


func set_brightness(value: float) -> void:
	"""Устанавливает яркость (-0.5 до 0.5)"""
	brightness = clamp(value, -0.5, 0.5)
	_material.set_shader_parameter("brightness", brightness)


func _update_shader_params() -> void:
	"""Обновляет все параметры шейдера"""
	if not _material:
		return

	_material.set_shader_parameter("enabled", enabled)
	_material.set_shader_parameter("intensity", intensity)
	_material.set_shader_parameter("nfs_style_intensity", nfs_style_intensity * intensity)
	_material.set_shader_parameter("contrast", contrast)
	_material.set_shader_parameter("saturation", saturation)
	_material.set_shader_parameter("brightness", brightness)


func _input(event: InputEvent) -> void:
	# L - toggle color grading
	if event is InputEventKey and event.pressed and event.keycode == KEY_L:
		toggle_color_grading()
