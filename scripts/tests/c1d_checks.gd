extends Node

# C-1d: the dash combo (a combo skill pressed inside dash_combo_window of
# the owner's dash start is stronger, linearly; the server checks the claimed
# gap against the arrival gap of the dash notice and the intent), the bare
# four's stamina column, and the kick's knockdown (down_time + getup_time).
# Two peers; also run through the 200 ms proxy, where the claimed gap must
# still be the owner's interval.

const HOME := Vector3(0.0, 0.9, 11.0)

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
	print("C1D_CHECK peer=%d %s %s" % [_peer_id, "PASS" if condition else "FAIL", label])


func note(line: String) -> void:
	print("C1D_NOTE peer=%d %s" % [_peer_id, line])


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


func _mate() -> Player:
	return _judge.actor_for(_client_peer())


func _dummy() -> Dummy:
	return _world.get_node("Dummy_1") as Dummy


func _wait_dummy_home(dummy: Dummy) -> void:
	await Harness.dummy_home(dummy, _judge, _local, _mate(), get_tree(), note)


func _stand_at(dummy: Dummy, distance: float) -> void:
	await _wait_dummy_home(dummy)
	var spot := dummy.home + Vector3(0.0, 0.0, distance)
	await tick_request(func() -> void:
		placed()
		_local.global_position = Vector3(spot.x, 0.9, spot.z)
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target()
		_local.movement.cancel_armed()
		_local.movement.set_aim_override(dummy.home)
		_local.snap_facing(dummy.home - _local.global_position))
	await _wait(0.4)


func _take(kind: int) -> void:
	await tick_request(func() -> void: _local.set_weapon(kind))
	var waited := 0.0
	while waited < 2.0 and ((kind == WeaponKinds.Kind.SHIELD and _local.offhand != kind)
			or (kind != WeaponKinds.Kind.SHIELD and _local.weapon != kind)):
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	await _wait(0.2)


func _wait_idle(seconds := 3.0) -> void:
	var waited := 0.0
	while _local.state != Player.State.IDLE and waited < seconds:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()


# Dash at the scarecrow from `distance`, press `slot` `gap` seconds after
# the dash started, and wait for the ruling.
func _dash_then(slot: int, gap: float, distance := 3.0) -> Dictionary:
	var dummy := _dummy()
	await _stand_at(dummy, distance)
	var before := _judge.last_strike.duplicate()
	var granted := _judge.combos_granted
	var refused := _judge.combos_refused
	var claimed := _local.skills.combos_claimed
	await tick_request(func() -> void:
		_local.movement.set_aim_override(dummy.home)
		_local.movement.request_dash())
	# (A lambda's assignment does not reach a local here, so the dash is
	# read off the body's state.)
	var dashed := _local.movement.is_dashing()
	var waited := get_physics_process_delta_time() * 3.0
	while _local.movement.seconds_since_dash() < gap:
		await get_tree().physics_frame
	var state_at_press := _local.state
	var since := _local.movement.seconds_since_dash()
	await tick_request(func() -> void: _local.skills.press_slot(slot))
	waited = 0.0
	while _judge.last_strike == before and waited < 2.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	await _wait(0.3)
	await _wait_idle()
	return {
		"dashed": dashed,
		"state_at_press": Player.State.keys()[state_at_press],
		"since": since,
		"claimed_sent": _local.skills.combos_claimed - claimed,
		"granted": _judge.combos_granted - granted,
		"refused": _judge.combos_refused - refused,
		"combo": _judge.last_combo.duplicate(),
		"strike": _judge.last_strike.duplicate(),
		"hit": _judge.last_hit.duplicate(),
	}


func _combo_formula(gap: float) -> float:
	return 1.0 + (Tuning.server.dash_combo_mult_max - 1.0) * (1.0 - gap / Tuning.server.dash_combo_window)


