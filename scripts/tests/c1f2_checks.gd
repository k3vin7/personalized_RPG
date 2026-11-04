extends Node

# C-1f-2: the model and its clips. A picture only -- the checks here read
# what is drawn (the clip, its speed, the model's size) against the body's
# state and the SkillDef's times; nothing about a ruling is measured, and the
# C-1 regression run beside this is what shows the rulings did not move.
# Two peers: the host reads its own screen and its replica of the client,
# the client reports its own screen.

const HOME := Vector3(0.0, 0.9, 11.0)
# A render frame at 60 Hz plus a physics frame: the clip's end is seen in
# _process, the start is stamped in the phase hook.
const FRAME_TOLERANCE := 1.0 / 60.0 + 1.0 / 120.0

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
	print("C1F2_CHECK peer=%d %s %s" % [_peer_id, "PASS" if condition else "FAIL", label])


func note(line: String) -> void:
	print("C1F2_NOTE peer=%d %s" % [_peer_id, line])


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


func _dummy() -> Dummy:
	return _world.get_node("Dummy_1") as Dummy


func _wait_idle(seconds := 3.0) -> void:
	var waited := 0.0
	while _local.state != Player.State.IDLE and waited < seconds:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()


func _park(at: Vector3) -> void:
	await tick_request(func() -> void:
		placed()
		_local.global_position = at
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target()
		_local.movement.cancel_armed()
		_local.movement.set_aim_override(Vector3.INF))
	await _wait(0.5)


func _take(kind: int) -> void:
	await tick_request(func() -> void: _local.set_weapon(kind))
	var waited := 0.0
	while waited < 2.0 and ((kind == WeaponKinds.Kind.SHIELD and _local.offhand != kind)
			or (kind != WeaponKinds.Kind.SHIELD and _local.weapon != kind)):
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	await _wait(0.2)


# Watches `body` for up to `seconds` and returns the clips seen, in order.
func _clips_seen(body: Player, seconds: float) -> Array:
	var seen: Array = []
	var waited := 0.0
	while waited < seconds:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		var clip := body.visual.current_clip()
		if seen.is_empty() or seen[seen.size() - 1] != clip:
			seen.append(clip)
	return seen


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
	await _model_checks()
	await _locomotion_checks()
	await _attack_checks()
	await _two_peer_checks()
	Tuning.values.smart_key_enabled = smart
	expect(_judge.move_warnings == warnings, "no_move_warnings_during_c1f2")
	expect(_judge.move_corrections == corrections, "no_corrections_during_c1f2")
	print("C1F2_RESULT peer=%d checks=%d failures=%d" % [_peer_id, _checks, _failures])
	finish.rpc(_failures)
	await _wait(1.0)
	get_tree().quit(0 if _failures == 0 else 1)


# ------------------------------------------------- 1: the model on the capsule

func _model_checks() -> void:
	var visual := _local.visual
	expect(visual != null and visual.model_loaded(), "the_body_carries_a_loaded_model")
	if visual == null or not visual.model_loaded():
		return
	var bones := visual.skeleton().get_bone_count()
	var height := visual.measured_height()
	var capsule := _local.half_height() * 2.0
	note("model: %d bones, scale %.3f, measured height %.2f m against the capsule's %.2f m; capsule mesh visible=%s, cone visible=%s" % [
		bones, visual.model_scale, height, capsule, _local._body_mesh_node.visible, _local._facing.visible])
	expect(bones == 23, "the_knight_rig_has_its_23_bones")
	expect(absf(height - capsule) < capsule * 0.06, "the_model_stands_as_tall_as_the_capsule")
	expect(not _local._body_mesh_node.visible and not _local._facing.visible, "the_capsule_and_the_cone_are_not_drawn")
	expect(absf(_local._body_shape.height - capsule) < 0.001 and absf(_local._body_shape.radius - _local.radius()) < 0.001,
		"the_collider_is_the_same_capsule")
	# The props: the sword on the right hand bone, the shield on the left.
	await _take(WeaponKinds.Kind.SWORD)
	var sword := _local._weapon_node
	var on_hand := sword != null and sword.get_parent() is BoneAttachment3D \
		and (sword.get_parent() as BoneAttachment3D).bone_name == CharacterVisual.HAND_BONE
	await _take(WeaponKinds.Kind.SHIELD)
	var shield := _local._offhand_node
	var on_offhand := shield != null and shield.get_parent() is BoneAttachment3D \
		and (shield.get_parent() as BoneAttachment3D).bone_name == CharacterVisual.OFFHAND_BONE
	note("sword parent %s, shield parent %s" % [
		sword.get_parent().name if sword != null else "none", shield.get_parent().name if shield != null else "none"])
	expect(on_hand and on_offhand, "the_sword_and_the_shield_hang_off_the_hand_bones")
	await _take(WeaponKinds.Kind.NONE)


