extends Node3D

# Single-player walkabout for a map scene run on its own with F6: no main
# menu, no ENet peer, one local player that is also the judge. Same recipe as
# blockout_test.gd, except that the map is this scene itself rather than a
# child of a NavigationRegion3D, so the bake parses from this node down.
#
# A Player placed in the scene by hand does not work: its node name is not a
# peer id, so its authority is peer 0 and nobody drives it. The player has to
# come through Net's spawner, which is what this does at spawn_point. The
# quarter camera, the status bars and the debug panel are built by the player
# itself in Player._ready() when it is local.
#
# Does nothing when the scene is instanced inside another one.
#
# Command line (after "--"): --walk-check presses jump and a move click once
# the player is down and prints what happened, then quits. --ride-check
# travels from the spawn to ride_check_end on foot and again on the horse,
# and prints both times and what the horse caught on.

const AGENT_RADIUS := 0.45
const CELL_SIZE := 0.25

@export var spawn_point := Vector3(0.0, 2.0, 8.0)
# Which way is up the screen, degrees about Y (0 = -Z). This map's north is
# the (-X, +Z) diagonal: zone_5's floor_N sits at (-75, 54), floor_E at
# (-75, -60), floor_S at (50, -60), floor_W at (50, 79). 135 puts north up.
@export var camera_yaw_degrees := 135.0
# The body as its collision capsule rather than the character model.
@export var capsule_body := true

var world_map: BlockoutMap
var _region: NavigationRegion3D
var _players_root: Node3D
var _spawner: MultiplayerSpawner
var _pending_nav_mesh: NavigationMesh
var _bake_started_ms := 0


func _ready() -> void:
	if get_tree().current_scene != self:
		return
	# Net.queue_physics() drops every request while there is no peer, and the
	# jump, dash and respawn paths all go through it. Offline is still a peer.
	if not multiplayer.has_multiplayer_peer():
		multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()

	var authority := ServerAuthority.new()
	authority.name = "ServerAuthority"
	add_child(authority)

	_region = NavigationRegion3D.new()
	_region.name = "NavigationRegion3D"
	add_child(_region)

	_players_root = Node3D.new()
	_players_root.name = "Players"
	add_child(_players_root)

	_spawner = MultiplayerSpawner.new()
	_spawner.name = "PlayerSpawner"
	_spawner.add_spawnable_scene(Net.PLAYER_SCENE)
	_spawner.spawn_function = _make_player
	add_child(_spawner)
	_spawner.spawn_path = _spawner.get_path_to(_players_root)

	# Deferred: the CSG shapes build their colliders after _ready.
	_bake_navigation.call_deferred()


func _bake_navigation() -> void:
	var nav_mesh := NavigationMesh.new()
	nav_mesh.agent_height = 1.9
	nav_mesh.agent_radius = AGENT_RADIUS
	nav_mesh.agent_max_climb = 0.3
	nav_mesh.agent_max_slope = Tuning.server.walk_slope_max_deg - 2.0
	nav_mesh.cell_size = CELL_SIZE
	nav_mesh.cell_height = 0.25
	nav_mesh.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_ROOT_NODE_CHILDREN
	nav_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	nav_mesh.geometry_collision_mask = Layers.WORLD | Layers.WALL | Layers.CLIMBABLE | Layers.NAV_BRIDGE
	var source := NavigationMeshSourceGeometryData3D.new()
	NavigationServer3D.parse_source_geometry_data(nav_mesh, source, self)
	_pending_nav_mesh = nav_mesh
	_bake_started_ms = Time.get_ticks_msec()
	NavigationServer3D.bake_from_source_geometry_data_async(nav_mesh, source, _on_bake_finished)


