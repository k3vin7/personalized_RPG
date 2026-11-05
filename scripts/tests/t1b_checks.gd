extends Node

# T-1b: the terrain test region. The host rules; the client reports. What is
# measured: the heights Terrain3D serves against the shape it was built from,
# on both peers (same data); the body walking, jumping, dashing on it; the
# walkable slope limit (stands at 30 deg, slides at 51; the slider moves it);
# the fall off the plateau costing HP; three scarecrows up, down and across
# the hill all reached by one side cut; a rock resting, grabbed and thrown on
# the terrain; and the client's body standing on the hill at the height the
# server computes.

const HALF := Player.BODY_HALF_HEIGHT
# Spots, by name. y is the body centre: the ground plus half the height.
const FLAT := Vector3(133.0, 0.0, 32.0)
const HILL_TOP := Vector3(150.0, 0.0, 40.0)
const HILL_SIDE := Vector3(150.0, 0.0, 48.0)        # 8 m south of the top: 30.5 deg
const BANK_MID := Vector3(138.0, 0.0, 16.0)         # on the 51 deg ramp, 2.5 m up
const PLATEAU_EDGE := Vector3(169.0, 0.0, 16.0)     # 7 m west of the plateau centre, on top
const RIM := Vector3(176.0, 0.0, 7.6)               # 8.4 m north of the centre: on the 83 deg rim, 4.8 m up
const CHUTE := Vector3(185.0, 0.0, 16.0)            # 9 m east of the centre: on the 55 deg chute, 6.6 m up
const ROCK_SPOT := Vector3(140.0, 0.0, 50.0)        # the forest floor
const SAMPLES := [
	Vector3(133.0, 0.0, 32.0), Vector3(150.0, 0.0, 40.0), Vector3(150.0, 0.0, 48.0), Vector3(138.0, 0.0, 16.0),
	Vector3(143.0, 0.0, 16.0), Vector3(176.0, 0.0, 16.0), Vector3(169.0, 0.0, 16.0), Vector3(136.0, 0.0, 50.0),
	Vector3(160.0, 0.0, 60.0),
]
const DUMMIES := ["Dummy_0", "Dummy_1", "Dummy_human"]

var _world: Node3D
var _local: Player
var _judge: ServerAuthority
var _terrain: TestTerrain
var _peer_id := 0
var _checks := 0
var _failures := 0
var _stage_done := ""
var _reports := {}
var _homes := {}


func expect(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("T1B_CHECK peer=%d %s %s" % [_peer_id, "PASS" if condition else "FAIL", label])


func note(line: String) -> void:
	print("T1B_NOTE peer=%d %s" % [_peer_id, line])


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


# The body centre for a spot on the shape.
static func _stand(spot: Vector3) -> Vector3:
	return Vector3(spot.x, TestTerrain.height_at(spot.x, spot.z) + HALF, spot.z)


func _ground_gap(body: Node3D) -> float:
	return body.global_position.y - HALF - TestTerrain.height_at(body.global_position.x, body.global_position.z)


func _park(spot: Vector3, aim := Vector3.INF) -> void:
	await tick_request(func() -> void:
		placed()
		_local.global_position = _stand(spot)
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target()
		_local.movement.cancel_armed()
		_local.movement.set_aim_override(aim))
	await _wait(0.6)


func _wait_idle(seconds := 4.0) -> void:
	var waited := 0.0
	while _local.state != Player.State.IDLE and waited < seconds:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()


func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))


static func _around(centre: Vector3, heading: Vector3, bearing_deg: float, distance: float) -> Vector3:
	var at := centre + heading.rotated(Vector3.UP, deg_to_rad(bearing_deg)) * distance
	return Vector3(at.x, TestTerrain.height_at(at.x, at.z) + Dummy.HALF_HEIGHT + 0.1, at.z)


