extends Node

# C-1c: the shield's four. The raise (a block window: no HP from the front,
# stamina instead, the push judged against the posture; the pool at 0 breaks
# it), the bash (a strike through the one force door), the throw (the shield
# as a rock-like body, the off hand empty until it is picked up), the slam
# (a disc, castable from the air, stronger for the fall). Two peers.

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
	print("C1C_CHECK peer=%d %s %s" % [_peer_id, "PASS" if condition else "FAIL", label])


func note(line: String) -> void:
	print("C1C_NOTE peer=%d %s" % [_peer_id, line])


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


# Home, on the ground, and refilled: the mark refills the HP RETURN_DELAY
# after the last hit, and a measurement that straddles the refill reads
# damage minus the refill (measured: a 9 slam read as 4.2).
func _wait_dummy_home(dummy: Dummy) -> void:
	var waited := 0.0
	while waited < 8.0 and (dummy.global_position.distance_to(dummy.home) > 0.3 or not dummy.is_on_floor()):
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	waited = 0.0
	while waited < 3.5 and dummy.hp < dummy.max_hp() - 0.01:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()


# Stand `distance` from the scarecrow on its `side` (+Z is its back, -Z its
# front), facing it.
func _stand_at(dummy: Dummy, distance: float, side := 1.0) -> void:
	await _wait_dummy_home(dummy)
	var spot := dummy.home + Vector3(0.0, 0.0, distance * side)
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


func _ids() -> PackedStringArray:
	var out := PackedStringArray()
	for index in 8:
		var def := _local.skills.slot_def(index)
		out.append(def.id if def != null else "-")
	return out


func _cast_and_wait(slot: int) -> Dictionary:
	var before := _judge.last_strike.duplicate()
	var thrown := _judge.shields_thrown
	await tick_request(func() -> void: _local.skills.press_slot(slot))
	var waited := 0.0
	while _judge.last_strike == before and _judge.shields_thrown == thrown and waited < 2.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	return _judge.last_strike


func _wait_idle(seconds := 2.0) -> void:
	var waited := 0.0
	while _local.state != Player.State.IDLE and waited < seconds:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()


func _until_impact(actor: Node3D) -> float:
	var pending := _judge.pending_strike(actor)
	if pending.is_empty():
		return -1.0
	return float(int(pending["at"]) - Time.get_ticks_msec()) / 1000.0


func _ensure_alive() -> void:
	if not _local.sync_dead and _local.state != Player.State.DEAD:
		return
	note("the host died on the way; respawning")
	await tick_request(func() -> void: _judge.server_respawn(_local))
	await _wait(1.0)


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
	await _slot_checks()
	await _block_checks()
	await _bash_checks()
	await _throw_checks()
	await _slam_checks()
	await _two_peer_checks()
	Tuning.values.smart_key_enabled = smart
	expect(_judge.move_warnings == warnings, "no_move_warnings_during_c1c")
	expect(_judge.move_corrections == corrections, "no_corrections_during_c1c")
	print("C1C_RESULT peer=%d checks=%d failures=%d" % [_peer_id, _checks, _failures])
	finish.rpc(_failures)
	await _wait(1.0)
	get_tree().quit(0 if _failures == 0 else 1)


# ------------------------------------------------- 1: the table

