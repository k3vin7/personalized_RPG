extends Node

# OW: race-only weapons (the great sword and the great shield). What cannot
# be seen: the server refusing a weapon the race's list does not name, the
# family member's multipliers reaching the server's ruling (reach, windup,
# bash width, block angle), the weapon's weight on the body on both screens,
# the thrown great shield as its own body, and a race change emptying a hand
# the new race may not fill. Each is run with the host as the body and again
# with the client as the body. Two peers; also through the 200 ms proxy.

const HOME := Vector3(0.0, 0.9, 11.0)
const ASIDE := Vector3(9.0, 0.9, 11.0)
const GS := WeaponKinds.Kind.GREAT_SWORD
const GSH := WeaponKinds.Kind.GREAT_SHIELD
const SWORD := WeaponKinds.Kind.SWORD
const SHIELD := WeaponKinds.Kind.SHIELD
const NONE := WeaponKinds.Kind.NONE

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
	print("OW_CHECK peer=%d %s %s" % [_peer_id, "PASS" if condition else "FAIL", label])


func note(line: String) -> void:
	print("OW_NOTE peer=%d %s" % [_peer_id, line])


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


func _near(a: float, b: float, slack := 0.001) -> bool:
	return absf(a - b) <= slack


func _wait_idle(seconds := 3.0) -> void:
	var waited := 0.0
	while _local.state != Player.State.IDLE and waited < seconds:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()


# This machine's body asks for a weapon and waits for the server's word (or
# for the wait to run out, which is what a refusal looks like).
func _take(kind: int, patience := 1.5) -> void:
	await tick_request(func() -> void: _local.set_weapon(kind))
	var waited := 0.0
	while waited < patience and not _has(kind):
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	await _wait(0.2)


func _has(kind: int) -> bool:
	if kind == NONE:
		return _local.weapon == NONE and _local.offhand == NONE
	return _local.weapon == kind or _local.offhand == kind


func _ask_race(kind: int) -> void:
	await _wait_idle()
	await tick_request(func() -> void:
		placed()
		ServerAuthority.submit_intent(_local, ServerAuthority.Intent.RACE, {"race": kind}))
	var waited := 0.0
	while waited < 3.0 and _local.stats.race != kind:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	await _wait(0.5)


# The body keeps its own height off the floor: an orc's is not a human's.
func _place(point: Vector3, face: Vector3) -> void:
	placed()
	if not multiplayer.is_server():
		await Harness.forgive_lead(get_tree(), placed)
	await tick_request(func() -> void:
		_local.skills.end_block()
		_local.global_position = Vector3(point.x, _local.global_position.y, point.z)
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target()
		_local.movement.cancel_armed()
		_local.movement.set_aim_override(face)
		_local.snap_facing(Vector3(face.x - point.x, 0.0, face.z - point.z)))
	await _wait(0.4)


# Host side: start a cast (here or on the client) and watch the server's own
# record: when the intent was ruled, and when the strike by `who` was.
func _watch_cast(who: String, start: Callable) -> Dictionary:
	var before := float(_judge.last_strike.get("at_unix", 0.0))
	var ruled := _judge.skills_ruled
	start.call()
	var began := Time.get_ticks_usec()
	var ruled_at := -1.0
	var struck_at := -1.0
	while float(Time.get_ticks_usec() - began) / 1000000.0 < 4.0:
		await get_tree().physics_frame
		var now := float(Time.get_ticks_usec() - began) / 1000000.0
		if ruled_at < 0.0 and _judge.skills_ruled > ruled:
			ruled_at = now
		if float(_judge.last_strike.get("at_unix", 0.0)) != before and String(_judge.last_strike.get("by", "")) == who:
			struck_at = now
			break
	await _wait(0.6)
	return {
		"ruled": ruled_at >= 0.0,
		"struck": struck_at >= 0.0,
		"took": struck_at - ruled_at,
		"hits": int(_judge.last_strike.get("hits", -1)) if struck_at >= 0.0 else -1,
		"skill": String(_judge.last_strike.get("skill", "")),
	}


func _press(slot: int, aim: Vector3) -> void:
	Net.queue_physics(func() -> void:
		_local.movement.set_aim_override(aim)
		_local.skills.press_slot(slot))


