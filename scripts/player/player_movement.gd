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

var player: Player

var _agent: NavigationAgent3D
var _has_target := false
var _target := Vector3.ZERO
var _path := PackedVector3Array()
var _path_index := 0
var _pending_frames := 0
var _retries := 0
var _drag_left := 0.0


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
	if player.state == Player.State.MOVE:
		player.change_state(Player.State.IDLE)


func set_target(world_point: Vector3) -> void:
	_target = world_point
	_has_target = true
	_agent.target_position = world_point
	_path.clear()
	_path_index = 0
	_retries = 0
	# The agent reports its previous path as finished until the server has taken
	# the new target. Do not read arrival from that one frame window.
	_pending_frames = 3


func _unhandled_input(event: InputEvent) -> void:
	if not player.is_local():
		return
	if event.is_action_pressed("cancel"):
		cancel_target()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("move_click"):
		_click_to_target()
		get_viewport().set_input_as_handled()


func _physics_process(delta: float) -> void:
	if not player.is_local():
		return
	# Held right button keeps re-issuing the order, the way a MOBA does.
	if Input.is_action_pressed("move_click"):
		_drag_left -= delta
		if _drag_left <= 0.0:
			_drag_left = DRAG_RETARGET_INTERVAL
			_click_to_target()
	else:
		_drag_left = 0.0

	var desired := _desired_velocity()
	var speed := player.stats.ratio()
	if desired.length_squared() > 0.0001:
		player.velocity.x = desired.x
		player.velocity.z = desired.z
		player.face_direction(desired, delta)
		if player.state == Player.State.IDLE:
			player.change_state(Player.State.MOVE)
	else:
		player.velocity.x = 0.0
		player.velocity.z = 0.0
		if player.state == Player.State.MOVE:
			player.change_state(Player.State.IDLE)
	# Gravity is here even before the jump stage, or the body floats off ledges.
	if player.is_on_floor():
		player.velocity.y = -0.5
	else:
		player.velocity.y -= Tuning.values.gravity * delta
	player.move_and_slide()


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
		return Vector3.ZERO
	if _path.is_empty():
		# One call makes the agent run its pending query; the points are then
		# ours to walk.
		_agent.get_next_path_position()
		_path = _agent.get_current_navigation_path()
		_path_index = 0
		if _path.is_empty():
			_retries += 1
			if _retries > PATH_QUERY_RETRIES:
				cancel_target()
				return Vector3.ZERO
			_pending_frames = 1
			return Vector3.ZERO
		_retries = 0

	var last_index := _path.size() - 1
	while _path_index < _path.size():
		var radius := ARRIVE_TOLERANCE if _path_index == last_index else PATH_LOOKAHEAD
		if _flat_distance(player.global_position, _path[_path_index]) > radius:
			break
		_path_index += 1
	if _path_index >= _path.size():
		cancel_target()
		return Vector3.ZERO

	var step := _path[_path_index] - player.global_position
	step.y = 0.0
	if step.length() < 0.05:
		return Vector3.ZERO
	return step.normalized() * move_speed()


func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))
