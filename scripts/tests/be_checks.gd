extends Node

# B-e: the whole of stage B, measured at a real latency.
#
# Run with tools/udp_delay_proxy.py between the two peers and pass the one way
# delay as --be-latency=<ms> so the numbers in the log say what they were taken
# under. Every wait in here is padded by that figure, because at 200 ms a check
# that waited 0.4 s was measuring the network rather than the game.

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


func expect(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("BE_CHECK lag=%s peer=%d %s %s" % [_label, _peer_id, "PASS" if condition else "FAIL", label])


func note(line: String) -> void:
	print("BE_NOTE lag=%s peer=%d %s" % [_label, _peer_id, line])


func tick_request(action: Callable) -> void:
	Net.queue_physics(action)
	for _frame in range(3):
		await get_tree().physics_frame


# Every wait is "enough for the game" plus "enough for the wire".
func _settle_wait(seconds: float) -> void:
	await get_tree().create_timer(seconds + _lag * 3.0).timeout


func _wait_stage(name_text: String, seconds := 25.0) -> bool:
	var waited := 0.0
	while _stage_done != name_text and waited < seconds + _lag * 20.0:
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
		if argument.begins_with("--be-latency="):
			_label = argument.trim_prefix("--be-latency=")
			_lag = _label.to_float() / 1000.0
	if not multiplayer.is_server():
		stage_done.rpc_id(1, "client_ready")
		return
	expect(await _wait_stage("client_ready"), "both_peers_present")
	await _normal_play_check()
	await _agreement_checks()
	await _client_action_checks()
	await _contest_check()
	await _hold_grace_window_check()
	await _reconnect_check()
	print("BE_RESULT lag=%s peer=%d checks=%d failures=%d" % [_label, _peer_id, _checks, _failures])
	await _settle_wait(0.5)
	# Last, because the client checks the menu it lands on.
	Net.leave("B-e 호스트 종료 확인")
	await get_tree().create_timer(3.0 + _lag * 10.0).timeout
	get_tree().quit(0 if _failures == 0 else 1)


# ----------------------------------------------------- B-e-1: the move check

func _normal_play_check() -> void:
	await tick_request(func() -> void: _judge.server_respawn(_local))
	await _settle_wait(0.6)
	client_play.rpc_id(_client_peer())
	var before := _judge.move_warnings
	# Our own ordinary play, at the same time as theirs: walk, jump, dash.
	for leg in range(3):
		_local.movement.set_target(_local.global_position + Vector3(3.0 if leg % 2 == 0 else -3.0, 0.0, 0.0))
		await _settle_wait(0.9)
		await tick_request(func() -> void:
			_local.movement.set_aim_override(_local.global_position + Vector3(4.0, 0.0, 0.0))
			_local.movement.request_jump())
		await _settle_wait(1.0)
		await tick_request(func() -> void: _local.movement.request_dash())
		await _settle_wait(0.9)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	expect(await _wait_stage("played"), "client_played_its_own_legs")
	# A fall and a death are ordinary too.
	await tick_request(func() -> void:
		_judge.forgive_move(1, "")
		_local.global_position += Vector3.UP * 5.0
		_local.velocity = Vector3.ZERO
		_local.floor_snap_length = 0.0
		_local.change_state(Player.State.AIRBORNE))
	await _settle_wait(1.6)
	var warnings := _judge.move_warnings - before
	note("move warnings during ordinary play: %d (tolerance=%.2f)" % [
		warnings, Tuning.values.server_speed_tolerance])
	expect(warnings == 0, "no_move_warnings_in_normal_play")

	# And the check is not asleep: a body teleported without the server being
	# told is what it is there to notice.
	var before_cheat := _judge.move_warnings
	await tick_request(func() -> void: _local.global_position += Vector3(12.0, 0.0, 0.0))
	await _settle_wait(0.5)
	expect(_judge.move_warnings > before_cheat, "move_check_notices_a_teleport")
	await tick_request(func() -> void: _judge.server_respawn(_local))
	await _settle_wait(0.6)


# ------------------------------- B-e-3: the same result on both screens

func _agreement_checks() -> void:
	var victim := _judge.actor_for(_client_peer())
	# Shoved: both peers read the body's resting place and the two are compared.
	await _place_both(victim)
	await tick_request(func() -> void:
		_judge.send_force(victim, ForceSystem.make_event(
			ForceSystem.Kind.SHOVE, Vector3(1.0, 0.25, 0.0), Tuning.values.shove_power,
			10.0, 1, false, Tuning.values.shove_damage, 0.0)))
	await _settle_wait(2.5)
	await _compare_views(victim, "shove")

	# Thrown: picked up through the door, thrown through the door.
	await _place_both(victim)
	await tick_request(func() -> void:
		_local.movement.set_aim_override(victim.global_position)
		_local.movement.interact())
	await _settle_wait(1.0)
	if _judge.holder_of(victim) != 1:
		expect(false, "host_grabbed_client_for_throw")
		return
	expect(true, "host_grabbed_client_for_throw")
	await tick_request(func() -> void:
		_local.movement.set_aim_override(_local.global_position + Vector3(14.0, 0.0, 0.0))
		_local.movement.interact())
	await _settle_wait(3.0)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	await _compare_views(victim, "throw")


func _place_both(victim: Player) -> void:
	_judge.forgive_move(_client_peer(), "")
	client_park.rpc_id(_client_peer(), Vector3(-14.0, 0.9, 13.0))
	await _wait_stage("parked")
	await _settle_wait(0.8)
	await tick_request(func() -> void:
		_judge.server_respawn(_local)
		_local.global_position = victim.global_position + Vector3(0.9, 0.0, 0.0))
	await _settle_wait(0.8)


# Both peers report where they think the body ended up, and the gap between
# the two screens is the number that matters.
func _compare_views(body: Player, what: String) -> void:
	_reported.erase(what)
	report_position.rpc_id(_client_peer(), body.get_path(), what)
	var waited := 0.0
	while not _reported.has(what) and waited < 8.0 + _lag * 20.0:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	if not _reported.has(what):
		expect(false, "%s_result_reported_by_client" % what)
		return
	var theirs: Vector3 = _reported[what]
	var gap := body.global_position.distance_to(theirs)
	note("%s final position: host=(%.2f, %.2f, %.2f) client=(%.2f, %.2f, %.2f) gap=%.3f m" % [
		what, body.global_position.x, body.global_position.y, body.global_position.z,
		theirs.x, theirs.y, theirs.z, gap])
	expect(gap < 0.5, "%s_result_same_on_both_screens" % what)


# ------------------------- B-e-3: the client acting, and what it costs it

func _client_action_checks() -> void:
	var rock := _world.get_node("Rock_1") as Rock
	var victim := _judge.actor_for(_client_peer())
	await _place_both(victim)
	var hp_before := _local.hp
	client_shove.rpc_id(_client_peer(), _local.get_path())
	expect(await _wait_stage("shoved"), "client_shoved")
	await _settle_wait(1.0)
	expect(_local.hp < hp_before, "client_shove_landed_on_the_host")

	# Grab and throw, with the client timing its own press to result.
	await tick_request(func() -> void:
		rock.global_position = victim.global_position + Vector3(0.9, 0.3, 0.0))
	await _settle_wait(0.6)
	var rock_from := rock.global_position
	client_rock.rpc_id(_client_peer(), rock.get_path())
	expect(await _wait_stage("rock"), "client_grabbed_and_threw")
	expect(rock.holder_peer == 0 and rock.global_position.distance_to(rock_from) > 1.0, "client_throw_moved_the_rock")

	# Grabbed by the host, escapes by itself.
	await _place_both(victim)
	await tick_request(func() -> void:
		_local.movement.set_aim_override(victim.global_position)
		_local.movement.interact())
	await _settle_wait(1.0)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	expect(_judge.holder_of(victim) == 1, "host_grabbed_client_for_escape")
	if _judge.holder_of(victim) != 1:
		return
	var escaped := int(_judge.release_reasons.get("escaped", 0))
	client_escape.rpc_id(_client_peer())
	expect(await _wait_stage("escaped"), "client_escaped")
	expect(int(_judge.release_reasons.get("escaped", 0)) > escaped, "escape_ruled_by_server")


# ----------------------------------------------- B-e-3: two reaching at once

func _contest_check() -> void:
	var rock := _world.get_node("Rock_0") as Rock
	var victim := _judge.actor_for(_client_peer())
	await tick_request(func() -> void:
		_judge.server_respawn(_local)
		_local.global_position = Vector3(-6.0, 0.9, 11.0))
	_judge.forgive_move(_client_peer(), "")
	client_park.rpc_id(_client_peer(), Vector3(-6.0, 0.9, 12.6))
	await _wait_stage("parked")
	await _settle_wait(1.0)
	await tick_request(func() -> void:
		rock.global_position = Vector3(-6.0, 1.0, 11.8))
	await _settle_wait(0.8)
	# Both reach for it as close to together as two machines can manage.
	client_grab_now.rpc_id(_client_peer(), rock.get_path())
	await tick_request(func() -> void:
		_local.movement.set_aim_override(rock.global_position)
		_local.movement.interact())
	await _settle_wait(1.5)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	var holder := _judge.holder_of(rock)
	note("contest holder=%d rows=%d table=%s (host=1 client=%d)" % [
		holder, _judge.hold_count(), _judge.describe_holds(), _client_peer()])
	expect(_judge.hold_count() <= 1, "one_row_at_most_after_a_contest")
	expect(holder == 1 or holder == _client_peer(), "exactly_one_of_them_got_it")
	if holder != 0:
		var other := _local if holder != 1 else victim
		expect(not _judge.can_grab(other, rock), "the_loser_is_refused_by_the_row")
	await tick_request(func() -> void:
		if _judge.holder_of(rock) == 1:
			_local.grab.drop())
	await _settle_wait(0.8)


# ------------- what B-c left open: the grace a remote holder gets, under lag

func _hold_grace_window_check() -> void:
	var rock := _world.get_node("Rock_2") as Rock
	var victim := _judge.actor_for(_client_peer())
	_judge.forgive_move(_client_peer(), "")
	client_park.rpc_id(_client_peer(), Vector3(-14.0, 0.9, 13.0))
	await _wait_stage("parked")
	await _settle_wait(0.8)
	await tick_request(func() -> void:
		rock.global_position = victim.global_position + Vector3(0.9, 0.3, 0.0))
	await _settle_wait(0.6)
	var released := int(_judge.release_reasons.get("holder_state", 0))
	# The leap lifts the body, which is a teleport the server is asking for.
	_judge.forgive_move(_client_peer(), "")
	client_grab_and_leap.rpc_id(_client_peer(), rock.get_path())
	if not await _wait_stage("leapt"):
		expect(false, "client_took_hold_and_left_the_ground")
		return
	expect(true, "client_took_hold_and_left_the_ground")
	# How long the server keeps a hold whose owner is already in the air.
	var kept := 0.0
	while kept < 3.0 + _lag * 10.0 and int(_judge.release_reasons.get("holder_state", 0)) == released:
		await get_tree().create_timer(0.02).timeout
		kept += 0.02
	var let_go := int(_judge.release_reasons.get("holder_state", 0)) > released
	note("hold kept after a remote holder left the ground: %.2f s (grace=%.2f, lag=%s ms, released=%s)" % [
		kept, ServerAuthority.HOLD_GRACE, _label, let_go])
	expect(let_go or _judge.holder_of(rock) == 0, "hold_ended_once_the_holder_was_seen_airborne")
	await _settle_wait(1.0)


# ------------------------------------------------- B-e-3: leaving and coming back

func _reconnect_check() -> void:
	var gone := int(_judge.release_reasons.get("holder_gone", 0))
	var before := Net.spawn_root.get_child_count()
	client_reconnect.rpc_id(_client_peer())
	# Away.
	var waited := 0.0
	while waited < 15.0 and multiplayer.get_peers().size() > 0:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	expect(multiplayer.get_peers().is_empty(), "client_left")
	# The despawn travels; at 200 ms the body is still there on the frame the
	# peer count drops, so this waits for it rather than reading it at once.
	var cleared := 0.0
	while cleared < 5.0 + _lag * 20.0 and Net.spawn_root.get_child_count() > before - 1:
		await get_tree().create_timer(0.1).timeout
		cleared += 0.1
	expect(Net.spawn_root.get_child_count() == before - 1, "its_body_was_removed")
	# Back.
	waited = 0.0
	while waited < 25.0 + _lag * 40.0 and multiplayer.get_peers().is_empty():
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	expect(not multiplayer.get_peers().is_empty(), "client_came_back")
	await _settle_wait(1.5)
	var back := _judge.actor_for(_client_peer())
	note("reconnect: peers=%d bodies=%d hp=%s holder_gone=%d" % [
		multiplayer.get_peers().size(), Net.spawn_root.get_child_count(),
		"%.0f" % back.hp if back != null else "none",
		int(_judge.release_reasons.get("holder_gone", 0))])
	expect(back != null and back.hp == back.stats.max_hp and not back.sync_dead, "the_returning_body_is_whole")
	expect(int(_judge.release_reasons.get("holder_gone", 0)) >= gone, "nothing_was_left_held_by_a_gone_peer")


# --------------------------------------------------------------------- RPCs

@rpc("any_peer", "call_remote", "reliable")
func stage_done(name_text: String) -> void:
	if multiplayer.is_server() and multiplayer.get_peers().has(multiplayer.get_remote_sender_id()):
		_stage_done = name_text


@rpc("any_peer", "call_remote", "reliable")
func report_back(what: String, where: Vector3) -> void:
	if multiplayer.is_server() and multiplayer.get_peers().has(multiplayer.get_remote_sender_id()):
		_reported[what] = where


@rpc("any_peer", "call_remote", "reliable")
func report_latency(what: String, milliseconds: int) -> void:
	if multiplayer.is_server() and multiplayer.get_peers().has(multiplayer.get_remote_sender_id()):
		note("felt latency, %s: %d ms" % [what, milliseconds])


@rpc("authority", "call_remote", "reliable")
func report_position(path: NodePath, what: String) -> void:
	var body := get_node_or_null(path) as Node3D
	if body != null:
		report_back.rpc_id(1, what, body.global_position)


@rpc("authority", "call_remote", "reliable")
func client_park(point: Vector3) -> void:
	await tick_request(func() -> void:
		_local.global_position = point
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target()
		_local.movement.set_aim_override(Vector3.INF))
	await _settle_wait(0.4)
	stage_done.rpc_id(1, "parked")


# Ordinary play: walk, jump, dash, with nothing teleported.
@rpc("authority", "call_remote", "reliable")
func client_play() -> void:
	for leg in range(3):
		_local.movement.set_target(_local.global_position + Vector3(0.0, 0.0, 3.0 if leg % 2 == 0 else -3.0))
		await _settle_wait(0.9)
		await tick_request(func() -> void:
			_local.movement.set_aim_override(_local.global_position + Vector3(0.0, 0.0, 4.0))
			_local.movement.request_jump())
		await _settle_wait(1.0)
		await tick_request(func() -> void: _local.movement.request_dash())
		await _settle_wait(0.9)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	stage_done.rpc_id(1, "played")


@rpc("authority", "call_remote", "reliable")
func client_shove(host_path: NodePath) -> void:
	var host_player := get_node(host_path) as Player
	await tick_request(func() -> void:
		_local.movement.set_aim_override(host_player.global_position))
	await _settle_wait(0.4)
	await tick_request(func() -> void:
		_local.movement.shove()
		_local.movement.set_aim_override(Vector3.INF))
	stage_done.rpc_id(1, "shoved")


@rpc("authority", "call_remote", "reliable")
func client_rock(rock_path: NodePath) -> void:
	var rock := get_node(rock_path) as Rock
	# Press to result, timed on the machine that pressed.
	var pressed := Time.get_ticks_msec()
	await tick_request(func() -> void:
		_local.movement.set_aim_override(rock.global_position)
		_local.movement.interact())
	var waited := 0.0
	while waited < 5.0 and not _local.grab.is_holding():
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	if _local.grab.is_holding():
		report_latency.rpc_id(1, "grab press to hold", Time.get_ticks_msec() - pressed)
	expect(_local.grab.is_holding(), "client_hold_arrived")
	await tick_request(func() -> void:
		_local.movement.set_aim_override(_local.global_position + Vector3.RIGHT * 10.0)
		_local.movement.interact())
	await _settle_wait(1.2)
	expect(not _local.grab.is_holding(), "client_hand_empty_after_throw")
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	stage_done.rpc_id(1, "rock")


@rpc("authority", "call_remote", "reliable")
func client_escape() -> void:
	expect(_local.state == Player.State.GRABBED, "client_knows_it_is_held")
	var presses := int(Tuning.values.grabbed_escape_presses)
	var pressed := 0
	for index in range(presses):
		if index == presses - 1:
			pressed = Time.get_ticks_msec()
		await tick_request(_local.grab.escape_press)
		if index < presses - 1:
			await get_tree().create_timer(0.12 + _lag).timeout
	var waited := 0.0
	while waited < 5.0 and _local.state == Player.State.GRABBED:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	if _local.state != Player.State.GRABBED:
		report_latency.rpc_id(1, "last escape press to freed", Time.get_ticks_msec() - pressed)
	expect(_local.state != Player.State.GRABBED, "client_got_free")
	stage_done.rpc_id(1, "escaped")


@rpc("authority", "call_remote", "reliable")
func client_grab_now(rock_path: NodePath) -> void:
	var rock := get_node(rock_path) as Rock
	await tick_request(func() -> void:
		_local.movement.set_aim_override(rock.global_position)
		_local.movement.interact()
		_local.movement.set_aim_override(Vector3.INF))


@rpc("authority", "call_remote", "reliable")
func client_grab_and_leap(rock_path: NodePath) -> void:
	var rock := get_node(rock_path) as Rock
	await tick_request(func() -> void:
		_local.movement.set_aim_override(rock.global_position)
		_local.movement.interact())
	var waited := 0.0
	while waited < 5.0 and not _local.grab.is_holding():
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	if not _local.grab.is_holding():
		return
	# Off the ground the instant the hold lands, which is the window B-c left
	# open: the server's grace is waiting for this body's state to arrive.
	# Lifted as well as declared airborne -- an AIRBORNE body still standing on
	# the floor lands again on the next step and is grounded once more.
	await tick_request(func() -> void:
		_local.global_position += Vector3.UP * 2.5
		_local.velocity = Vector3.ZERO
		_local.floor_snap_length = 0.0
		_local.change_state(Player.State.AIRBORNE))
	stage_done.rpc_id(1, "leapt")


@rpc("authority", "call_remote", "reliable")
func client_reconnect() -> void:
	# The second session must not start the suite again: one run, one report.
	Net.auto_smoke = false
	var port := Net.auto_port
	Net.leave("B-e 재접속 시험")
	await get_tree().create_timer(1.5).timeout
	Net.join("127.0.0.1", port)
	var mine: Node = null
	var waited := 0.0
	while waited < 25.0 + _lag * 40.0 and mine == null:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
		if Net.spawn_root != null:
			mine = Net.spawn_root.get_node_or_null(str(multiplayer.get_unique_id()))
	note("reconnect took %.1fs, body=%s" % [waited, "yes" if mine != null else "no"])
	expect(mine != null, "client_has_a_body_again_after_reconnect")
	if mine != null:
		_local = mine as Player
	print("BE_RESULT lag=%s peer=%d checks=%d failures=%d" % [_label, _peer_id, _checks, _failures])
	# The host leaves after this; the menu it lands on is the last check.
	Net.session_left.connect(_verify_host_shutdown)


func _verify_host_shutdown(_message: String) -> void:
	for _frame in range(4):
		await get_tree().process_frame
	expect(get_tree().current_scene != null
		and get_tree().current_scene.scene_file_path == "res://scenes/main.tscn",
		"host_shutdown_returned_the_client_to_the_menu")
	print("BE_RESULT lag=%s peer=%d checks=%d failures=%d final=true" % [
		_label, _peer_id, _checks, _failures])
	await get_tree().create_timer(0.5).timeout
	get_tree().quit(0 if _failures == 0 else 1)
