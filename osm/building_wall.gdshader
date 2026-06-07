shader_type spatial;
render_mode cull_disabled, diffuse_lambert_wrap, specular_schlick_ggx;

// Текстура стены
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D roughness_texture : filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 albedo_color : source_color = vec4(0.7, 0.6, 0.5, 1.0);
uniform bool use_texture = false;
uniform bool use_normal = false;
uniform bool use_roughness_texture = false;
uniform float normal_strength : hint_range(0.0, 2.0) = 0.8;
uniform float ao_strength : hint_range(0.0, 1.0) = 0.4;
uniform float roughness_base : hint_range(0.0, 1.0) = 0.7;

// Window recess emission — vertex COLOR содержит цвет окна
uniform bool use_vertex_emission = false;
uniform float recess_emission_energy : hint_range(0.0, 8.0) = 2.0;

// ── Soviet weathering (opt-in; 0.0 = off so curbs/parapets/fences stay clean) ──
// World-space noise → per-building tonal/tint variation + vertical streaks + grunge.
uniform float weather_strength : hint_range(0.0, 1.0) = 0.0;

global uniform bool is_night_global;
global uniform float wetness_global;

varying vec3 world_pos;

float _hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float _vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = _hash(i);
	float b = _hash(i + vec2(1.0, 0.0));
	float c = _hash(i + vec2(0.0, 1.0));
	float d = _hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

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

	// Soviet weathering (только если включено для этого материала)
	if (weather_strength > 0.0) {
		vec3 w = color;
		// 1. Per-building tonal value variation
		float macro = _vnoise(world_pos.xz * 0.025);
		w *= mix(0.88, 1.08, macro);
		// 2. Per-building warm↔cool tint (beige↔grey)
		float tintn = _vnoise(world_pos.xz * 0.018 + vec2(31.4, 7.7));
		w *= mix(vec3(0.94, 0.96, 1.03), vec3(1.07, 1.01, 0.89), tintn);
		// 3. Vertical water streaks
		float s = _vnoise(vec2((world_pos.x + world_pos.z) * 0.5, world_pos.y * 0.04));
		w *= 1.0 - smoothstep(0.6, 1.0, s) * 0.14;
		// 4. Fine grunge break-up
		float g = _vnoise(world_pos.xz * 0.18 + vec2(world_pos.y * 0.12));
		w *= mix(0.95, 1.03, g);
		// 5. Aged concrete desaturation
		float luma = dot(w, vec3(0.299, 0.587, 0.114));
		w = mix(w, vec3(luma), 0.10);
		color = mix(color, w, weather_strength);
	}

	// Wet darkening — бордюры/стены темнеют от дождя
	if (wetness_global > 0.0) {
		color *= (1.0 - 0.45 * wetness_global);
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
	// Wet: снижаем roughness
	if (wetness_global > 0.0) {
		ROUGHNESS = mix(ROUGHNESS, ROUGHNESS * 0.7, wetness_global);
	}
	METALLIC = 0.0;
	SPECULAR = 0.5;

	// Recess emission: vertex color = window light color (premultiplied)
	if (use_vertex_emission && is_night_global) {
		float lum = dot(COLOR.rgb, vec3(0.299, 0.587, 0.114));
		if (lum > 0.01) {
			EMISSION = COLOR.rgb * recess_emission_energy;
			// Lit recesses slightly brighter albedo from window light
			ALBEDO = mix(ALBEDO, ALBEDO + COLOR.rgb * 0.3, min(lum * 2.0, 1.0));
		}
	}
}
