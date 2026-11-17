class_name PlayerHands
extends Node3D

# 임시 캐릭터 a: two balls that float beside the capsule, and the sword in
# the main one. Drawn only -- no collider, no ruling reads anything here.
#
# A sword skill moves the main hand by code, off the same numbers the judge
# rules with, so the blade is where the ruling is:
#
#   windup    the hand is drawn to where the skill starts
#   strike    side cut / overhead cut: the blade lies on the judge's sweep
#             line -- from the body's centre line at the skill's strike
#             height, at SkillDef.swing_angle_deg(p), the tip at the skill's
#             reach -- and p is Player's swing clock, the one the server's
#             sweep mirrors. Thrust: straight out until the tip is at reach.
#   recovery  the hand goes back to its place in what is left of the recovery
#
# The parry stands the blade across the body (at the def's arc start) for as
# long as the cast lasts and, when the server says it turned a blow, flicks
# it through the def's own short arc.
#
# Nothing about a path is written here as a number: reach, the arc, where it
# starts, which way it turns, how long it takes, the windup and the recovery
# are all read off the SkillDef (whose sword values are Tuning.server's), and
# the blade's length off WeaponKinds. A slider that moves the ruling moves
# the hand. The constants below are the look of the hands themselves.
#
# Lives under Player's Visual container, in its space: the lean, the lying
# and the seat on a horse carry the hands with the body.

enum Mode {
	REST,
	WINDUP,
	STRIKE,
	RETURN,
	GUARD,
	FLICK,
}

const HAND_RADIUS := 0.11
# Where a hand rests: this far outside the body's side, this far above its
# centre (between the waist and the chest) and this far forward, the last two
# per unit of body scale.
const REST_SIDE := 0.17
const REST_HEIGHT := 0.2
const REST_FORWARD := 0.2
# At rest the blade points up and forward by this much, out of the way.
const REST_BLADE_PITCH_DEG := 55.0
# Carrying: both hands up under the load.
const CARRY_SIDE := 0.25
const CARRY_ABOVE_HEAD := 0.25
# The raised shield: forward and up, square to the heading.
const BLOCK_AT := Vector3(-0.1, 0.35, -0.15)
# How fast a hand settles on its resting place, and how long it takes to go
# back when a cast ends with no recovery left to do it in.
const SETTLE_RATE := 14.0
const RELEASE_TIME := 0.12
# The parry's stance: the blade this far in front of the body's surface,
# turned this much across it.
const GUARD_FORWARD := 0.15
# On another screen the windup's stamp and the strike's arrive closer
# together than they were sent, so the strike can begin before the hand has
# reached its start. Further off than CATCH_GAP, the hand is carried onto
# the judge's line over CATCH_UP instead of jumping there; on the owner's
# screen the windup ends on the start and this never runs.
const CATCH_GAP := 0.05
const CATCH_UP := 0.06
const GUARD_SLANT_DEG := 35.0

var player: Player
var mode := Mode.REST
var main: Node3D
var off: Node3D
var _def: SkillDef
var _clock := 0.0
var _span := 0.0
var _from := Transform3D.IDENTITY
var _block := false
var _catch_left := 0.0
# Whether the pose last written was still on its way to the judge's line.
var _carried := false


func setup(owner_player: Player, material: Material) -> void:
	player = owner_player
	main = _hand("MainHand", material)
	off = _hand("OffHand", material)
	snap_to_rest()


func _hand(hand_name: String, material: Material) -> Node3D:
	var slot := Node3D.new()
	slot.name = hand_name
	var ball := MeshInstance3D.new()
	ball.name = "Ball"
	var sphere := SphereMesh.new()
	sphere.radius = HAND_RADIUS
	sphere.height = HAND_RADIUS * 2.0
	ball.mesh = sphere
	ball.material_override = material
	slot.add_child(ball)
	add_child(slot)
	return slot


