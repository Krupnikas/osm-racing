// Жажда Скорости screen background — vertical ink gradient + cyan/magenta
// radial glows. Drop on a full-rect ColorRect.
shader_type canvas_item;

void fragment() {
	vec2 uv = UV;

	// Vertical ink gradient: #07090e -> #0b0e14 -> #060810.
	vec3 top = vec3(0.027, 0.035, 0.055);
	vec3 mid = vec3(0.043, 0.055, 0.078);
	vec3 bot = vec3(0.024, 0.031, 0.063);
	vec3 col = (uv.y < 0.5)
		? mix(top, mid, uv.y * 2.0)
		: mix(mid, bot, (uv.y - 0.5) * 2.0);

	// Cyan ellipse glow at upper-left.
	vec2 c1 = (uv - vec2(0.20, 0.30)) / vec2(0.80, 0.60);
	float d1 = clamp(length(c1), 0.0, 1.0);
	col += vec3(0.0, 0.91, 1.0) * 0.10 * (1.0 - smoothstep(0.0, 1.0, d1));

	// Magenta ellipse glow at lower-right.
	vec2 c2 = (uv - vec2(0.85, 0.75)) / vec2(0.70, 0.50);
	float d2 = clamp(length(c2), 0.0, 1.0);
	col += vec3(1.0, 0.168, 0.815) * 0.10 * (1.0 - smoothstep(0.0, 1.0, d2));

	COLOR = vec4(col, 1.0);
}
