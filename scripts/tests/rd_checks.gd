extends Node

# RD: the race scarecrows. Four more scarecrows north of the spawn, one per
# race, carrying the race's weight and strength from the race data, so a
# party member of that race can be shoved, lifted and thrown with one machine.
# The host conducts; the client reports what its own screen holds, because a
# scarecrow built in code only moves there through push_state.
#
# What is measured: that the four stand where they were put with the race's
# numbers; that the lift limit reads those numbers (a human lifts the elf,
# not the human); that the knockback verdict reads them (an orc's shove
# launches the human scarecrow and slides off the orc one); that a scarecrow
# shoved off the plaza comes back to its mark.
#
# With --shot=<png> on a windowed host, the F1 panel is opened and the screen
# saved, so the panel's layout can be looked at from a log run.

const HOME := Vector3(6.5, 0.9, 16.5)
const CLIENT_HOME := Vector3(0.0, 0.9, 11.0)
const ROW_Z := 13.5
const STAND_BACK := Vector3(0.0, 0.0, 1.2)
const TRACK_SECONDS := 2.5

var _world: Node3D
var _local: Player
var _judge: ServerAuthority
var _peer_id := 0
var _checks := 0
var _failures := 0
var _stage_done := ""
var _reported := {}
var _shot_path := ""


func expect(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("RD_CHECK peer=%d %s %s" % [_peer_id, "PASS" if condition else "FAIL", label])


func note(line: String) -> void:
	print("RD_NOTE peer=%d %s" % [_peer_id, line])


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


func _wait_stage(name_text: String, limit := 25.0) -> bool:
	var waited := 0.0
	while _stage_done != name_text and waited < limit:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	var arrived := _stage_done == name_text
	_stage_done = ""
	return arrived


func _wait_report(key: String, limit := 20.0) -> bool:
	var waited := 0.0
	while not _reported.has(key) and waited < limit:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	return _reported.has(key)


func _client_peer() -> int:
	var peers := multiplayer.get_peers()
	return peers[0] if peers.size() > 0 else 0


func _dummy(kind: int) -> Dummy:
	return _world.get_node_or_null("Dummy_%s" % Races.Kind.keys()[kind].to_lower()) as Dummy


func run(world: Node3D) -> void:
	_world = world
	_peer_id = multiplayer.get_unique_id()
	_local = Net.spawn_root.get_node(str(_peer_id)) as Player
	_judge = world.get_node_or_null("ServerAuthority") as ServerAuthority
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--shot="):
			_shot_path = argument.trim_prefix("--shot=")
	if not multiplayer.is_server():
		stage_done.rpc_id(1, "client_ready")
		return
	expect(await _wait_stage("client_ready"), "both_peers_present")
	await _park(HOME)
	client_park.rpc_id(_client_peer(), CLIENT_HOME)
	await _wait(1.0)

	await _standing_checks()
	await _lift_checks()
	await _knockback_checks()
	await _fall_return_check()

	client_report.rpc_id(_client_peer())
	expect(await _wait_report("dummies"), "client_reported_its_scarecrows")
	var seen: PackedFloat32Array = _reported.get("dummies", PackedFloat32Array())
	if seen.size() == Races.all_kinds().size() * 3:
		for index in Races.all_kinds().size():
			var kind: int = Races.all_kinds()[index]
			var dummy := _dummy(kind)
			var gap := seen[index * 3]
			note("client's %s scarecrow: %.2f m from its mark, weight %.0f strength %.0f" % [
				Races.label_for(kind), gap, seen[index * 3 + 1], seen[index * 3 + 2]])
			expect(gap < 0.5, "client_sees_the_%s_scarecrow_at_its_mark" % Races.Kind.keys()[kind].to_lower())
			expect(is_equal_approx(seen[index * 3 + 1], dummy.weight())
				and is_equal_approx(seen[index * 3 + 2], dummy.strength()),
				"client_builds_the_%s_scarecrow_with_the_same_numbers" % Races.Kind.keys()[kind].to_lower())

	if _shot_path != "":
		await _panel_shot()
	print("RD_RESULT peer=%d checks=%d failures=%d" % [_peer_id, _checks, _failures])
	await _wait(1.0)
	get_tree().quit(0 if _failures == 0 else 1)


func _standing_checks() -> void:
	var expected_x := 3.5
	for kind in Races.all_kinds():
		var dummy := _dummy(kind)
		var data := Races.data_for(kind)
		expect(dummy != null, "the_%s_scarecrow_exists" % Races.Kind.keys()[kind].to_lower())
		if dummy == null:
			expected_x += 2.0
			continue
		var p := dummy.global_position
		note("%s: at (%.2f, %.2f, %.2f) on_floor=%s weight %.0f strength %.0f label '%s'" % [
			Races.label_for(kind), p.x, p.y, p.z, dummy.is_on_floor(), dummy.weight(), dummy.strength(),
			dummy.race_label()])
		expect(absf(p.x - expected_x) < 0.1 and absf(p.z - ROW_Z) < 0.1 and p.y > 0.7 and p.y < 1.2
			and dummy.is_on_floor(), "it_stands_on_its_mark")
		expect(is_equal_approx(dummy.weight(), data.body_weight)
			and is_equal_approx(dummy.strength(), data.strength),
			"it_carries_the_races_weight_and_strength")
		expect(is_equal_approx(_judge.weight_of(dummy), data.body_weight),
			"the_judge_reads_that_weight")
		expected_x += 2.0
	var plain := _world.get_node_or_null("Dummy_0") as Dummy
	expect(plain != null and is_equal_approx(plain.weight(), Dummy.WEIGHT) and plain.strength() == 0.0,
		"the_plain_scarecrows_keep_their_12_kg_and_no_strength")


# A human (strength 60, limit 72 kg) lifts the elf (60 kg) and not the human
# (80 kg): the same lift formula a player's body goes through.
func _lift_checks() -> void:
	expect(_local.stats.race == Races.Kind.HUMAN, "the_host_is_human_for_the_lift")
	note("human lift limit %.1f kg" % _judge.lift_limit(_local))
	var elf := _dummy(Races.Kind.ELF)
	var human := _dummy(Races.Kind.HUMAN)
	await _stand_at(elf)
	await tick_request(func() -> void:
		_local.movement.set_aim_override(elf.global_position)
		_local.movement.interact())
	await _wait(0.6)
	expect(_judge.holder_of(elf) == 1 and _local.grab.is_holding(), "a_human_lifts_the_elf_scarecrow")
	await tick_request(func() -> void:
		_local.movement.set_aim_override(Vector3.INF)
		_local.grab.drop())
	await _wait(0.8)
	expect(_judge.holder_of(elf) == 0, "and_puts_it_down")
	await _stand_at(human)
	var rejected := _judge.rejected_intents
	await tick_request(func() -> void:
		_local.movement.set_aim_override(human.global_position)
		_local.movement.interact())
	await _wait(0.6)
	note("human on the human scarecrow: holder=%d rejected +%d" % [
		_judge.holder_of(human), _judge.rejected_intents - rejected])
	expect(_judge.holder_of(human) == 0 and not _local.grab.is_holding(),
		"a_human_cannot_lift_the_human_scarecrow")
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))


