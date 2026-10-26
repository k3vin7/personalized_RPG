extends Node

# B-c: the rulings moved to the server. Two peers, each one shoving, grabbing,
# throwing and escaping for itself, plus the E-5 exception table read off the
# judge's release reasons, plus 2-chapter bug 5 (a thrown rock hitting a
# person) now that the rock can actually be got into a hand.

const PARK_HOST := Vector3(-10.0, 0.9, 10.0)
const PARK_CLIENT := Vector3(-14.0, 0.9, 13.0)
# Far enough apart that neither body is in the other's grab range.
const HIT_LANE := Vector3(-16.0, 0.9, 6.0)

var _world: Node3D
var _local: Player
var _judge: ServerAuthority
var _peer_id := 0
var _checks := 0
var _failures := 0
var _stage_done := ""
var _last_hits := 0
var _escape_seen := 0


func expect(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("BC_CHECK peer=%d %s %s" % [_peer_id, "PASS" if condition else "FAIL", label])


func note(line: String) -> void:
	print("BC_NOTE peer=%d %s" % [_peer_id, line])


func tick_request(action: Callable) -> void:
	Net.queue_physics(action)
	for _frame in range(3):
		await get_tree().physics_frame


func _wait_stage(name_text: String, seconds := 20.0) -> bool:
	var waited := 0.0
	while _stage_done != name_text and waited < seconds:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	var arrived := _stage_done == name_text
	_stage_done = ""
	return arrived


func _client_peer() -> int:
	var peers := multiplayer.get_peers()
	return peers[0] if peers.size() > 0 else 0


func _released(reason: String) -> int:
	return int(_judge.release_reasons.get(reason, 0))


func run(world: Node3D) -> void:
	_world = world
	_peer_id = multiplayer.get_unique_id()
	_local = Net.spawn_root.get_node(str(_peer_id)) as Player
	_judge = world.get_node_or_null("ServerAuthority") as ServerAuthority
	await _structure_checks()
	if not multiplayer.is_server():
		stage_done.rpc_id(1, "client_ready")
		return
	expect(await _wait_stage("client_ready"), "both_peers_completed_structure_checks")
	await _host_shove_checks()
	await _host_hold_checks()
	await _client_action_checks()
	await _escape_checks()
	await _exception_checks()
	await _rock_versus_player_check()
	await _disconnect_exception_check()
	print("BC_RESULT peer=%d checks=%d failures=%d" % [_peer_id, _checks, _failures])
	await get_tree().create_timer(0.5).timeout
	get_tree().quit(0 if _failures == 0 else 1)


# ---------------------------------------------------------------- structure

func _structure_checks() -> void:
	expect(_judge != null and _judge.get_parent() == _world, "judge_is_session_child")
	expect(_judge != null and _judge.hold_count() == 0, "hold_table_starts_empty")

	# One table, one contract: everything holdable is in the group and offers
	# the read-only display setter.
	var rock := _world.get_node("Rock_0") as Rock
	var dummy := _world.get_node("Dummy_0") as Dummy
	var holdables: Array[Node] = [rock, dummy, _local]
	var all_in := true
	for body in holdables:
		all_in = all_in and body.is_in_group(ServerAuthority.HOLDABLE_GROUP) \
			and body.has_method("set_hold_display")
	expect(all_in, "rock_dummy_player_share_one_hold_table")

	# The owner-to-owner approval protocol is gone, not merely unused.
	expect(
		not rock.has_method("host_grab") and not rock.has_method("request_grab")
			and not rock.has_method("answer_grab") and not rock.has_method("host_release"),
		"rock_client_protocol_removed")
	expect(
		not _local.has_method("accept_grab") and not _local.has_method("grab_answer")
			and not _local.has_method("request_grab"),
		"player_owner_approval_removed")
	# The shove's numbers are the judge's now, so they are tuning values.
	expect(
		not _local.movement.has_method("apply_shove")
			and Tuning.values.get("shove_cooldown") == 0.6
			and Tuning.values.get("shove_range") == 1.5,
		"shove_ruling_and_numbers_left_the_client")
	await get_tree().physics_frame


# -------------------------------------------------------------- host rulings

func _host_shove_checks() -> void:
	var dummy := _world.get_node("Dummy_0") as Dummy
	var granted := _judge.granted_intents
	var rejected := _judge.rejected_intents
	var hp_before := dummy.hp
	var stood := dummy.global_position
	await tick_request(func() -> void:
		_local.respawn()
		_local.global_position = dummy.global_position - Vector3(1.0, 0.1, 0.0)
		_local.movement.set_aim_override(dummy.global_position))
	await get_tree().create_timer(0.4).timeout
	await tick_request(func() -> void: _last_hits = _local.movement.shove())
	expect(_last_hits >= 1, "server_ruled_shove_hit_dummy")
	expect(_judge.granted_intents > granted, "shove_intent_granted_by_judge")
	# The cooldown is the server's: a second press in the same breath is
	# refused by the judge, not by the key handler.
	await tick_request(func() -> void: _last_hits = _local.movement.shove())
	expect(_last_hits == 0 and _judge.rejected_intents > rejected, "server_owns_shove_cooldown")
	await get_tree().create_timer(0.5).timeout
	expect(dummy.hp < hp_before and dummy.global_position.distance_to(stood) > 0.2, "shove_damaged_and_moved_dummy")
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))