func snap_to_rest() -> void:
	mode = Mode.REST
	_def = null
	if main != null:
		main.transform = rest_main()
		off.transform = rest_off()


func set_block(raised: bool) -> void:
	_block = raised


# ------------------------------------------------------------------ places

func _carrying() -> bool:
	return player.state == Player.State.GRABBING


func rest_main() -> Transform3D:
	var s := player.body_scale()
	if _carrying():
		return Transform3D(Basis(Vector3.RIGHT, PI * 0.5),
			Vector3(CARRY_SIDE * s, player.half_height() + CARRY_ABOVE_HEAD * s, 0.0))
	return Transform3D(Basis(Vector3.RIGHT, deg_to_rad(REST_BLADE_PITCH_DEG)),
		Vector3(player.radius() + REST_SIDE, REST_HEIGHT * s, -REST_FORWARD * s))


func rest_off() -> Transform3D:
	var s := player.body_scale()
	if _carrying():
		return Transform3D(Basis.IDENTITY,
			Vector3(-CARRY_SIDE * s, player.half_height() + CARRY_ABOVE_HEAD * s, 0.0))
	if _block:
		return Transform3D(Basis.IDENTITY,
			Vector3(BLOCK_AT.x, BLOCK_AT.y * s, -(player.radius() + BLOCK_AT.z)))
	return Transform3D(Basis.IDENTITY,
		Vector3(-(player.radius() + REST_SIDE), REST_HEIGHT * s, -REST_FORWARD * s))


# Hilt to tip of what the main hand holds, along the hand's -Z.
func blade_length() -> float:
	return WeaponKinds.SWORD_LENGTH if player.weapon == WeaponKinds.Kind.SWORD else 0.0


# Whether this skill's motion is the hand's: a sword skill, with the sword
# in the hand.
func drives(def: SkillDef) -> bool:
	return def != null and def.weapon_id == "sword" and player.weapon == WeaponKinds.Kind.SWORD


# A sword skill that neither sweeps nor thrusts stands the blade as a guard
# (the parry).
func is_guard(def: SkillDef) -> bool:
	return drives(def) and not def.judge_by_sweep and not def.is_thrust_motion()


# The centre the judge measures a strike from: the body's centre line, at
# the skill's strike height.
func strike_pivot(def: SkillDef) -> Vector3:
	return Vector3(0.0, def.strike_height * player.body_scale(), 0.0)


# How far along the judge's line the hand sits so that the tip is at reach.
func grip_distance(def: SkillDef) -> float:
	return maxf(def.value("reach") - blade_length(), 0.0)


# The hand at progress p (0..1) of the strike, in the Visual's space. The
# hand's -Z is the blade.
func strike_pose(def: SkillDef, p: float) -> Transform3D:
	var pivot := strike_pivot(def)
	var grip := grip_distance(def)
	if def.is_thrust_motion():
		# Straight out along the heading, from the body's surface until the
		# tip is at reach.
		var start := minf(player.radius(), grip)
		return Transform3D(Basis.IDENTITY,
			pivot + Vector3(0.0, 0.0, -lerpf(start, grip, SkillDef.swing_eased(p))))
	var turned := _arc_basis(def, def.swing_angle_deg(p))
	return Transform3D(turned, pivot + turned * Vector3(0.0, 0.0, -grip))


# The judge's angle as a turn of the heading: horizontal arcs turn about the
# body's up (positive to its left), vertical ones about its right (positive
# up), which is how ServerAuthority's sweep reads the same number.
static func _arc_basis(def: SkillDef, angle_deg: float) -> Basis:
	var angle := deg_to_rad(angle_deg)
	if def.arc_plane == SkillDef.ArcPlane.HORIZONTAL:
		return Basis(Vector3.UP, angle)
	return Basis(Vector3.RIGHT, angle)


