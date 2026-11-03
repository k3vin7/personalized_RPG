extends Node

# C-1e: death and respawn in combat (HP 0 -> DEAD, apart from DOWNED; the
# respawn at a spawn mark with HP and stamina full, no penalty; both screens
# agree), the tuning panel's four combat groups and the six local feedback
# values, and the honest-combo refusal rate (how often a client's combo
# pressed inside the window is refused by the arrival check; reported, not
# judged -- run through the 80 ms + 20 ms jitter proxy as well).

const HOME := Vector3(0.0, 0.9, 11.0)
const COMBO_TRIES := 12

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
	print("C1E_CHECK peer=%d %s %s" % [_peer_id, "PASS" if condition else "FAIL", label])


func note(line: String) -> void:
	print("C1E_NOTE peer=%d %s" % [_peer_id, line])


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


func _wait_idle(seconds := 3.0) -> void:
	var waited := 0.0
	while _local.state != Player.State.IDLE and waited < seconds:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()


func _reset_pair() -> void:
	var mate := _mate()
	await tick_request(func() -> void:
		placed()
		_judge.server_set_hp(_local, _local.stats.max_hp)
		_judge.server_set_stamina(_local, _local.stats.max_stamina)
		_local.global_position = HOME
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target()
		_local.movement.set_aim_override(Vector3.INF)
		if mate != null and not mate.sync_dead:
			_judge.server_set_hp(mate, mate.stats.max_hp)
			_judge.server_set_stamina(mate, mate.stats.max_stamina))
	client_park.rpc_id(_client_peer(), HOME + Vector3(0.0, 0.0, -1.2))
	await _wait(0.9)


func run(world: Node3D) -> void:
	_world = world
	_peer_id = multiplayer.get_unique_id()
	_local = Net.spawn_root.get_node(str(_peer_id)) as Player
	_judge = world.get_node_or_null("ServerAuthority") as ServerAuthority
	if not multiplayer.is_server():
		stage_done.rpc_id(1, "client_ready")
		return
	expect(await _wait_stage("client_ready"), "both_peers_present")
	var warnings := _judge.move_warnings
	var corrections := _judge.move_corrections
	var smart: bool = Tuning.values.smart_key_enabled
	Tuning.values.smart_key_enabled = true
	await _panel_checks()
	await _client_death_checks()
	await _kick_death_checks()
	await _host_death_checks()
	await _combo_rate_checks()
	Tuning.values.smart_key_enabled = smart
	expect(_judge.move_warnings == warnings, "no_move_warnings_during_c1e")
	expect(_judge.move_corrections == corrections, "no_corrections_during_c1e")
	print("C1E_RESULT peer=%d checks=%d failures=%d" % [_peer_id, _checks, _failures])
	finish.rpc(_failures)
	await _wait(1.0)
	get_tree().quit(0 if _failures == 0 else 1)


# ------------------------------------------------- 1: the panel's groups and the local six

func _panel_checks() -> void:
	var groups := DebugPanel.GROUP_LABELS
	var wanted := ["Combat", "Sword", "Shield", "Dash combo"]
	var have_groups := true
	for g in wanted:
		have_groups = have_groups and groups.has(g)
	note("panel groups: %s" % [wanted.map(func(g: String) -> String: return "%s=%s" % [g, groups.has(g)])])
	expect(have_groups, "the_panel_has_the_four_combat_groups_server_approved")
	var server_fields := Tuning.field_names(Tuning.server)
	var sliders := ["weapon_attack_sword", "weapon_attack_shield", "armor_player", "armor_dummy", "crit_base", "crit_per_agility",
		"k_hp", "stamina_alpha", "stat_point_weight", "thrust_speed_bonus", "shield_slam_height_bonus", "parry_window",
		"dash_combo_mult_max", "dash_combo_window", "combo_jitter_allow"]
	var missing := []
	for s in sliders:
		if not server_fields.has(s):
			missing.append(s)
	note("server sliders the work order names: %d, missing %s" % [sliders.size(), missing])
	expect(missing.is_empty(), "every_slider_the_work_order_names_is_a_server_field")
	var local_fields := Tuning.field_names(Tuning.values)
	# C-0's set: the switch and the six sliders (hitstop, flash, particles,
	# sound, shake amp, shake time) plus the number's float time.
	var six := ["hit_feedback_enabled", "hitstop_frames", "hit_flash_time", "hit_particle_count", "hit_sound_enabled",
		"camera_shake_amp", "camera_shake_time", "damage_number_time"]
	var local_missing := []
	for s in six:
		if not local_fields.has(s):
			local_missing.append(s)
	var feedback_fields := []
	for f in local_fields:
		if f.begins_with("hit") or f.begins_with("camera") or f.begins_with("damage"):
			feedback_fields.append(f)
	note("local feedback fields: %s | missing %s" % [feedback_fields, local_missing])
	expect(local_missing.is_empty(), "the_hit_feedback_set_is_local_tuning_not_the_servers")