func _on_bake_finished() -> void:
	_region.navigation_mesh = _pending_nav_mesh
	_pending_nav_mesh = null
	print("WORLD_WALK_NAV_READY polygons=%d bake_ms=%d" % [
		_region.navigation_mesh.get_polygon_count(), Time.get_ticks_msec() - _bake_started_ms])
	# One mark, so a respawn comes back to the same spot. Net spawns peer 1
	# through the spawner the moment it is registered.
	var points: Array[Vector3] = [spawn_point]
	Net.register_playground(_players_root, points, _spawner)
	var local := _local_player()
	if local != null and local.camera != null:
		local.camera.set_yaw(camera_yaw_degrees)
	if local != null:
		local.draw_as_capsule(capsule_body)
	# The map (minimap top-right, Tab for the whole world), up = the camera's up.
	world_map = BlockoutMap.new()
	world_map.name = "BlockoutMap"
	world_map.setup(self, camera_yaw_degrees, scene_file_path.get_file().get_basename())
	add_child(world_map)
	print("WORLD_WALK_SPAWN local=%s peer=%d at=%s" % [
		local != null, multiplayer.get_unique_id(),
		local.global_position if local != null else Vector3.INF])
	if local == null:
		return
	for argument in OS.get_cmdline_user_args():
		if argument == "--walk-check":
			_walk_check(local)
		elif argument == "--ride-check":
			_ride_check(local)
		elif argument.begins_with("--shot="):
			_take_shots(argument.trim_prefix("--shot="))


# Saves the view with the minimap, then again with the full map open
# (<name>_full.png), and quits.
func _take_shots(path: String) -> void:
	await get_tree().create_timer(2.0).timeout
	await RenderingServer.frame_post_draw
	var first := get_viewport().get_texture().get_image().save_png(path)
	world_map.toggle_full()
	await get_tree().create_timer(0.3).timeout
	await RenderingServer.frame_post_draw
	var second := get_viewport().get_texture().get_image().save_png(path.get_basename() + "_full.png")
	print("WORLD_WALK_SHOT path=%s errors=%d,%d" % [path, first, second])
	get_tree().quit()


func _make_player(data: Variant) -> Node:
	var info := data as Dictionary
	var player := (load(Net.PLAYER_SCENE) as PackedScene).instantiate() as Node3D
	player.name = str(info.get("peer", 1))
	player.position = info.get("position", Vector3.ZERO)
	return player


func _local_player() -> Player:
	for child in _players_root.get_children():
		var player := child as Player
		if player != null and player.is_local():
			return player
	return null


# Measures what F6 is for: the body lands, a jump leaves the floor, a move
# order walks it. Input goes through the player's own request functions.
func _walk_check(local: Player) -> void:
	await get_tree().create_timer(1.5).timeout
	var landed := local.global_position
	print("WORLD_WALK_CHECK landed at=%s on_floor=%s state=%s" % [
		landed, local.is_on_floor(), Player.State.keys()[local.state]])
	print("WORLD_WALK_CHECK body capsule=%s model_loaded=%s model_visible=%s" % [
		local.drawn_as_capsule(), local.visual.model_loaded(), local.visual.visible])

	# Where the compass lands on the screen: north should be straight up from
	# the body (same x, smaller y), east to its right.
	var lens := local.camera.camera
	var here := lens.unproject_position(local.global_position)
	var north := Vector3(-1.0, 0.0, 1.0).normalized()
	var east := Vector3(-1.0, 0.0, -1.0).normalized()
	print("WORLD_WALK_CHECK view forward=%s north_on_screen=%s east_on_screen=%s" % [
		local.camera.get_camera_flat_forward(),
		lens.unproject_position(local.global_position + north * 5.0) - here,
		lens.unproject_position(local.global_position + east * 5.0) - here])

	# The map: what it read, that the minimap is centred on the body with
	# north up, and that Tab opens and closes the full one.
	var mini := world_map.minimap
	mini.refresh()
	var tab := InputEventAction.new()
	tab.action = BlockoutMap.ACTION
	tab.pressed = true
	Input.parse_input_event(tab)
	await get_tree().process_frame
	await get_tree().process_frame
	var opened := world_map.is_full_open()
	world_map.toggle_full()
	print("WORLD_WALK_CHECK map shapes=%d labels=%d extent=%s body_px=%s of %s north_px=%s tab_opens=%s closes=%s" % [
		world_map.shapes.size(), world_map.labels.size(), world_map.extent.size,
		mini.px_of(local.global_position), mini.size,
		mini.px_of(local.global_position + north * 20.0) - mini.px_of(local.global_position),
		opened, not world_map.is_full_open()])

	local.movement.request_jump()
	var peak := landed.y
	var left_floor := false
	for i in 90:
		await get_tree().physics_frame
		peak = maxf(peak, local.global_position.y)
		left_floor = left_floor or not local.is_on_floor()
	print("WORLD_WALK_CHECK jump left_floor=%s rise=%.2f" % [left_floor, peak - landed.y])

	await get_tree().create_timer(1.0).timeout
	var from := local.global_position
	local.movement.set_target(from + Vector3(6.0, 0.0, 0.0))
	await get_tree().create_timer(2.5).timeout
	var moved := local.global_position - from
	print("WORLD_WALK_CHECK move walked=%.2f on_floor=%s state=%s" % [
		Vector2(moved.x, moved.z).length(), local.is_on_floor(), Player.State.keys()[local.state]])
	get_tree().quit()