func _dummy_home() -> void:
	await Harness.dummy_home(_dummy(), _judge, _local, _mate(), get_tree(), note)


# The distance at which the sword's thrust falls short and the great sword's
# does not: past the sword's reach even after the whole cast step.
func _thrust_gap() -> float:
	var thrust := Skills.get_def("thrust")
	return thrust.value("reach") + thrust.step_distance + _dummy().body_radius() + 0.1


# Beside the bash's line: outside the shield's half width, inside the great
# shield's (the middle of the two).
func _bash_side() -> float:
	var half := Skills.get_def("shield_bash").value("width") * 0.5
	var great := Skills.for_holder("shield_bash", NONE, GSH).value("width") * 0.5
	return (half + great) * 0.5 + _dummy().body_radius()


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
	_table_checks()
	await _host_refusal_checks()
	await _host_reach_checks()
	await _host_windup_checks()
	await _host_shield_checks()
	await _host_race_strip_checks()
	await _client_checks()
	Tuning.values.smart_key_enabled = smart
	expect(_judge.move_warnings == warnings, "no_move_warnings_during_ow")
	expect(_judge.move_corrections == corrections, "no_corrections_during_ow")
	print("OW_RESULT peer=%d checks=%d failures=%d" % [_peer_id, _checks, _failures])
	finish.rpc(_failures)
	await _wait(1.0)
	get_tree().quit(0 if _failures == 0 else 1)


# ------------------------------------------------- 1: the data

func _table_checks() -> void:
	var thrust := Skills.get_def("thrust")
	var great := Skills.for_holder("thrust", GS, NONE)
	note("thrust: sword reach %.3f windup %.3f | great sword reach %.3f windup %.3f | blade %.3f -> %.3f" % [
		thrust.value("reach"), thrust.value("windup"), great.value("reach"), great.value("windup"),
		Weapons.length_of(SWORD), Weapons.length_of(GS)])
	expect(great != thrust and great.id == "thrust" and Skills.for_holder("thrust", SWORD, NONE) == thrust,
		"the_great_swords_thrust_is_the_swords_skill_with_its_own_numbers")
	expect(_near(great.value("reach"), thrust.value("reach") * 1.25) and _near(great.value("windup"), thrust.value("windup") * 1.15)
		and _near(great.value("damage"), thrust.value("damage")) and _near(great.value("recovery"), thrust.value("recovery")),
		"reach_x1_25_windup_x1_15_and_nothing_else")
	expect(_near(Weapons.length_of(GS), Weapons.length_of(SWORD) * 1.25) and Weapons.length_of(SWORD) > 0.0,
		"the_blade_is_1_25_times_the_swords")
	for id in ["side_cut", "overhead_cut"]:
		expect(_near(Skills.for_holder(id, GS, NONE).value("reach"), Skills.get_def(id).value("reach") * 1.25),
			"%s_reaches_1_25_times_as_far" % id)
	var bash := Skills.get_def("shield_bash")
	var great_bash := Skills.for_holder("shield_bash", NONE, GSH)
	var raise := Skills.for_holder("shield_raise", NONE, GSH)
	note("bash width %.3f -> %.3f | raise angle %.1f -> %.1f | throw width %.3f -> %.3f | slam radius %.3f -> %.3f" % [
		bash.value("width"), great_bash.value("width"),
		Skills.get_def("shield_raise").value("shape_angle_deg"), raise.value("shape_angle_deg"),
		Skills.get_def("shield_throw").value("width"), Skills.for_holder("shield_throw", NONE, GSH).value("width"),
		Skills.get_def("shield_slam").circle_radius_value(), Skills.for_holder("shield_slam", NONE, GSH).circle_radius_value()])
	expect(_near(great_bash.value("width"), bash.value("width") * 1.25) and _near(great_bash.value("reach"), bash.value("reach"))
		and _near(raise.value("shape_angle_deg"), Skills.get_def("shield_raise").value("shape_angle_deg") * 1.25),
		"the_great_shields_bash_width_and_raise_angle_are_x1_25")
	expect(_near(Skills.for_holder("shield_throw", NONE, GSH).value("width"), Skills.get_def("shield_throw").value("width"))
		and _near(Skills.for_holder("shield_slam", NONE, GSH).circle_radius_value(), Skills.get_def("shield_slam").circle_radius_value()),
		"the_throw_and_the_slam_are_the_shields_own")
	note("weights: sword %.1f great sword %.1f shield %.1f great shield %.1f" % [
		Weapons.weight_of(SWORD), Weapons.weight_of(GS), Weapons.weight_of(SHIELD), Weapons.weight_of(GSH)])
	expect(Weapons.weight_of(GS) > Weapons.weight_of(SWORD) and Weapons.weight_of(GSH) > Weapons.weight_of(SHIELD),
		"the_great_ones_are_heavier")
	var only_orc := true
	for race: int in Races.all_kinds():
		var is_orc: bool = race == Races.Kind.ORC
		if Weapons.usable_by(race, GS) != is_orc or Weapons.usable_by(race, GSH) != is_orc:
			only_orc = false
		if not (Weapons.usable_by(race, SWORD) and Weapons.usable_by(race, SHIELD) and Weapons.usable_by(race, NONE)):
			only_orc = false
	expect(only_orc, "the_lists_give_the_great_ones_to_the_orc_only_and_the_rest_to_everyone")


