extends Node

# GF (2026-11-24): the guard's rulings a well-behaved owner never asks for,
# and the ones only the server sees. Both peers' bodies, the client's first.
#
#   host:   --auto-host --auto-smoke --auto-only=GF --auto-port=P --auto-quit=120
#   client: --auto-join --auto-smoke --auto-only=GF --auto-port=P --auto-quit=120
#
# The host stands its body 1.6 m east of the client's. The body under test
# sends its requests itself (the client's travel as in play), straight to the
# server and past its own slot's rules -- what a forged client would send. The
# host tells it when (act), and reads the server's numbers:
#   1. "guard down" six times with no guard up: the move check is not
#      forgiven (it was, every time: a way to switch the speed check off);
#   2. a thrust cast, a raise 0.15 s into it: refused, the guard never up;
#      the same raise once the cast is over: granted;
#   3. the guard up past its grace, then a dash: the dash's speed is allowed
#      (the guard's pace used to be set over it);
#   4. the guard up, a rock thrown at it from well off its front: sent the
#      way the guard is turned, not back the way it came;
#   5. a perfect guard the pool cannot pay for: the blow lands whole, no
#      perfect guard is ruled and the guard breaks;
#   6. a thrown thing perfectly guarded (too heavy to send back) opens no
#      counter; a blow perfectly guarded opens it.

const GAP := 1.6
const SIDE_ANGLE := 120.0

var _world: Node3D
var _local: Player
var _mate: Player
var _peer_id := 0
var _checks := 0
var _failures := 0
var _lag := 0.0
var _judge: ServerAuthority
var _thrust_slot := -1
var _done := false