func _host_hold_checks() -> void:
	var heavy := _world.get_node("Rock_2") as Rock      # 20 kg
	await tick_request(func() -> void:
		_local.respawn()
		_local.global_position = PARK_HOST)
	await get_tree().create_timer(0.4).timeout

	# 4-chapter lift limit, ruled in one place for every kind of body.
	await tick_request(func() -> void:
		heavy.global_position = _local.global_position + Vector3(0.9, 0.3, 0.0))
	await get_tree().create_timer(0.3).timeout
	await tick_request(func() -> void:
		_local.stats.strength = 9.0
		expect(not _judge.can_grab(_local, heavy), "lift_limit_refuses_20kg_at_strength_9")
		_local.stats.strength = 10.0
		expect(_judge.can_grab(_local, heavy), "lift_limit_allows_20kg_at_strength_10"))
	# Reach is ruled on the server's view of where the body is.
	await tick_request(func() -> void:
		heavy.global_position = _local.global_position + Vector3(8.0, 0.3, 0.0))
	await get_tree().create_timer(0.3).timeout
	expect(not _judge.can_grab(_local, heavy), "reach_refuses_eight_metres")

	# A whole hold, through the key, with the table as the only record of it.
	await tick_request(func() -> void:
		heavy.global_position = _local.global_position + Vector3(0.9, 0.3, 0.0))
	await get_tree().create_timer(0.3).timeout
	await tick_request(func() -> void:
		_local.movement.set_aim_override(heavy.global_position)
		_local.movement.interact())
	await get_tree().create_timer(0.5).timeout
	expect(_local.grab.is_holding() and heavy.holder_peer == 1 and _judge.hold_count() == 1, "host_hold_recorded_in_table")
	expect(_local.state == Player.State.GRABBING, "holder_state_follows_table")
	var from := heavy.global_position
	await tick_request(func() -> void:
		_local.movement.set_aim_override(_local.global_position + Vector3.RIGHT * 10.0)
		_local.movement.interact())
	await get_tree().create_timer(1.2).timeout
	expect(heavy.holder_peer == 0 and _judge.hold_count() == 0, "throw_cleared_the_row")
	expect(heavy.global_position.distance_to(from) > 1.0, "host_throw_moved_the_rock")
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))


# ------------------------------------------------------------- client acting

