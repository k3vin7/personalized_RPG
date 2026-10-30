extends Node

# Stage M: the slots, the cast flow, and (M-2 on) the strikes that go through
# them. Two peers; the host conducts, the client casts once so the server's
# door is seen taking a cast from the other machine.
#
# Run at a latency with tools/udp_delay_proxy.py and --m-latency=<ms>.

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
var _reports := {}
# A value worked out inside a lambda comes back on a field.
var _asked := false


func expect(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("M_CHECK lag=%s peer=%d %s %s" % [_label, _peer_id, "PASS" if condition else "FAIL", label])


func note(line: String) -> void:
	print("M_NOTE lag=%s peer=%d %s" % [_label, _peer_id, line])


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


func _client_peer() -> int:
	var peers := multiplayer.get_peers()
	return peers[0] if peers.size() > 0 else 0


func _park(at: Vector3) -> void:
	await tick_request(func() -> void:
		placed()
		_local.global_position = at
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target()
		_local.movement.cancel_armed()
		_local.movement.set_aim_override(Vector3.INF))
	await _wait(0.4)


func _ids(from: int, to: int) -> Array:
	var out := []
	for index in range(from, to):
		var def := _local.skills.slot_def(index)
		out.append(def.id if def != null else "")
	return out


func run(world: Node3D) -> void:
	_world = world
	_peer_id = multiplayer.get_unique_id()
	_local = Net.spawn_root.get_node(str(_peer_id)) as Player
	_judge = world.get_node_or_null("ServerAuthority") as ServerAuthority
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--m-latency="):
			_label = argument.trim_prefix("--m-latency=")
			_lag = _label.to_float() / 1000.0
	if not multiplayer.is_server():
		stage_done.rpc_id(1, "client_ready")
		return
	expect(await _wait_stage("client_ready"), "both_peers_present")
	var warnings := _judge.move_warnings
	var corrections := _judge.move_corrections
	var smart: bool = Tuning.values.smart_key_enabled
	await _fill_checks()
	await _key_checks()
	await _windup_checks()
	await _recovery_checks()
	await _cooldown_checks()
	await _smart_key_checks()
	await _client_cast_check()
	await _strike_checks()
	await _knockdown_sequence_check()
	await _race_checks()
	await _weapon_checks()
	Tuning.values.smart_key_enabled = smart
	expect(_judge.move_warnings == warnings, "no_move_warnings_during_stage_m")
	expect(_judge.move_corrections == corrections, "no_corrections_during_stage_m")
	print("M_RESULT lag=%s peer=%d checks=%d failures=%d" % [_label, _peer_id, _checks, _failures])
	finish.rpc(_failures)
	await _wait(1.0)
	get_tree().quit(0 if _failures == 0 else 1)


# ------------------------------------------------------- M-1: what fills a slot

func _fill_checks() -> void:
	await _park(HOME)
	note("no weapon: slots %s" % [_ids(0, 8)])
	expect(_ids(0, 4) == Skills.BARE_IDS and _ids(4, 8) == ["", "", "", ""],
		"bare_hands_fill_the_first_four_and_the_rest_stand_empty")
	await tick_request(func() -> void: _local.set_weapon(WeaponKinds.Kind.SWORD))
	note("sword: slots %s" % [_ids(0, 8)])
	expect(_ids(0, 4) == ["", "", "", ""] and _ids(4, 8) == Skills.BARE_IDS,
		"a_one_hand_weapon_leaves_its_four_empty_and_moves_the_bare_four_to_the_off_hand")
	await tick_request(func() -> void: _local.set_weapon(WeaponKinds.Kind.SHIELD))
	note("shield: slots %s" % [_ids(0, 8)])
	expect(_ids(0, 4) == Skills.BARE_IDS and _ids(4, 8) == ["", "", "", ""],
		"a_shield_alone_keeps_the_bare_four_in_the_main_hand")
	await tick_request(func() -> void: _local.set_weapon(WeaponKinds.Kind.NONE))
	# Hands full: every slot shuts but the kick.
	var rock := _world.get_node("Rock_0") as Rock
	await tick_request(func() -> void:
		placed()
		rock.freeze = false
		rock.global_position = _local.global_position + Vector3(0.9, -0.3, 0.0)
		rock.linear_velocity = Vector3.ZERO)
	await _wait(0.3)
	await tick_request(func() -> void:
		_local.movement.set_aim_override(rock.global_position)
		_local.movement.interact())
	await _wait(0.5)
	expect(_local.grab.is_holding(), "the_rock_is_in_hand_for_the_lock_check")
	var locked := []
	for index in 4:
		locked.append(_local.skills.slot_locked(index))
	note("holding a rock: locked %s" % [locked])
	expect(locked == [true, true, true, false], "holding_locks_every_slot_but_the_kick")
	await tick_request(func() -> void:
		_local.movement.set_aim_override(Vector3.INF)
		_local.grab.drop())
	await _wait(0.5)
	expect(not _local.skills.slot_locked(0), "putting_it_down_opens_them_again")


# ------------------------------------------------------------- M-1: the keys

func _key_checks() -> void:
	await _park(HOME)
	Tuning.values.smart_key_enabled = true
	var was := _local.skills.key_for(2)
	note("slot 3 key: %s (%d)" % [_local.skills.key_label(2), was])
	expect(was == KEY_E, "slot_3_defaults_to_e")
	_local.skills.rebind(2, KEY_T)
	expect(_local.skills.key_for(2) == KEY_T and Tuning.values.slot_keys[2] == KEY_T,
		"a_rebind_is_stored_in_the_local_tuning")
	expect(InputMap.action_get_events("slot_3").size() == 1
		and (InputMap.action_get_events("slot_3")[0] as InputEventKey).physical_keycode == KEY_T,
		"and_written_into_the_input_map")
	var started := _local.skills.casts_started
	_local.movement.set_aim_override(HOME + Vector3(3.0, 0.0, 0.0))
	var press := InputEventKey.new()
	press.physical_keycode = KEY_T
	press.pressed = true
	Input.parse_input_event(press)
	await _wait(0.3)
	expect(_local.skills.casts_started == started + 1, "the_rebound_key_casts_the_slot")
	await _wait(0.6)
	var old_press := InputEventKey.new()
	old_press.physical_keycode = KEY_E
	old_press.pressed = true
	Input.parse_input_event(old_press)
	await _wait(0.3)
	expect(_local.skills.casts_started == started + 1, "the_old_key_no_longer_does")
	_local.skills.rebind(2, was)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	await _wait(0.3)


# ----------------------------------------------------- M-1: the windup locks

func _windup_checks() -> void:
	await _park(HOME)
	Tuning.values.smart_key_enabled = true
	var sent := _local.skills.casts_sent
	var punch := Skills.get_def("punch")
	note("punch: windup %.2f recovery %.2f cooldown %.2f" % [
		punch.value("windup"), punch.value("recovery"), punch.value("cooldown")])
	await tick_request(func() -> void:
		_local.movement.set_aim_override(HOME + Vector3(3.0, 0.0, 0.0))
		_local.skills.press_slot(2))
	expect(_local.state == Player.State.CASTING, "the_press_put_the_body_in_casting")
	expect(_local.skills.casts_sent == sent, "nothing_went_out_before_the_windup_ran")
	var stood := _local.global_position
	await tick_request(func() -> void:
		_local.movement.set_target(HOME + Vector3(3.0, 0.0, 0.0))
		_local.movement.press_jump()
		_local.movement.press_dash())
	await _wait(0.5)
	var moved := Vector2(_local.global_position.x - stood.x, _local.global_position.z - stood.z).length()
	note("during the windup: moved %.3f m, state now %s, casts sent %d -> %d" % [
		moved, Player.State.keys()[_local.state], sent, _local.skills.casts_sent])
	expect(moved < 0.1, "a_move_order_in_the_windup_moved_nothing")
	expect(_local.state != Player.State.AIRBORNE and _local.state != Player.State.DASH,
		"nor_did_a_jump_or_a_dash")
	expect(_local.skills.casts_sent == sent + 1, "the_cast_went_out_when_the_windup_ended")
	expect(_local.state == Player.State.IDLE, "and_the_recovery_ended_in_idle")
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))


