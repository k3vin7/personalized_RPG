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
var _reported := {}
var _label := "0"
var _flag := false
var _number := 0.0


# A clear 14 m of plaza to measure a walk along: z 14 misses the climb ring
# (z up to 12.3), the step ladder (z 15 and up) and the high platform (x 11 and
# up), and the props all stand at z 2 and z 6.
const WALK_LANE := Vector3(-8.0, 0.9, 14.0)


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
	await _dummy_carry_walk_check()
	await _rock_versus_player_check()
	await _second_push_check()
	await _escape_checks()
	await _exception_checks()
	await _tolerance_hold_checks()
	await _client_carry_jump_check()
	await _stats_authority_checks()
	await _race_table()
	expect(_judge.move_warnings == warnings, "no_move_warnings_during_stage_e")
	await _disconnect_exception_check()
	print("E_RESULT lag=%s peer=%d checks=%d failures=%d" % [_label, _peer_id, _checks, _failures])
	await _wait(1.0)
	get_tree().quit(0 if _failures == 0 else 1)


# ------------------------------------------------- the lift limit, and one hand

func _lift_limit_checks() -> void:
	# H-1: the limit is strength x 1.2, so a human (60) is good for 72 kg. The
	# old pair of checks straddled 20 kg at the 2.0 multiplier and said nothing
	# at all on the new scale -- every race clears a 20 kg rock without
	# noticing. These straddle each race's own limit instead, using the heavy
	# rocks the playground grew for exactly this.
	var rocks := {
		40.0: _world.get_node("Rock_3") as Rock,
		80.0: _world.get_node("Rock_4") as Rock,
		120.0: _world.get_node("Rock_5") as Rock,
	}
	await _park_self(HOME)
	var rows := PackedStringArray()
	for kind: int in Races.all_kinds():
		var data := Races.data_for(kind)
		await tick_request(func() -> void: _judge.harness_set_race(_local, kind))
		await _wait(0.3)
		await tick_request(func() -> void: _number = _judge.lift_limit(_local))
		var limit := _number
		var expected: float = data.strength * Tuning.values.lift_per_strength
		expect(absf(limit - expected) < 0.01,
			"%s_lift_limit_is_strength_times_the_multiplier" % data.label)
		# And the limit is what actually decides a grab, rock by rock.
		var verdicts := PackedStringArray()
		for weight: float in [40.0, 80.0, 120.0]:
			var rock: Rock = rocks[weight]
			await tick_request(func() -> void:
				rock.freeze = false
				rock.global_position = _local.global_position + Vector3(0.9, -0.3, 0.0)
				rock.linear_velocity = Vector3.ZERO)
			await _wait(0.4)
			await tick_request(func() -> void: _flag = _judge.can_grab(_local, rock))
			verdicts.append("%.0f:%s" % [weight, "yes" if _flag else "no"])
			expect(_flag == (weight <= limit),
				"%s_%.0fkg_matches_the_limit" % [data.label, weight])
		rows.append("%s %.0f/%.0fkg -> %.0fkg [%s]" % [
			data.label, data.strength, data.body_weight, limit,
			" ".join(verdicts)])
	note("lift limit by race (x%.1f): %s" % [
		Tuning.values.lift_per_strength, " | ".join(rows)])

	# A human lifts a bare elf and not a bare human: v4's intended shape, and
	# the one that makes training something to want.
	await tick_request(func() -> void: _judge.harness_set_race(_local, Races.Kind.HUMAN))
	await _wait(0.3)
	var human_limit := _judge.lift_limit(_local)
	var elf := Races.data_for(Races.Kind.ELF).body_weight
	var human := Races.data_for(Races.Kind.HUMAN).body_weight
	note("a human (%.0fkg limit) against a bare elf %.0fkg and a bare human %.0fkg" % [
		human_limit, elf, human])
	expect(human_limit >= elf, "a_human_can_lift_a_bare_elf")
	expect(human_limit < human, "but_not_a_bare_human")

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
	expect(one_hand < elf, "and_then_a_bare_elf_is_too_much")
	Tuning.values.one_hand_weapon = false


# --------------------------------------------- the one key: tap, arc, line

