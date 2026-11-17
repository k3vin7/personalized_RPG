shader_type spatial;

// 건물 진입 b/c: the world's CSG surfaces. While the local body is inside a
// building, everything that is not that building's own floor or the lit
// strip outside one of its doors is left undrawn. Painting it black where
// it stands (the shroud) is not enough: a house between the camera and the
// room would cover the room with its black outline.
//
// The opened building's own walls and upper floors are not this shader's
// business any more (c): they are separate pieces that are simply hidden.
//
// Drawn only: the collider is the CSG's and is not touched. Thrown away on a
// dither pattern (as dither_fade does) so the change can be eased.

const int MAX_ROOMS = 8;
const int MAX_DOORS = 8;
const float BELOW = 0.3;
const float ABOVE = 4.0;

uniform vec4 albedo : source_color = vec4(1.0, 1.0, 1.0, 1.0);
// 0 = the world as it is, 1 = opened.
uniform float amount : hint_range(0.0, 1.0) = 0.0;
// World to the interior marker's space; the rooms are boxes on its axes.
uniform mat4 to_local;
uniform int room_count = 0;
uniform vec3 room_centre[MAX_ROOMS];
uniform vec3 room_half[MAX_ROOMS];
// Which side of the rooms the camera is on, per axis (+1 or -1).
uniform vec2 near_sign = vec2(1.0, 1.0);
uniform float wall = 0.5;
uniform int door_count = 0;
uniform vec3 door_centre[MAX_DOORS];
uniform vec3 door_out[MAX_DOORS];
uniform vec2 door_half[MAX_DOORS];
uniform float glimpse = 3.0;

varying vec3 world_at;

const float BAYER[16] = float[16](
	0.0 / 16.0, 8.0 / 16.0, 2.0 / 16.0, 10.0 / 16.0,
	12.0 / 16.0, 4.0 / 16.0, 14.0 / 16.0, 6.0 / 16.0,
	3.0 / 16.0, 11.0 / 16.0, 1.0 / 16.0, 9.0 / 16.0,
	15.0 / 16.0, 7.0 / 16.0, 13.0 / 16.0, 5.0 / 16.0
);
const float SKIN = 0.01;

void vertex() {
	world_at = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	if (amount > 0.0 && room_count > 0) {
		vec3 at = (to_local * vec4(world_at, 1.0)).xyz;
		bool hidden = false;
		// Kept: what lies in a room (its floor), under its far walls, or
		// in the strip outside a door. The same test the shroud makes.
		bool kept = false;
		for (int i = 0; i < room_count; i++) {
			vec3 q = at - room_centre[i];
			vec3 h = room_half[i];
			float sx = q.x * near_sign.x;
			float sz = q.z * near_sign.y;
			if (sx < h.x && sx > -(h.x + wall) && sz < h.z && sz > -(h.z + wall)
					&& q.y > -(h.y + BELOW) && q.y < h.y + ABOVE) {
				kept = true;
			}
		}
		for (int i = 0; i < door_count; i++) {
			vec3 d = at - door_centre[i];
			vec2 out_flat = door_out[i].xz;
			float along = dot(d.xz, out_flat);
			float across = abs(dot(d.xz, vec2(-out_flat.y, out_flat.x)));
			if (across < door_half[i].x && along > -wall && along < glimpse + wall
					&& d.y > -(door_half[i].y + BELOW) && d.y < door_half[i].y) {
				kept = true;
			}
		}
		hidden = !kept;
		if (hidden) {
			ivec2 pixel = ivec2(FRAGCOORD.xy) % 4;
			if (amount > BAYER[pixel.y * 4 + pixel.x]) {
				discard;
			}
		}
	}
	ALBEDO = albedo.rgb;
	ROUGHNESS = 1.0;
}
