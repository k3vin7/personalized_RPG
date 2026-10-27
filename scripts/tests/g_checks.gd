extends Node

# Stage G, measured: the fall damage table the earlier stages set, the new
# ally_fall_death flag in both positions, and a cliff fall going all the way
# round to a respawn that both peers agree on.
#
# The flag only ever decides whether a party member's launch may be the death
# of you. The landing damage is taken either way -- the work order fixes that:
# the co-op launch is a finisher with a price.

const DROP_SPOT := Vector3(-2.0, 0.9, 11.0)
const PARK_CLIENT := Vector3(2.0, 0.9, 11.0)
# Past the +x edge of the plaza, which is the cliff, and well under the kill
# plane at -20.
const VOID_SPOT := Vector3(24.0, -26.0, 11.0)
# (h - fall_damage_min_height) x fall_damage_per_meter with the shipped numbers
# is (20 - 4) x 8 = 128, so this is lethal from full HP whatever rounding does.
const LETHAL_DROP := 20.0

var _world: Node3D
var _local: Player
var _judge: ServerAuthority
var _peer_id := 0
var _checks := 0
var _failures := 0
var _stage_done := ""
var _reported := {}
# A lambda copies the locals it reads, so anything worked out inside a
# tick_request comes back on a field.
var _hp := 0.0
var _dead := false