# ------------------------------------------------- 2: host: the refusal

func _host_refusal_checks() -> void:
	await _place(HOME, HOME + Vector3(0.0, 0.0, -5.0))
	await _ask_race(Races.Kind.HUMAN)
	await _take(NONE)
	var refused := _judge.weapons_refused_by_race
	await _take(GS, 0.6)
	await _take(GSH, 0.6)
	note("a human asks for both: main %s off %s, refused +%d (%s)" % [
		WeaponKinds.LABELS.get(_local.weapon, "?"), WeaponKinds.LABELS.get(_local.offhand, "?"),
		_judge.weapons_refused_by_race - refused, _judge.last_refusal])
	expect(_local.weapon == NONE and _local.offhand == NONE and _judge.weapon_of(1) == NONE and _judge.offhand_of(1) == NONE
		and _judge.weapons_refused_by_race == refused + 2, "the_server_refuses_a_human_the_great_sword_and_the_great_shield")
	await _ask_race(Races.Kind.ORC)
	expect(_local.stats.race == Races.Kind.ORC, "the_host_is_an_orc")
	await _take(SWORD)
	await _take(SHIELD)
	expect(_local.weapon == SWORD and _local.offhand == SHIELD, "an_orc_holds_the_plain_sword_and_shield")
	expect(_near(_local.stats.weapon_weight, Weapons.weight_of(SWORD) + Weapons.weight_of(SHIELD)), "and_they_weigh_on_it")
	await _take(GS)
	await _take(GSH)
	var slot := _local.skills.slot_def(0)
	note("an orc asks for both: main %s off %s, weapon weight %.1f, slot 0 %s reach %.3f, slot 4 %s" % [
		WeaponKinds.LABELS.get(_local.weapon, "?"), WeaponKinds.LABELS.get(_local.offhand, "?"), _local.stats.weapon_weight,
		slot.id if slot != null else "-", slot.value("reach") if slot != null else -1.0,
		_local.skills.slot_def(4).id if _local.skills.slot_def(4) != null else "-"])
	expect(_local.weapon == GS and _local.offhand == GSH and _judge.weapon_of(1) == GS and _judge.offhand_of(1) == GSH,
		"the_server_gives_an_orc_both")
	expect(slot != null and slot.id == "thrust" and _near(slot.value("reach"), Skills.get_def("thrust").value("reach") * 1.25)
		and _local.skills.slot_def(4) != null and _local.skills.slot_def(4).id == "shield_raise",
		"with_the_swords_and_the_shields_skills_in_the_slots")
	expect(_near(_local.stats.weapon_weight, Weapons.weight_of(GS) + Weapons.weight_of(GSH)), "and_their_weight_on_the_body")
	await _take(NONE)
	expect(_near(_local.stats.weapon_weight, 0.0), "empty_hands_weigh_nothing")


# ------------------------------------------------- 3: host: the reach