func run(world: Node3D) -> void:
	_world = world
	_peer_id = multiplayer.get_unique_id()
	_local = Net.spawn_root.get_node(str(_peer_id)) as Player
	_judge = world.get_node_or_null("ServerAuthority") as ServerAuthority
	if not multiplayer.is_server():
		stage_done.rpc_id(1, "client_ready")
		return
	expect(await _wait_stage("client_ready"), "both_peers_present")
	var warnings := _judge.move_warnings
	var corrections := _judge.move_corrections
	var smart: bool = Tuning.values.smart_key_enabled
	Tuning.values.smart_key_enabled = true
	await _table_checks()
	await _combo_checks()
	await _cheat_checks()
	await _stamina_checks()
	await _kick_checks()
	await _two_peer_checks()
	await _facing_checks()
	Tuning.values.smart_key_enabled = smart
	expect(_judge.move_warnings == warnings, "no_move_warnings_during_c1d")
	expect(_judge.move_corrections == corrections, "no_corrections_during_c1d")
	print("C1D_RESULT peer=%d checks=%d failures=%d" % [_peer_id, _checks, _failures])
	finish.rpc(_failures)
	await _wait(1.0)
	get_tree().quit(0 if _failures == 0 else 1)


# ------------------------------------------------- 1: the table

func _table_checks() -> void:
	note("dash combo: window %.2f, max x%.2f, jitter allow %.2f | down %.1f getup %.1f | bare stamina shove %.0f grab %.0f/s punch %.0f kick %.0f" % [
		Tuning.server.dash_combo_window, Tuning.server.dash_combo_mult_max, Tuning.server.combo_jitter_allow,
		Tuning.server.down_time, Tuning.server.getup_time,
		Skills.get_def("shove").value("stamina_cost"), Skills.get_def("grab").value("stamina_cost"),
		Skills.get_def("punch").value("stamina_cost"), Skills.get_def("kick").value("stamina_cost")])
	expect(absf(Tuning.server.dash_combo_window - 0.15) < 0.001 and absf(Tuning.server.dash_combo_mult_max - 1.3) < 0.001
		and absf(Tuning.server.combo_jitter_allow - 0.05) < 0.001, "the_combo_window_is_0_15_x1_3_at_once_and_0_05_jitter")
	var combo_ids := []
	for id in Skills.all_ids():
		if Skills.get_def(id).dash_combo:
			combo_ids.append(id)
	combo_ids.sort()
	note("combo skills: %s" % [combo_ids])
	expect(combo_ids == ["punch", "shield_bash", "thrust"], "the_combo_is_the_punchs_the_thrusts_and_the_shield_bashs")
	expect(absf(Tuning.server.down_time - 1.0) < 0.001 and absf(Tuning.server.getup_time - 0.3) < 0.001, "the_kick_lies_1_0_and_stands_up_in_0_3")
	expect(absf(Skills.get_def("shove").value("stamina_cost") - 6.0) < 0.001 and absf(Skills.get_def("grab").value("stamina_cost") - 2.0) < 0.001
		and absf(Skills.get_def("punch").value("stamina_cost") - 3.0) < 0.001 and absf(Skills.get_def("kick").value("stamina_cost") - 7.0) < 0.001,
		"the_bare_fours_stamina_column_is_6_2_3_7")


# ------------------------------------------------- 2: the combo on, off, and per skill

