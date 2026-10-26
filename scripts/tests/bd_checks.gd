extends Node

# B-d: HP, the alive flag, damage, stun, the fall, death and the way back are
# the server's. Two peers; the host conducts. The pose stays the owner's, which
# is half of what these checks are for -- the other half is that a client
# cannot write its own vitals or claim a fall that did not happen.

const PARK_HOST := Vector3(-10.0, 0.9, 10.0)
const PARK_CLIENT := Vector3(-14.0, 0.9, 13.0)
const DROP_SPOT := Vector3(-6.0, 0.9, 11.0)

var _world: Node3D
var _local: Player
var _judge: ServerAuthority
var _peer_id := 0
var _checks := 0
var _failures := 0
var _stage_done := ""


func expect(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("BD_CHECK peer=%d %s %s" % [_peer_id, "PASS" if condition else "FAIL", label])


func note(line: String) -> void:
	print("BD_NOTE peer=%d %s" % [_peer_id, line])


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
	await _fall_damage_checks()
	await _damage_and_stun_checks()
	await _death_checks()
	await _client_vitals_checks()
	print("BD_RESULT peer=%d checks=%d failures=%d" % [_peer_id, _checks, _failures])
	finish.rpc(_failures)
	await get_tree().create_timer(1.0).timeout
	get_tree().quit(0 if _failures == 0 else 1)


# ---------------------------------------------------------------- structure

func _structure_checks() -> void:
	var pose := _local.get_node_or_null("Synchronizer") as MultiplayerSynchronizer
	var vitals := _local.get_node_or_null("Vitals") as MultiplayerSynchronizer
	expect(Player.VITALS_OWNED_BY_SERVER, "vitals_switch_is_on")
	expect(vitals != null and vitals.get_multiplayer_authority() == 1, "vitals_authority_is_server")
	# The pose did not move with it: the player node is still the owner's.
	expect(
		pose != null and pose.get_multiplayer_authority() == _local.get_multiplayer_authority()
			and _local.get_multiplayer_authority() == String(_local.name).to_int(),
		"pose_authority_is_still_the_owner")
	expect(_local.vitals_authority() == 1, "vitals_authority_helper_agrees")
	expect(_local.vitals_are_mine() == multiplayer.is_server(), "only_server_owns_vitals")
	# The owner-side writers are gone, not merely unused.
	expect(
		not _local.has_method("die") and not _local.has_method("_take_damage")
			and not _local.has_method("_check_death"),
		"owner_side_vitals_writers_removed")
	expect(_local.has_method("enter_dead_now") and _local.has_method("apply_respawn"), "owner_applies_what_it_is_told")
	await get_tree().physics_frame


# ------------------------------------------------------------------- falling

func _fall_damage_checks() -> void:
	# The documented measurements: 5 m hurts, 3.5 m does not.
	var deep := await _drop(5.0)
	var shallow := await _drop(3.5)
	note("fall 5m damage=%.3f height=%.3f | 3.5m damage=%.3f height=%.3f" % [
		deep["damage"], deep["height"], shallow["damage"], shallow["height"]])
	# The documented pair is 5 m -> 8 and 3.5 m -> 0. A drop is measured from
	# where the body was put, so the height carries a few centimetres of
	# settling with it; the damage is 8 per metre over the 4 m threshold, which
	# makes a centimetre worth 0.08.
	expect(absf(float(deep["damage"]) - 8.0) < 0.5, "fall_5m_costs_8_as_before")
	expect(shallow["damage"] == 0.0, "fall_3_5m_costs_nothing_as_before")

	# Turned off by the debug flag, the same drop costs nothing.
	Tuning.values.fall_damage_enabled = false
	var disabled := await _drop(5.0)
	Tuning.values.fall_damage_enabled = true
	expect(disabled["damage"] == 0.0, "fall_damage_flag_still_works")

	# A client's own drop, ruled by the server from the client's report.
	var client := _judge.actor_for(_client_peer())
	var mismatches := _judge.fall_mismatches
	client_park.rpc_id(_client_peer(), PARK_CLIENT)
	expect(await _wait_stage("parked"), "client_parked_before_its_drop")
	await get_tree().create_timer(0.6).timeout
	client_drop.rpc_id(_client_peer(), 5.0)
	expect(await _wait_stage("dropped"), "client_drop_reported")
	await get_tree().create_timer(0.5).timeout
	note("client fall hp=%.0f mismatches=%d" % [client.hp, _judge.fall_mismatches])
	expect(client.hp < client.stats.max_hp, "server_charged_the_client_for_its_fall")
	expect(_judge.fall_mismatches == mismatches, "honest_report_raised_no_warning")
	await tick_request(func() -> void: _judge.server_respawn(client))
	await get_tree().create_timer(0.5).timeout

	# A lie. The server has the body's history and uses that instead.
	mismatches = _judge.fall_mismatches
	var hp_before := client.hp
	client_fake_fall.rpc_id(_client_peer())
	expect(await _wait_stage("faked"), "client_sent_a_false_fall_report")
	await get_tree().create_timer(0.5).timeout
	note("after false report hp=%.0f mismatches=%d" % [client.hp, _judge.fall_mismatches])
	expect(_judge.fall_mismatches > mismatches, "false_fall_report_logged_a_mismatch")
	expect(client.hp == hp_before and not client.sync_dead, "false_fall_report_did_no_damage")


func _drop(height: float) -> Dictionary:
	await tick_request(func() -> void:
		_judge.server_respawn(_local)
		_local.global_position = DROP_SPOT)
	await get_tree().create_timer(0.6).timeout
	var before := _local.hp
	await tick_request(func() -> void:
		_local.global_position = DROP_SPOT + Vector3.UP * height
		_local.velocity = Vector3.ZERO
		_local.floor_snap_length = 0.0
		_local.change_state(Player.State.AIRBORNE))
	var waited := 0.0
	while waited < 4.0 and not _local.is_grounded_state():
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	for _frame in range(6):
		await get_tree().physics_frame
	return {"damage": before - _local.hp, "height": _local.last_fall_height}


# -------------------------------------------------------- damage and stun

func _damage_and_stun_checks() -> void:
	var client := _judge.actor_for(_client_peer())
	await tick_request(func() -> void:
		_judge.server_respawn(_local)
		_judge.server_respawn(client))
	client_park.rpc_id(_client_peer(), PARK_CLIENT)
	expect(await _wait_stage("parked"), "client_parked")
	await get_tree().create_timer(0.6).timeout

	# A shove from a stranger: the server writes the HP and tells the owner to
	# be stunned. The owner writes neither number.
	var hp_before := client.hp
	await tick_request(func() -> void:
		_judge.send_force(client, ForceSystem.make_event(
			ForceSystem.Kind.SHOVE, Vector3(1.0, 0.1, 0.0), 5.0, 10.0, 1, false,
			Tuning.values.shove_damage, Tuning.values.shove_stun_time)))
	# Read inside the stun. shove_stun_time is 0.4 s, so half a second later
	# the body is correctly standing up again and the check measured nothing.
	await get_tree().create_timer(0.2).timeout
	note("stranger shove client hp=%.0f-%.0f state=%s" % [
		hp_before, client.hp, Player.State.keys()[client.state]])
	expect(is_equal_approx(client.hp, hp_before - Tuning.values.shove_damage), "server_wrote_the_damage")
	expect(client.state == Player.State.STUNNED, "owner_applied_the_stun_it_was_told")
	await get_tree().create_timer(Tuning.values.shove_stun_time + 0.5).timeout
	expect(client.state != Player.State.STUNNED, "stun_wore_off_on_its_own")

	# A team mate's push on a body already in the air: no damage, no stun.
	await get_tree().create_timer(Tuning.values.shove_stun_time + 0.6).timeout
	await tick_request(func() -> void: _judge.server_respawn(client))
	await get_tree().create_timer(0.6).timeout
	hp_before = client.hp
	await tick_request(func() -> void:
		_judge.send_force(client, ForceSystem.make_event(
			ForceSystem.Kind.THROW, Vector3.UP, 14.0, 0.0, 1, true, 0.0, 0.0)))
	await get_tree().create_timer(0.4).timeout
	await tick_request(func() -> void:
		_judge.send_force(client, ForceSystem.make_event(
			ForceSystem.Kind.SHOVE, Vector3(1.0, 0.2, 0.0), 5.0, 10.0, 1, true,
			Tuning.values.shove_damage, Tuning.values.shove_stun_time)))
	await get_tree().create_timer(0.4).timeout
	note("ally push in the air hp=%.0f-%.0f state=%s" % [
		hp_before, client.hp, Player.State.keys()[client.state]])
	expect(client.hp == hp_before, "ally_push_in_the_air_costs_nothing")
	expect(client.state != Player.State.STUNNED, "no_stun_in_the_air")
	await get_tree().create_timer(1.5).timeout


# ----------------------------------------------------------- death and back

func _death_checks() -> void:
	var client := _judge.actor_for(_client_peer())
	await tick_request(func() -> void: _judge.server_respawn(client))
	await get_tree().create_timer(0.6).timeout

	# Lethal damage: one death, ruled once, with the flag replicated out.
	await tick_request(func() -> void:
		_judge.send_force(client, ForceSystem.make_event(
			ForceSystem.Kind.SHOVE, Vector3(1.0, 0.1, 0.0), 2.0, 0.0, 1, false, 1000.0, 1.0)))
	await get_tree().create_timer(0.6).timeout
	expect(client.sync_dead and client.hp == 0.0, "server_ruled_the_death")
	expect(client.state == Player.State.DEAD, "owner_entered_dead_when_told")
	# B-a's rule: nothing moves a dead body out of DEAD but a respawn.
	await tick_request(func() -> void:
		_judge.send_force(client, ForceSystem.make_event(
			ForceSystem.Kind.SHOVE, Vector3.UP, 20.0, 0.0, 1, false, 0.0, 1.0)))
	await get_tree().create_timer(0.4).timeout
	expect(client.sync_dead and client.state == Player.State.DEAD, "dead_stays_dead_under_more_force")

	# And comes back on the server's clock, without the owner asking.
	var waited := 0.0
	while waited < Tuning.values.respawn_delay + 3.0 and client.sync_dead:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	note("respawn arrived after %.1fs hp=%.0f state=%s" % [
		waited, client.hp, Player.State.keys()[client.state]])
	expect(not client.sync_dead and client.hp == client.stats.max_hp, "server_brought_it_back")
	await get_tree().create_timer(0.8).timeout
	expect(client.state != Player.State.DEAD, "owner_left_dead_on_respawn")

	# The kill plane is the server's check, from the position it has.
	await tick_request(func() -> void:
		_judge.server_respawn(_local)
		_local.global_position = Vector3(0.0, Tuning.values.kill_plane_y - 2.0, 8.0))
	await get_tree().create_timer(0.5).timeout
	expect(_local.sync_dead and _local.state == Player.State.DEAD, "kill_plane_ruled_by_server")
	await get_tree().create_timer(Tuning.values.respawn_delay + 1.2).timeout
	expect(not _local.sync_dead and _local.state != Player.State.DEAD, "kill_plane_death_came_back")


# ------------------------------------------------- what a client cannot do

func _client_vitals_checks() -> void:
	var client := _judge.actor_for(_client_peer())
	await tick_request(func() -> void: _judge.server_respawn(client))
	await get_tree().create_timer(0.6).timeout
	var rejected := _judge.rejected_results
	client_forge_vitals.rpc_id(_client_peer())
	expect(await _wait_stage("forged"), "client_tried_to_write_its_own_vitals")
	await get_tree().create_timer(0.8).timeout
	note("after client forgery hp=%.0f dead=%s rejected_results=%d" % [
		client.hp, client.sync_dead, _judge.rejected_results])
	expect(client.hp == client.stats.max_hp, "client_hp_write_did_not_reach_the_server")
	expect(not client.sync_dead, "client_cannot_declare_itself_dead")
	expect(_judge.rejected_results >= rejected + 2, "forged_vitals_results_refused")


# --------------------------------------------------------------------- RPCs

@rpc("any_peer", "call_remote", "reliable")
func stage_done(name_text: String) -> void:
	if multiplayer.is_server() and multiplayer.get_peers().has(multiplayer.get_remote_sender_id()):
		_stage_done = name_text


@rpc("authority", "call_remote", "reliable")
func client_park(point: Vector3) -> void:
	await tick_request(func() -> void:
		_local.global_position = point
		_local.movement.set_aim_override(Vector3.INF))
	await get_tree().create_timer(0.4).timeout
	stage_done.rpc_id(1, "parked")


@rpc("authority", "call_remote", "reliable")
func client_drop(height: float) -> void:
	await tick_request(func() -> void:
		_local.global_position = _local.global_position + Vector3.UP * height
		_local.velocity = Vector3.ZERO
		_local.floor_snap_length = 0.0
		_local.change_state(Player.State.AIRBORNE))
	var waited := 0.0
	while waited < 4.0 and not _local.is_grounded_state():
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	for _frame in range(6):
		await get_tree().physics_frame
	# The owner no longer knows what the drop cost: it reported and the server
	# answered by replicating the HP back.
	note("own fall height=%.3f hp=%.1f" % [_local.last_fall_height, _local.hp])
	expect(_local.hp < _local.stats.max_hp, "client_sees_the_servers_hp_after_its_fall")
	stage_done.rpc_id(1, "dropped")


# A fall that never happened, claimed straight at the judge.
@rpc("authority", "call_remote", "reliable")
func client_fake_fall() -> void:
	await tick_request(func() -> void:
		ServerAuthority.submit_intent(_local, ServerAuthority.Intent.FALL, {
			"peak": _local.global_position.y + 400.0,
			"land": _local.global_position.y,
		}))
	await get_tree().create_timer(0.4).timeout
	stage_done.rpc_id(1, "faked")


# Writing its own HP, and sending the two result messages that would kill and
# revive a body.
@rpc("authority", "call_remote", "reliable")
func client_forge_vitals() -> void:
	var judge := _world.get_node("ServerAuthority") as ServerAuthority
	await tick_request(func() -> void:
		_local.hp = 1.0
		_local.sync_dead = true)
	judge.enter_dead.rpc_id(1)
	judge.apply_respawn.rpc_id(1)
	await get_tree().create_timer(0.8).timeout
	# The local write is not replicated and the next vitals packet overwrites
	# it: the client's own copy comes back to the server's number.
	note("client local write hp=%.0f dead=%s" % [_local.hp, _local.sync_dead])
	expect(_local.hp == _local.stats.max_hp, "local_hp_write_was_overwritten_by_the_server")
	expect(not _local.sync_dead, "local_dead_write_was_overwritten_by_the_server")
	stage_done.rpc_id(1, "forged")


@rpc("authority", "call_remote", "reliable")
func finish(host_failures: int) -> void:
	print("BD_RESULT peer=%d checks=%d failures=%d host_failures=%d" % [
		_peer_id, _checks, _failures, host_failures])
	get_tree().quit(0 if _failures == 0 else 1)
