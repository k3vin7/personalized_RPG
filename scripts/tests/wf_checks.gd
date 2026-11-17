extends Node

# 늑대 a: one wolf -- what the server rules and what the second screen is
# shown. How it looks and feels is the user's to try by hand.
#
#   host:   --auto-host --auto-smoke --auto-only=WF --auto-port=P --auto-quit=240
#   client: --auto-join --auto-smoke --auto-only=WF --auto-port=P --auto-quit=240
#
# The playground puts one wolf (Wolf_0) on the arena for this run. Measured:
# the numbers are the server's; it strolls near its mark; it notices a body
# inside the range, runs at it, stops, shows the path on both screens, and
# its bite costs the HP the table says (the host's body, then the client's);
# a body that steps off the path is not bitten; whoever hit it last is its
# target; a hit it holds against does not stop the bite and one past its
# tolerance does; past the leash it walks home and is deaf on the way; it
# dies to the table's count of sword thrusts; the carcass is on both screens,
# is lifted and thrown through the grab and throw doors, and is gone on time.
#
# 늑대 b adds: a body behind a wall is reached round its end (the navigation
# mesh) and not bitten through it; the way home is faster than the run and
# ends full; on the way home a blow turns it only when the hitter is inside
# the leash; it is back on its mark after wolf_respawn_time, on both screens;
# a pack (two more wolves beside it) chases what one of them was hit by or
# saw, and does not bite itself.
#
# Blows in the target and no-flinch checks are handed straight to
# ServerAuthority.apply_hit (the function under test is what the wolf does
# with one); one punch goes through the intent door to show a cast reaches it.

const STEP := 1.0 / 120.0
const FAR := Vector3(0.0, 0.0, 11.0)
const CLIENT_FAR := Vector3(-6.0, 0.0, 11.0)
const WOLF_HOME := Regions.ARENA + Vector3(-12.0, Wolf.BODY_RADIUS + 0.05, 8.0)

var _world: Node3D
var _local: Player
var _judge: ServerAuthority
var _wolf: Wolf
var _peer_id := 0
var _checks := 0
var _failures := 0
var _stage_done := ""
var _reports := {}
var _mates: Array[Wolf] = []


func expect(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("WF_CHECK peer=%d %s %s" % [_peer_id, "PASS" if condition else "FAIL", label])


func note(line: String) -> void:
	print("WF_NOTE peer=%d %s" % [_peer_id, line])


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


func _take_report(key: String, seconds := 15.0) -> Dictionary:
	var waited := 0.0
	while not _reports.has(key) and waited < seconds:
		await get_tree().create_timer(0.05).timeout
		waited += 0.05
	expect(_reports.has(key), "the_client_reported_%s" % key)
	var out: Dictionary = _reports.get(key, {})
	_reports.erase(key)
	return out


func _client_peer() -> int:
	var peers := multiplayer.get_peers()
	return peers[0] if peers.size() > 0 else 0


func _mate() -> Player:
	return _judge.actor_for(_client_peer())


func _until(test: Callable, limit: float) -> float:
	var waited := 0.0
	while waited < limit:
		if test.call():
			return waited
		await get_tree().physics_frame
		waited += STEP
	return -1.0


static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))


# A standing spot for this machine's body, `offset` from the wolf's mark.
func _by_wolf(offset: Vector3) -> Vector3:
	return Vector3(WOLF_HOME.x + offset.x, _local.half_height(), WOLF_HOME.z + offset.z)


func _stand(spot: Vector3) -> Vector3:
	return Vector3(spot.x, _local.half_height(), spot.z)


func _park(spot: Vector3) -> void:
	placed()
	await Harness.forgive_lead(get_tree(), placed)
	await tick_request(func() -> void:
		_local.global_position = spot
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target()
		_local.movement.set_aim_override(Vector3.INF))


# Both bodies out of its sight, the wolf alive, full and idle on its mark.
func _quiet() -> void:
	await _park(_stand(FAR))
	client_park.rpc_id(_client_peer(), CLIENT_FAR)
	await _wait(0.4)
	_wolf.harness_place(WOLF_HOME)
	await _wait(0.4)


func _phase_is(phase: String) -> Callable:
	return func() -> bool: return _wolf.attack_phase == phase


func _hit(attacker: Player, skill: String, direction: Vector3, extra := {}, target: Wolf = null) -> void:
	var ctx := {"direction": direction}
	ctx.merge(extra)
	var body := target if target != null else _wolf
	await tick_request(func() -> void: _judge.apply_hit(attacker, body, Skills.get_def(skill), ctx))


# Two more wolves beside the first, under the same parent: a pack. Built on
# both peers with the same names; the client's before the host's, so no
# state packet leaves for a node that is not there yet.
func _build_pack() -> void:
	for index in 2:
		var mate := (load("res://scenes/wolf.tscn") as PackedScene).instantiate() as Wolf
		mate.setup(WOLF_HOME + Vector3(-3.0, 0.0, -2.0 + 4.0 * float(index)), "Wolf_%d" % (index + 1))
		_world.add_child(mate)
		_mates.append(mate)


