extends RefCounted
class_name WetRoadMaterial

## Утилиты для создания эффекта мокрого асфальта с шейдером
## Поддерживает noise-based roughness variation и лужи

# Shader для дорог (lazy load)
static var _road_shader: Shader = null
static var _shader_loaded := false

# Параметры мокрой дороги ночью - умеренные отражения
const WET_NIGHT_METALLIC := 0.4
const WET_NIGHT_ROUGHNESS := 0.1
const WET_NIGHT_SPECULAR := 0.8

# Параметры мокрой дороги днём - меньше отражений
const WET_DAY_METALLIC := 0.3
const WET_DAY_ROUGHNESS := 0.15
const WET_DAY_SPECULAR := 0.7

# Параметры сухой дороги
const DRY_METALLIC := 0.0
const DRY_ROUGHNESS := 0.85
const DRY_SPECULAR := 0.5


static func _load_shader() -> void:
	if _shader_loaded:
		return

	# Попытка загрузить шейдер
	if ResourceLoader.exists("res://shaders/wet_road.gdshader"):
		_road_shader = load("res://shaders/wet_road.gdshader")
		print("WetRoadMaterial: Loaded wet_road.gdshader")
	else:
		print("WetRoadMaterial: wet_road.gdshader not found, using StandardMaterial3D fallback")

	_shader_loaded = true


static func has_shader() -> bool:
	"""Проверяет доступен ли шейдер"""
	_load_shader()
	return _road_shader != null


static func create_road_shader_material(albedo_texture: Texture2D = null, normal_texture: Texture2D = null, is_wet: bool = false, is_night: bool = false, noise_micro: Texture2D = null, noise_macro: Texture2D = null, roughness_texture: Texture2D = null, marking_texture: Texture2D = null) -> Material:
	"""Создаёт ShaderMaterial для дороги с поддержкой wet mode и noise variation"""
	_load_shader()

	if _road_shader == null:
		# Fallback на StandardMaterial3D
		return _create_standard_material(albedo_texture, normal_texture, is_wet, is_night)

	var mat := ShaderMaterial.new()
	mat.shader = _road_shader

	# Текстуры
	if albedo_texture:
		mat.set_shader_parameter("albedo_texture", albedo_texture)
		mat.set_shader_parameter("use_texture", true)
	else:
		mat.set_shader_parameter("use_texture", false)
		mat.set_shader_parameter("base_color", Color(0.22, 0.22, 0.24, 1.0))

	if normal_texture:
		mat.set_shader_parameter("normal_texture", normal_texture)
		mat.set_shader_parameter("normal_strength", 0.8)

	if roughness_texture:
		mat.set_shader_parameter("roughness_texture", roughness_texture)
		mat.set_shader_parameter("use_roughness_texture", true)

	if marking_texture:
		mat.set_shader_parameter("marking_texture", marking_texture)
		mat.set_shader_parameter("use_marking", true)

	if noise_micro:
		mat.set_shader_parameter("noise_micro_tex", noise_micro)
	if noise_macro:
		mat.set_shader_parameter("noise_macro_tex", noise_macro)

	# Night state (wetness управляется глобальным параметром wetness_global)
	mat.set_shader_parameter("is_night", is_night)

	# Default параметры
	mat.set_shader_parameter("dry_roughness", DRY_ROUGHNESS)
	mat.set_shader_parameter("wet_roughness", WET_NIGHT_ROUGHNESS if is_night else WET_DAY_ROUGHNESS)
	mat.set_shader_parameter("roughness_variation", 0.1)

	mat.set_shader_parameter("puddle_threshold", 0.65)
	mat.set_shader_parameter("puddle_roughness", 0.02)
	mat.set_shader_parameter("puddle_darkness", 0.2)

	mat.set_shader_parameter("dry_metallic", DRY_METALLIC)
	mat.set_shader_parameter("wet_metallic", WET_NIGHT_METALLIC if is_night else WET_DAY_METALLIC)
	mat.set_shader_parameter("puddle_metallic", 0.5)

	return mat