# ------------------------------------------------- M-1: no recast in recovery

func _recovery_checks() -> void:
	await _park(HOME)
	Tuning.values.smart_key_enabled = true
	var started := _local.skills.casts_started
	var ignored := _local.skills.presses_ignored
	var rejected := _judge.rejected_intents
	await tick_request(func() -> void:
		_local.movement.set_aim_override(HOME + Vector3(3.0, 0.0, 0.0))
		_local.skills.press_slot(2))
	# Host-local timing: the punch's own clock, not the wire's.
	await get_tree().create_timer(0.12).timeout
	expect(_local.state == Player.State.RECOVERING, "the_body_is_recovering_after_the_strike")
	await tick_request(func() -> void: _local.skills.press_slot(2))
	expect(_local.skills.casts_started == started + 1 and _local.skills.presses_ignored == ignored + 1,
		"a_recast_inside_the_recovery_is_ignored")
	# Forged past the slot: the server keeps its own clock.
	await tick_request(func() -> void:
		ServerAuthority.submit_intent(_local, ServerAuthority.Intent.SKILL, {
			"skill": "punch", "direction": Vector3(1.0, 0.0, 0.0)}))
	expect(_judge.rejected_intents == rejected + 1, "the_server_refuses_a_cast_inside_the_recovery")
	await _wait(0.5)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))


