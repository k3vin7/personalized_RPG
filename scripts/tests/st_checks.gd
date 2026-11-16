extends Node

# Going over a lip (step_height): on foot (a), on the horse (b), in a dash
# and in a skill's own step, and with a rock in the hands.
#
#   host:   --auto-host --auto-smoke --auto-only=ST --auto-port=P --auto-quit=400
#   client: --auto-join --auto-smoke --auto-only=ST --auto-port=P --auto-quit=400
#
# Both peers put maps/zone_5.tscn far off the playground (each owner collides
# on its own machine) and two boxes on the hub's clear lane, 0.30 m and
# 0.35 m. Nothing here is in the navigation bake, so the walks are
# order_straight(): the same ground step, without a path query.
#
# What is measured, for the host's body and the client's: the plaza disc
# (0.1 m) and farm_2's edge and corner are crossed without a stop, a frame in
# the air, a stamina or HP change; 0.30 m is climbed and 0.35 m is a wall; a
# shove in front of the box moves the body as it does with step_height 0;
# both screens put the body in the same place; the server's move check is
# silent.

const STEP := 1.0 / 120.0
const HOME := Vector3(0.0, 0.9, 11.0)
const CLIENT_SPOT := HOME + Vector3(-6.0, 0.0, 0.0)
# Where the map piece is put: off every region of the playground and above
# the kill plane.
const ZONE_AT := Vector3(-1000.0, 100.0, -1000.0)
const ZONE_FLOOR := 0.5
# The hub's clear lane (MT's LANE_A..LANE_B), z 14.
const BOX_LOW := Vector3(-5.0, 0.0, 14.0)
const BOX_HIGH := Vector3(5.0, 0.0, 14.0)
const BOX_SIDE := 2.0

var _world: Node3D
var _local: Player
var _judge: ServerAuthority
var _peer_id := 0
var _checks := 0
var _failures := 0
var _stage_done := ""
var _reports := {}
var _ride_warnings := 0
const ROCK_BESIDE := Vector3(0.9, -0.3, 0.0)


func expect(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("ST_CHECK peer=%d %s %s" % [_peer_id, "PASS" if condition else "FAIL", label])


func note(line: String) -> void:
	print("ST_NOTE peer=%d %s" % [_peer_id, line])


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


func _take_report(key: String, seconds := 30.0) -> Dictionary:
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


func _until(test: Callable, limit: float) -> float:
	var waited := 0.0
	while waited < limit:
		if test.call():
			return waited
		await get_tree().physics_frame
		waited += STEP
	return -1.0


static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))


# A point of the map piece, standing height for this body.
func _zone(x: float, z: float) -> Vector3:
	return ZONE_AT + Vector3(x, ZONE_FLOOR + _local.half_height(), z)


func _lane(x: float) -> Vector3:
	return Vector3(x, _local.half_height(), BOX_LOW.z)


func _build() -> void:
	var zone := (load("res://maps/zone_5.tscn") as PackedScene).instantiate() as Node3D
	zone.name = "StZone"
	_world.add_child(zone)
	zone.global_position = ZONE_AT
	_box("StBoxLow", BOX_LOW, 0.30)
	_box("StBoxHigh", BOX_HIGH, 0.35)


func _box(node_name: String, at: Vector3, height: float) -> void:
	var body := StaticBody3D.new()
	body.name = node_name
	body.collision_layer = Layers.WORLD
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(BOX_SIDE, height, BOX_SIDE)
	shape.shape = box
	body.add_child(shape)
	_world.add_child(body)
	body.global_position = at + Vector3(0.0, height * 0.5, 0.0)


func run(world: Node3D) -> void:
	_world = world
	_peer_id = multiplayer.get_unique_id()
	# Through a delay the order to begin can be here before this machine's
	# own body is.
	var waited := 0.0
	while Net.spawn_root.get_node_or_null(str(_peer_id)) == null and waited < 15.0:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	_local = Net.spawn_root.get_node(str(_peer_id)) as Player
	_judge = world.get_node_or_null("ServerAuthority") as ServerAuthority
	_build()
	# The CSG pieces build their colliders after they enter the tree.
	await _wait(1.0)
	if not multiplayer.is_server():
		stage_done.rpc_id(1, "client_ready")
		return
	expect(await _wait_stage("client_ready"), "both_peers_present")
	var warnings := _judge.move_warnings
	var corrections := _judge.move_corrections
	_data_checks()
	await _before_checks()
	await _crossing_checks(false)
	await _box_checks(false)
	await _push_checks()
	await _own_feet_checks()
	await _carry_checks()
	var on_foot_warnings := _judge.move_warnings - warnings
	await _crossing_checks(true)
	await _box_checks(true)
	_ride_warnings = _judge.move_warnings - warnings - on_foot_warnings
	note("move warnings on foot %d, riding %d, corrections %d during ST" % [
		on_foot_warnings, _ride_warnings, _judge.move_corrections - corrections])
	# Riding: a warning is one 0.1 s sample of a remote body over the cap
	# (MT's rule); it is counted and reported, a correction is the failure.
	expect(on_foot_warnings == 0, "no_move_warnings_on_foot_during_st")
	expect(_judge.move_corrections == corrections, "no_corrections_during_st")
	print("ST_RESULT peer=%d checks=%d failures=%d" % [_peer_id, _checks, _failures])
	finish.rpc(_failures)
	await _wait(1.0)
	get_tree().quit(0 if _failures == 0 else 1)


