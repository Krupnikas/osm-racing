shader_type sky;

// Crossfade between two panorama HDRI textures
uniform sampler2D panorama_current : filter_linear, repeat_disable;
uniform sampler2D panorama_next : filter_linear, repeat_disable;
uniform float blend : hint_range(0.0, 1.0) = 0.0;
uniform float exposure_current : hint_range(0.01, 8.0) = 1.0;
uniform float exposure_next : hint_range(0.01, 8.0) = 1.0;

void sky() {
	// SKY_COORDS — built-in equirectangular UV for panorama sampling
	vec3 col_cur = texture(panorama_current, SKY_COORDS).rgb * exposure_current;
	vec3 col_next = texture(panorama_next, SKY_COORDS).rgb * exposure_next;
	COLOR = mix(col_cur, col_next, blend);
}
