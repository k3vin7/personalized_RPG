extends Node

# Riding, sub-stages a, b and c: the summon, getting on and getting off; the
# horse's speed, its acceleration, its turn and the floor snap; then what a
# rider may not do, what a blow does to one, and the no-mount-zone slot.
#
#   host:   --auto-host --auto-smoke --auto-only=MT --auto-port=P --auto-quit=420
#   client: --auto-join --auto-smoke --auto-only=MT --auto-port=P --auto-quit=420
#
# What is measured: the key is a request and the server's clock puts the body
# on the horse mount_summon_time later; on the horse the collider is the
# upright mounted capsule and the rider's picture sits on its back, on both
# screens; a summon is called off by a hurt or by something in the seat;
# getting off is at once and leaves the horse standing mount_linger_time; an
# orc's horse is mount_large_scale times the size; the key is rebindable and
# one key keeps one meaning.

const HOME := Vector3(0.0, 0.9, 11.0)
# West of the mark: the rocks stand east of it (x 4..9, z 6..9).
const CLIENT_SPOT := HOME + Vector3(-6.0, 0.0, 0.0)
# A clear run across the hub, north of the rocks and south of the rack.
const LANE_A := Vector3(-14.0, 0.9, 14.0)
const LANE_B := Vector3(14.0, 0.9, 14.0)
# Over the top of the test terrain's hill (30 deg sides), west to east.
const HILL_A := Vector3(131.0, 0.0, 40.0)
const HILL_B := Vector3(169.0, 0.0, 40.0)
const STEP := 1.0 / 120.0

var _world: Node3D
var _local: Player
var _judge: ServerAuthority
var _peer_id := 0
var _checks := 0
var _failures := 0
var _stage_done := ""
var _reports := {}
var _swerve_limits := Vector3(INF, INF, INF)
var _swerve_misaligned := 0.0


func expect(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("MT_CHECK peer=%d %s %s" % [_peer_id, "PASS" if condition else "FAIL", label])


func note(line: String) -> void:
	print("MT_NOTE peer=%d %s" % [_peer_id, line])


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


func _take_report(key: String, seconds := 10.0) -> Dictionary:
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


# Physics seconds until `test` is true, or -1 after `limit`.
func _until(test: Callable, limit: float) -> float:
	var waited := 0.0
	while waited < limit:
		if test.call():
			return waited
		await get_tree().physics_frame
		waited += STEP
	return -1.0


# What this screen shows of a body's horse.
static func describe(body: Player) -> Dictionary:
	var horse := body.mount.horse()
	return {
		"sync": body.sync_mount,
		"stage": body.mount.stage,
		"collider": body.mount.collider_dims(),
		"capsule_off": (body.get_node("BodyShape") as CollisionShape3D).disabled,
		"horse": horse != null,
		"horse_at": horse.global_position if horse != null else Vector3.INF,
		"horse_scale": horse.scale.x if horse != null else 0.0,
		"lift": body._visual.position.y,
		"body_at": body.global_position,
		"lingering": body.mount.lingering_count(),
		"vanished": body.mount.horses_vanished,
		"linger_at": body.mount.lingering_position(),
		"state": Player.State.keys()[body.state],
	}


func _reset_pair() -> void:
	await tick_request(func() -> void:
		placed()
		_local.global_position = HOME
		_local.velocity = Vector3.ZERO
		_local.rotation.y = 0.0
		_local.movement.cancel_target()
		_local.movement.set_aim_override(Vector3.INF))
	client_park.rpc_id(_client_peer(), CLIENT_SPOT)
	await _wait(0.9)


func run(world: Node3D) -> void:
	_world = world
	_peer_id = multiplayer.get_unique_id()
	_local = Net.spawn_root.get_node(str(_peer_id)) as Player
	_judge = world.get_node_or_null("ServerAuthority") as ServerAuthority
	# --mt-knock-solo=N: one process on its own, its own body knocked away on
	# foot N times, the gaps between its physics steps timed. No second peer.
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--mt-knock-solo=") and multiplayer.is_server():
			await _knock_solo(int(arg.trim_prefix("--mt-knock-solo=")))
			get_tree().quit(0)
			return
	if not multiplayer.is_server():
		stage_done.rpc_id(1, "client_ready")
		return
	expect(await _wait_stage("client_ready"), "both_peers_present")
	var warnings := _judge.move_warnings
	var corrections := _judge.move_corrections
	# --mt-knock=N: the client knocked away on foot N times, its step gaps timed.
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--mt-knock="):
			await _reset_pair()
			await _knock_repeat(int(arg.trim_prefix("--mt-knock=")))
			finish.rpc(0)
			await _wait(1.0)
			get_tree().quit(0)
			return
	# --mt-thrown=N: only the thrown client's horse, N times over.
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--mt-thrown="):
			await _reset_pair()
			await _thrown_repeat(int(arg.trim_prefix("--mt-thrown=")))
			print("MT_RESULT peer=%d checks=%d failures=%d" % [_peer_id, _checks, _failures])
			finish.rpc(_failures)
			await _wait(1.0)
			get_tree().quit(0 if _failures == 0 else 1)
			return
	_data_checks()
	await _reset_pair()
	await _host_mount_checks()
	await _cancel_checks()
	await _hurt_and_blocked_checks()
	await _client_mount_checks()
	await _orc_checks()
	await _key_checks()
	await _ride_checks()
	await _turn_slow_checks()
	await _hill_checks()
	await _client_ride_checks()
	await _restriction_checks()
	await _hit_checks()
	await _zone_checks()
	await _target_checks()
	note("move warnings %d, corrections %d during MT" % [
		_judge.move_warnings - warnings, _judge.move_corrections - corrections])
	# A warning is one 0.1 s sample of a remote body over the cap: at the
	# horse's speed a late frame on the client is enough for one. Reported,
	# not failed; a correction (two in a row) is the failure.
	expect(_judge.move_corrections == corrections, "no_corrections_during_mt")
	print("MT_RESULT peer=%d checks=%d failures=%d" % [_peer_id, _checks, _failures])
	finish.rpc(_failures)
	await _wait(1.0)
	get_tree().quit(0 if _failures == 0 else 1)


# ------------------------------------------------- 1: the numbers are data

func _data_checks() -> void:
	var s := Tuning.server
	note("mount data: summon %.2f s, linger %.2f s, horse %.2f long x %.2f back x %.2f wide, large scale %.2f, key %s" % [
		s.mount_summon_time, s.mount_linger_time, s.mount_length, s.mount_back_height, s.mount_width,
		s.mount_large_scale, OS.get_keycode_string(int(Tuning.values.mount_key))])
	var fields := Tuning.field_names(Tuning.server)
	var missing := []
	for f in ["mount_summon_time", "mount_linger_time", "mount_length", "mount_back_height", "mount_width", "mount_large_scale",
			"mount_radius", "mount_seat_above", "mount_speed_mult", "mount_accel_time", "mount_decel_time", "mount_turn_deg",
			"mount_floor_snap", "mount_turn_slow_deg", "mount_turn_min_ratio"]:
		if not fields.has(f):
			missing.append(f)
	expect(missing.is_empty(), "the_mount_numbers_are_server_tuning_fields_with_sliders")
	expect(absf(s.mount_summon_time - 1.0) < 0.001 and absf(s.mount_linger_time - 3.0) < 0.001
		and absf(s.mount_length - 2.2) < 0.001 and absf(s.mount_back_height - 1.5) < 0.001
		and absf(s.mount_large_scale - 1.3) < 0.001,
		"defaults_are_1s_summon_3s_linger_2_2m_long_1_5m_back_1_3x_large")
	note("mount data: radius %.2f, seat above %.2f, speed x%.2f, accel %.2f s, decel %.2f s, turn %.0f deg/s, snap %.2f m" % [
		s.mount_radius, s.mount_seat_above, s.mount_speed_mult, s.mount_accel_time, s.mount_decel_time, s.mount_turn_deg,
		s.mount_floor_snap])
	expect(absf(s.mount_radius - 0.6) < 0.001 and absf(s.mount_speed_mult - 2.31) < 0.001
		and absf(s.mount_accel_time - 0.8) < 0.001 and absf(s.mount_decel_time - 0.5) < 0.001
		and absf(s.mount_turn_deg - 180.0) < 0.001 and s.mount_floor_snap > 0.0,
		"defaults_are_0_6m_radius_2_31x_speed_0_8s_up_0_5s_down_180_deg_a_second_snap_on")
	expect(DebugPanel.GROUP_LABELS.has("Mount"), "the_panel_has_the_mount_group")
	expect(int(Tuning.values.mount_key) == KEY_Z and Tuning.field_names(Tuning.values).has("mount_key"),
		"the_mount_key_is_local_and_defaults_to_z")
	var large := []
	for kind in Races.all_kinds():
		if Races.data_for(kind).large_mount:
			large.append(Races.label_for(kind))
	note("races with large_mount in their data: %s" % [large])
	expect(Races.data_for(Races.Kind.ORC).large_mount and large.size() == 1,
		"only_the_orcs_race_data_asks_for_the_large_horse")


# ------------------------------------------------- 2: the host gets on, rides, gets off

func _host_mount_checks() -> void:
	var dims := _dims_for(1.0, 1.0)
	var granted := _judge.mounts_granted
	var on_foot := describe(_local)
	expect(on_foot["stage"] == PlayerMount.Stage.NONE and not on_foot["capsule_off"]
		and (on_foot["collider"] as Vector2) == Vector2.ZERO and not on_foot["horse"],
		"on_foot_the_body_is_its_capsule_and_there_is_no_horse")
	Net.queue_physics(_local.movement.press_mount)
	var asked := await _until(func() -> bool: return _local.sync_mount == PlayerMount.Stage.SUMMONING, 0.5)
	expect(asked >= 0.0 and asked <= 0.05, "the_press_starts_the_summon_at_once")
	await _wait(0.5)
	var half := describe(_local)
	expect(half["stage"] == PlayerMount.Stage.SUMMONING and not half["capsule_off"] and not half["horse"],
		"half_way_through_the_summon_the_body_is_still_on_foot")
	var rest := await _until(func() -> bool: return _local.sync_mount == PlayerMount.Stage.MOUNTED, 2.0)
	note("host summon: asked after %.3f s, mounted %.3f s after the half-way look" % [asked, rest])
	expect(rest >= 0.0, "the_host_is_on_the_horse")
	expect(_judge.mounts_granted == granted + 1, "the_server_granted_one_mount")
	await _wait(0.3)
	var up := describe(_local)
	var feet_y := _local.global_position.y - _local.half_height()
	var lift_wanted := Tuning.server.mount_back_height + Tuning.server.mount_seat_above * _local.body_scale() - _local.half_height()
	note("host mounted: collider %s, capsule off %s, horse at %s (feet y %.2f), rider lift %.2f (wanted %.2f), state %s, on floor %s" % [
		up["collider"], up["capsule_off"], up["horse_at"], feet_y, up["lift"], lift_wanted, up["state"], _local.is_on_floor()])
	expect((up["collider"] as Vector2).is_equal_approx(dims) and up["capsule_off"],
		"mounted_the_collider_is_an_upright_capsule_0_6_wide_up_to_the_riders_head")
	expect(up["horse"] and absf((up["horse_at"] as Vector3).y - feet_y) < 0.02
		and Vector2((up["horse_at"] as Vector3).x - _local.global_position.x, (up["horse_at"] as Vector3).z - _local.global_position.z).length() < 0.02,
		"the_horse_stands_on_the_ground_under_the_body")
	expect(absf(float(up["lift"]) - lift_wanted) < 0.01 and float(up["lift"]) > 0.5,
		"the_riders_picture_is_lifted_onto_the_horses_back")
	expect(_local.is_on_floor() and absf(_local.global_position.y - HOME.y) < 0.05,
		"the_mounted_body_still_stands_on_the_floor_at_the_same_height")
	client_report_body.rpc_id(_client_peer(), _local.get_path(), "host_up")
	var seen := await _take_report("host_up")
	note("client sees the host mounted: %s" % [seen])
	expect(seen.get("stage", -1) == PlayerMount.Stage.MOUNTED and seen.get("horse", false)
		and (seen.get("collider", Vector2.ZERO) as Vector2).is_equal_approx(dims) and seen.get("capsule_off", false),
		"the_client_shows_the_host_on_a_horse_with_the_same_collider")
	expect((seen.get("horse_at", Vector3.INF) as Vector3).distance_to(up["horse_at"] as Vector3) < 0.1
		and absf(float(seen.get("lift", 0.0)) - lift_wanted) < 0.01,
		"the_clients_horse_and_rider_are_where_the_hosts_are")

	# Ridden a few metres: the horse goes with the body on both screens.
	await tick_request(func() -> void: _local.movement.set_target(HOME + Vector3(0.0, 0.0, 5.0)))
	await _wait(0.3)
	await _until(func() -> bool:
		return not _local.movement.has_target() and _local.velocity.length() < 0.02, 6.0)
	await _wait(0.6)
	var rode := describe(_local)
	client_report_body.rpc_id(_client_peer(), _local.get_path(), "host_rode")
	var seen_rode := await _take_report("host_rode")
	var rode_far := Vector2(_local.global_position.x - HOME.x, _local.global_position.z - HOME.z).length()
	note("host rode %.2f m: horse %s here, %s on the client" % [rode_far, rode["horse_at"], seen_rode.get("horse_at")])
	expect(rode_far > 4.0 and (rode["horse_at"] as Vector3).distance_to(_local.global_position - Vector3.UP * _local.half_height()) < 0.02,
		"the_horse_moves_with_the_body")
	expect((seen_rode.get("horse_at", Vector3.INF) as Vector3).distance_to(rode["horse_at"] as Vector3) < 0.15,
		"and_arrives_at_the_same_place_on_the_client")

	# Off: at once, and the horse stays where it stood for the linger.
	var left_at := _local.global_position - Vector3.UP * _local.half_height()
	client_watch_linger.rpc_id(_client_peer(), _local.get_path(), "host_linger")
	await _wait(0.2)
	Net.queue_physics(_local.movement.press_mount)
	var off := await _until(func() -> bool: return _local.mount.stage == PlayerMount.Stage.NONE, 0.5)
	var down := describe(_local)
	note("host off after %.3f s: collider %s, capsule off %s, lift %.2f, lingering %d at %s" % [
		off, down["collider"], down["capsule_off"], down["lift"], down["lingering"], down["linger_at"]])
	expect(off >= 0.0 and off <= 0.05, "the_same_key_gets_off_at_once")
	expect((down["collider"] as Vector2) == Vector2.ZERO and not down["capsule_off"] and absf(float(down["lift"])) < 0.001,
		"off_the_horse_the_body_is_its_capsule_again_standing_on_the_ground")
	expect(down["lingering"] == 1 and (down["linger_at"] as Vector3).distance_to(left_at) < 0.02,
		"the_horse_is_left_standing_where_the_rider_got_off")
	await tick_request(func() -> void: _local.movement.set_target(HOME))
	var gone := await _until(func() -> bool: return _local.mount.lingering_count() == 0, 6.0)
	var lingered := off + 3.0 * STEP + gone
	var walked := Vector2(_local.global_position.x - left_at.x, _local.global_position.z - left_at.z).length()
	note("host: the horse stood %.2f s after the dismount while the body walked %.2f m away" % [lingered, walked])
	expect(gone >= 0.0 and absf(lingered - Tuning.server.mount_linger_time) < 0.15,
		"and_is_gone_after_the_3_second_linger")
	var watched := await _take_report("host_linger")
	note("client: the host's horse stood %.2f s at %s (the host left it at %s)" % [
		float(watched.get("seconds", -1.0)), watched.get("at"), left_at])
	expect(absf(float(watched.get("seconds", -1.0)) - Tuning.server.mount_linger_time) < 0.2
		and (watched.get("at", Vector3.INF) as Vector3).distance_to(left_at) < 0.3,
		"the_client_sees_the_same_horse_stand_3_seconds_in_the_same_place")
	await _until(func() -> bool: return _local.state == Player.State.IDLE, 4.0)


# ------------------------------------------------- 3: a summon that does not finish

func _cancel_checks() -> void:
	var granted := _judge.mounts_granted
	Net.queue_physics(_local.movement.press_mount)
	await _wait(0.4)
	var during := _local.sync_mount
	Net.queue_physics(_local.movement.press_mount)
	await _wait(1.2)
	note("pressed again 0.4 s into the summon: stage %s then %s, granted %d" % [
		PlayerMount.Stage.keys()[during], PlayerMount.Stage.keys()[_local.sync_mount], _judge.mounts_granted - granted])
	expect(during == PlayerMount.Stage.SUMMONING and _local.sync_mount == PlayerMount.Stage.NONE
		and _judge.mounts_granted == granted, "the_key_again_during_the_summon_calls_it_off")

	# In the air when the clock runs out: the server asks then whether the
	# body is standing, and it is not.
	var cancelled := _judge.mounts_cancelled
	Net.queue_physics(_local.movement.press_mount)
	await _wait(0.5)
	await tick_request(func() -> void:
		_local.movement.set_aim_override(_local.global_position)
		_local.movement.request_jump())
	await _wait(0.9)
	note("jumped 0.5 s into the summon: stage %s, why %s, state %s" % [
		PlayerMount.Stage.keys()[_local.sync_mount], _judge.last_mount.get("why", ""), Player.State.keys()[_local.state]])
	expect(_local.sync_mount == PlayerMount.Stage.NONE and _judge.mounts_cancelled == cancelled + 1
		and String(_judge.last_mount.get("why", "")) == "not_standing",
		"a_body_in_the_air_when_the_summon_ends_does_not_get_the_horse")
	await _until(func() -> bool: return _local.state == Player.State.IDLE, 3.0)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))


