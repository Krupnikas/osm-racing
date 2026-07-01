shader_type sky;

// Crossfade between two panorama HDRI textures
uniform sampler2D panorama_current : filter_linear, repeat_enable;
uniform sampler2D panorama_next : filter_linear, repeat_enable;
uniform float blend : hint_range(0.0, 1.0) = 0.0;
uniform float exposure_current : hint_range(0.01, 8.0) = 1.0;
uniform float exposure_next : hint_range(0.01, 8.0) = 1.0;
// Поворот панорамы по горизонту (доля от полного оборота, 0.083 ≈ 30°)
uniform float rotation : hint_range(-0.5, 0.5) = 0.0;

// --- Полоса горизонта (Tier 1 «A»): дымка + низкая рваная лесополоса, ---
// --- чтобы заполнить пустой дальний край за радиусом загрузки чанков.  ---
// TIME здесь НЕ используется → небо остаётся статичным (дешёвый radiance).
uniform vec3 horizon_haze_color : source_color = vec3(0.72, 0.75, 0.80);
uniform float horizon_haze_strength : hint_range(0.0, 1.0) = 0.30;
uniform float horizon_haze_height : hint_range(0.02, 0.4) = 0.12;
uniform vec3 treeline_color : source_color = vec3(0.20, 0.23, 0.21);
uniform float treeline_top : hint_range(0.0, 0.1) = 0.012;
uniform float treeline_jitter : hint_range(0.0, 0.06) = 0.028;
uniform float treeline_strength : hint_range(0.0, 1.0) = 0.75;
uniform float treeline_aerial : hint_range(0.0, 1.0) = 0.55;

float h11(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = h11(i);
	float b = h11(i + vec2(1.0, 0.0));
	float c = h11(i + vec2(0.0, 1.0));
	float d = h11(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}
float fbm2(vec2 p) {
	float v = 0.0;
	float amp = 0.5;
	float fr = 1.0;
	for (int i = 0; i < 4; i++) {
		v += amp * vnoise(p * fr);
		amp *= 0.5;
		fr *= 2.0;
	}
	return v;
}

void sky() {
	vec2 uv = SKY_COORDS;
	uv.x = fract(uv.x + rotation);
	vec3 col_cur = texture(panorama_current, uv).rgb * exposure_current;
	vec3 col_next = texture(panorama_next, uv).rgb * exposure_next;
	vec3 col = mix(col_cur, col_next, blend);

	vec3 dir = normalize(EYEDIR);

	// Дымка у горизонта: сгущаем небо к линии горизонта, чтобы даль «сливалась».
	float haze = pow(clamp(1.0 - abs(dir.y) / horizon_haze_height, 0.0, 1.0), 2.0);
	col = mix(col, horizon_haze_color, haze * horizon_haze_strength);

	// Низкая рваная лесополоса, прижатая к горизонту. Рисуется на куполе неба →
	// перекрывается ближними зданиями и видна только в открытом дальнем крае.
	float az = atan(dir.x, dir.z);                 // азимут вокруг купола
	float jitter = fbm2(vec2(az * 2.2, 0.0));      // «зубчатость» верхушки
	float top = treeline_top + jitter * treeline_jitter;
	float tree = smoothstep(top, top - 0.008, dir.y) * smoothstep(-0.004, 0.003, dir.y);
	vec3 tcol = mix(treeline_color, horizon_haze_color, treeline_aerial); // аэроперспектива
	col = mix(col, tcol, tree * treeline_strength);

	COLOR = col;
}
