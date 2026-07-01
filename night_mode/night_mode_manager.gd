extends Node
class_name NightModeManager

## Центральный менеджер ночного режима в стиле NFS Underground
## День — HDRI панорамы (ясно/дождь), Ночь — процедурные шейдеры (оригинал)

signal night_mode_changed(enabled: bool)
signal rain_changed(enabled: bool)

# Настройки
@export var start_night := false  ## Включить ночной режим при старте

# Состояние
var is_night := false
var is_raining := false

# Ссылки на сцену
var _environment: Environment
var _sun_light: DirectionalLight3D
var _moon_light: DirectionalLight3D
var _world_env: WorldEnvironment
var _original_sky: ProceduralSkyMaterial
var _night_sky: ShaderMaterial
var _rain_system: GPUParticles3D
var _terrain_generator: Node
var _graphics_settings: Node
var _car: Node  # VehicleBody3D — для скорости дождя

# HDRI дневное небо
var _day_hdri_material: ShaderMaterial

# Data-driven горизонт-силуэт (дневное небо): профиль застроенности по азимуту.
const HORIZON_SECTORS := 128
const HORIZON_UPDATE_DIST := 40.0
var _horizon_last_pos := Vector3(1e9, 0.0, 1e9)
var _horizon_timer := 0.0
var _horizon_img: Image
var _horizon_tex: ImageTexture
var _day_clear_tex: Texture2D
var _day_rain_tex: Texture2D

# Пути к HDRI файлам (без суффикса разрешения)
const DAY_CLEAR_BASE := "res://textures/sky/day_clear_"
const DAY_RAIN_BASE := "res://textures/sky/day_rain_"
const SKY_RESOLUTION_SUFFIXES := { 0: "1k", 1: "2k", 2: "4k", 3: "8k" }

# Сохранённые дневные настройки
var _day_sun_energy := 1.0
var _day_sun_color := Color(1.0, 1.0, 1.0)
var _day_ambient_color := Color(0.5, 0.5, 0.5)
var _day_ambient_energy := 1.0
var _day_fog_color := Color(0.7, 0.75, 0.85)
var _day_fog_density := 0.0008
var _day_bg_energy := 1.0  # background_energy_multiplier
var _day_tonemap_exposure := 1.0
var _day_tonemap_white := 5.0
var _day_tonemap_mode := Environment.TONE_MAPPER_FILMIC
var _day_glow_intensity := 0.15
var _day_glow_bloom := 0.05
var _day_glow_blend_mode := Environment.GLOW_BLEND_MODE_SOFTLIGHT
var _day_glow_hdr_threshold := 1.2
var _day_glow_hdr_scale := 1.0
var _day_vfog_density := 0.005
var _day_vfog_albedo := Color(1, 1, 1)
var _day_vfog_emission := Color(0, 0, 0)
var _day_vfog_emission_energy := 0.0
var _day_vfog_ambient_inject := 0.0
var _day_vfog_gi_inject := 0.0
var _day_vfog_detail_spread := 0.8
var _day_vfog_length := 200.0
var _day_vfog_enabled := false  # Днём объёмный туман выключен (молочная пелена убрана)
var _day_saturation := 1.0  # adjustment_saturation ясного дня (для возврата после дождя)

# Ночные настройки в стиле NFS Underground
const NIGHT_SUN_ENERGY := 0.02
const MOON_LIGHT_ENERGY := 0.2
const MOON_LIGHT_COLOR := Color(0.7, 0.8, 1.0)
const NIGHT_AMBIENT_COLOR := Color(0.03, 0.04, 0.08)
const NIGHT_AMBIENT_ENERGY := 0.25
const NIGHT_FOG_COLOR := Color(0.05, 0.06, 0.10)  # Нейтральная тёмно-синяя ночь (без NFS-фиолета), как в example-night
const NIGHT_FOG_DENSITY := 0.003

# Transition
var _transition_tween: Tween

# Sky crossfade
var _sky_blend_tween: Tween

