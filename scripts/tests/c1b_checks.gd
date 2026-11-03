extends Node

# C-1b: the sword's four. The thrust (a line, the speed bonus), the side cut
# (a horizontal fan that leaves a body in the air alone), the overhead cut (a
# vertical fan that reaches one), the parry (a window: inside it the blow is
# turned and the attacker held still for its own recovery; outside it the
# recovery is the parrier's). The stamina column. Two peers: the host
# conducts, the client takes a sword of its own and strikes the host.

const HOME := Vector3(0.0, 0.9, 11.0)
const CLIENT_SPOT := Vector3(1.0, 0.9, 11.0)

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
	print("C1B_CHECK peer=%d %s %s" % [_peer_id, "PASS" if condition else "FAIL", label])


func note(line: String) -> void:
	print("C1B_NOTE peer=%d %s" % [_peer_id, line])


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


# A pushed scarecrow walks back to its mark after RETURN_DELAY; the next
# measurement waits for it to be there and on the ground.
func _wait_dummy_home(dummy: Dummy) -> void:
	var waited := 0.0
	while waited < 8.0 and (dummy.global_position.distance_to(dummy.home) > 0.3 or not dummy.is_on_floor()):
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	if dummy.global_position.distance_to(dummy.home) > 0.3:
		note("scarecrow %s is %.2f m off its mark after %.1f s" % [dummy.name, dummy.global_position.distance_to(dummy.home), waited])


# Stand `distance` south of the scarecrow (its back), facing it.
func _stand_before(dummy: Dummy, distance: float) -> void:
	await _wait_dummy_home(dummy)
	var spot := dummy.home + Vector3(0.0, 0.0, distance)
	await tick_request(func() -> void:
		placed()
		_local.global_position = Vector3(spot.x, 0.9, spot.z)
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target()
		_local.movement.cancel_armed()
		_local.movement.set_aim_override(dummy.home))
	await _wait(0.4)


func _take_sword() -> void:
	await tick_request(func() -> void: _local.set_weapon(WeaponKinds.Kind.SWORD))
	var waited := 0.0
	while _local.weapon != WeaponKinds.Kind.SWORD and waited < 2.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	await _wait(0.2)


# Cast slot `slot` and wait for the ruling (a strike) to land or 2 s.
func _cast_and_wait(slot: int) -> Dictionary:
	var ruled := _judge.skills_ruled
	var before := _judge.last_strike.duplicate()
	await tick_request(func() -> void: _local.skills.press_slot(slot))
	var waited := 0.0
	while _judge.skills_ruled == ruled and waited < 1.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	waited = 0.0
	while _judge.last_strike == before and waited < 2.0:
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
	await _range_checks()
	await _airborne_checks()
	await _speed_checks()
	await _parry_checks()
	await _stamina_checks()
	await _two_peer_checks()
	Tuning.values.smart_key_enabled = smart
	expect(_judge.move_warnings == warnings, "no_move_warnings_during_c1b")
	expect(_judge.move_corrections == corrections, "no_corrections_during_c1b")
	print("C1B_RESULT peer=%d checks=%d failures=%d" % [_peer_id, _checks, _failures])
	finish.rpc(_failures)
	await _wait(1.0)
	get_tree().quit(0 if _failures == 0 else 1)


# ------------------------------------------------- 1: the table, as loaded

