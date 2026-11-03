extends Node

# M-7: the catch. The client is the attacker (A), the host the catcher (B).
# Strikes are booked on the server at the start of the windup and ruled at the
# impact; a grab inside the catch window, by someone strong enough, cancels
# the strike and holds the attacker still. Run at 0, 50 and 200 ms: at 200 ms
# the window (0.3 s) is expected to be missed, so the window checks become
# notes there and only the regressions count.
#
# Run at a latency with tools/udp_delay_proxy.py and --m7-latency=<ms>.

const HOME := Vector3(0.0, 0.9, 11.0)
const CLIENT_SPOT := Vector3(1.0, 0.9, 11.0)
# Past this one-way latency the window checks are notes, not failures.
const STRICT_BELOW := 0.075

var _world: Node3D
var _local: Player
var _judge: ServerAuthority
var _peer_id := 0
var _checks := 0
var _failures := 0
var _stage_done := ""
var _lag := 0.0
var _label := "0"
var _strict := true
var _reports := {}


func expect(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("M7_CHECK lag=%s peer=%d %s %s" % [_label, _peer_id, "PASS" if condition else "FAIL", label])


# A window check: counted at low latency, noted otherwise.
func check(condition: bool, label: String) -> void:
	if _strict:
		expect(condition, label)
	else:
		note("(not counted at this latency) %s: %s" % [label, "ok" if condition else "missed"])


func note(line: String) -> void:
	print("M7_NOTE lag=%s peer=%d %s" % [_label, _peer_id, line])


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


func _wait_stage(name_text: String) -> bool:
	var waited := 0.0
	while _stage_done != name_text and waited < 25.0 + _lag * 20.0:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	var arrived := _stage_done == name_text
	_stage_done = ""
	return arrived


func _wait_report(key: String, seconds := 10.0) -> bool:
	var waited := 0.0
	while not _reports.has(key) and waited < seconds + _lag * 20.0:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	expect(_reports.has(key), "the_client_reported_%s" % key)
	return _reports.has(key)


func _client_peer() -> int:
	var peers := multiplayer.get_peers()
	return peers[0] if peers.size() > 0 else 0


func _mate() -> Player:
	return _judge.actor_for(_client_peer())


# Both bodies on their marks, facing each other, the host human again.
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


# How long until the client's booked kick lands, as the server sees it.
func _until_impact() -> float:
	var pending := _judge.pending_strike(_mate())
	if pending.is_empty():
		return -1.0
	return float(int(pending["at"]) - Time.get_ticks_msec()) / 1000.0


func run(world: Node3D) -> void:
	_world = world
	_peer_id = multiplayer.get_unique_id()
	_local = Net.spawn_root.get_node(str(_peer_id)) as Player
	_judge = world.get_node_or_null("ServerAuthority") as ServerAuthority
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--m7-latency="):
			_label = argument.trim_prefix("--m7-latency=")
			_lag = _label.to_float() / 1000.0
	_strict = _lag < STRICT_BELOW
	if not multiplayer.is_server():
		stage_done.rpc_id(1, "client_ready")
		return
	expect(await _wait_stage("client_ready"), "both_peers_present")
	var warnings := _judge.move_warnings
	var corrections := _judge.move_corrections
	var smart: bool = Tuning.values.smart_key_enabled
	Tuning.values.smart_key_enabled = true
	note("latency label %s ms one way: window checks %s" % [_label, "counted" if _strict else "noted only"])
	await _schedule_checks()
	await _catch_in_window_check()
	await _catch_outside_window_check()
	await _catch_too_weak_check()
	await _catch_then_lift_check()
	await _dummy_pattern_check()
	await _sequence_check()
	Tuning.values.smart_key_enabled = smart
	expect(_judge.move_warnings == warnings, "no_move_warnings_during_m7")
	expect(_judge.move_corrections == corrections, "no_corrections_during_m7")
	print("M7_RESULT lag=%s peer=%d checks=%d failures=%d" % [_label, _peer_id, _checks, _failures])
	finish.rpc(_failures)
	await _wait(1.0)
	get_tree().quit(0 if _failures == 0 else 1)


# ------------------------------------ 1: the intent at the windup's start, booked

func _schedule_checks() -> void:
	await _reset_pair()
	var mate := _mate()
	var punch := Skills.get_def("punch")
	# The client punches the host: the ruling is booked when the intent
	# arrives and runs at the impact. Its wall clock against the client's own
	# windup end says how late the ruling is -- one way of latency, expected.
	_reports.erase("cast")
	var hp_before := _local.hp
	client_cast.rpc_id(_client_peer(), 2)
	var waited := 0.0
	while waited < 2.0 and _judge.pending_strike(mate).is_empty():
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	var booked := not _judge.pending_strike(mate).is_empty()
	var booked_for := _until_impact()
	while waited < 4.0 and not _judge.pending_strike(mate).is_empty():
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	expect(booked, "a_strikes_intent_is_booked_at_the_start_of_the_windup")
	note("booked punch: %.3f s to impact at booking (windup %.2f)" % [booked_for, punch.impact_time()])
	if await _wait_report("cast"):
		var cast: Dictionary = _reports["cast"]
		var ruled_unix := float(_judge.last_strike.get("at_unix", 0.0))
		var late := ruled_unix - float(cast.get("fire_unix", 0.0))
		note("ruling against the client's windup end: %.3f s late (one way is about %.3f s)" % [late, _lag])
		expect(_judge.last_strike.get("by", "") == mate.name and int(_judge.last_strike.get("hits", 0)) == 1,
			"the_booked_strike_landed_at_its_time")
		expect(_local.hp < hp_before, "and_hurt_the_host")
	# A strike whose caster is knocked down in the windup never lands: the host
	# kicks first, the client casts a tenth of a second later, and the host's
	# impact (0.25) puts the client down before the client's own (0.35 on).
	await _reset_pair()
	hp_before = _local.hp
	var cancelled := _judge.strikes_cancelled
	var kick := Skills.get_def("kick")
	await tick_request(func() -> void: _local.skills.press_slot(3))
	await get_tree().create_timer(0.08).timeout
	client_cast.rpc_id(_client_peer(), 3)
	await _wait(kick.impact_time() + 0.8)
	note("caster knocked down in the windup: cancelled %d -> %d, host hp %.0f -> %.0f, client %s" % [
		cancelled, _judge.strikes_cancelled, hp_before, _local.hp, Player.State.keys()[mate.state]])
	check(_judge.strikes_cancelled > cancelled, "a_strike_is_cancelled_when_its_caster_goes_down_in_the_windup")
	check(_local.hp == hp_before, "and_never_lands")
	await _wait(Tuning.server.down_time + Tuning.server.getup_time + 0.5)


# ------------------------------------------------ 3: the catch, inside the window

# The client kicks; the host grabs when the booking is this far from impact.
func _attack_and_grab(grab_at_before_impact: float, release := false) -> void:
	var mate := _mate()
	client_cast.rpc_id(_client_peer(), 3)
	var waited := 0.0
	while waited < 2.0 and _judge.pending_strike(mate).is_empty():
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	while _until_impact() > grab_at_before_impact and not _judge.pending_strike(mate).is_empty():
		await get_tree().physics_frame
	await tick_request(func() -> void:
		_local.movement.set_aim_override(mate.global_position)
		_local.skills.press_slot(1)
		if release:
			_local.skills.release_slot(1))


func _catch_in_window_check() -> void:
	await _reset_pair()
	var mate := _mate()
	var kick := Skills.get_def("kick")
	var catches := _judge.catches
	var hp_before := _local.hp
	await _attack_and_grab(0.15)
	# The stun is timed from its first frame, not from after a wait.
	var seen_stun := 0.0
	while mate.state != Player.State.STUNNED and seen_stun < 1.0:
		await get_tree().physics_frame
		seen_stun += get_physics_process_delta_time()
	var caught := _judge.catches > catches
	note("grab 0.15 s before the kick's impact (window %.2f): catches %d -> %d, host hp %.0f -> %.0f, client %s, before_impact=%.3f" % [
		kick.catch_window_time(), catches, _judge.catches, hp_before, _local.hp,
		Player.State.keys()[mate.state], float(_judge.last_catch.get("before_impact", -1.0))])
	check(caught, "a_grab_inside_the_window_catches_the_kick")
	check(_local.hp == hp_before, "the_caught_kick_does_no_damage")
	# The attacker is held still for catch_stun.
	var stunned := mate.state == Player.State.STUNNED
	var held := 0.0
	while mate.state == Player.State.STUNNED and held < 3.0:
		await get_tree().physics_frame
		held += get_physics_process_delta_time()
	note("attacker stunned=%s for %.2f s (catch_stun %.1f)" % [stunned, held, Tuning.server.catch_stun])
	check(stunned, "the_attacker_is_held_still")
	check(absf(held - Tuning.server.catch_stun) < 0.3, "for_catch_stun")
	check(_local.state != Player.State.GRABBING, "the_catcher_is_free_not_grabbing")
	# And the catcher can kick the stunned attacker meanwhile.
	await _wait(kick.value("cooldown"))
	await _reset_pair()
	catches = _judge.catches
	await _attack_and_grab(0.15)
	await _wait(0.3)
	var stunned_now := mate.state == Player.State.STUNNED
	var mate_hp := mate.hp
	await tick_request(func() -> void:
		_local.movement.set_aim_override(mate.global_position)
		_local.skills.press_slot(3))
	await _wait(kick.impact_time() + 0.4)
	note("kick during the catch stun: attacker was stunned=%s, hp %.0f -> %.0f, now %s" % [
		stunned_now, mate_hp, mate.hp, Player.State.keys()[mate.state]])
	check(_judge.catches > catches and stunned_now and mate.hp < mate_hp, "the_catcher_can_kick_during_the_stun")
	await _wait(Tuning.server.down_time + Tuning.server.getup_time + 0.5)


# ------------------------------------------------ 3: outside the window, too weak

func _catch_outside_window_check() -> void:
	await _reset_pair()
	var mate := _mate()
	var kick := Skills.get_def("kick")
	var catches := _judge.catches
	var hp_before := _local.hp
	# The grab goes out before anything is booked: no catch, an ordinary grab
	# of someone too heavy to lift, and the kick lands as booked.
	await tick_request(func() -> void:
		_local.movement.set_aim_override(mate.global_position)
		_local.skills.press_slot(1))
	await _wait(0.3)
	client_cast.rpc_id(_client_peer(), 3)
	await _wait(kick.impact_time() + 0.6)
	note("grab before the attack: catches %d -> %d, host hp %.0f -> %.0f, host %s" % [
		catches, _judge.catches, hp_before, _local.hp, Player.State.keys()[_local.state]])
	expect(_judge.catches == catches, "a_grab_outside_the_window_catches_nothing")
	check(_local.hp < hp_before, "and_the_kick_lands_as_booked")
	await _wait(Tuning.server.down_time + Tuning.server.getup_time + 0.5)


func _catch_too_weak_check() -> void:
	await _reset_pair()
	var kick := Skills.get_def("kick")
	var catches := _judge.catches
	var hp_before := _local.hp
	# The kick's force times a large multiplier is more than a human has.
	var mult: float = Tuning.server.catch_power_mult
	Tuning.server.catch_power_mult = 20.0
	await _attack_and_grab(0.15)
	await _wait(kick.impact_time() + 0.6)
	note("grab in the window, strength %.0f against %.0f x %.0f: catches %d -> %d, host hp %.0f -> %.0f" % [
		_local.stats.strength, kick.catch_force_value(), Tuning.server.catch_power_mult,
		catches, _judge.catches, hp_before, _local.hp])
	expect(_judge.catches == catches, "a_catcher_too_weak_catches_nothing")
	check(_local.hp < hp_before, "and_takes_the_kick")
	Tuning.server.catch_power_mult = mult
	await _wait(Tuning.server.down_time + Tuning.server.getup_time + 0.5)


# -------------------------------------------- 3: a catch that can lift carries on

func _catch_then_lift_check() -> void:
	await _reset_pair()
	var mate := _mate()
	var kick := Skills.get_def("kick")
	# Handed the strength to lift a human; the key stays down.
	await tick_request(func() -> void: _judge.harness_set_stats(_local, 100.0))
	await _wait(0.3)
	var catches := _judge.catches
	await _attack_and_grab(0.15)
	await _wait(0.6)
	note("catch with the strength to lift: catches %d -> %d, lifted=%s, host %s holding=%s, client %s" % [
		catches, _judge.catches, _judge.last_catch.get("lifted", false), Player.State.keys()[_local.state],
		_local.grab.is_holding(), Player.State.keys()[mate.state]])
	check(_judge.catches > catches and bool(_judge.last_catch.get("lifted", false)) and _local.grab.is_holding(),
		"a_catch_by_someone_who_can_lift_carries_on_into_a_hold")
	await tick_request(func() -> void: _local.grab.drop())
	await _wait(1.5)
	# The same with a tap: the key is up before the hold lands, so it is put
	# straight down again -- a catch and nothing else.
	await _reset_pair()
	await tick_request(func() -> void: _judge.harness_set_stats(_local, 100.0))
	await _wait(0.3)
	catches = _judge.catches
	await _attack_and_grab(0.15, true)
	await _wait(0.8)
	note("catch with a tap: catches %d -> %d, lifted=%s, host holding=%s, client %s" % [
		catches, _judge.catches, _judge.last_catch.get("lifted", false), _local.grab.is_holding(),
		Player.State.keys()[mate.state]])
	check(_judge.catches > catches and not _local.grab.is_holding(), "a_tap_catches_without_carrying")
	await tick_request(func() -> void: _judge.harness_clear_stats(_local))
	await _wait(Tuning.server.catch_stun + 0.5)


# ------------------------------------------------- 4: the scarecrow's big swing

func _dummy_pattern_check() -> void:
	var dummy := _world.get_node("Dummy_1") as Dummy
	var slam := Skills.get_def("dummy_slam")
	await _reset_pair()
	client_park.rpc_id(_client_peer(), HOME + Vector3(-6.0, 0.0, 0.0))
	var spot := dummy.global_position + dummy.attack_direction() * 1.0
	await tick_request(func() -> void:
		placed()
		_local.global_position = Vector3(spot.x, 0.9, spot.z)
		_local.velocity = Vector3.ZERO
		_local.movement.set_aim_override(dummy.global_position))
	await _wait(0.5)
	var period: float = Tuning.server.dummy_attack_period
	Tuning.server.dummy_attack_period = 1.5
	Tuning.server.dummy_attack_enabled = true
	note("scarecrow pattern: period %.1f s (test), windup %.2f, recovery %.2f, range %.1f, damage %.0f, power %.0f, catch_force %.0f" % [
		Tuning.server.dummy_attack_period, slam.impact_time(), slam.value("recovery"), slam.value("reach"),
		slam.value("damage"), slam.value("knock_power"), slam.catch_force_value()])
	# Too weak for the catch (force 120) and too weak to lift the 12 kg
	# scarecrow (strength 5, limit 6): the grab in the window does nothing and
	# the slam lands.
	await tick_request(func() -> void: _judge.harness_set_stats(_local, 5.0))
	await _wait(0.3)
	var catches := _judge.catches
	var hp_before := _local.hp
	var waited := 0.0
	while waited < 4.0 and _judge.pending_strike(dummy).is_empty():
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	var saw_windup := dummy.attack_phase == "windup"
	var pending := _judge.pending_strike(dummy)
	while not pending.is_empty() and float(int(pending["at"]) - Time.get_ticks_msec()) / 1000.0 > 0.15:
		await get_tree().physics_frame
		pending = _judge.pending_strike(dummy)
	await tick_request(func() -> void: _local.skills.press_slot(1))
	await _wait(slam.impact_time() + 0.6)
	note("weak human grabs the slam in the window: windup shown=%s, catches %d -> %d, hp %.0f -> %.0f, holding=%s" % [
		saw_windup, catches, _judge.catches, hp_before, _local.hp, _local.grab.is_holding()])
	expect(saw_windup, "the_scarecrow_shows_its_windup")
	expect(_judge.catches == catches, "a_weak_human_cannot_catch_the_slam")
	check(_local.hp < hp_before, "and_takes_it")
	await tick_request(func() -> void:
		if _local.grab.is_holding():
			_local.grab.drop())
	await _wait(Tuning.server.down_time + Tuning.server.getup_time + 0.3)
	# Strength turned up past the slam's force: the same grab catches it.
	await tick_request(func() -> void:
		placed()
		_judge.harness_set_stats(_local, 150.0)
		_judge.server_set_hp(_local, _local.stats.max_hp)
		_local.global_position = Vector3(spot.x, 0.9, spot.z)
		_local.velocity = Vector3.ZERO)
	await _wait(0.5)
	catches = _judge.catches
	hp_before = _local.hp
	waited = 0.0
	while waited < 4.0 and _judge.pending_strike(dummy).is_empty():
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	pending = _judge.pending_strike(dummy)
	while not pending.is_empty() and float(int(pending["at"]) - Time.get_ticks_msec()) / 1000.0 > 0.15:
		await get_tree().physics_frame
		pending = _judge.pending_strike(dummy)
	await tick_request(func() -> void: _local.skills.press_slot(1))
	await _wait(slam.impact_time() + 0.6)
	note("strength 150 grabs the slam in the window: catches %d -> %d, hp %.0f -> %.0f, holding=%s" % [
		catches, _judge.catches, hp_before, _local.hp, _local.grab.is_holding()])
	check(_judge.catches > catches, "with_the_strength_slider_up_the_slam_is_caught")
	check(_local.hp == hp_before, "and_does_no_damage")
	Tuning.server.dummy_attack_enabled = false
	Tuning.server.dummy_attack_period = period
	await tick_request(func() -> void:
		if _local.grab.is_holding():
			_local.grab.drop()
		_judge.harness_clear_stats(_local)
		_local.movement.set_aim_override(Vector3.INF))
	await _wait(0.8)


# ------------------------------ the pass criterion: kick, catch, stun, kick back

func _sequence_check() -> void:
	await _reset_pair()
	var mate := _mate()
	var kick := Skills.get_def("kick")
	await _wait(kick.value("cooldown"))
	_reports.erase("states")
	client_trace_states.rpc_id(_client_peer(), 3.5)
	var seen: Array = []
	var tracing := 0.0
	var caught := false
	var kicked_back := false
	var catches := _judge.catches
	client_cast.rpc_id(_client_peer(), 3)
	while tracing < 3.5:
		await get_tree().physics_frame
		tracing += get_physics_process_delta_time()
		var until := _until_impact()
		if not caught and until > 0.0 and until <= 0.15:
			caught = true
			Net.queue_physics(func() -> void:
				_local.movement.set_aim_override(mate.global_position)
				_local.skills.press_slot(1))
		if caught and not kicked_back and mate.state == Player.State.STUNNED:
			kicked_back = true
			Net.queue_physics(func() -> void:
				_local.movement.set_aim_override(mate.global_position)
				_local.skills.press_slot(3))
		var state_name: String = Player.State.keys()[mate.state]
		if seen.is_empty() or seen[seen.size() - 1] != state_name:
			seen.append(state_name)
	if await _wait_report("states"):
		var there: Dictionary = _reports["states"]
		var theirs: Array = there.get("states", [])
		note("kick -> catch -> stun -> kick back: catches +%d, host saw %s, client saw %s" % [
			_judge.catches - catches, seen, theirs])
		check(_judge.catches > catches, "the_sequence_caught_the_kick")
		check(seen.has("STUNNED") and seen.has("DOWNED"), "the_attacker_was_stunned_then_knocked_down")
		expect(seen == theirs, "both_screens_saw_the_same_order_of_states")
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))


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
	await Harness.forgive_lead(get_tree())
	await tick_request(func() -> void:
		_local.global_position = point
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target()
		_local.movement.set_aim_override(Vector3.INF))


