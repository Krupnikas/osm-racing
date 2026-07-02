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
// Тинт базового альбедо (регион/износ): множитель поверх текстуры.
// 1.0 = как есть; <1 темнее. Задаётся в apply_road_type_params (Россия темнее, Дубай светлее).
uniform vec3 albedo_tint = vec3(1.0, 1.0, 1.0);
// Полировка «под Россию»: подтянуть базу к равномерному тёмному асфальту (меньше текстурности).
// base_uniformity = сколько блендить к плоскому base_road_color (0 = как есть, 1 = плоский цвет).
// base_road_color задан в ЛИНЕЙНОМ пространстве (не source_color): ~0.09 = средне-тёмный асфальт.
uniform float base_uniformity : hint_range(0.0, 1.0) = 0.0;
// Тёплый taupe-асфальт (R заметно > B) — не «холодный». Линейное пространство.
uniform vec3 base_road_color = vec3(0.085, 0.072, 0.055);
uniform float normal_strength : hint_range(0.0, 2.0) = 0.8;
uniform bool use_texture = true;

// A4: detail-нормаль — второй, более мелкий масштаб нормали для чёткости вблизи (whiteout-бленд).
// Гаснет с дистанцией (иначе высокочастотная нормаль мерцает вдали).
uniform float detail_normal_scale : hint_range(1.0, 12.0) = 4.0;
uniform float detail_normal_strength : hint_range(0.0, 1.5) = 0.6;
uniform float detail_fade_start : hint_range(2.0, 60.0) = 14.0;
uniform float detail_fade_len : hint_range(4.0, 60.0) = 22.0;

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

// Тайлинг базы асфальта в WORLD-SPACE (плиток на метр). Больше = мельче зерно.
// 0.8 ≈ одна плитка на 1.25 м. Заменяет растянутый UV.x=0..1 (плитка на всю ширину дороги).
uniform float asphalt_world_scale : hint_range(0.05, 4.0) = 0.8;

// A1: макро-вариация базы — медленный дрейф яркости (перекладки/выцветание),
// ломает восприятие повтора 1K-текстуры на длинных прямых. Период ~1/scale метров.
uniform float macro_var_scale : hint_range(0.002, 0.1) = 0.010;   // ~100 м
uniform float macro_var_strength : hint_range(0.0, 0.3) = 0.08;

// Заплатки ямочного ремонта и битумные змейки вынесены в ДЕКАЛИ
// (shaders/road_patch.gdshader + расстановка в osm_terrain_generator.gd).

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

