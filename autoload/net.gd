extends Node

# Host and join, and the player spawn that only the host performs. Scene changes
# are driven from here so the menu never has to know about the playground.

const DEFAULT_PORT := 7777
const MAX_PEERS := 4
const PLAYER_SCENE := "res://scenes/player.tscn"
const PLAYGROUND_SCENE := "res://scenes/playground.tscn"
# 2026-11-06: two ways in from the first screen. "playground" is the physics
# test (the grey-box map and every harness stage); "village" is the play test
# (the village the next work order describes; a flat placeholder until then).
# The host's choice is the session's: a client is told it on connection and
# loads that scene, whatever it picked itself.
const WORLD_SCENES := {
	"playground": PLAYGROUND_SCENE,
	"village": "res://scenes/village.tscn",
}
const WORLD_LABELS := {
	"playground": "물리 테스트 (물리 놀이터)",
	"village": "플레이 테스트 (마을)",
}
const DEFAULT_WORLD := "playground"

signal status_changed(message: String)
signal session_left(message: String)
signal playground_ready(playground: Node3D)

var is_hosting := false
# The world this peer asked for (the menu's pick, or --auto-world=), and the
# one the session runs: the host's.
var world := DEFAULT_WORLD
var spawn_root: Node3D
var spawn_points: Array[Vector3] = []
var spawner: MultiplayerSpawner

var _peer: ENetMultiplayerPeer
var auto_port := DEFAULT_PORT
var auto_smoke := false
# Names a single stage to check instead of the whole suite. A full run is
# minutes long, which is too slow to iterate one stage against.
var auto_only := ""
var _spawn_index := 0
var leave_message := ""
var _leaving := false
var _physics_requests: Array[Callable] = []


# Input and RPC callbacks enqueue work; only a physics tick changes bodies.
func queue_physics(request: Callable) -> void:
	if not _leaving:
		_physics_requests.append(request)


func _physics_process(_delta: float) -> void:
	var requests := _physics_requests.duplicate()
	_physics_requests.clear()
	for request: Callable in requests:
		if _leaving or not multiplayer.has_multiplayer_peer():
			break
		if request.is_valid():
			request.call()


# The world travels in the connection's authentication step (2026-11-07):
# the host sends its world name the moment a peer starts authenticating, the
# client loads that scene and answers "ready" once the scene (and so its
# PlayerSpawner) is in the tree, and only then does the host complete the
# connection. Done after connection instead, the host's spawner replicated
# its own body into the client's menu scene (no spawner there), the spawn
# failed and the client's own body never arrived (V-1, three runs).
const AUTH_TIMEOUT := 30.0
const AUTH_WORLD_PREFIX := "world:"
const AUTH_READY := "ready"
var _auth_world_loading := false


func _ready() -> void:
	var scene_multiplayer := multiplayer as SceneMultiplayer
	if scene_multiplayer != null:
		scene_multiplayer.auth_callback = _on_auth
		scene_multiplayer.auth_timeout = AUTH_TIMEOUT
		scene_multiplayer.peer_authenticating.connect(_on_peer_authenticating)
		scene_multiplayer.peer_authentication_failed.connect(_on_peer_authentication_failed)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	_parse_cmdline()


# Automated runs drive the whole session from the command line. Keeping this in
# here means a headless check never has to fake a button press.
func _parse_cmdline() -> void:
	var mode := ""
	for argument in OS.get_cmdline_user_args():
		if argument == "--auto-host":
			mode = "host"
		elif argument == "--auto-join":
			mode = "join"
		elif argument == "--auto-smoke":
			auto_smoke = true
		elif argument.begins_with("--auto-only="):
			auto_only = argument.trim_prefix("--auto-only=")
		elif argument.begins_with("--auto-world="):
			var want := argument.trim_prefix("--auto-world=")
			if WORLD_SCENES.has(want):
				world = want
			else:
				push_warning("Net: no world %s; %s" % [want, DEFAULT_WORLD])
		elif argument.begins_with("--auto-port="):
			var port := argument.trim_prefix("--auto-port=").to_int()
			if port >= 1024 and port <= 65535:
				auto_port = port
		elif argument.begins_with("--auto-quit="):
			var seconds := argument.trim_prefix("--auto-quit=").to_float()
			if seconds > 0.0:
				get_tree().create_timer(seconds).timeout.connect(get_tree().quit)
	if mode == "host":
		host.call_deferred(auto_port)
	elif mode == "join":
		# A short wait so both processes can be launched together: the client
		# would otherwise race the host's listen socket.
		get_tree().create_timer(1.5).timeout.connect(func() -> void: join("127.0.0.1", auto_port))


func host(port: int) -> bool:
	_reset_peer()
	leave_message = ""
	_peer = ENetMultiplayerPeer.new()
	var error := _peer.create_server(port, MAX_PEERS - 1)
	if error != OK:
		status_changed.emit("호스트 시작 실패: %s" % error_string(error))
		return false
	multiplayer.multiplayer_peer = _peer
	is_hosting = true
	print("PLAYGROUND_HOST_READY port=%d world=%s" % [port, world])
	get_tree().change_scene_to_file(WORLD_SCENES[world])
	return true


func join(address: String, port: int) -> bool:
	_reset_peer()
	leave_message = ""
	_peer = ENetMultiplayerPeer.new()
	var error := _peer.create_client(address, port)
	if error != OK:
		status_changed.emit("접속 시작 실패: %s" % error_string(error))
		return false
	multiplayer.multiplayer_peer = _peer
	is_hosting = false
	_auth_world_loading = false
	status_changed.emit("%s:%d 연결 중..." % [address, port])
	return true