func _table_checks() -> void:
	# The '기술 표' rows, read back through the sliders.
	var rows := {
		"thrust": [0.15, 0.30, 0.0, 2.2, 1.0, 3.0, 8.0],
		"side_cut": [0.20, 0.35, 0.0, 1.8, 1.2, 4.0, 10.0],
		"overhead_cut": [0.25, 0.40, 0.0, 1.8, 1.4, 3.0, 10.0],
		"parry": [0.0, 0.4, 1.0, 1.2, 0.0, 0.0, 6.0],
	}
	var all_ok := true
	for id: String in rows:
		var def := Skills.get_def(id)
		var want: Array = rows[id]
		var got := [def.value("windup"), def.value("recovery"), def.value("cooldown"), def.value("reach"),
			def.value("damage"), def.value("knock_power"), def.value("stamina_cost")]
		var ok := def.weapon_id == "sword" and def.hands == SkillDef.Hands.ONE_HAND_WEAPON
		for index in want.size():
			ok = ok and absf(float(got[index]) - float(want[index])) < 0.001
		all_ok = all_ok and ok
		note("%s: windup/recovery/cooldown %.2f/%.2f/%.2f reach %.1f damage %.1f power %.0f stamina %.0f %s" % [
			id, got[0], got[1], got[2], got[3], got[4], got[5], got[6], "ok" if ok else "MISMATCH"])
	expect(all_ok, "the_four_sword_defs_read_the_tables_numbers_off_the_sliders")
	var side := Skills.get_def("side_cut")
	var over := Skills.get_def("overhead_cut")
	var parry := Skills.get_def("parry")
	var thrust := Skills.get_def("thrust")
	note("shapes: thrust %s width %.1f | side_cut %s %.0f deg skip_airborne %s | overhead %s width %.1f vertical %.0f deg | parry %s %.0f deg window %.2f" % [
		SkillDef.RangeShape.keys()[thrust.range_shape], thrust.value("width"),
		SkillDef.RangeShape.keys()[side.range_shape], side.value("shape_angle_deg"), side.skip_airborne,
		SkillDef.RangeShape.keys()[over.range_shape], over.value("width"), over.value("vertical_angle_deg"),
		SkillDef.RangeShape.keys()[parry.range_shape], parry.value("shape_angle_deg"), Tuning.server.parry_window])
	expect(thrust.range_shape == SkillDef.RangeShape.LINE and absf(thrust.value("width") - 0.5) < 0.001
		and side.range_shape == SkillDef.RangeShape.FAN and absf(side.value("shape_angle_deg") - 120.0) < 0.001 and side.skip_airborne
		and over.range_shape == SkillDef.RangeShape.RECT and absf(over.value("vertical_angle_deg") - 40.0) < 0.001
		and parry.range_shape == SkillDef.RangeShape.NONE and not parry.shows_range() and absf(parry.value("shape_angle_deg") - 90.0) < 0.001,
		"the_shapes_are_the_c0_data_line_fan_narrow_rect_and_no_range_for_the_parry")
	expect(absf(thrust.value("speed_bonus") - 0.3) < 0.001 and side.value("speed_bonus") == 0.0,
		"only_the_thrust_carries_a_speed_bonus")
	expect(absf(Tuning.server.dummy_max_hp - 300.0) < 0.001 and absf(_dummy().max_hp() - 300.0) < 0.001
		and _dummy().hp > 299.0, "the_scarecrow_hp_is_the_300_slider")


# ------------------------------------------------- 2: the slots by the hands

func _slot_checks() -> void:
	await tick_request(func() -> void: _local.set_weapon(WeaponKinds.Kind.NONE))
	await _wait(0.4)
	var bare := _local.skills.slot_def(0)
	note("no weapon: slot 1 %s, slot 5 %s" % [bare.id if bare != null else "empty",
		_local.skills.slot_def(4).id if _local.skills.slot_def(4) != null else "empty"])
	expect(bare != null and bare.id == "shove" and _local.skills.slot_def(4) == null,
		"with_no_weapon_the_bare_four_take_the_first_slots")
	# A thrust sent with no sword in the hand is refused by the server.
	var rejected := _judge.rejected_intents
	await tick_request(func() -> void:
		ServerAuthority.submit_intent(_local, ServerAuthority.Intent.SKILL, {"skill": "thrust", "direction": Vector3.FORWARD}))
	await _wait(0.3)
	expect(_judge.rejected_intents == rejected + 1, "a_sword_skill_with_no_sword_is_refused_by_the_server")
	await _take_sword()
	var ids := PackedStringArray()
	for index in 8:
		var def := _local.skills.slot_def(index)
		ids.append(def.id if def != null else "-")
	note("sword: slots %s" % [ids])
	expect(ids[0] == "thrust" and ids[1] == "side_cut" and ids[2] == "overhead_cut" and ids[3] == "parry"
		and ids[4] == "shove" and ids[5] == "grab" and ids[6] == "punch" and ids[7] == "kick",
		"with_the_sword_its_four_take_the_first_slots_and_the_bare_four_the_off_hand")


