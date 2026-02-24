shader_type spatial;
render_mode cull_disabled;

uniform sampler2D billboard_texture : source_color, filter_nearest;
uniform float alpha_scissor_threshold : hint_range(0.0, 1.0) = 0.5;

void fragment() {
	vec4 tex = texture(billboard_texture, UV);
	ALBEDO = tex.rgb;
	ALPHA = tex.a;
	ALPHA_SCISSOR_THRESHOLD = alpha_scissor_threshold;
}
