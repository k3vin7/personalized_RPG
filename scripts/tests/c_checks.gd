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
	await _tap_and_hold_check()
	await _dash_checks()
	await _leap_budget_check()
	await _gap_edge_check()
	await _stamina_check()
	await _client_feel_check()
	expect(_judge.move_warnings == warnings, "no_move_warnings_during_stage_c")
	print("C_RESULT lag=%s peer=%d checks=%d failures=%d" % [_label, _peer_id, _checks, _failures])
	finish.rpc(_failures)
	await _wait(1.0)
	get_tree().quit(0 if _failures == 0 else 1)


# ------------------------------------------------------- the touch and the hold

# Returns the height gained and the launch speed.
# tap: let go the moment the body is in the air, which is what a touch is.
# Otherwise the key is held for the whole rise.
func _jump_from(home: Vector3, aim: Vector3, tap: bool) -> Dictionary:
	await tick_request(func() -> void:
		placed()
		_local.global_position = home
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target())
	await _wait(0.5)
	var floor_y := _local.global_position.y
	await tick_request(func() -> void:
		_local.movement.set_aim_override(aim)
		_local.movement.press_jump())
	# Sampled from the launch: the speed on the first airborne frame is the
	# whole of what the leap budget was spent on.
	var launch := Vector3.ZERO
	var peak := floor_y
	var sampled := 0.0
	while sampled < 2.5:
		await get_tree().physics_frame
		sampled += get_physics_process_delta_time()
		if launch == Vector3.ZERO and _local.state == Player.State.AIRBORNE:
			launch = _local.velocity
			if tap:
				# Released on the launch frame. The cut lands on the next step,
				# by which time the body has risen a centimetre or two -- which
				# is why a touch measures a little over its share.
				_local.movement.release_jump()
		peak = maxf(peak, _local.global_position.y)
		if launch != Vector3.ZERO and _local.is_grounded_state():
			break
	await tick_request(func() -> void:
		_local.movement.release_jump()
		_local.movement.set_aim_override(Vector3.INF))
	return {
		"height": peak - floor_y,
		"launch": launch,
		"travel": Vector2(_local.global_position.x - home.x, _local.global_position.z - home.z).length(),
	}


func _tap_and_hold_check() -> void:
	# The cursor on our own feet is how a jump straight up is asked for.
	var held := await _jump_from(HOME, HOME, false)
	var tapped := await _jump_from(HOME, HOME, true)
	var ratio: float = float(tapped["height"]) / maxf(float(held["height"]), 0.01)
	note("jump height: hold=%.2f m tap=%.2f m ratio=%.2f (tuning=%.2f, hold_time=%.2f)" % [
		held["height"], tapped["height"], ratio,
		Tuning.values.jump_tap_height_ratio, Tuning.values.jump_hold_time])
	expect(float(held["height"]) > float(tapped["height"]) + 0.2, "a_touch_lifts_less_than_a_hold")
	# Cut after up to a frame of rising, so the tap lands a little over its share.
	expect(ratio > Tuning.values.jump_tap_height_ratio - 0.1 and ratio < Tuning.values.jump_tap_height_ratio + 0.25,
		"touch_height_matches_the_tuning_ratio")


# ----------------------------------------------------------------- the dash

func _dash_to(home: Vector3, cursor_distance: float) -> float:
	await tick_request(func() -> void:
		placed()
		_local.global_position = home
		_local.velocity = Vector3.ZERO
		_local.stamina = Tuning.values.stamina_max
		_local.movement.cancel_target())
	await _wait(0.4)
	var from := _local.global_position
	await tick_request(func() -> void:
		_local.movement.set_aim_override(from + Vector3(cursor_distance, 0.0, 0.0))
		_local.movement.request_dash())
	await _wait(0.6)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	return Vector2(_local.global_position.x - from.x, _local.global_position.z - from.z).length()


