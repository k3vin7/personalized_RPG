class_name PlayerMovement
extends Node

# Click to move. Only the local player ever runs this.
#
# Waypoints are consumed in XZ, not in 3D: the body origin sits a capsule half
# height above the navigation surface, so a 3D distance test never reaches a
# waypoint and the character stalls on top of it.

const DRAG_RETARGET_INTERVAL := 0.1
const CLICK_MASK := 1 | 2 | 4 | 16  # World, Wall, Climbable, Throwable
const ARRIVE_TOLERANCE := 0.3
const PATH_LOOKAHEAD := 0.75
const PATH_QUERY_RETRIES := 4
# A click whose path ends further than this from where it was aimed did not
# reach: the target is across something.
const UNREACHABLE_DISTANCE := 0.5
# Pressing a touch early or a touch late still jumps.
const JUMP_BUFFER := 0.1
const COYOTE_TIME := 0.1
# How far out a wall still counts as within reach when the catch is attempted.
# Longer than the jump buffer on purpose: a catch is aimed at a wall you are
# still travelling towards, so the press lands well before the contact does.
const CATCH_BUFFER := 0.3
const CATCH_REACH := 0.3
const CATCH_PROBES := 8
# DOC: the stand in for a shield bash until there is a shield. Ground only.
const SHOVE_REACH := 1.5
const SHOVE_HALF_ANGLE := 45.0
# Allies are given a little extra, so a push that looked connected on the
# pusher's screen still counts after the trip over the network.
const SHOVE_ALLY_BONUS := 0.3
const SHOVE_COOLDOWN := 0.6
const CARRY_SPEED_SCALE := 0.7

var player: Player

var _agent: NavigationAgent3D
var _has_target := false
var _target := Vector3.ZERO
var _path := PackedVector3Array()
var _path_index := 0
var _pending_frames := 0
var _path_dirty := false
var _retries := 0
var _drag_left := 0.0
var _jump_buffer_left := 0.0
var _coyote_left := 0.0
var _catch_buffer_left := 0.0
var _aim_override := Vector3.INF
var _shove_cooldown_left := 0.0
var _intent_direction := Vector3.ZERO
var _intent_left := 0.0
var _pending_air_target: Variant = null
var _dash_left := 0.0
var _dash_direction := Vector3.ZERO
var _dash_cooldown_left := 0.0
var _climb_wall: CollisionObject3D
var _climb_point := Vector3.ZERO
var _climb_normal := Vector3.ZERO


func setup(owner_player: Player) -> void:
	player = owner_player
	_agent = NavigationAgent3D.new()
	_agent.name = "NavigationAgent3D"
	# Lifts returned points to the body origin so our own XZ consumption lines
	# up with where the body actually is.
	_agent.path_height_offset = Player.BODY_HALF_HEIGHT
	_agent.radius = Player.BODY_RADIUS
	_agent.avoidance_enabled = false
	player.add_child(_agent)
	set_physics_process(true)


func cancel_target() -> void:
	_has_target = false
	_path.clear()
	_path_index = 0
	_retries = 0
	_path_dirty = false


# Same path the key takes: the buffer is the only way in, so a test and a key
# press go through identical code.
func request_jump() -> void:
	_jump_buffer_left = JUMP_BUFFER
	_catch_buffer_left = CATCH_BUFFER


func has_target() -> bool:
	return _has_target


func intent_direction() -> Vector3:
	return _intent_direction


func intent_seconds_left() -> float:
	return _intent_left


func _clear_intent() -> void:
	_intent_direction = Vector3.ZERO
	_intent_left = 0.0