func run(world: Node3D) -> void:
	_world = world
	_peer_id = multiplayer.get_unique_id()
	_local = Net.spawn_root.get_node(str(_peer_id)) as Player
	_judge = world.get_node_or_null("ServerAuthority") as ServerAuthority
	_terrain = world.get_node_or_null("TestTerrain") as TestTerrain
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
	await _data_checks()
	await _move_checks()
	await _slope_checks()
	await _fall_checks()
	await _dummy_checks()
	await _rock_checks()
	await _client_checks()
	await _restore_homes()
	Tuning.values.smart_key_enabled = smart
	note("move warnings %d -> %d, corrections %d -> %d" % [warnings, _judge.move_warnings, corrections, _judge.move_corrections])
	expect(_judge.move_warnings == warnings, "no_move_warnings_during_t1b")
	expect(_judge.move_corrections == corrections, "no_corrections_during_t1b")
	print("T1B_RESULT peer=%d checks=%d failures=%d" % [_peer_id, _checks, _failures])
	finish.rpc(_failures)
	await _wait(1.0)
	get_tree().quit(0 if _failures == 0 else 1)


# ------------------------------------------------- 1: the data, both peers

func _data_checks() -> void:
	expect(_terrain != null and _terrain.built, "the_test_terrain_is_in_the_world")
	if _terrain == null or not _terrain.built:
		return
	var data: Object = _terrain.data()
	note("terrain: regions %d, collision %s (mode %d), walk slope %.0f deg, nav polygons %d" % [
		data.get_region_count(), _terrain.configured_as, _terrain.collision_mode(), Tuning.server.walk_slope_max_deg,
		(_world.get_node("NavigationRegion3D") as NavigationRegion3D).navigation_mesh.get_polygon_count()])
	expect(data.get_region_count() == 2, "two_64m_regions_are_loaded")
	expect(_terrain.collision_mode() == 3, "the_server_built_full_collision")
	var worst := 0.0
	var rows := []
	for sample: Vector3 in SAMPLES:
		var served: float = data.get_height(sample)
		var shape := TestTerrain.height_at(sample.x, sample.z)
		worst = maxf(worst, absf(served - shape))
		rows.append("(%.0f, %.0f) %.3f/%.3f" % [sample.x, sample.z, served, shape])
	note("host heights served/shape: %s | worst %.4f" % [", ".join(rows), worst])
	expect(worst < 0.01, "terrain3d_serves_the_heights_the_shape_was_built_from_on_the_host")
	# Outside the region: whatever get_height says, there is no ground to
	# stand on -- a ray down through the void west of the region hits nothing.
	# The collision footprint along x at z 40 (the region spans x 128..192)
	# and along z at x 160 (z 0..64): where a ray down finds terrain, and at
	# what height. This is the "no collision outside regions" rule, measured.
	var footprint := []
	var first_hit := INF
	var last_hit := -INF
	for x in [96.0, 110.0, 120.0, 126.0, 127.0, 128.0, 129.0, 160.0, 190.0, 191.0, 192.0, 193.0, 200.0, 224.0, 254.0, 255.0, 256.0, 262.0]:
		var at := Vector3(x, 20.0, 40.0)
		var query := PhysicsRayQueryParameters3D.create(at, at + Vector3.DOWN * 60.0, Layers.TERRAIN)
		var hit := _local.get_world_3d().direct_space_state.intersect_ray(query)
		var is_terrain := not hit.is_empty() and String((hit["collider"] as Node).name).begins_with("Terrain3D")
		footprint.append("x%.0f:%s" % [x, ("%.2f" % float((hit["position"] as Vector3).y)) if is_terrain else ("other" if not hit.is_empty() else "-")])
		if is_terrain:
			first_hit = minf(first_hit, x)
			last_hit = maxf(last_hit, x)
	var footprint_z := []
	for z in [-40.0, -10.0, -1.0, 0.0, 1.0, 32.0, 63.0, 64.0, 65.0, 90.0]:
		var at := Vector3(160.0, 20.0, z)
		var query := PhysicsRayQueryParameters3D.create(at, at + Vector3.DOWN * 60.0, Layers.TERRAIN)
		var hit := _local.get_world_3d().direct_space_state.intersect_ray(query)
		var is_terrain := not hit.is_empty() and String((hit["collider"] as Node).name).begins_with("Terrain3D")
		footprint_z.append("z%.0f:%s" % [z, ("%.2f" % float((hit["position"] as Vector3).y)) if is_terrain else ("other" if not hit.is_empty() else "-")])
	note("collision footprint at z 40 along x: %s" % " ".join(footprint))
	note("collision footprint at x 160 along z: %s" % " ".join(footprint_z))
	note("get_height outside the region: (120, 40) %s, (96, 40) %s, (160, 90) %s; region_locations %s" % [
		data.get_height(Vector3(120.0, 0.0, 40.0)), data.get_height(Vector3(96.0, 0.0, 40.0)),
		data.get_height(Vector3(160.0, 0.0, 90.0)), data.get("region_locations")])
	# 64 vertices span 63 cells, and the shape stops a cell short of the
	# region's last row: solid from about x 129 to x 190 (z 1 to 62). T-1d's
	# edge rule has to keep the raised rim inside that.
	expect(first_hit <= 129.0 and last_hit >= 254.0, "the_regions_are_solid_from_x129_to_x254_one_cell_in_from_each_outer_edge")
	expect(first_hit >= 127.0 and last_hit <= 256.0 and is_nan(data.get_height(Vector3(120.0, 0.0, 40.0)))
		and is_nan(data.get_height(Vector3(262.0, 0.0, 40.0))),
		"outside_the_regions_there_is_no_ground_and_no_collision")
	_reports.erase("heights")
	client_heights.rpc_id(_client_peer())
	if await _wait_report("heights"):
		var theirs: Dictionary = _reports["heights"]
		var diff := 0.0
		var served: Array = theirs.get("served", [])
		for index in mini(served.size(), SAMPLES.size()):
			diff = maxf(diff, absf(float(served[index]) - float(data.get_height(SAMPLES[index]))))
		note("client: regions %s collision %s, heights %s | worst host-client diff %.5f" % [
			theirs.get("regions"), theirs.get("collision"), served, diff])
		expect(int(theirs.get("regions", 0)) == 2 and diff < 0.0001, "the_client_holds_the_same_heights_as_the_server")
		expect(String(theirs.get("collision", "")) == "DYNAMIC_GAME" and int(theirs.get("mode", -1)) == 1,
			"and_builds_dynamic_collision_around_its_own_body")


