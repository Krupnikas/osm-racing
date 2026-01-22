extends RefCounted
class_name GroundMaterial

## Создаёт материал земли/травы с PBR текстурами и поддержкой мокрого эффекта
## Текстуры: ambientCG Grass004 (CC0 Public Domain)

# Параметры мокрой травы ночью
const WET_NIGHT_METALLIC := 0.15
const WET_NIGHT_ROUGHNESS := 0.25
const WET_NIGHT_SPECULAR := 0.6

# Параметры мокрой травы днём
const WET_DAY_METALLIC := 0.1
const WET_DAY_ROUGHNESS := 0.3
const WET_DAY_SPECULAR := 0.5

# Параметры сухой травы
const DRY_METALLIC := 0.0
const DRY_ROUGHNESS := 0.9
const DRY_SPECULAR := 0.3

# UV масштаб для тайлинга текстуры (текстура 1.4м x 1.4м)
const UV_SCALE := Vector3(0.5, 0.5, 0.5)  # ~2 метра на тайл


static func create_ground_material(is_wet: bool = false, is_night: bool = false) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()

	# Загружаем PBR текстуры ambientCG Grass004 напрямую из файлов
	var albedo_img := Image.load_from_file("res://textures/Grass004_1K-JPG_Color.jpg")
	var normal_img := Image.load_from_file("res://textures/Grass004_1K-JPG_NormalGL.jpg")
	var ao_img := Image.load_from_file("res://textures/Grass004_1K-JPG_AmbientOcclusion.jpg")

	var albedo_tex: ImageTexture = null
	var normal_tex: ImageTexture = null
	var ao_tex: ImageTexture = null

	if albedo_img:
		albedo_tex = ImageTexture.create_from_image(albedo_img)
	if normal_img:
		normal_tex = ImageTexture.create_from_image(normal_img)
	if ao_img:
		ao_tex = ImageTexture.create_from_image(ao_img)

	# Применяем текстуры
	if albedo_tex:
		mat.albedo_texture = albedo_tex
	if normal_tex:
		mat.normal_enabled = true
		mat.normal_texture = normal_tex
		mat.normal_scale = 0.3  # Уменьшено для меньшего шума
	if ao_tex:
		mat.ao_enabled = true
		mat.ao_texture = ao_tex
		mat.ao_light_affect = 0.5

	# UV тайлинг для большой поверхности
	mat.uv1_scale = UV_SCALE
	mat.uv1_triplanar = true  # Проекция со всех сторон
	mat.uv1_triplanar_sharpness = 1.0

	# Применяем свойства в зависимости от погоды
	apply_weather_properties(mat, is_wet, is_night)

	return mat


static func apply_weather_properties(material: StandardMaterial3D, is_wet: bool, is_night: bool = false) -> void:
	if not material:
		return

	if is_wet:
		if is_night:
			material.metallic = WET_NIGHT_METALLIC
			material.roughness = WET_NIGHT_ROUGHNESS
			material.metallic_specular = WET_NIGHT_SPECULAR
		else:
			material.metallic = WET_DAY_METALLIC
			material.roughness = WET_DAY_ROUGHNESS
			material.metallic_specular = WET_DAY_SPECULAR
		# Мокрая трава немного темнее
		material.albedo_color = Color(0.85, 0.85, 0.85)
	else:
		material.metallic = DRY_METALLIC
		material.roughness = DRY_ROUGHNESS
		material.metallic_specular = DRY_SPECULAR
		material.albedo_color = Color.WHITE
