extends Node
class_name NightModeManager

## Центральный менеджер ночного режима в стиле NFS Underground

signal night_mode_changed(enabled: bool)
signal rain_changed(enabled: bool)

# Состояние
var is_night := false
var is_raining := false

# Ссылки на сцену
var _environment: Environment
var _sun_light: DirectionalLight3D
var _moon_light: DirectionalLight3D
var _world_env: WorldEnvironment
var _original_sky: ProceduralSkyMaterial
var _day_sky: ShaderMaterial
var _night_sky: ShaderMaterial
var _rain_system: GPUParticles3D
var _terrain_generator: Node
var _graphics_settings: Node

# Сохранённые дневные настройки
var _day_sun_energy := 1.0
var _day_sun_color := Color(1.0, 1.0, 1.0)
var _day_ambient_color := Color(0.5, 0.5, 0.5)
var _day_ambient_energy := 1.0
var _day_fog_color := Color(0.7, 0.75, 0.85)
var _day_fog_density := 0.0008
var _day_tonemap_exposure := 1.0
var _day_glow_intensity := 0.3

# Ночные настройки в стиле NFS Underground
const NIGHT_SUN_ENERGY := 0.02  # Почти нет солнца ночью

# Лунный свет - иссиня-белый
const MOON_LIGHT_ENERGY := 0.12
const MOON_LIGHT_COLOR := Color(0.7, 0.8, 1.0)  # Иссиня-белый холодный свет
const NIGHT_AMBIENT_COLOR := Color(0.015, 0.02, 0.04)  # Очень тёмный синий
const NIGHT_AMBIENT_ENERGY := 0.15
# NFS Underground стиль - туман с оттенком городских огней (оранжево-синий)
const NIGHT_FOG_COLOR := Color(0.08, 0.04, 0.12)  # Тёмно-фиолетовый с оттенком города
const NIGHT_FOG_DENSITY := 0.003  # Более плотный туман для атмосферы

# Transition
var _transition_tween: Tween


func _ready() -> void:
	# Ищем компоненты сцены
	await get_tree().process_frame
	_find_scene_components()

	# Создаём дневное небо с облаками
	_create_day_sky()

	# Создаём ночное небо
	_create_night_sky()

	# Создаём лунный свет
	_create_moon_light()

	# Создаём систему дождя
	_create_rain_system()

	# Устанавливаем дневное небо по умолчанию
	_switch_to_day_sky()

	# По умолчанию: день без дождя
	print("NightModeManager: Ready (day mode, no rain)")


func _find_scene_components() -> void:
	# Ищем WorldEnvironment
	_world_env = get_tree().current_scene.find_child("WorldEnvironment", true, false) as WorldEnvironment
	if _world_env:
		_environment = _world_env.environment
		if _environment:
			if _environment.sky:
				_original_sky = _environment.sky.sky_material as ProceduralSkyMaterial
			# Сохраняем дневные настройки
			_day_fog_color = _environment.fog_light_color
			_day_fog_density = _environment.fog_density
			_day_tonemap_exposure = _environment.tonemap_exposure
			_day_glow_intensity = _environment.glow_intensity

	# Ищем DirectionalLight3D (солнце)
	_sun_light = get_tree().current_scene.find_child("DirectionalLight3D", true, false) as DirectionalLight3D
	if _sun_light:
		_day_sun_energy = _sun_light.light_energy
		_day_sun_color = _sun_light.light_color

	# Ищем terrain generator
	_terrain_generator = get_tree().current_scene.find_child("OSMTerrain", true, false)

	# Ищем настройки графики
	_graphics_settings = get_tree().current_scene.find_child("GraphicsSettings", true, false)