func _client_action_checks() -> void:
	var rock := _world.get_node("Rock_1") as Rock       # 10 kg
	var hp_before := _local.hp
	await tick_request(func() -> void:
		_local.respawn()
		_local.global_position = PARK_HOST)
	await get_tree().create_timer(0.5).timeout

	# The client's own shove, ruled on the server against the server's view.
	client_shove.rpc_id(_client_peer(), _local.get_path())
	expect(await _wait_stage("shoved"), "client_shove_reported")
	await get_tree().create_timer(0.8).timeout
	expect(_local.hp < hp_before, "client_shove_ruled_by_server_landed")

	# The client's own grab and throw. The rock is server-owned, so the server
	# is what puts it within the client's reach.
	var client := _judge.actor_for(_client_peer())
	await tick_request(func() -> void:
		rock.global_position = client.global_position + Vector3(0.9, 0.3, 0.0))
	await get_tree().create_timer(0.4).timeout
	var rock_from := rock.global_position
	client_rock.rpc_id(_client_peer(), rock.get_path())
	expect(await _wait_stage("rock"), "client_rock_reported")
	expect(_released("thrown") > 0, "client_throw_ended_row_as_thrown")
	expect(rock.holder_peer == 0 and rock.global_position.distance_to(rock_from) > 1.0, "client_throw_moved_the_rock")


# ------------------------------------------------------------------ escaping

func _escape_checks() -> void:
	var victim := _judge.actor_for(_client_peer())
	client_park.rpc_id(_client_peer(), PARK_CLIENT)
	expect(await _wait_stage("parked"), "client_parked")
	await get_tree().create_timer(0.6).timeout
	await tick_request(func() -> void:
		_local.respawn()
		_local.global_position = victim.global_position + Vector3(0.9, 0.0, 0.0)
		_local.movement.set_aim_override(victim.global_position))
	await get_tree().create_timer(0.6).timeout
	await tick_request(func() -> void: _local.movement.interact())
	await get_tree().create_timer(0.8).timeout
	expect(_local.grab.is_holding() and victim.state == Player.State.GRABBED, "host_grabbed_client")
	expect(_judge.holder_of(victim) == 1, "table_names_the_holder")
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	if victim.state != Player.State.GRABBED:
		return
	# Mutual grab: the person in my hands cannot take hold of me.
	expect(not _judge.can_grab(victim, _local), "mutual_grab_refused_by_table")
	var escaped := _released("escaped")
	client_escape.rpc_id(_client_peer())
	expect(await _wait_stage("escaped"), "client_escape_reported")
	await get_tree().create_timer(0.8).timeout
	expect(_released("escaped") > escaped, "escape_counted_on_server")
	expect(_judge.holder_of(victim) == 0 and not _local.grab.is_holding(), "escape_cleared_the_row")
	expect(_escape_seen > 0 and _escape_seen < int(Tuning.values.grabbed_escape_presses), "escape_progress_replicated_to_client")


# ------------------------------------------------------------- E-5 exceptions