# ------------------------------------------------------- M-1: the cooldown

func _cooldown_checks() -> void:
	await _park(HOME)
	Tuning.values.smart_key_enabled = true
	var kick := Skills.get_def("kick")
	var busy := kick.value("windup") + kick.value("recovery")
	var cooldown := kick.value("cooldown")
	note("kick: windup %.2f recovery %.2f cooldown %.2f" % [kick.value("windup"), kick.value("recovery"), cooldown])
	var started := _local.skills.casts_started
	var rejected := _judge.rejected_intents
	await tick_request(func() -> void:
		_local.movement.set_aim_override(HOME + Vector3(3.0, 0.0, 0.0))
		_local.skills.press_slot(3))
	await _wait(busy + 0.05)
	expect(_local.state == Player.State.IDLE, "the_kick_finished")
	await tick_request(func() -> void: _local.skills.press_slot(3))
	expect(_local.skills.casts_started == started + 1, "a_kick_inside_its_cooldown_is_ignored")
	await tick_request(func() -> void:
		ServerAuthority.submit_intent(_local, ServerAuthority.Intent.SKILL, {
			"skill": "kick", "direction": Vector3(1.0, 0.0, 0.0)}))
	expect(_judge.rejected_intents == rejected + 1, "and_refused_by_the_server_when_forged")
	# The cooldown runs from the strike (the end of the windup), not the press.
	await _wait(maxf(cooldown - kick.value("recovery") - 0.05, 0.0) + 0.15)
	await tick_request(func() -> void: _local.skills.press_slot(3))
	expect(_local.skills.casts_started == started + 2, "and_cast_once_the_cooldown_ran")
	await _wait(busy + 0.2)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))


# --------------------------------------------------- M-1: the smart key, both ways

func _smart_key_checks() -> void:
	await _park(HOME)
	Tuning.values.smart_key_enabled = false
	var started := _local.skills.casts_started
	await tick_request(func() -> void:
		_local.movement.set_aim_override(HOME + Vector3(3.0, 0.0, 0.0))
		_local.skills.press_slot(2))
	await _wait(0.2)
	expect(_local.movement.armed_action() == PlayerMovement.Armed.SKILL and _local.skills.armed_slot() == 2,
		"with_the_smart_key_off_the_press_arms_the_slot")
	expect(_local.movement.aim_indicator().is_showing(), "and_shows_the_reach")
	expect(_local.skills.casts_started == started, "nothing_was_cast_by_the_key_alone")
	await tick_request(func() -> void: _local.movement.cast_armed())
	expect(_local.skills.casts_started == started + 1, "the_left_button_cast_it")
	expect(_local.movement.armed_action() == PlayerMovement.Armed.NONE, "casting_disarmed_it")
	await _wait(0.5)
	await tick_request(func() -> void: _local.skills.press_slot(2))
	await tick_request(func() -> void: _local.movement.cancel_armed())
	expect(_local.movement.armed_action() == PlayerMovement.Armed.NONE and _local.skills.casts_started == started + 1,
		"cancelling_an_armed_slot_casts_nothing")
	expect(not _local.movement.aim_indicator().is_showing(), "and_takes_the_reach_away")
	Tuning.values.smart_key_enabled = true
	await tick_request(func() -> void: _local.skills.press_slot(2))
	expect(_local.skills.casts_started == started + 2 and _local.state == Player.State.CASTING,
		"with_the_smart_key_on_the_press_casts_at_once")
	await _wait(0.5)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))


# ------------------------------------------------ M-1: the other machine's cast