# Measured: putting a rock beside a body sometimes knocks that body into the
# air -- a teleported rigid body resolves its new contacts, and the log says
# ROCK_HIT target=1 speed=4.99 followed by airborne=true. can_grab() wants a
# grounded holder, so the take then fails and every leg built on it fails with
# it (about one run in ten). So: drop the rock a little lower than the hands
# rather than above them, stop it dead in both axes, and if the body did get
# lifted, wait for the landing before reaching for it.
func _take(rock: Rock) -> bool:
	await tick_request(func() -> void:
		rock.freeze = false
		rock.global_position = _local.global_position + Vector3(0.9, -0.3, 0.0)
		rock.linear_velocity = Vector3.ZERO
		rock.angular_velocity = Vector3.ZERO)
	await _wait(0.4)
	var settling := 0.0
	while settling < 2.0 and not _local.is_grounded_state():
		await get_tree().physics_frame
		settling += get_physics_process_delta_time()
	if settling > 0.0:
		note("the rock's placement lifted the holder; waited %.2f s for the landing" % settling)
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
	# H-1: 40 kg, not the old 20. A human is 80 kg bare, so a 20 kg rock moves
	# the ratio from 0.75 to 0.60 and the jump by 11 cm -- less than the check's
	# own tolerance. 40 kg is the heaviest rock a human's 72 kg limit allows,
	# which makes it the heaviest honest load to measure the penalty with.
	var heavy := _world.get_node("Rock_3") as Rock          # 40 kg
	await _park_self(HOME)
	var free_speed := _local.get_move_speed()
	var free_jump := _local.get_jump_height()
	# The apex of a standing jump with empty hands, measured. Since stage C-2
	# the in-place jump spends the whole leap budget upward, so get_jump_height()
	# is the vertical half of that budget and not the height reached -- which
	# makes it the wrong thing to compare a loaded jump against.
	var free_apex := await _standing_apex()
	expect(await _take(heavy), "took_the_heavy_rock")
	await _wait(0.3)
	var load := _local.stats.held_weight
	var carry_speed := _local.get_move_speed()
	var carry_jump := _local.get_jump_height()
	# 4-chapter: the load is in the weight, the weight is in the ratio, and the
	# ratio is in both of these. No rule of its own.
	var bare: float = _local.stats.race_weight + _local.stats.gear_weight
	var ratio_free: float = _local.stats.strength / maxf(bare, 0.1)
	var ratio_load: float = _local.stats.strength / maxf(bare + load, 0.1)
	note("carrying %.0f kg: speed %.2f -> %.2f, jump height %.2f -> %.2f (ratio %.2f -> %.2f)" % [
		load, free_speed, carry_speed, free_jump, carry_jump, ratio_free, ratio_load])
	expect(absf(load - heavy.weight) < 0.01, "what_is_carried_is_in_the_weight")
	expect(carry_speed < free_speed - 0.05, "carrying_something_heavy_slows_the_walk")
	expect(carry_jump < free_jump - 0.05, "and_lowers_the_jump")
	# Nothing is forbidden while carrying, and the hold survives the jump: the
	# load is in the jump's own weight, so the jump is already shorter for it.
	var floor_y := _local.global_position.y
	await tick_request(func() -> void:
		_local.movement.set_aim_override(_local.global_position)
		_local.movement.cast_jump())
	var jumped := false
	var held_all_the_way := true
	var peak := floor_y
	var sampled := 0.0
	while sampled < 1.6:
		await get_tree().physics_frame
		sampled += get_physics_process_delta_time()
		if _local.state == Player.State.AIRBORNE:
			jumped = true
			held_all_the_way = held_all_the_way and _local.grab.is_holding()
		peak = maxf(peak, _local.global_position.y)
	note("jump while carrying %.0f kg: left the ground=%s, apex %.2f m (empty-handed %.2f m), held all the way=%s, still holding=%s" % [
		load, jumped, peak - floor_y, free_apex, held_all_the_way, _local.grab.is_holding()])
	expect(jumped, "a_holder_may_still_jump")
	expect(held_all_the_way and _local.grab.is_holding(), "and_keeps_what_it_is_carrying")
	expect(peak - floor_y < free_apex - 0.3, "the_jump_is_shorter_for_the_load")

	# A fall, though, does take it: 7-6 narrowed to what it was written for.
	var state_released := _released("holder_state")
	await tick_request(func() -> void:
		placed()
		_local.global_position += Vector3.UP * 2.5
		_local.velocity = Vector3.ZERO
		_local.floor_snap_length = 0.0
		_local.change_state(Player.State.AIRBORNE))
	await _wait(0.6)
	note("dropped off an edge while carrying: holder_state %d -> %d, still holding=%s" % [
		state_released, _released("holder_state"), _local.grab.is_holding()])
	expect(_released("holder_state") > state_released, "but_a_fall_still_takes_it")
	await _wait(1.2)
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


# ------------------------- carrying a scarecrow slows the walk, not speeds it up

