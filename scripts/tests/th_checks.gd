extends Node

# TH: the one key with something in hand, after the 0.5 / 1.0 change.
#
#   let go before throw_hold_threshold (0.5 s)  -> put down, and no pose ever
#   held past it                                 -> the throw pose, from then on
#   held past throw_charge_max (1.0 s)           -> still the pose, charge full
#   let go                                       -> thrown
#
# Both peers run it on their own body with their own rock, because the key,
# the threshold and the pose are all the pressing machine's; the server only
# sees the intent that comes out at the end. The client reports its count.

const HOME := Vector3(0.0, 0.9, 11.0)
const CLIENT_HOME := Vector3(-6.0, 0.9, 11.0)
const ROCK_BESIDE := Vector3(0.9, -0.3, 0.0)

var _world: Node3D
var _local: Player
var _judge: ServerAuthority
var _peer_id := 0
var _checks := 0
var _failures := 0
var _stage_done := ""
var _client_result := PackedInt32Array()


func expect(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("TH_CHECK peer=%d %s %s" % [_peer_id, "PASS" if condition else "FAIL", label])


func note(line: String) -> void:
	print("TH_NOTE peer=%d %s" % [_peer_id, line])


func tick_request(action: Callable) -> void:
	Net.queue_physics(action)
	for _frame in range(3):
		await get_tree().physics_frame


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _wait_stage(name_text: String, limit := 25.0) -> bool:
	var waited := 0.0
	while _stage_done != name_text and waited < limit:
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
	if not multiplayer.is_server():
		stage_done.rpc_id(1, "client_ready")
		return
	expect(await _wait_stage("client_ready"), "both_peers_present")
	note("threshold %.2f s, charge max %.2f s" % [
		Tuning.values.throw_hold_threshold, Tuning.values.throw_charge_max])
	expect(is_equal_approx(Tuning.values.throw_hold_threshold, 0.5)
		and is_equal_approx(Tuning.values.throw_charge_max, 1.0), "the_defaults_are_half_a_second_and_one_second")
	await _park(HOME)
	var mine := _world.get_node("Rock_0") as Rock
	await _key_checks(mine)
	# The client's rock is put beside it by the server (rocks are the host's),
	# then the client runs the same sequence on its own machine.
	var mate := _judge.actor_for(_client_peer())
	var theirs := _world.get_node("Rock_1") as Rock
	client_park.rpc_id(_client_peer(), CLIENT_HOME)
	await _wait(1.0)
	await tick_request(func() -> void: _place_rock(theirs, mate.global_position))
	await _wait(0.5)
	client_run.rpc_id(_client_peer(), theirs.get_path())
	expect(await _wait_stage("client_done", 40.0), "client_finished_its_checks")
	if _client_result.size() == 2:
		note("client: checks=%d failures=%d" % [_client_result[0], _client_result[1]])
		expect(_client_result[1] == 0, "client_had_no_failures")
	print("TH_RESULT peer=%d checks=%d failures=%d" % [_peer_id, _checks, _failures])
	await _wait(1.0)
	get_tree().quit(0 if _failures == 0 else 1)


func _place_rock(rock: Rock, beside: Vector3) -> void:
	rock.freeze = false
	rock.global_position = beside + ROCK_BESIDE
	rock.linear_velocity = Vector3.ZERO
	rock.angular_velocity = Vector3.ZERO


func _take(rock: Rock) -> bool:
	if multiplayer.is_server():
		await tick_request(func() -> void: _place_rock(rock, _local.global_position))
		await _wait(0.4)
	await tick_request(func() -> void:
		_local.movement.set_aim_override(rock.global_position)
		_local.movement.interact())
	await _wait(0.8)
	return _local.grab.is_holding()


func _key_checks(rock: Rock) -> void:
	var threshold: float = Tuning.values.throw_hold_threshold
	var charge_max: float = Tuning.values.throw_charge_max

	# 1) A tap: put down, and the body never posed for a throw.
	expect(await _take(rock), "took_the_rock_for_the_tap")
	var posed := false
	await tick_request(func() -> void: _local.skills.press_slot(1))
	var held := 0.0
	while held < threshold * 0.5:
		await get_tree().physics_frame
		held += get_physics_process_delta_time()
		posed = posed or _local.predicted_action == ServerAuthority.Intent.THROW
	await tick_request(func() -> void: _local.skills.release_slot(1))
	await _wait(0.8)
	var at_feet := Vector2(rock.global_position.x - _local.global_position.x,
		rock.global_position.z - _local.global_position.z).length()
	note("tap %.2f s: posed=%s, holding=%s, rock %.2f m from the body" % [
		held, posed, _local.grab.is_holding(), at_feet])
	expect(not posed, "no_throw_pose_before_the_threshold")
	expect(not _local.grab.is_holding() and at_feet < 2.0, "a_tap_puts_it_down_at_the_feet")

	# 2) Held through the threshold, through full charge, and past it: the
	# pose arrives at the threshold and stays; the charge fills and holds.
	expect(await _take(rock), "took_the_rock_for_the_long_hold")
	var aim := _local.global_position + Vector3(4.0, 0.0, 0.0)
	await tick_request(func() -> void:
		_local.movement.set_aim_override(aim)
		_local.skills.press_slot(1))
	var pose_at := -1.0
	var lost_after := -1.0
	held = 0.0
	var long_hold := charge_max + 0.8
	while held < long_hold:
		await get_tree().physics_frame
		held += get_physics_process_delta_time()
		var posing := _local.predicted_action == ServerAuthority.Intent.THROW
		if posing and pose_at < 0.0:
			pose_at = held
		if pose_at >= 0.0 and not posing and lost_after < 0.0:
			lost_after = held
	var charge := _local.grab.charge_seconds()
	note("held %.2f s: pose from %.2f s (threshold %.2f), lost at %s, charge %.2f s (max %.2f)" % [
		held, pose_at, threshold, "never" if lost_after < 0.0 else "%.2f s" % lost_after,
		charge, charge_max])
	expect(pose_at >= threshold - 0.05 and pose_at <= threshold + 0.15, "the_throw_pose_starts_at_the_threshold")
	expect(lost_after < 0.0, "and_stays_while_the_key_is_down_past_full_charge")
	expect(charge >= charge_max, "the_charge_is_full_by_then")
	var from := rock.global_position
	await tick_request(func() -> void: _local.skills.release_slot(1))
	await _wait(1.5)
	var flew := Vector2(rock.global_position.x - from.x, rock.global_position.z - from.z).length()
	note("released after %.2f s: rock moved %.2f m, holding=%s, pose=%s" % [
		held, flew, _local.grab.is_holding(), _local.predicted_action])
	expect(not _local.grab.is_holding() and flew > 1.5, "letting_go_after_the_long_hold_throws")
	expect(_local.predicted_action == -1, "and_the_pose_is_gone_once_it_is_thrown")
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))


