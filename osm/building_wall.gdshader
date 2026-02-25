shader_type spatial;
render_mode cull_disabled, diffuse_lambert_wrap, specular_schlick_ggx;

// Текстура стены
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D roughness_texture : filter_linear_mipmap, repeat_enable;
uniform vec4 albedo_color : source_color = vec4(0.7, 0.6, 0.5, 1.0);
uniform bool use_texture = false;
uniform bool use_normal = false;
uniform bool use_roughness_texture = false;
uniform float normal_strength : hint_range(0.0, 2.0) = 0.8;
uniform float ao_strength : hint_range(0.0, 1.0) = 0.4;
uniform float roughness_base : hint_range(0.0, 1.0) = 0.7;

void fragment() {
	// Получаем цвет из текстуры или используем albedo_color
	vec4 tex_color = texture(albedo_texture, UV);
	vec3 color;
	if (use_texture) {
		color = tex_color.rgb;
	} else {
		color = albedo_color.rgb;
	}

	// Для кастомных текстур не применяем вариацию, для процедурных - минимальная
	if (!use_texture) {
		float height_variation = 0.02 * sin(UV.y * 50.0);
		color += vec3(height_variation);
	}

	ALBEDO = color;

	// Normal mapping
	if (use_normal) {
		vec3 normal_map = texture(normal_texture, UV).rgb;
		NORMAL_MAP = normal_map;
		NORMAL_MAP_DEPTH = normal_strength;
	}

	// Инвертируем нормаль для задних граней
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}

	// Roughness
	if (use_roughness_texture) {
		ROUGHNESS = texture(roughness_texture, UV).r;
	} else if (use_texture) {
		ROUGHNESS = 0.55;
	} else {
		ROUGHNESS = roughness_base;
	}
	METALLIC = 0.0;
	SPECULAR = 0.5;
}