# ------------------------------------------------------------ the ride check

# The far end of the 5_to_6 road (x 0, z -90 .. -450).
@export var ride_check_end := Vector3(0.0, 1.4, -448.0)
# Round the plaza's centre disk (radius 5, a 0.1 m lip) and down the middle
# of the road, for the trip that keeps to it. The
# direct order's own path leaves the road across the farm plots, whose 0.1 m
# lip stops a body on foot.
@export var ride_check_via: Array[Vector3] = [Vector3(8.0, 1.4, 3.0), Vector3(3.0, 1.4, -10.0), Vector3(0.0, 1.4, -20.0), Vector3(0.0, 1.4, -90.0), Vector3(0.0, 1.4, -270.0)]


# One order from where the body stands to `to`, sampled every physics step.
func _travel(local: Player, to: Vector3, limit: float, via: Array[Vector3] = []) -> Dictionary:
	var out := {"seconds": -1.0, "metres": 0.0, "peak": 0.0, "stuck": 0, "wall": 0, "air": 0,
		"slow_at": [], "wall_at": [], "points": 0}
	var from := local.global_position
	var line := Vector2(to.x - from.x, to.z - from.z).length()
	var stops: Array[Vector3] = via.duplicate()
	stops.append(to)
	local.movement.set_target(stops[0])
	var last := from
	var waited := 0.0
	var step := 1.0 / float(Engine.physics_ticks_per_second)
	var top := local.get_mount_speed() if local.is_mounted() else local.get_move_speed()
	var still := 0.0
	while waited < limit:
		await get_tree().physics_frame
		waited += step
		var here := local.global_position
		out["metres"] = float(out["metres"]) + Vector2(here.x - last.x, here.z - last.z).length()
		last = here
		var speed := Vector2(local.velocity.x, local.velocity.z).length()
		out["peak"] = maxf(float(out["peak"]), speed)
		if local.movement._path.size() > int(out["points"]):
			out["points"] = local.movement._path.size()
			out["path"] = local.movement._path.duplicate()
		# Not moving for five seconds with the order still standing: stuck.
		still = still + step if speed < 0.05 and waited > 1.0 else 0.0
		if still > 5.0:
			out["stuck_at"] = here
			break
		var left := Vector2(to.x - here.x, to.z - here.z).length()
		# The next point is ordered a little before this one is reached, so
		# the body does not brake for it.
		if stops.size() > 1 and Vector2(stops[0].x - here.x, stops[0].z - here.z).length() < 3.0:
			stops.remove_at(0)
			local.movement.set_target(stops[0])
		if local.is_on_wall():
			out["wall"] = int(out["wall"]) + 1
			if (out["wall_at"] as Array).size() < 6:
				(out["wall_at"] as Array).append(here)
		if not local.is_on_floor():
			out["air"] = int(out["air"]) + 1
		# Under half the top speed, well into the trip and well short of its
		# end: caught on something, or crawling round a corner.
		if waited > 2.0 and left > 12.0 and speed < top * 0.5:
			out["stuck"] = int(out["stuck"]) + 1
			if (out["slow_at"] as Array).size() < 6 and int(out["stuck"]) % 30 == 1:
				(out["slow_at"] as Array).append(here)
		if left < 1.0 and speed < 0.05 and not local.movement.has_target():
			out["seconds"] = waited
			break
	out["line"] = line
	out["short"] = Vector2(to.x - local.global_position.x, to.z - local.global_position.z).length()
	return out