func _table_checks() -> void:
	var rows := {
		"shield_bash": [0.15, 0.40, 1.0, 1.5, 0.5, 9.0, 12.0],
		"shield_throw": [0.30, 0.50, 0.0, 8.0, 0.8, 6.0, 10.0],
		"shield_slam": [0.30, 0.50, 1.5, 1.3, 1.5, 5.0, 14.0],
		"shield_raise": [0.0, 0.1, 0.0, 0.0, 0.0, 0.0, 0.0],
	}
	var all_ok := true
	for id: String in rows:
		var def := Skills.get_def(id)
		var want: Array = rows[id]
		var got := [def.value("windup"), def.value("recovery"), def.value("cooldown"), def.value("reach"),
			def.value("damage"), def.value("knock_power"), def.value("stamina_cost")]
		var ok := def.weapon_id == "shield" and def.hands == SkillDef.Hands.OFF_HAND
		for index in want.size():
			ok = ok and absf(float(got[index]) - float(want[index])) < 0.001
		all_ok = all_ok and ok
		note("%s: windup/recovery/cooldown %.2f/%.2f/%.2f reach %.1f damage %.1f power %.0f stamina %.0f %s" % [
			id, got[0], got[1], got[2], got[3], got[4], got[5], got[6], "ok" if ok else "MISMATCH"])
	expect(all_ok, "the_four_shield_defs_read_the_tables_numbers_off_the_sliders")
	var raise := Skills.get_def("shield_raise")
	var bash := Skills.get_def("shield_bash")
	var throw := Skills.get_def("shield_throw")
	var slam := Skills.get_def("shield_slam")
	note("raise: %.2f / %.2f s, recovery %.2f, angle %.0f, stamina x%.2f, tolerance x%.2f at 100%%, recover at %.0f%% | bash %s width %.1f | throw %s | slam %s radius %.1f height bonus %.2f airborne %s" % [
		Tuning.server.shield_raise_time, Tuning.server.shield_posture_time, Tuning.server.shield_raise_recovery,
		Tuning.server.shield_raise_angle, Tuning.server.block_stamina_mult, Tuning.server.block_tolerance_mult,
		Tuning.server.block_recover_fraction * 100.0,
		SkillDef.RangeShape.keys()[bash.range_shape], bash.value("width"),
		SkillDef.RangeShape.keys()[throw.range_shape],
		SkillDef.RangeShape.keys()[slam.range_shape], slam.circle_radius_value(), slam.value("height_bonus"), slam.usable_airborne])
	expect(raise.input_mode == SkillDef.InputMode.HOLD_BLOCK and raise.range_shape == SkillDef.RangeShape.NONE
		and bash.range_shape == SkillDef.RangeShape.RECT and absf(bash.value("width") - 1.4) < 0.001
		and throw.range_shape == SkillDef.RangeShape.LINE and throw.outcome == SkillDef.Outcome.THROW_WEAPON
		and slam.range_shape == SkillDef.RangeShape.CIRCLE and absf(slam.circle_radius_value() - 1.0) < 0.001 and slam.usable_airborne,
		"the_shapes_and_modes_are_the_tables_none_rect_line_circle")
	expect(absf(Tuning.server.shield_raise_time - 0.2) < 0.001 and absf(Tuning.server.shield_posture_time - 0.6) < 0.001
		and absf(Tuning.server.shield_raise_recovery - 0.1) < 0.001 and absf(Tuning.server.block_stamina_mult - 0.5) < 0.001,
		"the_raise_is_0_2_up_0_6_full_0_1_recovery_and_half_the_damage_in_stamina")


# ------------------------------------------------- 2: the slots by the hands

func _slot_checks() -> void:
	await _take(WeaponKinds.Kind.NONE)
	note("no weapon: %s" % [_ids()])
	expect(_ids()[0] == "shove" and _ids()[4] == "-", "bare_hands_bare_four_and_four_empty")
	await _take(WeaponKinds.Kind.SHIELD)
	note("shield alone: %s" % [_ids()])
	expect(_ids()[0] == "shove" and _ids()[3] == "kick" and _ids()[4] == "shield_raise" and _ids()[5] == "shield_bash"
		and _ids()[6] == "shield_throw" and _ids()[7] == "shield_slam", "a_shield_alone_bare_four_then_shield_four")
	await _take(WeaponKinds.Kind.SWORD)
	note("sword + shield: %s" % [_ids()])
	expect(_ids()[0] == "thrust" and _ids()[3] == "parry" and _ids()[4] == "shield_raise" and _ids()[7] == "shield_slam",
		"sword_and_shield_sword_four_then_shield_four")
	expect(_judge.weapon_of(_peer_id) == WeaponKinds.Kind.SWORD and _judge.offhand_of(_peer_id) == WeaponKinds.Kind.SHIELD,
		"the_server_holds_both_hands")
	await _take(WeaponKinds.Kind.NONE)
	expect(_local.weapon == WeaponKinds.Kind.NONE and _local.offhand == WeaponKinds.Kind.NONE and _ids()[4] == "-",
		"none_empties_both_hands")
	await _take(WeaponKinds.Kind.SWORD)
	await _take(WeaponKinds.Kind.SHIELD)