# The mounted capsule (radius, height) for a body scale and a horse scale.
static func _dims_for(body_scale: float, horse_scale: float) -> Vector2:
	var s := Tuning.server
	return Vector2(s.mount_radius * horse_scale,
		s.mount_back_height * horse_scale + s.mount_seat_above * body_scale + Player.BODY_HALF_HEIGHT * body_scale)


# ------------------------------------------------- 3b: hurt, or something in the seat

func _hurt_and_blocked_checks() -> void:
	var mate := _mate()
	var cancelled := _judge.mounts_cancelled
	var granted := _judge.mounts_granted
	Net.queue_physics(_local.movement.press_mount)
	await _wait(0.4)
	var before := _local.sync_mount
	await tick_request(func() -> void: _judge.server_damage(_local, 5.0, "mt_check"))
	var after := _local.sync_mount
	await _wait(1.0)
	note("hurt 0.4 s into the summon (5 HP through server_damage): stage %s -> %s, why %s, still %s a second later" % [
		PlayerMount.Stage.keys()[before], PlayerMount.Stage.keys()[after], _judge.last_mount.get("why", ""),
		PlayerMount.Stage.keys()[_local.sync_mount]])
	expect(before == PlayerMount.Stage.SUMMONING and after == PlayerMount.Stage.NONE
		and _local.sync_mount == PlayerMount.Stage.NONE and _judge.mounts_cancelled == cancelled + 1
		and _judge.mounts_granted == granted, "a_hurt_during_the_summon_calls_it_off")
	await tick_request(func() -> void: _judge.server_set_hp(_local, _local.stats.max_hp))

	# The client stands 0.9 m away: clear of the body on foot (0.4 + 0.4),
	# inside the mounted capsule (0.6 + 0.4).
	client_park.rpc_id(_client_peer(), HOME + Vector3(0.9, 0.0, 0.0))
	await _wait(1.0)
	var apart := Vector2(mate.global_position.x - _local.global_position.x, mate.global_position.z - _local.global_position.z).length()
	cancelled = _judge.mounts_cancelled
	Net.queue_physics(_local.movement.press_mount)
	await _wait(1.3)
	note("summoned with the client %.2f m away: stage %s, why %s, in the way: %s" % [
		apart, PlayerMount.Stage.keys()[_local.sync_mount], _judge.last_mount.get("why", ""), _judge.last_mount_blocker])
	expect(_local.sync_mount == PlayerMount.Stage.NONE and String(_judge.last_mount.get("why", "")) == "blocked"
		and _judge.last_mount_blocker == String(mate.name) and _judge.mounts_cancelled == cancelled + 1,
		"another_character_in_the_seat_when_the_summon_ends_calls_it_off")
	client_press_mount.rpc_id(_client_peer())
	await _wait(1.5)
	note("the client summoned beside the host: stage %s, why %s, in the way: %s" % [
		PlayerMount.Stage.keys()[mate.sync_mount], _judge.last_mount.get("why", ""), _judge.last_mount_blocker])
	expect(mate.sync_mount == PlayerMount.Stage.NONE and String(_judge.last_mount.get("why", "")) == "blocked"
		and _judge.last_mount_blocker == String(_local.name), "and_the_same_for_the_client_with_the_host_in_its_seat")
	# A rock in the seat.
	var rock := _world.get_node_or_null("Rock_0") as Node3D
	if rock != null:
		await tick_request(func() -> void:
			placed()
			_local.global_position = Vector3(rock.global_position.x - Rock.radius_for((rock as Rock).weight) - 0.5, HOME.y, rock.global_position.z)
			_local.velocity = Vector3.ZERO)
		await _wait(0.5)
		var rock_gap := Vector2(rock.global_position.x - _local.global_position.x, rock.global_position.z - _local.global_position.z).length()
		Net.queue_physics(_local.movement.press_mount)
		await _wait(1.3)
		note("summoned %.2f m from %s: stage %s, why %s, in the way: %s" % [rock_gap, rock.name,
			PlayerMount.Stage.keys()[_local.sync_mount], _judge.last_mount.get("why", ""), _judge.last_mount_blocker])
		expect(_local.sync_mount == PlayerMount.Stage.NONE and String(_judge.last_mount.get("why", "")) == "blocked"
			and _judge.last_mount_blocker == String(rock.name), "a_thing_in_the_seat_calls_it_off_too")
		await _get_off()
	await _reset_pair()

	# Walking through the summon still gets the horse.
	await tick_request(func() -> void: _local.movement.set_target(HOME + Vector3(0.0, 0.0, 6.0)))
	Net.queue_physics(_local.movement.press_mount)
	var took := await _until(func() -> bool: return _local.sync_mount == PlayerMount.Stage.MOUNTED, 2.0)
	var walked := Vector2(_local.global_position.x - HOME.x, _local.global_position.z - HOME.z).length()
	note("summoned while walking: mounted after %.2f s, %.2f m from where it was asked" % [took, walked])
	expect(took >= 0.0 and walked > 3.0, "a_body_that_walks_through_the_summon_is_mounted_on_the_move")
	await _until(func() -> bool: return _local.state == Player.State.IDLE, 3.0)
	Net.queue_physics(_local.movement.press_mount)
	await _wait(0.3)
	await _reset_pair()


# ------------------------------------------------- 4: the client gets on and off