# The parry's stance at flick progress q: the blade in front of the body at
# the def's arc angle, slanted across it.
func guard_pose(def: SkillDef, q: float) -> Transform3D:
	var stood := Basis(Vector3.UP, deg_to_rad(GUARD_SLANT_DEG)) * _arc_basis(def, def.swing_angle_deg(q))
	return Transform3D(stood,
		strike_pivot(def) + Vector3(0.0, 0.0, -(player.radius() + GUARD_FORWARD)))


# The blade's two ends in the world, hilt then tip.
func blade_ends() -> Array[Vector3]:
	var ends: Array[Vector3] = [
		main.global_position,
		main.to_global(Vector3(0.0, 0.0, -blade_length()))]
	return ends


# ------------------------------------------------------------------ the cast

func begin_windup(def: SkillDef) -> void:
	if not drives(def) or is_guard(def):
		return
	_def = def
	_from = main.transform
	_clock = 0.0
	_span = def.value("windup")
	mode = Mode.WINDUP


func begin_strike(def: SkillDef) -> void:
	_def = def
	mode = Mode.STRIKE
	_from = main.transform
	var start := strike_pose(def, 0.0)
	_catch_left = CATCH_UP if _from.origin.distance_to(start.origin) > CATCH_GAP else 0.0
	_carried = _catch_left > 0.0
	if _catch_left == 0.0:
		main.transform = start


func is_catching_up() -> bool:
	return mode == Mode.STRIKE and _carried


# From Player's swing clock, every frame of the strike.
func set_progress(p: float) -> void:
	if mode != Mode.STRIKE or _def == null:
		return
	var pose := strike_pose(_def, p)
	_carried = _catch_left > 0.0
	if _carried:
		pose = _from.interpolate_with(pose, 1.0 - _catch_left / CATCH_UP)
	main.transform = pose


# The sweep is over: back to its place in what the recovery has left.
func end_strike() -> void:
	if mode != Mode.STRIKE or _def == null:
		return
	_return_over(_def.value("recovery") - _def.swing_time())


func begin_guard(def: SkillDef) -> void:
	_def = def
	mode = Mode.GUARD


# The server said the parry turned a blow.
func flick(def: SkillDef) -> void:
	if not is_guard(def):
		return
	_def = def
	_clock = 0.0
	_span = def.swing_time()
	mode = Mode.FLICK


# The cast ended or was cut short.
func release() -> void:
	if mode == Mode.WINDUP or mode == Mode.STRIKE or mode == Mode.GUARD:
		_return_over(RELEASE_TIME)


func _return_over(seconds: float) -> void:
	_from = main.transform
	_clock = 0.0
	_span = maxf(seconds, RELEASE_TIME)
	mode = Mode.RETURN


func _process(delta: float) -> void:
	if player == null or main == null:
		return
	var settle := 1.0 - exp(-SETTLE_RATE * delta)
	off.transform = off.transform.interpolate_with(rest_off(), settle)
	match mode:
		Mode.STRIKE:
			_catch_left = maxf(0.0, _catch_left - delta)
		Mode.REST:
			main.transform = main.transform.interpolate_with(rest_main(), settle)
		Mode.WINDUP:
			_clock += delta
			var k := SkillDef.swing_eased(_clock / maxf(_span, 0.001))
			main.transform = _from.interpolate_with(strike_pose(_def, 0.0), k)
		Mode.GUARD:
			main.transform = main.transform.interpolate_with(guard_pose(_def, 0.0), 1.0 - exp(-SETTLE_RATE * 2.0 * delta))
		Mode.FLICK:
			_clock += delta
			var q := clampf(_clock / maxf(_span, 0.001), 0.0, 1.0)
			main.transform = guard_pose(_def, q)
			if q >= 1.0:
				_return_over(RELEASE_TIME)
		Mode.RETURN:
			_clock += delta
			var back := clampf(_clock / maxf(_span, 0.001), 0.0, 1.0)
			main.transform = _from.interpolate_with(rest_main(), back * back * (3.0 - 2.0 * back))
			if back >= 1.0:
				mode = Mode.REST
				_def = null