# E follow-up, found in play: carrying a scarecrow made the walk shoot up
# instead of slowing down. The formula was never wrong -- get_move_speed() has
# the load in it -- so what has to be measured is the ground actually covered.
# The scarecrow was written into the holder's hand every step with no collision
# exception, the two capsules overlapped, and the solver pushed the holder out
# of its own hands.
func _dummy_carry_walk_check() -> void:
	# The other scarecrow: Dummy_1 has just been put down by the check above
	# and is walking itself home, so it is neither still nor where it was.
	var dummy := _world.get_node("Dummy_0") as Dummy

	# Empty handed first, down the measuring lane.
	var free_travel := await _walk_for(WALK_LANE, 0.6)
	var free_formula := _local.get_move_speed()

	# Then with the scarecrow in hand. Picked up where it stands and carried
	# to the lane, because the lane has to be clear of the props.
	await _park_self(dummy.global_position - Vector3(1.0, 0.0, 0.0))
	# Long enough for the hand to be free again after the drop above.
	await _wait(1.0)
	await tick_request(func() -> void:
		_local.movement.set_aim_override(dummy.global_position)
		_local.movement.interact())
	await _wait(0.8)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	expect(_local.grab.is_holding(), "scarecrow_in_hand_for_the_walk")
	var load := _local.stats.held_weight
	var carry_formula := _local.get_move_speed()
	var carry_travel := await _walk_for(WALK_LANE, 0.6, false)

	var measured_ratio := carry_travel / maxf(free_travel, 0.01)
	var formula_ratio := carry_formula / maxf(free_formula, 0.01)
	note("walk measured: empty %.2f m/s (formula %.2f) -> carrying %.0f kg %.2f m/s (formula %.2f) | measured x%.3f, formula x%.3f, still holding=%s" % [
		free_travel, free_formula, load, carry_travel, carry_formula,
		measured_ratio, formula_ratio, _local.grab.is_holding()])
	expect(carry_travel <= free_travel + 0.05, "carrying_a_scarecrow_does_not_speed_the_walk_up")
	expect(carry_travel < free_travel - 0.05, "it_slows_it_down")
	# By as much as the formula says and no more: the absolute speeds are not
	# compared, because a walk measured from a standstill never reaches the
	# formula's figure. What has to match is how much the load costs.
	expect(absf(measured_ratio - formula_ratio) < 0.12,
		"and_it_slows_by_what_the_load_costs_and_no_more")
	await tick_request(func() -> void:
		if _local.grab.is_holding():
			_local.grab.drop())
	await _wait(0.8)

	# And the same measurement on the client's own machine, which is where a
	# person actually plays. The host gets out of the lane first.
	await _park_self(HOME)
	_reported.erase("carry_walk")
	client_carry_walk.rpc_id(
		_client_peer(), _world.get_node("Dummy_1").get_path(), WALK_LANE)
	var waited := 0.0
	while not _reported.has("carry_walk") and waited < 30.0 + _lag * 20.0:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	expect(_reported.has("carry_walk"), "the_client_measured_its_own_carry_walk")
	if _reported.has("carry_walk"):
		var numbers: PackedFloat32Array = _reported["carry_walk"]
		var client_measured := numbers[2] / maxf(numbers[0], 0.01)
		var client_formula := numbers[3] / maxf(numbers[1], 0.01)
		note("client walk measured: empty %.2f m/s (formula %.2f) -> carrying %.0f kg %.2f m/s (formula %.2f) | measured x%.3f, formula x%.3f, still holding=%s" % [
			numbers[0], numbers[1], numbers[4], numbers[2], numbers[3],
			client_measured, client_formula, numbers[5] > 0.5])
		expect(numbers[5] > 0.5, "the_client_was_still_holding_it")
		expect(numbers[2] <= numbers[0] + 0.05,
			"carrying_does_not_speed_the_clients_walk_up_either")
		expect(absf(client_measured - client_formula) < 0.12,
			"and_costs_the_client_what_the_load_costs")


# A holder keeps what it carries through its own jump -- and the server is the
# one that decides, from sync_jumped. That flag is the owner's, so for a client
# the server only ever has the replicated copy, and it was missing from the
# replication config: player.tscn declared properties/7 before properties/3,
# which SceneReplicationConfig refuses, so sync_jumped was dropped and the
# server read a default false. Every client that jumped with something in its
# hands had it taken away; the host, reading its own flag, kept it. A rock is
# used rather than a scarecrow because a put-down scarecrow walks home, and the
# host places it, because the host owns it.
func _client_carry_jump_check() -> void:
	var rock := _world.get_node("Rock_1") as Rock
	var client := _judge.actor_for(_client_peer())
	if rock == null or client == null:
		expect(false, "the_client_carry_jump_check_found_its_pieces")
		return
	var stand := Vector3(-16.0, 0.9, 12.0)
	await _park_self(HOME)
	_judge.forgive_move(_client_peer(), "", 30)
	client_park.rpc_id(_client_peer(), stand)
	await _wait_stage("parked")
	await tick_request(func() -> void:
		rock.freeze = false
		rock.global_position = stand + Vector3(0.9, -0.3, 0.0)
		rock.linear_velocity = Vector3.ZERO)
	await _wait(0.8)
	_reported.erase("carry_jump")
	client_carry_jump.rpc_id(_client_peer(), rock.get_path())
	# Sampled on the server, every physics frame: the state and the jump flag
	# reach it as two values and the order they arrive in is the whole bug, so
	# the sequence the server actually saw is what gets reported.
	var waited := 0.0
	var seen := PackedStringArray()
	var kept_through_the_air := true
	while not _reported.has("carry_jump") and waited < 30.0 + _lag * 20.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		var holds_now := _judge.held_by(_client_peer()) != null
		if client.state == Player.State.AIRBORNE and not holds_now:
			kept_through_the_air = false
		var stamp := "%s/%s/%s" % [
			Player.State.keys()[client.state],
			"J" if client.sync_jumped else "-",
			"H" if holds_now else "-"]
		if seen.is_empty() or seen[seen.size() - 1] != stamp:
			seen.append(stamp)
	note("server's view, state/jumped/hold: %s" % " ".join(seen))
	expect(kept_through_the_air, "the_server_never_saw_the_client_airborne_without_its_load")
	expect(_reported.has("carry_jump"), "the_client_reported_its_carry_jump")
	if not _reported.has("carry_jump"):
		return
	var n: PackedFloat32Array = _reported["carry_jump"]
	# What the server itself read off the wire while the client was in the air.
	# The hold is not read here: the client lets go itself before it reports, so
	# the table is empty by now whatever happened during the jump. What the jump
	# did is in held_all_the_way and in the server's own sequence above.
	note("client jump while carrying %.0f kg: took the rock=%s, left the ground=%s, apex %.2f m, held all the way=%s, still holding at the end of the flight=%s | server saw sync_jumped=%s" % [
		n[3], n[6] > 0.5, n[0] > 0.5, n[1], n[2] > 0.5, n[4] > 0.5, n[5] > 0.5])
	expect(n[6] > 0.5, "the_client_took_the_rock")
	expect(n[0] > 0.5, "the_client_holder_may_still_jump")
	expect(n[5] > 0.5, "the_server_saw_the_clients_own_jump_flag")
	expect(n[2] > 0.5 and n[4] > 0.5,
		"and_the_client_keeps_what_it_carries_through_its_own_jump")