# ------------------------------------------------- 2: walk, jump, dash on it

func _move_checks() -> void:
	await _park(FLAT)
	note("standing on the flat: on_floor=%s, gap to the ground %.3f m" % [_local.is_on_floor(), _ground_gap(_local)])
	expect(_local.is_on_floor() and absf(_ground_gap(_local)) < 0.1, "the_body_stands_on_the_terrain")
	# Walk up the hill by a click: the navigation mesh has the terrain in it.
	var from := _local.global_position
	await tick_request(func() -> void: _local.movement.set_target(_stand(HILL_TOP)))
	var waited := 0.0
	while waited < 14.0 and _flat(_local.global_position, HILL_TOP) > 1.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	note("walked from %s toward the hill top: after %.1f s at %s (%.2f m short), climbed %.2f m, gap %.3f" % [
		from, waited, _local.global_position, _flat(_local.global_position, HILL_TOP),
		_local.global_position.y - from.y, _ground_gap(_local)])
	expect(_flat(_local.global_position, HILL_TOP) <= 1.0 and _local.global_position.y - from.y > 5.0
		and absf(_ground_gap(_local)) < 0.15, "a_click_walks_the_body_up_the_hill_along_the_ground")
	await tick_request(func() -> void: _local.movement.cancel_target())
	# A jump on the slope lands on the slope.
	await _park(HILL_SIDE)
	var jump_aim := _stand(HILL_SIDE) + Vector3(3.0, 0.0, 0.0)
	await tick_request(func() -> void:
		_local.movement.set_aim_override(jump_aim)
		_local.movement.press_jump())
	waited = 0.0
	var left_ground := false
	while waited < 3.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		if _local.state == Player.State.AIRBORNE:
			left_ground = true
		elif left_ground and _local.is_on_floor():
			break
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	note("jump on the 30 deg side: left ground %s, landed at %s after %.2f s, gap %.3f, state %s" % [
		left_ground, _local.global_position, waited, _ground_gap(_local), Player.State.keys()[_local.state]])
	expect(left_ground and _local.is_on_floor() and absf(_ground_gap(_local)) < 0.15, "a_jump_on_the_slope_lands_back_on_the_slope")
	await _wait_idle()
	# A dash along the flat.
	await _park(FLAT, _stand(FLAT) + Vector3(0.0, 0.0, -6.0))
	from = _local.global_position
	await tick_request(func() -> void: _local.movement.press_dash())
	waited = 0.0
	var dashed := false
	while waited < 2.5:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		if _local.state == Player.State.DASH:
			dashed = true
		elif dashed and _local.state == Player.State.IDLE:
			break
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	note("dash on the flat: dashed %s, %.2f m in %.2f s, gap %.3f, state %s" % [
		dashed, _flat(_local.global_position, from), waited, _ground_gap(_local), Player.State.keys()[_local.state]])
	expect(dashed and _flat(_local.global_position, from) > 2.0 and absf(_ground_gap(_local)) < 0.15,
		"a_dash_runs_along_the_terrain")
	await _wait_idle()


