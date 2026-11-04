extends Node

# C-0: the combat skeleton's preparation -- the SkillDef display schema, the
# range shape a key shows, the swing bar and its trail, the scarecrow's
# windup telegraph, and the hit feedback set (hitstop, flash, particle, sound
# hook, shake, number). Everything here is a picture: the checks read counters
# and shapes, never a ruling. Two peers: the host conducts, the client stands
# in as the target and as the other screen, and reports what it saw.

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
	print("C0_CHECK peer=%d %s %s" % [_peer_id, "PASS" if condition else "FAIL", label])


func note(line: String) -> void:
	print("C0_NOTE peer=%d %s" % [_peer_id, line])


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


func _park(at: Vector3) -> void:
	await tick_request(func() -> void:
		placed()
		_local.global_position = at
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target()
		_local.movement.cancel_armed()
		_local.movement.set_aim_override(Vector3.INF))
	await _wait(0.4)


# Both bodies on their marks, a metre apart, the host aiming at the client.
func _reset_pair() -> void:
	var mate := _mate()
	await tick_request(func() -> void:
		placed()
		_judge.harness_clear_stats(_local)
		_judge.server_respawn(_local)
		if mate != null:
			_judge.server_respawn(mate)
		_local.global_position = HOME
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target()
		_local.movement.cancel_armed()
		_local.movement.set_aim_override(Vector3.INF))
	client_park.rpc_id(_client_peer(), CLIENT_SPOT)
	await _wait(0.9)
	_local.movement.set_aim_override(CLIENT_SPOT)


func _counters() -> Dictionary:
	return {
		"hits": _feedback.hits, "numbers": _feedback.numbers, "hitstops": _feedback.hitstops,
		"flashes": _feedback.flashes, "particles": _feedback.particles, "sounds": _feedback.sounds,
		"shakes": _feedback.shakes, "deduped": _feedback.deduped, "notified": _judge.hits_notified,
		"player_hitstops": _local.hitstops_applied,
	}


func _delta(before: Dictionary) -> Dictionary:
	var now := _counters()
	var out := {}
	for key: String in now.keys():
		out[key] = int(now[key]) - int(before[key])
	return out


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
	expect(_feedback != null, "the_hit_feedback_set_is_built_for_the_local_view")
	var warnings := _judge.move_warnings
	var corrections := _judge.move_corrections
	var smart: bool = Tuning.values.smart_key_enabled
	await _schema_checks()
	await _range_display_checks()
	await _swing_checks()
	await _attacker_feedback_checks()
	await _target_feedback_checks()
	await _spectator_checks()
	await _telegraph_checks()
	await _shake_checks()
	Tuning.values.smart_key_enabled = smart
	expect(_judge.move_warnings == warnings, "no_move_warnings_during_c0")
	expect(_judge.move_corrections == corrections, "no_corrections_during_c0")
	print("C0_RESULT peer=%d checks=%d failures=%d" % [_peer_id, _checks, _failures])
	finish.rpc(_failures)
	await _wait(1.0)
	get_tree().quit(0 if _failures == 0 else 1)


# ------------------------------------------------------- 1: the display schema

