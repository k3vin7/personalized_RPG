extends Node

# T-1c: the boundary pieces and the seam between two terrain regions. The
# host measures; the client reports its own copies and walks the seam too.
# Measured: the pieces exist on both peers with the same layers and from the
# same bake path; the seam at x 192 is one continuous ground (collision rays
# and heights across it, a walk over the bump astride it without leaving the
# ground); the climbable half of the cliff is climbed to its top and the
# slippery half refuses; the cut rock's flat face is climbed; the water
# blocks a walk into it.

const HALF := Player.BODY_HALF_HEIGHT
const SEAM_WEST := Vector3(186.0, 0.0, 20.0)
const SEAM_EAST := Vector3(198.0, 0.0, 20.0)
const CLIFF_FOOT_CLIMB := Vector3(207.5, 0.0, 39.0)   # 1 m south of the climbable face
const CLIFF_FOOT_SLIP := Vector3(222.5, 0.0, 39.0)
const ROCK_FOOT := Vector3(193.0, 0.0, 50.0)          # east of the cut face at x 192
const WATER_APPROACH := Vector3(228.0, 0.0, 16.0)      # 4 m west of the pool
const WATER_INSIDE := Vector3(241.0, 0.0, 16.0)

var _world: Node3D
var _local: Player
var _judge: ServerAuthority
var _terrain: TestTerrain
var _pieces: BoundaryPieces
var _peer_id := 0
var _checks := 0
var _failures := 0
var _stage_done := ""
var _reports := {}


func expect(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("T1C_CHECK peer=%d %s %s" % [_peer_id, "PASS" if condition else "FAIL", label])


func note(line: String) -> void:
	print("T1C_NOTE peer=%d %s" % [_peer_id, line])


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


func _wait_report(key: String, seconds := 15.0) -> bool:
	var waited := 0.0
	while not _reports.has(key) and waited < seconds:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	expect(_reports.has(key), "the_client_reported_%s" % key)
	return _reports.has(key)


func _client_peer() -> int:
	var peers := multiplayer.get_peers()
	return peers[0] if peers.size() > 0 else 0


static func _stand(spot: Vector3) -> Vector3:
	return Vector3(spot.x, TestTerrain.height_at(spot.x, spot.z) + HALF, spot.z)


func _ground_gap(body: Node3D) -> float:
	return body.global_position.y - HALF - TestTerrain.height_at(body.global_position.x, body.global_position.z)


func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))