# Мокрая машина
var _car_body_materials: Array[StandardMaterial3D] = []
var _car_body_dry_colors: Array[Color] = []  # Оригинальные цвета кузова
var _car_wet_tween: Tween
const CAR_DRY_ROUGHNESS := 0.35
const CAR_WET_ROUGHNESS := 0.005
const CAR_DRY_CLEARCOAT_ROUGHNESS := 0.15
const CAR_WET_CLEARCOAT_ROUGHNESS := 0.002
const CAR_DRY_METALLIC := 0.15
const CAR_WET_METALLIC := 0.7
const CAR_DRY_CLEARCOAT := 0.7
const CAR_WET_CLEARCOAT := 1.0
const CAR_WET_DARKEN := 0.2  # На сколько затемнить albedo

# Дневной дождь — приглушённое освещение
var _rain_light_tween: Tween
# Пасмурный дождь = ЯРКИЙ рассеянный день (небо — главный источник), а не сумерки.
# Солнце приглушено (нет жёстких теней), но ambient/HDRI остаются высокими.
const RAIN_SUN_ENERGY_MULT := 0.45  # Солнце слабее (мягкий рассеянный свет)
const RAIN_AMBIENT_ENERGY_MULT := 0.85  # Ambient почти полный — пасмурно, но светло
const RAIN_BG_ENERGY_MULT := 0.65  # HDRI небо чуть тусклее
const RAIN_FOG_DENSITY_MULT := 1.5  # Туман чуть гуще
const RAIN_VFOG_DENSITY_MULT := 2.0  # Объёмный туман гуще при дожде
const RAIN_FOG_COLOR := Color(0.62, 0.66, 0.72)  # Холодная серо-синяя дымка (пасмурно), вместо тёплой дневной
const RAIN_SATURATION := 0.78  # Десатурация в дождь (тусклый пасмурный грейд)


func _ready() -> void:
	# Глобальные шейдерные параметры зарегистрированы в project.godot [shader_globals]
	# Здесь только инициализируем значения
	RenderingServer.global_shader_parameter_set("is_night_global", false)
	RenderingServer.global_shader_parameter_set("wetness_global", 0.0)

	await get_tree().process_frame
	_find_scene_components()

	# HDRI дневное небо
	_create_day_hdri_sky()
	_load_day_textures()
	_apply_day_sky()

	# Ночное процедурное небо (оригинал)
	_create_night_sky()

	# Лунный свет
	_create_moon_light()

	# Дождь
	_create_rain_system()

	_car = get_tree().get_first_node_in_group("car")

	# CLI аргументы
	var args := OS.get_cmdline_args()
	var uargs := OS.get_cmdline_user_args()
	if args.has("--night") or uargs.has("--night"):
		start_night = true
	var start_rain := args.has("--rain") or uargs.has("--rain")

	if start_night:
		enable_night_mode()
	if start_rain:
		toggle_rain()
	print("NightModeManager: Ready (%s mode, %s)" % ["night" if is_night else "day", "rain" if is_raining else "no rain"])


func _find_scene_components() -> void:
	_world_env = get_tree().current_scene.find_child("WorldEnvironment", true, false) as WorldEnvironment
	if _world_env:
		_environment = _world_env.environment
		if _environment:
			if _environment.sky:
				_original_sky = _environment.sky.sky_material as ProceduralSkyMaterial
			_day_fog_color = _environment.fog_light_color
			_day_fog_density = _environment.fog_density
			_day_bg_energy = _environment.background_energy_multiplier
			_day_tonemap_exposure = _environment.tonemap_exposure
			_day_tonemap_white = _environment.tonemap_white
			_day_tonemap_mode = _environment.tonemap_mode
			_day_glow_intensity = _environment.glow_intensity
			_day_glow_bloom = _environment.glow_bloom
			_day_glow_blend_mode = _environment.glow_blend_mode
			_day_glow_hdr_threshold = _environment.glow_hdr_threshold
			_day_glow_hdr_scale = _environment.glow_hdr_scale
			_day_vfog_density = _environment.volumetric_fog_density
			_day_vfog_albedo = _environment.volumetric_fog_albedo
			_day_vfog_emission = _environment.volumetric_fog_emission
			_day_vfog_emission_energy = _environment.volumetric_fog_emission_energy
			_day_vfog_ambient_inject = _environment.volumetric_fog_ambient_inject
			_day_vfog_gi_inject = _environment.volumetric_fog_gi_inject
			_day_vfog_detail_spread = _environment.volumetric_fog_detail_spread
			_day_vfog_length = _environment.volumetric_fog_length
			_day_vfog_enabled = _environment.volumetric_fog_enabled
			# Capture day ambient so night→day restore returns to the scene's
			# real values (sky-source @ 1.35), not the var defaults (1.0 grey).
			_day_ambient_color = _environment.ambient_light_color
			_day_ambient_energy = _environment.ambient_light_energy
			_day_saturation = _environment.adjustment_saturation

	_sun_light = get_tree().current_scene.find_child("DirectionalLight3D", true, false) as DirectionalLight3D
	if _sun_light:
		_day_sun_energy = _sun_light.light_energy
		_day_sun_color = _sun_light.light_color

	_terrain_generator = get_tree().current_scene.find_child("OSMTerrain", true, false)
	_graphics_settings = get_tree().current_scene.find_child("GraphicsSettings", true, false)


