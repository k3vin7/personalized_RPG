extends Node

# TP: the debug teleport's server half (Intent.DEBUG_TELEPORT). What cannot
# be seen: the server finding the nearest floor a body can walk on, the body
# moved down the respawn's path (collision off for the teleport's blind, no
# refill, no move warning), and the refusal when debug tools are off. Run
# with the host as the body and again with the client as the body. Two
# peers; also through the 200 ms proxy. The map and the F3 key are looked
# at by hand.

# On the hub's plaza (x -20..20, z -2..18, floor at y 0).
const ON_FLOOR := Vector3(-8.0, 0.0, 14.0)
const ON_FLOOR_CLIENT := Vector3(-11.0, 0.0, 15.0)
# Past the plaza's east edge at z > 6: nothing below it but the kill plane.
const IN_THE_AIR := Vector3(24.0, 0.0, 14.0)
const IN_THE_AIR_CLIENT := Vector3(24.0, 0.0, 10.0)
const EDGE_X := 20.0

var _world: Node3D
var _local: Player
var _judge: ServerAuthority
var _peer_id := 0
var _checks := 0
var _failures := 0
var _stage_done := ""
var _reports := {}


func expect(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("TP_CHECK peer=%d %s %s" % [_peer_id, "PASS" if condition else "FAIL", label])


func note(line: String) -> void:
	print("TP_NOTE peer=%d %s" % [_peer_id, line])


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


func _wait_report(key: String, seconds := 10.0) -> bool:
	var waited := 0.0
	while not _reports.has(key) and waited < seconds:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	expect(_reports.has(key), "the_client_reported_%s" % key)
	return _reports.has(key)


func _client_peer() -> int:
	var peers := multiplayer.get_peers()
	return peers[0] if peers.size() > 0 else 0


func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


# This machine's body asks, and says what it saw of its own move.
func _ask(spot: Vector3) -> Dictionary:
	var from := _local.global_position
	var applied := _local.respawns_applied
	var blind := false
	Net.queue_physics(func() -> void:
		ServerAuthority.submit_intent(_local, ServerAuthority.Intent.DEBUG_TELEPORT, {"x": spot.x, "z": spot.z}))
	# The blind is short (SyncRules.TELEPORT_BLIND): watched for every step.
	var waited := 0.0
	while waited < 1.5:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		if _local.respawns_applied > applied and _local.collision_layer == 0:
			blind = true
	return {
		"from": from,
		"at": _local.global_position,
		"moved": _local.respawns_applied - applied,
		"blind_seen": blind,
		"layer": _local.collision_layer,
		"on_floor": _local.is_on_floor(),
		"hp": _local.hp,
	}


func run(world: Node3D) -> void:
	_world = world
	_peer_id = multiplayer.get_unique_id()
	_local = Net.spawn_root.get_node(str(_peer_id)) as Player
	_judge = world.get_node_or_null("ServerAuthority") as ServerAuthority
	if not multiplayer.is_server():
		stage_done.rpc_id(1, "client_ready")
		return
	expect(await _wait_stage("client_ready"), "both_peers_present")
	await _wait(1.0)
	var warnings := _judge.move_warnings
	var corrections := _judge.move_corrections
	note("debug tools %s (debug build %s), blind %.2f s" % [_judge.debug_tools, OS.is_debug_build(), SyncRules.TELEPORT_BLIND])
	expect(_judge.debug_tools == OS.is_debug_build(), "debug_tools_follow_the_build")
	await _host_checks()
	await _client_checks()
	expect(_judge.move_warnings == warnings, "no_move_warnings_during_tp")
	expect(_judge.move_corrections == corrections, "no_corrections_during_tp")
	print("TP_RESULT peer=%d checks=%d failures=%d" % [_peer_id, _checks, _failures])
	finish.rpc(_failures)
	await _wait(1.0)
	get_tree().quit(0 if _failures == 0 else 1)


func _host_checks() -> void:
	# Hurt first: a teleport is not a respawn, the HP stays where it was.
	await tick_request(func() -> void: _judge.server_set_hp(_local, _local.stats.max_hp - 7.0))
	var hp := _local.hp
	var done := _judge.debug_teleports
	var seen: Dictionary = await _ask(ON_FLOOR)
	note("host to the plaza %s: %s | server %s" % [ON_FLOOR, seen, _judge.last_debug_teleport])
	expect(_judge.debug_teleports == done + 1 and int(seen["moved"]) == 1 and _flat(seen["at"], ON_FLOOR) < 0.6,
		"the_host_is_moved_to_the_spot_it_clicked")
	expect(bool(seen["blind_seen"]) and int(seen["layer"]) == Player.PLAYER_LAYER and bool(seen["on_floor"]),
		"with_its_collision_off_for_the_blind_and_back_on_the_floor")
	expect(absf(float(seen["hp"]) - hp) < 0.01, "and_its_hp_is_not_refilled")
	# Thin air: the nearest floor a body can walk on, not the click.
	seen = await _ask(IN_THE_AIR)
	var landed: Vector3 = seen["at"]
	note("host to thin air %s: %s | server %s" % [IN_THE_AIR, seen, _judge.last_debug_teleport])
	expect(int(seen["moved"]) == 1 and landed.x < EDGE_X and _flat(landed, IN_THE_AIR) < 6.0 and bool(seen["on_floor"])
		and not _local.sync_dead, "a_click_in_thin_air_lands_the_host_on_the_nearest_floor")
	# Debug tools off: refused, nothing moves.
	var refused := _judge.debug_teleports_refused
	_judge.debug_tools = false
	seen = await _ask(ON_FLOOR)
	_judge.debug_tools = OS.is_debug_build()
	note("host with debug tools off: %s | refused +%d (%s)" % [seen, _judge.debug_teleports_refused - refused, _judge.last_refusal])
	expect(int(seen["moved"]) == 0 and _flat(seen["at"], seen["from"]) < 0.05 and _judge.debug_teleports_refused == refused + 1,
		"with_debug_tools_off_the_server_refuses_the_host")
	await tick_request(func() -> void: _judge.server_set_hp(_local, _local.stats.max_hp))


func _client_ask(spot: Vector3) -> Dictionary:
	_reports.erase("teleport")
	client_teleport.rpc_id(_client_peer(), spot)
	if await _wait_report("teleport"):
		# The server's copy of the body follows a round trip later.
		await _wait(0.6)
		return _reports["teleport"]
	return {}


func _client_checks() -> void:
	var client := _client_peer()
	var mate := _judge.actor_for(client)
	await tick_request(func() -> void: _judge.server_set_hp(mate, mate.stats.max_hp - 7.0))
	await _wait(0.5)
	var hp := mate.hp
	var done := _judge.debug_teleports
	var seen: Dictionary = await _client_ask(ON_FLOOR_CLIENT)
	note("client to the plaza %s: %s | the server's copy at %s | server %s" % [
		ON_FLOOR_CLIENT, seen, mate.global_position, _judge.last_debug_teleport])
	expect(_judge.debug_teleports == done + 1 and int(seen.get("moved", 0)) == 1
		and _flat(seen.get("at", Vector3.INF), ON_FLOOR_CLIENT) < 0.6 and _flat(mate.global_position, ON_FLOOR_CLIENT) < 0.6,
		"the_client_is_moved_to_the_spot_it_clicked_on_both_screens")
	expect(bool(seen.get("blind_seen", false)) and int(seen.get("layer", 0)) == Player.PLAYER_LAYER and bool(seen.get("on_floor", false)),
		"with_its_collision_off_for_the_blind_and_back_on_the_floor")
	expect(absf(mate.hp - hp) < 0.01 and absf(float(seen.get("hp", -1.0)) - hp) < 0.01, "and_its_hp_is_not_refilled")
	seen = await _client_ask(IN_THE_AIR_CLIENT)
	var landed: Vector3 = seen.get("at", Vector3.INF)
	note("client to thin air %s: %s | the server's copy at %s" % [IN_THE_AIR_CLIENT, seen, mate.global_position])
	expect(int(seen.get("moved", 0)) == 1 and landed.x < EDGE_X and _flat(landed, IN_THE_AIR_CLIENT) < 6.0
		and bool(seen.get("on_floor", false)) and not mate.sync_dead and _flat(mate.global_position, landed) < 0.6,
		"a_click_in_thin_air_lands_the_client_on_the_nearest_floor")
	var refused := _judge.debug_teleports_refused
	_judge.debug_tools = false
	seen = await _client_ask(ON_FLOOR_CLIENT)
	_judge.debug_tools = OS.is_debug_build()
	note("client with the server's debug tools off: %s | refused +%d" % [seen, _judge.debug_teleports_refused - refused])
	expect(int(seen.get("moved", 1)) == 0 and _flat(seen.get("at", Vector3.INF), seen.get("from", Vector3.ZERO)) < 0.05
		and _judge.debug_teleports_refused == refused + 1, "with_debug_tools_off_the_server_refuses_the_client")
	await tick_request(func() -> void: _judge.server_set_hp(mate, mate.stats.max_hp))


# ------------------------------------------------------------------ RPCs

@rpc("any_peer", "call_remote", "reliable")
func stage_done(name_text: String) -> void:
	if multiplayer.is_server() and multiplayer.get_peers().has(multiplayer.get_remote_sender_id()):
		_stage_done = name_text


@rpc("any_peer", "call_remote", "reliable")
func report(key: String, value: Variant) -> void:
	if multiplayer.is_server() and multiplayer.get_peers().has(multiplayer.get_remote_sender_id()):
		_reports[key] = value


@rpc("authority", "call_remote", "reliable")
func client_teleport(spot: Vector3) -> void:
	var seen: Dictionary = await _ask(spot)
	report.rpc_id(1, "teleport", seen)


@rpc("authority", "call_remote", "reliable")
func finish(host_failures: int) -> void:
	print("TP_RESULT peer=%d checks=%d failures=%d host_failures=%d" % [
		_peer_id, _checks, _failures, host_failures])
	get_tree().quit(0 if _failures == 0 else 1)