func set_target(world_point: Vector3) -> void:
	if player.state == Player.State.AIRBORNE:
		# In the air the click books a destination and nothing else: the arc is
		# already decided and must not bend.
		_pending_air_target = world_point
		return
	# An order to where we already stand is not an order. Without this, holding
	# the button with the cursor over your own feet arrives, cancels and
	# re-orders every tenth of a second, which reads as a flickering state.
	if _flat_distance(player.global_position, world_point) <= ARRIVE_TOLERANCE:
		return
	# A fresh click replaces any intent the last blocked one left behind.
	_clear_intent()
	_target = world_point
	_has_target = true
	_agent.target_position = world_point
	_retries = 0
	# The agent reports its previous path as finished until the server has taken
	# the new target, so the result is only read after a few frames. The path we
	# already have stays in use until then: a held right button re-issues the
	# order ten times a second, and dropping the path on each one would stop the
	# body dead between queries and flicker the state.
	_pending_frames = 3
	_path_dirty = true


func _unhandled_input(event: InputEvent) -> void:
	if not player.is_local():
		return
	if event.is_action_pressed("restart"):
		player.respawn()
		get_viewport().set_input_as_handled()
		return
	if player.grab != null and player.grab.is_held():
		# Held in someone's hands: Space is the only input that still does
		# anything, and it means "let me go".
		if event.is_action_pressed("jump"):
			player.grab.escape_press()
		get_viewport().set_input_as_handled()
		return
	if player.climb != null and player.climb.is_climbing():
		# On a wall the same two buttons mean different things: aim on the wall
		# face, or let go of it.
		if event.is_action_pressed("move_click"):
			var mouse := player.get_viewport().get_mouse_position()
			var camera := player.camera.camera
			player.climb.aim_at(camera.project_ray_origin(mouse), camera.project_ray_normal(mouse))
			get_viewport().set_input_as_handled()
		elif event.is_action_pressed("jump"):
			player.climb.detach()
			get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("cancel"):
		cancel_target()
		_clear_intent()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("move_click"):
		_click_to_target()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("debug_shove"):
		shove()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("grab_throw"):
		interact()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("dash"):
		request_dash()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("jump"):
		# Always buffered, never acted on here: input runs outside the physics
		# step, where is_on_floor() and the contact list both still describe
		# the previous one. What the press means is decided in the step.
		_jump_buffer_left = JUMP_BUFFER
		_catch_buffer_left = CATCH_BUFFER
		get_viewport().set_input_as_handled()


func _physics_process(delta: float) -> void:
	if not player.is_local():
		return
	if player.state == Player.State.DEAD:
		# Nothing moves while dead; the body waits where it fell.
		return
	if player.state == Player.State.GRABBED:
		# Someone else's hands decide where this body is.
		return
	if player.climb != null and player.climb.is_climbing():
		# The wall owns the body until it lets go.
		return
	_jump_buffer_left = maxf(0.0, _jump_buffer_left - delta)
	_catch_buffer_left = maxf(0.0, _catch_buffer_left - delta)
	_shove_cooldown_left = maxf(0.0, _shove_cooldown_left - delta)
	_dash_cooldown_left = maxf(0.0, _dash_cooldown_left - delta)
	_intent_left = maxf(0.0, _intent_left - delta)
	if _intent_left == 0.0:
		_intent_direction = Vector3.ZERO
	if player.is_on_floor():
		_coyote_left = COYOTE_TIME
	else:
		_coyote_left = maxf(0.0, _coyote_left - delta)

	if player.state == Player.State.STUNNED:
		# Physics keeps running while stunned; only the input stops.
		_stunned_step(delta)
		return
	if player.state == Player.State.DASH:
		_dash_step(delta)
	elif player.state == Player.State.AIRBORNE:
		_air_step(delta)
	else:
		_ground_step(delta)


