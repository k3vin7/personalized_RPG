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
	await _smart_key_checks()
	await _gap_edge_check()
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
	_plan = {}
	await tick_request(func() -> void:
		_local.movement.set_aim_override(aim)
		_plan = _local.movement.jump_plan(aim)
		_local.movement.cast_jump())
	var sampled := 0.0
	while sampled < 3.0:
		await get_tree().physics_frame
		sampled += get_physics_process_delta_time()
		if launch == Vector3.ZERO and _local.state == Player.State.AIRBORNE:
			launch = _local.velocity
		peak = maxf(peak, _local.global_position.y)
		if launch != Vector3.ZERO and _local.is_grounded_state():
			break
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	var landed := _local.global_position
	return {
		"height": peak - floor_y,
		"launch": launch,
		"speed": launch.length(),
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
	note("cursor jump: 2 m -> height %.2f miss %.2f speed %.2f | 4 m -> height %.2f miss %.2f speed %.2f (cap %.2f, reach %.2f)" % [
		near["height"], near["miss"], near["speed"],
		far["height"], far["miss"], far["speed"], cap, reach])
	expect(float(near["height"]) < float(far["height"]) - 0.1, "a_nearer_cursor_is_a_lower_jump")
	expect(float(near["miss"]) < 0.3, "the_two_metre_jump_landed_on_the_cursor")
	expect(float(far["miss"]) < 0.3, "the_four_metre_jump_landed_on_the_cursor")

	# Under the feet: straight up, at the standing height.
	var standing := await _jump_at(HOME, HOME)
	note("cursor under the feet: height %.2f travel %.2f speed %.2f (inplace_radius %.2f)" % [
		standing["height"], standing["travel"], standing["speed"], Tuning.values.jump_inplace_radius])
	expect(absf(float(standing["height"]) - _local.get_jump_height()) < 0.15, "the_in_place_jump_keeps_its_height")
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

	expect(float(near["speed"]) <= cap + 0.2 and float(far["speed"]) <= cap + 0.2
		and float(standing["speed"]) <= cap + 0.2 and float(beyond["speed"]) <= cap + 0.2
		and float(onto["speed"]) <= cap + 0.2, "every_launch_is_inside_the_cap")


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

	var asked_two := await _dash_to(HOME, 2.0)
	var asked_far := await _dash_to(HOME, 20.0)
	var asked_short := await _dash_to(HOME, 0.4)
	note("dash at strength 10: speed %.2f (cap %.2f) max %.2f m in %.2f s | cursor 2 m -> %.2f m in %.2f s | cursor 0.4 m -> %.2f m" % [
		speed, cap, reach, Tuning.values.dash_time_max,
		asked_two["distance"], asked_two["seconds"], asked_short["distance"]])
	note("dash vs stage C (4.00 m in 0.18 s = 22.2 m/s): now %.2f m in %.2f s = %.1f m/s" % [
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
	note("gap edge: stopped at z=%.2f (lip is -2.00), intent=(%.2f, %.2f) after %.2fs" % [
		stopped.z, intent.x, intent.z, watched])
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
