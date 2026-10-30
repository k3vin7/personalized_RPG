extends Node

# Stage N: the validation pass. The owner still decides its own position and
# speed; the server rules, and these check what each N step moved to the
# server's side -- the tuning table (N-1), and the steps that follow.
#
# Two peers; the host conducts. Run at a latency with tools/udp_delay_proxy.py
# and --n-latency=<ms>.

const HOME := Vector3(0.0, 0.9, 11.0)
const CLIENT_HOME := Vector3(-4.0, 0.9, 11.0)

var _world: Node3D
var _local: Player
var _judge: ServerAuthority
var _peer_id := 0
var _checks := 0
var _failures := 0
var _stage_done := ""
var _lag := 0.0
var _label := "0"
# What the client reported, keyed by what was asked.
var _reports := {}


func expect(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("N_CHECK lag=%s peer=%d %s %s" % [_label, _peer_id, "PASS" if condition else "FAIL", label])


func note(line: String) -> void:
	print("N_NOTE lag=%s peer=%d %s" % [_label, _peer_id, line])


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


func _wait_report(key: String, seconds := 10.0) -> bool:
	var waited := 0.0
	while not _reports.has(key) and waited < seconds + _lag * 20.0:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	expect(_reports.has(key), "the_client_reported_%s" % key)
	return _reports.has(key)


func _client_peer() -> int:
	var peers := multiplayer.get_peers()
	return peers[0] if peers.size() > 0 else 0


func run(world: Node3D) -> void:
	_world = world
	_peer_id = multiplayer.get_unique_id()
	_local = Net.spawn_root.get_node(str(_peer_id)) as Player
	_judge = world.get_node_or_null("ServerAuthority") as ServerAuthority
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--n-latency="):
			_label = argument.trim_prefix("--n-latency=")
			_lag = _label.to_float() / 1000.0
	if not multiplayer.is_server():
		stage_done.rpc_id(1, "client_ready")
		return
	expect(await _wait_stage("client_ready"), "both_peers_present")
	await _tuning_checks()
	await _correction_checks()
	print("N_RESULT lag=%s peer=%d checks=%d failures=%d" % [_label, _peer_id, _checks, _failures])
	finish.rpc(_failures)
	await _wait(1.0)
	get_tree().quit(0 if _failures == 0 else 1)


# ------------------------------------------------- N-1: the tuning table is the server's

func _tuning_checks() -> void:
	var gravity: float = Tuning.server.gravity
	note("server tuning: %d fields, gravity %.2f; local tuning: %d fields" % [
		Tuning.field_names(Tuning.server).size(), gravity, Tuning.field_names(Tuning.values).size()])
	# The two tables do not overlap, and the dead sliders are gone.
	var overlap := PackedStringArray()
	for field in Tuning.field_names(Tuning.values):
		if Tuning.is_server_field(field):
			overlap.append(field)
	expect(overlap.is_empty(), "no_field_is_in_both_tables")
	expect(not Tuning.is_server_field("throw_power") and not Tuning.is_server_field("throw_up_angle_deg"),
		"throw_power_and_the_fixed_angle_are_gone")

	# The client's own jump, after it has tried to write gravity on its copy.
	# Measured the same way here, on a body of the same race, so the two apexes
	# have to agree -- and they only can if the client's launch used the
	# server's gravity, not the 5 it wrote.
	var mine := await _standing_apex()
	client_park.rpc_id(_client_peer(), CLIENT_HOME)
	await _wait(0.8)
	_reports.erase("forge")
	client_forge_gravity.rpc_id(_client_peer())
	if await _wait_report("forge"):
		var forged: PackedFloat32Array = _reports["forge"]
		note("client wrote gravity 5 on its replica: reads back %.2f (server %.2f) | standing apex client %.3f m, host %.3f m" % [
			forged[0], gravity, forged[1], mine])
		expect(absf(forged[0] - gravity) < 0.001, "a_clients_write_to_its_replica_is_refused")
		expect(absf(forged[1] - mine) < 0.15, "and_its_jump_apex_is_the_servers")
	# The forged push it sent on the way out.
	await _wait(0.5)
	expect(absf(Tuning.server.gravity - gravity) < 0.001, "a_forged_table_push_changes_nothing")

	# A slider request: the server's table moves, and the replica follows.
	var rejected := _judge.rejected_intents
	await tick_request(func() -> void: ServerAuthority.submit_intent(_local,
		ServerAuthority.Intent.SERVER_TUNING, {"field": "gravity", "value": 30.0}))
	expect(absf(Tuning.server.gravity - 30.0) < 0.001, "a_request_moves_the_servers_table")
	await _wait(0.4)
	_reports.erase("gravity")
	client_report_field.rpc_id(_client_peer(), "gravity")
	if await _wait_report("gravity"):
		expect(absf(float(_reports["gravity"]) - 30.0) < 0.001, "and_the_replica_follows_it")
	# Out of range is clamped to the range the shipped default allows.
	await tick_request(func() -> void: ServerAuthority.submit_intent(_local,
		ServerAuthority.Intent.SERVER_TUNING, {"field": "gravity", "value": 999.0}))
	var limits := Tuning.limits_for("gravity")
	note("gravity asked 999 -> %.2f (limits %.1f..%.1f)" % [Tuning.server.gravity, limits.x, limits.y])
	expect(absf(Tuning.server.gravity - limits.y) < 0.001, "an_out_of_range_request_is_clamped")
	# A bool field, the same way.
	var party: bool = Tuning.server.same_party
	await tick_request(func() -> void: ServerAuthority.submit_intent(_local,
		ServerAuthority.Intent.SERVER_TUNING, {"field": "same_party", "value": not party}))
	expect(Tuning.server.same_party == (not party), "a_bool_field_is_a_request_too")
	await _wait(0.4)
	_reports.erase("same_party")
	client_report_field.rpc_id(_client_peer(), "same_party")
	if await _wait_report("same_party"):
		expect(bool(_reports["same_party"]) == (not party), "and_reaches_the_replica")
	# A local field, an unknown field and a wrong type are refused, not clamped.
	await tick_request(func() -> void: ServerAuthority.submit_intent(_local,
		ServerAuthority.Intent.SERVER_TUNING, {"field": "smart_key_enabled", "value": true}))
	await tick_request(func() -> void: ServerAuthority.submit_intent(_local,
		ServerAuthority.Intent.SERVER_TUNING, {"field": "no_such_field", "value": 1.0}))
	await tick_request(func() -> void: ServerAuthority.submit_intent(_local,
		ServerAuthority.Intent.SERVER_TUNING, {"field": "gravity", "value": true}))
	expect(_judge.rejected_intents == rejected + 3, "a_local_an_unknown_and_a_mistyped_field_are_refused")

	# A write on the server by any path -- a stage check, a harness -- is pushed
	# within a step, without an intent.
	Tuning.server.gravity = 25.0
	await _wait(0.4)
	_reports.erase("gravity")
	client_report_field.rpc_id(_client_peer(), "gravity")
	if await _wait_report("gravity"):
		expect(absf(float(_reports["gravity"]) - 25.0) < 0.001, "a_direct_server_write_is_pushed_too")

	# Back where everything else expects it.
	Tuning.server.gravity = gravity
	Tuning.server.same_party = party
	await _wait(0.4)
	_reports.erase("gravity")
	client_report_field.rpc_id(_client_peer(), "gravity")
	if await _wait_report("gravity"):
		expect(absf(float(_reports["gravity"]) - gravity) < 0.001, "and_the_replica_is_back_too")


# ------------------------------------------ N-2: the move check puts a body back

# The cheat on the client: writing its own position every step at three times
# the walk. The server sees a sprint no strength explains, and after
# MOVE_CORRECT_SAMPLES of it tells the owner where it last was.
var _cheat_left := 0.0
var _cheat_speed := 0.0
var _cheat_received := 0
var _dashes_made := 0


func _physics_process(delta: float) -> void:
	if _cheat_left <= 0.0 or _local == null:
		return
	_cheat_left -= delta
	if _local.corrections_received > _cheat_received:
		# Put back: the cheat stops here, so what is reported is where the
		# correction left the body, not where the next frame of cheating did.
		_cheat_left = 0.0
		return
	_local.global_position += Vector3(_cheat_speed * delta, 0.0, 0.0)


func _correction_checks() -> void:
	var corrections := _judge.move_corrections
	# The honest things first: a walk, two dashes a cooldown apart, a jump.
	await tick_request(func() -> void:
		placed()
		_local.global_position = HOME
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target())
	await _wait(0.4)
	_local.movement.set_target(HOME + Vector3(3.0, 0.0, 0.0))
	await _wait(1.0)
	for _leg in range(2):
		await tick_request(func() -> void:
			_local.movement.set_aim_override(_local.global_position + Vector3(-4.0, 0.0, 0.0))
			_local.movement.request_dash())
		await _wait(Tuning.server.dash_cooldown + 0.3)
	await tick_request(func() -> void:
		_local.movement.set_aim_override(_local.global_position + Vector3(3.0, 0.0, 0.0))
		_local.movement.request_jump())
	await _wait(1.2)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	expect(_judge.move_corrections == corrections, "honest_walk_dash_and_jump_are_not_corrected")

	# The cheat. The client runs at three times its walk by writing its own
	# position; the server puts it back and the client stops when it is.
	client_park.rpc_id(_client_peer(), CLIENT_HOME)
	await _wait(0.8)
	var mate := _judge.actor_for(_client_peer())
	var start := mate.global_position if mate != null else Vector3.ZERO
	_reports.erase("cheat")
	client_cheat_run.rpc_id(_client_peer(), 3.0, 2.0)
	if await _wait_report("cheat", 8.0):
		var cheat: PackedFloat32Array = _reports["cheat"]
		var put_back: Vector3 = last_correction_to()
		var landed := Vector3(cheat[1], cheat[2], cheat[3])
		note("client sprint x3: corrections received %d (server total +%d), farthest x %.2f from start %.2f, put back to (%.2f, %.2f, %.2f), ended at (%.2f, %.2f, %.2f), gap %.2f m" % [
			int(cheat[0]), _judge.move_corrections - corrections, cheat[4], start.x,
			put_back.x, put_back.y, put_back.z, landed.x, landed.y, landed.z,
			landed.distance_to(put_back)])
		expect(_judge.move_corrections > corrections, "the_sprint_was_corrected")
		expect(int(cheat[0]) >= 1, "and_the_client_received_it")
		expect(landed.distance_to(put_back) < 0.5, "the_body_ended_where_the_server_last_accepted_it")
		expect(cheat[4] - start.x < 3.0 * Tuning.server.base_move_speed * 0.6,
			"the_sprint_was_cut_short")
	corrections = _judge.move_corrections

	# A dash inside the cooldown, three times in a second: the notice is
	# counted like a sample over the cap, and two of those in a row put the
	# body back.
	_reports.erase("dash")
	client_cheat_dash.rpc_id(_client_peer())
	if await _wait_report("dash", 8.0):
		var dash: PackedFloat32Array = _reports["dash"]
		note("client dashed %d times inside the cooldown: corrections received %d (server total +%d)" % [
			int(dash[0]), int(dash[1]), _judge.move_corrections - corrections])
		expect(_judge.move_corrections > corrections, "dashes_inside_the_cooldown_are_corrected")
	# Back on a mark, with the check told.
	await tick_request(func() -> void: _judge.server_respawn(mate))
	await _wait(0.8)


func last_correction_to() -> Vector3:
	return _judge.last_correction.get("to", Vector3.INF) if _judge != null else Vector3.INF


# A jump straight up from HOME, its apex above the floor it left.
func _standing_apex() -> float:
	await tick_request(func() -> void:
		placed()
		_local.global_position = HOME
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target())
	await _wait(0.5)
	var apex := await _measure_apex(_local)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	return apex


func _measure_apex(body: Player) -> float:
	var floor_y := body.global_position.y
	var peak := floor_y
	var launched := false
	await tick_request(func() -> void:
		body.movement.set_aim_override(body.global_position)
		body.movement.cast_jump())
	var sampled := 0.0
	while sampled < 3.0:
		await get_tree().physics_frame
		sampled += get_physics_process_delta_time()
		if body.state == Player.State.AIRBORNE:
			launched = true
		peak = maxf(peak, body.global_position.y)
		if launched and body.is_grounded_state():
			break
	return peak - floor_y


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
func client_park(point: Vector3) -> void:
	await tick_request(func() -> void:
		placed()
		_local.global_position = point
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target()
		_local.movement.set_aim_override(Vector3.INF))


# Server -> client. Write gravity on the replica the way a cheat or a stray
# slider would, read it back, jump straight up with whatever the launch used,
# and report both. Then push a forged table at the server for good measure.
@rpc("authority", "call_remote", "reliable")
func client_forge_gravity() -> void:
	Tuning.server.gravity = 5.0
	var read_back: float = Tuning.server.gravity
	var apex := await _measure_apex(_local)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	_judge.push_server_tuning.rpc_id(1, {"gravity": 5.0})
	report.rpc_id(1, "forge", PackedFloat32Array([read_back, apex]))


@rpc("authority", "call_remote", "reliable")
func client_report_field(field: String) -> void:
	report.rpc_id(1, field, Tuning.server.get(field))


# Server -> client. Sprint by writing our own position at `times` the walk for
# up to `seconds`, stopping the moment a correction arrives, then report
# [corrections received, final x, y, z, farthest x reached].
@rpc("authority", "call_remote", "reliable")
func client_cheat_run(times: float, seconds: float) -> void:
	_cheat_received = _local.corrections_received
	_cheat_speed = Tuning.server.base_move_speed * times
	var farthest := _local.global_position.x
	_cheat_left = seconds
	var waited := 0.0
	while _cheat_left > 0.0 and waited < seconds + 1.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		farthest = maxf(farthest, _local.global_position.x)
	# The correction is a snap; let the body settle where it was put.
	await _wait(0.4)
	var at := _local.global_position
	report.rpc_id(1, "cheat", PackedFloat32Array([
		_local.corrections_received - _cheat_received, at.x, at.y, at.z, farthest]))


# Server -> client. Three dashes with the cooldown zeroed between them, a third
# of a second apart, then report [dashes made, corrections received].
@rpc("authority", "call_remote", "reliable")
func client_cheat_dash() -> void:
	var received := _local.corrections_received
	_dashes_made = 0
	for _dash in range(3):
		await tick_request(func() -> void:
			_local.movement._dash_cooldown_left = 0.0
			_local.movement.set_aim_override(_local.global_position + Vector3(0.0, 0.0, 3.0))
			if _local.movement.request_dash():
				_dashes_made += 1)
		await _wait(0.35)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	await _wait(0.6)
	report.rpc_id(1, "dash", PackedFloat32Array([_dashes_made, _local.corrections_received - received]))


@rpc("authority", "call_remote", "reliable")
func finish(host_failures: int) -> void:
	print("N_RESULT lag=%s peer=%d checks=%d failures=%d host_failures=%d" % [
		_label, _peer_id, _checks, _failures, host_failures])
	get_tree().quit(0 if _failures == 0 else 1)