func _ground_step(delta: float) -> void:
	# Held right button keeps re-issuing the order, the way a MOBA does.
	if Input.is_action_pressed("move_click"):
		_drag_left -= delta
		if _drag_left <= 0.0:
			_drag_left = DRAG_RETARGET_INTERVAL
			_click_to_target()
	else:
		_drag_left = 0.0

	if _pending_air_target is Vector3:
		# Applied on any grounded frame, not only on the landing transition: a
		# body that never reports a clean landing would swallow the click.
		var queued: Vector3 = _pending_air_target
		_pending_air_target = null
		set_target(queued)

	if _jump_buffer_left > 0.0 and player.state != Player.State.GRABBING \
			and (player.is_grounded_state() or _coyote_left > 0.0):
		_launch_jump()
		return

	var desired := _desired_velocity()
	if desired.length_squared() > 0.0001:
		player.velocity.x = desired.x
		player.velocity.z = desired.z
		player.face_direction(desired, delta)
	else:
		player.velocity.x = 0.0
		player.velocity.z = 0.0
	# Taken from whether an order stands, not from this frame's velocity: a
	# re-query gap is still MOVE, because the order has not gone anywhere.
	if _has_target and player.state == Player.State.IDLE:
		player.change_state(Player.State.MOVE)
	elif not _has_target and player.state == Player.State.MOVE:
		player.change_state(Player.State.IDLE)
	if player.is_on_floor():
		player.velocity.y = -0.5
	else:
		player.velocity.y -= Tuning.values.gravity * delta
	player.move_and_slide()
	if not player.is_on_floor():
		# Walked off something. Coyote time is already running, so a jump
		# pressed a frame late still goes.
		player.change_state(Player.State.AIRBORNE)
		return
	_try_attach_climb()


func _launch_jump() -> void:
	_jump_buffer_left = 0.0
	_catch_buffer_left = 0.0
	_coyote_left = 0.0
	var horizontal := Vector3(player.velocity.x, 0.0, player.velocity.z)
	if Tuning.values.jump_aims_at_cursor:
		horizontal = _cursor_jump_velocity(horizontal)
	elif horizontal.length() <= 0.1:
		# Standing still, but an order was blocked by a gap: jump the way the
		# click was pointing.
		if _intent_left > 0.0 and _intent_direction.length_squared() > 0.01:
			horizontal = _intent_direction * player.get_move_speed()
		else:
			horizontal = Vector3.ZERO
	_clear_intent()
	# A jump is a new order of its own, so the click that was taking us
	# somewhere is dropped rather than resumed on landing.
	cancel_target()
	player.velocity.x = horizontal.x
	player.velocity.z = horizontal.z
	player.velocity.y = player.get_jump_velocity()
	# Snapping would pull us straight back down on the launch frame.
	player.floor_snap_length = 0.0
	player.change_state(Player.State.AIRBORNE)
	player.move_and_slide()


func _stunned_step(delta: float) -> void:
	if player.is_on_floor():
		player.velocity.x = move_toward(player.velocity.x, 0.0, 10.0 * delta)
		player.velocity.z = move_toward(player.velocity.z, 0.0, 10.0 * delta)
		player.velocity.y = -0.5
	else:
		player.velocity.y -= Tuning.values.gravity * delta
	player.move_and_slide()


# Judged here, on the pusher's own client, as the authority table says. What it
# sends is a request; the target's own machine works out what it does.
func shove() -> int:
	if not player.is_grounded_state() or _shove_cooldown_left > 0.0:
		return 0
	var forward := cursor_direction()
	if forward.length_squared() < 0.01:
		forward = -player.global_transform.basis.z
		forward.y = 0.0
		if forward.length_squared() < 0.01:
			return 0
		forward = forward.normalized()
	_shove_cooldown_left = SHOVE_COOLDOWN
	player.snap_facing(forward)

	var shape := SphereShape3D.new()
	shape.radius = SHOVE_REACH + SHOVE_ALLY_BONUS
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = shape
	params.transform = Transform3D(Basis.IDENTITY, player.global_position)
	params.collision_mask = Player.PLAYER_LAYER | Dummy.LAYER
	params.collide_with_areas = false
	params.exclude = [player.get_rid()]
	var half_angle := deg_to_rad(SHOVE_HALF_ANGLE)
	var hits := 0
	for collision in player.get_world_3d().direct_space_state.intersect_shape(params, 8):
		var body := collision.get("collider") as Node3D
		if body == null or body == player:
			continue
		var offset := body.global_position - player.global_position
		offset.y = 0.0
		if offset.length_squared() < 0.0001:
			continue
		var is_ally := body is Player
		var reach := SHOVE_REACH + (SHOVE_ALLY_BONUS if is_ally else 0.0)
		if offset.length() > reach:
			continue
		if absf(forward.signed_angle_to(offset.normalized(), Vector3.UP)) > half_angle:
			continue
		var push := offset.normalized() + Vector3.UP * Tuning.values.shove_up_bias
		ForceSystem.send(body, ForceSystem.make_event(
			ForceSystem.Kind.SHOVE,
			push,
			Tuning.values.shove_power,
			player.stats.strength,
			player.get_multiplayer_authority(),
			is_ally,
			Tuning.values.shove_damage,
			Tuning.values.shove_stun_time))
		hits += 1
	print("PLAYGROUND_SHOVE by=%s hits=%d" % [player.name, hits])
	return hits


