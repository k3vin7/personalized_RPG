extends Node

# 임시 캐릭터 a: the floating hands and the sword -- what cannot be read off
# the screen by eye: that the blade is where the ruling is, frame by frame,
# that a slider on the ruling moves the hand, and that the other screen
# replays the same motion off the phase stamp it already gets.
#
#   host:   --auto-host --auto-smoke --auto-only=HA --auto-port=P --auto-quit=120
#   client: --auto-join --auto-smoke --auto-only=HA --auto-port=P --auto-quit=120
#
# The host's body casts; the host watches its own body and the client watches
# its copy of it. Measured per frame of a strike: the blade's angle against
# SkillDef.swing_angle_deg at the swing's progress, the tip's distance from
# the strike centre against the skill's reach, and (host) the picture's
# clock against the server's sweep clock. The parry's success is handed to
# the owner by hand (on_parry_result), since what is measured is the flick
# reaching the other screen, not the parry ruling.

const SPOT := Vector3(0.0, 0.0, 11.0)
const CLIENT_SPOT := Vector3(-6.0, 0.0, 11.0)
const SWORD_SLOTS := {"thrust": 0, "side_cut": 1, "overhead_cut": 2, "parry": 3}

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
	print("HA_CHECK peer=%d %s %s" % [_peer_id, "PASS" if condition else "FAIL", label])


func note(line: String) -> void:
	print("HA_NOTE peer=%d %s" % [_peer_id, line])


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


func _park(spot: Vector3) -> void:
	placed()
	await Harness.forgive_lead(get_tree(), placed)
	await tick_request(func() -> void:
		_local.global_position = Vector3(spot.x, _local.half_height(), spot.z)
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target()
		_local.movement.set_aim_override(_local.global_position + Vector3(5.0, 0.0, 0.0)))


# One body's hands, every rendered frame for `seconds`.
func _watch(body: Player, def: SkillDef, seconds: float) -> Dictionary:
	var out := {"modes": {}, "frames": 0, "angle_err": 0.0, "tip_err": 0.0, "angle_min": 999.0,
		"angle_max": -999.0, "tip_forward": 0.0, "start_gap": -1.0, "rest_gap": -1.0, "trail": 0,
		"clock_off": 0.0, "delay": 0.0}
	var hands := body.hands
	if hands == null:
		return out
	var pivot := hands.strike_pivot(def)
	var reach := def.value("reach")
	var last_windup := Transform3D.IDENTITY
	var had_windup := false
	var waited := 0.0
	while waited < seconds:
		await get_tree().process_frame
		waited += get_process_delta_time()
		(out["modes"] as Dictionary)[PlayerHands.Mode.keys()[hands.mode]] = true
		out["trail"] = maxi(int(out["trail"]), body.trail_sample_count())
		var pose := hands.main.transform
		if hands.mode == PlayerHands.Mode.WINDUP:
			last_windup = pose
			had_windup = true
		if hands.mode != PlayerHands.Mode.STRIKE or body.swing_progress() < 0.0:
			continue
		if had_windup and float(out["start_gap"]) < 0.0:
			# How far the windup left the hand from where the strike begins.
			out["start_gap"] = last_windup.origin.distance_to(hands.strike_pose(def, 0.0).origin)
		if hands.is_catching_up():
			# Another screen's late start, being carried onto the line.
			out["caught_up"] = true
			continue
		out["frames"] = int(out["frames"]) + 1
		var p := body.swing_progress()
		var blade := -pose.basis.z
		var tip := pose.origin + blade * hands.blade_length()
		if def.is_thrust_motion():
			out["tip_forward"] = maxf(float(out["tip_forward"]), -tip.z)
			out["tip_err"] = maxf(float(out["tip_err"]), absf(tip.x) + absf(tip.y - pivot.y))
		else:
			var angle := rad_to_deg(atan2(-blade.x, -blade.z)) if def.arc_plane == SkillDef.ArcPlane.HORIZONTAL \
				else rad_to_deg(atan2(blade.y, -blade.z))
			out["angle_err"] = maxf(float(out["angle_err"]), absf(angle_difference(deg_to_rad(angle), deg_to_rad(def.swing_angle_deg(p)))) * 180.0 / PI)
			out["angle_min"] = minf(float(out["angle_min"]), angle)
			out["angle_max"] = maxf(float(out["angle_max"]), angle)
			out["tip_err"] = maxf(float(out["tip_err"]), absf(tip.distance_to(pivot) - reach))
		# The server's sweep clock against the picture's, on the judging peer.
		if _judge != null and _judge.is_judge() and _judge.sweep_in_progress(body):
			var record: Dictionary = _judge._active_sweeps[body]
			var server_p := float(Time.get_ticks_msec() - int(record["start_ms"])) / 1000.0 / maxf(def.swing_time(), 0.001)
			if server_p <= 1.0:
				out["clock_off"] = maxf(float(out["clock_off"]), absf(server_p - p) * def.swing_time())
	out["rest_gap"] = hands.main.transform.origin.distance_to(hands.rest_main().origin)
	out["delay"] = body.last_remote_phase_delay
	return out


