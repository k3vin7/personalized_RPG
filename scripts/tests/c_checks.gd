extends Node

# Stage C, measured: the touch and the hold, the dash to the cursor, the one
# leap budget, the gap edge, and what a press costs in stamina. Plus stage C's
# other half -- how long a press takes to show on the screen that pressed it,
# now that the picture no longer waits for the ruling.
#
# Run at a latency with tools/udp_delay_proxy.py and --c-latency=<ms>.

const HOME := Vector3(0.0, 0.9, 11.0)
# The 2 m gap's lane. gap_start is z = -2, so the far block starts at z = -4.
const GAP_LANE_X := -15.0
const GAP_NEAR := Vector3(-15.0, 0.9, 1.0)
const GAP_TARGET := Vector3(-15.0, 0.0, -5.0)
# PlayerMovement.COYOTE_TIME plus a little: a press inside that window is a
# jump, not a catch.
const COYOTE_WAIT := 0.2

var _world: Node3D
var _local: Player
var _judge: ServerAuthority
var _peer_id := 0
var _checks := 0
var _failures := 0
var _stage_done := ""
# Read inside the physics step that pressed, because at no latency the server's
# answer is back within the three frames tick_request() waits.
var _saw_predicted := false
# Same reason: a value worked out inside a lambda comes back on a field.
var _plan := {}
var _lag := 0.0
var _label := "0"


func expect(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("C_CHECK lag=%s peer=%d %s %s" % [_label, _peer_id, "PASS" if condition else "FAIL", label])


func note(line: String) -> void:
	print("C_NOTE lag=%s peer=%d %s" % [_label, _peer_id, line])


func placed() -> void:
	if _judge == null:
		return
	if _judge.is_judge():
		_judge.forgive_move(multiplayer.get_unique_id(), "")
	else:
		_judge.harness_forgive_move.rpc_id(1)


func tick_request(action: Callable) -> void:
	Net.queue_physics(action)
	for _frame in range(3):
		await get_tree().physics_frame


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds + _lag * 3.0).timeout


# "Did it leave the ground", not "is it off the ground now": the waits grow
# with the latency and a jump is over in half a second, so a later look finds a
# body that has already landed.
func _left_the_ground(seconds := 1.2) -> bool:
	var waited := 0.0
	while waited < seconds:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		if _local.state == Player.State.AIRBORNE:
			return true
	return false


func _wait_stage(name_text: String) -> bool:
	var waited := 0.0
	while _stage_done != name_text and waited < 25.0 + _lag * 20.0:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	var arrived := _stage_done == name_text
	_stage_done = ""
	return arrived


func _client_peer() -> int:
	var peers := multiplayer.get_peers()
	return peers[0] if peers.size() > 0 else 0


func run(world: Node3D) -> void:
	_world = world
	_peer_id = multiplayer.get_unique_id()
	_local = Net.spawn_root.get_node(str(_peer_id)) as Player
	_judge = world.get_node_or_null("ServerAuthority") as ServerAuthority
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--c-latency="):
			_label = argument.trim_prefix("--c-latency=")
			_lag = _label.to_float() / 1000.0
	if not multiplayer.is_server():
		stage_done.rpc_id(1, "client_ready")
		return
	expect(await _wait_stage("client_ready"), "both_peers_present")
	var warnings := _judge.move_warnings
	await _jump_checks()
	await _dash_checks()
	await _rock_underfoot_check()
	await _air_space_checks()
	await _smart_key_checks()
	await _gap_edge_check()
	await _gap_width_checks()
	await _shadow_checks()
	await _stamina_check()
	await _client_feel_check()
	expect(_judge.move_warnings == warnings, "no_move_warnings_during_stage_c")
	print("C_RESULT lag=%s peer=%d checks=%d failures=%d" % [_label, _peer_id, _checks, _failures])
	finish.rpc(_failures)
	await _wait(1.0)
	get_tree().quit(0 if _failures == 0 else 1)


# ----------------------------------------------- the jump goes to the cursor

# Jumps at the given cursor point and reports what happened.
func _jump_at(home: Vector3, aim: Vector3) -> Dictionary:
	await tick_request(func() -> void:
		placed()
		_local.global_position = home
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target())
	await _wait(0.5)
	var floor_y := _local.global_position.y
	var launch := Vector3.ZERO
	var peak := floor_y
	var air := 0.0
	_plan = {}
	await tick_request(func() -> void:
		_local.movement.set_aim_override(aim)
		_plan = _local.movement.jump_plan(aim)
		_local.movement.cast_jump())
	var sampled := 0.0
	while sampled < 3.0:
		await get_tree().physics_frame
		sampled += get_physics_process_delta_time()
		if _local.state == Player.State.AIRBORNE:
			air += get_physics_process_delta_time()
		if launch == Vector3.ZERO and _local.state == Player.State.AIRBORNE:
			launch = _local.velocity
		peak = maxf(peak, _local.global_position.y)
		if launch != Vector3.ZERO and _local.is_grounded_state():
			break
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	var landed := _local.global_position
	return {
		"height": peak - floor_y,
		"air": air,
		"launch": launch,
		# Sampled on the first airborne frame, by which time the air step has
		# taken a step or two of gravity off it (22 m/s^2 / 120 Hz = 0.18 each).
		# The plan's launch is the exact one, so the cap is compared with that
		# and the sampled figure is reported beside it.
		"speed": launch.length(),
		"plan_speed": (_plan.get("launch", Vector3.ZERO) as Vector3).length(),
		"landed": landed,
		"miss": Vector2(landed.x - aim.x, landed.z - aim.z).length(),
		"travel": Vector2(landed.x - home.x, landed.z - home.z).length(),
		"plan": _plan,
	}