# === HDRI дневное небо ===

func _create_day_hdri_sky() -> void:
	_day_hdri_material = ShaderMaterial.new()
	var shader := load("res://sky/panorama_blend_sky.gdshader") as Shader
	if not shader:
		push_error("NightModeManager: Failed to load panorama_blend_sky.gdshader!")
		return
	_day_hdri_material.shader = shader
	print("NightModeManager: Day HDRI shader created")


func _load_day_textures() -> void:
	var resolution_idx := 1  # Default: 2K
	if _graphics_settings and "sky_resolution" in _graphics_settings:
		resolution_idx = _graphics_settings.sky_resolution

	var suffix: String = SKY_RESOLUTION_SUFFIXES[resolution_idx]

	# Day clear (.hdr)
	var clear_path := DAY_CLEAR_BASE + suffix + ".hdr"
	_day_clear_tex = _load_sky_texture(clear_path)

	# Day rain (.hdr)
	var rain_path := DAY_RAIN_BASE + suffix + ".hdr"
	_day_rain_tex = _load_sky_texture(rain_path)


func _load_sky_texture(res_path: String) -> Texture2D:
	# Через ResourceLoader (импортированные текстуры)
	if ResourceLoader.exists(res_path):
		var tex: Texture2D = load(res_path)
		if tex:
			print("NightModeManager: Loaded sky: %s (%dx%d)" % [res_path, tex.get_width(), tex.get_height()])
			return tex
	# Фоллбэк: загрузка через Image напрямую
	var abs_path: String = ProjectSettings.globalize_path(res_path)
	var img := Image.new()
	if img.load(abs_path) == OK:
		var tex := ImageTexture.create_from_image(img)
		print("NightModeManager: Loaded sky (Image fallback): %s (%dx%d)" % [res_path, img.get_width(), img.get_height()])
		return tex
	push_warning("NightModeManager: Failed to load sky: %s" % res_path)
	return null


func _apply_day_sky(crossfade: bool = false) -> void:
	if not _environment or not _environment.sky or not _day_hdri_material:
		return
	var tex_next: Texture2D = _day_rain_tex if is_raining else _day_clear_tex
	if not tex_next:
		if _original_sky:
			_environment.sky.sky_material = _original_sky
		return

	var exposure_next := 0.8 if is_raining else 1.0

	# Убеждаемся что шейдер активен
	_environment.sky.sky_material = _day_hdri_material
	_environment.sky.process_mode = Sky.PROCESS_MODE_REALTIME
	_day_hdri_material.set_shader_parameter("rotation", 0.139)

	if crossfade:
		# Текущая текстура остаётся в panorama_current, новая — в panorama_next
		var exposure_current: float = _day_hdri_material.get_shader_parameter("exposure_current")
		_day_hdri_material.set_shader_parameter("panorama_next", tex_next)
		_day_hdri_material.set_shader_parameter("exposure_next", exposure_next)
		_day_hdri_material.set_shader_parameter("blend", 0.0)

		if _sky_blend_tween:
			_sky_blend_tween.kill()
		_sky_blend_tween = create_tween()
		_sky_blend_tween.tween_property(_day_hdri_material, "shader_parameter/blend", 1.0, 3.0)
		_sky_blend_tween.tween_callback(_finish_sky_crossfade.bind(tex_next, exposure_next))
	else:
		# Мгновенная установка (первый запуск / reload)
		_day_hdri_material.set_shader_parameter("panorama_current", tex_next)
		_day_hdri_material.set_shader_parameter("panorama_next", tex_next)
		_day_hdri_material.set_shader_parameter("blend", 0.0)
		_day_hdri_material.set_shader_parameter("exposure_current", exposure_next)
		_day_hdri_material.set_shader_parameter("exposure_next", exposure_next)