func _client_mount_checks() -> void:
	var mate := _mate()
	var dims := _dims_for(1.0, 1.0)
	client_press_mount.rpc_id(_client_peer())
	var asked := await _until(func() -> bool: return mate.sync_mount == PlayerMount.Stage.SUMMONING, 2.0)
	var took := await _until(func() -> bool: return mate.sync_mount == PlayerMount.Stage.MOUNTED, 3.0)
	note("client asked: summoning seen after %.3f s, mounted %.3f s later (server clock %.2f s)" % [
		asked, took, Tuning.server.mount_summon_time])
	expect(asked >= 0.0 and took >= 0.0 and absf(took - Tuning.server.mount_summon_time) < 0.06,
		"the_clients_request_is_mounted_by_the_servers_clock_1_second_later")
	await _wait(0.5)
	var here := describe(mate)
	client_report_body.rpc_id(_client_peer(), mate.get_path(), "self_up")
	var there := await _take_report("self_up")
	note("client mounted, on the host: %s" % [here])
	note("client mounted, on its own screen: %s" % [there])
	expect(here["stage"] == PlayerMount.Stage.MOUNTED and (here["collider"] as Vector2).is_equal_approx(dims)
		and here["capsule_off"] and here["horse"],
		"the_host_shows_the_client_on_a_horse_with_the_horses_collider")
	expect(there.get("stage", -1) == PlayerMount.Stage.MOUNTED and (there.get("collider", Vector2.ZERO) as Vector2).is_equal_approx(dims)
		and there.get("capsule_off", false) and there.get("horse", false),
		"the_client_is_on_its_horse_on_its_own_screen")
	expect((there.get("horse_at", Vector3.INF) as Vector3).distance_to(here["horse_at"] as Vector3) < 0.15,
		"both_screens_put_the_clients_horse_in_the_same_place")
	var left_at := mate.global_position - Vector3.UP * mate.half_height()
	client_press_mount.rpc_id(_client_peer())
	var off := await _until(func() -> bool: return mate.mount.stage == PlayerMount.Stage.NONE, 2.0)
	var down := describe(mate)
	var gone := await _until(func() -> bool: return mate.mount.lingering_count() == 0, 6.0)
	note("client off: seen after %.3f s, capsule back %s, horse left at %s, gone %.2f s later" % [
		off, not down["capsule_off"], down["linger_at"], gone])
	expect(off >= 0.0 and not down["capsule_off"] and down["lingering"] == 1
		and (down["linger_at"] as Vector3).distance_to(left_at) < 0.1,
		"the_client_gets_off_and_its_horse_is_left_where_it_stood_on_the_host")
	expect(gone >= 0.0 and absf(gone - Tuning.server.mount_linger_time) < 0.15,
		"and_the_clients_horse_is_gone_after_3_seconds_on_the_host")


# ------------------------------------------------- 5: the orc's horse

func _orc_checks() -> void:
	var dims := _dims_for(1.0, 1.0)
	var big := _dims_for(Races.data_for(Races.Kind.ORC).height_cm / Races.data_for(Races.Kind.HUMAN).height_cm, Tuning.server.mount_large_scale)
	await tick_request(func() -> void:
		placed()
		_judge.harness_set_race(_local, Races.Kind.ORC))
	await _wait(0.6)
	# The taller body's origin is higher off the floor; let it settle.
	await tick_request(func() -> void:
		placed()
		_local.global_position = Vector3(HOME.x, _local.half_height() + 0.05, HOME.z)
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target())
	await _wait(0.5)
	Net.queue_physics(_local.movement.press_mount)
	await _until(func() -> bool: return _local.mount.stage == PlayerMount.Stage.MOUNTED, 3.0)
	await _wait(0.4)
	var up := describe(_local)
	client_report_body.rpc_id(_client_peer(), _local.get_path(), "orc_up")
	var seen := await _take_report("orc_up")
	note("orc mounted: collider %s (wanted %s), horse scale %.2f, lift %.2f, on floor %s | client: collider %s scale %.2f" % [
		up["collider"], big, up["horse_scale"], up["lift"], _local.is_on_floor(),
		seen.get("collider"), float(seen.get("horse_scale", 0.0))])
	expect((up["collider"] as Vector2).is_equal_approx(big) and absf(float(up["horse_scale"]) - Tuning.server.mount_large_scale) < 0.001,
		"an_orcs_horse_is_the_same_model_at_1_3_times_with_the_capsule_scaled_to_it")
	expect((seen.get("collider", Vector2.ZERO) as Vector2).is_equal_approx(big)
		and absf(float(seen.get("horse_scale", 0.0)) - Tuning.server.mount_large_scale) < 0.001,
		"and_the_client_shows_the_orcs_horse_at_the_same_size")
	expect(_local.is_on_floor(), "the_orc_on_its_horse_stands_on_the_floor")
	Net.queue_physics(_local.movement.press_mount)
	await _until(func() -> bool: return _local.mount.stage == PlayerMount.Stage.NONE, 1.0)
	await tick_request(func() -> void:
		placed()
		_judge.harness_set_race(_local, Races.Kind.HUMAN))
	await _wait(0.6)
	await tick_request(func() -> void:
		placed()
		_local.global_position = HOME
		_local.velocity = Vector3.ZERO)
	await _wait(3.2)


# ------------------------------------------------- 6: the key

func _press_key(code: int) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.physical_keycode = code as Key
		event.pressed = pressed
		Input.parse_input_event(event)
		Input.flush_buffered_events()
	for _frame in range(4):
		await get_tree().physics_frame


func _key_checks() -> void:
	var presses := _local.movement.mount_presses
	await _press_key(KEY_Z)
	var after_z := _local.sync_mount
	await _press_key(KEY_Z)
	var after_second := _local.sync_mount
	note("Z key: presses %d, stage %s then %s" % [_local.movement.mount_presses - presses,
		PlayerMount.Stage.keys()[after_z], PlayerMount.Stage.keys()[after_second]])
	expect(_local.movement.mount_presses == presses + 2 and after_z == PlayerMount.Stage.SUMMONING
		and after_second == PlayerMount.Stage.NONE, "the_z_key_asks_for_the_horse_and_z_again_sends_it_off")
	_local.movement.rebind_mount(KEY_X)
	presses = _local.movement.mount_presses
	await _press_key(KEY_Z)
	var z_after_rebind := _local.movement.mount_presses - presses
	await _press_key(KEY_X)
	var x_after_rebind := _local.movement.mount_presses - presses - z_after_rebind
	var stage_x := _local.sync_mount
	await _press_key(KEY_X)
	note("rebound to X: Z presses %d, X presses %d, stage %s, label %s" % [
		z_after_rebind, x_after_rebind, PlayerMount.Stage.keys()[stage_x], _local.movement.mount_key_label()])
	expect(z_after_rebind == 0 and x_after_rebind == 1 and stage_x == PlayerMount.Stage.SUMMONING
		and _local.sync_mount == PlayerMount.Stage.NONE, "after_a_rebind_the_new_key_works_and_the_old_one_does_not")
	# One key, one meaning, both ways round.
	var slot_key := _local.skills.key_for(0)
	_local.movement.rebind_mount(slot_key)
	var slot_emptied := _local.skills.key_for(0) == 0
	_local.skills.rebind(0, slot_key)
	var mount_emptied := int(Tuning.values.mount_key) == 0
	var dash_key := int(Tuning.values.dash_key)
	_local.movement.rebind_mount(dash_key)
	var dash_emptied := int(Tuning.values.dash_key) == 0
	_local.movement.rebind_dash(dash_key)
	var mount_emptied_by_dash := int(Tuning.values.mount_key) == 0
	_local.movement.rebind_mount(KEY_Z)
	note("one key one meaning: slot emptied %s, mount emptied by the slot %s, dash emptied %s, mount emptied by the dash %s, back on %s" % [
		slot_emptied, mount_emptied, dash_emptied, mount_emptied_by_dash, _local.movement.mount_key_label()])
	expect(slot_emptied and mount_emptied and dash_emptied and mount_emptied_by_dash
		and int(Tuning.values.mount_key) == KEY_Z and _local.skills.key_for(0) == slot_key
		and int(Tuning.values.dash_key) == dash_key,
		"a_key_given_to_the_mount_leaves_the_slot_or_the_dash_and_the_other_way_round")


# ------------------------------------------------- 7 (b): the speed, the ramps, the turn

# Rides `body` (this machine's) from where it stands to `to` and samples it
# every physics step.
func _ride(to: Vector3, limit := 12.0) -> Dictionary:
	var top := _local.get_mount_speed()
	var out := {"peak": 0.0, "to_top": -1.0, "brake_from": -1.0, "took": -1.0, "air": 0, "wall": 0,
		"from": _local.global_position, "max_y": _local.global_position.y}
	_local.movement.mount_turn_peak = 0.0
	Net.queue_physics(func() -> void: _local.movement.set_target(to))
	var waited := 0.0
	var moving_at := -1.0
	while waited < limit:
		await get_tree().physics_frame
		waited += STEP
		var speed := Vector2(_local.velocity.x, _local.velocity.z).length()
		if moving_at < 0.0 and speed > 0.01:
			moving_at = waited
		out["peak"] = maxf(float(out["peak"]), speed)
		out["max_y"] = maxf(float(out["max_y"]), _local.global_position.y)
		if float(out["to_top"]) < 0.0 and speed >= top * 0.995 and moving_at >= 0.0:
			out["to_top"] = waited - moving_at + STEP
		if float(out["to_top"]) >= 0.0 and float(out["brake_from"]) < 0.0 and speed < top * 0.995:
			out["brake_from"] = waited
		if _local.state == Player.State.AIRBORNE or not _local.is_on_floor():
			out["air"] = int(out["air"]) + 1
		if _local.is_on_wall():
			out["wall"] = int(out["wall"]) + 1
		if moving_at >= 0.0 and speed < 0.02 and not _local.movement.has_target():
			out["took"] = waited - moving_at
			break
	out["brake"] = waited - float(out["brake_from"]) if float(out["brake_from"]) >= 0.0 else -1.0
	out["short"] = Vector2(_local.global_position.x - to.x, _local.global_position.z - to.z).length()
	out["turn_peak"] = _local.movement.mount_turn_peak
	return out


func _put(at: Vector3, yaw: float) -> void:
	await tick_request(func() -> void:
		placed()
		_local.global_position = at
		_local.velocity = Vector3.ZERO
		_local.rotation.y = yaw
		_local.movement.cancel_target()
		_local.movement.set_aim_override(Vector3.INF))
	await _wait(0.5)


func _get_on() -> bool:
	Net.queue_physics(_local.movement.press_mount)
	var took := await _until(func() -> bool: return _local.mount.stage == PlayerMount.Stage.MOUNTED, 3.0)
	await _wait(0.2)
	return took >= 0.0


func _get_off() -> void:
	if _local.sync_mount == PlayerMount.Stage.NONE:
		return
	Net.queue_physics(_local.movement.press_mount)
	await _until(func() -> bool: return _local.mount.stage == PlayerMount.Stage.NONE, 1.0)