# Ground actually covered per second, walking at a point. With reset false the
# body is left as it is, so a hold is not thrown away before the measurement.
func _walk_for(home: Vector3, seconds: float, reset := true) -> float:
	if reset:
		await _park_self(home)
	else:
		await tick_request(func() -> void:
			placed()
			_local.global_position = home
			_local.velocity = Vector3.ZERO
			_local.movement.cancel_target())
		await _wait(0.6)
	var walk_to := home + Vector3(14.0, 0.0, 0.0)
	await tick_request(func() -> void: _local.movement.set_target(walk_to))
	# The first stretch is the body getting up to speed and the path being
	# prepared; the window after it has to end before the body arrives, or the
	# faster one is measured coming to a stop and reads slower than the slower
	# one. 0.6 s of run-up plus 0.6 s of window is 7.2 m at the empty walk
	# speed, well short of the 14 m target.
	await _beat(0.6)
	var from := _local.global_position
	var sampled := 0.0
	while sampled < seconds:
		await get_tree().physics_frame
		sampled += get_physics_process_delta_time()
	var travelled := Vector2(
		_local.global_position.x - from.x, _local.global_position.z - from.z).length()
	await tick_request(func() -> void: _local.movement.cancel_target())
	return travelled / maxf(sampled, 0.01)


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
	# H-2: and it went through v4's comparison on the way, like every other
	# force. A rock in flight carries no one's strength, so this is the one
	# force whose dv has no multiplier -- and it is still judged.
	var hit_knock: Dictionary = _judge.last_knock.get(_client_peer(), {})
	note("the rock hit's verdict: kind=%d h_speed %.2f vs tolerance %.2f -> %s" % [
		int(hit_knock.get("kind", -1)), float(hit_knock.get("h_speed", 0.0)),
		float(hit_knock.get("tolerance", 0.0)),
		"launched" if bool(hit_knock.get("launched", true)) else "slid"])
	expect(int(hit_knock.get("kind", -1)) == ForceSystem.Kind.KNOCKBACK,
		"a_rock_hit_goes_through_the_tolerance_comparison")
	expect(bool(hit_knock.get("judged", false)), "and_was_actually_compared")


# ----------------- 결정 2: a slide keeps its hands, a launch empties them (H-2)

# The two halves of v4's verdict, on the same body with the same push, with
# only the body's own strength changed. Nothing here drops the rock by hand:
# the launch becomes airborne and the hold table's existing rule takes it, which
# is what the work order asks to be checked rather than re-implemented.
func _tolerance_hold_checks() -> void:
	var rock := _world.get_node("Rock_0") as Rock
	# The slide carries the holder sideways with the rock in its hand, and the
	# legs before this one leave rocks lying about wherever they landed. At
	# 200 ms one of them was in the lane: the held rock struck it, and a held
	# thing that is hit is dropped -- the old rule, firing for the right reason
	# on the wrong rock. Put them all back on their spawn spots first, which
	# are 5 m clear of the lane this check uses.
	await tick_request(func() -> void:
		for index in 6:
			var other := _world.get_node_or_null("Rock_%d" % index) as Rock
			if other == null or other == rock:
				continue
			other.freeze = false
			other.global_position = other.home
			other.linear_velocity = Vector3.ZERO
			other.angular_velocity = Vector3.ZERO)
	await _wait(0.5)
	await _park_self(HOME)
	expect(await _take(rock), "took_a_rock_for_the_tolerance_checks")

	# Strong enough that the shove is inside its tolerance.
	_judge.harness_set_stats(_local, 150.0)
	await _wait(0.4)
	await _shove_self()
	await _wait(ServerAuthority.HOLD_LOST_GRACE + 0.6)
	var slid: Dictionary = (_judge.last_knock.get(_peer_id, {}) as Dictionary).duplicate()
	note("holding, inside the tolerance: h_speed %.2f vs %.2f -> %s, still holding=%s, state %s" % [
		float(slid.get("h_speed", 0.0)), float(slid.get("tolerance", 0.0)),
		"launched" if bool(slid.get("launched", true)) else "slid",
		_local.grab.is_holding(), Player.State.keys()[_local.state]])
	expect(not bool(slid.get("launched", true)), "the_push_on_the_holder_was_a_slide")
	expect(_local.grab.is_holding(), "a_holder_that_slid_keeps_what_it_holds")
	expect(_local.state != Player.State.STUNNED, "and_the_holder_is_not_stunned")

	# Weak enough that the same shove throws it -- but still strong enough to
	# lift a 5 kg rock, so what empties the hands is the launch and not the
	# lift limit.
	_judge.harness_set_stats(_local, 20.0)
	await _wait(0.4)
	await _shove_self()
	await _wait(ServerAuthority.HOLD_LOST_GRACE + 0.8)
	var hurled: Dictionary = (_judge.last_knock.get(_peer_id, {}) as Dictionary).duplicate()
	note("holding, over the tolerance: h_speed %.2f vs %.2f -> %s, still holding=%s" % [
		float(hurled.get("h_speed", 0.0)), float(hurled.get("tolerance", 0.0)),
		"launched" if bool(hurled.get("launched", true)) else "slid",
		_local.grab.is_holding()])
	expect(bool(hurled.get("launched", false)), "the_second_push_on_the_holder_was_a_launch")
	expect(not _local.grab.is_holding(), "a_holder_that_was_launched_drops_it")
	_judge.harness_clear_stats(_local)
	await _wait(1.0)


