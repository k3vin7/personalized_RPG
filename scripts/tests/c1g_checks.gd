extends Node

# C-1g-a: the sweep ruling. The side cut and the overhead cut are no longer
# one fan at the impact: the server follows the blade through its arc
# (SkillDef.arc_deg, the server's side_cut_arc_deg / overhead_cut_arc_deg)
# on the same easing the picture uses, and a body is hit the tick the blade
# reaches it, once per swing. What is measured here is the ruling: which
# scarecrows a swing reaches, in what order, how many times, and that the
# slider moves it. Two peers: the host rules, and the client's own cut is
# ruled the same way. Nothing here reads the picture (C-1g-b measures it).

# A clear spot in the arena, between the plain scarecrows' row (z 2) and
# the race row (z 13.5). The caster faces north (-Z).
const SPOT := Regions.ARENA + Vector3(0.0, 0.9, 7.0)
const CLIENT_SPOT := Regions.ARENA + Vector3(-6.0, 0.9, 7.0)
const HEADING := Vector3(0.0, 0.0, -1.0)
const RING := 1.5
const DUMMIES := ["Dummy_0", "Dummy_1", "Dummy_human"]

var _world: Node3D
var _local: Player
var _judge: ServerAuthority
var _peer_id := 0
var _checks := 0
var _failures := 0
var _stage_done := ""
var _reports := {}
var _homes := {}
# With --shot=<dir> on a windowed host, a frame of each layout is saved
# there mid-swing (the trail is drawn); headless, nothing is saved.
var _shot_dir := ""
var shots_saved := 0


