shader_type spatial;
render_mode cull_disabled;

// Текстуры
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap, repeat_enable;

// Параметры материала
uniform vec4 base_color : source_color = vec4(0.25, 0.25, 0.25, 1.0);
uniform float normal_strength : hint_range(0.0, 2.0) = 0.3;
uniform bool use_texture = true;

// Параметры мокрой дороги
uniform bool is_wet = false;
uniform bool is_night = false;

// Roughness настройки
uniform float dry_roughness : hint_range(0.0, 1.0) = 0.85;
uniform float wet_roughness : hint_range(0.0, 1.0) = 0.15;
uniform float roughness_variation : hint_range(0.0, 0.3) = 0.1;

// Лужи
uniform float puddle_threshold : hint_range(0.0, 1.0) = 0.65;
uniform float puddle_roughness : hint_range(0.0, 0.1) = 0.02;
uniform float puddle_darkness : hint_range(0.0, 0.5) = 0.2;

// Metallic для отражений
uniform float dry_metallic : hint_range(0.0, 1.0) = 0.0;
uniform float wet_metallic : hint_range(0.0, 1.0) = 0.35;
uniform float puddle_metallic : hint_range(0.0, 1.0) = 0.5;

// Specular
uniform float dry_specular : hint_range(0.0, 1.0) = 0.5;
uniform float wet_specular : hint_range(0.0, 1.0) = 0.8;

// Noise масштаб для вариации
uniform float noise_scale : hint_range(0.1, 10.0) = 2.0;
uniform float noise_scale_large : hint_range(0.01, 1.0) = 0.15;

// Простой хэш для процедурного noise
float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// Smooth noise (value noise)
float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);

	// Smooth interpolation
	vec2 u = f * f * (3.0 - 2.0 * f);

	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));

	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// FBM (Fractal Brownian Motion) для более интересного шума
float fbm(vec2 p) {
	float value = 0.0;
	float amplitude = 0.5;
	float frequency = 1.0;

	for (int i = 0; i < 4; i++) {
		value += amplitude * noise(p * frequency);
		amplitude *= 0.5;
		frequency *= 2.0;
	}

	return value;
}

void fragment() {
	// Получаем albedo
	vec3 albedo;
	if (use_texture) {
		albedo = texture(albedo_texture, UV).rgb;
	} else {
		albedo = base_color.rgb;
	}

	// Получаем noise для вариации
	float noise_fine = fbm(UV * noise_scale * 10.0);  // Мелкий шум
	float noise_large = fbm(UV * noise_scale_large * 10.0);  // Крупный шум для луж

	// Комбинируем noise для естественного вида
	float combined_noise = noise_fine * 0.4 + noise_large * 0.6;

	// Базовые значения
	float roughness;
	float metallic;
	float specular;

	if (is_wet) {
		// === МОКРАЯ ДОРОГА ===

		// Базовый roughness с вариацией
		roughness = wet_roughness + (combined_noise - 0.5) * roughness_variation * 2.0;

		// Проверяем лужи (области с очень низким roughness)
		bool is_puddle = noise_large > puddle_threshold;

		if (is_puddle) {
			// ЛУЖА - очень гладкая, отражающая
			roughness = puddle_roughness;
			metallic = puddle_metallic;

			// Затемняем в лужах
			albedo *= (1.0 - puddle_darkness);

			// Добавляем лёгкий синий оттенок воды
			albedo = mix(albedo, vec3(0.1, 0.15, 0.2), 0.15);
		} else {
			// Обычная мокрая дорога
			metallic = wet_metallic;

			// Небольшое затемнение мокрой поверхности
			albedo *= 0.9;
		}

		specular = wet_specular;

		// Fresnel эффект для отражений под углом
		float fresnel = pow(1.0 - abs(dot(NORMAL, VIEW)), 3.0);
		metallic = mix(metallic, metallic + 0.2, fresnel);

		// Ночью усиливаем эффект
		if (is_night) {
			metallic += 0.1;
			roughness *= 0.8;  // Ещё более гладкая ночью
		}

	} else {
		// === СУХАЯ ДОРОГА ===

		// Небольшая вариация roughness даже на сухой дороге
		roughness = dry_roughness + (noise_fine - 0.5) * 0.1;
		metallic = dry_metallic;
		specular = dry_specular;
	}

	// Clamp значения
	roughness = clamp(roughness, 0.01, 1.0);
	metallic = clamp(metallic, 0.0, 1.0);

	// Выход
	ALBEDO = albedo;
	ROUGHNESS = roughness;
	METALLIC = metallic;
	SPECULAR = specular;

	// Normal map
	NORMAL_MAP = texture(normal_texture, UV).rgb;
	NORMAL_MAP_DEPTH = normal_strength;
}
