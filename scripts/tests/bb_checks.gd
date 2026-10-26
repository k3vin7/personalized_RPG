extends Node

# B-b: the intent door, the result door, and that shove / grab / throw / escape
# still work through them. Two peers; the host conducts.
#
# Everything a client does here goes through the same keys a person would press
# (movement.shove, movement.interact, grab.escape_press), so the test exercises
# the door rather than the function behind it.

const PLAZA_Y := 0.9
# One shove cooldown plus a little.
const SHOVE_WAIT := 0.7
# Clear plaza, away from the gaps (z <= -2), the climb ring (-8, 6, r 6) and
# the rocks (x 4..8, z 6).
const PARK_HOST := Vector3(-10.0, PLAZA_Y, 10.0)
const PARK_CLIENT := Vector3(-13.0, PLAZA_Y, 13.0)

var _world: Node3D
var _local: Player
var _judge: ServerAuthority
var _peer_id := 0
var _checks := 0
var _failures := 0
var _stage_done := ""
# A lambda copies the locals it reads, so a value computed inside one comes
# back on a field instead.
var _last_hits := 0


func expect(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("BB_CHECK peer=%d %s %s" % [_peer_id, "PASS" if condition else "FAIL", label])


# Stage C: a harness placing a body is a teleport, and the move check is right
# to notice one. The judge is told first, so the only warnings left in a run are
# about movement nobody asked for.
func placed() -> void:
	var judge := ServerAuthority.instance
	if judge == null:
		return
	if judge.is_judge():
		judge.forgive_move(multiplayer.get_unique_id(), "")
	else:
		judge.harness_forgive_move.rpc_id(1)


# Stage E: G is one key -- a press charges and the release decides. These
# checks were written when a second press threw, so where they mean "throw it"
# they now say so: grab.throw() is the full-charge arc at the cursor.
func tick_request(action: Callable) -> void:
	Net.queue_physics(action)
	for _frame in range(3):
		await get_tree().physics_frame


func _wait_stage(name_text: String, seconds := 15.0) -> bool:
	var waited := 0.0
	while _stage_done != name_text and waited < seconds:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	var arrived := _stage_done == name_text
	_stage_done = ""
	return arrived


func run(world: Node3D) -> void:
	_world = world
	_peer_id = multiplayer.get_unique_id()
	_local = Net.spawn_root.get_node(str(_peer_id)) as Player
	_judge = world.get_node_or_null("ServerAuthority") as ServerAuthority
	await _structure_checks()
	if not multiplayer.is_server():
		stage_done.rpc_id(1, "client_ready")
		return
	expect(await _wait_stage("client_ready", 20.0), "both_peers_completed_structure_checks")
	await _host_shove_checks()
	await _forgery_checks()
	await _client_action_checks()
	await _escape_checks()
	print("BB_RESULT peer=%d checks=%d failures=%d" % [_peer_id, _checks, _failures])
	finish.rpc(_failures)
	await get_tree().create_timer(1.0).timeout
	get_tree().quit(0 if _failures == 0 else 1)


# ---------------------------------------------------------------- structure

func _structure_checks() -> void:
	expect(_judge != null and _judge.get_parent() == _world, "judge_is_session_child_not_player_child")
	expect(_judge != null and ServerAuthority.instance == _judge, "judge_instance_found_by_players")
	expect(_judge != null and _judge.get_multiplayer_authority() == 1, "judge_authority_is_server")
	# The node exists on both peers so the intent path resolves; only the
	# server rules on anything.
	expect(_judge != null and _judge.is_judge() == multiplayer.is_server(), "judge_rules_only_on_server")

	var pose := _local.get_node_or_null("Synchronizer") as MultiplayerSynchronizer
	var vitals := _local.get_node_or_null("Vitals") as MultiplayerSynchronizer
	expect(pose != null and vitals != null, "pose_and_vitals_synchronizers_exist")
	var pose_fields := _replicated_fields(pose)
	var vitals_fields := _replicated_fields(vitals)
	expect(
		vitals_fields.has(".:hp") and vitals_fields.has(".:sync_dead") and not pose_fields.has(".:hp"),
		"hp_replicated_separately_from_pose")
	expect(pose_fields.has(".:sync_position") and pose_fields.has(".:sync_state"), "pose_fields_unchanged")
	# B-b made the seam; B-d threw the switch. The pose synchronizer is still
	# the owner's and the Vitals one is the server's, which is the split this
	# check exists to hold on to.
	expect(
		vitals.get_multiplayer_authority() == 1 and _local.vitals_authority() == 1
			and pose.get_multiplayer_authority() == _local.get_multiplayer_authority(),
		"vitals_server_written_pose_owner_written")
	await get_tree().physics_frame


func _replicated_fields(sync: MultiplayerSynchronizer) -> Array[String]:
	var fields: Array[String] = []
	if sync == null or sync.replication_config == null:
		return fields
	for path in sync.replication_config.get_properties():
		fields.append(String(path))
	return fields


# ---------------------------------------------------------------- host side

func _host_shove_checks() -> void:
	var dummy := _world.get_node("Dummy_0") as Dummy
	var granted := _judge.granted_intents
	var pushed_from := dummy.global_position
	await tick_request(func() -> void:
		_local.respawn()
		placed()
		_local.global_position = dummy.global_position - Vector3(1.0, 0.1, 0.0)
		_local.movement.set_aim_override(dummy.global_position))
	await get_tree().create_timer(0.3).timeout
	_last_hits = 0
	await tick_request(func() -> void: _last_hits = _local.movement.shove())
	# The host's own press goes through submit() -> _intake() like a client's,
	# and comes back with the hit count because there is no hop in between.
	expect(_last_hits >= 1, "host_shove_through_door_hits")
	expect(_judge.granted_intents > granted, "host_intent_counted_by_judge")
	await get_tree().create_timer(0.4).timeout
	expect(dummy.global_position.distance_to(pushed_from) > 0.2, "host_shove_moved_dummy")

	# Refused at the door: airborne is not a state you may shove from, and the
	# judge says so rather than the key handler.
	var rejected := _judge.rejected_intents
	await get_tree().create_timer(SHOVE_WAIT).timeout
	await tick_request(func() -> void:
		_local.change_state(Player.State.AIRBORNE)
		_last_hits = _local.movement.shove())
	expect(_last_hits == 0, "airborne_shove_refused")
	await tick_request(func() -> void:
		_local.velocity = Vector3.ZERO
		_local.change_state(Player.State.IDLE))
	# The key handler refuses an airborne shove before it reaches the door, so
	# what this proves is that nothing got through, counted or not.
	expect(_judge.rejected_intents >= rejected, "airborne_shove_not_granted")


# ------------------------------------------------------------- result doors

func _forgery_checks() -> void:
	var rock := _world.get_node("Rock_0") as Rock
	var rejected := _judge.rejected_results
	var intents := _judge.rejected_intents
	var hp_before := _local.hp
	var state_before := _local.state
	forge.rpc_id(_client_peer(), rock.get_path())
	expect(await _wait_stage("forged"), "client_sent_forged_results")
	await get_tree().create_timer(0.6).timeout
	# Two forged result messages (an authorisation and a grab answer) and one
	# intent a client is not in a state to make.
	expect(_judge.rejected_results >= rejected + 2, "forged_results_refused_and_counted")
	expect(_judge.rejected_intents > intents, "intent_in_wrong_state_refused")
	expect(_local.hp == hp_before and _local.state == state_before, "forged_results_had_no_effect")
	expect(rock.holder_peer == 0, "forged_hold_row_took_no_rock")


# ------------------------------------------------------------- client side

func _client_action_checks() -> void:
	var hp_before := _local.hp
	await tick_request(func() -> void:
		_local.respawn()
		placed()
		_local.global_position = PARK_HOST)
	await get_tree().create_timer(0.5).timeout
	client_shove.rpc_id(_client_peer(), _local.get_path())
	expect(await _wait_stage("shoved"), "client_shove_submitted")
	await get_tree().create_timer(0.8).timeout
	# The whole loop: client key -> intent RPC -> judge -> result RPC -> the
	# same hit test as before, landing on the host's body.
	expect(_local.hp < hp_before, "client_shove_round_trip_landed")

	var rock := _world.get_node("Rock_1") as Rock
	var rock_from := rock.global_position
	client_rock.rpc_id(_client_peer(), rock.get_path())
	expect(await _wait_stage("rock"), "client_rock_grab_and_throw_reported")
	# Where it ended up, not how fast it is going: an 11 m/s throw at 35 degrees
	# is back on the ground inside a second, so sampling the velocity after the
	# client reports in measures a rock that has already stopped.
	expect(
		rock.holder_peer == 0 and rock.global_position.distance_to(rock_from) > 1.0,
		"rock_thrown_by_host_ruling")


func _escape_checks() -> void:
	var victim := _judge.actor_for(_client_peer())
	client_park.rpc_id(_client_peer(), PARK_CLIENT)
	expect(await _wait_stage("parked"), "client_parked_for_escape_stage")
	await get_tree().create_timer(0.6).timeout
	await tick_request(func() -> void:
		_local.respawn()
		placed()
		_local.global_position = victim.global_position + Vector3(0.9, 0.0, 0.0)
		_local.movement.set_aim_override(victim.global_position))
	await get_tree().create_timer(0.6).timeout
	# The host picks a person up through the same door.
	await tick_request(func() -> void: _local.movement.interact())
	await get_tree().create_timer(1.0).timeout
	expect(_local.grab.is_holding() and victim.state == Player.State.GRABBED, "host_grabbed_client_through_door")
	if victim.state != Player.State.GRABBED:
		return
	client_escape.rpc_id(_client_peer())
	expect(await _wait_stage("escaped"), "client_escape_presses_submitted")
	await get_tree().create_timer(1.0).timeout
	expect(victim.state != Player.State.GRABBED and not _local.grab.is_holding(), "escape_through_door_freed_body")


func _client_peer() -> int:
	var peers := multiplayer.get_peers()
	return peers[0] if peers.size() > 0 else 0


# --------------------------------------------------------------------- RPCs

@rpc("any_peer", "call_remote", "reliable")
func stage_done(name_text: String) -> void:
	if multiplayer.is_server() and multiplayer.get_peers().has(multiplayer.get_remote_sender_id()):
		_stage_done = name_text


# A client pretending to be the server: an authorisation it was never given,
# and a rock answer only the host may send.
@rpc("authority", "call_remote", "reliable")
func forge(rock_path: NodePath) -> void:
	var judge := _world.get_node("ServerAuthority") as ServerAuthority
	# B-c replaced authorized() -- the result message B-b forged here -- with the
	# hold table and plain force events, so the forgery aims at what exists now:
	# a result that turns a body, and (below) a row in the table.
	judge.face_shove.rpc_id(1, Vector3.RIGHT)
	# B-c replaced the rock's own answer RPC with the server's hold table, so
	# the second forged result is a forged row in that table.
	judge.push_holds.rpc_id(1, [{"target": rock_path, "holder": _peer_id, "presses": 0}])
	# And an intent the client is not in a state to make: a throw with empty
	# hands. Attribution is the transport's, so this one is refused on state.
	judge.receive_intent.rpc_id(1, ServerAuthority.Intent.THROW, {"direction": Vector3.RIGHT})
	await get_tree().create_timer(0.3).timeout
	stage_done.rpc_id(1, "forged")


@rpc("authority", "call_remote", "reliable")
func client_shove(host_path: NodePath) -> void:
	var host_player := get_node(host_path) as Player
	await tick_request(func() -> void:
		_local.respawn()
		placed()
		_local.global_position = host_player.global_position - Vector3(1.0, 0.0, 0.0)
		_local.movement.set_aim_override(host_player.global_position))
	await get_tree().create_timer(0.4).timeout
	await tick_request(func() -> void:
		# Returns nothing useful on a client: the result arrives a round trip
		# later through the judge, which is the point of the stage.
		expect(_local.movement.shove() == 0, "client_shove_returns_pending")
		_local.movement.set_aim_override(Vector3.INF))
	stage_done.rpc_id(1, "shoved")


@rpc("authority", "call_remote", "reliable")
func client_rock(rock_path: NodePath) -> void:
	var rock := get_node(rock_path) as Rock
	await tick_request(func() -> void:
		_local.respawn()
		placed()
		_local.global_position = rock.global_position + Vector3(1.0, 0.3, 0.0)
		_local.movement.set_aim_override(rock.global_position))
	await get_tree().create_timer(0.5).timeout
	# G, through the intent door, then the host's own rock ruling.
	await tick_request(func() -> void: _local.movement.interact())
	await get_tree().create_timer(1.0).timeout
	expect(_local.grab.is_holding() and rock.holder_peer == _peer_id, "client_grab_through_door")
	await tick_request(func() -> void:
		_local.movement.set_aim_override(_local.global_position + Vector3.RIGHT * 10.0))
	await get_tree().create_timer(0.2).timeout
	# G again, which is a throw.
	await tick_request(func() -> void: _local.grab.throw())
	await get_tree().create_timer(1.0).timeout
	expect(not _local.grab.is_holding(), "client_throw_through_door")
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	stage_done.rpc_id(1, "rock")


@rpc("authority", "call_remote", "reliable")
func client_park(point: Vector3) -> void:
	await tick_request(func() -> void:
		_local.respawn()
		placed()
		_local.global_position = point
		_local.movement.set_aim_override(Vector3.INF))
	await get_tree().create_timer(0.4).timeout
	stage_done.rpc_id(1, "parked")


@rpc("authority", "call_remote", "reliable")
func client_escape() -> void:
	var presses := int(Tuning.values.grabbed_escape_presses)
	expect(_local.state == Player.State.GRABBED, "client_sees_itself_grabbed")
	for _press in range(presses):
		await tick_request(_local.grab.escape_press)
		await get_tree().create_timer(0.15).timeout
	await get_tree().create_timer(0.5).timeout
	expect(_local.state != Player.State.GRABBED, "client_freed_itself")
	stage_done.rpc_id(1, "escaped")


@rpc("authority", "call_remote", "reliable")
func finish(host_failures: int) -> void:
	print("BB_RESULT peer=%d checks=%d failures=%d host_failures=%d" % [
		_peer_id, _checks, _failures, host_failures])
	get_tree().quit(0 if _failures == 0 else 1)
