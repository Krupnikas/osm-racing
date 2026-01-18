shader_type spatial;
render_mode cull_disabled;

// Текстура стены
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap;
uniform vec4 albedo_color : source_color = vec4(0.7, 0.6, 0.5, 1.0);
uniform bool use_texture = false;

void fragment() {
	// Получаем цвет из текстуры или используем albedo_color
	vec4 tex_color = texture(albedo_texture, UV);
	if (use_texture) {
		ALBEDO = tex_color.rgb;
	} else {
		ALBEDO = albedo_color.rgb;
	}

	// Инвертируем нормаль для задних граней - это ключевое исправление!
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}

	// Стандартные параметры материала
	ROUGHNESS = 0.9;
	METALLIC = 0.0;
}