func _park(spot: Vector3, aim := Vector3.INF) -> void:
	await tick_request(func() -> void:
		placed()
		if _local.climb.is_climbing():
			_local.climb.detach(0.0)
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


# A walk by click from `from` to `to`: the states seen and the worst gap to
# the shape on the way, and whether it arrived.
func _walk(from: Vector3, to: Vector3, seconds: float) -> Dictionary:
	await _park(from)
	await tick_request(func() -> void: _local.movement.set_target(_stand(to)))
	var seen := {}
	var worst_gap := 0.0
	var waited := 0.0
	while waited < seconds and _flat(_local.global_position, to) > 1.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		seen[Player.State.keys()[_local.state]] = true
		worst_gap = maxf(worst_gap, absf(_ground_gap(_local)))
	await tick_request(func() -> void: _local.movement.cancel_target())
	return {"arrived": _flat(_local.global_position, to) <= 1.0, "seconds": waited, "states": seen.keys(),
		"worst_gap": worst_gap, "at": _local.global_position}


func run(world: Node3D) -> void:
	_world = world
	_peer_id = multiplayer.get_unique_id()
	_local = Net.spawn_root.get_node(str(_peer_id)) as Player
	_judge = world.get_node_or_null("ServerAuthority") as ServerAuthority
	_terrain = world.get_node_or_null("TestTerrain") as TestTerrain
	_pieces = world.find_child("BoundaryPieces", true, false) as BoundaryPieces
	if not multiplayer.is_server():
		stage_done.rpc_id(1, "client_ready")
		return
	expect(await _wait_stage("client_ready"), "both_peers_present")
	var warnings := _judge.move_warnings
	var corrections := _judge.move_corrections
	var smart: bool = Tuning.values.smart_key_enabled
	Tuning.values.smart_key_enabled = true
	await _piece_checks()
	await _seam_checks()
	await _cliff_checks()
	await _rock_checks()
	await _water_checks()
	Tuning.values.smart_key_enabled = smart
	note("move warnings %d -> %d, corrections %d -> %d" % [warnings, _judge.move_warnings, corrections, _judge.move_corrections])
	expect(_judge.move_warnings == warnings, "no_move_warnings_during_t1c")
	expect(_judge.move_corrections == corrections, "no_corrections_during_t1c")
	print("T1C_RESULT peer=%d checks=%d failures=%d" % [_peer_id, _checks, _failures])
	finish.rpc(_failures)
	await _wait(1.0)
	get_tree().quit(0 if _failures == 0 else 1)


# ------------------------------------------------- 1: the pieces, both peers

func _describe_pieces() -> Dictionary:
	var out := {}
	if _pieces == null:
		return out
	for kind in ["cliff_climb", "cliff_slip", "rock", "water"]:
		var body := _pieces.body_for(kind)
		if body == null:
			out[kind] = null
			continue
		var shapes := []
		for child in body.get_children():
			if child is CollisionShape3D and (child as CollisionShape3D).shape != null:
				shapes.append((child as CollisionShape3D).shape.get_class())
		out[kind] = {"layer": body.collision_layer, "bake": _pieces.bake_results.get(kind, "?"),
			"at": body.global_position, "shapes": shapes, "tag": body.get_meta("boundary", "")}
	return out


func _piece_checks() -> void:
	expect(_pieces != null, "the_boundary_pieces_are_in_the_world")
	if _pieces == null:
		return
	var own := _describe_pieces()
	note("host pieces: %s" % [own])
	var layers_ok := own["cliff_climb"] != null and own["cliff_slip"] != null and own["rock"] != null and own["water"] != null \
		and int(own["cliff_climb"]["layer"]) == Layers.CLIMBABLE and int(own["cliff_slip"]["layer"]) == Layers.WALL \
		and int(own["rock"]["layer"]) == Layers.CLIMBABLE and int(own["water"]["layer"]) == Layers.WALL
	expect(layers_ok, "the_four_bodies_carry_climbable_slippery_rock_and_water_layers_and_tags")
	var baked := String(own["cliff_climb"]["bake"]) == "trimesh" and String(own["cliff_slip"]["bake"]) == "trimesh" \
		and String(own["rock"]["bake"]) == "trimesh"
	note("csg bake path: cliff %s / %s, rock %s (water is a plain box by design)" % [
		own["cliff_climb"]["bake"], own["cliff_slip"]["bake"], own["rock"]["bake"]])
	expect(baked, "the_csg_pieces_baked_their_own_collision_no_box_stand_in")
	# The cut rock's flat face: a ray from the east meets the rock at the seam
	# with a normal pointing east.
	var from := Vector3(BoundaryPieces.ROCK_CUT_X + 2.0, 1.5, BoundaryPieces.ROCK_CENTRE.z)
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.LEFT * 4.0, Layers.CLIMBABLE)
	var hit := _local.get_world_3d().direct_space_state.intersect_ray(query)
	note("cut rock face from the east: hit %s at %s normal %s" % [
		hit.get("collider", null), hit.get("position", null), hit.get("normal", null)])
	expect(not hit.is_empty() and absf(float((hit["position"] as Vector3).x) - BoundaryPieces.ROCK_CUT_X) < 0.15
		and (hit["normal"] as Vector3).dot(Vector3.RIGHT) > 0.95,
		"the_rock_is_cut_flat_on_the_seam_plane_facing_east")
	_reports.erase("pieces")
	client_pieces.rpc_id(_client_peer())
	if await _wait_report("pieces"):
		var theirs: Dictionary = _reports["pieces"]
		note("client pieces: %s" % [theirs])
		var same := true
		for kind in ["cliff_climb", "cliff_slip", "rock", "water"]:
			var mine: Variant = own.get(kind)
			var other: Variant = theirs.get(kind)
			same = same and mine != null and other != null and int(mine["layer"]) == int(other["layer"]) \
				and String(mine["bake"]) == String(other["bake"]) \
				and (mine["at"] as Vector3).distance_to(other["at"] as Vector3) < 0.001
		expect(same, "the_client_built_the_same_four_pieces_same_layers_same_bake_same_places")


# ------------------------------------------------- 2: the seam between regions