func _client_cast_check() -> void:
	var ruled := _judge.skills_ruled
	client_park.rpc_id(_client_peer(), CLIENT_HOME)
	await _wait(0.6)
	client_cast.rpc_id(_client_peer(), 2)
	var waited := 0.0
	while _judge.skills_ruled == ruled and waited < 5.0 + _lag * 10.0:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	note("client cast: server rulings %d -> %d after %.1f s" % [ruled, _judge.skills_ruled, waited])
	expect(_judge.skills_ruled == ruled + 1, "a_clients_cast_is_ruled_by_the_server")


# ------------------------------------------------ M-2: the punch and the kick

# The client body beside the host, a metre east, facing the host's strike.
func _place_target(mate: Player) -> void:
	await _park(HOME)
	client_park.rpc_id(_client_peer(), HOME + Vector3(1.0, 0.0, 0.0))
	await _wait(0.8)
	_local.movement.set_aim_override(mate.global_position)


func _strike_checks() -> void:
	var mate := _judge.actor_for(_client_peer())
	if mate == null:
		return
	Tuning.values.smart_key_enabled = true
	var punch := Skills.get_def("punch")
	var kick := Skills.get_def("kick")
	await tick_request(func() -> void: _judge.server_respawn(mate))
	await _place_target(mate)

	# The punch: lands, costs punch_damage, and the puncher recovers.
	var hp_before := mate.hp
	await tick_request(func() -> void: _local.skills.press_slot(2))
	await get_tree().create_timer(punch.value("windup") + 0.05).timeout
	var recovering := _local.state == Player.State.RECOVERING
	await _wait(punch.value("recovery") + 0.3)
	note("punch: hits=%s hp %.0f -> %.0f (damage %.1f), puncher recovering right after=%s, now %s" % [
		_judge.last_strike.get("hits", -1), hp_before, mate.hp, punch.value("damage"), recovering,
		Player.State.keys()[_local.state]])
	expect(int(_judge.last_strike.get("hits", 0)) == 1, "the_punch_landed")
	expect(absf((hp_before - mate.hp) - punch.value("damage")) < 0.01, "and_cost_punch_damage")
	expect(recovering and _local.state == Player.State.IDLE, "the_puncher_recovered_and_stood_again")
	expect(mate.state != Player.State.DOWNED, "a_punch_does_not_knock_down")

	# The kick: the body goes down, lies for down_time, stands up through
	# getup_time, and is itself again.
	await _wait(kick.value("cooldown"))
	hp_before = mate.hp
	await tick_request(func() -> void: _local.skills.press_slot(3))
	var waited := 0.0
	while mate.state != Player.State.DOWNED and waited < 2.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	var went_down := mate.state == Player.State.DOWNED
	var down_for := 0.0
	while mate.state == Player.State.DOWNED and down_for < 4.0:
		await get_tree().physics_frame
		down_for += get_physics_process_delta_time()
	var expected := Tuning.server.down_time + Tuning.server.getup_time
	note("kick: hits=%s downed=%s hp %.0f -> %.0f (damage %.1f), went down after %.2f s, lay %.2f s (down %.1f + getup %.1f = %.1f), then %s" % [
		_judge.last_strike.get("hits", -1), _judge.last_strike.get("downed", -1), hp_before, mate.hp,
		kick.value("damage"), waited, down_for, Tuning.server.down_time, Tuning.server.getup_time, expected,
		Player.State.keys()[mate.state]])
	expect(went_down, "the_kick_knocked_the_client_down")
	expect(absf((hp_before - mate.hp) - kick.value("damage")) < 0.01, "and_cost_kick_damage_more_than_the_punch")
	expect(absf(down_for - expected) < 0.35, "the_knockdown_lasted_down_time_plus_getup_time")
	expect(mate.state == Player.State.IDLE, "and_ended_standing")

	# A second kick while down resets the clock: the whole lie is longer.
	await _wait(kick.value("cooldown"))
	await _place_target(mate)
	await tick_request(func() -> void: _local.skills.press_slot(3))
	waited = 0.0
	while mate.state != Player.State.DOWNED and waited < 2.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	# The second kick is cast the moment the cooldown allows -- the cooldown
	# runs from the first strike, so this lands about 1.05 s into a 1.3 s lie.
	# Unpadded by the latency label on purpose: later than this and the body
	# has already stood up.
	await get_tree().create_timer(kick.value("cooldown") - 0.2).timeout
	# The first kick slid the body half a metre out of reach: step up to it.
	await tick_request(func() -> void:
		placed()
		_local.global_position = mate.global_position + Vector3(-1.0, 0.0, 0.0)
		_local.velocity = Vector3.ZERO
		_local.movement.set_aim_override(mate.global_position))
	await get_tree().create_timer(0.22).timeout
	await tick_request(func() -> void: _local.skills.press_slot(3))
	var span := waited + kick.value("cooldown") + 0.02
	while mate.state == Player.State.DOWNED and span < 6.0:
		await get_tree().physics_frame
		span += get_physics_process_delta_time()
	note("kick twice: downs applied on the client reported later; the lie spanned %.2f s from the first kick (one lie is %.1f)" % [
		span, expected])
	expect(span > expected + 0.5, "a_second_kick_resets_the_knockdown")

	# In the air the kick is a push and nothing more.
	await _wait(kick.value("cooldown"))
	await _place_target(mate)
	# Lifted rather than jumped: a jump is past the kick's reach by the time
	# the windup has run; a body set 1.2 m up is still falling through it.
	client_lift.rpc_id(_client_peer(), 1.2)
	await tick_request(func() -> void: _local.skills.press_slot(3))
	await _wait(kick.value("windup") + 0.1)
	var strike: Dictionary = _judge.last_strike.duplicate()
	var downed_in_air := false
	waited = 0.0
	while waited < 2.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		if mate.state == Player.State.DOWNED:
			downed_in_air = true
	note("kick at a body in the air: hits=%s downed=%s, ever down afterwards=%s" % [
		strike.get("hits", -1), strike.get("downed", -1), downed_in_air])
	expect(int(strike.get("hits", 0)) == 1, "the_kick_reached_the_body_in_the_air")
	expect(int(strike.get("downed", 1)) == 0 and not downed_in_air, "but_only_pushed_it")

	# Hands full: the punch is shut, the kick is open and casts.
	await _wait(kick.value("cooldown"))
	await _place_target(mate)
	var rock := _world.get_node("Rock_0") as Rock
	await tick_request(func() -> void:
		placed()
		rock.freeze = false
		rock.global_position = _local.global_position + Vector3(0.0, -0.3, -0.9)
		rock.linear_velocity = Vector3.ZERO)
	await _wait(0.3)
	await tick_request(func() -> void:
		_local.movement.set_aim_override(rock.global_position)
		_local.movement.interact())
	await _wait(0.5)
	expect(_local.grab.is_holding(), "the_rock_is_in_hand")
	var started := _local.skills.casts_started
	_local.movement.set_aim_override(mate.global_position)
	await tick_request(func() -> void: _local.skills.press_slot(2))
	expect(_local.skills.casts_started == started, "holding_the_punch_is_shut")
	await tick_request(func() -> void: _local.skills.press_slot(3))
	expect(_local.skills.casts_started == started + 1, "holding_the_kick_still_casts")
	await _wait(kick.value("windup") + kick.value("recovery") + 0.3)
	expect(_local.grab.is_holding(), "and_the_rock_stayed_in_hand_through_it")
	await tick_request(func() -> void:
		_local.movement.set_aim_override(Vector3.INF)
		_local.grab.drop())
	await _wait(0.5)

	# A scarecrow takes the damage and nothing else; a rock is pushed.
	var dummy := _world.get_node("Dummy_0") as Dummy
	await tick_request(func() -> void:
		placed()
		_local.global_position = dummy.global_position + Vector3(-1.0, 0.0, 0.0)
		_local.velocity = Vector3.ZERO
		_local.movement.set_aim_override(dummy.global_position))
	await _wait(0.5)
	await _wait(kick.value("cooldown"))
	var dummy_hp := dummy.hp
	await tick_request(func() -> void: _local.skills.press_slot(3))
	await _wait(kick.value("windup") + 0.3)
	note("kick at the scarecrow: hp %.0f -> %.0f" % [dummy_hp, dummy.hp])
	expect(dummy.hp < dummy_hp, "the_scarecrow_takes_the_kicks_damage")
	await _wait(kick.value("recovery") + kick.value("cooldown"))
	await tick_request(func() -> void:
		placed()
		_local.global_position = HOME + Vector3(-6.0, 0.0, 0.0)
		_local.velocity = Vector3.ZERO
		rock.freeze = false
		rock.global_position = HOME + Vector3(-6.0, -0.5, -1.0)
		rock.linear_velocity = Vector3.ZERO
		rock.angular_velocity = Vector3.ZERO
		_local.movement.set_aim_override(rock.global_position))
	await _wait(0.6)
	var rock_from := rock.global_position
	await tick_request(func() -> void: _local.skills.press_slot(3))
	await _wait(kick.value("windup") + 1.0)
	note("kick at a rock: moved %.2f m" % rock.global_position.distance_to(rock_from))
	expect(rock.global_position.distance_to(rock_from) > 0.3, "a_kicked_rock_is_pushed")
	await tick_request(func() -> void:
		_local.movement.set_aim_override(Vector3.INF)
		rock.global_position = rock.home
		rock.linear_velocity = Vector3.ZERO)
	await _wait(kick.value("recovery") + 0.3)