func _ride_checks() -> void:
	var s := Tuning.server
	var walk := _local.get_move_speed()
	var top := _local.get_mount_speed()
	note("speeds: bare human walk %.2f m/s, horse %.2f m/s (x%.2f)" % [walk, top, top / walk])
	expect(absf(top - walk * s.mount_speed_mult) < 0.001 and absf(top / walk - 2.31) < 0.001,
		"the_horses_speed_is_2_31_times_a_bare_level_1_humans_walk")
	# Facing along the lane (+x), so the first ride measures the ramp alone.
	var east := atan2(-1.0, 0.0)
	await _put(LANE_A, east)
	expect(await _get_on(), "the_host_is_mounted_for_the_ride")
	var run := await _ride(LANE_B)
	note("human ride %.1f m: peak %.2f m/s, 0 -> top in %.3f s, top -> 0 in %.3f s, whole ride %.2f s, stopped %.2f m from the order, air frames %d" % [
		Vector2(LANE_B.x - LANE_A.x, LANE_B.z - LANE_A.z).length(), run["peak"], run["to_top"], run["brake"], run["took"],
		run["short"], run["air"]])
	expect(absf(float(run["peak"]) - top) < 0.05, "the_ride_tops_out_at_the_horses_speed")
	expect(absf(float(run["to_top"]) - s.mount_accel_time) < 0.05, "it_reaches_the_top_speed_in_0_8_s")
	expect(absf(float(run["brake"]) - s.mount_decel_time) < 0.05, "it_stops_from_the_top_speed_in_0_5_s")
	expect(float(run["short"]) < 0.5, "and_stops_on_the_order")

	# The turn: sent straight back the way it came, from a standstill.
	var yaw_from := _local.rotation.y
	_local.movement.mount_turn_peak = 0.0
	Net.queue_physics(func() -> void: _local.movement.set_target(LANE_A))
	var turned := await _until(func() -> bool:
		return absf(wrapf(_local.rotation.y - yaw_from, -PI, PI)) > deg_to_rad(179.0), 3.0)
	var crept := Vector2(_local.global_position.x - LANE_B.x, _local.global_position.z - LANE_B.z).length()
	note("turned about from a standstill: 179 deg in %.3f s, fastest %.1f deg/s, %.2f m from where it stood" % [
		turned, _local.movement.mount_turn_peak, crept])
	expect(turned >= 0.0 and absf(turned - 179.0 / s.mount_turn_deg) < 0.08 and _local.movement.mount_turn_peak <= s.mount_turn_deg + 0.5,
		"the_horse_turns_at_180_degrees_a_second_and_no_faster")
	await _until(func() -> bool: return _local.state == Player.State.IDLE and not _local.movement.has_target(), 8.0)
	await _wait(0.3)

	# On foot the same about-turn is the walk's eased one, far quicker.
	await _get_off()
	await _put(LANE_A, east)
	var walk_yaw := _local.rotation.y
	Net.queue_physics(func() -> void: _local.movement.set_target(LANE_A + Vector3(-4.0, 0.0, 0.0)))
	var walk_turned := await _until(func() -> bool:
		return absf(wrapf(_local.rotation.y - walk_yaw, -PI, PI)) > deg_to_rad(170.0), 3.0)
	note("on foot the same about-turn: 170 deg in %.3f s" % walk_turned)
	expect(walk_turned >= 0.0 and walk_turned < turned, "which_is_slower_than_the_body_turns_on_foot")
	await _until(func() -> bool: return _local.state == Player.State.IDLE, 4.0)

	# The rider is not in the speed: an orc with 60 kg of gear, same lane.
	await tick_request(func() -> void:
		placed()
		_judge.harness_set_race(_local, Races.Kind.ORC)
		_judge.harness_set_stats(_local, NAN, INF, 60.0))
	await _wait(0.6)
	await _put(Vector3(LANE_A.x, _local.half_height() + 0.05, LANE_A.z), east)
	var orc_walk := _local.get_move_speed()
	var orc_top := _local.get_mount_speed()
	expect(await _get_on(), "the_orc_is_mounted_for_the_ride")
	var orc_run := await _ride(Vector3(LANE_B.x, _local.global_position.y, LANE_B.z))
	note("orc + 60 kg gear: walk %.2f m/s (human %.2f); horse %.2f m/s, peak %.2f, 0 -> top %.3f s, whole ride %.2f s (human %.2f s)" % [
		orc_walk, walk, orc_top, orc_run["peak"], orc_run["to_top"], orc_run["took"], run["took"]])
	expect(absf(orc_top - top) < 0.001 and absf(float(orc_run["peak"]) - float(run["peak"])) < 0.05
		and absf(float(orc_run["took"]) - float(run["took"])) < 0.1 and absf(orc_walk - walk) > 0.1,
		"race_strength_weight_and_gear_change_the_walk_and_not_the_horse")
	await _get_off()
	await tick_request(func() -> void:
		placed()
		_judge.harness_set_race(_local, Races.Kind.HUMAN)
		_judge.harness_clear_stats(_local))
	await _wait(0.6)
	await _put(HOME, 0.0)
	await _wait(3.0)


# ------------------------------------------------- 7b: the two sliders on the slow-down

# West along the lane at the top speed, then sent 45 degrees off (south-west):
# the lowest speed in the 0.4 s after the new order (the order is 19.8 m off,
# so the horse is not yet braking for its end inside that window).
func _dip_after_swerve() -> float:
	await _put(LANE_B, atan2(1.0, 0.0))
	await _get_on()
	Net.queue_physics(func() -> void: _local.movement.set_target(LANE_A))
	var top := _local.get_mount_speed()
	await _until(func() -> bool:
		return Vector2(_local.velocity.x, _local.velocity.z).length() >= top * 0.995 and _local.global_position.x < 3.0, 4.0)
	var here := _local.global_position
	Net.queue_physics(func() -> void: _local.movement.set_target(here + Vector3(-14.0, 0.0, -14.0)))
	var lowest := top
	var waited := 0.0
	while waited < 0.4:
		await get_tree().physics_frame
		waited += STEP
		# The first frames still run on the old path while the new one is asked.
		if waited > 0.05:
			lowest = minf(lowest, Vector2(_local.velocity.x, _local.velocity.z).length())
			var limits := _local.movement.mount_limits
			_swerve_limits = Vector3(minf(_swerve_limits.x, limits.x), minf(_swerve_limits.y, limits.y), minf(_swerve_limits.z, limits.z))
	note("   swerve: lowest allowed by misalignment %.2f, by the arc %.2f, by braking %.2f; path points %d; lowest speed %.2f" % [
		_swerve_limits.x, _swerve_limits.y, _swerve_limits.z, _local.movement._path.size(), lowest])
	_swerve_misaligned = _swerve_limits.x
	_swerve_limits = Vector3(INF, INF, INF)
	Net.queue_physics(_local.movement.cancel_target)
	await _wait(0.8)
	await _get_off()
	return lowest


# From a standstill, sent straight behind: the speed 0.3 s after the order.
func _speed_into_about_turn() -> float:
	await _put(LANE_B, atan2(-1.0, 0.0))
	await _get_on()
	Net.queue_physics(func() -> void: _local.movement.set_target(LANE_A))
	await _wait(0.3)
	var speed := Vector2(_local.velocity.x, _local.velocity.z).length()
	Net.queue_physics(_local.movement.cancel_target)
	await _wait(0.8)
	await _get_off()
	return speed


func _turn_slow_checks() -> void:
	var s := Tuning.server
	var top := _local.get_mount_speed()
	var slow_was: float = s.mount_turn_slow_deg
	var min_was: float = s.mount_turn_min_ratio
	note("slow-down sliders: starts at %.0f deg off, lowest ratio %.2f (range %s)" % [
		slow_was, min_was, Tuning.limits_for("mount_turn_slow_deg")])
	var dip_default := await _dip_after_swerve()
	var allowed_default := _swerve_misaligned
	s.mount_turn_slow_deg = 60.0
	var dip_late := await _dip_after_swerve()
	var allowed_late := _swerve_misaligned
	s.mount_turn_slow_deg = slow_was
	var crawl_default := await _speed_into_about_turn()
	s.mount_turn_min_ratio = 0.5
	var crawl_half := await _speed_into_about_turn()
	s.mount_turn_min_ratio = min_was
	note("swerved 45 deg at %.2f m/s: lowest speed %.2f with the slow-down from %.0f deg, %.2f with it from 60 deg" % [
		top, dip_default, slow_was, dip_late])
	note("0.3 s into an about-turn from a standstill: %.2f m/s at lowest ratio %.2f, %.2f m/s at 0.50" % [
		crawl_default, min_was, crawl_half])
	note("the misalignment rule alone allowed %.2f m/s from %.0f deg and %.2f m/s from 60 deg; the rest of the dip at 60 is the arc limit (the path's next point is near)" % [
		allowed_default, slow_was, allowed_late])
	expect(allowed_default < top * 0.8 and dip_default < top * 0.95 and absf(allowed_late - top) < 0.01 and dip_late > dip_default,
		"the_start_angle_slider_decides_whether_a_45_degree_swerve_is_slowed_for_misalignment")
	expect(crawl_default < 0.5 and crawl_half > 2.0,
		"the_lowest_ratio_slider_decides_whether_the_horse_moves_through_an_about_turn")
	await _put(HOME, 0.0)
	await _wait(3.0)


# ------------------------------------------------- 8 (b): the floor snap on a downhill

func _hill_spot(spot: Vector3) -> Vector3:
	return Vector3(spot.x, TestTerrain.height_at(spot.x, spot.z) + _local.half_height() + 0.05, spot.z)


func _hill_checks() -> void:
	var snap_was: float = Tuning.server.mount_floor_snap
	var east := atan2(-1.0, 0.0)
	await _put(_hill_spot(HILL_A), east)
	expect(await _get_on(), "the_host_is_mounted_on_the_terrain")
	var with_snap := await _ride(_hill_spot(HILL_B))
	await _get_off()
	await _put(_hill_spot(HILL_A), east)
	Tuning.server.mount_floor_snap = 0.0
	await _get_on()
	var without := await _ride(_hill_spot(HILL_B))
	Tuning.server.mount_floor_snap = snap_was
	await _get_off()
	note("over the 6 m hill (30 deg sides) at the horse's speed: snap %.2f m -> %d frames off the floor, peak %.2f m/s, top y %.2f, %.2f m short; snap 0 -> %d frames off the floor, top y %.2f" % [
		snap_was, with_snap["air"], with_snap["peak"], with_snap["max_y"], with_snap["short"], without["air"], without["max_y"]])
	expect(float(with_snap["max_y"]) - _hill_spot(HILL_A).y > 4.0 and float(with_snap["short"]) < 1.0,
		"the_ride_goes_over_the_hill_and_arrives")
	expect(int(with_snap["air"]) == 0, "with_the_floor_snap_the_horse_never_leaves_the_ground_downhill")
	await _put(HOME, 0.0)
	await _wait(3.0)


# ------------------------------------------------- 9 (b): the client rides, the server watches

func _client_ride_checks() -> void:
	var mate := _mate()
	var warnings := _judge.move_warnings
	var corrections := _judge.move_corrections
	client_ride.rpc_id(_client_peer(), LANE_A, LANE_B, false)
	var seen_peak := 0.0
	var waited := 0.0
	var last := mate.global_position
	var mounted_seen := false
	while waited < 14.0 and not _reports.has("ride"):
		await get_tree().physics_frame
		waited += STEP
		# Counted from a moment after the horse appears: the park before it is
		# a teleport, and reads as one.
		if mate.mount.is_mounted() and not mounted_seen:
			mounted_seen = true
			await _wait(0.3)
		if mounted_seen:
			seen_peak = maxf(seen_peak, _judge.observed_h_speed(mate))
		last = mate.global_position
	var ride := await _take_report("ride")
	await _wait(0.5)
	var here := describe(mate)
	note("client rode the lane: its own peak %.2f m/s in %.2f s, stopped %.2f m from the order; the server's samples peaked at %.2f m/s; body here %s, there %s; warnings %d, corrections %d" % [
		float(ride.get("peak", 0.0)), float(ride.get("took", -1.0)), float(ride.get("short", -1.0)), seen_peak,
		here["body_at"], ride.get("at"), _judge.move_warnings - warnings, _judge.move_corrections - corrections])
	expect(mounted_seen and absf(float(ride.get("peak", 0.0)) - _local.get_mount_speed()) < 0.05,
		"the_client_rides_at_the_horses_speed")
	expect(seen_peak > _local.get_mount_speed() * 0.9, "the_server_sees_the_clients_body_at_that_speed")
	expect((here["body_at"] as Vector3).distance_to(ride.get("at", Vector3.INF) as Vector3) < 0.1
		and here["stage"] == PlayerMount.Stage.MOUNTED and here["horse"],
		"both_screens_put_the_ridden_horse_in_the_same_place")
	expect(_judge.move_corrections == corrections, "the_move_check_does_not_put_the_ridden_body_back")
	# Getting off at full speed: the stage changes on the server at once and
	# the body's slowing arrives a round trip later.
	warnings = _judge.move_warnings
	client_ride.rpc_id(_client_peer(), LANE_B, LANE_A, true)
	var bail := await _take_report("ride", 14.0)
	await _wait(1.0)
	note("client got off at %.2f m/s mid-ride: stage on the host %s, warnings %d, corrections %d" % [
		float(bail.get("bail_speed", 0.0)), PlayerMount.Stage.keys()[mate.sync_mount],
		_judge.move_warnings - warnings, _judge.move_corrections - corrections])
	expect(float(bail.get("bail_speed", 0.0)) > _local.get_mount_speed() * 0.9 and mate.sync_mount == PlayerMount.Stage.NONE
		and _judge.move_corrections == corrections,
		"getting_off_at_full_speed_is_not_read_as_a_sprint")
	client_park.rpc_id(_client_peer(), CLIENT_SPOT)
	await _wait(3.2)