# ------------------------------------------------------- the number is data

func _data_checks() -> void:
	var limits := Tuning.limits_for("step_height")
	var panel := _world.get_node_or_null("DebugPanel")
	var slider := panel.find_child("step_height", true, false) as HSlider if panel != null else null
	note("step_height %.2f m, a server field %s, slider %s (%.2f..%.2f); body radius %.2f, walk %.2f m/s, horse %.2f m/s" % [
		Tuning.server.step_height, Tuning.is_server_field("step_height"), slider != null, limits.x, limits.y,
		_local.radius(), _local.get_move_speed(), _local.get_mount_speed()])
	expect(absf(Tuning.server.step_height - 0.3) < 0.0001 and Tuning.is_server_field("step_height"),
		"step_height_is_server_data_at_0_30")
	expect(slider != null and slider.max_value >= 0.5 and slider.min_value == 0.0, "step_height_has_a_slider")


# ------------------------------------------------------------- one walk

# This machine's body from `from` straight to `to`, and what happened to it.
func _walk(from: Vector3, to: Vector3, limit: float, ride := false, carry := NodePath()) -> Dictionary:
	var m := _local.movement
	var rock := get_node_or_null(carry) as Rock if not carry.is_empty() else null
	var heading := to - from
	placed()
	await Harness.forgive_lead(get_tree(), placed)
	await tick_request(func() -> void:
		_local.global_position = from
		_local.velocity = Vector3.ZERO
		_local.rotation.y = atan2(-heading.x, -heading.z)
		m.cancel_target()
		m.set_aim_override(Vector3.INF))
	await _wait(0.7)
	if ride:
		Net.queue_physics(m.press_mount)
		await _until(func() -> bool: return _local.is_mounted(), 3.0)
		await _wait(0.3)
	var held_at_start := false
	if rock != null:
		# The host puts the rock beside the mark (its own before this, the
		# client's before the walk was asked for).
		if multiplayer.is_server():
			await tick_request(func() -> void: _place_rock(rock, from))
			await _wait(0.4)
		await tick_request(func() -> void:
			m.set_aim_override(rock.global_position)
			m.interact())
		await _wait(0.8)
		m.set_aim_override(Vector3.INF)
		held_at_start = _local.grab.is_holding()
	var hand_gap := 0.0
	var lip_speed := -1.0
	# When the body was first within half a metre of the order's end, apart
	# from when the order was given up (the horse can creep the last 0.3 m).
	var reached := -1.0
	var ups := m.steps_up
	var downs := m.steps_down
	var seen_ups := ups
	var stamina := _local.stamina
	var hp := _local.hp
	var start := _local.global_position
	var last := start
	var y_max := start.y
	var y_min := start.y
	var worst_dy := 0.0
	var top_speed := 0.0
	var off_ground := 0
	var states := {}
	var waited := 0.0
	var mounted_all := true
	Net.queue_physics(func() -> void: m.order_straight(to))
	while waited < limit:
		await get_tree().physics_frame
		waited += STEP
		var at := _local.global_position
		if _local.state != Player.State.IDLE and _local.state != Player.State.MOVE \
				and not (rock != null and _local.state == Player.State.GRABBING):
			off_ground += 1
		states[Player.State.keys()[_local.state]] = true
		if ride and not _local.is_mounted():
			mounted_all = false
		y_max = maxf(y_max, at.y)
		y_min = minf(y_min, at.y)
		worst_dy = maxf(worst_dy, absf(at.y - last.y))
		top_speed = maxf(top_speed, _flat(at, last) / STEP)
		if m.steps_up > seen_ups and lip_speed < 0.0:
			lip_speed = _flat(at, last) / STEP
		seen_ups = m.steps_up
		if reached < 0.0 and _flat(at, to) <= 0.5:
			reached = waited
		if rock != null:
			hand_gap = maxf(hand_gap, rock.global_position.distance_to(_local.hand_position()))
		last = at
		if waited > 0.3 and not m.has_target():
			break
	var end := _local.global_position
	var out := {
		"arrived": _flat(end, to) <= 0.5, "seconds": waited, "start": start, "end": end,
		"rise": y_max - start.y, "drop": start.y - y_min, "end_rise": end.y - start.y,
		"worst_dy": worst_dy, "top_speed": top_speed, "off_ground": off_ground, "states": states.keys(),
		"ups": m.steps_up - ups, "downs": m.steps_down - downs,
		"stamina": _local.stamina - stamina, "hp": _local.hp - hp, "mounted": mounted_all,
		"walk_speed": _local.get_mount_speed() if ride else _local.get_move_speed(),
		"length": _flat(start, to), "lip_speed": lip_speed, "reached": reached,
		"held_at_start": held_at_start, "held_at_end": _local.grab.is_holding(), "hand_gap": hand_gap,
	}
	await tick_request(func() -> void: m.cancel_target())
	if ride and _local.is_mounted():
		Net.queue_physics(m.press_mount)
		await _until(func() -> bool: return not _local.is_mounted(), 2.0)
	await _wait(0.5)
	out["rest"] = _local.global_position
	if ride:
		# The horse left standing is in the next run's way until it is gone.
		await _wait(float(Tuning.server.mount_linger_time) + 0.3)
	return out


