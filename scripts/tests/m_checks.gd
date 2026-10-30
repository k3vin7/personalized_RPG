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
	await _wait(0.15)
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