func _thrust_from(distance: float) -> Dictionary:
	var dummy := _dummy()
	await _dummy_home()
	await _place(dummy.home + Vector3(0.0, 0.0, distance), dummy.home)
	var result: Dictionary = await _watch_cast(_local.name, func() -> void: _press(0, dummy.home))
	await _wait_idle()
	return result


func _host_reach_checks() -> void:
	var gap := _thrust_gap()
	await _take(SWORD)
	var short: Dictionary = await _thrust_from(gap)
	await _take(GS)
	var long: Dictionary = await _thrust_from(gap)
	note("host thrust from %.2f m: sword %s | great sword %s" % [gap, short, long])
	expect(bool(short["struck"]) and int(short["hits"]) == 0, "the_hosts_sword_thrust_falls_short")
	expect(bool(long["struck"]) and int(long["hits"]) == 1, "the_hosts_great_sword_thrust_reaches")
	await _take(NONE)


# ------------------------------------------------- 4: host: the windup

func _host_windup_checks() -> void:
	await _place(ASIDE, ASIDE + Vector3(0.0, 0.0, 5.0))
	await _take(SWORD)
	var plain: Dictionary = await _watch_cast(_local.name, func() -> void: _press(2, ASIDE + Vector3(0.0, 0.0, 5.0)))
	await _wait_idle()
	await _place(ASIDE, ASIDE + Vector3(0.0, 0.0, 5.0))
	await _take(GS)
	var great: Dictionary = await _watch_cast(_local.name, func() -> void: _press(2, ASIDE + Vector3(0.0, 0.0, 5.0)))
	await _wait_idle()
	var want := Skills.get_def("overhead_cut").value("windup") * 0.15
	note("host overhead cut, ruled to struck: sword %.3f s, great sword %.3f s, longer by %.3f (windup x0.15 = %.3f)" % [
		float(plain["took"]), float(great["took"]), float(great["took"]) - float(plain["took"]), want])
	expect(bool(plain["struck"]) and bool(great["struck"]) and absf(float(great["took"]) - float(plain["took"]) - want) < 0.02,
		"the_hosts_great_sword_rules_later_by_the_longer_windup")
	await _take(NONE)


# ------------------------------------------------- 5: host: the great shield

func _bash_beside(side: float) -> Dictionary:
	var dummy := _dummy()
	await _dummy_home()
	var spot := dummy.home + Vector3(side, 0.0, 1.2)
	await _place(spot, spot + Vector3(0.0, 0.0, -5.0))
	var result: Dictionary = await _watch_cast(_local.name, func() -> void: _press(5, spot + Vector3(0.0, 0.0, -5.0)))
	await _wait_idle()
	return result


func _guard_from_100_degrees() -> float:
	var mate := _mate()
	var face := HOME + Vector3(0.0, 0.0, -5.0)
	await _place(HOME, face)
	# 100 degrees off the heading: outside a half turn's half (90), inside the
	# great shield's (112.5).
	var angle := deg_to_rad(100.0)
	client_park.rpc_id(_client_peer(), HOME + Vector3(sin(angle), 0.0, -cos(angle)) * 2.0, HOME)
	await _wait(1.0)
	await tick_request(func() -> void:
		_local.movement.set_aim_override(face)
		_local.skills.press_slot(4))
	await _wait(Tuning.server.shield_posture_time + 0.4)
	var guards := _judge._block_guards(_local, mate)
	note("%s up, attacker 100 deg off the heading: block angle %.1f, blocking %s, guards %.2f" % [
		WeaponKinds.LABELS.get(_local.offhand, "?"), _judge.block_angle(1), _judge.is_blocking(1), guards])
	await tick_request(func() -> void: _local.skills.end_block())
	await _wait(0.4)
	return guards if _judge.block_angle(1) > 0.0 else -2.0


