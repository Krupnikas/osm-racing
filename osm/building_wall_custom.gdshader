shader_type spatial;
render_mode cull_disabled, diffuse_lambert_wrap, specular_schlick_ggx;

// Основные текстуры
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap;
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap;
uniform sampler2D ao_texture : hint_default_white, filter_linear_mipmap;
uniform sampler2D roughness_texture : hint_default_white, filter_linear_mipmap;

// Параметры
uniform float normal_strength : hint_range(0.0, 2.0) = 1.0;
uniform float ao_strength : hint_range(0.0, 1.0) = 0.7;
uniform float roughness_base : hint_range(0.0, 1.0) = 0.5;

void fragment() {
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

	// AO — уменьшаем влияние на direct light чтобы фары освещали здания
	float ao = texture(ao_texture, UV).r;
	AO = mix(1.0, ao, ao_strength);
	AO_LIGHT_AFFECT = 0.5;

	// Roughness
	float roughness_tex = texture(roughness_texture, UV).r;
	ROUGHNESS = mix(roughness_base, 1.0 - roughness_tex, 0.5);

	METALLIC = 0.0;
	SPECULAR = 0.5;
}