func _air_step(delta: float) -> void:
	if _jump_buffer_left > 0.0 and _coyote_left > 0.0:
		# Walked off something a moment ago: this is still the jump.
		_launch_jump()
		return
	if _catch_buffer_left > 0.0 and try_air_catch():
		_catch_buffer_left = 0.0
		_jump_buffer_left = 0.0
		return
	# No self input on the horizontal: the arc is decided at launch. Only the
	# body's facing still follows the cursor.
	_face_cursor(delta)
	player.velocity.y -= Tuning.values.gravity * delta
	player.move_and_slide()
	if player.is_on_floor():
		player.floor_snap_length = player.default_snap_length()
		player.change_state(Player.State.MOVE if _has_target else Player.State.IDLE)


# DOC: ground only, cursor aimed, and never while already dashing or airborne.
# The jump goes where the cursor points, carrying the speed already being
# travelled, or a full run's worth from a standstill. The cursor resting on the
# body itself is how a jump straight up is asked for, which there would
# otherwise be no way to express.
func _cursor_jump_velocity(current: Vector3) -> Vector3:
	var point: Variant = _cursor_ground_point()
	if point == null:
		return current
	var offset := (point as Vector3) - player.global_position
	offset.y = 0.0
	if offset.length() <= Tuning.values.jump_aim_deadzone:
		return Vector3.ZERO
	var speed := current.length()
	if speed <= 0.1:
		speed = player.get_move_speed()
	return offset.normalized() * speed


# One key, in the order that cannot surprise anyone: throw what is in your
# hands, otherwise take what you are standing on, otherwise pick up what is in
# reach.
func interact() -> bool:
	if player.grab != null and player.grab.is_holding():
		return player.grab.throw()
	for node in player.get_tree().get_nodes_in_group(WeaponRack.INTERACT_GROUP):
		if node.has_method("interact") and node.interact(player):
			return true
	if player.grab != null:
		return player.grab.grab()
	return false


# The click path and anything else that wants a climb go through here, so a
# test exercises exactly what the button does.
func order_climb(body: CollisionObject3D, contact: Vector3, normal: Vector3) -> void:
	_climb_wall = body
	_climb_point = contact
	_climb_normal = normal
	# DOC: walk to a spot 0.4 m out along the face normal.
	set_target(contact + normal * 0.4)


# Gap between the body and the wall face, not between their centres. The
# navigation surface is eroded by agent_radius, so a centre to centre measure
# can never come under the documented attach distance however close the body
# actually gets.
func climb_request_distance() -> float:
	if _climb_wall == null:
		return -1.0
	var plane := Plane(_climb_normal, _climb_point)
	return absf(plane.distance_to(player.global_position)) - Player.BODY_RADIUS