func _seam_checks() -> void:
	var data: Object = _terrain.data()
	note("regions: %s" % [data.get("region_locations")])
	expect(data.get_region_count() == 2, "two_regions_stand_side_by_side")
	# Heights across the seam on the bump: served vs the shape, both sides.
	var worst := 0.0
	var rows := []
	for x in [189.0, 190.0, 191.0, 191.5, 192.0, 192.5, 193.0, 194.0, 195.0]:
		var at := Vector3(x, 0.0, 20.0)
		var served: float = data.get_height(at)
		var shape := TestTerrain.height_at(x, 20.0)
		worst = maxf(worst, absf(served - shape))
		rows.append("x%.1f %.3f/%.3f" % [x, served, shape])
	note("heights across the seam at z 20 (bump): %s | worst %.4f" % [", ".join(rows), worst])
	# get_height() clamps inside the cell next to a region edge (x 191.5 and
	# 192.5 read the vertex, not the slope): 0.037 m on this bump. The
	# collision below is what bodies stand on and it is exact.
	expect(worst < 0.05, "the_height_is_continuous_across_the_seam_within_terrain3ds_edge_cell_rounding")
	# Collision across the seam: a ray down every half metre finds ground at
	# the shape's height; no gap at x 191..193.
	var gap_rows := []
	var misses := 0
	var worst_ray := 0.0
	var x := 188.0
	while x <= 196.0:
		var at := Vector3(x, 20.0, 20.0)
		var query := PhysicsRayQueryParameters3D.create(at, at + Vector3.DOWN * 40.0, Layers.TERRAIN)
		var hit := _local.get_world_3d().direct_space_state.intersect_ray(query)
		if hit.is_empty():
			misses += 1
			gap_rows.append("x%.1f:-" % x)
		else:
			var err := absf(float((hit["position"] as Vector3).y) - TestTerrain.height_at(x, 20.0))
			worst_ray = maxf(worst_ray, err)
			gap_rows.append("x%.1f:%.2f" % [x, float((hit["position"] as Vector3).y)])
		x += 0.5
	note("collision across the seam at z 20: %s | misses %d, worst vs shape %.3f" % [" ".join(gap_rows), misses, worst_ray])
	expect(misses == 0 and worst_ray < 0.1, "the_collision_is_continuous_across_the_seam_no_gap_cell")
	# Walk over it, both ways, and the client once.
	var over := await _walk(SEAM_WEST, SEAM_EAST, 10.0)
	note("host walk west -> east over the seam bump: %s" % [over])
	expect(bool(over["arrived"]) and not (over["states"] as Array).has("AIRBORNE") and not (over["states"] as Array).has("SLIDING")
		and float(over["worst_gap"]) < 0.12, "the_body_walks_east_over_the_seam_on_the_ground")
	var back := await _walk(SEAM_EAST, SEAM_WEST, 10.0)
	note("host walk east -> west: %s" % [back])
	expect(bool(back["arrived"]) and not (back["states"] as Array).has("AIRBORNE") and float(back["worst_gap"]) < 0.12,
		"and_back_west")
	_reports.erase("seam")
	client_walk_seam.rpc_id(_client_peer(), _stand(SEAM_WEST), _stand(SEAM_EAST))
	if await _wait_report("seam", 20.0):
		var theirs: Dictionary = _reports["seam"]
		note("client walk over the seam: %s" % [theirs])
		expect(bool(theirs.get("arrived", false)) and not (theirs.get("states", []) as Array).has("AIRBORNE")
			and float(theirs.get("worst_gap", 9.0)) < 0.12, "the_client_walks_the_seam_on_its_own_collision_too")


# ------------------------------------------------- 3: the cliff, climbable and slippery

func _climb_face(kind: String, foot: Vector3, face_z: float, label: String) -> Dictionary:
	var body := _pieces.body_for(kind)
	await _park(foot, Vector3(foot.x, 1.0, face_z))
	var contact := Vector3(foot.x, 1.5, face_z)
	var normal := Vector3(0.0, 0.0, -1.0)
	var attached := {}
	await tick_request(func() -> void:
		attached["ok"] = _local.climb.attach(body, contact, normal)
		if bool(attached["ok"]):
			_local.climb.set_wall_target(contact + Vector3.UP * (BoundaryPieces.CLIFF_TOP_Y + 1.0)))
	var before := _local.global_position
	var waited := 0.0
	var seen := {}
	while waited < 8.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		seen[Player.State.keys()[_local.state]] = true
		if bool(attached.get("ok", false)) and waited > 1.0 and not _local.climb.is_climbing() and _local.is_on_floor():
			break
	var out := {"attached": attached.get("ok", false), "rose": _local.global_position.y - before.y,
		"states": seen.keys(), "at": _local.global_position, "seconds": waited,
		"on_top": _local.global_position.y > BoundaryPieces.CLIFF_TOP_Y + HALF - 0.3
			and _local.global_position.z > face_z and _local.is_on_floor()}
	note("%s: %s" % [label, out])
	if _local.climb.is_climbing():
		await tick_request(func() -> void: _local.climb.detach(0.0))
	return out