# ------------------------------------------------- 2: state -> clip

func _locomotion_checks() -> void:
	await _park(HOME)
	expect(_local.state == Player.State.IDLE and _local.visual.current_clip() == CharacterVisual.clip_for("idle"),
		"standing_plays_the_idle_clip")
	# A walk order: the walk or run clip, paced by the body's own speed.
	await tick_request(func() -> void: _local.movement.set_target(HOME + Vector3(8.0, 0.0, 0.0)))
	await _wait(0.5)
	var moving_clip := _local.visual.current_clip()
	var moving_speed := _local.visual.clip_speed()
	note("moving: state %s, clip %s at x%.2f, body %.2f m/s" % [
		Player.State.keys()[_local.state], moving_clip, moving_speed, Vector2(_local.velocity.x, _local.velocity.z).length()])
	expect(_local.state == Player.State.MOVE and (moving_clip == CharacterVisual.clip_for("walk") or moving_clip == CharacterVisual.clip_for("run")),
		"moving_plays_the_walk_or_run_clip")
	await tick_request(func() -> void: _local.movement.cancel_target())
	await _wait(0.5)
	expect(_local.state == Player.State.IDLE and _local.visual.current_clip() == CharacterVisual.clip_for("idle"),
		"stopping_returns_to_idle")
	# The dash.
	await _park(HOME)
	await _wait(Tuning.server.dash_cooldown)
	await tick_request(func() -> void:
		_local.movement.set_aim_override(HOME + Vector3(0.0, 0.0, -4.0))
		_local.movement.request_dash())
	var dashing := _local.state == Player.State.DASH
	var dash_clip := _local.visual.current_clip()
	note("dash: state %s clip %s x%.2f" % [Player.State.keys()[_local.state], dash_clip, _local.visual.clip_speed()])
	expect(dashing and dash_clip == CharacterVisual.clip_for("dash"), "dashing_plays_the_dash_clip")
	await _wait_idle()
	# The jump: rising shows the jump clip, falling the fall clip.
	await _park(HOME)
	await tick_request(func() -> void:
		_local.movement.set_aim_override(HOME + Vector3(2.0, 0.0, 0.0))
		_local.movement.press_jump())
	var seen := await _clips_seen(_local, 1.2)
	note("jump: clips %s, state now %s" % [seen, Player.State.keys()[_local.state]])
	expect(seen.has(CharacterVisual.clip_for("jump")) and seen.has(CharacterVisual.clip_for("fall")),
		"a_jump_shows_the_jump_clip_then_the_fall_clip")
	await _wait_idle()
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))


# ------------------------------------------------- 3: the attack clips

