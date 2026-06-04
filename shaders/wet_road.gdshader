shader_type spatial;
render_mode cull_disabled;

// Текстуры
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;

// PBR текстуры
uniform sampler2D roughness_texture : filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool use_roughness_texture = false;

// Разметка (белые линии на прозрачном фоне)
uniform sampler2D marking_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool use_marking = false;

// Noise текстуры (tileable)
uniform sampler2D noise_micro_tex : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D noise_macro_tex : filter_linear_mipmap_anisotropic, repeat_enable;

// Параметры материала
uniform vec4 base_color : source_color = vec4(0.25, 0.25, 0.25, 1.0);
uniform float normal_strength : hint_range(0.0, 2.0) = 0.8;
uniform bool use_texture = true;

// Параметры мокрой дороги
global uniform float wetness_global;
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
uniform float wet_metallic : hint_range(0.0, 1.0) = 0.1;
uniform float puddle_metallic : hint_range(0.0, 1.0) = 0.3;

// Specular
uniform float dry_specular : hint_range(0.0, 1.0) = 0.5;
uniform float wet_specular : hint_range(0.0, 1.0) = 0.6;

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

// World-space масштаб noise для луж (синхронизация между дорогами/перекрёстками)
uniform float puddle_world_scale : hint_range(0.01, 0.5) = 0.08;

// Soviet asphalt wear: крупные world-space заплатки/износ + пятна (сухой асфальт)
uniform float asphalt_wear : hint_range(0.0, 1.0) = 0.55;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

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

	// === СУХАЯ ДОРОГА (база) ===
	float dry_rough;
	if (use_roughness_texture) {
		dry_rough = texture(roughness_texture, UV).r;
	} else {
		dry_rough = dry_roughness;
	}
	dry_rough += (n_micro - 0.5) * micro_roughness_dry;
	dry_rough += (n_macro - 0.5) * macro_roughness_dry;
	vec3 dry_albedo = albedo + (n_macro - 0.5) * macro_albedo_dry;

	// Soviet asphalt: крупные world-space заплатки (ремонты/износ) + пятна (масло/грязь)
	if (asphalt_wear > 0.0) {
		float patch = texture(noise_macro_tex, world_pos.xz * 0.018).r;   // ~55m заплатки
		float stain = texture(noise_micro_tex, world_pos.xz * 0.05).r;    // ~8m пятна
		dry_albedo *= mix(1.0, mix(0.78, 1.05, patch), asphalt_wear);
		dry_albedo *= mix(1.0, mix(0.90, 1.02, stain), asphalt_wear * 0.6);
		dry_rough = mix(dry_rough, dry_rough * mix(0.95, 1.08, patch), asphalt_wear);
	}

	// === МОКРАЯ ДОРОГА ===
	// Мокрый асфальт: сильное потемнение albedo (вода впитывается, свет поглощается)
	vec3 wet_albedo = albedo * 0.35;

	float wet_rough = wet_roughness;
	if (use_roughness_texture) {
		wet_rough = mix(wet_roughness, texture(roughness_texture, UV).r, 0.3);
	}
	wet_rough += (n_micro - 0.5) * micro_roughness_wet;
	wet_rough += (n_macro - 0.5) * macro_roughness_wet;

	// Puddle detection — world-space noise для синхронизации между дорогами/перекрёстками
	float n_puddle = texture(noise_macro_tex, world_pos.xz * puddle_world_scale).r;
	float puddle_value = n_puddle * curb_factor;
	float puddle_factor = smoothstep(0.5, 1.0, wetness_global) * step(puddle_threshold, puddle_value);
	wet_albedo = mix(wet_albedo, mix(wet_albedo * (1.0 - puddle_darkness), vec3(0.1, 0.15, 0.2), 0.15), puddle_factor);
	wet_rough = mix(wet_rough, puddle_roughness, puddle_factor);
	float wet_met = mix(wet_metallic, puddle_metallic, puddle_factor);

	// Fresnel — specular only, не metallic (иначе отражения маскируют потемнение)
	float fresnel = pow(1.0 - abs(dot(NORMAL, VIEW)), 3.0) * wetness_global;

	if (is_night) {
		wet_met += 0.05;
		wet_rough *= 0.8;
	}

	// === Финальное смешивание по wetness_global ===
	float roughness = mix(dry_rough, wet_rough, wetness_global);
	float metallic = mix(dry_metallic, wet_met, wetness_global);
	float specular = mix(dry_specular, wet_specular, wetness_global);
	albedo = mix(dry_albedo, wet_albedo, wetness_global);

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
