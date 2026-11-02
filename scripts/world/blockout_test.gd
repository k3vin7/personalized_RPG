extends Node3D

# Single-player walkabout for maps/blockout_Finimes.tscn. Run it with F6: no
# main menu, no ENet peer, one local player that is also the judge. The spawn
# and navigation pieces are the ones playground.gd uses, trimmed to what a
# walk needs; the quarter camera, the status bars and the debug panel are built
# by the player itself in Player._ready() when it is local.
#
# Command line (after "--"): --shot=<png path> saves the viewport and quits,
# --shot-at=<seconds> says when (default 3.0). --dash-key=<physical keycode>
# rebinds the dash to that key after the spawn and presses the old key, then
# the new one, so the log shows which of the two still dashes.

const SPAWN_POINT := Vector3(0.0, 2.0, 5.0)
const AGENT_RADIUS := 0.45
const CELL_SIZE := 0.25
# The navigation bake runs in a thread; the readout waits on the real one.
const SHOT_DELAY_DEFAULT := 3.0

# The game's own tilt by default; override in the inspector to try another.
@export var camera_pitch_degrees: float = QuarterCamera.PITCH_DEGREES

@onready var _region: NavigationRegion3D = $NavRegion
@onready var _readout: Label = $Hud/Readout

var _players_root: Node3D
var _spawner: MultiplayerSpawner
var _elapsed := 0.0
var _shot_path := ""
var _shot_at := SHOT_DELAY_DEFAULT
var _shot_done := false
var _dash_key_check := 0
var _dash_check_step := 0
var _dash_check_at := 0.0
var _dash_old_key := 0


func _enter_tree() -> void:
	# The blockout carries a Player instance of its own, named "Player", which
	# makes its authority peer 0: not local, not anyone's. Take it out before it
	# enters the tree, so the one spawned below is the only body at the mark.
	var blockout := get_node_or_null("NavRegion/Blockout")
	if blockout == null:
		return
	for child in blockout.get_children():
		if child is Player:
			blockout.remove_child(child)
			child.queue_free()


func _ready() -> void:
	# Net.queue_physics() drops every request while there is no peer, and the
	# jump, dash and respawn paths all go through it. Offline is still a peer.
	if not multiplayer.has_multiplayer_peer():
		multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	_parse_cmdline()
	_build_lighting()

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

	_bake_navigation()


func _parse_cmdline() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--shot="):
			_shot_path = argument.trim_prefix("--shot=")
		elif argument.begins_with("--shot-at="):
			_shot_at = float(argument.trim_prefix("--shot-at="))
		elif argument.begins_with("--dash-key="):
			_dash_key_check = int(argument.trim_prefix("--dash-key="))


# Same recipe as playground.gd: the blockout is a child of the region, so the
# bake reads its CSG colliders (world layer) and nothing else.
func _bake_navigation() -> void:
	var nav_mesh := NavigationMesh.new()
	nav_mesh.agent_height = 1.9
	nav_mesh.agent_radius = AGENT_RADIUS
	nav_mesh.agent_max_climb = 0.3
	nav_mesh.agent_max_slope = 46.0
	nav_mesh.cell_size = CELL_SIZE
	nav_mesh.cell_height = 0.25
	nav_mesh.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_ROOT_NODE_CHILDREN
	nav_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	nav_mesh.geometry_collision_mask = Layers.WORLD | Layers.WALL | Layers.CLIMBABLE
	_region.navigation_mesh = nav_mesh
	_region.bake_finished.connect(_on_bake_finished)
	_region.call_deferred("bake_navigation_mesh", true)


func _on_bake_finished() -> void:
	print("BLOCKOUT_TEST_NAV_READY polygons=%d" % _region.navigation_mesh.get_polygon_count())
	# One mark, so a respawn comes back to the same spot. Net spawns peer 1
	# through the spawner the moment it is registered.
	var points: Array[Vector3] = [SPAWN_POINT]
	Net.register_playground(_players_root, points, _spawner)
	var local := _local_player()
	if local != null and local.camera != null:
		local.camera.set_pitch(camera_pitch_degrees)
	print("BLOCKOUT_TEST_SPAWN local=%s peer=%d has_peer=%s at=%s" % [
		local != null, multiplayer.get_unique_id(), multiplayer.has_multiplayer_peer(),
		local.global_position if local != null else Vector3.INF])


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


func _local_player() -> Player:
	if _players_root == null:
		return null
	for child in _players_root.get_children():
		var player := child as Player
		if player != null and player.is_local():
			return player
	return null


func _unhandled_input(event: InputEvent) -> void:
	# T resets the walk clock. A raw key rather than an action: the action
	# table is the game's and this scene adds nothing to it.
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.keycode == KEY_T:
		_elapsed = 0.0


func _process(delta: float) -> void:
	_elapsed += delta
	var local := _local_player()
	if local == null:
		_readout.text = "pos ( -- )\nt = %.1f s" % _elapsed
	else:
		var p := local.global_position
		_readout.text = "pos ( %.2f, %.2f, %.2f )  %s\nt = %.1f s   [T] reset" % [
			p.x, p.y, p.z, Player.State.keys()[local.state], _elapsed]
	if _dash_key_check != 0 and local != null and local.movement != null:
		_dash_key_step(local)
	if _shot_path != "" and not _shot_done and _elapsed >= _shot_at and local != null:
		_shot_done = true
		_take_shot(local)


# Old key at 1.0 s, read at 1.4 s; new key at 1.6 s, read at 2.0 s. Each press
# goes through Input, so the InputMap decides what it means. With the smart
# key off (the default) the dash key arms the dash rather than starting it, so
# what is read is movement.armed_action(): NONE for the old key, DASH for the
# new one.
func _dash_key_step(local: Player) -> void:
	match _dash_check_step:
		0:
			if _elapsed < 1.0:
				return
			_dash_old_key = int(Tuning.values.dash_key)
			local.movement.rebind_dash(_dash_key_check)
			_press(_dash_old_key)
			_dash_check_at = _elapsed
			_dash_check_step = 1
		1:
			if _elapsed < _dash_check_at + 0.4:
				return
			print("BLOCKOUT_TEST_DASH_KEY old=%s armed=%s" % [
				OS.get_keycode_string(_dash_old_key),
				PlayerMovement.Armed.keys()[local.movement.armed_action()]])
			_press(_dash_key_check)
			_dash_check_at = _elapsed
			_dash_check_step = 2
		2:
			if _elapsed < _dash_check_at + 0.4:
				return
			print("BLOCKOUT_TEST_DASH_KEY new=%s armed=%s" % [
				OS.get_keycode_string(_dash_key_check),
				PlayerMovement.Armed.keys()[local.movement.armed_action()]])
			_dash_check_step = 3


func _press(physical_keycode: int) -> void:
	var down := InputEventKey.new()
	down.physical_keycode = physical_keycode as Key
	down.pressed = true
	Input.parse_input_event(down)
	var up := InputEventKey.new()
	up.physical_keycode = physical_keycode as Key
	up.pressed = false
	Input.parse_input_event(up)


func _take_shot(local: Player) -> void:
	# Wait a drawn frame so the readout above is what the capture shows.
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var error := image.save_png(_shot_path)
	print("BLOCKOUT_TEST_SHOT path=%s error=%d pos=%s on_floor=%s state=%s" % [
		_shot_path, error, local.global_position, local.is_on_floor(),
		Player.State.keys()[local.state]])
	get_tree().quit()
