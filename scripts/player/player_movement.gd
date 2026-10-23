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
var _intent_direction := Vector3.ZERO
var _intent_left := 0.0
var _pending_air_target: Variant = null
var _dash_left := 0.0
var _dash_direction := Vector3.ZERO
var _dash_cooldown_left := 0.0


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
	if event.is_action_pressed("cancel"):
		cancel_target()
		_clear_intent()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("move_click"):
		_click_to_target()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("dash"):
		request_dash()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("jump"):
		# Buffered, never acted on here: input runs outside the physics step,
		# where is_on_floor() still holds last step's answer.
		_jump_buffer_left = JUMP_BUFFER
		get_viewport().set_input_as_handled()


func _physics_process(delta: float) -> void:
	if not player.is_local():
		return
	if player.state == Player.State.DEAD:
		# Nothing moves while dead; the body waits where it fell.
		return
	_jump_buffer_left = maxf(0.0, _jump_buffer_left - delta)
	_dash_cooldown_left = maxf(0.0, _dash_cooldown_left - delta)
	_intent_left = maxf(0.0, _intent_left - delta)
	if _intent_left == 0.0:
		_intent_direction = Vector3.ZERO
	if player.is_on_floor():
		_coyote_left = COYOTE_TIME
	else:
		_coyote_left = maxf(0.0, _coyote_left - delta)

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

	if _jump_buffer_left > 0.0 and (player.is_grounded_state() or _coyote_left > 0.0):
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


func _launch_jump() -> void:
	_jump_buffer_left = 0.0
	_coyote_left = 0.0
	var horizontal := Vector3(player.velocity.x, 0.0, player.velocity.z)
	if horizontal.length() <= 0.1:
		# Standing still, but an order was blocked by a gap: jump the way the
		# click was pointing.
		if _intent_left > 0.0 and _intent_direction.length_squared() > 0.01:
			horizontal = _intent_direction * player.get_move_speed()
		else:
			horizontal = Vector3.ZERO
	# Only the heading changes with the toggle, never the speed, so the two
	# rules can be compared with one variable between them.
	if Tuning.values.jump_aims_at_cursor and horizontal.length() > 0.1:
		var aim := cursor_direction()
		if aim.length_squared() > 0.01:
			horizontal = aim * horizontal.length()
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


func _air_step(delta: float) -> void:
	# No self input on the horizontal: the arc is decided at launch. Only the
	# body's facing still follows the cursor.
	_face_cursor(delta)
	player.velocity.y -= Tuning.values.gravity * delta
	player.move_and_slide()
	if player.is_on_floor():
		player.floor_snap_length = player.default_snap_length()
		player.change_state(Player.State.MOVE if _has_target else Player.State.IDLE)


# DOC: ground only, cursor aimed, and never while already dashing or airborne.
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


func _face_cursor(delta: float) -> void:
	var point: Variant = _cursor_ground_point()
	if point == null:
		return
	player.face_direction((point as Vector3) - player.global_position, delta)


# Where the cursor meets the plane the body is standing on.
func _cursor_ground_point() -> Variant:
	if player.camera == null or player.camera.camera == null:
		return null
	var mouse := player.get_viewport().get_mouse_position()
	var from := player.camera.camera.project_ray_origin(mouse)
	var direction := player.camera.camera.project_ray_normal(mouse)
	var plane := Plane(Vector3.UP, player.global_position.y)
	return plane.intersects_ray(from, direction)


func move_speed() -> float:
	return Tuning.values.base_move_speed * Tuning.ratio_mult(player.stats.ratio(), Tuning.values.ratio_k_speed)


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
		# Climbing arrives in stage 4. For now, walk to the floor in front.
		set_target(hit["position"] as Vector3 + normal * 0.5)
		return
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