func _exception_checks() -> void:
	var rock := _world.get_node("Rock_0") as Rock
	var victim := _judge.actor_for(_client_peer())

	# 2. The holder is stunned.
	expect(await _hold_then(rock, func() -> void: _local.change_state(Player.State.STUNNED)), "hold_taken_for_stun_case")
	await get_tree().create_timer(0.4).timeout
	expect(_judge.hold_count() == 0 and _released("holder_state") > 0, "e5_holder_stunned_released")
	await tick_request(func() -> void:
		_local.velocity = Vector3.ZERO
		_local.change_state(Player.State.IDLE))

	# 2. The holder leaves the ground.
	var state_released := _released("holder_state")
	expect(await _hold_then(rock, func() -> void:
		_local.global_position += Vector3.UP * 2.0
		_local.change_state(Player.State.AIRBORNE)), "hold_taken_for_fall_case")
	await get_tree().create_timer(0.4).timeout
	expect(_judge.hold_count() == 0 and _released("holder_state") > state_released, "e5_holder_fell_released")
	await get_tree().create_timer(1.0).timeout

	# 2. The holder is pushed: the force door lets go before the force lands.
	var pushed := _released("holder_pushed")
	expect(await _hold_then(rock, func() -> void:
		_judge.send_force(_local, ForceSystem.make_event(
			ForceSystem.Kind.SHOVE, Vector3(1.0, 0.2, 0.0), 6.0, 10.0, 1, false, 0.0, 0.0))), "hold_taken_for_push_case")
	await get_tree().create_timer(0.3).timeout
	expect(_judge.hold_count() == 0 and _released("holder_pushed") > pushed, "e5_holder_pushed_released")
	await get_tree().create_timer(1.0).timeout

	# 3. The held body is pushed by something else.
	await tick_request(func() -> void:
		_local.respawn()
		_local.global_position = victim.global_position + Vector3(0.9, 0.0, 0.0)
		_local.movement.set_aim_override(victim.global_position))
	await get_tree().create_timer(0.6).timeout
	await tick_request(func() -> void: _local.movement.interact())
	await get_tree().create_timer(0.8).timeout
	var target_pushed := _released("target_pushed")
	if _judge.holder_of(victim) == 1:
		await tick_request(func() -> void:
			_judge.send_force(victim, ForceSystem.make_event(
				ForceSystem.Kind.KNOCKBACK, Vector3(0.0, 0.3, 1.0), 6.0, 0.0, 1, false, 0.0, 0.0)))
		await get_tree().create_timer(0.5).timeout
		expect(_released("target_pushed") > target_pushed and _judge.holder_of(victim) == 0, "e5_held_body_pushed_released")
	else:
		expect(false, "e5_held_body_pushed_released")
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))

	# 4. Two people reaching at once: the row the first wrote refuses the
	# second, with no case of its own.
	expect(await _hold_then(rock, func() -> void: pass), "hold_taken_for_contest_case")
	expect(not _judge.can_grab(victim, rock), "e5_simultaneous_grab_refused")
	var dropped := _released("dropped")
	await tick_request(_local.grab.drop)
	await get_tree().create_timer(0.4).timeout
	expect(_released("dropped") > dropped and _judge.hold_count() == 0, "drop_is_a_server_ruling")
	note("release_reasons=%s" % str(_judge.release_reasons))


# Takes hold of a rock through the key, waits for the grace to run out, then
# runs the thing that should end the hold.
func _hold_then(rock: Rock, after: Callable) -> bool:
	await tick_request(func() -> void:
		if _local.state == Player.State.DEAD:
			_local.respawn()
		_local.global_position = PARK_HOST
		_local.velocity = Vector3.ZERO
		if _local.state != Player.State.IDLE and _local.is_grounded_state() == false:
			_local.change_state(Player.State.IDLE))
	await get_tree().create_timer(0.5).timeout
	await tick_request(func() -> void:
		rock.global_position = _local.global_position + Vector3(0.9, 0.3, 0.0))
	await get_tree().create_timer(0.3).timeout
	await tick_request(func() -> void:
		_local.movement.set_aim_override(rock.global_position)
		_local.movement.interact())
	await get_tree().create_timer(0.5).timeout
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	var took := _local.grab.is_holding()
	# Past HOLD_GRACE: before it the judge leaves a new hold alone on purpose.
	await get_tree().create_timer(ServerAuthority.HOLD_GRACE + 0.2).timeout
	await tick_request(after)
	return took


# -------------------------------------------------- 2-chapter bug 5, measured