# One shove's worth of force at this body, from the server, through the one
# door. A human's strength behind it so the number is the one the 4x4 table
# shows for 인간 -> 인간.
func _shove_self() -> void:
	await tick_request(func() -> void:
		_judge.send_force(_local, ForceSystem.make_event(
			ForceSystem.Kind.SHOVE,
			(Vector3(1.0, 0.0, 0.0) + Vector3.UP * Tuning.values.shove_up_bias).normalized(),
			Tuning.values.shove_power, 60.0, 1, false,
			Tuning.values.shove_damage, Tuning.values.shove_stun_time)))


# ------------------------- a thrown team mate can be pushed again in the air

# H-1: the abilities became the server's, and this is the real path -- the one
# a person uses, not the harness door. A client's debug slider states a number,
# the server rules on it, and the Vitals synchronizer carries the answer back,
# so the server and both screens end up holding the same value. And the other
# direction: a client writing the number itself gets it taken away again.
func _stats_authority_checks() -> void:
	var mate := _judge.actor_for(_client_peer())
	if mate == null:
		expect(false, "the_stats_checks_found_the_client")
		return
	var asked := 111.0
	_reported.erase("stats")
	client_ask_stats.rpc_id(_client_peer(), asked)
	var waited := 0.0
	while not _reported.has("stats") and waited < 20.0 + _lag * 20.0:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	expect(_reported.has("stats"), "the_client_reported_what_its_slider_did")
	if not _reported.has("stats"):
		return
	var seen: PackedFloat32Array = _reported["stats"]
	note("slider path: client asked %.0f -> client sees %.0f, server sees %.0f (race %s)" % [
		asked, seen[0], mate.stats.strength, Races.label_for(mate.stats.race)])
	expect(absf(mate.stats.strength - asked) < 0.01, "the_server_took_the_sliders_number")
	expect(absf(seen[0] - asked) < 0.01, "and_the_client_sees_what_the_server_took")

	# Forged: the client writes the ability itself, both the stat and the
	# replicated field. The server's copy is the one that counts, and it comes
	# straight back over the top.
	_reported.erase("forged")
	client_forge_stats.rpc_id(_client_peer(), 999.0)
	waited = 0.0
	while not _reported.has("forged") and waited < 20.0 + _lag * 20.0:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	expect(_reported.has("forged"), "the_client_reported_its_forgery")
	if _reported.has("forged"):
		var forged: PackedFloat32Array = _reported["forged"]
		note("forged: client wrote 999 -> client ends at %.0f, server still %.0f" % [
			forged[0], mate.stats.strength])
		expect(absf(mate.stats.strength - asked) < 0.01,
			"a_clients_own_write_never_reached_the_server")
		expect(absf(forged[0] - asked) < 0.01,
			"and_was_taken_off_the_client_again")

	# Gear: the same door, a different field. No race value to fall back to, so
	# null means bare.
	_reported.erase("gear")
	client_ask_gear.rpc_id(_client_peer(), 50.0)
	waited = 0.0
	while not _reported.has("gear") and waited < 20.0 + _lag * 20.0:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	expect(_reported.has("gear"), "the_client_reported_what_the_gear_slider_did")
	if _reported.has("gear"):
		var gear: PackedFloat32Array = _reported["gear"]
		note("gear slider: asked 50 -> client sees %.0fkg (total %.0fkg), server sees %.0fkg (total %.0fkg), move %.3f -> %.3f m/s" % [
			gear[0], gear[1], mate.stats.gear_weight, mate.stats.total_weight(),
			gear[3], gear[2]])
		expect(absf(mate.stats.gear_weight - 50.0) < 0.01, "the_server_took_the_gear_weight")
		expect(absf(gear[0] - 50.0) < 0.01, "and_the_client_sees_it")
		expect(gear[2] < gear[3] - 0.01, "and_being_equipped_is_slower_than_bare")

	# The harness door is for --auto runs only. Flipped off and called, it has
	# to refuse -- that gate is what keeps it from being a way round the server
	# in a session a person started.
	var was_auto := Net.auto_smoke
	Net.auto_smoke = false
	var refused_stats := _judge.harness_set_stats(mate, 123.0)
	var refused_race := _judge.harness_set_race(mate, Races.Kind.ORC)
	Net.auto_smoke = was_auto
	note("harness door with auto off: set_stats=%s set_race=%s (strength still %.0f, race still %s)" % [
		refused_stats, refused_race, mate.stats.strength,
		Races.label_for(mate.stats.race)])
	expect(not refused_stats, "harness_set_stats_refuses_outside_an_auto_run")
	expect(not refused_race, "harness_set_race_refuses_outside_an_auto_run")
	expect(absf(mate.stats.strength - asked) < 0.01, "and_changed_nothing")
	expect(mate.stats.race == Races.DEFAULT, "and_left_the_race_alone")

	# And the client trying to do it itself, by every route it has. There is no
	# stats result RPC to forge -- the abilities ride the server's own
	# synchronizer -- so what a client can actually reach is the harness door
	# (which is not an RPC, and refuses off the judge) and its own fields.
	_reported.erase("direct")
	client_direct_stats.rpc_id(_client_peer())
	waited = 0.0
	while not _reported.has("direct") and waited < 20.0 + _lag * 20.0:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	expect(_reported.has("direct"), "the_client_reported_its_direct_attempts")
	if _reported.has("direct"):
		var direct: PackedFloat32Array = _reported["direct"]
		note("client's own attempts: harness door returned %s | after writing 777/777/77 it holds strength %.0f weight %.0f gear %.0f, server holds %.0f %.0f %.0f" % [
			direct[0] > 0.5, direct[1], direct[2], direct[3],
			mate.stats.strength, mate.stats.race_weight, mate.stats.gear_weight])
		expect(direct[0] < 0.5, "the_harness_door_refuses_a_client")
		expect(absf(mate.stats.strength - asked) < 0.01,
			"a_clients_own_strength_write_never_reached_the_server")
		expect(absf(mate.stats.gear_weight - 50.0) < 0.01,
			"nor_its_gear_write")
		expect(absf(direct[1] - asked) < 0.01 and absf(direct[3] - 50.0) < 0.01,
			"and_both_were_taken_off_the_client_again")

	# Back onto the race, the way choosing a race does it.
	_reported.erase("stats")
	client_ask_stats.rpc_id(_client_peer(), NAN)
	waited = 0.0
	while not _reported.has("stats") and waited < 20.0 + _lag * 20.0:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	var bare := Races.data_for(mate.stats.race).strength
	note("back to the race: server sees %.0f (%s is %.0f), gear %.0f, overridden=%s" % [
		mate.stats.strength, Races.label_for(mate.stats.race), bare,
		mate.stats.gear_weight, mate.stats.is_overridden()])
	expect(absf(mate.stats.strength - bare) < 0.01, "null_puts_the_body_back_on_its_race")
	expect(not mate.stats.is_overridden(), "and_clears_the_override")
	expect(absf(mate.stats.gear_weight) < 0.01, "and_takes_the_gear_off")


