shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, unshaded;

// The seam itself: a thin pane standing just in front of the cut face. What it
// draws is the screen behind it, resampled a few pixels off, plus a glow along
// the cut line. Refraction rather than a painted effect, so the strata and the
// characters behind it are what is being bent and the seam cannot be mistaken
// for a decal.

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float wobble_strength : hint_range(0.0, 0.05) = 0.006;
uniform float wobble_speed = 0.7;
uniform vec4 glow_color : source_color = vec4(0.70, 0.90, 1.00, 1.0);
uniform float edge_width : hint_range(0.01, 0.5) = 0.10;
uniform float pane_alpha : hint_range(0.0, 1.0) = 0.85;

void fragment() {
	float t = TIME * wobble_speed;
	vec2 offset = vec2(
		sin(UV.y * 21.0 + t * 2.3) + sin(UV.x * 5.0 - t * 1.1) * 0.5,
		sin(UV.x * 13.0 - t * 1.7)) * wobble_strength;
	vec3 behind = texture(screen_tex, SCREEN_UV + offset).rgb;

	// UV.y 0 is the top of the quad: the cut line, which is the edge worth
	// lighting. The two ends get a weaker one so the pane does not stop dead.
	float top = 1.0 - smoothstep(0.0, edge_width, UV.y);
	float ends = max(1.0 - smoothstep(0.0, edge_width * 0.5, UV.x), smoothstep(1.0 - edge_width * 0.5, 1.0, UV.x));
	// A slow band of light travelling up the seam.
	float travelling = smoothstep(0.55, 1.0, sin(UV.y * 5.0 - t * 1.3) * 0.5 + 0.5);

	// Added, so it has to stay small: the strata behind are already a bright
	// sunlit surface and anything heavier burns the top of the cut to white.
	vec3 colour = behind + glow_color.rgb * (top * 0.30 + ends * 0.12 + travelling * 0.05);
	ALBEDO = colour;
	ALPHA = pane_alpha;
}