# The pass criterion: A kicks B down, A punches B while down, B gets up. Both
# screens see the same order of states and have B in the same place.
func _knockdown_sequence_check() -> void:
	var mate := _judge.actor_for(_client_peer())
	if mate == null:
		return
	Tuning.values.smart_key_enabled = true
	var kick := Skills.get_def("kick")
	await _wait(kick.value("cooldown"))
	await tick_request(func() -> void: _judge.server_respawn(mate))
	await _place_target(mate)
	_reports.erase("states")
	client_trace_states.rpc_id(_client_peer(), 3.0)
	var seen: Array = []
	var tracing := 0.0
	var kicked := false
	var punched := false
	while tracing < 3.0:
		await get_tree().physics_frame
		tracing += get_physics_process_delta_time()
		if not kicked and tracing >= 0.2:
			kicked = true
			Net.queue_physics(func() -> void: _local.skills.press_slot(3))
		if not punched and tracing >= 0.2 + kick.value("windup") + kick.value("recovery") + 0.15:
			punched = true
			Net.queue_physics(func() -> void:
				_local.movement.set_aim_override(mate.global_position)
				_local.skills.press_slot(2))
		var state_name: String = Player.State.keys()[mate.state]
		if seen.is_empty() or seen[seen.size() - 1] != state_name:
			seen.append(state_name)
	var here := mate.global_position
	if await _wait_report("states"):
		var there: Dictionary = _reports["states"]
		var theirs: Array = there.get("states", [])
		var pos: Vector3 = there.get("position", Vector3.INF)
		note("knockdown sequence: host saw %s, client saw %s | client at (%.2f, %.2f, %.2f), host sees (%.2f, %.2f, %.2f), gap %.3f" % [
			seen, theirs, pos.x, pos.y, pos.z, here.x, here.y, here.z, here.distance_to(pos)])
		expect(seen == theirs, "both_screens_saw_the_same_order_of_states")
		expect(seen.has("DOWNED") and seen[seen.size() - 1] == "IDLE", "down_then_up")
		expect(here.distance_to(pos) < 0.5, "and_have_the_body_in_the_same_place")
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))