# ------------------------------------------------- 3: the block

# The scarecrow (turned to face +Z) slams the host standing 1.2 m in front
# of it. The host raises the shield `raise_before` seconds before the impact
# (or not at all), and the push, the HP and the stamina are read.
func _slam_into(raise_before: float, face_it := true) -> Dictionary:
	var dummy := _dummy()
	await _wait_dummy_home(dummy)
	await tick_request(func() -> void: dummy.rotation.y = PI)
	await _wait(0.1)
	var spot := dummy.global_position + dummy.attack_direction() * 1.2
	var face := dummy.global_position if face_it else dummy.global_position + dummy.attack_direction() * 10.0
	await tick_request(func() -> void:
		placed()
		_local.skills.end_block()
		_local.global_position = Vector3(spot.x, 0.9, spot.z)
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target()
		_local.movement.set_aim_override(face)
		_local.snap_facing(face - _local.global_position))
	await _wait(0.4)
	var hp_before := _local.hp
	var stamina_before := _local.stamina
	var spent := _judge.stamina_spent_by(_peer_id)
	var broken := _judge.blocks_broken
	Tuning.server.dummy_attack_period = 0.6
	Tuning.server.dummy_attack_enabled = true
	var waited := 0.0
	while _judge.pending_strike(dummy).is_empty() and waited < 4.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	Tuning.server.dummy_attack_period = 6.0
	var posture_at_impact := -2.0
	if raise_before > 0.0:
		while _until_impact(dummy) > raise_before and not _judge.pending_strike(dummy).is_empty():
			await get_tree().physics_frame
		await tick_request(func() -> void: _local.skills.press_slot(4))
	var start := _local.global_position
	while not _judge.pending_strike(dummy).is_empty():
		posture_at_impact = _judge.block_posture(_peer_id)
		await get_tree().physics_frame
	var hit := _judge.last_hit.duplicate()
	var knock: Dictionary = _judge.last_knock.get(_peer_id, {}).duplicate()
	await _wait(0.9)
	var moved := Vector2(_local.global_position.x - start.x, _local.global_position.z - start.z).length()
	Tuning.server.dummy_attack_enabled = false
	Tuning.server.dummy_attack_period = 4.0
	await tick_request(func() -> void:
		_local.skills.end_block()
		dummy.rotation.y = 0.0)
	await _wait(0.3)
	return {
		"posture": posture_at_impact,
		"hp_lost": hp_before - _local.hp,
		"stamina_before": stamina_before,
		"stamina_spent": _judge.stamina_spent_by(_peer_id) - spent,
		"blocked": bool(hit.get("blocked", false)),
		"launched": bool(knock.get("launched", false)),
		"h_speed": float(knock.get("h_speed", 0.0)),
		"tolerance": float(knock.get("tolerance", 0.0)),
		"moved": moved,
		"broken": _judge.blocks_broken - broken,
	}