func _combo_checks() -> void:
	await _take(WeaponKinds.Kind.NONE)
	var punch := Skills.get_def("punch")
	# 0.10 s after the dash: on, x(1 + 0.3 x (1 - 0.1/0.15)) = 1.1.
	var on := await _dash_then(2, 0.10)
	var want_on := _combo_formula(float(on["combo"].get("claimed", 0.0)))
	note("punch 0.10 s into the dash: %s" % [on])
	# The dash itself is over in about 0.1 s here (a short dash at the
	# scarecrow), so the press may land in DASH or just after it; the combo
	# is the gap, not the state.
	expect(bool(on["dashed"]) and int(on["claimed_sent"]) == 1 and int(on["granted"]) == 1,
		"a_punch_0_10_s_into_the_dash_is_a_combo")
	expect(absf(float(on["combo"].get("mult", 0.0)) - want_on) < 0.001 and absf(float(on["strike"].get("mult", 0.0)) - want_on) < 0.001
		and absf(want_on - 1.1) < 0.03, "at_the_linear_multiplier_about_1_1")
	expect(int(on["strike"].get("hits", 0)) == 1 and absf(float(on["hit"].get("dealt", 0.0)) - punch.value("damage") * want_on) < 0.01,
		"and_the_punch_lands_that_much_harder")
	# 0.20 s: off (the window is 0.15).
	var off := await _dash_then(2, 0.20)
	note("punch 0.20 s into the dash: %s" % [off])
	expect(int(off["claimed_sent"]) == 0 and int(off["granted"]) == 0 and absf(float(off["strike"].get("mult", 0.0)) - 1.0) < 0.001,
		"a_punch_0_20_s_into_the_dash_is_no_combo")
	# The thrust: combo x speed bonus (the dash's speed at the intent).
	await _take(WeaponKinds.Kind.SWORD)
	var thrust := await _dash_then(0, 0.05, 3.5)
	var combo := float(thrust["combo"].get("mult", 0.0))
	var total := float(thrust["strike"].get("mult", 0.0))
	note("thrust 0.05 s into the dash: combo %.3f, total mult %.3f (speed part %.3f), dealt %.2f" % [
		combo, total, total / maxf(combo, 0.001), float(thrust["hit"].get("dealt", 0.0))])
	expect(int(thrust["granted"]) == 1 and absf(combo - _combo_formula(float(thrust["combo"].get("claimed", 0.0)))) < 0.001
		and total / maxf(combo, 0.001) > 1.05, "a_thrust_from_the_dash_multiplies_the_combo_by_the_speed_bonus")
	# The shield bash.
	await _take(WeaponKinds.Kind.SHIELD)
	var bash := await _dash_then(5, 0.10, 2.5)
	var want_bash := _combo_formula(float(bash["combo"].get("claimed", 0.0)))
	note("shield bash 0.10 s into the dash: %s" % [bash])
	expect(int(bash["granted"]) == 1 and absf(float(bash["strike"].get("mult", 0.0)) - want_bash) < 0.001
		and int(bash["strike"].get("hits", 0)) == 1
		and absf(float(bash["hit"].get("dealt", 0.0)) - Skills.get_def("shield_bash").value("damage") * Weapons.attack_power_for("shield") * want_bash) < 0.01,
		"a_shield_bash_from_the_dash_is_a_combo_too")
	# The kick is not a combo skill: nothing claimed, nothing granted.
	await _take(WeaponKinds.Kind.NONE)
	var kick := await _dash_then(3, 0.10)
	note("kick 0.10 s into the dash: claimed %d granted %d state %s" % [int(kick["claimed_sent"]), int(kick["granted"]), kick["state_at_press"]])
	expect(int(kick["claimed_sent"]) == 0 and int(kick["granted"]) == 0, "the_kick_is_not_a_combo_skill")
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))


# ------------------------------------------------- 3: the cheat check

