extends Node

# V-1: the starting village, walked. Two peers; the host rules, the client
# reports. What is measured: Terrain3D's heights against the layout's shape
# on both peers; the body standing on the plaza; the village pace (2 m/s)
# with the walk clip at it; the two gates walked to the plaza, the stairs up
# to the houses and down from the training ground, the forest hill; on every
# walk the ground gap (through the ground / floating), time in the air,
# vertical kicks, stalls (stuck), and the camera against the terrain; the
# client walking a gate route on its own screen; the judge's move warnings.
#   host:   --auto-host --auto-smoke --auto-world=village --auto-only=V1 --auto-port=P --auto-quit=480
#   client: --auto-join --auto-smoke --auto-world=village --auto-only=V1 --auto-port=P --auto-quit=480
# With a window on the host, screenshots go to reports/V-1/.

const HALF := Player.BODY_HALF_HEIGHT
const SHOT_DIR := "res://reports/V-1/"
const ARRIVE := 1.5
# Spots (x, z); the ground is the layout's.
const PLAZA_IN := Vector2(0.0, -4.0)
const PLAZA_SE := Vector2(5.0, 5.0)
const PLAZA_W := Vector2(-6.0, 4.0)
const PLAZA_E := Vector2(6.0, 4.0)
const HOUSES := Vector2(-6.0, -48.0)
const TRAINING := Vector2(40.0, -30.0)
const SHOP := Vector2(5.0, -2.0)
const HILLTOP := Vector2(80.0, 0.0)
const HEIGHT_SAMPLES := {
	"plaza": Vector2(0.0, 0.0), "shop_terrace": Vector2(27.0, -3.0), "house_upper": Vector2(1.0, -40.0),
	"training": Vector2(39.0, -28.0), "hilltop": Vector2(80.0, 0.0), "gate_north": Vector2(24.0, -62.0),
	"gate_southeast": Vector2(45.0, 46.0), "beyond_cliff": Vector2(-70.0, 0.0), "tavern": Vector2(-27.0, -14.0),
}

var _world: Village
var _layout: VillageLayout
var _local: Player
var _judge: ServerAuthority
var _peer_id := 0
var _checks := 0
var _failures := 0
var _stage_done := ""
var _reports := {}
var _shots := false
var _camera_gap_min := INF