func _schema_checks() -> void:
	var all_ok := true
	for id in Skills.all_ids():
		var def := Skills.get_def(id)
		if def == null:
			all_ok = false
			continue
		var shape_ok := def.range_shape >= SkillDef.RangeShape.NONE and def.range_shape <= SkillDef.RangeShape.CIRCLE
		var arc_ok := is_finite(def.arc_start()) and is_finite(def.arc_degrees()) and def.swing_time() > 0.0
		note("%s: shape=%s angle=%.0f circle=%.1f telegraph=%s arc plane=%s start=%.0f sweep=%.0f duration=%.2f trail=%s big=%s" % [
			id, SkillDef.RangeShape.keys()[def.range_shape], def.shape_angle_deg, def.circle_radius, def.telegraph,
			SkillDef.ArcPlane.keys()[def.arc_plane], def.arc_start(), def.arc_sign() * def.arc_degrees(), def.swing_time(), def.trail, def.feedback_big])
		all_ok = all_ok and shape_ok and arc_ok
	expect(all_ok, "every_skilldef_carries_a_valid_range_shape_and_swing_arc")
	expect(Skills.get_def("grab").range_shape == SkillDef.RangeShape.NONE and not Skills.get_def("grab").shows_range(),
		"the_grab_shows_no_range")
	expect(Skills.get_def("punch").range_shape == SkillDef.RangeShape.RECT and Skills.get_def("kick").range_shape == SkillDef.RangeShape.RECT
		and Skills.get_def("shove").range_shape == SkillDef.RangeShape.RECT, "the_bare_strikes_show_a_rectangle")
	expect(Skills.get_def("dummy_slam").telegraph and Skills.get_def("dummy_slam").feedback_big,
		"the_scarecrows_slam_telegraphs_and_counts_as_big")
	# The shape builder itself: a RECT of the punch's reach, a FAN and a CIRCLE
	# built from a scratch def, each with the vertex count its shape implies.
	var mesh := ImmediateMesh.new()
	RangeShapes.write(mesh, Skills.get_def("punch"), 1.0)
	var rect_vertices: int = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size() if mesh.get_surface_count() > 0 else 0
	var scratch := SkillDef.new()
	scratch.range_shape = SkillDef.RangeShape.FAN
	scratch.reach = 1.8
	scratch.shape_angle_deg = 120.0
	RangeShapes.write(mesh, scratch, 1.0)
	var fan_vertices: int = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size() if mesh.get_surface_count() > 0 else 0
	var fan_extent := RangeShapes.extent_of(scratch)
	scratch.range_shape = SkillDef.RangeShape.CIRCLE
	scratch.reach = 1.3
	scratch.circle_radius = 1.0
	RangeShapes.write(mesh, scratch, 1.0)
	var circle_vertices: int = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size() if mesh.get_surface_count() > 0 else 0
	scratch.range_shape = SkillDef.RangeShape.LINE
	scratch.reach = 2.2
	RangeShapes.write(mesh, scratch, 1.0)
	var line_vertices: int = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size() if mesh.get_surface_count() > 0 else 0
	scratch.range_shape = SkillDef.RangeShape.NONE
	RangeShapes.write(mesh, scratch, 1.0)
	note("shape builder: rect %d vertices, fan %d (extent %.1f), circle %d (extent %.1f), line %d, none %d surfaces" % [
		rect_vertices, fan_vertices, fan_extent, circle_vertices, 2.3, line_vertices, mesh.get_surface_count()])
	expect(rect_vertices == 6 and fan_vertices == RangeShapes.FAN_SEGMENTS * 3
		and circle_vertices == RangeShapes.CIRCLE_SEGMENTS * 3 and line_vertices == 9 and mesh.get_surface_count() == 0,
		"the_shape_builder_draws_each_shape_and_nothing_for_none")


# ------------------------------------------- 2: the range a key shows (smart off)

func _range_display_checks() -> void:
	await _park(HOME)
	Tuning.values.smart_key_enabled = false
	var indicator := _local.movement.aim_indicator()
	var punch := Skills.get_def("punch")
	var kick := Skills.get_def("kick")
	_local.movement.set_aim_override(HOME + Vector3(3.0, 0.0, 0.0))
	await tick_request(func() -> void: _local.skills.press_slot(2))
	await _wait(0.2)
	var armed := _local.movement.armed_action() == PlayerMovement.Armed.SKILL
	var kind := indicator.shape_kind()
	var extent := indicator.shape_extent()
	note("punch armed: armed=%s shape=%s extent=%.2f (reach %.2f) showing=%s" % [
		armed, SkillDef.RangeShape.keys()[kind], extent, punch.value("reach"), indicator.is_showing()])
	expect(armed and kind == SkillDef.RangeShape.RECT, "arming_the_punch_shows_its_rectangle")
	expect(absf(extent - punch.value("reach")) < 0.01, "as_long_as_its_reach")
	await tick_request(func() -> void: _local.movement.cancel_armed())
	await _wait(0.1)
	expect(indicator.shape_kind() == SkillDef.RangeShape.NONE and not indicator.is_showing(),
		"cancelling_takes_the_shape_down")
	await tick_request(func() -> void: _local.skills.press_slot(3))
	await _wait(0.2)
	extent = indicator.shape_extent()
	note("kick armed: shape=%s extent=%.2f (reach %.2f)" % [
		SkillDef.RangeShape.keys()[indicator.shape_kind()], extent, kick.value("reach")])
	expect(indicator.shape_kind() == SkillDef.RangeShape.RECT and absf(extent - kick.value("reach")) < 0.01,
		"the_kick_shows_its_own_rectangle")
	# The left button casts it and the shape goes with the arming.
	var started := _local.skills.casts_started
	await tick_request(func() -> void: _local.movement.cast_armed())
	await _wait(0.1)
	expect(_local.skills.casts_started == started + 1 and indicator.shape_kind() == SkillDef.RangeShape.NONE,
		"the_left_button_casts_and_the_shape_goes")
	await _wait(kick.value("windup") + kick.value("recovery") + kick.value("cooldown") + 0.3)
	# Shape-less skills show nothing when their def is handed to the indicator.
	indicator.show_skill_shape(_local.global_position, Vector3.FORWARD, Skills.get_def("grab"))
	expect(indicator.shape_kind() == SkillDef.RangeShape.NONE, "a_def_with_no_shape_shows_nothing")
	indicator.hide_all()
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))


