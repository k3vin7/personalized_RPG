class_name Playground
extends Node3D

# The grey box map. Geometry is built from a table in code rather than placed by
# hand in the scene: the dimensions are the point of this map, and a table is
# the only form where they can be read and checked against the work order.

const WORLD_LAYER := Layers.WORLD
const WALL_LAYER := Layers.WALL
const CLIMBABLE_LAYER := Layers.CLIMBABLE
# Seen by the navigation bake and by nothing else. A bridge on this layer makes
# a gap look like continuous ground to pathfinding while bodies pass straight
# through it, so walking at the far side walks you off the edge and down.
const NAV_BRIDGE_LAYER := Layers.NAV_BRIDGE

# A navigation surface is eroded by agent_radius from every edge, so any top a
# character is meant to stand on needs a short side wider than twice that plus a
# cell or two. The stair tops here are 3 m, which clears it.
const ROCK_SCENE := "res://scenes/rock.tscn"
# West end of the plaza, on a line with 20 m of clear ground east of it and no
# wall, platform or edge in the way. Every distance a throw is measured over
# happens here.
# Six metres clear of the plaza's west edge: a body placed any nearer gets
# nudged off it by a landing throw and spends the next check falling.
const THROW_LANE := Vector3(-14.0, 1.0, 8.0)

const AGENT_RADIUS := 0.45
const CELL_SIZE := 0.25

var spawn_points: Array[Vector3] = []

var _region: NavigationRegion3D
var _spawner: MultiplayerSpawner
var _players_root: Node3D
var _boundary: TimeBoundary
# Set by the host over RPC, read by the client's half of the stage 7 checks.
var _escape_drill := false
var _disconnect_rock := NodePath()


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
	_build_time_boundary()

	for index in 2:
		var dummy := Dummy.new()
		dummy.setup(Vector3(-2.0 + float(index) * 4.0, 1.0, 2.0), "Dummy_%d" % index)
		add_child(dummy)
	_sign("허수아비 (E로 밀기)", Vector3(0.0, 2.6, 2.0), Color("ffe9b0"))

	# Three rocks, 5 / 10 / 20 kg. Built on every peer with the same names, so
	# only the host's state has to travel.
	var rock_weights := [5.0, 10.0, 20.0]
	for index in rock_weights.size():
		var rock := (load(ROCK_SCENE) as PackedScene).instantiate() as Rock
		rock.setup("Rock_%d" % index, Vector3(4.0 + float(index) * 2.0, 1.0, 6.0), rock_weights[index])
		add_child(rock)
	_sign("돌 (G 잡기 / G 던지기)", Vector3(6.0, 2.2, 6.0), Color("dfe6ee"))

	var rack := WeaponRack.new()
	rack.name = "WeaponRack"
	rack.position = Vector3(0.0, 0.0, 16.0)
	add_child(rack)

	# 3-chapter structure: the judge is a sibling of Players, not a child of a
	# player. Every peer carries it so the intent path resolves on both ends;
	# only the server peer rules on anything.
	var authority := ServerAuthority.new()
	authority.name = "ServerAuthority"
	add_child(authority)

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
	if Net.auto_only == "B-a":
		var checks := preload("res://scripts/tests/ba_checks.gd").new()
		checks.name = "BaChecks"
		# Lives through the host-disconnect scene change to verify cleanup.
		get_tree().root.add_child(checks)
		checks.run(self)
		return
	if Net.auto_only == "B-b":
		var bb := preload("res://scripts/tests/bb_checks.gd").new()
		bb.name = "BbChecks"
		get_tree().root.add_child(bb)
		bb.run(self)
		return
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

	if Net.auto_only != "":
		# One stage on its own, for iterating. The full suite is the default.
		if multiplayer.is_server():
			if Net.auto_only == "audit":
				await _run_audit(local)
			elif Net.auto_only == "8":
				await _run_stage8_checks(local)
			elif Net.auto_only == "7":
				await _run_stage7_checks(local)
			elif Net.auto_only == "6":
				await _run_stage6_checks(local)
			elif Net.auto_only == "2":
				await _run_stage2_checks(local)
		else:
			await _client_support(local)
		return

	# The view must not change angle between standing and moving.
	var idle_rotation := local.camera.rotation
	var idle_forward := local.camera.get_camera_flat_forward()

	# North of the gap lanes. With nav bridges in place a leg that reaches the
	# plaza's south edge walks the body off it and the rest of the run happens
	# on a corpse.
	var home := await _settle(local, Vector3(0.0, 1.0, 11.0))
	var travelled := 0.0
	var remote_travelled := 0.0
	var previous := home
	var remote_previous := remote.global_position if remote != null else Vector3.ZERO
	for leg in range(6):
		local.movement.set_target(home + Vector3(0.0, 0.0, 4.0 if leg % 2 == 0 else 0.0))
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

	# Every gap is bridged for pathfinding, so a click across one is a valid
	# order and the body walks out over the edge and falls. That is the asked
	# for behaviour, so what is checked is that it leaves the plaza and that
	# falling resolves itself rather than wedging the body somewhere.
	local.global_position = Vector3(-15.0, 1.0, 0.0)
	await get_tree().create_timer(0.6).timeout
	local.movement.set_target(Vector3(-15.0, 0.0, -6.0))
	await get_tree().create_timer(3.0).timeout
	print("PLAYGROUND_SMOKE_GAP peer=%d walked_off=%s y=%.2f state=%s" % [
		multiplayer.get_unique_id(), local.global_position.z < -2.0,
		local.global_position.y, Player.State.keys()[local.state]])
	await _settle(local, Vector3(0.0, 1.0, 11.0))

	# A held right button re-issues the order ten times a second. The state must
	# not flicker and the body must not stall between the queries.
	# Far enough that the whole window is travel: measuring past the arrival
	# would just be counting the time spent standing still.
	await _settle(local, Vector3(1.5, 1.0, 16.0))
	var flips := 0
	var last_state := local.state
	var stalls := 0
	var drag_target := Vector3(1.5, 0.0, 2.0)
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
	# Aimed at our own feet, which is how a jump straight up is asked for now
	# that the jump follows the cursor. Headless has no cursor at all, so every
	# check that jumps has to say where it is aiming.
	local.movement.set_aim_override(local.global_position)
	local.movement.request_jump()
	await get_tree().create_timer(0.35).timeout
	var jump_during := OcclusionFader.faded_rids().size()
	local.movement.set_aim_override(Vector3.INF)
	await get_tree().create_timer(1.2).timeout
	print("PLAYGROUND_SMOKE_FADE north_of_walls=%d south_of_walls=%d jump_before=%d jump_during=%d" % [
		faded_behind, faded_in_front, jump_before, jump_during])

	if multiplayer.is_server():
		await _run_stage2_checks(local)
		await _run_stage5_checks(local)
		await _run_stage4_checks(local)
		await _run_weapon_rack_check(local)
		await _run_stage3_checks(local)
		await _run_jump_toggle_check(local)
		await _run_stage6_checks(local)
		await _run_respawn_checks(local)
		await _run_stage8_checks(local)
		await _run_stage7_checks(local)
		# Long enough that the other process has really gone, not merely queued.
		await get_tree().create_timer(9.0).timeout
		print("PLAYGROUND_SMOKE_AFTER_LEAVE players=%d" % _players_root.get_child_count())
	else:
		await _client_support(local)


# Stage 2 gates. Each one is the outcome the work order asks for, measured
# rather than argued from the numbers.
# Cursor aimed jumps, and the deadzone that asks for a vertical one.
func _run_jump_toggle_check(local: Player) -> void:
	await _settle(local, Vector3(0.0, 1.0, 11.0))
	local.movement.set_aim_override(local.global_position)
	var start := local.global_position
	local.movement.request_jump()
	await get_tree().create_timer(1.2).timeout
	var on_self := _flat(local.global_position - start)
	await _settle(local, Vector3(0.0, 1.0, 11.0))
	start = local.global_position
	local.movement.set_aim_override(start + Vector3(5.0, 0.0, 0.0))
	local.movement.request_jump()
	await get_tree().create_timer(1.2).timeout
	print("PLAYGROUND_JUMP_CURSOR on_self_drift=%.2f aimed_travel=%.2f aimed_x=%.2f" % [
		on_self, _flat(local.global_position - start), local.global_position.x - start.x])
	local.movement.set_aim_override(Vector3.INF)