# ------------------------------------------------- 10 (c): on the horse a body only moves

func _restriction_checks() -> void:
	var mate := _mate()
	await _reset_pair()
	expect(await _get_on(), "the_host_is_mounted_for_the_restrictions")
	# Jump and dash keys: no jump, no dash, and off the horse, like a skill key
	# (the user's call after c).
	for key_name: String in ["jump", "dash"]:
		if not _local.is_mounted():
			await _wait(0.2)
			if not await _get_on():
				break
		var dropped := _local.movement.mounted_presses_dropped
		var stamina := _local.stamina
		await tick_request(func() -> void:
			_local.movement.set_aim_override(_local.global_position + Vector3(0.0, 0.0, 4.0))
			if key_name == "jump":
				_local.movement.press_jump()
			else:
				_local.movement.press_dash())
		var off := await _until(func() -> bool: return _local.mount.stage == PlayerMount.Stage.NONE, 0.5)
		var moved_state := false
		for _frame in range(40):
			await get_tree().physics_frame
			moved_state = moved_state or _local.state == Player.State.AIRBORNE or _local.state == Player.State.DASH
		note("%s key on the horse: off in %.3f s, jumped or dashed %s, presses caught %d, stamina %.1f -> %.1f, why %s" % [
			key_name, off, moved_state, _local.movement.mounted_presses_dropped - dropped, stamina, _local.stamina,
			_judge.last_mount.get("why", "")])
		expect(off >= 0.0 and off <= 0.05 and not moved_state and _local.movement.mounted_presses_dropped - dropped == 1
			and _local.stamina >= stamina - 0.01 and String(_judge.last_mount.get("why", "")) == "asked",
			"the_%s_key_on_the_horse_only_gets_off" % key_name)
		await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	await _wait(3.2)
	if not _local.is_mounted():
		expect(await _get_on(), "the_host_is_mounted_for_the_skill_keys")
	# A skill key: no cast, and off the horse. Every slot that holds a skill.
	var slots := []
	for index in PlayerSkills.SLOT_COUNT:
		var def := _local.skills.slot_def(index)
		if def == null:
			continue
		if not _local.is_mounted():
			await _wait(0.2)
			if not await _get_on():
				break
		var ruled := _judge.skills_ruled
		var holds := _judge.hold_count()
		var cast := false
		Net.queue_physics(func() -> void: _local.skills.press_slot(index))
		var off := await _until(func() -> bool: return _local.mount.stage == PlayerMount.Stage.NONE, 0.5)
		for _frame in range(30):
			await get_tree().physics_frame
			cast = cast or _local.is_casting() or _local.skills.is_blocking()
		Net.queue_physics(func() -> void: _local.skills.release_slot(index))
		await _wait(0.1)
		slots.append("%s: off in %.3f s, cast %s, rulings +%d, holds +%d" % [
			def.id, off, cast, _judge.skills_ruled - ruled, _judge.hold_count() - holds])
		expect(off >= 0.0 and off <= 0.05 and not cast and _judge.skills_ruled == ruled and _judge.hold_count() == holds
			and String(_judge.last_mount.get("why", "")) == "asked",
			"the_%s_key_on_the_horse_only_gets_off" % def.id)
	note("skill keys on the horse: %s" % [slots])
	await _wait(3.2)

	# The server says the same to an intent that reaches it anyway.
	expect(await _get_on(), "the_host_is_mounted_again")
	var refused := _judge.mounted_refusals
	var answers := []
	for row: Array in [
			[ServerAuthority.Intent.SKILL, {"skill": "punch", "direction": Vector3.FORWARD}],
			[ServerAuthority.Intent.SHOVE, {"direction": Vector3.FORWARD}],
			[ServerAuthority.Intent.GRAB, {"target": _world.get_node("Rock_0").get_path()}],
			[ServerAuthority.Intent.BLOCK, {"on": true}]]:
		var answer: Variant = ServerAuthority.submit_intent(_local, int(row[0]), row[1] as Dictionary)
		answers.append("%s -> %s" % [ServerAuthority.Intent.keys()[int(row[0])], answer])
	note("intents sent from the horse: %s; refused as mounted %d, last refusal %s, still mounted %s" % [
		answers, _judge.mounted_refusals - refused, _judge.last_refusal, _local.is_mounted()])
	expect(_judge.mounted_refusals - refused == 4 and _judge.last_refusal == "mounted" and _local.is_mounted()
		and not _judge.is_blocking(1) and _judge.hold_count() == 0,
		"the_server_refuses_a_skill_shove_grab_and_block_from_a_rider")
	# A client's skill that crosses its own mount on the wire.
	client_park.rpc_id(_client_peer(), CLIENT_SPOT)
	await _wait(0.9)
	client_press_mount.rpc_id(_client_peer())
	await _until(func() -> bool: return mate.sync_mount == PlayerMount.Stage.MOUNTED, 3.0)
	refused = _judge.mounted_refusals
	var ruled_before := _judge.skills_ruled
	client_send_skill.rpc_id(_client_peer(), "punch")
	await _wait(0.8)
	note("client sent a punch intent from the horse: refused %d, rulings +%d, client still mounted %s" % [
		_judge.mounted_refusals - refused, _judge.skills_ruled - ruled_before, mate.sync_mount == PlayerMount.Stage.MOUNTED])
	expect(_judge.mounted_refusals - refused == 1 and _judge.skills_ruled == ruled_before
		and mate.sync_mount == PlayerMount.Stage.MOUNTED, "and_refuses_the_same_from_a_client_on_its_horse")
	# A rider is not picked up.
	await tick_request(func() -> void:
		placed()
		_judge.harness_set_stats(_local, 150.0)
		_local.global_position = mate.global_position + Vector3(1.3, 0.0, 0.0)
		_local.velocity = Vector3.ZERO)
	await _get_off()
	await _wait(0.3)
	var can_mounted := _judge.can_grab(_local, mate)
	client_press_mount.rpc_id(_client_peer())
	await _until(func() -> bool: return mate.sync_mount == PlayerMount.Stage.NONE, 2.0)
	await _wait(0.3)
	var can_on_foot := _judge.can_grab(_local, mate)
	note("a strong body 1.3 m from the client: may grab it on its horse %s, on foot %s" % [can_mounted, can_on_foot])
	expect(not can_mounted and can_on_foot, "a_rider_cannot_be_picked_up_off_the_horse")
	await tick_request(func() -> void: _judge.harness_clear_stats(_local))
	await _reset_pair()
	await _wait(3.0)


# ------------------------------------------------- 11 (c): a blow on a rider

# Stands `body_is_local` in front of the scarecrow, at the mounted capsule's
# distance, and returns the spot.
func _slam_spot(dummy: Dummy) -> Vector3:
	var gap := Tuning.server.mount_radius + _judge.body_radius(dummy) + 0.15
	var spot := dummy.home + dummy.attack_direction() * gap
	return Vector3(spot.x, HOME.y, spot.z)


func _slams(on: bool) -> void:
	Tuning.server.dummy_attack_enabled = on


# Mounted in front of the scarecrow with `strength`, then one slam: what the
# server ruled and what both screens show.
func _hit_while_mounted(dummy: Dummy, strength: float, label: String) -> Dictionary:
	_slams(false)
	await Harness.dummy_home(dummy, _judge, _local, _mate(), get_tree(), note)
	await tick_request(func() -> void:
		placed()
		_judge.harness_set_stats(_local, strength)
		_judge.server_set_hp(_local, _local.stats.max_hp)
		_local.global_position = _slam_spot(dummy)
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target()
		_local.movement.set_aim_override(Vector3.INF))
	await _wait(0.6)
	var mounted := await _get_on()
	var hp := _local.hp
	var hits := _judge.mount_hits
	var throws := _judge.mount_throws
	var vanished := _local.mount.horses_vanished
	var at := _local.global_position
	_slams(true)
	var took := await _until(func() -> bool: return _local.sync_mount == PlayerMount.Stage.NONE, 6.0)
	_slams(false)
	# What the body does in the half second after it comes off.
	var airborne := false
	var peak_y := _local.global_position.y
	var lingering_after := -1
	for frame in range(60):
		await get_tree().physics_frame
		airborne = airborne or _local.state == Player.State.AIRBORNE
		peak_y = maxf(peak_y, _local.global_position.y)
		if frame == 6:
			lingering_after = _local.mount.lingering_count()
	client_report_body.rpc_id(_client_peer(), _local.get_path(), "hit_" + label)
	var seen := await _take_report("hit_" + label)
	var knock: Dictionary = _judge.last_knock.get(1, {})
	var out := {"mounted": mounted, "took": took, "why": String(_judge.last_mount.get("why", "")),
		"launched": bool(knock.get("launched", false)), "h_speed": float(knock.get("h_speed", 0.0)),
		"tolerance": float(knock.get("tolerance", 0.0)), "lost": hp - _local.hp, "airborne": airborne,
		"rise": peak_y - at.y, "lingering": lingering_after, "vanished": _local.mount.horses_vanished - vanished,
		"hits": _judge.mount_hits - hits, "throws": _judge.mount_throws - throws, "state": Player.State.keys()[_local.state],
		"capsule_back": not (_local.get_node("BodyShape") as CollisionShape3D).disabled,
		"seen_lingering": int(seen.get("lingering", -1)), "seen_stage": int(seen.get("stage", -1)),
		"seen_vanished": int(seen.get("vanished", -1))}
	note("%s (strength %.0f): mounted %s, off after %.2f s, why %s; knock %.2f vs tolerance %.2f -> %s; HP -%.1f; airborne %s (rose %.2f m), state %s; horse left standing %d (client sees %d), vanished here +%d (client total %d); server counts hit +%d thrown +%d" % [
		label, strength, mounted, took, out["why"], out["h_speed"], out["tolerance"],
		"launched" if out["launched"] else "slid", out["lost"], airborne, out["rise"], out["state"],
		out["lingering"], out["seen_lingering"], out["vanished"], out["seen_vanished"], out["hits"], out["throws"]])
	await _until(func() -> bool: return _local.state == Player.State.IDLE, 5.0)
	await _wait(3.2)
	return out