# The same walk by whichever body is asked, plus where the other screen
# shows that body once it has stopped.
func _walk_by(host: bool, key: String, from: Vector3, to: Vector3, limit: float, ride := false, carry := NodePath()) -> Dictionary:
	var got: Dictionary
	if host:
		got = await _walk(from, to, limit, ride, carry)
		client_view.rpc_id(_client_peer(), _local.get_path(), "view_" + key)
		var seen := await _take_report("view_" + key)
		got["other_screen"] = seen.get("at", Vector3.INF)
	else:
		client_walk.rpc_id(_client_peer(), key, from, to, limit, ride, carry)
		got = await _take_report(key, limit + 20.0)
		got["other_screen"] = _mate().global_position
	return got


func _line(label: String, got: Dictionary) -> String:
	var rest: Vector3 = got.get("rest", Vector3.INF)
	var other: Vector3 = got.get("other_screen", Vector3.INF)
	return "%s: arrived %s, within 0.5 m of the end after %.2f s, order over after %.2f s (%.2f m at %.2f m/s is %.2f s), ground speed at the lip %.2f m/s, rose %.3f m, dropped %.3f m, ended %.3f m up, largest height change in one step %.3f m, top ground speed %.2f m/s, steps not IDLE/MOVE %d, states %s, lip steps up %d / down %d, stamina %+.2f, HP %+.2f; rests at (%.2f, %.2f, %.2f), other screen (%.2f, %.2f, %.2f), apart %.3f m" % [
		label, got.get("arrived"), float(got.get("reached", -1.0)), float(got.get("seconds", -1.0)), float(got.get("length", 0.0)),
		float(got.get("walk_speed", 0.0)), float(got.get("length", 0.0)) / maxf(float(got.get("walk_speed", 1.0)), 0.01),
		float(got.get("lip_speed", -1.0)), float(got.get("rise", -1.0)), float(got.get("drop", -1.0)), float(got.get("end_rise", -1.0)),
		float(got.get("worst_dy", -1.0)), float(got.get("top_speed", -1.0)), int(got.get("off_ground", -1)),
		got.get("states"), int(got.get("ups", -1)), int(got.get("downs", -1)),
		float(got.get("stamina", -1.0)), float(got.get("hp", -1.0)),
		rest.x, rest.y, rest.z, other.x, other.y, other.z, rest.distance_to(other)]


# A crossing that should go through: no stop, no air, nothing spent, and the
# two screens agree. `rise` is how high the lip is, `end_rise` where it ends.
func _judge_crossing(who: String, name_text: String, got: Dictionary, rise: float, end_rise: float, ride: bool) -> void:
	var tag := "%s_%s%s" % [who, "riding_" if ride else "", name_text]
	var length := float(got.get("length", 0.0))
	var speed := maxf(float(got.get("walk_speed", 1.0)), 0.01)
	# The horse takes its acceleration and braking time on top of the run.
	var allowed := length / speed * 1.15 + (2.5 if ride else 0.3)
	var reached := float(got.get("reached", -1.0))
	expect(bool(got.get("arrived", false)) and reached >= 0.0 and reached <= allowed, "%s_goes_through_without_a_stop" % tag)
	expect(int(got.get("off_ground", -1)) == 0, "%s_never_leaves_the_ground_state" % tag)
	expect(absf(float(got.get("rise", -1.0)) - rise) <= 0.04 and absf(float(got.get("end_rise", -9.0)) - end_rise) <= 0.04,
		"%s_rises_the_lip_and_no_more" % tag)
	expect(absf(float(got.get("stamina", -1.0))) < 0.001 and absf(float(got.get("hp", -1.0))) < 0.001,
		"%s_costs_no_stamina_and_no_hp" % tag)
	expect(float(got.get("top_speed", 99.0)) <= speed * 1.05 + 0.05, "%s_is_no_faster_along_the_ground" % tag)
	var rest: Vector3 = got.get("rest", Vector3.INF)
	var other: Vector3 = got.get("other_screen", Vector3.ZERO)
	expect(rest.distance_to(other) <= 0.1, "%s_is_in_the_same_place_on_both_screens" % tag)
	if ride:
		expect(bool(got.get("mounted", false)), "%s_stays_on_the_horse" % tag)