# The blade's angle in the pose the strike ends on.
func hands_end_angle(def: SkillDef) -> float:
	var blade := -_local.hands.strike_pose(def, 1.0).basis.z
	if def.arc_plane == SkillDef.ArcPlane.HORIZONTAL:
		return rad_to_deg(atan2(-blade.x, -blade.z))
	return rad_to_deg(atan2(blade.y, -blade.z))


func _cast(skill: String) -> void:
	await tick_request(func() -> void: _local.skills.cast_slot(int(SWORD_SLOTS[skill])))


func run(world: Node3D) -> void:
	_world = world
	_peer_id = multiplayer.get_unique_id()
	var waited := 0.0
	while Net.spawn_root.get_node_or_null(str(_peer_id)) == null and waited < 15.0:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	_local = Net.spawn_root.get_node(str(_peer_id)) as Player
	_judge = world.get_node_or_null("ServerAuthority") as ServerAuthority
	await _wait(1.0)
	if not multiplayer.is_server():
		await _park(CLIENT_SPOT)
		stage_done.rpc_id(1, "client_ready")
		return
	expect(await _wait_stage("client_ready"), "both_peers_present")
	await _park(SPOT)
	await tick_request(func() -> void: _local.set_weapon(WeaponKinds.Kind.SWORD))
	waited = 0.0
	while _local.weapon != WeaponKinds.Kind.SWORD and waited < 2.0:
		await get_tree().physics_frame
		waited += 1.0 / 120.0
	await _wait(0.5)
	await _look_checks()
	for skill: String in ["side_cut", "overhead_cut", "thrust"]:
		await _strike_checks(skill, "")
	await _slider_checks()
	await _parry_checks()
	print("HA_RESULT peer=%d checks=%d failures=%d" % [_peer_id, _checks, _failures])
	finish.rpc(_failures)
	await _wait(1.0)
	get_tree().quit(0 if _failures == 0 else 1)


func _look_checks() -> void:
	var hands := _local.hands
	expect(not _local.visual.model_loaded() and _local.drawn_as_capsule(), "no_model_the_capsule_is_drawn")
	expect(hands != null and hands.main != null and hands.off != null, "two_hands")
	if hands == null:
		return
	var sword := hands.main.get_node_or_null("HeldWeapon")
	var rest := hands.rest_main().origin
	note("rest: main hand at %s (body radius %.2f, half height %.2f), sword in it %s, blade %.2f m" % [
		rest, _local.radius(), _local.half_height(), sword != null, hands.blade_length()])
	expect(sword != null, "the_sword_is_in_the_main_hand")
	expect(absf(rest.x) > _local.radius() and rest.z < 0.0 and rest.y > 0.0 and rest.y < _local.half_height() * 0.5,
		"a_hand_rests_beside_the_body_a_little_forward_between_waist_and_chest")
	client_view.rpc_id(_client_peer(), "look")
	var got := await _take_report("look")
	expect(bool(got.get("hands", false)) and bool(got.get("sword", false)) and not bool(got.get("model", true)),
		"the_client_draws_the_hosts_body_the_same_way")