func _jump_checks() -> void:
	var cap := _local.leap_speed_cap()
	var reach := _local.leap_max_range()
	# Same direction, two distances: the near one has to be the lower one, and
	# both have to land where the cursor was.
	var near := await _jump_at(HOME, HOME + Vector3(2.0, 0.0, 0.0))
	var far := await _jump_at(HOME, HOME + Vector3(4.0, 0.0, 0.0))
	note("cursor jump: 2 m -> height %.2f air %.2fs launch %.2f miss %.2f | 4 m -> height %.2f air %.2fs launch %.2f miss %.2f (cap %.2f, reach %.2f, gravity %.1f)" % [
		near["height"], near["air"], near["plan_speed"], near["miss"],
		far["height"], far["air"], far["plan_speed"], far["miss"],
		cap, reach, Tuning.values.gravity])
	expect(float(near["height"]) < float(far["height"]) - 0.1, "a_nearer_cursor_is_a_lower_jump")
	expect(float(near["miss"]) < 0.3, "the_two_metre_jump_landed_on_the_cursor")
	expect(float(far["miss"]) < 0.3, "the_four_metre_jump_landed_on_the_cursor")

	# Under the feet: straight up, at the standing height.
	var standing := await _jump_at(HOME, HOME)
	note("cursor under the feet: height %.2f air %.2fs travel %.2f launch %.2f (sampled %.2f) (cap %.2f -> apex %.2f, inplace_radius %.2f)" % [
		standing["height"], standing["air"], standing["travel"], standing["plan_speed"], standing["speed"], cap,
		cap * cap / (2.0 * Tuning.values.gravity), Tuning.values.jump_inplace_radius])
	# The whole budget, upward: the apex a launch at the cap reaches.
	var cap_apex := cap * cap / (2.0 * Tuning.values.gravity)
	expect(absf(float(standing["height"]) - cap_apex) < 0.2, "the_in_place_jump_spends_the_whole_budget")
	expect(absf(float(standing["plan_speed"]) - cap) < 0.05, "and_launches_at_the_cap")
	expect(float(standing["travel"]) < 0.3, "the_in_place_jump_goes_nowhere_sideways")
	expect(float(standing["height"]) > float(far["height"]), "the_in_place_jump_is_the_highest")

	# Out of reach: as far as the budget goes, and the ring says so.
	var beyond := await _jump_at(HOME, HOME + Vector3(20.0, 0.0, 0.0))
	var plan: Dictionary = beyond["plan"]
	note("cursor 20 m away: travelled %.2f (reach %.2f) clamped=%s speed %.2f" % [
		beyond["travel"], reach, plan.get("clamped", false), beyond["speed"]])
	expect(bool(plan.get("clamped", false)), "an_unreachable_cursor_is_reported_as_clamped")
	expect(absf(float(beyond["travel"]) - reach) < 0.5, "it_jumped_as_far_as_the_budget_allows")
	# The ring is what a person sees for that. Armed, it is on the limit.
	await tick_request(func() -> void:
		_local.movement.set_aim_override(_local.global_position + Vector3(20.0, 0.0, 0.0))
		_local.movement.press_jump())
	await _wait(0.3)
	var indicator := _local.movement.aim_indicator()
	expect(indicator != null and indicator.is_showing(), "the_ring_is_shown_for_an_armed_jump")
	expect(indicator != null and indicator.landing_is_clamped(), "the_ring_marks_the_limit_not_the_cursor")
	await tick_request(func() -> void:
		_local.movement.cancel_armed()
		_local.movement.set_aim_override(Vector3.INF))

	# Onto a step, which is the landing-higher case.
	# A dot is not allowed in a node name, so the level's "Step_1.0" is called
	# this, and the boxes hang off the navigation region rather than the root.
	var step := _world.find_child("Step_1_0", true, false) as Node3D
	if step == null:
		expect(false, "the_one_metre_step_is_in_the_level")
		return
	# The aim is where the body origin should end up, which is a half height
	# above the surface it is standing on.
	var top := Vector3(step.global_position.x, 1.0 + Player.BODY_HALF_HEIGHT, step.global_position.z)
	var onto := await _jump_at(Vector3(top.x, 0.9, 11.0), top)
	note("onto the 1 m step: landed y=%.2f miss %.2f apex %.2f speed %.2f" % [
		(onto["landed"] as Vector3).y, onto["miss"], (onto["plan"] as Dictionary).get("apex", 0.0), onto["speed"]])
	expect((onto["landed"] as Vector3).y > 1.5, "the_jump_got_up_onto_the_step")
	expect(float(onto["miss"]) < 0.6, "and_landed_near_the_cursor_on_top_of_it")
	# A target this body can actually reach is never drawn as the limit: that
	# was the bug -- a 1 m step asked for an apex the budget could not pay for,
	# so the ring went orange while the jump worked, and the ring was drawn at
	# the cursor while the body landed short of it.
	expect(not bool((onto["plan"] as Dictionary).get("clamped", true)), "a_reachable_step_is_not_marked_as_the_limit")

	# What the height actually buys, measured on the level's own step ladder.
	# Reported rather than asserted: which steps a jump should reach is a
	# tuning decision, and this is the number it should be made from.
	for height in [0.5, 1.0, 1.5, 2.0]:
		var rung := _world.find_child("Step_%s" % String.num(float(height), 1).replace(".", "_"), true, false) as Node3D
		if rung == null:
			continue
		var rung_top := Vector3(rung.global_position.x, float(height) + Player.BODY_HALF_HEIGHT, rung.global_position.z)
		var tried := await _jump_at(Vector3(rung_top.x, 0.9, 11.0), rung_top)
		var landed_on: bool = (tried["landed"] as Vector3).y > float(height) + 0.5
		var rung_plan: Dictionary = tried["plan"]
		note("step ladder: %.1f m rung -> landed y=%.2f on_top=%s | apex %.2f launch %.2f/%.2f at_limit=%s" % [
			float(height), (tried["landed"] as Vector3).y, landed_on,
			rung_plan.get("apex", 0.0), tried["plan_speed"], cap,
			rung_plan.get("clamped", false)])

	expect(float(near["plan_speed"]) <= cap + 0.01 and float(far["plan_speed"]) <= cap + 0.01
		and float(standing["plan_speed"]) <= cap + 0.01 and float(beyond["plan_speed"]) <= cap + 0.01
		and float(onto["plan_speed"]) <= cap + 0.01, "every_launch_is_inside_the_cap")


