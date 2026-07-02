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

// A3: прямоугольные ремонтные заплатки (свежий тёмный битум), изредка. По типу
// дороги/региону (в Дубае patch_strength=0). Заплатки — целыми ячейками world-space.
uniform float patch_strength : hint_range(0.0, 1.0) = 0.0;
uniform float patch_cell_m : hint_range(1.0, 8.0) = 3.0;
uniform float patch_coverage : hint_range(0.0, 0.6) = 0.18;

// A3b: битумные «змейки» — залитые гудроном трещины: тёмные глянцевые извилистые линии.
// Domain-warped изолинии в world-space (непрерывны между чанками). В Дубае strength=0.
uniform float snake_strength : hint_range(0.0, 1.0) = 0.0;
uniform float snake_scale : hint_range(0.02, 0.5) = 0.12;
uniform float snake_width : hint_range(0.01, 0.2) = 0.05;
uniform float snake_warp : hint_range(0.0, 2.0) = 0.7;
uniform float snake_coverage : hint_range(0.3, 0.95) = 0.60;

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

// Хэш ячейки world-space (для прямоугольных заплаток A3).
float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 345.45));
	p += dot(p, p + 34.345);
	return fract(p.x * p.y);
}

// Аналитический value-noise + fbm (для битумных змеек — не мипается, чёткие вдаль).
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}
float fbm2(vec2 p) {
	float v = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 4; i++) {
		v += amp * vnoise(p);
		p *= 2.0;
		amp *= 0.5;
	}
	return v;
}

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

	// A3: ремонтные заплатки — в СИСТЕМЕ КООРДИНАТ ДОРОГИ (вдоль/поперёк), прямоугольниками
	// вытянутыми вдоль дороги, изредка и дискретно (случайный inset внутри ячейки), разной темноты.
	if (patch_strength > 0.0) {
		float across_p = (UV2.y > 0.5) ? UV2.x : (UV.x - 0.5) * road_width_m;   // поперёк, м
		float along_p = UV.y * 10.0;                                            // вдоль, м
		vec2 pc = vec2(across_p / patch_cell_m, along_p / (patch_cell_m * 1.8)); // вытянуто вдоль
		vec2 pcell = floor(pc);
		vec2 pf = fract(pc);
		float is_cell = step(1.0 - patch_coverage, hash21(pcell));
		// случайный под-прямоугольник ячейки → дискретные заплатки с зазорами (не сетка)
		vec2 lo = vec2(hash21(pcell + 3.1), hash21(pcell + 5.7)) * 0.22;
		vec2 hi = 1.0 - vec2(hash21(pcell + 8.3), hash21(pcell + 9.9)) * 0.22;
		float inside = step(lo.x, pf.x) * step(pf.x, hi.x) * step(lo.y, pf.y) * step(pf.y, hi.y);
		float pdark = mix(0.62, 0.82, hash21(pcell + 7.3));                     // разной темноты
		float amt = is_cell * inside * patch_strength;
		dry_albedo *= mix(1.0, pdark, amt);
		dry_rough = mix(dry_rough, dry_rough * 0.85, amt);                      // свежий битум глаже
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

	// A3b: битумные змейки — domain-warped изолинии на АНАЛИТИЧЕСКОМ шуме (не мипается →
	// чёткие и видны вдаль, без «поп-ина» у машины). Ширина линии через fwidth = ~1px на экране.
	if (snake_strength > 0.0) {
		vec2 tp = world_pos.xz * snake_scale;
		vec2 warp = vec2(fbm2(tp), fbm2(tp + vec2(3.7, 1.9)));
		float field = fbm2(tp * 0.8 + warp * snake_warp);
		float d = abs(field - 0.5);
		float w = fwidth(d) + 0.0015;                         // минимум ~1px, антиалиасинг
		float line = 1.0 - smoothstep(snake_width, snake_width + w, d);
		float smask = smoothstep(snake_coverage, snake_coverage + 0.15,
			fbm2(world_pos.xz * 0.02 + vec2(11.0, 7.0)));     // змейки лишь местами
		float amt = line * smask * snake_strength;
		dry_albedo = mix(dry_albedo, vec3(0.02, 0.02, 0.025), amt);          // чёрный битум
		dry_rough = mix(dry_rough, 0.28, amt);                               // глянцевый
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

	// Normal map
	NORMAL_MAP = texture(normal_texture, asph_uv).rgb;
	NORMAL_MAP_DEPTH = normal_strength;
}