# ------------------------------------------------ 3: the swing bar and the trail

func _swing_checks() -> void:
	await _park(HOME)
	Tuning.values.smart_key_enabled = true
	var kick := Skills.get_def("kick")
	var mate := _mate()
	client_park.rpc_id(_client_peer(), HOME + Vector3(-3.0, 0.0, 0.0))
	await _wait(0.6)
	_reports.erase("swing")
	client_watch_swing.rpc_id(_client_peer(), _local.get_path(), 2.5)
	await _wait(0.2)
	_local.movement.set_aim_override(HOME + Vector3(0.0, 0.0, -3.0))
	var swings := _local.swings_started
	await tick_request(func() -> void: _local.skills.press_slot(3))
	# Through the windup; then sample the strike.
	var waited := 0.0
	while not _local.swing_active() and waited < 1.5:
		await get_tree().process_frame
		waited += get_process_delta_time()
	var first := _local.swing_progress()
	var progress := first
	var rose := true
	var samples_max := 0
	var frames := 0
	while _local.swing_active() and frames < 2000:
		await get_tree().process_frame
		frames += 1
		var now := _local.swing_progress()
		if now >= 0.0:
			if now < progress - 0.0001:
				rose = false
			progress = now
		samples_max = maxi(samples_max, _local.trail_sample_count())
	await _wait(0.5)
	note("kick swing: started %d -> %d, first progress %.2f, last %.2f, monotonic=%s, trail samples max %d (cap %d), active after=%s, trail left=%d, pivot rotation now %s" % [
		swings, _local.swings_started, first, progress, rose, samples_max, Player.TRAIL_MAX_SAMPLES,
		_local.swing_active(), _local.trail_sample_count(), _local._swing_pivot.rotation])
	expect(_local.swings_started == swings + 1, "the_strike_starts_a_swing")
	expect(first >= 0.0 and progress > first and rose, "whose_progress_rises_through_the_arc")
	expect(samples_max > 1, "and_leaves_a_trail")
	expect(not _local.swing_active() and _local._swing_pivot.rotation == Vector3.ZERO,
		"and_the_pivot_is_back_at_rest_when_it_ends")
	if await _wait_report("swing"):
		var seen: Dictionary = _reports["swing"]
		note("the swing on the other screen: seen=%s samples max %d progress max %.2f" % [
			seen.get("seen", false), int(seen.get("samples", 0)), float(seen.get("progress", -1.0))])
		expect(bool(seen.get("seen", false)) and int(seen.get("samples", 0)) > 1,
			"the_other_screen_replays_the_swing_and_its_trail")
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	if mate != null:
		await _wait(0.3)


# ------------------------------- 4: the attacker's feedback (host punches client)