func _ride_check(local: Player) -> void:
	await get_tree().create_timer(1.5).timeout
	var start := local.global_position
	var judge := ServerAuthority.instance
	var warnings := judge.move_warnings
	var corrections := judge.move_corrections
	print("WORLD_RIDE_CHECK from=%s to=%s walk_speed=%.2f mount_speed=%.2f" % [
		start, ride_check_end, local.get_move_speed(), local.get_mount_speed()])
	var walk := await _travel(local, ride_check_end, 200.0)
	print("WORLD_RIDE_CHECK walk seconds=%.2f metres=%.1f line=%.1f peak=%.2f path_points=%d slow_frames=%d wall_frames=%d air_frames=%d short=%.2f" % [
		walk["seconds"], walk["metres"], walk["line"], walk["peak"], walk["points"], walk["stuck"], walk["wall"], walk["air"], walk["short"]])
	judge.forgive_move(multiplayer.get_unique_id(), "ride_check")
	local.movement.cancel_target()
	local.global_position = start
	local.velocity = Vector3.ZERO
	local.rotation.y = 0.0
	await get_tree().create_timer(1.0).timeout
	local.movement.press_mount()
	await get_tree().create_timer(float(Tuning.server.mount_summon_time) + 0.5).timeout
	print("WORLD_RIDE_CHECK mounted=%s collider=%s" % [local.is_mounted(), local.mount.collider_dims()])
	var ride := await _travel(local, ride_check_end, 120.0)
	print("WORLD_RIDE_CHECK ride seconds=%.2f metres=%.1f line=%.1f peak=%.2f path_points=%d slow_frames=%d wall_frames=%d air_frames=%d short=%.2f" % [
		ride["seconds"], ride["metres"], ride["line"], ride["peak"], ride["points"], ride["stuck"], ride["wall"], ride["air"], ride["short"]])
	print("WORLD_RIDE_CHECK ride slow_at=%s wall_at=%s" % [ride["slow_at"], ride["wall_at"]])
	print("WORLD_RIDE_CHECK walk slow_at=%s wall_at=%s stuck_at=%s" % [walk["slow_at"], walk["wall_at"], walk.get("stuck_at", "none")])
	print("WORLD_RIDE_CHECK walk_path=%s" % [walk.get("path", [])])
	print("WORLD_RIDE_CHECK ride_path=%s" % [ride.get("path", [])])
	# The same two trips kept to the road.
	var road := {}
	for mounted: bool in [true, false]:
		judge.forgive_move(multiplayer.get_unique_id(), "ride_check")
		local.movement.cancel_target()
		if local.is_mounted() != mounted:
			local.movement.press_mount()
		local.global_position = start
		local.velocity = Vector3.ZERO
		local.rotation.y = 0.0
		await get_tree().create_timer(float(Tuning.server.mount_summon_time) + 0.5).timeout
		var trip := await _travel(local, ride_check_end, 200.0, ride_check_via)
		road[mounted] = trip
		print("WORLD_RIDE_CHECK road %s seconds=%.2f metres=%.1f peak=%.2f slow_frames=%d wall_frames=%d air_frames=%d short=%.2f stuck_at=%s slow_at=%s wall_at=%s" % [
			"ride" if mounted else "walk", trip["seconds"], trip["metres"], trip["peak"], trip["stuck"], trip["wall"],
			trip["air"], trip["short"], trip.get("stuck_at", "none"), trip["slow_at"], trip["wall_at"]])
	print("WORLD_RIDE_CHECK road ratio=%.2f direct_ride=%.2f move_warnings=%d corrections=%d" % [
		float(road[false]["seconds"]) / maxf(float(road[true]["seconds"]), 0.01), float(ride["seconds"]),
		judge.move_warnings - warnings, judge.move_corrections - corrections])
	get_tree().quit()