func _finish_sky_crossfade(tex: Texture2D, exposure: float) -> void:
	"""После завершения crossfade — переносим next в current"""
	_day_hdri_material.set_shader_parameter("panorama_current", tex)
	_day_hdri_material.set_shader_parameter("exposure_current", exposure)
	_day_hdri_material.set_shader_parameter("blend", 0.0)
	_environment.sky.process_mode = Sky.PROCESS_MODE_QUALITY


func reload_sky_textures() -> void:
	_load_day_textures()
	if not is_night:
		_apply_day_sky()
	print("NightModeManager: Sky textures reloaded")


# === Ночное процедурное небо (оригинал) ===

func _create_night_sky() -> void:
	_night_sky = ShaderMaterial.new()

	var shader := Shader.new()
	shader.code = """
shader_type sky;

uniform vec3 moon_direction = vec3(-0.3, 0.6, 0.4);
uniform float moon_size = 0.01;
uniform float star_density = 0.0015;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void sky() {
	vec3 dir = normalize(EYEDIR);

	// NFS Underground style - глубокий тёмно-синий с фиолетовым оттенком
	float horizon = smoothstep(-0.15, 0.5, dir.y);
	vec3 sky_top = vec3(0.01, 0.015, 0.04);
	vec3 sky_horizon = vec3(0.04, 0.02, 0.08);
	vec3 col = mix(sky_horizon, sky_top, horizon);

	// Stars
	if (dir.y > 0.05) {
		vec2 star_uv = dir.xz / (dir.y + 0.001) * 100.0;
		float star = step(1.0 - star_density, hash(floor(star_uv)));
		float brightness = hash(floor(star_uv) + vec2(0.5, 0.5));
		float twinkle = 0.7 + 0.3 * sin(TIME * (3.0 + brightness * 4.0) + brightness * 100.0);
		col += vec3(0.9, 0.95, 1.0) * star * twinkle * brightness;
	}

	// Moon
	vec3 moon_dir = normalize(moon_direction);
	float moon_dist = distance(dir, moon_dir);
	float moon = smoothstep(moon_size, moon_size * 0.5, moon_dist);
	float moon_glow = pow(smoothstep(moon_size * 4.0, moon_size, moon_dist), 2.5) * 0.25;
	col += vec3(0.85, 0.9, 1.0) * moon * 1.5;
	col += vec3(0.3, 0.4, 0.7) * moon_glow;

	// City glow - оранжевое от натриевых фонарей
	float city_glow_orange = smoothstep(0.15, -0.1, dir.y);
	col += vec3(0.25, 0.12, 0.02) * city_glow_orange * 0.8;

	// Лёгкий розово-фиолетовый неон (приглушён — без тяжёлого NFS-фиолета)
	float neon_glow = smoothstep(0.1, -0.15, dir.y);
	col += vec3(0.12, 0.06, 0.14) * neon_glow * 0.15;

	// Синее свечение от рекламы
	float blue_glow = smoothstep(0.08, -0.08, dir.y) * (0.5 + 0.5 * sin(dir.x * 10.0));
	col += vec3(0.02, 0.08, 0.15) * blue_glow * 0.2;

	COLOR = col;
}
"""
	_night_sky.shader = shader


func _switch_to_night_sky() -> void:
	if _environment and _environment.sky:
		_environment.sky.sky_material = _night_sky


func _switch_to_day_sky() -> void:
	_apply_day_sky()


# === Лунный свет ===