# ------------------------------------------------- the dash is the same budget

func _dash_to(home: Vector3, cursor_distance: float) -> Dictionary:
	# dash_cooldown is a second: without waiting it out the next dash is
	# refused and the check measures a body standing still.
	await get_tree().create_timer(Tuning.values.dash_cooldown + 0.2).timeout
	await tick_request(func() -> void:
		placed()
		_local.global_position = home
		_local.velocity = Vector3.ZERO
		_local.stamina = Tuning.values.stamina_max
		_local.movement.cancel_target())
	await _wait(0.4)
	var from := _local.global_position
	var started := Time.get_ticks_usec()
	await tick_request(func() -> void:
		_local.movement.set_aim_override(from + Vector3(cursor_distance, 0.0, 0.0))
		_local.movement.request_dash())
	var elapsed := 0.0
	while elapsed < 1.5 and _local.movement.is_dashing():
		await get_tree().physics_frame
		elapsed += get_physics_process_delta_time()
	var took := float(Time.get_ticks_usec() - started) / 1000000.0
	await _wait(0.3)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	return {
		"distance": Vector2(_local.global_position.x - from.x, _local.global_position.z - from.z).length(),
		"seconds": took,
	}


func _dash_checks() -> void:
	var cap := _local.leap_speed_cap()
	var speed := _local.dash_speed()
	var reach := _local.movement.dash_max_distance()
	expect(absf(speed - cap * Tuning.values.dash_speed_mult) < 0.01, "the_dash_speed_is_the_cap_times_the_multiplier")
	# The dash and the longest jump cover the same ground.
	expect(absf(reach - _local.leap_max_range()) < 0.01, "the_dash_reaches_as_far_as_the_longest_jump")

	var asked_two := await _dash_to(HOME, 2.0)
	var asked_far := await _dash_to(HOME, 20.0)
	var asked_short := await _dash_to(HOME, 0.4)
	note("dash at strength 10: speed %.2f (= cap %.2f x %.1f) max %.2f m (= leap range) | cursor 2 m -> %.2f m in %.2f s | cursor 0.4 m -> %.2f m" % [
		speed, cap, Tuning.values.dash_speed_mult, reach,
		asked_two["distance"], asked_two["seconds"], asked_short["distance"]])
	note("dash full: %.2f m in %.2f s = %.1f m/s (stage C was 4.00 m in 0.18 s = 22.2 m/s)" % [
		asked_far["distance"], asked_far["seconds"],
		float(asked_far["distance"]) / maxf(float(asked_far["seconds"]), 0.01)])
	expect(absf(float(asked_two["distance"]) - 2.0) < 0.35, "cursor_two_metres_stops_at_two_metres")
	expect(absf(float(asked_far["distance"]) - reach) < 0.4, "a_far_cursor_stops_at_the_budget")
	expect(absf(float(asked_short["distance"]) - Tuning.values.dash_min_distance) < 0.35, "a_near_cursor_still_travels_the_minimum")

	# Strength is in the cap, so it moves the speed and the distance together.
	await tick_request(func() -> void: _local.stats.strength = 20.0)
	var strong_speed := _local.dash_speed()
	var strong_reach := _local.movement.dash_max_distance()
	var strong := await _dash_to(HOME, 20.0)
	note("dash at strength 20: speed %.2f (cap %.2f) max %.2f m -> travelled %.2f m in %.2f s" % [
		strong_speed, _local.leap_speed_cap(), strong_reach,
		strong["distance"], strong["seconds"]])
	expect(strong_speed > speed + 0.5, "strength_raises_the_dash_speed")
	expect(strong_reach > reach + 0.2, "strength_raises_the_dash_distance")
	expect(absf(float(strong["distance"]) - strong_reach) < 0.4, "the_longer_dash_is_actually_travelled")
	await tick_request(func() -> void: _local.stats.strength = 10.0)