func _block_checks() -> void:
	var slam := Skills.get_def("dummy_slam")
	var slam_damage := slam.value("damage")
	# The posture over time, on the server's clock.
	await _stand_at(_dummy(), 1.5)
	await tick_request(func() -> void: _local.skills.press_slot(4))
	var samples := PackedFloat32Array()
	for at: float in [0.1, 0.3, 0.7]:
		var waited := 0.0
		while waited < at - (0.0 if samples.is_empty() else [0.1, 0.3, 0.7][samples.size() - 1]):
			await get_tree().physics_frame
			waited += get_physics_process_delta_time()
		samples.append(_judge.block_posture(_peer_id))
	note("posture at 0.1 / 0.3 / 0.7 s after the press: %.2f / %.2f / %.2f (up at %.1f, full at %.1f)" % [
		samples[0], samples[1], samples[2], Tuning.server.shield_raise_time, Tuning.server.shield_posture_time])
	expect(samples[0] < 0.0 and samples[1] > 0.1 and samples[1] < 0.5 and samples[2] > 0.99,
		"the_shield_is_not_up_at_0_1_s_a_quarter_up_at_0_3_and_full_at_0_7")
	expect(_local.skills.is_blocking() and _judge.is_blocking(_peer_id), "the_block_stands_on_both_the_owner_and_the_server")
	await tick_request(func() -> void: _local.skills.end_block())
	await _wait(0.3)
	expect(not _local.skills.is_blocking() and not _judge.is_blocking(_peer_id), "and_the_release_ends_it_on_both")
	# The slam is given a little more force for these: at the table's 8 its
	# push (7.76 m/s) sits just over a human's tolerance (7.2), so a posture
	# of 8% already holds it and the 0%/100% difference cannot be read.
	var slam_power: float = Tuning.server.dummy_attack_power
	Tuning.server.dummy_attack_power = 10.0
	# No block: the baseline.
	var plain := await _slam_into(0.0)
	note("slam, no shield: %s" % [plain])
	expect(absf(float(plain["hp_lost"]) - slam_damage) < 0.01 and not bool(plain["blocked"]), "an_unblocked_slam_costs_its_damage")
	# Full posture: no HP, half the damage in stamina, the push held (slid).
	var full := await _slam_into(1.0)
	note("slam into a 100%% block: %s" % [full])
	expect(bool(full["blocked"]) and float(full["posture"]) > 0.99 and float(full["hp_lost"]) < 0.01,
		"a_slam_into_a_full_block_costs_no_hp")
	expect(absf(float(full["stamina_spent"]) - slam_damage * Tuning.server.block_stamina_mult) < 0.01,
		"and_half_its_damage_in_stamina")
	expect(not bool(full["launched"]) and float(full["tolerance"]) > float(plain["tolerance"]) * 1.5,
		"and_is_held_the_tolerance_raised_by_the_posture")
	# Just raised: blocked, but pushed like a body that was hit.
	var late := await _slam_into(0.23)
	note("slam into a block raised 0.23 s before: %s" % [late])
	expect(bool(late["blocked"]) and float(late["posture"]) >= 0.0 and float(late["posture"]) < 0.3 and float(late["hp_lost"]) < 0.01,
		"a_block_just_raised_still_costs_no_hp")
	expect(bool(late["launched"]) and float(late["moved"]) > float(full["moved"]) + 0.5,
		"but_is_pushed_further_than_the_full_posture")
	note("pushed: unblocked %.2f m, 0%% %.2f m, 100%% %.2f m" % [float(plain["moved"]), float(late["moved"]), float(full["moved"])])
	# From behind: no block.
	var behind := await _slam_into(1.0, false)
	note("slam from behind a raised shield: %s" % [behind])
	expect(not bool(behind["blocked"]) and absf(float(behind["hp_lost"]) - slam_damage) < 0.01, "a_shield_does_not_cover_the_back")
	Tuning.server.dummy_attack_power = slam_power
	# The pool at 0: the block breaks and cannot be raised until the pool
	# is back to the fraction. The regen is slowed for this so the lockout
	# outlives the measurement (at 25/s it lifts in a second).
	await _ensure_alive()
	var regen: float = Tuning.server.stamina_regen
	Tuning.server.stamina_regen = 0.0
	await tick_request(func() -> void: _judge.server_set_stamina(_local, 3.0))
	var broken := await _slam_into(1.0)
	note("slam into a block with 3 stamina: %s | lockout %s, owner blocking %s, stamina %.1f" % [
		broken, _judge.block_locked(_peer_id), _local.skills.is_blocking(), _local.stamina])
	expect(bool(broken["blocked"]) and int(broken["broken"]) == 1 and float(broken["hp_lost"]) < 0.01 and not _local.skills.is_blocking(),
		"a_hit_that_empties_the_pool_breaks_the_block")
	await tick_request(func() -> void: _local.skills.press_slot(4))
	await _wait(0.3)
	var refused_early := not _local.skills.is_blocking()
	note("raise again at %.1f stamina: blocking %s, server locked %s" % [_local.stamina, _local.skills.is_blocking(), _judge.block_locked(_peer_id)])
	expect(refused_early and _judge.block_locked(_peer_id), "and_the_shield_cannot_be_raised_until_the_pool_recovers")
	Tuning.server.stamina_regen = regen
	var need := _local.stats.max_stamina * Tuning.server.block_recover_fraction
	var waited := 0.0
	while _judge.block_locked(_peer_id) and waited < 8.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	await tick_request(func() -> void: _local.skills.press_slot(4))
	await _wait(0.3)
	note("after %.2f s (stamina %.1f, need %.1f): locked %s, blocking %s" % [
		waited, _local.stamina, need, _judge.block_locked(_peer_id), _local.skills.is_blocking()])
	expect(not _judge.block_locked(_peer_id) and _local.skills.is_blocking() and _local.stamina >= need - 1.0,
		"and_can_be_once_it_has")
	Tuning.server.stamina_regen = regen
	await tick_request(func() -> void:
		_local.skills.end_block()
		_judge.server_set_stamina(_local, _local.stats.max_stamina)
		_judge.server_set_hp(_local, _local.stats.max_hp)
		_local.movement.set_aim_override(Vector3.INF))
	await _wait(0.3)