func run(world: Node3D) -> void:
	_world = world
	_peer_id = multiplayer.get_unique_id()
	var waited := 0.0
	while Net.spawn_root.get_node_or_null(str(_peer_id)) == null and waited < 15.0:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	_local = Net.spawn_root.get_node(str(_peer_id)) as Player
	_judge = world.get_node_or_null("ServerAuthority") as ServerAuthority
	_wolf = world.get_node_or_null("Wolf_0") as Wolf
	await _wait(1.0)
	if not multiplayer.is_server():
		stage_done.rpc_id(1, "client_ready")
		return
	expect(await _wait_stage("client_ready"), "both_peers_present")
	expect(_wolf != null, "the_wolf_is_in_the_world")
	if _wolf == null:
		finish.rpc(_failures + 1)
		get_tree().quit(1)
		return
	await _data_checks()
	await _idle_checks()
	await _bite_checks()
	await _dodge_checks()
	await _path_checks()
	await _client_bitten_checks()
	await _target_checks()
	await _no_flinch_checks()
	await _leash_checks()
	await _death_checks()
	await _pack_checks()
	print("WF_RESULT peer=%d checks=%d failures=%d" % [_peer_id, _checks, _failures])
	finish.rpc(_failures)
	await _wait(1.0)
	get_tree().quit(0 if _failures == 0 else 1)


# ------------------------------------------------------- the numbers are data

func _data_checks() -> void:
	var fields := ["wolf_aggro_range", "wolf_leash_range", "wolf_bite_start_range", "wolf_bite_range",
		"wolf_bite_width", "wolf_bite_windup", "wolf_bite_recovery", "wolf_bite_damage", "wolf_lunge_time",
		"wolf_run_speed_mult", "wolf_walk_speed_mult", "wolf_wander_radius", "wolf_wander_pause",
		"wolf_weight", "wolf_strength", "wolf_max_hp", "wolf_corpse_time",
		"wolf_return_speed_mult", "wolf_respawn_time"]
	var missing := 0
	for field: String in fields:
		if not Tuning.is_server_field(field):
			missing += 1
	expect(missing == 0, "every_wolf_number_is_a_server_field")
	var panel := _world.get_node_or_null("DebugPanel")
	var slider := panel.find_child("wolf_aggro_range", true, false) if panel != null else null
	note("debug panel slider for wolf_aggro_range: %s" % (slider != null))
	var human_hp := Races.data_for(Races.Kind.HUMAN).vitality * Tuning.server.k_hp
	note("wolf: hp %.0f, weight %.0f, strength %.0f (tolerance %.2f m/s), run %.2f m/s (human walk %.2f), bite %.1f = %.1f%% of a human's %.0f" % [
		_wolf.max_hp(), _wolf.weight(), _wolf.strength(),
		ForceSystem.tolerance_for(_wolf.strength(), 1.0), _wolf.run_speed(), Player.human_walk_speed(),
		Tuning.server.wolf_bite_damage, 100.0 * Tuning.server.wolf_bite_damage / human_hp, human_hp])
	expect(is_equal_approx(_wolf.run_speed(), Player.human_walk_speed() * 1.2), "it_runs_at_1_2_times_a_humans_walk")
	expect(is_equal_approx(_judge.weight_of(_wolf), Tuning.server.wolf_weight), "the_judge_weighs_it_at_wolf_weight")
	# A client's own write to the table changes nothing; what it holds is the push.
	client_view.rpc_id(_client_peer(), "data")
	var got := await _take_report("data")
	expect(is_equal_approx(float(got.get("max_hp", -1.0)), Tuning.server.wolf_max_hp)
		and is_equal_approx(float(got.get("weight", -1.0)), Tuning.server.wolf_weight),
		"the_client_holds_the_servers_wolf_numbers")
	expect(bool(got.get("has_wolf", false)), "the_client_has_the_wolf")


# ------------------------------------------------------------------- idle

func _idle_checks() -> void:
	await _quiet()
	var farthest := 0.0
	var travelled := 0.0
	var last := _wolf.global_position
	var modes := {}
	var waited := 0.0
	while waited < 6.0:
		await get_tree().physics_frame
		waited += STEP
		farthest = maxf(farthest, _flat(_wolf.global_position, WOLF_HOME))
		travelled += _flat(_wolf.global_position, last)
		last = _wolf.global_position
		modes[_wolf.mode] = true
	note("idle 6 s: strolled %.2f m, at most %.2f m from the mark" % [travelled, farthest])
	expect(modes.size() == 1 and modes.has(Wolf.Mode.IDLE), "nobody_near_it_stays_idle")
	expect(travelled > 0.3, "idle_it_strolls")
	expect(farthest <= Tuning.server.wolf_wander_radius + 0.5, "the_stroll_stays_inside_wolf_wander_radius")
	# A strolling body is a round trip further on by the time the client's
	# answer is back, so what the client shows is held against where the
	# server had the wolf over the round trip, not against one instant of it.
	var trail: Array[Vector3] = []
	var asked := Time.get_ticks_msec()
	client_view.rpc_id(_client_peer(), "idle")
	var back_wait := 0.0
	while not _reports.has("idle") and back_wait < 15.0:
		await get_tree().physics_frame
		back_wait += STEP
		trail.append(_wolf.global_position)
	var trip := float(Time.get_ticks_msec() - asked) / 1000.0
	var got := await _take_report("idle")
	var seen: Vector3 = got.get("wolf_at", Vector3.INF)
	var nearest := seen.distance_to(_wolf.global_position)
	for point: Vector3 in trail:
		nearest = minf(nearest, seen.distance_to(point))
	note("idle: answer back in %.2f s; the client shows it %.2f m from where the host has it now, %.2f m from where the host had it during the trip (speed now %.2f)" % [
		trip, seen.distance_to(_wolf.global_position), nearest, Vector2(_wolf.velocity.x, _wolf.velocity.z).length()])
	expect(nearest < 0.6, "the_client_shows_the_wolf_where_the_server_has_it")