# H-1's after table: the same rows H-0 measured before the change, now per race.
# Formula values rather than flight times, because what H-1 changed is the
# formula -- C and D measure the flights, and they still do.
func _race_table() -> void:
	await _park_self(HOME)
	for kind: int in Races.all_kinds():
		var data := Races.data_for(kind)
		await tick_request(func() -> void: _judge.harness_set_race(_local, kind))
		await _wait(0.4)
		var cap := _local.leap_speed_cap()
		note("race %s: strength %.0f weight %.0fkg endurance %.0f agility %.0f intellect %.0f height %.0fcm | ratio %.4f mult_jump %.4f mult_speed %.4f | move %.3f m/s, standing apex %.3f m, leap range %.3f m, dash %.3f m/s, lift %.0fkg, hp_max %.0f" % [
			data.label, data.strength, data.body_weight, data.endurance,
			data.agility, data.intellect, data.height_cm,
			_local.get_ratio(),
			Tuning.ratio_mult(_local.get_ratio(), Tuning.values.ratio_k_jump),
			Tuning.ratio_mult(_local.get_ratio(), Tuning.values.ratio_k_speed),
			_local.get_move_speed(), cap * cap / (2.0 * Tuning.values.gravity),
			_local.leap_max_range(), _local.dash_speed(),
			_judge.lift_limit(_local), _local.stats.max_hp])
	# The one number v4 names outright: a bare human is the reference, so its
	# multiplier is exactly 1.
	await tick_request(func() -> void: _judge.harness_set_race(_local, Races.Kind.HUMAN))
	await _wait(0.4)
	var human_mult := Tuning.ratio_mult(_local.get_ratio(), Tuning.values.ratio_k_jump)
	note("bare human ratio %.4f -> mult %.4f (ratio_ref %.2f)" % [
		_local.get_ratio(), human_mult, Tuning.values.ratio_ref])
	expect(absf(human_mult - 1.0) < 0.0001, "a_bare_human_is_exactly_one")