# ------------------------------------------------- 4: the bash

func _bash_checks() -> void:
	var dummy := _dummy()
	var bash := Skills.get_def("shield_bash")
	await _stand_at(dummy, 1.2)
	var hp_before := dummy.hp
	var start := dummy.global_position
	var strike := await _cast_and_wait(5)
	await _wait(0.6)
	var pushed := Vector2(dummy.global_position.x - start.x, dummy.global_position.z - start.z).length()
	note("bash at 1.2 m: %s | hit %s | dummy hp %.1f -> %.1f, pushed %.2f m" % [strike, _judge.last_hit, hp_before, dummy.hp, pushed])
	# Damage is read off the server's ruling (last_hit.dealt): the mark
	# refills the scarecrow's HP at its own moment, and an HP difference
	# that straddles it is wrong (measured: a 9 read as 4.2).
	expect(String(strike.get("skill", "")) == "shield_bash" and int(strike.get("hits", 0)) == 1
		and String(_judge.last_hit.get("target", "")) == dummy.name
		and absf(float(_judge.last_hit.get("dealt", 0.0)) - bash.value("damage") * Weapons.attack_power_for("shield")) < 0.01,
		"the_bash_lands_its_coefficient_times_the_shield")
	expect(pushed > 1.0 and float(_judge.last_hit.get("dealt", 0.0)) > 0.0, "and_pushes_through_the_force_door")
	await _wait_idle()
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))


# ------------------------------------------------- 5: the throw and the pick-up