func _hit_checks() -> void:
	var mate := _mate()
	var dummy := _world.get_node("Dummy_1") as Dummy
	var slam := Skills.get_def("dummy_slam")
	var period: float = Tuning.server.dummy_attack_period
	var enabled: bool = Tuning.server.dummy_attack_enabled
	Tuning.server.dummy_attack_period = 1.5
	client_park.rpc_id(_client_peer(), _slam_spot(dummy) + Vector3(0.0, 0.0, 8.0))
	note("scarecrow slam: windup %.2f s, reach %.1f, damage %.0f, power %.0f; rider stands %.2f m from it" % [
		slam.impact_time(), slam.value("reach"), slam.value("damage"), slam.value("knock_power"),
		Tuning.server.mount_radius + _judge.body_radius(dummy) + 0.15])

	# A real blow during the summon: asked for as the windup starts.
	await Harness.dummy_home(dummy, _judge, _local, mate, get_tree(), note)
	await tick_request(func() -> void:
		placed()
		_judge.server_set_hp(_local, _local.stats.max_hp)
		_local.global_position = _slam_spot(dummy)
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target())
	await _wait(0.6)
	var cancelled := _judge.mounts_cancelled
	var granted := _judge.mounts_granted
	_slams(true)
	await _until(func() -> bool: return dummy.attack_phase == "windup", 5.0)
	Net.queue_physics(_local.movement.press_mount)
	await _wait(1.6)
	_slams(false)
	note("slammed during the summon: stage %s, why %s, cancelled +%d, granted +%d, HP %.0f / %.0f" % [
		PlayerMount.Stage.keys()[_local.sync_mount], _judge.last_mount.get("why", ""), _judge.mounts_cancelled - cancelled,
		_judge.mounts_granted - granted, _local.hp, _local.stats.max_hp])
	expect(_local.sync_mount == PlayerMount.Stage.NONE and String(_judge.last_mount.get("why", "")) == "hurt"
		and _judge.mounts_granted == granted and _local.hp < _local.stats.max_hp,
		"a_scarecrows_blow_during_the_summon_calls_it_off")
	await _until(func() -> bool: return _local.state == Player.State.IDLE, 5.0)

	# Within the rider's tolerance: off the horse, on its feet.
	var held := await _hit_while_mounted(dummy, 150.0, "strong rider")
	expect(held["mounted"] and float(held["took"]) >= 0.0 and float(held["lost"]) > 0.0, "the_scarecrow_hits_a_rider")
	expect(not held["launched"] and held["why"] == "hit" and held["hits"] == 1 and held["throws"] == 0,
		"a_blow_inside_the_riders_tolerance_gets_it_off_the_horse")
	expect(not held["airborne"] and float(held["rise"]) < 0.1 and held["capsule_back"],
		"and_it_lands_on_its_feet_where_it_stood")
	expect(held["lingering"] == 1 and held["vanished"] == 0 and held["seen_lingering"] == 1
		and held["seen_stage"] == PlayerMount.Stage.NONE,
		"with_the_horse_left_standing_as_after_any_dismount_on_both_screens")

	# Over it: thrown, the ordinary launch, and the horse gone at once.
	var thrown := await _hit_while_mounted(dummy, 2.0, "weak rider")
	expect(thrown["mounted"] and thrown["launched"] and thrown["why"] == "thrown" and thrown["throws"] == 1 and thrown["hits"] == 0,
		"a_blow_over_the_riders_tolerance_throws_it_off")
	expect(thrown["airborne"] and float(thrown["rise"]) > 0.05, "and_the_ordinary_launch_applies")
	expect(thrown["lingering"] == 0 and thrown["vanished"] == 1 and thrown["seen_lingering"] == 0
		and thrown["seen_stage"] == PlayerMount.Stage.NONE,
		"and_the_horse_is_gone_at_once_on_both_screens")
	expect(float(thrown["tolerance"]) < float(held["tolerance"]) and absf(float(thrown["h_speed"]) - float(held["h_speed"])) < 20.0,
		"the_tolerance_in_the_verdict_is_the_riders_own")
	await tick_request(func() -> void:
		placed()
		_judge.harness_clear_stats(_local)
		_judge.server_set_hp(_local, _local.stats.max_hp)
		_local.global_position = _slam_spot(dummy) + Vector3(6.0, 0.0, 6.0)
		_local.velocity = Vector3.ZERO)

	# The client as the rider: whatever the verdict is, the rest follows it.
	await Harness.dummy_home(dummy, _judge, _local, mate, get_tree(), note)
	client_park.rpc_id(_client_peer(), _slam_spot(dummy))
	await _wait(1.0)
	client_press_mount.rpc_id(_client_peer())
	var up := await _until(func() -> bool: return mate.sync_mount == PlayerMount.Stage.MOUNTED, 3.0)
	await _wait(0.4)
	var hp := mate.hp
	var throws := _judge.mount_throws
	var hits := _judge.mount_hits
	var vanished := mate.mount.horses_vanished
	_slams(true)
	var took := await _until(func() -> bool: return mate.sync_mount == PlayerMount.Stage.NONE, 6.0)
	_slams(false)
	# The client's own screen follows the server's word a little later: wait
	# for it to change, up to 1 s (was a fixed 0.3 s; the headless client's
	# frame gaps ate that margin 2 times in 20).
	client_watch_stage.rpc_id(_client_peer(), mate.get_path(), "client_hit_followed")
	var followed := await _take_report("client_hit_followed", 4.0)
	note("client's own screen followed the server %.3f s after the watch reached it" % float(followed.get("followed", -1.0)))
	var knock: Dictionary = _judge.last_knock.get(_client_peer(), {})
	var launched := bool(knock.get("launched", false))
	client_report_body.rpc_id(_client_peer(), mate.get_path(), "client_hit")
	var own := await _take_report("client_hit")
	note("client rider slammed: mounted %.2f, off after %.2f s, why %s, knock %.2f vs %.2f -> %s, HP -%.1f; on the host: horse left %d, vanished +%d; on its own screen: stage %s, horse left %d, vanished total %d, capsule off %s" % [
		up, took, _judge.last_mount.get("why", ""), float(knock.get("h_speed", 0.0)), float(knock.get("tolerance", 0.0)),
		"launched" if launched else "slid", hp - mate.hp, mate.mount.lingering_count(), mate.mount.horses_vanished - vanished,
		own.get("stage"), own.get("lingering"), own.get("vanished"), own.get("capsule_off")])
	expect(up >= 0.0 and took >= 0.0 and hp - mate.hp > 0.0, "the_scarecrow_hits_a_client_on_its_horse")
	if launched:
		expect(String(_judge.last_mount.get("why", "")) == "thrown" and _judge.mount_throws == throws + 1
			and mate.mount.lingering_count() == 0 and int(own.get("lingering", -1)) == 0 and not own.get("capsule_off", true),
			"the_thrown_client_has_no_horse_left_on_either_screen")
	else:
		expect(String(_judge.last_mount.get("why", "")) == "hit" and _judge.mount_hits == hits + 1
			and mate.mount.lingering_count() == 1 and int(own.get("lingering", -1)) == 1 and not own.get("capsule_off", true),
			"the_clients_horse_is_left_standing_on_both_screens")
	Tuning.server.dummy_attack_period = period
	Tuning.server.dummy_attack_enabled = enabled
	await tick_request(func() -> void: _judge.server_set_hp(mate, mate.stats.max_hp))
	await _reset_pair()
	await _wait(3.0)


# The client slammed off its horse, `times` over: what its own screen shows
# once it has followed the server, 1 s at most (as in _hit_checks),
# and how long after the server's word its own screen followed.
func _thrown_repeat(times: int) -> void:
	var mate := _mate()
	var dummy := _world.get_node("Dummy_1") as Dummy
	var period: float = Tuning.server.dummy_attack_period
	var enabled: bool = Tuning.server.dummy_attack_enabled
	Tuning.server.dummy_attack_period = 1.5
	await tick_request(func() -> void:
		placed()
		_local.global_position = _slam_spot(dummy) + Vector3(6.0, 0.0, 6.0)
		_local.velocity = Vector3.ZERO)
	var failed := 0
	for trial in range(times):
		_slams(false)
		await Harness.dummy_home(dummy, _judge, _local, mate, get_tree(), note)
		client_park.rpc_id(_client_peer(), _slam_spot(dummy))
		await _wait(1.0)
		client_press_mount.rpc_id(_client_peer())
		var up := await _until(func() -> bool: return mate.sync_mount == PlayerMount.Stage.MOUNTED, 3.0)
		await _wait(0.4)
		var throws := _judge.mount_throws
		_slams(true)
		var took := await _until(func() -> bool: return mate.sync_mount == PlayerMount.Stage.NONE, 6.0)
		_slams(false)
		var frame_off := Engine.get_physics_frames()
		client_watch_stage.rpc_id(_client_peer(), mate.get_path(), "lag_%d" % trial)
		var lag := await _take_report("lag_%d" % trial, 4.0)
		var knock: Dictionary = _judge.last_knock.get(_client_peer(), {})
		client_report_body.rpc_id(_client_peer(), mate.get_path(), "trial_%d" % trial)
		var own := await _take_report("trial_%d" % trial)
		var thrown := String(_judge.last_mount.get("why", "")) == "thrown" and _judge.mount_throws == throws + 1
		var passed: bool = thrown and mate.mount.lingering_count() == 0 and int(own.get("lingering", -1)) == 0 \
			and not own.get("capsule_off", true)
		if not passed:
			failed += 1
		note("thrown trial %d: %s; mounted %.2f, off after %.2f s (host frame %d), why %s, launched %s; client's own screen once it followed (1 s at most): stage %s, horses left %s, vanished total %s, capsule off %s; when the watch RPC arrived its screen showed stage %s / sync %s, and followed %.3f s later (state then %s, hp %s)" % [
			trial + 1, "PASS" if passed else "FAIL", up, took, frame_off, _judge.last_mount.get("why", ""),
			knock.get("launched"), own.get("stage"), own.get("lingering"), own.get("vanished"), own.get("capsule_off"),
			lag.get("stage_at_rpc"), lag.get("sync_at_rpc"), float(lag.get("followed", -1.0)), lag.get("state"), lag.get("hp")])
		note("thrown trial %d clock (client's own, real ms): report RPC arrived %d ms after the watch RPC (host sent them 300 apart); stage followed %d ms after the watch RPC, in %d physics steps; longest gap between its physics steps %d ms" % [
			trial + 1, int(own.get("msec", 0)) - int(lag.get("arrived_ms", 0)), int(lag.get("real_ms", -1)),
			roundi(float(lag.get("followed", 0.0)) / STEP), int(lag.get("worst_gap_ms", -1))])
		await tick_request(func() -> void: _judge.server_set_hp(mate, mate.stats.max_hp))
		await _until(func() -> bool: return mate.state == Player.State.IDLE, 5.0)
		await _wait(1.0)
	note("thrown trials: %d, failed %d" % [times, failed])
	expect(failed == 0, "the_thrown_client_has_no_horse_left_on_either_screen_every_time")
	Tuning.server.dummy_attack_period = period
	Tuning.server.dummy_attack_enabled = enabled


# ------------------------------------------------- the stall at a launch, timed

# Real time between this process's physics steps, and every node that enters
# the tree, while _gap_on. Measurement only.
var _gap_on := false
var _gap_last_usec := 0
var _gap_steps: Array = []
var _gap_nodes: Array = []
var _gap_hit_usec := 0
var _gap_hp := 0.0
var _gap_frames: Array = []
var _gap_frame_last := 0


func _physics_process(_delta: float) -> void:
	if not _gap_on:
		return
	var now := Time.get_ticks_usec()
	_gap_steps.append([now, now - _gap_last_usec, Engine.get_process_frames()])
	_gap_last_usec = now
	if _gap_hit_usec == 0 and (_local.hp < _gap_hp - 0.01 or _local.state == Player.State.AIRBORNE):
		_gap_hit_usec = now


func _process(_delta: float) -> void:
	if not _gap_on:
		return
	var now := Time.get_ticks_usec()
	_gap_frames.append([now, now - _gap_frame_last])
	_gap_frame_last = now