# ----------------------------------------------- noticed, chased, bitten (host)

func _bite_checks() -> void:
	await _quiet()
	client_watch.rpc_id(_client_peer(), "bite_watch", 5.0)
	var hp_before := _local.hp
	var hits_before := _judge.hits_applied
	await _park(_by_wolf(Vector3(10.0, 0.0, 0.0)))
	var noticed := await _until(func() -> bool: return _wolf.mode == Wolf.Mode.CHASE, 2.0)
	expect(noticed >= 0.0 and _wolf.target_peer == 1, "a_body_inside_wolf_aggro_range_is_noticed")
	var peak := 0.0
	var waited := 0.0
	while waited < 4.0 and _wolf.attack_phase != "windup":
		await get_tree().physics_frame
		waited += STEP
		peak = maxf(peak, Vector2(_wolf.velocity.x, _wolf.velocity.z).length())
	expect(_wolf.attack_phase == "windup", "it_winds_up_a_bite")
	var gap := _flat(_wolf.global_position, _local.global_position)
	var from := _wolf.global_position
	var heading := _wolf.attack_direction()
	var host_yaw := _wolf.rotation.y
	note("chase: noticed after %.2f s, ran at %.2f m/s (run speed %.2f), stopped %.2f m from the body" % [
		noticed, peak, _wolf.run_speed(), gap])
	expect(absf(peak - _wolf.run_speed()) < 0.2, "it_chases_at_its_run_speed")
	expect(gap <= Tuning.server.wolf_bite_start_range + 0.2 and gap > Tuning.server.wolf_bite_start_range - 0.6,
		"it_stops_at_wolf_bite_start_range")
	expect(_wolf.telegraph_visible(), "the_host_screen_shows_the_path")
	var wound := await _until(_phase_is("lunge"), 1.5)
	var fill := _wolf.telegraph_fill()
	note("bite: windup %.2f s (table %.2f)" % [wound, Tuning.server.wolf_bite_windup])
	expect(absf(wound - Tuning.server.wolf_bite_windup) < 0.06, "the_windup_lasts_wolf_bite_windup")
	await _until(_phase_is("recovery"), 1.0)
	var hit := _judge.last_hit
	expect(_judge.hits_applied == hits_before + 1 and String(hit.get("target", "")) == "1"
		and String(hit.get("skill", "")) == "wolf_bite", "the_bite_is_one_apply_hit_on_the_body_in_the_path")
	expect(is_equal_approx(float(hit.get("dealt", -1.0)), Tuning.server.wolf_bite_damage)
		and is_equal_approx(_local.hp, hp_before - Tuning.server.wolf_bite_damage), "the_bite_costs_wolf_bite_damage")
	var leapt := (_wolf.global_position - from).dot(heading)
	note("bite: leapt %.2f m toward the body (stopped by it), fill at the leap %.2f" % [leapt, fill])
	expect(leapt > 0.5, "it_leaps_along_the_path")
	var rest := _wolf.global_position
	await _wait(Tuning.server.wolf_bite_recovery * 0.75)
	expect(_wolf.attack_phase == "recovery" and _flat(rest, _wolf.global_position) < 0.05,
		"it_does_not_move_through_the_recovery")
	var got := await _take_report("bite_watch")
	note("bite on the client's screen: windup seen %s, path shown %s, filled to %.2f, heading off by %.3f rad" % [
		got.get("windup", false), got.get("telegraph", false), float(got.get("fill", 0.0)),
		absf(angle_difference(float(got.get("yaw", 99.0)), host_yaw))])
	expect(bool(got.get("telegraph", false)), "the_client_screen_shows_the_path")
	expect(float(got.get("fill", 0.0)) > 0.6, "the_path_fills_on_the_client_screen")
	expect(absf(angle_difference(float(got.get("yaw", 99.0)), host_yaw)) < 0.05, "both_screens_point_the_path_the_same_way")


# -------------------------------- the path is where the body was, not where it is

