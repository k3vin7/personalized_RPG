extends Node

# RC (2026-11-22): the rising cut and its dive (rising_cut_m2, mastery 2), on
# both peers.
#
#   host:   --auto-host --auto-smoke --auto-only=RC --auto-port=P --auto-quit=90
#   client: --auto-join --auto-smoke --auto-only=RC --auto-port=P --auto-quit=90
#
# The client goes first, then the host. Before each turn the host stands its
# own body 1.8 m east of the client's; the one whose turn it is aims at the
# other and casts the rising cut, pressing its slot again during the windup:
#   1. the dive follows, and starts at the top of the leap (windup + swing +
#      combo_next_at after the press, the body near its highest);
#   2. the body comes back down to the height it left from and stays there
#      (no correction from the server);
#   3. the server ruled the step (no refusal) and the dive's landing hit the
#      other body (host only: what the server's strikes said, per caster).
# Mastery is Tuning.server.mastery_debug_level (5 unless changed).

const SEQUENCE_AT := 12.0
const GAP := 1.8

var _world: Node3D
var _local: Player
var _mate: Player
var _peer_id := 0
var _checks := 0
var _failures := 0
var _lag := 0.0
var _mate_stamps := {}
var _started_msec := 0
var _judge: ServerAuthority
# Host only: the dive's hits per caster, off the server's strike rulings.
var _dive_hits := {}
var _last_seen := {}
# Kept at the start: the client may have left before the host's last checks.
var _mate_name := ""
var _own_name := ""