# Server -> client: cast `slot` at the host, and report when the windup ended
# on this machine's wall clock.
@rpc("authority", "call_remote", "reliable")
func client_cast(slot: int) -> void:
	var host := Net.spawn_root.get_node_or_null("1") as Player
	var aim := host.global_position if host != null else _local.global_position + Vector3(-3.0, 0.0, 0.0)
	var was: bool = Tuning.values.smart_key_enabled
	Tuning.values.smart_key_enabled = true
	await tick_request(func() -> void:
		_local.movement.set_aim_override(aim)
		_local.skills.press_slot(slot))
	var def := _local.skills.slot_def(slot)
	await get_tree().create_timer((def.value("windup") if def != null else 0.3) + 0.1).timeout
	report.rpc_id(1, "cast", {"cast_unix": _local.skills.last_cast_unix, "fire_unix": _local.skills.last_fire_unix})
	await _wait(0.6)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	Tuning.values.smart_key_enabled = was


@rpc("authority", "call_remote", "reliable")
func client_trace_states(seconds: float) -> void:
	var seen: Array = []
	var t := 0.0
	while t < seconds:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
		var state_name: String = Player.State.keys()[_local.state]
		if seen.is_empty() or seen[seen.size() - 1] != state_name:
			seen.append(state_name)
	report.rpc_id(1, "states", {"states": seen, "position": _local.global_position})


@rpc("authority", "call_remote", "reliable")
func finish(host_failures: int) -> void:
	print("M7_RESULT lag=%s peer=%d checks=%d failures=%d host_failures=%d" % [
		_label, _peer_id, _checks, _failures, host_failures])
	get_tree().quit(0 if _failures == 0 else 1)