# One cast, watched on both screens. `tag` names a second run of the same skill.
func _strike_checks(skill: String, tag: String) -> void:
	var def := Skills.get_def(skill)
	var key := skill + tag
	var seconds := def.value("windup") + def.value("recovery") + 0.9
	client_watch.rpc_id(_client_peer(), key, skill, seconds + 0.4)
	await _wait(0.2)
	_cast(skill)
	var mine := await _watch(_local, def, seconds)
	var theirs := await _take_report(key)
	var reach := def.value("reach")
	for row: Array in [["host", mine], ["client", theirs]]:
		var who: String = row[0]
		var got: Dictionary = row[1]
		var modes: Dictionary = got.get("modes", {})
		if def.is_thrust_motion():
			note("%s %s screen: frames %d, tip went %.3f m out (reach %.2f), off the line %.3f m, windup left the hand %.3f m short, back at rest %.3f m, modes %s, phase delay %.3f s" % [
				key, who, got.get("frames", 0), float(got.get("tip_forward", 0.0)), reach, float(got.get("tip_err", 9.0)),
				float(got.get("start_gap", -1.0)), float(got.get("rest_gap", 9.0)), modes.keys(), float(got.get("delay", 0.0))])
			expect(absf(float(got.get("tip_forward", 0.0)) - reach) < 0.03, "%s_%s_the_tip_ends_at_the_reach" % [key, who])
			expect(float(got.get("tip_err", 9.0)) < 0.01, "%s_%s_the_blade_stays_on_the_heading" % [key, who])
		else:
			note("%s %s screen: frames %d, blade angle off the ruling's by at most %.2f deg, tip off the reach by %.3f m, swept %.0f..%.0f deg (ruling %.0f..%.0f), trail %d, windup left the hand %.3f m short, back at rest %.3f m, modes %s, clock off the server's %.3f s, phase delay %.3f s, late start carried %s" % [
				key, who, got.get("frames", 0), float(got.get("angle_err", 999.0)), float(got.get("tip_err", 9.0)),
				float(got.get("angle_min", 0.0)), float(got.get("angle_max", 0.0)),
				minf(def.arc_start(), def.arc_end()), maxf(def.arc_start(), def.arc_end()), got.get("trail", 0),
				float(got.get("start_gap", -1.0)), float(got.get("rest_gap", 9.0)), modes.keys(),
				float(got.get("clock_off", 0.0)), float(got.get("delay", 0.0)), got.get("caught_up", false)])
			expect(float(got.get("angle_err", 999.0)) < 0.5, "%s_%s_the_blade_is_at_the_rulings_angle_every_frame" % [key, who])
			expect(float(got.get("tip_err", 9.0)) < 0.01, "%s_%s_the_tip_is_on_the_edge_of_the_range" % [key, who])
			# The far end is reached, to within the last rendered frame of the
			# swing: the frame that reaches it also ends the strike, so the last
			# one seen is a frame short (5 degrees of 240 at 15% of the time left).
			expect(absf(float(got.get("angle_max" if def.arc_sign() > 0.0 else "angle_min", 999.0)) - def.arc_end()) < 10.0,
				"%s_%s_the_sweep_ends_at_the_end_of_the_arc" % [key, who])
			expect(int(got.get("trail", 0)) >= 2, "%s_%s_the_blade_leaves_an_afterimage" % [key, who])
		expect(int(got.get("frames", 0)) >= 3, "%s_%s_the_strike_is_shown" % [key, who])
		expect(modes.has("WINDUP") and modes.has("STRIKE") and modes.has("RETURN"), "%s_%s_windup_strike_and_return_are_all_shown" % [key, who])
		expect(float(got.get("rest_gap", 9.0)) < 0.05, "%s_%s_the_hand_is_back_at_rest" % [key, who])
	if not def.is_thrust_motion():
		expect(absf(hands_end_angle(def) - def.arc_end()) < 0.01, "%s_the_last_pose_is_the_end_of_the_arc" % key)
		# The picture's clock starts on the owner's physics tick and runs on
		# rendered frames; the server's starts at its booked millisecond. On
		# the judging peer the two are within a few frames (measured 0.009 to
		# 0.033 s over nine swings); more than that would be a different clock.
		expect(float(mine.get("clock_off", 9.0)) < 0.05, "%s_the_pictures_clock_is_the_servers_sweep_clock" % key)
	await _wait(0.4)


