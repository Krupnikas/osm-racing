shader_type spatial;
render_mode cull_disabled;

uniform vec3 color1 : source_color = vec3(0.22, 0.47, 0.87);  // Синий
uniform vec3 color2 : source_color = vec3(0.85, 0.2, 0.5);    // Малиновый
uniform float stripe_width : hint_range(0.05, 0.5) = 0.15;
uniform float angle : hint_range(0.0, 90.0) = 45.0;

void fragment() {
	// Поворачиваем UV для диагональных полос
	float rad = radians(angle);
	float x = UV.x * cos(rad) - UV.y * sin(rad);

	// Создаём полосы
	float stripe = mod(x, stripe_width * 2.0);
	float t = step(stripe_width, stripe);

	vec3 color = mix(color1, color2, t);

	ALBEDO = color;
	ROUGHNESS = 0.3;
	METALLIC = 0.0;
	EMISSION = color * 0.2;
}
