extends Node

# RB (2026-11-23): standing on a monster's back, on both peers.
#
#   host:   --auto-host --auto-smoke --auto-only=RB --auto-port=P --auto-quit=120
#   client: --auto-join --auto-smoke --auto-only=RB --auto-port=P --auto-quit=120
#
# The playground puts one wolf (Wolf_0) on the arena for this run; it is kept
# standing (no aggro, no stroll). The client goes first, then the host. The
# one whose turn it is puts its own body on the wolf's back and:
#   1. this screen and the server's rider table both have it on the back;
#   2. the wolf's own bite, booked by the host while the body is up there,
#      passes it by (0 hits, no HP lost);
#   3. the thrust's slot casts the stab down, which the server rules, lands
#      on the wolf and is a crit (the crit roll is pinned off in a check run);
#   4. wolf_shake_after seconds after it got on, the wolf shakes and the body
#      is thrown off: it leaves the back and lands on the ground beside it,
#      with no correction from the server and no HP lost.
# Not here: being carried by a walking wolf (looked at in play).

const SEQUENCE_AT := 12.0
const STEP := 1.0 / 120.0

var _world: Node3D
var _local: Player
var _mate: Player
var _wolf: Wolf
var _peer_id := 0
var _checks := 0
var _failures := 0
var _lag := 0.0
var _started_msec := 0
var _judge: ServerAuthority


