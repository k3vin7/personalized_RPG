extends Node

# 건물 진입: the inside of a building is a matter of each screen alone. With
# two players, what one screen does must not reach the other, and each
# screen must draw the other body by the one rule -- drawn while it stands on
# something that is drawn.
#
#   host:   --auto-host --auto-smoke --auto-only=BI --auto-port=P --auto-quit=520
#   client: --auto-join --auto-smoke --auto-only=BI --auto-port=P --auto-quit=520
#
# Both peers put maps/zone_5.tscn far off the playground (as ST does) and the
# two bodies are set down in the pub -- cellar, ground floor, upstairs, the
# landing, outside -- in ten pairings. There is no navigation bake out there,
# so nobody walks: a body is put on its spot and read once its screen has
# settled.
#
# What is read, on both screens, for every pairing:
#   - which storey this screen says its own body is on;
#   - whether the other body is drawn here (the layer its meshes are on);
#   - that both screens have each body in the same place, standing (the wall
#     pieces, floor slabs and stairs are the same colliders on both);
# and once, from outside: with the other player in the building, this screen
# still draws the whole building. The server's move check has to stay quiet
# throughout.

const STEP := 1.0 / 120.0
const ZONE_AT := Vector3(-1000.0, 100.0, -1000.0)
# The pub's place in the map piece.
const PUB_AT := Vector3(9.0, 0.0, 2.0)
# After both bodies are set down: the replication, the fade in or out of a
# building and the actors' turn (InteriorView.ACTOR_PERIOD).
const SETTLE := 1.6
const SAME_PLACE := 0.15

# name -> [where the feet are in the pub, the storey a screen should say, on
# a landing, how high (for "is the other drawn": -1 cellar, 0 outside), and
# -- where a storey has more than one -- which space of it (the rooms that
# open into each other)]
const PLACES := {
	"cellar": [Vector3(13.0, -3.0, 20.0), "storey_b1", false, -1],
	"ground": [Vector3(14.5, 0.5, 11.5), "storey_1", false, 1, "hall"],
	"ground_b": [Vector3(10.6, 0.5, 18.5), "storey_1", false, 1, "hall"],
	"kitchen": [Vector3(13.0, 0.5, 24.0), "storey_1", false, 1, "kitchen"],
	"second": [Vector3(15.5, 3.5, 12.0), "storey_2", false, 2, "hall"],
	"second_room": [Vector3(11.5, 3.5, 13.3), "storey_2", false, 2, "room_w2"],
	"landing": [Vector3(4.0, 3.5, 24.7), "storey_2", true, 2],
	"third": [Vector3(14.0, 6.5, 23.0), "storey_3", false, 3],
	"outside": [Vector3(4.0, 0.5, 8.0), "", false, 0],
}
# [host's place, client's place]
const PAIRS := [
	["ground", "ground_b"], ["ground", "second"], ["ground", "outside"], ["ground", "cellar"],
	["second", "ground"], ["second", "third"], ["cellar", "ground"], ["outside", "ground"],
	["landing", "ground"], ["third", "second"], ["ground", "kitchen"], ["kitchen", "ground_b"], ["second", "second_room"],
]

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
	print("BI_CHECK peer=%d %s %s" % [_peer_id, "PASS" if condition else "FAIL", label])


func note(line: String) -> void:
	print("BI_NOTE peer=%d %s" % [_peer_id, line])


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


func _take_report(key: String, seconds := 30.0) -> Dictionary:
	var waited := 0.0
	while not _reports.has(key) and waited < seconds:
		await get_tree().create_timer(0.05).timeout
		waited += 0.05
	expect(_reports.has(key), "the_client_reported_%s" % key)
	var out: Dictionary = _reports.get(key, {})
	_reports.erase(key)
	return out


func _client_peer() -> int:
	var peers := multiplayer.get_peers()
	return peers[0] if peers.size() > 0 else 0


# The other player's body, on this machine.
func _other() -> Player:
	for child in Net.spawn_root.get_children():
		var body := child as Player
		if body != null and body != _local:
			return body
	return null


# Where a body stands for a place: its feet on the place, in the world.
func _spot(place: String) -> Vector3:
	return ZONE_AT + PUB_AT + (PLACES[place][0] as Vector3) + Vector3(0.0, _local.half_height() + 0.02, 0.0)


func run(world: Node3D) -> void:
	_world = world
	_peer_id = multiplayer.get_unique_id()
	var waited := 0.0
	while Net.spawn_root.get_node_or_null(str(_peer_id)) == null and waited < 15.0:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	_local = Net.spawn_root.get_node(str(_peer_id)) as Player
	_judge = world.get_node_or_null("ServerAuthority") as ServerAuthority
	var zone := (load("res://maps/zone_5.tscn") as PackedScene).instantiate() as Node3D
	zone.name = "BiZone"
	_world.add_child(zone)
	zone.global_position = ZONE_AT
	# The CSG pieces build their colliders after they enter the tree.
	await _wait(1.0)
	# The map piece came after this screen sorted the world into "outside".
	if _local.interior_view != null:
		_local.interior_view.retag()
	if not multiplayer.is_server():
		stage_done.rpc_id(1, "client_ready")
		return
	expect(await _wait_stage("client_ready"), "both_peers_present")
	var warnings := _judge.move_warnings
	var corrections := _judge.move_corrections
	for pair: Array in PAIRS:
		await _pairing(String(pair[0]), String(pair[1]))
	note("move warnings %d, corrections %d during BI" % [
		_judge.move_warnings - warnings, _judge.move_corrections - corrections])
	expect(_judge.move_warnings == warnings, "no_move_warnings_during_bi")
	expect(_judge.move_corrections == corrections, "no_corrections_during_bi")
	print("BI_RESULT peer=%d checks=%d failures=%d" % [_peer_id, _checks, _failures])
	finish.rpc(_failures)
	await _wait(1.0)
	get_tree().quit(0 if _failures == 0 else 1)