# Probes outwards for a wall rather than reading the last step's contact list.
# Sliding down a face separates and re-touches from frame to frame, so the
# contact list is empty on most of them and a press would be thrown away.
func try_air_catch() -> bool:
	if player.state != Player.State.AIRBORNE or player.climb == null:
		return false
	var space := player.get_world_3d().direct_space_state
	var reach := Player.BODY_RADIUS + CATCH_REACH
	for index in range(CATCH_PROBES):
		var angle := TAU * float(index) / float(CATCH_PROBES)
		var direction := Vector3(sin(angle), 0.0, cos(angle))
		var from := player.global_position
		var query := PhysicsRayQueryParameters3D.create(from, from + direction * reach, Player.CLIMBABLE_LAYER)
		query.collide_with_areas = false
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			continue
		var body := hit.get("collider") as CollisionObject3D
		if body == null:
			continue
		if player.climb.attach(body, hit["position"] as Vector3, hit.get("normal", -direction) as Vector3):
			print("PLAYGROUND_AIR_CATCH y=%.2f" % player.global_position.y)
			return true
	return false


func _clear_climb_request() -> void:
	_climb_wall = null


# Close enough to the spot that was clicked on the wall, so take hold of it.
func _try_attach_climb() -> void:
	if _climb_wall == null or player.climb == null:
		return
	if climb_request_distance() > Tuning.values.climb_attach_distance:
		return
	var body := _climb_wall
	var point := _climb_point
	var normal := _climb_normal
	_clear_climb_request()
	cancel_target()
	player.climb.attach(body, point, normal)


func request_dash() -> bool:
	if not player.is_grounded_state() or _dash_cooldown_left > 0.0:
		return false
	var aim := cursor_direction()
	if aim.length_squared() < 0.01:
		return false
	_dash_direction = aim
	_dash_left = Tuning.values.dash_distance
	_dash_cooldown_left = Tuning.values.dash_cooldown
	cancel_target()
	_clear_intent()
	player.velocity.y = 0.0
	player.change_state(Player.State.DASH)
	return true


func is_dashing() -> bool:
	return player.state == Player.State.DASH


func _dash_step(delta: float) -> void:
	var speed: float = Tuning.values.dash_distance / maxf(Tuning.values.dash_duration, 0.01)
	# Tracked as remaining distance so the last step covers exactly what is
	# left rather than a frame's worth more or less.
	var step := minf(speed * delta, _dash_left)
	_dash_left -= step
	var frame_speed := step / maxf(delta, 0.0001)
	player.velocity.x = _dash_direction.x * frame_speed
	player.velocity.z = _dash_direction.z * frame_speed
	player.velocity.y -= Tuning.values.gravity * delta
	player.move_and_slide()
	# A wall ends it on the spot, and so does running out of ground.
	if player.is_on_wall() or _dash_left <= 0.0:
		_end_dash()
	elif not player.is_on_floor():
		_end_dash()


func _end_dash() -> void:
	_dash_left = 0.0
	player.velocity.x = 0.0
	player.velocity.z = 0.0
	player.change_state(Player.State.IDLE if player.is_on_floor() else Player.State.AIRBORNE)


func cursor_direction() -> Vector3:
	var point: Variant = _cursor_ground_point()
	if point == null:
		return Vector3.ZERO
	var direction := (point as Vector3) - player.global_position
	direction.y = 0.0
	if direction.length_squared() < 0.0004:
		return Vector3.ZERO
	return direction.normalized()


# The spot on our own standing plane the cursor is over. Used to pick between
# several things within arm's reach.
func cursor_point() -> Vector3:
	var point: Variant = _cursor_ground_point()
	return point as Vector3 if point != null else player.global_position


func _face_cursor(delta: float) -> void:
	var point: Variant = _cursor_ground_point()
	if point == null:
		return
	player.face_direction((point as Vector3) - player.global_position, delta)


# Where the cursor meets the plane the body is standing on.
# Lets a check stand in for the mouse, which headless does not have.
func set_aim_override(point: Vector3) -> void:
	_aim_override = point