func expect(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("RB_CHECK peer=%d %s %s" % [_peer_id, "PASS" if condition else "FAIL", label])


func note(line: String) -> void:
	print("RB_NOTE peer=%d %s" % [_peer_id, line])


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _elapsed() -> float:
	return float(Time.get_ticks_msec() - _started_msec) / 1000.0


func _game_seconds() -> float:
	return float(Engine.get_physics_frames()) / float(Engine.physics_ticks_per_second)


func _until(seen: Callable, limit: float) -> bool:
	var waited := 0.0
	while waited < limit:
		if bool(seen.call()):
			return true
		await get_tree().physics_frame
		waited += STEP
	return bool(seen.call())


# The server is told this body is about to be placed (a check's teleport).
func _placed() -> void:
	if _judge == null:
		return
	if _judge.is_judge():
		_judge.forgive_move(multiplayer.get_unique_id(), "")
	else:
		_judge.harness_forgive_move.rpc_id(1)


func _park(spot: Vector3) -> void:
	_placed()
	await Harness.forgive_lead(get_tree(), _placed)
	Net.queue_physics(func() -> void:
		_local.global_position = spot
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target())
	for _frame in 3:
		await get_tree().physics_frame


func run(world: Node3D) -> void:
	_world = world
	_peer_id = multiplayer.get_unique_id()
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--be-latency="):
			_lag = argument.trim_prefix("--be-latency=").to_float() / 1000.0
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
	_wolf = world.get_node_or_null("Wolf_0") as Wolf
	expect(_local != null and _mate != null, "both_peers_present")
	expect(_wolf != null and _judge != null, "the_wolf_and_the_judge_are_in_the_world")
	if _local == null or _mate == null or _wolf == null or _judge == null:
		_finish()
		return
	_started_msec = Time.get_ticks_msec()
	var is_host := multiplayer.is_server()
	if is_host:
		# It stands where it is: nobody is noticed, no stroll.
		Tuning.server.wolf_aggro_range = 0.0
		Tuning.server.wolf_wander_radius = 0.0
	await _wait(1.0)
	_local.set_weapon(WeaponKinds.Kind.SWORD)
	await _wait(1.5 + _lag * 2.0)
	expect(_local.weapon == WeaponKinds.Kind.SWORD, "the_sword_is_in_hand")
	while _elapsed() < SEQUENCE_AT + _lag * 2.0:
		await _wait(0.05)
	note("wolf radius %.2f length %.2f hp %.0f; shake after %.2f windup %.2f power %.1f angle %.0f; stab windup %.2f damage x%.2f; lag %.0f ms" % [
		Wolf.radius(), Wolf.length(), _wolf.hp, Tuning.server.wolf_shake_after, Tuning.server.wolf_shake_windup,
		Tuning.server.wolf_shake_power, Tuning.server.wolf_shake_angle, Skills.get_def("back_stab").value("windup"),
		Skills.get_def("back_stab").value("damage"), _lag * 1000.0])
	if is_host:
		await _watch_the_client()
		await _wait(2.0 + _lag * 4.0)
		# The client's stab made it the wolf's target: forgotten, so the wolf
		# stands for the host's turn as it did for the client's.
		_wolf.harness_place(_wolf.global_position)
		await _wait(0.5)
		await _turn()
		await _wait(1.0 + _lag * 2.0)
		note("server: rides begun %d ended %d, back strikes %d, riders shaken %d, wolf shakes %d, move warnings %d" % [
			_judge.rides_begun, _judge.rides_ended, _judge.back_strikes_landed, _judge.riders_shaken,
			_wolf.shakes_started, _judge.move_warnings])
		expect(_judge.back_strikes_landed == 2, "the_server_landed_both_stabs_on_the_wolf")
		expect(_judge.riders_shaken == 2 and _wolf.shakes_started == 2, "the_wolf_shook_each_rider_off_once")
		expect(_judge.rides_begun == 2 and _judge.move_warnings == 0, "two_rides_and_no_move_warning")
	else:
		await _turn()
		# The host's own turn follows; this machine only has to stay.
		await _wait(14.0 + _lag * 8.0)
	_finish()


# Host only: the client's turn, by the server's own tables.
func _watch_the_client() -> void:
	var peer := _mate.get_multiplayer_authority()
	var on := await _until(func() -> bool: return _judge.rider_mount(peer) == _wolf, 60.0)
	var on_at := _game_seconds()
	expect(on, "the_server_has_the_client_on_the_wolfs_back")
	if not on:
		return
	await _bite_passes(_mate, "the_client")
	var strikes := _judge.back_strikes_landed
	var hp := _wolf.hp
	var stabbed := await _until(func() -> bool: return _judge.back_strikes_landed > strikes, 6.0)
	await _wait(0.1)
	var hit := _judge.last_hit
	note("server: client's stab landed %s; last hit %s; wolf hp %.1f -> %.1f" % [stabbed, hit, hp, _wolf.hp])
	expect(stabbed and String(hit.get("skill", "")) == "back_stab" and String(hit.get("target", "")) == str(_wolf.name),
		"the_clients_stab_lands_on_the_wolf_it_stands_on")
	expect(bool(hit.get("crit", false)), "the_clients_stab_is_a_crit")
	var shaken := _judge.riders_shaken
	var thrown := await _until(func() -> bool: return _judge.riders_shaken > shaken, 8.0)
	var after := _game_seconds() - on_at
	var want := float(Tuning.server.wolf_shake_after) + float(Tuning.server.wolf_shake_windup)
	note("server: client shaken off %s, %.2f s after it got on (want %.2f)" % [thrown, after, want])
	expect(thrown, "the_wolf_shakes_the_client_off")
	expect(absf(after - want) < 0.6 + _lag * 2.0, "the_shake_comes_wolf_shake_after_seconds_in")
	await _wait(1.5 + _lag * 2.0)
	expect(_judge.rider_mount(peer) == null, "the_server_has_the_client_off_the_back_again")


# Host only: the wolf's own bite, booked while `rider` is on its back.
func _bite_passes(rider: Player, who: String) -> void:
	var bite := Skills.get_def("wolf_bite")
	var hp := rider.hp
	var forward := -_wolf.global_transform.basis.z
	_judge.schedule_strike(_wolf, bite, forward)
	await _wait(bite.impact_time() + 0.25)
	var strike := _judge.last_strike
	note("server: the wolf's bite with %s on its back: %s; hp %.1f -> %.1f" % [who, strike, hp, rider.hp])
	# By the rider's own HP: the bite may reach the other body, on the ground
	# beside the wolf after its own turn.
	expect(String(strike.get("skill", "")) == "wolf_bite" and is_equal_approx(rider.hp, hp),
		"the_wolfs_own_bite_passes_%s_on_its_back" % who)


# This body's turn.
func _turn() -> void:
	var is_host := multiplayer.is_server()
	var slot := -1
	for index in PlayerSkills.SLOT_COUNT:
		var held := _local.skills.slot_def(index)
		if held != null and held.id == "thrust":
			slot = index
	expect(slot >= 0, "the_thrust_is_in_a_slot")
	if slot < 0:
		return
	var corrections := _local.corrections_received
	var hp := _local.hp
	var back := _wolf.global_position + Vector3.UP * (Wolf.radius() + _local.half_height() + 0.05)
	await _park(back)
	var on_at := _game_seconds()
	await _wait(0.6 + _lag * 2.0)
	var mount := _local.skills.mount_under()
	note("on the back: body y %.2f (wolf top %.2f), on floor %s, this screen's mount %s" % [
		_local.global_position.y - _local.half_height(), _wolf.global_position.y + Wolf.radius(), _local.is_on_floor(),
		mount.name if mount != null else "-"])
	expect(mount == _wolf, "this_screen_has_the_body_on_the_wolfs_back")
	if is_host:
		expect(_judge.rider_mount(_peer_id) == _wolf, "the_server_has_the_host_on_the_wolfs_back")
		await _bite_passes(_local, "the_host")
	else:
		# The host books the bite now; the stab waits for it.
		await _wait(1.0)
	_local.movement.set_aim_override(_local.global_position + Vector3(0.0, 0.0, -2.0))
	for _frame in 4:
		await get_tree().physics_frame
	var wolf_hp := _wolf.hp
	var cast_ok := _local.skills.cast_slot(slot)
	await get_tree().physics_frame
	var cast_def := _local.skills.current_def()
	var cast_id := cast_def.id if cast_def != null else ""
	var cast_at := _game_seconds()
	await _until(func() -> bool: return not _local.skills.is_busy(), 3.0)
	var busy_for := _game_seconds() - cast_at
	# The wolf's HP on this screen is the server's, a push later.
	await _until(func() -> bool: return _wolf.hp < wolf_hp - 0.5, 3.0 + _lag * 4.0)
	note("the thrust's slot on the back cast %s (%s), busy %.2f s; wolf hp %.1f -> %.1f on this screen %.2f s after the cast" % [
		cast_id, cast_ok, busy_for, wolf_hp, _wolf.hp, _game_seconds() - cast_at])
	expect(cast_ok and cast_id == "back_stab", "the_thrusts_slot_casts_the_stab_down_on_a_back")
	expect(_wolf.hp < wolf_hp - 0.5, "the_stab_takes_the_wolfs_hp_on_this_screen")
	if is_host:
		var hit := _judge.last_hit
		expect(String(hit.get("skill", "")) == "back_stab" and bool(hit.get("crit", false)), "the_hosts_stab_is_a_crit")
	# The shake-off: wolf_shake_after from getting on, then its windup.
	var highest := _local.global_position.y
	var left_back := false
	var waited := 0.0
	var limit := float(Tuning.server.wolf_shake_after) + float(Tuning.server.wolf_shake_windup) + 3.0 + _lag * 4.0
	while waited < limit:
		await get_tree().physics_frame
		waited += STEP
		highest = maxf(highest, _local.global_position.y)
		if _local.skills.mount_under() == null and _game_seconds() - on_at > 1.0:
			left_back = true
			break
	var off_after := _game_seconds() - on_at
	await _wait(1.5 + _lag * 2.0)
	var feet := _local.global_position.y - _local.half_height()
	var wolf_floor := _wolf.global_position.y - Wolf.radius()
	var aside := Vector2(_local.global_position.x - _wolf.global_position.x, _local.global_position.z - _wolf.global_position.z).length()
	note("thrown off %s after %.2f s on the back (went %.2f m up); now feet %.2f m over the wolf's floor, %.2f m from it; hp %.1f -> %.1f; corrections %d" % [
		left_back, off_after, highest - back.y, feet - wolf_floor, aside, hp, _local.hp, _local.corrections_received - corrections])
	expect(left_back, "the_wolf_shakes_this_body_off_its_back")
	expect(absf(feet - wolf_floor) < 0.3 and _local.skills.mount_under() == null, "the_body_lands_on_the_ground_beside_the_wolf")
	expect(is_equal_approx(_local.hp, hp), "no_hp_is_lost_on_the_back_or_by_the_shake")
	expect(_local.corrections_received == corrections, "the_server_did_not_put_the_body_back")
	_local.movement.set_aim_override(Vector3.INF)


func _finish() -> void:
	print("RB_RESULT peer=%d checks=%d failures=%d" % [_peer_id, _checks, _failures])
	await _wait(10.0 if multiplayer.is_server() else 0.5)
	get_tree().quit(0 if _failures == 0 else 1)
