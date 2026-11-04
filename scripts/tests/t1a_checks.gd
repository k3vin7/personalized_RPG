extends Node

# T-1a: Terrain3D installed and loading. Both peers put an empty Terrain3D
# node into the playground and read it back: the extension's classes exist,
# the version, the data and collision objects it builds on entering the tree,
# the collision modes it offers, and that an empty terrain answers a height
# query with NAN (no region). The client reports the same to the host. No
# terrain data yet; that is T-1b.

var _world: Node3D
var _local: Player
var _judge: ServerAuthority
var _peer_id := 0
var _checks := 0
var _failures := 0
var _stage_done := ""
var _reports := {}


func expect(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("T1A_CHECK peer=%d %s %s" % [_peer_id, "PASS" if condition else "FAIL", label])


func note(line: String) -> void:
	print("T1A_NOTE peer=%d %s" % [_peer_id, line])


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


func run(world: Node3D) -> void:
	_world = world
	_peer_id = multiplayer.get_unique_id()
	_local = Net.spawn_root.get_node(str(_peer_id)) as Player
	_judge = world.get_node_or_null("ServerAuthority") as ServerAuthority
	if not multiplayer.is_server():
		stage_done.rpc_id(1, "client_ready")
		return
	expect(await _wait_stage("client_ready"), "both_peers_present")
	var warnings := _judge.move_warnings
	var corrections := _judge.move_corrections
	var own := await _probe()
	note("host: %s" % [own])
	expect(bool(own.get("loaded", false)), "the_terrain3d_extension_is_loaded_on_the_host")
	expect(String(own.get("version", "")).begins_with("1.1."), "and_it_is_the_1_1_release")
	expect(bool(own.get("in_tree", false)) and bool(own.get("data", false)) and bool(own.get("collision", false)),
		"an_empty_terrain_node_enters_the_scene_with_its_data_and_collision_objects")
	expect(bool(own.get("empty_height_nan", false)), "an_empty_terrain_answers_a_height_query_with_nan")
	expect(int(own.get("modes", 0)) == 5, "the_collision_modes_are_disabled_dynamic_full_x_game_editor")
	_reports.erase("probe")
	client_probe.rpc_id(_client_peer())
	if await _wait_report("probe"):
		var theirs: Dictionary = _reports["probe"]
		note("client: %s" % [theirs])
		expect(bool(theirs.get("loaded", false)) and bool(theirs.get("in_tree", false))
			and String(theirs.get("version", "")) == String(own.get("version", "")),
			"the_client_loads_the_same_terrain3d_and_opens_the_empty_terrain_too")
	expect(_judge.move_warnings == warnings, "no_move_warnings_during_t1a")
	expect(_judge.move_corrections == corrections, "no_corrections_during_t1a")
	print("T1A_RESULT peer=%d checks=%d failures=%d" % [_peer_id, _checks, _failures])
	finish.rpc(_failures)
	await _wait(1.0)
	get_tree().quit(0 if _failures == 0 else 1)


# Adds an empty Terrain3D to the world for a moment and reads it.
func _probe() -> Dictionary:
	var out := {"loaded": ClassDB.class_exists("Terrain3D"), "headless": DisplayServer.get_name() == "headless"}
	if not bool(out["loaded"]):
		return out
	var terrain: Node3D = ClassDB.instantiate("Terrain3D")
	terrain.name = "T1aTerrain"
	# Headless has no camera: the clipmap follows the local body instead, which
	# is also what a dedicated server would do.
	terrain.set("clipmap_target", _local)
	_world.add_child(terrain)
	for _frame in range(3):
		await get_tree().physics_frame
	out["version"] = terrain.get_version()
	out["in_tree"] = terrain.is_inside_tree()
	var data: Object = terrain.get("data")
	var collision: Object = terrain.get("collision")
	out["data"] = data != null
	out["collision"] = collision != null
	if data != null:
		var h: float = data.get_height(Vector3(1.0, 0.0, 1.0))
		out["empty_height_nan"] = is_nan(h)
		out["region_count"] = (data.get("region_count") if "region_count" in data else -1)
	if collision != null:
		out["collision_mode"] = collision.get("mode")
		var props := []
		for prop in collision.get_property_list():
			var pname := String(prop["name"])
			if int(prop["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE == 0 and int(prop["usage"]) & PROPERTY_USAGE_EDITOR != 0:
				props.append("%s=%s" % [pname, collision.get(pname)])
		out["collision_props"] = props
	out["modes"] = ClassDB.class_get_integer_constant_list("Terrain3DCollision", true).size()
	out["mode_names"] = Array(ClassDB.class_get_integer_constant_list("Terrain3DCollision", true))
	terrain.queue_free()
	await get_tree().physics_frame
	return out


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
func client_probe() -> void:
	var out := await _probe()
	report.rpc_id(1, "probe", out)


@rpc("authority", "call_remote", "reliable")
func finish(host_failures: int) -> void:
	print("T1A_RESULT peer=%d checks=%d failures=%d host_failures=%d" % [
		_peer_id, _checks, _failures, host_failures])
	get_tree().quit(0 if _failures == 0 else 1)
