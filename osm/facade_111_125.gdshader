// Shader for the Северное Шоссе 39 111-125 atom facade prototype.
// Mirrors building_wall_custom.gdshader's lighting setup (cull_disabled +
// diffuse_lambert_wrap + back-face NORMAL flip) so vertical walls aren't
// pitch-black under top-down sun lighting, and adds optional alpha_scissor
// for window overlays.

shader_type spatial;
// `depth_prepass_alpha` is the key bit: with plain ALPHA_SCISSOR_THRESHOLD
// we got hard cuts at the threshold, and the antialiased edge pixels of the
// window-frame PNGs (alpha 0.6–0.99, frame RGB = white) rendered as fully
// opaque white — visible as a white halo around windows. depth_prepass_alpha
// does a depth pre-pass for fragments whose alpha is above a small cutoff,
// then alpha-blends the colour pass, so half-transparent edges blend with
// the wall behind smoothly. The depth pre-pass keeps the geometry sorted
// correctly so the overlay doesn't disappear behind the wall.
render_mode cull_disabled, depth_prepass_alpha, diffuse_lambert_wrap, specular_schlick_ggx;

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D emission_texture : hint_default_black, filter_linear_mipmap_anisotropic;
uniform float roughness_base : hint_range(0.0, 1.0) = 0.78;
uniform float night_factor : hint_range(0.0, 1.0) = 0.0;
uniform vec3 emit_color : source_color = vec3(1.0, 0.88, 0.55);

// ── Soviet weathering (procedural, world-space; no per-instance data) ──────
// Each building sits at a different world position, so low-frequency world-XZ
// noise gives per-building tonal/tint variation "for free". Vertical streaks +
// grunge + slight desaturation read as aged concrete panels.
uniform float weather_strength : hint_range(0.0, 1.0) = 0.7;

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
	vec4 tex = texture(albedo_texture, UV);
	vec3 base = tex.rgb;
	vec3 alb = base;

	// 1. Per-building tonal value variation (no two blocks identical)
	float macro = _vnoise(world_pos.xz * 0.025);
	alb *= mix(0.88, 1.08, macro);

	// 2. Per-building warm↔cool tint within a Soviet palette (beige↔grey)
	float tintn = _vnoise(world_pos.xz * 0.018 + vec2(31.4, 7.7));
	alb *= mix(vec3(0.94, 0.96, 1.03), vec3(1.07, 1.01, 0.89), tintn);

	// 3. Vertical water streaks (stretched along Y, narrow in X/Z)
	float s = _vnoise(vec2((world_pos.x + world_pos.z) * 0.5, world_pos.y * 0.04));
	float streak = smoothstep(0.6, 1.0, s);
	alb *= 1.0 - streak * 0.14;

	// 4. Fine grunge break-up to kill flat tiling
	float g = _vnoise(world_pos.xz * 0.18 + vec2(world_pos.y * 0.12));
	alb *= mix(0.95, 1.03, g);

	// 5. Aged concrete: slight desaturation
	float luma = dot(alb, vec3(0.299, 0.587, 0.114));
	alb = mix(alb, vec3(luma), 0.10);

	ALBEDO = mix(base, alb, weather_strength);
	ALPHA = tex.a;

	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}

	float emit_mask = texture(emission_texture, UV).r;
	EMISSION = emit_color * emit_mask * night_factor * COLOR.r;

	ROUGHNESS = roughness_base;
	METALLIC = 0.0;
	SPECULAR = 0.2;  // Матовый бетон — меньше specular-мерцания (раньше TAA это маскировал)
}