func _run_stage5_checks(local: Player) -> void:
	var dummy := get_node_or_null("Dummy_0") as Dummy
	if dummy == null:
		print("PLAYGROUND_STAGE5 no_dummy")
		return
	var spot := dummy.global_position + Vector3(0.0, 0.0, 1.2)
	await _settle(local, Vector3(spot.x, 1.0, spot.z))
	local.movement.set_aim_override(dummy.global_position)
	var before_hp := dummy.hp
	var before_position := dummy.global_position
	var hits := local.movement.shove()
	await get_tree().create_timer(0.8).timeout
	print("PLAYGROUND_STAGE5_SHOVE hits=%d moved=%.2f hp=%.0f-%.0f" % [
		hits, _flat(dummy.global_position - before_position), before_hp, dummy.hp])

	print("PLAYGROUND_STAGE5_COOLDOWN immediate=%d" % local.movement.shove())
	await get_tree().create_timer(Tuning.values.shove_stun_time + 0.8).timeout

	# Stronger arms throw it further: that is the formula doing its job.
	await _settle(local, Vector3(spot.x, 1.0, spot.z))
	local.movement.set_aim_override(dummy.global_position)
	local.stats.strength = 30.0
	before_position = dummy.global_position
	local.movement.shove()
	await get_tree().create_timer(0.8).timeout
	print("PLAYGROUND_STAGE5_STRENGTH moved=%.2f" % _flat(dummy.global_position - before_position))
	local.stats.strength = 10.0
	local.movement.set_aim_override(Vector3.INF)
	await get_tree().create_timer(3.5).timeout
	print("PLAYGROUND_STAGE5_RETURN home_distance=%.2f hp=%.0f" % [
		_flat(dummy.global_position - dummy.home), dummy.hp])

	# A push onto a body standing on the ground: moved, hurt, and stunned.
	await _settle(local, Vector3(0.0, 1.0, 11.0))
	var hp_before := local.hp
	var ally_push := ForceSystem.make_event(
		ForceSystem.Kind.SHOVE, Vector3(1.0, 0.25, 0.0).normalized(),
		Tuning.values.shove_power, 10.0, 1, true,
		Tuning.values.shove_damage, Tuning.values.shove_stun_time)
	ForceSystem.send(local, ally_push)
	await get_tree().physics_frame
	print("PLAYGROUND_STAGE5_GROUND state=%s hp=%.0f-%.0f speed=%.2f" % [
		Player.State.keys()[local.state], hp_before, local.hp,
		Vector2(local.velocity.x, local.velocity.z).length()])
	await get_tree().create_timer(2.0).timeout

	# The same push on a body already in the air: the arc bends and it costs
	# nothing, which is what makes helping a team mate across possible.
	await _settle(local, Vector3(0.0, 1.0, 11.0))
	local.movement.set_aim_override(local.global_position)
	local.movement.request_jump()
	await get_tree().create_timer(0.3).timeout
	hp_before = local.hp
	var before_speed := Vector2(local.velocity.x, local.velocity.z).length()
	ForceSystem.send(local, ally_push)
	await get_tree().physics_frame
	print("PLAYGROUND_STAGE5_AIR state=%s hp=%.0f-%.0f speed=%.2f-%.2f" % [
		Player.State.keys()[local.state], hp_before, local.hp,
		before_speed, Vector2(local.velocity.x, local.velocity.z).length()])
	local.movement.set_aim_override(Vector3.INF)
	await get_tree().create_timer(2.0).timeout


func _run_stage4_checks(local: Player) -> void:
	# Front facing wall A: free movement on the face.
	# Ring wall at 0 degrees: its face points straight at the camera.
	var front_face := CLIMB_RING_CENTRE + Vector3(0.0, 1.5, CLIMB_RING_RADIUS + 0.3)
	var attached := await _attach_to(local, front_face, Vector3(0.0, 0.0, 1.0), front_face + Vector3(0.0, -0.5, 2.0))
	print("PLAYGROUND_STAGE4_ATTACH attached=%s state=%s" % [
		attached, Player.State.keys()[local.state]])
	if attached:
		var before := local.global_position
		local.climb.set_wall_target(front_face + Vector3(1.2, 2.5, 0.0))
		await get_tree().create_timer(2.0).timeout
		print("PLAYGROUND_STAGE4_FRONT rose=%.2f sideways=%.2f stamina=%.0f" % [
			local.global_position.y - before.y,
			absf(local.global_position.x - before.x), local.stamina])
		local.climb.detach()
		await get_tree().create_timer(1.2).timeout
		print("PLAYGROUND_STAGE4_DETACH state=%s" % Player.State.keys()[local.state])

	# Side facing wall B: vertical only.
	# Ring wall at 45 degrees: the most slanted face the map still has.
	var slant := Vector3(sin(deg_to_rad(45.0)), 0.0, cos(deg_to_rad(45.0)))
	var side_face := CLIMB_RING_CENTRE + slant * (CLIMB_RING_RADIUS + 0.3) + Vector3.UP * 1.5
	var side := await _attach_to(local, side_face, slant, side_face + slant * 2.0 - Vector3.UP * 0.5)
	if side:
		var before := local.global_position
		await get_tree().create_timer(2.0).timeout
		# Aiming at a chosen height on a side face has to land near it, not
		# metres away: that plane is edge on to the camera.
		var errors := PackedStringArray()
		for wanted_y in [1.5, 3.0, 5.0]:
			var aim_point := Vector3(side_face.x, wanted_y, side_face.z)
			var origin := local.camera.camera.global_position
			local.climb.aim_at(origin, (aim_point - origin).normalized())
			errors.append("%.1f→%.2f" % [wanted_y, local.climb.wall_target().y])
		print("PLAYGROUND_STAGE4_AIM %s" % " ".join(errors))
		local.climb.set_wall_target(side_face + Vector3.UP * 2.5)
		await get_tree().create_timer(2.0).timeout
		print("PLAYGROUND_STAGE4_DIAGONAL rose=%.2f sideways=%.2f" % [
			local.global_position.y - before.y,
			absf(local.global_position.z - before.z)])
		local.climb.detach()
		await get_tree().create_timer(1.2).timeout
	else:
		print("PLAYGROUND_STAGE4_SIDE attach_failed")

	# Jumping at a climbable wall and pressing jump again while touching it
	# takes hold, and hanging there drains stamina without an entry fee.
	await _settle(local, front_face + Vector3(0.0, -0.5, 2.0))
	local.global_position = front_face + Vector3(0.0, 2.5, 2.3)
	local.velocity = Vector3(0.0, 0.0, -4.0)
	local.change_state(Player.State.AIRBORNE)
	# Let coyote time lapse first. Pressed inside it, the key is still a jump,
	# which is correct and not what this check is about.
	await get_tree().create_timer(0.25).timeout
	# Pressed once, early, the way a player would: the buffer and the probe
	# have to find the wall, not the press.
	local.movement.request_jump()
	var caught := false
	var stamina_at_catch := 0.0
	for _tick in range(90):
		await get_tree().physics_frame
		if local.climb.is_climbing():
			caught = true
			stamina_at_catch = local.stamina
			break
	await get_tree().create_timer(1.0).timeout
	print("PLAYGROUND_STAGE4_AIRCATCH caught=%s state=%s stamina_at_catch=%.0f after_1s=%.0f" % [
		caught, Player.State.keys()[local.state], stamina_at_catch, local.stamina])
	if caught:
		local.climb.detach()
		await get_tree().create_timer(1.2).timeout

	# Running out of stamina drops you off the wall.
	var tired := await _attach_to(local, front_face, Vector3(0.0, 0.0, 1.0), front_face + Vector3(0.0, -0.5, 2.0))
	if tired:
		local.stamina = 8.0
		local.climb.set_wall_target(front_face + Vector3(0.0, 4.0, 0.0))
		await get_tree().create_timer(1.2).timeout
		print("PLAYGROUND_STAGE4_STAMINA stamina=%.0f state=%s" % [
			local.stamina, Player.State.keys()[local.state]])
		await get_tree().create_timer(1.5).timeout

	# A smooth wall refuses.
	var smooth := get_node_or_null("NavigationRegion3D/SmoothWall") as CollisionObject3D
	print("PLAYGROUND_STAGE4_SMOOTH attached=%s" % [
		local.climb.attach(smooth, Vector3(16.0, 2.0, 2.3), Vector3(0.0, 0.0, 1.0)) if smooth != null else "no_wall"])

	# Climbing to the top steps onto it.
	var top := await _attach_to(local, front_face, Vector3(0.0, 0.0, 1.0), front_face + Vector3(0.0, -0.5, 2.0))
	if top:
		local.climb.set_wall_target(front_face + Vector3(0.0, 4.4, 0.0))
		await get_tree().create_timer(5.0).timeout
		print("PLAYGROUND_STAGE4_MANTLE y=%.2f state=%s stamina=%.0f" % [
			local.global_position.y, Player.State.keys()[local.state], local.stamina])


