extends Node

# GD (2026-11-22): the sword's block (sword_guard, the sword's fourth slot)
# and its mastery, on both peers' bodies.
#
#   host:   --auto-host --auto-smoke --auto-only=GD --auto-port=P --auto-quit=150
#   client: --auto-join --auto-smoke --auto-only=GD --auto-port=P --auto-quit=150
#
# The host stands its body 1.6 m east of the client's; each body faces the
# other. The client's body is the guard first, then the host's. The guard is
# raised by the guarding peer's own slot (its intent travels as in play); the
# blow is the server's: the host, on seeing the guard come up in its own
# record, sets the mastery and lands a thrust from the other body through
# apply_hit (the ruling under test), or throws a rock at it. Four raises:
#   1. mastery 0, blow 0.05 s after the raise: blocked, 15 % of the damage
#      lands, no perfect guard;
#   2. mastery 5, 0.05 s: perfect -- nothing lands, no push, the attacker is
#      held still (STUNNED);
#   3. mastery 5, 0.5 s (past the window): blocked, 15 % lands;
#   4. mastery 5, a rock thrown at the guard as the raise is seen: sent back.
#   (3 also turns the guarding body 120 degrees away right after the press:
#   the sword's guard keeps the heading its press sent, so it still blocks.)
#   5. the guard held, the guarding body walked at 3 m/s by hand past the
#      client's own rule (the sword's guard holds it still): the server warns;
#      then the guard down and an ordinary walk at once: no warning.
# The server's numbers are read on the host.

const SEQUENCE_AT := 12.0
const GAP := 1.6
const RAISES := 5
const RAISE_EVERY := 3.0
const HOLD := 1.2

var _world: Node3D
var _local: Player
var _mate: Player
var _peer_id := 0
var _checks := 0
var _failures := 0
var _lag := 0.0
var _started_msec := 0
var _judge: ServerAuthority
var _mate_peer := 0


