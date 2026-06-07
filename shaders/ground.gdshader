shader_type spatial;
render_mode cull_disabled;

// PBR текстуры травы
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D roughness_tex : filter_linear_mipmap_anisotropic, repeat_enable;

// Macro noise для борьбы с тайлингом
uniform sampler2D noise_macro_tex : filter_linear_mipmap_anisotropic, repeat_enable;

// Глобальные режимы
global uniform float wetness_global;
uniform bool is_night = false;

// PBR параметры
uniform float normal_strength : hint_range(0.0, 2.0) = 0.8;
uniform float dry_roughness_base : hint_range(0.0, 1.0) = 0.85;
uniform float wet_roughness_base : hint_range(0.0, 1.0) = 0.75;
uniform float wet_darkening : hint_range(0.0, 0.8) = 0.55;

// Macro variation (world-space noise)
uniform float macro_world_scale : hint_range(0.005, 0.2) = 0.015;
uniform float macro_albedo_intensity : hint_range(0.0, 0.3) = 0.12;
uniform float macro_roughness_intensity : hint_range(0.0, 0.3) = 0.15;

// Weedy verge / разнотравье: пятна более густой и зелёной травы поверх сухой базы.
// Несколько масштабов world-space шума → неоднородный, "запущенный" газон.
uniform float weed_scale : hint_range(0.005, 0.3) = 0.06;
uniform float weed_threshold : hint_range(0.0, 1.0) = 0.42;
uniform float weed_intensity : hint_range(0.0, 1.0) = 0.7;
uniform float weed_green : hint_range(1.0, 1.4) = 1.18;   // буст зелёного в клочках
uniform float weed_darken : hint_range(0.5, 1.0) = 0.82;  // гуще/темнее

// Tire track mask (локальная маска вокруг машины)
uniform sampler2D track_mask_tex : repeat_disable, filter_linear;
uniform sampler2D noise_micro_tex : filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec2 track_origin_world = vec2(0.0);
uniform float track_world_size = 50.0;

// Mud appearance
uniform vec3 mud_color : source_color = vec3(0.35, 0.28, 0.18);
uniform float mud_albedo_strength : hint_range(0.0, 1.0) = 0.45;
uniform float mud_darken : hint_range(0.0, 0.4) = 0.08;
uniform float mud_desaturate : hint_range(0.0, 1.0) = 0.3;
uniform float mud_roughness : hint_range(0.0, 1.0) = 0.92;
uniform float mud_noise_strength : hint_range(0.0, 0.5) = 0.15;
uniform float mud_wet_boost : hint_range(0.0, 0.5) = 0.15;

// Varying: мировая позиция вершины (model space → world space)
varying vec3 world_vertex;

void vertex() {
	world_vertex = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 world_xz = world_vertex.xz;

	// Albedo из PBR текстуры
	vec3 albedo = texture(albedo_tex, UV).rgb;

	// Roughness из текстуры, масштабируем к базовому уровню
	float tex_rough = texture(roughness_tex, UV).r;
	float roughness = mix(dry_roughness_base - 0.15, dry_roughness_base + 0.05, tex_rough);

	// Macro noise в world-space
	float n_macro = texture(noise_macro_tex, world_xz * macro_world_scale).r;
	albedo += (n_macro - 0.5) * macro_albedo_intensity;
	roughness += (n_macro - 0.5) * macro_roughness_intensity;

	// Weedy verge: клочки более густой/зелёной травы (разнотравье), два масштаба
	// шума со смещением, чтобы не коррелировать с macro variation выше.
	float weed_a = texture(noise_macro_tex, world_xz * weed_scale + vec2(11.3, 7.1)).r;
	float weed_b = texture(noise_macro_tex, world_xz * weed_scale * 2.7 + vec2(3.4, 19.2)).r;
	float weed = smoothstep(weed_threshold, 1.0, weed_a * 0.65 + weed_b * 0.35);
	// Убираем жёлтый (гасим R и B), поднимаем зелёный → явно зелёные клочки
	vec3 weedy = vec3(albedo.r * 0.74, min(1.0, albedo.g * weed_green), albedo.b * 0.66) * weed_darken;
	albedo = mix(albedo, weedy, weed * weed_intensity);
	roughness = mix(roughness, min(1.0, roughness + 0.05), weed);  // гуще → чуть матовее

	// === Tire tracks (грязные следы шин) ===
	vec2 track_local = (world_xz - track_origin_world) / track_world_size;
	float track = 0.0;
	if (track_local.x >= 0.0 && track_local.x <= 1.0 && track_local.y >= 0.0 && track_local.y <= 1.0) {
		track = texture(track_mask_tex, track_local).r;
		// Рваные края через micro noise
		float tn = texture(noise_micro_tex, world_xz * 0.8).r;
		track *= mix(1.0 - mud_noise_strength, 1.0 + mud_noise_strength, tn);
		track = smoothstep(0.05, 0.3, track);
		track = clamp(track, 0.0, 1.0);
	}
	// В дождь следы заметнее
	if (wetness_global > 0.0) {
		track = clamp(track * (1.0 + mud_wet_boost * wetness_global), 0.0, 1.0);
	}
	// Десатурация зелени → серый
	float luma = dot(albedo, vec3(0.299, 0.587, 0.114));
	albedo = mix(albedo, vec3(luma), track * mud_desaturate);
	// Примешиваем цвет грязи
	albedo = mix(albedo, mud_color, track * mud_albedo_strength);
	// Дополнительное затемнение
	albedo *= (1.0 - track * mud_darken);
	// Грязь более матовая
	roughness = mix(roughness, mud_roughness, track);

	// Wet mode: трава темнеет, roughness снижается (без луж/блеска)
	if (wetness_global > 0.0) {
		albedo *= (1.0 - wet_darkening * wetness_global);
		roughness = mix(roughness, min(roughness, wet_roughness_base), wetness_global);
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