func _gap_node_added(node: Node) -> void:
	if not _gap_on:
		return
	var text := "%s(%s)" % [node.name, node.get_class()]
	var script := node.get_script() as Script
	if script != null:
		text += "[%s]" % script.resource_path.get_file()
	for prop: String in ["mesh", "material_override", "process_material", "stream", "texture", "draw_pass_1", "font"]:
		if prop in node:
			var res := node.get(prop) as Resource
			if res != null:
				text += " %s=%s%s" % [prop, res.get_class(), (":" + res.resource_path.get_file()) if res.resource_path != "" else ""]
	var parent := node.get_parent()
	_gap_nodes.append([Time.get_ticks_usec(), text + " under " + (String(parent.name) if parent != null else "?")])


func _gap_begin() -> void:
	if not get_tree().node_added.is_connected(_gap_node_added):
		get_tree().node_added.connect(_gap_node_added)
	_gap_steps = []
	_gap_nodes = []
	_gap_frames = []
	_gap_hit_usec = 0
	_gap_hp = _local.hp
	_gap_last_usec = Time.get_ticks_usec()
	_gap_frame_last = _gap_last_usec
	_gap_on = true


# What the record says: the longest gap in the second around the hit, the
# longest outside it, and what entered the tree during the long one.
func _gap_end() -> Dictionary:
	_gap_on = false
	var hit := _gap_hit_usec
	var worst := 0
	var worst_at := 0
	var worst_from := 0
	var calm := 0
	var long_gaps := 0
	var all_long := []
	for row: Array in _gap_steps:
		var at := int(row[0])
		var gap := int(row[1])
		if gap > 50000 and hit != 0:
			all_long.append("%d@%+d" % [gap / 1000, (at - hit) / 1000])
		if hit != 0 and at >= hit - 300000 and at <= hit + 700000:
			if gap > 20000:
				long_gaps += 1
			if gap > worst:
				worst = gap
				worst_at = at
				worst_from = at - gap
		elif gap > calm:
			calm = gap
	var frame_worst := 0
	for row: Array in _gap_frames:
		var at := int(row[0])
		if hit != 0 and at >= hit - 300000 and at <= hit + 700000:
			frame_worst = maxi(frame_worst, int(row[1]))
	var during := []
	var around := []
	for row: Array in _gap_nodes:
		var at := int(row[0])
		if at >= worst_from and at <= worst_at:
			during.append(row[1])
		elif hit != 0 and at >= hit - 300000 and at <= hit + 700000:
			around.append(row[1])
	return {"hit_seen": hit != 0, "worst_ms": float(worst) / 1000.0, "worst_after_hit_ms": float(worst_at - hit) / 1000.0,
		"calm_worst_ms": float(calm) / 1000.0, "long_gaps": long_gaps, "frame_worst_ms": float(frame_worst) / 1000.0,
		"steps": _gap_steps.size(), "all_long": all_long, "frames": _gap_frames.size(),
		"span_ms": float(_gap_last_usec - int((_gap_steps[0] as Array)[0])) / 1000.0 if _gap_steps.size() > 0 else 0.0,
		"nodes_during": during, "nodes_around": around, "state": Player.State.keys()[_local.state]}


func _gap_line(label: String, got: Dictionary) -> String:
	return "%s: hit seen %s; longest gap between physics steps around the hit %.1f ms (ending %.1f ms after the hit showed), longest away from it %.1f ms, gaps over 20 ms around the hit %d, longest gap between drawn frames %.1f ms; nodes entering the tree during the long gap: %s; in the rest of that second: %s" % [
		label, got.get("hit_seen"), float(got.get("worst_ms", -1.0)), float(got.get("worst_after_hit_ms", 0.0)),
		float(got.get("calm_worst_ms", -1.0)), int(got.get("long_gaps", -1)), float(got.get("frame_worst_ms", -1.0)),
		got.get("nodes_during"), got.get("nodes_around")] + "; every gap over 50 ms in the %.0f ms record, as ms@ms-from-hit: %s; %d steps, %d drawn frames" % [
		float(got.get("span_ms", 0.0)), got.get("all_long"), int(got.get("steps", 0)), int(got.get("frames", 0))]


# The client on foot in front of the scarecrow, knocked away `times` over.
func _knock_repeat(times: int) -> void:
	var mate := _mate()
	var dummy := _world.get_node("Dummy_1") as Dummy
	var period: float = Tuning.server.dummy_attack_period
	var enabled: bool = Tuning.server.dummy_attack_enabled
	Tuning.server.dummy_attack_period = 1.5
	await tick_request(func() -> void:
		placed()
		_local.global_position = _slam_spot(dummy) + Vector3(6.0, 0.0, 6.0)
		_local.velocity = Vector3.ZERO)
	for trial in range(times):
		_slams(false)
		await Harness.dummy_home(dummy, _judge, _local, mate, get_tree(), note)
		client_park.rpc_id(_client_peer(), _slam_spot(dummy))
		await _wait(1.5)
		var hp := mate.hp
		client_gap_watch.rpc_id(_client_peer(), "gap_%d" % trial, 4.5)
		_gap_hp = -1000.0
		_gap_begin()
		_gap_hp = -1000.0
		await _wait(0.5)
		_slams(true)
		await _until(func() -> bool: return mate.hp < hp - 0.01, 3.5)
		_slams(false)
		var knock: Dictionary = _judge.last_knock.get(_client_peer(), {})
		var got := await _take_report("gap_%d" % trial, 8.0)
		_gap_hit_usec = _gap_last_usec
		var host_got := _gap_end()
		note("knock trial %d, the host process over the same seconds: gaps over 50 ms as ms@ms-from-end: %s; %d steps, %d drawn frames in %.0f ms" % [
			trial + 1, host_got.get("all_long"), int(host_got.get("steps", 0)), int(host_got.get("frames", 0)), float(host_got.get("span_ms", 0.0))])
		note(_gap_line("knock trial %d (client on foot, launched %s, HP -%.0f)" % [trial + 1, knock.get("launched"), hp - mate.hp], got))
		await tick_request(func() -> void: _judge.server_set_hp(mate, mate.stats.max_hp))
		await _until(func() -> bool: return mate.state == Player.State.IDLE, 5.0)
		await _wait(0.5)
	Tuning.server.dummy_attack_period = period
	Tuning.server.dummy_attack_enabled = enabled


# This process alone: its own body knocked away on foot, `times` over.
func _knock_solo(times: int) -> void:
	var dummy := _world.get_node("Dummy_1") as Dummy
	Tuning.server.dummy_attack_period = 1.5
	note("solo: display server %s, vsync %d, max fps %d" % [DisplayServer.get_name(), DisplayServer.window_get_vsync_mode(), Engine.max_fps])
	for trial in range(times):
		_slams(false)
		await Harness.dummy_home(dummy, _judge, _local, null, get_tree(), note)
		await tick_request(func() -> void:
			placed()
			_judge.server_set_hp(_local, _local.stats.max_hp)
			_local.global_position = _slam_spot(dummy)
			_local.velocity = Vector3.ZERO
			_local.movement.cancel_target())
		await _wait(1.5)
		var hp := _local.hp
		_gap_begin()
		await _wait(0.5)
		_slams(true)
		await _until(func() -> bool: return _local.hp < hp - 0.01, 3.5)
		_slams(false)
		await _wait(1.0)
		var got := _gap_end()
		var knock: Dictionary = _judge.last_knock.get(1, {})
		note(_gap_line("solo knock trial %d (on foot, launched %s, HP -%.0f)" % [trial + 1, knock.get("launched"), hp - _local.hp], got))
		await _until(func() -> bool: return _local.state == Player.State.IDLE, 5.0)
		await _wait(0.5)
	print("MT_RESULT peer=%d solo knock trials=%d" % [_peer_id, times])


# ------------------------------------------------- 12 (c): the no-mount-zone slot

func _zone_checks() -> void:
	note("no-mount zones as shipped: %d; riding allowed at the mark: %s" % [
		_judge.no_mount_zones.size(), _judge.mount_allowed_at(HOME)])
	expect(_judge.no_mount_zones.is_empty() and _judge.mount_allowed_at(HOME),
		"no_zone_is_set_anywhere_riding_is_allowed_everywhere")
	# A zone put in the slot by hand, around the mark.
	_judge.no_mount_zones.append(AABB(HOME - Vector3(3.0, 3.0, 3.0), Vector3(6.0, 6.0, 6.0)))
	var granted := _judge.mounts_granted
	Net.queue_physics(_local.movement.press_mount)
	await _wait(1.4)
	var inside := _local.sync_mount
	var why := _judge.last_refusal
	# Asked for outside it, walked into it during the summon.
	await _put(HOME + Vector3(0.0, 0.0, 6.0), 0.0)
	Net.queue_physics(_local.movement.press_mount)
	await tick_request(func() -> void: _local.movement.set_target(HOME))
	await _wait(1.4)
	var walked_in := _local.sync_mount
	var why_walked := String(_judge.last_mount.get("why", ""))
	await tick_request(func() -> void: _local.movement.cancel_target())
	# Outside it, the horse comes.
	await _put(HOME + Vector3(0.0, 0.0, 6.0), 0.0)
	var outside := await _get_on()
	await _get_off()
	_judge.no_mount_zones.clear()
	await _put(HOME, 0.0)
	var cleared := await _get_on()
	await _get_off()
	note("with a zone around the mark: asked inside -> %s (%s); asked outside and walked in -> %s (%s); asked outside -> mounted %s; zone removed -> mounted %s" % [
		PlayerMount.Stage.keys()[inside], why, PlayerMount.Stage.keys()[walked_in], why_walked, outside, cleared])
	expect(inside == PlayerMount.Stage.NONE and why == "no_mount_zone" and _judge.mounts_granted - granted == 2,
		"a_body_inside_a_zone_in_the_slot_is_refused_the_horse")
	expect(walked_in == PlayerMount.Stage.NONE and why_walked == "no_mount_zone",
		"and_one_that_walks_in_during_the_summon_does_not_get_it")
	expect(outside and cleared, "outside_the_zone_and_with_the_slot_empty_again_the_horse_comes")
	await _wait(3.2)


# ------------------------------------------------- 13 (d): the rider as a target

# One blow at a body standing at STRIKE_AT: `by_host` says who swings. The
# attacker stands `gap` south of it and strikes north. Returns what the
# server ruled.
const STRIKE_AT := HOME + Vector3(3.0, 0.0, 1.0)

func _strike_at_rider(by_host: bool, skill: String, gap: float, mounted: bool) -> Dictionary:
	var mate := _mate()
	var target := mate if by_host else _local
	var target_spot := STRIKE_AT
	var attacker_spot := STRIKE_AT + Vector3(0.0, 0.0, gap)
	# Both on foot, parked, healed.
	if _local.sync_mount != PlayerMount.Stage.NONE:
		await _get_off()
	if mate.sync_mount != PlayerMount.Stage.NONE:
		client_press_mount.rpc_id(_client_peer())
		await _until(func() -> bool: return mate.sync_mount == PlayerMount.Stage.NONE, 2.0)
	await _until(func() -> bool: return _local.state == Player.State.IDLE and mate.state == Player.State.IDLE, 5.0)
	client_park.rpc_id(_client_peer(), target_spot if by_host else attacker_spot)
	await _put(attacker_spot if by_host else target_spot, 0.0)
	await _wait(0.6)
	await tick_request(func() -> void:
		_judge.server_set_hp(target, target.stats.max_hp))
	if mounted:
		if by_host:
			client_press_mount.rpc_id(_client_peer())
		else:
			Net.queue_physics(_local.movement.press_mount)
		await _until(func() -> bool: return target.sync_mount == PlayerMount.Stage.MOUNTED, 3.0)
		await _wait(0.4)
	var was_mounted := target.sync_mount == PlayerMount.Stage.MOUNTED
	var hp := target.hp
	var ruled := _judge.skills_ruled
	var feet := target.global_position.y - target.half_height()
	var flat_gap := Vector2(_local.global_position.x - mate.global_position.x, _local.global_position.z - mate.global_position.z).length()
	if by_host:
		Net.queue_physics(func() -> void:
			ServerAuthority.submit_intent(_local, ServerAuthority.Intent.SKILL, {"skill": skill, "direction": Vector3.FORWARD}))
	else:
		client_send_skill.rpc_id(_client_peer(), skill)
	var def := Skills.get_def(skill)
	await _wait(def.impact_time() + 0.9)
	var attacker := _local if by_host else mate
	var out := {"mounted": was_mounted, "lost": hp - target.hp, "ruled": _judge.skills_ruled - ruled,
		"gap": flat_gap, "strike_above_feet": attacker.global_position.y + def.strike_height * attacker.body_scale() - feet,
		"stage_after": target.sync_mount, "why": String(_judge.last_mount.get("why", "")),
		"radius": _judge.body_radius(target) if was_mounted and target.sync_mount == PlayerMount.Stage.MOUNTED else -1.0}
	await _until(func() -> bool: return target.state == Player.State.IDLE, 5.0)
	await _wait(1.0)
	return out


