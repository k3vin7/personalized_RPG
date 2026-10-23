class_name Playground
extends Node3D

# The grey box map. Geometry is built from a table in code rather than placed by
# hand in the scene: the dimensions are the point of this map, and a table is
# the only form where they can be read and checked against the work order.

const WORLD_LAYER := 1
const WALL_LAYER := 2
const CLIMBABLE_LAYER := 4
# Seen by the navigation bake and by nothing else. A bridge on this layer makes
# a gap look like continuous ground to pathfinding while bodies pass straight
# through it, so walking at the far side walks you off the edge and down.
const NAV_BRIDGE_LAYER := 128

# A navigation surface is eroded by agent_radius from every edge, so any top a
# character is meant to stand on needs a short side wider than twice that plus a
# cell or two. The stair tops here are 3 m, which clears it.
const AGENT_RADIUS := 0.45
const CELL_SIZE := 0.25

var spawn_points: Array[Vector3] = []

var _region: NavigationRegion3D
var _spawner: MultiplayerSpawner
var _players_root: Node3D


func _ready() -> void:
	_region = NavigationRegion3D.new()
	_region.name = "NavigationRegion3D"
	_region.use_edge_connections = false
	add_child(_region)

	_build_lighting()
	_build_ground()
	_build_stairs()
	_build_gaps()
	_build_walls()
	_build_occluders()

	var rack := WeaponRack.new()
	rack.name = "WeaponRack"
	rack.position = Vector3(0.0, 0.0, 16.0)
	add_child(rack)

	_players_root = Node3D.new()
	_players_root.name = "Players"
	add_child(_players_root)

	_spawner = MultiplayerSpawner.new()
	_spawner.name = "PlayerSpawner"
	_spawner.add_spawnable_scene(Net.PLAYER_SCENE)
	# Custom spawn: the peer id and the spawn point travel with the node, so a
	# client's character starts where the host put it instead of at the origin
	# and then arguing about it over the network.
	_spawner.spawn_function = _make_player
	add_child(_spawner)
	# Set once the spawner is in the tree, and relative to it: an absolute path
	# resolved from outside the active tree is refused.
	_spawner.spawn_path = _spawner.get_path_to(_players_root)

	spawn_points.assign([
		Vector3(-2.0, 1.0, 4.0),
		Vector3(2.0, 1.0, 4.0),
		Vector3(-2.0, 1.0, 8.0),
		Vector3(2.0, 1.0, 8.0),
	])
	for point in spawn_points:
		var marker := Marker3D.new()
		marker.position = point
		add_child(marker)

	_bake_navigation()


func _bake_navigation() -> void:
	var nav_mesh := NavigationMesh.new()
	nav_mesh.agent_height = 1.9
	nav_mesh.agent_radius = AGENT_RADIUS
	# Low on purpose: every step here is meant to need a jump, not a walk up.
	nav_mesh.agent_max_climb = 0.3
	nav_mesh.agent_max_slope = 46.0
	nav_mesh.cell_size = CELL_SIZE
	# Matched to the navigation map's own cell height, or the bake warns about
	# rasterisation error along the edges.
	nav_mesh.cell_height = 0.25
	nav_mesh.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_ROOT_NODE_CHILDREN
	nav_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	# Walls are parsed too, so a path routes around them instead of straight
	# through. They cannot contribute a walkable surface: their faces are
	# vertical, and every wall here is 0.6 m thick, which agent_radius erodes
	# away entirely, so no polygon forms on top of one either.
	nav_mesh.geometry_collision_mask = WORLD_LAYER | WALL_LAYER | CLIMBABLE_LAYER | NAV_BRIDGE_LAYER
	_region.navigation_mesh = nav_mesh
	_region.bake_finished.connect(_on_bake_finished)
	_region.call_deferred("bake_navigation_mesh", true)


func _on_bake_finished() -> void:
	print("PLAYGROUND_NAV_READY polygons=%d" % _region.navigation_mesh.get_polygon_count())
	Net.register_playground(_players_root, spawn_points, _spawner)
	Net.playground_ready.emit(self)
	if Net.auto_smoke and multiplayer.is_server():
		_start_smoke_when_ready()


# The two processes reach this point seconds apart, so the host waits for the
# second player and then starts everyone at once. Without that, each peer
# measures the other while the other is still waiting to begin.
func _start_smoke_when_ready() -> void:
	for _wait in range(120):
		await get_tree().create_timer(0.05).timeout
		if _players_root.get_child_count() >= 2:
			break
	begin_smoke.rpc()
	_run_smoke()