func _create_moon_light() -> void:
	_moon_light = DirectionalLight3D.new()
	_moon_light.name = "MoonLight"
	_moon_light.light_color = MOON_LIGHT_COLOR
	_moon_light.light_energy = 0.0
	_moon_light.shadow_enabled = true
	_moon_light.directional_shadow_max_distance = 200.0
	_moon_light.rotation_degrees = Vector3(-15, 145, 0)
	get_tree().current_scene.add_child(_moon_light)
	# Диск луны в ночном небе — по реальному направлению лунного света (не хардкод),
	# чтобы луна и её тени/подсветка совпадали. basis.z смотрит «к источнику» (в небо).
	if _night_sky:
		_night_sky.set_shader_parameter("moon_direction", _moon_light.global_transform.basis.z)


# === Дождь ===

func _create_rain_system() -> void:
	_rain_system = GPUParticles3D.new()
	_rain_system.name = "RainSystem"
	_rain_system.amount = 16000
	_rain_system.lifetime = 1.5
	_rain_system.one_shot = false
	_rain_system.explosiveness = 0.0
	_rain_system.randomness = 1.0
	_rain_system.visibility_aabb = AABB(Vector3(-60, -30, -60), Vector3(120, 60, 120))
	_rain_system.emitting = false

	var process_mat := ParticleProcessMaterial.new()
	process_mat.direction = Vector3(0.1, -1, 0.05)
	process_mat.spread = 3.0
	process_mat.initial_velocity_min = 35.0
	process_mat.initial_velocity_max = 45.0
	process_mat.gravity = Vector3(0, -15, 0)
	process_mat.damping_min = 0.0
	process_mat.damping_max = 0.0
	process_mat.particle_flag_align_y = true
	process_mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process_mat.emission_box_extents = Vector3(50, 5, 50)
	process_mat.scale_min = 0.8
	process_mat.scale_max = 1.2
	_rain_system.process_material = process_mat

	var drop_mesh := CylinderMesh.new()
	drop_mesh.top_radius = 0.008
	drop_mesh.bottom_radius = 0.008
	drop_mesh.height = 0.4
	_rain_system.draw_pass_1 = drop_mesh

	var drop_mat := StandardMaterial3D.new()
	drop_mat.albedo_color = Color(0.7, 0.8, 1.0, 0.25)
	drop_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	drop_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	drop_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_rain_system.material_override = drop_mat

	add_child(_rain_system)


func _update_horizon_profile(delta: float) -> void:
	_horizon_timer -= delta
	if not _day_hdri_material:
		return
	if not _car or not is_instance_valid(_car):
		_car = get_tree().get_first_node_in_group("car")
		if not _car:
			return
	if not _terrain_generator or not _terrain_generator.has_method("get_horizon_profile"):
		return
	var pos: Vector3 = _car.global_position
	if _horizon_timer > 0.0 and pos.distance_to(_horizon_last_pos) < HORIZON_UPDATE_DIST:
		return
	_horizon_timer = 2.0
	_horizon_last_pos = pos
	var bytes: PackedByteArray = _terrain_generator.get_horizon_profile(Vector2(pos.x, pos.z), HORIZON_SECTORS)
	if bytes.size() != HORIZON_SECTORS:
		return
	if _horizon_img == null:
		_horizon_img = Image.create_from_data(HORIZON_SECTORS, 1, false, Image.FORMAT_L8, bytes)
		_horizon_tex = ImageTexture.create_from_image(_horizon_img)
	else:
		_horizon_img.set_data(HORIZON_SECTORS, 1, false, Image.FORMAT_L8, bytes)
		_horizon_tex.update(_horizon_img)
	_day_hdri_material.set_shader_parameter("horizon_profile", _horizon_tex)
	_day_hdri_material.set_shader_parameter("horizon_profile_enabled", true)