func _host_shield_checks() -> void:
	var side := _bash_side()
	await _take(SHIELD)
	var narrow: Dictionary = await _bash_beside(side)
	var plain_guard := await _guard_from_100_degrees()
	var plain_angle := _judge.block_angle(1)
	await _take(GSH)
	var wide: Dictionary = await _bash_beside(side)
	note("host bash with the scarecrow %.2f m beside the line: shield %s | great shield %s" % [side, narrow, wide])
	expect(bool(narrow["struck"]) and int(narrow["hits"]) == 0, "the_hosts_shield_bash_passes_beside_it")
	expect(bool(wide["struck"]) and int(wide["hits"]) == 1, "the_hosts_great_shield_bash_catches_it")
	var great_guard := await _guard_from_100_degrees()
	expect(_near(plain_angle, Tuning.server.shield_raise_angle) and _near(_judge.block_angle(1), minf(Tuning.server.shield_raise_angle * 1.25, 360.0)),
		"the_great_shields_block_angle_is_x1_25")
	expect(plain_guard < 0.0 and great_guard >= 0.0, "a_blow_from_100_degrees_passes_the_shield_and_meets_the_great_shield")
	# The throw: the body that leaves the hand is the great shield.
	var away := ASIDE + Vector3(0.0, 0.0, 8.0)
	await _place(ASIDE, away)
	var thrown := _judge.shields_thrown
	await tick_request(func() -> void:
		_local.movement.set_aim_override(away)
		_local.skills.press_slot(6))
	await _wait(Skills.for_holder("shield_throw", NONE, GSH).impact_time() + 1.5)
	var shield_name := String(_judge.last_shield_throw.get("shield", ""))
	var body := _world.get_node_or_null(shield_name) as Shield
	note("host throws: thrown +%d, body %s kind %s weight %.1f, off hand %s, weapon weight %.1f" % [
		_judge.shields_thrown - thrown, shield_name,
		WeaponKinds.LABELS.get(body.weapon_kind, "?") if body != null else "-", body.weight if body != null else -1.0,
		WeaponKinds.LABELS.get(_local.offhand, "?"), _local.stats.weapon_weight])
	expect(_judge.shields_thrown == thrown + 1 and body != null and body.weapon_kind == GSH and _near(body.weight, Weapons.weight_of(GSH)),
		"the_thrown_great_shield_is_a_great_shield_at_its_own_weight")
	expect(_local.offhand == NONE and _near(_local.stats.weapon_weight, 0.0), "and_the_hand_and_the_body_are_lighter_for_it")
	_reports.erase("node")
	client_report_node.rpc_id(_client_peer(), shield_name)
	if await _wait_report("node"):
		var seen: Dictionary = _reports["node"]
		note("the client's copy of %s: %s" % [shield_name, seen])
		expect(bool(seen.get("exists", false)) and int(seen.get("kind", -1)) == GSH and _near(float(seen.get("weight", 0.0)), Weapons.weight_of(GSH)),
			"the_client_sees_the_same_body")
	await _wait_idle()
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))


# ------------------------------------------------- 6: host: the race change

func _host_race_strip_checks() -> void:
	await _place(HOME, HOME + Vector3(0.0, 0.0, -5.0))
	await _take(NONE)
	await _take(GS)
	await _take(SHIELD)
	await _ask_race(Races.Kind.HUMAN)
	await _wait(0.3)
	note("orc with a great sword and a shield becomes human: main %s off %s" % [
		WeaponKinds.LABELS.get(_local.weapon, "?"), WeaponKinds.LABELS.get(_local.offhand, "?")])
	expect(_local.stats.race == Races.Kind.HUMAN and _local.weapon == NONE and _judge.weapon_of(1) == NONE,
		"a_host_that_stops_being_an_orc_loses_the_great_sword")
	expect(_local.offhand == SHIELD and _judge.offhand_of(1) == SHIELD, "and_keeps_the_shield_a_human_may_hold")
	await _take(NONE)


# ------------------------------------------------- 7: the client as the body

func _client_take(kind: int) -> Dictionary:
	_reports.erase("weapon")
	client_take_weapon.rpc_id(_client_peer(), kind)
	if await _wait_report("weapon"):
		return _reports["weapon"]
	return {}


func _client_race(kind: int) -> int:
	_reports.erase("race")
	client_race.rpc_id(_client_peer(), kind)
	if await _wait_report("race"):
		return int(_reports["race"])
	return -1