func _attacker_feedback_checks() -> void:
	await _reset_pair()
	Tuning.values.smart_key_enabled = true
	var mate := _mate()
	var punch := Skills.get_def("punch")
	var before := _counters()
	var hp_before := mate.hp
	var frames: int = Tuning.values.hitstop_frames
	await tick_request(func() -> void: _local.skills.press_slot(2))
	# The flash is short: catch it on the way.
	var waited := 0.0
	var saw_flash := false
	while waited < punch.value("windup") + 1.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
		if mate.flash_left() > 0.0:
			saw_flash = true
	var d := _delta(before)
	note("host punches client: %s, number value %.1f (damage %.1f), hp %.0f -> %.0f, flash on the mate seen=%s, hitstop frames %d (slider %d), point %s" % [
		d, _feedback.last_number_value, punch.value("damage"), hp_before, mate.hp, saw_flash,
		_local.last_hitstop_frames, frames, _feedback.last_point])
	expect(int(d["notified"]) == 1, "the_server_tells_the_attacker_once")
	expect(int(d["hits"]) == 1, "the_attacker_screen_counts_one_hit")
	expect(int(d["numbers"]) == 1 and absf(_feedback.last_number_value - punch.value("damage")) < 0.01,
		"and_floats_the_punch_damage_as_a_number")
	expect(int(d["hitstops"]) == 1 and int(d["player_hitstops"]) == 1 and _local.last_hitstop_frames == frames,
		"and_holds_the_swing_for_hitstop_frames")
	expect(int(d["flashes"]) == 1 and saw_flash, "and_flashes_the_body_it_hit")
	expect(int(d["particles"]) == 1 and int(d["sounds"]) == 1, "and_bursts_and_sounds_once")
	expect(int(d["shakes"]) == 0, "a_punch_that_slid_does_not_shake_the_camera")
	expect(_feedback.last_point.distance_to(mate.global_position) < 1.0, "the_point_is_on_the_target")
	# A second punch into the recovery+cooldown window: a second hit, not a
	# dedupe of the first.
	await _wait(punch.value("recovery") + 0.3)
	before = _counters()
	await tick_request(func() -> void: _local.skills.press_slot(2))
	await _wait(punch.value("windup") + 0.5)
	d = _delta(before)
	note("second punch: %s" % [d])
	expect(int(d["hits"]) == 1 and int(d["numbers"]) == 1, "the_next_punch_is_its_own_hit")
	# Switched off: nothing is drawn.
	await _wait(punch.value("recovery") + 0.3)
	Tuning.values.hit_feedback_enabled = false
	before = _counters()
	await tick_request(func() -> void: _local.skills.press_slot(2))
	await _wait(punch.value("windup") + 0.5)
	d = _delta(before)
	Tuning.values.hit_feedback_enabled = true
	note("feedback off: %s" % [d])
	expect(int(d["hits"]) == 0 and int(d["numbers"]) == 0 and int(d["hitstops"]) == 0 and int(d["notified"]) == 1,
		"with_the_switch_off_the_notice_arrives_and_nothing_is_drawn")
	await _wait(punch.value("recovery") + 0.3)


# ----------------------------- 5: the target's feedback (the client, punched)

func _target_feedback_checks() -> void:
	await _reset_pair()
	var punch := Skills.get_def("punch")
	_reports.erase("felt")
	client_watch_feedback.rpc_id(_client_peer(), 2.0)
	await _wait(0.3)
	await tick_request(func() -> void: _local.skills.press_slot(2))
	if await _wait_report("felt"):
		var felt: Dictionary = _reports["felt"]
		note("the client, punched: %s (damage %.1f)" % [felt, punch.value("damage")])
		expect(int(felt.get("hits", 0)) >= 1 and int(felt.get("numbers", 0)) >= 1
			and absf(float(felt.get("value", 0.0)) - punch.value("damage")) < 0.01,
			"the_target_screen_shows_the_hit_and_its_number")
		expect(int(felt.get("hitstops", 0)) >= 1 and bool(felt.get("self_flash", false)),
			"and_holds_still_and_flashes_its_own_body")
		expect(int(felt.get("hits", 0)) == 1, "once_whichever_of_the_force_and_the_hp_came_first")
	await _wait(punch.value("recovery") + 0.3)


# ------------------------------ 6: the other screen (client watches a scarecrow)

func _spectator_checks() -> void:
	var dummy := _world.get_node("Dummy_1") as Dummy
	var punch := Skills.get_def("punch")
	var spot := dummy.global_position + Vector3(0.0, 0.0, 1.2)
	await tick_request(func() -> void:
		placed()
		_local.global_position = Vector3(spot.x, 0.9, spot.z)
		_local.velocity = Vector3.ZERO
		_local.movement.set_aim_override(dummy.global_position))
	client_park.rpc_id(_client_peer(), Vector3(spot.x + 3.0, 0.9, spot.z))
	await _wait(0.8)
	_reports.erase("watched")
	client_watch_dummy.rpc_id(_client_peer(), dummy.get_path(), 2.5)
	await _wait(0.3)
	var before := _counters()
	var hp_before := dummy.hp
	await tick_request(func() -> void: _local.skills.press_slot(2))
	var waited := 0.0
	var saw_flash := false
	while waited < punch.value("windup") + 1.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
		if dummy.flash_left() > 0.0:
			saw_flash = true
	var d := _delta(before)
	note("host punches the scarecrow: %s, dummy hp %.0f -> %.0f, flash seen=%s" % [d, hp_before, dummy.hp, saw_flash])
	expect(int(d["hits"]) == 1 and int(d["deduped"]) >= 1,
		"the_host_sees_one_hit_on_the_scarecrow_though_two_paths_report_it")
	expect(saw_flash and int(d["numbers"]) == 1, "with_a_flash_and_a_number")
	if await _wait_report("watched"):
		var seen: Dictionary = _reports["watched"]
		note("the client watching the scarecrow: %s" % [seen])
		expect(int(seen.get("numbers", 0)) >= 1 and bool(seen.get("flash", false)),
			"the_other_screen_shows_the_scarecrow_being_hit")
	await _wait(punch.value("recovery") + 0.3)


