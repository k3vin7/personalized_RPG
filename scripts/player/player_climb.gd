class_name PlayerClimb
extends Node

# Climbing. The body hangs a fixed distance off one wall face and moves on that
# face's plane.
#
# Movement on the wall is solved against the plane in maths, never by a physics
# ray. A wall facing away from the camera is faded out and therefore excluded
# from the click ray, so a physics query could not find the very wall being
# climbed. The plane always can.

const HANG_DISTANCE := 0.35
# Below this the wall plane is too edge on to the view for a cursor ray to meet
# it accurately. The map has no such walls, but a stray one must not become
# unaimable, so the height is solved against a camera facing plane instead.
const EDGE_ON_LIMIT := 0.35
const ARRIVE := 0.25
const MANTLE_TIME := 0.3
const DETACH_PUSH := 2.0
const EDGE_PROBE := 0.45
# F follow-up: every face of a climb wall that stands square to the ground can
# be climbed, not one chosen face of it. What marks a wall as climbable is the
# wall, on the climbable layer and coloured for it; which side you take hold of
# is yours to pick. Flatter than this against vertical and the face is a slope
# or a top, which is walked on rather than climbed.
const VERTICAL_LIMIT := 0.3
# 4-chapter, stage F: squarer to the view than this and the face is a front or
# a back, which can be climbed in any direction. Flatter and it is a side face,
# which can only be climbed up and down.
const SIDE_FACE_LIMIT := 0.7

var player: Player

var wall: CollisionObject3D
var wall_normal := Vector3.ZERO
var wall_plane := Plane()

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
	# F follow-up: any face of it that stands square to the ground. A top or a
	# slope is not a face to climb, and that is the only side ruled out.
	if not face_is_climbable(body, normal):
		print("PLAYGROUND_CLIMB_REFUSED wall=%s face=%s" % [body.name, normal])
		return false
	wall = body
	wall_normal = flat.normalized()
	wall_plane = Plane(wall_normal, contact)
	_has_target = false
	player.velocity = Vector3.ZERO
	# Hung off the face at the height the feet were already at.
	var hang := wall_plane.project(player.global_position) + wall_normal * HANG_DISTANCE
	player.global_position = Vector3(hang.x, player.global_position.y, hang.z)
	player.look_at_wall(wall_normal)
	player.change_state(Player.State.CLIMB)
	print("PLAYGROUND_CLIMB_ATTACH normal=%s edge_on=%.2f" % [wall_normal, _view_alignment()])
	return true


# A climb wall, taken hold of on a face that stands up from the ground. Both
# halves matter: the layer says this wall is climbable at all, and the normal
# says this side of it is a wall rather than a floor or a lid.
static func face_is_climbable(body: CollisionObject3D, normal: Vector3) -> bool:
	if body == null:
		return false
	if (body.collision_layer & Playground.CLIMBABLE_LAYER) == 0:
		return false
	return is_vertical_face(normal)


# Square to the ground, give or take. A top or a slope answers no.
static func is_vertical_face(normal: Vector3) -> bool:
	if not normal.is_finite() or normal.length_squared() < 0.0001:
		return false
	return absf(normal.normalized().dot(Vector3.UP)) <= VERTICAL_LIMIT


# DOC (stage F): a face squarer to the view than SIDE_FACE_LIMIT is a front or
# a back and may be climbed in any direction. One flatter to the view is a side
# face: up and down only, because left and right on it would be travel into or
# out of the screen that the player cannot judge.
func is_side_face() -> bool:
	return _view_alignment() <= SIDE_FACE_LIMIT


# How squarely this face meets the view. 1.0 is straight on, 0.0 is edge on.
func _view_alignment() -> float:
	if player.camera == null:
		return 1.0
	return absf(wall_normal.dot(player.camera.get_camera_flat_forward()))


# Where on the wall the cursor is pointing, solved on the wall's own plane.
# That plane faces the view on every wall this map has, so the ray meets it
# squarely. Only a wall placed nearly edge on falls back to a camera facing
# plane, which is well conditioned but gives height only.
func aim_at(from: Vector3, direction: Vector3) -> void:
	var solving := wall_plane
	if _view_alignment() < EDGE_ON_LIMIT and player.camera != null:
		solving = Plane(player.camera.get_camera_flat_forward(), player.global_position)
	var point: Variant = solving.intersects_ray(from, direction)
	if point == null:
		return
	set_wall_target(point as Vector3)


func wall_target() -> Vector3:
	return _target


func set_wall_target(point: Vector3) -> void:
	_target = point + wall_normal * HANG_DISTANCE
	if is_side_face():
		# Up and down only: the sideways part of the order is dropped rather
		# than refused, so a click above you still takes you up a side face.
		_target.x = player.global_position.x
		_target.z = player.global_position.z
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
	var hit := player.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return false
	# The wall going on is not enough: it has to still be a climb wall, so a
	# climb never carries on round a corner onto a smooth one.
	return face_is_climbable(hit.get("collider") as CollisionObject3D, wall_normal)


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