func _attach_to(local: Player, contact: Vector3, normal: Vector3, stand: Vector3) -> bool:
	await _settle(local, stand)
	var wall := _wall_at(contact, normal)
	if wall == null:
		return false
	local.movement.order_climb(wall, contact, normal)
	var waited := 0.0
	while waited < 4.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		if local.climb.is_climbing():
			return true
	print("PLAYGROUND_STAGE4_NOATTACH distance=%.2f limit=%.2f" % [
		local.movement.climb_request_distance(), Tuning.values.climb_attach_distance])
	return false


func _wall_at(contact: Vector3, normal: Vector3) -> CollisionObject3D:
	var from := contact + normal * 1.5
	var query := PhysicsRayQueryParameters3D.create(from, contact - normal * 0.5, CLIMBABLE_LAYER | WALL_LAYER)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	return hit.get("collider") as CollisionObject3D if not hit.is_empty() else null


func _run_weapon_rack_check(local: Player) -> void:
	var rack := get_node_or_null("WeaponRack") as Node3D
	if rack == null:
		print("PLAYGROUND_RACK missing")
		return
	var picked := PackedStringArray()
	for index in range(5):
		var lane := rack.global_position + Vector3((float(index) - 2.0) * WeaponRack.SPACING, 1.0, -3.0)
		await _settle(local, lane)
		local.movement.set_target(rack.global_position + Vector3((float(index) - 2.0) * WeaponRack.SPACING, 0.0, 0.0))
		await get_tree().create_timer(1.6).timeout
		# Standing on it is not enough any more; the key is what equips.
		var before := local.weapon
		var took: bool = (rack as WeaponRack).interact(local)
		picked.append("%d:%s%s" % [
			index,
			WeaponKinds.LABELS.get(local.weapon, "?"),
			"" if took and before != local.weapon else "(미변경)"])
	print("PLAYGROUND_RACK picked=[%s] held_node=%s" % [
		", ".join(picked), local.has_node("Visual/HeldWeapon")])


func _run_stage3_checks(local: Player) -> void:
	await _settle(local, Vector3(0.0, 1.0, 11.0))
	var start := local.global_position
	var aim := local.movement.cursor_direction()
	var went := local.movement.request_dash()
	# Refused mid dash, and a jump pressed during one is ignored.
	var second := local.movement.request_dash()
	local.movement.request_jump()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var jumped := local.velocity.y > 1.0
	await get_tree().create_timer(0.8).timeout
	print("PLAYGROUND_STAGE3_DASH went=%s distance=%.2f heading_match=%.2f second=%s jumped=%s state=%s" % [
		went, _flat(local.global_position - start),
		aim.dot((local.global_position - start).normalized()),
		second, jumped, Player.State.keys()[local.state]])

	# Cooldown: still refused a moment later, allowed once it has run out.
	var during_cooldown := local.movement.request_dash()
	await get_tree().create_timer(Tuning.values.dash_cooldown + 0.2).timeout
	var after_cooldown := local.movement.request_dash()
	await get_tree().create_timer(0.6).timeout
	print("PLAYGROUND_STAGE3_COOLDOWN during=%s after=%s" % [during_cooldown, after_cooldown])

	# In the air it does not go at all.
	await _settle(local, Vector3(0.0, 4.0, 11.0))
	local.global_position = Vector3(0.0, 6.0, 11.0)
	await get_tree().physics_frame
	await get_tree().physics_frame
	print("PLAYGROUND_STAGE3_AIR state=%s went=%s" % [
		Player.State.keys()[local.state], local.movement.request_dash()])

	# A wall stops it where it hits, not four metres on.
	await _settle(local, Vector3(0.0, 1.0, 11.0))
	var blocker := StaticBody3D.new()
	blocker.name = "DashBlocker"
	blocker.position = local.global_position + aim * 2.5
	blocker.collision_layer = WALL_LAYER
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(4.0, 3.0, 0.6)
	shape.size = Vector3(4.0, 3.0, 0.6) if absf(aim.z) > absf(aim.x) else Vector3(0.6, 3.0, 4.0)
	collision.shape = shape
	blocker.add_child(collision)
	add_child(blocker)
	await get_tree().physics_frame
	var wall_start := local.global_position
	local.movement.request_dash()
	await get_tree().create_timer(0.6).timeout
	print("PLAYGROUND_STAGE3_WALL distance=%.2f state=%s" % [
		_flat(local.global_position - wall_start), Player.State.keys()[local.state]])
	blocker.queue_free()


# Stage 6 gates. Every height is dropped and measured, never computed: the
# damage has to come out of the same tracking the game uses in play.
func _run_stage6_checks(local: Player) -> void:
	for height in [5.0, 3.5]:
		var drop := await _drop_from(local, height)
		print("PLAYGROUND_STAGE6_DROP asked=%.1f measured=%.2f hp=%.0f-%.0f damage=%.1f" % [
			height, drop["fall"], drop["before"], drop["after"], drop["before"] - drop["after"]])

	# The debug flag turns it off, which is the condition the work order asks
	# for: the same drop that hurt a moment ago now costs nothing.
	Tuning.values.fall_damage_enabled = false
	var disabled := await _drop_from(local, 5.0)
	Tuning.values.fall_damage_enabled = true
	print("PLAYGROUND_STAGE6_DISABLED measured=%.2f damage=%.1f" % [
		disabled["fall"], disabled["before"] - disabled["after"]])

	# Launched by a team mate rather than by our own jump: the push costs no
	# damage, the landing does.
	await _settle(local, Vector3(0.0, 1.0, 11.0))
	local.hp = local.stats.max_hp
	var before_hp := local.hp
	ForceSystem.send(local, ForceSystem.make_event(
		ForceSystem.Kind.THROW, Vector3.UP, 18.0, 0.0, 1, true, 0.0, 0.0))
	await get_tree().physics_frame
	var after_launch := local.hp
	var waited := 0.0
	var peak := local.global_position.y
	while waited < 4.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		peak = maxf(peak, local.global_position.y)
		if local.is_grounded_state():
			break
	print("PLAYGROUND_STAGE6_THROWN peak=%.2f hp=%.0f-%.0f-%.0f fall=%.2f" % [
		peak, before_hp, after_launch, local.hp, local.last_fall_height])
	local.hp = local.stats.max_hp


# Placed in the air over the plaza and left to fall. A jump cannot be used to
# measure a known height, because its own apex goes into the total.
func _drop_from(local: Player, height: float) -> Dictionary:
	await _settle(local, Vector3(0.0, 1.0, 11.0))
	local.hp = local.stats.max_hp
	var before := local.hp
	local.global_position = Vector3(0.0, 0.9 + height, 11.0)
	local.velocity = Vector3.ZERO
	local.floor_snap_length = 0.0
	local.change_state(Player.State.AIRBORNE)
	var waited := 0.0
	while waited < 4.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		if local.is_grounded_state():
			break
	return {"before": before, "after": local.hp, "fall": local.last_fall_height}