func _client_cast(point: Vector3, aim: Vector3, slot: int) -> Dictionary:
	client_park.rpc_id(_client_peer(), point, aim)
	await _wait(1.2)
	var who := _mate().name
	return await _watch_cast(who, func() -> void: client_cast_at.rpc_id(_client_peer(), aim, slot))


func _client_checks() -> void:
	var mate := _mate()
	var client := _client_peer()
	var dummy := _dummy()
	await _place(ASIDE + Vector3(4.0, 0.0, 0.0), ASIDE)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	client_park.rpc_id(client, HOME, HOME + Vector3(0.0, 0.0, -5.0))
	await _wait(1.0)
	expect(await _client_race(Races.Kind.HUMAN) == Races.Kind.HUMAN, "the_client_is_a_human")
	await _client_take(NONE)
	var refused := _judge.weapons_refused_by_race
	var asked: Dictionary = await _client_take(GS)
	note("a human client asks for the great sword: %s | server main %s, refused +%d" % [
		asked, WeaponKinds.LABELS.get(_judge.weapon_of(client), "?"), _judge.weapons_refused_by_race - refused])
	expect(int(asked.get("weapon", -1)) == NONE and _judge.weapon_of(client) == NONE and mate.weapon == NONE
		and _judge.weapons_refused_by_race == refused + 1, "the_server_refuses_a_human_client_the_great_sword")
	expect(await _client_race(Races.Kind.ORC) == Races.Kind.ORC and mate.stats.race == Races.Kind.ORC, "the_client_is_an_orc")
	# The reach, with the sword first.
	var gap := _thrust_gap()
	await _client_take(SWORD)
	await _dummy_home()
	var short: Dictionary = await _client_cast(dummy.home + Vector3(0.0, 0.0, gap), dummy.home, 0)
	var plain_cut: Dictionary = await _client_cast(HOME, HOME + Vector3(0.0, 0.0, 5.0), 2)
	asked = await _client_take(GS)
	note("an orc client asks for the great sword: %s | server main %s | the host's copy: main %s weapon weight %.1f" % [
		asked, WeaponKinds.LABELS.get(_judge.weapon_of(client), "?"), WeaponKinds.LABELS.get(mate.weapon, "?"), mate.stats.weapon_weight])
	expect(int(asked.get("weapon", -1)) == GS and _judge.weapon_of(client) == GS and mate.weapon == GS,
		"the_server_gives_an_orc_client_the_great_sword")
	expect(_near(float(asked.get("thrust_reach", 0.0)), Skills.get_def("thrust").value("reach") * 1.25)
		and _near(float(asked.get("blade", 0.0)), Weapons.length_of(GS)), "the_clients_slot_and_blade_carry_the_great_swords_numbers")
	expect(_near(float(asked.get("weight", -1.0)), Weapons.weight_of(GS)) and _near(mate.stats.weapon_weight, Weapons.weight_of(GS)),
		"its_weight_is_on_the_body_on_both_screens")
	await _dummy_home()
	var long: Dictionary = await _client_cast(dummy.home + Vector3(0.0, 0.0, gap), dummy.home, 0)
	note("client thrust from %.2f m: sword %s | great sword %s" % [gap, short, long])
	expect(bool(short["struck"]) and int(short["hits"]) == 0, "the_clients_sword_thrust_falls_short")
	expect(bool(long["struck"]) and int(long["hits"]) == 1, "the_clients_great_sword_thrust_reaches")
	var great_cut: Dictionary = await _client_cast(HOME, HOME + Vector3(0.0, 0.0, 5.0), 2)
	var want := Skills.get_def("overhead_cut").value("windup") * 0.15
	note("client overhead cut, ruled to struck on the server: sword %.3f s, great sword %.3f s, longer by %.3f (want %.3f)" % [
		float(plain_cut["took"]), float(great_cut["took"]), float(great_cut["took"]) - float(plain_cut["took"]), want])
	expect(bool(plain_cut["struck"]) and bool(great_cut["struck"]) and absf(float(great_cut["took"]) - float(plain_cut["took"]) - want) < 0.02,
		"the_clients_great_sword_rules_later_by_the_longer_windup")
	# The great shield in the client's hand, and the race change.
	asked = await _client_take(GSH)
	expect(int(asked.get("offhand", -1)) == GSH and _judge.offhand_of(client) == GSH and mate.offhand == GSH
		and _near(_judge.block_angle(client), minf(Tuning.server.shield_raise_angle * 1.25, 360.0)),
		"an_orc_client_holds_the_great_shield_and_blocks_wider")
	expect(_near(float(asked.get("weight", -1.0)), Weapons.weight_of(GS) + Weapons.weight_of(GSH)), "and_carries_both_weights")
	client_park.rpc_id(client, HOME, HOME + Vector3(0.0, 0.0, -5.0))
	await _wait(1.0)
	expect(await _client_race(Races.Kind.HUMAN) == Races.Kind.HUMAN, "the_client_is_a_human_again")
	await _wait(0.5)
	_reports.erase("hands")
	client_report_hands.rpc_id(client)
	if await _wait_report("hands"):
		var hands: Dictionary = _reports["hands"]
		note("the client after the race change: %s | server main %s off %s" % [
			hands, WeaponKinds.LABELS.get(_judge.weapon_of(client), "?"), WeaponKinds.LABELS.get(_judge.offhand_of(client), "?")])
		expect(int(hands.get("weapon", -1)) == NONE and int(hands.get("offhand", -1)) == NONE
			and _judge.weapon_of(client) == NONE and _judge.offhand_of(client) == NONE and _near(float(hands.get("weight", -1.0)), 0.0),
			"a_client_that_stops_being_an_orc_loses_both")