func _dodge_checks() -> void:
	await _quiet()
	await _park(_by_wolf(Vector3(10.0, 0.0, 0.0)))
	expect(await _until(_phase_is("windup"), 5.0) >= 0.0, "dodge_it_winds_up")
	var from := _wolf.global_position
	var heading := _wolf.attack_direction()
	var hp_before := _local.hp
	var side := Vector3(-heading.z, 0.0, heading.x)
	await _park(_stand(_local.global_position + side * 5.0))
	await _until(_phase_is("recovery"), 2.0)
	var leapt := (_wolf.global_position - from).dot(heading)
	note("dodge: body stepped 5 m aside in the windup; hp %.0f -> %.0f; the wolf leapt %.2f m along the old heading (table %.2f)" % [
		hp_before, _local.hp, leapt, Tuning.server.wolf_bite_range])
	expect(is_equal_approx(_local.hp, hp_before), "a_body_that_left_the_path_is_not_bitten")
	expect(String(_judge.last_strike.get("skill", "")) == "wolf_bite" and int(_judge.last_strike.get("hits", -1)) == 0,
		"the_bite_was_ruled_and_reached_nobody")
	expect(absf(leapt - Tuning.server.wolf_bite_range) < 0.4, "it_leaps_wolf_bite_range_to_where_the_body_was")


# ------------------------------------------- round the wall, not through it

func _path_checks() -> void:
	await _park(_stand(FAR))
	client_park.rpc_id(_client_peer(), CLIENT_FAR)
	await _wait(0.4)
	# The wall (playground, WfWall) stands at arena x 14, z 11..18.
	var wall_x := Regions.ARENA.x + 14.0
	var wall_end := Regions.ARENA.z + 11.0
	_wolf.harness_place(Regions.ARENA + Vector3(11.5, Wolf.BODY_RADIUS + 0.05, 16.0))
	await _wait(0.4)
	var detours := _wolf.detours
	var hp_before := _local.hp
	await _park(_stand(Regions.ARENA + Vector3(17.0, 0.0, 16.0)))
	var south := _wolf.global_position.z
	var waited := 0.0
	while waited < 6.0 and _wolf.attack_phase != "windup":
		await get_tree().physics_frame
		waited += STEP
		south = minf(south, _wolf.global_position.z)
	note("path: a body 5.5 m away behind the wall; windup after %.2f s at x %.2f (wall %.1f), went as far south as z %.2f (wall end %.1f), %d path answers with a corner" % [
		waited, _wolf.global_position.x, wall_x, south, wall_end, _wolf.detours - detours])
	expect(_wolf.attack_phase == "windup", "it_reaches_a_body_behind_a_wall")
	expect(south < wall_end + 0.3 and _wolf.detours > detours, "it_went_round_the_end_of_the_wall")
	expect(_wolf.global_position.x > wall_x + 0.3, "the_bite_starts_on_the_bodys_side_of_the_wall")
	await _until(_phase_is("recovery"), 1.5)
	expect(is_equal_approx(_local.hp, hp_before - Tuning.server.wolf_bite_damage), "and_the_bite_lands_there")


# ------------------------------------------------- the client's body is bitten

func _client_bitten_checks() -> void:
	await _quiet()
	var mate := _mate()
	var hp_before := mate.hp
	client_watch.rpc_id(_client_peer(), "mate_watch", 5.0)
	client_park.rpc_id(_client_peer(), _by_wolf(Vector3(8.0, 0.0, 0.0)))
	var noticed := await _until(func() -> bool: return _wolf.target_peer == _client_peer(), 3.0)
	expect(noticed >= 0.0, "the_clients_body_is_noticed")
	await _until(_phase_is("recovery"), 6.0)
	var hit := _judge.last_hit
	expect(String(hit.get("target", "")) == str(_client_peer()) and String(hit.get("skill", "")) == "wolf_bite",
		"the_clients_body_is_bitten")
	expect(is_equal_approx(mate.hp, hp_before - Tuning.server.wolf_bite_damage), "the_server_takes_wolf_bite_damage_off_the_client")
	# Out of reach before the two HP are compared, so no second bite lands
	# between the server's number and the client's reading of it.
	client_park.rpc_id(_client_peer(), CLIENT_FAR)
	var got := await _take_report("mate_watch")
	note("client bitten: server hp %.0f -> %.0f, the client's own screen says %.0f, path shown there %s" % [
		hp_before, mate.hp, float(got.get("hp", -1.0)), got.get("telegraph", false)])
	expect(is_equal_approx(float(got.get("hp", -1.0)), mate.hp), "the_client_sees_its_own_hp_drop")
	expect(bool(got.get("telegraph", false)), "the_client_saw_the_path_of_the_bite_that_hit_it")


# ---------------------------------------------------- whoever hit it last

