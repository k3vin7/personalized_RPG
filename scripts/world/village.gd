class_name Village
extends Node3D

# V-1 (2026-11-07): the Finimes starting village, first cut. The play test's
# world: the plaza, the height zones, the roads with their stairs, the two
# gates and the building footprints, all read from data/village_layout.tres
# and built on every peer. Blockout only: flat colours, no models, no NPCs.
#
# What a session needs is the same as the playground's: the judge, the
# player spawner, the spawn marks, a navigation mesh baked from the terrain
# and the static bodies. The village walks: on the judge the server's base
# move speed is set to the layout's (2 m/s); the playground keeps 6.

const LAYOUT_PATH := "res://data/village_layout.tres"
const AGENT_RADIUS := 0.45
const CELL_SIZE := 0.25
const PAVING_COLOUR := Color("8f8a80")
const FOUNTAIN_COLOUR := Color("6f7f94")
const STEP_COLOUR := Color("a09a8c")
const GATE_COLOUR := Color("8a6a46")
const FOOTPRINT_COLOUR := Color(0.95, 0.75, 0.35, 0.28)
const FOOTPRINT_HEIGHT := 3.0

var layout: VillageLayout
var terrain: VillageTerrain
var spawn_points: Array[Vector3] = []
var stair_count := 0
var step_count := 0

var _region: NavigationRegion3D
var _spawner: MultiplayerSpawner
var _players_root: Node3D
var _pending_nav_mesh: NavigationMesh
var _smoke_started := false
var village_map: VillageMap


func _ready() -> void:
	layout = load(LAYOUT_PATH) as VillageLayout
	if layout == null:
		push_error("Village: %s did not load" % LAYOUT_PATH)
		return
	_region = NavigationRegion3D.new()
	_region.name = "NavigationRegion3D"
	_region.use_edge_connections = false
	add_child(_region)

	_build_lighting()
	terrain = VillageTerrain.build(self, layout)
	# Under the navigation region so the bake parses their bodies.
	_build_plaza(_region)
	_build_stairs(_region)
	_build_gates(_region)
	_build_footprints()
	_sign("피니메스 시작마을 (V-1 블록아웃)", Vector3(0.0, 4.5, 0.0), Color("ffe9b0"))

	var authority := ServerAuthority.new()
	authority.name = "ServerAuthority"
	add_child(authority)

	_players_root = Node3D.new()
	_players_root.name = "Players"
	add_child(_players_root)

	_spawner = MultiplayerSpawner.new()
	_spawner.name = "PlayerSpawner"
	_spawner.add_spawnable_scene(Net.PLAYER_SCENE)
	_spawner.spawn_function = _make_player
	add_child(_spawner)
	_spawner.spawn_path = _spawner.get_path_to(_players_root)

	spawn_points.clear()
	for point in layout.spawn_points:
		spawn_points.append(Vector3(point.x, layout.height_at(point.x, point.z) + Player.BODY_HALF_HEIGHT + 0.1, point.z))
		var marker := Marker3D.new()
		marker.position = spawn_points[spawn_points.size() - 1]
		add_child(marker)

	# The village pace. Written by the judge only; the heartbeat carries it
	# to every replica (N-1), the playground's 6 m/s is untouched.
	if Tuning.is_judge():
		Tuning.server.base_move_speed = layout.move_speed
		Tuning.notify_changed()
		print("VILLAGE_MOVE_SPEED %.2f" % Tuning.server.base_move_speed)

	call_deferred("_bake_navigation")


# ------------------------------------------------------------ the pieces

# The paving: a stone disc on the plaza, 2 cm proud of the ground (the
# ground is the collider); the fountain: its space, a low drum that blocks.
func _build_plaza(parent: Node) -> void:
	var paving := MeshInstance3D.new()
	paving.name = "Paving"
	var disc := CylinderMesh.new()
	disc.top_radius = layout.plaza_radius
	disc.bottom_radius = layout.plaza_radius
	disc.height = 0.04
	disc.radial_segments = 48
	paving.mesh = disc
	paving.material_override = _flat(PAVING_COLOUR)
	paving.position = Vector3(0.0, layout.plaza_height + 0.02, 0.0)
	add_child(paving)

	var fountain := StaticBody3D.new()
	fountain.name = "FountainSpace"
	fountain.position = Vector3(0.0, layout.plaza_height + 0.5, 0.0)
	fountain.collision_layer = Layers.WALL
	fountain.collision_mask = 0
	var shape := CollisionShape3D.new()
	var drum := CylinderShape3D.new()
	drum.radius = layout.fountain_radius
	drum.height = 1.0
	shape.shape = drum
	fountain.add_child(shape)
	var mesh := MeshInstance3D.new()
	var drum_mesh := CylinderMesh.new()
	drum_mesh.top_radius = layout.fountain_radius
	drum_mesh.bottom_radius = layout.fountain_radius
	drum_mesh.height = 1.0
	mesh.mesh = drum_mesh
	mesh.material_override = _flat(FOUNTAIN_COLOUR)
	fountain.add_child(mesh)
	parent.add_child(fountain)
	_sign("분수대 자리 (지름 %.0f m)" % (layout.fountain_radius * 2.0), Vector3(0.0, 2.2, 0.0), Color("cfe3ff"))