# Casts `slot` at the scarecrow and reads the attack clip's name, its speed
# and the time it took against the windup + the swing.
func _cast_and_time(slot: int) -> Dictionary:
	var dummy := _dummy()
	var def := _local.skills.slot_def(slot)
	var spot := dummy.home + Vector3(0.0, 0.0, 2.0)
	await tick_request(func() -> void:
		placed()
		_local.global_position = Vector3(spot.x, 0.9, spot.z)
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target()
		_local.movement.set_aim_override(dummy.home))
	await _wait(0.4)
	var shown := _local.visual.attacks_shown
	await tick_request(func() -> void: _local.skills.press_slot(slot))
	var clip := _local.visual.current_clip()
	var speed := _local.visual.clip_speed()
	var waited := 0.0
	# The clip advances in render frames and the start is stamped in a
	# physics tick, so the end can be read up to one render frame early;
	# the longest render frame seen is the tolerance.
	var render_frame := 0.0
	while _local.visual.attack_finished_msec == 0 and waited < 3.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		render_frame = maxf(render_frame, get_process_delta_time())
	var took := float(_local.visual.attack_finished_msec - _local.visual.attack_started_msec) / 1000.0
	var expected := def.value("windup") + def.swing_time()
	var held := _local.visual.current_clip()
	await _wait_idle()
	await _wait(0.3)
	return {
		"skill": def.id, "clip": clip, "speed": speed, "clip_len": CharacterVisual.clip_length(clip),
		"took": took, "expected": expected, "shown": _local.visual.attacks_shown - shown,
		"held": held, "after": _local.visual.current_clip(), "render_frame": render_frame,
	}


func _attack_checks() -> void:
	await _take(WeaponKinds.Kind.SWORD)
	for row: Array in [["side_cut", 1, "slash_h"], ["overhead_cut", 2, "slash_v"], ["thrust", 0, "thrust"]]:
		var seen := await _cast_and_time(int(row[1]))
		var want_clip := CharacterVisual.clip_for(String(row[2]))
		var want_speed: float = float(seen["clip_len"]) / maxf(float(seen["expected"]), 0.02)
		var tolerance: float = maxf(FRAME_TOLERANCE, float(seen["render_frame"]) + 1.0 / 120.0)
		note("%s: clip %s (want %s) x%.3f (want x%.3f), ran %.3f s for %.3f s of windup + swing (tolerance %.3f, longest render frame %.3f), held %s, after %s" % [
			seen["skill"], seen["clip"], want_clip, float(seen["speed"]), want_speed,
			float(seen["took"]), float(seen["expected"]), tolerance, float(seen["render_frame"]), seen["held"], seen["after"]])
		expect(String(seen["skill"]) == String(row[0]) and int(seen["shown"]) == 1 and String(seen["clip"]) == want_clip,
			"%s_plays_the_%s_clip" % [row[0], row[2]])
		expect(absf(float(seen["speed"]) - want_speed) < 0.01, "%s_runs_at_clip_length_over_windup_plus_swing" % row[0])
		expect(absf(float(seen["took"]) - float(seen["expected"])) <= tolerance,
			"%s_clip_ends_with_the_swing_within_a_frame" % row[0])
		expect(String(seen["held"]) == want_clip and String(seen["after"]) == CharacterVisual.clip_for("idle"),
			"%s_holds_its_last_frame_through_the_recovery_then_idles" % row[0])
	await _take(WeaponKinds.Kind.NONE)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))


# ------------------------------------------------- 4: the other peer