# ------------------------------------------ M-3: the race stand and the weapon rack

func _race_checks() -> void:
	var pedestals := _world.get_node("RacePedestal") as RacePedestal
	var mate := _judge.actor_for(_client_peer())
	for kind: int in Races.all_kinds():
		var data := Races.data_for(kind)
		var spot := pedestals.zone_position(kind)
		await tick_request(func() -> void:
			placed()
			_local.global_position = spot + Vector3(0.0, 0.9, 0.0)
			_local.velocity = Vector3.ZERO
			_local.movement.cancel_target())
		await _wait(0.4)
		_asked = false
		await tick_request(func() -> void: _asked = pedestals.interact(_local))
		await _wait(0.3)
		note("stand %s: asked=%s -> race %s, strength %.0f (data %.0f), weight %.0f (data %.0f), max_hp %.0f, max_stamina %.0f, hp %.0f" % [
			data.label, _asked, Races.label_for(_local.stats.race), _local.stats.strength, data.strength,
			_local.stats.race_weight, data.body_weight, _local.stats.max_hp, _local.stats.max_stamina, _local.hp])
		expect(_local.stats.race == kind, "standing_on_the_%s_stand_and_pressing_g_takes_the_race" % String(Races.Kind.keys()[kind]).to_lower())
		expect(absf(_local.stats.strength - data.strength) < 0.01 and absf(_local.stats.race_weight - data.body_weight) < 0.01,
			"%s_strength_and_weight_are_the_race_data" % String(Races.Kind.keys()[kind]).to_lower())
		expect(absf(_local.stats.max_hp - data.endurance * Tuning.server.hp_per_endurance) < 0.01
			and _local.hp <= _local.stats.max_hp + 0.01, "%s_hp_follows_and_is_clamped" % String(Races.Kind.keys()[kind]).to_lower())
	# Back to human for everything after. Told to the move check: the orc
	# stand to the human stand is 6.6 m in a step.
	await tick_request(func() -> void:
		placed()
		_local.global_position = pedestals.zone_position(Races.Kind.HUMAN) + Vector3(0.0, 0.9, 0.0))
	await _wait(0.4)
	await tick_request(func() -> void: pedestals.interact(_local))
	await _wait(0.3)
	expect(_local.stats.race == Races.Kind.HUMAN, "back_on_the_human_stand")

	# Full hands are refused, and so is a client naming a race the stand does
	# not have. Away from the stands first: a rock put down on one is in it.
	await _park(HOME)
	var rock := _world.get_node("Rock_0") as Rock
	await tick_request(func() -> void:
		placed()
		rock.freeze = false
		rock.global_position = _local.global_position + Vector3(0.9, -0.3, 0.0)
		rock.linear_velocity = Vector3.ZERO)
	await _wait(0.3)
	await tick_request(func() -> void:
		_local.movement.set_aim_override(rock.global_position)
		_local.movement.interact())
	await _wait(0.5)
	expect(_local.grab.is_holding(), "the_rock_is_in_hand_for_the_race_refusal")
	var rejected := _judge.rejected_intents
	await tick_request(func() -> void:
		_local.movement.set_aim_override(Vector3.INF)
		ServerAuthority.submit_intent(_local, ServerAuthority.Intent.RACE, {"race": Races.Kind.ORC}))
	expect(_judge.rejected_intents == rejected + 1 and _local.stats.race == Races.Kind.HUMAN,
		"a_race_asked_with_full_hands_is_refused")
	await tick_request(func() -> void: _local.grab.drop())
	await _wait(0.5)
	await tick_request(func() -> void:
		ServerAuthority.submit_intent(_local, ServerAuthority.Intent.RACE, {"race": 9}))
	expect(_judge.rejected_intents == rejected + 2, "an_unknown_race_is_refused")
	# The client's own write never reaches the server (H-1's rule, re-read).
	if mate != null:
		var before := mate.stats.race
		_reports.erase("race")
		client_forge_race.rpc_id(_client_peer(), Races.Kind.DWARF)
		if await _wait_report("race"):
			note("client wrote dwarf on its own stats: it now reads %s, server holds %s" % [
				Races.label_for(int(_reports["race"])), Races.label_for(mate.stats.race)])
			expect(mate.stats.race == before, "a_clients_own_race_write_never_reached_the_server")
			expect(int(_reports["race"]) == before, "and_was_taken_off_the_client_again")


