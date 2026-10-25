shader_type spatial;
render_mode cull_disabled;

// The cut face of the time boundary: horizontal strata, as if a spade had gone
// straight down through the ground and the far half had been lifted.
//
// Bands are solved from the world y, not from the UV, so the stripes line up
// across every piece of the face and stay put when the mesh is resized. The
// dither block is the same one dither_fade.gdshader uses: this face is in the
// occluder group like any other wall, and the fader sets "fade" on whatever
// shader the wall happens to carry.

uniform vec4 low_color : source_color = vec4(0.38, 0.29, 0.21, 1.0);
uniform vec4 high_color : source_color = vec4(0.78, 0.69, 0.50, 1.0);
uniform vec4 seam_color : source_color = vec4(0.22, 0.16, 0.12, 1.0);
uniform float bands_per_metre = 6.0;
uniform float waviness = 0.07;
uniform float fade : hint_range(0.0, 1.0) = 1.0;

const float BAYER[16] = float[16](
	0.0 / 16.0, 8.0 / 16.0, 2.0 / 16.0, 10.0 / 16.0,
	12.0 / 16.0, 4.0 / 16.0, 14.0 / 16.0, 6.0 / 16.0,
	3.0 / 16.0, 11.0 / 16.0, 1.0 / 16.0, 9.0 / 16.0,
	15.0 / 16.0, 7.0 / 16.0, 13.0 / 16.0, 5.0 / 16.0
);

varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float band_noise(float n) {
	return fract(sin(n * 12.9898) * 43758.5453);
}

void fragment() {
	ivec2 pixel = ivec2(FRAGCOORD.xy) % 4;
	if (fade < BAYER[pixel.y * 4 + pixel.x]) {
		discard;
	}

	// Layers are never dead level in the ground, so neither are these.
	float wobble = (sin(world_position.x * 0.55) + sin(world_position.x * 1.63 + 1.7) * 0.4) * waviness;
	float height = (world_position.y + wobble) * bands_per_metre;
	float band = floor(height);
	float tone = band_noise(band);
	vec3 colour = mix(low_color.rgb, high_color.rgb, tone);
	// Thin dark line where two layers meet.
	float within = fract(height);
	float seam = min(smoothstep(0.0, 0.07, within), 1.0 - smoothstep(0.93, 1.0, within));
	colour = mix(seam_color.rgb, colour, seam);
	// Grit, so a 20 m wide face does not read as flat paint.
	colour *= 0.94 + 0.06 * band_noise(band * 3.1 + floor(world_position.x * 7.0));

	ALBEDO = colour;
	ROUGHNESS = 0.92;
}
