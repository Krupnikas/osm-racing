shader_type spatial;
render_mode cull_disabled;

// PBR текстуры травы
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D roughness_tex : filter_linear_mipmap, repeat_enable;

// Macro noise для борьбы с тайлингом
uniform sampler2D noise_macro_tex : filter_linear_mipmap, repeat_enable;

// Глобальные режимы
uniform bool is_wet = false;
uniform bool is_night = false;

// PBR параметры
uniform float normal_strength : hint_range(0.0, 2.0) = 0.8;
uniform float dry_roughness_base : hint_range(0.0, 1.0) = 0.85;
uniform float wet_roughness_base : hint_range(0.0, 1.0) = 0.75;
uniform float wet_darkening : hint_range(0.0, 0.3) = 0.12;

// Macro variation (world-space noise)
uniform float macro_world_scale : hint_range(0.005, 0.2) = 0.015;
uniform float macro_albedo_intensity : hint_range(0.0, 0.3) = 0.12;
uniform float macro_roughness_intensity : hint_range(0.0, 0.3) = 0.15;


void fragment() {
	// Albedo из PBR текстуры
	vec3 albedo = texture(albedo_tex, UV).rgb;

	// Roughness из текстуры, масштабируем к базовому уровню
	float tex_rough = texture(roughness_tex, UV).r;
	float roughness = mix(dry_roughness_base - 0.15, dry_roughness_base + 0.05, tex_rough);

	// Macro noise в world-space (VERTEX = world pos, т.к. transform = IDENTITY)
	float n_macro = texture(noise_macro_tex, VERTEX.xz * macro_world_scale).r;
	albedo += (n_macro - 0.5) * macro_albedo_intensity;
	roughness += (n_macro - 0.5) * macro_roughness_intensity;

	// Wet mode: трава темнеет, roughness снижается (без луж/блеска)
	if (is_wet) {
		albedo *= (1.0 - wet_darkening);
		roughness = min(roughness, wet_roughness_base);
	}

	// Night mode: лёгкое затемнение
	if (is_night) {
		albedo *= 0.95;
		roughness *= 0.97;
	}

	// Clamp
	ALBEDO = clamp(albedo, vec3(0.0), vec3(1.0));
	ROUGHNESS = clamp(roughness, 0.0, 1.0);
	METALLIC = 0.0;
	SPECULAR = 0.4;

	// Normal map
	NORMAL_MAP = texture(normal_tex, UV).rgb;
	NORMAL_MAP_DEPTH = normal_strength;
}