func _cursor_ground_point() -> Variant:
	if _aim_override != Vector3.INF:
		return _aim_override
	if player.camera == null or player.camera.camera == null:
		return null
	var mouse := player.get_viewport().get_mouse_position()
	var from := player.camera.camera.project_ray_origin(mouse)
	var direction := player.camera.camera.project_ray_normal(mouse)
	var plane := Plane(Vector3.UP, player.global_position.y)
	return plane.intersects_ray(from, direction)


func move_speed() -> float:
	var speed: float = Tuning.values.base_move_speed * Tuning.ratio_mult(
		player.stats.ratio(), Tuning.values.ratio_k_speed)
	if player.state == Player.State.GRABBING:
		# DOC: 70% while carrying something, and no jump or dash at all.
		speed *= CARRY_SPEED_SCALE
	return speed


func _click_to_target() -> void:
	if player.camera == null or player.camera.camera == null:
		return
	var mouse := player.get_viewport().get_mouse_position()
	var from := player.camera.camera.project_ray_origin(mouse)
	var to := from + player.camera.camera.project_ray_normal(mouse) * 500.0
	var query := PhysicsRayQueryParameters3D.create(from, to, CLICK_MASK)
	query.collide_with_areas = false
	# A wall that is currently faded out must not take the click: the player is
	# aiming at what they can see through it.
	query.exclude = OcclusionFader.faded_rids()
	var hit := player.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return
	var normal := hit.get("normal", Vector3.ZERO) as Vector3
	var collider := hit.get("collider") as CollisionObject3D
	if collider != null and (collider.collision_layer & Player.CLIMBABLE_LAYER) != 0:
		# Walk to the foot of the wall first; the attach happens on arrival.
		order_climb(collider, hit["position"] as Vector3, normal)
		return
	_clear_climb_request()
	if normal.dot(Vector3.UP) < 0.6:
		return
	set_target(hit["position"] as Vector3)


func _desired_velocity() -> Vector3:
	if not _has_target:
		return Vector3.ZERO
	if _pending_frames > 0:
		_pending_frames -= 1
	elif _path_dirty or _path.is_empty():
		_query_path()
	if _path.is_empty():
		return Vector3.ZERO

	var last_index := _path.size() - 1
	while _path_index < _path.size():
		var radius := ARRIVE_TOLERANCE if _path_index == last_index else PATH_LOOKAHEAD
		if _flat_distance(player.global_position, _path[_path_index]) > radius:
			break
		_path_index += 1
	if _path_index >= _path.size():
		# Walked out the old path while a new one is still being prepared: wait
		# for it rather than reporting an arrival that is not one.
		if not _path_dirty:
			_capture_intent_if_blocked()
			cancel_target()
		return Vector3.ZERO

	var step := _path[_path_index] - player.global_position
	step.y = 0.0
	if step.length() < 0.05:
		return Vector3.ZERO
	return step.normalized() * move_speed()


# Stopping at the near edge of a gap is not the same as arriving. When the path
# ends well short of where the click landed, the direction is kept for a while
# so a jump pressed here goes where the click was pointing.
func _capture_intent_if_blocked() -> void:
	var path_end := _path[_path.size() - 1] if not _path.is_empty() else player.global_position
	if _flat_distance(path_end, _target) <= UNREACHABLE_DISTANCE:
		return
	var direction := _target - player.global_position
	direction.y = 0.0
	if direction.length_squared() < 0.01:
		return
	_intent_direction = direction.normalized()
	_intent_left = Tuning.values.move_intent_timeout


func _query_path() -> void:
	# One call makes the agent run its pending query; the points are then ours
	# to walk in XZ.
	_agent.get_next_path_position()
	var result := _agent.get_current_navigation_path()
	if result.is_empty():
		_retries += 1
		if _retries > PATH_QUERY_RETRIES:
			# No path at all: the click was somewhere this body cannot walk to,
			# which is exactly the case the jump intent exists for.
			_capture_intent_if_blocked()
			cancel_target()
			return
		_pending_frames = 1
		return
	_path = result
	_path_index = 0
	_path_dirty = false
	_retries = 0


func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))