func _create_day_sky() -> void:
	_day_sky = ShaderMaterial.new()

	var shader := Shader.new()
	# Более насыщенное дневное небо
	shader.code = """
shader_type sky;

// Более насыщенные цвета неба
uniform vec3 sky_top_color : source_color = vec3(0.25, 0.45, 0.95);  // Ярче синий
uniform vec3 sky_horizon_color : source_color = vec3(0.55, 0.7, 0.95);  // Насыщенный горизонт
uniform vec3 ground_color : source_color = vec3(0.35, 0.4, 0.35);

uniform vec3 sun_direction = vec3(-0.5, 0.7, 0.3);
uniform float sun_size : hint_range(0.01, 0.2) = 0.045;
uniform vec3 sun_color : source_color = vec3(1.0, 0.95, 0.85);

uniform float cloud_coverage : hint_range(0.0, 1.0) = 0.35;
uniform float cloud_speed : hint_range(0.0, 0.1) = 0.008;
uniform vec3 cloud_color : source_color = vec3(1.0, 1.0, 1.0);
uniform vec3 cloud_shadow_color : source_color = vec3(0.65, 0.7, 0.8);

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
	float value = 0.0;
	float amplitude = 0.5;
	float frequency = 1.0;
	for (int i = 0; i < 5; i++) {
		value += amplitude * noise(p * frequency);
		amplitude *= 0.5;
		frequency *= 2.0;
	}
	return value;
}

float clouds(vec2 uv, float time) {
	vec2 cloud_uv = uv * 3.0 + vec2(time * cloud_speed, 0.0);
	float cloud_noise = fbm(cloud_uv);
	cloud_noise += 0.5 * fbm(cloud_uv * 2.0 + vec2(time * cloud_speed * 0.5, 0.0));
	return smoothstep(1.0 - cloud_coverage, 1.0 - cloud_coverage + 0.3, cloud_noise);
}

void sky() {
	vec3 dir = normalize(EYEDIR);

	float horizon = smoothstep(-0.1, 0.6, dir.y);
	vec3 sky = mix(sky_horizon_color, sky_top_color, horizon);

	if (dir.y < 0.0) {
		float ground_blend = smoothstep(0.0, -0.3, dir.y);
		sky = mix(sky_horizon_color, ground_color, ground_blend);
	}

	vec3 sun_dir = normalize(sun_direction);
	float sun_dist = distance(dir, sun_dir);
	float sun = smoothstep(sun_size, sun_size * 0.6, sun_dist);
	float sun_glow = smoothstep(sun_size * 10.0, sun_size, sun_dist) * 0.35;
	sky += sun_color * sun * 2.5;
	sky += sun_color * sun_glow;

	if (dir.y > 0.05) {
		vec2 cloud_uv = dir.xz / (dir.y + 0.1);
		float cloud = clouds(cloud_uv, TIME);
		float cloud_sun = dot(normalize(vec3(cloud_uv.x, 1.0, cloud_uv.y)), sun_dir);
		vec3 lit_cloud = mix(cloud_shadow_color, cloud_color, smoothstep(-0.2, 0.5, cloud_sun));
		float cloud_fade = smoothstep(0.05, 0.3, dir.y);
		sky = mix(sky, lit_cloud, cloud * cloud_fade * 0.85);
	}

	// Атмосферное рассеивание - более тёплое
	float scatter = pow(1.0 - abs(dir.y), 4.0) * 0.2;
	sky += vec3(0.9, 0.7, 0.5) * scatter;

	COLOR = sky;
}
"""
	_day_sky.shader = shader


func _create_moon_light() -> void:
	# Создаём отдельный направленный свет для луны
	_moon_light = DirectionalLight3D.new()
	_moon_light.name = "MoonLight"
	_moon_light.light_color = MOON_LIGHT_COLOR
	_moon_light.light_energy = 0.0  # Выключен днём
	_moon_light.shadow_enabled = true
	_moon_light.directional_shadow_max_distance = 300.0

	# Луна светит под другим углом, чем солнце (противоположная сторона)
	# Направление совпадает с moon_direction в шейдере: vec3(-0.3, 0.6, 0.4)
	_moon_light.rotation_degrees = Vector3(-35, 145, 0)

	get_tree().current_scene.add_child(_moon_light)