func _cheat_checks() -> void:
	var dummy := _dummy()
	await _stand_at(dummy, 1.2)
	# A combo claimed with no dash behind it.
	var refused := _judge.combos_refused
	await tick_request(func() -> void:
		ServerAuthority.submit_intent(_local, ServerAuthority.Intent.SKILL, {
			"skill": "punch", "direction": _local.movement.shove_direction(), "dash_gap": 0.05}))
	await _wait(0.5)
	note("punch claiming a 0.05 s gap with no dash: %s" % [_judge.last_combo])
	expect(_judge.combos_refused == refused + 1 and String(_judge.last_combo.get("why", "")) == "no_dash"
		and absf(float(_judge.last_strike.get("mult", 0.0)) - 1.0) < 0.001, "a_combo_claimed_with_no_dash_is_refused")
	await _wait_idle()
	# A gap claimed shorter than the wire saw: dash, wait 0.12 s, claim 0.02.
	await _stand_at(dummy, 3.0)
	refused = _judge.combos_refused
	await tick_request(func() -> void:
		_local.movement.set_aim_override(dummy.home)
		_local.movement.request_dash())
	while _local.movement.seconds_since_dash() < 0.12:
		await get_tree().physics_frame
	await tick_request(func() -> void:
		ServerAuthority.submit_intent(_local, ServerAuthority.Intent.SKILL, {
			"skill": "punch", "direction": _local.movement.shove_direction(), "dash_gap": 0.02}))
	await _wait(0.5)
	note("punch claiming 0.02 s when the notice and the intent arrived %.3f s apart: %s" % [
		float(_judge.last_combo.get("arrival", 0.0)), _judge.last_combo])
	expect(_judge.combos_refused == refused + 1 and String(_judge.last_combo.get("why", "")) == "gap_shorter_than_the_wire",
		"a_gap_shorter_than_the_arrival_gap_minus_the_allowance_is_refused")
	await _wait_idle()
	# And a claim inside the allowance passes: dash, wait 0.08, claim 0.05.
	await _stand_at(dummy, 3.0)
	var granted := _judge.combos_granted
	await tick_request(func() -> void:
		_local.movement.set_aim_override(dummy.home)
		_local.movement.request_dash())
	while _local.movement.seconds_since_dash() < 0.08:
		await get_tree().physics_frame
	await tick_request(func() -> void:
		ServerAuthority.submit_intent(_local, ServerAuthority.Intent.SKILL, {
			"skill": "punch", "direction": _local.movement.shove_direction(), "dash_gap": 0.05}))
	await _wait(0.5)
	note("punch claiming 0.05 s at an arrival gap of %.3f: %s" % [float(_judge.last_combo.get("arrival", 0.0)), _judge.last_combo])
	expect(_judge.combos_granted == granted + 1, "a_claim_inside_the_allowance_is_granted")
	await _wait_idle()
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))


# ------------------------------------------------- 4: the bare four's stamina

func _stamina_checks() -> void:
	var dummy := _dummy()
	var rows := [["shove", 0], ["punch", 2], ["kick", 3]]
	var all_ok := true
	for row: Array in rows:
		var def := Skills.get_def(row[0])
		await _stand_at(dummy, 1.2)
		var spent := _judge.stamina_spent_by(_peer_id)
		await tick_request(func() -> void: _local.skills.press_slot(int(row[1])))
		await _wait(0.3)
		var took := _judge.stamina_spent_by(_peer_id) - spent
		note("%s: the server took %.2f (column %.0f)" % [row[0], took, def.value("stamina_cost")])
		all_ok = all_ok and absf(took - def.value("stamina_cost")) < 0.001
		await _wait_idle()
		await _wait(def.value("cooldown") + 0.2)
	expect(all_ok, "the_shove_the_punch_and_the_kick_cost_their_columns_on_the_server")
	# The grab: per second while lifting.
	var rock := _world.get_node("Rock_0") as Rock
	await tick_request(func() -> void:
		placed()
		_local.global_position = HOME
		_local.velocity = Vector3.ZERO
		rock.freeze = false
		rock.global_position = HOME + Vector3(0.0, -0.3, -0.9)
		rock.linear_velocity = Vector3.ZERO
		_local.movement.set_aim_override(rock.global_position))
	await _wait(0.5)
	await tick_request(func() -> void: _local.movement.interact())
	await _wait(0.3)
	var held := _local.grab.is_holding()
	var spent := _judge.stamina_spent_by(_peer_id)
	await _wait(1.0)
	var drain := _judge.stamina_spent_by(_peer_id) - spent
	note("holding the rock for 1.0 s: held %s, the server took %.2f (column %.0f/s)" % [held, drain, Skills.get_def("grab").value("stamina_cost")])
	expect(held and absf(drain - Skills.get_def("grab").value("stamina_cost")) < 0.3, "lifting_costs_the_grabs_column_per_second")
	await tick_request(func() -> void: _local.grab.drop())
	await _wait(0.5)
	await tick_request(func() -> void:
		_local.movement.set_aim_override(Vector3.INF)
		rock.global_position = Vector3(4.0, Rock.radius_for(rock.weight) + 0.05, 6.0)
		rock.linear_velocity = Vector3.ZERO)


# ------------------------------------------------- 5: the kick's knockdown