// Полосы наката колёс. По умолчанию ВКЛ (1.0) на всех дорогах — покрытие "бесплатно",
// т.к. шейдер общий для всех дорожных мешей. apply_road_type_params выключает (0.0)
// на тротуарах/трамвае/перекрёстках. Ширина колеи постоянна в метрах:
// across_m берём из UV2.x (точно, если меш несёт UV2.y>0.5), иначе из road_width_m.
uniform float wheel_wear : hint_range(0.0, 1.0) = 1.0;
uniform float road_width_m : hint_range(1.0, 30.0) = 6.0;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// База асфальта — WORLD-SPACE тайлинг (world_pos.xz), а не UV дороги:
	// зерно равномерно и реалистично по размеру, независимо от ширины дороги
	// (UV.x=0..1 растягивал плитку на всю ширину → зерно было в разы крупнее).
	// Разметка и шум остаются на UV.
	vec2 asph_uv = world_pos.xz * asphalt_world_scale;

	// Albedo
	vec3 albedo;
	if (use_texture) {
		albedo = texture(albedo_texture, asph_uv).rgb;
	} else {
		albedo = base_color.rgb;
	}
	albedo *= albedo_tint;   // регион/износ-тинт базы
	albedo = mix(albedo, base_road_color, base_uniformity);   // «под Россию»: ровнее+темнее
	// A1: медленный world-space дрейф яркости (tiling-break на длинных прямых)
	float macro_var = texture(noise_macro_tex, world_pos.xz * macro_var_scale).r;
	albedo *= mix(1.0 - macro_var_strength, 1.0 + macro_var_strength, macro_var);

	// Разметка наносится В КОНЦЕ (поверх износа/заплаток) — см. блок перед выводом.

	// Noise samples (2 texture fetches вместо FBM)
	float n_micro = texture(noise_micro_tex, UV * micro_scale).r;
	float n_macro = texture(noise_macro_tex, UV * macro_scale).r;

	// Curb bias: усиление луж у краёв дороги (UV.x: 0=left, 1=right)
	float edge_dist = abs(UV.x - 0.5) * 2.0;
	float curb_factor = mix(1.0, 1.0 + edge_dist * 0.5, curb_puddle_bias);

	// === СУХАЯ ДОРОГА (база) ===
	float dry_rough;
	if (use_roughness_texture) {
		dry_rough = texture(roughness_texture, asph_uv).r;
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

	// Полосы наката колёс: две тёмные полосы в каждой полосе движения (3.5 м),
	// на расстоянии 1.4 м (колея авто ≈ ±0.7 м от центра полосы). ПОСТОЯННО в метрах.
	// Только на достаточно широких дорогах (узкие проезды/дорожки — без колеи).
	if (wheel_wear > 0.0 && road_width_m >= 5.5) {
		// across_m — расстояние от осевой в метрах. UV2 (если валиден) точнее всего.
		float across_m = (UV2.y > 0.5) ? UV2.x : (UV.x - 0.5) * road_width_m;
		float lane_center = (floor(across_m / 3.5) + 0.5) * 3.5;
		float lane_local = across_m - lane_center;          // -1.75..1.75 в полосе
		float wp = abs(abs(lane_local) - 0.70);             // до ближайшей колеи, м
		float band = smoothstep(0.28, 0.0, wp);             // полоса наката ~56 см (шире)
		// продольная/world вариация, чтобы не было идеальной краски
		float wj = texture(noise_macro_tex, world_pos.xz * 0.06).r;
		band *= mix(0.7, 1.0, wj);
		dry_albedo *= mix(1.0, 0.83, band * wheel_wear);    // бледнее (раньше 0.72)
		dry_rough = mix(dry_rough, dry_rough * 0.9, band * wheel_wear);
	}

	// === МОКРАЯ ДОРОГА ===
	// Мокрый асфальт: сильное потемнение albedo (вода впитывается, свет поглощается)
	vec3 wet_albedo = albedo * 0.35;

	float wet_rough = wet_roughness;
	if (use_roughness_texture) {
		wet_rough = mix(wet_roughness, texture(roughness_texture, asph_uv).r, 0.3);
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

	// Разметка — ПОВЕРХ износа/заплаток (краска сверху) + делает поверхность глаже
	if (use_marking) {
		vec4 mark = texture(marking_texture, UV);
		albedo = mix(albedo, mark.rgb, mark.a);
		roughness = mix(roughness, 0.4, mark.a);
	}

	// Clamp значения
	roughness = clamp(roughness, 0.01, 1.0);
	metallic = clamp(metallic, 0.0, 1.0);

	// Выход
	ALBEDO = albedo;
	ROUGHNESS = roughness;
	METALLIC = metallic;
	SPECULAR = specular;

	// Normal map — A4: база + мелкая detail-нормаль (whiteout), detail гаснет с дистанцией.
	vec3 bn = texture(normal_texture, asph_uv).rgb * 2.0 - 1.0;
	vec3 dn = texture(normal_texture, asph_uv * detail_normal_scale).rgb * 2.0 - 1.0;
	float cam_dist = length(world_pos - CAMERA_POSITION_WORLD);
	float det_fade = clamp(1.0 - (cam_dist - detail_fade_start) / detail_fade_len, 0.0, 1.0) * detail_normal_strength;
	dn.xy *= det_fade;
	vec3 comb_n = normalize(vec3(bn.xy + dn.xy, max(bn.z * dn.z, 0.05)));   // whiteout-бленд
	NORMAL_MAP = comb_n * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = normal_strength;
}
