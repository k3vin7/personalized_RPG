extends Node

# CB (2026-11-18): the side cut's three combo steps, on both peers.
#
#   host:   --auto-host --auto-smoke --auto-only=CB --auto-port=P --auto-quit=60
#   client: --auto-join --auto-smoke --auto-only=CB --auto-port=P --auto-quit=60
#
# Each peer, on its own body where it spawned (no teleport), with a sword:
#   1. the side cut's slot pressed again while each step is still going: the
#      casts are side_cut, side_cut_2 (two steps since 2026-11-19), following when the
#      swing before it is through (no recovery, never out of the cast); a
#      press after step 3 has ended is side_cut again.
#   2. a press after a step has ended is side_cut, not step 2; the thrust
#      pressed again while it is going is followed by thrust_2.
#   3. a step sent with no chain behind it (side_cut_2 on its own) is refused
#      by the server.
# And each peer watches the other body's skill stamp for steps 2 and 3. The
# server's counts (steps ruled, steps refused) are read on the host at the end.

# Late enough that a peer that had a model profile to read (seconds, at its
# spawn) is watching before the other one starts.
const SEQUENCE_AT := 12.0

var _world: Node3D
var _local: Player
var _mate: Player
var _peer_id := 0
var _checks := 0
var _failures := 0
var _lag := 0.0
var _mate_stamps := {}
var _started_msec := 0