func _park(point: Vector3) -> void:
	await tick_request(func() -> void:
		if _judge != null:
			if _judge.is_judge():
				_judge.forgive_move(multiplayer.get_unique_id(), "")
			else:
				_judge.harness_forgive_move.rpc_id(1)
		_local.global_position = point
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target())
	await _wait(0.6)


# --------------------------------------------------------------------- RPCs

@rpc("any_peer", "call_remote", "reliable")
func stage_done(name_text: String) -> void:
	if multiplayer.is_server() and multiplayer.get_peers().has(multiplayer.get_remote_sender_id()):
		_stage_done = name_text


@rpc("any_peer", "call_remote", "reliable")
func report_result(values: PackedInt32Array) -> void:
	if multiplayer.is_server() and multiplayer.get_peers().has(multiplayer.get_remote_sender_id()):
		_client_result = values


@rpc("authority", "call_remote", "reliable")
func client_park(point: Vector3) -> void:
	await _park(point)


@rpc("authority", "call_remote", "reliable")
func client_run(rock_path: NodePath) -> void:
	var rock := get_node_or_null(rock_path) as Rock
	if rock != null:
		await _key_checks(rock)
	else:
		expect(false, "client_found_its_rock")
	print("TH_RESULT peer=%d checks=%d failures=%d" % [_peer_id, _checks, _failures])
	report_result.rpc_id(1, PackedInt32Array([_checks, _failures]))
	stage_done.rpc_id(1, "client_done")