# ------------------------------------------------- 2: the client dies and comes back

func _client_death_checks() -> void:
	await _reset_pair()
	var mate := _mate()
	var punch := Skills.get_def("punch")
	await tick_request(func() -> void:
		_judge.server_set_hp(mate, 1.0)
		_judge.server_set_stamina(mate, 10.0)
		_local.movement.set_aim_override(mate.global_position))
	await _wait(0.3)
	var died_before := _judge.rejected_intents
	var downs := mate.downs_applied
	await tick_request(func() -> void: _local.skills.press_slot(2))
	var waited := 0.0
	while not mate.sync_dead and waited < 2.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	var dead_seen_at := waited
	var replica_dead := 0.0
	while mate.state != Player.State.DEAD and replica_dead < 1.5:
		await get_tree().physics_frame
		replica_dead += get_physics_process_delta_time()
	var death_spot := mate.global_position
	_reports.erase("vitals")
	client_report_vitals.rpc_id(_client_peer())
	var seen: Dictionary = _reports["vitals"] if await _wait_report("vitals") else {}
	note("punch at 1 hp: dead after %.2f s, replica DEAD after +%.2f s, hp %.1f, client says %s" % [
		dead_seen_at, replica_dead, mate.hp, seen])
	expect(mate.sync_dead and mate.hp == 0.0 and String(_judge.last_hit.get("skill", "")) == "punch", "a_hit_that_takes_the_last_hp_kills")
	expect(mate.state == Player.State.DEAD and String(seen.get("state", "")) == "DEAD" and float(seen.get("hp", 1.0)) == 0.0,
		"and_both_screens_show_the_body_dead")
	expect(mate.state != Player.State.DOWNED and mate.downs_applied == downs, "dead_not_downed")
	# A blow on the dead body does nothing more.
	var hits := _judge.hits_applied
	await _wait(punch.value("recovery") + 0.2)
	await tick_request(func() -> void: _local.skills.press_slot(2))
	await _wait(0.6)
	expect(_judge.hits_applied > hits and float(_judge.last_hit.get("dealt", 1.0)) == 0.0 and mate.hp == 0.0, "a_blow_on_a_dead_body_deals_nothing")
	# The respawn: the server's delay, then full vitals at a mark, both screens.
	waited = 0.0
	while mate.sync_dead and waited < Tuning.server.respawn_delay + 3.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	await _wait(1.2)
	_reports.erase("vitals")
	client_report_vitals.rpc_id(_client_peer())
	var back: Dictionary = _reports["vitals"] if await _wait_report("vitals") else {}
	var client_pos: Vector3 = back.get("position", Vector3.INF)
	note("respawn after %.2f s (delay %.1f): server hp %.1f/%.1f stamina %.1f/%.1f at %s | client says %s | %.2f m from the death spot, screens %.2f m apart" % [
		waited, Tuning.server.respawn_delay, mate.hp, mate.stats.max_hp, mate.stamina, mate.stats.max_stamina, mate.global_position, back,
		mate.global_position.distance_to(death_spot), mate.global_position.distance_to(client_pos) if client_pos.is_finite() else -1.0])
	expect(not mate.sync_dead and absf(mate.hp - mate.stats.max_hp) < 0.01 and absf(mate.stamina - mate.stats.max_stamina) < 0.01,
		"the_respawn_fills_hp_and_stamina_on_the_server")
	expect(String(back.get("state", "DEAD")) != "DEAD" and absf(float(back.get("hp", 0.0)) - mate.stats.max_hp) < 0.01
		and absf(float(back.get("stamina", 0.0)) - mate.stats.max_stamina) < 0.01, "and_the_clients_own_screen_agrees")
	expect(mate.global_position.distance_to(death_spot) > 2.0 and client_pos.is_finite() and mate.global_position.distance_to(client_pos) < 1.0,
		"at_a_spawn_mark_the_same_on_both_screens")
	await _wait_idle()