# ------------------------------------------------- 3: each skill in and out of reach

func _range_checks() -> void:
	var dummy := _dummy()
	var sword := Weapons.attack_power_for("sword")
	for row: Array in [["thrust", 0, 2.4, 3.3], ["side_cut", 1, 1.5, 2.6], ["overhead_cut", 2, 1.5, 2.6]]:
		var id: String = row[0]
		var slot: int = row[1]
		var def := Skills.get_def(id)
		await _stand_before(dummy, float(row[2]))
		var hp_before := dummy.hp
		var strike := await _cast_and_wait(slot)
		var hit := _judge.last_hit
		var want := def.value("damage") * sword
		note("%s at %.1f m (reach %.1f): %s | hit %s | dummy hp %.1f -> %.1f (want %.1f)" % [
			id, float(row[2]), def.value("reach"), strike, hit, hp_before, dummy.hp, want])
		expect(String(strike.get("skill", "")) == id and int(strike.get("hits", 0)) == 1
			and absf((hp_before - dummy.hp) - want) < 0.01, "%s_in_reach_lands_its_coefficient_times_the_sword" % id)
		await _wait_idle()
		await _stand_before(dummy, float(row[3]))
		hp_before = dummy.hp
		strike = await _cast_and_wait(slot)
		note("%s at %.1f m: %s | dummy hp %.1f -> %.1f" % [id, float(row[3]), strike, hp_before, dummy.hp])
		expect(String(strike.get("skill", "")) == id and int(strike.get("hits", 0)) == 0 and absf(dummy.hp - hp_before) < 0.01,
			"%s_out_of_reach_misses" % id)
		await _wait_idle()
	# The side cut's fan: a body 1.5 m away but 80 degrees off the heading is
	# outside 120 degrees.
	await _stand_before(dummy, 1.5)
	var off := dummy.home + Vector3(0.0, 0.0, 1.5).rotated(Vector3.UP, deg_to_rad(80.0))
	await tick_request(func() -> void:
		placed()
		_local.global_position = Vector3(off.x, 0.9, off.z)
		_local.velocity = Vector3.ZERO
		_local.movement.set_aim_override(_local.global_position + (dummy.home - _local.global_position).rotated(Vector3.UP, deg_to_rad(80.0))))
	await _wait(0.4)
	var hp_before := dummy.hp
	var strike := await _cast_and_wait(1)
	note("side cut with the scarecrow 80 deg off the heading at 1.5 m: %s | hp %.1f -> %.1f" % [strike, hp_before, dummy.hp])
	expect(int(strike.get("hits", 0)) == 0 and absf(dummy.hp - hp_before) < 0.01, "the_side_cut_fan_is_120_degrees_not_a_disc")
	await _wait_idle()
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))


# ------------------------------------------------- 4: a body in the air

