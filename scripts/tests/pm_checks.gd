extends Node

# PM (2026-11-22): the guard's training ground -- the sword scarecrow and the
# pitching machines -- on both peers' bodies.
#
#   host:   --auto-host --auto-smoke --auto-only=PM --auto-port=P --auto-quit=200
#   client: --auto-join --auto-smoke --auto-only=PM --auto-port=P --auto-quit=200
#
# The client's body goes first, then the host's. Each:
#   A. stands 2 m from SwordDummy_0: it turns, shows its cut and cuts it
#      (the server's strike by the scarecrow hits this body);
#   B1. stands in the lane 6 m from the 5 kg machine, the only one switched
#       on: it throws and the ball hits this body (the server's hit);
#   B2. raises the sword's guard and holds it; the 20 kg machine throws: the
#       hit is blocked (15 % lands) and the ball is not sent back.
# The host's body then also (perfect timing is exact only on the server's
# own machine; the client's perfect guard is GD's):
#   B3. a perfect guard on the 5 kg ball: sent back;
#   B4. a perfect guard on the 20 kg ball: not sent back (too heavy), nothing
#       lands, a share of the stamina spent.
# The host switches the machines and reads the server's numbers.

const SEQUENCE_AT := 12.0
const DUMMY_SPOT := Vector3(12.0, 0.0, 2.0)
# 6 m in front of machine 1 (5 kg) and machine 3 (20 kg). A ball's hit
# pushes the body, so it is stood again before each machine.
const LANE_SPOT := Vector3(-11.0, 0.0, 6.0)
const LANE_SPOT_3 := Vector3(-11.0, 0.0, 12.0)
const AWAY_SPOT := Vector3(0.0, 0.0, 16.5)

var _world: Node3D
var _local: Player
var _mate: Player
var _peer_id := 0
var _checks := 0
var _failures := 0
var _lag := 0.0
var _started_msec := 0
var _judge: ServerAuthority
var _mate_name := ""
var _own_name := ""
var _last_seen := {}
var _cuts := {}