func _run_respawn_checks(local: Player) -> void:
	# Falling past the kill plane kills and brings the body back on its own.
	await _settle(local, Vector3(0.0, 1.0, 8.0))
	local.global_position = Vector3(0.0, Tuning.values.kill_plane_y - 2.0, 8.0)
	await get_tree().create_timer(0.3).timeout
	var died := local.state == Player.State.DEAD
	await get_tree().create_timer(Tuning.values.respawn_delay + 0.8).timeout
	print("PLAYGROUND_FALL died=%s back_home=%.2f state=%s" % [
		died, _distance_to_a_spawn(local), Player.State.keys()[local.state]])

	# R restarts from anywhere, without having to fall first.
	await _settle(local, Vector3(-12.0, 1.0, 4.0))
	local.respawn()
	await get_tree().create_timer(0.5).timeout
	print("PLAYGROUND_RESTART back_home=%.2f state=%s" % [
		_distance_to_a_spawn(local), Player.State.keys()[local.state]])


# A respawn now picks whichever mark is free, so the check asks how far the body
# is from a mark rather than from one particular mark.
func _distance_to_a_spawn(local: Player) -> float:
	var best := INF
	for point in spawn_points:
		best = minf(best, local.global_position.distance_to(point))
	return best


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

	# Standing jump: straight up, and as high as the formula says. Aimed at our
	# own feet, which is what asks for a vertical one.
	var start := await _settle(local, Vector3(1.5, 1.0, 8.0))
	local.movement.set_aim_override(local.global_position)
	local.movement.request_jump()
	var peak := start.y
	var airborne := 0.0
	while airborne < 1.4:
		await get_tree().physics_frame
		airborne += get_physics_process_delta_time()
		peak = maxf(peak, local.global_position.y)
	local.movement.set_aim_override(Vector3.INF)
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
	local.movement.set_aim_override(local.global_position)
	local.movement.request_jump()
	await get_tree().physics_frame
	await get_tree().physics_frame
	local.movement.set_aim_override(Vector3.INF)
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
	# Where the run is heading, well out in front: the cursor decides a jump's
	# direction now, and aiming at a target the body has nearly reached puts the
	# cursor inside the deadzone, which asks for a vertical jump and throws the
	# run up speed away.
	var heading := Vector3(local.velocity.x, 0.0, local.velocity.z)
	if heading.length() > 0.1:
		local.movement.set_aim_override(local.global_position + heading.normalized() * 6.0)
	else:
		local.movement.set_aim_override(Vector3(target.x, local.global_position.y, target.z))
	local.movement.request_jump()
	await get_tree().physics_frame
	await get_tree().physics_frame
	local.movement.set_aim_override(Vector3.INF)
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
	local.movement.set_aim_override(Vector3(target.x, local.global_position.y, target.z))
	local.movement.request_jump()
	await get_tree().physics_frame
	await get_tree().physics_frame
	local.movement.set_aim_override(Vector3.INF)
	await get_tree().create_timer(2.5).timeout
	return local.global_position


# Stage 8 gates. The seam is mostly something to look at, so what gets measured
# is the geometry under the look and the two ways over it: climbing the cut
# face, and being thrown onto it. The looking itself is the user's call.
func _run_stage8_checks(local: Player) -> void:
	if _boundary == null:
		print("PLAYGROUND_STAGE8 missing_boundary")
		return
	var seam_x := TimeBoundary.SEAM.x
	var face_z := _boundary.face_z()
	var space := get_world_3d().direct_space_state

	# 8-1: the two grounds at the heights the work order asks for, sampled
	# across the width rather than at one spot, and no crack at the join. A ray
	# dropped just behind the face has to land on the sand at 3 m: anything
	# lower is a gap the seam would show daylight through.
	var grass_tops := PackedStringArray()
	var sand_tops := PackedStringArray()
	var worst_seam := 0.0
	for offset in [-9.0, -4.0, 1.0, 6.0, 9.0]:
		var x: float = seam_x + offset
		grass_tops.append("%.2f" % _ground_y(space, Vector3(x, 6.0, face_z + 2.0)))
		sand_tops.append("%.2f" % _ground_y(space, Vector3(x, 6.0, face_z - 3.0)))
		var at_seam := _ground_y(space, Vector3(x, 6.0, face_z - 0.05))
		worst_seam = maxf(worst_seam, absf(at_seam - TimeBoundary.TOP_Y))
	print("PLAYGROUND_STAGE8_GEOM grass=[%s] sand=[%s] seam_error=%.3f" % [
		", ".join(grass_tops), ", ".join(sand_tops), worst_seam])

	# The face itself: what a click from the grass side would meet first, and
	# on which layer. Climbable is the gate; anything else and the seam is
	# scenery you cannot get over.
	var probe := PhysicsRayQueryParameters3D.create(
		Vector3(seam_x, 1.5, face_z + 3.0),
		Vector3(seam_x, 1.5, face_z - 1.0),
		WORLD_LAYER | WALL_LAYER | CLIMBABLE_LAYER)
	var hit := space.intersect_ray(probe)
	var face_body := hit.get("collider") as CollisionObject3D
	print("PLAYGROUND_STAGE8_FACE hit=%s layer=%d climbable=%s at_z=%.2f" % [
		face_body.name if face_body != null else "none",
		face_body.collision_layer if face_body != null else 0,
		face_body != null and (face_body.collision_layer & CLIMBABLE_LAYER) != 0,
		(hit["position"] as Vector3).z if not hit.is_empty() else 0.0])

	# 8-2: a jump does not get you up it. This is the whole point of the gate.
	var stand := Vector3(seam_x, 1.0, face_z + 1.2)
	await _settle(local, stand)
	local.movement.set_aim_override(Vector3(seam_x, local.global_position.y, face_z - 2.0))
	local.movement.request_jump()
	var peak := local.global_position.y
	for _tick in range(150):
		await get_tree().physics_frame
		peak = maxf(peak, local.global_position.y)
	local.movement.set_aim_override(Vector3.INF)
	print("PLAYGROUND_STAGE8_JUMPGATE peak_y=%.2f top_y=%.2f over=%s rested_y=%.2f" % [
		peak, TimeBoundary.TOP_Y, peak > TimeBoundary.TOP_Y + Player.BODY_HALF_HEIGHT,
		local.global_position.y])

	# 8-3: climbing it puts you on the sand.
	var contact := Vector3(seam_x, 1.2, face_z)
	var attached := await _attach_to(local, contact, Vector3(0.0, 0.0, 1.0), Vector3(seam_x, 1.0, face_z + 1.6))
	if attached:
		local.climb.set_wall_target(Vector3(seam_x, TimeBoundary.TOP_Y + 0.6, face_z))
		await get_tree().create_timer(5.0).timeout
		print("PLAYGROUND_STAGE8_CLIMB y=%.2f z=%.2f state=%s stamina=%.0f on_top=%s" % [
			local.global_position.y, local.global_position.z,
			Player.State.keys()[local.state], local.stamina,
			local.global_position.y > TimeBoundary.TOP_Y + Player.BODY_HALF_HEIGHT - 0.2])
	else:
		print("PLAYGROUND_STAGE8_CLIMB attach_failed")
	await _settle(local, Vector3(seam_x, 1.0, face_z + 4.0))

	await _run_stage8_throw(local, face_z)