func _airborne_checks() -> void:
	var dummy := _dummy()
	var side := Skills.get_def("side_cut")
	var over := Skills.get_def("overhead_cut")
	# The side cut: the scarecrow is popped up as the cast begins, so it is
	# off the ground at the impact (windup 0.2 s): inside the height band,
	# left alone all the same.
	await _stand_before(dummy, 1.5)
	var hp_before := dummy.hp
	var skipped := int(_judge.last_strike.get("skipped_airborne", 0))
	await tick_request(func() -> void:
		dummy.velocity.y = 9.0
		_local.skills.press_slot(1))
	var waited := 0.0
	var peak := dummy.global_position.y
	var airborne_at_impact := false
	while waited < side.impact_time() + 0.3:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		peak = maxf(peak, dummy.global_position.y)
		if absf(waited - side.impact_time()) < 0.02:
			airborne_at_impact = not dummy.is_on_floor()
	var strike := _judge.last_strike
	note("side cut on a scarecrow in the air (peak y %.2f, airborne at impact %s): %s | hp %.1f -> %.1f" % [
		peak, airborne_at_impact, strike, hp_before, dummy.hp])
	expect(airborne_at_impact and String(strike.get("skill", "")) == "side_cut" and int(strike.get("hits", 0)) == 0
		and int(strike.get("skipped_airborne", 0)) == 1 and absf(dummy.hp - hp_before) < 0.01,
		"the_side_cut_leaves_a_body_in_the_air_alone")
	await _wait_idle()
	await _wait(1.2)
	# The overhead cut reaches it.
	await _stand_before(dummy, 1.5)
	hp_before = dummy.hp
	await tick_request(func() -> void:
		dummy.velocity.y = 9.0
		_local.skills.press_slot(2))
	waited = 0.0
	var rise_at_impact := 0.0
	airborne_at_impact = false
	while waited < over.impact_time() + 0.3:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		if absf(waited - over.impact_time()) < 0.02:
			airborne_at_impact = not dummy.is_on_floor()
			rise_at_impact = dummy.global_position.y - (_local.global_position.y + over.strike_height)
	strike = _judge.last_strike
	note("overhead cut on a scarecrow in the air (airborne at impact %s, centre %.2f m above the pivot): %s | hp %.1f -> %.1f" % [
		airborne_at_impact, rise_at_impact, strike, hp_before, dummy.hp])
	expect(airborne_at_impact and String(strike.get("skill", "")) == "overhead_cut" and int(strike.get("hits", 0)) == 1
		and absf((hp_before - dummy.hp) - over.value("damage") * Weapons.attack_power_for("sword")) < 0.01,
		"the_overhead_cut_reaches_a_body_in_the_air")
	await _wait_idle()
	await _wait(1.2)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))


# ------------------------------------------------- 5: the thrust's speed bonus

func _speed_checks() -> void:
	var dummy := _dummy()
	var thrust := Skills.get_def("thrust")
	var sword := Weapons.attack_power_for("sword")
	var bonus := thrust.value("speed_bonus")
	var base: float = Tuning.server.base_move_speed
	# Standing: x1.
	await _stand_before(dummy, 2.0)
	var hp_before := dummy.hp
	var strike := await _cast_and_wait(0)
	var standing := hp_before - dummy.hp
	note("thrust standing: mult %.3f, dealt %.2f" % [float(strike.get("mult", 0.0)), standing])
	expect(absf(float(strike.get("mult", 0.0)) - 1.0) < 0.001 and absf(standing - thrust.value("damage") * sword) < 0.01,
		"a_standing_thrust_is_the_plain_coefficient")
	await _wait_idle()
	# Moving at the base speed as the intent goes out: the server reads the
	# body's speed in that tick, x(1 + 0.3 x 6/6) = 1.3.
	await _stand_before(dummy, 2.0)
	hp_before = dummy.hp
	var ruled := _judge.skills_ruled
	await tick_request(func() -> void:
		_local.velocity = Vector3(0.0, 0.0, -base)
		_local.skills.press_slot(0))
	var waited := 0.0
	while _judge.last_strike.get("skill", "") != "thrust" or _judge.skills_ruled == ruled or dummy.hp == hp_before:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		if waited > 2.0:
			break
	strike = _judge.last_strike
	var moving := hp_before - dummy.hp
	var want_mult := 1.0 + bonus * base / base
	note("thrust at %.1f m/s (base %.1f, bonus %.2f): mult %.3f (formula %.3f), dealt %.2f (standing %.2f)" % [
		base, base, bonus, float(strike.get("mult", 0.0)), want_mult, moving, standing])
	expect(absf(float(strike.get("mult", 0.0)) - want_mult) < 0.01 and absf(moving - standing * want_mult) < 0.05,
		"a_moving_thrust_is_the_coefficient_times_one_plus_the_bonus_times_speed_over_base")
	await _wait_idle()
	# And a real run: ordered to walk at the scarecrow from 5 m, the thrust
	# pressed while walking reads the walk's speed.
	await _stand_before(dummy, 5.0)
	hp_before = dummy.hp
	await tick_request(func() -> void: _local.movement.set_target(dummy.home + Vector3(0.0, 0.0, 1.0)))
	await _wait(0.45)
	var speed_seen := Vector2(_local.velocity.x, _local.velocity.z).length()
	ruled = _judge.skills_ruled
	await tick_request(func() -> void:
		_local.movement.set_aim_override(dummy.home)
		_local.skills.press_slot(0))
	await _wait(thrust.impact_time() + thrust.value("recovery") + 0.3)
	strike = _judge.last_strike
	note("thrust pressed mid-walk (speed %.2f m/s): mult %.3f, hits %d, dealt %.2f" % [
		speed_seen, float(strike.get("mult", 0.0)), int(strike.get("hits", 0)), hp_before - dummy.hp])
	expect(speed_seen > 1.0 and float(strike.get("mult", 0.0)) > 1.0
		and absf(float(strike.get("mult", 0.0)) - (1.0 + bonus * speed_seen / base)) < 0.08,
		"a_thrust_pressed_while_walking_carries_the_walks_speed")
	await _wait_idle()
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))