func expect(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("CB_CHECK peer=%d %s %s" % [_peer_id, "PASS" if condition else "FAIL", label])


func note(line: String) -> void:
	print("CB_NOTE peer=%d %s" % [_peer_id, line])


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _elapsed() -> float:
	return float(Time.get_ticks_msec() - _started_msec) / 1000.0


func _game_seconds() -> float:
	return float(Engine.get_physics_frames()) / float(Engine.physics_ticks_per_second)


func _process(_delta: float) -> void:
	if is_instance_valid(_mate) and _mate.sync_skill_id != "":
		_mate_stamps[_mate.sync_skill_id] = true
	if _tracing and is_instance_valid(_local):
		_trace_frame()


# ------------------------------------------------------------------ the trace
# Every drawn frame of the chained side cut on this peer's own body: where the
# body is and which way it faces, where the model's sword hand is, and what
# the clip is doing. Printed afterwards as the things that changed in one
# frame by more than a moving body does (a turn, a jump of the hand, the clip
# changing) and as speeds in 0.05 s bins.
var _tracing := false
var _trace: Array[Dictionary] = []


func _trace_frame() -> void:
	var row := {
		"t": float(Time.get_ticks_usec()) / 1000000.0,
		"body": _local.global_position,
		"yaw": rad_to_deg(_local.rotation.y),
		"state": _local.state,
	}
	var visual := _local.visual
	if visual != null and visual.model_loaded():
		var skeleton := visual.skeleton()
		var hand := skeleton.find_bone("RightHand")
		var hips := skeleton.find_bone("Hips")
		row["hand"] = skeleton.global_transform * skeleton.get_bone_global_pose(hand).origin
		row["hips"] = skeleton.global_transform * skeleton.get_bone_global_pose(hips).origin
		row["clip"] = visual.current_clip()
		row["at"] = visual._anim.current_animation_position if visual._anim.is_playing() else -1.0
		row["speed"] = visual.clip_speed()
		row["shown"] = visual._model.visible
	_trace.append(row)


func _report_trace() -> void:
	if _trace.size() < 3:
		return
	var t0 := float(_trace[0]["t"])
	var events: Array[String] = []
	var body_bins := {}
	var hand_bins := {}
	var bin_start := {}
	for index in range(1, _trace.size()):
		var a: Dictionary = _trace[index - 1]
		var b: Dictionary = _trace[index]
		var t := float(b["t"]) - t0
		var dt := maxf(float(b["t"]) - float(a["t"]), 0.0001)
		var turn := absf(wrapf(float(b["yaw"]) - float(a["yaw"]), -180.0, 180.0))
		if turn > 2.0:
			events.append("%.3f turn %.0f deg" % [t, turn])
		if int(b["state"]) != int(a["state"]):
			events.append("%.3f state %s>%s" % [t, Player.State.keys()[a["state"]], Player.State.keys()[b["state"]]])
		var moved := (b["body"] as Vector3).distance_to(a["body"] as Vector3)
		if moved / dt > 8.0:
			events.append("%.3f body %.2f m in one frame" % [t, moved])
		if b.has("clip") and a.has("clip"):
			if String(b["clip"]) != String(a["clip"]):
				events.append("%.3f clip %s>%s" % [t, a["clip"], b["clip"]])
			if bool(b["shown"]) != bool(a["shown"]):
				events.append("%.3f model shown=%s" % [t, b["shown"]])
			# The hand against the body: what the clip itself does.
			var rel_a := (a["hand"] as Vector3) - (a["body"] as Vector3)
			var rel_b := (b["hand"] as Vector3) - (b["body"] as Vector3)
			var hand_speed := rel_a.distance_to(rel_b) / dt
			if hand_speed > 25.0:
				events.append("%.3f hand %.2f m in one frame" % [t, rel_a.distance_to(rel_b)])
			var hips_a := (a["hips"] as Vector3) - (a["body"] as Vector3)
			var hips_b := (b["hips"] as Vector3) - (b["body"] as Vector3)
			if hips_a.distance_to(hips_b) / dt > 6.0:
				events.append("%.3f hips %.2f m in one frame" % [t, hips_a.distance_to(hips_b)])
		var bin := int(t / 0.05)
		if not bin_start.has(bin):
			bin_start[bin] = index
	for bin in bin_start:
		var first: Dictionary = _trace[int(bin_start[bin])]
		var last_index := int(bin_start.get(bin + 1, _trace.size() - 1))
		var last: Dictionary = _trace[last_index]
		var span := maxf(float(last["t"]) - float(first["t"]), 0.0001)
		body_bins[bin] = (last["body"] as Vector3).distance_to(first["body"] as Vector3) / span
		if first.has("hand") and last.has("hand"):
			hand_bins[bin] = ((last["hand"] as Vector3) - (last["body"] as Vector3)).distance_to(
				(first["hand"] as Vector3) - (first["body"] as Vector3)) / span
	var body_row: Array[String] = []
	var hand_row: Array[String] = []
	for bin in body_bins:
		body_row.append("%.2f:%.1f" % [float(bin) * 0.05, float(body_bins[bin])])
		if hand_bins.has(bin):
			hand_row.append("%.2f:%.1f" % [float(bin) * 0.05, float(hand_bins[bin])])
	note("trace: %d frames over %.2f s" % [_trace.size(), float(_trace[_trace.size() - 1]["t"]) - t0])
	note("trace events: %s" % [events])
	note("trace body speed m/s: %s" % " ".join(body_row))
	note("trace hand speed (against the body) m/s: %s" % " ".join(hand_row))


func run(world: Node3D) -> void:
	_world = world
	_peer_id = multiplayer.get_unique_id()
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--be-latency="):
			_lag = argument.trim_prefix("--be-latency=").to_float() / 1000.0
	# Both bodies before anything starts, so each sees the other's casts. This
	# peer's own body can arrive after this runs (a model profile takes a
	# moment to read): it is waited for, not assumed.
	var waited := 0.0
	while (_local == null or _mate == null) and waited < 30.0:
		_local = Net.spawn_root.get_node_or_null(str(_peer_id)) as Player
		if _local != null:
			for node in Net.spawn_root.get_children():
				var body := node as Player
				if body != null and body != _local:
					_mate = body
		if _local == null or _mate == null:
			await _wait(0.2)
			waited += 0.2
	expect(_local != null and _mate != null, "both_peers_present")
	if _local == null or _mate == null:
		_finish()
		return
	_started_msec = Time.get_ticks_msec()
	await _wait(1.0)
	_local.set_weapon(WeaponKinds.Kind.SWORD)
	await _wait(1.5 + _lag * 2.0)
	expect(_local.weapon == WeaponKinds.Kind.SWORD, "the_sword_is_in_hand")
	while _elapsed() < SEQUENCE_AT + _lag * 2.0:
		await _wait(0.05)
	var slot := _side_cut_slot()
	expect(slot >= 0, "the_side_cut_is_in_a_slot")
	if slot < 0:
		_finish()
		return
	var ahead := -_local.global_transform.basis.z
	_local.movement.set_aim_override(_local.global_position + ahead * 6.0)
	note("windups: step 1 %.2f, step 2 %.2f; combo window %.2f + grace %.2f; lag %.0f ms one way" % [
		Skills.get_def("side_cut").value("windup"), Skills.get_def("side_cut_2").value("windup"),
		Tuning.server.combo_window, Tuning.server.combo_grace, _lag * 1000.0])

	# 1: the slot pressed again while each step is still going (the press is
	# remembered): step 2 follows step 1 and step 3 follows step 2 the moment
	# the swing before is through, with no recovery between and the body
	# never out of the cast. A fourth press, after step 3 has ended, is step 1.
	var cast: Array[String] = []
	var starts: Array[float] = []
	var left_cast := false
	_tracing = true
	_local.skills.cast_slot(slot)
	cast.append(_local.skills.current_def().id)
	starts.append(_game_seconds())
	# 2026-11-19: two steps. The slot is pressed again during each; the second
	# press, during step 2, has nothing to follow it and the cast ends.
	for step in 2:
		await _wait(0.05)
		_local.skills.press_slot(slot)
		var before := cast[cast.size() - 1]
		var step_wait := 0.0
		while step_wait < 4.0:
			await get_tree().physics_frame
			step_wait += 1.0 / 120.0
			var now_def := _local.skills.current_def()
			if now_def == null:
				left_cast = step == 0
				break
			if now_def.id != before:
				cast.append(now_def.id)
				starts.append(_game_seconds())
				break
	# Through the third step's recovery and back to standing.
	var settle := 0.0
	while _local.skills.is_busy() and settle < 4.0:
		await get_tree().physics_frame
		settle += 1.0 / 120.0
	await _wait(0.5)
	_tracing = false
	_report_trace()
	cast.append(await _press(slot))
	note("pressed again during each step, then once after the end: %s" % [cast])
	expect(",".join(cast) == "side_cut,side_cut_2,side_cut", "the_presses_go_step_1_2_and_back_to_1")
	expect(not left_cast, "the_body_never_left_the_cast_between_steps")
	if starts.size() == 2:
		var first := Skills.get_def("side_cut")
		var gap_1 := starts[1] - starts[0]
		var want_1 := first.value("windup") + first.swing_time()
		note("step 1 -> 2 after %.3f s (windup + swing %.3f; with its recovery it was %.3f)" % [
			gap_1, want_1, first.value("windup") + first.value("recovery")])
		# On the game's own clock (physics ticks): the wall clock of a headless
		# pair runs long by whole frames whenever a process stalls.
		expect(absf(gap_1 - want_1) < 0.03, "each_step_follows_when_the_swing_before_is_through")
	expect(Skills.get_def("side_cut_2").arc_sign() == -Skills.get_def("side_cut").arc_sign()
		and Skills.get_def("side_cut_2").combo_next == "" and not Skills.is_known("side_cut_3"),
		"step_2_cuts_the_other_way_and_is_the_last")

	# 2: a press after the step has ended is not a step 2 (combo_window 0).
	await _wait(0.5)
	var late := await _press(slot)
	note("a press just after the step before it ended cast: %s" % late)
	expect(late == "side_cut", "a_press_after_the_end_is_the_first_step_again")
	await _wait(Tuning.server.combo_window + Tuning.server.combo_grace + 0.4 + _lag * 2.0)

	# 2b: the thrust needs a hit for its next step. Here nothing is in front
	# of the blade: pressed again while it is going, it is still only a thrust.
	var thrust_slot := -1
	for index in PlayerSkills.SLOT_COUNT:
		var held := _local.skills.slot_def(index)
		if held != null and held.id == "thrust":
			thrust_slot = index
	expect(thrust_slot >= 0, "the_thrust_is_in_a_slot")
	if thrust_slot >= 0:
		var missed := await _thrust_and_press_again(thrust_slot)
		note("a thrust that hit nothing, pressed again while going, was followed by: '%s'" % missed)
		expect(missed == "", "a_thrust_that_misses_is_not_followed_by_the_kick")
	await _wait(0.6 + _lag * 2.0)

	# 3: a step with no chain behind it. Sent as the slot would send it.
	ServerAuthority.submit_intent(_local, ServerAuthority.Intent.SKILL, {
		"skill": "side_cut_2",
		"direction": ahead,
	})
	await _wait(0.6 + _lag * 2.0)
	note("own steps cast by the slot so far: %d" % _local.skills.combo_steps_cast)
	expect(_local.skills.combo_steps_cast == 1, "the_slot_cast_one_step")

	# 4: a thrust that lands. The host's body is stood 1.6 m from the
	# client's (the host moves its own body; the client's is left alone); the
	# client thrusts at it first, the host at the client's after it is back
	# on its feet. The step is opened by the server at the hit and, for the
	# client, the word comes back over the wire.
	# Ordered by what each peer sees of the other, not by the clock: a peer
	# that read a model profile at its spawn starts seconds behind.
	var is_host := multiplayer.is_server()
	if is_host:
		# The client has thrown its missing thrust (and, 3 s on, its forged
		# step): stand by it, then wait for its kick and for this body to be
		# back on its feet before standing by it again.
		await _until(func() -> bool: return _mate_stamps.has("thrust"), 60.0)
		await _wait(3.0 + _lag * 4.0)
		await _stand_by_mate()
		await _until(func() -> bool: return _mate_stamps.has("thrust_2"), 40.0)
		await _wait(4.0)
		await _stand_by_mate()
	else:
		# The host's body has come to stand by this one.
		await _until(func() -> bool: return _flat_gap() < 2.2, 60.0)
		await _wait(1.0)
	if thrust_slot >= 0:
		_local.movement.set_aim_override(_mate.global_position)
		for frame in 4:
			await get_tree().physics_frame
		var gap := Vector2(_mate.global_position.x - _local.global_position.x, _mate.global_position.z - _local.global_position.z).length()
		var landed := await _thrust_and_press_again(thrust_slot)
		note("a thrust at the other body %.2f m away (reach %.2f), pressed again while going, was followed by: '%s'" % [
			gap, Skills.get_def("thrust").value("reach"), landed])
		expect(landed == "thrust_2", "a_thrust_that_lands_is_followed_by_the_kick")
	_local.movement.set_aim_override(_local.global_position)
	expect(_local.skills.combo_steps_cast == 2, "the_slots_cast_two_steps_in_all")

	# 5 (2026-11-19): the dash cut, away from the other body. The body covers
	# the skill's step in its swing, far faster than a walk: the server lets
	# it through on the skill's own data (no move warning, no correction: the
	# body is still where it got to afterwards), and the other screen sees it.
	var dash_slot := -1
	for index in PlayerSkills.SLOT_COUNT:
		var held_now := _local.skills.slot_def(index)
		if held_now != null and held_now.id == "dash_cut":
			dash_slot = index
	expect(dash_slot >= 0, "the_dash_cut_is_in_a_slot")
	if dash_slot >= 0:
		var idle := 0.0
		while _local.skills.is_busy() and idle < 5.0:
			await get_tree().physics_frame
			idle += 1.0 / 120.0
		await _wait(0.3 + _lag * 2.0)
		var away := _local.global_position - _mate.global_position
		away.y = 0.0
		away = away.normalized() if away.length() > 0.1 else ahead
		_local.movement.set_aim_override(_local.global_position + away * 8.0)
		for frame in 4:
			await get_tree().physics_frame
		var dash := Skills.get_def("dash_cut")
		var from := _local.global_position
		var corrections_before := _local.corrections_received
		var began := _game_seconds()
		var cast_ok := _local.skills.cast_slot(dash_slot)
		var crossed_at := -1.0
		var busy := 0.0
		while _local.skills.is_busy() and busy < 4.0:
			await get_tree().physics_frame
			busy += 1.0 / 120.0
			if crossed_at < 0.0 and (_local.global_position - from).length() >= dash.step_distance * 0.95:
				crossed_at = _game_seconds() - began
		await _wait(0.6 + _lag * 4.0)
		var went := _local.global_position - from
		went.y = 0.0
		note("dash cut: cast %s; went %.2f m (step %.2f), %.2f m off the line; there %.2f s after the press (windup %.2f + swing %.2f); streak %d, %.2f m long; corrections since %d" % [
			cast_ok, went.length(), dash.step_distance, (went - away * went.dot(away)).length(), crossed_at,
			dash.value("windup"), dash.swing_time(), _local.streaks_drawn, _local.streak_length(),
			_local.corrections_received - corrections_before])
		expect(cast_ok and absf(went.length() - dash.step_distance) < 0.3, "the_dash_cut_covers_its_step_and_stays_there")
		expect(crossed_at > 0.0 and crossed_at < dash.value("windup") + dash.swing_time() + 0.08, "the_dash_is_over_with_the_swing")
		expect(_local.streaks_drawn == 1, "the_streak_is_drawn_once")
		_local.movement.set_aim_override(_local.global_position)

	if is_host:
		# The client's were all seen before this body's own; it is still here
		# (it stays 4 s past this body's dash cut).
		await _wait(0.5)
	else:
		# The host's own thrust, kick and dash cut come after this one's.
		await _until(func() -> bool: return _mate_stamps.has("dash_cut"), 40.0)
		await _wait(4.0 + _lag * 4.0)
	note("the other body's skill stamps seen here: %s; its streaks drawn here: %d" % [_mate_stamps.keys(), _mate.streaks_drawn if is_instance_valid(_mate) else -1])
	expect(_mate_stamps.has("side_cut_2") and _mate_stamps.has("thrust_2"),
		"this_screen_saw_the_other_bodys_steps")
	expect(_mate_stamps.has("dash_cut") and is_instance_valid(_mate) and _mate.streaks_drawn >= 1, "this_screen_saw_the_other_bodys_dash_cut_and_streak")
	var judge: ServerAuthority = null
	if is_instance_valid(_world):
		judge = _world.get_node_or_null("ServerAuthority") as ServerAuthority
	if multiplayer.is_server() and judge != null:
		note("server: combo steps ruled %d, refused %d, opened by a hit %d" % [
			judge.combo_steps_ruled, judge.combo_steps_refused, judge.combo_opened_by_hit])
		expect(judge.combo_steps_ruled == 4, "the_server_ruled_two_steps_for_each_peer")
		expect(judge.combo_steps_refused == 2, "the_server_refused_both_out_of_turn_steps")
		expect(judge.combo_opened_by_hit == 2, "the_server_opened_the_kick_once_for_each_peer_on_a_hit")
		note("server: move warnings in the whole run %d" % judge.move_warnings)
	_finish()


func _flat_gap() -> float:
	return Vector2(_mate.global_position.x - _local.global_position.x, _mate.global_position.z - _local.global_position.z).length()


# Waits for `seen` to say so, or for `limit` seconds.
func _until(seen: Callable, limit: float) -> void:
	var waited := 0.0
	while waited < limit and not bool(seen.call()):
		await _wait(0.1)
		waited += 0.1


# The host's own body, 1.6 m east of the other one and at its height.
func _stand_by_mate() -> void:
	var spot := _mate.global_position + Vector3(1.6, 0.0, 0.0)
	Net.queue_physics(func() -> void:
		_local.global_position = spot
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target())
	await _wait(0.6)


# Casts the thrust, presses its slot again while it is going, and returns the
# id of the step that followed it ("" when the cast simply ended).
func _thrust_and_press_again(slot: int) -> String:
	var idle := 0.0
	while _local.skills.is_busy() and idle < 5.0:
		await get_tree().physics_frame
		idle += 1.0 / 120.0
	if not _local.skills.cast_slot(slot):
		return "refused_here"
	await _wait(0.05)
	_local.skills.press_slot(slot)
	var followed := ""
	var waited := 0.0
	while waited < 3.0 and followed == "":
		await get_tree().physics_frame
		waited += 1.0 / 120.0
		var def := _local.skills.current_def()
		if def == null:
			break
		if def.id != "thrust":
			followed = def.id
	var busy := 0.0
	while _local.skills.is_busy() and busy < 4.0:
		await get_tree().physics_frame
		busy += 1.0 / 120.0
	return followed

func _finish() -> void:
	print("CB_RESULT peer=%d checks=%d failures=%d" % [_peer_id, _checks, _failures])
	# The host outlives the client: its counts need the client's casts.
	await _wait(10.0 if multiplayer.is_server() else 0.5)
	get_tree().quit(0 if _failures == 0 else 1)


func _side_cut_slot() -> int:
	for index in PlayerSkills.SLOT_COUNT:
		var def := _local.skills.slot_def(index)
		if def != null and def.id == "side_cut":
			return index
	return -1


# One press of the slot; returns the id of what it cast, after the cast and
# its recovery have ended.
func _press(slot: int) -> String:
	var waited := 0.0
	while _local.skills.is_busy() and waited < 5.0:
		await get_tree().physics_frame
		waited += 1.0 / 120.0
	# A moment past the recovery: the server's lock runs on its own clock.
	await _wait(0.06)
	if not _local.skills.cast_slot(slot):
		return "refused_here"
	var def := _local.skills.current_def()
	var id := def.id if def != null else "none"
	waited = 0.0
	while _local.skills.is_busy() and waited < 5.0:
		await get_tree().physics_frame
		waited += 1.0 / 120.0
	return id