# Being thrown onto the sand. The throw does not have to clear the lip for the
# gate to be good, but who can and who cannot is worth knowing, so this sweeps
# the thrower's strength against a 10 kg team mate.
#
# The stand off distance is the throw's own apex distance, worked out from the
# same numbers the throw uses, so each attempt is the best one that strength
# can make rather than an arbitrary spot that happens to fail.
func _run_stage8_throw(local: Player, face_z: float) -> void:
	var remote: Player = null
	for child in _players_root.get_children():
		var player := child as Player
		if player != null and not player.is_local():
			remote = player
	if remote == null:
		print("PLAYGROUND_STAGE8_THROW no_remote_peer")
		return

	var angle := deg_to_rad(Tuning.values.throw_up_angle_deg)
	# Clearing the lip means the body's centre, not its feet.
	var wanted := TimeBoundary.TOP_Y + Player.BODY_HALF_HEIGHT
	var was_strength: float = local.stats.strength
	var mate_weight := 10.0
	set_remote_weight.rpc_id(String(remote.name).to_int(), mate_weight)
	# 10 is the default and fails; 18 is where the arithmetic says it starts to
	# work; 25 is past the point where ratio_mult_max caps the multiplier, so it
	# is also the best throw the game can produce at all.
	for strength in [10.0, 18.0, 25.0]:
		local.stats.strength = strength
		var mult: float = Tuning.ratio_mult(strength / mate_weight, Tuning.values.ratio_k_jump)
		var speed: float = Tuning.values.throw_power * mult
		var rise := speed * sin(angle)
		var apex_at := speed * cos(angle) * (rise / Tuning.values.gravity)
		await get_tree().create_timer(0.5).timeout
		var lane := Vector3(TimeBoundary.SEAM.x, 1.0, face_z + apex_at)
		if not await _grab_remote(local, remote, lane):
			print("PLAYGROUND_STAGE8_THROW grab_failed strength=%.0f" % strength)
			continue
		await get_tree().create_timer(0.4).timeout
		# Read from the hand that is about to let go, so the predicted apex is
		# a world height and can be put beside the lip it has to clear.
		var apex: float = local.hand_position().y + rise * rise / (2.0 * Tuning.values.gravity)
		local.movement.set_aim_override(local.global_position + Vector3(0.0, 0.0, -20.0))
		local.movement.interact()
		await get_tree().create_timer(3.0).timeout
		local.movement.set_aim_override(Vector3.INF)
		print("PLAYGROUND_STAGE8_THROW strength=%.0f mate=%.0fkg mult=%.2f speed=%.1f stand_off=%.2f predicted_apex=%.2f needed=%.2f landed_y=%.2f landed_z=%.2f on_top=%s" % [
			strength, mate_weight, mult, speed, apex_at, apex, wanted,
			remote.global_position.y, remote.global_position.z,
			remote.global_position.y > TimeBoundary.TOP_Y])
		await get_tree().create_timer(1.0).timeout
	local.stats.strength = was_strength
	# Parked out on the grass, not in the throwing lane. Stage 7 teleports our
	# own body into that lane to measure rock throws, and a team mate left
	# standing in it is something to land on: the rocks came down on their head
	# and measured 0.3 m.
	place_remote.rpc_id(String(remote.name).to_int(),
		Vector3(TimeBoundary.SEAM.x, 1.0, face_z + 8.0))


# Numbers that have to agree with each other but live in different files.
#
# A diff review cannot catch this class: every file is self consistent, and the
# disagreement only exists between them. Rocks fell at the project's 9.8 while
# every character fell at the tuned 22, and a player and a dummy each left the
# other out of their mask, so they passed through one another. Both read fine
# in isolation. So they get measured instead, in one table, every run.
func _run_audit(local: Player) -> void:
	print("PLAYGROUND_AUDIT_GRAVITY tuned=%.2f project=%.2f" % [
		Tuning.values.gravity,
		float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))])
	for node in get_tree().get_nodes_in_group(Rock.GROUP):
		var rock := node as Rock
		if rock != null:
			print("PLAYGROUND_AUDIT_GRAVITY rock=%s effective=%.2f" % [
				rock.name,
				rock.gravity_scale * float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))])

	# Numbers that are written out twice, in files that do not import each
	# other. They agree today; printed so that the day they stop agreeing is a
	# line in the log rather than a thing someone notices in play.
	print("PLAYGROUND_AUDIT_SHARED hold_grace rock=%.2f grab=%.2f | state_interval rock=%.2f dummy=%.2f | dummy_weight=%.1f" % [
		Rock.HOLD_GRACE, PlayerGrab.HOLD_GRACE,
		Rock.STATE_INTERVAL, Dummy.STATE_INTERVAL,
		Dummy.MAX_HP * 0.2])

	# Everything that can be stood on, pushed or thrown, with what it collides
	# with. A pair that appears in neither mask passes through.
	var bodies: Array[CollisionObject3D] = []
	_collect_bodies(self, bodies)
	var moving: Array[CollisionObject3D] = []
	for body in bodies:
		var layer := body.collision_layer
		print("PLAYGROUND_AUDIT_BODY name=%s type=%s layer=%d mask=%d" % [
			body.name, body.get_class(), layer, body.collision_mask])
		if body is CharacterBody3D or body is RigidBody3D:
			moving.append(body)

	for index in moving.size():
		for other_index in range(index + 1, moving.size()):
			var a := moving[index]
			var b := moving[other_index]
			# Godot needs the pair in one direction only, so this is a miss
			# exactly when neither side knows about the other.
			if (a.collision_mask & b.collision_layer) == 0 and (b.collision_mask & a.collision_layer) == 0:
				print("PLAYGROUND_AUDIT_PASSTHROUGH %s(%d/%d) <-> %s(%d/%d)" % [
					a.name, a.collision_layer, a.collision_mask,
					b.name, b.collision_layer, b.collision_mask])

	# And the same thing measured rather than read off the masks: walk into a
	# dummy and see whether it stops us.
	var dummy := get_node_or_null("Dummy_0") as Dummy
	if dummy == null:
		return
	var approach := dummy.global_position + Vector3(0.0, 0.0, 3.0)
	await _settle(local, Vector3(approach.x, 1.0, approach.z))
	local.movement.set_target(dummy.global_position + Vector3(0.0, 0.0, -1.5))
	var closest := INF
	var waited := 0.0
	while waited < 4.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		closest = minf(closest, _flat(local.global_position - dummy.global_position))
	# Two capsules of radius 0.4 cannot be closer than 0.8 apart if they are
	# solid to each other.
	print("PLAYGROUND_AUDIT_WALKINTO closest=%.2f solid_at=%.2f passed_through=%s dummy_moved=%.2f" % [
		closest, Player.BODY_RADIUS * 2.0, closest < Player.BODY_RADIUS * 2.0 - 0.05,
		_flat(dummy.global_position - dummy.home)])
	local.movement.cancel_target()


func _collect_bodies(node: Node, into: Array[CollisionObject3D]) -> void:
	for child in node.get_children():
		var body := child as CollisionObject3D
		if body != null:
			into.append(body)
		_collect_bodies(child, into)


func _ground_y(space: PhysicsDirectSpaceState3D, from: Vector3) -> float:
	var query := PhysicsRayQueryParameters3D.create(
		from, from + Vector3.DOWN * 12.0, WORLD_LAYER | CLIMBABLE_LAYER)
	var hit := space.intersect_ray(query)
	return (hit["position"] as Vector3).y if not hit.is_empty() else -99.0


