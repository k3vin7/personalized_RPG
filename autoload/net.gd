extends Node

# Host and join, and the player spawn that only the host performs. Scene changes
# are driven from here so the menu never has to know about the playground.

const DEFAULT_PORT := 7777
const MAX_PEERS := 4
const PLAYER_SCENE := "res://scenes/player.tscn"
const PLAYGROUND_SCENE := "res://scenes/playground.tscn"

signal status_changed(message: String)
signal session_left(message: String)
signal playground_ready(playground: Node3D)

var is_hosting := false
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


func _ready() -> void:
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
	print("PLAYGROUND_HOST_READY port=%d" % port)
	get_tree().change_scene_to_file(PLAYGROUND_SCENE)
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


@rpc("any_peer", "call_remote", "reliable")
func request_tuning() -> void:
	if not multiplayer.is_server():
		return
	send_tuning.rpc_id(multiplayer.get_remote_sender_id(), Tuning.export_values())


@rpc("authority", "call_remote", "reliable")
func send_tuning(incoming: Dictionary) -> void:
	Tuning.import_values(incoming)
	print("PLAYGROUND_TUNING_PULLED fields=%d" % incoming.size())


func _on_peer_connected(peer_id: int) -> void:
	print("PLAYGROUND_PEER_CONNECTED peer=%d" % peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	if _leaving or not multiplayer.has_multiplayer_peer() or not multiplayer.is_server() or not is_instance_valid(spawn_root):
		return
	var node := spawn_root.get_node_or_null(str(peer_id))
	if node != null:
		node.queue_free()
	print("PLAYGROUND_PEER_DISCONNECTED peer=%d" % peer_id)


func _on_connected() -> void:
	print("PLAYGROUND_CONNECTED peer=%d" % multiplayer.get_unique_id())
	get_tree().change_scene_to_file(PLAYGROUND_SCENE)


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