func leave(message: String) -> void:
	if _leaving:
		return
	_leaving = true
	leave_message = message
	_physics_requests.clear()
	var scene := get_tree().current_scene
	if scene != null:
		scene.process_mode = Node.PROCESS_MODE_DISABLED
	_finish_leave.call_deferred()


func _finish_leave() -> void:
	# Detach the old world before removing its multiplayer peer. Its physics
	# callbacks must never run with a missing peer, including during teardown.
	get_tree().change_scene_to_file("res://scenes/main.tscn")
	_reset_peer()
	_leaving = false
	session_left.emit(leave_message)


# Called by the playground once it is in the tree and knows where players go.
func register_playground(root: Node3D, points: Array[Vector3], player_spawner: MultiplayerSpawner) -> void:
	spawn_root = root
	spawn_points = points
	spawner = player_spawner
	_spawn_index = 0
	if multiplayer.is_server():
		_spawn_player(1)
		for peer_id in multiplayer.get_peers():
			_spawn_player(peer_id)
	else:
		peer_ready.rpc_id(1)


# A client tells the host it has the playground loaded. Spawning before that
# would replicate a node into a scene the client has not got yet.
@rpc("any_peer", "call_remote", "reliable")
func peer_ready() -> void:
	if not multiplayer.is_server():
		return
	_spawn_player(multiplayer.get_remote_sender_id())


func _spawn_player(peer_id: int) -> void:
	if spawn_root == null or spawn_root.has_node(str(peer_id)):
		return
	if spawner == null:
		return
	var point := Vector3.ZERO
	if not spawn_points.is_empty():
		point = spawn_points[_spawn_index % spawn_points.size()]
	_spawn_index += 1
	# The name is the peer id, which is how every peer works out the authority
	# for itself without another message.
	spawner.spawn({"peer": peer_id, "position": point})
	print("PLAYGROUND_SPAWN peer=%d players=%d" % [peer_id, spawn_root.get_child_count()])


func _on_peer_connected(peer_id: int) -> void:
	print("PLAYGROUND_PEER_CONNECTED peer=%d" % peer_id)


# Host side: a peer has begun authenticating -- tell it the world.
func _on_peer_authenticating(peer_id: int) -> void:
	if multiplayer.is_server():
		(multiplayer as SceneMultiplayer).send_auth(peer_id, (AUTH_WORLD_PREFIX + world).to_utf8_buffer())


# Both sides: the other end's authentication message.
func _on_auth(peer_id: int, data: PackedByteArray) -> void:
	var text := data.get_string_from_utf8()
	var scene_multiplayer := multiplayer as SceneMultiplayer
	print("PLAYGROUND_AUTH peer=%d from=%d text=%s" % [multiplayer.get_unique_id(), peer_id, text])
	if multiplayer.is_server():
		if text == AUTH_READY:
			scene_multiplayer.complete_auth(peer_id)
		return
	if text.begins_with(AUTH_WORLD_PREFIX) and not _auth_world_loading:
		var host_world := text.trim_prefix(AUTH_WORLD_PREFIX)
		if not WORLD_SCENES.has(host_world):
			leave("호스트의 월드를 모릅니다: %s" % host_world)
			return
		if host_world != world:
			status_changed.emit("호스트의 %s 로 입장합니다." % WORLD_LABELS[host_world])
		world = host_world
		_auth_world_loading = true
		print("PLAYGROUND_WORLD_ASSIGNED peer=%d world=%s" % [multiplayer.get_unique_id(), world])
		_load_world_then_answer(peer_id)


# Client side: the world scene in, then "ready"; the host completes the
# connection and its spawner finds the PlayerSpawner here.
func _load_world_then_answer(host_id: int) -> void:
	get_tree().change_scene_to_file(WORLD_SCENES[world])
	var waited := 0
	while waited < 600:
		await get_tree().process_frame
		waited += 1
		var scene := get_tree().current_scene
		if scene != null and scene.scene_file_path == WORLD_SCENES[world] and scene.is_node_ready():
			break
	_auth_world_loading = false
	if not multiplayer.has_multiplayer_peer():
		return
	var scene_multiplayer := multiplayer as SceneMultiplayer
	scene_multiplayer.send_auth(host_id, AUTH_READY.to_utf8_buffer())
	scene_multiplayer.complete_auth(host_id)
	print("PLAYGROUND_WORLD_READY peer=%d world=%s frames=%d" % [multiplayer.get_unique_id(), world, waited])


func _on_peer_authentication_failed(peer_id: int) -> void:
	print("PLAYGROUND_AUTH_FAILED peer=%d" % peer_id)
	if not multiplayer.is_server():
		leave("호스트와 월드를 맞추지 못했습니다 (인증 시간 초과).")


func _on_peer_disconnected(peer_id: int) -> void:
	if _leaving or not multiplayer.has_multiplayer_peer() or not multiplayer.is_server() or not is_instance_valid(spawn_root):
		return
	var node := spawn_root.get_node_or_null(str(peer_id))
	if node != null:
		node.queue_free()
	print("PLAYGROUND_PEER_DISCONNECTED peer=%d" % peer_id)


func _on_connected() -> void:
	# The world scene is already in: it was loaded during authentication.
	print("PLAYGROUND_CONNECTED peer=%d world=%s" % [multiplayer.get_unique_id(), world])


func _on_connection_failed() -> void:
	leave("접속 실패: 주소, 포트, 방화벽을 확인하세요.")


func _on_server_disconnected() -> void:
	leave("호스트 연결이 종료되었습니다.")


func _reset_peer() -> void:
	is_hosting = false
	spawn_root = null
	spawner = null
	spawn_points.clear()
	_physics_requests.clear()
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	_peer = null