func _rock_versus_player_check() -> void:
	var rock := _world.get_node("Rock_0") as Rock
	var victim := _judge.actor_for(_client_peer())
	client_park.rpc_id(_client_peer(), HIT_LANE + Vector3(3.0, 0.0, 0.0))
	expect(await _wait_stage("parked"), "client_parked_in_hit_lane")
	await tick_request(func() -> void:
		_local.respawn()
		_local.global_position = HIT_LANE)
	await get_tree().create_timer(0.8).timeout
	await tick_request(func() -> void:
		rock.global_position = _local.global_position + Vector3(0.9, 0.3, 0.0))
	await get_tree().create_timer(0.3).timeout
	await tick_request(func() -> void:
		_local.movement.set_aim_override(rock.global_position)
		_local.movement.interact())
	await get_tree().create_timer(0.6).timeout
	expect(_local.grab.is_holding(), "rock_in_hand_for_hit_check")
	var hp_before := victim.hp
	var stood := victim.global_position
	# Thrown flat. At the documented 35 degrees the rock leaves a hand 1.7 m
	# above the thrower's own origin and passes over a 1.8 m body until about
	# 9 m out: that is the arc, measured in stage 7's sweep, not a force that
	# fails to land. What is under test here is the landing.
	var angle_was: float = Tuning.values.throw_up_angle_deg
	Tuning.values.throw_up_angle_deg = 0.0
	await tick_request(func() -> void:
		_local.movement.set_aim_override(victim.global_position)
		_local.movement.interact())
	var closest := INF
	var sampled := 0.0
	while sampled < 2.0:
		await get_tree().physics_frame
		sampled += get_physics_process_delta_time()
		closest = minf(closest, rock.global_position.distance_to(victim.global_position))
	Tuning.values.throw_up_angle_deg = angle_was
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	var moved := Vector2(victim.global_position.x - stood.x, victim.global_position.z - stood.z).length()
	note("rock_vs_player closest=%.2f touching_at=%.2f hp=%.0f-%.0f moved=%.2f" % [
		closest, Rock.radius_for(rock.weight) + Player.BODY_RADIUS, hp_before, victim.hp, moved])
	expect(victim.hp < hp_before, "bug5_thrown_rock_damages_a_person")
	expect(moved > 0.2, "bug5_thrown_rock_knocks_a_person_back")


# ---------------------------------------- E-5 1: the holder disconnects

func _disconnect_exception_check() -> void:
	var rock := _world.get_node("Rock_1") as Rock
	var client := _judge.actor_for(_client_peer())
	await tick_request(func() -> void:
		rock.global_position = client.global_position + Vector3(0.9, 0.3, 0.0))
	await get_tree().create_timer(0.4).timeout
	client_rock_hold.rpc_id(_client_peer(), rock.get_path())
	expect(await _wait_stage("holding"), "client_holding_before_disconnect")
	expect(rock.holder_peer == _client_peer(), "table_names_client_as_holder")
	var gone := _released("holder_gone")
	client_leave.rpc_id(_client_peer())
	var waited := 0.0
	while waited < 10.0 and _released("holder_gone") == gone:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	expect(_released("holder_gone") > gone, "e5_holder_disconnect_released")
	expect(rock.holder_peer == 0 and _judge.hold_count() == 0, "disconnect_cleared_the_row")


# --------------------------------------------------------------------- RPCs

@rpc("any_peer", "call_remote", "reliable")
func stage_done(name_text: String) -> void:
	if multiplayer.is_server() and multiplayer.get_peers().has(multiplayer.get_remote_sender_id()):
		_stage_done = name_text


@rpc("any_peer", "call_remote", "reliable")
func escape_progress(presses: int) -> void:
	if multiplayer.is_server() and multiplayer.get_peers().has(multiplayer.get_remote_sender_id()):
		_escape_seen = maxi(_escape_seen, presses)


@rpc("authority", "call_remote", "reliable")
func client_park(point: Vector3) -> void:
	await tick_request(func() -> void:
		_local.respawn()
		_local.global_position = point
		_local.movement.set_aim_override(Vector3.INF))
	await get_tree().create_timer(0.4).timeout
	stage_done.rpc_id(1, "parked")