# ------------------------- picking up the rock you are standing on top of

# Reported: standing on a rock and grabbing it sent the body up for ever. The
# rock is assigned hand_position() every step, so lifting it out from under its
# own holder swept the capsule up to hand height, which raised the hand, which
# swept it again -- about 200 m/s, climbing until something stopped it.
func _rock_underfoot_check() -> void:
	var rock := _world.get_node("Rock_2") as Rock          # the biggest, 20 kg
	var radius := Rock.radius_for(rock.weight)
	var spot := Vector3(6.0, radius, 2.0)
	await tick_request(func() -> void:
		placed()
		_judge.server_respawn(_local)
		rock.global_position = spot
		rock.linear_velocity = Vector3.ZERO
		rock.angular_velocity = Vector3.ZERO)
	await _wait(0.5)
	# Standing on top of it.
	await tick_request(func() -> void:
		placed()
		_local.global_position = rock.global_position + Vector3(0.0, radius + Player.BODY_HALF_HEIGHT, 0.0)
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target())
	await _wait(0.8)
	var stood_on := _local.global_position.y
	var grounded := _local.is_grounded_state()
	await tick_request(func() -> void:
		_local.movement.set_aim_override(rock.global_position)
		_local.movement.interact())
	var highest := _local.global_position.y
	var took := false
	var watched := 0.0
	while watched < 1.5:
		await get_tree().physics_frame
		watched += get_physics_process_delta_time()
		highest = maxf(highest, _local.global_position.y)
		took = took or _local.grab.is_holding()
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	note("rock underfoot: stood at y=%.2f (grounded=%s) -> took hold=%s, still holding=%s, highest y in 1.5 s = %.2f" % [
		stood_on, grounded, took, _local.grab.is_holding(), highest])
	expect(grounded, "the_body_was_standing_on_the_rock")
	# A metre of slack: the body does come off the rock's top, it just must not
	# be carried up by it.
	expect(highest < stood_on + 1.0, "grabbing_the_rock_underfoot_does_not_lift_the_body")
	# The hold is taken, and then ends on its own: lifting the rock takes away
	# the floor, and 7-6 says a holder that leaves the ground drops what it
	# carries. That is the rule working, not the bug.
	expect(took, "the_grab_itself_still_worked")
	await tick_request(func() -> void:
		if _local.grab.is_holding():
			_local.grab.drop())
	await _wait(0.6)


# ------------------------------- Space off the ground: the wall, and the dash

