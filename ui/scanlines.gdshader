// Full-screen overlay: scanlines + film noise + subtle vignette.
// Apply via: ColorRect (full screen) + ShaderMaterial.
shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;

uniform float scan_opacity   : hint_range(0.0, 1.0) = 0.55;
uniform float scan_density   : hint_range(1.0, 8.0) = 3.0;
uniform float noise_opacity  : hint_range(0.0, 1.0) = 0.40;
uniform float vignette       : hint_range(0.0, 1.0) = 0.35;
uniform float chroma_split   : hint_range(0.0, 8.0) = 0.0;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

void fragment() {
	vec2 uv = SCREEN_UV;

	float band = sin(FRAGCOORD.y * (3.14159 / scan_density));
	float scan = smoothstep(0.0, 1.0, abs(band));
	float scan_dim = 1.0 - scan_opacity * scan;

	float n = hash21(FRAGCOORD.xy + TIME * 60.0);
	float noise = (n - 0.5) * noise_opacity;

	vec2 vc = uv - 0.5;
	float v = 1.0 - dot(vc, vc) * vignette * 2.0;

	vec3 col = textureLod(screen_texture, uv, 0.0).rgb;
	if (chroma_split > 0.001) {
		float dx = chroma_split / SCREEN_PIXEL_SIZE.x * SCREEN_PIXEL_SIZE.x;
		col.r = textureLod(screen_texture, uv + vec2( dx, 0.0), 0.0).r;
		col.b = textureLod(screen_texture, uv - vec2( dx, 0.0), 0.0).b;
	}

	col *= scan_dim * v;
	col += noise;

	COLOR = vec4(col, 1.0);
}
