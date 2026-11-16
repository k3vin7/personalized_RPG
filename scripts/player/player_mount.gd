class_name PlayerMount
extends Node3D

# The horse under a body, on every peer. Nothing here decides anything: the
# stage is the server's (Player.sync_mount, on the Vitals synchronizer) and
# this node shows it -- the stand-in model, the rider lifted onto its back,
# and the body's collider swapped for the mounted one. Built in code on each
# peer from the replicated stage, so nothing in it needs a synchronizer of
# its own: the horse is a child of the body and goes where the body goes.
#
# The mounted collider is an upright capsule: mount_radius wide, from the
# ground to the rider's head. The horse's length is in the picture only
# (the user's call, 2026-11-16: a 2.2 m box caught on corners the 0.45 m
# navigation bake never left room for).
#
# Getting off leaves the horse standing where it was for mount_linger_time,
# then it is gone. The one left behind is a picture only (no collider).

enum Stage {
	NONE,
	# The key was pressed; the server's summon clock is running.
	SUMMONING,
	MOUNTED,
}

const HORSE_COLOUR := Color("7a5230")

var player: Player
var stage: int = Stage.NONE
# How many times this screen has put the body on a horse / taken it off.
var mounts_shown := 0
var dismounts_shown := 0
# The server's count of throws this screen has acted on, and how many times
# a horse was taken away at once rather than left standing.
var thrown_seen := 0
var horses_vanished := 0

var _horse: Node3D
var _shape_node: CollisionShape3D
var _capsule: CapsuleShape3D
var _body_shape_node: CollisionShape3D
# Horses left standing after a dismount: {"node": Node3D, "left": seconds}.
var _lingering: Array[Dictionary] = []
var _built_scale := 0.0
var _built_dims := Vector2.ZERO


func setup(owner_player: Player, body_shape_node: CollisionShape3D) -> void:
	player = owner_player
	_body_shape_node = body_shape_node
	_capsule = CapsuleShape3D.new()
	_shape_node = CollisionShape3D.new()
	_shape_node.name = "MountShape"
	_shape_node.shape = _capsule
	_shape_node.disabled = true
	# A direct child of the body: a shape under any other node is not the
	# body's.
	player.add_child(_shape_node)
	set_physics_process(true)


func is_mounted() -> bool:
	return stage == Stage.MOUNTED


# 1.0, or the server's mount_large_scale for a race whose data asks for it.
func horse_scale() -> float:
	if player == null or player.stats == null:
		return 1.0
	return Tuning.server.mount_large_scale if Races.data_for(player.stats.race).large_mount else 1.0


# Width, back height, length of the horse this body rides, in metres. The
# picture's; only the back height reaches the collider (through the seat).
func horse_size() -> Vector3:
	return Vector3(Tuning.server.mount_width, Tuning.server.mount_back_height,
		Tuning.server.mount_length) * horse_scale()


# How far a rider's body centre sits above where it stands on foot, whether
# or not this body is riding now (the server asks before it grants).
func seat_lift_mounted() -> float:
	return horse_size().y + Tuning.server.mount_seat_above * player.body_scale() - player.half_height()


func seat_lift() -> float:
	if stage != Stage.MOUNTED or player == null:
		return 0.0
	return seat_lift_mounted()


# The mounted collider: (radius, height). Upright, feet to the rider's head.
func capsule_dims() -> Vector2:
	var height := player.half_height() * 2.0 + seat_lift_mounted()
	var radius := float(Tuning.server.mount_radius) * horse_scale()
	return Vector2(radius, maxf(height, radius * 2.0))


# Where that capsule's centre is, relative to the body's origin.
func capsule_offset() -> Vector3:
	return Vector3(0.0, -player.half_height() + capsule_dims().y * 0.5, 0.0)


func horse() -> Node3D:
	return _horse


func lingering_count() -> int:
	return _lingering.size()


func lingering_position() -> Vector3:
	if _lingering.is_empty():
		return Vector3.INF
	return (_lingering[_lingering.size() - 1]["node"] as Node3D).global_position


# (radius, height) of the collider in use, or zero on foot.
func collider_dims() -> Vector2:
	return Vector2(_capsule.radius, _capsule.height) if not _shape_node.disabled else Vector2.ZERO


