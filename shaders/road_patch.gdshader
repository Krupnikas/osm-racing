shader_type spatial;
render_mode cull_back;

// Заплатка ямочного ремонта. Асфальт сэмплится в WORLD-SPACE тем же масштабом и тёплым
// тинтом, что и дорога (wet_road.gdshader) → щебёнка того же размера и та же температура,
// заплатка просто ТЕМНЕЕ. Форма и мягкая выпуклость — из shape-маски (UV квада).
uniform sampler2D asphalt_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D shape_tex : filter_linear_mipmap;              // .r = форма (alpha), scissor
uniform sampler2D shape_normal : hint_normal, filter_linear_mipmap;
uniform float asphalt_world_scale = 0.8;                          // как у дороги
uniform vec3 patch_tint = vec3(0.70, 0.63, 0.52);                // как albedo_tint дороги (линейный)
uniform float darken = 0.7;                                       // дополнительно темнее дороги
uniform float rough : hint_range(0.0, 1.0) = 0.85;
uniform float spec : hint_range(0.0, 1.0) = 0.15;                 // 0.15 матовая заплатка / выше — глянец битума

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float a = texture(shape_tex, UV).r;
	if (a < 0.5) {
		discard;                                                  // вырез по форме (как scissor)
	}
	vec2 auv = wpos.xz * asphalt_world_scale;                     // тот же world-space тайлинг, что у дороги
	ALBEDO = texture(asphalt_tex, auv).rgb * patch_tint * darken;
	ROUGHNESS = rough;
	METALLIC = 0.0;
	SPECULAR = spec;                                              // заплатка матовая / битум глянцевый
	NORMAL_MAP = texture(shape_normal, UV).rgb;                   // мягкая выпуклость
}
