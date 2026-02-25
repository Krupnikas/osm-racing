shader_type spatial;
render_mode cull_disabled;

// Текстуры
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap, repeat_enable;

// PBR текстуры
uniform sampler2D roughness_texture : filter_linear_mipmap, repeat_enable;
uniform bool use_roughness_texture = false;

// Разметка (белые линии на прозрачном фоне)
uniform sampler2D marking_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform bool use_marking = false;

// Noise текстуры (tileable)
uniform sampler2D noise_micro_tex : filter_linear_mipmap, repeat_enable;
uniform sampler2D noise_macro_tex : filter_linear_mipmap, repeat_enable;

// Параметры материала
uniform vec4 base_color : source_color = vec4(0.25, 0.25, 0.25, 1.0);
uniform float normal_strength : hint_range(0.0, 2.0) = 0.8;
uniform bool use_texture = true;

// Параметры мокрой дороги
uniform bool is_wet = false;
uniform bool is_night = false;

// Roughness настройки
uniform float dry_roughness : hint_range(0.0, 1.0) = 0.85;
uniform float wet_roughness : hint_range(0.0, 1.0) = 0.15;

// Лужи
uniform float puddle_threshold : hint_range(0.0, 1.0) = 0.65;
uniform float puddle_roughness : hint_range(0.0, 0.1) = 0.02;
uniform float puddle_darkness : hint_range(0.0, 0.5) = 0.2;

// Metallic для отражений
uniform float dry_metallic : hint_range(0.0, 1.0) = 0.0;
uniform float wet_metallic : hint_range(0.0, 1.0) = 0.35;
uniform float puddle_metallic : hint_range(0.0, 1.0) = 0.5;

// Specular
uniform float dry_specular : hint_range(0.0, 1.0) = 0.5;
uniform float wet_specular : hint_range(0.0, 1.0) = 0.8;

// Масштабы UV для noise
uniform float micro_scale : hint_range(1.0, 50.0) = 12.0;
uniform float macro_scale : hint_range(0.1, 5.0) = 0.8;

// Интенсивности (dry)
uniform float macro_roughness_dry : hint_range(0.0, 0.2) = 0.08;
uniform float macro_albedo_dry : hint_range(0.0, 0.1) = 0.03;
uniform float micro_roughness_dry : hint_range(0.0, 0.15) = 0.06;

// Интенсивности (wet)
uniform float macro_roughness_wet : hint_range(0.0, 0.3) = 0.15;
uniform float micro_roughness_wet : hint_range(0.0, 0.1) = 0.04;

// Curb puddle bias (0 = равномерно, >0 = чаще у краёв)
uniform float curb_puddle_bias : hint_range(0.0, 1.0) = 0.3;


void fragment() {
	// Albedo
	vec3 albedo;
	if (use_texture) {
		albedo = texture(albedo_texture, UV).rgb;
	} else {
		albedo = base_color.rgb;
	}

	// Наложение разметки поверх асфальта
	if (use_marking) {
		vec4 mark = texture(marking_texture, UV);
		albedo = mix(albedo, mark.rgb, mark.a);
	}

	// Noise samples (2 texture fetches вместо FBM)
	float n_micro = texture(noise_micro_tex, UV * micro_scale).r;
	float n_macro = texture(noise_macro_tex, UV * macro_scale).r;

	// Curb bias: усиление луж у краёв дороги (UV.x: 0=left, 1=right)
	float edge_dist = abs(UV.x - 0.5) * 2.0;
	float curb_factor = mix(1.0, 1.0 + edge_dist * 0.5, curb_puddle_bias);

	float roughness;
	float metallic;
	float specular;

	if (is_wet) {
		// === МОКРАЯ ДОРОГА ===
		float base_rough = wet_roughness;
		if (use_roughness_texture) {
			base_rough = mix(wet_roughness, texture(roughness_texture, UV).r, 0.3);
		}
		base_rough += (n_micro - 0.5) * micro_roughness_wet;
		base_rough += (n_macro - 0.5) * macro_roughness_wet;

		// Puddle detection через macro noise + curb bias
		float puddle_value = n_macro * curb_factor;
		bool is_puddle = puddle_value > puddle_threshold;

		if (is_puddle) {
			roughness = puddle_roughness;
			metallic = puddle_metallic;
			albedo *= (1.0 - puddle_darkness);
			albedo = mix(albedo, vec3(0.1, 0.15, 0.2), 0.15);
		} else {
			roughness = base_rough;
			metallic = wet_metallic;
			albedo *= 0.9;
		}

		specular = wet_specular;

		// Fresnel эффект для отражений под углом
		float fresnel = pow(1.0 - abs(dot(NORMAL, VIEW)), 3.0);
		metallic = mix(metallic, metallic + 0.2, fresnel);

		if (is_night) {
			metallic += 0.1;
			roughness *= 0.8;
		}

	} else {
		// === СУХАЯ ДОРОГА ===
		if (use_roughness_texture) {
			roughness = texture(roughness_texture, UV).r;
		} else {
			roughness = dry_roughness;
		}
		roughness += (n_micro - 0.5) * micro_roughness_dry;
		roughness += (n_macro - 0.5) * macro_roughness_dry;

		// Macro variation для albedo (мягкие пятна)
		albedo += (n_macro - 0.5) * macro_albedo_dry;

		metallic = dry_metallic;
		specular = dry_specular;
	}

	// Разметка делает поверхность гладкой (краска)
	if (use_marking) {
		float mark_alpha = texture(marking_texture, UV).a;
		roughness = mix(roughness, 0.4, mark_alpha);
	}

	// Clamp значения
	roughness = clamp(roughness, 0.01, 1.0);
	metallic = clamp(metallic, 0.0, 1.0);

	// Выход
	ALBEDO = albedo;
	ROUGHNESS = roughness;
	METALLIC = metallic;
	SPECULAR = specular;

	// Normal map
	NORMAL_MAP = texture(normal_texture, UV).rgb;
	NORMAL_MAP_DEPTH = normal_strength;
}