func expect(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("GF_CHECK peer=%d %s %s" % [_peer_id, "PASS" if condition else "FAIL", label])


func note(line: String) -> void:
	print("GF_NOTE peer=%d %s" % [_peer_id, line])


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


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
	await _wait(1.0)
	_local.set_weapon(WeaponKinds.Kind.SWORD)
	await _wait(1.5 + _lag * 2.0)
	expect(_local.weapon == WeaponKinds.Kind.SWORD, "the_sword_is_in_hand")
	for index in PlayerSkills.SLOT_COUNT:
		var held := _local.skills.slot_def(index)
		if held != null and held.id == "thrust":
			_thrust_slot = index
	expect(_thrust_slot >= 0, "the_thrust_is_in_a_slot")
	if not multiplayer.is_server():
		# The host says when; stay until it says it is over.
		var stayed := 0.0
		while not _done and stayed < 110.0:
			await _wait(0.2)
			stayed += 0.2
		_finish()
		return
	await _wait(4.0 + _lag * 4.0)
	await _stand_by_mate()
	var angle_before: float = Tuning.server.sword_guard_angle
	var regen_before: float = Tuning.server.stamina_regen
	var mastery_before: int = int(Tuning.server.mastery_debug_level)
	for body: Player in [_mate, _local]:
		var who := "client" if body == _mate else "host"
		var other := _local if body == _mate else _mate
		await _down_spam(body, who)
		await _raise_mid_cast(body, other, who)
		await _dash_out_of_guard(body, other, who)
		Tuning.server.sword_guard_angle = SIDE_ANGLE
		await _side_reflect(body, other, who)
		Tuning.server.sword_guard_angle = angle_before
		var share_before: float = Tuning.server.guard_reflect_lift_share
		Tuning.server.guard_reflect_lift_share = 0.0
		await _counter_after_perfect(body, other, who)
		Tuning.server.guard_reflect_lift_share = share_before
		Tuning.server.stamina_regen = 0.0
		await _perfect_unpaid(body, other, who)
		Tuning.server.stamina_regen = regen_before
		await _wait(1.0)
	Tuning.server.mastery_debug_level = mastery_before
	over.rpc()
	_finish()


# ------------------------------------------------------------ the acting body

# Host -> the peer whose body is under test.
@rpc("authority", "call_remote", "reliable")
func act(step: String, at: Vector3) -> void:
	_act(step, at)


@rpc("authority", "call_remote", "reliable")
func over() -> void:
	_done = true


func _ask(body: Player, step: String, at := Vector3.ZERO) -> void:
	if body == _local:
		_act(step, at)
	else:
		act.rpc_id(body.get_multiplayer_authority(), step, at)


# Requests sent as a forged client would: straight to the server, past the
# slot's own rules. `at` is a point in the world the request is turned to.
func _act(step: String, at: Vector3) -> void:
	var toward := at - _local.global_position
	toward.y = 0.0
	toward = toward.normalized() if toward.length_squared() > 0.0001 else Vector3.FORWARD
	var raise := {"on": true, "guard": "sword_guard", "direction": toward}
	match step:
		"off_spam":
			for count in 6:
				ServerAuthority.submit_intent(_local, ServerAuthority.Intent.BLOCK, {"on": false})
				await _wait(0.05)
		"cast_raise":
			_local.movement.set_aim_override(at)
			for frame in 3:
				await get_tree().physics_frame
			var cast := _local.skills.cast_slot(_thrust_slot)
			note("thrust cast here: %s" % cast)
			await _wait(0.15)
			ServerAuthority.submit_intent(_local, ServerAuthority.Intent.BLOCK, raise)
		"raise":
			ServerAuthority.submit_intent(_local, ServerAuthority.Intent.BLOCK, raise)
		"lower":
			ServerAuthority.submit_intent(_local, ServerAuthority.Intent.BLOCK, {"on": false})
		"dash":
			ServerAuthority.submit_intent(_local, ServerAuthority.Intent.DASH, {})


# ------------------------------------------------------------- the host's reads

func _forgive(peer: int) -> int:
	return int((_judge._move_watch.get(peer, {}) as Dictionary).get("forgive", 0))


func _blocking_within(peer: int, limit: float) -> bool:
	var waited := 0.0
	while not _judge.is_blocking(peer) and waited < limit:
		await get_tree().physics_frame
		waited += 1.0 / 120.0
	return _judge.is_blocking(peer)


func _down_within(peer: int, limit: float) -> void:
	var waited := 0.0
	while _judge.is_blocking(peer) and waited < limit:
		await get_tree().physics_frame
		waited += 1.0 / 120.0


# 1: "guard down" with no guard up forgives nothing.
func _down_spam(body: Player, who: String) -> void:
	var peer := body.get_multiplayer_authority()
	var settled := 0.0
	while _forgive(peer) > 0 and settled < 8.0:
		await get_tree().physics_frame
		settled += 1.0 / 120.0
	var granted := _judge.granted_intents
	_ask(body, "off_spam")
	var most := 0
	var watched := 0.0
	while watched < 0.8 + _lag * 2.0:
		await get_tree().physics_frame
		watched += 1.0 / 120.0
		most = maxi(most, _forgive(peer))
	note("%s: six downs with no guard up: requests granted %d, most move samples forgiven %d (settled after %.2f s)" % [
		who, _judge.granted_intents - granted, most, settled])
	expect(_judge.granted_intents - granted >= 6 and most == 0, "%s_a_down_with_no_guard_up_forgives_no_move" % who)


# 2: no guard inside a cast; the same raise after it.
func _raise_mid_cast(body: Player, other: Player, who: String) -> void:
	var peer := body.get_multiplayer_authority()
	var away := body.global_position + (body.global_position - other.global_position).normalized() * 3.0
	var ruled := _judge.skills_ruled
	var refused := _judge.blocks_refused_mid_cast
	_ask(body, "cast_raise", away)
	var up := false
	var watched := 0.0
	while watched < 1.0 + _lag * 2.0:
		await get_tree().physics_frame
		watched += 1.0 / 120.0
		up = up or _judge.is_blocking(peer)
	note("%s: a raise 0.15 s into a thrust: casts ruled %d, raises refused mid cast %d, guard seen up %s" % [
		who, _judge.skills_ruled - ruled, _judge.blocks_refused_mid_cast - refused, up])
	expect(_judge.skills_ruled - ruled == 1, "%s_the_thrust_was_ruled" % who)
	expect(not up and _judge.blocks_refused_mid_cast - refused == 1, "%s_a_raise_inside_a_cast_is_refused" % who)
	await _wait(2.5 + _lag * 2.0)
	_ask(body, "raise", other.global_position)
	var after := await _blocking_within(peer, 1.5 + _lag * 2.0)
	expect(after, "%s_the_same_raise_after_the_cast_is_granted" % who)
	await _wait(0.9)
	_ask(body, "lower")
	await _down_within(peer, 2.0 + _lag * 2.0)


# 3: the dash's speed is allowed with the guard up.
func _dash_out_of_guard(body: Player, other: Player, who: String) -> void:
	var peer := body.get_multiplayer_authority()
	await _wait(0.6)
	_ask(body, "raise", other.global_position)
	var up := await _blocking_within(peer, 1.5 + _lag * 2.0)
	await _wait(SyncRules.GUARD_SPEED_GRACE + 0.2)
	var held := _judge.move_allowance(body).x
	_ask(body, "dash")
	var most := 0.0
	var watched := 0.0
	while watched < 0.5 + _lag * 2.0:
		await get_tree().physics_frame
		watched += 1.0 / 120.0
		if _judge.is_blocking(peer):
			most = maxf(most, _judge.move_allowance(body).x)
	note("%s: guard up %s; allowed speed with the guard held %.2f m/s, after a dash %.2f (the walk %.2f, the dash %.2f)" % [
		who, up, held, most, body.get_move_speed(), body.dash_speed()])
	expect(up and held < body.get_move_speed(), "%s_a_held_guard_is_held_to_its_own_pace" % who)
	expect(most >= body.dash_speed(), "%s_a_dash_is_allowed_its_speed_with_the_guard_up" % who)
	await _wait(0.5)
	_ask(body, "lower")
	await _down_within(peer, 2.0 + _lag * 2.0)


# 4: a thrown thing is sent the way the guard is turned.
func _side_reflect(body: Player, other: Player, who: String) -> void:
	var peer := body.get_multiplayer_authority()
	var rock: Rock = null
	for node in _world.find_children("*", "", true, false):
		if node is Rock and (node as Rock).holder_peer == 0:
			rock = node as Rock
			break
	expect(rock != null, "%s_a_rock_to_throw" % who)
	if rock == null:
		return
	Tuning.server.mastery_debug_level = 5
	await _wait(0.6)
	_ask(body, "raise", other.global_position)
	var up := await _blocking_within(peer, 1.5 + _lag * 2.0)
	var forward := -body.global_transform.basis.z
	var record: Dictionary = _judge._blocks.get(peer, {})
	if record.has("direction"):
		forward = record["direction"]
	forward.y = 0.0
	forward = forward.normalized()
	# From well off the guard's front, still inside its angle.
	var off := maxf(_judge.block_angle(peer) * 0.5 - 10.0, 0.0)
	var from_side := forward.rotated(Vector3.UP, deg_to_rad(off))
	var from := body.global_position + from_side * 1.6 + Vector3.UP * 0.9
	var reflected := _judge.guards_reflected
	Net.queue_physics(func() -> void:
		rock.global_position = from
		rock.linear_velocity = Vector3.ZERO)
	for frame in 6:
		await get_tree().physics_frame
	var toward := (body.global_position + Vector3.UP * 0.9 - rock.global_position).normalized()
	_judge.send_force(rock, ForceSystem.make_event(ForceSystem.Kind.THROW, toward, 14.0, 0.0, 1, true, 0.0, 0.0))
	var flew := 0.0
	while _judge.guards_reflected == reflected and flew < 0.6:
		await get_tree().physics_frame
		flew += 1.0 / 120.0
	for frame in 3:
		await get_tree().physics_frame
	var flat := Vector3(rock.linear_velocity.x, 0.0, rock.linear_velocity.z)
	var apart := rad_to_deg(forward.angle_to(flat.normalized())) if flat.length_squared() > 0.0001 else 180.0
	note("%s: guard up %s, angle %.0f; a rock from %.0f deg off its front: reflected %d -> %d, flying %.1f deg off the guard's heading at %.1f m/s" % [
		who, up, _judge.block_angle(peer), off, reflected, _judge.guards_reflected, apart, flat.length()])
	expect(off >= 15.0, "%s_the_rock_comes_from_off_the_front" % who)
	expect(_judge.guards_reflected == reflected + 1 and apart < 8.0, "%s_the_rock_is_sent_the_way_the_guard_is_turned" % who)
	await _wait(0.9)
	_ask(body, "lower")
	await _down_within(peer, 2.0 + _lag * 2.0)


# 6: the counter opens on a blow perfectly guarded, not on a thrown thing.
# (Nothing is sent back here: the reflect limit is 0 for this.)
func _counter_after_perfect(body: Player, other: Player, who: String) -> void:
	var peer := body.get_multiplayer_authority()
	var rock: Rock = null
	for node in _world.find_children("*", "", true, false):
		if node is Rock and (node as Rock).holder_peer == 0:
			rock = node as Rock
			break
	if rock == null:
		expect(false, "%s_a_rock_for_the_counter_check" % who)
		return
	Tuning.server.mastery_debug_level = 5
	await _wait(1.0)
	_ask(body, "raise", other.global_position)
	var up := await _blocking_within(peer, 1.5 + _lag * 2.0)
	var forward := -body.global_transform.basis.z
	var record: Dictionary = _judge._blocks.get(peer, {})
	if record.has("direction"):
		forward = record["direction"]
	forward.y = 0.0
	forward = forward.normalized()
	var from := body.global_position + forward * 1.6 + Vector3.UP * 0.9
	var perfect := _judge.guards_perfect
	var opened := _judge.counters_opened
	var reflected := _judge.guards_reflected
	Net.queue_physics(func() -> void:
		rock.global_position = from
		rock.linear_velocity = Vector3.ZERO)
	for frame in 6:
		await get_tree().physics_frame
	var toward := (body.global_position + Vector3.UP * 0.9 - rock.global_position).normalized()
	_judge.send_force(rock, ForceSystem.make_event(ForceSystem.Kind.THROW, toward, 14.0, 0.0, 1, true, 0.0, 0.0))
	var flew := 0.0
	while _judge.guards_perfect == perfect and flew < 0.6:
		await get_tree().physics_frame
		flew += 1.0 / 120.0
	note("%s: guard up %s; a rock perfectly guarded: perfect guards %d -> %d, sent back %d -> %d, counters opened %d -> %d" % [
		who, up, perfect, _judge.guards_perfect, reflected, _judge.guards_reflected, opened, _judge.counters_opened])
	expect(_judge.guards_perfect == perfect + 1 and _judge.guards_reflected == reflected, "%s_the_rock_is_perfectly_guarded_not_sent_back" % who)
	expect(_judge.counters_opened == opened, "%s_a_thrown_thing_perfectly_guarded_opens_no_counter" % who)
	await _wait(0.9)
	_ask(body, "lower")
	await _down_within(peer, 2.0 + _lag * 2.0)
	# The blow.
	await _wait(1.0)
	_ask(body, "raise", other.global_position)
	up = await _blocking_within(peer, 1.5 + _lag * 2.0)
	perfect = _judge.guards_perfect
	opened = _judge.counters_opened
	var direction := body.global_position - other.global_position
	direction.y = 0.0
	_judge.apply_hit(other, body, Skills.get_def("thrust"), {"direction": direction.normalized(), "source_strength": 0.0})
	note("%s: guard up %s; a thrust perfectly guarded: perfect guards %d -> %d, counters opened %d -> %d" % [
		who, up, perfect, _judge.guards_perfect, opened, _judge.counters_opened])
	expect(_judge.guards_perfect == perfect + 1 and _judge.counters_opened == opened + 1, "%s_a_blow_perfectly_guarded_opens_the_counter" % who)
	await _wait(1.2 + _lag * 2.0)
	_ask(body, "lower")
	await _down_within(peer, 2.0 + _lag * 2.0)
	await _wait(1.0)


# 5: a perfect guard the pool cannot pay for is no guard.
func _perfect_unpaid(body: Player, other: Player, who: String) -> void:
	var peer := body.get_multiplayer_authority()
	Tuning.server.mastery_debug_level = 5
	await _wait(0.6)
	_judge.server_set_stamina(body, 0.5)
	_ask(body, "raise", other.global_position)
	var up := await _blocking_within(peer, 1.5 + _lag * 2.0)
	var perfect := _judge.guards_perfect
	var broken := _judge.blocks_broken
	var thrust := Skills.get_def("thrust")
	var direction := body.global_position - other.global_position
	direction.y = 0.0
	var hit := _judge.apply_hit(other, body, thrust, {"direction": direction.normalized(), "source_strength": 0.0})
	var final := float(hit.get("final", 0.0))
	var dealt := float(hit.get("dealt", -1.0))
	note("%s: guard up %s, 0.5 stamina, a thrust inside the perfect window: final %.2f dealt %.2f blocked %s, perfect guards %d -> %d, broken %d -> %d, still up %s, block %s" % [
		who, up, final, dealt, hit.get("blocked", false), perfect, _judge.guards_perfect, broken, _judge.blocks_broken,
		_judge.is_blocking(peer), _judge.last_block])
	expect(up and final > 0.0 and absf(dealt - final) < 0.01 and not bool(hit.get("blocked", false)),
		"%s_a_guard_the_pool_cannot_pay_for_lets_the_blow_land_whole" % who)
	expect(_judge.guards_perfect == perfect and _judge.blocks_broken == broken + 1 and not _judge.is_blocking(peer),
		"%s_and_it_breaks_with_no_perfect_guard" % who)
	if body.stats != null:
		_judge.server_set_stamina(body, body.stats.max_stamina)
	var locked := 0.0
	while _judge.block_locked(peer) and locked < 3.0:
		await get_tree().physics_frame
		locked += 1.0 / 120.0
	await _wait(0.5 + _lag * 2.0)


func _stand_by_mate() -> void:
	var spot := _mate.global_position + Vector3(GAP, 0.0, 0.0)
	Net.queue_physics(func() -> void:
		_local.global_position = spot
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target())
	await _wait(0.6)


func _finish() -> void:
	print("GF_RESULT peer=%d checks=%d failures=%d" % [_peer_id, _checks, _failures])
	await _wait(10.0 if multiplayer.is_server() else 0.5)
	get_tree().quit(0 if _failures == 0 else 1)