# The server's stage arriving. Run on every peer for every body.
func apply(new_stage: int) -> void:
	if new_stage == stage:
		return
	var was := stage
	stage = new_stage
	if new_stage == Stage.MOUNTED:
		_get_on()
	elif was == Stage.MOUNTED:
		_get_off()
	player.on_mount_changed()
	print("PLAYGROUND_MOUNT_SHOWN peer=%s on=%d stage=%s" % [
		player.name, multiplayer.get_unique_id(), Stage.keys()[stage]])


# Thrown off: the horse is gone at once. The count and the stage travel
# together but are read one after the other, so this covers both orders --
# the horse still under the body, and the one just left behind.
func on_thrown(count: int) -> void:
	var first := thrown_seen == 0 and count > 0 and mounts_shown == 0
	thrown_seen = count
	if first:
		return # A body that arrived on this screen with old throws on it.
	horses_vanished += 1
	for entry: Dictionary in _lingering:
		var node := entry["node"] as Node3D
		if is_instance_valid(node):
			node.queue_free()
	_lingering.clear()
	if stage == Stage.MOUNTED and _horse != null:
		_horse.queue_free()
		_horse = null


func _get_on() -> void:
	mounts_shown += 1
	_build_horse()
	_fit()
	_shape_node.disabled = false
	_body_shape_node.disabled = true


func _get_off() -> void:
	dismounts_shown += 1
	_shape_node.disabled = true
	_body_shape_node.disabled = false
	if _horse == null:
		return
	# Left where it stands: top_level takes it out from under the body.
	var at := _horse.global_transform
	_horse.top_level = true
	_horse.global_transform = at
	_lingering.append({"node": _horse, "left": float(Tuning.server.mount_linger_time)})
	_horse = null


func _physics_process(delta: float) -> void:
	if stage == Stage.MOUNTED and (not is_equal_approx(_built_scale, horse_scale())
			or not _built_dims.is_equal_approx(capsule_dims())):
		# The race or a slider changed under a rider: the same horse, resized.
		_fit()
		player.on_mount_changed()
	if _lingering.is_empty():
		return
	for index in range(_lingering.size() - 1, -1, -1):
		var entry: Dictionary = _lingering[index]
		entry["left"] = float(entry["left"]) - delta
		if float(entry["left"]) <= 0.0:
			var node := entry["node"] as Node3D
			if is_instance_valid(node):
				node.queue_free()
			_lingering.remove_at(index)


# The collider and the model's place, from the numbers as they are now. The
# body's origin stays a half height above the ground, as on foot, so the
# capsule and the horse hang from it down to the feet.
func _fit() -> void:
	var dims := capsule_dims()
	_built_scale = horse_scale()
	_built_dims = dims
	_capsule.radius = dims.x
	_capsule.height = dims.y
	_shape_node.position = capsule_offset()
	if _horse != null:
		_horse.position = Vector3(0.0, -player.half_height(), 0.0)
		_horse.scale = Vector3.ONE * _built_scale


# The stand-in: a trunk, a head and four legs, out of boxes. Built at scale 1
# from the tuning's length, back height and width; forward is -Z.
func _build_horse() -> void:
	if _horse != null:
		_horse.queue_free()
	_horse = Node3D.new()
	_horse.name = "Horse"
	add_child(_horse)
	var length: float = Tuning.server.mount_length
	var back: float = Tuning.server.mount_back_height
	var width: float = Tuning.server.mount_width
	var material := StandardMaterial3D.new()
	material.albedo_color = HORSE_COLOUR
	material.roughness = 0.8
	var trunk_height := back * 0.45
	_add_box(Vector3(width, trunk_height, length * 0.8),
		Vector3(0.0, back - trunk_height * 0.5, length * 0.1), material)
	_add_box(Vector3(width * 0.55, back * 0.3, length * 0.3),
		Vector3(0.0, back * 1.05, -length * 0.35), material)
	var leg_height := back - trunk_height
	for x: float in [-0.3, 0.3]:
		for z: float in [-0.22, 0.42]:
			_add_box(Vector3(width * 0.22, leg_height, width * 0.22),
				Vector3(width * x, leg_height * 0.5, length * z), material)


func _add_box(size: Vector3, at: Vector3, material: Material) -> void:
	var part := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	part.mesh = mesh
	part.position = at
	part.material_override = material
	_horse.add_child(part)