func _target_checks() -> void:
	await _quiet()
	# Blind while the two are put in place (the client's park is an RPC later
	# than the host's), so both are there the step it can see again.
	var aggro: float = Tuning.server.wolf_aggro_range
	Tuning.server.wolf_aggro_range = 0.0
	client_park.rpc_id(_client_peer(), _by_wolf(Vector3(7.0, 0.0, -3.0)))
	await _park(_by_wolf(Vector3(10.0, 0.0, 5.0)))
	await _until(func() -> bool: return _flat(_mate().global_position, WOLF_HOME) < 9.0, 3.0)
	Tuning.server.wolf_aggro_range = aggro
	await _until(func() -> bool: return _wolf.mode == Wolf.Mode.CHASE, 3.0)
	note("two bodies in range: it went for peer %d (the client is the nearer)" % _wolf.target_peer)
	expect(_wolf.target_peer == _client_peer(), "of_two_it_notices_the_nearer")
	await _hit(_local, "punch", Vector3(-1.0, 0.0, 0.0))
	expect(_wolf.target_peer == 1, "hit_by_the_host_it_turns_on_the_host")
	await _hit(_mate(), "punch", Vector3(-1.0, 0.0, 0.0))
	expect(_wolf.target_peer == _client_peer(), "hit_by_the_client_it_turns_on_the_client")


# ------------------------------------- hit: a slide, a launch, and no flinch

func _no_flinch_checks() -> void:
	await _quiet()
	# Blind and still, so the first blow is the only reason it moves.
	var aggro: float = Tuning.server.wolf_aggro_range
	var wander: float = Tuning.server.wolf_wander_radius
	Tuning.server.wolf_aggro_range = 0.0
	Tuning.server.wolf_wander_radius = 0.0
	await _park(_by_wolf(Vector3(1.4, 0.0, 0.0)))
	await _wait(0.5)
	expect(_wolf.mode == Wolf.Mode.IDLE, "with_no_range_a_body_beside_it_is_not_noticed")
	var hp_before := _wolf.hp
	# A cast through the intent door, like a key press.
	await tick_request(func() -> void: _judge.submit(_local, ServerAuthority.Intent.SKILL,
		{"skill": "punch", "direction": Vector3(-1.0, 0.0, 0.0)}))
	await _wait(0.6)
	var punch := Skills.get_def("punch")
	note("punch through the door: wolf hp %.0f -> %.0f (punch %.1f); target %d" % [
		hp_before, _wolf.hp, punch.value("damage"), _wolf.target_peer])
	expect(is_equal_approx(_wolf.hp, hp_before - punch.value("damage")), "a_cast_punch_takes_its_damage_off_the_wolf")
	expect(_wolf.mode == Wolf.Mode.CHASE and _wolf.target_peer == 1, "a_blow_makes_the_hitter_its_target")
	# In the windup: a thrust it holds against. No stagger -- the bite lands.
	expect(await _until(_phase_is("windup"), 4.0) >= 0.0, "flinch_it_winds_up")
	var cancelled := _judge.strikes_cancelled
	var host_hp := _local.hp
	var heading := _wolf.attack_direction()
	await _hit(_local, "thrust", -heading)
	note("thrust in the windup: launched %s, tolerance %.2f, phase %s" % [
		_wolf.last_launched, _wolf.last_tolerance, _wolf.attack_phase])
	expect(not _wolf.last_launched, "a_thrust_is_inside_its_tolerance")
	expect(_wolf.attack_phase == "windup", "a_blow_it_holds_against_does_not_end_the_windup")
	await _until(_phase_is("recovery"), 1.5)
	expect(_judge.strikes_cancelled == cancelled and is_equal_approx(_local.hp, host_hp - Tuning.server.wolf_bite_damage),
		"the_bite_still_lands_after_the_blow")
	# In the next windup: a shove, which is past it.
	expect(await _until(_phase_is("windup"), 4.0) >= 0.0, "flinch_it_winds_up_again")
	cancelled = _judge.strikes_cancelled
	host_hp = _local.hp
	heading = _wolf.attack_direction()
	var from := _wolf.global_position
	await _hit(_local, "shove", (-heading + Vector3.UP * Tuning.server.shove_up_bias).normalized(),
		{"kind": ForceSystem.Kind.SHOVE, "power": Tuning.server.shove_power})
	expect(_wolf.last_launched, "a_shove_is_past_its_tolerance")
	expect(_wolf.attack_phase == "" and _judge.strikes_cancelled == cancelled + 1, "thrown_off_its_feet_the_bite_is_cancelled")
	await _wait(0.6)
	note("shove: a 40 kg wolf lands %.2f m away" % _flat(from, _wolf.global_position))
	expect(_flat(from, _wolf.global_position) > 2.0, "a_shove_throws_the_light_body_metres")
	expect(is_equal_approx(_local.hp, host_hp), "the_cancelled_bite_costs_nothing")
	Tuning.server.wolf_aggro_range = aggro
	Tuning.server.wolf_wander_radius = wander


# --------------------------------------------------------------- the leash