# Stage 7 gates. The rock half runs on the host alone; the team mate half needs
# the second peer, which co-operates from _client_support.
func _run_stage7_checks(local: Player) -> void:
	# Each rock is picked up where it lies, then carried to the measuring lane
	# and thrown. Measured in the lane rather than on the spot because a throw
	# from where the rocks stand runs out of plaza and the rock rolls off the
	# west edge, and a rock falling through the void covers ground forever.
	for index in 3:
		var rock := get_node_or_null("Rock_%d" % index) as Rock
		if rock == null:
			continue
		var spot := rock.global_position
		await _settle(local, Vector3(spot.x, 1.0, spot.z + 1.1))
		local.movement.set_aim_override(rock.global_position)
		var picked := local.movement.interact()
		var carrying := local.state == Player.State.GRABBING
		local.global_position = THROW_LANE
		await get_tree().physics_frame
		await get_tree().physics_frame
		# Aimed east down the open lane: 20 m of clear plaza, no wall and no
		# edge in the way.
		local.movement.set_aim_override(THROW_LANE + Vector3(20.0, 0.0, 0.0))
		var from := local.global_position
		var thrown := local.movement.interact()
		await get_tree().create_timer(2.5).timeout
		print("PLAYGROUND_STAGE7_ROCK weight=%.0f picked=%s carrying=%s thrown=%s flew=%.2f landed_y=%.2f" % [
			rock.weight, picked, carrying, thrown,
			_flat(rock.global_position - from), rock.global_position.y])
		local.movement.set_aim_override(Vector3.INF)

	# A thrown rock that lands on a dummy pushes it and hurts it.
	var dummy := get_node_or_null("Dummy_0") as Dummy
	var rock_0 := get_node_or_null("Rock_0") as Rock
	if dummy != null and rock_0 != null:
		# Five metres back. The hand is 2.6 m up and a dummy is 1.9 m tall, so a
		# flat throw needs enough distance to come down into it and not so much
		# that it lands short. This distance is a function of gravity: it was
		# nine metres while rocks were still falling at the project's 9.8, and
		# at nine metres under the tuned 22 the rock now lands in front of it.
		await _settle(local, Vector3(dummy.global_position.x, 1.0, dummy.global_position.z + 5.0))
		# Brought to hand rather than walked to: the throw is what is under test.
		rock_0.host_grab(1)
		local.grab.on_rock_answer(rock_0, true)
		for _frame in range(6):
			await get_tree().physics_frame
		print("PLAYGROUND_STAGE7_INHAND gap=%.2f" % rock_0.global_position.distance_to(local.hand_position()))
		local.movement.set_aim_override(dummy.global_position)
		# Thrown flat for this one check: at the documented 35 degrees a rock
		# aimed from three metres passes clean over a 1.8 m dummy, which would
		# measure the arc rather than the hit.
		var angle_was: float = Tuning.values.throw_up_angle_deg
		Tuning.values.throw_up_angle_deg = 0.0
		var dummy_hp := dummy.hp
		var dummy_at := dummy.global_position
		local.movement.interact()
		# Watched all the way in: a miss and a hit that does nothing look the
		# same in the result, and they are not the same problem.
		var closest := INF
		var sampled := 0.0
		var pushed := 0.0
		while sampled < 1.5:
			await get_tree().physics_frame
			sampled += get_physics_process_delta_time()
			closest = minf(closest, rock_0.global_position.distance_to(dummy.global_position))
			pushed = maxf(pushed, _flat(dummy.global_position - dummy_at))
		Tuning.values.throw_up_angle_deg = angle_was
		print("PLAYGROUND_STAGE7_ROCKPATH closest=%.2f rock_y=%.2f rock_at=(%.1f, %.1f)" % [
			closest, rock_0.global_position.y, rock_0.global_position.x, rock_0.global_position.z])
		print("PLAYGROUND_STAGE7_ROCKHIT hp=%.0f-%.0f moved=%.2f" % [dummy_hp, dummy.hp, pushed])
		local.movement.set_aim_override(Vector3.INF)
		await get_tree().create_timer(3.5).timeout

	# Carrying costs speed, and a carried rock cannot be jumped with.
	var rock_1 := get_node_or_null("Rock_1") as Rock
	if rock_1 != null:
		await _settle(local, Vector3(0.0, 1.0, 11.0))
		var free_speed := await _travel_for(local, 1.2)
		rock_1.host_grab(1)
		local.grab.on_rock_answer(rock_1, true)
		for _frame in range(6):
			await get_tree().physics_frame
		var carry_speed := await _travel_for(local, 1.2)
		var jump_y := local.global_position.y
		local.movement.set_aim_override(local.global_position)
		local.movement.request_jump()
		await get_tree().create_timer(0.4).timeout
		local.movement.set_aim_override(Vector3.INF)
		print("PLAYGROUND_STAGE7_CARRY free=%.2f carrying=%.2f ratio=%.2f jump_rise=%.2f state=%s" % [
			free_speed, carry_speed, carry_speed / maxf(free_speed, 0.01),
			local.global_position.y - jump_y, Player.State.keys()[local.state]])

		# 7-6: a holder who is stunned drops what it was carrying.
		ForceSystem.send(local, ForceSystem.make_event(
			ForceSystem.Kind.SHOVE, Vector3(1.0, 0.1, 0.0), Tuning.values.shove_power,
			10.0, 1, false, 1.0, Tuning.values.shove_stun_time))
		await get_tree().physics_frame
		print("PLAYGROUND_STAGE7_STUNDROP state=%s holder=%d holding=%s" % [
			Player.State.keys()[local.state], rock_1.holder_peer, local.grab.is_holding()])
		await get_tree().create_timer(Tuning.values.shove_stun_time + 0.8).timeout

		# 7-6: and so does a holder who leaves the ground.
		await _settle(local, Vector3(0.0, 1.0, 11.0))
		rock_1.host_grab(1)
		local.grab.on_rock_answer(rock_1, true)
		for _frame in range(6):
			await get_tree().physics_frame
		local.global_position += Vector3.UP * 2.0
		local.change_state(Player.State.AIRBORNE)
		await get_tree().physics_frame
		print("PLAYGROUND_STAGE7_FALLDROP holder=%d holding=%s" % [
			rock_1.holder_peer, local.grab.is_holding()])
		await get_tree().create_timer(1.5).timeout

		# 7-6: two people reaching for the same rock. The host answers one.
		var other_peer := 0
		for child in _players_root.get_children():
			if String(child.name) != str(multiplayer.get_unique_id()):
				other_peer = String(child.name).to_int()
		var first := rock_1.host_grab(1)
		var second := rock_1.host_grab(other_peer) if other_peer != 0 else false
		print("PLAYGROUND_STAGE7_CONTEST first=%s second=%s holder=%d" % [first, second, rock_1.holder_peer])
		rock_1.host_release(1)
		if local.state == Player.State.GRABBING:
			local.change_state(Player.State.IDLE)

	await _run_stage7_team(local)


# Measured as distance covered, not as a velocity sample: the velocity read back
# from a step is whatever that step left behind.
func _travel_for(local: Player, seconds: float) -> float:
	local.movement.set_target(local.global_position + Vector3(0.0, 0.0, -8.0))
	var previous := local.global_position
	var covered := 0.0
	var waited := 0.0
	while waited < seconds:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		covered += _flat(local.global_position - previous)
		previous = local.global_position
	local.movement.cancel_target()
	return covered / seconds