# The verdict, through the same door a player gets it from. A human's shove
# on the human scarecrow is inside its tolerance (7 x ~0.97 < 7.2): a slide.
# An orc's is over it: a launch. The orc scarecrow's tolerance (12) holds
# against the orc's shove too.
func _knockback_checks() -> void:
	Tuning.values.smart_key_enabled = true
	var human := _dummy(Races.Kind.HUMAN)
	var orc := _dummy(Races.Kind.ORC)
	var verdict := await _shove(human)
	note("human shoves the human scarecrow: launched=%s tolerance=%.2f push=%.2f" % [
		verdict["launched"], verdict["tolerance"], verdict["push"]])
	expect(not verdict["launched"] and is_equal_approx(verdict["tolerance"],
		Races.data_for(Races.Kind.HUMAN).strength * Tuning.server.tolerance_per_strength),
		"a_humans_shove_slides_off_the_human_scarecrow")
	await _wait(3.5)

	await tick_request(func() -> void:
		ServerAuthority.submit_intent(_local, ServerAuthority.Intent.RACE, {"race": Races.Kind.ORC}))
	await _wait(0.3)
	expect(_local.stats.race == Races.Kind.ORC, "the_host_became_an_orc")
	client_watch.rpc_id(_client_peer(), human.get_path(), TRACK_SECONDS + 3.0)
	await _wait(0.3)
	verdict = await _shove(human)
	note("orc shoves the human scarecrow: launched=%s tolerance=%.2f push=%.2f" % [
		verdict["launched"], verdict["tolerance"], verdict["push"]])
	expect(verdict["launched"], "an_orcs_shove_launches_the_human_scarecrow")
	expect(await _wait_report("watch"), "client_reported_what_it_saw")
	var seen: PackedFloat32Array = _reported.get("watch", PackedFloat32Array())
	if seen.size() >= 1:
		note("client saw the human scarecrow move %.2f m" % seen[0])
		expect(seen[0] > 1.0, "client_saw_the_human_scarecrow_fly")
	await _wait(3.5)

	verdict = await _shove(orc)
	note("orc shoves the orc scarecrow: launched=%s tolerance=%.2f push=%.2f" % [
		verdict["launched"], verdict["tolerance"], verdict["push"]])
	expect(not verdict["launched"] and is_equal_approx(verdict["tolerance"],
		Races.data_for(Races.Kind.ORC).strength * Tuning.server.tolerance_per_strength),
		"an_orcs_shove_slides_off_the_orc_scarecrow")
	await _wait(3.5)