func expect(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("G_CHECK peer=%d %s %s" % [_peer_id, "PASS" if condition else "FAIL", label])


func note(line: String) -> void:
	print("G_NOTE peer=%d %s" % [_peer_id, line])


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
	await get_tree().create_timer(seconds).timeout


func _wait_stage(name_text: String) -> bool:
	var waited := 0.0
	while _stage_done != name_text and waited < 25.0:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	var arrived := _stage_done == name_text
	_stage_done = ""
	return arrived


func _client_peer() -> int:
	var peers := multiplayer.get_peers()
	return peers[0] if not peers.is_empty() else 0


func run(world: Node3D) -> void:
	_world = world
	await get_tree().create_timer(2.5).timeout
	_peer_id = multiplayer.get_unique_id()
	_local = Net.spawn_root.get_node(str(_peer_id)) as Player
	_judge = world.get_node_or_null("ServerAuthority") as ServerAuthority
	if not multiplayer.is_server():
		stage_done.rpc_id(1, "client_ready")
		return
	expect(await _wait_stage("client_ready"), "both_peers_present")
	var warnings := _judge.move_warnings
	await _fall_table_checks()
	await _ally_flag_checks()
	await _ally_void_checks()
	await _cliff_respawn_checks()
	expect(_judge.move_warnings == warnings, "no_move_warnings_during_stage_g")
	print("G_RESULT peer=%d checks=%d failures=%d" % [_peer_id, _checks, _failures])
	finish.rpc(_failures)
	await _wait(1.0)
	get_tree().quit(0 if _failures == 0 else 1)


# -------------------------------------------- the table the earlier stages set

func _fall_table_checks() -> void:
	var deep := await _drop(5.0, false)
	var shallow := await _drop(3.5, false)
	note("fall 5m damage=%.3f height=%.3f | 3.5m damage=%.3f height=%.3f" % [
		deep["damage"], deep["height"], shallow["damage"], shallow["height"]])
	expect(absf(float(deep["damage"]) - 8.0) < 0.5, "fall_5m_still_costs_8")
	expect(float(shallow["damage"]) == 0.0, "fall_3_5m_still_costs_nothing")


# ----------------------------------------------------------- ally_fall_death

func _ally_flag_checks() -> void:
	var was: bool = Tuning.values.ally_fall_death

	# Off: a party member's launch may hurt you all the way down to 1.
	Tuning.values.ally_fall_death = false
	var spared := await _drop(LETHAL_DROP, true)
	note("ally launch, flag off: drop %.1fm damage=%.1f hp=%.1f dead=%s" % [
		LETHAL_DROP, spared["damage"], spared["hp"], spared["dead"]])
	expect(not bool(spared["dead"]), "an_ally_launch_does_not_kill_with_the_flag_off")
	expect(absf(float(spared["hp"]) - 1.0) < 0.01, "and_leaves_exactly_1_hp")
	expect(float(spared["damage"]) > 0.0, "and_the_landing_damage_is_still_taken")

	# On: the same launch finishes the job.
	Tuning.values.ally_fall_death = true
	var killed := await _drop(LETHAL_DROP, true)
	note("ally launch, flag on: drop %.1fm damage=%.1f hp=%.1f dead=%s" % [
		LETHAL_DROP, killed["damage"], killed["hp"], killed["dead"]])
	expect(bool(killed["dead"]), "the_same_launch_kills_with_the_flag_on")

	# And a fall nobody else caused is never spared, whatever the flag says.
	Tuning.values.ally_fall_death = false
	var alone := await _drop(LETHAL_DROP, false)
	note("own fall, flag off: drop %.1fm hp=%.1f dead=%s" % [
		LETHAL_DROP, alone["hp"], alone["dead"]])
	expect(bool(alone["dead"]), "a_fall_of_your_own_still_kills_with_the_flag_off")

	Tuning.values.ally_fall_death = was
	await _revive()


# ------------------------------------- out of the world, after an ally launch

func _ally_void_checks() -> void:
	var was: bool = Tuning.values.ally_fall_death

	# Off: it cannot be left down there, so it comes home alive instead.
	Tuning.values.ally_fall_death = false
	await _revive()
	await _ally_push()
	await tick_request(func() -> void:
		placed()
		_local.global_position = VOID_SPOT)
	await _wait(1.2)
	await tick_request(func() -> void:
		_hp = _local.hp
		_dead = _local.sync_dead)
	note("void after an ally launch, flag off: hp=%.1f dead=%s y=%.2f" % [
		_hp, _dead, _local.global_position.y])
	expect(not _dead, "the_kill_plane_spares_an_ally_launch_with_the_flag_off")
	expect(_local.global_position.y > Tuning.values.kill_plane_y,
		"and_puts_the_body_back_in_the_world")

	# On: out of the world is the end.
	Tuning.values.ally_fall_death = true
	await _revive()
	await _ally_push()
	await tick_request(func() -> void:
		placed()
		_local.global_position = VOID_SPOT)
	await _wait(1.2)
	await tick_request(func() -> void: _dead = _local.sync_dead)
	note("void after an ally launch, flag on: dead=%s" % _dead)
	expect(_dead, "and_kills_it_with_the_flag_on")

	Tuning.values.ally_fall_death = was
	await _wait(Tuning.values.respawn_delay + 1.0)
	await _revive()


# --------------------------------------- the cliff, on both screens at once

func _cliff_respawn_checks() -> void:
	var client := _judge.actor_for(_client_peer())
	await tick_request(func() -> void:
		_judge.server_respawn(_local)
		_judge.server_respawn(client))
	client_park.rpc_id(_client_peer(), PARK_CLIENT)
	expect(await _wait_stage("parked"), "client_parked")
	await _wait(0.8)

	# The client's own body goes over the cliff, so the death is a remote one
	# and both machines have to end up saying the same thing.
	var home := client.global_position
	client_void.rpc_id(_client_peer(), VOID_SPOT)
	expect(await _wait_stage("fell"), "client_went_over_the_cliff")
	var died := false
	var waited := 0.0
	while waited < 4.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		if client.sync_dead:
			died = true
			break
	note("client cliff fall: dead=%s hp=%.0f y=%.2f" % [died, client.hp, client.global_position.y])
	expect(died, "a_cliff_fall_is_a_death")

	# And the way back.
	await _wait(Tuning.values.respawn_delay + 2.0)
	note("after respawn: dead=%s hp=%.0f y=%.2f moved_from_home=%.2f" % [
		client.sync_dead, client.hp, client.global_position.y,
		client.global_position.distance_to(home)])
	expect(not client.sync_dead, "and_the_body_comes_back")
	expect(client.hp == client.stats.max_hp, "with_its_health_back")
	expect(client.global_position.y > Tuning.values.kill_plane_y, "and_back_in_the_world")

	# Both screens. The client reports where it thinks its own body is; the
	# host reads the same body from its own copy of the world.
	_reported.erase("client_body")
	report_position.rpc_id(_client_peer(), client.get_path(), "client_body")
	var arrived := 0.0
	while not _reported.has("client_body") and arrived < 6.0:
		await get_tree().create_timer(0.1).timeout
		arrived += 0.1
	expect(_reported.has("client_body"), "the_client_answered_where_its_body_is")
	if _reported.has("client_body"):
		var there: Vector3 = _reported["client_body"]
		var gap := there.distance_to(client.global_position)
		note("respawned body: host sees %s, client sees %s, gap %.3f m" % [
			client.global_position, there, gap])
		expect(gap < 0.5, "both_screens_agree_on_where_the_respawned_body_is")


# --------------------------------------------------------------------- helpers

func _revive() -> void:
	await tick_request(func() -> void:
		placed()
		_judge.server_respawn(_local)
		_local.global_position = DROP_SPOT
		_local.velocity = Vector3.ZERO)
	await _wait(0.8)


# A party member's push, through the one force door, so the judge records the
# flight the way a real shove would.
func _ally_push() -> void:
	var peer := _client_peer()
	await tick_request(func() -> void:
		_judge.send_force(_local, ForceSystem.make_event(
			ForceSystem.Kind.SHOVE,
			Vector3(0.0, 1.0, 0.0),
			0.5,
			10.0,
			peer,
			true,
			0.0,
			0.0)))


# Dropped from a height. With ally true a party member's push lands first, in
# the same breath, so the judge has a flight to attribute the fall to.
func _drop(height: float, ally: bool) -> Dictionary:
	await _revive()
	if ally:
		await _ally_push()
	var before := _local.hp
	await tick_request(func() -> void:
		placed()
		_local.global_position = DROP_SPOT + Vector3.UP * height
		_local.velocity = Vector3.ZERO
		_local.floor_snap_length = 0.0
		_local.change_state(Player.State.AIRBORNE))
	var waited := 0.0
	while waited < 6.0 and not _local.is_grounded_state() and not _local.sync_dead:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	for _frame in range(8):
		await get_tree().physics_frame
	return {
		"damage": before - _local.hp,
		"height": _local.last_fall_height,
		"hp": _local.hp,
		"dead": _local.sync_dead,
	}


# --------------------------------------------------------------------- RPCs

@rpc("any_peer", "call_remote", "reliable")
func stage_done(name_text: String) -> void:
	if multiplayer.is_server() and multiplayer.get_peers().has(multiplayer.get_remote_sender_id()):
		_stage_done = name_text


@rpc("any_peer", "call_remote", "reliable")
func report_back(what: String, where: Vector3) -> void:
	if multiplayer.is_server() and multiplayer.get_peers().has(multiplayer.get_remote_sender_id()):
		_reported[what] = where


@rpc("authority", "call_remote", "reliable")
func report_position(path: NodePath, what: String) -> void:
	var body := get_node_or_null(path) as Node3D
	if body != null:
		report_back.rpc_id(1, what, body.global_position)


@rpc("authority", "call_remote", "reliable")
func client_park(at_position: Vector3) -> void:
	Net.queue_physics(func() -> void:
		placed()
		_local.global_position = at_position
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target())
	await get_tree().create_timer(0.4).timeout
	stage_done.rpc_id(1, "parked")


@rpc("authority", "call_remote", "reliable")
func client_void(at_position: Vector3) -> void:
	Net.queue_physics(func() -> void:
		placed()
		_local.global_position = at_position
		_local.velocity = Vector3.ZERO
		_local.change_state(Player.State.AIRBORNE))
	await get_tree().create_timer(0.3).timeout
	stage_done.rpc_id(1, "fell")


@rpc("any_peer", "call_remote", "reliable")
func finish(host_failures: int) -> void:
	if not multiplayer.is_server():
		print("G_RESULT peer=%d checks=%d failures=%d host_failures=%d" % [
			_peer_id, _checks, _failures, host_failures])
		await get_tree().create_timer(0.5).timeout
		get_tree().quit(0 if host_failures == 0 and _failures == 0 else 1)