# ------------------------------------------------- 6: the parry

# Stand in front of the scarecrow (it faces -Z), let it swing, press the
# parry this long before the impact.
func _slam_and_parry(press_before_impact: float) -> Dictionary:
	var dummy := _dummy()
	await _wait_dummy_home(dummy)
	# The scarecrow is turned to face south (+Z, into the arena) for this:
	# facing -Z its slam pushed the parrier north off the arena's edge, a
	# kill-plane death between two checks (measured, run c).
	await tick_request(func() -> void: dummy.rotation.y = PI)
	await _wait(0.1)
	var spot := dummy.global_position + dummy.attack_direction() * 1.2
	await tick_request(func() -> void:
		placed()
		_local.global_position = Vector3(spot.x, 0.9, spot.z)
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target()
		_local.movement.set_aim_override(dummy.global_position))
	await _wait(0.4)
	note("parry stand: scarecrow at %s (home %s) facing %s, parrier at %s" % [
		dummy.global_position, dummy.home, dummy.attack_direction(), _local.global_position])
	var hp_before := _local.hp
	var parries := _judge.parries
	var failed := _judge.parries_failed
	Tuning.server.dummy_attack_period = 0.6
	Tuning.server.dummy_attack_enabled = true
	var waited := 0.0
	while _judge.pending_strike(dummy).is_empty() and waited < 4.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	expect(not _judge.pending_strike(dummy).is_empty(), "the_scarecrow_booked_a_slam")
	# One slam: the next is pushed far off so it cannot land inside the
	# measurement, while the pattern stays on (switching it off wipes the
	# stunned phase being measured).
	Tuning.server.dummy_attack_period = 6.0
	while _until_impact(dummy) > press_before_impact and not _judge.pending_strike(dummy).is_empty():
		await get_tree().physics_frame
	var pressed_at := _until_impact(dummy)
	var press_msec := Time.get_ticks_msec()
	await tick_request(func() -> void: _local.skills.press_slot(3))
	# Time the parrier's recovery from the press, and the scarecrow's stun.
	# The pattern is switched off the moment this slam is ruled, so the next
	# one (period 0.6 + windup 0.8) does not land inside the measurement.
	var recovery_seen := -1.0
	var stunned_seen := 0.0
	var stun_started := -1.0
	var hp_after_slam := -1.0
	waited = 0.0
	var ruled_at := -1.0
	while waited < 2.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		if ruled_at < 0.0 and _judge.pending_strike(dummy).is_empty():
			ruled_at = waited
		if hp_after_slam < 0.0 and ruled_at >= 0.0 and waited > ruled_at + 0.3:
			hp_after_slam = _local.hp
		if recovery_seen < 0.0 and _local.state != Player.State.RECOVERING and waited > 0.05:
			recovery_seen = float(Time.get_ticks_msec() - press_msec) / 1000.0
		if dummy.attack_phase == "stunned":
			if stun_started < 0.0:
				stun_started = waited
			stunned_seen = waited - stun_started + get_physics_process_delta_time()
	Tuning.server.dummy_attack_enabled = false
	Tuning.server.dummy_attack_period = 4.0
	await tick_request(func() -> void: dummy.rotation.y = 0.0)
	await _wait(0.3)
	if hp_after_slam < 0.0:
		hp_after_slam = _local.hp
	return {
		"pressed_before_impact": pressed_at,
		"parries": _judge.parries - parries,
		"failed": _judge.parries_failed - failed,
		"hp_lost": hp_before - hp_after_slam,
		"recovery": recovery_seen,
		"stun": stunned_seen,
		"last": _judge.last_parry.duplicate(),
	}


