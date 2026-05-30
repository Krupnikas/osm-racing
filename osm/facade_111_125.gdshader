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

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap;
uniform sampler2D emission_texture : hint_default_black, filter_linear_mipmap;
uniform float roughness_base : hint_range(0.0, 1.0) = 0.78;
uniform float night_factor : hint_range(0.0, 1.0) = 0.0;
uniform vec3 emit_color : source_color = vec3(1.0, 0.88, 0.55);

void fragment() {
	vec4 tex = texture(albedo_texture, UV);
	ALBEDO = tex.rgb;
	ALPHA = tex.a;

	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}

	float emit_mask = texture(emission_texture, UV).r;
	EMISSION = emit_color * emit_mask * night_factor * COLOR.r;

	ROUGHNESS = roughness_base;
	METALLIC = 0.0;
	SPECULAR = 0.5;
}