# ------------------------------------------------- 3: a kick at the last hp is a death, not a knockdown

func _kick_death_checks() -> void:
	await _reset_pair()
	var mate := _mate()
	var kick := Skills.get_def("kick")
	await tick_request(func() -> void:
		_judge.server_set_hp(mate, 1.0)
		_local.movement.set_aim_override(mate.global_position))
	await _wait(0.3)
	var downs := mate.downs_applied
	await tick_request(func() -> void: _local.skills.press_slot(3))
	var waited := 0.0
	var saw_downed := false
	while not mate.sync_dead and waited < 2.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		saw_downed = saw_downed or mate.state == Player.State.DOWNED
	await _wait(0.5)
	saw_downed = saw_downed or mate.state == Player.State.DOWNED
	note("kick at 1 hp: dead %s, hit %s, ever DOWNED %s, downs %d -> %d, state %s" % [
		mate.sync_dead, _judge.last_hit, saw_downed, downs, mate.downs_applied, Player.State.keys()[mate.state]])
	expect(mate.sync_dead and not saw_downed and mate.downs_applied == downs and mate.state == Player.State.DEAD,
		"a_kick_that_kills_is_a_death_not_a_knockdown")
	waited = 0.0
	while mate.sync_dead and waited < Tuning.server.respawn_delay + 3.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	await _wait(1.0)
	await _wait_idle()
	await _wait(kick.value("cooldown"))


# ------------------------------------------------- 4: the host dies, the client's screen agrees

func _host_death_checks() -> void:
	await _reset_pair()
	var mate := _mate()
	await tick_request(func() -> void: _judge.server_set_hp(_local, 1.0))
	await _wait(0.3)
	var respawns := _local.respawns_applied
	_reports.erase("mate_seen")
	client_cast_at.rpc_id(_client_peer(), HOME, 2)
	var waited := 0.0
	while not _local.sync_dead and waited < 3.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	var dead := _local.sync_dead and _local.state == Player.State.DEAD
	await _wait(0.6)
	client_report_body.rpc_id(_client_peer(), _local.get_path())
	var seen: Dictionary = _reports["mate_seen"] if await _wait_report("mate_seen") else {}
	note("the client's punch at the host at 1 hp: host dead %s (state %s) after %.2f s | the client sees %s" % [
		dead, Player.State.keys()[_local.state], waited, seen])
	expect(dead, "the_host_dies_to_the_clients_blow")
	expect(bool(seen.get("dead", false)) and String(seen.get("state", "")) == "DEAD" and float(seen.get("hp", 1.0)) == 0.0,
		"and_the_clients_screen_shows_the_host_dead")
	waited = 0.0
	while _local.sync_dead and waited < Tuning.server.respawn_delay + 3.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	await _wait(1.2)
	_reports.erase("mate_seen")
	client_report_body.rpc_id(_client_peer(), _local.get_path())
	var after: Dictionary = _reports["mate_seen"] if await _wait_report("mate_seen") else {}
	var seen_pos: Vector3 = after.get("position", Vector3.INF)
	note("host respawned after %.2f s: hp %.1f stamina %.1f at %s, respawns %d -> %d | the client sees %s (%.2f m apart)" % [
		waited, _local.hp, _local.stamina, _local.global_position, respawns, _local.respawns_applied, after,
		_local.global_position.distance_to(seen_pos) if seen_pos.is_finite() else -1.0])
	expect(not _local.sync_dead and _local.respawns_applied == respawns + 1 and absf(_local.hp - _local.stats.max_hp) < 0.01
		and absf(_local.stamina - _local.stats.max_stamina) < 0.01, "the_host_comes_back_full")
	expect(not bool(after.get("dead", true)) and String(after.get("state", "DEAD")) != "DEAD"
		and seen_pos.is_finite() and _local.global_position.distance_to(seen_pos) < 1.0, "and_the_clients_screen_agrees_on_where")


# ------------------------------------------------- 5: honest combos through the wire, how often refused

