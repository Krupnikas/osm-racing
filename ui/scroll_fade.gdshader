// Bottom-fade overlay: same ink gradient as ScreenBg, alpha rises from
// transparent at the top to opaque at the bottom. Place at the bottom edge
// of a ScrollContainer area to mask scroll-out.
shader_type canvas_item;

uniform float screen_height = 1080.0;
uniform float overlay_top    = 880.0;  // y position where the overlay starts
uniform float fade_height    = 80.0;   // length of the fade ramp at the top

void fragment() {
	vec2 uv = UV;

	// Recompute the screen-y of this fragment so we can sample the
	// background gradient at the matching height.
	float global_y = (overlay_top + uv.y * fade_height) / screen_height;

	vec3 top = vec3(0.027, 0.035, 0.055);
	vec3 mid = vec3(0.043, 0.055, 0.078);
	vec3 bot = vec3(0.024, 0.031, 0.063);
	vec3 col = (global_y < 0.5)
		? mix(top, mid, global_y * 2.0)
		: mix(mid, bot, (global_y - 0.5) * 2.0);

	// Fade in the overlay alpha from 0 (top of overlay) to 1 (bottom).
	float a = smoothstep(0.0, 1.0, uv.y);
	COLOR = vec4(col, a);
}