func expect(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("PM_CHECK peer=%d %s %s" % [_peer_id, "PASS" if condition else "FAIL", label])


func note(line: String) -> void:
	print("PM_NOTE peer=%d %s" % [_peer_id, line])


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _elapsed() -> float:
	return float(Time.get_ticks_msec() - _started_msec) / 1000.0


func _process(_delta: float) -> void:
	if _judge != null and multiplayer.is_server() and _judge.last_strike != _last_seen:
		_last_seen = _judge.last_strike.duplicate()
		if String(_last_seen.get("skill", "")) == "dummy_sword_cut":
			var hits := int(_last_seen.get("hits", 0))
			_cuts["all"] = int(_cuts.get("all", 0)) + 1
			_cuts["hits"] = int(_cuts.get("hits", 0)) + hits


func run(world: Node3D) -> void:
	_world = world
	_peer_id = multiplayer.get_unique_id()
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--be-latency="):
			_lag = argument.trim_prefix("--be-latency=").to_float() / 1000.0
	_judge = world.get_node_or_null("ServerAuthority") as ServerAuthority
	var waited := 0.0
	while (_local == null or _mate == null) and waited < 30.0:
		_local = Net.spawn_root.get_node_or_null(str(_peer_id)) as Player
		if _local != null:
			for node in Net.spawn_root.get_children():
				var body := node as Player
				if body != null and body != _local:
					_mate = body
		if _local == null or _mate == null:
			await _wait(0.2)
			waited += 0.2
	expect(_local != null and _mate != null, "both_peers_present")
	if _local == null or _mate == null:
		_finish()
		return
	_mate_name = str(_mate.name)
	_own_name = str(_local.name)
	_started_msec = Time.get_ticks_msec()
	await _wait(1.0)
	_local.set_weapon(WeaponKinds.Kind.SWORD)
	await _wait(1.5 + _lag * 2.0)
	expect(_local.weapon == WeaponKinds.Kind.SWORD, "the_sword_is_in_hand")
	expect(_world.get_node_or_null("SwordDummy_0") != null and _world.get_node_or_null("PitchingMachine_4") != null,
		"the_training_ground_is_built")
	if multiplayer.is_server():
		_switch_machines(-1)
	while _elapsed() < SEQUENCE_AT + _lag * 2.0:
		await _wait(0.05)
	if multiplayer.is_server():
		await _host_side()
	else:
		await _client_side()
	_finish()


# ------------------------------------------------------------- the client

func _client_side() -> void:
	var dummy := _world.get_node("SwordDummy_0") as Dummy
	var shown_before := dummy.telegraphs_shown
	await _go(DUMMY_SPOT)
	# Until its telegraph shows here (the host's half waits its own 4 s).
	var phases := []
	var looked := 0.0
	while looked < 8.0 + _lag * 4.0 and dummy.telegraphs_shown <= shown_before:
		await _wait(0.1)
		looked += 0.1
		phases.append("%s@%.1f(%.1fm)" % [dummy.attack_phase, looked, _flat(dummy.global_position, _local.global_position)])
	note("scarecrow phases seen here: %s" % [phases.slice(0, 12)])
	await _wait(1.5)
	note("the sword scarecrow's telegraphs seen here: %d" % (dummy.telegraphs_shown - shown_before))
	expect(dummy.telegraphs_shown > shown_before, "client_sees_the_sword_scarecrows_telegraph")
	await _go(LANE_SPOT)
	var machine := _world.get_node("PitchingMachine_1") as PitchingMachine
	var lanes_seen := 0
	var was := ""
	var watched := 0.0
	# The host switches the machine on once it sees this body here, a round
	# trip later; the machine then waits its period: watched long enough.
	while watched < 12.0 + _lag * 4.0:
		await get_tree().physics_frame
		watched += 1.0 / 120.0
		if machine.phase == "windup" and was != "windup":
			lanes_seen += 1
		was = machine.phase
	expect(lanes_seen >= 1, "client_sees_the_machines_lane")
	await _go(LANE_SPOT_3)
	await _raise_and_hold(9.0 + _lag * 2.0)
	await _go(AWAY_SPOT)
	await _wait(40.0)


# ------------------------------------------------------------- the host

func _host_side() -> void:
	var mate_peer := _mate.get_multiplayer_authority()
	# The client's turn.
	await _until(func() -> bool: return _flat(_mate.global_position, Regions.ARENA + DUMMY_SPOT) < 0.6, 40.0)
	await _expect_cut(_mate, "client")
	await _until(func() -> bool: return _flat(_mate.global_position, Regions.ARENA + LANE_SPOT) < 0.6, 20.0)
	await _expect_ball_hit(_mate, 1, "client", false)
	await _until(func() -> bool: return _judge.is_blocking(mate_peer) 		and _flat(_mate.global_position, Regions.ARENA + LANE_SPOT_3) < 0.6, 15.0)
	await _wait(0.5)
	await _expect_ball_hit(_mate, 3, "client", true)
	await _until(func() -> bool: return _flat(_mate.global_position, Regions.ARENA + AWAY_SPOT) < 1.0, 20.0)
	# This body's turn.
	await _go(DUMMY_SPOT)
	await _expect_cut(_local, "host")
	await _go(LANE_SPOT)
	await _expect_ball_hit(_local, 1, "host", false)
	await _go(LANE_SPOT_3)
	# Raised and judged side by side: the hold is not awaited.
	_raise_and_hold(9.0)
	await _wait(0.5)
	await _expect_ball_hit(_local, 3, "host", true)
	await _until(func() -> bool: return not _local.skills.is_blocking(), 8.0)
	await _go(LANE_SPOT)
	await _perfect_on(1, true)
	await _go(LANE_SPOT_3)
	await _perfect_on(3, false)
	_switch_machines(-1)


func _expect_cut(body: Player, who: String) -> void:
	var before := int(_cuts.get("hits", 0))
	var all_before := int(_cuts.get("all", 0))
	await _wait(4.0 + _lag * 2.0)
	note("%s by the sword scarecrow: cuts %d, hits %d" % [who, int(_cuts.get("all", 0)) - all_before, int(_cuts.get("hits", 0)) - before])
	expect(int(_cuts.get("hits", 0)) > before, "%s_the_sword_scarecrow_cuts_a_body_that_comes_close" % who)


# Machine `index` alone, until it has thrown once; the ball's hit on `body`.
func _expect_ball_hit(body: Player, index: int, who: String, guarded: bool) -> void:
	var machine := _world.get_node("PitchingMachine_%d" % index) as PitchingMachine
	var reflected := _judge.guards_reflected
	var hits_before := _judge.hits_applied
	var shots := machine.shots
	_switch_machines(index)
	await _until(func() -> bool: return machine.shots > shots, 12.0)
	_switch_machines(-1)
	await _until(func() -> bool: return _judge.hits_applied > hits_before, 2.0)
	var hit := _judge.last_hit
	note("%s, %.0f kg ball: shots %d -> %d, hit %s" % [who, machine.ball_weight, shots, machine.shots, hit])
	expect(String(hit.get("target", "")) == str(body.name) and _judge.hits_applied > hits_before,
		"%s_the_%.0fkg_ball_hits" % [who, machine.ball_weight])
	if guarded:
		expect(bool(hit.get("blocked", false)) and absf(float(hit.get("dealt", 0.0)) - float(hit.get("final", 0.0)) * 0.15) < 0.01
			and _judge.guards_reflected == reflected, "%s_the_held_guard_blocks_the_%.0fkg_ball" % [who, machine.ball_weight])


# Host only: this body's perfect guard on machine `index`'s ball.
func _perfect_on(index: int, sent_back: bool) -> void:
	var machine := _world.get_node("PitchingMachine_%d" % index) as PitchingMachine
	var reflected := _judge.guards_reflected
	var perfect := _judge.guards_perfect
	var hits_before := _judge.hits_applied
	var stamina := _local.stamina
	_judge.last_block = {}
	var shots := machine.shots
	_switch_machines(index)
	await _until(func() -> bool: return machine.shots > shots, 12.0)
	_switch_machines(-1)
	# Raised so the ball arrives 0.1 s into the window.
	var flight := _flat(machine.ball.global_position, _local.global_position) / maxf(float(Tuning.server.pitch_speed) * 0.95, 1.0)
	await _wait(maxf(flight - 0.1, 0.0))
	var slot := _guard_slot()
	_local.movement.set_aim_override(machine.global_position)
	_local.skills.press_slot(slot)
	await _wait(0.6)
	_local.skills.release_slot(slot)
	var hit := _judge.last_hit
	note("host perfect on the %.0f kg ball: reflected %d -> %d, perfect %d -> %d, hits %d -> %d, stamina %.1f -> %.1f, block %s" % [
		machine.ball_weight, reflected, _judge.guards_reflected, perfect, _judge.guards_perfect, hits_before,
		_judge.hits_applied, stamina, _local.stamina, _judge.last_block])
	if sent_back:
		expect(_judge.guards_reflected == reflected + 1, "host_a_perfect_guard_sends_the_light_ball_back")
	else:
		expect(_judge.guards_reflected == reflected and _judge.guards_perfect == perfect + 1
			and float(hit.get("dealt", -1.0)) == 0.0 and float(_judge.last_block.get("stamina_cost", 0.0)) > 0.0,
			"host_the_heavy_ball_is_not_sent_back_but_perfectly_blocked")


func _raise_and_hold(seconds: float) -> void:
	var slot := _guard_slot()
	var machine := _world.get_node("PitchingMachine_3") as PitchingMachine
	_local.movement.set_aim_override(machine.global_position)
	for frame in 3:
		await get_tree().physics_frame
	_local.skills.press_slot(slot)
	await _wait(seconds)
	_local.skills.release_slot(slot)


func _guard_slot() -> int:
	for index in PlayerSkills.SLOT_COUNT:
		var held := _local.skills.slot_def(index)
		if held != null and held.id == "sword_guard":
			return index
	return -1


func _switch_machines(only: int) -> void:
	for index in 5:
		var machine := _world.get_node_or_null("PitchingMachine_%d" % index) as PitchingMachine
		if machine != null:
			machine.active = index == only


# This body to `spot` in the arena, forgiven by the server as a placement.
func _go(spot: Vector3) -> void:
	var at := Regions.ARENA + spot + Vector3(0.0, _local.global_position.y, 0.0)
	_placed()
	await Harness.forgive_lead(get_tree(), _placed)
	Net.queue_physics(func() -> void:
		_local.global_position = at
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target())
	for frame in 3:
		await get_tree().physics_frame
	await _wait(0.5 + _lag * 2.0)


func _placed() -> void:
	if _judge == null:
		return
	if _judge.is_judge():
		_judge.forgive_move(multiplayer.get_unique_id(), "")
	else:
		_judge.harness_forgive_move.rpc_id(1)


func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func _until(seen: Callable, limit: float) -> void:
	var waited := 0.0
	while waited < limit and not bool(seen.call()):
		await _wait(0.05)
		waited += 0.05


func _finish() -> void:
	print("PM_RESULT peer=%d checks=%d failures=%d" % [_peer_id, _checks, _failures])
	await _wait(10.0 if multiplayer.is_server() else 0.5)
	get_tree().quit(0 if _failures == 0 else 1)