func _two_peer_checks() -> void:
	var mate := _mate()
	expect(mate != null and mate.visual != null and mate.visual.model_loaded(), "the_replica_carries_a_model_too")
	await _park(HOME)
	client_park.rpc_id(_client_peer(), HOME + Vector3(0.0, 0.0, -3.0))
	await _wait(0.9)
	# The client walks: this screen's replica shows the walk or run clip.
	client_walk.rpc_id(_client_peer(), HOME + Vector3(6.0, 0.0, -3.0))
	var walk_seen := await _clips_seen(mate, 1.0)
	note("the client walks: replica clips %s" % [walk_seen])
	expect(walk_seen.has(CharacterVisual.clip_for("walk")) or walk_seen.has(CharacterVisual.clip_for("run")),
		"this_screen_shows_the_clients_walk")
	await _wait(1.5)
	client_park.rpc_id(_client_peer(), HOME + Vector3(0.0, 0.0, -3.0))
	await _wait(0.9)
	# The client dashes: the replica shows the dash clip while DASH is replicated.
	client_dash.rpc_id(_client_peer(), HOME + Vector3(4.0, 0.0, -3.0))
	var dash_seen := await _clips_seen(mate, 0.8)
	note("the client dashes: replica clips %s" % [dash_seen])
	expect(dash_seen.has(CharacterVisual.clip_for("dash")), "this_screen_shows_the_clients_dash")
	await _wait(0.5)
	# 3.5 m, so the next park (to 1.2 m) is a snap and not a lerp the move
	# check reads as a sprint.
	client_park.rpc_id(_client_peer(), HOME + Vector3(0.0, 0.0, -3.5))
	await _wait(0.9)
	# The client's side cut at the host from 3.5 m (past the reach): the replica
	# plays the same clip at the same speed off the replicated phase, and the
	# client's own screen says what it drew.
	_reports.erase("weapon")
	client_take_weapon.rpc_id(_client_peer(), WeaponKinds.Kind.SWORD)
	await _wait_report("weapon")
	_reports.erase("cast")
	var replica_start := Time.get_ticks_msec()
	client_cast_at.rpc_id(_client_peer(), HOME, 1)
	var replica_clip := ""
	var replica_speed := 0.0
	var replica_delay := -1.0
	var waited := 0.0
	while waited < 2.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		if replica_clip == "" and mate.visual.picture == "attack":
			replica_clip = mate.visual.current_clip()
			replica_speed = mate.visual.clip_speed()
			replica_delay = float(Time.get_ticks_msec() - replica_start) / 1000.0
	var theirs: Dictionary = _reports.get("cast", {}) if await _wait_report("cast") else {}
	var want := CharacterVisual.clip_for("slash_h")
	note("the client's side cut: its screen %s | replica here clip %s x%.3f, %.3f s after the order" % [
		theirs, replica_clip, replica_speed, replica_delay])
	expect(String(theirs.get("clip", "")) == want and absf(float(theirs.get("speed", 0.0)) - float(theirs.get("want_speed", -1.0))) < 0.01,
		"the_clients_own_screen_plays_the_slash_clip_at_the_skills_pace")
	expect(replica_clip == want and absf(replica_speed - float(theirs.get("speed", -1.0))) < 0.01,
		"this_screen_replays_the_same_clip_at_the_same_pace")
	expect(replica_delay >= 0.0 and replica_delay < 0.5, "within_half_a_second_of_the_order")
	await _wait(1.0)
	# The client knocks the host down (the kick) and hits it (the punch): the
	# hit clip, then the held lying frame, on this screen.
	_reports.erase("weapon")
	client_take_weapon.rpc_id(_client_peer(), WeaponKinds.Kind.NONE)
	await _wait_report("weapon")
	client_park.rpc_id(_client_peer(), HOME + Vector3(0.0, 0.0, -1.2))
	await _wait(0.9)
	client_cast_at.rpc_id(_client_peer(), HOME, 2)
	var punch_seen := await _clips_seen(_local, 1.2)
	note("punched by the client: own clips %s" % [punch_seen])
	expect(punch_seen.has(CharacterVisual.clip_for("hit")), "being_hit_plays_the_hit_clip")
	await _wait(0.6)
	client_cast_at.rpc_id(_client_peer(), HOME, 3)
	waited = 0.0
	while _local.state != Player.State.DOWNED and waited < 2.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	await _wait(0.3)
	var down_clip := _local.visual.current_clip()
	var down_playing := _local.visual.is_clip_playing()
	var lying_deg := rad_to_deg(absf(_local._visual.rotation.x))
	note("kicked down: state %s, clip %s playing=%s, container tilt %.1f deg" % [
		Player.State.keys()[_local.state], down_clip, down_playing, lying_deg])
	expect(_local.state == Player.State.DOWNED and down_clip == CharacterVisual.clip_for("down") and not down_playing and lying_deg > 80.0,
		"lying_holds_a_still_frame_on_the_flat_container")
	while _local.state == Player.State.DOWNED:
		await get_tree().physics_frame
	await _wait(0.5)
	expect(_local.state == Player.State.IDLE and _local.visual.current_clip() == CharacterVisual.clip_for("idle"), "and_stands_back_up_into_idle")
	# Death: the host at 1 HP takes the client's punch, dies, respawns. Both
	# are put back first: the kick pushed the host out of the punch's reach.
	await _park(HOME)
	client_park.rpc_id(_client_peer(), HOME + Vector3(0.0, 0.0, -6.0))
	await _wait(0.9)
	client_park.rpc_id(_client_peer(), HOME + Vector3(0.0, 0.0, -1.2))
	await _wait(0.9)
	await tick_request(func() -> void: _judge.server_set_hp(_local, 1.0))
	await _wait(0.3)
	client_cast_at.rpc_id(_client_peer(), HOME, 2)
	waited = 0.0
	while _local.state != Player.State.DEAD and waited < 2.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	await _wait(0.3)
	var dead_clip := _local.visual.current_clip()
	note("killed: state %s, clip %s playing=%s" % [Player.State.keys()[_local.state], dead_clip, _local.visual.is_clip_playing()])
	expect(_local.state == Player.State.DEAD and dead_clip == CharacterVisual.clip_for("death"), "dying_plays_the_death_clip")
	await _wait(2.5)
	await tick_request(func() -> void: _local.respawn())
	await _wait_idle(4.0)
	await _wait(0.5)
	expect(_local.state == Player.State.IDLE and _local.visual.current_clip() == CharacterVisual.clip_for("idle"), "respawning_returns_to_idle")
	await tick_request(func() -> void: _judge.server_set_hp(_local, _local.stats.max_hp))


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
func client_walk(to: Vector3) -> void:
	await tick_request(func() -> void: _local.movement.set_target(to))