func _parry_checks() -> void:
	var slam := Skills.get_def("dummy_slam")
	var parry := Skills.get_def("parry")
	# Inside the window: pressed 0.12 s before the impact (window 0.25).
	var inside := await _slam_and_parry(0.12)
	note("parry %.3f s before the slam: %s" % [float(inside["pressed_before_impact"]), inside])
	expect(int(inside["parries"]) == 1 and float(inside["hp_lost"]) < 0.01, "a_parry_inside_the_window_turns_the_slam_and_costs_no_hp")
	expect(absf(float(inside["stun"]) - slam.value("recovery")) < 0.12 and absf(float(inside["last"].get("stun", 0.0)) - slam.value("recovery")) < 0.001,
		"and_holds_the_attacker_for_its_own_recovery_0_5")
	expect(float(inside["recovery"]) >= 0.0 and float(inside["recovery"]) < parry.value("recovery") - 0.1,
		"and_the_parriers_recovery_ends_at_once")
	await _wait(1.0)
	# Outside: pressed 0.6 s before the impact, the window has closed by the
	# time the slam lands: it hits, the parry fails, the recovery is 0.4.
	var outside := await _slam_and_parry(0.6)
	note("parry %.3f s before the slam: %s" % [float(outside["pressed_before_impact"]), outside])
	expect(int(outside["parries"]) == 0 and int(outside["failed"]) == 1
		and absf(float(outside["hp_lost"]) - slam.value("damage")) < 0.01, "a_parry_outside_the_window_fails_and_the_slam_lands")
	expect(absf(float(outside["recovery"]) - parry.value("recovery")) < 0.08, "and_costs_the_failed_recovery_0_4")
	expect(float(outside["stun"]) == 0.0, "and_the_attacker_is_not_held")
	await _wait(1.0)
	Tuning.server.dummy_attack_enabled = false
	await tick_request(func() -> void:
		_local.movement.set_aim_override(Vector3.INF)
		_judge.server_set_hp(_local, _local.stats.max_hp))
	await _ensure_alive()


# A body that died on the way (a slam too many) is put back before the
# next section measures anything.
func _ensure_alive() -> void:
	if not _local.sync_dead and _local.state != Player.State.DEAD:
		return
	note("the host died on the way (hp %.1f, %s); respawning" % [_local.hp, Player.State.keys()[_local.state]])
	await tick_request(func() -> void: _judge.server_respawn(_local))
	await _wait(1.0)


# ------------------------------------------------- 7: the stamina column

