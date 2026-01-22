shader_type spatial;
render_mode cull_disabled;

// Текстура стены
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap;
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap;
uniform vec4 albedo_color : source_color = vec4(0.7, 0.6, 0.5, 1.0);
uniform bool use_texture = false;
uniform bool use_normal = false;
uniform float normal_strength : hint_range(0.0, 2.0) = 0.8;
uniform float ao_strength : hint_range(0.0, 1.0) = 0.4;
uniform float roughness_base : hint_range(0.0, 1.0) = 0.85;

void fragment() {
	// Получаем цвет из текстуры или используем albedo_color
	vec4 tex_color = texture(albedo_texture, UV);
	vec3 color;
	if (use_texture) {
		color = tex_color.rgb;
	} else {
		color = albedo_color.rgb;
	}

	// Простой Ambient Occlusion - затемнение внизу здания
	float ao = 1.0 - ao_strength * pow(1.0 - UV.y, 2.0);
	color *= ao;

	// Добавляем небольшую вариацию по высоте
	float height_variation = 0.02 * sin(UV.y * 50.0);
	color += vec3(height_variation);

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

	// Вариация roughness для интересных отражений
	float roughness_variation = 0.05 * texture(albedo_texture, UV * 4.0).r;
	ROUGHNESS = roughness_base + roughness_variation;
	METALLIC = 0.0;
}
