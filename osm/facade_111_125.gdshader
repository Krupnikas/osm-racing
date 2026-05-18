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
uniform float roughness_base : hint_range(0.0, 1.0) = 0.78;

void fragment() {
	vec4 tex = texture(albedo_texture, UV);
	ALBEDO = tex.rgb;
	ALPHA = tex.a;

	// With cull_disabled, the back face has its geometric normal flipped
	// relative to FRONT_FACING. We assigned outward vertex normals on the
	// CPU side; flip them on the back face so lighting is correct on both
	// sides of the wall. Matches building_wall_custom.gdshader convention.
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}

	ROUGHNESS = roughness_base;
	METALLIC = 0.0;
	SPECULAR = 0.5;
}