func _stamina_checks() -> void:
	var dummy := _dummy()
	var thrust := Skills.get_def("thrust")
	await _stand_before(dummy, 2.0)
	var before := _local.stamina
	var spent := _judge.stamina_spent_by(_peer_id)
	await tick_request(func() -> void: _local.skills.press_slot(0))
	var after := _local.stamina
	note("thrust: stamina %.2f -> %.2f (cost %.0f, regen %.0f/s over the tick; server took %.2f)" % [
		before, after, thrust.value("stamina_cost"), Tuning.server.stamina_regen, _judge.stamina_spent_by(_peer_id) - spent])
	expect(absf(_judge.stamina_spent_by(_peer_id) - spent - thrust.value("stamina_cost")) < 0.001
		and before - after > thrust.value("stamina_cost") - Tuning.server.stamina_regen * 0.05 - 0.01,
		"a_cast_costs_its_stamina_column_on_the_server")
	await _wait_idle()
	# At 0 the press is refused on the owner's machine and the intent is
	# refused by the server if sent anyway.
	var ignored := _local.skills.presses_ignored
	var rejected := _judge.rejected_intents
	var ruled := _judge.skills_ruled
	await tick_request(func() -> void:
		_local.stamina = 0.0
		_local.skills.press_slot(0))
	expect(_local.skills.presses_ignored == ignored + 1 and _judge.skills_ruled == ruled, "at_0_stamina_the_press_is_refused")
	await tick_request(func() -> void:
		_local.stamina = 0.0
		ServerAuthority.submit_intent(_local, ServerAuthority.Intent.SKILL, {"skill": "thrust", "direction": Vector3.FORWARD}))
	await _wait(0.2)
	expect(_judge.rejected_intents == rejected + 1 and _judge.skills_ruled == ruled, "and_the_server_refuses_the_intent_at_0")
	await _wait(1.0)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))


# ------------------------------------------------- 8: the other peer

func _two_peer_checks() -> void:
	var mate := _mate()
	var thrust := Skills.get_def("thrust")
	await tick_request(func() -> void:
		placed()
		_judge.server_set_hp(_local, _local.stats.max_hp)
		_local.global_position = HOME
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target()
		_local.movement.set_aim_override(Vector3.INF))
	# 1.3 m apart: inside the thrust's reach (2.2) and the parry's (1.2 + a
	# body's radius 0.4), so each can answer the other.
	client_park.rpc_id(_client_peer(), HOME + Vector3(0.0, 0.0, -1.3))
	await _wait(0.9)
	# The client takes a sword; the server's word on its hands reaches both,
	# the client's own machine a packet later than this one, so its report
	# is waited for before it is asked to swing.
	_reports.erase("weapon")
	client_take_weapon.rpc_id(_client_peer(), WeaponKinds.Kind.SWORD)
	var waited := 0.0
	while mate.weapon != WeaponKinds.Kind.SWORD and waited < 3.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	var client_has_it := await _wait_report("weapon") and int(_reports["weapon"]) == WeaponKinds.Kind.SWORD
	expect(mate.weapon == WeaponKinds.Kind.SWORD and _judge.weapon_of(_client_peer()) == WeaponKinds.Kind.SWORD and client_has_it,
		"the_client_holds_a_sword_by_the_servers_word")
	# The client thrusts the host: the host loses 10, sees the swing.
	var hp_before := _local.hp
	var applied := _judge.hits_applied
	_reports.erase("cast")
	client_cast_at.rpc_id(_client_peer(), HOME, 0)
	var saw_swing := false
	var saw_phase := ""
	waited = 0.0
	while _judge.hits_applied == applied and waited < 3.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		if mate.sync_skill_id == "thrust":
			saw_phase = mate.sync_skill_phase
		if mate.swing_active():
			saw_swing = true
	await _wait(0.5)
	note("the client's thrust on the host: hit %s | host hp %.1f -> %.1f | saw phase '%s' swing %s" % [
		_judge.last_hit, hp_before, _local.hp, saw_phase, saw_swing])
	expect(String(_judge.last_hit.get("skill", "")) == "thrust" and String(_judge.last_hit.get("target", "")) == _local.name
		and absf((hp_before - _local.hp) - thrust.value("damage") * Weapons.attack_power_for("sword")) < 0.01,
		"the_clients_thrust_is_ruled_on_the_server_and_lands_on_the_host")
	expect(saw_phase != "" or saw_swing, "and_the_host_screen_shows_the_clients_swing")
	if await _wait_report("cast"):
		var cast: Dictionary = _reports["cast"]
		note("the client's own count: %s" % [cast])
		expect(float(cast.get("spent", 0.0)) > thrust.value("stamina_cost") - 1.5
			and absf(_judge.stamina_spent_by(_client_peer()) - thrust.value("stamina_cost")) < 0.001,
			"the_client_paid_the_stamina_column_on_the_server_and_saw_it")
	# The client parries the host's thrust: the host is held for the thrust's
	# recovery, the client takes nothing.
	# Both put back first: the client's thrust slid the host half a metre
	# (measured 1.85 m apart, past the parry's 1.6).
	await tick_request(func() -> void:
		placed()
		_local.global_position = HOME
		_local.velocity = Vector3.ZERO)
	client_park.rpc_id(_client_peer(), HOME + Vector3(0.0, 0.0, -1.3))
	await _wait(0.9)
	hp_before = mate.hp
	var parries := _judge.parries
	await tick_request(func() -> void: _local.movement.set_aim_override(mate.global_position))
	await _wait(0.2)
	await tick_request(func() -> void: _local.skills.press_slot(0))
	# The client is told to parry when the booking is 0.2 s from impact: the
	# order and the parry intent each cross the wire once, and the window
	# (0.25) has to still be open at the impact.
	while _until_impact(_local) > 0.2 and not _judge.pending_strike(_local).is_empty():
		await get_tree().physics_frame
	client_cast_at.rpc_id(_client_peer(), HOME, 3)
	waited = 0.0
	var host_stunned := 0.0
	while waited < 2.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		if _local.state == Player.State.STUNNED:
			host_stunned += get_physics_process_delta_time()
	note("the client's parry of the host's thrust: parries +%d, last %s, client hp %.1f -> %.1f, host stunned %.2f s" % [
		_judge.parries - parries, _judge.last_parry, hp_before, mate.hp, host_stunned])
	# One way of latency sits between the press and the window, so this is
	# reported and only loosely checked: the parry either turned it (stun =
	# the thrust's recovery) or the window missed the impact by the lag.
	expect(_judge.parries - parries == 1 and absf(mate.hp - hp_before) < 0.01 and absf(host_stunned - thrust.value("recovery")) < 0.15
		or (_judge.parries == parries and absf((hp_before - mate.hp) - thrust.value("damage") * 10.0) < 0.01),
		"the_clients_parry_turns_the_hosts_thrust_or_misses_by_the_lag_and_nothing_else")
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
func client_park(point: Vector3) -> void:
	await tick_request(func() -> void:
		placed()
		_local.global_position = point
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target()
		_local.movement.set_aim_override(Vector3.INF))