func _leash_checks() -> void:
	await _quiet()
	var leash: float = Tuning.server.wolf_leash_range
	Tuning.server.wolf_leash_range = 16.0
	# 20 m is out of its sight; the blow is what starts the chase.
	await _park(_by_wolf(Vector3(20.0, 0.0, 0.0)))
	await _hit(_local, "punch", Vector3(-1.0, 0.0, 0.0))
	var hurt := _wolf.hp
	await _park(_by_wolf(Vector3(30.0, 0.0, 0.0)))
	var gave_up := await _until(func() -> bool: return _wolf.mode == Wolf.Mode.RETURN, 5.0)
	var out := _flat(_wolf.global_position, WOLF_HOME)
	note("leash 16 m: gave up after %.2f s, %.2f m from its mark, hp %.0f" % [gave_up, out, hurt])
	expect(gave_up >= 0.0 and out >= 16.0 and out < 17.0, "wolf_leash_range_from_its_mark_it_gives_up")
	await _hit(_local, "punch", Vector3(-1.0, 0.0, 0.0))
	expect(_wolf.mode == Wolf.Mode.RETURN and _wolf.target_peer == 0, "a_blow_from_outside_the_leash_does_not_turn_it")
	var peak := 0.0
	var waited := 0.0
	while waited < 6.0 and _wolf.mode != Wolf.Mode.IDLE:
		await get_tree().physics_frame
		waited += STEP
		peak = maxf(peak, Vector2(_wolf.velocity.x, _wolf.velocity.z).length())
	var back := _wolf.run_speed() * Tuning.server.wolf_return_speed_mult
	note("return: home after %.2f s at %.2f m/s (run %.2f x %.2f = %.2f), %.2f m from the mark, hp %.0f / %.0f" % [
		waited, peak, _wolf.run_speed(), Tuning.server.wolf_return_speed_mult, back,
		_flat(_wolf.global_position, WOLF_HOME), _wolf.hp, _wolf.max_hp()])
	expect(_wolf.mode == Wolf.Mode.IDLE and _flat(_wolf.global_position, WOLF_HOME) <= Wolf.HOME_RADIUS + 0.3, "it_goes_back_to_its_mark")
	expect(absf(peak - back) < 0.3, "it_goes_home_at_wolf_return_speed_mult_times_its_run")
	expect(hurt < _wolf.max_hp() and is_equal_approx(_wolf.hp, _wolf.max_hp()), "home_it_is_full_again")
	# Again, and this time the hitter stands inside the leash.
	await _park(_by_wolf(Vector3(20.0, 0.0, 0.0)))
	await _hit(_local, "punch", Vector3(-1.0, 0.0, 0.0))
	await _park(_by_wolf(Vector3(30.0, 0.0, 0.0)))
	await _until(func() -> bool: return _wolf.mode == Wolf.Mode.RETURN, 5.0)
	await _park(_by_wolf(Vector3(10.0, 0.0, 4.0)))
	var still_going := _wolf.mode == Wolf.Mode.RETURN
	await _hit(_local, "punch", Vector3(-1.0, 0.0, 0.0))
	note("return, hitter 10.8 m from the mark (leash 16): was going home %s, after the blow mode %s target %d" % [
		still_going, Wolf.Mode.keys()[_wolf.mode], _wolf.target_peer])
	expect(still_going, "going_home_it_does_not_notice_a_body_by_sight")
	expect(_wolf.mode == Wolf.Mode.CHASE and _wolf.target_peer == 1, "a_blow_from_inside_the_leash_turns_it_round")
	Tuning.server.wolf_leash_range = leash


# ----------------------------------------------------- death and the carcass