# ------------------------------------------------- 3: the slope limit

func _slide_from(spot: Vector3, label: String) -> Dictionary:
	# Measured from the spot the body was placed on. The states the body
	# passes through are collected (SLIDING vs AIRBORNE is the point), and
	# the fall record and HP before and after say whether a fall was charged.
	var fall_before := _local.last_fall_height
	var hp_before := _local.hp
	var seen := {}
	await tick_request(func() -> void:
		placed()
		_local.global_position = _stand(spot)
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target()
		_local.movement.cancel_armed()
		_local.movement.set_aim_override(Vector3.INF))
	var start := _stand(spot)
	var waited := 0.0
	while waited < 2.2:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		seen[Player.State.keys()[_local.state]] = true
	var moved := _flat(_local.global_position, start)
	var dropped := start.y - _local.global_position.y
	note("%s: states %s, fall record %.2f -> %.2f, hp %.0f -> %.0f" % [
		label, seen.keys(), fall_before, _local.last_fall_height, hp_before, _local.hp])
	var normal := _local.get_floor_normal() if _local.is_on_floor() else _local.get_wall_normal() if _local.is_on_wall() else Vector3.ZERO
	note("%s: after 2 s moved %.2f m, dropped %.2f m, on_floor=%s on_wall=%s floor_angle %.1f contact normal %s floor_max %.1f, at %s gap %.3f, state %s (limit %.0f deg)" % [
		label, moved, dropped, _local.is_on_floor(), _local.is_on_wall(),
		rad_to_deg(_local.get_floor_angle()) if _local.is_on_floor() else -1.0, normal, rad_to_deg(_local.floor_max_angle),
		_local.global_position, _ground_gap(_local), Player.State.keys()[_local.state], Tuning.server.walk_slope_max_deg])
	return {"moved": moved, "dropped": dropped, "states": seen,
		"fell": absf(_local.last_fall_height - fall_before) > 0.001, "hp_lost": hp_before - _local.hp}