# ------------------------------------- 7: the scarecrow's telegraph fills in

func _telegraph_checks() -> void:
	var dummy := _world.get_node("Dummy_1") as Dummy
	var slam := Skills.get_def("dummy_slam")
	# Out of the slam's reach, watching.
	var spot := dummy.global_position + dummy.attack_direction() * 4.0
	await tick_request(func() -> void:
		placed()
		_local.global_position = Vector3(spot.x, 0.9, spot.z)
		_local.velocity = Vector3.ZERO
		_local.movement.set_aim_override(Vector3.INF))
	client_park.rpc_id(_client_peer(), Vector3(spot.x + 2.0, 0.9, spot.z))
	await _wait(0.6)
	_reports.erase("telegraph")
	client_watch_telegraph.rpc_id(_client_peer(), dummy.get_path(), 4.0)
	var period: float = Tuning.server.dummy_attack_period
	Tuning.server.dummy_attack_period = 1.5
	Tuning.server.dummy_attack_enabled = true
	var waited := 0.0
	while dummy.attack_phase != "windup" and waited < 4.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
	var visible_at_start := dummy.telegraph_visible()
	var first := dummy.telegraph_fill()
	var last := first
	var rose := true
	var frames := 0
	while dummy.attack_phase == "windup" and frames < 4000:
		await get_tree().process_frame
		frames += 1
		# The phase flips in a physics step and the picture goes with it, so
		# only a frame that still shows it is a sample of the fill.
		if not dummy.telegraph_visible():
			continue
		var fill := dummy.telegraph_fill()
		if fill < last - 0.0001:
			rose = false
		last = fill
	await get_tree().process_frame
	var hidden_after := not dummy.telegraph_visible()
	Tuning.server.dummy_attack_enabled = false
	Tuning.server.dummy_attack_period = period
	note("telegraph: visible at windup=%s fill %.2f -> %.2f over %d frames (windup %.2f s), monotonic=%s, hidden after=%s, shown %d" % [
		visible_at_start, first, last, frames, slam.impact_time(), rose, hidden_after, dummy.telegraphs_shown])
	expect(visible_at_start, "the_telegraph_shows_with_the_windup")
	expect(first < 0.35 and last > 0.85 and rose, "and_fills_from_empty_to_full_through_it")
	expect(hidden_after, "and_goes_at_the_impact")
	if await _wait_report("telegraph"):
		var seen: Dictionary = _reports["telegraph"]
		note("the client's telegraph: %s" % [seen])
		expect(bool(seen.get("seen", false)) and float(seen.get("fill_max", 0.0)) > 0.8 and bool(seen.get("hidden", false)),
			"the_other_screen_fills_the_same_telegraph_and_takes_it_down")
	await _wait(slam.value("recovery") + 0.5)


# ---------------------------------- 8: the big one shakes (the slam lands on me)