# A leg that grabs a person often follows one that threw something at them, and
# a parked body is not a settled one: the park is a position write, so a body
# still carrying a push keeps moving after it lands. Rather than widen a fixed
# wait, this waits for the two of them to actually be in reach and says how far
# apart they ended up if they never are.
func _await_pair_within_reach(other: Player, point: Vector3) -> float:
	var reach: float = Tuning.values.grab_range + Player.BODY_RADIUS
	var gap := INF
	var waited := 0.0
	while waited < 8.0 + _lag * 20.0:
		var offset := other.global_position - _local.global_position
		offset.y = 0.0
		gap = offset.length()
		if gap <= reach:
			return gap
		# Put them both back and let them settle again.
		_judge.forgive_move(other.get_multiplayer_authority(), "", 30)
		client_park.rpc_id(other.get_multiplayer_authority(), point + Vector3(0.9, 0.0, 0.0))
		await _wait_stage("parked")
		await _park_self(point)
		waited += 2.0
	return gap


# v4's lift limit means a human (72 kg) cannot pick up a bare human (80 kg).
# That is the intended shape, not something to tune away -- but the legs below
# are about what happens once someone IS held, so the holder is handed the
# strength to get there. On the server, which is what owns an ability now.
func _strong_enough_for_people() -> void:
	await tick_request(func() -> void: _judge.harness_set_stats(_local, 150.0))
	await _wait(0.2)


func _second_push_check() -> void:
	var mate := _judge.actor_for(_client_peer())
	_judge.forgive_move(_client_peer(), "", 30)
	client_park.rpc_id(_client_peer(), LANE + Vector3(0.9, 0.0, 0.0))
	await _wait_stage("parked")
	await _wait(0.6)
	await _park_self(LANE)
	var gap := await _await_pair_within_reach(mate, LANE)
	await _strong_enough_for_people()
	await tick_request(func() -> void:
		_local.movement.set_aim_override(mate.global_position)
		_local.movement.interact())
	await _wait(1.0)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	if _judge.holder_of(mate) != 1:
		note("the team mate was not picked up: %.2f m apart (reach %.2f), limit %.0f kg against %.0f kg" % [
			gap, Tuning.values.grab_range + Player.BODY_RADIUS,
			_judge.lift_limit(_local), _judge.weight_of(mate)])
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
	await _strong_enough_for_people()
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
	# Leaving the ground is the one verdict that waits: a body seen airborne
	# without its jump flag is also what a client looks like for a sample after
	# it lands, so the server makes the verdict last HOLD_LOST_GRACE before
	# acting on it. The window is read from the constant rather than written
	# again here -- a bare 0.5 s was 0.25 s of margin and failed now and then.
	await _wait(ServerAuthority.HOLD_LOST_GRACE + 0.5)
	expect(_released("holder_state") > state_released, "e5_holder_off_the_ground_dropped_it")
	await _wait(1.2)

	# The held body is pushed by something else.
	await _park_self(LANE)
	_judge.forgive_move(_client_peer(), "", 30)
	client_park.rpc_id(_client_peer(), LANE + Vector3(0.9, 0.0, 0.0))
	await _wait_stage("parked")
	await _wait(0.6)
	await _strong_enough_for_people()
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
	await _strong_enough_for_people()
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

# A standing jump with nothing in hand, for the loaded one to be compared with.
func _standing_apex() -> float:
	var floor_y := _local.global_position.y
	var peak := floor_y
	await tick_request(func() -> void:
		_local.movement.set_aim_override(_local.global_position)
		_local.movement.cast_jump())
	var sampled := 0.0
	while sampled < 1.6:
		await get_tree().physics_frame
		sampled += get_physics_process_delta_time()
		peak = maxf(peak, _local.global_position.y)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	return peak - floor_y


func _park_self(point: Vector3) -> void:
	await tick_request(func() -> void:
		placed()
		_judge.server_respawn(_local)
		_local.global_position = point
		_local.velocity = Vector3.ZERO
		_judge.harness_clear_stats(_local)
		_local.stamina = _local.stats.max_stamina
		_local.movement.cancel_target())
	await _wait(0.6)


# --------------------------------------------------------------------- RPCs

@rpc("any_peer", "call_remote", "reliable")
func report_numbers(what: String, values: PackedFloat32Array) -> void:
	if multiplayer.is_server() and multiplayer.get_peers().has(multiplayer.get_remote_sender_id()):
		_reported[what] = values


# The client measures its own walk, because the overlap this is about happens
# on whichever machine owns the body doing the carrying -- and in play that is
# a client, not the host.
@rpc("authority", "call_remote", "reliable")
func client_carry_walk(dummy_path: NodePath, lane: Vector3) -> void:
	var dummy := get_node_or_null(dummy_path) as Dummy
	if dummy == null:
		report_numbers.rpc_id(1, "carry_walk", PackedFloat32Array([0.0, 0.0, 0.0, 0.0, 0.0]))
		return
	var free_travel := await _walk_for(lane, 0.6)
	var free_formula := _local.get_move_speed()
	await _park_self(dummy.global_position - Vector3(1.0, 0.0, 0.0))
	await _wait(1.0)
	await tick_request(func() -> void:
		_local.movement.set_aim_override(dummy.global_position)
		_local.movement.interact())
	await _wait(1.0)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	var load := _local.stats.held_weight
	var carry_formula := _local.get_move_speed()
	var carry_travel := await _walk_for(lane, 0.6, false)
	var holding := 1.0 if _local.grab.is_holding() else 0.0
	await tick_request(func() -> void:
		if _local.grab.is_holding():
			_local.grab.drop())
	report_numbers.rpc_id(1, "carry_walk", PackedFloat32Array([
		free_travel, free_formula, carry_travel, carry_formula, load, holding]))