# Steps drawn on every stair segment. The ramp in the terrain is what the
# body walks on; these boxes have no collision and sit with their noses on
# the ramp line, so a foot sinks into the back of a tread by a riser at most.
func _build_stairs(_parent: Node) -> void:
	var holder := Node3D.new()
	holder.name = "Stairs"
	add_child(holder)
	for stair in layout.stairs():
		var from: Vector3 = stair["from"]
		var to: Vector3 = stair["to"]
		var width: float = stair["width"]
		var low := from if from.y <= to.y else to
		var high := to if from.y <= to.y else from
		var run := Vector2(high.x - low.x, high.z - low.z)
		var length := run.length()
		var rise := high.y - low.y
		var steps := maxi(int(ceil(rise / layout.stair_riser)), 1)
		var riser := rise / float(steps)
		var tread := length / float(steps)
		var direction := run.normalized()
		var yaw := atan2(-direction.x, -direction.y)
		for index in steps:
			var along := tread * (float(index) + 0.5)
			var centre := Vector2(low.x, low.z) + direction * along
			var top := low.y + riser * float(index + 1)
			var box := MeshInstance3D.new()
			var mesh := BoxMesh.new()
			mesh.size = Vector3(width, riser + 0.02, tread)
			box.mesh = mesh
			box.material_override = _flat(STEP_COLOUR if index % 2 == 0 else STEP_COLOUR.darkened(0.08))
			box.position = Vector3(centre.x, top - (riser + 0.02) * 0.5, centre.y)
			box.rotation.y = yaw
			holder.add_child(box)
			step_count += 1
		stair_count += 1
		_sign("계단 %s (%.1f m, %d단)" % [stair["road"], rise, steps],
			Vector3((low.x + high.x) * 0.5, high.y + 1.6, (low.z + high.z) * 0.5), Color("e8e2d2"))
	print("VILLAGE_STAIRS count=%d steps=%d" % [stair_count, step_count])


# The two gates: a post either side of the road, so the way in reads as a
# way in. A guard stands here later.
func _build_gates(parent: Node) -> void:
	for entry in [["north", layout.gate_north, layout.road_named("north_road")],
			["southeast", layout.gate_southeast, layout.road_named("southeast_road")]]:
		var label: String = entry[0]
		var at: Vector2 = entry[1]
		var road: Dictionary = entry[2]
		var width := float(road.get("width", 4.5))
		# The road's direction at the gate: from the gate's nearest segment.
		var points: PackedVector3Array = road["points"]
		var direction := Vector2(0.0, -1.0)
		var best := INF
		for index in points.size() - 1:
			var a := Vector2(points[index].x, points[index].z)
			var b := Vector2(points[index + 1].x, points[index + 1].z)
			var d := at.distance_to(Geometry2D.get_closest_point_to_segment(at, a, b))
			if d < best:
				best = d
				direction = (b - a).normalized()
		var side := Vector2(-direction.y, direction.x)
		for s: float in [-1.0, 1.0]:
			var post := StaticBody3D.new()
			post.name = "Gate_%s_%s" % [label, "l" if s < 0.0 else "r"]
			var foot := at + side * (width * 0.5 + 0.6) * s
			var ground := layout.height_at(foot.x, foot.y)
			post.position = Vector3(foot.x, ground + 1.5, foot.y)
			post.collision_layer = Layers.WALL
			post.collision_mask = 0
			var shape := CollisionShape3D.new()
			var box := BoxShape3D.new()
			box.size = Vector3(0.6, 3.0, 0.6)
			shape.shape = box
			post.add_child(shape)
			var mesh := MeshInstance3D.new()
			var box_mesh := BoxMesh.new()
			box_mesh.size = box.size
			mesh.mesh = box_mesh
			mesh.material_override = _flat(GATE_COLOUR)
			post.add_child(mesh)
			parent.add_child(post)
		_sign("길목 (%s)" % ("북" if label == "north" else "남동"),
			Vector3(at.x, layout.height_at(at.x, at.y) + 3.6, at.y), Color("ffd6a0"))