# The user-facing bug C-2 introduced: with the smart key off, a press in the
# air only armed a jump, so nothing ever reached the catch buffer and a body
# could not take hold of a wall any more. Space off the ground has three jobs
# and none of them is "aim"; this measures two of them.
func _air_space_checks() -> void:
	var wall := _world.find_child("ClimbWall_0", true, false) as Node3D
	if wall == null:
		expect(false, "the_climb_ring_is_in_the_level")
		return
	# Just off the wall's face, in the air, falling. The face is at z = 11.7
	# and a body stands a radius off it.
	var face_z: float = wall.global_position.z - 0.3
	var beside := Vector3(wall.global_position.x, 2.5, face_z - Player.BODY_RADIUS - 0.12)
	await tick_request(func() -> void:
		placed()
		_local.global_position = beside
		_local.velocity = Vector3(0.0, -0.5, 0.0)
		_local.floor_snap_length = 0.0
		_local.change_state(Player.State.AIRBORNE))
	# The coyote window has to close first. A body that was on the ground a
	# tenth of a second ago gets a jump out of the press, before the catch is
	# ever considered -- which is correct, and is not what this measures.
	await get_tree().create_timer(COYOTE_WAIT).timeout
	# Space, in the air, with the smart key off: this is a wall catch.
	var was: bool = Tuning.values.smart_key_enabled
	Tuning.values.smart_key_enabled = false
	Net.queue_physics(_local.movement.press_jump)
	var caught := false
	var waited := 0.0
	while waited < 1.2 and not caught:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		caught = _local.climb != null and _local.climb.is_climbing()
	note("space in the air: caught the wall=%s after %.2fs, state=%s, armed=%d" % [
		caught, waited, Player.State.keys()[_local.state], _local.movement.armed_action()])
	expect(caught, "space_in_the_air_takes_hold_of_a_wall")
	expect(_local.movement.armed_action() == PlayerMovement.Armed.NONE, "a_press_in_the_air_arms_nothing")
	if caught:
		await tick_request(func() -> void: _local.climb.detach(0.0))
		await _wait(1.0)

	# The whole path a person takes: stand in front of a wall, jump at it, and
	# press Space on the way in.
	var ground := Vector3(wall.global_position.x, 0.9, face_z - 2.0)
	var aim := Vector3(wall.global_position.x, 0.9, face_z - Player.BODY_RADIUS)
	await tick_request(func() -> void:
		placed()
		if _local.climb != null and _local.climb.is_climbing():
			_local.climb.detach(0.0)
		_local.global_position = ground
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target()
		_local.movement.set_aim_override(aim)
		_local.movement.cast_jump())
	var flown := 0.0
	var grabbed := false
	while flown < 2.0 and not grabbed:
		await get_tree().physics_frame
		flown += get_physics_process_delta_time()
		# Pressed as the wall comes into reach, which is what a person does.
		if _local.state == Player.State.AIRBORNE \
				and absf(_local.global_position.z - (face_z - Player.BODY_RADIUS)) < 0.5:
			_local.movement.press_jump()
		grabbed = _local.climb != null and _local.climb.is_climbing()
	note("jumped at the wall then pressed space: caught=%s after %.2fs at y=%.2f" % [
		grabbed, flown, _local.global_position.y])
	expect(grabbed, "jump_at_a_wall_then_space_takes_hold")
	await tick_request(func() -> void:
		if _local.climb != null and _local.climb.is_climbing():
			_local.climb.detach(0.0)
		_local.movement.set_aim_override(Vector3.INF))
	await _wait(1.0)

	# And Space during a dash is the dash jump, not an aim.
	await tick_request(func() -> void:
		placed()
		_local.global_position = HOME
		_local.velocity = Vector3.ZERO
		_local.stamina = Tuning.values.stamina_max
		_local.movement.cancel_target()
		_local.movement.set_aim_override(HOME + Vector3(8.0, 0.0, 0.0))
		_local.movement.request_dash())
	await get_tree().create_timer(0.08).timeout
	var dashing := _local.movement.is_dashing()
	Net.queue_physics(_local.movement.press_jump)
	var jumped := await _left_the_ground()
	var dash_launch := Vector3.ZERO
	var looked := 0.0
	while looked < 0.5 and dash_launch == Vector3.ZERO:
		await get_tree().physics_frame
		looked += get_physics_process_delta_time()
		if _local.state == Player.State.AIRBORNE:
			dash_launch = _local.velocity
	note("space during a dash: was dashing=%s, left the ground=%s, launch %.2f (dash speed %.2f, cap %.2f)" % [
		dashing, jumped, dash_launch.length(), _local.dash_speed(), _local.leap_speed_cap()])
	expect(dashing and jumped, "space_during_a_dash_is_the_dash_jump")
	# The dash runs at twice the budget; the jump out of it does not.
	expect(dash_launch.length() <= _local.leap_speed_cap() + 0.4, "a_dash_jump_is_cut_back_to_the_budget")
	await _wait(1.5)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	Tuning.values.smart_key_enabled = was


# ------------------------------------------------------- 5-chapter smart key