@rpc("authority", "call_remote", "reliable")
func begin_smoke() -> void:
	_run_smoke()


func _run_smoke() -> void:
	# Replication is the thing worth checking: the host spawns, every peer ends
	# up with the same players, and each peer sees the other one move. Both
	# characters walk back and forth for the whole window, because the two
	# processes start their checks seconds apart and a single there-and-stop
	# move would be over before the other peer started looking.
	var names := PackedStringArray()
	var local: Player = null
	var remote: Player = null
	for child in _players_root.get_children():
		var player := child as Player
		if player == null:
			continue
		names.append(player.name)
		if player.is_local():
			local = player
		else:
			remote = player
	print("PLAYGROUND_SMOKE_PLAYERS peer=%d count=%d names=%s" % [
		multiplayer.get_unique_id(), names.size(), ", ".join(names)])
	if local == null:
		print("PLAYGROUND_SMOKE_LOCAL missing")
		return

	# The view must not change angle between standing and moving.
	var idle_rotation := local.camera.rotation
	var idle_forward := local.camera.get_camera_flat_forward()

	var home := local.global_position
	var travelled := 0.0
	var remote_travelled := 0.0
	var previous := home
	var remote_previous := remote.global_position if remote != null else Vector3.ZERO
	for leg in range(6):
		local.movement.set_target(home + Vector3(0.0, 0.0, -5.0 if leg % 2 == 0 else 0.0))
		for _tick in range(60):
			await get_tree().physics_frame
			travelled += _flat(local.global_position - previous)
			previous = local.global_position
			if remote != null:
				remote_travelled += _flat(remote.global_position - remote_previous)
				remote_previous = remote.global_position
	print("PLAYGROUND_SMOKE_MOVE peer=%d travelled=%.2f state=%s" % [
		multiplayer.get_unique_id(), travelled, Player.State.keys()[local.state]])
	print("PLAYGROUND_SMOKE_REMOTE peer=%d remote_travelled=%.2f" % [
		multiplayer.get_unique_id(), remote_travelled])
	print("PLAYGROUND_SMOKE_CAMERA moving_rotation_delta=%.4f forward_delta=%.4f pitch=%.1f" % [
		(local.camera.rotation - idle_rotation).length(),
		(local.camera.get_camera_flat_forward() - idle_forward).length(),
		rad_to_deg(-local.camera.rotation.x)])

	# A target on the far side of a gap is unreachable: the navigation mesh does
	# not bridge it, so the body must stop on this side rather than walk out.
	local.global_position = Vector3(-15.0, 1.0, 0.0)
	await get_tree().create_timer(0.6).timeout
	local.movement.set_target(Vector3(-15.0, 0.0, -6.0))
	await get_tree().create_timer(3.0).timeout
	print("PLAYGROUND_SMOKE_GAP peer=%d stopped_z=%.2f crossed=%s" % [
		multiplayer.get_unique_id(), local.global_position.z, local.global_position.z < -2.5])

	# A held right button re-issues the order ten times a second. The state must
	# not flicker and the body must not stall between the queries.
	# Far enough that the whole window is travel: measuring past the arrival
	# would just be counting the time spent standing still.
	local.global_position = Vector3(1.5, 1.0, 16.0)
	await get_tree().create_timer(0.6).timeout
	var flips := 0
	var last_state := local.state
	var stalls := 0
	var drag_target := Vector3(1.5, 0.0, -1.0)
	# Counted only while the order is still live. Idling at the destination is
	# not a stall, and counting it hid the real number behind the travel time.
	# Distance covered against distance possible: a per frame velocity sample
	# turned out to read whatever the step had just left behind, which is not
	# the same thing as whether the body kept moving.
	var measured := 0
	var covered := 0.0
	var drag_previous := local.global_position
	for _tick in range(240):
		if _tick % 12 == 0:
			local.movement.set_target(drag_target)
		await get_tree().physics_frame
		if not local.movement.has_target():
			break
		measured += 1
		covered += _flat(local.global_position - drag_previous)
		drag_previous = local.global_position
		if local.state != last_state:
			flips += 1
			last_state = local.state
	stalls = measured
	var possible := local.get_move_speed() * float(measured) * get_physics_process_delta_time()
	print("PLAYGROUND_SMOKE_DRAG state_flips=%d covered=%.2f of possible %.2f (%.0f%%)" % [
		flips, covered, possible, 100.0 * covered / maxf(possible, 0.01)])

	# Walls below the character fade by height alone, wherever they are. From
	# the high platform the smooth wall (top 4 m) is under our feet; from the
	# plaza nothing is, and no occluder sits in this line of sight either.
	# Settled, not just teleported: an order left over from the drag check would
	# walk the body straight back off the platform.
	# Walls nearer the camera than the body fade; walls further away do not.
	# Every wall in this map sits at z 2 or z 6..10, so standing north of them
	# all should fade none, and standing south of them all should fade all.
	await _settle(local, Vector3(0.0, 1.0, 14.0))
	await get_tree().create_timer(0.8).timeout
	var faded_behind := OcclusionFader.faded_rids().size()
	await _settle(local, Vector3(0.0, 1.0, 0.0))
	await get_tree().create_timer(0.8).timeout
	var faded_in_front := OcclusionFader.faded_rids().size()
	var jump_before := OcclusionFader.faded_rids().size()
	local.movement.request_jump()
	await get_tree().create_timer(0.35).timeout
	var jump_during := OcclusionFader.faded_rids().size()
	await get_tree().create_timer(1.2).timeout
	print("PLAYGROUND_SMOKE_FADE north_of_walls=%d south_of_walls=%d jump_before=%d jump_during=%d" % [
		faded_behind, faded_in_front, jump_before, jump_during])

	if multiplayer.is_server():
		await _run_stage2_checks(local)
		await _run_respawn_checks(local)
		# Long enough that the other process has really gone, not merely queued.
		await get_tree().create_timer(9.0).timeout
		print("PLAYGROUND_SMOKE_AFTER_LEAVE players=%d" % _players_root.get_child_count())


