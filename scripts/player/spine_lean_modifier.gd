extends SkeletonModifier3D

# What is laid over whatever clip is playing (2026-11-18). A
# SkeletonModifier3D is the engine's own place for this: it runs after the
# animation has posed the skeleton each frame and what it writes to the bones
# is not kept, so the clip underneath is never changed -- and because it runs
# in the same frame as the pose, nothing it works out is a frame behind.
#
# The waist: a turn about the skeleton's own left-right axis (X: this rig
# faces +Z, so a positive turn about +X carries "up" toward "forward"),
# shared evenly between `bones`, bottom to top.
#   `degrees`: a forward lean added to the clip (the thrust, which the file
#     plays standing upright, bent so the blade goes in at the middle).
#   `straighten`: how much of the clip's OWN forward bend is taken back out,
#     0..1 (the overhead cut, whose clip is a wood-chopping swing that folds
#     the body nearly flat). The bend is read off `chest_bone` each frame --
#     how far its long axis has tipped forward -- and that share of it is
#     turned back.
#
# The weapon in the hand: `aim` (0..1) turns `grip`, the node the weapon
# hangs off under the hand slot, until the blade lies along the forearm. The
# slot's +Y is where the blade points; it is swung onto the forearm's
# direction, as the slot sees it, by the shortest turn.
#
# CharacterVisual eases all three in and out and sets them every frame.

var bones: Array[String] = ["Spine", "Spine1"]
var chest_bone := "Spine2"
# The roots of the two arms (the upper arms: the shoulder blades stay with
# the chest).
var arm_bones: Array[String] = ["LeftArm", "RightArm"]
var degrees := 0.0
var straighten := 0.0
# Neck first, head last.
var head_bones: Array[String] = ["Neck", "Head"]
var look_ahead := 0.0

var grip: Node3D
var slot_bone := ""
var elbow_bone := ""
var wrist_bone := ""
var aim := 0.0
# The grip undoes the model's scale so a held prop keeps its own size.
var grip_scale := 1.0
var _aimed := false


func _process_modification_with_delta(_delta: float) -> void:
	var skeleton := get_skeleton()
	if skeleton == null:
		return
	_bend_waist(skeleton)
	_face_ahead(skeleton)
	_aim_weapon(skeleton)


# The head kept looking the way the body faces (2026-11-19, the overhead cut:
# its arms come from a clip that turns right round, and the head went with
# them). Each of `head_bones` is turned toward the way it sits in the rest
# pose -- upright, facing the skeleton's front -- the neck part of the way and
# the head the rest, by `look_ahead` (0..1).
func _face_ahead(skeleton: Skeleton3D) -> void:
	if look_ahead <= 0.001 or head_bones.is_empty():
		return
	for index in head_bones.size():
		var bone := skeleton.find_bone(head_bones[index])
		if bone < 0:
			continue
		# The last bone gets the whole weight, the ones under it a share.
		var share := clampf(look_ahead, 0.0, 1.0) * float(index + 1) / float(head_bones.size())
		var pose := skeleton.get_bone_global_pose(bone)
		var now := pose.basis.orthonormalized().get_rotation_quaternion()
		var rest := skeleton.get_bone_global_rest(bone).basis.orthonormalized().get_rotation_quaternion()
		pose.basis = Basis(now.slerp(rest, share))
		skeleton.set_bone_global_pose(bone, pose)


func _bend_waist(skeleton: Skeleton3D) -> void:
	if bones.is_empty():
		return
	var turn := deg_to_rad(degrees)
	var taken_out := 0.0
	if straighten > 0.001:
		var chest := skeleton.find_bone(chest_bone)
		if chest >= 0:
			var up := skeleton.get_bone_global_pose(chest).basis.y.normalized()
			# Forward tip of the chest's long axis; only a forward bend is
			# taken out, a body leaning back is left as the clip has it.
			var tip := atan2(up.z, up.y)
			if tip > 0.0:
				taken_out = tip * clampf(straighten, 0.0, 1.0)
				turn -= taken_out
	if absf(turn) < 0.0002:
		return
	var share := turn / float(bones.size())
	for bone_name in bones:
		_turn(skeleton, bone_name, share)
	# The arms hang off the chest and would be lifted with it: straightened
	# on its own, the overhead cut ended with the blade pointing at the sky.
	# What was taken out of the waist is given back at each arm's root, so
	# the arms and the blade point where the clip points them, from shoulders
	# that are now higher.
	if taken_out > 0.0:
		for bone_name in arm_bones:
			_turn(skeleton, bone_name, taken_out)


func _turn(skeleton: Skeleton3D, bone_name: String, radians: float) -> void:
	var bone := skeleton.find_bone(bone_name)
	if bone < 0:
		return
	var pose := skeleton.get_bone_global_pose(bone)
	pose.basis = Basis(Vector3.RIGHT, radians) * pose.basis
	skeleton.set_bone_global_pose(bone, pose)


func _aim_weapon(skeleton: Skeleton3D) -> void:
	if not is_instance_valid(grip):
		return
	if aim <= 0.0 and not _aimed:
		return
	var turn := Basis.IDENTITY
	if aim > 0.0:
		var slot := skeleton.find_bone(slot_bone)
		var elbow := skeleton.find_bone(elbow_bone)
		var wrist := skeleton.find_bone(wrist_bone)
		if slot >= 0 and elbow >= 0 and wrist >= 0:
			# All three off this frame's pose, in the skeleton's own space:
			# the forearm against the slot it ends in. The waist's turn above
			# carries both alike, so it changes nothing here.
			var arm := skeleton.get_bone_global_pose(wrist).origin - skeleton.get_bone_global_pose(elbow).origin
			var local := skeleton.get_bone_global_pose(slot).basis.orthonormalized().inverse() * arm
			if local.length() > 0.0001 and local.normalized().dot(Vector3.UP) > -0.999:
				turn = Basis(Quaternion.IDENTITY.slerp(Quaternion(Vector3.UP, local.normalized()), clampf(aim, 0.0, 1.0)))
	_aimed = aim > 0.0
	grip.basis = turn.scaled(Vector3.ONE * grip_scale)