# --------------------------------------------- before: step_height 0 (as it was)

func _before_checks() -> void:
	Tuning.server.step_height = 0.0
	await _wait(1.2)
	var got := await _walk(_zone(-7.5, 0.0), _zone(-2.0, 0.0), 3.0)
	note(_line("before (step_height 0), host on foot onto the plaza disc", got))
	expect(not bool(got.get("arrived", true)) and float(got.get("rise", 1.0)) < 0.04, "with_step_height_0_the_disc_stops_the_walker_as_before")
	Tuning.server.step_height = 0.3
	await _wait(1.2)
	client_tuning.rpc_id(_client_peer(), "tuning")
	var seen := await _take_report("tuning")
	expect(absf(float(seen.get("step_height", -1.0)) - 0.3) < 0.0001, "the_client_holds_the_servers_step_height")


# ------------------------------------------------------ the map's own lips

func _crossing_checks(ride: bool) -> void:
	var limit := 8.0
	for host: bool in [true, false]:
		var who := "host" if host else "client"
		var mode := "riding" if ride else "on foot"
		if not host:
			# The host's own body out of the client's way: it stopped on the
			# client's last starting mark.
			await _park(HOME)
		if ride:
			await _ride_crossings(who)
			continue
		# The plaza disc, radius 5, 0.1 m: up one side and down the other.
		var got := await _walk_by(host, "disc", _zone(-8.0, 0.0), _zone(8.0, 0.0), limit, ride)
		note(_line("%s %s across the plaza disc (0.1 m up, 0.1 m down)" % [who, mode], got))
		_judge_crossing(who, "across_the_disc", got, 0.1, 0.0, ride)
		expect(int(got.get("ups", 0)) > 0, "%s_%sthe_disc_was_a_lip_step" % [who, "riding_" if ride else ""])
		# farm_2: x 6..16, z -29..-16, 0.1 m. Straight over its west edge.
		got = await _walk_by(host, "farm_edge", _zone(2.5, -22.0), _zone(10.0, -22.0), limit, ride)
		note(_line("%s %s onto farm_2 over its edge (0.1 m)" % [who, mode], got))
		_judge_crossing(who, "onto_farm_2_over_the_edge", got, 0.1, 0.1, ride)
		# Back off it.
		got = await _walk_by(host, "farm_off", _zone(10.0, -22.0), _zone(2.5, -22.0), limit, ride)
		note(_line("%s %s off farm_2 over its edge (0.1 m down)" % [who, mode], got))
		_judge_crossing(who, "off_farm_2_over_the_edge", got, 0.0, -0.1, ride)
		# Diagonally over its corner at (6, -29).
		got = await _walk_by(host, "farm_corner", _zone(3.5, -31.5), _zone(9.5, -25.5), limit, ride)
		note(_line("%s %s onto farm_2 over its corner (0.1 m)" % [who, mode], got))
		_judge_crossing(who, "onto_farm_2_over_the_corner", got, 0.1, 0.1, ride)
		got = await _walk_by(host, "farm_corner_off", _zone(9.5, -25.5), _zone(3.5, -31.5), limit, ride)
		note(_line("%s %s off farm_2 over its corner (0.1 m down)" % [who, mode], got))
		_judge_crossing(who, "off_farm_2_over_the_corner", got, 0.0, -0.1, ride)