func _dash_checks() -> void:
	# The cursor decides, between the floor and the ceiling.
	var asked_two := await _dash_to(HOME, 2.0)
	var asked_far := await _dash_to(HOME, 20.0)
	var asked_short := await _dash_to(HOME, 0.4)
	note("dash: cursor 2 m -> %.2f m | cursor 20 m -> %.2f m (max=%.2f) | cursor 0.4 m -> %.2f m (min=%.2f)" % [
		asked_two, asked_far, _local.movement.dash_max_distance(),
		asked_short, Tuning.values.dash_min_distance])
	expect(absf(asked_two - 2.0) < 0.35, "cursor_two_metres_stops_at_two_metres")
	expect(absf(asked_far - _local.movement.dash_max_distance()) < 0.35, "a_far_cursor_stops_at_the_strength_limit")
	expect(absf(asked_short - Tuning.values.dash_min_distance) < 0.35, "a_near_cursor_still_travels_the_minimum")

	# Strength moves the ceiling, which is what the debug slider is for.
	var weak_max := _local.movement.dash_max_distance()
	await tick_request(func() -> void: _local.stats.strength = 20.0)
	var strong_max := _local.movement.dash_max_distance()
	var strong := await _dash_to(HOME, 20.0)
	note("dash max: strength 10 -> %.2f m, strength 20 -> %.2f m (travelled %.2f)" % [
		weak_max, strong_max, strong])
	expect(strong_max > weak_max + 0.3, "strength_raises_the_dash_ceiling")
	expect(absf(strong - strong_max) < 0.4, "the_longer_dash_is_actually_travelled")
	await tick_request(func() -> void: _local.stats.strength = 10.0)


# ------------------------------------------------------------ the leap budget

func _leap_budget_check() -> void:
	var cap := _local.movement.leap_speed_cap()
	var standing := await _jump_from(HOME, HOME, false)
	var aimed := await _jump_from(HOME, HOME + Vector3(8.0, 0.0, 0.0), false)
	# Out of a dash: the jump is pressed while the dash is still running.
	await tick_request(func() -> void:
		placed()
		_local.global_position = HOME
		_local.velocity = Vector3.ZERO
		_local.stamina = Tuning.values.stamina_max
		_local.movement.cancel_target())
	await _wait(0.5)
	var from := _local.global_position
	var dash_launch := Vector3.ZERO
	var dash_peak := from.y
	await tick_request(func() -> void:
		_local.movement.set_aim_override(from + Vector3(8.0, 0.0, 0.0))
		_local.movement.request_dash())
	await get_tree().create_timer(0.06).timeout
	await tick_request(func() -> void: _local.movement.press_jump())
	var sampled := 0.0
	while sampled < 2.5:
		await get_tree().physics_frame
		sampled += get_physics_process_delta_time()
		if dash_launch == Vector3.ZERO and _local.state == Player.State.AIRBORNE:
			dash_launch = _local.velocity
		dash_peak = maxf(dash_peak, _local.global_position.y)
		if dash_launch != Vector3.ZERO and _local.is_grounded_state():
			break
	await tick_request(func() -> void:
		_local.movement.release_jump()
		_local.movement.set_aim_override(Vector3.INF))
	var dash_travel := Vector2(_local.global_position.x - from.x, _local.global_position.z - from.z).length()

	var standing_speed: float = (standing["launch"] as Vector3).length()
	var aimed_speed: float = (aimed["launch"] as Vector3).length()
	var dash_speed := dash_launch.length()
	note("leap cap=%.2f | standing: height=%.2f speed=%.2f | aimed: travel=%.2f speed=%.2f | dash jump: travel=%.2f height=%.2f speed=%.2f" % [
		cap, standing["height"], standing_speed, aimed["travel"], aimed_speed,
		dash_travel, dash_peak - from.y, dash_speed])
	expect(standing_speed <= cap + 0.2 and aimed_speed <= cap + 0.2 and dash_speed <= cap + 0.2,
		"every_launch_is_inside_the_cap")
	expect(float(standing["height"]) > dash_peak - from.y + 0.2, "the_standing_jump_is_the_highest")
	expect(dash_travel > float(aimed["travel"]) + 0.1 and dash_travel > float(standing["travel"]),
		"the_dash_jump_is_the_furthest")


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
		_local.movement.press_jump())
	await _wait(2.5)
	await tick_request(func() -> void:
		_local.movement.release_jump()
		_local.movement.set_aim_override(Vector3.INF))
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