# Where buildings go: a translucent box and a name over each, no collision.
func _build_footprints() -> void:
	var holder := Node3D.new()
	holder.name = "Footprints"
	add_child(holder)
	for footprint in layout.footprints:
		var at: Vector2 = footprint["at"]
		var size: Vector2 = footprint["size"]
		var ground := layout.height_at(at.x, at.y)
		var box := MeshInstance3D.new()
		box.name = String(footprint["name"])
		var mesh := BoxMesh.new()
		mesh.size = Vector3(size.x, FOOTPRINT_HEIGHT, size.y)
		box.mesh = mesh
		var material := _flat(FOOTPRINT_COLOUR)
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		box.material_override = material
		box.position = Vector3(at.x, ground + FOOTPRINT_HEIGHT * 0.5, at.y)
		box.rotation_degrees.y = float(footprint.get("yaw", 0.0))
		box.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		box.add_to_group("footprint")
		holder.add_child(box)
		_sign(String(footprint["name"]), Vector3(at.x, ground + FOOTPRINT_HEIGHT + 0.6, at.y), Color("ffe9b0"))


static func _flat(colour: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	material.roughness = 0.9
	return material


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


func _build_lighting() -> void:
	var environment := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("a9b4bd")
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


# ------------------------------------------------------------ the session

func _bake_navigation() -> void:
	var nav_mesh := NavigationMesh.new()
	nav_mesh.agent_height = 1.9
	nav_mesh.agent_radius = AGENT_RADIUS
	nav_mesh.agent_max_climb = 0.3
	# Only what the body can walk: the playground bakes at 46 deg (its
	# steps are meant to need a jump), but here a path over a slope the
	# body cannot climb left it pushing at a wall (V-1, first run).
	nav_mesh.agent_max_slope = Tuning.server.walk_slope_max_deg - 2.0
	nav_mesh.cell_size = CELL_SIZE
	nav_mesh.cell_height = 0.25
	nav_mesh.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_ROOT_NODE_CHILDREN
	nav_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	nav_mesh.geometry_collision_mask = Layers.WORLD | Layers.WALL | Layers.CLIMBABLE | Layers.NAV_BRIDGE
	var source := NavigationMeshSourceGeometryData3D.new()
	NavigationServer3D.parse_source_geometry_data(nav_mesh, source, self)
	if terrain != null and terrain.built:
		var faces := terrain.nav_faces()
		source.add_faces(faces, Transform3D.IDENTITY)
		print("VILLAGE_NAV_TERRAIN faces=%d" % (faces.size() / 3))
	_pending_nav_mesh = nav_mesh
	NavigationServer3D.bake_from_source_geometry_data_async(nav_mesh, source, _on_bake_finished)


func _on_bake_finished() -> void:
	if _pending_nav_mesh != null:
		_region.navigation_mesh = _pending_nav_mesh
		_pending_nav_mesh = null
	print("VILLAGE_NAV_READY polygons=%d" % _region.navigation_mesh.get_polygon_count())
	Net.register_playground(_players_root, spawn_points, _spawner)
	Net.playground_ready.emit(self)
	# The map (minimap top-right, Tab for the whole village), on every screen.
	village_map = VillageMap.new()
	village_map.name = "VillageMap"
	village_map.setup(layout)
	add_child(village_map)
	print("VILLAGE_READY peer=%d" % multiplayer.get_unique_id())
	if Net.auto_smoke and multiplayer.is_server():
		_start_smoke_when_ready()


func _make_player(data: Variant) -> Node:
	var info := data as Dictionary
	var player := (load(Net.PLAYER_SCENE) as PackedScene).instantiate() as Node3D
	player.name = str(info.get("peer", 1))
	player.position = info.get("position", Vector3.ZERO)
	return player


# ------------------------------------------------------------ the harness

func _start_smoke_when_ready() -> void:
	for _wait in range(120):
		await get_tree().create_timer(0.05).timeout
		if _players_root.get_child_count() >= 2:
			break
	# Harness only. The spawns leave with the host's next network flush
	# while an RPC leaves at once: sent in the same frame as the second
	# spawn, begin_smoke reached the client before its own body did (the
	# auth handshake lets a client connect during the host's bake, so both
	# spawns and the start can land in one frame -- V-1, 2026-11-07).
	await get_tree().create_timer(0.5).timeout
	begin_smoke.rpc()
	_run_smoke()


@rpc("authority", "call_remote", "reliable")
func begin_smoke() -> void:
	_run_smoke()


func _run_smoke() -> void:
	if _smoke_started:
		return
	_smoke_started = true
	if Net.auto_only in ["V1", "V1nav", "V1walk"]:
		var checks := preload("res://scripts/tests/v1_checks.gd").new()
		checks.name = "V1Checks"
		add_child(checks)
		checks.run(self)
		return
	print("VILLAGE_SMOKE no stage named %s" % Net.auto_only)