func expect(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("C1G_CHECK peer=%d %s %s" % [_peer_id, "PASS" if condition else "FAIL", label])


func note(line: String) -> void:
	print("C1G_NOTE peer=%d %s" % [_peer_id, line])


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


func _dummy(index: int) -> Dummy:
	return _world.get_node(DUMMIES[index]) as Dummy


func _wait_idle(seconds := 3.0) -> void:
	var waited := 0.0
	while _local.state != Player.State.IDLE and waited < seconds:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()


func _park(at: Vector3, aim: Vector3) -> void:
	await tick_request(func() -> void:
		placed()
		_local.global_position = at
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target()
		_local.movement.cancel_armed()
		_local.movement.set_aim_override(aim))
	await _wait(0.5)


func _take_sword() -> void:
	await tick_request(func() -> void: _local.set_weapon(WeaponKinds.Kind.SWORD))
	var waited := 0.0
	while _local.weapon != WeaponKinds.Kind.SWORD and waited < 3.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	await _wait(0.2)


# A point `distance` from `centre` at `bearing` degrees off `heading`, left
# positive -- the server's convention for the sweep.
static func _around(centre: Vector3, heading: Vector3, bearing_deg: float, distance: float) -> Vector3:
	var at := centre + heading.rotated(Vector3.UP, deg_to_rad(bearing_deg)) * distance
	return Vector3(at.x, 1.0, at.z)


# The three scarecrows on marks around `centre`: their home moves with them,
# so the walk-home and the refill happen on the new mark.
func _place(centre: Vector3, heading: Vector3, bearings: Array, distance := RING) -> void:
	await tick_request(func() -> void:
		for index in bearings.size():
			var dummy := _dummy(index)
			var mark := _around(centre, heading, float(bearings[index]), distance)
			dummy.home = mark
			dummy.release_to(mark))
	await _wait(0.8)


func _restore_homes() -> void:
	await tick_request(func() -> void:
		for index in DUMMIES.size():
			var dummy := _dummy(index)
			var home: Vector3 = _homes[dummy.name]
			dummy.home = home
			dummy.release_to(home))
	await _wait(0.5)


# Casts `slot` and waits for the ruling to finish (a sweep ends at the end
# of the swing). Returns the judge's last_strike.
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


# The arc is about the body where it stands at the impact (where the blade
# starts moving). The cast step (2026-11-04) has carried it
# step_distance x windup / (windup + swing) ahead of the press by then, so
# the marks are set about that point.
func _origin_of(def: SkillDef, from: Vector3, heading: Vector3) -> Vector3:
	var windup := def.value("windup")
	return from + heading * def.step_distance * windup / maxf(windup + def.swing_time(), 0.001)


static func _names(order: Array) -> Array:
	var out := []
	for entry: Dictionary in order:
		out.append(String(entry["target"]))
	return out


# Saves a frame `after` seconds from now, without holding up the caller:
# called (not awaited) just before a press, it lands mid-swing.
func _shot_after(label: String, after: float) -> void:
	if _shot_dir == "" or DisplayServer.get_name() == "headless":
		return
	await _wait(after)
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [_shot_dir, label]
	var error := image.save_png(path)
	shots_saved += 1 if error == OK else 0
	print("C1G_SHOT path=%s error=%d" % [path, error])


func _hp_of(indices: Array) -> Array:
	var out := []
	for index: int in indices:
		out.append(_dummy(index).hp)
	return out


# The scarecrow's hit ring holds the last few hit ids (Dummy.HIT_RING), so
# its size stops counting; the ids themselves only grow. "Hit since" is the
# number of ids in the ring above the last one seen before.
func _hits_of(indices: Array) -> Array:
	var out := []
	for index: int in indices:
		out.append(_dummy(index).last_hit_id())
	return out


func _new_hits(index: int, since: int) -> int:
	var count := 0
	for id in _dummy(index).hit_ids:
		if int(id) > since:
			count += 1
	return count


func run(world: Node3D) -> void:
	_world = world
	_peer_id = multiplayer.get_unique_id()
	_local = Net.spawn_root.get_node(str(_peer_id)) as Player
	_judge = world.get_node_or_null("ServerAuthority") as ServerAuthority
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--shot="):
			_shot_dir = argument.trim_prefix("--shot=")
	if not multiplayer.is_server():
		stage_done.rpc_id(1, "client_ready")
		return
	expect(await _wait_stage("client_ready"), "both_peers_present")
	for index in DUMMIES.size():
		_homes[_dummy(index).name] = _dummy(index).home
	var warnings := _judge.move_warnings
	var corrections := _judge.move_corrections
	var smart: bool = Tuning.values.smart_key_enabled
	Tuning.values.smart_key_enabled = true
	await _take_sword()
	_data_checks()
	await _side_cut_checks()
	await _slider_checks()
	await _overhead_checks()
	await _client_checks()
	await _restore_homes()
	Tuning.values.smart_key_enabled = smart
	expect(_judge.move_warnings == warnings, "no_move_warnings_during_c1g")
	expect(_judge.move_corrections == corrections, "no_corrections_during_c1g")
	print("C1G_RESULT peer=%d checks=%d failures=%d" % [_peer_id, _checks, _failures])
	finish.rpc(_failures)
	await _wait(1.0)
	get_tree().quit(0 if _failures == 0 else 1)


# ------------------------------------------------- 1: the numbers, one source

func _data_checks() -> void:
	var side := Skills.get_def("side_cut")
	var over := Skills.get_def("overhead_cut")
	var thrust := Skills.get_def("thrust")
	var parry := Skills.get_def("parry")
	note("side cut: arc %.0f (server side_cut_arc_deg %.0f) from %.0f to %.0f, centred=%s reversed=%s sweep=%s plane=%s over %.2f s" % [
		side.arc_degrees(), Tuning.server.side_cut_arc_deg, side.arc_start(), side.arc_end(),
		side.arc_centred, side.arc_reversed, side.judge_by_sweep, SkillDef.ArcPlane.keys()[side.arc_plane], side.swing_time()])
	expect(absf(side.arc_degrees() - 240.0) < 0.001 and absf(Tuning.server.side_cut_arc_deg - 240.0) < 0.001
		and side.judge_by_sweep and side.arc_centred and side.arc_plane == SkillDef.ArcPlane.HORIZONTAL
		and absf(side.arc_start() - 120.0) < 0.001 and absf(side.arc_end() + 120.0) < 0.001,
		"the_side_cuts_arc_is_the_servers_240_centred_on_the_heading_left_to_right")
	note("overhead cut: arc %.0f (server overhead_cut_arc_deg %.0f) from %.0f to %.0f, width %.1f, sweep=%s plane=%s over %.2f s" % [
		over.arc_degrees(), Tuning.server.overhead_cut_arc_deg, over.arc_start(), over.arc_end(),
		over.value("width"), over.judge_by_sweep, SkillDef.ArcPlane.keys()[over.arc_plane], over.swing_time()])
	expect(absf(over.arc_degrees() - 120.0) < 0.001 and absf(Tuning.server.overhead_cut_arc_deg - 120.0) < 0.001
		and over.judge_by_sweep and not over.arc_centred and over.arc_plane == SkillDef.ArcPlane.VERTICAL
		and absf(over.arc_start() - 90.0) < 0.001 and absf(over.arc_end() + 30.0) < 0.001
		and absf(over.value("width") - 0.4) < 0.001,
		"the_overhead_cuts_arc_is_the_servers_120_from_straight_up_down_past_horizontal_width_unchanged")
	expect(thrust.is_thrust_motion() and not thrust.judge_by_sweep
		and absf(parry.arc_degrees() - 30.0) < 0.001 and not parry.judge_by_sweep,
		"the_thrust_and_the_parry_are_not_sweeps_and_keep_their_numbers")
	# The margin rule: ruling >= drawn - margin, ruling <= drawn + margin.
	# Until C-1g-b measures the model, the drawn arc is the pivot's, which is
	# the same number -- the rule holds with 0 to spare, and the slider exists.
	var margin: float = Tuning.server.swing_arc_margin_deg
	var side_drawn := absf(side.swing_angle_deg(1.0) - side.swing_angle_deg(0.0))
	var over_drawn := absf(over.swing_angle_deg(1.0) - over.swing_angle_deg(0.0))
	note("margin %.0f deg: side cut ruling %.0f vs pivot arc %.0f | overhead ruling %.0f vs pivot arc %.0f" % [
		margin, side.arc_degrees(), side_drawn, over.arc_degrees(), over_drawn])
	expect(absf(margin - 20.0) < 0.001 and absf(side.arc_degrees() - side_drawn) <= margin
		and absf(over.arc_degrees() - over_drawn) <= margin,
		"the_ruling_arc_is_within_the_margin_of_the_drawn_arc_and_the_margin_is_a_20_deg_slider")
	# The easing is one function: the blade at half time is past half the arc.
	expect(absf(SkillDef.swing_eased(0.5) - 0.75) < 0.001 and SkillDef.swing_eased(0.0) == 0.0
		and SkillDef.swing_eased(1.0) == 1.0, "the_swing_easing_is_shared_and_front_loaded")


# ------------------------------------------------- 2: the side cut sweeps

func _side_cut_checks() -> void:
	var side := Skills.get_def("side_cut")
	var damage := side.value("damage") * Weapons.attack_power_for("sword")
	await _park(SPOT, SPOT + HEADING * 6.0)
	var origin := _origin_of(side, SPOT, HEADING)
	note("side cut marks about %s (the body stands at %s at the press, steps %.2f m by the impact)" % [
		origin, SPOT, (origin - SPOT).length()])
	# Front, 110 left, 110 right: all three inside 120 to each side.
	await _place(origin, HEADING, [0.0, 110.0, -110.0])
	var hp_before := _hp_of([0, 1, 2])
	var hits_before := _hits_of([0, 1, 2])
	_shot_after("a_side_cut_front_110_110", side.value("windup") + side.swing_time() * 0.7)
	var strike := await _cast_and_wait(1)
	var sweep := _judge.last_sweep.duplicate(true)
	var hp_after := _hp_of([0, 1, 2])
	var hits_after := _hits_of([0, 1, 2])
	note("side cut over front / left 110 / right 110 at %.1f m: %s | sweep %s | hp %s -> %s | hit counts %s -> %s" % [
		RING, strike, sweep, hp_before, hp_after, hits_before, hits_after])
	var each_once := true
	for index in 3:
		each_once = each_once and absf((float(hp_before[index]) - float(hp_after[index])) - damage) < 0.01 \
			and _new_hits(index, int(hits_before[index])) == 1
	expect(String(strike.get("skill", "")) == "side_cut" and int(strike.get("hits", 0)) == 3 and each_once,
		"one_side_cut_hits_the_front_the_110_left_and_the_110_right_scarecrows_once_each")
	# The order the blade reached them: left (where the swing starts), front,
	# right -- and later each time. An instant fan would stamp them together.
	var order: Array = sweep.get("order", [])
	var names := _names(order)
	var times := []
	for entry: Dictionary in order:
		times.append(int(entry["ms"]))
	note("sweep order: %s at %s ms, bearings %s, origin %s (marks about %s)" % [names, times,
		order.map(func(entry: Dictionary) -> String: return "%.1f" % float(entry["bearing"])),
		sweep.get("origin", Vector3.INF), origin])
	expect(names == ["Dummy_1", "Dummy_0", "Dummy_human"] and times.size() == 3
		and int(times[0]) < int(times[1]) and int(times[1]) < int(times[2]),
		"the_blade_reaches_the_left_one_first_then_the_front_then_the_right_at_later_ticks")
	await _wait_idle()
	# 130 to each side: outside. The front one is sent out of reach behind.
	await _place(origin, HEADING, [180.0, 130.0, -130.0], RING)
	await tick_request(func() -> void:
		var far := _around(origin, HEADING, 180.0, 3.0)
		_dummy(0).home = far
		_dummy(0).release_to(far))
	await _wait(0.8)
	hits_before = _hits_of([1, 2])
	_shot_after("a_side_cut_130_130_missed", side.value("windup") + side.swing_time() * 0.9)
	strike = await _cast_and_wait(1)
	hits_after = _hits_of([1, 2])
	note("side cut with scarecrows at 130 left / 130 right at %.1f m: %s | hit counts %s -> %s" % [RING, strike, hits_before, hits_after])
	expect(int(strike.get("hits", 0)) == 0 and hits_before == hits_after,
		"the_130_left_and_130_right_scarecrows_are_not_reached")
	await _wait_idle()


# ------------------------------------------------- 3: the slider moves the ruling

func _slider_checks() -> void:
	var side := Skills.get_def("side_cut")
	var origin := _origin_of(side, SPOT, HEADING)
	await _place(origin, HEADING, [0.0, 110.0, -110.0])
	var was: float = Tuning.server.side_cut_arc_deg
	Tuning.server.side_cut_arc_deg = 180.0
	await _wait(0.2)
	note("side_cut_arc_deg %.0f -> %.0f: def reads %.0f, arc %.0f to %.0f" % [
		was, Tuning.server.side_cut_arc_deg, side.arc_degrees(), side.arc_start(), side.arc_end()])
	var hits_before := _hits_of([0, 1, 2])
	var strike := await _cast_and_wait(1)
	var hits_after := _hits_of([0, 1, 2])
	note("side cut at 180 deg over front / 110 left / 110 right: %s | hit counts %s -> %s" % [strike, hits_before, hits_after])
	expect(absf(side.arc_degrees() - 180.0) < 0.001 and int(strike.get("hits", 0)) == 1
		and _new_hits(0, int(hits_before[0])) == 1 and hits_before[1] == hits_after[1] and hits_before[2] == hits_after[2],
		"at_180_deg_the_same_swing_reaches_only_the_front_one_the_slider_is_the_ruling")
	Tuning.server.side_cut_arc_deg = was
	await _wait(0.2)
	expect(absf(side.arc_degrees() - 240.0) < 0.001, "and_back_at_240_the_def_reads_240")
	await _wait_idle()


# ------------------------------------------------- 4: the overhead cut sweeps a vertical plane

func _overhead_checks() -> void:
	var over := Skills.get_def("overhead_cut")
	var damage := over.value("damage") * Weapons.attack_power_for("sword")
	await _park(SPOT, SPOT + HEADING * 6.0)
	var origin := _origin_of(over, SPOT, HEADING)
	# Front on the ground at 1.2 m; one held above the head (centre 2 m up,
	# 1 m ahead: jump height; parked 90 left first so nothing overlaps); one
	# 45 left at 1.5 m.
	await _place(origin, HEADING, [0.0, 90.0, 45.0], 1.2)
	await tick_request(func() -> void:
		var above := origin + HEADING * 1.0 + Vector3.UP * 2.0
		_dummy(1).harness_pin(above, 12.0)
		var left := _around(origin, HEADING, 45.0, RING)
		_dummy(2).home = left
		_dummy(2).release_to(left))
	await _wait(0.8)
	var above_dummy := _dummy(1)
	var dy := above_dummy.global_position.y - (origin.y + over.strike_height)
	var ahead := (above_dummy.global_position - origin).dot(HEADING)
	note("above: centre %.2f over the pivot, %.2f ahead: pitch span %.0f..%.0f deg (C-1b's 40 deg fan at that distance reached %.2f up)" % [
		dy, ahead, rad_to_deg(atan2(dy - Dummy.HALF_HEIGHT, ahead)), rad_to_deg(atan2(dy + Dummy.HALF_HEIGHT, ahead)),
		tan(deg_to_rad(20.0)) * ahead + Dummy.HALF_HEIGHT])
	var hp_before := _hp_of([0, 1, 2])
	var hits_before := _hits_of([0, 1, 2])
	_shot_after("a_overhead_front_above_45left", over.value("windup") + over.swing_time() * 0.6)
	var strike := await _cast_and_wait(2)
	var sweep := _judge.last_sweep.duplicate(true)
	var hp_after := _hp_of([0, 1, 2])
	var hits_after := _hits_of([0, 1, 2])
	note("overhead cut over front 1.2 m / above / 45 left: %s | sweep %s | hp %s -> %s | hit counts %s -> %s | last hit dealt %.1f (want %.1f)" % [
		strike, sweep, hp_before, hp_after, hits_before, hits_after, float(_judge.last_hit.get("dealt", 0.0)), damage])
	expect(String(strike.get("skill", "")) == "overhead_cut" and int(strike.get("hits", 0)) == 2
		and _new_hits(0, int(hits_before[0])) == 1
		and _new_hits(1, int(hits_before[1])) == 1
		and hits_before[2] == hits_after[2]
		and absf(float(_judge.last_hit.get("dealt", 0.0)) - damage) < 0.01,
		"the_overhead_cut_hits_the_one_in_front_and_the_one_above_the_head_not_the_one_45_left")
	var names := _names(sweep.get("order", []))
	expect(names == ["Dummy_1", "Dummy_0"], "the_blade_reaches_the_one_above_before_the_one_in_front")
	await _wait_idle()
	# The front one was knocked back and waits before walking home: put it
	# on its mark again, and the third one 45 right.
	await _park(SPOT, SPOT + HEADING * 6.0)
	await tick_request(func() -> void:
		_dummy(0).release_to(_dummy(0).home)
		var right := _around(origin, HEADING, -45.0, RING)
		_dummy(2).home = right
		_dummy(2).release_to(right))
	await _wait(0.8)
	hits_before = _hits_of([0, 1, 2])
	strike = await _cast_and_wait(2)
	hits_after = _hits_of([0, 1, 2])
	note("overhead cut over front / above / 45 right: %s | hit counts %s -> %s" % [strike, hits_before, hits_after])
	expect(int(strike.get("hits", 0)) == 2 and _new_hits(0, int(hits_before[0])) == 1
		and _new_hits(1, int(hits_before[1])) == 1 and hits_before[2] == hits_after[2],
		"nor_the_one_45_right_the_width_is_unchanged")
	await _wait_idle()
	await tick_request(func() -> void: _dummy(1).harness_pin(_dummy(1).home, 0.0))
	await _wait(0.5)


# ------------------------------------------------- 5: the client's cut, ruled here

func _client_checks() -> void:
	var mate := _mate()
	if mate == null:
		expect(false, "the_client_has_a_body")
		return
	_reports.erase("weapon")
	client_take_weapon.rpc_id(_client_peer(), WeaponKinds.Kind.SWORD)
	await _wait_report("weapon")
	client_park.rpc_id(_client_peer(), CLIENT_SPOT)
	await _wait(1.2)
	await _place(_origin_of(Skills.get_def("side_cut"), CLIENT_SPOT, HEADING), HEADING, [0.0, 110.0, -110.0])
	var hits_before := _hits_of([0, 1, 2])
	var ruled := _judge.skills_ruled
	var before := _judge.last_strike.duplicate()
	_reports.erase("cast")
	client_cast_at.rpc_id(_client_peer(), CLIENT_SPOT + HEADING * 6.0, 1)
	var waited := 0.0
	while _judge.last_strike == before and waited < 4.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	var strike := _judge.last_strike
	var hits_after := _hits_of([0, 1, 2])
	await _wait_report("cast")
	note("the client's side cut over front / 110 left / 110 right (client at %s, mate here at %s): ruled %d -> %d, %s | hit counts %s -> %s | sweep %s" % [
		CLIENT_SPOT, mate.global_position, ruled, _judge.skills_ruled, strike, hits_before, hits_after, _judge.last_sweep])
	var each := true
	for index in 3:
		each = each and _new_hits(index, int(hits_before[index])) == 1
	expect(String(strike.get("by", "")) == mate.name and String(strike.get("skill", "")) == "side_cut"
		and int(strike.get("hits", 0)) == 3 and each,
		"the_clients_side_cut_is_swept_on_the_host_and_reaches_all_three")
	_reports.erase("weapon")
	client_take_weapon.rpc_id(_client_peer(), WeaponKinds.Kind.NONE)
	await _wait_report("weapon")


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


@rpc("authority", "call_remote", "reliable")
func client_take_weapon(kind: int) -> void:
	await tick_request(func() -> void: _local.set_weapon(kind))
	var waited := 0.0
	while _local.weapon != kind and waited < 3.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	await _wait(0.2)
	report.rpc_id(1, "weapon", _local.weapon)


# Server -> client: cast `slot` at a point.
@rpc("authority", "call_remote", "reliable")
func client_cast_at(aim: Vector3, slot: int) -> void:
	var was: bool = Tuning.values.smart_key_enabled
	Tuning.values.smart_key_enabled = true
	var started := _local.skills.casts_started
	await tick_request(func() -> void:
		_local.movement.set_aim_override(aim)
		_local.skills.press_slot(slot))
	await _wait(0.8)
	report.rpc_id(1, "cast", {"slot": slot, "started": _local.skills.casts_started - started})
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	Tuning.values.smart_key_enabled = was


@rpc("authority", "call_remote", "reliable")
func finish(host_failures: int) -> void:
	print("C1G_RESULT peer=%d checks=%d failures=%d host_failures=%d" % [
		_peer_id, _checks, _failures, host_failures])
	get_tree().quit(0 if _failures == 0 else 1)