static func _create_standard_material(albedo_texture: Texture2D, normal_texture: Texture2D, is_wet: bool, is_night: bool) -> StandardMaterial3D:
	"""Fallback на StandardMaterial3D если шейдер не доступен"""
	var mat := StandardMaterial3D.new()
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	if albedo_texture:
		mat.albedo_texture = albedo_texture
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	else:
		mat.albedo_color = Color(0.22, 0.22, 0.24, 1.0)

	if normal_texture:
		mat.normal_enabled = true
		mat.normal_texture = normal_texture
		mat.normal_scale = 0.3

	apply_wet_properties(mat, is_wet, is_night)
	return mat


static func apply_wet_properties(material: Material, is_wet: bool, is_night: bool = true) -> void:
	"""Применяет wet/dry состояние к материалу"""
	if not material:
		return

	if material is ShaderMaterial:
		# Shader material (wetness управляется глобальным параметром wetness_global)
		material.set_shader_parameter("is_night", is_night)

		if is_wet:
			if is_night:
				material.set_shader_parameter("wet_roughness", WET_NIGHT_ROUGHNESS)
				material.set_shader_parameter("wet_metallic", WET_NIGHT_METALLIC)
			else:
				material.set_shader_parameter("wet_roughness", WET_DAY_ROUGHNESS)
				material.set_shader_parameter("wet_metallic", WET_DAY_METALLIC)

	elif material is StandardMaterial3D:
		# Fallback для StandardMaterial3D
		if is_wet:
			if is_night:
				material.metallic = WET_NIGHT_METALLIC
				material.roughness = WET_NIGHT_ROUGHNESS
				material.metallic_specular = WET_NIGHT_SPECULAR
			else:
				material.metallic = WET_DAY_METALLIC
				material.roughness = WET_DAY_ROUGHNESS
				material.metallic_specular = WET_DAY_SPECULAR
			# Немного затемняем для мокрого эффекта
			var color: Color = material.albedo_color
			material.albedo_color = color.darkened(0.15)
		else:
			material.metallic = DRY_METALLIC
			material.roughness = DRY_ROUGHNESS
			material.metallic_specular = DRY_SPECULAR


static func create_wet_road_material(base_color: Color = Color(0.18, 0.18, 0.2), is_night: bool = true) -> StandardMaterial3D:
	"""Legacy: создаёт StandardMaterial3D для совместимости"""
	var mat := StandardMaterial3D.new()
	mat.albedo_color = base_color.darkened(0.15)
	if is_night:
		mat.metallic = WET_NIGHT_METALLIC
		mat.roughness = WET_NIGHT_ROUGHNESS
		mat.metallic_specular = WET_NIGHT_SPECULAR
	else:
		mat.metallic = WET_DAY_METALLIC
		mat.roughness = WET_DAY_ROUGHNESS
		mat.metallic_specular = WET_DAY_SPECULAR
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


static func create_dry_road_material(base_color: Color = Color(0.2, 0.2, 0.22)) -> StandardMaterial3D:
	"""Legacy: создаёт StandardMaterial3D для совместимости"""
	var mat := StandardMaterial3D.new()
	mat.albedo_color = base_color
	mat.metallic = DRY_METALLIC
	mat.roughness = DRY_ROUGHNESS
	mat.metallic_specular = DRY_SPECULAR
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


static func apply_road_type_params(mat: ShaderMaterial, road_type: String) -> void:
	match road_type:
		"intersection", "crossing":
			mat.set_shader_parameter("macro_roughness_dry", 0.05)
			mat.set_shader_parameter("macro_albedo_dry", 0.02)
			# Curb bias не нужен на перекрёстках (нет краёв)
			mat.set_shader_parameter("curb_puddle_bias", 0.0)
		"highway":
			mat.set_shader_parameter("macro_roughness_dry", 0.06)
			mat.set_shader_parameter("macro_albedo_dry", 0.02)
			mat.set_shader_parameter("micro_scale", 15.0)
		"path":
			mat.set_shader_parameter("macro_roughness_dry", 0.04)
			mat.set_shader_parameter("micro_roughness_dry", 0.03)
		_:
			pass