@rpc("authority", "call_remote", "reliable")
func client_shove(host_path: NodePath) -> void:
	var host_player := get_node(host_path) as Player
	await tick_request(func() -> void:
		_local.respawn()
		_local.global_position = host_player.global_position - Vector3(1.0, 0.0, 0.0)
		_local.movement.set_aim_override(host_player.global_position))
	await get_tree().create_timer(0.5).timeout
	await tick_request(func() -> void:
		expect(_local.movement.shove() == 0, "client_shove_returns_no_local_verdict")
		_local.movement.set_aim_override(Vector3.INF))
	stage_done.rpc_id(1, "shoved")


@rpc("authority", "call_remote", "reliable")
func client_rock(rock_path: NodePath) -> void:
	var rock := get_node(rock_path) as Rock
	await tick_request(func() -> void:
		_local.movement.set_aim_override(rock.global_position)
		_local.movement.interact())
	await get_tree().create_timer(0.8).timeout
	expect(_local.grab.is_holding() and rock.holder_peer == _peer_id, "client_grab_recorded_in_table")
	expect(_local.state == Player.State.GRABBING, "client_holder_state_follows_table")
	await tick_request(func() -> void:
		_local.movement.set_aim_override(_local.global_position + Vector3.RIGHT * 10.0)
		_local.movement.interact())
	await get_tree().create_timer(1.0).timeout
	expect(not _local.grab.is_holding(), "client_throw_cleared_its_hand")
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	stage_done.rpc_id(1, "rock")


@rpc("authority", "call_remote", "reliable")
func client_rock_hold(rock_path: NodePath) -> void:
	var rock := get_node(rock_path) as Rock
	await tick_request(func() -> void:
		_local.movement.set_aim_override(rock.global_position)
		_local.movement.interact())
	await get_tree().create_timer(0.8).timeout
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	expect(_local.grab.is_holding(), "client_took_hold_for_disconnect_case")
	stage_done.rpc_id(1, "holding")


@rpc("authority", "call_remote", "reliable")
func client_escape() -> void:
	expect(_local.state == Player.State.GRABBED, "client_sees_itself_grabbed")
	var presses := int(Tuning.values.grabbed_escape_presses)
	var from := _local.global_position
	for index in range(presses):
		await tick_request(_local.grab.escape_press)
		if index == presses - 2:
			# The count lives in the server's row; this is the client reading
			# its own progress back out of the table.
			escape_progress.rpc_id(1, ServerAuthority.instance.escape_presses(_local))
		if index < presses - 1:
			await get_tree().create_timer(0.2).timeout
	# Sampled from the press, not after it. The body is let go at hand height,
	# which is directly over the holder's head, so it comes down on that head
	# within a frame or two and the ground step takes the recoil speed straight
	# back off it. Measuring a moment later measures a body standing still on
	# someone's shoulders. (Standing on heads is stage D's business.)
	var peak := 0.0
	var sampled := 0.0
	var lowest := INF
	while sampled < 0.6:
		await get_tree().physics_frame
		sampled += get_physics_process_delta_time()
		peak = maxf(peak, Vector2(_local.velocity.x, _local.velocity.z).length())
		lowest = minf(lowest, _local.global_position.y)
	var pushed := Vector2(_local.global_position.x - from.x, _local.global_position.z - from.z).length()
	note("escape peak_speed=%.2f pushed=%.2f lowest_y=%.2f recoil_tuning=%.2f" % [
		peak, pushed, lowest, Tuning.values.escape_recoil_power])
	expect(_local.state != Player.State.GRABBED, "client_freed_itself")
	expect(peak > 1.0, "escape_recoil_arrived_as_force")
	stage_done.rpc_id(1, "escaped")


@rpc("authority", "call_remote", "reliable")
func client_leave() -> void:
	print("BC_RESULT peer=%d checks=%d failures=%d" % [_peer_id, _checks, _failures])
	await get_tree().create_timer(0.2).timeout
	Net.leave("B-c 보유자 접속 끊김 확인")
	await get_tree().create_timer(1.5).timeout
	get_tree().quit(0 if _failures == 0 else 1)