func _kick_checks() -> void:
	var mate := _mate()
	var kick := Skills.get_def("kick")
	await tick_request(func() -> void:
		placed()
		_local.global_position = HOME
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target())
	client_park.rpc_id(_client_peer(), HOME + Vector3(0.0, 0.0, -1.2))
	await _wait(0.9)
	await tick_request(func() -> void:
		_local.movement.set_aim_override(mate.global_position)
		_local.skills.press_slot(3))
	var waited := 0.0
	while mate.state != Player.State.DOWNED and waited < 2.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	var went_down := mate.state == Player.State.DOWNED
	var lay := 0.0
	while mate.state == Player.State.DOWNED and lay < 4.0:
		await get_tree().physics_frame
		lay += get_physics_process_delta_time()
	var expected: float = Tuning.server.down_time + Tuning.server.getup_time
	note("kick on the client: went down %s after %.2f s, lay %.2f s (down %.1f + getup %.1f = %.1f), then %s" % [
		went_down, waited, lay, Tuning.server.down_time, Tuning.server.getup_time, expected, Player.State.keys()[mate.state]])
	expect(went_down and absf(lay - expected) < 0.35, "the_kick_fells_for_down_time_plus_getup_time")
	await _wait_idle()
	await _wait(kick.value("cooldown"))
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))


# ------------------------------------------------- 6: the other peer, through the wire

func _two_peer_checks() -> void:
	var mate := _mate()
	var punch := Skills.get_def("punch")
	await tick_request(func() -> void:
		placed()
		_judge.server_set_hp(_local, _local.stats.max_hp)
		_local.global_position = HOME
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target())
	client_park.rpc_id(_client_peer(), HOME + Vector3(0.0, 0.0, -3.0))
	await _wait(1.0)
	var hp_before := _local.hp
	var granted := _judge.combos_granted
	var refused := _judge.combos_refused
	_reports.erase("combo")
	client_dash_combo.rpc_id(_client_peer(), HOME, 2, 0.10)
	var waited := 0.0
	while _judge.combos_granted == granted and _judge.combos_refused == refused and waited < 4.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	await _wait(0.8)
	var combo := _judge.last_combo.duplicate()
	var client_side: Dictionary = _reports.get("combo", {}) if await _wait_report("combo") else {}
	var want := _combo_formula(float(combo.get("claimed", 0.0)))
	note("the client's dash punch at the host: combo %s | client says %s | host hp %.1f -> %.1f | hit %s" % [
		combo, client_side, hp_before, _local.hp, _judge.last_hit])
	expect(_judge.combos_granted == granted + 1 and String(combo.get("why", "x")) == "", "the_clients_combo_is_granted_on_the_servers_arrival_check")
	expect(absf(float(combo.get("claimed", -1.0)) - float(client_side.get("claimed", -2.0))) < 0.02
		and absf(float(combo.get("mult", 0.0)) - want) < 0.001,
		"on_the_gap_the_client_sent_not_the_arrival_gap")
	expect(String(_judge.last_hit.get("skill", "")) == "punch" and String(_judge.last_hit.get("target", "")) == _local.name
		and absf((hp_before - _local.hp) - punch.value("damage") * want) < 0.02, "and_the_punch_lands_harder_on_the_host")
	note("arrival gap the server saw: %.3f s (claimed %.3f)" % [float(combo.get("arrival", 0.0)), float(combo.get("claimed", 0.0))])
	await _wait(0.5)


# ------------------------------------------------- 7: the dash faces its way

# The yaw a body shows when it faces `direction` (snap_facing's formula).
static func _yaw_of(direction: Vector3) -> float:
	return atan2(-direction.x, -direction.z)


# Stand at `at` facing east, dash north, and read the yaw on the first dash
# frame and at the end of the dash.
func _dash_facing(at: Vector3) -> Dictionary:
	var aim := at + Vector3(0.0, 0.0, -4.0)
	await tick_request(func() -> void:
		placed()
		_local.global_position = at
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target()
		_local.movement.cancel_armed()
		_local.movement.set_aim_override(Vector3.INF)
		_local.snap_facing(Vector3(1.0, 0.0, 0.0)))
	await _wait(Tuning.server.dash_cooldown + 0.3)
	var seen := {"before": _local.rotation.y, "first": 100.0, "last": 100.0, "dashed": false}
	Net.queue_physics(func() -> void:
		_local.movement.set_aim_override(aim)
		seen["dashed"] = _local.movement.request_dash()
		seen["first"] = _local.rotation.y)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var waited := 0.0
	while _local.movement.is_dashing() and waited < 1.5:
		seen["last"] = _local.rotation.y
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	await _wait(0.3)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	seen["want"] = _yaw_of(aim - at)
	seen["after"] = _local.rotation.y
	return seen


