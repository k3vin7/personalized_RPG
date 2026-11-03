extends Node

# C-1a: the ability sheet (vitality, points), HP and stamina off it, the
# weapon's attack power, the one damage function (coefficient x attack, crit,
# armour) and the hit id every screen matches its feedback to. Two peers: the
# host conducts and the client stands in as the target and the other screen.

const HOME := Vector3(0.0, 0.9, 11.0)
const CLIENT_SPOT := Vector3(1.0, 0.9, 11.0)

var _world: Node3D
var _local: Player
var _judge: ServerAuthority
var _feedback: HitFeedback
var _peer_id := 0
var _checks := 0
var _failures := 0
var _stage_done := ""
var _reports := {}


func expect(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("C1A_CHECK peer=%d %s %s" % [_peer_id, "PASS" if condition else "FAIL", label])


func note(line: String) -> void:
	print("C1A_NOTE peer=%d %s" % [_peer_id, line])


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


func _reset_pair() -> void:
	var mate := _mate()
	await tick_request(func() -> void:
		placed()
		_judge.harness_clear_stats(_local)
		_judge.harness_set_points(_local, PackedInt32Array([0, 0, 0, 0, 0]))
		_judge.server_respawn(_local)
		if mate != null:
			_judge.harness_clear_stats(mate)
			_judge.harness_set_points(mate, PackedInt32Array([0, 0, 0, 0, 0]))
			_judge.server_respawn(mate)
		_local.global_position = HOME
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target()
		_local.movement.cancel_armed()
		_local.movement.set_aim_override(Vector3.INF))
	client_park.rpc_id(_client_peer(), CLIENT_SPOT)
	await _wait(0.9)
	_local.movement.set_aim_override(CLIENT_SPOT)


# The host punches the client once and waits for the ruling.
func _punch_mate() -> Dictionary:
	var punch := Skills.get_def("punch")
	var applied := _judge.hits_applied
	await tick_request(func() -> void: _local.skills.press_slot(2))
	var waited := 0.0
	while _judge.hits_applied == applied and waited < 2.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	await _wait(punch.value("recovery") + 0.3)
	return _judge.last_hit if _judge.hits_applied > applied else {}


func run(world: Node3D) -> void:
	_world = world
	_peer_id = multiplayer.get_unique_id()
	_local = Net.spawn_root.get_node(str(_peer_id)) as Player
	_judge = world.get_node_or_null("ServerAuthority") as ServerAuthority
	_feedback = HitFeedback.instance
	if not multiplayer.is_server():
		stage_done.rpc_id(1, "client_ready")
		return
	expect(await _wait_stage("client_ready"), "both_peers_present")
	var warnings := _judge.move_warnings
	var corrections := _judge.move_corrections
	var smart: bool = Tuning.values.smart_key_enabled
	Tuning.values.smart_key_enabled = true
	await _formula_checks()
	await _vitals_checks()
	await _points_checks()
	await _weapon_checks()
	await _crit_checks()
	await _armor_checks()
	await _hit_id_checks()
	await _bypass_checks()
	Tuning.values.smart_key_enabled = smart
	expect(_judge.move_warnings == warnings, "no_move_warnings_during_c1a")
	expect(_judge.move_corrections == corrections, "no_corrections_during_c1a")
	print("C1A_RESULT peer=%d checks=%d failures=%d" % [_peer_id, _checks, _failures])
	finish.rpc(_failures)
	await _wait(1.0)
	get_tree().quit(0 if _failures == 0 else 1)


# ------------------------------------------------- 1: the armour formula table

func _formula_checks() -> void:
	# max(0, attack - armour x 0.05) x 100 / (100 + armour), the design's
	# formula (2026-10-30), read as a table. The work order's expected column
	# (10/4.75/0/4.4) does not come out of this formula; the design's numbers
	# are what is checked, and the difference is reported.
	var pct: float = Tuning.server.armor_flat_pct
	var rows := [[10.0, 0.0, 10.0], [10.0, 100.0, 2.5], [10.0, 400.0, 0.0], [30.0, 400.0, 2.0], [20.0, 400.0, 0.0], [21.0, 400.0, 0.2]]
	var all_ok := true
	for row: Array in rows:
		var got := ServerAuthority.damage_after_armor(float(row[0]), float(row[1]))
		var ok := absf(got - float(row[2])) < 0.005
		all_ok = all_ok and ok
		note("formula: attack %.0f armour %.0f -> %.2f (expected %.2f, flat %.2f) %s" % [
			float(row[0]), float(row[1]), got, float(row[2]), pct, "ok" if ok else "MISMATCH"])
	expect(all_ok, "the_armour_formula_matches_the_designs_table_to_two_decimals")
	expect(absf(pct - 0.05) < 0.0001 and Tuning.limits_for("armor_player").y >= 400.0,
		"the_five_percent_is_a_slider_and_armour_sliders_reach_400")


# --------------------------------------------- 2: vitality -> HP, endurance -> stamina

func _vitals_checks() -> void:
	await _reset_pair()
	var k: float = Tuning.server.k_hp
	var alpha: float = Tuning.server.stamina_alpha
	await tick_request(func() -> void: _judge.harness_set_race(_local, Races.Kind.HUMAN))
	await _wait(0.3)
	note("human: vitality %.0f endurance %.0f -> max_hp %.2f max_stamina %.2f (k_hp %.2f alpha %.2f)" % [
		_local.stats.vitality, _local.stats.endurance, _local.stats.max_hp, _local.stats.max_stamina, k, alpha])
	expect(absf(_local.stats.max_hp - 105.0) < 0.1, "a_human_has_105_hp")
	expect(absf(_local.stats.max_stamina - 101.5) < 0.1, "and_101_5_stamina")
	var all_ok := true
	for kind: int in Races.all_kinds():
		var data := Races.data_for(kind)
		await tick_request(func() -> void: _judge.harness_set_race(_local, kind))
		await _wait(0.3)
		var hp_ok := absf(_local.stats.max_hp - data.vitality * k) < 0.01
		var st_ok := absf(_local.stats.max_stamina - data.endurance * (1.0 + alpha)) < 0.01
		note("%s: vitality %.0f -> hp %.1f, endurance %.0f -> stamina %.1f" % [
			data.label, data.vitality, _local.stats.max_hp, data.endurance, _local.stats.max_stamina])
		all_ok = all_ok and hp_ok and st_ok
	expect(all_ok, "every_race_takes_hp_from_vitality_and_stamina_from_endurance")
	# HP really comes from the vitality column, not from endurance: give the
	# dwarf a vitality its endurance does not have, on the server's table.
	var dwarf := Races.data_for(Races.Kind.DWARF)
	var was := dwarf.vitality
	dwarf.vitality = 130.0
	await tick_request(func() -> void: _judge.harness_set_race(_local, Races.Kind.DWARF))
	await _wait(0.3)
	note("dwarf with vitality 130 (endurance %.0f): max_hp %.1f" % [dwarf.endurance, _local.stats.max_hp])
	expect(absf(_local.stats.max_hp - 130.0 * k) < 0.01 and absf(_local.stats.max_hp - dwarf.endurance * k) > 1.0,
		"changing_the_vitality_column_alone_changes_the_hp")
	dwarf.vitality = was
	await tick_request(func() -> void: _judge.harness_set_race(_local, Races.Kind.HUMAN))
	await _wait(0.3)
	# The other screen: the server puts the client on orc; the client's own
	# body says 120 / 116 from the same table.
	var mate := _mate()
	await tick_request(func() -> void: _judge.harness_set_race(mate, Races.Kind.ORC))
	await _wait(0.6)
	_reports.erase("vitals")
	client_report_vitals.rpc_id(_client_peer())
	if await _wait_report("vitals"):
		var seen: Dictionary = _reports["vitals"]
		note("client on orc: server max_hp %.1f max_stamina %.1f | client's own %.1f %.1f hp %.1f" % [
			mate.stats.max_hp, mate.stats.max_stamina, float(seen["max_hp"]), float(seen["max_stamina"]), float(seen["hp"])])
		expect(absf(float(seen["max_hp"]) - mate.stats.max_hp) < 0.01 and absf(float(seen["max_stamina"]) - mate.stats.max_stamina) < 0.01,
			"the_client_computes_the_same_hp_and_stamina_from_the_same_table")
		expect(absf(float(seen["max_hp"]) - 120.0) < 0.1 and absf(float(seen["max_stamina"]) - 116.0) < 0.1, "an_orc_is_120_and_116")
	await tick_request(func() -> void: _judge.harness_set_race(mate, Races.Kind.HUMAN))
	await _wait(0.5)


# ------------------------------------------- 3: race base + points x weight

func _points_checks() -> void:
	await _reset_pair()
	var w: float = Tuning.server.stat_point_weight
	var base_strength := _local.stats.strength
	var base_agility := _local.stats.agility
	await tick_request(func() -> void: _judge.harness_set_points(_local, PackedInt32Array([20, 0, 10, 0, 10])))
	await _wait(0.5)
	note("points [20,0,10,0,10] x %.2f: strength %.1f -> %.1f, agility %.1f -> %.1f, vitality %.1f, max_hp %.1f" % [
		w, base_strength, _local.stats.strength, base_agility, _local.stats.agility, _local.stats.vitality, _local.stats.max_hp])
	expect(absf(_local.stats.strength - (base_strength + 20.0 * w)) < 0.01, "strength_is_race_base_plus_points_times_the_weight")
	expect(absf(_local.stats.agility - (base_agility + 10.0 * w)) < 0.01, "so_is_agility")
	expect(absf(_local.stats.max_hp - (70.0 + 10.0 * w) * Tuning.server.k_hp) < 0.01, "and_the_hp_follows_the_vitality_points")
	# The points travel: the client sees the host's strength from them.
	_reports.erase("mate_stats")
	client_report_body.rpc_id(_client_peer(), _local.get_path())
	if await _wait_report("mate_stats"):
		var seen: Dictionary = _reports["mate_stats"]
		note("the host as the client sees it: strength %.1f points %s max_hp %.1f" % [
			float(seen["strength"]), seen["points"], float(seen["max_hp"])])
		expect(absf(float(seen["strength"]) - _local.stats.strength) < 0.01 and absf(float(seen["max_hp"]) - _local.stats.max_hp) < 0.01,
			"the_points_reach_the_other_screen_with_the_same_numbers")
	# A race change is a fresh sheet.
	await tick_request(func() -> void: _judge.harness_set_race(_local, Races.Kind.ELF))
	await _wait(0.3)
	expect(_local.stats.points == PackedInt32Array([0, 0, 0, 0, 0]), "choosing_a_race_clears_the_points")
	await tick_request(func() -> void: _judge.harness_set_race(_local, Races.Kind.HUMAN))
	await _wait(0.3)


# ------------------------------------- 4: coefficient x weapon attack power

func _weapon_checks() -> void:
	await _reset_pair()
	var mate := _mate()
	var punch := Skills.get_def("punch")
	note("weapons: sword %.0f shield %.0f bare %.0f (sliders) | punch coefficient %.1f on %s" % [
		Weapons.attack_power_for("sword"), Weapons.attack_power_for("shield"), Weapons.attack_power_for("bare"),
		punch.value("damage"), punch.weapon_id])
	expect(absf(Weapons.attack_power_for("sword") - 10.0) < 0.01 and absf(Weapons.attack_power_for("shield") - 6.0) < 0.01
		and absf(Weapons.attack_power_for("bare") - 1.0) < 0.01, "the_three_weapon_defs_read_their_sliders")
	var hp_before := mate.hp
	var hit := await _punch_mate()
	note("punch: %s, mate hp %.1f -> %.1f" % [hit, hp_before, mate.hp])
	expect(not hit.is_empty() and absf(float(hit.get("dealt", -1.0)) - punch.value("damage")) < 0.01
		and absf((hp_before - mate.hp) - punch.value("damage")) < 0.01, "a_bare_punch_deals_its_coefficient_times_one")
	# Bare attack power 3: the same punch deals three times as much.
	Tuning.server.weapon_attack_bare = 3.0
	await _wait(0.2)
	hp_before = mate.hp
	hit = await _punch_mate()
	note("punch with bare attack 3: %s, mate hp %.1f -> %.1f" % [hit, hp_before, mate.hp])
	expect(absf((hp_before - mate.hp) - punch.value("damage") * 3.0) < 0.01, "the_weapons_attack_power_multiplies_the_coefficient")
	Tuning.server.weapon_attack_bare = 1.0
	await _wait(0.2)
	# And the fields the table added: every skill carries them.
	var fields_ok := true
	for id in Skills.all_ids():
		var def := Skills.get_def(id)
		fields_ok = fields_ok and Weapons.is_known(def.weapon_id) and def.value("stamina_cost") >= 0.0 \
			and def.stun_on_hit >= 0.0 and def.attack_tag == SkillDef.AttackTag.PHYSICAL and not def.holy
		note("%s: weapon %s stamina %.1f stun_on_hit %.2f tag %s holy %s" % [
			id, def.weapon_id, def.value("stamina_cost"), def.stun_on_hit, SkillDef.AttackTag.keys()[def.attack_tag], def.holy])
	expect(fields_ok, "every_skill_names_a_weapon_and_carries_stamina_stun_tag_and_holy")
	expect(absf(Skills.get_def("kick").value("stamina_cost") - 7.0) < 0.01 and absf(Skills.get_def("shove").value("stamina_cost") - 6.0) < 0.01,
		"the_stamina_column_is_on_the_server_sliders")


# ------------------------------------------------------------- 5: the crit

func _crit_checks() -> void:
	await _reset_pair()
	var mate := _mate()
	var punch := Skills.get_def("punch")
	var mult: float = Tuning.server.crit_mult
	note("crit: base %.3f per agility %.4f mult %.2f; human chance %.3f" % [
		Tuning.server.crit_base, Tuning.server.crit_per_agility, mult, _judge.crit_chance(_local)])
	# Pinned always: x1.5.
	_judge.harness_pin_crit(1, 1)
	var hp_before := mate.hp
	var hit := await _punch_mate()
	note("forced crit: %s, hp %.1f -> %.1f" % [hit, hp_before, mate.hp])
	expect(bool(hit.get("crit", false)) and absf((hp_before - mate.hp) - punch.value("damage") * mult) < 0.01,
		"a_forced_crit_deals_crit_mult_times_the_damage")
	# The roll, with the dice loaded through the sliders: chance 1 always
	# crits, chance 0 never.
	_judge.harness_pin_crit(1, 0)
	var base: float = Tuning.server.crit_base
	Tuning.server.crit_base = 1.0
	await _wait(0.2)
	hit = await _punch_mate()
	var always := bool(hit.get("crit", false))
	Tuning.server.crit_base = 0.0
	await _wait(0.2)
	hit = await _punch_mate()
	var never := bool(hit.get("crit", false))
	Tuning.server.crit_base = base
	note("rolled: chance 1.0 crit=%s, chance 0.0 crit=%s" % [always, never])
	expect(always and not never, "the_server_rolls_the_chance_off_the_sliders")
	# Agility above the race's raises the chance by crit_per_agility a point.
	await tick_request(func() -> void: _judge.harness_set_points(_local, PackedInt32Array([0, 0, 100, 0, 0])))
	await _wait(0.3)
	var raised := _judge.crit_chance(_local)
	var want: float = Tuning.server.crit_base + 100.0 * Tuning.server.stat_point_weight * Tuning.server.crit_per_agility
	note("agility +%.0f: chance %.4f (formula %.4f)" % [100.0 * Tuning.server.stat_point_weight, raised, want])
	expect(absf(raised - want) < 0.0001, "agility_over_the_race_base_raises_the_chance_per_point")
	await tick_request(func() -> void: _judge.harness_set_points(_local, PackedInt32Array([0, 0, 0, 0, 0])))
	_judge.harness_pin_crit(1, -1)
	await _wait(0.3)


# ------------------------------------------------------------ 6: the armour

func _armor_checks() -> void:
	await _reset_pair()
	var mate := _mate()
	var punch := Skills.get_def("punch")
	var coef := punch.value("damage")
	# 100 armour: a 2-point punch is inside the flat band, 0 damage, no number.
	Tuning.server.armor_player = 100.0
	await _wait(0.2)
	var hp_before := mate.hp
	var numbers := _feedback.numbers
	var hit := await _punch_mate()
	note("armour 100 vs punch %.0f: %s, hp %.1f -> %.1f, numbers +%d" % [coef, hit, hp_before, mate.hp, _feedback.numbers - numbers])
	expect(absf(float(hit.get("final", -1.0))) < 0.001 and absf(mate.hp - hp_before) < 0.001, "inside_the_flat_band_the_hit_costs_nothing")
	expect(_feedback.numbers == numbers, "and_floats_no_number")
	# 20 armour: (2 - 1) x 100/120.
	Tuning.server.armor_player = 20.0
	await _wait(0.2)
	hp_before = mate.hp
	hit = await _punch_mate()
	var want := ServerAuthority.damage_after_armor(coef, 20.0)
	note("armour 20: %s, hp %.2f -> %.2f (formula %.3f)" % [hit, hp_before, mate.hp, want])
	expect(absf((hp_before - mate.hp) - want) < 0.01 and absf(float(hit.get("final", -1.0)) - want) < 0.001,
		"the_characters_armour_slider_goes_through_the_formula")
	Tuning.server.armor_player = 0.0
	# The scarecrow's own slider.
	var dummy := _world.get_node("Dummy_1") as Dummy
	var spot := dummy.global_position + Vector3(0.0, 0.0, 1.2)
	await tick_request(func() -> void:
		placed()
		_local.global_position = Vector3(spot.x, 0.9, spot.z)
		_local.velocity = Vector3.ZERO
		_local.movement.set_aim_override(dummy.global_position))
	await _wait(0.5)
	Tuning.server.armor_dummy = 20.0
	await _wait(0.2)
	var dummy_hp := dummy.hp
	var applied := _judge.hits_applied
	await tick_request(func() -> void: _local.skills.press_slot(2))
	var waited := 0.0
	while _judge.hits_applied == applied and waited < 2.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	await _wait(punch.value("recovery") + 0.3)
	note("scarecrow armour 20: %s, dummy hp %.2f -> %.2f (formula %.3f)" % [_judge.last_hit, dummy_hp, dummy.hp, want])
	expect(absf((dummy_hp - dummy.hp) - want) < 0.01, "the_scarecrows_armour_slider_goes_through_the_same_formula")
	Tuning.server.armor_dummy = 0.0
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	await _wait(0.5)


# --------------------------------- 7: one hit id, one feedback; two hits, two

func _hit_id_checks() -> void:
	var dummy := _world.get_node("Dummy_1") as Dummy
	var punch := Skills.get_def("punch")
	var spot := dummy.global_position
	await tick_request(func() -> void:
		placed()
		_local.global_position = Vector3(spot.x, 0.9, spot.z + 1.2)
		_local.velocity = Vector3.ZERO
		_local.movement.set_aim_override(dummy.global_position))
	client_park.rpc_id(_client_peer(), Vector3(spot.x + 1.2, 0.9, spot.z))
	await _wait(0.8)
	# Both peers punch the scarecrow in the same tenth of a second: two ids,
	# two feedbacks on every screen, where a time window showed one.
	_reports.erase("felt")
	client_watch_feedback.rpc_id(_client_peer(), 2.0)
	await _wait(0.3)
	var hits := _feedback.hits
	var deduped := _feedback.deduped
	var applied := _judge.hits_applied
	var ids: Array[int] = []
	client_cast_at.rpc_id(_client_peer(), dummy.global_position, 2)
	await tick_request(func() -> void: _local.skills.press_slot(2))
	var waited := 0.0
	while _judge.hits_applied < applied + 2 and waited < 2.5:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		if _judge.hits_applied > applied and not ids.has(int(_judge.last_hit["id"])):
			ids.append(int(_judge.last_hit["id"]))
	await _wait(punch.value("recovery") + 0.4)
	note("two punches on the scarecrow within %.2f s: ids %s, host feedback hits +%d deduped +%d" % [
		waited, ids, _feedback.hits - hits, _feedback.deduped - deduped])
	expect(_judge.hits_applied == applied + 2 and ids.size() == 2, "two_blows_landed_with_two_ids")
	expect(_feedback.hits - hits == 2, "the_host_screen_draws_both")
	expect(_feedback.deduped - deduped >= 1, "and_folds_only_the_same_id_told_twice")
	if await _wait_report("felt"):
		var felt: Dictionary = _reports["felt"]
		note("the client screen: %s" % [felt])
		expect(int(felt.get("hits", 0)) == 2, "the_client_screen_draws_both_too")
	# A fall carries an id of its own, so the replica draws it once.
	await _reset_pair()
	var mate := _mate()
	hits = _feedback.hits
	var fall_from := HOME + Vector3(-4.0, 9.0, 0.0)
	client_park.rpc_id(_client_peer(), fall_from)
	waited = 0.0
	while mate.hp >= mate.stats.max_hp - 0.01 and waited < 4.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	await _wait(0.5)
	note("the client dropped 9 m: hp %.1f, hit id %d damage %.1f, host feedback hits +%d" % [
		mate.hp, mate.last_hit_id(), mate.last_hit_damage(), _feedback.hits - hits])
	expect(mate.hp < mate.stats.max_hp and mate.last_hit_id() > 0 and _feedback.hits - hits == 1,
		"a_fall_carries_its_own_hit_id_and_the_other_screen_draws_it_once")


# ------------------------------- 8: HP comes off through apply_hit and nowhere else

func _bypass_checks() -> void:
	await _reset_pair()
	var mate := _mate()
	# A force with damage sent around apply_hit is stripped of it and logged.
	var hp_before := mate.hp
	var bypass := ForceSystem.make_event(ForceSystem.Kind.KNOCKBACK, Vector3.FORWARD, 0.0, 0.0, 1, false, 50.0, 0.0)
	await tick_request(func() -> void: _judge.send_force(mate, bypass))
	await _wait(0.4)
	note("a 50-damage force sent around apply_hit: mate hp %.1f -> %.1f, event damage now %.1f" % [
		hp_before, mate.hp, float(bypass.get("damage", -1.0))])
	expect(absf(mate.hp - hp_before) < 0.01 and float(bypass.get("damage", -1.0)) == 0.0,
		"a_force_that_skips_apply_hit_costs_no_hp")
	# A thrown rock's hit goes through it: raw damage, crit pinned off, armour
	# 0. The real path -- the host takes the rock and line-throws it at the
	# client -- so the rock leaves the hand the way a player's does.
	var rock := _world.get_node("Rock_0") as Rock
	await tick_request(func() -> void:
		placed()
		rock.freeze = false
		rock.global_position = _local.global_position + Vector3(0.0, -0.3, -0.9)
		rock.linear_velocity = Vector3.ZERO
		rock.angular_velocity = Vector3.ZERO)
	await _wait(0.5)
	await tick_request(func() -> void:
		_local.movement.set_aim_override(rock.global_position)
		_local.movement.interact())
	await _wait(0.5)
	expect(_local.grab.is_holding(), "the_host_took_the_rock_for_the_throw")
	# A line throw leaves the hand (~2.6 m) flat; a body 1 m away is passed
	# over the head (capsule top 1.8 m). At 5 m, gravity 22 and ~15.6 m/s, the
	# rock has dropped ~1.1 m and meets the capsule's middle.
	var throw_spot := HOME + Vector3(5.0, 0.0, 0.0)
	client_park.rpc_id(_client_peer(), throw_spot)
	await _wait(0.9)
	note("client parked for the throw at %s (sees y %.2f, %.2f m off)" % [
		throw_spot, mate.global_position.y, Vector2(mate.global_position.x - throw_spot.x, mate.global_position.z - throw_spot.z).length()])
	var applied := _judge.hits_applied
	await tick_request(func() -> void:
		_local.movement.set_aim_override(mate.global_position)
		ServerAuthority.submit_intent(_local, ServerAuthority.Intent.THROW, {
			"direction": _local.grab.throw_direction(),
			"target": _local.movement.cursor_jump_target(),
			"charge": 1.0,
			"line": true,
		}))
	# The throw itself is a hit on the rock (a line throw's damage to the
	# thrown body; a rock has no HP, dealt 0), so hits_applied moves at once.
	# The hit waited for is the rock landing on the client.
	var waited := 0.0
	var next_sample := 0.0
	while String(_judge.last_hit.get("target", "")) != mate.name and waited < 2.5:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		if waited >= next_sample and waited < 1.0:
			next_sample += 0.1
			note("  t=%.2f rock (%.2f, %.2f, %.2f) v=%.2f layer=%d | mate (%.2f, %.2f, %.2f)" % [
				waited, rock.global_position.x, rock.global_position.y, rock.global_position.z,
				rock.linear_velocity.length(), rock.collision_layer,
				mate.global_position.x, mate.global_position.y, mate.global_position.z])
	note("rock line-thrown at the client: %s (after %.2f s)" % [_judge.last_hit, waited])
	expect(_judge.hits_applied > applied and String(_judge.last_hit.get("skill", "x")) == ""
		and absf(float(_judge.last_hit.get("base", 0.0)) - Rock.HIT_DAMAGE) < 0.01
		and String(_judge.last_hit.get("target", "")) == mate.name, "a_thrown_rocks_damage_is_apply_hits_too")
	await _wait(1.0)
	await tick_request(func() -> void:
		_local.movement.set_aim_override(Vector3.INF)
		rock.linear_velocity = Vector3.ZERO
		rock.global_position = Vector3(4.0, Rock.radius_for(rock.weight) + 0.05, 6.0))


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
func client_report_vitals() -> void:
	report.rpc_id(1, "vitals", {"max_hp": _local.stats.max_hp, "max_stamina": _local.stats.max_stamina, "hp": _local.hp})


# Server -> client: how this screen computes another body's sheet.
@rpc("authority", "call_remote", "reliable")
func client_report_body(path: NodePath) -> void:
	var body := get_node_or_null(path) as Player
	if body == null:
		report.rpc_id(1, "mate_stats", {})
		return
	report.rpc_id(1, "mate_stats", {"strength": body.stats.strength, "points": body.stats.points, "max_hp": body.stats.max_hp})


# Server -> client: cast `slot` at a point.
@rpc("authority", "call_remote", "reliable")
func client_cast_at(aim: Vector3, slot: int) -> void:
	var was: bool = Tuning.values.smart_key_enabled
	Tuning.values.smart_key_enabled = true
	await tick_request(func() -> void:
		_local.movement.set_aim_override(aim)
		_local.skills.press_slot(slot))
	await _wait(0.8)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	Tuning.values.smart_key_enabled = was


@rpc("authority", "call_remote", "reliable")
func client_watch_feedback(seconds: float) -> void:
	var fb := HitFeedback.instance
	var hits := fb.hits
	var numbers := fb.numbers
	await _wait(seconds)
	report.rpc_id(1, "felt", {"hits": fb.hits - hits, "numbers": fb.numbers - numbers, "deduped": fb.deduped})


@rpc("authority", "call_remote", "reliable")
func finish(host_failures: int) -> void:
	print("C1A_RESULT peer=%d checks=%d failures=%d host_failures=%d" % [
		_peer_id, _checks, _failures, host_failures])
	get_tree().quit(0 if _failures == 0 else 1)