func _process(delta: float) -> void:
	_update_horizon_profile(delta)
	# Rain follows camera + velocity-based direction
	if _rain_system and _rain_system.emitting:
		var camera := get_viewport().get_camera_3d()
		if camera:
			var offset := Vector3(0, 25, 0)

			if not _car:
				_car = get_tree().get_first_node_in_group("car")

			if _car:
				var vel: Vector3 = _car.linear_velocity
				var hvel := Vector3(vel.x, 0.0, vel.z)
				var hspeed := hvel.length()

				if hspeed > 2.0:
					offset += hvel.normalized() * clampf(hspeed * 0.3, 0.0, 15.0)

				var mat: ParticleProcessMaterial = _rain_system.process_material

				if hspeed > 2.0:
					var hdir := Vector3(-vel.x, 0.0, -vel.z).normalized()
					var speed_factor := clampf(hspeed * 0.04, 0.0, 2.5)
					mat.direction = (Vector3(0.0, -1.0, 0.0) + hdir * speed_factor).normalized()
					mat.gravity = Vector3(-vel.x * 0.5, -15.0, -vel.z * 0.5)
					var speed_boost := clampf(hspeed * 0.3, 0.0, 15.0)
					mat.initial_velocity_min = 35.0 + speed_boost
					mat.initial_velocity_max = 45.0 + speed_boost
				else:
					mat.direction = Vector3(0.1, -1.0, 0.05).normalized()
					mat.gravity = Vector3(0.0, -15.0, 0.0)
					mat.initial_velocity_min = 35.0
					mat.initial_velocity_max = 45.0

			_rain_system.global_position = camera.global_position + offset


# === Переключение режимов ===

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
	RenderingServer.global_shader_parameter_set("is_night_global", true)

	# Переключаем небо на процедурное ночное
	_switch_to_night_sky()

	# Обновляем окна
	if _terrain_generator and _terrain_generator.has_method("update_window_night_mode"):
		_terrain_generator.update_window_night_mode(true)

	# Обновляем отражения на дорогах
	if is_raining and _terrain_generator and _terrain_generator.has_method("set_wet_mode"):
		_terrain_generator.set_wet_mode(true, true)

	# Cancel existing tweens
	if _transition_tween:
		_transition_tween.kill()
	if _rain_light_tween:
		_rain_light_tween.kill()

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

		# NFS Underground style bloom
		_environment.glow_enabled = true
		_environment.glow_intensity = 1.2
		_environment.glow_bloom = 0.2
		_environment.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
		_environment.glow_hdr_threshold = 0.7
		_environment.glow_hdr_scale = 2.0

		# Tonemap
		_environment.tonemap_mode = Environment.TONE_MAPPER_AGX
		_environment.tonemap_exposure = 1.4
		_environment.tonemap_white = 6.0

		# Volumetric fog — атмосферная подсветка фонарей, но не «суп»
		_environment.volumetric_fog_enabled = true
		_transition_tween.tween_property(_environment, "volumetric_fog_density", 0.008, 1.5)
		_environment.volumetric_fog_albedo = Color(0.6, 0.65, 0.8)
		_environment.volumetric_fog_emission = Color(0.02, 0.01, 0.03)
		_environment.volumetric_fog_emission_energy = 0.3
		_environment.volumetric_fog_ambient_inject = 0.1
		_environment.volumetric_fog_gi_inject = 1.0
		_environment.volumetric_fog_detail_spread = 0.3
		_environment.volumetric_fog_length = 200.0
		_environment.volumetric_fog_temporal_reprojection_enabled = true
		_environment.volumetric_fog_temporal_reprojection_amount = 0.95

	night_mode_changed.emit(true)
	print("Night mode enabled")