func _death_checks() -> void:
	await _quiet()
	var aggro: float = Tuning.server.wolf_aggro_range
	var keep: float = Tuning.server.wolf_corpse_time
	var again: float = Tuning.server.wolf_respawn_time
	Tuning.server.wolf_aggro_range = 0.0
	Tuning.server.wolf_corpse_time = 8.0
	Tuning.server.wolf_respawn_time = 13.0
	await _park(_by_wolf(Vector3(3.0, 0.0, 0.0)))
	var thrusts := 0
	while _wolf.hp > 0.0 and thrusts < 10:
		await _hit(_local, "thrust", Vector3(-1.0, 0.0, 0.0))
		thrusts += 1
		await _wait(0.3)
	var died_at := Time.get_ticks_msec()
	note("death: %d sword thrusts (%.0f each) for %.0f hp" % [
		thrusts, Skills.get_def("thrust").value("damage") * Weapons.attack_power_for("sword"), _wolf.max_hp()])
	expect(thrusts >= 3 and thrusts <= 4, "three_or_four_sword_thrusts_kill_it")
	await _wait(0.3)
	var body := _wolf.corpse()
	expect(_wolf.is_dead() and not _wolf.visible and _wolf.collision_layer == 0, "at_0_hp_the_wolf_is_gone")
	expect(not _wolf.is_in_group(ServerAuthority.HOLDABLE_GROUP), "a_dead_wolf_is_not_a_body_to_hold")
	expect(body != null and body is Rock and body.is_in_group(ServerAuthority.HOLDABLE_GROUP)
		and body.collision_layer == Layers.THROWABLE, "a_carcass_lies_there_and_it_is_a_rock")
	if body == null:
		Tuning.server.wolf_aggro_range = aggro
		Tuning.server.wolf_corpse_time = keep
		return
	expect(is_equal_approx(_judge.weight_of(body), Tuning.server.wolf_weight), "the_carcass_weighs_wolf_weight")
	await _wait(0.6)
	client_view.rpc_id(_client_peer(), "dead")
	var got := await _take_report("dead")
	var seen: Vector3 = got.get("corpse_at", Vector3.INF)
	note("dead on the client's screen: wolf shown %s, carcass there %s, %.2f m from the server's" % [
		got.get("wolf_visible", true), got.get("has_corpse", false), seen.distance_to(body.global_position)])
	expect(not bool(got.get("wolf_visible", true)), "the_client_no_longer_shows_the_wolf")
	expect(bool(got.get("has_corpse", false)) and seen.distance_to(body.global_position) < 0.6,
		"the_client_shows_the_carcass_where_the_server_has_it")
	# A dead wolf does nothing.
	Tuning.server.wolf_aggro_range = aggro
	var bites := _wolf.bites_started
	var host_hp := _local.hp
	await _park(_stand(_wolf.global_position + Vector3(2.0, 0.0, 2.0)))
	await _wait(1.5)
	expect(_wolf.bites_started == bites and is_equal_approx(_local.hp, host_hp), "a_dead_wolf_bites_nobody")
	# Lifted and thrown through the same doors as a rock.
	await _park(_stand(body.global_position + Vector3(1.0, 0.0, 0.0)))
	await _wait(0.3)
	await tick_request(func() -> void: _judge.submit(_local, ServerAuthority.Intent.GRAB, {"target": body.get_path()}))
	await _wait(0.4)
	expect(_judge.holder_of(body) == 1, "the_grab_door_lifts_the_carcass")
	client_view.rpc_id(_client_peer(), "held")
	got = await _take_report("held")
	expect(int(got.get("corpse_holder", -1)) == 1, "the_clients_hold_table_has_the_carcass_in_the_hosts_hands")
	var from := _local.global_position
	await tick_request(func() -> void: _judge.submit(_local, ServerAuthority.Intent.THROW,
		{"direction": Vector3(1.0, 0.0, 0.0), "charge": 1.0, "line": true}))
	await _wait(1.5)
	note("carcass thrown: %.2f m from the thrower" % (_flat(from, body.global_position) if is_instance_valid(body) else -1.0))
	expect(is_instance_valid(body) and _judge.holder_of(body) == 0 and _flat(from, body.global_position) > 3.0,
		"the_throw_door_throws_the_carcass")
	# And gone on time, on both screens.
	var gone := await _until(func() -> bool: return _wolf.corpse() == null, 12.0)
	var lay := float(Time.get_ticks_msec() - died_at) / 1000.0
	note("carcass gone %.2f s after the death (table %.1f)" % [lay, Tuning.server.wolf_corpse_time])
	expect(gone >= 0.0 and absf(lay - Tuning.server.wolf_corpse_time) < 1.0, "the_carcass_is_gone_after_wolf_corpse_time")
	await _wait(0.5)
	client_view.rpc_id(_client_peer(), "gone")
	got = await _take_report("gone")
	expect(not bool(got.get("has_corpse", true)), "the_carcass_is_gone_on_the_client_too")
	Tuning.server.wolf_corpse_time = keep
	# Back on its mark. Nobody near, so it is found idle.
	await _park(_stand(FAR))
	var back := await _until(func() -> bool: return not _wolf.is_dead(), 10.0)
	var dead_for := float(Time.get_ticks_msec() - died_at) / 1000.0
	note("respawn: back %.2f s after the death (table %.1f), %.2f m from its mark, hp %.0f / %.0f" % [
		dead_for, Tuning.server.wolf_respawn_time, _flat(_wolf.global_position, WOLF_HOME), _wolf.hp, _wolf.max_hp()])
	expect(back >= 0.0 and absf(dead_for - Tuning.server.wolf_respawn_time) < 1.0, "it_is_back_after_wolf_respawn_time")
	expect(_flat(_wolf.global_position, WOLF_HOME) < 0.5 and is_equal_approx(_wolf.hp, _wolf.max_hp())
		and _wolf.mode == Wolf.Mode.IDLE, "on_its_mark_full_and_idle")
	await _wait(0.6)
	expect(_wolf.visible and _wolf.collision_layer == Layers.DUMMY and _wolf.is_in_group(ServerAuthority.HOLDABLE_GROUP),
		"and_a_body_again")
	client_view.rpc_id(_client_peer(), "back")
	got = await _take_report("back")
	var shown: Vector3 = got.get("wolf_at", Vector3.INF)
	note("respawn on the client's screen: shown %s, %.2f m from the server's" % [
		got.get("wolf_visible", false), shown.distance_to(_wolf.global_position)])
	expect(bool(got.get("wolf_visible", false)) and shown.distance_to(_wolf.global_position) < 0.6,
		"the_client_shows_it_again_where_the_server_has_it")
	Tuning.server.wolf_respawn_time = again


# ------------------------------------------------------------------ the pack

