// gauss_blur.gdshader — 1D directional Gaussian. Use TWICE: once with
// axis=(1,0) for horizontal pass, once with axis=(0,1) for vertical.
// Equivalent to a 2D Gaussian via separability — no grid artefact.
shader_type canvas_item;

uniform float blur_radius : hint_range(0.0, 256.0) = 32.0;
uniform float intensity   : hint_range(0.0, 8.0)   = 1.0;
uniform vec2  axis        = vec2(1.0, 0.0);

const int N = 24;

void fragment() {
	vec2 px = TEXTURE_PIXEL_SIZE;
	vec4 acc = vec4(0.0);
	float total = 0.0;
	for (int i = -N; i <= N; i++) {
		float fi = float(i);
		float t  = fi / float(N);
		float w  = exp(-t * t * 4.5);
		vec2 off = axis * fi * (blur_radius / float(N)) * px;
		acc   += texture(TEXTURE, UV + off) * w;
		total += w;
	}
	COLOR = (acc / total) * vec4(1.0, 1.0, 1.0, intensity);
}