func disable_night_mode() -> void:
	if not is_night:
		return

	is_night = false
	RenderingServer.global_shader_parameter_set("is_night_global", false)

	# Переключаем небо обратно на HDRI дневное
	_switch_to_day_sky()

	# Обновляем окна
	if _terrain_generator and _terrain_generator.has_method("update_window_night_mode"):
		_terrain_generator.update_window_night_mode(false)

	# Обновляем отражения на дорогах
	if is_raining and _terrain_generator and _terrain_generator.has_method("set_wet_mode"):
		_terrain_generator.set_wet_mode(true, false)

	# Cancel existing tweens
	if _transition_tween:
		_transition_tween.kill()
	if _rain_light_tween:
		_rain_light_tween.kill()

	_transition_tween = create_tween()
	_transition_tween.set_parallel(true)

	# Restore sun (с учётом дождя)
	var rain_mult := func(base: float, mult: float) -> float: return base * (mult if is_raining else 1.0)
	if _sun_light:
		_transition_tween.tween_property(_sun_light, "light_energy", rain_mult.call(_day_sun_energy, RAIN_SUN_ENERGY_MULT), 1.5)
		_transition_tween.tween_property(_sun_light, "light_color", _day_sun_color, 1.5)

	# Turn off moon light
	if _moon_light:
		_transition_tween.tween_property(_moon_light, "light_energy", 0.0, 1.5)

	# Restore ambient and fog (с учётом дождя)
	if _environment:
		_transition_tween.tween_property(_environment, "ambient_light_color", _day_ambient_color, 1.5)
		_transition_tween.tween_property(_environment, "ambient_light_energy", rain_mult.call(_day_ambient_energy, RAIN_AMBIENT_ENERGY_MULT), 1.5)
		_transition_tween.tween_property(_environment, "background_energy_multiplier", rain_mult.call(_day_bg_energy, RAIN_BG_ENERGY_MULT), 1.5)
		_transition_tween.tween_property(_environment, "fog_light_color", _day_fog_color, 1.5)
		_transition_tween.tween_property(_environment, "fog_density", rain_mult.call(_day_fog_density, RAIN_FOG_DENSITY_MULT), 1.5)

		# Restore day glow
		_environment.glow_intensity = _day_glow_intensity
		_environment.glow_bloom = _day_glow_bloom
		_environment.glow_blend_mode = _day_glow_blend_mode
		_environment.glow_hdr_threshold = _day_glow_hdr_threshold
		_environment.glow_hdr_scale = _day_glow_hdr_scale

		# Restore tonemap
		_environment.tonemap_mode = _day_tonemap_mode
		_environment.tonemap_exposure = _day_tonemap_exposure
		_environment.tonemap_white = _day_tonemap_white

		# Restore volumetric fog
		_transition_tween.tween_property(_environment, "volumetric_fog_density", _day_vfog_density, 1.5)
		_environment.volumetric_fog_albedo = _day_vfog_albedo
		_environment.volumetric_fog_emission = _day_vfog_emission
		_environment.volumetric_fog_emission_energy = _day_vfog_emission_energy
		_environment.volumetric_fog_ambient_inject = _day_vfog_ambient_inject
		_environment.volumetric_fog_gi_inject = _day_vfog_gi_inject
		_environment.volumetric_fog_detail_spread = _day_vfog_detail_spread
		_environment.volumetric_fog_length = _day_vfog_length
		_environment.volumetric_fog_enabled = _day_vfog_enabled

	night_mode_changed.emit(false)
	print("Night mode disabled")


func toggle_rain() -> void:
	is_raining = not is_raining
	_rain_system.emitting = is_raining

	# Днём плавно переключаем HDRI текстуру (ясно↔дождь)
	if not is_night:
		_apply_day_sky(true)
		_apply_rain_lighting(is_raining)

	# Update road wetness (плавно за 5 секунд)
	if _terrain_generator and _terrain_generator.has_method("set_wet_mode"):
		_terrain_generator.set_wet_mode(is_raining, is_night)

	# Мокрая машина (плавно за 3 секунды)
	_apply_car_wetness(is_raining)

	rain_changed.emit(is_raining)
	print("Rain: ", "enabled" if is_raining else "disabled")


func set_rain(enabled: bool) -> void:
	if enabled != is_raining:
		toggle_rain()