func _combo_rate_checks() -> void:
	await _reset_pair()
	var granted := _judge.combos_granted
	var refused := _judge.combos_refused
	var reasons := {}
	var arrivals := PackedFloat32Array()
	var claims := PackedFloat32Array()
	var no_claim := 0
	for attempt in COMBO_TRIES:
		await tick_request(func() -> void:
			_judge.server_set_hp(_local, _local.stats.max_hp)
			_local.global_position = HOME
			_local.velocity = Vector3.ZERO)
		client_park.rpc_id(_client_peer(), HOME + Vector3(0.0, 0.0, -3.0))
		await _wait(0.8)
		var g := _judge.combos_granted
		var r := _judge.combos_refused
		_reports.erase("combo")
		client_dash_combo.rpc_id(_client_peer(), HOME, 2, 0.10)
		var waited := 0.0
		while _judge.combos_granted == g and _judge.combos_refused == r and waited < 4.0:
			await get_tree().physics_frame
			waited += get_physics_process_delta_time()
		var combo := _judge.last_combo
		if _judge.combos_refused > r:
			var why := String(combo.get("why", "?"))
			reasons[why] = int(reasons.get(why, 0)) + 1
		elif _judge.combos_granted == g:
			# No ruling: the client did not claim one (its dash was refused --
			# the cooldown, the pool -- so there was nothing to judge).
			no_claim += 1
		arrivals.append(float(combo.get("arrival", -1.0)) if _judge.combos_granted + _judge.combos_refused > g + r else -1.0)
		claims.append(float(combo.get("claimed", -1.0)) if _judge.combos_granted + _judge.combos_refused > g + r else -1.0)
		# Past the dash cooldown before the next try, so every try dashes.
		await _wait(maxf(Tuning.server.dash_cooldown, 1.2) + 0.5)
	var total_g := _judge.combos_granted - granted
	var total_r := _judge.combos_refused - refused
	note("honest combos (gap 0.10, %d tries): granted %d, refused %d %s, not claimed %d | claimed %s | arrival %s" % [
		COMBO_TRIES, total_g, total_r, reasons, no_claim, claims, arrivals])
	print("C1E_COMBO_RATE tries=%d granted=%d refused=%d no_claim=%d" % [COMBO_TRIES, total_g, total_r, no_claim])
	expect(total_g + total_r + no_claim == COMBO_TRIES, "every_honest_combo_try_is_accounted_for")
	await _wait_idle()


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
	report.rpc_id(1, "vitals", {"hp": _local.hp, "stamina": _local.stamina, "state": Player.State.keys()[_local.state],
		"dead": _local.sync_dead, "position": _local.global_position})


# Server -> client: how this screen sees another body.
@rpc("authority", "call_remote", "reliable")
func client_report_body(path: NodePath) -> void:
	var body := get_node_or_null(path) as Player
	if body == null:
		report.rpc_id(1, "mate_seen", {})
		return
	report.rpc_id(1, "mate_seen", {"hp": body.hp, "dead": body.sync_dead, "state": Player.State.keys()[body.state],
		"position": body.global_position})


@rpc("authority", "call_remote", "reliable")
func client_cast_at(aim: Vector3, slot: int) -> void:
	var was: bool = Tuning.values.smart_key_enabled
	Tuning.values.smart_key_enabled = true
	await tick_request(func() -> void:
		_local.movement.set_aim_override(aim)
		_local.skills.press_slot(slot))
	await _wait(1.0)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	Tuning.values.smart_key_enabled = was


@rpc("authority", "call_remote", "reliable")
func client_dash_combo(aim: Vector3, slot: int, gap: float) -> void:
	var was: bool = Tuning.values.smart_key_enabled
	Tuning.values.smart_key_enabled = true
	await tick_request(func() -> void:
		_local.movement.set_aim_override(aim)
		_local.movement.request_dash())
	while _local.movement.seconds_since_dash() < gap:
		await get_tree().physics_frame
	await tick_request(func() -> void: _local.skills.press_slot(slot))
	await _wait(1.0)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	Tuning.values.smart_key_enabled = was


@rpc("authority", "call_remote", "reliable")
func finish(host_failures: int) -> void:
	print("C1E_RESULT peer=%d checks=%d failures=%d host_failures=%d" % [
		_peer_id, _checks, _failures, host_failures])
	get_tree().quit(0 if _failures == 0 else 1)