func expect(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("V1_CHECK peer=%d %s %s" % [_peer_id, "PASS" if condition else "FAIL", label])


func note(line: String) -> void:
	print("V1_NOTE peer=%d %s" % [_peer_id, line])


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


func _stand(spot: Vector2) -> Vector3:
	return Vector3(spot.x, _layout.height_at(spot.x, spot.y) + HALF + 0.05, spot.y)


# The body's bottom against the ground it actually collides with (a ray
# down onto the world layer); the layout's shape only if nothing is hit.
# Terrain3D's collision interpolates its 1 m vertices, the shape is
# continuous, and the two differ by up to ~15 cm at a ramp's foot.
func _ground_gap(body: Node3D) -> float:
	var at := body.global_position
	var space := body.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(at, at + Vector3.DOWN * 6.0, Layers.WORLD)
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return at.y - HALF - _layout.height_at(at.x, at.z)
	return at.y - HALF - (hit["position"] as Vector3).y


static func _flat(a: Vector3, b: Vector2) -> float:
	return Vector2(a.x, a.z).distance_to(b)


func _park(spot: Vector2) -> void:
	await tick_request(func() -> void:
		placed()
		_local.global_position = _stand(spot)
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target()
		_local.movement.cancel_armed()
		_local.movement.set_aim_override(Vector3.INF))
	await _wait(0.8)


func _shot(name_text: String) -> void:
	if not _shots:
		return
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	if image == null:
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	var path := SHOT_DIR + "%s.png" % name_text
	note("shot %s (%s)" % [path, "saved" if image.save_png(path) == OK else "error"])


# Walks the body to `target` and watches it: the ground gap, time in the
# air, vertical kicks, stalls, the camera over the terrain. Returns the
# numbers; nothing here is a verdict.
func _walk_to(target: Vector2, seconds: float) -> Dictionary:
	note("  path: %s" % _path_summary(_local.global_position, target))
	await tick_request(func() -> void: _local.movement.set_target(Vector3(target.x, _layout.height_at(target.x, target.y), target.y)))
	var waited := 0.0
	var snapped_stall := false
	var gap_min := INF
	var gap_max := -INF
	var air_now := 0.0
	var air_max := 0.0
	var vy_max := 0.0
	var stall_max := 0.0
	var stall_now := 0.0
	var best := _flat(_local.global_position, target)
	var started := _flat(_local.global_position, target)
	var arrived := false
	var killed := false
	var cam_gap := INF
	while waited < seconds:
		await get_tree().physics_frame
		var dt := get_physics_process_delta_time()
		waited += dt
		if _local.state == Player.State.DEAD:
			killed = true
			break
		var gap := _ground_gap(_local)
		gap_min = minf(gap_min, gap)
		gap_max = maxf(gap_max, gap)
		if _local.state == Player.State.AIRBORNE:
			air_now += dt
			air_max = maxf(air_max, air_now)
		else:
			air_now = 0.0
		vy_max = maxf(vy_max, absf(_local.velocity.y))
		var remaining := _flat(_local.global_position, target)
		if remaining < best - 0.3:
			best = remaining
			stall_now = 0.0
		else:
			stall_now += dt
			stall_max = maxf(stall_max, stall_now)
			if stall_now > 3.0 and not snapped_stall:
				snapped_stall = true
				note("  stalled: %s" % _stall_snapshot())
		if _local.camera != null:
			var cam := _local.camera.global_position
			cam_gap = minf(cam_gap, cam.y - _layout.height_at(cam.x, cam.z))
		if remaining < ARRIVE:
			arrived = true
			break
	_camera_gap_min = minf(_camera_gap_min, cam_gap)
	return {
		"arrived": arrived, "killed": killed, "seconds": snappedf(waited, 0.01), "from": snappedf(started, 0.1),
		"left": snappedf(_flat(_local.global_position, target), 0.1), "gap_min": snappedf(gap_min, 0.001),
		"gap_max": snappedf(gap_max, 0.001), "air_max": snappedf(air_max, 0.01), "vy_max": snappedf(vy_max, 0.01),
		"stall_max": snappedf(stall_max, 0.01), "cam_gap": snappedf(cam_gap, 0.01) if cam_gap != INF else "none",
		"state": Player.State.keys()[_local.state],
	}


# The navigation map's path between two spots: how many points, how long,
# and how far its end is from the target (a gap means the target is cut off).
func _path_summary(from: Vector3, target: Vector2) -> String:
	var map := _world.get_world_3d().navigation_map
	var to := Vector3(target.x, _layout.height_at(target.x, target.y), target.y)
	var path := NavigationServer3D.map_get_path(map, from, to, true)
	if path.is_empty():
		return "no path from %s to %s" % [from.snapped(Vector3.ONE * 0.1), to.snapped(Vector3.ONE * 0.1)]
	var length := 0.0
	for index in path.size() - 1:
		length += path[index].distance_to(path[index + 1])
	var tail := path[path.size() - 1]
	return "%d points, %.1f m, ends %.1f m from the target at %s" % [
		path.size(), length, _flat(tail, target), tail.snapped(Vector3.ONE * 0.1)]


# Where a stalled body is and what it is pushing against.
func _stall_snapshot() -> String:
	var at := _local.global_position
	var ground := _layout.height_at(at.x, at.z)
	var dx := _layout.height_at(at.x + 0.5, at.z) - _layout.height_at(at.x - 0.5, at.z)
	var dz := _layout.height_at(at.x, at.z + 0.5) - _layout.height_at(at.x, at.z - 0.5)
	var slope := rad_to_deg(atan(Vector2(dx, dz).length()))
	var movement := _local.movement
	var path: PackedVector3Array = movement._path
	var next := path[movement._path_index] if movement._path_index < path.size() else Vector3.INF
	var ahead := Vector3.INF
	if next != Vector3.INF:
		var step := next - at
		step.y = 0.0
		if step.length() > 0.01:
			var probe := at + step.normalized() * 0.6
			ahead = Vector3(probe.x, _layout.height_at(probe.x, probe.z), probe.z)
	return "at %s ground %.2f slope %.0f deg, floor=%s v=%s state %s, path %d/%d next %s (ground ahead %.2f, %.2f up)" % [
		at.snapped(Vector3.ONE * 0.01), ground, slope, _local.is_on_floor(), _local.velocity.snapped(Vector3.ONE * 0.01),
		Player.State.keys()[_local.state], movement._path_index, path.size(),
		next.snapped(Vector3.ONE * 0.1) if next != Vector3.INF else "none",
		ahead.y if ahead != Vector3.INF else NAN, (ahead.y - ground) if ahead != Vector3.INF else NAN]


# V1nav: every route's path and every stair's real slope, printed.
func _nav_report() -> void:
	var routes := [
		["north_gate_to_plaza", _layout.gate_north, PLAZA_IN], ["southeast_gate_to_plaza", _layout.gate_southeast, PLAZA_SE],
		["plaza_to_houses", Vector2(-4.0, -4.0), HOUSES], ["houses_to_training", HOUSES, TRAINING],
		["training_to_shop", TRAINING, SHOP], ["shop_to_hilltop", SHOP, HILLTOP], ["plaza_to_tavern", PLAZA_W, Vector2(-26.0, -8.0)],
	]
	for route in routes:
		note("nav %s: %s" % [route[0], _path_summary(_stand(route[1]), route[2])])
	for stair in _layout.stairs():
		var from: Vector3 = stair["from"]
		var to: Vector3 = stair["to"]
		var steps := int(ceil(from.distance_to(to) / 0.25))
		# The shape's own slope along the centre line (Terrain3DData.get_height
		# is the nearest vertex, not interpolated, so it cannot measure this;
		# the collision shape interpolates between the 1 m vertices).
		var steepest := 0.0
		var last := _layout.height_at(from.x, from.z)
		for index in range(1, steps + 1):
			var t := float(index) / float(steps)
			var p := from.lerp(to, t)
			var h := _layout.height_at(p.x, p.z)
			var run := from.distance_to(to) / float(steps)
			steepest = maxf(steepest, rad_to_deg(atan(absf(h - last) / run)))
			last = h
		note("stair %s %s -> %s: terrain rise %.2f (layout %.2f), steepest %.0f deg on the shape (walk limit %.0f)" % [
			stair["road"], Vector2(from.x, from.z), Vector2(to.x, to.z),
			_world.terrain.height_of(Vector3(to.x, 0.0, to.z)) - _world.terrain.height_of(Vector3(from.x, 0.0, from.z)),
			to.y - from.y, steepest, Tuning.server.walk_slope_max_deg])


func _judge_walk(label: String, stats: Dictionary, max_seconds: float) -> void:
	note("%s: %s" % [label, stats])
	expect(bool(stats["arrived"]) and not bool(stats["killed"]), "%s_arrives" % label)
	expect(float(stats["gap_min"]) > -0.15, "%s_never_sinks_into_the_ground" % label)
	expect(float(stats["gap_max"]) < 0.6, "%s_never_floats" % label)
	expect(float(stats["air_max"]) < 0.4, "%s_never_falls_long" % label)
	expect(float(stats["stall_max"]) < 2.5, "%s_never_gets_stuck" % label)
	expect(float(stats["seconds"]) < max_seconds, "%s_within_%.0f_s" % [label, max_seconds])


func _height_samples() -> Dictionary:
	var out := {}
	for key in HEIGHT_SAMPLES:
		var spot: Vector2 = HEIGHT_SAMPLES[key]
		out[key] = snappedf(_world.terrain.height_of(Vector3(spot.x, 0.0, spot.y)), 0.001)
	return out


func run(world: Node3D) -> void:
	_world = world as Village
	_layout = _world.layout
	_peer_id = multiplayer.get_unique_id()
	# The spawn replicates on its own channel: the body may land after the
	# host's begin_smoke. Wait for it rather than read a null.
	var waited := 0.0
	while (Net.spawn_root == null or not Net.spawn_root.has_node(str(_peer_id))) and waited < 15.0:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	_local = Net.spawn_root.get_node_or_null(str(_peer_id)) as Player
	_judge = world.get_node_or_null("ServerAuthority") as ServerAuthority
	_shots = DisplayServer.get_name() != "headless"
	if _local == null:
		print("V1_RESULT peer=%d checks=0 failures=1 no_body_after_%.1f_s" % [_peer_id, waited])
		get_tree().quit(1)
		return
	if Net.auto_only == "V1nav":
		# Host alone: the navigation paths and the ramps, no walking.
		await _wait(1.0)
		_nav_report()
		get_tree().quit(0)
		return
	if Net.auto_only == "V1walk":
		# Host alone: the uphill walks, with the stall snapshots.
		await _wait(1.0)
		await _park(Vector2(-4.0, -4.0))
		_judge_walk("plaza_to_houses_up_the_stairs", await _walk_to(HOUSES, 60.0), 60.0)
		_judge_walk("houses_to_training_ground", await _walk_to(TRAINING, 70.0), 70.0)
		await _park(SHOP)
		_judge_walk("shop_up_the_forest_hill", await _walk_to(HILLTOP, 80.0), 80.0)
		print("V1_RESULT peer=%d checks=%d failures=%d (walk diagnostic)" % [_peer_id, _checks, _failures])
		get_tree().quit(0)
		return
	if not multiplayer.is_server():
		stage_done.rpc_id(1, "client_ready")
		return
	expect(await _wait_stage("client_ready"), "both_peers_present")
	var warnings := _judge.move_warnings
	var corrections := _judge.move_corrections
	var smart: bool = Tuning.values.smart_key_enabled
	Tuning.values.smart_key_enabled = true
	await _model_checks()
	await _terrain_checks()
	await _pace_checks()
	await _route_checks()
	await _client_checks()
	Tuning.values.smart_key_enabled = smart
	note("camera over the terrain, lowest %.2f m across every walk" % _camera_gap_min)
	expect(_camera_gap_min > 1.0, "the_camera_never_enters_the_terrain")
	note("judge: move warnings %d -> %d, corrections %d -> %d" % [warnings, _judge.move_warnings, corrections, _judge.move_corrections])
	expect(_judge.move_warnings == warnings, "no_move_warnings_during_v1")
	expect(_judge.move_corrections == corrections, "no_corrections_during_v1")
	print("V1_RESULT peer=%d checks=%d failures=%d" % [_peer_id, _checks, _failures])
	finish.rpc(_failures)
	await _wait(1.0)
	get_tree().quit(0 if _failures == 0 else 1)


# ------------------------------------------------- 1: the model

func _model_checks() -> void:
	var visual := _local.visual
	expect(visual != null and visual.model_loaded(), "the_body_carries_a_loaded_model")
	if visual == null or not visual.model_loaded():
		return
	var want_bones := int(CharacterVisual.profile()["bones"])
	note("model profile %s: %d bones, scale %.3f, measured %.2f m vs capsule %.2f m" % [
		CharacterVisual.profile_name(), visual.skeleton().get_bone_count(), visual.model_scale,
		visual.measured_height(), _local.half_height() * 2.0])
	expect(CharacterVisual.profile_name() == "tripo", "the_village_draws_the_tripo_profile")
	expect(visual.skeleton().get_bone_count() == want_bones, "the_rig_has_its_bones")
	expect(absf(visual.measured_height() - _local.half_height() * 2.0) < 0.11, "the_model_stands_as_tall_as_the_capsule")
	await _wait(1.0)
	var gap := _ground_gap(_local)
	note("spawned at %s, ground gap %.3f, state %s" % [_local.global_position.snapped(Vector3.ONE * 0.01), gap, Player.State.keys()[_local.state]])
	expect(absf(gap) < 0.15 and _local.state == Player.State.IDLE, "the_body_stands_on_the_plaza")
	await _shot("01_spawn_plaza")
	await _map_checks()


# The map: the minimap in the corner from the start, centred on this body;
# Tab opens the full map and Tab closes it.
func _map_checks() -> void:
	var map := _world.village_map
	expect(map != null and map.minimap != null and map.minimap.visible, "the_minimap_is_up_in_the_corner")
	if map == null:
		return
	expect(not map.is_full_open(), "the_full_map_starts_closed")
	var viewport_size := get_viewport().get_visible_rect().size
	var corner := map.minimap.get_global_rect()
	note("minimap rect %s in a %s viewport" % [corner, viewport_size])
	expect(corner.end.x <= viewport_size.x and corner.position.x > viewport_size.x * 0.5 and corner.position.y < viewport_size.y * 0.25,
		"the_minimap_sits_top_right")
	map.minimap.queue_redraw()
	await get_tree().process_frame
	var me := map.minimap.px_of(_local.global_position)
	note("this body draws at %s on the %s minimap" % [me, map.minimap.size])
	expect(me.distance_to(map.minimap.size * 0.5) < 1.0, "the_minimap_is_centred_on_this_body")
	var tab := InputEventKey.new()
	tab.physical_keycode = KEY_TAB
	tab.pressed = true
	Input.parse_input_event(tab)
	await get_tree().process_frame
	await get_tree().process_frame
	expect(map.is_full_open(), "tab_opens_the_full_map")
	await _shot("01b_full_map")
	var full_px := map.full_map.px_of(_local.global_position)
	var inside := Rect2(Vector2.ZERO, map.full_map.size).has_point(full_px)
	var gate_px := map.full_map.to_px(_layout.gate_north)
	note("full map %s px, this body at %s, the north gate at %s, scale %.2f px/m" % [map.full_map.size, full_px, gate_px, map.full_map.scale_px])
	expect(inside and Rect2(Vector2.ZERO, map.full_map.size).has_point(gate_px), "the_full_map_shows_the_body_and_the_gates")
	var release := InputEventKey.new()
	release.physical_keycode = KEY_TAB
	release.pressed = false
	Input.parse_input_event(release)
	await get_tree().process_frame
	Input.parse_input_event(tab)
	await get_tree().process_frame
	await get_tree().process_frame
	expect(not map.is_full_open(), "tab_again_closes_the_full_map")
	Input.parse_input_event(release)
	await get_tree().process_frame


# ------------------------------------------------- 2: the terrain

func _terrain_checks() -> void:
	expect(_world.terrain != null and _world.terrain.built, "the_terrain_is_built")
	if _world.terrain == null or not _world.terrain.built:
		return
	var data := _world.terrain.data()
	note("terrain: regions %d, collision %s, stairs %d (%d steps), nav polygons %d" % [
		data.get_region_count(), _world.terrain.configured_as, _world.stair_count, _world.step_count,
		_world._region.navigation_mesh.get_polygon_count()])
	expect(data.get_region_count() == 16, "the_terrain_has_its_16_regions")
	expect(_world.terrain.configured_as == "FULL_GAME", "the_judge_has_full_collision")
	var worst := 0.0
	var mine := _height_samples()
	for key in HEIGHT_SAMPLES:
		var spot: Vector2 = HEIGHT_SAMPLES[key]
		var want := _layout.height_at(spot.x, spot.y)
		var got := float(mine[key])
		worst = maxf(worst, absf(got - want))
		note("height %s at %s: terrain %.3f, layout %.3f" % [key, spot, got, want])
	expect(worst < 0.1, "terrain_heights_match_the_layout_within_10_cm")
	expect(float(mine["beyond_cliff"]) < Tuning.server.kill_plane_y, "beyond_the_cliff_is_under_the_kill_plane")
	expect(absf(float(mine["plaza"]) - _layout.plaza_height) < 0.01 and absf(float(mine["house_upper"]) - _layout.upper_height) < 0.1
		and absf(float(mine["training"]) - _layout.training_height) < 0.1, "plaza_houses_and_training_sit_at_their_levels")
	_reports.erase("heights")
	client_sample_heights.rpc_id(_client_peer())
	if await _wait_report("heights"):
		var theirs: Dictionary = _reports["heights"]
		var apart := 0.0
		for key in mine:
			apart = maxf(apart, absf(float(mine[key]) - float(theirs.get(key, NAN))))
		note("client heights differ from the host's by at most %.3f" % apart)
		expect(apart < 0.05, "both_peers_hold_the_same_ground")
	expect(absf(Tuning.server.base_move_speed - _layout.move_speed) < 0.001, "the_village_pace_is_on_the_server_table")


# ------------------------------------------------- 3: the pace

func _pace_checks() -> void:
	await _park(PLAZA_W)
	await tick_request(func() -> void: _local.movement.set_target(Vector3(PLAZA_E.x, 0.0, PLAZA_E.y)))
	var waited := 0.0
	var t2 := -1.0
	var t10 := -1.0
	var clip := ""
	var clip_speed := 0.0
	while waited < 12.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		var gone := _local.global_position.x - (PLAZA_W.x)
		if t2 < 0.0 and gone >= 2.0:
			t2 = waited
		if gone >= 6.0 and clip == "":
			clip = _local.visual.current_clip()
			clip_speed = _local.visual.clip_speed()
		if gone >= 10.0:
			t10 = waited
			break
	var speed := 8.0 / (t10 - t2) if t2 >= 0.0 and t10 > t2 else 0.0
	note("pace: %.2f m/s over 8 m (server %.2f), clip %s at x%.2f" % [speed, Tuning.server.base_move_speed, clip, clip_speed])
	expect(absf(speed - _layout.move_speed) < 0.3, "the_body_walks_at_the_village_pace")
	expect(clip == CharacterVisual.clip_for("walk"), "moving_at_the_village_pace_shows_the_walk_clip")
	expect(clip_speed > 1.5 and clip_speed <= 2.0, "the_walk_clip_keeps_pace_without_hitting_the_cap")
	await _wait(1.0)


# ------------------------------------------------- 4: the routes

func _route_checks() -> void:
	# North gate down to the plaza: the long stair (1.8 m) and the plaza rim stair.
	await _park(_layout.gate_north)
	await _shot("02_gate_north")
	_judge_walk("north_gate_to_plaza", await _walk_to(PLAZA_IN, 70.0), 70.0)
	await _shot("03_plaza_from_north")
	# South-east gate to the plaza.
	await _park(_layout.gate_southeast)
	await _shot("04_gate_southeast")
	_judge_walk("southeast_gate_to_plaza", await _walk_to(PLAZA_SE, 60.0), 60.0)
	# Plaza up to the houses (two stairs up: 1.2 then 1.8).
	await _park(Vector2(-4.0, -4.0))
	_judge_walk("plaza_to_houses_up_the_stairs", await _walk_to(HOUSES, 60.0), 60.0)
	await _shot("05_houses_upper")
	# Houses to the training ground (across the upper quarter and down to +2.5).
	_judge_walk("houses_to_training_ground", await _walk_to(TRAINING, 70.0), 70.0)
	await _shot("06_training_ground")
	# Training ground down to the shop terrace (the 1.3 m stair down).
	_judge_walk("training_down_to_the_shop", await _walk_to(SHOP, 50.0), 50.0)
	# The hill: from the shop terrace up the forest slope.
	_judge_walk("shop_up_the_forest_hill", await _walk_to(HILLTOP, 80.0), 80.0)
	await _shot("07_hilltop")
	var top_gap := _ground_gap(_local)
	note("hilltop: body at %s, ground %.2f, gap %.3f" % [_local.global_position.snapped(Vector3.ONE * 0.01),
		_layout.height_at(_local.global_position.x, _local.global_position.z), top_gap])
	await _park(PLAZA_IN)


# ------------------------------------------------- 5: the other peer

func _client_checks() -> void:
	var mate := _mate()
	expect(mate != null and mate.visual != null and mate.visual.model_loaded(), "the_replica_carries_a_model_too")
	_reports.erase("route")
	client_route.rpc_id(_client_peer(), _layout.gate_north, PLAZA_IN, 70.0)
	# Meanwhile this screen watches the replica: it must end up on the plaza
	# and never sit far off the ground (its position is eased, so looser).
	var waited := 0.0
	var gap_min := INF
	var gap_max := -INF
	while waited < 75.0 and not _reports.has("route"):
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		if mate != null and waited > 2.0:
			var gap := _ground_gap(mate)
			gap_min = minf(gap_min, gap)
			gap_max = maxf(gap_max, gap)
	if await _wait_report("route", 5.0):
		var theirs: Dictionary = _reports["route"]
		note("the client walked the north gate route on its own screen: %s" % [theirs])
		expect(bool(theirs.get("arrived", false)) and not bool(theirs.get("killed", true)), "the_clients_body_arrives_on_its_screen")
		expect(float(theirs.get("gap_min", -9.0)) > -0.15 and float(theirs.get("gap_max", 9.0)) < 0.6, "the_clients_body_stays_on_the_ground")
		expect(float(theirs.get("stall_max", 9.0)) < 2.5, "the_clients_body_never_gets_stuck")
	note("replica here: ground gap %.3f .. %.3f, %.1f m from the plaza target" % [gap_min, gap_max, _flat(mate.global_position, PLAZA_IN) if mate != null else -1.0])
	expect(mate != null and _flat(mate.global_position, PLAZA_IN) < 3.0, "this_screen_shows_the_client_on_the_plaza")
	expect(gap_min > -0.5 and gap_max < 1.0, "the_replica_rides_the_same_ground")


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
func client_sample_heights() -> void:
	report.rpc_id(1, "heights", _height_samples())


# Server -> client: park at `from`, walk to `to`, report the numbers.
@rpc("authority", "call_remote", "reliable")
func client_route(from: Vector2, to: Vector2, seconds: float) -> void:
	placed()
	await Harness.forgive_lead(get_tree(), placed)
	await tick_request(func() -> void:
		_local.global_position = _stand(from)
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target()
		_local.movement.set_aim_override(Vector3.INF))
	await _wait(1.0)
	var stats := await _walk_to(to, seconds)
	note("client route: %s" % [stats])
	report.rpc_id(1, "route", stats)


@rpc("authority", "call_remote", "reliable")
func finish(host_failures: int) -> void:
	print("V1_RESULT peer=%d checks=%d failures=%d host_failures=%d" % [_peer_id, _checks, _failures, host_failures])
	await _wait(0.5)
	get_tree().quit(0 if host_failures == 0 else 1)