func _slope_checks() -> void:
	var slope_deg := rad_to_deg(atan(PI * TestTerrain.HILL_HEIGHT / (2.0 * TestTerrain.HILL_RADIUS)))
	var bank_deg := rad_to_deg(atan(TestTerrain.BANK_HEIGHT / (TestTerrain.BANK_X1 - TestTerrain.BANK_X0)))
	note("slopes: hill side %.1f deg, bank %.1f deg; limit %.0f deg" % [slope_deg, bank_deg, Tuning.server.walk_slope_max_deg])
	var stood := await _slide_from(HILL_SIDE, "on the %.0f deg hill side" % slope_deg)
	expect(float(stood["moved"]) < 0.3, "the_body_stands_on_the_30_deg_slope_under_the_40_deg_limit")
	var slid := await _slide_from(BANK_MID, "on the %.0f deg bank" % bank_deg)
	expect(float(slid["moved"]) > 1.0 and float(slid["dropped"]) > 0.8, "and_slides_down_the_51_deg_bank")
	expect((slid["states"] as Dictionary).has("SLIDING") and not (slid["states"] as Dictionary).has("AIRBORNE")
		and not bool(slid["fell"]) and _local.state == Player.State.IDLE,
		"the_slide_is_sliding_not_airborne_grounded_and_no_fall_is_recorded")
	await _wait_idle()
	# The 83 deg rim is past slide_max_deg: a face, so a fall from the start.
	var rim := await _slide_from(RIM, "on the 83 deg rim 4.8 m up (slide_max %.0f)" % Tuning.server.slide_max_deg)
	expect(not (rim["states"] as Dictionary).has("SLIDING") and (rim["states"] as Dictionary).has("AIRBORNE")
		and bool(rim["fell"]) and absf(_local.last_fall_height - 4.8) < 0.6,
		"the_83_deg_rim_is_a_fall_from_where_the_body_was_put")
	await _wait_idle()
	# The chute: 55 deg slide from 6.6 m down to the 5 m break, then a 79 deg
	# face (5 m over one cell) that is past slide_max_deg.
	# face. The fall counts from the break, not from the top. The fall floor
	# is lowered to 1 m for this so the damage shows the height.
	var min_was: float = Tuning.server.fall_damage_min_height
	Tuning.server.fall_damage_min_height = 1.0
	await _wait(0.2)
	var chute := await _slide_from(CHUTE, "on the 55 deg chute 6.6 m up, break at %.0f m" % TestTerrain.CHUTE_BREAK_HEIGHT)
	var from_break := maxf(0.0, (_local.last_fall_height - 1.0) * Tuning.server.fall_damage_per_meter)
	var from_top := (6.6 - 1.0) * Tuning.server.fall_damage_per_meter
	note("chute: fall height %.2f (break at %.1f, top at 6.6), hp lost %.1f (from the break %.1f, from the top would be %.1f)" % [
		_local.last_fall_height, TestTerrain.CHUTE_BREAK_HEIGHT, float(chute["hp_lost"]), from_break, from_top])
	Tuning.server.fall_damage_min_height = min_was
	await _wait(0.2)
	expect((chute["states"] as Dictionary).has("SLIDING") and (chute["states"] as Dictionary).has("AIRBORNE")
		and bool(chute["fell"]) and _local.last_fall_height < 5.8 and _local.last_fall_height > 3.0
		and absf(float(chute["hp_lost"]) - from_break) < 0.6,
		"a_slide_that_ends_in_a_drop_counts_the_fall_from_the_break_not_the_top")
	await _wait_idle()
	# The slider: at 25 the hill side is too steep.
	var was: float = Tuning.server.walk_slope_max_deg
	Tuning.server.walk_slope_max_deg = 25.0
	await _wait(0.2)
	var slid_hill := await _slide_from(HILL_SIDE, "on the hill side with the limit at 25")
	expect(float(slid_hill["moved"]) > 1.0, "at_a_25_deg_limit_the_30_deg_side_slides_the_slider_is_the_rule")
	Tuning.server.walk_slope_max_deg = was
	await _wait(0.2)
	await _wait_idle()
	var stood_again := await _slide_from(HILL_SIDE, "on the hill side with the limit back at %.0f" % was)
	expect(float(stood_again["moved"]) < 0.3, "and_back_at_40_it_stands_again")


# ------------------------------------------------- 4: the fall off the plateau