# Stage 2 gates. Each one is the outcome the work order asks for, measured
# rather than argued from the numbers.
func _run_respawn_checks(local: Player) -> void:
	# Falling past the kill plane kills and brings the body back on its own.
	await _settle(local, Vector3(0.0, 1.0, 8.0))
	var home := local.spawn_point
	local.global_position = Vector3(0.0, Tuning.values.kill_plane_y - 2.0, 8.0)
	await get_tree().create_timer(0.3).timeout
	var died := local.state == Player.State.DEAD
	await get_tree().create_timer(Tuning.values.respawn_delay + 0.8).timeout
	print("PLAYGROUND_FALL died=%s back_home=%.2f state=%s" % [
		died, local.global_position.distance_to(home), Player.State.keys()[local.state]])

	# R restarts from anywhere, without having to fall first.
	await _settle(local, Vector3(-12.0, 1.0, 4.0))
	local.respawn()
	await get_tree().create_timer(0.5).timeout
	print("PLAYGROUND_RESTART back_home=%.2f state=%s" % [
		local.global_position.distance_to(home), Player.State.keys()[local.state]])


func _run_stage2_checks(local: Player) -> void:
	# What is actually standing at the step positions?
	for probe in [Vector3(-6.0, 5.0, 14.0), Vector3(-1.5, 5.0, 14.0)]:
		var query := PhysicsRayQueryParameters3D.create(probe, probe + Vector3.DOWN * 8.0, 0xFFFFFFFF)
		var hit := get_world_3d().direct_space_state.intersect_ray(query)
		var collider := hit.get("collider") as Node3D if not hit.is_empty() else null
		print("PLAYGROUND_PROBE at=%.1f hit=%s y=%.2f layer=%d" % [
			probe.x,
			collider.name if collider != null else "none",
			(hit.get("position", Vector3.ZERO) as Vector3).y,
			(collider as CollisionObject3D).collision_layer if collider != null else -1])
	print("PLAYGROUND_STAGE2_FORMULA ratio=%.2f jump_height=%.2f jump_velocity=%.2f move_speed=%.2f" % [
		local.get_ratio(), local.get_jump_height(), local.get_jump_velocity(), local.get_move_speed()])

	# Standing jump: straight up, and as high as the formula says.
	var start := await _settle(local, Vector3(1.5, 1.0, 8.0))
	local.movement.request_jump()
	var peak := start.y
	var airborne := 0.0
	while airborne < 1.4:
		await get_tree().physics_frame
		airborne += get_physics_process_delta_time()
		peak = maxf(peak, local.global_position.y)
	print("PLAYGROUND_STAGE2_STANDING rise=%.2f drift=%.2f" % [
		peak - start.y, _flat(local.global_position - start)])

	# Steps: 1.5 m is meant to be reachable, 2.0 m is not. The jump has to be
	# taken on the run and early: launching from the edge puts the body only a
	# metre up by the time it reaches the step and it hits the side. Picking
	# that moment is the skill the work order is asking about.
	for step in [{"height": 1.5, "x": -6.0}, {"height": 2.0, "x": -1.5}]:
		# Approached from the south, where there is room to get up to speed:
		# the step row sits close to the plaza's north edge.
		# Aimed at the ground in front of the step, not at its top: a click on
		# the top makes the path walk around the block, and the jump inherits
		# that sideways heading and misses.
		var landed := await _jump_on_the_run(
			local,
			Vector3(step["x"], 1.0, 7.0),
			Vector3(step["x"], 0.0, 11.5),
			12.5,
			2.3)
		print("PLAYGROUND_STAGE2_STEP height=%.1f landed_y=%.2f on_top=%s" % [
			step["height"], landed.y, landed.y > float(step["height"]) + 0.5])

	# With a nav bridge the far side is a valid destination, so ordering a move
	# there walks the body out over the gap and drops it.
	await _settle(local, Vector3(-5.0, 1.0, 2.0))
	local.movement.set_target(Vector3(-5.0, 0.0, -8.0))
	await get_tree().create_timer(3.0).timeout
	print("PLAYGROUND_STAGE2_WALKOFF y=%.2f z=%.2f state=%s" % [
		local.global_position.y, local.global_position.z, Player.State.keys()[local.state]])
	await _settle(local, Vector3(0.0, 1.0, 8.0))

	# Gaps: 3 m is meant to be crossable, 5 m is not. Taken on the run, like the
	# steps: with a nav bridge over the gap the body no longer stops at the
	# edge, it walks off, so the jump has to be timed rather than set up.
	#
	# A gap wants the opposite timing to a step. A step is cleared by leaving
	# early and being high at the edge; a gap is crossed by leaving as late as
	# possible, because every metre spent before the edge is a metre not spent
	# over it.
	for gap in [{"width": 3.0, "x": -5.0}, {"width": 5.0, "x": 15.0}]:
		var far_z: float = -2.0 - float(gap["width"]) - 2.0
		var landed := await _jump_on_the_run(
			local,
			Vector3(gap["x"], 1.0, 4.0),
			Vector3(gap["x"], 0.0, far_z),
			-2.0,
			0.5)
		print("PLAYGROUND_STAGE2_GAP width=%.0f landed=(%.2f, %.2f) crossed=%s" % [
			gap["width"], landed.y, landed.z, landed.z < -2.0 - float(gap["width"]) and landed.y > -1.0])

	# A click made in the air must not bend the arc, and must be honoured on
	# landing.
	start = await _settle(local, Vector3(1.5, 1.0, 8.0))
	local.movement.request_jump()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var air_velocity := Vector2(local.velocity.x, local.velocity.z)
	local.movement.set_target(Vector3(1.5, 0.0, 2.0))
	await get_tree().create_timer(0.3).timeout
	var bend := (Vector2(local.velocity.x, local.velocity.z) - air_velocity).length()
	await get_tree().create_timer(2.5).timeout
	print("PLAYGROUND_STAGE2_AIRCLICK arc_bend=%.3f walked_after_landing=%.2f state=%s" % [
		bend, _flat(local.global_position - start), Player.State.keys()[local.state]])


