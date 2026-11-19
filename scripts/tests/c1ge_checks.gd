extends Node

# C-1g-e: the scroll zoom, measured on the host alone (the camera is this
# screen's; nothing about it travels). What is checked: the zoom level moves
# the distance and the tilt together between (18 m, 55 deg) and (9 m, 35
# deg); the wheel steps it; the view never turns; and the mouse aim -- the
# click ray through a screen point, which cursor_jump_target() and
# _cursor_ground_point() build the same way -- lands on the ground exactly at
# every zoom: the physics hit is on the floor plane, and the hit projected
# back to the screen is the pixel it came from.

const HOME := Vector3(0.0, 0.9, 11.0)
const ZOOMS := [1.0, 0.5, 0.0]
# Screen points as fractions of the viewport: the centre, a ring around it,
# and the corners the far ray can still reach.
const POINTS := [
	Vector2(0.5, 0.5), Vector2(0.2, 0.5), Vector2(0.8, 0.5), Vector2(0.5, 0.2), Vector2(0.5, 0.8),
	Vector2(0.1, 0.1), Vector2(0.9, 0.1), Vector2(0.1, 0.9), Vector2(0.9, 0.9), Vector2(0.5, 0.05),
]
const PIXEL_TOLERANCE := 0.5
const METRE_TOLERANCE := 0.02

var _world: Node3D
var _local: Player
var _judge: ServerAuthority
var _peer_id := 0
var _checks := 0
var _failures := 0