func _cliff_checks() -> void:
	var up := await _climb_face("cliff_climb", CLIFF_FOOT_CLIMB, BoundaryPieces.CLIFF_FACE_Z, "climbable half")
	expect(bool(up["attached"]) and bool(up["on_top"]) and (up["states"] as Array).has("CLIMB"),
		"the_climbable_cliff_is_climbed_to_the_top_and_stood_on")
	await _wait_idle()
	var slip := await _climb_face("cliff_slip", CLIFF_FOOT_SLIP, BoundaryPieces.CLIFF_FACE_Z, "slippery half")
	expect(not bool(slip["attached"]) and float(slip["rose"]) < 0.3 and not (slip["states"] as Array).has("CLIMB"),
		"the_slippery_cliff_refuses_the_climb")
	# Walking into the slippery half gets nowhere either.
	var into := await _walk(CLIFF_FOOT_SLIP, Vector3(CLIFF_FOOT_SLIP.x, 0.0, BoundaryPieces.CLIFF_FACE_Z + 5.0), 5.0)
	note("walk into the slippery face: %s" % [into])
	expect(not bool(into["arrived"]) and (into["at"] as Vector3).z < BoundaryPieces.CLIFF_FACE_Z,
		"and_a_walk_into_it_stops_at_the_face")
	await _wait_idle()


# ------------------------------------------------- 4: the cut rock

func _rock_checks() -> void:
	var body := _pieces.body_for("rock")
	await _park(ROCK_FOOT, Vector3(BoundaryPieces.ROCK_CUT_X, 1.0, ROCK_FOOT.z))
	var contact := Vector3(BoundaryPieces.ROCK_CUT_X, 1.5, ROCK_FOOT.z)
	var attached := {}
	await tick_request(func() -> void:
		attached["ok"] = _local.climb.attach(body, contact, Vector3.RIGHT)
		if bool(attached["ok"]):
			_local.climb.set_wall_target(contact + Vector3.UP * 2.0))
	var before := _local.global_position
	await _wait(2.0)
	var rose := _local.global_position.y - before.y
	note("cut rock: attached %s, rose %.2f m on its cut face, state %s" % [
		attached.get("ok", false), rose, Player.State.keys()[_local.state]])
	expect(bool(attached.get("ok", false)) and rose > 1.0, "the_cut_rocks_flat_face_is_climbed")
	await tick_request(func() -> void:
		if _local.climb.is_climbing():
			_local.climb.detach(0.0))
	await _wait(0.8)
	await _wait_idle()


# ------------------------------------------------- 5: the water blocks

func _water_checks() -> void:
	var into := await _walk(WATER_APPROACH, WATER_INSIDE, 6.0)
	var edge := BoundaryPieces.WATER_CENTRE.x - BoundaryPieces.WATER_SIZE.x * 0.5
	note("walk into the water (edge at x %.0f): %s" % [edge, into])
	expect(not bool(into["arrived"]) and (into["at"] as Vector3).x < edge + 0.6 and _local.state != Player.State.AIRBORNE,
		"the_water_blocks_the_body_stops_at_its_edge_no_swim_rule_yet")
	var inside := Vector3(BoundaryPieces.WATER_CENTRE.x, 5.0, BoundaryPieces.WATER_CENTRE.z)
	var query := PhysicsRayQueryParameters3D.create(inside, inside + Vector3.DOWN * 10.0, Layers.WALL)
	var hit := _local.get_world_3d().direct_space_state.intersect_ray(query)
	expect(not hit.is_empty() and (hit["collider"] as Node).is_in_group("water"), "the_block_in_the_water_is_tagged_water")
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
func client_pieces() -> void:
	report.rpc_id(1, "pieces", _describe_pieces())


@rpc("authority", "call_remote", "reliable")
func client_walk_seam(from: Vector3, to: Vector3) -> void:
	placed()
	await Harness.forgive_lead(get_tree(), placed)
	await tick_request(func() -> void:
		_local.global_position = from
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target()
		_local.movement.set_aim_override(Vector3.INF))
	await _wait(0.6)
	var start := _local.global_position
	await tick_request(func() -> void: _local.movement.set_target(to))
	var seen := {}
	var worst_gap := 0.0
	var waited := 0.0
	while waited < 10.0 and _flat(_local.global_position, to) > 1.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		seen[Player.State.keys()[_local.state]] = true
		worst_gap = maxf(worst_gap, absf(_ground_gap(_local)))
	await tick_request(func() -> void: _local.movement.cancel_target())
	var region := _world.get_node_or_null("NavigationRegion3D") as NavigationRegion3D
	report.rpc_id(1, "seam", {"arrived": _flat(_local.global_position, to) <= 1.0, "seconds": waited,
		"states": seen.keys(), "worst_gap": worst_gap, "from": start, "at": _local.global_position,
		"left": _flat(_local.global_position, to), "has_target": _local.movement.has_target(),
		"nav_polygons": region.navigation_mesh.get_polygon_count() if region != null and region.navigation_mesh != null else -1})


@rpc("authority", "call_remote", "reliable")
func finish(host_failures: int) -> void:
	print("T1C_RESULT peer=%d checks=%d failures=%d host_failures=%d" % [
		_peer_id, _checks, _failures, host_failures])
	get_tree().quit(0 if _failures == 0 else 1)