# Walk at something and jump while still moving, once the body passes the
# given z. The horizontal speed is carried into the arc, which is what makes a
# step clearable at all.
func _jump_on_the_run(
		local: Player,
		from: Vector3,
		target: Vector3,
		edge_z: float,
		lead: float) -> Vector3:
	await _settle(local, from)
	local.movement.set_target(target)
	var waited := 0.0
	while waited < 4.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		if absf(local.global_position.z - edge_z) <= lead:
			break
	var launch := local.global_position
	var launch_velocity := Vector2(local.velocity.x, local.velocity.z)
	var launch_speed := launch_velocity.length()
	local.movement.request_jump()
	var peak := launch.y
	var airborne := 0.0
	var trace := PackedStringArray()
	var samples := 0
	while airborne < 2.0:
		await get_tree().physics_frame
		airborne += get_physics_process_delta_time()
		peak = maxf(peak, local.global_position.y)
		samples += 1
		if samples % 12 == 0 and trace.size() < 10:
			trace.append("%.2f/%.2f" % [local.global_position.z, local.global_position.y])
	print("PLAYGROUND_STAGE2_RUNJUMP launch=(%.2f, %.2f) vel=(%.2f, %.2f) peak_y=%.2f end=(%.2f, %.2f)" % [
		launch.x, launch.z, launch_velocity.x, launch_velocity.y, peak,
		local.global_position.x, local.global_position.z])
	return local.global_position