@rpc("authority", "call_remote", "reliable")
func client_dash(aim: Vector3) -> void:
	await tick_request(func() -> void:
		_local.movement.set_aim_override(aim)
		_local.movement.request_dash())
	await _wait(0.6)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))


@rpc("authority", "call_remote", "reliable")
func client_take_weapon(kind: int) -> void:
	await tick_request(func() -> void: _local.set_weapon(kind))
	var waited := 0.0
	while _local.weapon != kind and _local.offhand != kind and waited < 3.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	await _wait(0.2)
	report.rpc_id(1, "weapon", _local.weapon)


# Server -> client: cast `slot` at a point; report the clip this screen drew.
@rpc("authority", "call_remote", "reliable")
func client_cast_at(aim: Vector3, slot: int) -> void:
	var was: bool = Tuning.values.smart_key_enabled
	Tuning.values.smart_key_enabled = true
	var def := _local.skills.slot_def(slot)
	await tick_request(func() -> void:
		_local.movement.set_aim_override(aim)
		_local.skills.press_slot(slot))
	var clip := _local.visual.current_clip()
	var speed := _local.visual.clip_speed()
	var expected := (def.value("windup") + def.swing_time()) if def != null else 0.0
	await _wait(1.2)
	Tuning.values.smart_key_enabled = was
	report.rpc_id(1, "cast", {
		"slot": slot, "clip": clip, "speed": speed,
		"want_speed": CharacterVisual.clip_length(clip) / maxf(expected, 0.02),
	})
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))


@rpc("authority", "call_remote", "reliable")
func finish(host_failures: int) -> void:
	print("C1F2_RESULT peer=%d checks=%d failures=%d host_failures=%d" % [
		_peer_id, _checks, _failures, host_failures])
	await _wait(0.5)
	get_tree().quit(0 if host_failures == 0 else 1)
