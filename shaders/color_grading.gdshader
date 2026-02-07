shader_type canvas_item;

// Color Grading для NFS Underground стиля
// Использует hint_screen_texture для чтения экрана

uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform float intensity : hint_range(0.0, 1.0) = 1.0;
uniform bool enabled = true;

// Дополнительные настройки для тонкой подстройки
uniform float contrast : hint_range(0.5, 2.0) = 1.0;
uniform float saturation : hint_range(0.0, 2.0) = 1.0;
uniform float brightness : hint_range(-0.5, 0.5) = 0.0;

// NFS Underground стиль - усиление синего/фиолетового в тенях, тёплые highlights
uniform float nfs_style_intensity : hint_range(0.0, 1.0) = 0.0;

vec3 apply_contrast(vec3 color, float amount) {
	return (color - 0.5) * amount + 0.5;
}

vec3 apply_saturation(vec3 color, float amount) {
	float gray = dot(color, vec3(0.299, 0.587, 0.114));
	return mix(vec3(gray), color, amount);
}

vec3 apply_nfs_style(vec3 color) {
	// NFS Underground стиль:
	// - Синие/фиолетовые тени
	// - Тёплые оранжевые highlights
	// - Общий контрастный look

	float luminance = dot(color, vec3(0.299, 0.587, 0.114));

	// Тени -> синий/фиолетовый сдвиг
	vec3 shadow_tint = vec3(0.1, 0.05, 0.2);  // Фиолетовый
	float shadow_amount = 1.0 - smoothstep(0.0, 0.4, luminance);

	// Highlights -> тёплый оранжевый сдвиг
	vec3 highlight_tint = vec3(0.15, 0.08, 0.0);  // Оранжевый
	float highlight_amount = smoothstep(0.6, 1.0, luminance);

	// Применяем tinting
	color += shadow_tint * shadow_amount * 0.3;
	color += highlight_tint * highlight_amount * 0.2;

	// Усиливаем контраст
	color = apply_contrast(color, 1.15);

	// Немного поднимаем saturation
	color = apply_saturation(color, 1.1);

	return color;
}

void fragment() {
	// Читаем экран через hint_screen_texture
	vec4 original = texture(screen_texture, SCREEN_UV);

	if (!enabled) {
		COLOR = original;
	} else {
		vec3 color = original.rgb;

		// Применяем базовые настройки
		color += brightness;
		color = apply_contrast(color, contrast);
		color = apply_saturation(color, saturation);

		// Применяем NFS стиль если включён
		if (nfs_style_intensity > 0.0) {
			vec3 nfs_color = apply_nfs_style(original.rgb);
			color = mix(color, nfs_color, nfs_style_intensity);
		}

		// Clamp для безопасности
		color = clamp(color, 0.0, 1.0);

		COLOR = vec4(color, 1.0);
	}
}