func _facing_checks() -> void:
	var want := _yaw_of(Vector3(0.0, 0.0, -4.0))
	var host := await _dash_facing(HOME + Vector3(-4.0, 0.0, 0.0))
	note("host dash north from facing east: %s" % [host])
	expect(bool(host["dashed"]) and absf(angle_difference(float(host["before"]), want)) > 1.0,
		"the_host_stood_facing_away_from_the_dash_before_it")
	expect(absf(angle_difference(float(host["first"]), want)) < 0.05,
		"the_host_faces_the_dash_direction_on_the_dash_frame")
	expect(absf(angle_difference(float(host["last"]), want)) < 0.05 and absf(angle_difference(float(host["after"]), want)) < 0.05,
		"and_still_faces_it_when_the_dash_ends")
	# The client: its own screen, then this screen's replica of it.
	var mate := _mate()
	var spot := HOME + Vector3(4.0, 0.0, 0.0)
	_reports.erase("facing")
	client_dash_facing.rpc_id(_client_peer(), spot)
	var client_side: Dictionary = _reports.get("facing", {}) if await _wait_report("facing", 12.0) else {}
	await _wait(0.5)
	var replica := mate.rotation.y if mate != null else 100.0
	note("client dash north from facing east: %s | replica yaw here %.3f (want %.3f)" % [client_side, replica, want])
	expect(bool(client_side.get("dashed", false)) and absf(angle_difference(float(client_side.get("first", 100.0)), want)) < 0.05,
		"the_client_faces_its_dash_direction_on_its_own_screen")
	expect(absf(angle_difference(float(client_side.get("after", 100.0)), want)) < 0.05,
		"and_keeps_it_after_the_dash")
	expect(absf(angle_difference(replica, want)) < 0.1, "the_hosts_replica_of_the_client_faces_the_same_way")


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
	placed()
	await Harness.forgive_lead(get_tree())
	await tick_request(func() -> void:
		_local.global_position = point
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target()
		_local.movement.set_aim_override(Vector3.INF))


# Server -> client: stand at `at` facing east, dash north, report the yaws.
@rpc("authority", "call_remote", "reliable")
func client_dash_facing(at: Vector3) -> void:
	var seen := await _dash_facing(at)
	report.rpc_id(1, "facing", seen)


# Server -> client: dash at `aim`, press `slot` `gap` seconds after the
# dash started, report the gap this machine measured.
@rpc("authority", "call_remote", "reliable")
func client_dash_combo(aim: Vector3, slot: int, gap: float) -> void:
	var was: bool = Tuning.values.smart_key_enabled
	Tuning.values.smart_key_enabled = true
	var claimed := _local.skills.combos_claimed
	await tick_request(func() -> void:
		_local.movement.set_aim_override(aim)
		_local.movement.request_dash())
	var dashed := _local.movement.is_dashing()
	while _local.movement.seconds_since_dash() < gap:
		await get_tree().physics_frame
	var since := _local.movement.seconds_since_dash()
	await tick_request(func() -> void: _local.skills.press_slot(slot))
	await _wait(0.3)
	report.rpc_id(1, "combo", {"dashed": dashed, "claimed": since, "sent": _local.skills.combos_claimed - claimed})
	await _wait(1.0)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	Tuning.values.smart_key_enabled = was


@rpc("authority", "call_remote", "reliable")
func finish(host_failures: int) -> void:
	print("C1D_RESULT peer=%d checks=%d failures=%d host_failures=%d" % [
		_peer_id, _checks, _failures, host_failures])
	get_tree().quit(0 if _failures == 0 else 1)