# The same lips on the horse, with the run-up its top speed needs: the disc
# along the road (x 0), farm_2 from the road side.
func _ride_crossings(who: String) -> void:
	var host := who == "host"
	var got := await _walk_by(host, "ride_disc", _zone(0.0, 30.0), _zone(0.0, -30.0), 12.0, true)
	note(_line("%s riding across the plaza disc (0.1 m up, 0.1 m down)" % who, got))
	_judge_crossing(who, "across_the_disc", got, 0.1, 0.0, true)
	# Under the mounted capsule (radius 0.6) a 0.1 m lip is a 34 degree
	# contact, inside walk_slope_max_deg: the engine walks it and the lip
	# step is not asked. What is checked is that it was crossed at speed.
	expect(float(got.get("top_speed", 0.0)) >= float(got.get("walk_speed", 99.0)) * 0.95,
		"%s_riding_the_disc_was_crossed_at_the_horses_top_speed" % who)
	got = await _walk_by(host, "ride_farm", _zone(-5.0, -22.0), _zone(24.0, -22.0), 10.0, true)
	note(_line("%s riding onto farm_2 over its edge (0.1 m)" % who, got))
	_judge_crossing(who, "onto_farm_2_over_the_edge", got, 0.1, 0.1, true)
	got = await _walk_by(host, "ride_farm_off", _zone(24.0, -22.0), _zone(-5.0, -22.0), 10.0, true)
	note(_line("%s riding off farm_2 over its edge (0.1 m down)" % who, got))
	_judge_crossing(who, "off_farm_2_over_the_edge", got, 0.0, -0.1, true)
	got = await _walk_by(host, "ride_corner", _zone(-1.0, -36.0), _zone(14.0, -21.0), 10.0, true)
	note(_line("%s riding onto farm_2 over its corner (0.1 m)" % who, got))
	_judge_crossing(who, "onto_farm_2_over_the_corner", got, 0.1, 0.1, true)
	got = await _walk_by(host, "ride_corner_off", _zone(14.0, -21.0), _zone(-1.0, -36.0), 10.0, true)
	note(_line("%s riding off farm_2 over its corner (0.1 m down)" % who, got))
	_judge_crossing(who, "off_farm_2_over_the_corner", got, 0.0, -0.1, true)


# ------------------------------------------------- 0.30 m is a lip, 0.35 a wall

func _box_checks(ride: bool) -> void:
	for host: bool in [true, false]:
		var who := "host" if host else "client"
		var mode := "riding" if ride else "on foot"
		var pre := "riding_" if ride else ""
		# The other body out of the lane.
		if host:
			client_park.rpc_id(_client_peer(), CLIENT_SPOT)
		else:
			await _park(HOME)
		var back := 8.5 if ride else 4.0
		var got := await _walk_by(host, "box_up", _lane(BOX_LOW.x - back), _lane(BOX_LOW.x), 6.0, ride)
		note(_line("%s %s onto the 0.30 m box" % [who, mode], got))
		_judge_crossing(who, "onto_the_0_30_box", got, 0.3, 0.3, ride)
		expect(int(got.get("ups", 0)) > 0, "%s_%sthe_0_30_box_was_a_lip_step" % [who, pre])
		got = await _walk_by(host, "box_over", _lane(BOX_LOW.x - back), _lane(BOX_LOW.x + 4.0), 8.0, ride)
		note(_line("%s %s over the 0.30 m box and down the far side" % [who, mode], got))
		_judge_crossing(who, "over_the_0_30_box_and_down", got, 0.3, 0.0, ride)
		# On the horse from the far side, with a run-up.
		var side := 1.0 if ride else -1.0
		got = await _walk_by(host, "box_wall", _lane(BOX_HIGH.x + side * (8.5 if ride else 4.0)), _lane(BOX_HIGH.x), 3.0, ride)
		note(_line("%s %s at the 0.35 m box" % [who, mode], got))
		var rest: Vector3 = got.get("rest", Vector3.ZERO)
		expect(not bool(got.get("arrived", true)) and float(got.get("rise", 1.0)) < 0.04 and int(got.get("ups", 1)) == 0
			and absf(rest.x - BOX_HIGH.x) > BOX_SIDE * 0.5 and float(got.get("top_speed", 0.0)) > 3.0
			and (bool(got.get("mounted", false)) or not ride), "%s_%sthe_0_35_box_is_a_wall" % [who, pre])
		expect(int(got.get("off_ground", -1)) == 0, "%s_%sstays_on_the_ground_against_the_0_35_box" % [who, pre])
	await _park(HOME)
	client_park.rpc_id(_client_peer(), CLIENT_SPOT)
	await _wait(0.5)


func _park(spot: Vector3) -> void:
	placed()
	await Harness.forgive_lead(get_tree(), placed)
	await tick_request(func() -> void:
		_local.global_position = spot
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target()
		_local.movement.set_aim_override(Vector3.INF))


# ------------------------------------------------ shoved in front of the lip

