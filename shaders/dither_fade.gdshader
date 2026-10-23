shader_type spatial;
render_mode cull_disabled;

// Fading by throwing pixels away on an ordered dither pattern instead of by
// alpha blending. Alpha would need the walls sorted against each other and
// against the character, which goes wrong the moment two faded walls overlap.

uniform vec4 albedo : source_color = vec4(0.45, 0.47, 0.5, 1.0);
uniform float fade : hint_range(0.0, 1.0) = 1.0;
uniform float roughness_value : hint_range(0.0, 1.0) = 0.8;

const float BAYER[16] = float[16](
	0.0 / 16.0, 8.0 / 16.0, 2.0 / 16.0, 10.0 / 16.0,
	12.0 / 16.0, 4.0 / 16.0, 14.0 / 16.0, 6.0 / 16.0,
	3.0 / 16.0, 11.0 / 16.0, 1.0 / 16.0, 9.0 / 16.0,
	15.0 / 16.0, 7.0 / 16.0, 13.0 / 16.0, 5.0 / 16.0
);

void fragment() {
	ivec2 pixel = ivec2(FRAGCOORD.xy) % 4;
	float threshold = BAYER[pixel.y * 4 + pixel.x];
	if (fade < threshold) {
		discard;
	}
	ALBEDO = albedo.rgb;
	ROUGHNESS = roughness_value;
}
