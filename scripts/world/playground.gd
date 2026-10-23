class_name Playground
extends Node3D

# The grey box map. Geometry is built from a table in code rather than placed by
# hand in the scene: the dimensions are the point of this map, and a table is
# the only form where they can be read and checked against the work order.

const WORLD_LAYER := 1
const WALL_LAYER := 2
const CLIMBABLE_LAYER := 4

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
	# Only the World layer is walkable: climb walls and smooth walls must not
	# contribute a surface.
	nav_mesh.geometry_collision_mask = WORLD_LAYER
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

	# A target on the far side of a gap is unreachable: the navigation mesh does
	# not bridge it, so the body must stop on this side rather than walk out.
	local.global_position = Vector3(-15.0, 1.0, 0.0)
	await get_tree().create_timer(0.6).timeout
	local.movement.set_target(Vector3(-15.0, 0.0, -6.0))
	await get_tree().create_timer(3.0).timeout
	print("PLAYGROUND_SMOKE_GAP peer=%d stopped_z=%.2f crossed=%s" % [
		multiplayer.get_unique_id(), local.global_position.z, local.global_position.z < -2.5])

	if multiplayer.is_server():
		# Long enough that the other process has really gone, not merely queued.
		await get_tree().create_timer(9.0).timeout
		print("PLAYGROUND_SMOKE_AFTER_LEAVE players=%d" % _players_root.get_child_count())


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
		_sign("GAP %.0fm" % width, Vector3(lane, 1.6, gap_start + 1.0), Color("d9f3ff"))


func _build_walls() -> void:
	# Climbable, 6 x 6. A faces the camera, B faces sideways, C faces away.
	_box("ClimbWallA", Vector3(-14.0, 3.0, 2.0), Vector3(6.0, 6.0, 0.6), Color("7a8f7a"), CLIMBABLE_LAYER, true)
	_box("ClimbWallB", Vector3(-4.0, 3.0, 2.0), Vector3(0.6, 6.0, 6.0), Color("7a8f7a"), CLIMBABLE_LAYER, true)
	_box("ClimbWallC", Vector3(6.0, 3.0, 2.0), Vector3(6.0, 6.0, 0.6), Color("7a8f7a"), CLIMBABLE_LAYER, true)
	_sign("CLIMB A / B / C", Vector3(-4.0, 7.0, 2.0), Color("c8ffc8"))
	# Smooth wall: looks the same, cannot be climbed.
	_box("SmoothWall", Vector3(16.0, 2.0, 2.0), Vector3(6.0, 4.0, 0.6), Color("555b62"), WALL_LAYER)
	_sign("SMOOTH", Vector3(16.0, 5.0, 2.0), Color.WHITE)


func _build_occluders() -> void:
	# Between the camera and the plaza, so walking behind one fades it.
	_box("OccluderA", Vector3(-6.0, 2.5, 10.0), Vector3(8.0, 5.0, 0.6), Color("4b535c"), WALL_LAYER, true, true)
	_box("OccluderB", Vector3(8.0, 2.5, 6.0), Vector3(8.0, 5.0, 0.6), Color("4b535c"), WALL_LAYER, true, true)
	_sign("OCCLUSION", Vector3(-6.0, 6.0, 10.0), Color.WHITE)


func _box(
		box_name: String,
		at_position: Vector3,
		size: Vector3,
		color: Color,
		layer: int,
		outside_navigation := false,
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
	if occluder:
		# Dither fade needs the shader; everything else can stay a plain
		# material so the fade path is only paid for where it is used.
		var shader_material := ShaderMaterial.new()
		shader_material.shader = load("res://shaders/dither_fade.gdshader")
		shader_material.set_shader_parameter("albedo", color)
		shader_material.set_shader_parameter("fade", 1.0)
		mesh_instance.material_override = shader_material
		body.add_to_group(OcclusionFader.OCCLUDER_GROUP)
	else:
		var material := StandardMaterial3D.new()
		material.albedo_color = color
		material.roughness = 0.8
		mesh_instance.material_override = material
	body.add_child(mesh_instance)

	# Only navigation geometry hangs under the region.
	if outside_navigation:
		add_child(body)
	else:
		_region.add_child(body)
	return body


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