# ------------------------------------------------------------------ RPCs

@rpc("any_peer", "call_remote", "reliable")
func stage_done(name_text: String) -> void:
	if multiplayer.is_server() and multiplayer.get_peers().has(multiplayer.get_remote_sender_id()):
		_stage_done = name_text


@rpc("any_peer", "call_remote", "reliable")
func report(key: String, value: Variant) -> void:
	if multiplayer.is_server() and multiplayer.get_peers().has(multiplayer.get_remote_sender_id()):
		_reports[key] = value


func _hands_report() -> Dictionary:
	var slot := _local.skills.slot_def(0)
	return {
		"weapon": _local.weapon,
		"offhand": _local.offhand,
		"weight": _local.stats.weapon_weight,
		"blade": _local.hands.blade_length() if _local.hands != null else Weapons.length_of(_local.weapon),
		"thrust_reach": slot.value("reach") if slot != null and slot.id == "thrust" else -1.0,
	}


@rpc("authority", "call_remote", "reliable")
func client_park(point: Vector3, face: Vector3) -> void:
	await _place(point, face)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))


@rpc("authority", "call_remote", "reliable")
func client_take_weapon(kind: int) -> void:
	await _take(kind, 1.5)
	await _wait(0.2)
	report.rpc_id(1, "weapon", _hands_report())


@rpc("authority", "call_remote", "reliable")
func client_race(kind: int) -> void:
	await _ask_race(kind)
	report.rpc_id(1, "race", _local.stats.race)


@rpc("authority", "call_remote", "reliable")
func client_report_hands() -> void:
	report.rpc_id(1, "hands", _hands_report())


@rpc("authority", "call_remote", "reliable")
func client_cast_at(aim: Vector3, slot: int) -> void:
	var was: bool = Tuning.values.smart_key_enabled
	Tuning.values.smart_key_enabled = true
	await tick_request(func() -> void:
		_local.movement.set_aim_override(aim)
		_local.skills.press_slot(slot))
	await _wait(1.2)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	Tuning.values.smart_key_enabled = was


@rpc("authority", "call_remote", "reliable")
func client_report_node(node_name: String) -> void:
	var body := _world.get_node_or_null(node_name) as Shield
	report.rpc_id(1, "node", {
		"exists": body != null,
		"kind": body.weapon_kind if body != null else -1,
		"weight": body.weight if body != null else 0.0,
	})


@rpc("authority", "call_remote", "reliable")
func finish(host_failures: int) -> void:
	print("OW_RESULT peer=%d checks=%d failures=%d host_failures=%d" % [
		_peer_id, _checks, _failures, host_failures])
	get_tree().quit(0 if _failures == 0 else 1)
