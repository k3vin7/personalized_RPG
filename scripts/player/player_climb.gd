class_name PlayerClimb
extends Node

# Climbing. The body hangs a fixed distance off one wall face and moves on that
# face's plane.
#
# Movement on the wall is solved against the plane in maths, never by a physics
# ray. A wall facing away from the camera is faded out and therefore excluded
# from the click ray, so a physics query could not find the very wall being
# climbed. The plane always can.

enum Face {
	FRONT_OR_BACK,
	SIDE,
}

const HANG_DISTANCE := 0.35
const FACE_THRESHOLD := 0.7
const ARRIVE := 0.25
const MANTLE_TIME := 0.3
const DETACH_PUSH := 2.0
const EDGE_PROBE := 0.45

var player: Player

var wall: CollisionObject3D
var wall_normal := Vector3.ZERO
var wall_plane := Plane()
var face := Face.FRONT_OR_BACK

var _target: Vector3 = Vector3.ZERO
var _has_target := false
var _mantle_left := 0.0
var _mantle_to := Vector3.ZERO


func setup(owner_player: Player) -> void:
	player = owner_player
	set_physics_process(true)


func is_climbing() -> bool:
	return player.state == Player.State.CLIMB or player.state == Player.State.MANTLE


# From the ground after walking to the wall, or out of the air by pressing jump
# while touching a climbable one. Never automatic: a wall you brush past on the
# way somewhere else should not grab you.
#
# Catching costs no stamina. The cost is in hanging there, which drains the same
# way a climb from the ground does.
func attach(body: CollisionObject3D, contact: Vector3, normal: Vector3) -> bool:
	if player.state != Player.State.IDLE and player.state != Player.State.MOVE and player.state != Player.State.AIRBORNE:
		return false
	var flat := Vector3(normal.x, 0.0, normal.z)
	if flat.length_squared() < 0.01:
		return false
	# DOC: a smooth wall is not climbable however hard it is clicked.
	if body == null or (body.collision_layer & Playground.CLIMBABLE_LAYER) == 0:
		return false
	wall = body
	wall_normal = flat.normalized()
	wall_plane = Plane(wall_normal, contact)
	face = _classify_face()
	_has_target = false
	player.velocity = Vector3.ZERO
	# Hung off the face at the height the feet were already at.
	var hang := wall_plane.project(player.global_position) + wall_normal * HANG_DISTANCE
	player.global_position = Vector3(hang.x, player.global_position.y, hang.z)
	player.look_at_wall(wall_normal)
	player.change_state(Player.State.CLIMB)
	print("PLAYGROUND_CLIMB_ATTACH face=%s normal=%s" % [Face.keys()[face], wall_normal])
	return true


# DOC: a face pointing roughly at or away from the camera can be climbed in any
# direction; one pointing sideways only up and down.
func _classify_face() -> int:
	if player.camera == null:
		return Face.FRONT_OR_BACK
	var forward := player.camera.get_camera_flat_forward()
	return Face.FRONT_OR_BACK if absf(wall_normal.dot(forward)) > FACE_THRESHOLD else Face.SIDE


# Where on the wall the cursor is pointing, solved on the plane.
func aim_at(from: Vector3, direction: Vector3) -> void:
	var point: Variant = wall_plane.intersects_ray(from, direction)
	if point == null:
		return
	set_wall_target(point as Vector3)


func set_wall_target(point: Vector3) -> void:
	_target = point + wall_normal * HANG_DISTANCE
	_has_target = true


func detach(push: float = DETACH_PUSH) -> void:
	if not is_climbing():
		return
	wall = null
	_has_target = false
	player.velocity = wall_normal * push
	player.velocity.y = 0.0
	player.change_state(Player.State.AIRBORNE)


func _physics_process(delta: float) -> void:
	if not player.is_local():
		return
	if player.state == Player.State.MANTLE:
		_mantle_step(delta)
		return
	if player.state != Player.State.CLIMB:
		return

	player.stamina = maxf(0.0, player.stamina - Tuning.values.stamina_climb_drain * delta)
	if player.stamina <= 0.0:
		detach(0.5)
		return

	if _has_target:
		var to_target := _target - player.global_position
		# Sideways movement only exists on a face you can traverse; a side face
		# is climbed straight up and down.
		if face == Face.SIDE:
			var vertical := to_target.dot(Vector3.UP)
			to_target = Vector3.UP * vertical
		if to_target.length() <= ARRIVE:
			_has_target = false
			player.velocity = Vector3.ZERO
		else:
			var step := to_target.normalized() * Tuning.values.climb_speed
			if not _wall_continues(step * delta):
				# Ran out of wall to the side; hold position rather than
				# sliding off the end of it.
				player.velocity = Vector3.ZERO
			else:
				player.velocity = step
	else:
		player.velocity = Vector3.ZERO

	player.move_and_slide()
	_check_ends()


# A short ray from just inside the body back into the wall. The wall is a
# collider even when it is faded, because fading only changes what is drawn and
# what the click ray may hit.
func _descending() -> bool:
	return _has_target and _target.y < player.global_position.y - 0.05


func _wall_continues(offset: Vector3) -> bool:
	var from := player.global_position + offset + wall_normal * 0.1
	var query := PhysicsRayQueryParameters3D.create(from, from - wall_normal * (HANG_DISTANCE + 0.4), Playground.CLIMBABLE_LAYER)
	query.collide_with_areas = false
	return not player.get_world_3d().direct_space_state.intersect_ray(query).is_empty()


func _check_ends() -> void:
	# Bottom: the feet are back on the ground, and we were going down. Without
	# the second half, attaching at foot height counts as having arrived at the
	# bottom on the very first frame and the wall lets go immediately.
	if player.is_on_floor() and _descending():
		wall = null
		_has_target = false
		player.change_state(Player.State.IDLE)
		return
	# Top: no wall left above the head, and ground just past the edge.
	var head := player.global_position + Vector3.UP * (Player.BODY_HALF_HEIGHT + 0.15)
	var inward := head - wall_normal * (HANG_DISTANCE + EDGE_PROBE)
	var space := player.get_world_3d().direct_space_state
	var ahead := PhysicsRayQueryParameters3D.create(head, inward, Playground.CLIMBABLE_LAYER)
	if not space.intersect_ray(ahead).is_empty():
		return
	var down := PhysicsRayQueryParameters3D.create(inward, inward + Vector3.DOWN * 1.2, Playground.WORLD_LAYER | Playground.CLIMBABLE_LAYER)
	var floor_hit := space.intersect_ray(down)
	if floor_hit.is_empty():
		return
	# Stood exactly where the probe found ground. Pushing further in sounds
	# safer but these walls are 0.6 m thick, so half a metre of inset comes out
	# the other side and drops the body in mid air.
	_mantle_to = (floor_hit["position"] as Vector3) + Vector3.UP * Player.BODY_HALF_HEIGHT
	_mantle_left = MANTLE_TIME
	player.velocity = Vector3.ZERO
	player.change_state(Player.State.MANTLE)


func _mantle_step(delta: float) -> void:
	_mantle_left -= delta
	var ratio := clampf(1.0 - maxf(_mantle_left, 0.0) / MANTLE_TIME, 0.0, 1.0)
	player.global_position = player.global_position.lerp(_mantle_to, ratio)
	if _mantle_left <= 0.0:
		player.global_position = _mantle_to
		wall = null
		_has_target = false
		player.velocity = Vector3.ZERO
		player.change_state(Player.State.IDLE)