func _weapon_checks() -> void:
	var rack := _world.get_node("WeaponRack") as WeaponRack
	var mate := _judge.actor_for(_client_peer())
	# The host at the sword stand: the request is ruled at once.
	await tick_request(func() -> void:
		placed()
		_local.global_position = rack.global_position + Vector3(-2.0 * WeaponRack.SPACING, 0.9, 0.0)
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target())
	await _wait(0.4)
	await tick_request(func() -> void: rack.interact(_local))
	await _wait(0.2)
	note("sword stand: host weapon %s, server rules %s" % [
		WeaponKinds.LABELS.get(_local.weapon, "?"), WeaponKinds.LABELS.get(_judge.weapon_of(1), "?")])
	expect(_local.weapon == WeaponKinds.Kind.SWORD and _judge.weapon_of(1) == WeaponKinds.Kind.SWORD,
		"the_rack_asks_and_the_server_rules_the_weapon")
	expect(_ids(4, 8) == Skills.BARE_IDS, "and_the_slots_followed_the_ruling")
	await tick_request(func() -> void: _local.set_weapon(WeaponKinds.Kind.NONE))
	await _wait(0.2)
	expect(_local.weapon == WeaponKinds.Kind.NONE and _judge.weapon_of(1) == WeaponKinds.Kind.NONE, "and_dropped_it_again")
	if mate == null:
		return
	# The client asks through the door: the server's table and the client's
	# hand agree. Then the client draws a spear on its own: the server's table
	# does not move, and the disagreement is counted.
	var mismatches := _judge.weapon_mismatches
	_reports.erase("weapon")
	client_weapon.rpc_id(_client_peer(), WeaponKinds.Kind.BOW, false)
	if await _wait_report("weapon"):
		note("client asked for a bow: client holds %s, server rules %s" % [
			WeaponKinds.LABELS.get(int(_reports["weapon"]), "?"), WeaponKinds.LABELS.get(_judge.weapon_of(_client_peer()), "?")])
		expect(int(_reports["weapon"]) == WeaponKinds.Kind.BOW and _judge.weapon_of(_client_peer()) == WeaponKinds.Kind.BOW,
			"a_clients_request_is_ruled_and_applied")
	_reports.erase("weapon")
	client_weapon.rpc_id(_client_peer(), WeaponKinds.Kind.SPEAR, true)
	if await _wait_report("weapon"):
		await _wait(0.5)
		note("client drew a spear on its own: client shows %s, server rules %s, mismatches %d -> %d" % [
			WeaponKinds.LABELS.get(int(_reports["weapon"]), "?"), WeaponKinds.LABELS.get(_judge.weapon_of(_client_peer()), "?"),
			mismatches, _judge.weapon_mismatches])
		expect(_judge.weapon_of(_client_peer()) == WeaponKinds.Kind.BOW, "a_clients_own_weapon_write_never_reached_the_server")
		expect(_judge.weapon_mismatches > mismatches, "and_the_server_counts_the_disagreement")
	_reports.erase("weapon")
	client_weapon.rpc_id(_client_peer(), WeaponKinds.Kind.NONE, false)
	await _wait_report("weapon")