func _fall_checks() -> void:
	await _park(PLATEAU_EDGE)
	var hp_before := _local.hp
	var falls := _judge.last_hit.duplicate()
	var top := _local.global_position
	await tick_request(func() -> void:
		_local.movement.set_aim_override(_stand(PLATEAU_EDGE) + Vector3(-5.0, -8.0, 0.0))
		_local.movement.press_jump())
	var waited := 0.0
	var left := false
	while waited < 4.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		if _local.state == Player.State.AIRBORNE:
			left = true
		elif left and _local.is_on_floor():
			break
	await _wait(0.4)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	var height := _local.last_fall_height
	var expected_damage := maxf(0.0, (height - Tuning.server.fall_damage_min_height) * Tuning.server.fall_damage_per_meter)
	note("off the plateau: from %s to %s (%.2f m down), fall height %.2f, hp %.0f -> %.0f (expected damage %.1f at min %.0f x %.0f/m), gap %.3f" % [
		top, _local.global_position, top.y - _local.global_position.y, height, hp_before, _local.hp,
		expected_damage, Tuning.server.fall_damage_min_height, Tuning.server.fall_damage_per_meter, _ground_gap(_local)])
	expect(left and top.y - _local.global_position.y > 6.0 and absf(_ground_gap(_local)) < 0.2,
		"the_jump_off_the_plateau_lands_on_the_ground_below")
	expect(height > 6.0 and hp_before - _local.hp > 0.0 and absf((hp_before - _local.hp) - expected_damage) < 0.6,
		"and_the_fall_costs_hp_by_the_fall_formula")
	await _wait_idle()


# ------------------------------------------------- 5: scarecrows up, down and across the hill

func _dummy_checks() -> void:
	var side := Skills.get_def("side_cut")
	await tick_request(func() -> void: _local.set_weapon(WeaponKinds.Kind.SWORD))
	await _wait(0.4)
	# Standing on the hill side facing east (across the slope): bearing 0 is
	# level with the body, +110 is up the hill, -110 down it.
	var heading := Vector3(1.0, 0.0, 0.0)
	var caster := _stand(HILL_SIDE)
	var origin := caster + heading * side.step_distance * side.value("windup") / (side.value("windup") + side.swing_time())
	await _park(HILL_SIDE, caster + heading * 6.0)
	await tick_request(func() -> void:
		for index in 3:
			var dummy := _dummy(index)
			var mark := _around(origin, heading, [0.0, 110.0, -110.0][index], 1.5)
			dummy.home = mark
			dummy.release_to(mark))
	await _wait(1.0)
	var heights := []
	var ids := []
	for index in 3:
		heights.append("%.2f" % (_dummy(index).global_position.y - caster.y))
		ids.append(_dummy(index).last_hit_id())
	var ruled := _judge.skills_ruled
	var before := _judge.last_strike.duplicate()
	await tick_request(func() -> void: _local.skills.press_slot(1))
	var waited := 0.0
	while (_judge.skills_ruled == ruled or _judge.last_strike == before) and waited < 2.5:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	var strike := _judge.last_strike
	var each := true
	var new_ids := []
	for index in 3:
		new_ids.append(_dummy(index).last_hit_id())
		each = each and int(new_ids[index]) != int(ids[index])
	note("side cut on the hill side at scarecrows level / up / down (centre height vs caster %s m): %s | sweep %s" % [
		heights, strike, _judge.last_sweep])
	expect(String(strike.get("skill", "")) == "side_cut" and int(strike.get("hits", 0)) == 3 and each,
		"one_side_cut_reaches_the_scarecrows_level_up_and_down_the_slope")
	await _wait_idle()


# ------------------------------------------------- 6: a rock on the terrain