func expect(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("C1GE_CHECK peer=%d %s %s" % [_peer_id, "PASS" if condition else "FAIL", label])


func note(line: String) -> void:
	print("C1GE_NOTE peer=%d %s" % [_peer_id, line])


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func tick_request(action: Callable) -> void:
	Net.queue_physics(action)
	for _frame in range(3):
		await get_tree().physics_frame


func run(world: Node3D) -> void:
	_world = world
	_peer_id = multiplayer.get_unique_id()
	_local = Net.spawn_root.get_node(str(_peer_id)) as Player
	_judge = world.get_node_or_null("ServerAuthority") as ServerAuthority
	if not multiplayer.is_server():
		return
	await _wait(1.0)
	await tick_request(func() -> void:
		if _judge != null:
			_judge.forgive_move(multiplayer.get_unique_id(), "")
		_local.global_position = HOME
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target()
		_local.movement.set_aim_override(Vector3.INF))
	await _wait(1.0)
	var zoom_was: float = Tuning.values.camera_zoom
	_data_checks()
	await _zoom_checks()
	await _aim_checks()
	await _wheel_checks()
	_local.camera.set_zoom_now(zoom_was)
	print("C1GE_RESULT peer=%d checks=%d failures=%d" % [_peer_id, _checks, _failures])
	await _wait(0.5)
	get_tree().quit(0 if _failures == 0 else 1)


# ------------------------------------------------- 1: the numbers

func _data_checks() -> void:
	var v := Tuning.values
	note("camera: zoom %.2f, distance %.1f m at %.0f deg; near %.2f x at %.0f deg; wheel step %.2f, smoothing %.1f" % [
		v.camera_zoom, v.camera_distance, v.camera_pitch_deg, v.camera_near_mult, v.camera_near_pitch_deg,
		v.camera_zoom_step, v.camera_zoom_smoothing])
	# 2026-11-17: far is 50 m of ground across (38.64 m away). 2026-11-18: the
	# nearest is 0.2 of that at 28.33 deg (it was 0.4 at 35), and the game
	# starts at zoom 0.325, which is the same view as before (below).
	expect(absf(v.camera_distance - 38.64) < 0.001 and absf(v.camera_pitch_deg - 55.0) < 0.001
		and absf(v.camera_near_mult - 0.2) < 0.001 and absf(v.camera_near_pitch_deg - 28.3333) < 0.001
		and absf(v.camera_zoom - 0.325) < 0.001,
		"the_defaults_are_38_64m_55deg_far_and_0_2_of_the_distance_at_28deg_near_starting_at_zoom_0_325")
	expect(absf(QuarterCamera.distance_for(v.camera_zoom) - 17.774) < 0.001
		and absf(QuarterCamera.pitch_deg_for(v.camera_zoom) - 37.0) < 0.001,
		"the_starting_view_is_17_77m_away_at_37deg")
	expect(absf(QuarterCamera.distance_for(1.0) - 38.64) < 0.001 and absf(QuarterCamera.pitch_deg_for(1.0) - 55.0) < 0.001
		and absf(QuarterCamera.distance_for(0.0) - 15.456) < 0.001 and absf(QuarterCamera.pitch_deg_for(0.0) - 35.0) < 0.001
		and absf(QuarterCamera.distance_for(0.5) - 27.048) < 0.001 and absf(QuarterCamera.pitch_deg_for(0.5) - 45.0) < 0.001,
		"distance_and_tilt_interpolate_together_on_the_one_zoom_number")
	var was: float = v.camera_near_pitch_deg
	v.camera_near_pitch_deg = 25.0
	var moved := absf(QuarterCamera.pitch_deg_for(0.0) - 25.0) < 0.001 and absf(QuarterCamera.pitch_deg_for(1.0) - 55.0) < 0.001
	v.camera_near_pitch_deg = was
	expect(moved, "the_near_tilt_is_the_slider_the_far_tilt_is_untouched_by_it")


# ------------------------------------------------- 2: the view at each zoom

func _zoom_checks() -> void:
	var camera := _local.camera
	for zoom: float in ZOOMS:
		camera.set_zoom_now(zoom)
		await _wait(0.4)
		var offset := camera.global_position - _local.global_position
		var pitch := rad_to_deg(atan2(offset.y, Vector2(offset.x, offset.z).length()))
		note("zoom %.1f: camera %.2f m from the body at %.1f deg (asked %.1f m / %.1f deg), rotation (%.1f, %.1f, %.1f)" % [
			zoom, offset.length(), pitch, QuarterCamera.distance_for(zoom), QuarterCamera.pitch_deg_for(zoom),
			rad_to_deg(camera.rotation.x), rad_to_deg(camera.rotation.y), rad_to_deg(camera.rotation.z)])
		expect(absf(offset.length() - QuarterCamera.distance_for(zoom)) < 0.05
			and absf(pitch - QuarterCamera.pitch_deg_for(zoom)) < 0.2,
			"at_zoom_%s_the_camera_sits_at_the_asked_distance_and_tilt" % _tag(zoom))
		expect(absf(camera.rotation.y) < 0.0001 and absf(camera.rotation.z) < 0.0001
			and absf(rad_to_deg(-camera.rotation.x) - QuarterCamera.pitch_deg_for(zoom)) < 0.01,
			"and_looks_down_at_that_tilt_with_no_turn_at_zoom_%s" % _tag(zoom))
	# The eased zoom: asked 1 -> 0 through the tuning value, the shown value
	# arrives within a second without overshoot.
	camera.set_zoom_now(1.0)
	await _wait(0.2)
	Tuning.values.camera_zoom = 0.0
	var lowest := 1.0
	var waited := 0.0
	while waited < 1.5:
		await get_tree().process_frame
		waited += get_process_delta_time()
		lowest = minf(lowest, camera.zoom_shown())
	note("eased zoom 1 -> 0: shown %.3f after %.1f s, lowest %.3f" % [camera.zoom_shown(), waited, lowest])
	expect(absf(camera.zoom_shown()) < 0.001 and lowest >= -0.0001, "the_shown_zoom_eases_to_the_asked_level_without_overshoot")


static func _tag(zoom: float) -> String:
	return ("%.1f" % zoom).replace(".", "_")


# ------------------------------------------------- 3: the mouse aim at each zoom

func _aim_checks() -> void:
	var camera := _local.camera
	var view := _local.get_viewport().get_visible_rect().size
	var floor_y := _local.global_position.y - _local.half_height()
	note("viewport %s, floor y %.2f, body at %s" % [view, floor_y, _local.global_position])
	for zoom: float in ZOOMS:
		camera.set_zoom_now(zoom)
		await _wait(0.4)
		var worst_px := 0.0
		var worst_m := 0.0
		var misses := 0
		var rows := []
		for fraction: Vector2 in POINTS:
			var pixel := Vector2(view.x * fraction.x, view.y * fraction.y)
			var from := camera.camera.project_ray_origin(pixel)
			var direction := camera.camera.project_ray_normal(pixel)
			# The plane the body stands on: what _cursor_ground_point() uses.
			var on_plane: Variant = Plane(Vector3.UP, floor_y).intersects_ray(from, direction)
			# The world: what cursor_jump_target() uses.
			var query := PhysicsRayQueryParameters3D.create(from, from + direction * 200.0, PlayerMovement.CLICK_MASK)
			query.collide_with_areas = false
			var hit := _local.get_world_3d().direct_space_state.intersect_ray(query)
			if on_plane == null or hit.is_empty():
				misses += 1
				rows.append("%s: MISS plane=%s hit=%s" % [fraction, on_plane != null, not hit.is_empty()])
				continue
			var hit_point: Vector3 = hit["position"]
			var back := camera.camera.unproject_position(hit_point)
			var px_error := back.distance_to(pixel)
			var m_error := hit_point.distance_to(on_plane as Vector3)
			worst_px = maxf(worst_px, px_error)
			worst_m = maxf(worst_m, m_error)
			rows.append("%s -> ground (%.2f, %.2f, %.2f) %.1f m out, back to screen off %.3f px, plane vs world %.3f m" % [
				fraction, hit_point.x, hit_point.y, hit_point.z,
				Vector2(hit_point.x - _local.global_position.x, hit_point.z - _local.global_position.z).length(), px_error, m_error])
		note("aim at zoom %.1f (%.1f m, %.0f deg): worst %.3f px, worst plane-vs-world %.3f m, misses %d" % [
			zoom, QuarterCamera.distance_for(zoom), QuarterCamera.pitch_deg_for(zoom), worst_px, worst_m, misses])
		for row in rows:
			note("   %s" % row)
		expect(misses == 0 and worst_px < PIXEL_TOLERANCE and worst_m < METRE_TOLERANCE,
			"at_zoom_%s_every_screen_point_lands_on_the_floor_under_its_own_pixel" % _tag(zoom))


# ------------------------------------------------- 4: the wheel

func _wheel_checks() -> void:
	# 2026-11-17: the wheel turns the view and no longer zooms; the middle
	# button steps the zoom near -> default -> far -> near.
	var camera := _local.camera
	var stops := camera.zoom_stops()
	camera.set_zoom_now(stops[1])
	await _wait(0.2)
	var steps := camera.wheel_steps
	var yaw_was := camera.yaw_deg
	var turn: float = Tuning.values.camera_turn_step_deg
	for _n in 3:
		_wheel(MOUSE_BUTTON_WHEEL_UP)
		await get_tree().process_frame
	_wheel(MOUSE_BUTTON_WHEEL_DOWN)
	await _wait(1.5)
	var zoom_after_wheel: float = Tuning.values.camera_zoom
	note("wheel: 3 up, 1 down -> yaw %.2f from %.2f (step %.1f), notches %d, zoom %.3f" % [
		camera.yaw_deg, yaw_was, turn, camera.wheel_steps - steps, zoom_after_wheel])
	expect(absf(camera.yaw_deg - (yaw_was + 2.0 * turn)) < 0.05 and camera.wheel_steps - steps == 4
		and absf(zoom_after_wheel - stops[1]) < 0.001,
		"the_wheel_turns_the_view_one_step_a_notch_and_does_not_zoom")
	var seen: Array[float] = []
	for _n in 3:
		_wheel(MOUSE_BUTTON_MIDDLE)
		await get_tree().process_frame
		seen.append(Tuning.values.camera_zoom)
	await _wait(0.8)
	note("middle button from the default: %s (stops %s), camera %.2f m / %.1f deg" % [
		seen, stops, camera.view_distance(), camera.view_pitch_deg()])
	expect(absf(seen[0] - stops[2]) < 0.001 and absf(seen[1] - stops[0]) < 0.001 and absf(seen[2] - stops[1]) < 0.001,
		"the_middle_button_steps_default_to_far_to_near_to_default")
	camera.set_yaw(yaw_was)


func _wheel(index: int) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = index
	event.pressed = true
	event.position = _local.get_viewport().get_visible_rect().size * 0.5
	Input.parse_input_event(event)
	Input.flush_buffered_events()
	var release := InputEventMouseButton.new()
	release.button_index = index
	release.pressed = false
	release.position = event.position
	Input.parse_input_event(release)
	Input.flush_buffered_events()
