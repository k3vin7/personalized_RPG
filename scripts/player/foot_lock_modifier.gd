extends SkeletonModifier3D

# 2026-11-21: the feet kept where they touched the ground (foot locking), so
# a body that does not move as its clip does -- a path held in place, a
# blend into the stance -- does not slide its feet. A picture only: every
# screen works it out for itself, and nothing here is the server's.
#
# This runs before the engine's own two-bone IK (TwoBoneIK3D, `ik`), which
# hangs off the same skeleton right after it: here each foot's target and
# knee pole are put where they belong this frame, off the pose the clip has
# just given, and the IK bends the leg to it.
#
# CharacterVisual says every frame which feet the clip has on the ground
# (`contact`, measured off the clip at load). A foot that comes down is held
# where it came down for as long as it stays down; one that lifts is let go
# over RELEASE. begin_return(seconds, kept) is the step back into the stance
# after a clip that does not end in it, while the body itself moves on (its
# path, SkillDef motion_return_move): the `kept` foot stays where it is and
# the other is lifted a little and set down where the stance has it, over
# `seconds`. With no `kept` foot, the two step one after the other.

const RELEASE := 0.08
const STEP_LIFT := 0.08
# A held foot further than this from the hip (a share of the leg's length)
# is drawn in to it: a leg is never stretched past straight.
const REACH := 0.98

var ik: TwoBoneIK3D
# side -> [thigh, calf, foot] bone names.
var legs := {}
var targets := {}
var poles := {}
var contact := {"l": false, "r": false}
var locks := 0

var _locked := {"l": false, "r": false}
var _lock_at := {"l": Vector3.ZERO, "r": Vector3.ZERO}
var _weight := {"l": 0.0, "r": 0.0}
var _return_left := -1.0
var _return_total := 0.0
var _return_from := {}
var _return_first := "l"
var _return_kept := ""
# 2026-11-21: plant(): both feet held where they are while the body stands
# (out of an attack whose clip stepped into a stance of its own, so the blend
# into the idle does not move them again), until unplant() -- the body walks,
# attacks, is hit -- or the body itself is moved off them (PLANT_DRIFT).
var _planted := false
var _plant_origin := Vector3.ZERO
const PLANT_DRIFT := 0.15
# A foot is on the ground for plant() this close to the body's floor (the
# foot bone is the ankle: 0.13 m up when standing).
const PLANT_HEIGHT := 0.2
const IK_EASE := 0.12
var _ik_weight := 0.0


func plant() -> void:
	_planted = true
	_plant_origin = Vector3.INF
	for side: String in ["l", "r"]:
		_locked[side] = false


func unplant() -> void:
	_planted = false


func planted() -> bool:
	return _planted


func begin_return(seconds: float, kept := "") -> void:
	if seconds <= 0.0:
		return
	_return_total = seconds
	_return_left = seconds
	_return_from = {}
	_return_kept = kept


func cancel_return() -> void:
	_return_left = -1.0


func returning() -> bool:
	return _return_left >= 0.0


func _process_modification_with_delta(delta: float) -> void:
	var skeleton := get_skeleton()
	if skeleton == null or ik == null or legs.is_empty():
		return
	var world := skeleton.global_transform
	var any := false
	var places := {}
	for side: String in ["l", "r"]:
		var names: Array = legs[side]
		var hip := world * skeleton.get_bone_global_pose(skeleton.find_bone(String(names[0]))).origin
		var knee := world * skeleton.get_bone_global_pose(skeleton.find_bone(String(names[1]))).origin
		var foot := world * skeleton.get_bone_global_pose(skeleton.find_bone(String(names[2]))).origin
		places[side] = [hip, knee, foot]
	if _planted:
		if _plant_origin == Vector3.INF:
			_plant_origin = world.origin
		elif world.origin.distance_to(_plant_origin) > PLANT_DRIFT:
			_planted = false
	if returning() and _return_from.is_empty():
		# The foot that has further to go steps first.
		var far := {}
		for side: String in ["l", "r"]:
			var held: Vector3 = _lock_at[side] if _weight[side] > 0.0 else (places[side][2] as Vector3)
			_return_from[side] = held
			far[side] = held.distance_to(places[side][2] as Vector3)
		_return_first = "l" if float(far["l"]) >= float(far["r"]) else "r"
	for side: String in ["l", "r"]:
		var hip: Vector3 = places[side][0]
		var knee: Vector3 = places[side][1]
		var foot: Vector3 = places[side][2]
		var target := foot
		var holding := false
		if returning():
			var done := 1.0 - _return_left / maxf(_return_total, 0.001)
			if side == _return_kept:
				# Planted: the body moves over it into the stance.
				target = _return_from[side]
			else:
				var span := Vector2(0.1, 0.9) if _return_kept != "" 					else (Vector2(0.0, 0.5) if side == _return_first else Vector2(0.5, 1.0))
				var step := smoothstep(span.x, span.y, done)
				target = (_return_from[side] as Vector3).lerp(foot, step) + Vector3.UP * STEP_LIFT * sin(PI * step)
			holding = true
		elif bool(contact[side]) or (_planted and (_locked[side] or foot.y - world.origin.y <= PLANT_HEIGHT)):
			# (Planted: only a foot that is on the ground -- 2026-11-21, the
			# rising cut's landing froze with both feet held in the air.)
			if not _locked[side]:
				_locked[side] = true
				_lock_at[side] = foot
				locks += 1
			_weight[side] = 1.0
			target = _lock_at[side]
			holding = true
		else:
			_locked[side] = false
			_weight[side] = maxf(0.0, float(_weight[side]) - delta / RELEASE)
			target = foot.lerp(_lock_at[side], float(_weight[side]))
			holding = float(_weight[side]) > 0.0
		var leg := hip.distance_to(knee) + knee.distance_to(foot)
		if hip.distance_to(target) > leg * REACH:
			target = hip + (target - hip).normalized() * leg * REACH
		(targets[side] as Node3D).global_position = target
		# The knee bends the way the clip has it bend.
		var bend := knee - (hip + foot) * 0.5
		if bend.length_squared() < 0.000001:
			bend = -world.basis.z
		(poles[side] as Node3D).global_position = knee + bend.normalized() * 0.5
		any = any or holding
	if returning():
		_return_left -= delta
		if _return_left < 0.0:
			# Done: the feet are where the stance has them, nothing is held.
			_return_left = -1.0
			for side: String in ["l", "r"]:
				_locked[side] = false
				_weight[side] = 0.0
	# 2026-11-21: eased on and off (IK_EASE), never switched: the leg the IK
	# solves is not quite the clip's even on the clip's own foot (the side
	# cut's end bobbed when it came on at once).
	_ik_weight = move_toward(_ik_weight, 1.0 if any else 0.0, delta / IK_EASE)
	ik.influence = _ik_weight
	ik.active = _ik_weight > 0.0