func _throw_checks() -> void:
	var dummy := _dummy()
	var throw := Skills.get_def("shield_throw")
	await _stand_at(dummy, 5.5)
	var hp_before := dummy.hp
	var applied := _judge.hits_applied
	var strike := await _cast_and_wait(6)
	var waited := 0.0
	while _judge.hits_applied == applied and waited < 2.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	await _wait(0.3)
	var shield_name := String(_judge.last_shield_throw.get("shield", ""))
	var shield := _world.get_node_or_null(shield_name) as Shield
	note("shield throw: %s | hit %s | dummy hp %.1f -> %.1f | shield node %s | off hand %s | slots %s" % [
		_judge.last_shield_throw, _judge.last_hit, hp_before, dummy.hp, shield != null,
		WeaponKinds.LABELS.get(_local.offhand, "?"), _ids()])
	expect(shield != null and _judge.shields_thrown >= 1, "the_throw_puts_a_shield_body_in_the_world")
	expect(_local.offhand == WeaponKinds.Kind.NONE and _ids()[4] == "shove" and _ids()[7] == "kick",
		"and_empties_the_off_hand_so_the_bare_four_take_its_slots")
	expect(String(_judge.last_hit.get("skill", "")) == "shield_throw" and String(_judge.last_hit.get("target", "")) == dummy.name
		and absf(float(_judge.last_hit.get("dealt", 0.0)) - throw.value("damage") * Weapons.attack_power_for("shield")) < 0.01,
		"the_flying_shield_hits_with_its_throws_coefficient")
	_reports.erase("node")
	client_report_node.rpc_id(_client_peer(), shield_name)
	if await _wait_report("node"):
		expect(bool(_reports["node"].get("exists", false)), "the_client_sees_the_shield_body")
	await _wait_idle()
	await _wait(1.0)
	# Pick it up: the grab key on it puts it back.
	if shield != null:
		var at := shield.global_position
		await tick_request(func() -> void:
			placed()
			_local.global_position = Vector3(at.x, 0.9, at.z + 1.0)
			_local.velocity = Vector3.ZERO
			_local.movement.set_aim_override(at))
		await _wait(0.5)
		await tick_request(func() -> void: _local.movement.interact())
		waited = 0.0
		while _local.offhand != WeaponKinds.Kind.SHIELD and waited < 2.0:
			await get_tree().physics_frame
			waited += get_physics_process_delta_time()
		await _wait(0.3)
		var gone := _world.get_node_or_null(shield_name) == null
		note("pick-up: off hand %s after %.2f s, node gone %s, slots %s" % [
			WeaponKinds.LABELS.get(_local.offhand, "?"), waited, gone, _ids()])
		expect(_local.offhand == WeaponKinds.Kind.SHIELD and gone and _ids()[4] == "shield_raise",
			"the_grab_key_on_the_shield_puts_it_back_and_the_body_goes")
		_reports.erase("node")
		client_report_node.rpc_id(_client_peer(), shield_name)
		if await _wait_report("node"):
			expect(not bool(_reports["node"].get("exists", true)), "on_the_client_too")
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))


# ------------------------------------------------- 6: the slam