# The team mate half. Needs the second peer, and says so when there is none.
func _run_stage7_team(local: Player) -> void:
	var remote: Player = null
	for child in _players_root.get_children():
		var player := child as Player
		if player != null and not player.is_local():
			remote = player
	if remote == null:
		print("PLAYGROUND_STAGE7_TEAM no_remote_peer")
		return

	await _run_rock_vs_player(local, remote)

	# Heavier team mate, shorter throw. The weight lives on their machine, so
	# they are asked to set it, and both bodies are placed in the same clear
	# lane each time: the z=8 line is open plaza from the west edge to the east,
	# and a throw that leaves the ground invalidates the measurement.
	var lane := THROW_LANE
	for weight in [10.0, 25.0]:
		set_remote_weight.rpc_id(String(remote.name).to_int(), weight)
		await get_tree().create_timer(0.5).timeout
		if not await _grab_remote(local, remote, lane):
			print("PLAYGROUND_STAGE7_TEAM grab_failed weight=%.0f" % weight)
			continue
		# Read after a moment: the hold is agreed over the network, so the body
		# is not above the hand on the frame the answer arrives.
		await get_tree().create_timer(0.4).timeout
		var held_offset := remote.global_position.y - local.global_position.y
		local.movement.set_aim_override(local.global_position + Vector3(20.0, 0.0, 0.0))
		var from := remote.global_position
		local.movement.interact()
		await get_tree().create_timer(2.5).timeout
		print("PLAYGROUND_STAGE7_TEAMTHROW weight=%.0f held_above=%.2f flew=%.2f landed_y=%.2f state=%s" % [
			weight, held_offset, _flat(remote.global_position - from),
			remote.global_position.y, Player.State.keys()[remote.state]])
		local.movement.set_aim_override(Vector3.INF)
		await get_tree().create_timer(1.5).timeout
	set_remote_weight.rpc_id(String(remote.name).to_int(), 10.0)

	# A thrown team mate is in the air, so a shove bends their arc again.
	if await _grab_remote(local, remote):
		local.movement.set_aim_override(local.global_position + Vector3(20.0, 0.0, 0.0))
		local.movement.interact()
		await get_tree().create_timer(0.35).timeout
		var mid_air := remote.state == Player.State.AIRBORNE
		var before := remote.global_position
		ForceSystem.send(remote, ForceSystem.make_event(
			ForceSystem.Kind.SHOVE, Vector3(1.0, 0.3, 0.0), Tuning.values.shove_power,
			local.stats.strength, 1, true, Tuning.values.shove_damage, 0.0))
		await get_tree().create_timer(1.5).timeout
		print("PLAYGROUND_STAGE7_SECONDPUSH airborne=%s extra=%.2f" % [
			mid_air, _flat(remote.global_position - before)])
		local.movement.set_aim_override(Vector3.INF)
		await get_tree().create_timer(2.0).timeout

	# 7-6: a held body that is pushed comes free and takes the push.
	if await _grab_remote(local, remote):
		ForceSystem.send(remote, ForceSystem.make_event(
			ForceSystem.Kind.SHOVE, Vector3(1.0, 0.3, 0.0), Tuning.values.shove_power,
			local.stats.strength, 1, true, 0.0, 0.0))
		await get_tree().create_timer(0.6).timeout
		print("PLAYGROUND_STAGE7_FORCEFREE remote_state=%s still_holding=%s" % [
			Player.State.keys()[remote.state], local.grab.is_holding()])
		await get_tree().create_timer(1.5).timeout

	# 7-5: Space, five times. The presses happen on their machine.
	if await _grab_remote(local, remote):
		begin_escape_drill.rpc_id(String(remote.name).to_int())
		var waited := 0.0
		while waited < 6.0 and remote.state == Player.State.GRABBED:
			await get_tree().physics_frame
			waited += get_physics_process_delta_time()
		# Read after a moment: the holder's hands are emptied by the same
		# replicated state, which arrives a frame or two later.
		await get_tree().create_timer(0.5).timeout
		print("PLAYGROUND_STAGE7_ESCAPE freed_after=%.2fs state=%s still_holding=%s" % [
			waited, Player.State.keys()[remote.state], local.grab.is_holding()])
		await get_tree().create_timer(1.5).timeout

	# 7-6: the holder disconnects. They take a rock with them and leave; the
	# host's own rule is what has to release it.
	var rock_2 := get_node_or_null("Rock_2") as Rock
	if rock_2 != null:
		begin_disconnect_drill.rpc_id(String(remote.name).to_int(), rock_2.get_path())
		var held_by := 0
		var watched := 0.0
		while watched < 8.0:
			await get_tree().create_timer(0.1).timeout
			watched += 0.1
			if rock_2.holder_peer != 0:
				held_by = rock_2.holder_peer
				break
		await get_tree().create_timer(4.0).timeout
		print("PLAYGROUND_STAGE7_DISCONNECT held_by=%d after_leave_holder=%d players=%d" % [
			held_by, rock_2.holder_peer, _players_root.get_child_count()])


# Does a thrown rock actually hit a person? The dummy check throws flat on
# purpose, so it never answered this: at the documented 35 degrees the rock
# leaves a hand 2.6 m up, and a body is 1.8 m tall. Measured at three distances,
# because a throw that clears a head at three metres can still come down on one
# at nine.
#
# Reported as the closest the rock ever came to the body and how high it was
# passing at that moment, so a miss and a pass through cannot be confused: a
# rock that goes over reads as a wide gap with a positive height, and a rock
# that ignores the body reads as a gap near zero with no damage.
func _run_rock_vs_player(local: Player, remote: Player) -> void:
	var rock := get_node_or_null("Rock_0") as Rock
	if rock == null:
		return
	# A hit means the two surfaces met: sphere radius plus the capsule's 0.4.
	var touching := Rock.radius_for(rock.weight) + Player.BODY_RADIUS
	for distance in [3.0, 6.0, 9.0]:
		if local.state == Player.State.DEAD:
			local.respawn()
		await _settle(local, THROW_LANE)
		place_remote.rpc_id(String(remote.name).to_int(), THROW_LANE + Vector3(distance, 0.0, 0.0))
		await get_tree().create_timer(1.0).timeout
		# Brought to hand rather than walked to: the throw is what is under test.
		rock.host_grab(1)
		local.grab.on_rock_answer(rock, true)
		for _frame in range(6):
			await get_tree().physics_frame
		var hp_before := remote.hp
		var stood := remote.global_position
		local.movement.set_aim_override(remote.global_position)
		local.movement.interact()
		var closest := INF
		var passing_height := 0.0
		var sampled := 0.0
		while sampled < 2.0:
			await get_tree().physics_frame
			sampled += get_physics_process_delta_time()
			var gap := rock.global_position.distance_to(remote.global_position)
			if gap < closest:
				closest = gap
				passing_height = rock.global_position.y - remote.global_position.y
		local.movement.set_aim_override(Vector3.INF)
		print("PLAYGROUND_ROCK_VS_PLAYER distance=%.0f angle=%.0f closest=%.2f touching_at=%.2f passing_height=%.2f hp=%.0f-%.0f moved=%.2f" % [
			distance, Tuning.values.throw_up_angle_deg, closest, touching, passing_height,
			hp_before, remote.hp, _flat(remote.global_position - stood)])
		# The harness putting a prop back on its mark, not game logic: the next
		# leg has to start from the same place, and a rock left lying beside the
		# team mate would be grabbed instead of them.
		rock.global_position = rock.home
		rock.linear_velocity = Vector3.ZERO
		rock.angular_velocity = Vector3.ZERO
		await get_tree().create_timer(1.0).timeout


# Stands next to them and takes hold. Returns whether the hold actually
# happened: the answer comes back over the network, so it is waited for.
func _grab_remote(local: Player, remote: Player, lane := THROW_LANE) -> bool:
	# Both bodies placed, both alive. A check that starts from wherever the last
	# throw left them measures the leftovers of that throw.
	#
	# Our own body is placed FIRST and the team mate second, and never closer
	# than 1.6 m. A remote body is positioned by assignment rather than by
	# move_and_slide, so one that travels across the map sweeps its capsule
	# through whatever is standing at the far end: on the other machine that
	# reads as a solid wall arriving at speed, and the local body is shoved out
	# of it and glides away airborne. Placing ourselves first means the sweep
	# finishes before the other body is standing there.
	if local.state == Player.State.DEAD:
		local.respawn()
	await _settle(local, lane + Vector3(1.6, 0.0, 0.0))
	var settling := 0.0
	while settling < 2.0 and not local.is_grounded_state():
		await get_tree().physics_frame
		settling += get_physics_process_delta_time()
	place_remote.rpc_id(String(remote.name).to_int(), lane)
	await get_tree().create_timer(0.8).timeout
	# Placed again if the first one landed on a body that was still dying: the
	# respawn that follows would move it out from under the check.
	if remote.state == Player.State.DEAD:
		place_remote.rpc_id(String(remote.name).to_int(), lane)
		await get_tree().create_timer(2.0).timeout
	local.movement.set_aim_override(remote.global_position)
	local.movement.interact()
	var waited := 0.0
	# Two things have to arrive: our own approval, and the target's GRABBED
	# state coming back over the network. Measuring before the second one is
	# how a working hold reads as a failure.
	while waited < 2.0 and not (local.grab.is_holding() and remote.state == Player.State.GRABBED):
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	local.movement.set_aim_override(Vector3.INF)
	var ready := local.grab.is_holding() and remote.state == Player.State.GRABBED
	if not ready:
		print("PLAYGROUND_STAGE7_GRABFAIL me=%s at=(%.1f, %.1f, %.1f) holding=%s them=%s at=(%.1f, %.1f, %.1f) sync=(%.1f, %.1f, %.1f) stepping=%s" % [
			Player.State.keys()[local.state], local.global_position.x, local.global_position.y,
			local.global_position.z, local.grab.is_holding(),
			Player.State.keys()[remote.state], remote.global_position.x,
			remote.global_position.y, remote.global_position.z,
			remote.sync_position.x, remote.sync_position.y, remote.sync_position.z,
			remote.is_physics_processing()])
	return ready


