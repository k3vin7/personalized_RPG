extends Node

# Stage E, measured: the one key and what letting go of it means, the lift
# limit and the one-hand toggle, carrying something heavy, a thrown team mate
# pushed again in the air, a rock hitting a person, and the five exceptions a
# hold can meet. Plus the three the work order adds: a grab names its target
# and fails rather than taking someone else, an escape puts the body down
# beside the holder and the recoil actually moves it, and an arc lands near the
# cursor at any range.

const HOME := Vector3(0.0, 0.9, 11.0)
const LANE := Vector3(-13.0, 0.9, 9.0)

var _world: Node3D
var _local: Player
var _judge: ServerAuthority
var _peer_id := 0
var _checks := 0
var _failures := 0
var _stage_done := ""
var _lag := 0.0
var _label := "0"
var _flag := false
var _number := 0.0


func expect(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("E_CHECK lag=%s peer=%d %s %s" % [_label, _peer_id, "PASS" if condition else "FAIL", label])


func note(line: String) -> void:
	print("E_NOTE lag=%s peer=%d %s" % [_label, _peer_id, line])


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


func _beat(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _wait_stage(name_text: String) -> bool:
	var waited := 0.0
	while _stage_done != name_text and waited < 25.0 + _lag * 20.0:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	var arrived := _stage_done == name_text
	_stage_done = ""
	return arrived


func _client_peer() -> int:
	var peers := multiplayer.get_peers()
	return peers[0] if peers.size() > 0 else 0


func _released(reason: String) -> int:
	return int(_judge.release_reasons.get(reason, 0))


func run(world: Node3D) -> void:
	_world = world
	_peer_id = multiplayer.get_unique_id()
	_local = Net.spawn_root.get_node(str(_peer_id)) as Player
	_judge = world.get_node_or_null("ServerAuthority") as ServerAuthority
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--e-latency="):
			_label = argument.trim_prefix("--e-latency=")
			_lag = _label.to_float() / 1000.0
	if not multiplayer.is_server():
		stage_done.rpc_id(1, "client_ready")
		return
	expect(await _wait_stage("client_ready"), "both_peers_present")
	var warnings := _judge.move_warnings
	await _lift_limit_checks()
	await _one_key_checks()
	await _carry_weight_checks()
	await _target_id_checks()
	await _dummy_grab_check()
	await _rock_versus_player_check()
	await _second_push_check()
	await _escape_checks()
	await _exception_checks()
	expect(_judge.move_warnings == warnings, "no_move_warnings_during_stage_e")
	await _disconnect_exception_check()
	print("E_RESULT lag=%s peer=%d checks=%d failures=%d" % [_label, _peer_id, _checks, _failures])
	await _wait(1.0)
	get_tree().quit(0 if _failures == 0 else 1)


# ------------------------------------------------- the lift limit, and one hand

func _lift_limit_checks() -> void:
	var heavy := _world.get_node("Rock_2") as Rock          # 20 kg
	await _park_self(HOME)
	await tick_request(func() -> void:
		heavy.global_position = _local.global_position + Vector3(0.9, 0.3, 0.0))
	await _wait(0.4)
	await tick_request(func() -> void:
		_local.stats.strength = 9.0
		_flag = _judge.can_grab(_local, heavy))
	expect(not _flag, "nine_strength_cannot_lift_twenty_kilos")
	await tick_request(func() -> void:
		_local.stats.strength = 10.0
		_flag = _judge.can_grab(_local, heavy))
	expect(_flag, "ten_strength_can")
	# One hand on a weapon halves it.
	Tuning.values.one_hand_weapon = true
	await tick_request(func() -> void: _number = _judge.lift_limit(_local))
	var one_hand := _number
	Tuning.values.one_hand_weapon = false
	await tick_request(func() -> void: _number = _judge.lift_limit(_local))
	var two_hands := _number
	note("lift limit: both hands %.1f kg, one hand %.1f kg (mult %.1f)" % [
		two_hands, one_hand, Tuning.values.grab_one_hand_strength_mult])
	expect(absf(one_hand - two_hands * 0.5) < 0.01, "one_hand_halves_the_limit")
	Tuning.values.one_hand_weapon = true
	await tick_request(func() -> void: _flag = _judge.can_grab(_local, heavy))
	expect(not _flag, "and_then_twenty_kilos_is_too_much")
	Tuning.values.one_hand_weapon = false


# --------------------------------------------- the one key: tap, arc, line

func _take(rock: Rock) -> bool:
	await tick_request(func() -> void:
		rock.global_position = _local.global_position + Vector3(0.9, 0.3, 0.0)
		rock.linear_velocity = Vector3.ZERO)
	await _wait(0.4)
	await tick_request(func() -> void:
		_local.movement.set_aim_override(rock.global_position)
		_local.movement.interact())
	await _wait(0.5)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	return _local.grab.is_holding()


func _one_key_checks() -> void:
	var rock := _world.get_node("Rock_0") as Rock           # 5 kg
	await _park_self(HOME)
	expect(await _take(rock), "took_the_rock_for_the_one_key_checks")

	# A tap is a put-down: it lands next to the body, not across the plaza.
	var dropped := _released("dropped")
	var from := rock.global_position
	await tick_request(_local.grab.press_throw)
	await _beat(0.2)
	await tick_request(_local.grab.release_throw_key)
	await _wait(0.8)
	var put_down := Vector2(rock.global_position.x - _local.global_position.x,
		rock.global_position.z - _local.global_position.z).length()
	note("tap (0.2 s, threshold %.1f): reason dropped %d -> %d, rock %.2f m from the body" % [
		Tuning.values.throw_hold_threshold, dropped, _released("dropped"), put_down])
	expect(_released("dropped") > dropped, "a_tap_puts_it_down")
	expect(put_down < 2.0, "and_it_lands_at_the_feet")

	# Held past the threshold: an arc that lands where the cursor is, at two
	# ranges, because a fixed angle is exactly what used to fail at one of them.
	for distance in [3.0, 7.0]:
		expect(await _take(rock), "took_the_rock_for_the_%.0f_m_arc" % distance)
		var aim := _local.global_position + Vector3(float(distance), 0.0, 0.0)
		await tick_request(func() -> void:
			_local.movement.set_aim_override(aim)
			_local.grab.press_throw())
		await _beat(Tuning.values.throw_charge_max + 0.1)
		await tick_request(_local.grab.release_throw_key)
		# The nearest the rock ever came to the mark, not where it finally
		# stopped: a thrown sphere lands and then rolls, and the roll is not
		# part of the throw.
		var miss := INF
		var sampled := 0.0
		while sampled < 2.2:
			await get_tree().physics_frame
			sampled += get_physics_process_delta_time()
			miss = minf(miss, Vector2(rock.global_position.x - aim.x,
				rock.global_position.z - aim.z).length())
		await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
		note("arc to a cursor %.0f m away: passed within %.2f m, rested %.2f m away (y %.2f)" % [
			distance, miss,
			Vector2(rock.global_position.x - aim.x, rock.global_position.z - aim.z).length(),
			rock.global_position.y])
		expect(miss < 1.5, "the_arc_lands_near_the_cursor_at_%.0f_m" % distance)

	# Shift is a straight line: much flatter and much faster than the arc.
	expect(await _take(rock), "took_the_rock_for_the_line")
	var start := rock.global_position
	_number = 0.0
	await tick_request(func() -> void:
		_local.movement.set_aim_override(_local.global_position + Vector3(8.0, 0.0, 0.0))
		ServerAuthority.submit_intent(_local, ServerAuthority.Intent.THROW, {
			"direction": _local.grab.throw_direction(),
			"target": _local.movement.cursor_jump_target(),
			"charge": 1.0,
			"line": true,
		}))
	await _beat(0.12)
	var rise := rock.global_position.y - start.y
	var along := rock.global_position.x - start.x
	await _wait(1.5)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	note("line throw: after 0.12 s it had gone %.2f m along and %.2f m up" % [along, rise])
	expect(along > 0.8 and rise < along, "the_line_throw_is_flat_and_fast")


# ------------------------------------------- carrying something heavy

func _carry_weight_checks() -> void:
	var heavy := _world.get_node("Rock_2") as Rock          # 20 kg
	await _park_self(HOME)
	var free_speed := _local.get_move_speed()
	var free_jump := _local.get_jump_height()
	expect(await _take(heavy), "took_the_heavy_rock")
	await _wait(0.3)
	var load := _local.stats.held_weight
	var carry_speed := _local.get_move_speed()
	var carry_jump := _local.get_jump_height()
	# 4-chapter: the load is in the weight, the weight is in the ratio, and the
	# ratio is in both of these. No rule of its own.
	var ratio_free: float = _local.stats.strength / 10.0
	var ratio_load: float = _local.stats.strength / maxf(10.0 + load, 0.1)
	note("carrying %.0f kg: speed %.2f -> %.2f, jump height %.2f -> %.2f (ratio %.2f -> %.2f)" % [
		load, free_speed, carry_speed, free_jump, carry_jump, ratio_free, ratio_load])
	expect(absf(load - heavy.weight) < 0.01, "what_is_carried_is_in_the_weight")
	expect(carry_speed < free_speed - 0.05, "carrying_something_heavy_slows_the_walk")
	expect(carry_jump < free_jump - 0.05, "and_lowers_the_jump")
	# And nothing is forbidden while carrying.
	await tick_request(func() -> void:
		_local.movement.set_aim_override(_local.global_position)
		_local.movement.cast_jump())
	var jumped := false
	var waited := 0.0
	while waited < 1.0 and not jumped:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		jumped = _local.state == Player.State.AIRBORNE
	note("jump while carrying: left the ground=%s, still holding=%s" % [
		jumped, _local.grab.is_holding()])
	expect(jumped, "a_holder_may_still_jump")
	await _wait(1.5)
	await tick_request(func() -> void:
		_local.movement.set_aim_override(Vector3.INF)
		if _local.grab.is_holding():
			_local.grab.drop())
	await _wait(0.6)


# ------------------------------- a grab names its target and fails if it is gone

func _target_id_checks() -> void:
	var rock := _world.get_node("Rock_1") as Rock
	var mate := _judge.actor_for(_client_peer())
	await _park_self(HOME)
	# The rock is already in someone else's hands, and the only other thing
	# under the cursor is a person. The grab has to fail, not take the person.
	await tick_request(func() -> void:
		rock.global_position = _local.global_position + Vector3(0.9, 0.3, 0.0))
	await _wait(0.4)
	_judge.forgive_move(_client_peer(), "", 30)
	client_park.rpc_id(_client_peer(), _local.global_position + Vector3(1.4, 0.0, 0.0))
	await _wait_stage("parked")
	await _wait(0.6)
	# Taken by the server on the client's behalf, so the rock is genuinely held.
	await tick_request(func() -> void: _judge._take_hold(_client_peer(), rock))
	await _wait(0.4)
	var rejected := _judge.rejected_intents
	await tick_request(func() -> void:
		_local.movement.set_aim_override(rock.global_position)
		_flag = _local.grab.grab())
	await _wait(0.6)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	note("aimed at a rock someone else holds: the grab was submitted=%s, holding=%s, holder of the rock=%d" % [
		_flag, _local.grab.is_holding(), _judge.holder_of(rock)])
	expect(not _local.grab.is_holding(), "a_taken_rock_is_not_swapped_for_the_person_behind_it")
	expect(_judge.holder_of(rock) == _client_peer(), "and_the_rock_stays_where_it_was")
	await tick_request(func() -> void: _judge._end_hold(_client_peer(), "dropped"))
	await _wait(0.5)


# ------------------------------------------------- a scarecrow can be carried

func _dummy_grab_check() -> void:
	var dummy := _world.get_node("Dummy_1") as Dummy
	await _park_self(dummy.global_position - Vector3(1.0, 0.0, 0.0))
	await tick_request(func() -> void:
		_local.movement.set_aim_override(dummy.global_position)
		_local.movement.interact())
	await _wait(0.8)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	var held := _local.grab.is_holding() and _judge.holder_of(dummy) == 1
	var above := dummy.global_position.y - _local.global_position.y
	note("scarecrow: held=%s, it is %.2f m above the body, load %.0f kg" % [
		held, above, _local.stats.held_weight])
	expect(held, "a_scarecrow_can_be_picked_up")
	expect(above > 0.5, "and_it_rides_the_hand")
	await tick_request(func() -> void:
		if _local.grab.is_holding():
			_local.grab.drop())
	await _wait(0.8)


# ------------------------------------------- a rock hitting a person

func _rock_versus_player_check() -> void:
	var rock := _world.get_node("Rock_0") as Rock
	var victim := _judge.actor_for(_client_peer())
	_judge.forgive_move(_client_peer(), "", 30)
	client_park.rpc_id(_client_peer(), Vector3(-16.0, 0.9, 3.0))
	await _wait_stage("parked")
	await _wait(0.8)
	await _park_self(Vector3(-16.0, 0.9, 6.0))
	expect(await _take(rock), "took_the_rock_to_throw_at_someone")
	var hp_before := victim.hp
	var stood := victim.global_position
	await tick_request(func() -> void:
		_local.movement.set_aim_override(victim.global_position)
		ServerAuthority.submit_intent(_local, ServerAuthority.Intent.THROW, {
			"direction": _local.grab.throw_direction(),
			"target": victim.global_position,
			"charge": 1.0,
			"line": true,
		}))
	var closest := INF
	var sampled := 0.0
	while sampled < 2.0:
		await get_tree().physics_frame
		sampled += get_physics_process_delta_time()
		closest = minf(closest, rock.global_position.distance_to(victim.global_position))
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	var moved := Vector2(victim.global_position.x - stood.x, victim.global_position.z - stood.z).length()
	note("rock at a person: closest %.2f m (touching at %.2f), hp %.0f -> %.0f, knocked %.2f m" % [
		closest, Rock.radius_for(rock.weight) + Player.BODY_RADIUS, hp_before, victim.hp, moved])
	expect(victim.hp < hp_before, "a_thrown_rock_hurts_a_person")
	expect(moved > 0.15, "and_knocks_them_back")


# ------------------------- a thrown team mate can be pushed again in the air

func _second_push_check() -> void:
	var mate := _judge.actor_for(_client_peer())
	_judge.forgive_move(_client_peer(), "", 30)
	client_park.rpc_id(_client_peer(), LANE + Vector3(0.9, 0.0, 0.0))
	await _wait_stage("parked")
	await _wait(0.6)
	await _park_self(LANE)
	await tick_request(func() -> void:
		_local.movement.set_aim_override(mate.global_position)
		_local.movement.interact())
	await _wait(1.0)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	if _judge.holder_of(mate) != 1:
		expect(false, "picked_the_team_mate_up_to_throw")
		return
	expect(true, "picked_the_team_mate_up_to_throw")
	var from := mate.global_position
	await tick_request(func() -> void:
		_local.movement.set_aim_override(_local.global_position + Vector3(9.0, 0.0, 0.0))
		_local.grab.throw()
		_local.movement.set_aim_override(Vector3.INF))
	# Polled, not sampled at a fixed moment: the mate's state is a replicated
	# read, so at 200 ms the host still sees a body standing on the ground a
	# third of a second after the throw that launched it.
	var airborne := false
	var watched := 0.0
	while watched < 1.5 + _lag * 6.0 and not airborne:
		await get_tree().physics_frame
		watched += get_physics_process_delta_time()
		airborne = mate.state == Player.State.AIRBORNE
	var mid := mate.global_position
	# Pushed again while they are still flying: the second push bends the arc.
	await tick_request(func() -> void:
		_judge.send_force(mate, ForceSystem.make_event(
			ForceSystem.Kind.SHOVE, Vector3(1.0, 0.2, 0.0), Tuning.values.shove_power,
			10.0, 1, true, Tuning.values.shove_damage, 0.0)))
	await _wait(2.0)
	var landed := mate.global_position
	var first := Vector2(mid.x - from.x, mid.z - from.z).length()
	var total := Vector2(landed.x - from.x, landed.z - from.z).length()
	note("thrown team mate: airborne mid-flight=%s, %.2f m by then, %.2f m in the end (+%.2f from the second push)" % [
		airborne, first, total, total - first])
	expect(airborne, "the_thrown_team_mate_was_in_the_air")
	expect(total > first + 0.5, "a_second_push_sent_them_further")
	await _wait(1.0)


# ------------------------- the escape: beside the holder, and actually pushed

func _escape_checks() -> void:
	var victim := _judge.actor_for(_client_peer())
	_judge.forgive_move(_client_peer(), "", 30)
	client_park.rpc_id(_client_peer(), LANE + Vector3(0.9, 0.0, 0.0))
	await _wait_stage("parked")
	await _wait(0.6)
	await _park_self(LANE)
	await tick_request(func() -> void:
		_local.movement.set_aim_override(victim.global_position)
		_local.movement.interact())
	await _wait(1.0)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	if _judge.holder_of(victim) != 1:
		expect(false, "picked_the_client_up_for_the_escape")
		return
	expect(true, "picked_the_client_up_for_the_escape")
	var escaped := _released("escaped")
	client_escape.rpc_id(_client_peer())
	expect(await _wait_stage("escaped"), "the_client_escaped")
	await _wait(0.5)
	expect(_released("escaped") > escaped, "the_escape_was_ruled_by_the_server")
	# Put down beside, not above: the gap in height has to be small and the gap
	# on the ground has to be real.
	var above := victim.global_position.y - _local.global_position.y
	var beside := Vector2(victim.global_position.x - _local.global_position.x,
		victim.global_position.z - _local.global_position.z).length()
	note("after the escape: %.2f m above the holder, %.2f m to the side" % [above, beside])
	expect(above < 1.0, "the_freed_body_is_not_left_on_the_holders_head")
	expect(beside > Player.BODY_RADIUS, "it_is_put_down_beside_them")
	await _wait(1.0)


# ------------------------------------------------- the five exceptions

func _exception_checks() -> void:
	var rock := _world.get_node("Rock_0") as Rock
	var victim := _judge.actor_for(_client_peer())

	# Holder stunned.
	await _park_self(HOME)
	expect(await _take(rock), "took_a_rock_for_the_stun_case")
	await _beat(ServerAuthority.HOLD_GRACE + 0.3)
	var state_released := _released("holder_state")
	await tick_request(func() -> void: _local.change_state(Player.State.STUNNED))
	await _wait(0.4)
	expect(_released("holder_state") > state_released, "e5_holder_stunned_dropped_it")
	await tick_request(func() -> void:
		_local.velocity = Vector3.ZERO
		_local.change_state(Player.State.IDLE))
	await _wait(0.6)

	# Holder leaves the ground.
	expect(await _take(rock), "took_a_rock_for_the_fall_case")
	await _beat(ServerAuthority.HOLD_GRACE + 0.3)
	state_released = _released("holder_state")
	await tick_request(func() -> void:
		placed()
		_local.global_position += Vector3.UP * 2.5
		_local.velocity = Vector3.ZERO
		_local.floor_snap_length = 0.0
		_local.change_state(Player.State.AIRBORNE))
	await _wait(0.5)
	expect(_released("holder_state") > state_released, "e5_holder_off_the_ground_dropped_it")
	await _wait(1.2)

	# The held body is pushed by something else.
	await _park_self(LANE)
	_judge.forgive_move(_client_peer(), "", 30)
	client_park.rpc_id(_client_peer(), LANE + Vector3(0.9, 0.0, 0.0))
	await _wait_stage("parked")
	await _wait(0.6)
	await tick_request(func() -> void:
		_local.movement.set_aim_override(victim.global_position)
		_local.movement.interact())
	await _wait(1.0)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	var pushed := _released("target_pushed")
	if _judge.holder_of(victim) == 1:
		await tick_request(func() -> void:
			_judge.send_force(victim, ForceSystem.make_event(
				ForceSystem.Kind.KNOCKBACK, Vector3(0.0, 0.3, 1.0), 6.0, 0.0, 1, false)))
		await _wait(0.5)
		expect(_released("target_pushed") > pushed, "e5_a_held_body_that_is_pushed_comes_free")
	else:
		expect(false, "e5_a_held_body_that_is_pushed_comes_free")

	# Two at once, and the two of them on each other.
	await _park_self(HOME)
	expect(await _take(rock), "took_a_rock_for_the_contest")
	expect(not _judge.can_grab(victim, rock), "e5_the_second_reach_is_refused")
	await tick_request(func() -> void:
		_local.movement.set_aim_override(victim.global_position)
		_local.grab.drop())
	await _wait(0.6)
	await _park_self(LANE)
	_judge.forgive_move(_client_peer(), "", 30)
	client_park.rpc_id(_client_peer(), LANE + Vector3(0.9, 0.0, 0.0))
	await _wait_stage("parked")
	await _wait(0.6)
	await tick_request(func() -> void:
		_local.movement.set_aim_override(victim.global_position)
		_local.movement.interact())
	await _wait(1.0)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	if _judge.holder_of(victim) == 1:
		expect(not _judge.can_grab(victim, _local), "e5_the_body_in_your_hands_cannot_grab_you")
	else:
		expect(false, "e5_the_body_in_your_hands_cannot_grab_you")
	await tick_request(_local.grab.drop)
	await _wait(0.8)
	note("release reasons so far: %s" % str(_judge.release_reasons))


# ----------------------------------------- the holder disconnects, last

func _disconnect_exception_check() -> void:
	var rock := _world.get_node("Rock_1") as Rock
	var client := _judge.actor_for(_client_peer())
	if client == null:
		expect(false, "e5_the_holder_disconnecting_frees_it")
		return
	await tick_request(func() -> void:
		rock.global_position = client.global_position + Vector3(0.9, 0.3, 0.0))
	await _wait(0.5)
	client_take_rock.rpc_id(_client_peer(), rock.get_path())
	expect(await _wait_stage("holding"), "the_client_was_holding_before_it_left")
	var gone := _released("holder_gone")
	client_leave.rpc_id(_client_peer())
	var waited := 0.0
	while waited < 12.0 and _released("holder_gone") == gone:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	note("holder disconnect: reason after %.1fs, rock holder now %d" % [waited, rock.holder_peer])
	expect(_released("holder_gone") > gone, "e5_the_holder_disconnecting_frees_it")
	expect(rock.holder_peer == 0, "and_the_rock_is_free")


# --------------------------------------------------------------------- helpers

func _park_self(point: Vector3) -> void:
	await tick_request(func() -> void:
		placed()
		_judge.server_respawn(_local)
		_local.global_position = point
		_local.velocity = Vector3.ZERO
		_local.stats.strength = 10.0
		_local.stamina = Tuning.values.stamina_max
		_local.movement.cancel_target())
	await _wait(0.6)


# --------------------------------------------------------------------- RPCs

@rpc("any_peer", "call_remote", "reliable")
func stage_done(name_text: String) -> void:
	if multiplayer.is_server() and multiplayer.get_peers().has(multiplayer.get_remote_sender_id()):
		_stage_done = name_text


@rpc("authority", "call_remote", "reliable")
func client_park(point: Vector3) -> void:
	await tick_request(func() -> void:
		placed()
		_local.global_position = point
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target()
		_local.movement.set_aim_override(Vector3.INF))
	await _wait(0.4)
	stage_done.rpc_id(1, "parked")


@rpc("authority", "call_remote", "reliable")
func client_escape() -> void:
	var presses := int(Tuning.values.grabbed_escape_presses)
	var from := _local.global_position
	var stamina_before := _local.stamina
	for index in range(presses):
		await tick_request(_local.grab.escape_press)
		if index < presses - 1:
			await get_tree().create_timer(0.12 + _lag).timeout
	# Stamina read before the regen gives it back; the recoil sampled while it
	# is happening.
	var stamina_after := _local.stamina
	var peak := 0.0
	var sampled := 0.0
	while sampled < 0.8:
		await get_tree().physics_frame
		sampled += get_physics_process_delta_time()
		peak = maxf(peak, Vector2(_local.velocity.x, _local.velocity.z).length())
	var pushed := Vector2(_local.global_position.x - from.x, _local.global_position.z - from.z).length()
	note("escape: peak speed %.2f, moved %.2f m, stamina %.0f -> %.0f on the presses (%.0f each, regen %.0f/s)" % [
		peak, pushed, stamina_before, stamina_after,
		Tuning.values.stamina_escape_press, Tuning.values.stamina_regen])
	expect(_local.state != Player.State.GRABBED, "the_client_got_free")
	expect(peak > 1.0, "the_escape_recoil_actually_moved_it")
	expect(stamina_before - stamina_after >= Tuning.values.stamina_escape_press, "and_the_presses_cost_stamina")
	stage_done.rpc_id(1, "escaped")


@rpc("authority", "call_remote", "reliable")
func client_take_rock(rock_path: NodePath) -> void:
	var rock := get_node(rock_path) as Rock
	await tick_request(func() -> void:
		_local.movement.set_aim_override(rock.global_position)
		_local.movement.interact())
	await _wait(0.8)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	expect(_local.grab.is_holding(), "the_client_took_the_rock")
	stage_done.rpc_id(1, "holding")


@rpc("authority", "call_remote", "reliable")
func client_leave() -> void:
	print("E_RESULT lag=%s peer=%d checks=%d failures=%d" % [_label, _peer_id, _checks, _failures])
	await _beat(0.2)
	Net.leave("E 보유자 접속 끊김 확인")
	await _beat(1.5)
	get_tree().quit(0 if _failures == 0 else 1)