func _create_night_sky() -> void:
	_night_sky = ShaderMaterial.new()

	var shader := Shader.new()
	# NFS Underground style night sky - яркое свечение города, насыщенные цвета
	shader.code = """
shader_type sky;

uniform vec3 moon_direction = vec3(-0.3, 0.6, 0.4);
uniform float moon_size = 0.08;  // Больше луна
uniform float star_density = 0.0015;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void sky() {
	vec3 dir = normalize(EYEDIR);

	// NFS Underground style - глубокий тёмно-синий с фиолетовым оттенком
	float horizon = smoothstep(-0.15, 0.5, dir.y);
	vec3 sky_top = vec3(0.01, 0.015, 0.04);  // Почти чёрный с синевой
	vec3 sky_horizon = vec3(0.04, 0.02, 0.08);  // Фиолетовый горизонт
	vec3 col = mix(sky_horizon, sky_top, horizon);

	// Stars - меньше и ярче
	if (dir.y > 0.05) {
		vec2 star_uv = dir.xz / (dir.y + 0.001) * 100.0;
		float star = step(1.0 - star_density, hash(floor(star_uv)));
		float brightness = hash(floor(star_uv) + vec2(0.5, 0.5));
		float twinkle = 0.7 + 0.3 * sin(TIME * (3.0 + brightness * 4.0) + brightness * 100.0);
		col += vec3(0.9, 0.95, 1.0) * star * twinkle * brightness;
	}

	// Moon - иссиня-белый с ярким ореолом
	vec3 moon_dir = normalize(moon_direction);
	float moon_dist = distance(dir, moon_dir);
	float moon = smoothstep(moon_size, moon_size * 0.5, moon_dist);
	float moon_glow = smoothstep(moon_size * 8.0, moon_size, moon_dist) * 0.5;
	// Иссиня-белый цвет луны
	col += vec3(0.85, 0.9, 1.0) * moon * 1.5;
	// Синеватый ореол вокруг луны
	col += vec3(0.3, 0.4, 0.7) * moon_glow;

	// NFS Underground стиль - СИЛЬНОЕ свечение города на горизонте
	// Оранжево-жёлтое от натриевых фонарей
	float city_glow_orange = smoothstep(0.15, -0.1, dir.y);
	col += vec3(0.25, 0.12, 0.02) * city_glow_orange * 0.8;

	// Дополнительное розово-фиолетовое свечение (неон)
	float neon_glow = smoothstep(0.1, -0.15, dir.y);
	col += vec3(0.15, 0.05, 0.2) * neon_glow * 0.5;

	// Синее свечение от рекламы
	float blue_glow = smoothstep(0.08, -0.08, dir.y) * (0.5 + 0.5 * sin(dir.x * 10.0));
	col += vec3(0.02, 0.08, 0.15) * blue_glow * 0.3;

	COLOR = col;
}
"""
	_night_sky.shader = shader


func _create_rain_system() -> void:
	_rain_system = GPUParticles3D.new()
	_rain_system.name = "RainSystem"
	_rain_system.amount = 4000  # Оптимизация: снижено с 8000 для производительности
	_rain_system.lifetime = 1.5
	_rain_system.one_shot = false
	_rain_system.explosiveness = 0.0
	_rain_system.randomness = 1.0
	_rain_system.visibility_aabb = AABB(Vector3(-40, -20, -40), Vector3(80, 40, 80))  # Оптимизация: уменьшена область
	_rain_system.emitting = false

	# Материал частиц
	var process_mat := ParticleProcessMaterial.new()
	process_mat.direction = Vector3(0.1, -1, 0.05)  # Slight angle for wind
	process_mat.spread = 3.0
	process_mat.initial_velocity_min = 35.0
	process_mat.initial_velocity_max = 45.0
	process_mat.gravity = Vector3(0, -15, 0)
	process_mat.damping_min = 0.0
	process_mat.damping_max = 0.0

	# Emission shape - box above camera
	process_mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process_mat.emission_box_extents = Vector3(50, 5, 50)

	# Scale
	process_mat.scale_min = 0.8
	process_mat.scale_max = 1.2

	_rain_system.process_material = process_mat

	# Mesh для капель - тонкий цилиндр
	var drop_mesh := CylinderMesh.new()
	drop_mesh.top_radius = 0.008
	drop_mesh.bottom_radius = 0.008
	drop_mesh.height = 0.4
	_rain_system.draw_pass_1 = drop_mesh

	# Материал капель
	var drop_mat := StandardMaterial3D.new()
	drop_mat.albedo_color = Color(0.7, 0.8, 1.0, 0.25)
	drop_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	drop_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	drop_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_rain_system.material_override = drop_mat

	add_child(_rain_system)


func _process(_delta: float) -> void:
	# Rain follows camera
	if _rain_system and _rain_system.emitting:
		var camera := get_viewport().get_camera_3d()
		if camera:
			_rain_system.global_position = camera.global_position + Vector3(0, 25, 0)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_N:
				toggle_night_mode()
			KEY_R:
				toggle_rain()


func toggle_night_mode() -> void:
	if is_night:
		disable_night_mode()
	else:
		enable_night_mode()