func expect(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("RC_CHECK peer=%d %s %s" % [_peer_id, "PASS" if condition else "FAIL", label])


func note(line: String) -> void:
	print("RC_NOTE peer=%d %s" % [_peer_id, line])


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _elapsed() -> float:
	return float(Time.get_ticks_msec() - _started_msec) / 1000.0


func _game_seconds() -> float:
	return float(Engine.get_physics_frames()) / float(Engine.physics_ticks_per_second)


func _process(_delta: float) -> void:
	if is_instance_valid(_mate) and _mate.sync_skill_id != "":
		_mate_stamps[_mate.sync_skill_id] = true
	if _judge != null and _judge.last_strike != _last_seen:
		_last_seen = _judge.last_strike.duplicate()
		if String(_last_seen.get("skill", "")) == "rising_cut_m2":
			var by := String(_last_seen.get("by", ""))
			_dive_hits[by] = int(_dive_hits.get(by, 0)) + int(_last_seen.get("hits", 0))
			note("server: dive by %s hit %d" % [by, int(_last_seen.get("hits", 0))])


func run(world: Node3D) -> void:
	_world = world
	_peer_id = multiplayer.get_unique_id()
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--be-latency="):
			_lag = argument.trim_prefix("--be-latency=").to_float() / 1000.0
	if multiplayer.is_server():
		_judge = world.get_node_or_null("ServerAuthority") as ServerAuthority
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
	_mate_name = str(_mate.name)
	_own_name = str(_local.name)
	await _wait(1.0)
	_local.set_weapon(WeaponKinds.Kind.SWORD)
	await _wait(1.5 + _lag * 2.0)
	expect(_local.weapon == WeaponKinds.Kind.SWORD, "the_sword_is_in_hand")
	while _elapsed() < SEQUENCE_AT + _lag * 2.0:
		await _wait(0.05)
	var rise := Skills.get_def("rising_cut")
	var dive := Skills.get_def("rising_cut_m2")
	note("mastery %d; rising cut windup %.3f swing %.3f next at %.3f; dive windup %.3f radius %.2f range %.2f; lag %.0f ms" % [
		int(Tuning.server.mastery_debug_level), rise.value("windup"), rise.swing_time(), rise.combo_next_delay(),
		dive.value("windup"), dive.circle_radius_value(), dive.value("reach"), _lag * 1000.0])
	var is_host := multiplayer.is_server()
	if is_host:
		await _stand_by_mate()
		await _until(func() -> bool: return _mate_stamps.has("rising_cut_m2"), 40.0)
		await _wait(4.0 + _lag * 4.0)
		await _stand_by_mate()
		await _turn()
		await _wait(4.0 + _lag * 4.0)
		note("server: dive hits by caster %s; combo steps ruled %d refused %d; move warnings %d" % [
			_dive_hits, _judge.combo_steps_ruled if _judge else -1, _judge.combo_steps_refused if _judge else -1,
			_judge.move_warnings if _judge else -1])
		if _judge != null:
			expect(_judge.combo_steps_ruled == 2 and _judge.combo_steps_refused == 0, "the_server_ruled_both_dives")
			expect(int(_dive_hits.get(_mate_name, 0)) >= 1, "the_clients_dive_hit_the_host")
			expect(int(_dive_hits.get(_own_name, 0)) >= 1, "the_hosts_dive_hit_the_client")
	else:
		await _until(func() -> bool: return _flat_gap() < GAP + 0.4, 60.0)
		await _wait(1.0)
		await _turn()
		await _until(func() -> bool: return _mate_stamps.has("rising_cut_m2"), 40.0)
		await _wait(4.0 + _lag * 4.0)
	_finish()


# This body's turn: aim at the other, the rising cut with a second press in
# its windup, then watch the dive.
func _turn() -> void:
	var slot := -1
	for index in PlayerSkills.SLOT_COUNT:
		var held := _local.skills.slot_def(index)
		if held != null and held.id == "rising_cut":
			slot = index
	expect(slot >= 0, "the_rising_cut_is_in_a_slot")
	if slot < 0:
		return
	_local.movement.set_aim_override(_mate.global_position)
	for frame in 4:
		await get_tree().physics_frame
	var rise := Skills.get_def("rising_cut")
	var start := _local.global_position
	var corrections := _local.corrections_received
	var began := _game_seconds()
	var cast_ok := _local.skills.cast_slot(slot)
	await _wait(0.05)
	_local.skills.press_slot(slot)
	var chained_at := -1.0
	var height_at_chain := 0.0
	var highest := start.y
	var busy := 0.0
	while busy < 5.0:
		await get_tree().physics_frame
		busy += 1.0 / 120.0
		highest = maxf(highest, _local.global_position.y)
		var def := _local.skills.current_def()
		if chained_at < 0.0 and def != null and def.id == "rising_cut_m2":
			chained_at = _game_seconds() - began
			height_at_chain = _local.global_position.y - start.y
		if not _local.skills.is_busy():
			break
	await _wait(0.6 + _lag * 2.0)
	var want := rise.value("windup") + rise.swing_time() + rise.combo_next_delay()
	note("cast %s; dive at %.3f s (want %.3f), %.2f m up then (highest %.2f); landed %.2f m from the start height, %.2f m across; corrections %d" % [
		cast_ok, chained_at, want, height_at_chain, highest - start.y, _local.global_position.y - start.y,
		Vector2(_local.global_position.x - start.x, _local.global_position.z - start.z).length(),
		_local.corrections_received - corrections])
	expect(cast_ok and chained_at > 0.0, "the_dive_follows_the_rising_cut")
	expect(absf(chained_at - want) < 0.04, "the_dive_starts_at_the_top_of_the_leap")
	expect(height_at_chain > 1.5, "the_body_is_high_when_the_dive_starts")
	expect(absf(_local.global_position.y - start.y) < 0.15, "the_body_lands_back_on_the_ground")
	expect(_local.corrections_received == corrections, "the_server_did_not_put_the_body_back")
	_local.movement.set_aim_override(_local.global_position)


func _flat_gap() -> float:
	return Vector2(_mate.global_position.x - _local.global_position.x, _mate.global_position.z - _local.global_position.z).length()


func _until(seen: Callable, limit: float) -> void:
	var waited := 0.0
	while waited < limit and not bool(seen.call()):
		await _wait(0.1)
		waited += 0.1


# The host's own body, GAP east of the other one and at its height.
func _stand_by_mate() -> void:
	var spot := _mate.global_position + Vector3(GAP, 0.0, 0.0)
	Net.queue_physics(func() -> void:
		_local.global_position = spot
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target())
	await _wait(0.6)


func _finish() -> void:
	print("RC_RESULT peer=%d checks=%d failures=%d" % [_peer_id, _checks, _failures])
	await _wait(10.0 if multiplayer.is_server() else 0.5)
	get_tree().quit(0 if _failures == 0 else 1)