func _wait_report(key: String, seconds := 10.0) -> bool:
	var waited := 0.0
	while not _reports.has(key) and waited < seconds + _lag * 20.0:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	expect(_reports.has(key), "the_client_reported_%s" % key)
	return _reports.has(key)


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


@rpc("authority", "call_remote", "reliable")
func client_lift(height: float) -> void:
	await tick_request(func() -> void:
		placed()
		_local.global_position += Vector3.UP * height
		_local.velocity = Vector3.ZERO
		_local.floor_snap_length = 0.0
		_local.change_state(Player.State.AIRBORNE))


@rpc("authority", "call_remote", "reliable")
func client_jump() -> void:
	await tick_request(func() -> void:
		_local.movement.set_aim_override(_local.global_position)
		_local.movement.cast_jump())
	await _wait(0.3)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))


# Server -> client: our own state, each time it changes, for `seconds`, and
# where we ended up.
@rpc("authority", "call_remote", "reliable")
func client_trace_states(seconds: float) -> void:
	var seen: Array = []
	var t := 0.0
	while t < seconds:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
		var state_name: String = Player.State.keys()[_local.state]
		if seen.is_empty() or seen[seen.size() - 1] != state_name:
			seen.append(state_name)
	report.rpc_id(1, "states", {"states": seen, "position": _local.global_position})


# Server -> client: write a race straight onto our own stats, the way a cheat
# would, wait a beat, and report what the stats say now.
@rpc("authority", "call_remote", "reliable")
func client_forge_race(kind: int) -> void:
	_local.stats.race = kind
	await _wait(0.5)
	report.rpc_id(1, "race", _local.stats.race)


# Server -> client: take a weapon through the door, or draw it on our own
# synchronizer (forge), then report what we hold.
@rpc("authority", "call_remote", "reliable")
func client_weapon(kind: int, forge: bool) -> void:
	await tick_request(func() -> void:
		if forge:
			_local._apply_weapon(kind)
		else:
			_local.set_weapon(kind))
	await _wait(0.8)
	report.rpc_id(1, "weapon", _local.weapon)


@rpc("authority", "call_remote", "reliable")
func client_cast(slot: int) -> void:
	var was: bool = Tuning.values.smart_key_enabled
	Tuning.values.smart_key_enabled = true
	await tick_request(func() -> void:
		_local.movement.set_aim_override(_local.global_position + Vector3(3.0, 0.0, 0.0))
		_local.skills.press_slot(slot))
	await _wait(1.0)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	Tuning.values.smart_key_enabled = was


@rpc("authority", "call_remote", "reliable")
func finish(host_failures: int) -> void:
	print("M_RESULT lag=%s peer=%d checks=%d failures=%d host_failures=%d" % [
		_label, _peer_id, _checks, _failures, host_failures])
	get_tree().quit(0 if _failures == 0 else 1)
