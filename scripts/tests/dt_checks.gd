extends Node

# DT: a thrown scarecrow. Reported in play: the scarecrow, thrown from the
# hand, hung above the thrower instead of flying. Both peers throw one through
# the grab slot (slot 2: press to charge, release to throw), and both screens
# measure where it went -- the thrower's own, and the one watching.
#
# Numbers, not verdicts: how far along it got, how high above the thrower it
# was, and whether it ever sat over the thrower's head once the throw was out.

const CHARGE_WAIT := 0.1
const TRACK_SECONDS := 2.5
const THROW_RANGE := 5.0
# Where the thrower stands relative to the scarecrow's home, and which way it
# throws. Both are harness geometry, not game rules: the host's lane from
# Dummy_1 runs north up the plaza; the client's from Dummy_0 cannot, because
# ClimbWall_90 stands at x = -2 from z = 4.5 on, and a stand to the west of
# Dummy_0 is inside ClimbWall_135. So the client stands east and throws
# north-north-east, between Dummy_1 and the walls.
const HOST_STAND := Vector3(-1.0, 0.0, 0.0)
const HOST_LANE := Vector3(0.0, 0.0, 1.0)
const CLIENT_STAND := Vector3(1.0, 0.0, 0.0)
const CLIENT_LANE := Vector3(0.4472, 0.0, 0.8944)  # (1, 0, 2) normalized

var _world: Node3D
var _local: Player
var _judge: ServerAuthority
var _peer_id := 0
var _checks := 0
var _failures := 0
var _stage_done := ""
var _reported := {}