func _slam_checks() -> void:
	var dummy := _dummy()
	var slam := Skills.get_def("shield_slam")
	var shield := Weapons.attack_power_for("shield")
	await _stand_at(dummy, 1.3)
	var hp_before := dummy.hp
	var strike := await _cast_and_wait(7)
	var ground := float(_judge.last_hit.get("dealt", 0.0))
	note("slam on the ground: %s | hit %s | dealt %.2f (want %.2f), hp %.1f -> %.1f" % [
		strike, _judge.last_hit, ground, slam.value("damage") * shield, hp_before, dummy.hp])
	expect(String(strike.get("skill", "")) == "shield_slam" and int(strike.get("hits", 0)) == 1
		and String(_judge.last_hit.get("target", "")) == dummy.name
		and absf(ground - slam.value("damage") * shield) < 0.01 and absf(float(strike.get("mult", 0.0)) - 1.0) < 0.001,
		"a_slam_from_the_ground_is_its_coefficient_times_the_shield")
	await _wait_idle()
	await _wait(slam.value("cooldown"))
	# From the air: dropped 2.2 m above the same spot, cast while falling.
	await _wait_dummy_home(dummy)
	var spot := dummy.home + Vector3(0.0, 0.0, 1.3)
	hp_before = dummy.hp
	await tick_request(func() -> void:
		placed()
		_local.global_position = Vector3(spot.x, 0.9 + 2.2, spot.z)
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target()
		_local.movement.set_aim_override(dummy.home))
	var waited := 0.0
	while _local.state != Player.State.AIRBORNE and waited < 0.5:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	var casts := _local.skills.casts_sent
	await tick_request(func() -> void: _local.skills.press_slot(7))
	var state_at_press := _local.state
	waited = 0.0
	while _judge.last_strike == strike and waited < 2.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	await _wait(0.3)
	var air := _judge.last_strike
	var dealt := float(_judge.last_hit.get("dealt", 0.0)) if String(_judge.last_hit.get("skill", "")) == "shield_slam" else 0.0
	var mult := float(air.get("mult", 0.0))
	note("slam from the air (pressed while %s, cast sent %s): %s | dealt %.2f = %.2f x mult %.3f?" % [
		Player.State.keys()[state_at_press], _local.skills.casts_sent > casts, air, dealt, slam.value("damage") * shield, mult])
	expect(state_at_press == Player.State.AIRBORNE and _local.skills.casts_sent > casts, "the_slam_can_be_cast_from_the_air")
	expect(String(air.get("skill", "")) == "shield_slam" and int(air.get("hits", 0)) == 1 and mult > 1.1
		and absf(dealt - slam.value("damage") * shield * mult) < 0.05,
		"and_lands_harder_by_the_height_bonus_times_the_metres_fallen")
	await _wait_idle()
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))


# ------------------------------------------------- 7: the other peer

func _two_peer_checks() -> void:
	var mate := _mate()
	var thrust := Skills.get_def("thrust")
	var throw := Skills.get_def("shield_throw")
	await tick_request(func() -> void:
		placed()
		_judge.server_set_hp(_local, _local.stats.max_hp)
		_local.global_position = HOME
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target())
	await _take(WeaponKinds.Kind.NONE)
	await _take(WeaponKinds.Kind.SWORD)
	client_park.rpc_id(_client_peer(), HOME + Vector3(0.0, 0.0, -1.5), HOME)
	await _wait(0.9)
	_reports.erase("weapon")
	client_take_weapon.rpc_id(_client_peer(), WeaponKinds.Kind.SHIELD)
	var has_it := await _wait_report("weapon") and int(_reports["weapon"]) == WeaponKinds.Kind.SHIELD
	expect(has_it and _judge.offhand_of(_client_peer()) == WeaponKinds.Kind.SHIELD, "the_client_holds_a_shield_by_the_servers_word")
	# The client blocks; the host thrusts: no HP, stamina on the server.
	_reports.erase("block")
	client_block.rpc_id(_client_peer(), true)
	var waited := 0.0
	while not _judge.is_blocking(_client_peer()) and waited < 2.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	await _wait(0.7)
	var hp_before := mate.hp
	var spent := _judge.stamina_spent_by(_client_peer())
	await tick_request(func() -> void:
		_local.movement.set_aim_override(mate.global_position)
		_local.skills.press_slot(0))
	await _wait(thrust.impact_time() + 0.5)
	note("the host's thrust into the client's block: hit %s | client hp %.1f -> %.1f | server took %.2f stamina | block %s" % [
		_judge.last_hit, hp_before, mate.hp, _judge.stamina_spent_by(_client_peer()) - spent, _judge.last_block])
	expect(bool(_judge.last_hit.get("blocked", false)) and absf(mate.hp - hp_before) < 0.01
		and absf((_judge.stamina_spent_by(_client_peer()) - spent) - thrust.value("damage") * 10.0 * Tuning.server.block_stamina_mult) < 0.01,
		"the_clients_block_turns_the_hosts_thrust_into_stamina")
	client_block.rpc_id(_client_peer(), false)
	await _wait_idle()
	await _wait(0.5)
	# The client throws its shield at the host.
	await tick_request(func() -> void:
		placed()
		_local.global_position = HOME
		_local.velocity = Vector3.ZERO)
	client_park.rpc_id(_client_peer(), HOME + Vector3(0.0, 0.0, -5.5), HOME)
	await _wait(0.9)
	hp_before = _local.hp
	var thrown := _judge.shields_thrown
	client_cast_at.rpc_id(_client_peer(), HOME, 6)
	waited = 0.0
	while (String(_judge.last_hit.get("target", "")) != _local.name or String(_judge.last_hit.get("skill", "")) != "shield_throw") and waited < 3.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	await _wait(0.3)
	var shield_name := String(_judge.last_shield_throw.get("shield", ""))
	note("the client's throw at the host: %s | hit %s | host hp %.1f -> %.1f | node here %s" % [
		_judge.last_shield_throw, _judge.last_hit, hp_before, _local.hp, _world.get_node_or_null(shield_name) != null])
	expect(_judge.shields_thrown == thrown + 1 and _world.get_node_or_null(shield_name) != null, "the_clients_shield_flies_as_a_body_on_the_host")
	expect(String(_judge.last_hit.get("skill", "")) == "shield_throw" and String(_judge.last_hit.get("target", "")) == _local.name
		and absf((hp_before - _local.hp) - throw.value("damage") * Weapons.attack_power_for("shield")) < 0.01,
		"and_hits_the_host_with_the_throws_coefficient")
	await _wait(1.0)
	client_take_weapon.rpc_id(_client_peer(), WeaponKinds.Kind.NONE)
	await tick_request(func() -> void:
		_local.movement.set_aim_override(Vector3.INF)
		_local.set_weapon(WeaponKinds.Kind.NONE))
	await _wait(0.5)


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
func client_park(point: Vector3, face: Vector3) -> void:
	await tick_request(func() -> void:
		placed()
		_local.skills.end_block()
		_local.global_position = point
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target()
		_local.movement.set_aim_override(face)
		_local.snap_facing(face - point))
	await _wait(0.2)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))


