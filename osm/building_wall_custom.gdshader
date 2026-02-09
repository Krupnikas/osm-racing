shader_type spatial;
render_mode cull_disabled;

// Основные текстуры
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap;
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap;
uniform sampler2D ao_texture : hint_default_white, filter_linear_mipmap;
uniform sampler2D roughness_texture : hint_default_white, filter_linear_mipmap;

// Emissive mask - RGB цвета окон, чёрный = нет свечения
uniform sampler2D emission_mask : source_color, filter_linear_mipmap;
uniform float emission_energy : hint_range(0.0, 5.0) = 1.0;
uniform bool has_emission_mask = false;

// Глобальный параметр ночного режима - обновляется автоматически
global uniform bool is_night_global;

// Параметры
uniform float normal_strength : hint_range(0.0, 2.0) = 1.0;
uniform float ao_strength : hint_range(0.0, 1.0) = 1.0;
uniform float roughness_base : hint_range(0.0, 1.0) = 0.5;

void fragment() {
	// Albedo
	ALBEDO = texture(albedo_texture, UV).rgb;

	// Normal map
	vec3 normal_map = texture(normal_texture, UV).rgb;
	if (normal_map != vec3(0.5, 0.5, 1.0)) {
		NORMAL_MAP = normal_map;
		NORMAL_MAP_DEPTH = normal_strength;
	}

	// Инвертируем нормаль для задних граней
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}

	// AO
	float ao = texture(ao_texture, UV).r;
	AO = mix(1.0, ao, ao_strength);
	AO_LIGHT_AFFECT = ao_strength;

	// Roughness
	float roughness_tex = texture(roughness_texture, UV).r;
	ROUGHNESS = mix(roughness_base, 1.0 - roughness_tex, 0.5);

	METALLIC = 0.0;

	// Emission - только ночью и только если есть маска
	if (has_emission_mask && is_night_global) {
		vec3 emission_color = texture(emission_mask, UV).rgb;
		EMISSION = emission_color * emission_energy;
	}
}
