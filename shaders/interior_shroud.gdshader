shader_type spatial;
render_mode unshaded, depth_test_disabled, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;

// 건물 진입 a: a quad over the whole screen that blacks out every pixel whose
// place in the world is outside the building the local body is in. The place
// is read back from the depth buffer, so it covers whatever is out there
// (ground, other buildings, bodies, the sky) without knowing about any of it.
// Outside each door a strip of ground the door's width stays lit, fading out
// over `glimpse` metres.

const int MAX_ROOMS = 8;
const int MAX_DOORS = 8;
// How far under a floor and over a ceiling still counts as inside: the floor
// itself, and a body that jumps.
const float BELOW = 0.3;
const float ABOVE = 4.0;

uniform sampler2D depth_texture : hint_depth_texture, filter_nearest, repeat_disable;
uniform float amount : hint_range(0.0, 1.0) = 0.0;
uniform mat4 to_local;
uniform int room_count = 0;
uniform vec3 room_centre[MAX_ROOMS];
uniform vec3 room_half[MAX_ROOMS];
uniform vec2 near_sign = vec2(1.0, 1.0);
uniform float wall = 0.5;
uniform int door_count = 0;
// The middle of the doorway, the flat unit direction out of the building,
// and half the door's width and height.
uniform vec3 door_centre[MAX_DOORS];
uniform vec3 door_out[MAX_DOORS];
uniform vec2 door_half[MAX_DOORS];
uniform float glimpse = 3.0;

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

void fragment() {
	float depth = texture(depth_texture, SCREEN_UV).r;
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	vec3 ndc = vec3(SCREEN_UV, depth) * 2.0 - 1.0;
#else
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth);
#endif
	vec4 view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	view.xyz /= view.w;
	vec3 world = (INV_VIEW_MATRIX * vec4(view.xyz, 1.0)).xyz;
	vec3 at = (to_local * vec4(world, 1.0)).xyz;

	float shown = 0.0;
	for (int i = 0; i < room_count; i++) {
		vec3 q = at - room_centre[i];
		vec3 h = room_half[i];
		// The far walls are part of the picture; the near ones are not drawn,
		// and what shows through where they stood is outside.
		float sx = q.x * near_sign.x;
		float sz = q.z * near_sign.y;
		bool level = q.y > -(h.y + BELOW) && q.y < h.y + ABOVE;
		bool in_x = sx < h.x && sx > -(h.x + wall);
		bool in_z = sz < h.z && sz > -(h.z + wall);
		// A far wall is shown end to end, the posts at both its ends with it.
		bool far_x = sx <= -h.x && sx > -(h.x + wall) && sz < h.z + wall && sz > -(h.z + wall);
		bool far_z = sz <= -h.z && sz > -(h.z + wall) && sx < h.x + wall && sx > -(h.x + wall);
		if (level && ((in_x && in_z) || far_x || far_z)) {
			shown = 1.0;
		}
	}
	for (int i = 0; i < door_count; i++) {
		vec3 d = at - door_centre[i];
		vec2 out_flat = door_out[i].xz;
		float along = dot(d.xz, out_flat);
		float across = abs(dot(d.xz, vec2(-out_flat.y, out_flat.x)));
		if (across < door_half[i].x && along > -wall && along < glimpse + wall
				&& d.y > -(door_half[i].y + BELOW) && d.y < door_half[i].y) {
			shown = max(shown, 1.0 - clamp((along - wall) / max(glimpse, 0.01), 0.0, 1.0));
		}
	}
	ALBEDO = vec3(0.0);
	ALPHA = amount * (1.0 - shown);
}