func _smart_key_checks() -> void:
	var was: bool = Tuning.values.smart_key_enabled
	# Off (the default): the key shows, the left button casts.
	Tuning.values.smart_key_enabled = false
	await tick_request(func() -> void:
		placed()
		_local.global_position = HOME
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target()
		_local.movement.set_aim_override(HOME + Vector3(3.0, 0.0, 0.0))
		_local.movement.press_jump())
	await _wait(0.3)
	var armed := _local.movement.armed_action()
	var showing := _local.movement.aim_indicator().is_showing()
	expect(armed == PlayerMovement.Armed.JUMP, "the_key_armed_the_jump_instead_of_casting_it")
	expect(showing, "arming_shows_where_it_would_go")
	expect(_local.state != Player.State.AIRBORNE, "nothing_was_cast_by_the_key_alone")
	# The left button casts it.
	Net.queue_physics(func() -> void: _local.movement.cast_armed())
	expect(await _left_the_ground(), "the_left_button_cast_it")
	expect(_local.movement.armed_action() == PlayerMovement.Armed.NONE, "casting_disarmed_it")
	expect(not _local.movement.aim_indicator().is_showing(), "casting_took_the_rings_away")
	await _wait(1.5)

	# And cancelling takes it back without casting.
	await tick_request(func() -> void:
		placed()
		_local.global_position = HOME
		_local.velocity = Vector3.ZERO
		_local.movement.set_aim_override(HOME + Vector3(3.0, 0.0, 0.0))
		_local.movement.press_dash())
	await _wait(0.3)
	expect(_local.movement.armed_action() == PlayerMovement.Armed.DASH, "the_dash_arms_the_same_way")
	await tick_request(func() -> void: _local.movement.cancel_armed())
	await _wait(0.3)
	expect(_local.movement.armed_action() == PlayerMovement.Armed.NONE
		and _local.state != Player.State.DASH, "cancelling_an_armed_action_casts_nothing")
	expect(not _local.movement.aim_indicator().is_showing(), "cancelling_took_the_rings_away")

	# The dash shows a line, not a ring: an arrow from here to where it goes.
	await tick_request(func() -> void:
		placed()
		_local.global_position = HOME
		_local.velocity = Vector3.ZERO
		_local.stamina = Tuning.values.stamina_max
		_local.movement.set_aim_override(HOME + Vector3(2.5, 0.0, 0.0))
		_local.movement.press_dash())
	await _wait(0.3)
	var arrow := _local.movement.aim_indicator()
	var reach := _local.movement.dash_max_distance()
	note("dash arrow: showing=%s length=%.2f (cursor 2.5 m, reach %.2f)" % [
		arrow.is_showing(), arrow.arrow_length(), reach])
	expect(arrow.is_showing() and absf(arrow.arrow_length() - 2.5) < 0.35, "the_dash_arrow_reaches_the_cursor")
	# Past the reach, the arrow stops at the limit and says so.
	await tick_request(func() -> void:
		_local.movement.set_aim_override(HOME + Vector3(20.0, 0.0, 0.0)))
	await _wait(0.3)
	note("dash arrow out of reach: length=%.2f clamped=%s" % [
		arrow.arrow_length(), arrow.landing_is_clamped()])
	expect(absf(arrow.arrow_length() - reach) < 0.35, "the_arrow_stops_at_the_dash_limit")
	expect(arrow.landing_is_clamped(), "and_is_marked_as_the_limit")
	await tick_request(func() -> void:
		_local.movement.cancel_armed()
		_local.movement.set_aim_override(Vector3.INF))
	await _wait(0.2)
	expect(not arrow.is_showing(), "cancelling_took_the_arrow_away")

	# On: the key is the cast.
	Tuning.values.smart_key_enabled = true
	Net.queue_physics(func() -> void:
		placed()
		_local.global_position = HOME
		_local.velocity = Vector3.ZERO
		_local.movement.set_aim_override(HOME + Vector3(3.0, 0.0, 0.0))
		_local.movement.press_jump())
	var cast_by_the_key := await _left_the_ground()
	note("smart key on: left the ground on the press alone=%s, armed=%d" % [
		cast_by_the_key, _local.movement.armed_action()])
	expect(cast_by_the_key, "with_the_smart_key_on_the_press_casts")
	expect(_local.movement.armed_action() == PlayerMovement.Armed.NONE, "nothing_is_left_armed")
	await _wait(1.5)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	Tuning.values.smart_key_enabled = was


# ------------------------------------------------------------- the gap edge

func _gap_edge_check() -> void:
	await tick_request(func() -> void:
		placed()
		_local.global_position = GAP_NEAR
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target())
	await _wait(0.8)
	# A click on the far side of the gap. There is no bridge over it any more,
	# so the path cannot reach and the body should stop at the lip.
	await tick_request(func() -> void: _local.movement.set_target(GAP_TARGET))
	# Watched rather than read at the end: the direction a blocked click leaves
	# behind expires after move_intent_timeout, so a late read finds nothing.
	var intent := Vector3.ZERO
	var watched := 0.0
	while watched < 3.0:
		await get_tree().physics_frame
		watched += get_physics_process_delta_time()
		if _local.movement.intent_direction().length() > intent.length():
			intent = _local.movement.intent_direction()
		if intent.length() > 0.5 and not _local.movement.has_target():
			break
	var stopped := _local.global_position
	note("gap edge: stopped at z=%.2f (lip is -2.00), intent=(%.2f, %.2f) after %.2fs (hop %.2f, ledge margin %.2f)" % [
		stopped.z, intent.x, intent.z, watched,
		Tuning.values.jump_min_hop_height, Tuning.values.jump_ledge_margin])
	expect(stopped.z > -2.6 and stopped.z < 0.6, "the_click_stopped_at_the_lip")
	expect(_local.state != Player.State.DEAD, "the_click_did_not_walk_it_off")
	expect(intent.length() > 0.5 and intent.z < -0.5, "the_blocked_click_left_its_direction_behind")
	# And Space crosses, aimed where the click was pointing.
	await tick_request(func() -> void:
		_local.movement.set_aim_override(GAP_TARGET)
		_local.movement.cast_jump())
	await _wait(2.5)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	note("after Space: z=%.2f y=%.2f state=%s" % [
		_local.global_position.z, _local.global_position.y, Player.State.keys()[_local.state]])
	expect(_local.global_position.z < -4.0 and _local.global_position.y > -1.0, "space_crossed_the_gap")