func _shove(dummy: Dummy) -> Dictionary:
	await _stand_at(dummy)
	await tick_request(func() -> void: _local.movement.set_aim_override(dummy.global_position))
	await _wait(0.2)
	var before_hp := dummy.hp
	await tick_request(func() -> void: _local.skills.press_slot(0))
	var waited := 0.0
	while waited < 1.5 and is_equal_approx(dummy.hp, before_hp):
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	await get_tree().physics_frame
	var push := Vector2(dummy.velocity.x, dummy.velocity.z).length()
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	return {"launched": dummy.last_launched, "tolerance": dummy.last_tolerance,
		"push": push, "hit": not is_equal_approx(dummy.hp, before_hp)}


# Shoved off the plaza: it comes back to its mark instead of falling forever.
func _fall_return_check() -> void:
	var elf := _dummy(Races.Kind.ELF)
	await tick_request(func() -> void:
		elf.global_position = elf.home + Vector3(0.0, Tuning.server.kill_plane_y - 5.0, 0.0))
	await _wait(0.6)
	note("elf scarecrow after the drop: %.2f m from its mark" % elf.global_position.distance_to(elf.home))
	expect(elf.global_position.distance_to(elf.home) < 0.5, "a_scarecrow_off_the_world_returns_to_its_mark")


func _stand_at(dummy: Dummy) -> void:
	await _park(dummy.home + STAND_BACK + Vector3(0.0, 0.9, 0.0))


func _park(point: Vector3) -> void:
	await tick_request(func() -> void:
		placed()
		if _judge.is_judge():
			_judge.server_respawn(_local)
		_local.global_position = point
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target())
	await _wait(0.6)


func _panel_shot() -> void:
	# The panel hangs off the scene, not the body (player.gd: the body's
	# parent is the spawner's path, where anything is a replicated player).
	var panel := get_tree().current_scene.get_node_or_null("DebugPanel") as CanvasLayer
	if panel == null:
		note("no debug panel on the local body")
		return
	panel.visible = true
	await _wait(0.3)
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var error := image.save_png(_shot_path)
	print("RD_SHOT path=%s error=%d" % [_shot_path, error])


# --------------------------------------------------------------------- RPCs

@rpc("any_peer", "call_remote", "reliable")
func stage_done(name_text: String) -> void:
	if multiplayer.is_server() and multiplayer.get_peers().has(multiplayer.get_remote_sender_id()):
		_stage_done = name_text


@rpc("any_peer", "call_remote", "reliable")
func report_numbers(what: String, values: PackedFloat32Array) -> void:
	if multiplayer.is_server() and multiplayer.get_peers().has(multiplayer.get_remote_sender_id()):
		_reported[what] = values


@rpc("authority", "call_remote", "reliable")
func client_park(point: Vector3) -> void:
	await _park(point)


# The client's own copies: where they stand and what numbers they carry.
@rpc("authority", "call_remote", "reliable")
func client_report() -> void:
	var values := PackedFloat32Array()
	for kind in Races.all_kinds():
		var dummy := _dummy(kind)
		if dummy == null:
			values.append_array(PackedFloat32Array([INF, 0.0, 0.0]))
			continue
		values.append(dummy.global_position.distance_to(dummy.home))
		values.append(dummy.weight())
		values.append(dummy.strength())
	report_numbers.rpc_id(1, "dummies", values)


# The client watches one scarecrow and reports how far it got from its mark.
@rpc("authority", "call_remote", "reliable")
func client_watch(dummy_path: NodePath, seconds: float) -> void:
	var dummy := get_node_or_null(dummy_path) as Dummy
	if dummy == null:
		report_numbers.rpc_id(1, "watch", PackedFloat32Array())
		return
	var origin := dummy.global_position
	var max_gap := 0.0
	var elapsed := 0.0
	while elapsed < seconds:
		await get_tree().physics_frame
		elapsed += get_physics_process_delta_time()
		max_gap = maxf(max_gap, dummy.global_position.distance_to(origin))
	report_numbers.rpc_id(1, "watch", PackedFloat32Array([max_gap]))
