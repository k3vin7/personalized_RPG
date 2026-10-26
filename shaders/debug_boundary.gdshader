shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled;

void fragment() {
	ALBEDO = vec3(1.0, 0.05, 0.03);
	// Quad UV.y is zero at the top: the marker fades upward.
	ALPHA = 0.5 * UV.y * UV.y;
}