func _apply_rain_lighting(raining: bool) -> void:
	"""Плавно приглушает/восстанавливает дневное освещение при дожде"""
	if _rain_light_tween:
		_rain_light_tween.kill()

	_rain_light_tween = create_tween()
	_rain_light_tween.set_parallel(true)

	if raining:
		if _sun_light:
			_rain_light_tween.tween_property(_sun_light, "light_energy", _day_sun_energy * RAIN_SUN_ENERGY_MULT, 4.0)
		if _environment:
			_rain_light_tween.tween_property(_environment, "ambient_light_energy", _day_ambient_energy * RAIN_AMBIENT_ENERGY_MULT, 4.0)
			_rain_light_tween.tween_property(_environment, "background_energy_multiplier", _day_bg_energy * RAIN_BG_ENERGY_MULT, 4.0)
			_rain_light_tween.tween_property(_environment, "fog_density", _day_fog_density * RAIN_FOG_DENSITY_MULT, 4.0)
			_rain_light_tween.tween_property(_environment, "volumetric_fog_density", _day_vfog_density * RAIN_VFOG_DENSITY_MULT, 4.0)
			# Пасмурный дождь: холодная серая дымка + десатурация (вместо тёплого ясного грейда)
			_rain_light_tween.tween_property(_environment, "fog_light_color", RAIN_FOG_COLOR, 4.0)
			_rain_light_tween.tween_property(_environment, "adjustment_saturation", RAIN_SATURATION, 4.0)
	else:
		if _sun_light:
			_rain_light_tween.tween_property(_sun_light, "light_energy", _day_sun_energy, 4.0)
		if _environment:
			_rain_light_tween.tween_property(_environment, "ambient_light_energy", _day_ambient_energy, 4.0)
			_rain_light_tween.tween_property(_environment, "background_energy_multiplier", _day_bg_energy, 4.0)
			_rain_light_tween.tween_property(_environment, "fog_density", _day_fog_density, 4.0)
			_rain_light_tween.tween_property(_environment, "volumetric_fog_density", _day_vfog_density, 4.0)
			# Возврат к тёплому ясному грейду
			_rain_light_tween.tween_property(_environment, "fog_light_color", _day_fog_color, 4.0)
			_rain_light_tween.tween_property(_environment, "adjustment_saturation", _day_saturation, 4.0)


# === Мокрая машина ===

func _collect_car_body_materials() -> void:
	"""Собирает StandardMaterial3D кузова из машины игрока"""
	_car_body_materials.clear()
	_car_body_dry_colors.clear()
	if not _car:
		_car = get_tree().get_first_node_in_group("car")
	if not _car:
		return

	# Ищем Node3D-setup (polo_setup, beetle_setup, logan_setup) внутри машины
	for child in _car.get_children():
		if child is Node3D and child.get_script():
			_collect_body_mats_recursive(child)
			break
	# Если не нашли через setup — ищем по всей иерархии
	if _car_body_materials.is_empty():
		_collect_body_mats_recursive(_car)


func _collect_body_mats_recursive(node: Node) -> void:
	"""Рекурсивно собирает body-материалы из MeshInstance3D"""
	if node is MeshInstance3D:
		var mesh_name: String = node.name.to_lower()
		var is_body: bool = "body" in mesh_name or "roof" in mesh_name
		if is_body:
			var surface_count: int = node.get_surface_override_material_count()
			for i in range(surface_count):
				var mat: Material = node.get_surface_override_material(i)
				if mat is StandardMaterial3D and mat not in _car_body_materials:
					_car_body_materials.append(mat)
					_car_body_dry_colors.append(mat.albedo_color)
	for child in node.get_children():
		_collect_body_mats_recursive(child)


func _apply_car_wetness(wet: bool) -> void:
	"""Плавно делает кузов мокрым/сухим за 3 секунды"""
	if _car_body_materials.is_empty():
		_collect_car_body_materials()
	if _car_body_materials.is_empty():
		return

	if _car_wet_tween:
		_car_wet_tween.kill()

	_car_wet_tween = create_tween()
	_car_wet_tween.set_parallel(true)

	var target_rough: float = CAR_WET_ROUGHNESS if wet else CAR_DRY_ROUGHNESS
	var target_cc_rough: float = CAR_WET_CLEARCOAT_ROUGHNESS if wet else CAR_DRY_CLEARCOAT_ROUGHNESS
	var target_metallic: float = CAR_WET_METALLIC if wet else CAR_DRY_METALLIC
	var target_clearcoat: float = CAR_WET_CLEARCOAT if wet else CAR_DRY_CLEARCOAT

	for i in range(_car_body_materials.size()):
		var mat: StandardMaterial3D = _car_body_materials[i]
		_car_wet_tween.tween_property(mat, "roughness", target_rough, 3.0)
		_car_wet_tween.tween_property(mat, "clearcoat_roughness", target_cc_rough, 3.0)
		_car_wet_tween.tween_property(mat, "metallic", target_metallic, 3.0)
		_car_wet_tween.tween_property(mat, "clearcoat", target_clearcoat, 3.0)
		var dry_color: Color = _car_body_dry_colors[i]
		var wet_color: Color = dry_color.darkened(CAR_WET_DARKEN)
		var target_color: Color = wet_color if wet else dry_color
		_car_wet_tween.tween_property(mat, "albedo_color", target_color, 3.0)