@rpc("authority", "call_remote", "reliable")
func set_remote_weight(weight: float) -> void:
	var local := _local_player()
	if local != null:
		local.stats.race_weight = weight


# Placed by the host so a measurement happens in a known spot. Only the body's
# own machine may move it, so the host asks.
@rpc("authority", "call_remote", "reliable")
func place_remote(at: Vector3) -> void:
	var local := _local_player()
	if local == null:
		return
	if local.state == Player.State.DEAD:
		# Otherwise the pending respawn fires later and moves the body out from
		# under whatever the host was about to measure.
		local.respawn()
	local.global_position = at
	local.velocity = Vector3.ZERO
	local.movement.cancel_target()
	local.hp = local.stats.max_hp
	print("PLAYGROUND_PLACED asked=(%.1f, %.1f, %.1f) now=(%.1f, %.1f, %.1f)" % [
		at.x, at.y, at.z, local.global_position.x, local.global_position.y, local.global_position.z])
	var touching := PackedStringArray()
	var drift := 0.0
	var previous := local.global_position
	var watched := 0.0
	while watched < 1.0:
		await get_tree().physics_frame
		watched += get_physics_process_delta_time()
		drift += _flat(local.global_position - previous)
		previous = local.global_position
		for index in local.get_slide_collision_count():
			var collider := local.get_slide_collision(index).get_collider() as Node
			if collider != null and not touching.has(collider.name):
				touching.append(collider.name)
	print("PLAYGROUND_PLACED_AFTER at=(%.1f, %.1f, %.1f) state=%s drift=%.2f touching=[%s] target=%s" % [
		local.global_position.x, local.global_position.y, local.global_position.z,
		Player.State.keys()[local.state], drift, ", ".join(touching),
		local.movement.has_target()])


@rpc("authority", "call_remote", "reliable")
func begin_escape_drill() -> void:
	_escape_drill = true


@rpc("authority", "call_remote", "reliable")
func begin_disconnect_drill(rock_path: NodePath) -> void:
	_disconnect_rock = rock_path


# The client's half of stage 7: stand still so the host can reach you, mash
# Space when asked, and leave while holding a rock when asked.
func _client_support(local: Player) -> void:
	var waited := 0.0
	var reported_mutual := false
	while waited < 200.0:
		await get_tree().create_timer(0.12).timeout
		waited += 0.12
		# This loop sleeps across the shutdown, so the body it was watching can
		# be gone by the time it wakes.
		if not is_instance_valid(local):
			return
		if local.state == Player.State.GRABBED and not reported_mutual:
			reported_mutual = true
			# 7-6: being held refuses a grab of your own.
			print("PLAYGROUND_STAGE7_MUTUAL grab_while_held=%s" % local.grab.grab())
		if _escape_drill and local.state == Player.State.GRABBED:
			local.grab.escape_press()
		if _disconnect_rock != NodePath():
			var rock := get_node_or_null(_disconnect_rock) as Rock
			_disconnect_rock = NodePath()
			if rock != null:
				while local.state == Player.State.DEAD:
					await get_tree().create_timer(0.2).timeout
				# Waited out first: a rock that is still rolling has moved on by
				# the time we have walked to where it was.
				var resting := 0.0
				var last := rock.global_position
				while resting < 4.0:
					await get_tree().create_timer(0.2).timeout
					resting += 0.2
					if last.distance_to(rock.global_position) < 0.05:
						break
					last = rock.global_position
				for _attempt in range(3):
					await _settle(local, Vector3(
						rock.global_position.x + 1.0, 1.0, rock.global_position.z))
					local.movement.set_aim_override(rock.global_position)
					local.movement.interact()
					await get_tree().create_timer(0.8).timeout
					if local.grab.is_holding():
						break
				print("PLAYGROUND_STAGE7_LEAVING holding=%s rock_at=%.1f me_at=%.1f" % [
					local.grab.is_holding(), rock.global_position.x, local.global_position.x])
				await get_tree().create_timer(0.3).timeout
				get_tree().quit()
			return


func _local_player() -> Player:
	for child in _players_root.get_children():
		var player := child as Player
		if player != null and player.is_local():
			return player
	return null


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


const CLIMB_RING_CENTRE := Vector3(-8.0, 0.0, 6.0)
const CLIMB_RING_RADIUS := 6.0
# 90 and 270 degrees are left out on purpose: a face pointing across the view
# cannot be aimed at properly, and since the camera never rotates it is the
# level's job never to place one.
const CLIMB_RING_ANGLES := [0.0, 45.0, 135.0, 180.0, 225.0, 315.0]


func _build_walls() -> void:
	# Climbable faces in a ring, minus the two that would point across the view.
	# Every wall here meets the camera squarely enough to aim at, so climbing
	# works the same on all of them and the side face rule is gone entirely.
	for degrees in CLIMB_RING_ANGLES:
		var yaw := deg_to_rad(float(degrees))
		var outward := Vector3(sin(yaw), 0.0, cos(yaw))
		var wall := _box(
			"ClimbWall_%d" % roundi(rad_to_deg(yaw)),
			CLIMB_RING_CENTRE + outward * CLIMB_RING_RADIUS + Vector3.UP * 3.0,
			Vector3(3.0, 6.0, 0.6),
			Color("6f9a63"),
			CLIMBABLE_LAYER,
			false,
			yaw)
		# The label says which way it points, so the rule can be read off the
		# map rather than worked out.
		_sign(
			"%d°" % roundi(rad_to_deg(yaw)),
			wall.position + Vector3.UP * 3.6,
			Color("c8ffc8"))
	_sign("CLIMB RING (8면)", CLIMB_RING_CENTRE + Vector3.UP * 8.0, Color("c8ffc8"))
	# Smooth wall: looks similar, cannot be climbed.
	_box("SmoothWall", Vector3(16.0, 2.0, 2.0), Vector3(6.0, 4.0, 0.6), Color("555b62"), WALL_LAYER)
	_sign("SMOOTH (등반 불가)", Vector3(16.0, 5.0, 2.0), Color.WHITE)


func _build_time_boundary() -> void:
	_boundary = TimeBoundary.new()
	_boundary.name = "TimeBoundary"
	add_child(_boundary)
	_boundary.build(_region)
	_sign("등반 단차 3m", Vector3(TimeBoundary.SEAM.x, TimeBoundary.TOP_Y + 2.0, TimeBoundary.SEAM.z + 1.2), Color("c8ffc8"))
	var overlay := preload("res://scripts/debug/boundary_overlay.gd").new()
	overlay.name = "BoundaryOverlay"
	add_child(overlay)
	# Printed on every peer, host and client alike: the seam is built from a
	# table rather than replicated, so the only way to know the two screens
	# agree is to compare what each one built.
	print("PLAYGROUND_BOUNDARY peer=%d %s" % [
		multiplayer.get_unique_id() if multiplayer.has_multiplayer_peer() else 0,
		_boundary.signature()])


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
		occluder := false,
		yaw := 0.0) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = box_name
	body.position = at_position
	body.rotation.y = yaw
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
		# side is simply the larger z, taken from the rotated footprint.
		var reach_z := (absf(sin(yaw)) * size.x + absf(cos(yaw)) * size.z) * 0.5
		body.set_meta("near_z", at_position.z + reach_z)
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
