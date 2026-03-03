shader_type sky;

// Crossfade between two panorama HDRI textures
uniform sampler2D panorama_current : filter_linear, repeat_enable;
uniform sampler2D panorama_next : filter_linear, repeat_enable;
uniform float blend : hint_range(0.0, 1.0) = 0.0;
uniform float exposure_current : hint_range(0.01, 8.0) = 1.0;
uniform float exposure_next : hint_range(0.01, 8.0) = 1.0;
// Поворот панорамы по горизонту (доля от полного оборота, 0.083 ≈ 30°)
uniform float rotation : hint_range(-0.5, 0.5) = 0.0;

void sky() {
	vec2 uv = SKY_COORDS;
	uv.x = fract(uv.x + rotation);
	vec3 col_cur = texture(panorama_current, uv).rgb * exposure_current;
	vec3 col_next = texture(panorama_next, uv).rgb * exposure_next;
	COLOR = mix(col_cur, col_next, blend);
}
