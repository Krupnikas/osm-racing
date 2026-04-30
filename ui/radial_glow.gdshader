// radial_glow.gdshader — soft Gaussian-like radial halo on a ColorRect.
// Renders a smooth glow blob that fades to transparent at the rect edges.
// Apply via ShaderMaterial on a ColorRect placed behind the bright element.
shader_type canvas_item;

uniform vec4  glow_color  : source_color = vec4(1.0, 0.17, 0.81, 1.0);
uniform float falloff_pow : hint_range(1.0, 12.0) = 4.0;
uniform float intensity   : hint_range(0.0, 4.0) = 1.0;

void fragment() {
	vec2  c = vec2(0.5);
	float d = distance(UV, c) * 2.0;
	float a = exp(-d * d * falloff_pow) * intensity;
	COLOR = vec4(glow_color.rgb, clamp(a, 0.0, 1.0));
}
