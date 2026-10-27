extends Node

# Stage F, measured: only marked faces can be climbed, a side face goes up and
# down only, a faded face is still aimable, and two peers agree on where a
# climbing body is. Plus the height table the work order asks for: how high a
# ledge a body can jump onto at three strengths, which is what climb faces have
# to be placed against.

const RING_CENTRE := Vector3(-8.0, 0.0, 6.0)
const RING_RADIUS := 6.0
const HOME := Vector3(0.0, 0.9, 11.0)

var _world: Node3D
var _local: Player
var _judge: ServerAuthority
var _peer_id := 0
var _checks := 0
var _failures := 0
var _stage_done := ""
var _lag := 0.0
var _label := "0"
var _flag := false
var _reported := {}
# A lambda copies the locals it reads, so a value worked out inside one comes
# back on a field.
var _aimed := Vector3.ZERO
# A lambda copies the locals it reads, so anything a tick_request has to hand
# back lives here instead. This has caught out every stage's checks so far.
var _decided := ""
var _distance := 0.0


func expect(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("F_CHECK lag=%s peer=%d %s %s" % [_label, _peer_id, "PASS" if condition else "FAIL", label])


func note(line: String) -> void:
	print("F_NOTE lag=%s peer=%d %s" % [_label, _peer_id, line])


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
	await get_tree().create_timer(seconds + _lag * 3.0).timeout


func _beat(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _wait_stage(name_text: String) -> bool:
	var waited := 0.0
	while _stage_done != name_text and waited < 25.0 + _lag * 20.0:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	var arrived := _stage_done == name_text
	_stage_done = ""
	return arrived


func _client_peer() -> int:
	var peers := multiplayer.get_peers()
	return peers[0] if peers.size() > 0 else 0


func run(world: Node3D) -> void:
	_world = world
	_peer_id = multiplayer.get_unique_id()
	_local = Net.spawn_root.get_node(str(_peer_id)) as Player
	_judge = world.get_node_or_null("ServerAuthority") as ServerAuthority
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--f-latency="):
			_label = argument.trim_prefix("--f-latency=")
			_lag = _label.to_float() / 1000.0
	if not multiplayer.is_server():
		stage_done.rpc_id(1, "client_ready")
		return
	expect(await _wait_stage("client_ready"), "both_peers_present")
	var warnings := _judge.move_warnings
	await _marked_face_checks()
	await _side_face_checks()
	await _faded_face_check()
	await _two_peer_check()
	await _click_rule_checks()
	await _reach_table()
	expect(_judge.move_warnings == warnings, "no_move_warnings_during_stage_f")
	print("F_RESULT lag=%s peer=%d checks=%d failures=%d" % [_label, _peer_id, _checks, _failures])
	finish.rpc(_failures)
	await _wait(1.0)
	get_tree().quit(0 if _failures == 0 else 1)


# --------------------------------------------------------------------- helpers

func _ring_wall(degrees: float) -> StaticBody3D:
	return _world.find_child("ClimbWall_%d" % roundi(degrees), true, false) as StaticBody3D


func _outward(degrees: float) -> Vector3:
	var yaw := deg_to_rad(degrees)
	return Vector3(sin(yaw), 0.0, cos(yaw))


# Puts the body against a face and takes hold of it, the way the air catch does.
func _attach(degrees: float, from_behind := false) -> bool:
	var outward := _outward(degrees)
	var normal := -outward if from_behind else outward
	var face := RING_CENTRE + outward * (RING_RADIUS + (0.3 if not from_behind else -0.3)) \
		+ Vector3.UP * 1.5
	var stand := face + normal * (Player.BODY_RADIUS + 0.2)
	await tick_request(func() -> void:
		placed()
		_judge.server_respawn(_local)
		if _local.climb.is_climbing():
			_local.climb.detach(0.0)
		_local.global_position = stand
		_local.velocity = Vector3.ZERO
		_local.stamina = Tuning.values.stamina_max
		_local.movement.cancel_target())
	await _wait(0.5)
	var wall := _ring_wall(degrees)
	await tick_request(func() -> void:
		_flag = _local.climb.attach(wall, face, normal))
	await _wait(0.3)
	return _flag


# ------------------------------------- every face that stands up can be climbed

func _marked_face_checks() -> void:
	var wall := _ring_wall(0.0)
	expect(wall != null, "the_ring_wall_exists")
	if wall == null:
		return
	expect((wall.collision_layer & Playground.CLIMBABLE_LAYER) != 0,
		"the_wall_is_on_the_climbable_layer")
	# F follow-up: the wall is what is marked, not one face of it, so the green
	# panel that used to name a single side is gone.
	expect(wall.find_child("ClimbFace", false, false) == null,
		"no_single_face_is_singled_out_any_more")

	expect(await _attach(0.0), "the_face_pointing_at_the_camera_can_be_climbed")
	expect(_local.climb.is_climbing(), "and_the_body_is_on_it")
	await tick_request(func() -> void: _local.climb.detach(0.0))
	await _wait(0.8)

	# The back of the same wall stands up from the ground too, so it holds.
	var held := await _attach(0.0, true)
	note("the back of the same wall: attached=%s state=%s" % [
		held, Player.State.keys()[_local.state]])
	expect(held, "the_back_of_the_same_wall_holds_as_well")
	expect(_local.climb.is_climbing(), "and_the_body_is_on_that_too")
	await tick_request(func() -> void: _local.climb.detach(0.0))
	await _wait(0.5)

	# A top is not a face: it is somewhere to stand, and the rule says so
	# without needing a body put on one.
	expect(not PlayerClimb.face_is_climbable(wall, Vector3.UP),
		"the_top_of_a_climb_wall_is_not_a_climbing_face")
	expect(PlayerClimb.face_is_climbable(wall, _outward(0.0)),
		"and_a_side_of_it_is")
	var smooth := _world.find_child("SmoothWall", true, false) as CollisionObject3D
	expect(smooth != null and not PlayerClimb.face_is_climbable(smooth, Vector3(0.0, 0.0, 1.0)),
		"a_smooth_wall_is_still_not_climbable")
	await _wait(0.3)


# ------------------------------------ what the right button means, by surface

func _click_rule_checks() -> void:
	var boundary := _world.get_node_or_null("TimeBoundary") as TimeBoundary
	# The slab lives under the navigation region so it is part of the bake, so
	# the boundary's own handle on it is what finds it, not a path.
	var face := boundary.face as CollisionObject3D if boundary != null else null
	expect(face != null, "the_3m_cut_face_exists")
	if face == null:
		return
	await tick_request(func() -> void:
		placed()
		_judge.server_respawn(_local)
		if _local.climb.is_climbing():
			_local.climb.detach(0.0)
		_local.global_position = HOME
		_local.movement.cancel_target())
	await _wait(0.5)

	# The grass on top of the 3 m ledge. This is the one that used to hang the
	# body off the face instead of walking it anywhere.
	var top := Vector3(TimeBoundary.SEAM.x, TimeBoundary.TOP_Y, boundary.face_z() - 1.0)
	await tick_request(func() -> void:
		_decided = _local.movement.order_from_surface(face, top, Vector3.UP)
		_distance = _local.movement.climb_request_distance())
	note("right click on the ledge top: decided=%s climb_request=%.2f" % [_decided, _distance])
	expect(_decided == "move", "clicking_the_top_of_a_climb_wall_is_a_move")
	expect(_distance < 0.0, "and_leaves_no_climb_order_behind")

	# The face of the same body, pointed at head on.
	var front := Vector3(TimeBoundary.SEAM.x, 1.5, boundary.face_z())
	await tick_request(func() -> void:
		_decided = _local.movement.order_from_surface(face, front, Vector3(0.0, 0.0, 1.0)))
	note("right click on the same body's face: decided=%s" % _decided)
	expect(_decided == "climb", "clicking_a_climbable_face_head_on_is_a_climb")

	# A wall that is not climbable is neither.
	var smooth := _world.find_child("SmoothWall", true, false) as CollisionObject3D
	await tick_request(func() -> void:
		_decided = _local.movement.order_from_surface(
			smooth, smooth.global_position + Vector3(0.0, 0.0, 0.4), Vector3(0.0, 0.0, 1.0)))
	note("right click on the smooth wall: decided=%s" % _decided)
	expect(_decided == "none", "clicking_a_wall_that_is_not_climbable_orders_nothing")

	# Space, aimed at a climbable face: a jump, never a climb order.
	await tick_request(func() -> void: _local.movement.cancel_target())
	var wall := _ring_wall(0.0)
	var wall_face := RING_CENTRE + _outward(0.0) * (RING_RADIUS + 0.3) + Vector3.UP * 2.0
	await tick_request(func() -> void:
		placed()
		_local.global_position = wall_face + _outward(0.0) * 2.0
		_local.global_position.y = 0.9
		_local.velocity = Vector3.ZERO)
	await _wait(0.5)
	await tick_request(func() -> void:
		_local.movement.set_aim_override(wall_face)
		# Pressed the way the key is pressed, then cast: with the smart key off
		# the press arms and the left button casts, and the point is that
		# neither step ever turns into a climb order.
		_local.movement.press_jump()
		_local.movement.cast_armed())
	await _beat(1.6)
	await tick_request(func() -> void:
		_local.movement.set_aim_override(Vector3.INF)
		_distance = _local.movement.climb_request_distance()
		_decided = Player.State.keys()[_local.state])
	note("space aimed at a climb face: climb_request=%.2f state=%s" % [_distance, _decided])
	expect(_distance < 0.0, "space_never_becomes_a_climb_order")
	expect(not _local.climb.is_climbing(), "and_does_not_put_the_body_on_the_wall")
	await _wait(0.4)


# ------------------------------------------- a side face goes up and down only

func _side_face_checks() -> void:
	# Which of the ring's faces is a side face is a fact about the camera, so
	# it is read rather than assumed.
	var alignments := PackedStringArray()
	var side_degrees := -1.0
	var front_degrees := -1.0
	for degrees in Playground.CLIMB_RING_ANGLES:
		var forward := _local.camera.get_camera_flat_forward()
		var alignment: float = absf(_outward(float(degrees)).dot(forward))
		alignments.append("%d:%.2f" % [int(degrees), alignment])
		if alignment <= PlayerClimb.SIDE_FACE_LIMIT and side_degrees < 0.0:
			side_degrees = float(degrees)
		if alignment > PlayerClimb.SIDE_FACE_LIMIT and front_degrees < 0.0:
			front_degrees = float(degrees)
	note("face alignment to the view (limit %.2f): %s" % [
		PlayerClimb.SIDE_FACE_LIMIT, " ".join(alignments)])
	if side_degrees < 0.0:
		expect(false, "the_ring_has_a_side_face")
		return
	expect(true, "the_ring_has_a_side_face")

	# A front face takes an order in any direction.
	if front_degrees >= 0.0 and await _attach(front_degrees):
		var before := _local.global_position
		var face := RING_CENTRE + _outward(front_degrees) * (RING_RADIUS + 0.3) + Vector3.UP * 1.5
		var across := Vector3(-_outward(front_degrees).z, 0.0, _outward(front_degrees).x)
		await tick_request(func() -> void:
			_local.climb.set_wall_target(face + across * 1.2 + Vector3.UP * 1.5))
		await _wait(2.0)
		var rose := _local.global_position.y - before.y
		var sideways := Vector2(_local.global_position.x - before.x,
			_local.global_position.z - before.z).length()
		note("front face (%d deg): rose %.2f m, moved %.2f m across" % [
			int(front_degrees), rose, sideways])
		expect(rose > 0.3 and sideways > 0.3, "a_front_face_can_be_climbed_in_any_direction")
		await tick_request(func() -> void: _local.climb.detach(0.0))
		await _wait(0.8)
	else:
		expect(false, "a_front_face_can_be_climbed_in_any_direction")

	# A side face drops the sideways half of the order.
	expect(await _attach(side_degrees), "the_side_face_can_be_climbed")
	expect(_local.climb.is_side_face(), "and_is_judged_a_side_face")
	var before_side := _local.global_position
	var side_face := RING_CENTRE + _outward(side_degrees) * (RING_RADIUS + 0.3) + Vector3.UP * 1.5
	var sideways_dir := Vector3(-_outward(side_degrees).z, 0.0, _outward(side_degrees).x)
	await tick_request(func() -> void:
		_local.climb.set_wall_target(side_face + sideways_dir * 1.5 + Vector3.UP * 1.5))
	await _wait(2.0)
	var side_rose := _local.global_position.y - before_side.y
	var side_across := Vector2(_local.global_position.x - before_side.x,
		_local.global_position.z - before_side.z).length()
	note("side face (%d deg): rose %.2f m, moved %.2f m across (the order asked for 1.5 m across)" % [
		int(side_degrees), side_rose, side_across])
	expect(side_rose > 0.3, "a_side_face_still_goes_up")
	expect(side_across < 0.3, "but_not_sideways")
	await tick_request(func() -> void: _local.climb.detach(0.0))
	await _wait(0.8)


# ------------------------------- a face turned away from the view is still aimable

func _faded_face_check() -> void:
	# The face that points most nearly away from the camera: the one the fader
	# takes out of the drawing and out of the click ray.
	var away_degrees := 0.0
	var worst := 2.0
	for degrees in Playground.CLIMB_RING_ANGLES:
		var alignment := _outward(float(degrees)).dot(_local.camera.get_camera_flat_forward())
		if alignment < worst:
			worst = alignment
			away_degrees = float(degrees)
	if not await _attach(away_degrees):
		expect(false, "the_turned_away_face_can_be_climbed")
		return
	expect(true, "the_turned_away_face_can_be_climbed")
	var face := RING_CENTRE + _outward(away_degrees) * (RING_RADIUS + 0.3) + Vector3.UP * 1.5
	var before := _local.global_position
	# Aimed with a camera ray, which is what a click is -- and the wall's own
	# plane is what solves it, not a physics query, so a faded face is as
	# aimable as any other.
	_aimed = Vector3.ZERO
	await tick_request(func() -> void:
		var target := face + Vector3.UP * 2.0
		var origin := _local.camera.camera.global_position
		_local.climb.aim_at(origin, (target - origin).normalized())
		_aimed = _local.climb.wall_target())
	await _wait(2.0)
	var rose := _local.global_position.y - before.y
	note("face turned away (%d deg, alignment %.2f): the click solved to y=%.2f and the body rose %.2f m" % [
		int(away_degrees), worst, _aimed.y, rose])
	expect(_aimed != Vector3.ZERO, "a_click_on_a_faded_face_still_finds_the_wall")
	expect(rose > 0.3, "and_the_body_moves_to_it")
	await tick_request(func() -> void: _local.climb.detach(0.0))
	await _wait(0.8)


# ------------------------------------------- the two screens agree

func _two_peer_check() -> void:
	var mate := _judge.actor_for(_client_peer())
	_judge.forgive_move(_client_peer(), "", 30)
	client_climb.rpc_id(_client_peer(), 0.0)
	expect(await _wait_stage("climbing"), "the_client_climbed")
	await _wait(1.0)
	_reported.erase("climb")
	report_position.rpc_id(_client_peer(), mate.get_path(), "climb")
	var waited := 0.0
	while not _reported.has("climb") and waited < 10.0 + _lag * 20.0:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	if not _reported.has("climb"):
		expect(false, "the_climbing_body_is_in_the_same_place_on_both_screens")
		return
	var theirs: Vector3 = _reported["climb"]
	var gap := mate.global_position.distance_to(theirs)
	note("climbing body: host sees (%.2f, %.2f, %.2f), client sees (%.2f, %.2f, %.2f), gap %.3f m" % [
		mate.global_position.x, mate.global_position.y, mate.global_position.z,
		theirs.x, theirs.y, theirs.z, gap])
	expect(gap < 0.5, "the_climbing_body_is_in_the_same_place_on_both_screens")
	client_detach.rpc_id(_client_peer())
	await _wait(1.2)


# ----------------------------- how high a ledge a jump can reach, by strength

func _reach_table() -> void:
	for strength in [10.0, 20.0, 30.0]:
		await tick_request(func() -> void:
			placed()
			_judge.server_respawn(_local)
			_local.stats.strength = float(strength)
			_local.global_position = HOME
			_local.velocity = Vector3.ZERO
			_local.movement.cancel_target())
		await _wait(0.6)
		var cap := _local.leap_speed_cap()
		var highest := 0.0
		var rungs := PackedStringArray()
		for height in [0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0]:
			var rung := _world.find_child("Step_%s" % String.num(float(height), 1).replace(".", "_"), true, false) as Node3D
			if rung == null:
				continue
			var onto := await _jump_onto(rung, float(height))
			rungs.append("%.1f:%s" % [float(height), "yes" if onto else "no"])
			if onto:
				highest = maxf(highest, float(height))
		# And the 3 m climb ledge. Tried from the same stand-offs as the rungs:
		# it is the one ledge in the map at that height, so whether a strong
		# body can jump it rather than climb it is worth knowing.
		var boundary := _world.get_node_or_null("TimeBoundary") as TimeBoundary
		var ledge := false
		if boundary != null:
			# Stood close in. The height a leap can reach falls away with the
			# distance to it -- solving v^2 >= g(h + sqrt(d^2 + h^2)) for h
			# gives h = (B^2 - d^2) / 2B with B = cap^2/g -- so a table taken
			# from four metres out would be measuring the distance, not the
			# strength.
			for stand_off: float in STAND_OFFS:
				ledge = await _jump_onto_point(
					Vector3(TimeBoundary.SEAM.x, 0.9, boundary.face_z() + stand_off),
					Vector3(TimeBoundary.SEAM.x, TimeBoundary.TOP_Y + Player.BODY_HALF_HEIGHT,
						boundary.face_z() - 1.0),
					TimeBoundary.TOP_Y)
				if ledge:
					break
			rungs.append("%.1f:%s" % [TimeBoundary.TOP_Y, "yes" if ledge else "no"])
			if ledge:
				highest = maxf(highest, TimeBoundary.TOP_Y)
		var budget := cap * cap / maxf(Tuning.values.gravity, 0.01)
		var reach_at_one := (budget * budget - 1.0) / (2.0 * budget)
		note("strength %.0f: cap %.2f, standing apex %.2f m, ledge the budget allows from 1 m out %.2f m | rungs %s -> highest actually reached %.1f m" % [
			strength, cap, budget * 0.5, reach_at_one, " ".join(rungs), highest])
		expect(highest > 0.0, "a_body_at_strength_%.0f_can_get_onto_something" % strength)
	await tick_request(func() -> void: _local.stats.strength = 10.0)


# F follow-up: the old table jumped from 3 m back at every height, so what it
# measured was the walk-up, not the strength -- the reach a leap has falls away
# with the distance to the ledge. One stand-off is not enough either: close in,
# a steep launch scrapes up the rung's own face and loses its forward travel,
# and far out the budget runs out of height. So a few are tried and the answer
# is whether any of them gets the body up there, which is the question being
# asked.
const STAND_OFFS := [1.0, 2.0]
const AIM_INSETS := [0.6, 1.5]


func _jump_onto(rung: Node3D, height: float) -> bool:
	var near_face := rung.global_position.z - 1.5
	for stand_off: float in STAND_OFFS:
		for inset: float in AIM_INSETS:
			var onto := await _jump_onto_point(
				Vector3(rung.global_position.x, 0.9, near_face - stand_off),
				Vector3(rung.global_position.x, height + Player.BODY_HALF_HEIGHT,
					near_face + inset),
				height)
			if onto:
				return true
	return false


func _jump_onto_point(from: Vector3, aim: Vector3, height: float) -> bool:
	await tick_request(func() -> void:
		placed()
		if _local.state == Player.State.DEAD:
			_judge.server_respawn(_local)
		_local.global_position = from
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target())
	await _wait(0.5)
	await tick_request(func() -> void:
		_local.movement.set_aim_override(aim)
		_local.movement.cast_jump())
	await _beat(2.4)
	await tick_request(func() -> void: _local.movement.set_aim_override(Vector3.INF))
	return _local.global_position.y > height + 0.5 and _local.is_grounded_state()


# --------------------------------------------------------------------- RPCs

@rpc("any_peer", "call_remote", "reliable")
func stage_done(name_text: String) -> void:
	if multiplayer.is_server() and multiplayer.get_peers().has(multiplayer.get_remote_sender_id()):
		_stage_done = name_text


@rpc("any_peer", "call_remote", "reliable")
func report_back(what: String, where: Vector3) -> void:
	if multiplayer.is_server() and multiplayer.get_peers().has(multiplayer.get_remote_sender_id()):
		_reported[what] = where


@rpc("authority", "call_remote", "reliable")
func report_position(path: NodePath, what: String) -> void:
	var body := get_node_or_null(path) as Node3D
	if body != null:
		report_back.rpc_id(1, what, body.global_position)


@rpc("authority", "call_remote", "reliable")
func client_climb(degrees: float) -> void:
	var yaw := deg_to_rad(degrees)
	var outward := Vector3(sin(yaw), 0.0, cos(yaw))
	var face := RING_CENTRE + outward * (RING_RADIUS + 0.3) + Vector3.UP * 1.5
	var wall := _world.find_child("ClimbWall_%d" % roundi(degrees), true, false) as StaticBody3D
	await tick_request(func() -> void:
		placed()
		_local.global_position = face + outward * (Player.BODY_RADIUS + 0.2)
		_local.velocity = Vector3.ZERO
		_local.stamina = Tuning.values.stamina_max
		_local.movement.cancel_target())
	await _wait(0.5)
	await tick_request(func() -> void:
		if _local.climb.attach(wall, face, outward):
			_local.climb.set_wall_target(face + Vector3.UP * 1.5))
	await _wait(1.5)
	expect(_local.climb.is_climbing(), "the_client_is_on_the_wall")
	stage_done.rpc_id(1, "climbing")


@rpc("authority", "call_remote", "reliable")
func client_detach() -> void:
	await tick_request(func() -> void:
		if _local.climb.is_climbing():
			_local.climb.detach(0.0))


@rpc("authority", "call_remote", "reliable")
func finish(host_failures: int) -> void:
	print("F_RESULT lag=%s peer=%d checks=%d failures=%d host_failures=%d" % [
		_label, _peer_id, _checks, _failures, host_failures])
	get_tree().quit(0 if _failures == 0 else 1)