func expect(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("GD_CHECK peer=%d %s %s" % [_peer_id, "PASS" if condition else "FAIL", label])


func note(line: String) -> void:
	print("GD_NOTE peer=%d %s" % [_peer_id, line])


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _elapsed() -> float:
	return float(Time.get_ticks_msec() - _started_msec) / 1000.0


func run(world: Node3D) -> void:
	_world = world
	_peer_id = multiplayer.get_unique_id()
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--be-latency="):
			_lag = argument.trim_prefix("--be-latency=").to_float() / 1000.0
	if multiplayer.is_server():
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
	_mate_peer = _mate.get_multiplayer_authority()
	_started_msec = Time.get_ticks_msec()
	await _wait(1.0)
	_local.set_weapon(WeaponKinds.Kind.SWORD)
	await _wait(1.5 + _lag * 2.0)
	expect(_local.weapon == WeaponKinds.Kind.SWORD, "the_sword_is_in_hand")
	var slot := -1
	for index in PlayerSkills.SLOT_COUNT:
		var held := _local.skills.slot_def(index)
		if held != null and held.id == "sword_guard":
			slot = index
	expect(slot >= 0, "the_sword_block_is_in_a_slot")
	while _elapsed() < SEQUENCE_AT + _lag * 2.0:
		await _wait(0.05)
	if multiplayer.is_server():
		await _stand_by_mate()
		# The client's raises, ruled here.
		await _judge_raises(_mate, _local, "client")
		# Then this body's own.
		await _wait(1.0)
		# Raised and ruled side by side: the series is not awaited.
		_raise_series(slot)
		await _judge_raises(_local, _mate, "host")
		await _wait(1.0)
		note("server: perfect guards %d, reflected %d, blocks broken %d" % [
			_judge.guards_perfect, _judge.guards_reflected, _judge.blocks_broken])
		expect(_judge.guards_perfect == 2, "the_server_ruled_one_perfect_guard_per_body")
		expect(_judge.guards_reflected == 2, "the_server_sent_back_one_rock_per_body")
	else:
		await _until(func() -> bool: return _flat_gap() < GAP + 0.4, 60.0)
		await _wait(1.0)
		await _raise_series(slot)
		# The host's own raises come after; stay for them.
		await _wait(RAISES * RAISE_EVERY + 6.0 + _lag * 4.0)
	_finish()


# This body raises its guard RAISES times, facing the other.
func _raise_series(slot: int) -> void:
	for raise in RAISES:
		var to := _mate.global_position
		# The press turns the body to the cursor: headless has none, so the
		# check points it at the other body.
		_local.movement.set_aim_override(to)
		Net.queue_physics(func() -> void:
			_local.look_at(Vector3(to.x, _local.global_position.y, to.z), Vector3.UP))
		for frame in 3:
			await get_tree().physics_frame
		var ok := _local.skills.press_slot(slot)
		note("raise %d pressed: %s" % [raise + 1, ok])
		if raise == 2:
			# Turned away by hand right after the press.
			await _wait(0.05)
			Net.queue_physics(func() -> void: _local.rotation.y += deg_to_rad(120.0))
		if raise == 4:
			await _wait(0.6)
			var side := _local.global_transform.basis.x
			side.y = 0.0
			side = side.normalized()
			var walked := 0.0
			while walked < 0.6:
				await get_tree().physics_frame
				var step := 1.0 / 120.0
				walked += step
				_local.global_position += side * 3.0 * step
			await _wait(0.3)
			_local.skills.release_slot(slot)
			await _wait(0.05)
			_local.movement.set_target(_local.global_position + side * 3.0)
			await _wait(RAISE_EVERY)
			continue
		await _wait(HOLD)
		_local.skills.release_slot(slot)
		await _wait(RAISE_EVERY - HOLD)


# Host: the guard on `guard` comes up RAISES times; each is answered.
func _judge_raises(guard: Player, attacker: Player, who: String) -> void:
	var peer := guard.get_multiplayer_authority()
	for raise in RAISES:
		var up := 0.0
		while not _judge.is_blocking(peer) and up < 20.0:
			await get_tree().physics_frame
			up += 1.0 / 120.0
		expect(_judge.is_blocking(peer), "%s_guard_%d_came_up" % [who, raise + 1])
		Tuning.server.mastery_debug_level = 0 if raise == 0 else 5
		# The rock (4) is thrown at once: its placing (6 steps) and flight
		# (1.6 m at 14 m/s) already take 0.16 s of the 0.2 s window.
		var delay := 0.5 if raise == 2 else (0.0 if raise == 3 else 0.05)
		await _wait(delay)
		if raise == 4:
			var before := _judge.move_warnings
			while _judge.is_blocking(peer):
				await get_tree().physics_frame
			var during := _judge.move_warnings - before
			await _wait(2.0 + _lag * 2.0)
			var after := _judge.move_warnings - before - during
			note("%s: move warnings while walking with the guard up %d, after it came down and a walk %d" % [who, during, after])
			expect(during >= 1, "%s_a_walk_with_the_sword_guard_up_is_warned" % who)
			expect(after == 0, "%s_the_walk_after_the_guard_is_not_warned" % who)
			continue
		if raise == 3:
			await _throw_rock_at(guard, who)
		else:
			_land_thrust(guard, attacker, who, raise)
			await _wait(0.3 + _lag * 2.0)
			if raise == 1:
				note("%s: attacker %s state %s after the perfect guard; ruling %s" % [who, attacker.name, Player.State.keys()[attacker.state], _judge.last_guard])
				expect(attacker.state == Player.State.STUNNED, "%s_perfect_guard_holds_the_attacker" % who)
		while _judge.is_blocking(peer):
			await get_tree().physics_frame
	Tuning.server.mastery_debug_level = 5


func _land_thrust(guard: Player, attacker: Player, who: String, raise: int) -> void:
	var thrust := Skills.get_def("thrust")
	var direction := guard.global_position - attacker.global_position
	direction.y = 0.0
	var perfect_before := _judge.guards_perfect
	var hit := _judge.apply_hit(attacker, guard, thrust, {"direction": direction.normalized(), "source_strength": 0.0})
	var final := float(hit.get("final", 0.0))
	var dealt := float(hit.get("dealt", -1.0))
	var knock := _judge.last_knock.get(guard.get_multiplayer_authority(), {}) as Dictionary
	note("%s raise %d (mastery %d): final %.2f dealt %.2f blocked %s perfect %s knock %s" % [
		who, raise + 1, int(Tuning.server.mastery_debug_level), final, dealt, hit.get("blocked", false),
		_judge.guards_perfect > perfect_before, knock])
	if raise == 1:
		expect(dealt == 0.0 and _judge.guards_perfect == perfect_before + 1, "%s_perfect_guard_takes_nothing" % who)
	else:
		expect(bool(hit.get("blocked", false)) and absf(dealt - final * 0.15) < 0.01 and _judge.guards_perfect == perfect_before,
			"%s_guard_%d_lets_15_percent_through" % [who, raise + 1])


func _throw_rock_at(guard: Player, who: String) -> void:
	var rock: Rock = null
	for node in _world.find_children("*", "", true, false):
		if node is Rock and (node as Rock).holder_peer == 0:
			rock = node as Rock
			break
	expect(rock != null, "%s_a_rock_to_throw" % who)
	if rock == null:
		return
	# In front of the guard as the server holds it: the heading its press
	# sent (the body's facing on this screen can still be turning back from
	# raise 3's turn).
	var forward := -guard.global_transform.basis.z
	var record: Dictionary = _judge._blocks.get(guard.get_multiplayer_authority(), {})
	if record.has("direction"):
		forward = record["direction"]
	forward.y = 0.0
	forward = forward.normalized()
	var from := guard.global_position + forward * 1.6 + Vector3.UP * 0.9
	var reflected_before := _judge.guards_reflected
	Net.queue_physics(func() -> void:
		rock.global_position = from
		rock.linear_velocity = Vector3.ZERO)
	for frame in 6:
		await get_tree().physics_frame
	var toward := (guard.global_position + Vector3.UP * 0.9 - rock.global_position).normalized()
	_judge.send_force(rock, ForceSystem.make_event(ForceSystem.Kind.THROW, toward, 14.0, 0.0, 1, true, 0.0, 0.0))
	# Read right after the turn: the rock can meet a body on its way back.
	var flew := 0.0
	while _judge.guards_reflected == reflected_before and flew < 0.6:
		await get_tree().physics_frame
		flew += 1.0 / 120.0
	for frame in 3:
		await get_tree().physics_frame
	var away := rock.linear_velocity.dot(forward)
	note("%s: rock sent at the guard, reflected %d -> %d, its speed along the guard's front now %.2f" % [
		who, reflected_before, _judge.guards_reflected, away])
	expect(_judge.guards_reflected == reflected_before + 1 and away > 1.0, "%s_guard_sends_the_rock_back" % who)


func _flat_gap() -> float:
	return Vector2(_mate.global_position.x - _local.global_position.x, _mate.global_position.z - _local.global_position.z).length()


func _until(seen: Callable, limit: float) -> void:
	var waited := 0.0
	while waited < limit and not bool(seen.call()):
		await _wait(0.1)
		waited += 0.1


func _stand_by_mate() -> void:
	var spot := _mate.global_position + Vector3(GAP, 0.0, 0.0)
	Net.queue_physics(func() -> void:
		_local.global_position = spot
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target())
	await _wait(0.6)


func _finish() -> void:
	print("GD_RESULT peer=%d checks=%d failures=%d" % [_peer_id, _checks, _failures])
	await _wait(10.0 if multiplayer.is_server() else 0.5)
	get_tree().quit(0 if _failures == 0 else 1)