func _rock_checks() -> void:
	var rock := _world.get_node_or_null("Rock_0") as Rock
	if rock == null:
		expect(false, "rock_0_exists")
		return
	var rock_home := rock.global_position
	var radius := Rock.radius_for(rock.weight)
	var drop := Vector3(ROCK_SPOT.x, TestTerrain.height_at(ROCK_SPOT.x, ROCK_SPOT.z) + 3.0, ROCK_SPOT.z)
	await tick_request(func() -> void:
		rock.global_position = drop
		rock.linear_velocity = Vector3.ZERO
		rock.angular_velocity = Vector3.ZERO)
	await _wait(2.5)
	var rest := rock.global_position
	var rest_gap := rest.y - radius - TestTerrain.height_at(rest.x, rest.z)
	note("rock (%.0f kg, r %.2f) dropped from 3 m over the forest floor: rests at %s, %.3f m off the ground" % [rock.weight, radius, rest, rest_gap])
	# A sphere dropped on flat ground bounces and rolls a few metres before
	# it stops; what is measured is that it rests on the ground.
	expect(absf(rest_gap) < 0.15 and _flat(rest, drop) < 6.0, "a_rock_comes_to_rest_on_the_terrain")
	# Grab it and throw it east; it lands on the terrain again.
	await _park(Vector3(rest.x - 1.3, 0.0, rest.z), rest)
	await tick_request(func() -> void:
		_local.movement.set_aim_override(rock.global_position)
		_local.movement.interact())
	await _wait(0.8)
	var held := _judge.holder_of(rock) == 1
	note("grab on the terrain: holder %d" % _judge.holder_of(rock))
	expect(held, "the_rock_is_picked_up_on_the_terrain")
	if held:
		var target := _stand(Vector3(rest.x + 7.0, 0.0, rest.z))
		await tick_request(func() -> void:
			_local.movement.set_aim_override(target)
			_local.grab.throw())
		await _wait(3.0)
		await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
		var landed := rock.global_position
		var landed_gap := landed.y - radius - TestTerrain.height_at(landed.x, landed.z)
		note("thrown toward %s: rests at %s (%.2f m east), %.3f m off the ground" % [target, landed, landed.x - rest.x, landed_gap])
		expect(landed.x - rest.x > 2.0 and absf(landed_gap) < 0.2, "and_the_thrown_rock_lands_and_rests_on_the_terrain")
	await _wait_idle()
	await tick_request(func() -> void:
		rock.global_position = rock_home
		rock.linear_velocity = Vector3.ZERO
		rock.angular_velocity = Vector3.ZERO)
	await _wait(0.5)


# ------------------------------------------------- 7: the client on the hill

func _client_checks() -> void:
	var mate := _mate()
	if mate == null:
		expect(false, "the_client_has_a_body")
		return
	var top := _stand(HILL_TOP)
	client_park.rpc_id(_client_peer(), top)
	await _wait(2.0)
	_reports.erase("stand")
	client_stand_report.rpc_id(_client_peer())
	if not await _wait_report("stand"):
		return
	var theirs: Dictionary = _reports["stand"]
	var server_ground := _terrain.height_of(mate.global_position)
	var replica_gap := mate.global_position.y - HALF - server_ground
	var own_gap := float(theirs.get("gap", 99.0))
	note("client on the hill top: its own screen y %.3f (gap to its ground %.3f, on_floor %s) | replica here y %.3f, server ground %.3f, gap %.3f | screen-vs-server height diff %.3f" % [
		float(theirs.get("y", 0.0)), own_gap, theirs.get("on_floor"), mate.global_position.y, server_ground, replica_gap,
		absf(float(theirs.get("y", 0.0)) - mate.global_position.y)])
	expect(bool(theirs.get("on_floor", false)) and absf(own_gap) < 0.15, "the_client_stands_on_the_hill_on_its_own_dynamic_collision")
	expect(absf(replica_gap) < 0.2, "and_its_replica_on_the_server_stands_on_the_servers_full_collision_at_the_same_height")


func _restore_homes() -> void:
	await tick_request(func() -> void:
		for index in DUMMIES.size():
			var dummy := _dummy(index)
			var home: Vector3 = _homes[dummy.name]
			dummy.home = home
			dummy.release_to(home))
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
func client_heights() -> void:
	var out := {"regions": 0, "collision": "", "mode": -1, "served": []}
	if _terrain != null and _terrain.built:
		out["regions"] = _terrain.data().get_region_count()
		out["collision"] = _terrain.configured_as
		out["mode"] = _terrain.collision_mode()
		for sample: Vector3 in SAMPLES:
			(out["served"] as Array).append(_terrain.height_of(sample))
	report.rpc_id(1, "heights", out)


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
func client_stand_report() -> void:
	var ground := _terrain.height_of(_local.global_position) if _terrain != null else NAN
	report.rpc_id(1, "stand", {"y": _local.global_position.y, "gap": _local.global_position.y - HALF - ground,
		"on_floor": _local.is_on_floor(), "ground": ground})


@rpc("authority", "call_remote", "reliable")
func finish(host_failures: int) -> void:
	print("T1B_RESULT peer=%d checks=%d failures=%d host_failures=%d" % [
		_peer_id, _checks, _failures, host_failures])
	get_tree().quit(0 if _failures == 0 else 1)