@rpc("authority", "call_remote", "reliable")
func client_take_weapon(kind: int) -> void:
	await tick_request(func() -> void: _local.set_weapon(kind))
	var waited := 0.0
	while waited < 3.0 and ((kind == WeaponKinds.Kind.SHIELD and _local.offhand != kind)
			or (kind != WeaponKinds.Kind.SHIELD and _local.weapon != kind)):
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	await _wait(0.2)
	report.rpc_id(1, "weapon", _local.offhand if kind == WeaponKinds.Kind.SHIELD else _local.weapon)


@rpc("authority", "call_remote", "reliable")
func client_block(on: bool) -> void:
	await tick_request(func() -> void:
		if on:
			_local.skills.press_slot(4)
		else:
			_local.skills.end_block())
	await _wait(0.2)
	report.rpc_id(1, "block", {"blocking": _local.skills.is_blocking(), "stamina": _local.stamina})


@rpc("authority", "call_remote", "reliable")
func client_cast_at(aim: Vector3, slot: int) -> void:
	var was: bool = Tuning.values.smart_key_enabled
	Tuning.values.smart_key_enabled = true
	await tick_request(func() -> void:
		_local.movement.set_aim_override(aim)
		_local.skills.press_slot(slot))
	await _wait(1.0)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	Tuning.values.smart_key_enabled = was


@rpc("authority", "call_remote", "reliable")
func client_report_node(node_name: String) -> void:
	report.rpc_id(1, "node", {"exists": _world.get_node_or_null(node_name) != null})


@rpc("authority", "call_remote", "reliable")
func finish(host_failures: int) -> void:
	print("C1C_RESULT peer=%d checks=%d failures=%d host_failures=%d" % [
		_peer_id, _checks, _failures, host_failures])
	get_tree().quit(0 if _failures == 0 else 1)