# The client 0.6 m short of the 0.30 m box, shoved at it by the host.
func _push_once(label: String) -> Dictionary:
	var mate := _mate()
	var face := BOX_LOW.x - BOX_SIDE * 0.5
	var spot := _lane(face - mate.radius() - 0.6)
	client_park.rpc_id(_client_peer(), spot)
	await _park(spot + Vector3(-1.1, 0.0, 0.0))
	await _wait(1.2)
	client_watch.rpc_id(_client_peer(), "push_" + label, 2.5)
	await _wait(0.3)
	var hp := mate.hp
	await tick_request(func() -> void:
		_local.movement.set_aim_override(mate.global_position)
		_local.movement.shove())
	await _wait(0.1)
	_local.movement.set_aim_override(Vector3.INF)
	var got := await _take_report("push_" + label)
	got["hp"] = mate.hp - hp
	got["other_screen"] = mate.global_position
	var rest: Vector3 = got.get("rest", Vector3.INF)
	var from: Vector3 = got.get("start", Vector3.INF)
	note("shove %s: the client from x %.2f (box face at x %.2f) moved %.2f m along the lane, furthest x %.2f, rose %.3f m, steps not IDLE/MOVE %d, states %s, lip steps up %d / down %d, rests at (%.2f, %.2f, %.2f), host's screen apart %.3f m" % [
		label, from.x, face, rest.x - from.x, float(got.get("x_max", 0.0)), float(got.get("rise", -1.0)),
		int(got.get("off_ground", -1)), got.get("states"), int(got.get("ups", -1)), int(got.get("downs", -1)),
		rest.x, rest.y, rest.z, rest.distance_to(mate.global_position)])
	return got


func _push_checks() -> void:
	var with_step := await _push_once("with step_height 0.30")
	Tuning.server.step_height = 0.0
	await _wait(1.2)
	var without := await _push_once("with step_height 0 (as before)")
	Tuning.server.step_height = 0.3
	await _wait(1.2)
	var a: Vector3 = with_step.get("rest", Vector3.INF)
	var b: Vector3 = without.get("rest", Vector3.ZERO)
	var start: Vector3 = with_step.get("start", Vector3.ZERO)
	expect(a.x - start.x > 0.1, "the_shove_moved_the_client")
	expect(int(with_step.get("ups", -1)) == 0 and int(with_step.get("downs", -1)) == 0, "a_shoved_body_takes_no_lip_step")
	expect(a.distance_to(b) <= 0.15 and absf(float(with_step.get("rise", 0.0)) - float(without.get("rise", 1.0))) <= 0.03,
		"shoved_at_the_lip_it_ends_where_it_did_before")
	var other: Vector3 = with_step.get("other_screen", Vector3.ZERO)
	expect(a.distance_to(other) <= 0.1, "the_shoved_body_is_in_the_same_place_on_both_screens")
	await _park(HOME)
	client_park.rpc_id(_client_peer(), CLIENT_SPOT)
	await _wait(0.5)


# ------------------------------------- the body's own feet: a dash, a skill's step

# This machine's body at `from` facing +x, doing `kind` ("dash" or a skill id).
func _act(kind: String, from: Vector3, seconds: float) -> Dictionary:
	var m := _local.movement
	placed()
	await Harness.forgive_lead(get_tree(), placed)
	await tick_request(func() -> void:
		_local.global_position = from
		_local.velocity = Vector3.ZERO
		_local.rotation.y = atan2(-1.0, 0.0)
		m.cancel_target()
		m.set_aim_override(from + Vector3(30.0, 0.0, 0.0)))
	await _wait(0.9)
	var start := _local.global_position
	var ups := m.steps_up
	var downs := m.steps_down
	var plan := float(m.dash_plan().get("distance", 0.0)) if kind == "dash" else Skills.get_def(kind).step_distance
	var y_max := start.y
	var x_max := start.x
	var states := {}
	if kind == "dash":
		Net.queue_physics(func() -> void: m.request_dash())
	else:
		# Through the slot, as a key press does: the skill's own step begins
		# there, not in the intent.
		Net.queue_physics(func() -> void:
			for index in range(8):
				var def := _local.skills.slot_def(index)
				if def != null and def.id == kind:
					_local.skills.cast_slot(index)
					return)
	var waited := 0.0
	while waited < seconds:
		await get_tree().physics_frame
		waited += STEP
		var at := _local.global_position
		y_max = maxf(y_max, at.y)
		x_max = maxf(x_max, at.x)
		states[Player.State.keys()[_local.state]] = true
	m.set_aim_override(Vector3.INF)
	return {"start": start, "rest": _local.global_position, "x_max": x_max, "rise": y_max - start.y,
		"end_rise": _local.global_position.y - start.y, "states": states.keys(), "plan": plan,
		"ups": m.steps_up - ups, "downs": m.steps_down - downs}