@rpc("authority", "call_remote", "reliable")
func client_carry_jump(rock_path: NodePath) -> void:
	var rock := get_node_or_null(rock_path) as Node3D
	if rock == null:
		report_numbers.rpc_id(1, "carry_jump", PackedFloat32Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]))
		return
	await tick_request(func() -> void:
		_local.movement.set_aim_override(rock.global_position)
		_local.movement.interact())
	await _wait(1.0 + _lag * 2.0)
	var took := _local.grab.is_holding()
	var load := _local.stats.held_weight
	var floor_y := _local.global_position.y
	# Straight up: the cursor on our own feet is how a jump in place is asked
	# for, and it keeps the measurement about the hold rather than the landing.
	await tick_request(func() -> void:
		_local.movement.set_aim_override(_local.global_position)
		_local.movement.cast_jump())
	var jumped := false
	var held_all_the_way := true
	var flag_set := false
	var peak := floor_y
	var sampled := 0.0
	while sampled < 1.6:
		await get_tree().physics_frame
		sampled += get_physics_process_delta_time()
		if _local.state == Player.State.AIRBORNE:
			jumped = true
			held_all_the_way = held_all_the_way and _local.grab.is_holding()
			flag_set = flag_set or _local.sync_jumped
		peak = maxf(peak, _local.global_position.y)
	var holding := 1.0 if _local.grab.is_holding() else 0.0
	await tick_request(func() -> void:
		_local.movement.set_aim_override(Vector3.INF)
		if _local.grab.is_holding():
			_local.grab.drop())
	report_numbers.rpc_id(1, "carry_jump", PackedFloat32Array([
		1.0 if jumped else 0.0,
		peak - floor_y,
		1.0 if held_all_the_way else 0.0,
		load,
		holding,
		1.0 if flag_set else 0.0,
		1.0 if took else 0.0]))


@rpc("authority", "call_remote", "reliable")
func client_ask_stats(value: float) -> void:
	# Exactly what the debug slider does: state a number, let the server decide.
	# NAN is the panel's "follow the race again" button.
	await tick_request(func() -> void:
		ServerAuthority.submit_intent(_local, ServerAuthority.Intent.STATS, {
			"strength": null if is_nan(value) else value,
		} if not is_nan(value) else {
			"strength": null, "weight": null, "gear": null,
		}))
	# Long enough for the ruling to be made and replicated back.
	await _wait(0.8 + _lag * 4.0)
	report_numbers.rpc_id(1, "stats", PackedFloat32Array([_local.stats.strength]))


@rpc("authority", "call_remote", "reliable")
func client_forge_stats(value: float) -> void:
	# No result RPC exists to forge: the abilities ride the server's own
	# synchronizer. So the forgery is the blunt one -- write the stat and the
	# replicated field directly and see whether either sticks.
	await tick_request(func() -> void:
		_local.stats.strength_override = value
		_local.sync_strength_override = value)
	await _wait(0.8 + _lag * 4.0)
	report_numbers.rpc_id(1, "forged", PackedFloat32Array([_local.stats.strength]))


@rpc("authority", "call_remote", "reliable")
func client_ask_gear(value: float) -> void:
	var bare_speed := _local.get_move_speed()
	await tick_request(func() -> void:
		ServerAuthority.submit_intent(_local, ServerAuthority.Intent.STATS, {
			"gear": value,
		}))
	await _wait(0.8 + _lag * 4.0)
	report_numbers.rpc_id(1, "gear", PackedFloat32Array([
		_local.stats.gear_weight, _local.stats.total_weight(),
		_local.get_move_speed(), bare_speed]))


@rpc("authority", "call_remote", "reliable")
func client_direct_stats() -> void:
	# Every route a client has to an ability, tried in turn. The harness door
	# first: it is not an RPC, so this is the client calling it on its own
	# ServerAuthority, where is_judge() is false.
	var door := false
	var judge := ServerAuthority.instance
	if judge != null:
		door = judge.harness_set_stats(_local, 777.0, 777.0, 77.0)
	# Then the blunt one: write the stat and the replicated field directly.
	await tick_request(func() -> void:
		_local.stats.strength_override = 777.0
		_local.stats.weight_override = 777.0
		_local.stats.gear_weight = 77.0
		_local.sync_strength_override = 777.0
		_local.sync_weight_override = 777.0
		_local.sync_gear_weight = 77.0)
	await _wait(0.8 + _lag * 4.0)
	report_numbers.rpc_id(1, "direct", PackedFloat32Array([
		1.0 if door else 0.0,
		_local.stats.strength, _local.stats.race_weight, _local.stats.gear_weight]))


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