func _settle(local: Player, at_position: Vector3) -> Vector3:
	# A check that ended in a fall leaves the body dead and unable to move, so
	# wait the respawn out before placing it for the next one.
	var waited := 0.0
	while local.state == Player.State.DEAD and waited < 6.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	local.global_position = at_position
	local.velocity = Vector3.ZERO
	local.movement.cancel_target()
	await get_tree().create_timer(0.8).timeout
	return local.global_position


# Walk at an unreachable target, which stops at the edge and leaves the jump
# intent behind, then jump. This is the "click, stop, Space" flow.
func _jump_towards(local: Player, from: Vector3, target: Vector3) -> Vector3:
	await _settle(local, from)
	local.movement.set_target(target)
	var waited := 0.0
	while waited < 3.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		if local.movement.intent_seconds_left() > 0.0:
			break
	local.movement.request_jump()
	await get_tree().create_timer(2.5).timeout
	return local.global_position


func _flat(delta: Vector3) -> float:
	return Vector2(delta.x, delta.z).length()


# Runs on every peer with the same data, which is what makes the spawn match.
func _make_player(data: Variant) -> Node:
	var info := data as Dictionary
	var player := (load(Net.PLAYER_SCENE) as PackedScene).instantiate() as Node3D
	player.name = str(info.get("peer", 1))
	player.position = info.get("position", Vector3.ZERO)
	return player


func _build_lighting() -> void:
	var environment := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("9ba3ad")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("dce5ef")
	env.ambient_light_energy = 0.6
	environment.environment = env
	add_child(environment)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52.0, -40.0, 0.0)
	sun.light_energy = 1.05
	sun.shadow_enabled = true
	add_child(sun)


func _build_ground() -> void:
	# 40 x 20 plaza. Its +x edge is the cliff: nothing below it until the kill
	# plane, which is what the respawn test needs.
	_box("Plaza", Vector3(0.0, -0.5, 8.0), Vector3(40.0, 1.0, 20.0), Color("777d84"), WORLD_LAYER)
	_box("HighPlatform", Vector3(14.0, 2.5, 14.0), Vector3(6.0, 5.0, 6.0), Color("6d747b"), WORLD_LAYER)


func _build_stairs() -> void:
	# 0.5 / 1.0 / 1.5 / 2.0 m, each 3 x 3: the jump height ladder.
	var heights := [0.5, 1.0, 1.5, 2.0]
	for index in heights.size():
		var height: float = heights[index]
		_box(
			"Step_%.1f" % height,
			Vector3(-15.0 + float(index) * 4.5, height * 0.5, 14.0),
			Vector3(3.0, height, 3.0),
			Color("656b72"),
			WORLD_LAYER)
		_sign("%.1fm" % height, Vector3(-15.0 + float(index) * 4.5, height + 1.2, 14.0), Color.WHITE)


func _build_gaps() -> void:
	# 2 / 3 / 4 / 5 m gaps, each with a floor 3 m down so a failed jump lands
	# somewhere instead of dying. The far side must not touch the plaza, or the
	# navigation mesh would bridge the gap and there would be nothing to jump.
	var widths := [2.0, 3.0, 4.0, 5.0]
	var lanes := [-15.0, -5.0, 5.0, 15.0]
	for index in widths.size():
		var width: float = widths[index]
		var lane: float = lanes[index]
		var gap_start := -2.0
		var far_edge := gap_start - width
		_box(
			"GapFar_%.0f" % width,
			Vector3(lane, -0.5, far_edge - 3.0),
			Vector3(8.0, 1.0, 6.0),
			Color("858b91"),
			WORLD_LAYER)
		_box(
			"GapPit_%.0f" % width,
			Vector3(lane, -3.5, gap_start - width * 0.5),
			Vector3(8.0, 1.0, width + 1.0),
			Color("5f656b"),
			WORLD_LAYER)
		# Nothing to stand on, only something to path over.
		_nav_bridge("GapBridge_%.0f" % width, Vector3(lane, -0.5, gap_start - width * 0.5), Vector3(8.0, 1.0, width))
		_sign("GAP %.0fm" % width, Vector3(lane, 1.6, gap_start + 1.0), Color("d9f3ff"))