@rpc("authority", "call_remote", "reliable")
func client_take_weapon(kind: int) -> void:
	await tick_request(func() -> void: _local.set_weapon(kind))
	var waited := 0.0
	while _local.weapon != kind and waited < 3.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	await _wait(0.2)
	report.rpc_id(1, "weapon", _local.weapon)


# Server -> client: cast `slot` at a point; report what it cost.
@rpc("authority", "call_remote", "reliable")
func client_cast_at(aim: Vector3, slot: int) -> void:
	var was: bool = Tuning.values.smart_key_enabled
	Tuning.values.smart_key_enabled = true
	# C-1b': the cost lands on this screen a packet later, as the server's
	# number; the deepest the pool goes in the next 0.8 s is what was paid
	# (regen refills 8 in a third of a second).
	var before := _local.stamina
	var lowest := before
	await tick_request(func() -> void:
		_local.movement.set_aim_override(aim)
		_local.skills.press_slot(slot))
	var waited := 0.0
	while waited < 0.8:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		lowest = minf(lowest, _local.stamina)
	report.rpc_id(1, "cast", {"spent": before - lowest, "slot": slot})
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	Tuning.values.smart_key_enabled = was


@rpc("authority", "call_remote", "reliable")
func finish(host_failures: int) -> void:
	print("C1B_RESULT peer=%d checks=%d failures=%d host_failures=%d" % [
		_peer_id, _checks, _failures, host_failures])
	get_tree().quit(0 if _failures == 0 else 1)