# ------------------------------------------------------ the blob under the feet

func _shadow_checks() -> void:
	var shadow := _local.get_node_or_null("FootShadow") as MeshInstance3D
	expect(shadow != null, "every_body_has_a_blob_under_it")
	if shadow == null:
		return
	# Cosmetic only: nothing to collide with, and on its own layer so a capture
	# can leave it out.
	var solid := false
	for child in shadow.get_children():
		solid = solid or child is CollisionObject3D
	expect(not solid and shadow.layers == Player.SHADOW_LAYER and shadow.top_level,
		"the_blob_is_render_only_on_its_own_layer")

	await tick_request(func() -> void:
		placed()
		_judge.server_respawn(_local)
		_local.global_position = HOME
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target())
	await _wait(0.6)
	var standing_gap := _local.global_position.y - Player.BODY_HALF_HEIGHT - shadow.global_position.y
	var standing_scale := shadow.scale.x
	# The blob stays on the floor while the body goes up, so the gap between
	# them is what reads as height.
	await tick_request(func() -> void:
		_local.movement.set_aim_override(HOME)
		_local.movement.cast_jump())
	var widest := standing_gap
	var smallest := standing_scale
	var sampled := 0.0
	while sampled < 1.0:
		await get_tree().physics_frame
		sampled += get_physics_process_delta_time()
		widest = maxf(widest, _local.global_position.y - Player.BODY_HALF_HEIGHT - shadow.global_position.y)
		smallest = minf(smallest, shadow.scale.x)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	note("foot blob: gap on the ground %.3f m -> %.2f m at the top of a jump, scale %.2f -> %.2f, y=%.2f" % [
		standing_gap, widest, standing_scale, smallest, shadow.global_position.y])
	expect(absf(standing_gap) < 0.1, "it_sits_at_the_feet_when_standing")
	expect(widest > 2.0, "it_stays_on_the_floor_while_the_body_rises")
	expect(smallest < standing_scale - 0.1, "and_shrinks_with_the_distance")
	await _wait(0.8)


# ------------------------------------------------- how wide a gap can be crossed

# The level has 2 / 3 / 4 / 5 m gaps. Reported rather than asserted beyond the
# 2 m one: how wide a gap should be crossable is a tuning decision, and this is
# the measurement it should be made from.
func _gap_width_checks() -> void:
	var lanes := {2.0: -15.0, 3.0: -5.0, 4.0: 5.0, 5.0: 15.0}
	for width in [2.0, 3.0, 4.0, 5.0]:
		var lane: float = lanes[width]
		# The near lip is z = -2; stand a little back from it.
		var start := Vector3(lane, 0.9, -1.2)
		# The far block starts at -2 - width; aim just onto it.
		var target := Vector3(lane, 0.9, -2.0 - float(width) - 0.5)
		await tick_request(func() -> void:
			placed()
			_judge.server_respawn(_local)
			_local.global_position = start
			_local.velocity = Vector3.ZERO
			_local.movement.cancel_target())
		await _wait(0.6)
		_plan = {}
		await tick_request(func() -> void:
			_local.movement.set_aim_override(target)
			_plan = _local.movement.jump_plan(target)
			_local.movement.cast_jump())
		await _wait(2.2)
		await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
		var crossed: bool = _local.global_position.z < -2.0 - float(width) \
			and _local.global_position.y > -1.0
		note("gap %.0f m: crossed=%s landed z=%.2f y=%.2f at_limit=%s (aim was %.2f m away)" % [
			float(width), crossed, _local.global_position.z, _local.global_position.y,
			_plan.get("clamped", false), absf(target.z - start.z)])
		if width == 2.0:
			expect(crossed, "the_two_metre_gap_is_crossed")
		if width == 4.0:
			expect(true, "the_four_metre_gap_was_measured")
	await tick_request(func() -> void:
		_judge.server_respawn(_local)
		placed()
		_local.global_position = HOME)
	await _wait(0.8)


# ---------------------------------------------------------------- stamina

