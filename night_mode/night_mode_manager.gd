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
var _world_env: WorldEnvironment
var _original_sky: ProceduralSkyMaterial
var _night_sky: ShaderMaterial
var _rain_system: GPUParticles3D
var _terrain_generator: Node

# Сохранённые дневные настройки
var _day_sun_energy := 1.0
var _day_sun_color := Color(1.0, 1.0, 1.0)
var _day_ambient_color := Color(0.5, 0.5, 0.5)
var _day_ambient_energy := 1.0

# Ночные настройки
const NIGHT_SUN_ENERGY := 0.15  # Лунный свет чуть ярче
const NIGHT_SUN_COLOR := Color(0.7, 0.8, 1.0)  # Холодный белый лунный свет
const NIGHT_AMBIENT_COLOR := Color(0.03, 0.04, 0.08)  # Холодный синеватый
const NIGHT_AMBIENT_ENERGY := 0.25

# Transition
var _transition_tween: Tween


func _ready() -> void:
	# Ищем компоненты сцены
	await get_tree().process_frame
	_find_scene_components()

	# Создаём ночное небо
	_create_night_sky()

	# Создаём систему дождя
	_create_rain_system()

	# По умолчанию включаем ночь и дождь
	enable_night_mode()
	toggle_rain()
	print("Night mode enabled")


func _find_scene_components() -> void:
	# Ищем WorldEnvironment
	_world_env = get_tree().current_scene.find_child("WorldEnvironment", true, false) as WorldEnvironment
	if _world_env:
		_environment = _world_env.environment
		if _environment and _environment.sky:
			_original_sky = _environment.sky.sky_material as ProceduralSkyMaterial

	# Ищем DirectionalLight3D (солнце)
	_sun_light = get_tree().current_scene.find_child("DirectionalLight3D", true, false) as DirectionalLight3D
	if _sun_light:
		_day_sun_energy = _sun_light.light_energy
		_day_sun_color = _sun_light.light_color

	# Ищем terrain generator
	_terrain_generator = get_tree().current_scene.find_child("OSMTerrain", true, false)


func _create_night_sky() -> void:
	_night_sky = ShaderMaterial.new()

	var shader := Shader.new()
	shader.code = """
shader_type sky;

uniform vec3 moon_direction = vec3(-0.5, 0.7, 0.5);
uniform float moon_size = 0.06;
uniform float star_density = 0.002;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void sky() {
	vec3 dir = normalize(EYEDIR);

	// Night gradient (horizon to zenith)
	float horizon = smoothstep(-0.1, 0.4, dir.y);
	vec3 col = mix(vec3(0.02, 0.04, 0.10), vec3(0.0, 0.01, 0.03), horizon);

	// Stars (only above horizon)
	if (dir.y > 0.0) {
		vec2 star_uv = dir.xz / (dir.y + 0.001) * 80.0;
		float star = step(1.0 - star_density, hash(floor(star_uv)));
		float brightness = hash(floor(star_uv) + vec2(0.5, 0.5));
		float twinkle = 0.6 + 0.4 * sin(TIME * (2.0 + brightness * 3.0) + brightness * 100.0);
		col += vec3(star * twinkle * brightness * 0.9);
	}

	// Moon - cold white
	vec3 moon_dir = normalize(moon_direction);
	float moon_dist = distance(dir, moon_dir);
	float moon = smoothstep(moon_size, moon_size * 0.7, moon_dist);
	float moon_glow = smoothstep(moon_size * 5.0, moon_size, moon_dist) * 0.25;
	col += vec3(0.85, 0.9, 1.0) * moon;
	col += vec3(0.15, 0.2, 0.35) * moon_glow;

	// Slight horizon glow (city lights reflection)
	float city_glow = smoothstep(0.1, -0.05, dir.y) * 0.15;
	col += vec3(0.15, 0.10, 0.05) * city_glow;

	COLOR = col;
}
"""
	_night_sky.shader = shader


func _create_rain_system() -> void:
	_rain_system = GPUParticles3D.new()
	_rain_system.name = "RainSystem"
	_rain_system.amount = 8000
	_rain_system.lifetime = 1.5
	_rain_system.one_shot = false
	_rain_system.explosiveness = 0.0
	_rain_system.randomness = 1.0
	_rain_system.visibility_aabb = AABB(Vector3(-60, -30, -60), Vector3(120, 60, 120))
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
				if is_night:
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

	# Cancel existing tween
	if _transition_tween:
		_transition_tween.kill()

	_transition_tween = create_tween()
	_transition_tween.set_parallel(true)

	# Dim sun and change color to moonlight
	if _sun_light:
		_transition_tween.tween_property(_sun_light, "light_energy", NIGHT_SUN_ENERGY, 1.5)
		_transition_tween.tween_property(_sun_light, "light_color", NIGHT_SUN_COLOR, 1.5)

	# Change ambient
	if _environment:
		_transition_tween.tween_property(_environment, "ambient_light_color", NIGHT_AMBIENT_COLOR, 1.5)
		_transition_tween.tween_property(_environment, "ambient_light_energy", NIGHT_AMBIENT_ENERGY, 1.5)

		# Enable bloom
		_environment.glow_enabled = true
		_environment.glow_intensity = 1.2
		_environment.glow_bloom = 0.3
		_environment.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
		_environment.glow_hdr_threshold = 0.8

	# Switch sky after short delay
	_transition_tween.chain().tween_callback(_switch_to_night_sky)

	night_mode_changed.emit(true)
	print("Night mode enabled")


func disable_night_mode() -> void:
	if not is_night:
		return

	is_night = false

	# Disable rain first
	if is_raining:
		toggle_rain()

	# Cancel existing tween
	if _transition_tween:
		_transition_tween.kill()

	_transition_tween = create_tween()
	_transition_tween.set_parallel(true)

	# Restore sun
	if _sun_light:
		_transition_tween.tween_property(_sun_light, "light_energy", _day_sun_energy, 1.5)
		_transition_tween.tween_property(_sun_light, "light_color", _day_sun_color, 1.5)

	# Restore ambient
	if _environment:
		_transition_tween.tween_property(_environment, "ambient_light_color", _day_ambient_color, 1.5)
		_transition_tween.tween_property(_environment, "ambient_light_energy", _day_ambient_energy, 1.5)

		# Disable bloom
		_environment.glow_enabled = false

	# Switch sky
	_switch_to_day_sky()

	night_mode_changed.emit(false)
	print("Night mode disabled")


func _switch_to_night_sky() -> void:
	if _environment and _environment.sky:
		_environment.sky.sky_material = _night_sky


func _switch_to_day_sky() -> void:
	if _environment and _environment.sky and _original_sky:
		_environment.sky.sky_material = _original_sky


func toggle_rain() -> void:
	if not is_night:
		return

	is_raining = not is_raining
	_rain_system.emitting = is_raining

	# Update road wetness
	if _terrain_generator and _terrain_generator.has_method("set_wet_mode"):
		_terrain_generator.set_wet_mode(is_raining)

	rain_changed.emit(is_raining)
	print("Rain: ", "enabled" if is_raining else "disabled")


func set_rain(enabled: bool) -> void:
	if enabled != is_raining and is_night:
		toggle_rain()