func _build_walls() -> void:
	# Climbable, 6 x 6. A faces the camera, B faces sideways, C faces away.
	_box("ClimbWallA", Vector3(-14.0, 3.0, 2.0), Vector3(6.0, 6.0, 0.6), Color("7a8f7a"), CLIMBABLE_LAYER)
	# Clear of the x=-5 gap lane: a wall beside a lane eats the run up, because
	# agent_radius keeps the walkable surface half a metre off it.
	_box("ClimbWallB", Vector3(-9.0, 3.0, 2.0), Vector3(0.6, 6.0, 6.0), Color("7a8f7a"), CLIMBABLE_LAYER)
	_box("ClimbWallC", Vector3(6.0, 3.0, 2.0), Vector3(6.0, 6.0, 0.6), Color("7a8f7a"), CLIMBABLE_LAYER)
	_sign("CLIMB A / B / C", Vector3(-9.0, 7.0, 2.0), Color("c8ffc8"))
	# Smooth wall: looks the same, cannot be climbed.
	_box("SmoothWall", Vector3(16.0, 2.0, 2.0), Vector3(6.0, 4.0, 0.6), Color("555b62"), WALL_LAYER)
	_sign("SMOOTH", Vector3(16.0, 5.0, 2.0), Color.WHITE)


func _build_occluders() -> void:
	# Between the camera and the plaza, so walking behind one fades it. Kept
	# east of the step row: a wall across the approach would stop the run up a
	# step before it started, now that walls are part of the navigation bake.
	_box("OccluderA", Vector3(7.0, 2.5, 10.0), Vector3(8.0, 5.0, 0.6), Color("4b535c"), WALL_LAYER, true)
	_box("OccluderB", Vector3(16.0, 2.5, 6.0), Vector3(8.0, 5.0, 0.6), Color("4b535c"), WALL_LAYER, true)
	_sign("OCCLUSION", Vector3(7.0, 6.0, 10.0), Color.WHITE)


func _box(
		box_name: String,
		at_position: Vector3,
		size: Vector3,
		color: Color,
		layer: int,
		occluder := false) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = box_name
	body.position = at_position
	body.collision_layer = layer
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)

	var mesh_instance := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = size
	mesh_instance.mesh = box_mesh
	# Walls fade, floors never do. A floor cannot hide the character, and fading
	# them turned every jump into a screen wide flicker as the ground crossed
	# the threshold and came back.
	var is_wall := layer == WALL_LAYER or layer == CLIMBABLE_LAYER
	if is_wall:
		var shader_material := ShaderMaterial.new()
		shader_material.shader = load("res://shaders/dither_fade.gdshader")
		shader_material.set_shader_parameter("albedo", color)
		shader_material.set_shader_parameter("fade", 1.0)
		mesh_instance.material_override = shader_material
		# The face nearest the camera. The view never rotates, so the camera
		# side is simply the larger z.
		body.set_meta("near_z", at_position.z + size.z * 0.5)
		body.add_to_group(OcclusionFader.WALL_GROUP)
		if occluder:
			body.add_to_group(OcclusionFader.OCCLUDER_GROUP)
	else:
		var material := StandardMaterial3D.new()
		material.albedo_color = color
		material.roughness = 0.8
		mesh_instance.material_override = material
	body.add_child(mesh_instance)

	_region.add_child(body)
	return body


# No mesh and no mask anyone reads: it exists for the bake and for nothing else.
func _nav_bridge(bridge_name: String, at_position: Vector3, size: Vector3) -> void:
	var body := StaticBody3D.new()
	body.name = bridge_name
	body.position = at_position
	body.collision_layer = NAV_BRIDGE_LAYER
	body.collision_mask = 0
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	_region.add_child(body)


func _sign(text: String, at_position: Vector3, color: Color) -> void:
	var label := Label3D.new()
	label.text = text
	label.position = at_position
	label.modulate = color
	label.font_size = 36
	label.outline_size = 7
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	add_child(label)