func _shake_checks() -> void:
	var dummy := _world.get_node("Dummy_1") as Dummy
	var slam := Skills.get_def("dummy_slam")
	var spot := dummy.global_position + dummy.attack_direction() * 1.0
	await tick_request(func() -> void:
		placed()
		_judge.server_set_hp(_local, _local.stats.max_hp)
		_local.global_position = Vector3(spot.x, 0.9, spot.z)
		_local.velocity = Vector3.ZERO)
	client_park.rpc_id(_client_peer(), dummy.global_position + Vector3(4.0, 0.0, 4.0))
	await _wait(0.6)
	var period: float = Tuning.server.dummy_attack_period
	Tuning.server.dummy_attack_period = 1.0
	Tuning.server.dummy_attack_enabled = true
	var before := _counters()
	var camera_shakes := _local.camera.shakes_started
	var hp_before := _local.hp
	var waited := 0.0
	while _local.hp >= hp_before and waited < 5.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
	await _wait(0.3)
	Tuning.server.dummy_attack_enabled = false
	Tuning.server.dummy_attack_period = period
	var d := _delta(before)
	note("the slam lands on the host: %s, hp %.0f -> %.0f (damage %.0f), camera shakes %d -> %d, number %.1f" % [
		d, hp_before, _local.hp, slam.value("damage"), camera_shakes, _local.camera.shakes_started, _feedback.last_number_value])
	expect(_local.hp < hp_before, "the_slam_landed")
	expect(int(d["hits"]) == 1 and int(d["shakes"]) == 1 and _local.camera.shakes_started == camera_shakes + 1,
		"a_big_hit_on_me_shakes_the_camera_once")
	expect(int(d["notified"]) == 0, "a_scarecrows_blow_notifies_no_attacker")
	await _wait(Tuning.server.down_time + Tuning.server.getup_time + 1.0)
	await tick_request(func() -> void:
		placed()
		_judge.server_respawn(_local))
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
	placed()
	await Harness.forgive_lead(get_tree(), placed)
	await tick_request(func() -> void:
		_local.global_position = point
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target()
		_local.movement.set_aim_override(Vector3.INF))


# Server -> client: watch `path` for a swing and its trail.
@rpc("authority", "call_remote", "reliable")
func client_watch_swing(path: NodePath, seconds: float) -> void:
	var body := get_node_or_null(path) as Player
	var out := {"seen": false, "samples": 0, "progress": -1.0}
	var t := 0.0
	while t < seconds and body != null:
		await get_tree().process_frame
		t += get_process_delta_time()
		if body.swing_active():
			out["seen"] = true
			out["progress"] = maxf(float(out["progress"]), body.swing_progress())
		out["samples"] = maxi(int(out["samples"]), body.trail_sample_count())
	report.rpc_id(1, "swing", out)


# Server -> client: count what this screen's feedback set does over `seconds`.
@rpc("authority", "call_remote", "reliable")
func client_watch_feedback(seconds: float) -> void:
	var fb := HitFeedback.instance
	var hits := fb.hits
	var numbers := fb.numbers
	var hitstops := fb.hitstops
	var self_flash := false
	var t := 0.0
	while t < seconds:
		await get_tree().process_frame
		t += get_process_delta_time()
		if _local.flash_left() > 0.0:
			self_flash = true
	report.rpc_id(1, "felt", {
		"hits": fb.hits - hits, "numbers": fb.numbers - numbers, "hitstops": fb.hitstops - hitstops,
		"value": fb.last_number_value, "self_flash": self_flash, "deduped": fb.deduped})


# Server -> client: watch a scarecrow for a hit seen from here.
@rpc("authority", "call_remote", "reliable")
func client_watch_dummy(path: NodePath, seconds: float) -> void:
	var dummy := get_node_or_null(path) as Dummy
	var fb := HitFeedback.instance
	var numbers := fb.numbers
	var flash := false
	var t := 0.0
	while t < seconds and dummy != null:
		await get_tree().process_frame
		t += get_process_delta_time()
		if dummy.flash_left() > 0.0:
			flash = true
	report.rpc_id(1, "watched", {"numbers": fb.numbers - numbers, "flash": flash, "target": fb.last_target})


# Server -> client: watch a scarecrow's telegraph fill and go.
@rpc("authority", "call_remote", "reliable")
func client_watch_telegraph(path: NodePath, seconds: float) -> void:
	var dummy := get_node_or_null(path) as Dummy
	var out := {"seen": false, "fill_max": 0.0, "hidden": false}
	var t := 0.0
	while t < seconds and dummy != null:
		await get_tree().process_frame
		t += get_process_delta_time()
		if dummy.telegraph_visible():
			out["seen"] = true
			out["fill_max"] = maxf(float(out["fill_max"]), dummy.telegraph_fill())
		elif bool(out["seen"]):
			out["hidden"] = true
			break
	report.rpc_id(1, "telegraph", out)


@rpc("authority", "call_remote", "reliable")
func finish(host_failures: int) -> void:
	print("C0_RESULT peer=%d checks=%d failures=%d host_failures=%d" % [
		_peer_id, _checks, _failures, host_failures])
	get_tree().quit(0 if _failures == 0 else 1)