func _act_by(host: bool, key: String, kind: String, from: Vector3, seconds: float) -> Dictionary:
	var got: Dictionary
	if host:
		got = await _act(kind, from, seconds)
		client_view.rpc_id(_client_peer(), _local.get_path(), "view_" + key)
		var seen := await _take_report("view_" + key)
		got["other_screen"] = seen.get("at", Vector3.INF)
	else:
		client_act.rpc_id(_client_peer(), key, kind, from, seconds)
		got = await _take_report(key, seconds + 20.0)
		got["other_screen"] = _mate().global_position
	return got


func _act_line(label: String, got: Dictionary) -> String:
	var start: Vector3 = got.get("start", Vector3.INF)
	var rest: Vector3 = got.get("rest", Vector3.INF)
	var other: Vector3 = got.get("other_screen", Vector3.INF)
	return "%s: from x %.2f, planned %.2f m, furthest x %.2f (%.2f m), rests at (%.2f, %.2f, %.2f), rose %.3f m, ended %.3f m up, states %s, lip steps up %d / down %d, other screen apart %.3f m" % [
		label, start.x, float(got.get("plan", 0.0)), float(got.get("x_max", 0.0)), float(got.get("x_max", 0.0)) - start.x,
		rest.x, rest.y, rest.z, float(got.get("rise", -1.0)), float(got.get("end_rise", -1.0)), got.get("states"),
		int(got.get("ups", -1)), int(got.get("downs", -1)), rest.distance_to(other)]


func _own_feet_checks() -> void:
	var low_face := BOX_LOW.x - BOX_SIDE * 0.5
	var high_face := BOX_HIGH.x - BOX_SIDE * 0.5
	for host: bool in [true, false]:
		var who := "host" if host else "client"
		if host:
			client_park.rpc_id(_client_peer(), CLIENT_SPOT)
		else:
			await _park(HOME)
		# A dash from 2 m short of the 0.30 m box: over it.
		var got := await _act_by(host, "dash_low", "dash", _lane(low_face - 2.0), 2.0)
		note(_act_line("%s dash at the 0.30 m box" % who, got))
		var states: Array = got.get("states", ["?"])
		var start: Vector3 = got.get("start", Vector3.ZERO)
		expect(int(got.get("ups", 0)) > 0 and absf(float(got.get("rise", 0.0)) - 0.3) <= 0.04, "%s_a_dash_goes_up_the_0_30_box" % who)
		expect(float(got.get("x_max", -99.0)) - start.x >= float(got.get("plan", 99.0)) * 0.95, "%s_the_dash_covers_its_whole_distance_over_the_box" % who)
		expect(not states.has("AIRBORNE") and not states.has("SLIDING") and not states.has("?"), "%s_the_dash_over_the_box_is_never_in_the_air" % who)
		var rest: Vector3 = got.get("rest", Vector3.INF)
		var other: Vector3 = got.get("other_screen", Vector3.ZERO)
		expect(rest.distance_to(other) <= 0.1, "%s_after_the_dash_both_screens_agree" % who)
		await _wait(float(Tuning.server.dash_cooldown) + 0.3)
		# The same dash at the 0.35 m box: a wall.
		got = await _act_by(host, "dash_high", "dash", _lane(high_face - 2.0), 2.0)
		note(_act_line("%s dash at the 0.35 m box" % who, got))
		expect(int(got.get("ups", 1)) == 0 and float(got.get("rise", 1.0)) < 0.04
			and float(got.get("x_max", 99.0)) < high_face, "%s_a_dash_stops_at_the_0_35_box" % who)
		# A punch's own step (0.3 m) from just short of where the foot meets
		# the 0.30 m box's edge.
		got = await _act_by(host, "punch_low", "punch", _lane(low_face - 0.45), 2.5)
		note(_act_line("%s punch step into the 0.30 m box" % who, got))
		start = got.get("start", Vector3.ZERO)
		states = got.get("states", ["?"])
		expect(int(got.get("ups", 0)) > 0 and float(got.get("rise", 0.0)) > 0.1 and float(got.get("x_max", -99.0)) - start.x > 0.2,
			"%s_a_skills_own_step_goes_up_the_lip" % who)
		expect(not states.has("AIRBORNE") and not states.has("?"), "%s_the_skills_step_on_the_lip_is_never_in_the_air" % who)
	await _park(HOME)
	client_park.rpc_id(_client_peer(), CLIENT_SPOT)
	await _wait(0.5)


# ----------------------------------------------- a rock in the hands over a lip

func _place_rock(rock: Rock, beside: Vector3) -> void:
	rock.freeze = false
	rock.global_position = beside + ROCK_BESIDE
	rock.linear_velocity = Vector3.ZERO
	rock.angular_velocity = Vector3.ZERO