func expect(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("DT_CHECK peer=%d %s %s" % [_peer_id, "PASS" if condition else "FAIL", label])


func note(line: String) -> void:
	print("DT_NOTE peer=%d %s" % [_peer_id, line])


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


func _wait_stage(name_text: String, limit := 25.0) -> bool:
	var waited := 0.0
	while _stage_done != name_text and waited < limit:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	var arrived := _stage_done == name_text
	_stage_done = ""
	return arrived


func _wait_report(key: String, limit := 20.0) -> bool:
	var waited := 0.0
	while not _reported.has(key) and waited < limit:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	return _reported.has(key)


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

	# 1) The host throws Dummy_1 south; the client watches the same scarecrow.
	var dummy := _world.get_node("Dummy_1") as Dummy
	client_watch.rpc_id(_client_peer(), dummy.get_path(), 5.0 + TRACK_SECONDS)
	await _wait(0.3)
	var mine := await _throw_and_track(dummy, THROW_RANGE, HOST_STAND, HOST_LANE)
	_judge_throw("host_throw_own_screen", mine)
	# Short aims, the way a cursor near the feet or a missed ray gives them:
	# 0 m is the solver's "straight up" branch. Where does the scarecrow end up?
	for short_range in [0.0, 0.5, 1.0, 2.0]:
		await _wait(3.0)
		var short := await _throw_and_track(dummy, float(short_range), HOST_STAND, HOST_LANE)
		note("host throw aimed %.1f m away: along max %.2f final %.2f, up max %.2f final %.2f, hovered=%s, let go=%s" % [
			short_range, short["max_h"], short["final_h"], short["max_up"], short["final_up"],
			short["hover"], not short["held_after"]])
		expect(short["held"], "host_held_it_for_the_%.1f_m_throw" % short_range)
		expect(not short["hover"], "a_%.1f_m_throw_does_not_leave_it_over_the_thrower" % short_range)
		expect(short["final_up"] < 0.6, "a_%.1f_m_throw_puts_it_back_on_the_ground" % short_range)
	expect(await _wait_report("watch"), "client_reported_what_it_saw_of_the_host_throw")
	var seen: PackedFloat32Array = _reported.get("watch", PackedFloat32Array())
	if seen.size() >= 4:
		note("client screen of the host's throw: along max %.2f final %.2f, up max %.2f, hovered=%s" % [
			seen[0], seen[1], seen[2], seen[3] > 0.5])
		expect(seen[0] > 2.0, "client_saw_the_hosts_scarecrow_fly_along")
		expect(seen[3] < 0.5, "client_did_not_see_it_hover_over_the_host")
	await _wait(3.0)

	# 2) The client throws Dummy_0; the host (the server) watches it.
	var other := _world.get_node("Dummy_0") as Dummy
	var client_body := Net.spawn_root.get_node(str(_client_peer())) as Player
	client_throw.rpc_id(_client_peer(), other.get_path())
	# The server's own view of the client's throw: the authority simulation.
	var pick_up_done := 0.0
	while pick_up_done < 6.0 and _judge.holder_of(other) != _client_peer():
		await get_tree().physics_frame
		pick_up_done += get_physics_process_delta_time()
	expect(_judge.holder_of(other) == _client_peer(), "client_picked_its_scarecrow_up")
	while _judge.holder_of(other) == _client_peer() and pick_up_done < 12.0:
		await get_tree().physics_frame
		pick_up_done += get_physics_process_delta_time()
	note("client body at (%.2f, %.2f, %.2f) when its hold ended; host body at (%.2f, %.2f, %.2f); Dummy_1 at (%.2f, %.2f, %.2f)" % [
		client_body.global_position.x, client_body.global_position.y, client_body.global_position.z,
		_local.global_position.x, _local.global_position.y, _local.global_position.z,
		dummy.global_position.x, dummy.global_position.y, dummy.global_position.z])
	var server_view := await _track(other, client_body.global_position, TRACK_SECONDS)
	note("server screen of the client's throw: along max %.2f final %.2f, up max %.2f final %.2f, hovered=%s" % [
		server_view["max_h"], server_view["final_h"], server_view["max_up"],
		server_view["final_up"], server_view["hover"]])
	expect(server_view["max_h"] > 2.0, "server_saw_the_clients_scarecrow_fly_along")
	expect(not server_view["hover"], "server_did_not_see_it_hover_over_the_client")
	expect(await _wait_report("throw"), "client_reported_its_own_throw")
	var theirs: PackedFloat32Array = _reported.get("throw", PackedFloat32Array())
	if theirs.size() >= 5:
		note("client's own screen: held=%s, along max %.2f final %.2f, up max %.2f, hovered=%s" % [
			theirs[4] > 0.5, theirs[0], theirs[1], theirs[2], theirs[3] > 0.5])
		expect(theirs[4] > 0.5, "client_held_it_before_the_throw")
		expect(theirs[0] > 2.0, "client_saw_its_own_scarecrow_fly_along")
		expect(theirs[3] < 0.5, "client_did_not_see_it_hover_over_itself")

	print("DT_RESULT peer=%d checks=%d failures=%d" % [_peer_id, _checks, _failures])
	await _wait(1.0)
	get_tree().quit(0 if _failures == 0 else 1)


func _judge_throw(label: String, result: Dictionary) -> void:
	note("%s: held=%s, along max %.2f final %.2f, up max %.2f final %.2f, hovered=%s, still held after=%s" % [
		label, result["held"], result["max_h"], result["final_h"], result["max_up"],
		result["final_up"], result["hover"], result["held_after"]])
	expect(result["held"], "%s_held_it_first" % label)
	expect(result["max_h"] > 2.0, "%s_flew_along" % label)
	expect(not result["hover"], "%s_did_not_hover_over_the_thrower" % label)
	expect(not result["held_after"], "%s_let_go" % label)


# Stands at `stand` from the scarecrow, picks it up, charges the grab slot and
# lets go `throw_range` metres down `lane`, then tracks it. Returns the track
# plus whether it was held before and after.
func _throw_and_track(dummy: Dummy, throw_range: float, stand: Vector3, lane: Vector3) -> Dictionary:
	await _park_self(dummy.global_position + stand)
	await tick_request(func() -> void:
		_local.movement.set_aim_override(dummy.global_position)
		_local.skills.press_slot(1))
	await _wait(0.8)
	var held := _local.grab.is_holding()
	var aim := _local.global_position + lane * throw_range
	await tick_request(func() -> void:
		_local.movement.set_aim_override(aim)
		_local.skills.press_slot(1))
	await _wait(Tuning.values.throw_charge_max + CHARGE_WAIT)
	var from := _local.global_position
	await tick_request(func() -> void: _local.skills.release_slot(1))
	var result := await _track(dummy, from, TRACK_SECONDS)
	result["held"] = held
	result["held_after"] = _local.grab.is_holding()
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	return result


# Samples the scarecrow against a point for `seconds`. "hover" is any sample
# after the first half second with the scarecrow within a metre horizontally
# and more than 1.2 m above the point.
func _track(dummy: Dummy, origin: Vector3, seconds: float) -> Dictionary:
	var max_h := 0.0
	var max_up := -INF
	var hover := false
	var elapsed := 0.0
	var final_h := 0.0
	var final_up := 0.0
	while elapsed < seconds:
		await get_tree().physics_frame
		elapsed += get_physics_process_delta_time()
		var offset := dummy.global_position - origin
		var h := Vector2(offset.x, offset.z).length()
		max_h = maxf(max_h, h)
		max_up = maxf(max_up, offset.y)
		final_h = h
		final_up = offset.y
		if elapsed > 0.5 and h < 1.0 and offset.y > 1.2:
			hover = true
	return {"max_h": max_h, "final_h": final_h, "max_up": max_up, "final_up": final_up,
		"hover": hover}


func _park_self(point: Vector3) -> void:
	await tick_request(func() -> void:
		placed()
		if _judge.is_judge():
			_judge.server_respawn(_local)
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
func report_numbers(what: String, values: PackedFloat32Array) -> void:
	if multiplayer.is_server() and multiplayer.get_peers().has(multiplayer.get_remote_sender_id()):
		_reported[what] = values


# The client watches the host's scarecrow on its own screen.
@rpc("authority", "call_remote", "reliable")
func client_watch(dummy_path: NodePath, seconds: float) -> void:
	var dummy := get_node_or_null(dummy_path) as Dummy
	var host := Net.spawn_root.get_node_or_null("1") as Player
	if dummy == null or host == null:
		report_numbers.rpc_id(1, "watch", PackedFloat32Array())
		return
	# Wait for the hold to appear, then for it to end: the throw is the end.
	var waited := 0.0
	while waited < seconds and dummy.holder_peer != 1:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	while waited < seconds and dummy.holder_peer == 1:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	var origin := host.global_position
	var result := await _track(dummy, origin, TRACK_SECONDS)
	report_numbers.rpc_id(1, "watch", PackedFloat32Array([
		result["max_h"], result["final_h"], result["max_up"], 1.0 if result["hover"] else 0.0]))


# The client throws its own scarecrow and reports what its screen showed.
@rpc("authority", "call_remote", "reliable")
func client_throw(dummy_path: NodePath) -> void:
	var dummy := get_node_or_null(dummy_path) as Dummy
	if dummy == null:
		report_numbers.rpc_id(1, "throw", PackedFloat32Array())
		return
	var result := await _throw_and_track(dummy, THROW_RANGE, CLIENT_STAND, CLIENT_LANE)
	report_numbers.rpc_id(1, "throw", PackedFloat32Array([
		result["max_h"], result["final_h"], result["max_up"],
		1.0 if result["hover"] else 0.0, 1.0 if result["held"] else 0.0]))
