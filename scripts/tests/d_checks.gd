extends Node

# Stage D, measured: the shove as a rectangle, in the air, with a recoil; v4's
# knockback tolerance; a team mate launched off a push; a head as a platform; and the two
# things the work order asks for beside them -- whether the 5 m gap can be
# crossed by two players together, and how far a dash jump reaches.

const HOME := Vector3(0.0, 0.9, 11.0)
const LANE := Vector3(-13.0, 0.9, 9.0)
# The 5 m gap: lane x = 15, near lip z = -2, far block from z = -7.
# The 5 m gap, in the obstacle course (Regions.OBSTACLE).
const GAP5_LANE := 15.0 + Regions.OBSTACLE.x
const GAP5_START := Vector3(GAP5_LANE, 0.9, -1.2)
const GAP5_FAR := -7.0

var _world: Node3D
var _local: Player
var _judge: ServerAuthority
var _peer_id := 0
var _checks := 0
var _failures := 0
var _reports := {}
var _stage_done := ""
var _lag := 0.0
var _label := "0"
var _reported := {}
var _hits := 0


func expect(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("D_CHECK lag=%s peer=%d %s %s" % [_label, _peer_id, "PASS" if condition else "FAIL", label])


func note(line: String) -> void:
	print("D_NOTE lag=%s peer=%d %s" % [_label, _peer_id, line])


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


# For sampling a body on this machine, where the wire is not involved: padding
# these by the latency means reading a body that has already landed.
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


func run(world: Node3D) -> void:
	_world = world
	_peer_id = multiplayer.get_unique_id()
	_local = Net.spawn_root.get_node(str(_peer_id)) as Player
	_judge = world.get_node_or_null("ServerAuthority") as ServerAuthority
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--d-latency="):
			_label = argument.trim_prefix("--d-latency=")
			_lag = _label.to_float() / 1000.0
	if not multiplayer.is_server():
		stage_done.rpc_id(1, "client_ready")
		return
	expect(await _wait_stage("client_ready"), "both_peers_present")
	var warnings := _judge.move_warnings
	var corrections := _judge.move_corrections
	await _event_shape_checks()
	await _rectangle_checks()
	await _air_and_recoil_checks()
	await _tolerance_checks()
	await _race_table_checks()
	await _lift_angle_checks()
	await _race_mult_authority_checks()
	await _ally_launch_checks()
	await _dummy_air_check()
	await _head_platform_checks()
	await _gap5_coop_check()
	await _dash_jump_range_check()
	expect(_judge.move_warnings == warnings, "no_move_warnings_during_stage_d")
	expect(_judge.move_corrections == corrections, "no_corrections_during_stage_d")
	print("D_RESULT lag=%s peer=%d checks=%d failures=%d" % [_label, _peer_id, _checks, _failures])
	finish.rpc(_failures)
	await _wait(1.0)
	get_tree().quit(0 if _failures == 0 else 1)


# -------------------------------------- the event: an id, a time, a recoil kind

func _event_shape_checks() -> void:
	var event := ForceSystem.make_event(
		ForceSystem.Kind.RECOIL, Vector3.RIGHT, 1.0, 10.0, 1, true)
	var second := ForceSystem.make_event(
		ForceSystem.Kind.SHOVE, Vector3.RIGHT, 1.0, 10.0, 1, true)
	note("event ids %d then %d, at %.2f s, RECOIL=%d" % [
		event["id"], second["id"], event["at"], ForceSystem.Kind.RECOIL])
	expect(int(second["id"]) > int(event["id"]) and int(event["id"]) > 0, "every_event_has_its_own_id")
	expect(float(event["at"]) > 0.0, "and_the_time_it_was_made")
	var before := _judge.force_history.size()
	await tick_request(func() -> void:
		_judge.send_force(_local, ForceSystem.make_event(
			ForceSystem.Kind.KNOCKBACK, Vector3.UP, 1.0, 0.0, 1, true)))
	await _wait(0.3)
	expect(_judge.force_history.size() > before, "the_server_keeps_a_history_of_what_it_sent")
	var last: Dictionary = _judge.force_history[_judge.force_history.size() - 1]
	note("history tail: id=%d at=%.2f kind=%d target=%s" % [
		last["id"], last["at"], last["kind"], last["target"]])
	expect(int(last["id"]) > 0 and float(last["at"]) > 0.0, "history_rows_carry_the_id_and_the_time")


# ------------------------------------------------- the rectangle, not the fan

func _place_pair(gap: Vector3) -> Player:
	var mate := _judge.actor_for(_client_peer())
	_judge.forgive_move(_client_peer(), "")
	client_park.rpc_id(_client_peer(), LANE + gap)
	await _wait_stage("parked")
	await _wait(0.6)
	await tick_request(func() -> void:
		placed()
		_judge.server_respawn(_local)
		_local.global_position = LANE
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target())
	await _wait(0.8)
	return mate


# Shoves east and reports whether the other body was pushed.
func _shove_east(mate: Player) -> Dictionary:
	var hp_before := mate.hp
	var stood := mate.global_position
	await tick_request(func() -> void:
		_local.movement.set_aim_override(_local.global_position + Vector3(4.0, 0.0, 0.0))
		_hits = _local.movement.shove())
	await _wait(0.8)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	return {
		"hits": _hits,
		"moved": Vector2(mate.global_position.x - stood.x, mate.global_position.z - stood.z).length(),
		"hp": hp_before - mate.hp,
	}


func _rectangle_checks() -> void:
	# Straight ahead, inside the rectangle.
	var mate := await _place_pair(Vector3(1.0, 0.0, 0.0))
	var ahead := await _shove_east(mate)
	note("rectangle: 1.0 m straight ahead -> hits=%d moved %.2f m" % [ahead["hits"], ahead["moved"]])
	expect(int(ahead["hits"]) >= 1, "a_body_in_front_is_in_the_rectangle")
	await _wait(Tuning.server.shove_cooldown + 0.4)

	# Off to the side by more than half the width: a fan would still have had
	# it, a rectangle does not.
	var aside: float = Tuning.server.shove_width * 0.5 + Player.BODY_RADIUS + 0.7
	mate = await _place_pair(Vector3(0.9, 0.0, aside))
	var beside := await _shove_east(mate)
	note("rectangle: 0.9 m ahead and %.2f m to the side -> hits=%d moved %.2f m (width %.2f)" % [
		aside, beside["hits"], beside["moved"], Tuning.server.shove_width])
	expect(int(beside["hits"]) == 0, "a_body_off_to_the_side_is_outside_it")
	await _wait(Tuning.server.shove_cooldown + 0.4)

	# Past the far end.
	mate = await _place_pair(Vector3(Tuning.server.shove_range + Player.BODY_RADIUS + 1.0, 0.0, 0.0))
	var far := await _shove_east(mate)
	note("rectangle: past the end -> hits=%d (range %.2f)" % [far["hits"], Tuning.server.shove_range])
	expect(int(far["hits"]) == 0, "a_body_past_the_end_is_outside_it")
	await _wait(Tuning.server.shove_cooldown + 0.4)


# ------------------------------------------- in the air, and what it costs

func _air_and_recoil_checks() -> void:
	var mate := await _place_pair(Vector3(1.0, 0.0, 0.0))
	# Pushed off the ground first, so the shove is thrown from mid-air.
	await tick_request(func() -> void:
		_judge.send_force(_local, ForceSystem.make_event(
			ForceSystem.Kind.THROW, Vector3.UP, 9.0, 0.0, 1, true)))
	await _beat(0.15)
	var airborne := _local.state == Player.State.AIRBORNE
	var speed_before := Vector2(_local.velocity.x, _local.velocity.z).length()
	var air := await _shove_east(mate)
	note("in the air: was airborne=%s hits=%d, mate moved %.2f m" % [
		airborne, air["hits"], air["moved"]])
	expect(airborne, "the_pusher_was_off_the_ground")
	expect(int(air["hits"]) >= 1, "a_shove_goes_out_in_the_air")
	await _wait(1.5)

	# The recoil: the same push, backwards, as its own event.
	await _wait(Tuning.server.shove_cooldown + 0.4)
	mate = await _place_pair(Vector3(1.0, 0.0, 0.0))
	var recoils := 0
	for row in _judge.force_history:
		if int(row["kind"]) == ForceSystem.Kind.RECOIL:
			recoils += 1
	var pushed_from := _local.global_position
	await tick_request(func() -> void:
		_local.movement.set_aim_override(_local.global_position + Vector3(4.0, 0.0, 0.0))
		_hits = _local.movement.shove())
	await _wait(0.1)
	var kick := Vector2(_local.velocity.x, _local.velocity.z).length()
	await _wait(0.7)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	var after := 0
	for row in _judge.force_history:
		if int(row["kind"]) == ForceSystem.Kind.RECOIL:
			after += 1
	var slid := _local.global_position.x - pushed_from.x
	note("recoil: %d -> %d events, pusher speed %.2f, slid %.2f m back (shove_recoil %.2f)" % [
		recoils, after, kick, slid, Tuning.server.shove_recoil])
	expect(after > recoils, "the_push_cost_the_pusher_a_force_event")
	expect(slid < 0.0, "and_pushed_it_backwards")
	await _wait(Tuning.server.shove_cooldown + 0.4)


# ------------------------------------------- v4's knockback tolerance (H-2)

func _tolerance_checks() -> void:
	# Same weight, two very different strengths. v4 took the target's strength
	# out of the distance entirely -- it buys a tolerance, not a shorter slide
	# -- so the two have to land on the same number. The check this replaces
	# asserted the opposite, which is what v4 changed.
	var mate := await _place_pair(Vector3(1.0, 0.0, 0.0))
	_judge.harness_set_stats(mate, 60.0, 80.0)
	await _wait(0.5)
	var weak := await _shove_east(mate)
	var weak_knock: Dictionary = _judge.last_knock.get(_client_peer(), {}).duplicate()
	await _wait(Tuning.server.shove_cooldown + 0.6)
	mate = await _place_pair(Vector3(1.0, 0.0, 0.0))
	_judge.harness_set_stats(mate, 120.0, 80.0)
	await _wait(0.5)
	var strong := await _shove_east(mate)
	var strong_knock: Dictionary = _judge.last_knock.get(_client_peer(), {}).duplicate()
	note("same weight 80kg: strength 60 moved %.2f m (h_speed %.2f vs tolerance %.2f), strength 120 moved %.2f m (h_speed %.2f vs tolerance %.2f)" % [
		weak["moved"], float(weak_knock.get("h_speed", 0.0)), float(weak_knock.get("tolerance", 0.0)),
		strong["moved"], float(strong_knock.get("h_speed", 0.0)), float(strong_knock.get("tolerance", 0.0))])
	expect(absf(float(weak_knock.get("h_speed", 0.0)) - float(strong_knock.get("h_speed", 0.0))) < 0.01,
		"the_same_weight_is_given_the_same_dv_whatever_its_strength")
	expect(absf(float(weak["moved"]) - float(strong["moved"])) < 0.25,
		"and_moves_the_same_distance")
	_judge.harness_clear_stats(mate)
	await _wait(Tuning.server.shove_cooldown + 0.5)

	# A slide: inside the tolerance, so no stun, and the damage is taken all
	# the same. 결정 2, measured rather than read.
	mate = await _place_pair(Vector3(1.0, 0.0, 0.0))
	_judge.harness_set_stats(mate, 150.0, 80.0)
	await _wait(0.5)
	var slid := await _shove_east(mate)
	var slid_knock: Dictionary = _judge.last_knock.get(_client_peer(), {}).duplicate()
	note("inside the tolerance: h_speed %.2f <= %.2f, verdict=%s, moved %.2f m, hp -%.0f, state %s" % [
		float(slid_knock.get("h_speed", 0.0)), float(slid_knock.get("tolerance", 0.0)),
		"launched" if bool(slid_knock.get("launched", true)) else "slid",
		slid["moved"], slid["hp"], Player.State.keys()[mate.state]])
	expect(not bool(slid_knock.get("launched", true)), "a_push_inside_the_tolerance_is_a_slide")
	expect(mate.state != Player.State.STUNNED, "a_body_that_slid_is_not_stunned")
	expect(mate.state != Player.State.AIRBORNE, "and_stays_on_the_ground")
	expect(float(slid["hp"]) > 0.0, "and_still_takes_the_damage")
	_judge.harness_clear_stats(mate)
	await _wait(Tuning.server.shove_cooldown + 0.5)

	# And a launch: over the tolerance, off the ground, stunned.
	mate = await _place_pair(Vector3(1.0, 0.0, 0.0))
	_judge.harness_set_stats(mate, 1.0, 80.0)
	await _wait(0.5)
	var hurled := await _shove_east(mate)
	var hurled_knock: Dictionary = _judge.last_knock.get(_client_peer(), {}).duplicate()
	note("over the tolerance: h_speed %.2f > %.2f, verdict=%s, moved %.2f m, state %s, y %.2f" % [
		float(hurled_knock.get("h_speed", 0.0)), float(hurled_knock.get("tolerance", 0.0)),
		"launched" if bool(hurled_knock.get("launched", true)) else "slid",
		hurled["moved"], Player.State.keys()[mate.state], mate.global_position.y])
	expect(bool(hurled_knock.get("launched", false)), "a_push_over_the_tolerance_is_a_launch")
	expect(float(hurled["moved"]) > float(slid["moved"]), "and_goes_further_than_the_slide")
	_judge.harness_clear_stats(mate)
	await _wait(Tuning.server.shove_cooldown + 0.5)

	# The recoil goes through the same comparison. It is the one force a body
	# asks to be given, so it is the one that could have grown an exception.
	var recoil: Dictionary = _judge.last_knock.get(1, {})
	note("the pusher's own recoil: kind=%d h_speed %.2f vs tolerance %.2f -> %s" % [
		int(recoil.get("kind", -1)), float(recoil.get("h_speed", 0.0)),
		float(recoil.get("tolerance", 0.0)),
		"launched" if bool(recoil.get("launched", true)) else "slid"])
	expect(int(recoil.get("kind", -1)) == ForceSystem.Kind.RECOIL,
		"the_recoil_went_through_the_tolerance_comparison")

	# A client cannot state its own verdict. ForceSystem only believes peer 1,
	# so a forged event aimed at the host's body is dropped at the door.
	mate = await _place_pair(Vector3(1.0, 0.0, 0.0))
	var stood := _local.global_position
	var before := int((_judge.last_knock.get(1, {}) as Dictionary).get("id", 0))
	client_forge_force.rpc_id(_client_peer(), _local.get_path())
	await _wait(0.8)
	var after := int((_judge.last_knock.get(1, {}) as Dictionary).get("id", 0))
	var shifted := Vector2(_local.global_position.x - stood.x, _local.global_position.z - stood.z).length()
	note("a client's forged force event: host moved %.2f m, last verdict id %d -> %d" % [
		shifted, int(before), int(after)])
	expect(shifted < 0.3, "a_forged_force_from_a_client_moves_nobody")
	expect(int(before) == int(after), "and_no_verdict_was_made_for_it")
	await _wait(0.4)


# The work order's 4x4: every race pushing every race, with the dv, the
# tolerance and the verdict. Measured rather than worked out, because the dv
# depends on the pusher's strength over the target's whole weight and that is
# the sum the table exists to show.
func _race_table_checks() -> void:
	var rows := PackedStringArray()
	var launched_any := false
	var slid_any := false
	for pusher in Races.all_kinds():
		for target in Races.all_kinds():
			var mate := await _place_pair(Vector3(1.0, 0.0, 0.0))
			_judge.harness_set_race(_local, pusher)
			_judge.harness_set_race(mate, target)
			await _wait(0.5)
			var hit := await _shove_east(mate)
			var knock: Dictionary = _judge.last_knock.get(_client_peer(), {})
			var launched := bool(knock.get("launched", true))
			launched_any = launched_any or launched
			slid_any = slid_any or not launched
			rows.append("%s -> %s: dv %.2f, tolerance %.2f, %s, moved %.2f m" % [
				Races.label_for(pusher), Races.label_for(target),
				float(knock.get("h_speed", 0.0)), float(knock.get("tolerance", 0.0)),
				"튕겨나감" if launched else "미끄러짐", hit["moved"]])
			await _wait(Tuning.server.shove_cooldown + 0.4)
	for row in rows:
		note("table " + row)
	expect(rows.size() == 16, "the_four_by_four_table_is_complete")
	expect(launched_any and slid_any, "the_table_has_both_verdicts_in_it")
	_judge.harness_set_race(_local, Races.DEFAULT)
	_judge.harness_set_race(_judge.actor_for(_client_peer()), Races.DEFAULT)
	await _wait(0.6)


# The lift angle: a force aimed knock_lift_angle_deg or more above the
# horizontal is a lift and is applied whole; below it, the tolerance applies.
func _lift_angle_checks() -> void:
	await _place_pair(Vector3(1.0, 0.0, 0.0))
	var steep_deg: float = Tuning.server.knock_lift_angle_deg + 15.0
	var steep := deg_to_rad(steep_deg)
	await tick_request(func() -> void:
		_judge.send_force(_local, ForceSystem.make_event(
			ForceSystem.Kind.THROW, Vector3(cos(steep), sin(steep), 0.0), 6.0, 0.0, 1, true)))
	await _beat(0.15)
	var lifted: Dictionary = (_judge.last_knock.get(1, {}) as Dictionary).duplicate()
	var airborne := _local.state == Player.State.AIRBORNE
	note("lift at %.0f deg: judged=%s h_speed %.2f vs tolerance %.2f, airborne=%s (knock_lift_angle_deg %.0f)" % [
		steep_deg, bool(lifted.get("judged", true)),
		float(lifted.get("h_speed", 0.0)), float(lifted.get("tolerance", 0.0)),
		airborne, Tuning.server.knock_lift_angle_deg])
	expect(not bool(lifted.get("judged", true)), "a_force_above_the_lift_angle_is_not_judged")
	expect(airborne, "and_lifts_the_body_whole")
	await _wait(1.6)
	await _place_pair(Vector3(1.0, 0.0, 0.0))
	var shallow_deg: float = Tuning.server.knock_lift_angle_deg - 15.0
	var shallow := deg_to_rad(shallow_deg)
	await tick_request(func() -> void:
		_judge.send_force(_local, ForceSystem.make_event(
			ForceSystem.Kind.THROW, Vector3(cos(shallow), sin(shallow), 0.0), 4.0, 0.0, 1, true)))
	await _beat(0.15)
	var pushed: Dictionary = (_judge.last_knock.get(1, {}) as Dictionary).duplicate()
	note("push at %.0f deg: judged=%s h_speed %.2f vs tolerance %.2f -> %s, state %s" % [
		shallow_deg, bool(pushed.get("judged", false)),
		float(pushed.get("h_speed", 0.0)), float(pushed.get("tolerance", 0.0)),
		"launched" if bool(pushed.get("launched", true)) else "slid",
		Player.State.keys()[_local.state]])
	expect(bool(pushed.get("judged", false)), "a_force_below_the_lift_angle_is_judged")
	expect(not bool(pushed.get("launched", true)), "and_this_one_was_a_slide")
	await _wait(1.0)


# The race multipliers are the server's. The real path -- a client's slider,
# an intent, the ruling, the table pushed back -- and the forged one.
func _race_mult_authority_checks() -> void:
	var mate := _judge.actor_for(_client_peer())
	var before := _local.get_move_speed()
	_reports.erase("race_mult")
	client_ask_race_mult.rpc_id(_client_peer(), "move", Races.Kind.HUMAN, 1.5)
	var waited := 0.0
	while not _reports.has("race_mult") and waited < 10.0 + _lag * 20.0:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	var after := _local.get_move_speed()
	note("race_move_mult[human] asked 1.5 by the client: server table %.2f, client table %s, host human move %.3f -> %.3f" % [
		_judge.race_move_mult(Races.Kind.HUMAN), str(_reports.get("race_mult", "none")), before, after])
	expect(is_equal_approx(_judge.race_move_mult(Races.Kind.HUMAN), 1.5), "the_server_took_the_race_multiplier")
	expect(_reports.has("race_mult") and is_equal_approx(float(_reports.get("race_mult", 0.0)), 1.5),
		"and_the_client_sees_the_servers_table")
	expect(mate != null and _local.stats.race == Races.Kind.HUMAN and absf(after - before * 1.5) < 0.01,
		"and_a_human_walks_at_the_multiplied_speed")

	# Forged: the client pushes a table of its own. Refused at the door.
	client_forge_race_mult.rpc_id(_client_peer())
	await _wait(0.8)
	note("a client's forged race table: server tolerance[human] %.2f, move[human] %.2f" % [
		_judge.race_tolerance_mult(Races.Kind.HUMAN), _judge.race_move_mult(Races.Kind.HUMAN)])
	var untouched := is_equal_approx(_judge.race_tolerance_mult(Races.Kind.HUMAN), 1.0)
	var kept := is_equal_approx(_judge.race_move_mult(Races.Kind.HUMAN), 1.5)
	expect(untouched and kept, "a_forged_race_table_from_a_client_is_refused")
	ServerAuthority.submit_intent(_local, ServerAuthority.Intent.RACE_MULT, {
		"field": "move", "race": Races.Kind.HUMAN, "value": 1.0})
	await _wait(0.6)
	expect(is_equal_approx(_local.get_move_speed(), before), "and_the_table_went_back_to_one")


@rpc("authority", "call_remote", "reliable")
func client_ask_race_mult(field: String, race: int, value: float) -> void:
	ServerAuthority.submit_intent(_local, ServerAuthority.Intent.RACE_MULT, {
		"field": field, "race": race, "value": value})
	await _wait(1.0)
	var mine := ServerAuthority.instance.race_tolerance_mult(race)
	if field == "move":
		mine = ServerAuthority.instance.race_move_mult(race)
	report_number.rpc_id(1, "race_mult", mine)


@rpc("authority", "call_remote", "reliable")
func client_forge_race_mult() -> void:
	var nines := PackedFloat32Array([9.0, 9.0, 9.0, 9.0])
	ServerAuthority.instance.push_race_mults.rpc_id(1, nines, nines)


@rpc("any_peer", "call_remote", "reliable")
func report_number(key: String, value: float) -> void:
	if multiplayer.is_server():
		_reports[key] = value


# Sent from the client on purpose: a hand-made event, with a verdict in it, at
# a body the client does not own.
@rpc("authority", "call_remote", "reliable")
func client_forge_force(path: NodePath) -> void:
	var event := ForceSystem.make_event(
		ForceSystem.Kind.SHOVE, Vector3(1.0, 0.0, 0.0), 40.0, 999.0,
		multiplayer.get_unique_id(), false, 0.0, 0.0)
	event["knock_launched"] = false
	event["knock_h_speed"] = 0.0
	event["knock_tolerance"] = 999.0
	ForceSystem.receive_force.rpc_id(1, path, event)


# ------------------------------------- a jumping team mate is a step, not a target

func _ally_launch_checks() -> void:
	# A team mate in the air: launched up and away, and it costs them nothing.
	Tuning.server.same_party = true
	var mate := await _place_pair(Vector3(1.0, 0.0, 0.0))
	client_jump.rpc_id(_client_peer())
	await _wait_stage("jumped")
	var hp_before := mate.hp
	var from := mate.global_position
	await tick_request(func() -> void:
		_local.movement.set_aim_override(_local.global_position + Vector3(4.0, 0.0, 0.0))
		_hits = _local.movement.shove())
	# Read before the landing. The push costs a team mate nothing; coming down
	# from five metres is a fall, and falls are charged for by anyone's rules.
	await _wait(0.35)
	var hp_after_push := mate.hp
	var peak := mate.global_position.y
	var sampled := 0.0
	while sampled < 2.5:
		await get_tree().physics_frame
		sampled += get_physics_process_delta_time()
		peak = maxf(peak, mate.global_position.y)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	var flew := Vector2(mate.global_position.x - from.x, mate.global_position.z - from.z).length()
	note("ally in the air: hits=%d peak %.2f m (from %.2f), flew %.2f m, hp %.0f -> %.0f on the push -> %.0f after landing (angle %.0f)" % [
		_hits, peak, from.y, flew, hp_before, hp_after_push, mate.hp,
		Tuning.server.shove_ally_launch_angle_deg])
	expect(_hits >= 1 and peak > from.y + 0.3, "a_team_mate_in_the_air_is_launched_upward")
	expect(hp_after_push == hp_before, "and_the_push_itself_costs_them_nothing")
	await _wait(Tuning.server.shove_cooldown + 1.2)

	# The same push with the party toggle off: this one hurts.
	Tuning.server.same_party = false
	mate = await _place_pair(Vector3(1.0, 0.0, 0.0))
	client_jump.rpc_id(_client_peer())
	await _wait_stage("jumped")
	hp_before = mate.hp
	await tick_request(func() -> void:
		_local.movement.set_aim_override(_local.global_position + Vector3(4.0, 0.0, 0.0))
		_hits = _local.movement.shove())
	await _wait(0.8)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	note("not a team mate, in the air: hits=%d hp %.0f -> %.0f" % [_hits, hp_before, mate.hp])
	expect(_hits >= 1 and mate.hp < hp_before, "someone_who_is_not_a_team_mate_takes_the_damage")
	Tuning.server.same_party = true
	await _wait(Tuning.server.shove_cooldown + 1.0)


# ---------------------------------------------- the scarecrow, in the air

func _dummy_air_check() -> void:
	var dummy := _world.get_node("Dummy_0") as Dummy
	await tick_request(func() -> void:
		placed()
		_judge.server_respawn(_local)
		_local.global_position = dummy.global_position - Vector3(1.0, 0.1, 0.0))
	await _wait(0.6)
	# Up first, then sideways while it is still off the ground: the second push
	# has to bend the arc rather than replace it.
	await tick_request(func() -> void:
		_judge.send_force(dummy, ForceSystem.make_event(
			ForceSystem.Kind.THROW, Vector3.UP, 9.0, 0.0, 1, false)))
	await _beat(0.15)
	var rising := dummy.velocity.y
	await tick_request(func() -> void:
		_judge.send_force(dummy, ForceSystem.make_event(
			ForceSystem.Kind.SHOVE, Vector3.RIGHT, 6.0, 0.0, 1, false)))
	await get_tree().physics_frame
	var after := dummy.velocity
	note("scarecrow in the air: rising %.2f, after a sideways push velocity=(%.2f, %.2f, %.2f)" % [
		rising, after.x, after.y, after.z])
	expect(rising > 1.0, "the_scarecrow_was_in_the_air")
	expect(after.y > 1.0 and after.x > 1.0, "a_push_in_the_air_is_added_not_written_over")
	await _wait(2.0)


# ------------------------------------------------- a head is a surface

func _head_platform_checks() -> void:
	var mate := await _place_pair(Vector3(0.0, 0.0, 0.0))
	# Standing on their head: placed there, which is what landing on one ends
	# up as anyway.
	await tick_request(func() -> void:
		placed()
		_local.global_position = mate.global_position + Vector3(0.0, Player.BODY_HALF_HEIGHT * 2.0 + 0.05, 0.0)
		_local.velocity = Vector3.ZERO
		_local.floor_snap_length = 0.0
		_local.change_state(Player.State.AIRBORNE))
	var stood := false
	var waited := 0.0
	while waited < 1.5 and not stood:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		stood = _local.is_grounded_state() and _local.global_position.y > mate.global_position.y + 1.0
	note("head: stood on it=%s after %.2fs at y=%.2f (mate at %.2f)" % [
		stood, waited, _local.global_position.y, mate.global_position.y])
	expect(stood, "a_head_can_be_stood_on")
	if not stood:
		return
	# And jumped off again.
	var from_y := _local.global_position.y
	await tick_request(func() -> void:
		_local.movement.set_aim_override(_local.global_position)
		_local.movement.cast_jump())
	var peak := from_y
	var sampled := 0.0
	while sampled < 1.2:
		await get_tree().physics_frame
		sampled += get_physics_process_delta_time()
		peak = maxf(peak, _local.global_position.y)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	note("head: jumped off it, %.2f -> peak %.2f (+%.2f)" % [from_y, peak, peak - from_y])
	expect(peak > from_y + 1.0, "and_jumped_off_it_again")
	await _wait(1.5)

	# But not lived on: head_stomp_time and the body slides off.
	await tick_request(func() -> void:
		placed()
		_local.global_position = mate.global_position + Vector3(0.0, Player.BODY_HALF_HEIGHT * 2.0 + 0.05, 0.0)
		_local.velocity = Vector3.ZERO
		_local.floor_snap_length = 0.0
		_local.change_state(Player.State.AIRBORNE))
	var landed_at := 0.0
	var left_at := 0.0
	sampled = 0.0
	while sampled < Tuning.server.head_stomp_time + 2.0:
		await get_tree().physics_frame
		sampled += get_physics_process_delta_time()
		if landed_at == 0.0 and _local.is_grounded_state():
			landed_at = sampled
		elif landed_at > 0.0 and left_at == 0.0 and _local.state == Player.State.AIRBORNE:
			left_at = sampled
	note("head: stood for %.2f s then came off (head_stomp_time %.2f)" % [
		maxf(left_at - landed_at, 0.0), Tuning.server.head_stomp_time])
	expect(left_at > landed_at, "a_head_is_a_step_not_a_perch")
	await _wait(1.5)


# ------------------------- the 5 m gap, which one body cannot cross alone

func _gap5_coop_check() -> void:
	# Alone first: the jump is aimed across and falls short, which is the
	# premise the work order sets.
	await tick_request(func() -> void:
		placed()
		_judge.server_respawn(_local)
		_local.global_position = GAP5_START
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target())
	await _wait(0.8)
	await tick_request(func() -> void:
		_local.movement.set_aim_override(Vector3(GAP5_LANE, 0.9, GAP5_FAR - 0.5))
		_local.movement.cast_jump())
	await _wait(2.5)
	var alone := _local.global_position
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	var alone_crossed := alone.z < GAP5_FAR and alone.y > -1.0
	note("5 m gap alone: landed z=%.2f y=%.2f crossed=%s" % [alone.z, alone.y, alone_crossed])
	expect(not alone_crossed, "the_five_metre_gap_is_not_crossed_alone")

	# Together: the client jumps across and the host shoves it on the way.
	var mate := _judge.actor_for(_client_peer())
	# The pusher stands behind, the team mate at the lip. The mate jumps
	# straight up -- not across -- and the push is what sends it, which is the
	# whole point of the launch angle. A mate that jumps away first is out of
	# the rectangle before anyone can reach it.
	await tick_request(func() -> void:
		placed()
		_judge.server_respawn(_local)
		_local.global_position = Vector3(GAP5_LANE, 0.9, -0.3))
	_judge.forgive_move(_client_peer(), "")
	client_park.rpc_id(_client_peer(), Vector3(GAP5_LANE, 0.9, -1.2))
	await _wait_stage("parked")
	await _wait(0.8)
	var from := mate.global_position
	client_jump.rpc_id(_client_peer())
	# Pushed the moment it is off the ground, while it is still in reach.
	var pushed := false
	var sampled := 0.0
	var peak := from.y
	while sampled < 4.0:
		await get_tree().physics_frame
		sampled += get_physics_process_delta_time()
		peak = maxf(peak, mate.global_position.y)
		if not pushed and mate.state == Player.State.AIRBORNE:
			pushed = true
			_local.movement.set_aim_override(_local.global_position + Vector3(0.0, 0.0, -4.0))
			_hits = _local.movement.shove()
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	await _wait(1.0)
	var landed := mate.global_position
	var crossed := landed.z < GAP5_FAR and landed.y > -1.0
	note("5 m gap together: pushed=%s hits=%d peak %.2f, landed z=%.2f y=%.2f, flew %.2f m toward the gap, crossed=%s (far edge %.1f, launch angle %.0f, spring = the mate's own jump)" % [
		pushed, _hits, peak, landed.z, landed.y, from.z - landed.z, crossed, GAP5_FAR,
		Tuning.server.shove_ally_launch_angle_deg])
	expect(pushed and _hits >= 1, "the_jumping_team_mate_was_pushed")
	# Reported either way: whether a push is enough to carry a body over a gap
	# it cannot jump is a tuning answer, and this is the measurement for it.
	expect(true, "the_five_metre_coop_crossing_was_measured")
	await tick_request(func() -> void:
		_judge.server_respawn(_local)
		placed())
	await _wait(1.0)

	# Pushed late in the arc instead of at the start. A nudge added to whatever
	# the body was already doing would send it a different distance; a spring
	# that replaces the vertical with the body's own jump sends it the same one,
	# which is what makes this work at a latency at all.
	await tick_request(func() -> void:
		placed()
		_judge.server_respawn(_local)
		_local.global_position = Vector3(GAP5_LANE, 0.9, -0.3))
	_judge.forgive_move(_client_peer(), "", 30)
	client_park.rpc_id(_client_peer(), Vector3(GAP5_LANE, 0.9, -1.2))
	await _wait_stage("parked")
	await _wait(0.8)
	var late_from := mate.global_position
	client_jump.rpc_id(_client_peer())
	var late_pushed := false
	var late_peak := late_from.y
	var waited := 0.0
	while waited < 4.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		late_peak = maxf(late_peak, mate.global_position.y)
		# Deliberately late: a third of a second after it left the ground.
		if not late_pushed and mate.state == Player.State.AIRBORNE and waited > 0.35:
			late_pushed = true
			_local.movement.set_aim_override(_local.global_position + Vector3(0.0, 0.0, -4.0))
			_hits = _local.movement.shove()
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	await _wait(1.0)
	var late_flew := late_from.z - mate.global_position.z
	var late_crossed: bool = mate.global_position.z < GAP5_FAR and mate.global_position.y > -1.0
	note("5 m gap, pushed late in the arc: pushed=%s hits=%d peak %.2f (early push %.2f), flew %.2f m (early %.2f), landed z=%.2f y=%.2f crossed=%s" % [
		late_pushed, _hits, late_peak, peak, late_flew, from.z - landed.z,
		mate.global_position.z, mate.global_position.y, late_crossed])
	expect(late_pushed, "the_late_push_went_out")
	# Compared as distance flown, not as the peak. The spring gives the same
	# launch wherever it lands, so what follows the push is the same arc -- but
	# it starts from wherever the body had got to, so a late push peaks higher
	# simply by starting higher. What a player cares about is whether they get
	# across, and that is the distance.
	expect(absf(late_flew - (from.z - landed.z)) < 1.5, "pushing_late_in_the_arc_carries_the_same_distance")
	expect(late_crossed, "and_the_late_push_crosses_too")
	await tick_request(func() -> void:
		_judge.server_respawn(_local)
		placed())
	await _wait(1.0)


# ----------------------------------------- how far a dash jump reaches

func _dash_jump_range_check() -> void:
	await tick_request(func() -> void:
		placed()
		_judge.server_respawn(_local)
		_local.global_position = HOME
		_local.velocity = Vector3.ZERO
		_local.stamina = _local.stats.max_stamina
		_local.movement.cancel_target())
	await _wait(0.8)
	var from := _local.global_position
	await tick_request(func() -> void:
		_local.movement.set_aim_override(from + Vector3(12.0, 0.0, 0.0))
		_local.movement.request_dash())
	await get_tree().create_timer(0.06).timeout
	await tick_request(func() -> void: _local.movement.press_jump())
	# Two distances, because they answer different questions: how far the leap
	# itself went, and how far the whole move covered. Only the first one is
	# the budget's business.
	var launch := Vector3.ZERO
	var left_ground := Vector3.ZERO
	var sampled := 0.0
	while sampled < 3.0:
		await get_tree().physics_frame
		sampled += get_physics_process_delta_time()
		if launch == Vector3.ZERO and _local.state == Player.State.AIRBORNE:
			launch = _local.velocity
			left_ground = _local.global_position
		if launch != Vector3.ZERO and _local.is_grounded_state():
			break
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	var whole := Vector2(_local.global_position.x - from.x, _local.global_position.z - from.z).length()
	var leap := Vector2(_local.global_position.x - left_ground.x, _local.global_position.z - left_ground.z).length()
	var jump_reach := _local.leap_max_range()
	note("dash jump: leap itself %.2f m from where the feet left the ground, whole move %.2f m from the dash's start | launch %.2f (cap %.2f), plain jump reach %.2f m, dash reach %.2f m" % [
		leap, whole, launch.length(), _local.leap_speed_cap(), jump_reach,
		_local.movement.dash_max_distance()])
	expect(launch.length() <= _local.leap_speed_cap() + 0.4, "the_dash_jump_launch_is_inside_the_budget")
	# The leap is a leap: no dash speed survives into it.
	expect(leap <= jump_reach + 0.5, "the_leap_out_of_a_dash_is_no_longer_than_any_other_leap")
	expect(whole > leap, "but_the_whole_move_covers_more_because_the_dash_came_first")

	# And the 5 m gap stays uncrossable alone, dash or no dash: the dash can
	# carry a body to the lip, and the leap from there is still just a leap.
	await tick_request(func() -> void:
		placed()
		_judge.server_respawn(_local)
		# South of SmoothWall (x 13..19, z 1.7..2.3), which the dash used to
		# start pressed against -- it ended on the wall in the first frame and
		# the body never moved.
		_local.global_position = Vector3(GAP5_LANE, 0.9, 1.0)
		_local.velocity = Vector3.ZERO
		_local.stamina = _local.stats.max_stamina
		_local.movement.cancel_target())
	# The cooldown from the dash above has to run out, or the dash is refused
	# and the body never leaves the mark -- which would pass this check for
	# doing nothing at all.
	await get_tree().create_timer(Tuning.server.dash_cooldown + 0.3).timeout
	var started_at := _local.global_position.z
	_hits = 0
	await tick_request(func() -> void:
		_local.movement.set_aim_override(Vector3(GAP5_LANE, 0.9, -1.4))
		_hits = 1 if _local.movement.request_dash() else 0)
	# Jumped at the lip, which is the best a single body can do.
	var dashed := 0.0
	while dashed < 1.0 and _local.global_position.z > -1.0:
		await get_tree().physics_frame
		dashed += get_physics_process_delta_time()
	note("dash to the lip: accepted=%d z %.2f -> %.2f (grounded=%s stamina=%.0f)" % [
		_hits, started_at, _local.global_position.z,
		_local.is_grounded_state(), _local.stamina])
	expect(_hits == 1 and _local.global_position.z < started_at - 2.0, "the_dash_to_the_lip_actually_ran")
	await tick_request(func() -> void:
		_local.movement.set_aim_override(Vector3(GAP5_LANE, 0.9, GAP5_FAR - 0.5))
		_local.movement.press_jump())
	await _beat(2.6)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	var landed := _local.global_position
	var crossed := landed.z < GAP5_FAR and landed.y > -1.0
	note("5 m gap with a dash jump, alone: landed z=%.2f y=%.2f crossed=%s (far edge %.1f)" % [
		landed.z, landed.y, crossed, GAP5_FAR])
	expect(not crossed, "the_five_metre_gap_is_not_crossed_alone_even_with_a_dash")
	await tick_request(func() -> void:
		_judge.server_respawn(_local)
		placed())
	await _wait(1.0)


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
func client_jump() -> void:
	await tick_request(func() -> void:
		_local.movement.set_aim_override(_local.global_position)
		_local.movement.cast_jump())
	var waited := 0.0
	while waited < 1.0 and _local.state != Player.State.AIRBORNE:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	stage_done.rpc_id(1, "jumped")


@rpc("authority", "call_remote", "reliable")
func client_gap_jump(target: Vector3) -> void:
	await tick_request(func() -> void:
		_local.movement.set_aim_override(target)
		_local.movement.cast_jump())
	await _wait(0.5)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))


@rpc("authority", "call_remote", "reliable")
func finish(host_failures: int) -> void:
	print("D_RESULT lag=%s peer=%d checks=%d failures=%d host_failures=%d" % [
		_label, _peer_id, _checks, _failures, host_failures])
	get_tree().quit(0 if _failures == 0 else 1)