func _carry_once(host: bool, label: String, from: Vector3, to: Vector3, rise: float) -> void:
	var who := "host" if host else "client"
	var rock := _world.get_node("Rock_0") as Rock
	var peer := 1 if host else _client_peer()
	var walker := _local if host else _mate()
	if not host:
		await tick_request(func() -> void: _place_rock(rock, from))
		await _wait(0.4)
	var got := await _walk_by(host, "carry", from, to, 8.0, false, rock.get_path())
	var held_by_server := _judge.held_by(peer) == rock
	var gap_on_host := rock.global_position.distance_to(walker.hand_position())
	note("%s carrying the 5 kg rock %s: held when it set off %s, held at the end %s (server's table %s), furthest the rock was from the hand on the walker's own screen %.3f m, on the host's screen at rest %.3f m, rock at (%.2f, %.2f, %.2f)" % [
		who, label, got.get("held_at_start"), got.get("held_at_end"), held_by_server,
		float(got.get("hand_gap", -1.0)), gap_on_host, rock.global_position.x, rock.global_position.y, rock.global_position.z])
	note(_line("%s carrying, %s" % [who, label], got))
	var tag := "%s_carrying_%s" % [who, label.replace(" ", "_").replace(".", "_")]
	expect(bool(got.get("held_at_start", false)), "%s_took_the_rock" % tag)
	expect(bool(got.get("arrived", false)) and absf(float(got.get("rise", -1.0)) - rise) <= 0.04 and int(got.get("off_ground", -1)) == 0,
		"%s_crosses_like_empty_hands" % tag)
	expect(bool(got.get("held_at_end", false)) and held_by_server and gap_on_host <= 0.1, "%s_still_has_the_rock_in_the_hand" % tag)
	if host:
		await tick_request(func() -> void: _local.grab.drop())
	else:
		client_drop.rpc_id(_client_peer())
	await _wait(0.8)


func _carry_checks() -> void:
	for host: bool in [true, false]:
		if host:
			client_park.rpc_id(_client_peer(), CLIENT_SPOT)
		else:
			await _park(HOME)
		await _carry_once(host, "across the 0.1 m disc", _zone(-8.0, 0.0), _zone(8.0, 0.0), 0.1)
		await _carry_once(host, "over the 0.30 m box", _lane(BOX_LOW.x - 4.0), _lane(BOX_LOW.x + 4.0), 0.3)
	await _park(HOME)
	client_park.rpc_id(_client_peer(), CLIENT_SPOT)
	await _wait(0.5)


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
	await _park(point)


@rpc("authority", "call_remote", "reliable")
func client_walk(key: String, from: Vector3, to: Vector3, limit: float, ride: bool, carry: NodePath) -> void:
	report.rpc_id(1, key, await _walk(from, to, limit, ride, carry))


@rpc("authority", "call_remote", "reliable")
func client_act(key: String, kind: String, from: Vector3, seconds: float) -> void:
	report.rpc_id(1, key, await _act(kind, from, seconds))


@rpc("authority", "call_remote", "reliable")
func client_drop() -> void:
	Net.queue_physics(func() -> void: _local.grab.drop())


# Server -> client: where this screen shows a body.
@rpc("authority", "call_remote", "reliable")
func client_view(path: NodePath, key: String) -> void:
	var body := get_node_or_null(path) as Node3D
	report.rpc_id(1, key, {"at": body.global_position if body != null else Vector3.INF})


@rpc("authority", "call_remote", "reliable")
func client_tuning(key: String) -> void:
	report.rpc_id(1, key, {"step_height": Tuning.server.step_height})


# Server -> client: this body watched for `seconds` while something is done
# to it.
@rpc("authority", "call_remote", "reliable")
func client_watch(key: String, seconds: float) -> void:
	var m := _local.movement
	var ups := m.steps_up
	var downs := m.steps_down
	var start := _local.global_position
	var x_max := start.x
	var y_max := start.y
	var off_ground := 0
	var states := {}
	var waited := 0.0
	while waited < seconds:
		await get_tree().physics_frame
		waited += STEP
		var at := _local.global_position
		x_max = maxf(x_max, at.x)
		y_max = maxf(y_max, at.y)
		if _local.state != Player.State.IDLE and _local.state != Player.State.MOVE:
			off_ground += 1
		states[Player.State.keys()[_local.state]] = true
	report.rpc_id(1, key, {"start": start, "rest": _local.global_position, "x_max": x_max, "rise": y_max - start.y,
		"off_ground": off_ground, "states": states.keys(), "ups": m.steps_up - ups, "downs": m.steps_down - downs})


@rpc("authority", "call_remote", "reliable")
func finish(host_failures: int) -> void:
	print("ST_RESULT peer=%d checks=%d failures=%d host_failures=%d" % [
		_peer_id, _checks, _failures, host_failures])
	get_tree().quit(0 if _failures == 0 else 1)
