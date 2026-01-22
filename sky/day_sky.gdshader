shader_type sky;

// Параметры неба
uniform vec3 sky_top_color : source_color = vec3(0.3, 0.5, 0.9);
uniform vec3 sky_horizon_color : source_color = vec3(0.6, 0.75, 0.95);
uniform vec3 ground_color : source_color = vec3(0.3, 0.35, 0.3);

// Параметры солнца
uniform vec3 sun_direction = vec3(-0.5, 0.7, 0.3);
uniform float sun_size : hint_range(0.01, 0.2) = 0.05;
uniform vec3 sun_color : source_color = vec3(1.0, 0.95, 0.8);

// Параметры облаков
uniform float cloud_coverage : hint_range(0.0, 1.0) = 0.4;
uniform float cloud_speed : hint_range(0.0, 0.1) = 0.01;
uniform vec3 cloud_color : source_color = vec3(1.0, 1.0, 1.0);
uniform vec3 cloud_shadow_color : source_color = vec3(0.7, 0.75, 0.85);

// Noise functions
float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);

	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));

	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
	float value = 0.0;
	float amplitude = 0.5;
	float frequency = 1.0;

	for (int i = 0; i < 5; i++) {
		value += amplitude * noise(p * frequency);
		amplitude *= 0.5;
		frequency *= 2.0;
	}

	return value;
}

float clouds(vec2 uv, float time) {
	vec2 cloud_uv = uv * 3.0 + vec2(time * cloud_speed, 0.0);

	float cloud_noise = fbm(cloud_uv);
	cloud_noise += 0.5 * fbm(cloud_uv * 2.0 + vec2(time * cloud_speed * 0.5, 0.0));

	// Применяем coverage
	float cloud = smoothstep(1.0 - cloud_coverage, 1.0 - cloud_coverage + 0.3, cloud_noise);

	return cloud;
}

void sky() {
	vec3 dir = normalize(EYEDIR);

	// Градиент неба
	float horizon = smoothstep(-0.1, 0.5, dir.y);
	vec3 sky = mix(sky_horizon_color, sky_top_color, horizon);

	// Земля под горизонтом
	if (dir.y < 0.0) {
		float ground_blend = smoothstep(0.0, -0.3, dir.y);
		sky = mix(sky_horizon_color, ground_color, ground_blend);
	}

	// Солнце
	vec3 sun_dir = normalize(sun_direction);
	float sun_dist = distance(dir, sun_dir);
	float sun = smoothstep(sun_size, sun_size * 0.7, sun_dist);
	float sun_glow = smoothstep(sun_size * 8.0, sun_size, sun_dist) * 0.3;

	sky += sun_color * sun * 2.0;
	sky += sun_color * sun_glow;

	// Облака (только выше горизонта)
	if (dir.y > 0.05) {
		// Проекция на плоскость облаков
		vec2 cloud_uv = dir.xz / (dir.y + 0.1);

		float cloud = clouds(cloud_uv, TIME);

		// Освещение облаков от солнца
		float cloud_sun = dot(normalize(vec3(cloud_uv.x, 1.0, cloud_uv.y)), sun_dir);
		vec3 lit_cloud = mix(cloud_shadow_color, cloud_color, smoothstep(-0.2, 0.5, cloud_sun));

		// Добавляем облака с fade к горизонту
		float cloud_fade = smoothstep(0.05, 0.3, dir.y);
		sky = mix(sky, lit_cloud, cloud * cloud_fade * 0.9);
	}

	// Атмосферное рассеяние у горизонта
	float scatter = pow(1.0 - abs(dir.y), 5.0) * 0.15;
	sky += vec3(0.9, 0.7, 0.5) * scatter;

	COLOR = sky;
}