func _pack_checks() -> void:
	await _quiet()
	client_build_pack.rpc_id(_client_peer())
	expect(await _wait_stage("pack_built"), "the_client_built_the_pack")
	_build_pack()
	await _wait(0.6)
	expect(_wolf.pack().size() == 2, "three_wolves_under_one_parent_are_a_pack")
	var aggro: float = Tuning.server.wolf_aggro_range
	var wander: float = Tuning.server.wolf_wander_radius
	Tuning.server.wolf_wander_radius = 0.0
	# Seen by one: 11.5 m from the first, 14.6 m from the two behind it.
	await _park(_by_wolf(Vector3(11.5, 0.0, 0.0)))
	await _until(func() -> bool: return _wolf.mode == Wolf.Mode.CHASE, 2.0)
	await get_tree().physics_frame
	note("pack, seen by one: modes %s / %s / %s, targets %d / %d / %d" % [
		Wolf.Mode.keys()[_wolf.mode], Wolf.Mode.keys()[_mates[0].mode], Wolf.Mode.keys()[_mates[1].mode],
		_wolf.target_peer, _mates[0].target_peer, _mates[1].target_peer])
	expect(_mates[0].mode == Wolf.Mode.CHASE and _mates[1].mode == Wolf.Mode.CHASE
		and _mates[0].target_peer == 1 and _mates[1].target_peer == 1, "what_one_sees_the_pack_chases")
	# Three wolves biting one body for a while: none of them bites a wolf.
	var host_hp := _local.hp
	await _wait(4.0)
	var whole := is_equal_approx(_wolf.hp, _wolf.max_hp()) and is_equal_approx(_mates[0].hp, _mates[0].max_hp()) \
		and is_equal_approx(_mates[1].hp, _mates[1].max_hp())
	note("pack, 4 s on one body: host hp %.0f -> %.0f, wolves %.0f / %.0f / %.0f" % [
		host_hp, _local.hp, _wolf.hp, _mates[0].hp, _mates[1].hp])
	expect(_local.hp < host_hp, "the_pack_bites_the_body")
	expect(whole, "the_pack_does_not_bite_itself")
	# Hit by another: the whole pack turns on the hitter, seen or not.
	Tuning.server.wolf_aggro_range = 0.0
	await _hit(_mate(), "punch", Vector3(-1.0, 0.0, 0.0), {}, _mates[0])
	note("pack, one hit by the client: targets %d / %d / %d" % [_wolf.target_peer, _mates[0].target_peer, _mates[1].target_peer])
	expect(_wolf.target_peer == _client_peer() and _mates[0].target_peer == _client_peer()
		and _mates[1].target_peer == _client_peer(), "what_hits_one_the_pack_chases")
	Tuning.server.wolf_aggro_range = aggro
	Tuning.server.wolf_wander_radius = wander


# ------------------------------------------------------------------ the wire

@rpc("any_peer", "call_remote", "reliable")
func stage_done(name_text: String) -> void:
	if multiplayer.is_server() and multiplayer.get_peers().has(multiplayer.get_remote_sender_id()):
		_stage_done = name_text


@rpc("any_peer", "call_remote", "reliable")
func report(key: String, value: Variant) -> void:
	if multiplayer.is_server() and multiplayer.get_peers().has(multiplayer.get_remote_sender_id()):
		_reports[key] = value


@rpc("authority", "call_remote", "reliable")
func client_build_pack() -> void:
	_build_pack()
	stage_done.rpc_id(1, "pack_built")


@rpc("authority", "call_remote", "reliable")
func client_park(point: Vector3) -> void:
	await _park(_stand(point))


# Server -> client: what this screen shows right now.
@rpc("authority", "call_remote", "reliable")
func client_view(key: String) -> void:
	var body := _wolf.corpse() if _wolf != null else null
	report.rpc_id(1, key, {
		"has_wolf": _wolf != null,
		"max_hp": Tuning.server.wolf_max_hp,
		"weight": Tuning.server.wolf_weight,
		"wolf_at": _wolf.global_position if _wolf != null else Vector3.INF,
		"wolf_visible": _wolf.visible if _wolf != null else false,
		"phase": _wolf.attack_phase if _wolf != null else "",
		"has_corpse": body != null,
		"corpse_at": body.global_position if body != null else Vector3.INF,
		"corpse_holder": _judge.holder_of(body) if body != null and _judge != null else -1,
		"hp": _local.hp,
	})


# Server -> client: this screen's wolf watched for `seconds`.
@rpc("authority", "call_remote", "reliable")
func client_watch(key: String, seconds: float) -> void:
	var out := {"windup": false, "telegraph": false, "fill": 0.0, "yaw": 99.0}
	var waited := 0.0
	while waited < seconds and _wolf != null:
		await get_tree().process_frame
		waited += get_process_delta_time()
		if _wolf.attack_phase == "windup":
			out["windup"] = true
		if _wolf.telegraph_visible():
			out["telegraph"] = true
			out["fill"] = maxf(float(out["fill"]), _wolf.telegraph_fill())
			out["yaw"] = _wolf.rotation.y
	out["hp"] = _local.hp
	report.rpc_id(1, key, out)


@rpc("authority", "call_remote", "reliable")
func finish(host_failures: int) -> void:
	print("WF_RESULT peer=%d checks=%d failures=%d host_failures=%d" % [
		_peer_id, _checks, _failures, host_failures])
	get_tree().quit(0 if _failures == 0 else 1)