func _line(label: String, got: Dictionary) -> String:
	return "%s: gap %.2f m, strike %.2f m above the target's feet, %s -> ruled %d, HP -%.1f, stage after %s (%s)" % [
		label, float(got["gap"]), float(got["strike_above_feet"]), "mounted" if got["mounted"] else "on foot",
		int(got["ruled"]), float(got["lost"]), PlayerMount.Stage.keys()[int(got["stage_after"])], got["why"]]


func _target_checks() -> void:
	var mate := _mate()
	var punch := Skills.get_def("punch")
	var kick := Skills.get_def("kick")
	var punch_height := punch.strike_height
	var reach_kick := kick.value("reach")
	var reach_punch := punch.value("reach")
	await tick_request(func() -> void:
		placed()
		_local.global_position = STRIKE_AT + Vector3(0.0, 0.0, 3.0))
	client_park.rpc_id(_client_peer(), STRIKE_AT)
	await _wait(1.0)
	client_press_mount.rpc_id(_client_peer())
	await _until(func() -> bool: return mate.sync_mount == PlayerMount.Stage.MOUNTED, 3.0)
	var dims := mate.mount.capsule_dims()
	var lift := _judge.mounted_lift(mate)
	note("the rider as a target: capsule radius %.2f, height %.2f (walking body %.2f / %.2f), judged radius %.2f, lift %.2f; kick reach %.2f at %.2f m above the feet, punch reach %.2f at %.2f; band beyond the body %.2f" % [
		dims.x, dims.y, mate.radius(), mate.half_height() * 2.0, _judge.body_radius(mate), lift,
		reach_kick, mate.half_height() + kick.strike_height, reach_punch, mate.half_height() + punch.strike_height,
		ServerAuthority.STRIKE_REACH_BEYOND])
	expect(absf(_judge.body_radius(mate) - dims.x) < 0.001 and absf(lift + mate.half_height() * 2.0 - dims.y) < 0.001,
		"a_rider_is_judged_as_the_whole_mounted_capsule")
	client_press_mount.rpc_id(_client_peer())
	await _until(func() -> bool: return mate.sync_mount == PlayerMount.Stage.NONE, 2.0)
	await _wait(3.2)
	expect(_judge.body_radius(mate) == mate.radius() and _judge.mounted_lift(mate) == 0.0,
		"and_on_foot_as_the_walking_body_again")

	# Host swings at the client on its horse.
	var near := maxf(reach_kick - 0.2, 1.25)
	var low := await _strike_at_rider(true, "kick", near, true)
	note(_line("low blow (kick) at a client rider", low))
	expect(low["mounted"] and float(low["lost"]) > 0.0 and int(low["stage_after"]) == PlayerMount.Stage.NONE,
		"a_low_blow_hits_a_client_on_its_horse")
	# Head height: the punch raised for the test to the rider's head.
	var head_above_feet := dims.y - 0.25
	punch.strike_height = head_above_feet - _local.half_height()
	var head := await _strike_at_rider(true, "punch", maxf(reach_punch - 0.2, 1.25), true)
	note(_line("head-height blow (punch raised to %.2f) at a client rider" % head_above_feet, head))
	expect(head["mounted"] and float(head["lost"]) > 0.0 and int(head["stage_after"]) == PlayerMount.Stage.NONE,
		"a_blow_at_the_riders_head_hits_a_client_on_its_horse")
	# Past the walking body's band, still inside the rider's.
	var over := _local.half_height() * 2.0 + ServerAuthority.STRIKE_REACH_BEYOND + lift * 0.5
	punch.strike_height = over - _local.half_height()
	var high_foot := await _strike_at_rider(true, "punch", maxf(reach_punch - 0.2, 1.25), false)
	var high_ride := await _strike_at_rider(true, "punch", maxf(reach_punch - 0.2, 1.25), true)
	note(_line("blow at %.2f m, on foot" % over, high_foot))
	note(_line("blow at %.2f m, mounted" % over, high_ride))
	expect(float(high_foot["lost"]) == 0.0 and int(high_foot["ruled"]) == 1 and float(high_ride["lost"]) > 0.0,
		"a_blow_over_a_walkers_head_still_reaches_the_rider")
	punch.strike_height = punch_height
	# The horse's width: a kick that stops short of the walking body.
	var wide := reach_kick + (mate.radius() + dims.x) * 0.5
	var wide_foot := await _strike_at_rider(true, "kick", wide, false)
	var wide_ride := await _strike_at_rider(true, "kick", wide, true)
	note(_line("kick from %.2f m (reach %.2f), on foot" % [wide, reach_kick], wide_foot))
	note(_line("kick from %.2f m (reach %.2f), mounted" % [wide, reach_kick], wide_ride))
	expect(float(wide_foot["lost"]) == 0.0 and int(wide_foot["ruled"]) == 1 and float(wide_ride["lost"]) > 0.0,
		"a_blow_that_reaches_the_horse_but_not_a_walker_hits")

	# The client swings at the host on its horse.
	var c_low := await _strike_at_rider(false, "kick", near, true)
	note(_line("client's low blow (kick) at the host rider", c_low))
	expect(c_low["mounted"] and float(c_low["lost"]) > 0.0 and int(c_low["stage_after"]) == PlayerMount.Stage.NONE,
		"a_clients_low_blow_hits_the_host_on_its_horse")
	punch.strike_height = head_above_feet - mate.half_height()
	var c_head := await _strike_at_rider(false, "punch", maxf(reach_punch - 0.2, 1.25), true)
	note(_line("client's head-height blow at the host rider", c_head))
	expect(c_head["mounted"] and float(c_head["lost"]) > 0.0 and int(c_head["stage_after"]) == PlayerMount.Stage.NONE,
		"a_clients_blow_at_the_riders_head_hits_the_host_on_its_horse")
	punch.strike_height = punch_height
	await tick_request(func() -> void:
		_judge.server_set_hp(_local, _local.stats.max_hp)
		_judge.server_set_hp(mate, mate.stats.max_hp))
	await _reset_pair()
	await _wait(3.0)


# ------------------------------------------------------------------- RPCs

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
func client_press_mount() -> void:
	Net.queue_physics(_local.movement.press_mount)


# Server -> client: send a skill intent whatever this body is doing.
@rpc("authority", "call_remote", "reliable")
func client_send_skill(skill: String) -> void:
	Net.queue_physics(func() -> void:
		ServerAuthority.submit_intent(_local, ServerAuthority.Intent.SKILL, {"skill": skill, "direction": Vector3.FORWARD}))


# Server -> client: stand at `from`, get on, ride to `to`; with `bail`, get
# off the moment the horse is at its top speed.
@rpc("authority", "call_remote", "reliable")
func client_ride(from: Vector3, to: Vector3, bail: bool) -> void:
	if _local.sync_mount != PlayerMount.Stage.NONE:
		Net.queue_physics(_local.movement.press_mount)
		await _until(func() -> bool: return _local.mount.stage == PlayerMount.Stage.NONE, 2.0)
	placed()
	await Harness.forgive_lead(get_tree(), placed)
	var flat := to - from
	await tick_request(func() -> void:
		_local.global_position = from
		_local.velocity = Vector3.ZERO
		_local.rotation.y = atan2(-flat.x, -flat.z)
		_local.movement.cancel_target())
	await _wait(0.8)
	await _get_on()
	if not bail:
		var run := await _ride(to)
		run["at"] = _local.global_position
		report.rpc_id(1, "ride", run)
		return
	Net.queue_physics(func() -> void: _local.movement.set_target(to))
	var top := _local.get_mount_speed()
	await _until(func() -> bool: return Vector2(_local.velocity.x, _local.velocity.z).length() >= top * 0.995, 4.0)
	var speed := Vector2(_local.velocity.x, _local.velocity.z).length()
	Net.queue_physics(_local.movement.press_mount)
	await _until(func() -> bool: return _local.state == Player.State.IDLE and not _local.movement.has_target(), 8.0)
	report.rpc_id(1, "ride", {"bail_speed": speed, "at": _local.global_position})


# Server -> client: how this screen shows a body's horse.
@rpc("authority", "call_remote", "reliable")
func client_report_body(path: NodePath, key: String) -> void:
	var body := get_node_or_null(path) as Player
	var seen := describe(body) if body != null else {}
	seen["msec"] = Time.get_ticks_msec()
	report.rpc_id(1, key, seen)


# Server -> client: what this screen shows of a body's stage now, and how
# long until it shows the body off its horse.
@rpc("authority", "call_remote", "reliable")
func client_watch_stage(path: NodePath, key: String) -> void:
	var body := get_node_or_null(path) as Player
	if body == null:
		report.rpc_id(1, key, {})
		return
	var stage_at_rpc := body.mount.stage
	var sync_at_rpc := body.sync_mount
	var arrived := Time.get_ticks_msec()
	var last := arrived
	var worst_gap := 0
	var steps := 0
	while body.mount.stage != PlayerMount.Stage.NONE and steps < 120:
		await get_tree().physics_frame
		steps += 1
		var now := Time.get_ticks_msec()
		worst_gap = maxi(worst_gap, now - last)
		last = now
	report.rpc_id(1, key, {"stage_at_rpc": stage_at_rpc, "sync_at_rpc": sync_at_rpc, "followed": float(steps) * STEP,
		"real_ms": Time.get_ticks_msec() - arrived, "worst_gap_ms": worst_gap, "arrived_ms": arrived,
		"state": Player.State.keys()[body.state], "hp": body.hp})


# Server -> client: time this process's physics steps for `seconds`.
@rpc("authority", "call_remote", "reliable")
func client_gap_watch(key: String, seconds: float) -> void:
	_gap_begin()
	await get_tree().create_timer(seconds).timeout
	report.rpc_id(1, key, _gap_end())


# Server -> client: time the horse a body leaves behind, on this screen.
@rpc("authority", "call_remote", "reliable")
func client_watch_linger(path: NodePath, key: String) -> void:
	var body := get_node_or_null(path) as Player
	if body == null:
		report.rpc_id(1, key, {})
		return
	var appeared := await _until(func() -> bool: return body.mount.lingering_count() > 0, 8.0)
	var at := body.mount.lingering_position()
	var stood := await _until(func() -> bool: return body.mount.lingering_count() == 0, 8.0)
	report.rpc_id(1, key, {"seconds": stood if appeared >= 0.0 else -1.0, "at": at})


@rpc("authority", "call_remote", "reliable")
func finish(host_failures: int) -> void:
	print("MT_RESULT peer=%d checks=%d failures=%d host_failures=%d" % [
		_peer_id, _checks, _failures, host_failures])
	get_tree().quit(0 if _failures == 0 else 1)