# A slider on the ruling moves the hand: a longer, narrower side cut.
func _slider_checks() -> void:
	var reach: float = Tuning.server.side_cut_range
	var arc: float = Tuning.server.side_cut_arc_deg
	Tuning.server.side_cut_range = 2.4
	Tuning.server.side_cut_arc_deg = 120.0
	await _wait(0.8)
	var def := Skills.get_def("side_cut")
	note("sliders: side_cut_range %.1f -> 2.4, side_cut_arc_deg %.0f -> 120 (arc %.0f..%.0f)" % [reach, arc, def.arc_start(), def.arc_end()])
	await _strike_checks("side_cut", "_slid")
	Tuning.server.side_cut_range = reach
	Tuning.server.side_cut_arc_deg = arc
	await _wait(0.5)


func _parry_checks() -> void:
	var def := Skills.get_def("parry")
	_cast("parry")
	await _wait(0.2)
	var hands := _local.hands
	var stance := hands.guard_pose(def, 0.0)
	note("parry: mode %s, hand %.3f m from the stance, blade stood %.0f deg up" % [
		PlayerHands.Mode.keys()[hands.mode], hands.main.transform.origin.distance_to(stance.origin),
		rad_to_deg(asin(clampf((-hands.main.transform.basis.z).y, -1.0, 1.0)))])
	expect(hands.mode == PlayerHands.Mode.GUARD and hands.main.transform.origin.distance_to(stance.origin) < 0.05,
		"the_parry_stands_the_blade_in_front_of_the_body")
	client_view.rpc_id(_client_peer(), "guard")
	var got := await _take_report("guard")
	expect(String(got.get("mode", "")) == "GUARD", "the_client_shows_the_stance")
	await _wait(def.value("recovery") + 0.4)
	expect(hands.mode == PlayerHands.Mode.REST, "a_parry_that_turned_nothing_goes_back_to_rest")
	# Again, and this time the owner is told it turned a blow.
	await _wait(def.value("cooldown") + 0.2)
	client_watch.rpc_id(_client_peer(), "flick", "parry", 1.5)
	await _wait(0.2)
	_cast("parry")
	await _wait(0.15)
	await tick_request(func() -> void: _local.skills.on_parry_result(true))
	var mine := await _watch(_local, def, 1.0)
	var theirs := await _take_report("flick")
	note("parry success: host modes %s, client modes %s" % [(mine["modes"] as Dictionary).keys(), (theirs.get("modes", {}) as Dictionary).keys()])
	expect((mine["modes"] as Dictionary).has("FLICK"), "a_parry_that_turned_a_blow_flicks")
	expect((theirs.get("modes", {}) as Dictionary).has("FLICK"), "and_the_client_sees_the_flick")
	expect(float(mine.get("rest_gap", 9.0)) < 0.05, "and_the_hand_is_back_at_rest")


# ------------------------------------------------------------------ the wire

@rpc("any_peer", "call_remote", "reliable")
func stage_done(name_text: String) -> void:
	if multiplayer.is_server() and multiplayer.get_peers().has(multiplayer.get_remote_sender_id()):
		_stage_done = name_text


@rpc("any_peer", "call_remote", "reliable")
func report(key: String, value: Variant) -> void:
	if multiplayer.is_server() and multiplayer.get_peers().has(multiplayer.get_remote_sender_id()):
		_reports[key] = value


func _host_body() -> Player:
	return Net.spawn_root.get_node_or_null("1") as Player


@rpc("authority", "call_remote", "reliable")
func client_view(key: String) -> void:
	var body := _host_body()
	var hands := body.hands if body != null else null
	report.rpc_id(1, key, {
		"hands": hands != null,
		"sword": hands != null and hands.main.get_node_or_null("HeldWeapon") != null,
		"model": body != null and body.visual != null and body.visual.model_loaded(),
		"mode": PlayerHands.Mode.keys()[hands.mode] if hands != null else "",
	})


@rpc("authority", "call_remote", "reliable")
func client_watch(key: String, skill: String, seconds: float) -> void:
	var body := _host_body()
	if body == null:
		report.rpc_id(1, key, {})
		return
	report.rpc_id(1, key, await _watch(body, Skills.get_def(skill), seconds))


@rpc("authority", "call_remote", "reliable")
func finish(host_failures: int) -> void:
	print("HA_RESULT peer=%d checks=%d failures=%d host_failures=%d" % [
		_peer_id, _checks, _failures, host_failures])
	get_tree().quit(0 if _failures == 0 else 1)
