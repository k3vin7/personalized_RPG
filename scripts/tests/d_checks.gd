extends Node

# Stage D, measured: the shove as a rectangle, in the air, with a recoil; the
# brace; a team mate launched off a push; a head as a platform; and the two
# things the work order asks for beside them -- whether the 5 m gap can be
# crossed by two players together, and how far a dash jump reaches.

const HOME := Vector3(0.0, 0.9, 11.0)
const LANE := Vector3(-13.0, 0.9, 9.0)
# The 5 m gap: lane x = 15, near lip z = -2, far block from z = -7.
const GAP5_LANE := 15.0
const GAP5_START := Vector3(15.0, 0.9, -1.2)
const GAP5_FAR := -7.0

var _world: Node3D
var _local: Player
var _judge: ServerAuthority
var _peer_id := 0
var _checks := 0
var _failures := 0
var _stage_done := ""
var _lag := 0.0
var _label := "0"
var _reported := {}
var _hits := 0


func expect(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("D_CHECK lag=%s peer=%d %s %s" % [_label, _peer_id, "PASS" if condition else "FAIL", label])


func note(line: String) -> void:
	print("D_NOTE lag=%s peer=%d %s" % [_label, _peer_id, line])


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


# For sampling a body on this machine, where the wire is not involved: padding
# these by the latency means reading a body that has already landed.
func _beat(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


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
		if argument.begins_with("--d-latency="):
			_label = argument.trim_prefix("--d-latency=")
			_lag = _label.to_float() / 1000.0
	if not multiplayer.is_server():
		stage_done.rpc_id(1, "client_ready")
		return
	expect(await _wait_stage("client_ready"), "both_peers_present")
	var warnings := _judge.move_warnings
	await _event_shape_checks()
	await _rectangle_checks()
	await _air_and_recoil_checks()
	await _brace_checks()
	await _ally_launch_checks()
	await _dummy_air_check()
	await _head_platform_checks()
	await _gap5_coop_check()
	await _dash_jump_range_check()
	expect(_judge.move_warnings == warnings, "no_move_warnings_during_stage_d")
	print("D_RESULT lag=%s peer=%d checks=%d failures=%d" % [_label, _peer_id, _checks, _failures])
	finish.rpc(_failures)
	await _wait(1.0)
	get_tree().quit(0 if _failures == 0 else 1)


# -------------------------------------- the event: an id, a time, a recoil kind

func _event_shape_checks() -> void:
	var event := ForceSystem.make_event(
		ForceSystem.Kind.RECOIL, Vector3.RIGHT, 1.0, 10.0, 1, true)
	var second := ForceSystem.make_event(
		ForceSystem.Kind.SHOVE, Vector3.RIGHT, 1.0, 10.0, 1, true)
	note("event ids %d then %d, at %.2f s, RECOIL=%d" % [
		event["id"], second["id"], event["at"], ForceSystem.Kind.RECOIL])
	expect(int(second["id"]) > int(event["id"]) and int(event["id"]) > 0, "every_event_has_its_own_id")
	expect(float(event["at"]) > 0.0, "and_the_time_it_was_made")
	var before := _judge.force_history.size()
	await tick_request(func() -> void:
		_judge.send_force(_local, ForceSystem.make_event(
			ForceSystem.Kind.KNOCKBACK, Vector3.UP, 1.0, 0.0, 1, true)))
	await _wait(0.3)
	expect(_judge.force_history.size() > before, "the_server_keeps_a_history_of_what_it_sent")
	var last: Dictionary = _judge.force_history[_judge.force_history.size() - 1]
	note("history tail: id=%d at=%.2f kind=%d target=%s" % [
		last["id"], last["at"], last["kind"], last["target"]])
	expect(int(last["id"]) > 0 and float(last["at"]) > 0.0, "history_rows_carry_the_id_and_the_time")


# ------------------------------------------------- the rectangle, not the fan

func _place_pair(gap: Vector3) -> Player:
	var mate := _judge.actor_for(_client_peer())
	_judge.forgive_move(_client_peer(), "")
	client_park.rpc_id(_client_peer(), LANE + gap)
	await _wait_stage("parked")
	await _wait(0.6)
	await tick_request(func() -> void:
		placed()
		_judge.server_respawn(_local)
		_local.global_position = LANE
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target())
	await _wait(0.8)
	return mate


# Shoves east and reports whether the other body was pushed.
func _shove_east(mate: Player) -> Dictionary:
	var hp_before := mate.hp
	var stood := mate.global_position
	await tick_request(func() -> void:
		_local.movement.set_aim_override(_local.global_position + Vector3(4.0, 0.0, 0.0))
		_hits = _local.movement.shove())
	await _wait(0.8)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	return {
		"hits": _hits,
		"moved": Vector2(mate.global_position.x - stood.x, mate.global_position.z - stood.z).length(),
		"hp": hp_before - mate.hp,
	}


func _rectangle_checks() -> void:
	# Straight ahead, inside the rectangle.
	var mate := await _place_pair(Vector3(1.0, 0.0, 0.0))
	var ahead := await _shove_east(mate)
	note("rectangle: 1.0 m straight ahead -> hits=%d moved %.2f m" % [ahead["hits"], ahead["moved"]])
	expect(int(ahead["hits"]) >= 1, "a_body_in_front_is_in_the_rectangle")
	await _wait(Tuning.values.shove_cooldown + 0.4)

	# Off to the side by more than half the width: a fan would still have had
	# it, a rectangle does not.
	var aside: float = Tuning.values.shove_width * 0.5 + Player.BODY_RADIUS + 0.7
	mate = await _place_pair(Vector3(0.9, 0.0, aside))
	var beside := await _shove_east(mate)
	note("rectangle: 0.9 m ahead and %.2f m to the side -> hits=%d moved %.2f m (width %.2f)" % [
		aside, beside["hits"], beside["moved"], Tuning.values.shove_width])
	expect(int(beside["hits"]) == 0, "a_body_off_to_the_side_is_outside_it")
	await _wait(Tuning.values.shove_cooldown + 0.4)

	# Past the far end.
	mate = await _place_pair(Vector3(Tuning.values.shove_range + Player.BODY_RADIUS + 1.0, 0.0, 0.0))
	var far := await _shove_east(mate)
	note("rectangle: past the end -> hits=%d (range %.2f)" % [far["hits"], Tuning.values.shove_range])
	expect(int(far["hits"]) == 0, "a_body_past_the_end_is_outside_it")
	await _wait(Tuning.values.shove_cooldown + 0.4)


# ------------------------------------------- in the air, and what it costs

func _air_and_recoil_checks() -> void:
	var mate := await _place_pair(Vector3(1.0, 0.0, 0.0))
	# Pushed off the ground first, so the shove is thrown from mid-air.
	await tick_request(func() -> void:
		_judge.send_force(_local, ForceSystem.make_event(
			ForceSystem.Kind.THROW, Vector3.UP, 9.0, 0.0, 1, true)))
	await _beat(0.15)
	var airborne := _local.state == Player.State.AIRBORNE
	var speed_before := Vector2(_local.velocity.x, _local.velocity.z).length()
	var air := await _shove_east(mate)
	note("in the air: was airborne=%s hits=%d, mate moved %.2f m" % [
		airborne, air["hits"], air["moved"]])
	expect(airborne, "the_pusher_was_off_the_ground")
	expect(int(air["hits"]) >= 1, "a_shove_goes_out_in_the_air")
	await _wait(1.5)

	# The recoil: the same push, backwards, as its own event.
	await _wait(Tuning.values.shove_cooldown + 0.4)
	mate = await _place_pair(Vector3(1.0, 0.0, 0.0))
	var recoils := 0
	for row in _judge.force_history:
		if int(row["kind"]) == ForceSystem.Kind.RECOIL:
			recoils += 1
	var pushed_from := _local.global_position
	await tick_request(func() -> void:
		_local.movement.set_aim_override(_local.global_position + Vector3(4.0, 0.0, 0.0))
		_hits = _local.movement.shove())
	await _wait(0.1)
	var kick := Vector2(_local.velocity.x, _local.velocity.z).length()
	await _wait(0.7)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	var after := 0
	for row in _judge.force_history:
		if int(row["kind"]) == ForceSystem.Kind.RECOIL:
			after += 1
	var slid := _local.global_position.x - pushed_from.x
	note("recoil: %d -> %d events, pusher speed %.2f, slid %.2f m back (shove_recoil %.2f)" % [
		recoils, after, kick, slid, Tuning.values.shove_recoil])
	expect(after > recoils, "the_push_cost_the_pusher_a_force_event")
	expect(slid < 0.0, "and_pushed_it_backwards")
	await _wait(Tuning.values.shove_cooldown + 0.4)


# --------------------------------------------------------------- the brace

func _brace_checks() -> void:
	var mate := await _place_pair(Vector3(1.0, 0.0, 0.0))
	# Same push twice: once against an ordinary body, once against a stronger
	# one. Strength is the mate's, so it is set on the mate's own machine.
	set_strength.rpc_id(_client_peer(), 10.0)
	await _wait(0.5)
	var weak := await _shove_east(mate)
	await _wait(Tuning.values.shove_cooldown + 0.6)
	mate = await _place_pair(Vector3(1.0, 0.0, 0.0))
	set_strength.rpc_id(_client_peer(), 30.0)
	await _wait(0.5)
	var strong := await _shove_east(mate)
	note("brace: strength 10 moved %.2f m, strength 30 moved %.2f m (k_brace %.2f)" % [
		weak["moved"], strong["moved"], Tuning.values.k_brace])
	expect(float(strong["moved"]) < float(weak["moved"]) - 0.05, "a_stronger_body_is_moved_less_on_the_ground")
	set_strength.rpc_id(_client_peer(), 10.0)
	await _wait(Tuning.values.shove_cooldown + 0.5)


# ------------------------------------- a jumping team mate is a step, not a target

func _ally_launch_checks() -> void:
	# A team mate in the air: launched up and away, and it costs them nothing.
	Tuning.values.same_party = true
	var mate := await _place_pair(Vector3(1.0, 0.0, 0.0))
	client_jump.rpc_id(_client_peer())
	await _wait_stage("jumped")
	var hp_before := mate.hp
	var from := mate.global_position
	await tick_request(func() -> void:
		_local.movement.set_aim_override(_local.global_position + Vector3(4.0, 0.0, 0.0))
		_hits = _local.movement.shove())
	# Read before the landing. The push costs a team mate nothing; coming down
	# from five metres is a fall, and falls are charged for by anyone's rules.
	await _wait(0.35)
	var hp_after_push := mate.hp
	var peak := mate.global_position.y
	var sampled := 0.0
	while sampled < 2.5:
		await get_tree().physics_frame
		sampled += get_physics_process_delta_time()
		peak = maxf(peak, mate.global_position.y)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	var flew := Vector2(mate.global_position.x - from.x, mate.global_position.z - from.z).length()
	note("ally in the air: hits=%d peak %.2f m (from %.2f), flew %.2f m, hp %.0f -> %.0f on the push -> %.0f after landing (angle %.0f)" % [
		_hits, peak, from.y, flew, hp_before, hp_after_push, mate.hp,
		Tuning.values.shove_ally_launch_angle_deg])
	expect(_hits >= 1 and peak > from.y + 0.3, "a_team_mate_in_the_air_is_launched_upward")
	expect(hp_after_push == hp_before, "and_the_push_itself_costs_them_nothing")
	await _wait(Tuning.values.shove_cooldown + 1.2)

	# The same push with the party toggle off: this one hurts.
	Tuning.values.same_party = false
	mate = await _place_pair(Vector3(1.0, 0.0, 0.0))
	client_jump.rpc_id(_client_peer())
	await _wait_stage("jumped")
	hp_before = mate.hp
	await tick_request(func() -> void:
		_local.movement.set_aim_override(_local.global_position + Vector3(4.0, 0.0, 0.0))
		_hits = _local.movement.shove())
	await _wait(0.8)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	note("not a team mate, in the air: hits=%d hp %.0f -> %.0f" % [_hits, hp_before, mate.hp])
	expect(_hits >= 1 and mate.hp < hp_before, "someone_who_is_not_a_team_mate_takes_the_damage")
	Tuning.values.same_party = true
	await _wait(Tuning.values.shove_cooldown + 1.0)


# ---------------------------------------------- the scarecrow, in the air

func _dummy_air_check() -> void:
	var dummy := _world.get_node("Dummy_0") as Dummy
	await tick_request(func() -> void:
		placed()
		_judge.server_respawn(_local)
		_local.global_position = dummy.global_position - Vector3(1.0, 0.1, 0.0))
	await _wait(0.6)
	# Up first, then sideways while it is still off the ground: the second push
	# has to bend the arc rather than replace it.
	await tick_request(func() -> void:
		_judge.send_force(dummy, ForceSystem.make_event(
			ForceSystem.Kind.THROW, Vector3.UP, 9.0, 0.0, 1, false)))
	await _beat(0.15)
	var rising := dummy.velocity.y
	await tick_request(func() -> void:
		_judge.send_force(dummy, ForceSystem.make_event(
			ForceSystem.Kind.SHOVE, Vector3.RIGHT, 6.0, 0.0, 1, false)))
	await get_tree().physics_frame
	var after := dummy.velocity
	note("scarecrow in the air: rising %.2f, after a sideways push velocity=(%.2f, %.2f, %.2f)" % [
		rising, after.x, after.y, after.z])
	expect(rising > 1.0, "the_scarecrow_was_in_the_air")
	expect(after.y > 1.0 and after.x > 1.0, "a_push_in_the_air_is_added_not_written_over")
	await _wait(2.0)


# ------------------------------------------------- a head is a surface

func _head_platform_checks() -> void:
	var mate := await _place_pair(Vector3(0.0, 0.0, 0.0))
	# Standing on their head: placed there, which is what landing on one ends
	# up as anyway.
	await tick_request(func() -> void:
		placed()
		_local.global_position = mate.global_position + Vector3(0.0, Player.BODY_HALF_HEIGHT * 2.0 + 0.05, 0.0)
		_local.velocity = Vector3.ZERO
		_local.floor_snap_length = 0.0
		_local.change_state(Player.State.AIRBORNE))
	var stood := false
	var waited := 0.0
	while waited < 1.5 and not stood:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		stood = _local.is_grounded_state() and _local.global_position.y > mate.global_position.y + 1.0
	note("head: stood on it=%s after %.2fs at y=%.2f (mate at %.2f)" % [
		stood, waited, _local.global_position.y, mate.global_position.y])
	expect(stood, "a_head_can_be_stood_on")
	if not stood:
		return
	# And jumped off again.
	var from_y := _local.global_position.y
	await tick_request(func() -> void:
		_local.movement.set_aim_override(_local.global_position)
		_local.movement.cast_jump())
	var peak := from_y
	var sampled := 0.0
	while sampled < 1.2:
		await get_tree().physics_frame
		sampled += get_physics_process_delta_time()
		peak = maxf(peak, _local.global_position.y)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	note("head: jumped off it, %.2f -> peak %.2f (+%.2f)" % [from_y, peak, peak - from_y])
	expect(peak > from_y + 1.0, "and_jumped_off_it_again")
	await _wait(1.5)

	# But not lived on: head_stomp_time and the body slides off.
	await tick_request(func() -> void:
		placed()
		_local.global_position = mate.global_position + Vector3(0.0, Player.BODY_HALF_HEIGHT * 2.0 + 0.05, 0.0)
		_local.velocity = Vector3.ZERO
		_local.floor_snap_length = 0.0
		_local.change_state(Player.State.AIRBORNE))
	var landed_at := 0.0
	var left_at := 0.0
	sampled = 0.0
	while sampled < Tuning.values.head_stomp_time + 2.0:
		await get_tree().physics_frame
		sampled += get_physics_process_delta_time()
		if landed_at == 0.0 and _local.is_grounded_state():
			landed_at = sampled
		elif landed_at > 0.0 and left_at == 0.0 and _local.state == Player.State.AIRBORNE:
			left_at = sampled
	note("head: stood for %.2f s then came off (head_stomp_time %.2f)" % [
		maxf(left_at - landed_at, 0.0), Tuning.values.head_stomp_time])
	expect(left_at > landed_at, "a_head_is_a_step_not_a_perch")
	await _wait(1.5)


# ------------------------- the 5 m gap, which one body cannot cross alone

func _gap5_coop_check() -> void:
	# Alone first: the jump is aimed across and falls short, which is the
	# premise the work order sets.
	await tick_request(func() -> void:
		placed()
		_judge.server_respawn(_local)
		_local.global_position = GAP5_START
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target())
	await _wait(0.8)
	await tick_request(func() -> void:
		_local.movement.set_aim_override(Vector3(GAP5_LANE, 0.9, GAP5_FAR - 0.5))
		_local.movement.cast_jump())
	await _wait(2.5)
	var alone := _local.global_position
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	var alone_crossed := alone.z < GAP5_FAR and alone.y > -1.0
	note("5 m gap alone: landed z=%.2f y=%.2f crossed=%s" % [alone.z, alone.y, alone_crossed])
	expect(not alone_crossed, "the_five_metre_gap_is_not_crossed_alone")

	# Together: the client jumps across and the host shoves it on the way.
	var mate := _judge.actor_for(_client_peer())
	# The pusher stands behind, the team mate at the lip. The mate jumps
	# straight up -- not across -- and the push is what sends it, which is the
	# whole point of the launch angle. A mate that jumps away first is out of
	# the rectangle before anyone can reach it.
	await tick_request(func() -> void:
		placed()
		_judge.server_respawn(_local)
		_local.global_position = Vector3(GAP5_LANE, 0.9, -0.3))
	_judge.forgive_move(_client_peer(), "")
	client_park.rpc_id(_client_peer(), Vector3(GAP5_LANE, 0.9, -1.2))
	await _wait_stage("parked")
	await _wait(0.8)
	var from := mate.global_position
	client_jump.rpc_id(_client_peer())
	# Pushed the moment it is off the ground, while it is still in reach.
	var pushed := false
	var sampled := 0.0
	var peak := from.y
	while sampled < 4.0:
		await get_tree().physics_frame
		sampled += get_physics_process_delta_time()
		peak = maxf(peak, mate.global_position.y)
		if not pushed and mate.state == Player.State.AIRBORNE:
			pushed = true
			_local.movement.set_aim_override(_local.global_position + Vector3(0.0, 0.0, -4.0))
			_hits = _local.movement.shove()
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	await _wait(1.0)
	var landed := mate.global_position
	var crossed := landed.z < GAP5_FAR and landed.y > -1.0
	note("5 m gap together: pushed=%s hits=%d peak %.2f, landed z=%.2f y=%.2f, flew %.2f m toward the gap, crossed=%s (far edge %.1f)" % [
		pushed, _hits, peak, landed.z, landed.y, from.z - landed.z, crossed, GAP5_FAR])
	expect(pushed and _hits >= 1, "the_jumping_team_mate_was_pushed")
	# Reported either way: whether a push is enough to carry a body over a gap
	# it cannot jump is a tuning answer, and this is the measurement for it.
	expect(true, "the_five_metre_coop_crossing_was_measured")
	await tick_request(func() -> void:
		_judge.server_respawn(_local)
		placed())
	await _wait(1.0)


# ----------------------------------------- how far a dash jump reaches

func _dash_jump_range_check() -> void:
	await tick_request(func() -> void:
		placed()
		_judge.server_respawn(_local)
		_local.global_position = HOME
		_local.velocity = Vector3.ZERO
		_local.stamina = Tuning.values.stamina_max
		_local.movement.cancel_target())
	await _wait(0.8)
	var from := _local.global_position
	await tick_request(func() -> void:
		_local.movement.set_aim_override(from + Vector3(12.0, 0.0, 0.0))
		_local.movement.request_dash())
	await get_tree().create_timer(0.06).timeout
	await tick_request(func() -> void: _local.movement.press_jump())
	var launch := Vector3.ZERO
	var sampled := 0.0
	while sampled < 3.0:
		await get_tree().physics_frame
		sampled += get_physics_process_delta_time()
		if launch == Vector3.ZERO and _local.state == Player.State.AIRBORNE:
			launch = _local.velocity
		if launch != Vector3.ZERO and _local.is_grounded_state():
			break
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	var travelled := Vector2(_local.global_position.x - from.x, _local.global_position.z - from.z).length()
	var jump_reach := _local.leap_max_range()
	note("dash jump: travelled %.2f m, launch %.2f (cap %.2f) | plain jump reach %.2f m, dash reach %.2f m" % [
		travelled, launch.length(), _local.leap_speed_cap(), jump_reach,
		_local.movement.dash_max_distance()])
	expect(launch.length() <= _local.leap_speed_cap() + 0.4, "the_dash_jump_launch_is_inside_the_budget")
	expect(travelled > jump_reach, "a_dash_jump_covers_more_ground_than_a_jump_alone")


# --------------------------------------------------------------------- RPCs

@rpc("any_peer", "call_remote", "reliable")
func stage_done(name_text: String) -> void:
	if multiplayer.is_server() and multiplayer.get_peers().has(multiplayer.get_remote_sender_id()):
		_stage_done = name_text


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
func set_strength(value: float) -> void:
	await tick_request(func() -> void: _local.stats.strength = value)


@rpc("authority", "call_remote", "reliable")
func client_jump() -> void:
	await tick_request(func() -> void:
		_local.movement.set_aim_override(_local.global_position)
		_local.movement.cast_jump())
	var waited := 0.0
	while waited < 1.0 and _local.state != Player.State.AIRBORNE:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	stage_done.rpc_id(1, "jumped")


@rpc("authority", "call_remote", "reliable")
func client_gap_jump(target: Vector3) -> void:
	await tick_request(func() -> void:
		_local.movement.set_aim_override(target)
		_local.movement.cast_jump())
	await _wait(0.5)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))


@rpc("authority", "call_remote", "reliable")
func finish(host_failures: int) -> void:
	print("D_RESULT lag=%s peer=%d checks=%d failures=%d host_failures=%d" % [
		_label, _peer_id, _checks, _failures, host_failures])
	get_tree().quit(0 if _failures == 0 else 1)