# Whether a screen whose body is at `viewer` draws a body at `other`.
static func _should_see(viewer: String, other: String) -> bool:
	var mine: int = PLACES[viewer][3]
	var theirs: int = PLACES[other][3]
	# From outside, everybody; from inside, whoever is on the same storey and
	# in the same space of it.
	if mine == 0:
		return true
	var my_space: String = PLACES[viewer][4] if PLACES[viewer].size() > 4 else ""
	var their_space: String = PLACES[other][4] if PLACES[other].size() > 4 else ""
	return theirs == mine and my_space == their_space


func _pairing(host_place: String, client_place: String) -> void:
	var tag := "%s_and_%s" % [host_place, client_place]
	await _park(_spot(host_place))
	client_park.rpc_id(_client_peer(), _spot(client_place))
	await _wait(SETTLE)
	var mine := _read()
	client_read.rpc_id(_client_peer(), tag)
	var theirs := await _take_report(tag)
	note("%s: host says %s | client says %s" % [tag, mine, theirs])
	for side: Array in [["host", host_place, client_place, mine, theirs], ["client", client_place, host_place, theirs, mine]]:
		var who: String = side[0]
		var at: String = side[1]
		var other_at: String = side[2]
		var got: Dictionary = side[3]
		var other_got: Dictionary = side[4]
		expect(String(got.get("storey", "?")) == String(PLACES[at][1]) and bool(got.get("landing", false)) == bool(PLACES[at][2]),
			"%s_at_%s_is_on_the_storey_it_stands_on__%s" % [who, at, tag])
		expect(bool(got.get("sees_other", false)) == _should_see(at, other_at),
			"%s_at_%s_%s_the_other_at_%s" % [who, at, "draws" if _should_see(at, other_at) else "does_not_draw", other_at])
		expect(bool(got.get("on_floor", false)), "%s_stands_at_%s__%s" % [who, at, tag])
		var own: Vector3 = got.get("at", Vector3.INF)
		var seen_there: Vector3 = other_got.get("other_at", Vector3.INF)
		expect(own.distance_to(seen_there) <= SAME_PLACE,
			"%s_at_%s_is_in_the_same_place_on_both_screens__%s" % [who, at, tag])
	if host_place == "outside":
		# With the other player inside, this screen draws the whole building.
		expect(bool(mine.get("building_whole", false)) and int(mine.get("mask", 0)) == 0xFFFFF,
			"from_outside_the_building_is_drawn_whole_while_the_other_is_in_it")


func _park(spot: Vector3) -> void:
	placed()
	await Harness.forgive_lead(get_tree(), placed)
	await tick_request(func() -> void:
		_local.global_position = spot
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target()
		_local.movement.set_aim_override(Vector3.INF))


# What this screen says: its own storey, whether the other body is drawn,
# where both bodies are, and whether the building stands whole.
func _read() -> Dictionary:
	var view := _local.interior_view
	var other := _other()
	var sees := false
	if other != null:
		for found in other.find_children("*", "VisualInstance3D", true, false):
			var drawn := found as VisualInstance3D
			if drawn is Light3D or not drawn.is_visible_in_tree():
				continue
			sees = (drawn.layers & _local.camera.camera.cull_mask) != 0
			break
	var whole := true
	var pub := _world.get_node_or_null("BiZone/pub")
	if pub != null:
		for child in pub.get_children():
			var part := child as Node3D
			if part != null and not part.visible:
				whole = false
			var storey := child as BuildingInterior
			if storey == null:
				continue
			for piece: Dictionary in storey.pieces:
				var mesh := (piece["meshes"] as Array)[0] as MeshInstance3D
				if not mesh.visible or mesh.transform.basis.y.length() < 0.99:
					whole = false
	return {
		"storey": String(view.storey.name) if view != null and is_instance_valid(view.storey) else "",
		"landing": view != null and view.on_landing,
		"sees_other": sees,
		"on_floor": _local.is_on_floor(),
		"at": _local.global_position,
		"other_at": other.global_position if other != null else Vector3.INF,
		"mask": _local.camera.camera.cull_mask,
		"building_whole": whole,
	}


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
func client_park(point: Vector3) -> void:
	await _park(point)


@rpc("authority", "call_remote", "reliable")
func client_read(key: String) -> void:
	report.rpc_id(1, key, _read())


@rpc("authority", "call_remote", "reliable")
func finish(failures: int) -> void:
	print("BI_RESULT peer=%d checks=%d failures=%d (host's count %d)" % [_peer_id, _checks, _failures, failures])
	await _wait(0.5)
	get_tree().quit(0 if failures == 0 else 1)