func _stamina_check() -> void:
	await tick_request(func() -> void:
		placed()
		_local.global_position = HOME
		_local.velocity = Vector3.ZERO
		_local.stamina = Tuning.values.stamina_max
		_local.movement.cancel_target())
	await _wait(0.5
	)
	var before := _local.stamina
	# Read on the next step, not half a second later: stamina_regen puts 25 a
	# second back while the body is on the ground, which is more than the dash
	# costs by the time a slow check gets round to looking.
	await tick_request(func() -> void:
		_local.movement.set_aim_override(_local.global_position + Vector3(4.0, 0.0, 0.0))
		_local.movement.request_dash())
	var after := _local.stamina
	note("stamina: %.1f -> %.1f per dash (cost=%.1f, regen=%.1f/s)" % [
		before, after, Tuning.values.stamina_dash_cost, Tuning.values.stamina_regen])
	expect(before - after >= Tuning.values.stamina_dash_cost - 0.5, "a_dash_costs_stamina")
	# And with none left it does not go.
	await tick_request(func() -> void: _local.stamina = 1.0)
	var refused := true
	await tick_request(func() -> void:
		_local.movement._dash_cooldown_left = 0.0
		refused = not _local.movement.request_dash())
	expect(refused, "no_stamina_no_dash")
	await tick_request(func() -> void:
		_local.stamina = Tuning.values.stamina_max
		_local.movement.set_aim_override(Vector3.INF))


# --------------------------- stage C's other half: how fast a press shows

func _client_feel_check() -> void:
	var victim := _judge.actor_for(_client_peer())
	var rock := _world.get_node("Rock_1") as Rock
	_judge.forgive_move(_client_peer(), "")
	client_park.rpc_id(_client_peer(), Vector3(-13.0, 0.9, 13.0))
	expect(await _wait_stage("parked"), "client_parked")
	await _wait(0.8)
	await tick_request(func() -> void:
		rock.global_position = victim.global_position + Vector3(0.9, 0.3, 0.0))
	await _wait(0.6)
	client_feel.rpc_id(_client_peer(), rock.get_path())
	expect(await _wait_stage("felt"), "client_reported_what_it_felt")


# --------------------------------------------------------------------- RPCs

@rpc("any_peer", "call_remote", "reliable")
func stage_done(name_text: String) -> void:
	if multiplayer.is_server() and multiplayer.get_peers().has(multiplayer.get_remote_sender_id()):
		_stage_done = name_text


@rpc("any_peer", "call_remote", "reliable")
func report_feel(what: String, shown: int, applied: int) -> void:
	if multiplayer.is_server() and multiplayer.get_peers().has(multiplayer.get_remote_sender_id()):
		note("felt: %s shown after %d ms, applied after %d ms" % [what, shown, applied])
		# The whole point of the picture: it is on the screen in a frame or two
		# whatever the wire is doing.
		expect(shown <= 40, "%s_showed_within_a_couple_of_frames" % what)


@rpc("authority", "call_remote", "reliable")
func client_park(point: Vector3) -> void:
	await tick_request(func() -> void:
		placed()
		_local.global_position = point
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target()
		_local.movement.set_aim_override(Vector3.INF))
	await _wait(0.4)
	stage_done.rpc_id(1, "parked")


@rpc("authority", "call_remote", "reliable")
func client_feel(rock_path: NodePath) -> void:
	var rock := get_node(rock_path) as Rock
	# A grab: the lean shows at once, the hold arrives when the server says so.
	var pressed := Time.get_ticks_msec()
	var shown := -1
	_saw_predicted = false
	await tick_request(func() -> void:
		_local.movement.set_aim_override(rock.global_position)
		_local.movement.interact()
		_saw_predicted = _local.predicted_action != -1
		if _saw_predicted:
			shown = _local.predicted_at_msec - pressed)
	var waited := 0.0
	while waited < 5.0 and not _local.grab.is_holding():
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	expect(_saw_predicted, "the_grab_showed_in_the_frame_it_was_pressed")
	report_feel.rpc_id(1, "grab", maxi(shown, 0), Time.get_ticks_msec() - pressed)
	expect(_local.grab.is_holding(), "client_got_the_hold")
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))

	# A shove with nothing in reach: the server refuses it, and the refusal is
	# what takes the picture back rather than a timeout.
	await _wait(0.5)
	var refused_at := Time.get_ticks_msec()
	_saw_predicted = false
	await tick_request(func() -> void:
		_local.movement.set_aim_override(_local.global_position + Vector3(5.0, 0.0, 0.0))
		_local.movement.shove()
		_saw_predicted = _local.predicted_action != -1)
	var showed_refused := _saw_predicted
	waited = 0.0
	while waited < 3.0 and _local.predicted_action != -1:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	note("refused shove: shown=%s taken back after %d ms (timeout is %.0f ms)" % [
		showed_refused, Time.get_ticks_msec() - refused_at, Player.PREDICT_SHOW * 1000.0])
	expect(showed_refused, "a_refused_press_still_showed_at_once")
	expect(_local.predicted_action == -1, "the_refusal_took_the_picture_back")
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	stage_done.rpc_id(1, "felt")


@rpc("authority", "call_remote", "reliable")
func finish(host_failures: int) -> void:
	print("C_RESULT lag=%s peer=%d checks=%d failures=%d host_failures=%d" % [
		_label, _peer_id, _checks, _failures, host_failures])
	get_tree().quit(0 if _failures == 0 else 1)