func enable_night_mode() -> void:
	if is_night:
		return

	is_night = true

	# Переключаем небо СРАЗУ
	_switch_to_night_sky()

	# Обновляем отражения на дорогах (больше ночью)
	if is_raining and _terrain_generator and _terrain_generator.has_method("set_wet_mode"):
		_terrain_generator.set_wet_mode(true, true)  # wet=true, night=true

	# Cancel existing tween
	if _transition_tween:
		_transition_tween.kill()

	_transition_tween = create_tween()
	_transition_tween.set_parallel(true)

	# Dim sun
	if _sun_light:
		_transition_tween.tween_property(_sun_light, "light_energy", NIGHT_SUN_ENERGY, 1.5)

	# Turn on moon light
	if _moon_light:
		_transition_tween.tween_property(_moon_light, "light_energy", MOON_LIGHT_ENERGY, 1.5)

	# Change ambient and fog - NFS Underground style
	if _environment:
		_transition_tween.tween_property(_environment, "ambient_light_color", NIGHT_AMBIENT_COLOR, 1.5)
		_transition_tween.tween_property(_environment, "ambient_light_energy", NIGHT_AMBIENT_ENERGY, 1.5)
		_transition_tween.tween_property(_environment, "fog_light_color", NIGHT_FOG_COLOR, 1.5)
		_transition_tween.tween_property(_environment, "fog_density", NIGHT_FOG_DENSITY, 1.5)

		# NFS Underground style bloom - сильный, с низким порогом
		_environment.glow_enabled = true
		_environment.glow_intensity = 1.8  # Сильнее
		_environment.glow_bloom = 0.4
		_environment.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
		_environment.glow_hdr_threshold = 0.5  # Ниже порог - больше свечения
		_environment.glow_hdr_scale = 2.0

		# Tonemap для контраста
		_environment.tonemap_mode = Environment.TONE_MAPPER_ACES
		_environment.tonemap_exposure = 1.1
		_environment.tonemap_white = 6.0

	night_mode_changed.emit(true)
	print("Night mode enabled")


func disable_night_mode() -> void:
	if not is_night:
		return

	is_night = false

	# Переключаем небо обратно
	_switch_to_day_sky()

	# Обновляем отражения на дорогах (меньше днём)
	if is_raining and _terrain_generator and _terrain_generator.has_method("set_wet_mode"):
		_terrain_generator.set_wet_mode(true, false)  # wet=true, night=false

	# Cancel existing tween
	if _transition_tween:
		_transition_tween.kill()

	_transition_tween = create_tween()
	_transition_tween.set_parallel(true)

	# Restore sun
	if _sun_light:
		_transition_tween.tween_property(_sun_light, "light_energy", _day_sun_energy, 1.5)
		_transition_tween.tween_property(_sun_light, "light_color", _day_sun_color, 1.5)

	# Turn off moon light
	if _moon_light:
		_transition_tween.tween_property(_moon_light, "light_energy", 0.0, 1.5)

	# Restore ambient and fog
	if _environment:
		_transition_tween.tween_property(_environment, "ambient_light_color", _day_ambient_color, 1.5)
		_transition_tween.tween_property(_environment, "ambient_light_energy", _day_ambient_energy, 1.5)
		_transition_tween.tween_property(_environment, "fog_light_color", _day_fog_color, 1.5)
		_transition_tween.tween_property(_environment, "fog_density", _day_fog_density, 1.5)

		# Restore day glow settings
		_environment.glow_intensity = _day_glow_intensity
		_environment.glow_bloom = 0.1
		_environment.glow_hdr_threshold = 1.0
		_environment.glow_hdr_scale = 1.0

		# Restore tonemap
		_environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
		_environment.tonemap_exposure = _day_tonemap_exposure
		_environment.tonemap_white = 1.0

	night_mode_changed.emit(false)
	print("Night mode disabled")


func _switch_to_night_sky() -> void:
	if _environment and _environment.sky:
		_environment.sky.sky_material = _night_sky


func _switch_to_day_sky() -> void:
	if not _environment or not _environment.sky:
		return
	# Проверяем настройку облаков
	var use_clouds := true
	if _graphics_settings:
		use_clouds = _graphics_settings.clouds_enabled
	if use_clouds and _day_sky:
		_environment.sky.sky_material = _day_sky
	elif _original_sky:
		_environment.sky.sky_material = _original_sky


func toggle_rain() -> void:
	is_raining = not is_raining
	_rain_system.emitting = is_raining

	# Update road wetness - меньше отражений днём
	if _terrain_generator and _terrain_generator.has_method("set_wet_mode"):
		_terrain_generator.set_wet_mode(is_raining, is_night)

	rain_changed.emit(is_raining)
	print("Rain: ", "enabled" if is_raining else "disabled")


func set_rain(enabled: bool) -> void:
	if enabled != is_raining:
		toggle_rain()
